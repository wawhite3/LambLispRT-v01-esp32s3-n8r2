;;; Copyright 2026 by Frobenius Norm LLC 2026-06-30
;;; Free for non-commercial use. Commercial use requires a license.
;;; struct-tests.scm -- P133 (7.3) struct pack/unpack round-trip tests.
;;; Self-contained (no prelude deps): pipe into the host binary, e.g.
;;;   .pio/build/linux_x86_64/program < scm/tests/ll_tests/struct-tests.scm
(define *st-pass* 0)
(define *st-fail* 0)
(define (st-check name expected actual)
  (if (equal? expected actual)
      (set! *st-pass* (+ *st-pass* 1))
      (begin
        (set! *st-fail* (+ *st-fail* 1))
        (display "FAIL ") (display name)
        (display "  expected=") (write expected)
        (display "  got=") (write actual) (newline))))

;; calcsize
(st-check "calcsize >HHf"   8 (struct-calcsize ">HHf"))
(st-check "calcsize <4h2xQ" 18 (struct-calcsize "<4h2xQ"))
(st-check "calcsize bBhHiIqQ" 30 (struct-calcsize "bBhHiIqQ"))

;; unsigned round-trips, both byte orders
(st-check "be HHf"  '(258 1000 3.5)   (struct-unpack ">HHf" (struct-pack ">HHf" 258 1000 3.5)))
(st-check "le HHf"  '(258 1000 3.5)   (struct-unpack "<HHf" (struct-pack "<HHf" 258 1000 3.5)))

;; signed round-trips
(st-check "le i neg"  '(-123456)      (struct-unpack "<i" (struct-pack "<i" -123456)))
(st-check "be b neg"  '(-5)           (struct-unpack ">b" (struct-pack ">b" -5)))
(st-check "be h neg"  '(-30000)       (struct-unpack ">h" (struct-pack ">h" -30000)))

;; unsigned byte / short edge values
(st-check "B 200"     '(200)          (struct-unpack ">B" (struct-pack ">B" 200)))
(st-check "H 65535"   '(65535)        (struct-unpack ">H" (struct-pack ">H" 65535)))

;; 64-bit
(st-check "le q big"  '(9000000000)   (struct-unpack "<q" (struct-pack "<q" 9000000000)))

;; float / double  (compare numerically: 'd' yields float64, distinct cell type from a float32 literal)
(st-check "be d" #t (= 3.140625 (car (struct-unpack ">d" (struct-pack ">d" 3.140625)))))

;; endianness reorders multi-byte fields; ">H" 258 = 0x0102 -> bytes (1 2) regardless of read order
(st-check "be bytes"  '(1 2)          (struct-unpack ">BB" (struct-pack ">H" 258)))
(st-check "le bytes"  '(1 2)          (struct-unpack "<BB" (struct-pack ">H" 258)))
;; the multi-byte field itself does flip: ">H" packs 0x0102, "<H" reads it as 0x0201
(st-check "endian flip" '(513)        (struct-unpack "<H" (struct-pack ">H" 258)))

;; pack-into! writes in place, no allocation
(st-check "pack-into!" '(513 1027)
          (let ((bv (make-bytevector 8 0)))
            (struct-pack-into! bv 2 ">HH" 513 1027)
            (struct-unpack ">HH" bv 2)))

;; pad bytes are skipped on both sides
(st-check "pad xx"    '(7 9)          (struct-unpack ">B2xB" (struct-pack ">B2xB" 7 9)))

(display "\n=== STRUCT TESTS: ")
(display *st-pass*) (display " passed, ")
(display *st-fail*) (display " failed ===\n")
