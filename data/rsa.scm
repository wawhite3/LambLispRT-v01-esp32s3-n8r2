;;; rsa.scm -- RSA, Diffie-Hellman, HMAC-SHA256 in Scheme over modular-exponent.
;;; Copyright 2026 by Frobenius Norm LLC 2026-05-10
;;; Free for non-commercial use. Commercial use requires a license.

;;; bytevector helpers (subset needed here)

(define (bytevector-xor a b)
  (let* ((n (bytevector-length a))
         (out (make-bytevector n 0)))
    (let loop ((i 0))
      (if (= i n)
        out
        (begin
          (bytevector-u8-set! out i
            (bitwise-xor (bytevector-u8-ref a i)
                         (bytevector-u8-ref b i)))
          (loop (+ i 1)))))))

;;; bignum <-> bytevector (big-endian)

(define (bytevector->bignum bv)
  (let ((n (bytevector-length bv)))
    (let loop ((i 0) (acc (to-bignum 0)))
      (if (= i n)
        acc
        (loop (+ i 1)
              (bignum-add
                (bignum-shift acc 8)
                (to-bignum (bytevector-u8-ref bv i))))))))

(define (bignum->bytevector bn)
  (let* ((s (bignum-to-string bn 16))
         (hex (if (odd? (string-length s))
                (string-append "0" s)
                s))
         (nbytes (quotient (string-length hex) 2))
         (out (make-bytevector nbytes 0)))
    (let loop ((i 0))
      (if (= i nbytes)
        out
        (begin
          (bytevector-u8-set! out i
            (string->number (substring hex (* i 2) (+ (* i 2) 2)) 16))
          (loop (+ i 1)))))))

(define (bignum-bit-length n)
  (let ((s (bignum-to-string n 2)))
    (string-length s)))

;;; HMAC-SHA256

(define (hmac-sha256 key data)
  (let* ((block-size 64)
         (k (if (> (bytevector-length key) block-size)
              (sha256 key)
              key))
         (pad-len (- block-size (bytevector-length k)))
         (k-padded (bytevector-append k (make-bytevector pad-len 0)))
         (o-key (bytevector-xor k-padded (make-bytevector block-size #x5c)))
         (i-key (bytevector-xor k-padded (make-bytevector block-size #x36))))
    (sha256 (bytevector-append o-key (sha256 (bytevector-append i-key data))))))

(define (hkdf-sha256 ikm info len)
  (let* ((prk (hmac-sha256 (make-bytevector 32 0) ikm))
         (t1  (hmac-sha256 prk (bytevector-append info (bytevector 1)))))
    (bytevector-copy t1 0 len)))

;;; RSA

;;!<[B535] NOTE THE ASYMMETRY BEFORE YOU USE THESE AS A PAIR: `rsa-encrypt` takes a BYTEVECTOR
;;!<and returns a BIGNUM; `rsa-decrypt` takes a BIGNUM and returns a BIGNUM.  So they do not
;;!<compose -- `(rsa-encrypt (rsa-decrypt x k) k)` is a type error that raises nothing and
;;!<returns a wrong number.  That is exactly how `rsa-verify` was broken for the whole life of
;;!<the file.  `rsa-sign`/`rsa-verify` below stay in the integer domain for this reason.
(define (rsa-encrypt msg pub-key)
  (modular-exponent
    (bytevector->bignum msg)
    (cdr (assq 'e pub-key))
    (cdr (assq 'n pub-key))))

(define (rsa-decrypt cipher priv-key)
  (modular-exponent
    cipher
    (cdr (assq 'd priv-key))
    (cdr (assq 'n priv-key))))

(define (rsa-sign msg priv-key)
  (rsa-decrypt (bytevector->bignum (sha256 msg)) priv-key))

;;!<[B535] VERIFY COMPARES INTEGERS, and must not be "simplified" back into bytevectors.
;;!<Two separate hazards live in the byte-domain version this replaced, and it had both:
;;!<  1. TYPE.  `sig` is what `rsa-sign` returned, i.e. the output of `modular-exponent` -- a
;;!<     BIGNUM.  `rsa-encrypt` opens with `(bytevector->bignum msg)`, so it wants a BYTEVECTOR.
;;!<     Passing a bignum does not raise; it quietly yields a different number.
;;!<  2. WIDTH.  Even with the types right, `bignum->bytevector` emits the modulus width (256 B
;;!<     for RSA-2048) while `sha256` is 32 B, so `equal?` fails on length alone.
;;!<The old line therefore returned #f for EVERY signature, valid or not -- which made LLIP
;;!<mutual authentication reject every legitimate peer.  It failed closed, so nothing was
;;!<exposed; the feature simply could not work, and no test called this procedure.
(define (rsa-verify msg sig pub-key)
  (= (modular-exponent sig (cdr (assq 'e pub-key)) (cdr (assq 'n pub-key)))
     (bytevector->bignum (sha256 msg))))

;;; Diffie-Hellman

(define (diffie-hellman-keygen prime generator)
  (let ((priv (ll-random-bignum (bignum-bit-length prime))))
    (cons (modular-exponent (to-bignum generator) priv prime) priv)))

(define (diffie-hellman-shared peer-pub priv prime)
  (modular-exponent peer-pub priv prime))

