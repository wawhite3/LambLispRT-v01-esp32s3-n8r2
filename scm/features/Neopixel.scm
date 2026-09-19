;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(info "Loading neopixel controls\n")

#|
Return a list of float RGB values corresponding to the given HSL values
All values in the interval [0..1]
|#
(define hsl2rgbf
  (let ((me "(hsl2rgbf)")
	(0_3rds 0.0)
	(1_3rd  (/f 3.0))
	(2_3rds (/f 2.0 3.0))
	)
    (lambda (hue sat lum)
      (let* ((h (- hue (floor hue) 0.0))
	     (s (if (<f sat 0.0) 0.0 (if (>f sat 1.0) 1.0 sat)))
	     (l (if (<f lum 0.0) 0.0 (if (>f lum 1.0) 1.0 lum)))
	     (rfrac 0.0)
	     (gfrac 0.0)
	     (bfrac 0.0)
	     )
	
	(cond ((<f h 1_3rd)
	       (set! gfrac (*f h 3.0))			;red to green
	       (set! rfrac (-f 1.0 gfrac))
	       )
	      ((<f h 2_3rds)
	       (set! bfrac (*f (-f h 1_3rd) 3.0))	;green to blue
	       (set! gfrac (-f 1.0 bfrac))
	       )
	      (else
	       (set! rfrac (*f (-f h 2_3rds) 3.0))	;blue to red
	       (set! bfrac (-f 1.0 rfrac))
	       )
	      )
	(set! rfrac (/f rfrac 2.0))
	(set! gfrac (/f gfrac 2.0))
	(set! bfrac (/f bfrac 2.0))

	(let* ((chroma (*f (-f 1.0 (abs (-f (*f 2.0 l) 1.0))) s))
	       (m (-f l (/f chroma 2.0)))
	       )
	  (list (+f m rfrac) (+f m gfrac) (+f m bfrac))
	  )
	)
      )
    )
  )

;;;convert hsl values in any number format to integer rgb values.
(define hsl2rgbi
  (let ((me "(hsl2rgbi)")
	(fn (lambda (x) (floor (* x 255))))
	)
    (lambda (hue sat lum)
      (let* ((rgbf (hsl2rgbf hue sat lum))
	     (ri (fn (car rgbf)))
	     (gi (fn (cadr rgbf)))
	     (bi (fn (caddr rgbf)))
	     )
	(list ri gi bi)
	)
      )
    )
  )
;;;  (map (lambda (x) (floor (* x 255))) (hsl2rgbf hue sat lum))

;;; B456: this read `(Pins 'pin-rgbled)`, which was wrong TWICE and silently so.
;;;   1. WRONG CASE -- every pin map declares `pin-RGBLED`, and LambLisp symbols are
;;;      case-sensitive, so the lowercase key matched nothing.
;;;   2. WRONG ACCESSOR -- a dict is not applicable; `(Pins 'k)` RAISES.  The idioms are
;;;      `dict-ref?` (-> the pair, or #f) and `dict-ref` (-> the value).
;;; Because the call sat in a `let` init inside a top-level `define`, it raised at LOAD time, and
;;; `load` reports the error and moves to the next form -- so `ledrgb!` was never defined at all,
;;; on EVERY board shipping this file, and nothing called it so nothing ever noticed.  A definition
;;; that never happens looks exactly like one that did.
;;;
;;; Follows WS2812.scm's shape (`dict-ref?` then `cdr`), which is why the external ring has always
;;; worked while this did not.  ledrgb! is now ALWAYS defined: on a board with no `pin-RGBLED` it is
;;; a no-op returning #f rather than an unbound name, so a caller can run everywhere and a probe
;;; gets a clean answer instead of a load-time raise.
(define have-rgbled-pin (dict-ref? Pins 'pin-RGBLED))
(define pin-RGBLED (if have-rgbled-pin (cdr have-rgbled-pin) #f))
(define ledrgb!
  (if pin-RGBLED
      (lambda (r g b) (neopixelWrite pin-RGBLED r g b))
      (lambda (r g b) #f)))            ;;;!< no onboard RGB LED on this board

(define (mkhuergbvec n)
  (let* ((step (/ 1.0 n))
	 (vec (make-vector n nil))
	 )
    (let loop ((index (- n 1)))
      (if (< index 0) vec
	  (begin
	    (vector-set! vec index (hsl2rgbi (* index step) 1.0 0.5))
	    (loop (- index 1))
	    )
	  )
      )
    )
  )

(define pattern_hue3
  (let* ((me "(pattern_hue3)")
	 (cycletime  10000.0)	;ms time for full color cycle
	 (updateintv 40.0)	;ms between updates
	 ;; B457: inexact->exact is load-bearing.  `floor` PRESERVES EXACTNESS, so (floor 250.0) is
	 ;; 250.0, and mkhuergbvec hands it to make-vector, whose C++ does mustbe_int32() and raises.
	 ;; The raise is inside a let* init in a top-level define, so `load` reported it and moved on:
	 ;; pattern_hue3 was never defined, and (define pattern_led pattern_hue3) below then failed on
	 ;; the unbound name -- two definitions lost silently, including the file's headline export.
	 ;; `truncate` is NOT a substitute here; it returns 250.0 too.
	 (n          (inexact->exact (floor (/ cycletime updateintv))))
	 (rgbvec     (mkhuergbvec n))
	 (rgbix      0)
	 (t_upd      (AutoTimer_ms updateintv))
	 )
    (lambda ()
      (unless (t_upd)
	(if (>= rgbix n) (set! rgbix 0))
	(apply ledrgb! (vector-ref rgbvec rgbix))
	(set! rgbix (+ 1 rgbix))
	)
      )
    )
  )

#|
(define (mkhuergblist hue sat lum step res)
  (cond  ((> hue 1.0) res)
	 ((< hue 0.0) res)
	 (else 
	  (let ((rgbi (hsl2rgbi hue sat lum)))
	    (mkhuergblist (+ hue step) sat lum step (cons rgbi res))
	    )
	  )
	 )
  )

(define pattern_hue2
  (let* ((me "(pattern_hue2)")
	 (cycletime 10000.0)	;ms time for full color cycle
	 (updateintv 40.0)	;ms between updates
	 (rgblist-orig (mkhuergblist 1.0 1.0 0.5 (- (/ updateintv cycletime)) nil))
	 (rgblist nil)
	 (t_upd (AutoTimer_ms updateintv))
	 )
    (lambda ()
      (unless (t_upd)
	(if (null? rgblist) (set! rgblist rgblist-orig))
	(apply ledrgb! (car rgblist))
	(set! rgblist (cdr rgblist))
	)
      )
    )
  )
|#
#|
Run one pass of an idle pattern on the LEDs.
|#
#|
(define pattern_hue1
  (let* ((me "(pattern_hue1)")
	 (cycletime 10000.0)	;ms time for full color cycle
	 (updateintv 40.0)	;ms between updates
	 (huestep (/f updateintv cycletime))	;hue increment
	 (t_upd (AutoTimer_ms updateintv))
	 
	 (hue 0.0)	;current values
	 (sat 1.0)
	 (lum 0.5)
	 )
    (lambda ()
      (unless (t_upd)
	(apply ledrgb! (hsl2rgbi hue sat lum))
	(set! hue (if (<f hue 1.0) (+f hue huestep) 0.0))
	)
      )
    )
  )
|#
(define pattern_led pattern_hue3)
