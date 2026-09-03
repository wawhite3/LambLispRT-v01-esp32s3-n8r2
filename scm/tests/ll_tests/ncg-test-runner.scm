;;; ncg-test-runner.scm -- Run r7rs-tests.scm under full NCG compilation.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-17 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Strategy: compile everything already in the environment to NCG first,
;;; then load the test file.  The test framework (check/check-true/etc.)
;;; runs in interpreter mode, but all R7RS primitives under test are NCG.

(display "=== Compiling environment to NCG ===\n")
(ncg-compile-environment! (interaction-environment))
(display "=== NCG compile done -- loading r7rs-tests.scm ===\n")
(load "r7rs-tests.scm" 0)
(display "=== ncg-test-runner done ===\n")
