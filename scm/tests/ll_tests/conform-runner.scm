;;; conform-runner.scm -- Load all R7RS conformance test suites.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-27 19:30:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; r7rs-tests.scm   -> r7rs-pass / r7rs-fail
;;; rxrs-tests.scm   -> rxrs-pass / rxrs-fail (value-verifying, 2026-06-23)
;;; r5rs-pitfall.scm -> r5rs-pitfall-pass / r5rs-pitfall-fail
;;;
;;; Usage: echo '(load "ll_tests/conform-runner.scm" 0)' | ./program

(define conform-pass 0)
(define conform-fail 0)
;; Exceptions = KNOWN, ACCEPTED spec nonconformances (call/cc, dynamic-wind, parameterize, ...):
;; counted separately from pass/fail so a clean run still enumerates every deviation.
(define conform-exception 0)
(define conform-exception-expected 0)

(display "\n=== r7rs-tests ===\n")
(load "ll_tests/r7rs-tests.scm" 0)
(set! conform-pass (+ conform-pass r7rs-pass))
(set! conform-fail (+ conform-fail r7rs-fail))
(set! conform-exception (+ conform-exception r7rs-exception))
(set! conform-exception-expected (+ conform-exception-expected r7rs-exception-expected))

;; NB: do NOT pre-define these counters here -- a top-level (define X 0) before the
;; (load ...) shadows the loaded file's own (define X ...), so the aggregation below
;; would read 0.  Mirror the r7rs pattern: load, then read the file's counters.
(display "\n=== rxrs-tests ===\n")
(load "ll_tests/rxrs-tests.scm" 0)
(set! conform-pass (+ conform-pass rxrs-pass))
(set! conform-fail (+ conform-fail rxrs-fail))
(set! conform-exception (+ conform-exception rxrs-exception))
(set! conform-exception-expected (+ conform-exception-expected rxrs-exception-expected))

(display "\n=== r5rs-pitfall ===\n")
(load "ll_tests/r5rs-pitfall.scm" 0)
(set! conform-pass (+ conform-pass r5rs-pitfall-pass))
(set! conform-fail (+ conform-fail r5rs-pitfall-fail))
(set! conform-exception (+ conform-exception r5rs-pitfall-exception))
(set! conform-exception-expected (+ conform-exception-expected r5rs-pitfall-exception-expected))

(display "\nTotal: ") (display conform-pass) (display " pass, ")
(display conform-fail) (display " fail, ")
(display conform-exception) (display " exception") (newline)
(display "Exceptions expected: ") (display conform-exception-expected) (newline)

;; Expected-exception report: the UNIMPLEMENTED R7RS FUNCTIONS (the spec differences) and how many
;; conformance cases each makes non-conformant -- grouped by the underlying cause.  We name only the
;; function/form, never the individual test cases (those are noise).  Counts are computed from the
;; cases each function actually caused (classified below), so they cannot drift out of sync.
(define %exc-names (append r7rs-exception-names r5rs-pitfall-exception-names))
(define (%exc->fn name)                          ;; the R7RS function a failing case exercises
  (cond ((not (string? name))                       "call-with-current-continuation") ;; pitfall ids = call/cc
        ((string-contains name "call/cc")           "call-with-current-continuation")
        ((string-contains name "call-with-current") "call-with-current-continuation")
        ((string-contains name "dynamic-wind")      "dynamic-wind")
        ((string-contains name "make-parameter")    "make-parameter")
        ((string-contains name "parameterize")      "parameterize")
        ((string-contains name "raise-continuable") "raise-continuable")
        ((string-contains name "define-library")    "define-library")
        ((string-contains name "import")            "import")
        (else                                       "unclassified")))
(define %fn-count '())                            ;; alist (function . #cases), from actual data
(for-each (lambda (n)
            (let* ((fn (%exc->fn n)) (p (assoc fn %fn-count)))
              (if p (set-cdr! p (+ 1 (cdr p))) (set! %fn-count (cons (cons fn 1) %fn-count)))))
          %exc-names)
(define (%count-of fn) (let ((p (assoc fn %fn-count))) (if p (cdr p) 0)))
;; ordered (function . cause) -- continuation-dependent functions grouped first, then the library system
(define %exc-report
  (list (cons "call-with-current-continuation" "requires first-class continuations (call/cc)")
        (cons "dynamic-wind"                    "requires first-class continuations (call/cc)")
        (cons "make-parameter"                  "requires first-class continuations (call/cc)")
        (cons "parameterize"                    "requires first-class continuations (call/cc)")
        (cons "raise-continuable"               "requires first-class continuations (call/cc)")
        (cons "import"                          "library system (no value on a single-image target)")
        (cons "define-library"                  "library system (no value on a single-image target)")))
(display "\nUnimplemented R7RS functions (deliberate embedded design gaps) -- function : exceptions:\n")
(let ((last ""))
  (for-each (lambda (fc)
              (when (not (string=? (cdr fc) last)) (display "  -- ") (display (cdr fc)) (display "\n") (set! last (cdr fc)))
              (display "    ") (display (car fc)) (display " : ") (display (%count-of (car fc))) (display " exceptions\n"))
            %exc-report))
(display "  Total exceptions expected: ") (display conform-exception-expected) (newline)
;; Machine footnote for the report parser (w3_test.sh matches "EXCEPTION <name> | reason <text>"):
;; ONE line per exception CASE, reason = the R7RS function it exercises.  gen_comprehensive_report
;; groups these by function to produce the human report -- so we must emit per case, not per function.
(for-each (lambda (n)
            (display "EXCEPTION ") (display n) (display " | reason ") (display (%exc->fn n)) (newline))
          %exc-names)
(let ((tsum (apply + (map (lambda (fc) (%count-of (car fc))) %exc-report))))
  (when (not (= tsum conform-exception))
    (display "WARNING: function breakdown sums to ") (display tsum)
    (display " but ") (display conform-exception) (display " exceptions were counted\n")))
(display "--- conform done ---") (newline)

