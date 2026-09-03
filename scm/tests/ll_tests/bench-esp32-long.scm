;;; bench-esp32-long.scm -- ESP32 benchmark with larger params to reduce noise.
;;; Single run per benchmark, params ~3-5x the standard bench-runner.scm.
;;; Interp and Bytecode only -- NCG falls back to bytecode on ESP32-S3.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-15 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.

(define (current-us) (micros))

;;; Suppress auto-run in benchmarks.scm.
(define (bench name thunk03 expected) #f)
(define (run-benchmarks) #f)
(load "benchmarks.scm" 0)

(define (bench-timed name thunk04)
  (let* ((t0     (current-us))
         (result (thunk04))
         (dt     (- (current-us) t0)))
    (display name)
    (display dt)
    (display " us\n")))

(define (run-suite label)
  (display "=== ") (display label) (display " ===\n")
  (bench-timed "tak(7,4,1)        " (lambda () (tak 7 4 1)))
  (bench-timed "iota+sum(2000)    " (lambda () (list-sum (iota 2000))))
  (bench-timed "closure(2000)     " (lambda () (closure-bench 2000)))
  (bench-timed "map-x^2(300)      " (lambda () (map-bench 300))))

(run-suite "Interpreter")
(compile-environment! (interaction-environment))
(run-suite "Bytecode")

(display "--- done ---\n")
