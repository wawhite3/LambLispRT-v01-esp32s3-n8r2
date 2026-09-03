;;; bench-sint-run.scm -- Runner for bench-sint.scm benchmarks.
;;; Loads definitions, runs interpreter then bytecode suite.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-15 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.

(load "bench-sint.scm" 0)

(run-sint-bench "Interpreter")
(compile-environment! (interaction-environment))
(run-sint-bench "Bytecode")

(display "--- done ---\n")
