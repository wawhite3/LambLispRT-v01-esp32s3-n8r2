;;; Copyright 2026 by Frobenius Norm LLC 2026-05-19 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; compiler-coverage.scm -- report AST→BC and BC→NCG coverage for an environment.
;;;
;;; Run:  echo '(load "data/ll_tests/compiler-coverage.scm" 0)' | ./program

(compiler-coverage (interaction-environment))
