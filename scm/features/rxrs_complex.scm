;;; Copyright 2026 by Frobenius Norm LLC 2026-04-07 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_complex.scm -- R7RS 6.2  Complex number type.
;;; Load after rxrs_rational.scm.
;;;
;;; Representation: (cons %cpx-tag (cons real-part imag-part))
;;;   %cpx-tag    -- (list 'complex), unique by eq?
;;;   real-part   -- any exact or inexact real (including rationals)
;;;   imag-part   -- any exact or inexact real; NEVER 0 (normalized away)
;;;
;;; All public procedures shadow their rational-aware counterparts.  The saved
;;; primitives use the prefix %cpx: to avoid collisions.

;;; -----------------------------------------------------------------------
;;; Internal representation
;;; -----------------------------------------------------------------------

(define %cpx-tag (list 'complex))    ;;;!< unique tag; nothing else is eq? to it

(define (%cpx-make r i)
  ;;; Canonical constructor.  Returns plain real when imaginary part is 0.
  (if (and (number? i) (= i 0))
    r
    (cons %cpx-tag (cons r i))))

(define (%cpx?  x)  (and (pair? x) (eq? (car x) %cpx-tag)))
(define (%cpx-r x)  (if (%cpx? x) (cadr x) x))    ;;;!< real part of any number
(define (%cpx-i x)  (if (%cpx? x) (cddr x) 0))    ;;;!< imaginary part of any number

;;; -----------------------------------------------------------------------
;;; Save rational-aware operations (loaded by rxrs_rational.scm)
;;; -----------------------------------------------------------------------

(define %cpx:number?       number?)
(define %cpx:complex?      complex?)
(define %cpx:real?         real?)
(define %cpx:integer?      integer?)
(define %cpx:exact?        exact?)
(define %cpx:inexact?      inexact?)
(define %cpx:+             +)
(define %cpx:-             -)
(define %cpx:*             *)
(define %cpx:/             /)
(define %cpx:=             =)
(define %cpx:<             <)
(define %cpx:abs           abs)
(define %cpx:sqrt          sqrt)
(define %cpx:exact->inexact  exact->inexact)
(define %cpx:inexact->exact  inexact->exact)
(define %cpx:number->string  number->string)
(define %cpx:display         display)

;;; -----------------------------------------------------------------------
;;; Predicates
;;; -----------------------------------------------------------------------

(define (number?  x)  (or (%cpx:number?  x)  (%cpx? x)))
(define (complex? x)  (or (%cpx:complex? x)  (%cpx? x)))
(define (real?    x)  (and (%cpx:real? (%cpx-r x)) (= (%cpx-i x) 0)))
(define (integer? x)  (and (%cpx:integer? (%cpx-r x)) (= (%cpx-i x) 0)))
(define (exact?   x)  (if (%cpx? x)
                        (and (%cpx:exact? (%cpx-r x)) (%cpx:exact? (%cpx-i x)))
                        (%cpx:exact? x)))
(define (inexact? x)  (if (%cpx? x)
                        (or  (%cpx:inexact? (%cpx-r x)) (%cpx:inexact? (%cpx-i x)))
                        (%cpx:inexact? x)))

;;; -----------------------------------------------------------------------
;;; Exactness conversions
;;; -----------------------------------------------------------------------

(define (exact->inexact x)
  (if (%cpx? x)
    (%cpx-make (%cpx:exact->inexact (%cpx-r x))
               (%cpx:exact->inexact (%cpx-i x)))
    (%cpx:exact->inexact x)))

(define inexact exact->inexact)

(define (inexact->exact x)
  (if (%cpx? x)
    (%cpx-make (%cpx:inexact->exact (%cpx-r x))
               (%cpx:inexact->exact (%cpx-i x)))
    (%cpx:inexact->exact x)))

(define exact inexact->exact)

;;; -----------------------------------------------------------------------
;;; Complex-specific accessors
;;; -----------------------------------------------------------------------

(define (real-part  x)  (%cpx-r x))
(define (imag-part  x)  (%cpx-i x))

(define (magnitude x)
  (if (%cpx? x)
    (let ((r (%cpx-r x))
          (i (%cpx-i x)))
      (%cpx:sqrt (%cpx:+ (%cpx:* r r) (%cpx:* i i))))
    (%cpx:abs x)))

(define (angle x)
  (if (%cpx? x)
    (atan (%cpx-i x) (%cpx-r x))
    (if (%cpx:< x 0)
      (* 4 (atan 1.0))   ;;; pi for negative real
      0)))

(define (make-rectangular r i)
  (%cpx-make r i))

(define (make-polar magnitude angle)
  (%cpx-make (%cpx:* magnitude (cos angle))
             (%cpx:* magnitude (sin angle))))

;;; -----------------------------------------------------------------------
;;; 2-arg arithmetic helpers
;;; -----------------------------------------------------------------------

(define (%any-cpx? lst)
  (and (pair? lst)
       (or (%cpx? (car lst)) (%any-cpx? (cdr lst)))))

(define (%cpx-add2 a b)
  (%cpx-make (%cpx:+ (%cpx-r a) (%cpx-r b))
             (%cpx:+ (%cpx-i a) (%cpx-i b))))

(define (%cpx-sub2 a b)
  (%cpx-make (%cpx:- (%cpx-r a) (%cpx-r b))
             (%cpx:- (%cpx-i a) (%cpx-i b))))

(define (%cpx-mul2 a b)
  (let ((ar (%cpx-r a))  (ai (%cpx-i a))
        (br (%cpx-r b))  (bi (%cpx-i b)))
    (%cpx-make (%cpx:- (%cpx:* ar br) (%cpx:* ai bi))
               (%cpx:+ (%cpx:* ar bi) (%cpx:* ai br)))))

(define (%cpx-div2 a b)
  (let* ((ar (%cpx-r a))  (ai (%cpx-i a))
         (br (%cpx-r b))  (bi (%cpx-i b))
         (d  (%cpx:+ (%cpx:* br br) (%cpx:* bi bi))))
    (if (= d 0)
      (error "complex division by zero" a b)
      (%cpx-make (%cpx:/ (%cpx:+ (%cpx:* ar br) (%cpx:* ai bi)) d)
                 (%cpx:/ (%cpx:- (%cpx:* ai br) (%cpx:* ar bi)) d)))))

;;; -----------------------------------------------------------------------
;;; Arithmetic operators
;;; -----------------------------------------------------------------------

(define (+ . args)
  (if (%any-cpx? args)
    (let loop ((acc 0) (rest args))
      (if (null? rest) acc
        (loop (%cpx-add2 acc (car rest)) (cdr rest))))
    (apply %cpx:+ args)))

(define (- first . rest)
  (if (or (%cpx? first) (%any-cpx? rest))
    (if (null? rest)
      (%cpx-sub2 0 first)
      (let loop ((acc first) (r rest))
        (if (null? r) acc
          (loop (%cpx-sub2 acc (car r)) (cdr r)))))
    (apply %cpx:- first rest)))

(define (* . args)
  (if (%any-cpx? args)
    (let loop ((acc 1) (rest args))
      (if (null? rest) acc
        (loop (%cpx-mul2 acc (car rest)) (cdr rest))))
    (apply %cpx:* args)))

(define (/ first . rest)
  (if (or (%cpx? first) (%any-cpx? rest))
    (if (null? rest)
      (%cpx-div2 1 first)
      (let loop ((acc first) (r rest))
        (if (null? r) acc
          (loop (%cpx-div2 acc (car r)) (cdr r)))))
    (apply %cpx:/ first rest)))

;;; -----------------------------------------------------------------------
;;; Equality (no ordering for complex numbers)
;;; -----------------------------------------------------------------------

(define (= . args)
  (if (%any-cpx? args)
    (let loop ((prev (car args)) (rest (cdr args)))
      (or (null? rest)
          (and (%cpx:= (%cpx-r prev) (%cpx-r (car rest)))
               (%cpx:= (%cpx-i prev) (%cpx-i (car rest)))
               (loop (car rest) (cdr rest)))))
    (apply %cpx:= args)))

;;; -----------------------------------------------------------------------
;;; abs (= magnitude for complex), sqrt extension for negative reals
;;; -----------------------------------------------------------------------

(define (abs x)
  (if (%cpx? x)
    (magnitude x)
    (%cpx:abs x)))

(define (sqrt x)
  (cond
    ((%cpx? x)
     ;;; General complex sqrt: sqrt(r*e^(i*theta)) = sqrt(r)*e^(i*theta/2)
     (let ((r (magnitude x))
           (theta (angle x)))
       (make-polar (%cpx:sqrt r) (%cpx:/ theta 2.0))))
    ((%cpx:< x 0)
     ;;; Negative real: sqrt(-x) * i
     (%cpx-make 0 (%cpx:sqrt (%cpx:- x))))
    (else
     (%cpx:sqrt x))))

;;; -----------------------------------------------------------------------
;;; number->string and display
;;; -----------------------------------------------------------------------

(define (number->string x . radix-args)
  (if (%cpx? x)
    (let ((r (%cpx-r x))
          (i (%cpx-i x)))
      (let ((rs (if (= r 0) ""    (%cpx:number->string r)))
            (is (%cpx:number->string (if (%cpx:< i 0) (%cpx:- i) i))))
        (cond
          ((= r 0)          (string-append is "i"))
          ((%cpx:< i 0)     (string-append rs "-" is "i"))
          (else             (string-append rs "+" is "i")))))
    (apply %cpx:number->string x radix-args)))

(define (display x . port-args)
  (if (%cpx? x)
    (apply %cpx:display (number->string x) port-args)
    (apply %cpx:display x port-args)))

