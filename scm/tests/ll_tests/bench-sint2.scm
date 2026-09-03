;;; bench-sint2.scm -- Signed small-integer benchmarks for the sint cache.
;;; Uses the negative portion of the cache range (-255..0).
;;; All intermediate values stay in -255..255 (signed byte, common in sensor/audio work).
;;; Without cache: 3-5 allocs/iter.  With cache (-255..4096): 0 allocs/iter.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-15 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.

;;; 1. Signed IIR low-pass filter on centered samples.
;;;    Input: x in -128..127 (signed 8-bit ADC or audio).
;;;    y = (3*y + x) / 4 -- same as lpf-bench but signed.
;;;    3y in -384..381, 3y+x in -512..508, y2 in -128..127 -- all cached.
;;;    Without cache: 4 allocs/iter.  With cache: 0.
(define (signed-lpf-bench n)
  (let loop ((i n) (y 0))
    (if (= i 0) y
        (let* ((x  (- (modulo i 256) 128))   ; -128..127, cached
               (y2 (quotient (+ (* 3 y) x) 4))) ; -128..127, cached
          (loop (- i 1) y2)))))

;;; 2. Signed saturating clamp to -128..127.
;;;    Models audio sample clipping or signed PWM duty cycle.
;;;    All values -128..127 -- all cached.
;;;    Without cache: 3-4 allocs/iter.  With cache: 0.
(define (signed-clamp-bench n)
  (let loop ((i n) (acc 0))
    (if (= i 0) acc
        (let* ((delta (- (modulo i 64) 32))    ; -32..31, cached
               (r     (+ acc delta))
               (c     (if (> r 127) 127 (if (< r -128) -128 r))))
          (loop (- i 1) c)))))

;;; 3. Signed running min/max (range detection).
;;;    Models finding the peak-to-peak range of a signed sensor signal.
;;;    lo, hi always -128..127 -- all cached.
;;;    Without cache: 2-3 allocs/iter.  With cache: 0.
(define (signed-minmax-bench n)
  (let loop ((i n) (lo 127) (hi -128))
    (if (= i 0) (- hi lo)
        (let ((v (- (modulo i 256) 128)))   ; -128..127, cached
          (loop (- i 1)
                (if (< v lo) v lo)
                (if (> v hi) v hi))))))

;;; Run all three benchmarks.
(define (run-sint2-bench label)
  (define (current-us) (micros))
  (define (bench-timed name thunk10)
    (let* ((t0 (current-us)) (_ (thunk10)) (dt (- (current-us) t0)))
      (display name) (display dt) (display " us\n")))
  (display "=== ") (display label) (display " ===\n")
  (bench-timed "signed-lpf(4096)    " (lambda () (signed-lpf-bench 4096)))
  (bench-timed "signed-clamp(4096)  " (lambda () (signed-clamp-bench 4096)))
  (bench-timed "signed-minmax(4096) " (lambda () (signed-minmax-bench 4096))))
