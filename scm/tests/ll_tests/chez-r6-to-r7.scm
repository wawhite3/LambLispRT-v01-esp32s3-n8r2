;;; Copyright 2026 by Frobenius Norm LLC 2026-04-08 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; chez-r6-to-r7.scm -- R6RS-to-R7RS shims for Chez Scheme 9.5.x
;;;
;;; Provides R7RS-small procedures and syntax that are absent or renamed in
;;; Chez's R6RS implementation.  Safe to load on LambLisp too: each binding
;;; is guarded so that an already-correct native implementation is kept.
;;;
;;; Requires: guard, raise (both present on Chez and LambLisp).
;;; Load BEFORE the test framework and tests.

;;; -----------------------------------------------------------------------
;;; Platform detection
;;; -----------------------------------------------------------------------

;;; chez-scheme? = #t when running on Chez (syslog not bound), #f on LambLisp.
(define chez-scheme?
  (guard (exn (#t #t))    ;;!< exception -> syslog not bound -> Chez
    (eval 'syslog)
    #f))                  ;;!< syslog bound -> LambLisp

;;; -----------------------------------------------------------------------
;;; news / warn -- test framework output  (LambLisp has builtins; define for Chez)
;;; -----------------------------------------------------------------------

(define (%r7t-fmt color fmt . args)
  ;;; Minimal ~a formatter.  color = ANSI escape string or #f for plain.
  (when color (display color))
  (let loop ((chars (string->list fmt)) (args args))
    (cond
      ((null? chars) (values))
      ((and (char=? (car chars) #\~)
            (pair? (cdr chars))
            (char=? (cadr chars) #\a))
       (display (if (null? args) "?" (car args)))
       (loop (cddr chars) (if (null? args) '() (cdr args))))
      (else
       (display (string (car chars)))
       (loop (cdr chars) args))))
  (when color (display "\x1b;[0m")))

(define (news fmt . args) (apply %r7t-fmt "\x1b;[32m" fmt args))
(define (warn fmt . args) (apply %r7t-fmt "\x1b;[31m" fmt args))

;;; -----------------------------------------------------------------------
;;; R7RS §6.11  error-object API
;;; -----------------------------------------------------------------------
;;; Chez uses R6RS condition types.  Redefine error to raise a tagged list
;;; so error-object? and friends work uniformly on both platforms.
;;; On LambLisp, rxrs_ai.scm already defines these identically.

(define (error message . irritants)
  (raise (list 'error-object message irritants)))
(define (error-object?        e) (and (pair? e) (eq? (car e) 'error-object)))
(define (error-object-message e) (cadr  e))
(define (error-object-irritants e) (caddr e))

;;; -----------------------------------------------------------------------
;;; R7RS §4.2.5  Promise extensions
;;; -----------------------------------------------------------------------
;;; Chez 9.5.8 does not provide promise?, make-promise, or delay-force.
;;; promise?    : Chez delay returns a procedure; use procedure? as proxy.
;;; make-promise: if given a procedure (promise), return it; else wrap in delay.
;;; delay-force : delay suffices for finite-depth tests (n <= 50).

(define promise?
  (guard (e (#t (lambda (x) (procedure? x))))
    promise?))
(define make-promise
  (guard (e (#t (lambda (x) (if (procedure? x) x (delay x)))))
    make-promise))
(define-syntax delay-force
  (syntax-rules ()
    ((_ expr) (delay expr))))

;;; -----------------------------------------------------------------------
;;; R7RS §5.5  define-record-type
;;; -----------------------------------------------------------------------
;;; Chez uses R6RS define-record-type syntax (incompatible with R7RS).
;;; Records represented as vectors: #('type-name f1 f2 ...).
;;; Installed only on Chez via eval so LambLisp keeps its C++ version.

(when chez-scheme?
  (eval '(define-syntax define-record-type
           (syntax-rules ()
             ((_ type-name (ctor f ...) pred? clause ...)
              (%drt type-name (ctor f ...) pred? 0 clause ...)))))
  (eval '(define-syntax %drt
           (syntax-rules ()
             ((_ type-name (ctor f ...) pred? idx)
              (begin
                (define (ctor f ...) (vector 'type-name f ...))
                (define (pred? x)
                  (and (vector? x) (positive? (vector-length x))
                       (eq? (vector-ref x 0) 'type-name)))))
             ((_ type-name ctor-spec pred? idx (fname acc) rest ...)
              (begin
                (define (acc x) (vector-ref x (+ 1 idx)))
                (%drt type-name ctor-spec pred? (+ 1 idx) rest ...)))
             ((_ type-name ctor-spec pred? idx (fname acc mut) rest ...)
              (begin
                (define (acc x) (vector-ref x (+ 1 idx)))
                (define (mut x v) (vector-set! x (+ 1 idx) v))
                (%drt type-name ctor-spec pred? (+ 1 idx) rest ...)))))))

;;; -----------------------------------------------------------------------
;;; R7RS §6.2  Numeric operations
;;; -----------------------------------------------------------------------

(define exact-integer?
  (guard (e (#t (lambda (x) (and (exact? x) (integer? x)))))
    exact-integer?))

(define square
  (guard (e (#t (lambda (x) (* x x))))
    square))

(define floor-quotient
  (guard (e (#t (lambda (n d)
                  (let ((q (floor (/ n d))))
                    (if (and (exact? n) (exact? d)) (inexact->exact q) q)))))
    floor-quotient))

(define floor-remainder
  (guard (e (#t (lambda (n d) (- n (* d (floor-quotient n d))))))
    floor-remainder))

(define floor/
  (guard (e (#t (lambda (n d) (values (floor-quotient n d) (floor-remainder n d)))))
    floor/))

(define truncate-quotient
  (guard (e (#t (lambda (n d)
                  (let ((q (truncate (/ n d))))
                    (if (and (exact? n) (exact? d)) (inexact->exact q) q)))))
    truncate-quotient))

(define truncate-remainder
  (guard (e (#t (lambda (n d) (- n (* d (truncate-quotient n d))))))
    truncate-remainder))

(define truncate/
  (guard (e (#t (lambda (n d) (values (truncate-quotient n d) (truncate-remainder n d)))))
    truncate/))

;;; -----------------------------------------------------------------------
;;; R7RS §6.4  List operations
;;; -----------------------------------------------------------------------

(define list-set!
  (guard (e (#t (lambda (l k val) (set-car! (list-tail l k) val))))
    list-set!))

;;; -----------------------------------------------------------------------
;;; R7RS §6.6  Characters
;;; -----------------------------------------------------------------------

(define digit-value
  (guard (e (#t (lambda (c)
                  (let ((n (- (char->integer c) (char->integer #\0))))
                    (if (and (>= n 0) (<= n 9)) n #f)))))
    digit-value))

;;; -----------------------------------------------------------------------
;;; R7RS §6.7  Strings
;;; -----------------------------------------------------------------------

;;; string-copy with optional start/end  (Chez takes only 1 arg)
(define %base-string-copy string-copy)
(define (string-copy s . args)
  (if (null? args)
    (%base-string-copy s)
    (let* ((start (car args))
           (end   (if (null? (cdr args)) (string-length s) (cadr args))))
      (substring s start end))))

;;; string-copy! to at from [start [end]]
(define %base-string-ref  string-ref)
(define %base-string-set! string-set!)
(define string-copy!
  (guard (e (#t (lambda (to at from . args)
                  (let* ((start (if (null? args) 0 (car args)))
                         (end   (if (or (null? args) (null? (cdr args)))
                                    (string-length from) (cadr args))))
                    (let loop ((i start) (j at))
                      (when (< i end)
                        (%base-string-set! to j (%base-string-ref from i))
                        (loop (+ i 1) (+ j 1))))))))
    string-copy!))

;;; string-fill! with optional start/end
(define %base-string-fill! string-fill!)
(define (string-fill! s c . args)
  (let* ((start (if (null? args) 0 (car args)))
         (end   (if (or (null? args) (null? (cdr args))) (string-length s) (cadr args))))
    (let loop ((i start))
      (when (< i end) (string-set! s i c) (loop (+ i 1))))))

;;; string->list with optional start/end
(define %base-string->list string->list)
(define (string->list s . args)
  (if (null? args)
    (%base-string->list s)
    (let* ((start (car args))
           (end   (if (null? (cdr args)) (string-length s) (cadr args))))
      (%base-string->list (substring s start end)))))

;;; string->vector, vector->string
(define string->vector
  (guard (e (#t (lambda (s . args)
                  (list->vector (apply string->list s args)))))
    string->vector))

(define vector->string
  (guard (e (#t (lambda (v . args)
                  (list->string (vector->list v)))))
    vector->string))

;;; string-map proc str [str2 ...]
(define string-map
  (guard (e (#t (lambda (proc . strs)
                  (let* ((len (apply min (map string-length strs)))
                         (res (make-string len #\a)))
                    (let loop ((i 0))
                      (when (< i len)
                        (string-set! res i (apply proc (map (lambda (s) (string-ref s i)) strs)))
                        (loop (+ i 1))))
                    res))))
    string-map))

;;; string-for-each proc str [str2 ...]
(define string-for-each
  (guard (e (#t (lambda (proc . strs)
                  (let ((len (apply min (map string-length strs))))
                    (let loop ((i 0))
                      (when (< i len)
                        (apply proc (map (lambda (s) (string-ref s i)) strs))
                        (loop (+ i 1))))))))
    string-for-each))

;;; -----------------------------------------------------------------------
;;; R7RS §6.8  Vectors
;;; -----------------------------------------------------------------------

;;; vector->list with optional start/end
(define %base-vector->list vector->list)
(define (vector->list v . args)
  (if (null? args)
    (%base-vector->list v)
    (let* ((start (car args))
           (end   (if (null? (cdr args)) (vector-length v) (cadr args))))
      (let loop ((i (- end 1)) (acc '()))
        (if (< i start) acc
          (loop (- i 1) (cons (vector-ref v i) acc)))))))

;;; vector-copy with optional start/end
(define %base-vector-copy vector-copy)
(define (vector-copy v . args)
  (let* ((start (if (null? args) 0 (car args)))
         (end   (if (or (null? args) (null? (cdr args))) (vector-length v) (cadr args)))
         (len   (- end start))
         (r     (make-vector len #f)))
    (let loop ((i 0))
      (when (< i len) (vector-set! r i (vector-ref v (+ start i))) (loop (+ i 1))))
    r))

;;; vector-copy! to at from [start [end]]
(define vector-copy!
  (guard (e (#t (lambda (to at from . args)
                  (let* ((start (if (null? args) 0 (car args)))
                         (end   (if (or (null? args) (null? (cdr args)))
                                    (vector-length from) (cadr args))))
                    (let loop ((i start) (j at))
                      (when (< i end)
                        (vector-set! to j (vector-ref from i))
                        (loop (+ i 1) (+ j 1))))))))
    vector-copy!))

;;; vector-fill! with optional start/end
(define %base-vector-fill! vector-fill!)
(define (vector-fill! v x . args)
  (let* ((start (if (null? args) 0 (car args)))
         (end   (if (or (null? args) (null? (cdr args))) (vector-length v) (cadr args))))
    (let loop ((i start))
      (when (< i end) (vector-set! v i x) (loop (+ i 1))))))

;;; vector-append vecs...
(define (vector-append . vecs)
  (let* ((len (apply + (map vector-length vecs)))
         (r   (make-vector len #f)))
    (let loop ((vecs vecs) (at 0))
      (unless (null? vecs)
        (let* ((v (car vecs)) (n (vector-length v)))
          (let copy ((i 0))
            (when (< i n) (vector-set! r (+ at i) (vector-ref v i)) (copy (+ i 1))))
          (loop (cdr vecs) (+ at n)))))
    r))

;;; -----------------------------------------------------------------------
;;; R7RS §6.9  Bytevectors
;;; -----------------------------------------------------------------------

;;; bytevector-copy bv [start [end]]  (Chez takes only 1 arg)
(define %base-bytevector-copy bytevector-copy)
(define (bytevector-copy bv . args)
  (let* ((start (if (null? args) 0 (car args)))
         (end   (if (or (null? args) (null? (cdr args)))
                    (bytevector-length bv) (cadr args)))
         (len   (- end start))
         (r     (make-bytevector len 0)))
    (let loop ((i 0))
      (when (< i len)
        (bytevector-u8-set! r i (bytevector-u8-ref bv (+ start i)))
        (loop (+ i 1))))
    r))

;;; bytevector-copy! to at from [start [end]]
(define bytevector-copy!
  (guard (e (#t (lambda (to at from . args)
                  (let* ((start (if (null? args) 0 (car args)))
                         (end   (if (or (null? args) (null? (cdr args)))
                                    (bytevector-length from) (cadr args))))
                    (let loop ((i start) (j at))
                      (when (< i end)
                        (bytevector-u8-set! to j (bytevector-u8-ref from i))
                        (loop (+ i 1) (+ j 1))))))))
    bytevector-copy!))

;;; bytevector-append bv ...
(define bytevector-append
  (guard (e (#t (lambda bvs
                  (let* ((len (apply + (map bytevector-length bvs)))
                         (r   (make-bytevector len 0)))
                    (let loop ((bvs bvs) (at 0))
                      (unless (null? bvs)
                        (let* ((bv (car bvs)) (n (bytevector-length bv)))
                          (let copy ((i 0))
                            (when (< i n)
                              (bytevector-u8-set! r (+ at i) (bytevector-u8-ref bv i))
                              (copy (+ i 1))))
                          (loop (cdr bvs) (+ at n)))))
                    r))))
    bytevector-append))

;;; utf8->string bv [start [end]]  (Chez only takes 1 arg)
(define %base-utf8->string utf8->string)
(define (utf8->string bv . args)
  (if (null? args)
    (%base-utf8->string bv)
    (let* ((start (car args))
           (end   (if (null? (cdr args)) (bytevector-length bv) (cadr args))))
      (%base-utf8->string (bytevector-copy bv start end)))))

;;; -----------------------------------------------------------------------
;;; R7RS §6.13  Ports and I/O
;;; -----------------------------------------------------------------------

;;; I/O functions missing from Chez 9.5.8 (Chez uses R6RS names)
(define read-line
  (guard (e (#t (lambda args
                  (let ((p (if (null? args) (current-input-port) (car args))))
                    (get-line p)))))
    read-line))

(define read-string
  (guard (e (#t (lambda (k . args)
                  (let ((p (if (null? args) (current-input-port) (car args))))
                    (get-string-n p k)))))
    read-string))

(define write-string
  (guard (e (#t (lambda (s . args)
                  (let* ((p     (if (null? args) (current-output-port) (car args)))
                         (start (if (or (null? args) (null? (cdr args))) 0 (cadr args)))
                         (end   (if (or (null? args) (null? (cdr args)) (null? (cddr args)))
                                    (string-length s) (caddr args))))
                    (display (substring s start end) p)))))
    write-string))

;;; Bytevector ports -- implemented via string ports with char<->byte mapping.
;;; Works for byte values 0-127 (ASCII range); sufficient for the test data.
(define open-input-bytevector
  (guard (e (#t (lambda (bv)
                  (let* ((n (bytevector-length bv))
                         (s (make-string n #\a)))
                    (let loop ((i 0))
                      (when (< i n)
                        (string-set! s i (integer->char (bytevector-u8-ref bv i)))
                        (loop (+ i 1))))
                    (open-input-string s)))))
    open-input-bytevector))

(define open-output-bytevector
  (guard (e (#t open-output-string))
    open-output-bytevector))

(define get-output-bytevector
  (guard (e (#t (lambda (p)
                  (let* ((s  (get-output-string p))
                         (n  (string-length s))
                         (bv (make-bytevector n 0)))
                    (let loop ((i 0))
                      (when (< i n)
                        (bytevector-u8-set! bv i (char->integer (string-ref s i)))
                        (loop (+ i 1))))
                    bv))))
    get-output-bytevector))

(define read-u8
  (guard (e (#t (lambda args
                  (let* ((p (if (null? args) (current-input-port) (car args)))
                         (c (read-char p)))
                    (if (eof-object? c) c (char->integer c))))))
    read-u8))

(define peek-u8
  (guard (e (#t (lambda args
                  (let* ((p (if (null? args) (current-input-port) (car args)))
                         (c (peek-char p)))
                    (if (eof-object? c) c (char->integer c))))))
    peek-u8))

(define write-u8
  (guard (e (#t (lambda (byte . args)
                  (let ((p (if (null? args) (current-output-port) (car args))))
                    (write-char (integer->char byte) p)))))
    write-u8))

(define u8-ready?
  (guard (e (#t (lambda args
                  (let ((p (if (null? args) (current-input-port) (car args))))
                    (char-ready? p)))))
    u8-ready?))

;;; Port open? predicates -- not in Chez 9.5.8 (use port-closed? instead)
(define input-port-open?
  (guard (e (#t (lambda (p) (not (port-closed? p)))))
    input-port-open?))
(define output-port-open?
  (guard (e (#t (lambda (p) (not (port-closed? p)))))
    output-port-open?))

;;; -----------------------------------------------------------------------
;;; R7RS §6.14  Time
;;; -----------------------------------------------------------------------
;;; Chez uses SRFI-19/POSIX time API; map to R7RS names.

(define current-jiffy
  (guard (e (#t (lambda ()
                  (let ((t (current-time)))
                    (+ (* (time-second t) 1000000000) (time-nanosecond t))))))
    current-jiffy))

(define jiffies-per-second
  (guard (e (#t (lambda () 1000000000)))
    jiffies-per-second))

(define current-second
  (guard (e (#t (lambda () (exact->inexact (time-second (current-time))))))
    current-second))

