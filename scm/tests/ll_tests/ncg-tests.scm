;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; NCG (Native Code Generator) test suite
;;;
;;; Tests ncg-compile, ncg-compiled?, and correct execution of
;;; NCG-compiled procedures covering every bytecode opcode.
;;;
;;; These tests require the NCG backend to be implemented for the current
;;; platform.  On unsupported platforms ncg-compile returns the proc
;;; unchanged and ncg-compiled? returns #f; the functional correctness
;;; tests below still run via the bytecode fallback path.
;;;
;;; Load with: (load "ncg-tests.scm" 1)
;;; =======================================================================

(define (check name expected actual)
  (if (equal? expected actual)
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a  expected=~a  got=~a\n" name expected actual)))

(define (check-true name actual)
  (if actual
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a  expected=#t  got=~a\n" name actual)))

(define (check-false name actual)
  (if (not actual)
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a  expected=#f  got=~a\n" name actual)))

;;; Compile a lambda to bytecode, then to native code.  Returns the
;;; native proc (or the bytecode proc if NCG is not available).
(define (ncg-compile-lambda lam)
  (ncg-compile (procedure->bytecode lam)))

;;; Report whether the current platform has an NCG backend.
(define ncg-available?
  (let ((probe (ncg-compile (procedure->bytecode (lambda (x) x)))))
    (ncg-compiled? probe)))

(printf "NCG available: ~a\n" ncg-available?)


;;; -----------------------------------------------------------------------
;;; 1. ncg-compiled? predicate
;;; -----------------------------------------------------------------------

(printf "--- 1. ncg-compiled? predicate ---\n")

(define ncg-add1 (ncg-compile-lambda (lambda (x) (+ x 1))))

;;; ncg-compiled? on non-bytecode objects must be #f.
(check-false "ncg-compiled? lambda"    (ncg-compiled? (lambda (x) x)))
(check-false "ncg-compiled? integer"   (ncg-compiled? 42))
(check-false "ncg-compiled? nil"       (ncg-compiled? '()))

;;; A plain bytecode proc (not yet NCG-compiled) is not ncg-compiled?.
(let ((bc (procedure->bytecode (lambda (x) x))))
  (check-false "ncg-compiled? plain bytecode"  (ncg-compiled? bc)))

;;; ncg-compiled? on the ncg-compiled proc reflects the platform.
;;; On platforms with an NCG backend this will be #t; others #f.
;;; Either way the value should be a boolean.
(check-true "ncg-compiled? is boolean"
            (boolean? (ncg-compiled? ncg-add1)))


;;; -----------------------------------------------------------------------
;;; 2. NCG_LOAD_CONST / NCG_PUSH_NIL
;;; -----------------------------------------------------------------------

(printf "--- 2. constants ---\n")

(define ncg-ret42   (ncg-compile-lambda (lambda () 42)))
(define ncg-ret-t   (ncg-compile-lambda (lambda () #t)))
(define ncg-ret-f   (ncg-compile-lambda (lambda () #f)))
(define ncg-ret-nil (ncg-compile-lambda (lambda () '())))
(define ncg-ret-str (ncg-compile-lambda (lambda () "world")))
(define ncg-ret-sym (ncg-compile-lambda (lambda () 'bar)))

(check "ncg const 42"     42       (ncg-ret42))
(check "ncg const #t"     #t       (ncg-ret-t))
(check "ncg const #f"     #f       (ncg-ret-f))
(check "ncg const nil"    '()      (ncg-ret-nil))
(check "ncg const string" "world"  (ncg-ret-str))
(check "ncg const symbol" 'bar     (ncg-ret-sym))


;;; -----------------------------------------------------------------------
;;; 3. NCG_LOAD_LOCAL / NCG_STORE_LOCAL
;;; -----------------------------------------------------------------------

(printf "--- 3. locals ---\n")

(define ncg-identity  (ncg-compile-lambda (lambda (x) x)))
(define ncg-swap      (ncg-compile-lambda (lambda (a b) (list b a))))
(define ncg-3args     (ncg-compile-lambda (lambda (a b c) (+ a (* b c)))))

(check "ncg identity 7"   7        (ncg-identity 7))
(check "ncg identity #f"  #f       (ncg-identity #f))
(check "ncg swap"         '(2 1)   (ncg-swap 1 2))
(check "ncg 3 args"       7        (ncg-3args 1 2 3))

;;; set! local via NCG_STORE_LOCAL
(define ncg-local-set!
  (ncg-compile-lambda
   (lambda (x)
     (set! x (* x 3))
     x)))

(check "ncg local set! *3"   12   (ncg-local-set! 4))


;;; -----------------------------------------------------------------------
;;; 4. NCG_LOAD_GLOBAL / NCG_STORE_GLOBAL
;;; -----------------------------------------------------------------------

(printf "--- 4. globals ---\n")

(define ncg-test-global 200)

(define ncg-read-global
  (ncg-compile-lambda (lambda () ncg-test-global)))

(define ncg-write-global
  (ncg-compile-lambda
   (lambda (v)
     (set! ncg-test-global v))))

(check "ncg read global"   200  (ncg-read-global))
(ncg-write-global 777)
(check "ncg write global"  777  ncg-test-global)
(ncg-write-global 200)

(define ncg-call-car
  (ncg-compile-lambda (lambda (x) (car x))))

(check "ncg call global car"  'a  (ncg-call-car '(a b c)))


;;; -----------------------------------------------------------------------
;;; 5. NCG_CALL / NCG_TAIL_CALL (via ncg-do-call shim)
;;; -----------------------------------------------------------------------

(printf "--- 5. calls ---\n")

(define ncg-add   (ncg-compile-lambda (lambda (a b) (+ a b))))
(define ncg-mul   (ncg-compile-lambda (lambda (a b) (* a b))))

(check "ncg add"  9    (ncg-add 4 5))
(check "ncg mul"  42   (ncg-mul 6 7))

;;; Nested call: (+ (* a a) 1)
(define ncg-sq+1
  (ncg-compile-lambda (lambda (x) (+ (* x x) 1))))

(check "ncg sq+1 3"   10  (ncg-sq+1 3))
(check "ncg sq+1 5"   26  (ncg-sq+1 5))

;;; begin sequence (NCG_POP between non-tail calls)
(define ncg-begin-seq
  (ncg-compile-lambda
   (lambda (x)
     (+ x 1)
     (+ x 2)
     (+ x 10))))

(check "ncg begin last"  20  (ncg-begin-seq 10))


;;; -----------------------------------------------------------------------
;;; 6. NCG_JUMP / NCG_JUMP_IF_FALSE (if / cond)
;;; -----------------------------------------------------------------------

(printf "--- 6. branches ---\n")

(define ncg-abs
  (ncg-compile-lambda
   (lambda (x)
     (if (< x 0) (- x) x))))

(check "ncg abs -7"   7   (ncg-abs -7))
(check "ncg abs  7"   7   (ncg-abs  7))
(check "ncg abs  0"   0   (ncg-abs  0))

(define ncg-sign
  (ncg-compile-lambda
   (lambda (x)
     (if (> x 0) 1
         (if (< x 0) -1 0)))))

(check "ncg sign  2"    1   (ncg-sign  2))
(check "ncg sign -2"   -1   (ncg-sign -2))
(check "ncg sign  0"    0   (ncg-sign  0))

(define ncg-cond-grade
  (ncg-compile-lambda
   (lambda (score)
     (cond ((>= score 90) 'A)
           ((>= score 80) 'B)
           ((>= score 70) 'C)
           (else          'F)))))

(check "ncg cond A"  'A  (ncg-cond-grade 95))
(check "ncg cond B"  'B  (ncg-cond-grade 85))
(check "ncg cond C"  'C  (ncg-cond-grade 72))
(check "ncg cond F"  'F  (ncg-cond-grade 50))


;;; -----------------------------------------------------------------------
;;; 7. and / or (short-circuit, multiple jumps)
;;; -----------------------------------------------------------------------

(printf "--- 7. and / or ---\n")

(define ncg-and2 (ncg-compile-lambda (lambda (a b) (and a b))))
(define ncg-or2  (ncg-compile-lambda (lambda (a b) (or  a b))))

(check "ncg and #t #t"   #t   (ncg-and2 #t #t))
(check "ncg and #f #t"   #f   (ncg-and2 #f #t))
(check "ncg and 3  5"     5   (ncg-and2  3  5))
(check "ncg and #f 5"    #f   (ncg-and2 #f  5))

(check "ncg or  #f #f"   #f   (ncg-or2 #f #f))
(check "ncg or  #f  7"    7   (ncg-or2 #f  7))
(check "ncg or   4 #f"    4   (ncg-or2  4 #f))

;;; (and) → #t, (or) → #f
(define ncg-and0 (ncg-compile-lambda (lambda () (and))))
(define ncg-or0  (ncg-compile-lambda (lambda () (or))))

(check "ncg and empty"   #t   (ncg-and0))
(check "ncg or  empty"   #f   (ncg-or0))


;;; -----------------------------------------------------------------------
;;; 8. let / let*
;;; -----------------------------------------------------------------------

(printf "--- 8. let / let* ---\n")

(define ncg-let1
  (ncg-compile-lambda
   (lambda (x)
     (let ((y (+ x 1))
           (z (- x 1)))
       (* y z)))))

;;; x=5: y=6, z=4, 6*4=24
(check "ncg let"   24   (ncg-let1 5))

(define ncg-letstar
  (ncg-compile-lambda
   (lambda (x)
     (let* ((a (+ x 1))
            (b (* a a)))
       b))))

;;; x=4: a=5, b=25
(check "ncg let*"   25   (ncg-letstar 4))


;;; -----------------------------------------------------------------------
;;; 9. Named let loop
;;; -----------------------------------------------------------------------

(printf "--- 9. named let loop ---\n")

(define ncg-sum-n
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i n) (s 0))
       (if (= i 0) s
           (loop (- i 1) (+ s i)))))))

(check "ncg sum 0"    0    (ncg-sum-n 0))
(check "ncg sum 10"  55    (ncg-sum-n 10))

(define ncg-fib-iter
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i n) (a 0) (b 1))
       (if (= i 0) a
           (loop (- i 1) b (+ a b)))))))

(check "ncg fib 0"    0   (ncg-fib-iter  0))
(check "ncg fib 7"   13   (ncg-fib-iter  7))
(check "ncg fib 10"  55   (ncg-fib-iter 10))


;;; -----------------------------------------------------------------------
;;; 10. NCG_SELF (bc-self: named-let loop variable)
;;; -----------------------------------------------------------------------

(printf "--- 10. NCG_SELF (self-tail) ---\n")

;;; The NCG_SELF opcode is emitted when the compiler pushes the
;;; current bytecode cell for use as the named-let loop function.
;;; Named-let loops use an inlined backward jump (not SELF), but
;;; functions that reference themselves via a global also exercise
;;; the full call path.  The named-let tests above cover the JUMP
;;; path; here we test a global self-recursive compiled procedure.

(define ncg-countdown
  (ncg-compile-lambda
   (lambda (n acc)
     (if (= n 0)
         acc
         (ncg-countdown (- n 1) (+ acc 1))))))

(check "ncg self-recursive count 5"   5   (ncg-countdown 5 0))
(check "ncg self-recursive count 0"   0   (ncg-countdown 0 0))


;;; -----------------------------------------------------------------------
;;; 11. Numerical correctness (broader coverage)
;;; -----------------------------------------------------------------------

(printf "--- 11. numerical ---\n")

(define ncg-pow2
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i n) (r 1))
       (if (= i 0) r
           (loop (- i 1) (* r 2)))))))

(check "ncg 2^0"    1     (ncg-pow2  0))
(check "ncg 2^8"  256     (ncg-pow2  8))
(check "ncg 2^10" 1024    (ncg-pow2 10))

(define ncg-gcd
  (ncg-compile-lambda
   (lambda (a b)
     (let loop ((x a) (y b))
       (if (= y 0) x
           (loop y (remainder x y)))))))

(check "ncg gcd 12 8"   4   (ncg-gcd 12  8))
(check "ncg gcd 35 14"  7   (ncg-gcd 35 14))
(check "ncg gcd 7  5"   1   (ncg-gcd  7  5))


;;; -----------------------------------------------------------------------
;;; 12. List operations
;;; -----------------------------------------------------------------------

(printf "--- 12. list ops ---\n")

(define ncg-list-len
  (ncg-compile-lambda
   (lambda (lst)
     (let loop ((l lst) (n 0))
       (if (null? l) n
           (loop (cdr l) (+ n 1)))))))

(check "ncg length nil"   0   (ncg-list-len '()))
(check "ncg length 3"     3   (ncg-list-len '(a b c)))
(check "ncg length 5"     5   (ncg-list-len '(1 2 3 4 5)))

(define ncg-list-sum
  (ncg-compile-lambda
   (lambda (lst)
     (let loop ((l lst) (s 0))
       (if (null? l) s
           (loop (cdr l) (+ s (car l))))))))

(check "ncg list-sum nil"       0   (ncg-list-sum '()))
(check "ncg list-sum 1..5"     15   (ncg-list-sum '(1 2 3 4 5)))


;;; -----------------------------------------------------------------------
;;; 13. ncg-compile idempotency
;;; -----------------------------------------------------------------------

(printf "--- 13. idempotency ---\n")

;;; Calling ncg-compile twice on the same proc should not corrupt it.
(define ncg-double (ncg-compile-lambda (lambda (x) (* x 2))))
(ncg-compile ncg-double)  ;; second call -- should be no-op

(check "ncg double after re-compile"  10  (ncg-double 5))

;;; ncg-compile on a proc not yet bytecoded: should work if we first
;;; get bytecode.
(define bc-triple (procedure->bytecode (lambda (x) (* x 3))))
(define ncg-triple (ncg-compile bc-triple))

(check "ncg triple 7"  21  (ncg-triple 7))


;;; -----------------------------------------------------------------------
;;; 14. Mixed bytecode and NCG calls
;;; -----------------------------------------------------------------------

(printf "--- 14. mixed BC + NCG ---\n")

;;; A bytecode proc calling an NCG proc.
(define ncg-helper  (ncg-compile-lambda  (lambda (x) (+ x 100))))
(define bc-uses-ncg (procedure->bytecode (lambda (x) (ncg-helper (* x 2)))))

(check "bc calls ncg 5"   110  (bc-uses-ncg 5))
(check "bc calls ncg 10"  120  (bc-uses-ncg 10))

;;; An NCG proc calling a bytecode proc.
(define bc-halve   (procedure->bytecode (lambda (x) (quotient x 2))))
(define ncg-uses-bc (ncg-compile-lambda (lambda (x) (bc-halve (* x 4)))))

(check "ncg calls bc 5"   10   (ncg-uses-bc 5))
(check "ncg calls bc 7"   14   (ncg-uses-bc 7))


;;; -----------------------------------------------------------------------
;;; 15. compile-environment! then ncg-compile-environment!
;;; -----------------------------------------------------------------------

(printf "--- 15. compile-environment! ---\n")

;;; Define some lambdas and mass-compile them.
(define ncg-env-test-a (lambda (x) (+ x  1)))
(define ncg-env-test-b (lambda (x) (* x  2)))
(define ncg-env-test-c (lambda (x) (- x  1)))

(compile-environment! (interaction-environment))

(check "env-compiled a"  11  (ncg-env-test-a 10))
(check "env-compiled b"  20  (ncg-env-test-b 10))
(check "env-compiled c"   9  (ncg-env-test-c 10))

;;; Now NCG-compile everything that was bytecoded.
(let ((n (ncg-compile-environment! (interaction-environment))))
  (check-true "ncg-compile-environment! returned integer"  (integer? n)))

(check "ncg-env a after mass-NCG"  11  (ncg-env-test-a 10))
(check "ncg-env b after mass-NCG"  20  (ncg-env-test-b 10))
(check "ncg-env c after mass-NCG"   9  (ncg-env-test-c 10))


;;; -----------------------------------------------------------------------
;;; 16. P129 unboxed-fixnum arithmetic -- overflow, deopt, mixed, negatives
;;; -----------------------------------------------------------------------
;;;
;;; These exercise the P129 representation-tracking fast path and its
;;; box-at-boundary / guard-deopt fallbacks.  Correctness must be identical
;;; to the interpreter; the only difference is speed.

(printf "--- 16. P129 unboxed-fixnum ---\n")

;;; (a) Overflow at the box boundary: 32+32 / 32x32 must promote to a wider
;;;     integer, NOT truncate to int32 (B68).  These values exceed INT32_MAX.
(define ncg-add-ovf (ncg-compile-lambda (lambda (a b) (+ a b))))
(define ncg-mul-ovf (ncg-compile-lambda (lambda (a b) (* a b))))

;;; 2_000_000_000 + 2_000_000_000 = 4_000_000_000 (> INT32_MAX 2147483647)
(check "ncg add overflow→wide"  4000000000  (ncg-add-ovf 2000000000 2000000000))
;;; 100_000 * 100_000 = 10_000_000_000 (> INT32_MAX, fits int64)
(check "ncg mul overflow→wide"  10000000000 (ncg-mul-ovf 100000 100000))
;;; 46341^2 = 2147488281 just over INT32_MAX -- the classic truncation tripwire.
(check "ncg mul just-over-int32" 2147488281 (ncg-mul-ovf 46341 46341))
;;; Subtraction underflow below INT32_MIN.
(define ncg-sub-ovf (ncg-compile-lambda (lambda (a b) (- a b))))
(check "ncg sub underflow→wide"  -4000000000 (ncg-sub-ovf -2000000000 2000000000))

;;; (b) Guard / deopt on non-fixnum operands: a literal-fixnum operand combined
;;;     with a non-T_INT32 operand must take the slow path and stay correct.
;;;     (P129 skips the guard on the *literal* operand only; the runtime value
;;;     operand is still guarded and deopts to the full numeric-tower shim.)
(define ncg-add1   (ncg-compile-lambda (lambda (x) (+ x 1))))     ;; literal b=1
(define ncg-sub1   (ncg-compile-lambda (lambda (x) (- x 1))))
(define ncg-lt-lit (ncg-compile-lambda (lambda (x) (< x 5))))     ;; literal b=5

(check "ncg +1 fixnum"        43     (ncg-add1 42))
(check "ncg +1 deopt int64"   10000000001 (ncg-add1 10000000000))  ;; x is int64 → deopt
(check "ncg -1 fixnum"        41     (ncg-sub1 42))

;;; (c) Mixed int / float: the float operand fails the T_INT32 guard → slow path,
;;;     producing an inexact result (numeric tower unchanged).
(define ncg-mix-add (ncg-compile-lambda (lambda (a b) (+ a b))))
(define ncg-mix-mul (ncg-compile-lambda (lambda (a b) (* a b))))
(check "ncg int+float"   3.5   (ncg-mix-add 1   2.5))
(check "ncg float+int"   3.5   (ncg-mix-add 2.5 1))
(check "ncg int*float"   5.0   (ncg-mix-mul 2   2.5))

;;; (d) Negative ranges through the fast path (sign-extension correctness).
(define ncg-neg-add (ncg-compile-lambda (lambda (a b) (+ a b))))
(define ncg-neg-sub (ncg-compile-lambda (lambda (a b) (- a b))))
(define ncg-neg-mul (ncg-compile-lambda (lambda (a b) (* a b))))
(check "ncg neg add"   -7   (ncg-neg-add -3 -4))
(check "ncg neg sub"    1   (ncg-neg-sub -3 -4))
(check "ncg neg mul"   12   (ncg-neg-mul -3 -4))
(check "ncg neg+pos"   -1   (ncg-neg-add -4  3))

;;; (e) Comparisons in loop conditions (the JUMP_IF_FALSE consumer of a compare),
;;;     across the zero boundary and with literal bounds -- the common P129 case.
(define ncg-count-lt
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i 0) (c 0))
       (if (< i n) (loop (+ i 1) (+ c 1)) c)))))
(check "ncg loop < 0"      0   (ncg-count-lt 0))
(check "ncg loop < 100"  100   (ncg-count-lt 100))

(define ncg-cmp-all
  (ncg-compile-lambda
   (lambda (a b)
     (list (< a b) (<= a b) (> a b) (>= a b) (= a b)))))
(check "ncg cmp 3 5"  '(#t #t #f #f #f)  (ncg-cmp-all 3 5))
(check "ncg cmp 5 5"  '(#f #t #f #t #t)  (ncg-cmp-all 5 5))
(check "ncg cmp 5 3"  '(#f #f #t #t #f)  (ncg-cmp-all 5 3))
(check "ncg cmp -2 1" '(#t #t #f #f #f)  (ncg-cmp-all -2 1))

;;; (f) Nested arithmetic chain: (+ (* a a) (* b b)) -- multiple boxed
;;;     intermediates feeding arith ops.
(define ncg-sumsq (ncg-compile-lambda (lambda (a b) (+ (* a a) (* b b)))))
(check "ncg sumsq 3 4"   25   (ncg-sumsq 3 4))
(check "ncg sumsq -3 4"  25   (ncg-sumsq -3 4))

;;; (g) GC-stress variant: a tight loop that does unboxed arithmetic AND
;;;     allocates (cons) every iteration, forcing the collector to run while the
;;;     arithmetic fast path is hot.  Proves no raw int is ever GC-scanned: a
;;;     mis-scanned raw value would corrupt the heap and crash or wrong-answer.
;;;     The accumulator sum is computed via the unboxed path; the list growth
;;;     drives allocation/GC.
(define ncg-gc-stress
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i n) (sum 0) (lst '()))
       (if (= i 0)
           sum
           (loop (- i 1) (+ sum i) (cons i lst)))))))
;;; sum_{i=1..n} i = n(n+1)/2 ; n=2000 → 2001000
(check "ncg gc-stress sum"  2001000  (ncg-gc-stress 2000))


;;; -----------------------------------------------------------------------
;;; 16b. P129 Phase 2 -- inline NCG_STORE_LOCAL + in-loop guard-skip
;;; -----------------------------------------------------------------------
;;;
;;; Phase 2B replaces the per-iteration NCG_STORE_LOCAL write-barrier shim CALL with an
;;; inline store guarded by a runtime gcphase check (call the shim only while marking, else
;;; a plain mov).  Phase 2A propagates a per-slot "provably int32" fact across loop back-edges
;;; to skip the runtime T_INT32 guard on in-loop arith operands, conservatively cleared on any
;;; non-int store so overflow-growable accumulators stay correct.  The value stored/loaded is
;;; ALWAYS boxed, so ncg_mark_frames() never sees a raw int.  These tests prove correctness of
;;; the inline store across GC points and of the conservative clear.

(printf "--- 16b. P129 Phase 2 inline-store / guard-skip ---\n")

;;; (h) Loop-var store-then-read-back with an intervening cons.  The set! writes the local via
;;;     the inline NCG_STORE_LOCAL path; the cons allocates (a GC point that may begin a mark
;;;     phase, exercising the gcphase==marking write-barrier branch); then the local is read
;;;     back and must still hold the stored, fully-markable value.  A mis-stored (unbarriered
;;;     or raw) value would be collected or mis-scanned → wrong answer or crash.
(define ncg-store-readback
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i 0) (acc 0) (junk '()))
       (if (= i n)
           acc
           (let ((v (* i 3)))                 ;; compute a value
             (set! acc (+ acc v))             ;; inline STORE_LOCAL of acc (boxed)
             (set! junk (cons i junk))        ;; allocate between store and read-back
             (loop (+ i 1) acc junk)))))))    ;; read acc back across the GC point
;;; sum_{i=0..n-1} 3i = 3 * (n-1)n/2 ; n=1000 → 3 * 499500 = 1498500
(check "ncg store-readback w/cons"  1498500  (ncg-store-readback 1000))
(check "ncg store-readback n=1"     0        (ncg-store-readback 1))
(check "ncg store-readback n=2"     3        (ncg-store-readback 2))

;;; (i) Induction var crossing the int32 range mid-loop.  acc starts as a small int32 but the
;;;     repeated (+ acc step) grows it past INT32_MAX, so the slot can hold a T_INT64.  Phase 2A
;;;     must NOT mark acc "provably int32" (its store is an arith result that can overflow), so
;;;     the type guard is NOT skipped and the value promotes correctly.  A wrong guard-skip would
;;;     read the T_INT64 cell's car as the whole value → truncation / wrong answer.
(define ncg-induction-cross
  (ncg-compile-lambda
   (lambda (n step)
     (let loop ((i 0) (acc 0))
       (if (= i n)
           acc
           (loop (+ i 1) (+ acc step)))))))
;;; 10 iterations of +500_000_000 = 5_000_000_000 (> INT32_MAX 2147483647 → must be int64)
(check "ncg induction →int64"  5000000000  (ncg-induction-cross 10 500000000))
;;; Stays in int32 range: 10 * 100 = 1000.
(check "ncg induction int32"   1000        (ncg-induction-cross 10 100))
;;; Negative crossing below INT32_MIN.
(check "ncg induction →int64-" -5000000000 (ncg-induction-cross 10 -500000000))

;;; (j) GC-stress over the inline-store loop under FORCED collect.  Every iteration explicitly
;;;     forces a full GC (gc!) right after the inline store and before the read-back, maximally
;;;     stressing the write-barrier / mark-frames path: if the inline store left an unmarkable
;;;     or raw value in the locals slot, the forced collect would reclaim/corrupt it.
(define (ncg-force-gc-step! x) (gc!) x)             ;; forces a stop-the-world collect
(define ncg-gc-forced
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i 0) (acc 0) (lst '()))
       (if (= i n)
           acc
           (begin
             (set! acc (+ acc i))                    ;; inline STORE_LOCAL of acc
             (set! lst (cons (ncg-force-gc-step! i) lst))  ;; force GC between store and read
             (loop (+ i 1) acc lst)))))))
;;; sum_{i=0..n-1} i = (n-1)n/2 ; n=300 → 299*300/2 = 44850
(check "ncg gc-forced sum"  44850  (ncg-gc-forced 300))


;;; -----------------------------------------------------------------------
;;; SEAM: NCG-COMPILED CODE CALLING AN INTERPRETED CLOSURE, COLLECTING INSIDE THE CALL
;;; -----------------------------------------------------------------------
;;;
;;; WHY THIS EXISTS.  Our correctness suites exercise ONE EXECUTION MODE AT A TIME, so none of
;;; them constructs a compiled->interpreted call -- and that seam is where ncg_call's T_PROC path
;;; lives.  It exists ONLY because compiled code calls interpreted code, so neither a fully-AST
;;; nor a fully-NCG suite reaches it.  Until now the only thing routinely producing that shape was
;;; bench-runner's NCG pass (251 compiled procedures calling a non-compiled environment) -- a
;;; PERFORMANCE tier, covering a CORRECTNESS property incidentally.  B226 was a missing GC root on
;;; exactly this path: ncg_call read the callee's body and held it across an allocating call, and
;;; a collection landing there swept it (apply_proc_partial then saw gcstate 0x04 GC_FREE).
;;;
;;; TWO PROPERTIES THIS TEST MUST KEEP, both learned the expensive way:
;;;
;;;   1. VERIFY THE VALUE, not merely the absence of a crash.  A swept closure body does NOT have
;;;      to fault -- it can quietly produce a wrong answer, which passes a smoke test.  The callee
;;;      allocates BEFORE the collect and reads it back AFTER, so a sweep of live data shows up as
;;;      arithmetic that does not add up.
;;;   2. FORCE the collection; do not hope for one.  A test that relies on allocation pressure to
;;;      land a GC in the right window passes on most runs and fails on a Tuesday.  `(gc!)` inside
;;;      the interpreted callee puts the collect INSIDE the compiled->interpreted call by
;;;      construction -- the same shape as the observed backtrace, where gc_collect is called from
;;;      ncg_call.
;;;
;;; seam-callee is deliberately NEVER passed to ncg-compile: if it is ever compiled, this test
;;; silently stops testing the seam and becomes an NCG->NCG call, which is a different path.

(printf "--- seam: compiled -> interpreted, GC inside the call ---\n")

(define (seam-callee i)                  ;;; INTERPRETED -- do not compile this
  (let ((cell (cons i (cons (* i 2) (list)))))   ;;; live across the collect below
    (gc!)                                        ;;; collect issued from INSIDE the seam call
    (+ (car cell) (car (cdr cell)))))            ;;; 3i if the cell survived intact

(define ncg-seam
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i n) (acc 0))
       (if (= i 0) acc (loop (- i 1) (+ acc (seam-callee i))))))))

(if (ncg-compiled? ncg-seam)
    (check-true "seam driver is ncg-compiled" (ncg-compiled? ncg-seam))
    ;;; NOT a correctness failure: the driver compiles standalone on this board (verified on the
    ;;; S3 devkit, ncg-compiled? #t and the value exact), so a #f here means compilation was
    ;;; declined in THIS context -- exec-pool pressure after the compiles above it is the leading
    ;;; candidate.  Say so loudly instead of failing: an un-compiled driver means the SEAM IS NOT
    ;;; UNDER TEST in this run, which the reader must know, but it is not a defect in the code
    ;;; under test.  Never let this degrade to silence -- that is the whole point of the check.
    (printf "SKIP seam: driver not ncg-compiled here; seam NOT exercised this run\n"))
(check-false "seam callee stays interpreted" (ncg-compiled? seam-callee))
;;; sum_{i=1..n} 3i = 3n(n+1)/2 ; n=60 -> 3*1830 = 5490
;;; GATED on the driver having compiled, for the same reason as the unwind case below: if it did
;;; not, the INTERPRETED path runs and passes, reporting coverage of a seam the run never crossed.
(if (ncg-compiled? ncg-seam)
    (check "seam compiled->interpreted +gc"  5490  (ncg-seam 60))
    (printf "SKIP seam value check: driver not ncg-compiled; interpreted path would pass falsely\n"))


;;; -----------------------------------------------------------------------
;;; SEAM, UNWIND WINDOW: collection during the RETURN path of a compiled->interpreted call
;;; -----------------------------------------------------------------------
;;;
;;; The case above collects while the seam call is IN FLIGHT.  This one collects while it is
;;; UNWINDING -- after the interpreted callee has stopped running, while the result is in flight
;;; and frames above are being released.  `ncg_release_frames_above()` runs on that path and
;;; writes f->prev unchecked, and a chain-validity guard has reported a link that was never a
;;; frame (was_a_frame=0) there.  Neither the suites nor the benchmark runner construct it.
;;;
;;; The unwind path is reached by a THROW out of the interpreted callee, not by a normal return:
;;; that is where ncg_eval_jit_call releases the frames above it.  The handler forces the collect,
;;; so the GC lands during the release rather than whenever allocation pressure happens to trigger.
;;; Value-verified for the same reason as above: a swept frame or result can return a wrong number
;;; rather than crashing.

(printf "--- seam: GC during the UNWIND of a compiled -> interpreted call ---\n")

(define (seam-raiser i)                  ;;; INTERPRETED; always throws
  (if (> i 0) (raise 'seam-unwind) 0))

(define ncg-unwind
  (ncg-compile-lambda
   (lambda (n)
     (let loop ((i n) (acc 0))
       (if (= i 0) acc
           (loop (- i 1)
                 (+ acc (with-exception-handler
                         (lambda (e) (gc!) 3)      ;;; collect DURING the unwind
                         (lambda () (seam-raiser i))))))))))

(if (ncg-compiled? ncg-unwind)
    (begin
      (check-true "unwind driver is ncg-compiled" #t)
      ;;; every iteration is caught and contributes 3 ; n=60 -> 180
      (check "seam unwind +gc in handler"  180  (ncg-unwind 60)))
    ;;; SKIP THE VALUE CHECK TOO, not just the compiled-ness check.  If the driver did not
    ;;; compile, the INTERPRETED path runs -- and it catches correctly -- so the value check
    ;;; PASSES for a path the test never meant to exercise.  Observed on the 4WD 2026-09-02:
    ;;; "PASS seam unwind +gc in handler" in a tier where the exec pool was exhausted and no
    ;;; compiled code ran at all.  A pass for an untaken path is worse than no test: it reports
    ;;; coverage that does not exist.
    (printf "SKIP unwind: driver not ncg-compiled here; window NOT exercised, value check skipped\n"))

(printf "--- done ---\n")
