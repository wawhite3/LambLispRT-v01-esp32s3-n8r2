;;; Copyright 2026 by Frobenius Norm LLC 2026-09-20
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; base64.scm -- RFC 4648 base64, bytevector <-> string.  [P69] Phase 3.
;;;
;;; WHY LLIP NEEDS THIS AT ALL.  The LLIP wire is S-expressions as ASCII text, one per line,
;;; terminated by newline.  An AES-GCM ciphertext is arbitrary bytes: it contains newlines, it
;;; contains NUL, and a LambLisp string cannot hold a NUL at all -- writing one does not set a
;;; byte, it SHORTENS THE STRING (see the B317 note at Cell::any_str_get_chars).  So the
;;; ciphertext cannot travel as a string on this transport without an encoding, and base64 is the
;;; one the protocol specifies.
;;;
;;; NOT A GENERAL CODEC, AND DELIBERATELY SO: no line wrapping, no URL-safe alphabet, no
;;; whitespace tolerance on decode.  Every byte this handles is produced by the encoder three
;;; lines away in the same protocol.  A decoder that silently skips characters it does not
;;; understand is the wrong shape for a security boundary -- it turns a corrupted or tampered
;;; frame into a shorter valid one instead of an error, which is precisely the case AES-GCM's tag
;;; exists to catch.  So: reject anything that is not alphabet, padding, or the exact length.

(syslog "base64 loading\n")

(define b64-alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

;;!Reverse table as a 128-entry vector: -1 = not a base64 character.  Built once at load, because
;;!the alternative is a 64-step `string-index` per decoded character and this runs per message.
(define b64-rev
  (let ((v (make-vector 128 -1)))
    (let loop ((i 0))
      (if (< i 64)
          (begin (vector-set! v (char->integer (string-ref b64-alphabet i)) i)
                 (loop (+ i 1)))))
    v))

;;!(base64-encode bv) -> string.  Standard alphabet, always padded to a multiple of 4.
(define (base64-encode bv)
  (let* ((n   (bytevector-length bv))
         (out (open-output-string)))
    (let loop ((i 0))
      (if (< i n)
          (let* ((b0 (bytevector-u8-ref bv i))
                 (b1 (if (< (+ i 1) n) (bytevector-u8-ref bv (+ i 1)) 0))
                 (b2 (if (< (+ i 2) n) (bytevector-u8-ref bv (+ i 2)) 0))
                 (trip (+ (* b0 65536) (* b1 256) b2))
                 (rem  (- n i)))
            (write-char (string-ref b64-alphabet (quotient trip 262144)) out)
            (write-char (string-ref b64-alphabet (modulo (quotient trip 4096) 64)) out)
            (write-char (if (> rem 1) (string-ref b64-alphabet (modulo (quotient trip 64) 64)) #\=) out)
            (write-char (if (> rem 2) (string-ref b64-alphabet (modulo trip 64)) #\=) out)
            (loop (+ i 3)))))
    (get-output-string out)))

;;!(base64-decode s) -> bytevector.  RAISES on any character outside the alphabet, on a length
;;!that is not a multiple of 4, and on padding in the wrong place.  See the header: silence here
;;!would convert a tampered frame into a shorter well-formed one.
(define (base64-decode s)
  (let ((len (string-length s)))
    (if (not (= 0 (modulo len 4)))
        (error "base64-decode: length is not a multiple of 4" len))
    (if (= len 0)
        (bytevector)
        (let* ((pad (cond ((char=? (string-ref s (- len 1)) #\=)
                           (if (char=? (string-ref s (- len 2)) #\=) 2 1))
                          (else 0)))
               (out (make-bytevector (- (* 3 (quotient len 4)) pad) 0)))
          (let loop ((i 0) (o 0))
            (if (< i len)
                (let ((q (lambda (k)
                           (let* ((c (string-ref s (+ i k)))
                                  (v (char->integer c)))
                             (cond ((char=? c #\=)
                                    ;; padding is legal only in the last group, last two slots
                                    (if (or (< (+ i 4) len) (< k 2))
                                        (error "base64-decode: misplaced padding at" (+ i k)))
                                    0)
                                   ((or (< v 0) (> v 127) (= -1 (vector-ref b64-rev v)))
                                    (error "base64-decode: illegal character at" (+ i k)))
                                   (else (vector-ref b64-rev v)))))))
                  (let ((trip (+ (* (q 0) 262144) (* (q 1) 4096) (* (q 2) 64) (q 3))))
                    (if (< o (bytevector-length out))
                        (bytevector-u8-set! out o (quotient trip 65536)))
                    (if (< (+ o 1) (bytevector-length out))
                        (bytevector-u8-set! out (+ o 1) (modulo (quotient trip 256) 256)))
                    (if (< (+ o 2) (bytevector-length out))
                        (bytevector-u8-set! out (+ o 2) (modulo trip 256)))
                    (loop (+ i 4) (+ o 3))))))
          out))))

(syslog "base64 loaded\n")
