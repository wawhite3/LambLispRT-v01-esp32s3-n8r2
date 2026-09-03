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

(define ledrgb!
  (let ((ledpin (Pins 'pin-rgbled)))
    (lambda (r g b)
      (neopixelWrite ledpin r g b)
      )
    )
  )

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
	 (n          (floor (/ cycletime updateintv)))
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
