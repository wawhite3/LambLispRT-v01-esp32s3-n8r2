;;; bitwise_s3.scm -- device check for BC_/NCG_BITAND/BITOR/BITXOR (d5a9d1f).
;;; SELF-TESTS ALL THREE MODES.  A plain (load) runs every case as AST, then
;;; again after procedure->bytecode, then again after ncg-compile-transitive!.
;;; That matters because only NCG reaches the xtensa emission (e_and/e_or/e_xor
;;; and do_op 3/4/5) -- an AST-only or BC-only pass is a FALSE GREEN for it.
;;; The checks live in a thunk for exactly that reason: top-level checks can only
;;; ever be interpreted, so the interesting half would never run.
(define fails 0)
(define (chk name got want)
  (if (equal? got want)
      (begin (display "PASS ") (display name) (newline))
      (begin (set! fails (+ fails 1))
             (display "FAIL ") (display name)
             (display " got=") (display got)
             (display " want=") (display want) (newline))))

(define (bitwise-suite)
  ;;; --- 1. basic truth, distinct bit patterns -------------------------------
  ;;; If the xtensa e_or encoding (RRR OP2=2) were wrong, OR would decode as some
  ;;; other RRR op; these three must NOT agree with each other.
  (chk 'and    (bitwise-and 12 10) 8)
  (chk 'or     (bitwise-or  12 10) 14)
  (chk 'xor    (bitwise-xor 12 10) 6)
  (chk 'or-ne-and (equal? (bitwise-or 12 10) (bitwise-and 12 10)) #f)
  (chk 'or-ne-xor (equal? (bitwise-or 12 10) (bitwise-xor 12 10)) #f)

  ;;; --- 2. OUT OF SMALL-INT CACHE [-2048,4096] ------------------------------
  ;;; THE critical case on xtensa: the out-of-cache path passes do_op straight to
  ;;; ncg_arith_box32, whose switch was `0 add / 1 sub / default MULTIPLY` before
  ;;; d5a9d1f.  A wrong decode here silently MULTIPLIES.  Products would be huge,
  ;;; so these values are chosen so a mis-decode cannot coincidentally match.
  (chk 'big-and (bitwise-and 1000000 999999) 999936)
  (chk 'big-or  (bitwise-or  1000000 999999) 1000063)
  (chk 'big-xor (bitwise-xor 1000000 999999) 127)
  (chk 'edge-hi (bitwise-or  4096 1) 4097)          ; just past cache top
  (chk 'edge-lo (bitwise-and -2049 -1) -2049)       ; just past cache bottom

  ;;; --- 3. sign extension ---------------------------------------------------
  ;;; xtensa loads operands with e_l32i (native 32-bit).  On x86_64/aarch64 they
  ;;; are sign-extended to 64 bits first; the result must agree on all three.
  (chk 'neg-and (bitwise-and -1 255) 255)
  (chk 'neg-or  (bitwise-or  -256 255) -1)
  (chk 'neg-xor (bitwise-xor -1 -1) 0)
  (chk 'neg-mix (bitwise-and -8 -3) -8)
  (chk 'neg-big (bitwise-xor -1000000 123456) -958592)
  (chk 'neg-big2 (bitwise-and -1000000 123456) 41024)
  (chk 'neg-big3 (bitwise-or -1000000 123456) -917568)

  ;;; --- 4. hot loops -- must exceed the NCG threshold -----------------------
  ;;; This is the only part that reaches the new xtensa emission at all.
  (define (xloop n acc) (if (= n 0) acc (xloop (- n 1) (bitwise-xor acc n))))
  (chk 'loop-xor  (xloop 1000 0) 1000)     ; XOR 1..n, n mod 4 = 0 -> n
  (chk 'loop-xor2 (xloop 1001 0) 1)        ; n mod 4 = 1 -> 1
  (chk 'loop-xor3 (xloop 1002 0) 1003)     ; n mod 4 = 2 -> n+1
  (define (aloop n acc) (if (= n 0) acc (aloop (- n 1) (bitwise-and acc 65535))))
  (chk 'loop-and (aloop 1000 123456789) 52501)
  (define (oloop n acc) (if (= n 0) acc (oloop (- n 1) (bitwise-or acc n))))
  (chk 'loop-or  (oloop 1000 0) 1023)      ; OR of 1..1000 -> all bits below 1024

  ;;; --- 5. mixed, out-of-cache, inside a compiled procedure -----------------
  (define (mix a b) (bitwise-xor (bitwise-or a b) (bitwise-and a b)))
  (chk 'mix-small (mix 12 10) 6)
  (chk 'mix-big   (mix 1000000 999999) 127)
  fails)

;;; --- run the whole suite in all three modes ------------------------------
(define (run-mode name thunk12)
  (set! fails 0)
  (let ((n (thunk12)))
    (display "bitwise ") (display name) (display ": ")
    (display n) (display " failure(s)") (newline)
    n))

(define total 0)
(set! total (+ total (run-mode "AST" bitwise-suite)))
(set! bitwise-suite (procedure->bytecode bitwise-suite))
(set! total (+ total (run-mode "BC" bitwise-suite)))
(ncg-compile-transitive! bitwise-suite)
(set! total (+ total (run-mode "NCG" bitwise-suite)))
(display "bitwise: ") (display total) (display " failure(s) across 3 modes") (newline)
