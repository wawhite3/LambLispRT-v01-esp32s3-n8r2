;;; bignum-hw-tests.scm -- correctness of the ESP32 RSA/MPI accelerator path in Lamb::bignum_mul.
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-24 13:05:00
;;;
;;; bn_mul_hw() takes the hardware only for operands that are big enough to repay it and small
;;; enough for MULT mode (>= 256 limb products, <= 64 limbs each); everything else runs the
;;; schoolbook loop.  These cases STRADDLE both edges deliberately, so a fault in either path --
;;; or in the hand-off between them -- shows up as a wrong digest rather than as a silent
;;; disagreement between two implementations of the same operation.
;;; Every expected value was computed independently in Python, never read back from LambLisp.
;;; Digest is (a*b) mod 1000000007, which is short to print and sensitive to every limb.

(define bn-fails 0)
(define (bn-chk name got want)
  (if (equal? got want)
      (begin (display "PASS ") (display name) (newline))
      (begin (set! bn-fails (+ bn-fails 1))
             (display "FAIL ") (display name)
             (display " got=") (display got) (display " want=") (display want) (newline))))

(define (bn-pow base k) (let loop ((i k) (a 1)) (if (= i 0) a (loop (- i 1) (* a base)))))
(define (bn-digest a b) (remainder (* a b) 1000000007))

(define (bn-suite label)
  (display "=== bignum-hw ") (display label) (display " ===") (newline)
  (set! bn-fails 0)
  ;;                                        limbs      products   path
  (bn-chk 'tiny  (bn-digest (bn-pow 3   20) (bn-pow 7   15)) 195700676)   ;;  1x2       2   software
  (bn-chk 'small (bn-digest (bn-pow 3  100) (bn-pow 7   80)) 121658452)   ;;  5x8      40   software
  (bn-chk 'bound (bn-digest (bn-pow 3  320) (bn-pow 7  230)) 815439428)   ;; 16x21    336   software (under the 1600 threshold)
  (bn-chk 'bench (bn-digest (bn-pow 3  500) (bn-pow 7  400)) 801052796)   ;; 25x36    900   software (under the 1600 threshold)
  (bn-chk 'cap   (bn-digest (bn-pow 3 1290) (bn-pow 7  720)) 711922328)   ;; 64x64   4096   HARDWARE (at cap)
  (bn-chk 'over  (bn-digest (bn-pow 3 1350) (bn-pow 7 1150))  38367993)   ;; 67x101  6767   software (over cap)
  ;; the exact pair the bignum-mul benchmark uses: DH/RSA-2048 operands, 64x64 limbs
  (bn-chk 'dh2048 (bn-digest (bn-pow 3 1292) (bn-pow 7  729)) 737829950)   ;; 64x64   4096   HARDWARE
  ;; squaring drives the i==j diagonal of the schoolbook loop and the X==Y case in MULT mode
  (bn-chk 'square (let ((x (bn-pow 3 500))) (bn-digest x x))   56888193)
  (display "bignum-hw ") (display label) (display ": ") (display bn-fails)
  (display " failure(s)") (newline)
  bn-fails)

;;; ---------------------------------------------------------------------------------------------
;;; Diffie-Hellman / RSA operations on the RSA peripheral.
;;;
;;; The modulus below is the RFC 3526 group-14 2048-bit MODP prime -- the actual modulus deployed
;;; DH uses -- so these are the operations and the operand size that matter in practice, not
;;; synthetic ones.  The peripheral can do three things and only three: multiply, modular
;;; multiply, and modular exponentiation.  It has NO divider, which is why plain bignum division
;;; and remainder stay in software; there is no hardware to move them to.
;;; Every expected value below is from Python's pow()/%, computed independently of LambLisp.

(define dh-p 32317006071311007300338913926423828248817941241140239112842009751400741706634354222619689417363569347117901737909704191754605873209195028853758986185622153212175412514901774520270235796078236248884246189477587641105928646099411723245426622522193230540919037680524235519125679715870117001058055877651038861847280257976054903569732561526167081339361799541336476559160368317896729073178384589680639671900977202194168647225871031411336429319536193471636533209717077448227988588565369208645296636077250268955505928362751121174096972998068410554359584866583291642136218231078990999448652468262416972035911852507045361090559)
(define dh-g 2)
(define dh-x 19165957154648518984833798312370182933836280465431825030423421435200329784875)              ;; a fixed 256-bit private exponent, DH-2048's usual exponent size

(define (bn-crypto-suite label)
  (display "=== bignum-crypto ") (display label) (display " ===") (newline)
  (set! bn-fails 0)
  ;; modexp: the DH public value g^x mod p, digested so the line stays short
  (bn-chk 'dh-modexp   (remainder (modular-exponent dh-g dh-x dh-p) 1000000007) 776335697)
  ;; modexp with the RSA public exponent 65537 -- the verify/encrypt direction
  (bn-chk 'rsa-e65537  (remainder (modular-exponent 3 65537 dh-p) 1000000007) 69154392)
  ;; modexp with a tiny exponent, which must agree whichever path takes it
  (bn-chk 'modexp-1    (modular-exponent 12345 1 dh-p) 12345)
  ;; modular multiply: the peripheral's third operation
  (bn-chk 'mulmod      (remainder (bignum-mulmod (bn-pow 3 1292) (bn-pow 7 729) dh-p) 1000000007) 742136508)
  ;; EVEN modulus: Montgomery cannot, so this MUST come back from the software path, still correct
  (bn-chk 'mulmod-even (bignum-mulmod 123456789 987654321 1000000000) 112635269)
  ;; modexp with an even modulus, likewise software
  (bn-chk 'modexp-even (modular-exponent 7 100 1000000000) 928060001)
  (display "bignum-crypto ") (display label) (display ": ") (display bn-fails)
  (display " failure(s)") (newline)
  bn-fails)
