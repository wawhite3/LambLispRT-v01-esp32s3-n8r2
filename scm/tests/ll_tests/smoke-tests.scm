;;; smoke-tests.scm -- ~10 must-pass invariants; always < 2 s.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-27 19:30:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Catches: arithmetic, lambda, tail-call, GC stress, string, list,
;;; boolean, define, let.  All tests run; Total line always printed.
;;;
;;; Usage: echo '(load "ll_tests/smoke-tests.scm" 0)' | ./program

(define smoke-pass 0)
(define smoke-fail 0)

;; Report, on PASS and FAIL alike, the challenge (the ACTUAL expression under test), the expected
;; value and the actual (tested) value -- so the report shows a per-test line a reviewer can verify
;; by eye.  `check` is a MACRO so it can print the unevaluated `expr` form AND evaluate it.  The
;; leading "PASS "/"FAIL " token stays first (the harness counts ^PASS/^FAIL lines and the Total
;; line); the "| expr <form> | expected <e> | got <a>" suffix is what the report parser extracts.
;; `write` (not `display`) so strings stay quoted and lists keep their structure, on one line.
(define-syntax check
  (syntax-rules ()
    ((_ name expected expr)
     (let* ((expected-val expected)
            (actual-val   expr)
            (ok (equal? expected-val actual-val)))
       (display (if ok "PASS " "FAIL "))
       (display name)
       (display " | expr ")     (write (quote expr))
       (display " | expected ") (write expected-val)
       (display " | got ")      (write actual-val)
       (newline)
       (if ok (set! smoke-pass (+ smoke-pass 1))
              (set! smoke-fail (+ smoke-fail 1)))))))

(check "arithmetic"   4          (+ 2 2))
(check "lambda"       9          ((lambda (x) (* x x)) 3))
(check "tail-call"    0          (let loop ((n 1000)) (if (= n 0) 0 (loop (- n 1)))))
(check "list"         '(1 2 3)   (list 1 2 3))
(check "car/cdr"      2          (car (cdr '(1 2 3))))
(check "string"       "hi"       (string-append "h" "i"))
(check "gc-stress"    #t         (let loop ((n 5000))
                                   (if (= n 0) #t (begin (cons n n) (loop (- n 1))))))
(check "boolean"      #f         (and #t #f))
(check "define"       42         (begin (define smoke-x 42) smoke-x))
(check "let"          7          (let ((a 3) (b 4)) (+ a b)))

(display "Total: ") (display smoke-pass) (display " pass, ")
(display smoke-fail) (display " fail") (newline)
(display "--- smoke done ---") (newline)

