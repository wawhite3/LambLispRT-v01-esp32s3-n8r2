;;; bench-adc.scm -- 12-bit ADC calibration pipeline benchmarks.
;;; Models real embedded signal processing where raw ADC values (0..4095) are
;;; offset-corrected to a signed range and filtered.  All per-sample intermediate
;;; values fit in -2048..4095, matching the sint cache range exactly.
;;;
;;; With cache:    0-2 allocs/iter (only unbounded accumulators).
;;; Without cache: 4-6 allocs/iter.
;;;
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-15 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.

;;;-----------------------------------------------------------------------------
;;; Pseudo-random 12-bit ADC sample stream.
;;; Returns a value in 0..4095 for each i -- good spectral spread.
(define (adc-raw i) (modulo (* i 1031) 4096))   ;!< raw 0..4095, all cached

;;;-----------------------------------------------------------------------------
;;; 1. Offset + gain calibration with min/max/sum statistics.
;;;    Simulates: read raw → subtract midpoint offset → apply ±2% gain trim.
;;;    offset-corrected cal = raw - 2048   → -2048..2047   CACHED
;;;    gain trim delta = cal / 50          → -40..40       CACHED
;;;    calibrated = cal + delta            → -2088..2087   CACHED
;;;    vmin, vmax track calibrated range   → -2088..2087   CACHED
;;;    sum grows unbounded (accepted: it is the output, not intermediate)
(define (adc-cal-bench n)
  (let loop ((i n) (vmin 2047) (vmax -2048) (sum 0))
    (if (= i 0)
        (list vmin vmax (quotient sum n))
        (let* ((raw  (adc-raw i))                ; 0..4095, cached
               (cal  (- raw 2048))               ; -2048..2047, cached
               (trim (quotient cal 50))           ; gain trim: -40..40, cached
               (cv   (+ cal trim)))               ; calibrated: -2088..2087, cached
          (loop (- i 1)
                (if (< cv vmin) cv vmin)
                (if (> cv vmax) cv vmax)
                (+ sum cv))))))

;;;-----------------------------------------------------------------------------
;;; 2. Exponential moving average (EMA) filter on calibrated data.
;;;    Uses the decomposed form  ema' = ema - ema/16 + raw/16  to avoid
;;;    large intermediate products; all terms stay in -2048..2047.
;;;    ema/16  → -128..127   CACHED
;;;    raw/16  → -128..127   CACHED
;;;    ema - ema/16 + raw/16 → converges to mean of raw ≈ 0  CACHED
(define (adc-ema-bench n)
  (let loop ((i n) (ema 0))
    (if (= i 0) ema
        (let* ((raw  (- (adc-raw i) 2048))       ; -2048..2047, cached
               (es   (quotient ema 16))           ; -128..127, cached
               (rs   (quotient raw 16))           ; -128..127, cached
               (ema2 (+ (- ema es) rs)))          ; new ema, cached
          (loop (- i 1) ema2)))))

;;;-----------------------------------------------------------------------------
;;; 3. Differential measurement: two channels sharing a common midpoint.
;;;    Simulates a bridge sensor or dual-supply ADC (e.g. load cell, thermocouple).
;;;    Both channels biased to center 1024..3071 so diff stays -2047..2047.
;;;    ch-a, ch-b → 1024..3071  CACHED
;;;    diff = ch-a - ch-b → -2047..2047  CACHED
;;;    |diff| → 0..2047  CACHED
;;;    threshold hits counted; count grows unbounded (accepted)
;;;    NOTE: threshold inlined as constant -- avoids outer let* frame lookup penalty.
(define (adc-diff-bench n)
  (let loop ((i n) (peak 0) (hits 0))
    (if (= i 0)
        (list peak hits)
        (let* ((ch-a  (+ (modulo (* i 1031) 2048) 1024))  ; 1024..3071, cached
               (ch-b  (+ (modulo (* i 1033) 2048) 1024))  ; 1024..3071, cached
               (diff  (- ch-a ch-b))                       ; -2047..2047, cached
               (adiff (if (< diff 0) (- 0 diff) diff))     ; 0..2047, cached
               (hit   (if (> adiff 256) 1 0)))             ; 0 or 1, cached
          (loop (- i 1)
                (if (> adiff peak) adiff peak)
                (+ hits hit))))))

;;;-----------------------------------------------------------------------------
;;; Runner
(define (run-adc-bench label)
  (define (current-us) (micros))
  (define (bench-timed name thunk02)
    (let* ((t0 (current-us)) (_ (thunk02)) (dt (- (current-us) t0)))
      (display name) (display dt) (display " us\n")))
  (display "=== ") (display label) (display " ===\n")
  (bench-timed "adc-cal(4096)   " (lambda () (adc-cal-bench  4096)))
  (bench-timed "adc-ema(4096)   " (lambda () (adc-ema-bench  4096)))
  (bench-timed "adc-diff(4096)  " (lambda () (adc-diff-bench 4096))))
