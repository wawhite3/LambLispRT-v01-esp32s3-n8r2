;;; pause_bench.scm -- GC pause latency benchmark (P43).
;;; Copyright 2026 by Frobenius Norm LLC 2026-05-05 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Allocates N cons cells; measures worst-case and mean per-allocation time.
;;; Requires current-us (LambLisp built-in).
;;; Output: "pause_bench: worst=Xus mean=Y/Zus n=N"

(define (pause-bench n)
  (let loop ((i 0) (worst 0) (sum 0))
    (if (>= i n)
      (begin
        (display "pause_bench: worst=") (display worst) (display "us")
        (display " mean=") (display sum) (display "/") (display n) (display "us")
        (display " n=") (display n) (newline))
      (let* ((t0  (current-us))
             (p   (cons i i))
             (dt  (- (current-us) t0)))
        (loop (+ i 1)
              (if (> dt worst) dt worst)
              (+ sum dt))))))

(pause-bench 100000)
