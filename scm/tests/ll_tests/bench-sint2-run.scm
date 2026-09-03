;;; bench-sint2-run.scm -- Runner for bench-sint2.scm.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-15 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.

(load "bench-sint2.scm" 0)

(run-sint2-bench "Interpreter")
(compile-environment! (interaction-environment))
(run-sint2-bench "Bytecode")

(display "--- done ---\n")
