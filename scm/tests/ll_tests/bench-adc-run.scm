;;; bench-adc-run.scm -- Runner for bench-adc.scm.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-15 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.

(load "bench-adc.scm" 0)

(run-adc-bench "Interpreter")
(compile-environment! (interaction-environment))
(run-adc-bench "Bytecode")

(display "--- done ---\n")
