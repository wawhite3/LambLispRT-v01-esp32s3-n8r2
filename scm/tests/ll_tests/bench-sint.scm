;;; bench-sint.scm -- Benchmarks designed to show small integer cache benefit.
;;; All key intermediate values stay in 0..255 (byte-width sensor/signal processing).
;;; For each benchmark: with cache = 0 allocations/iter; without = 3-5 allocs/iter.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-15 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.

;;; 1. Low-pass filter (IIR): y[n] = (3*y[n-1] + x[n]) / 4
;;;    Models a simple software RC filter on 8-bit ADC samples.
;;;    x in 0..255, 3y in 0..765, 3y+x in 0..1021, y2 in 0..255 -- all cached.
;;;    Without cache: 4 allocs/iter (x, 3y, 3y+x, y2).
;;;    With cache:    0 allocs/iter.
(define (lpf-bench n)
  (let loop ((i n) (y 128))
    (if (= i 0) y
        (let* ((x  (modulo i 256))
               (y2 (quotient (+ (* 3 y) x) 4)))
          (loop (- i 1) y2)))))

;;; 2. Saturating adder: accumulate byte samples, clamp to 0..255.
;;;    Models audio mixing or sensor fusion with overflow protection.
;;;    All values stay in 0..255 -- all cached.
;;;    Without cache: 3 allocs/iter (sample, sum, clamped).
;;;    With cache:    0 allocs/iter.
(define (sat-add-bench n)
  (let loop ((i n) (acc 128))
    (if (= i 0) acc
        (let* ((s (modulo i 256))
               (r (+ acc s))
               (c (if (> r 255) 255 r)))
          (loop (- i 1) c)))))

;;; 3. Running min/max over byte stream.
;;;    Models finding sensor range over a window.
;;;    lo, hi always 0..255 -- all cached.
;;;    Without cache: 2-3 allocs/iter. With cache: 0 allocs/iter.
(define (minmax-bench n)
  (let loop ((i n) (lo 255) (hi 0))
    (if (= i 0) (+ lo hi)
        (let ((v (modulo i 256)))
          (loop (- i 1)
                (if (< v lo) v lo)
                (if (> v hi) v hi))))))

;;; Run all three with n=4096 (loop counter i also in cache range).
(define (run-sint-bench label)
  (define (current-us) (micros))
  (define (bench-timed name thunk09)
    (let* ((t0 (current-us)) (_ (thunk09)) (dt (- (current-us) t0)))
      (display name) (display dt) (display " us\n")))
  (display "=== ") (display label) (display " ===\n")
  (bench-timed "lpf(4096)     " (lambda () (lpf-bench 4096)))
  (bench-timed "sat-add(4096) " (lambda () (sat-add-bench 4096)))
  (bench-timed "minmax(4096)  " (lambda () (minmax-bench 4096))))
