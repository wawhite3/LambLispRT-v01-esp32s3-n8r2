;;; ncg_iota_bench.scm -- standalone iota(500) timing for ESP32.
;;; Uses the C++ native mop3_iota (SRFI-1) -- does NOT load benchmarks.scm,
;;; which would shadow the C++ iota with a Scheme version.
;;; Usage: (load "ncg_iota_bench.scm" 0)
;;; Copyright 2026 by Frobenius Norm LLC 2026-05-13 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.

(let ((dummy (iota 500)))    ; warmup + allow GC to stabilize
  #t)

(let* ((R   50)
       (t0  (micros))
       (dummy (let lp ((i R))
                (if (= i 0) #t
                    (begin (iota 500) (lp (- i 1))))))
       (dt  (quotient (- (micros) t0) R)))
  (display "iota(500) C++: ")
  (display dt)
  (display " us")
  (newline))

(display "--- done ---")
(newline)

; end of ncg_iota_bench.scm
