;;; Copyright 2026 by Frobenius Norm LLC 2026-04-10 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; chez-compat.scm -- R7RS compatibility shim for Chez Scheme 9.5
;;;
;;; Load BEFORE bench-tests.scm:
;;;   (load "chez-compat.scm")
;;;   (load "bench-tests.scm")
;;;
;;; Sets *bench-lamblisp-only* = #f so nlambda/macro?/dict sections are skipped.
;;; Defines R7RS functions missing from Chez 9.5.8.

;;; Disable LambLisp-only sections in bench-tests.scm
(define *bench-lamblisp-only* #f)

;;; ---------------------------------------------------------------------------
;;; R7RS number functions missing from Chez 9.5
;;; ---------------------------------------------------------------------------

(define (floor->exact x)    (exact (floor x)))
(define (ceiling->exact x)  (exact (ceiling x)))
(define (truncate->exact x) (exact (truncate x)))
(define (round->exact x)    (exact (round x)))

;;; number->string: R7RS requires lowercase hex digits; Chez 9.5 returns uppercase.
(define chez-number->string number->string)
(define (number->string n . args)
  (let ((s (apply chez-number->string n args)))
    (if (and (not (null? args)) (= (car args) 16))
        (string-downcase s)
        s)))

;;; ---------------------------------------------------------------------------
;;; R7RS string functions missing from Chez 9.5
;;; ---------------------------------------------------------------------------

;;; string-contains: return index of first occurrence of needle in haystack, or #f
(define (string-contains haystack needle)
  (let* ((hlen (string-length haystack))
         (nlen (string-length needle)))
    (if (= nlen 0)
        0
        (let loop ((i 0))
          (cond
           ((> (+ i nlen) hlen) #f)
           ((string=? (substring haystack i (+ i nlen)) needle) i)
           (else (loop (+ i 1))))))))

;;; ---------------------------------------------------------------------------
;;; R7RS error and error-object functions
;;; ---------------------------------------------------------------------------
;;; Chez's (error who msg irritant...) is R6RS, not R7RS.
;;; We redefine `error` to raise a plain R7RS-style tagged list so that
;;; error-object?/message/irritants work portably.

(define (error msg . irritants)
  (raise (list 'error-object msg irritants)))

(define (error-object? obj)
  (and (pair? obj) (eq? (car obj) 'error-object)))

(define (error-object-message obj)   (cadr obj))
(define (error-object-irritants obj) (caddr obj))

;;; ---------------------------------------------------------------------------
;;; R7RS define-record-type (Chez 9.5 uses R6RS syntax -- translate here)
;;; Handles immutable records with 1-3 fields.
;;; Chez's make-record-type takes a string name + list of field-name symbols.
;;; ---------------------------------------------------------------------------

(define-syntax define-record-type
  (syntax-rules ()
    ;; 1-field
    ((_ tname (ctor fa) pred (fa2 aa))
     (begin
       (define rtd  (make-record-type (symbol->string (quote tname)) (list (quote fa2))))
       (define pred (record-predicate rtd))
       (define ctor (record-constructor rtd))
       (define aa   (record-accessor rtd 0))))
    ;; 2-field
    ((_ tname (ctor fa fb) pred (fa2 aa) (fb2 ab))
     (begin
       (define rtd  (make-record-type (symbol->string (quote tname)) (list (quote fa2) (quote fb2))))
       (define pred (record-predicate rtd))
       (define ctor (record-constructor rtd))
       (define aa   (record-accessor rtd 0))
       (define ab   (record-accessor rtd 1))))
    ;; 3-field
    ((_ tname (ctor fa fb fc) pred (fa2 aa) (fb2 ab) (fc2 ac))
     (begin
       (define rtd  (make-record-type (symbol->string (quote tname)) (list (quote fa2) (quote fb2) (quote fc2))))
       (define pred (record-predicate rtd))
       (define ctor (record-constructor rtd))
       (define aa   (record-accessor rtd 0))
       (define ab   (record-accessor rtd 1))
       (define ac   (record-accessor rtd 2))))))

;;; ---------------------------------------------------------------------------
;;; R7RS bytevector-copy with optional start/end (Chez 9.5 takes only 1 arg)
;;; ---------------------------------------------------------------------------

(define (bytevector-copy bv . args)
  (let* ((start  (if (null? args) 0 (car args)))
         (end    (if (or (null? args) (null? (cdr args))) (bytevector-length bv) (cadr args)))
         (len    (- end start))
         (result (make-bytevector len 0)))
    (do ((i 0 (+ i 1)))
      ((= i len) result)
      (bytevector-u8-set! result i (bytevector-u8-ref bv (+ start i))))))

;;; ---------------------------------------------------------------------------
;;; Timing helper
;;; ---------------------------------------------------------------------------

;;; Chez has (time expr) as a special form, not a procedure.
;;; For bench timing, use current-time or cpu-time.

;;; ---------------------------------------------------------------------------
;;; R7RS port / I/O functions missing from Chez 9.5 (R6RS port names differ)
;;; ---------------------------------------------------------------------------

;;; write-string: write string (or substring) to port
(define (write-string str . args)
  (let* ((port  (if (null? args) (current-output-port) (car args)))
         (rest  (if (null? args) '() (cdr args)))
         (start (if (null? rest) 0 (car rest)))
         (end   (if (or (null? rest) (null? (cdr rest))) (string-length str) (cadr rest))))
    (put-string port (substring str start end))))

;;; u8-ready?: Chez has no equivalent; bytevector ports are always ready
(define (u8-ready? port) #t)

;;; open-input-bytevector: R7RS name for Chez's open-bytevector-input-port
(define (open-input-bytevector bv)
  (open-bytevector-input-port bv))

;;; read-u8 / peek-u8 / write-u8: R7RS names (Chez 9.5 uses R6RS names)
(define (read-u8 . args)
  (let ((port (if (null? args) (current-input-port) (car args))))
    (get-u8 port)))

(define (peek-u8 . args)
  (let ((port (if (null? args) (current-input-port) (car args))))
    (lookahead-u8 port)))

(define (write-u8 byte . args)
  (let ((port (if (null? args) (current-output-port) (car args))))
    (put-u8 port byte)))

;;; open-output-bytevector / get-output-bytevector:
;;; Chez's open-bytevector-output-port returns (values port extractor-proc).
;;; We stash the extractor in an alist so get-output-bytevector can find it.
(define *bvop-registry* '())

(define (open-output-bytevector)
  (let-values (((p get) (open-bytevector-output-port)))
    (set! *bvop-registry* (cons (cons p get) *bvop-registry*))
    p))

(define (get-output-bytevector p)
  (let ((entry (assq p *bvop-registry*)))
    (if entry
        ((cdr entry))
        (error 'get-output-bytevector "not an output-bytevector port" p))))


