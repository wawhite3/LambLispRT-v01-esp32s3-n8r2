;;; Copyright 2026 by Frobenius Norm LLC 2026-04-07 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_rational.scm -- R7RS 6.2  Exact rational number type.
;;; Load after rxrs_ai.scm.
;;;
;;; Representation: (cons %rat-tag (cons numerator denominator))
;;;   %rat-tag    -- (list 'rational), unique by eq?
;;;   numerator   -- integer, any sign
;;;   denominator -- positive integer >= 2  (denominator=1 normalizes to integer)
;;;
;;; All public procedures shadow their C++ counterparts.  The saved
;;; primitives use the prefix %rat: to avoid collisions.

;;; -----------------------------------------------------------------------
;;; Internal representation
;;; -----------------------------------------------------------------------

(define %rat-tag (list 'rational))   ;;;!< unique tag; nothing else is eq? to it

(define (%rat-make n d)
  ;;; Canonical constructor.  Always reduces n/d; returns integer when d=1.
  (if (= d 0)
    (error "rational: division by zero" n d)
    (let* ((sign (if (< d 0) -1 1))
           (n    (* sign n))
           (d    (* sign d))
           (g    (gcd (if (< n 0) (- n) n) d)))
      (let ((n/ (quotient n g))
            (d/ (quotient d g)))
        (if (= d/ 1) n/
          (cons %rat-tag (cons n/ d/)))))))

(define (%rat?  x)  (and (pair? x) (eq? (car x) %rat-tag)))
(define (%rat-n x)  (if (%rat? x) (cadr x) x))   ;;;!< numerator of any exact
(define (%rat-d x)  (if (%rat? x) (cddr x) 1))   ;;;!< denominator of any exact

;;; -----------------------------------------------------------------------
;;; Continued-fraction helpers for inexact->exact
;;; -----------------------------------------------------------------------

#|!
  (%cf-approx x eps max-terms)
  Approximate x in [0,1) as a rational using continued fractions.
  Stops when the remainder is smaller than eps or after max-terms steps.
|#
(define (%cf-approx x eps max-terms)
  (define (go x p0 q0 p1 q1 n)
    (if (or (= n 0) (< (if (< x 0) (- x) x) eps))
      (%rat-make p0 q0)
      (let* ((a  (floor x))
             (ia (%rat:inexact->exact a))    ;;; bypass complex wrapper -- use C++ i->e directly
             (p2 (+ (* ia p1) p0))
             (q2 (+ (* ia q1) q0))
             (r  (- x a)))
        (if (< (if (< r 0) (- r) r) eps)
          (%rat-make p2 q2)
          (go (/ 1.0 r) p1 q1 p2 q2 (- n 1))))))
  (go x 0 1 1 0 max-terms))

(define (%float->exact x)
  ;;; Convert inexact real to exact rational via continued fractions.
  (if (or (infinite? x) (nan? x))
    (error "inexact->exact: no exact representation" x)
    (let* ((neg   (< x 0))
           (x     (if neg (- x) x))
           (ipart (%rat:inexact->exact (floor x)))     ;;; bypass complex wrapper -- use C++ i->e directly
           (fpart (- x (* 1.0 ipart))))               ;;; fractional part, inexact
      (let ((frat  (%cf-approx fpart 1e-10 40)))
        (let ((result (if (= frat 0) ipart (%rat-make (+ (* (%rat-d frat) ipart)
                                                         (%rat-n frat))
                                                       (%rat-d frat)))))
          (if neg (- result) result))))))

;;; -----------------------------------------------------------------------
;;; Save primitive operations (C++ versions)
;;; -----------------------------------------------------------------------

(define %rat:number?    number?)
(define %rat:integer?   integer?)
(define %rat:real?      real?)
(define %rat:exact?     exact?)
(define %rat:inexact?   inexact?)
(define %rat:+          +)
(define %rat:-          -)
(define %rat:*          *)
(define %rat:/          /)
(define %rat:=          =)
(define %rat:<          <)
(define %rat:<=         <=)
(define %rat:>          >)
(define %rat:>=         >=)
(define %rat:abs        abs)
(define %rat:max        max)
(define %rat:min        min)
(define %rat:zero?      zero?)
(define %rat:positive?  positive?)
(define %rat:negative?  negative?)
(define %rat:floor      floor)
(define %rat:ceiling    ceiling)
(define %rat:truncate   truncate)
(define %rat:round      round)
(define %rat:expt       expt)
(define %rat:gcd        gcd)
(define %rat:lcm        lcm)
(define %rat:exact->inexact  exact->inexact)
(define %rat:inexact->exact  inexact->exact)
(define %rat:number->string  number->string)
(define %rat:display         display)

;;; -----------------------------------------------------------------------
;;; Predicates
;;; -----------------------------------------------------------------------

(define (number?   x)  (or (%rat:number? x)  (%rat? x)))
(define (real?     x)  (or (%rat:real? x)    (%rat? x)))
(define (rational? x)  (and (number? x)
                             (not (infinite? x))
                             (not (nan? x))))
(define (integer?  x)  (or (%rat:integer? x)
                            (and (%rat? x) (= (%rat-d x) 1))))  ;;; shouldn't occur post-normalization
(define (exact?    x)  (or (%rat:exact? x)   (%rat? x)))
(define (inexact?  x)  (and (not (%rat? x))  (%rat:inexact? x)))
(define (complex?  x)  (number? x))           ;;; placeholder; rxrs_complex.scm overrides
(define (real-part x)  x)                     ;;; placeholder; rxrs_complex.scm overrides
(define (imag-part x)  (if (number? x) 0 (error "not a number" x)))

;;; -----------------------------------------------------------------------
;;; Exactness conversions
;;; -----------------------------------------------------------------------

(define (exact->inexact x)
  (if (%rat? x)
    (%rat:/ (%rat:exact->inexact (%rat-n x))
            (%rat:exact->inexact (%rat-d x)))
    (%rat:exact->inexact x)))

(define inexact exact->inexact)    ;;; R7RS alias

(define (inexact->exact x)
  (cond
    ((%rat? x)         x)          ;;; already exact rational
    ((%rat:exact? x)   x)          ;;; exact integer
    (else              (%float->exact x))))

(define exact inexact->exact)      ;;; R7RS alias

;;; -----------------------------------------------------------------------
;;; Numerator and denominator
;;; -----------------------------------------------------------------------

(define (numerator x)
  (cond
    ((%rat? x)          (%rat-n x))
    ((%rat:integer? x)  x)
    (else               (numerator (inexact->exact x)))))

(define (denominator x)
  (cond
    ((%rat? x)          (%rat-d x))
    ((%rat:integer? x)  1)
    (else               (denominator (inexact->exact x)))))

;;; -----------------------------------------------------------------------
;;; 2-arg arithmetic helpers -- use saved C++ primitives for components
;;; -----------------------------------------------------------------------

(define (%any-rat? lst)
  (and (pair? lst)
       (or (%rat? (car lst)) (%any-rat? (cdr lst)))))

(define (%rat-inexact2 a b op)
  ;;; Mixed exact/inexact: convert exact to inexact, then use C++ op.
  (op (if (%rat:exact? a) (%rat:/ (%rat:exact->inexact (%rat-n a))
                                   (%rat:exact->inexact (%rat-d a)))
        a)
      (if (%rat:exact? b) (%rat:/ (%rat:exact->inexact (%rat-n b))
                                   (%rat:exact->inexact (%rat-d b)))
        b)))

(define (%rat-add2 a b)
  (if (or (%rat:inexact? a) (%rat:inexact? b))
    (%rat-inexact2 a b %rat:+)
    (%rat-make (%rat:+ (%rat:* (%rat-n a) (%rat-d b))
                       (%rat:* (%rat-n b) (%rat-d a)))
               (%rat:* (%rat-d a) (%rat-d b)))))

(define (%rat-sub2 a b)
  (if (or (%rat:inexact? a) (%rat:inexact? b))
    (%rat-inexact2 a b %rat:-)
    (%rat-make (%rat:- (%rat:* (%rat-n a) (%rat-d b))
                       (%rat:* (%rat-n b) (%rat-d a)))
               (%rat:* (%rat-d a) (%rat-d b)))))

(define (%rat-mul2 a b)
  (if (or (%rat:inexact? a) (%rat:inexact? b))
    (%rat-inexact2 a b %rat:*)
    (%rat-make (%rat:* (%rat-n a) (%rat-n b))
               (%rat:* (%rat-d a) (%rat-d b)))))

(define (%rat-div2 a b)
  (if (or (%rat:inexact? a) (%rat:inexact? b))
    (%rat-inexact2 a b %rat:/)
    (%rat-make (%rat:* (%rat-n a) (%rat-d b))
               (%rat:* (%rat-d a) (%rat-n b)))))

;;; -----------------------------------------------------------------------
;;; Arithmetic operators
;;; -----------------------------------------------------------------------

(define (+ . args)
  (if (%any-rat? args)
    (let loop ((acc 0) (rest args))
      (if (null? rest) acc
        (loop (%rat-add2 acc (car rest)) (cdr rest))))
    (apply %rat:+ args)))

(define (- first . rest)
  (if (or (%rat? first) (%any-rat? rest))
    (if (null? rest)
      (%rat-sub2 0 first)
      (let loop ((acc first) (r rest))
        (if (null? r) acc
          (loop (%rat-sub2 acc (car r)) (cdr r)))))
    (apply %rat:- first rest)))

(define (* . args)
  (if (%any-rat? args)
    (let loop ((acc 1) (rest args))
      (if (null? rest) acc
        (loop (%rat-mul2 acc (car rest)) (cdr rest))))
    (apply %rat:* args)))

(define (/ first . rest)
  (if (or (%rat? first) (%any-rat? rest))
    (if (null? rest)
      (%rat-div2 1 first)
      (let loop ((acc first) (r rest))
        (if (null? r) acc
          (loop (%rat-div2 acc (car r)) (cdr r)))))
    (apply %rat:/ first rest)))

;;; -----------------------------------------------------------------------
;;; Comparisons
;;; -----------------------------------------------------------------------

(define (%rat-cmp2 a b)
  ;;; Returns negative, zero, or positive integer: sign of (a - b).
  (if (or (%rat:inexact? a) (%rat:inexact? b))
    (let ((fa (if (%rat:exact? a) (%rat-inexact2 a 1 %rat:*) a))
          (fb (if (%rat:exact? b) (%rat-inexact2 b 1 %rat:*) b)))
      (cond ((%rat:< fa fb) -1) ((%rat:> fa fb) 1) (else 0)))
    (%rat:- (%rat:* (%rat-n a) (%rat-d b))
            (%rat:* (%rat-n b) (%rat-d a)))))

(define (%rat-chain cmp args)
  ;;; Chain comparison: (cmp a0 a1) and (cmp a1 a2) and ...
  (or (null? args) (null? (cdr args))
      (and (cmp (%rat-cmp2 (car args) (cadr args)) 0)
           (%rat-chain cmp (cdr args)))))

(define (=  . args) (if (%any-rat? args) (%rat-chain %rat:=  args) (apply %rat:=  args)))
(define (<  . args) (if (%any-rat? args) (%rat-chain %rat:<  args) (apply %rat:<  args)))
(define (<= . args) (if (%any-rat? args) (%rat-chain %rat:<= args) (apply %rat:<= args)))
(define (>  . args) (if (%any-rat? args) (%rat-chain %rat:>  args) (apply %rat:>  args)))
(define (>= . args) (if (%any-rat? args) (%rat-chain %rat:>= args) (apply %rat:>= args)))

;;; -----------------------------------------------------------------------
;;; Single-argument and variadic numeric operations
;;; -----------------------------------------------------------------------

(define (abs x)
  (if (%rat? x)
    (%rat-make (if (%rat:< (%rat-n x) 0) (%rat:- (%rat-n x)) (%rat-n x))
               (%rat-d x))
    (%rat:abs x)))

(define (zero?     x) (if (%rat? x) (= (%rat-n x) 0) (%rat:zero? x)))
(define (positive? x) (if (%rat? x) (%rat:> (%rat-n x) 0) (%rat:positive? x)))
(define (negative? x) (if (%rat? x) (%rat:< (%rat-n x) 0) (%rat:negative? x)))

(define (max . args)
  (if (%any-rat? args)
    (let loop ((m (car args)) (rest (cdr args)))
      (if (null? rest) m
        (loop (if (> (car rest) m) (car rest) m) (cdr rest))))
    (apply %rat:max args)))

(define (min . args)
  (if (%any-rat? args)
    (let loop ((m (car args)) (rest (cdr args)))
      (if (null? rest) m
        (loop (if (< (car rest) m) (car rest) m) (cdr rest))))
    (apply %rat:min args)))

;;; -----------------------------------------------------------------------
;;; Floor, ceiling, truncate, round
;;; -----------------------------------------------------------------------

(define (floor x)
  (if (%rat? x)
    (let ((q (quotient  (%rat-n x) (%rat-d x)))
          (r (remainder (%rat-n x) (%rat-d x))))
      (if (%rat:< r 0) (%rat:- q 1) q))    ;;; floor toward -inf
    (%rat:floor x)))

(define (ceiling x)
  (if (%rat? x)
    (let ((q (quotient  (%rat-n x) (%rat-d x)))
          (r (remainder (%rat-n x) (%rat-d x))))
      (if (%rat:> r 0) (%rat:+ q 1) q))    ;;; ceiling toward +inf
    (%rat:ceiling x)))

(define (truncate x)
  (if (%rat? x)
    (quotient (%rat-n x) (%rat-d x))        ;;; truncate toward zero
    (%rat:truncate x)))

(define (round x)
  (if (%rat? x)
    (let* ((n   (%rat-n x))
           (d   (%rat-d x))
           (q   (quotient  n d))
           (r   (remainder n d))
           (2r  (%rat:* 2 (if (%rat:< r 0) (%rat:- r) r))))
      (cond
        ((%rat:< 2r d)  q)                  ;;; |frac| < 1/2: round toward zero
        ((%rat:> 2r d)  (if (%rat:> r 0) (%rat:+ q 1) (%rat:- q 1)))  ;;; round away
        ((even? q)      q)                  ;;; tie: banker's rounding -- even wins
        (else           (if (%rat:> r 0) (%rat:+ q 1) (%rat:- q 1)))))
    (%rat:round x)))

;;; -----------------------------------------------------------------------
;;; Exponentiation
;;; -----------------------------------------------------------------------

(define (expt base exp)
  (cond
    ((and (exact? base) (%rat:integer? exp) (%rat:>= exp 0))
     (let loop ((acc 1) (n exp))
       (if (= n 0) acc (loop (* acc base) (%rat:- n 1)))))
    ((and (exact? base) (%rat:integer? exp) (%rat:< exp 0))
     (/ 1 (expt base (%rat:- exp))))
    (else
     (%rat:expt (if (exact? base) (exact->inexact base) base)
                (if (exact? exp)  (exact->inexact exp)  exp)))))

;;; -----------------------------------------------------------------------
;;; GCD and LCM for rationals
;;; R7RS: gcd(a/p, b/q) = gcd(a,b)/lcm(p,q)
;;;       lcm(a/p, b/q) = lcm(a,b)/gcd(p,q)
;;; -----------------------------------------------------------------------

(define (gcd . args)
  (define (gcd2 a b)
    (let ((an (if (%rat:< (%rat-n a) 0) (%rat:- (%rat-n a)) (%rat-n a)))
          (bn (if (%rat:< (%rat-n b) 0) (%rat:- (%rat-n b)) (%rat-n b))))
      (%rat-make (%rat:gcd an bn) (%rat:lcm (%rat-d a) (%rat-d b)))))
  (if (%any-rat? args)
    (abs (let loop ((g 0) (rest args))
           (if (null? rest) g (loop (gcd2 g (car rest)) (cdr rest)))))
    (apply %rat:gcd args)))

(define (lcm . args)
  (define (lcm2 a b)
    (let ((an (if (%rat:< (%rat-n a) 0) (%rat:- (%rat-n a)) (%rat-n a)))
          (bn (if (%rat:< (%rat-n b) 0) (%rat:- (%rat-n b)) (%rat-n b))))
      (%rat-make (%rat:lcm an bn) (%rat:gcd (%rat-d a) (%rat-d b)))))
  (if (%any-rat? args)
    (abs (let loop ((l 1) (rest args))
           (if (null? rest) l (loop (lcm2 l (car rest)) (cdr rest)))))
    (apply %rat:lcm args)))

;;; -----------------------------------------------------------------------
;;; rationalize  (R7RS 6.2.6)
;;; Find the simplest exact rational r such that |x - r| <= |delta|.
;;; Uses the Stern-Brocot / mediants algorithm on exact rationals.
;;; -----------------------------------------------------------------------

(define (rationalize x delta)
  (define (simplest-between lo hi)
    ;;; lo and hi are exact rationals; lo <= hi.
    (let ((c (ceiling lo)))
      (cond
        ((<= c hi)  c)             ;;; integer in [lo,hi]: ceiling(lo) is smallest
        (else
         ;;; No integer in range; floor(lo) = floor(hi) = a.
         ;;; Recurse on reciprocal range, then take 1/result + a.
         (let ((a (floor lo)))
           (+ a (/ 1 (simplest-between (/ 1 (- hi a))
                                       (/ 1 (- lo a))))))))))
  (let ((d (if (< delta 0) (- delta) delta)))
    (let ((lo (- x d))
          (hi (+ x d)))
      (cond
        ((not (< lo hi))   (inexact->exact x))          ;;; delta=0: exact float value
        ((> lo 0)          (simplest-between (inexact->exact lo) (inexact->exact hi)))
        ((< hi 0)          (- (simplest-between (inexact->exact (- hi))
                                                 (inexact->exact (- lo)))))
        (else              0)))))    ;;; interval straddles zero; 0 is simplest

;;; -----------------------------------------------------------------------
;;; number->string and display
;;; -----------------------------------------------------------------------

(define (number->string x . radix-args)
  (if (%rat? x)
    (string-append (%rat:number->string (%rat-n x))
                   "/"
                   (%rat:number->string (%rat-d x)))
    (apply %rat:number->string x radix-args)))

(define (display x . port-args)
  (if (%rat? x)
    (apply %rat:display (number->string x) port-args)
    (apply %rat:display x port-args)))

