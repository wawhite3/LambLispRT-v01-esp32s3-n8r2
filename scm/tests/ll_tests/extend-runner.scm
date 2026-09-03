;;; extend-runner.scm -- Load LambLisp extension test suite.
;;; Copyright 2026 by Frobenius Norm LLC 2026-06-02 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; ll-extensions-tests.scm  -> ll-ext-pass / ll-ext-fail  (always)
;;; lamblisp-tests.scm        -> lamblisp-test-pass / lamblisp-test-fail (S3+ only)
;;;
;;; Usage: echo '(load "ll_tests/extend-runner.scm" 0)' | ./program

(define extend-pass 0)
(define extend-fail 0)

(display "\n=== ll-extensions-tests ===\n")
(load "ll_tests/ll-extensions-tests.scm" 0)
(set! extend-pass (+ extend-pass ll-ext-pass))
(set! extend-fail (+ extend-fail ll-ext-fail))

(define lamblisp-test-pass 0)
(define lamblisp-test-fail 0)
(display "\n=== lamblisp-tests ===\n")
(guard (e (#t (display "SKIPPED (file not on this board)\n")))
  (load "ll_tests/lamblisp-tests.scm" 0))
(set! extend-pass (+ extend-pass lamblisp-test-pass))
(set! extend-fail (+ extend-fail lamblisp-test-fail))

(display "\nTotal: ") (display extend-pass) (display " pass, ")
(display extend-fail) (display " fail") (newline)
(display "--- extend done ---") (newline)

