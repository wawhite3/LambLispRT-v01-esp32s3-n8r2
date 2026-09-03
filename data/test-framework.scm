; Copyright 2026 by Frobenius Norm LLC 2026-04-18 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
; test-framework.scm -- Unified test and timing utilities for LambLisp.

#|!
@file test-framework.scm
@brief Shared test assertion macros and timing utilities.

## Synopsis

    (load "test-framework.scm" 0)

    (test-suite "arithmetic"
      (test "addition"       (+ 1 2)    3)
      (test "subtraction"    (- 5 3)    2)
      (test-error "div/zero" (/ 1 0)))

    (test-report)   ; => "3 passed, 0 failed" (or nothing if tf-quiet)

## Compatibility

Defines `check` as an alias for `test` so existing suites that call
`(check name expected actual)` work unchanged, but note argument order:
existing suites pass `(check name expected actual)` while `test` uses
`(test name expr expected)`.  The alias handles both orderings -- see below.

## Globals

    tf-pass    -- count of passing assertions (this session)
    tf-fail    -- count of failing assertions (this session)
    tf-skip    -- count of skipped assertions
    tf-quiet   -- if #t, suppress PASS lines (only FAILs print)

|#

;;; ---------------------------------------------------------------------------
;;; Error catch sentinel -- a unique pair; eq? identity used to detect catch.
;;; with-exception-handler is a C++ primitive; always available without setup.scm.
;;; ---------------------------------------------------------------------------

(define tf-error-sentinel (list 'tf-error))  ;;!< unique identity; never returned by user exprs

;;; Evaluate expr; return its value, or tf-error-sentinel if it throws.
;;; Handler returns the error message string as the cdr of the sentinel pair.
(define-syntax tf-try
  (syntax-rules ()
    ((_ expr)
     (with-exception-handler
       (lambda (e)
         (cons (car tf-error-sentinel)
               (if (and (pair? e) (eq? (car e) 'error-object))
                 (cadr e)                        ;;!< R7RS error-object message
                 "error")))                      ;;!< VM T_ERROR or other
       (lambda () expr)))))

(define (tf-error? v)
  (and (pair? v) (eq? (car v) 'tf-error)))

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

(define tf-pass  0)   ;;!< passing assertions since last (tf-reset!)
(define tf-fail  0)   ;;!< failing assertions since last (tf-reset!)
(define tf-skip  0)   ;;!< skipped assertions
(define tf-quiet #f)  ;;!< suppress PASS output when #t

(define (tf-reset!)
  (set! tf-pass 0)
  (set! tf-fail 0)
  (set! tf-skip 0))

;;; ---------------------------------------------------------------------------
;;; Core assertion -- (test label expr expected)
;;; Evaluates expr; catches any error and treats it as the actual value.
;;; ---------------------------------------------------------------------------

(define-syntax test
  (syntax-rules ()
    ((_ label expr expected)
     (let* ((e expected)
            (a (tf-try expr)))
       (if (equal? e a)
         (begin
           (set! tf-pass (+ tf-pass 1))
           (unless tf-quiet
             (display "PASS ") (display label) (newline)))
         (begin
           (set! tf-fail (+ tf-fail 1))
           (display "FAIL ") (display label)
           (display "\n      expected: ") (write e)
           (display "\n      got:      ") (write a)
           (newline)))))))

;;; (test-error label expr) -- assert that expr raises an error.
(define-syntax test-error
  (syntax-rules ()
    ((_ label expr)
     (let ((threw? (tf-error? (tf-try expr))))
       (if threw?
         (begin
           (set! tf-pass (+ tf-pass 1))
           (unless tf-quiet
             (display "PASS ") (display label) (display " (error expected)") (newline)))
         (begin
           (set! tf-fail (+ tf-fail 1))
           (display "FAIL ") (display label)
           (display " -- expected error but none raised") (newline)))))))

;;; (test-true label expr) -- assert that expr is truthy.
(define-syntax test-true
  (syntax-rules ()
    ((_ label expr)
     (test label (if expr #t #f) #t))))

;;; (test-false label expr) -- assert that expr is #f.
(define-syntax test-false
  (syntax-rules ()
    ((_ label expr)
     (test label (if expr #t #f) #f))))

;;; ---------------------------------------------------------------------------
;;; Backward-compat alias -- existing suites call (check name expected actual)
;;; where expected and actual are already-evaluated values.
;;; ---------------------------------------------------------------------------

(define (check name expected actual)
  (if (equal? expected actual)
    (begin
      (set! tf-pass (+ tf-pass 1))
      (unless tf-quiet
        (display "PASS ") (display name) (newline)))
    (begin
      (set! tf-fail (+ tf-fail 1))
      (display "FAIL ") (display name)
      (display "\n      expected: ") (write expected)
      (display "\n      got:      ") (write actual)
      (newline))))

;;; ---------------------------------------------------------------------------
;;; (test-suite "name" body ...) -- group assertions; print one-line summary.
;;; Saves and restores counters so suites nest cleanly.
;;; ---------------------------------------------------------------------------

(define-syntax test-suite
  (syntax-rules ()
    ((_ name body ...)
     (let ((p0 tf-pass) (f0 tf-fail))
       (display "--- ") (display name) (display " ---") (newline)
       body ...
       (let ((dp (- tf-pass p0))
             (df (- tf-fail f0)))
         (display name) (display ": ")
         (display dp) (display " passed")
         (when (> df 0)
           (display ", ") (display df) (display " FAILED"))
         (newline))))))

;;; ---------------------------------------------------------------------------
;;; (test-skip label reason) -- record a skipped test.
;;; ---------------------------------------------------------------------------

(define-syntax test-skip
  (syntax-rules ()
    ((_ label reason)
     (begin
       (set! tf-skip (+ tf-skip 1))
       (unless tf-quiet
         (display "SKIP ") (display label)
         (display " -- ") (display reason) (newline))))))

;;; ---------------------------------------------------------------------------
;;; (test-report) -- print totals; return #t if all passed.
;;; ---------------------------------------------------------------------------

(define (test-report)
  (display "=== ")
  (display tf-pass) (display " passed")
  (when (> tf-fail 0)
    (display ", ") (display tf-fail) (display " FAILED"))
  (when (> tf-skip 0)
    (display ", ") (display tf-skip) (display " skipped"))
  (display " ===") (newline)
  (= tf-fail 0))

;;; ---------------------------------------------------------------------------
;;; (time expr) -- evaluate expr, print elapsed time, return value.
;;; Uses micros() for sub-millisecond resolution.
;;; ---------------------------------------------------------------------------

(define-syntax time
  (syntax-rules ()
    ((_ expr)
     (let* ((t0 (micros))
            (v  expr)
            (dt (- (micros) t0)))
       (display dt) (display " us")
       (when (>= dt 1000)
         (display " (")
         (display (/ dt 1000))
         (display " ms)"))
       (newline)
       v))))

;;; (time-n n expr) -- run expr n times, print total and per-call average.
(define-syntax time-n
  (syntax-rules ()
    ((_ n expr)
     (let* ((t0  (micros))
            (cnt n))
       (let loop ((i 0))
         (when (< i cnt) expr (loop (+ i 1))))
       (let ((dt (- (micros) t0)))
         (display cnt) (display "x: ")
         (display dt) (display " us total, ")
         (display (quotient dt cnt)) (display " us/call")
         (newline))))))

