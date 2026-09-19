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

(define (rsa-verify msg sig pub-key)
  (equal? (bignum->bytevector (rsa-encrypt sig pub-key))
          (sha256 msg)))

;;; Diffie-Hellman

(define (diffie-hellman-keygen prime generator)
  (let ((priv (ll-random-bignum (bignum-bit-length prime))))
    (cons (modular-exponent (to-bignum generator) priv prime) priv)))

(define (diffie-hellman-shared peer-pub priv prime)
  (modular-exponent peer-pub priv prime))

