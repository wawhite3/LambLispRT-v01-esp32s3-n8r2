;;; bc-ngram.scm -- P165 Layer 1: static opcode n-gram histogram over the losing benchmarks.
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-30 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Usage: echo '(load "ll_tests/bc-ngram.scm" 0)' | ./program   (or: ./w3 bc-ngram <env>)
;;;
;;; Measures WHICH adjacent bytecode sequences actually occur (fusable-only: no window
;;; crosses a jump target) in the benchmarks P165 names as losing.  This histogram is the
;;; go/no-go gate for P165: a few dominant pairs/triples -> a fusion table pays; a flat
;;; tail -> close P165.  Static occurrence is a good proxy here because these are tight
;;; recursive workers whose whole body is the hot path.

(load "ll_tests/benchmarks.scm" 0)              ;; defines fib tak ackermann tree-sum make-adder closure-bench
(compile-environment! (current-environment))    ;; ensure every proc is T_BYTECODE (idempotent if autocompiled)

(define (ng name proc)
  (syslog "\n#### ~a ####\n" name)
  (if (bytecode? proc)
      (bc-ngram (list proc) 12)
      (syslog "  (~a is not compiled to bytecode -- skipped)\n" name)))

;; per-benchmark (isolates each proc's own hot sequences)
(ng 'fib          fib)
(ng 'tak          tak)
(ng 'ackermann    ackermann)
(ng 'tree-sum     tree-sum)
(ng 'make-adder   make-adder)      ;; closure(500): outer builder + inner (lambda (x) (+ x n)) via const pool
(ng 'closure-bench closure-bench)

;; combined view -- the decision-driving histogram across all six losing benchmarks
(syslog "\n#### COMBINED (all six losing benchmarks) ####\n")
(bc-ngram (list fib tak ackermann tree-sum make-adder closure-bench) 20)

(syslog "\n--- bc-ngram done ---\n")
