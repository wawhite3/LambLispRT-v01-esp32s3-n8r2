;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
#|
i2c utility functions
These are in addition to the native mop3 Wire functions.
|#

(syslog "Loading I2C utility functions\n")

(define have-I2C-code (dict-ref? (current-environment) 'Wire.begin))
(define have-I2C-pins (dict-ref? Pins 'pins-i2c))
(define have-I2C (and have-I2C-code have-I2C-pins))

(unless have-I2C
  (warn "I2C not available, code: ~a, pins: ~a\n" have-I2C-code have-I2C-pins)
  (define Wire.setPins Lambda0)
  (define Wire.begin Lambda0)
  (define Wire.beginTransmission Lambda0)
  (define Wire.endTransmission Lambda0)
  )

(define I2C-expected-devices (2list->dict '(
					    (i2c-master 0)
					    (PCF8574 #x20)
					    (LCD1602 #x27)
					    (PCA9685 #x5f)
					    (PCA9685-secondary #x70)
					    )
					  )
  )

(define I2C-expected-addresses (dict-values I2C-expected-devices))

(define (I2C.begin sda scl addr)
  (let ((me 'I2C.begin)
	)
    (info "~a ~a ==> ~a\n" me `(Wire.setPins ,sda ,scl) (Wire.setPins sda scl))
    (info "~a ~a ==> ~a\n" me `(Wire.begin ,addr) (Wire.begin addr))
    )
  #t
  )

(define (I2C.ping addr)
  (Wire.beginTransmission addr)
  (Wire.endTransmission)
  )
    
(define (I2C.inventory)
  ;;; letrec*, NOT let* -- `fn` CALLS ITSELF, and a let* binding is not in scope for its own
  ;;; initializer.  Interpreted this works BY ACCIDENT (the closure holds the frame by reference and
  ;;; the binding exists by call time); COMPILED it does not -- the bytecode/NCG compiler gives a
  ;;; let* binding a local SLOT, so the self-call is not a local and compiles to a global lookup
  ;;; that fails with `Lamb::dict_ref() Unbound key 'fn'`.  Same defect as Buzzer.chirp's
  ;;; `queue-all`, which failed exactly that way on the 4WD once ncg-compile-environment! had run.
  ;;; letrec* keeps let*'s sequential left-to-right evaluation AND scopes every binding over every
  ;;; initializer, so it is correct in all three tiers.
  (letrec* ((me "(I2C.inventory)")
	 (fn (lambda (addr Nfound)
	       (if (>= addr #x80) Nfound
		   (let ((ping-error (I2C.ping addr)))
		     (if ping-error (begin
				      (when (memq addr I2C-expected-addresses) (warn "~a addr ~a error ~a\n" me addr ping-error))
				      (fn (+ 1 addr) Nfound)
				      )
			 (begin
			   (if (memq addr I2C-expected-addresses) (info "~a found ~a\n" me addr)
			       (warn "~a Unexpected device found ~a\n" me addr)
			       )
			   (fn  (+ 1 addr) (+ 1 Nfound))
			   )
			 )
		     )
		   )
	       )
	     )
	 )
    (fn 0 0)
    )
  )

(when have-I2C
  (let* ((pins (cdr have-I2C-pins))
	 (pin-sda (car pins))
	 (pin-scl (cadr pins))
	 (addr 0)	;0 in LambLisp means we are master
	 )
    (news "~a ==> ~a\n" `(I2C.begin ,pin-sda ,pin-scl ,addr) (I2C.begin pin-sda pin-scl addr))
    (news "I2C devices found: ~a\n" (I2C.inventory))
    )
  )


