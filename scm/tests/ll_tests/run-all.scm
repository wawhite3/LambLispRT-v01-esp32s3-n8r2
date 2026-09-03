;;; run-all.scm -- Run all LambLisp test suites and print a combined summary.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-18 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Runs: subsystem tests, conformance tests, extension tests.
;;; Benchmarks are NOT included -- run ll_tests/bench-runner.scm separately.
;;;
;;; Usage (from project root):
;;;   echo '(load "ll_tests/run-all.scm" 0)' | .pio/build/linux_x86_64/program
;;;
;;; On the board (after REPL up):
;;;   (load "ll_tests/run-all.scm" 0)
;;;
;;; NOTE: SPIFFS path limit is 32 chars.  All ll_tests/*.scm files are flat
;;; (no subdirectories) so their paths stay within the limit.

(define run-all-total-pass 0)
(define run-all-total-fail 0)

;;; Helper: accumulate pass/fail from a suite's global counters.
;;; Guard protects against a test file aborting early and leaving counters unbound.
(define (run-all-tally! pass-sym fail-sym)
  (guard (e (#t
             (display "WARNING: counters not available for ")
             (display (list pass-sym fail-sym))
             (display " (test file may have aborted early)\n")))
    (let ((p (eval pass-sym (interaction-environment)))
          (f (eval fail-sym (interaction-environment))))
      (set! run-all-total-pass (+ run-all-total-pass p))
      (set! run-all-total-fail (+ run-all-total-fail f)))))

;;; ---------------------------------------------------------------------------
;;; Subsystem tests
;;; ---------------------------------------------------------------------------

(display "\n=== Subsystem tests ===\n")

(load "ll_tests/let-tests.scm" 0)
(load "ll_tests/named-let-tests.scm" 0)
(load "ll_tests/letrec-tests.scm" 0)
(load "ll_tests/loop-tests.scm" 0)
(load "ll_tests/qq-tests.scm" 0)
(load "ll_tests/syntax-rules-tests.scm" 0)
(load "ll_tests/bytecode-tests.scm" 0)
(load "ll_tests/ncg-tests.scm" 0)

;;; Network and LLIP tests require a running server -- skipped in run-all.
;;; Load manually: (load "ll_tests/llip-tests.scm" 0)
;;;                (load "ll_tests/network-tests.scm" 0)

;;; Subsystem suites (let, named-let, letrec, loop, qq, syntax-rules, bytecode, ncg)
;;; print PASS/FAIL per test but do not accumulate named counters.
;;; They are not included in the run-all-total; check their individual output for details.

;;; ---------------------------------------------------------------------------
;;; Conformance tests
;;; ---------------------------------------------------------------------------

(display "\n=== Conformance tests ===\n")

(load "ll_tests/r7rs-tests.scm" 0)
(load "ll_tests/rxrs-tests.scm" 0)
(load "ll_tests/r5rs-pitfall.scm" 0)
(load "ll_tests/utf8-tests.scm" 0)

(run-all-tally! 'r7rs-pass          'r7rs-fail)
(run-all-tally! 'r5rs-pitfall-pass  'r5rs-pitfall-fail)
(run-all-tally! 'utf8-pass          'utf8-fail)

;;; ---------------------------------------------------------------------------
;;; Extension tests
;;; ---------------------------------------------------------------------------

(display "\n=== Extension tests ===\n")

(load "ll_tests/lamblisp-tests.scm" 0)

(run-all-tally! 'lamblisp-test-pass 'lamblisp-test-fail)

;;; ---------------------------------------------------------------------------
;;; Combined summary
;;; ---------------------------------------------------------------------------

(display "\n=== run-all summary ===\n")
(display "Total: ")
(display run-all-total-pass) (display " pass, ")
(display run-all-total-fail) (display " fail")
(newline)

; end of run-all.scm
