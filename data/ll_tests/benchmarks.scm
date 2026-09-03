;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; benchmarks.scm -- portable Scheme benchmarks
;;; R5RS only.  Runs unchanged on LambLisp, Chez Scheme, and TinyScheme.
;;;
;;; Timing: current-ms returns 0 by default (no built-in timer assumed).
;;; To enable timing, evaluate this before loading the file:
;;;
;;;   LambLisp:    (define current-ms millis)
;;;   Chez Scheme: (define (current-ms)
;;;                  (let ((t (current-time 'monotonic)))
;;;                    (+ (* (time-second t) 1000)
;;;                       (quotient (time-nanosecond t) 1000000))))
;;;   TinyScheme:  no portable timer; leave as 0
;;;

(define (current-ms) 0)                            ;;;!< override for your platform

;;;-----------------------------------------------------------------------------
;;; Benchmark harness

(define (bench name thunk11 expected)
  (let* ((t0     (current-ms))
         (result (thunk11))
         (dt     (- (current-ms) t0)))
    (display name) (display ":  ")
    (display result)
    (display (if (or (not expected) (equal? result expected)) "  OK" "  FAIL"))
    (display "  ")
    (display dt) (display " ms")
    (newline)
    (or (not expected) (equal? result expected))))

;;;-----------------------------------------------------------------------------
;;; 1.  Recursive Fibonacci -- measures raw function call and integer arithmetic.

(define (fib n)
  (if (< n 2) n
      (+ (fib (- n 1)) (fib (- n 2)))))

;;;-----------------------------------------------------------------------------
;;; 2.  Tail-recursive Fibonacci -- verifies tail-call elimination.
;;; n=92: fib(92)=7540113804746346429 is the last value fitting in int64.
;;; fib(93) overflows.  Run 109 reps so total iterations ~= 10000 (comparable
;;; to other benchmarks) and so the result is the same on all R5RS implementations.

(define (fib-iter n)
  (let loop ((i n) (a 0) (b 1))
    (if (= i 0) a
        (loop (- i 1) b (+ a b)))))

(define (fib-iter-bench reps)           ;;;!< reps × fib-iter(92); result = fib(92)
  (let loop ((k reps))
    (if (= k 0) (fib-iter 92)
        (begin (fib-iter 92) (loop (- k 1))))))

;;;-----------------------------------------------------------------------------
;;; 3.  Takeuchi function -- classic recursive benchmark, no allocation.

(define (tak x y z)
  (if (not (< y x)) z
      (tak (tak (- x 1) y z)
           (tak (- y 1) z x)
           (tak (- z 1) x y))))

;;;-----------------------------------------------------------------------------
;;; 4.  List construction and traversal.

;;; iota is now a C++ native proc: (iota count start step) -- SRFI-1
;;; (iota n 1) produces (1 2 ... n), matching the old Scheme definition.
;;; list-sum and list-product are now C++ native procs.

;;;-----------------------------------------------------------------------------
;;; 5.  Quicksort -- in-place vector sort.  Hoare partition, middle pivot.
;;;     make-iota-vec(n) builds vector 1..n; qsort-vec! sorts in place.
;;;     Matches µPy benchmark: iota(200) = Python list (dynamic array, O(1) access).

(define (make-iota-vec n)
  (let ((v (make-vector n)))
    (let loop ((i 0))
      (if (< i n)                              ;;; `if`/`begin`, NOT `when`: `when` is a T_MACRO and
          (begin                               ;;; costs 2.8x in the AST tier -- see the sieve note
            (vector-set! v i (+ i 1))
            (loop (+ i 1)))))
    v))

(define (qsort-vec! v)
  (let qsort-h! ((lo 0) (hi (- (vector-length v) 1)))
    (if (< lo hi)                              ;;; `if`, NOT `when` -- T_MACRO costs 2.8x in AST
      (let ((pivot (vector-ref v (quotient (+ lo hi) 2))))
        (let part ((i lo) (j hi))
          (let lp-i ((i i))
            (if (and (<= i hi) (< (vector-ref v i) pivot)) (lp-i (+ i 1))
                (let lp-j ((j j))
                  (if (and (>= j lo) (> (vector-ref v j) pivot)) (lp-j (- j 1))
                      (if (<= i j)
                          (begin
                            (let ((t (vector-ref v i)))
                              (vector-set! v i (vector-ref v j))
                              (vector-set! v j t))
                            (part (+ i 1) (- j 1)))
                          (begin
                            (qsort-h! lo j)
                            (qsort-h! i hi)))))))))))
  v)

(define (vector-sum v)
  (let ((n (vector-length v)))
    (let loop ((i 0) (acc 0))
      (if (= i n) acc
          (loop (+ i 1) (+ acc (vector-ref v i)))))))

(define (vector-sorted? v)
  (let ((n (vector-length v)))
    (let loop ((i 1))
      (if (>= i n) #t
          (if (> (vector-ref v (- i 1)) (vector-ref v i)) #f
              (loop (+ i 1)))))))

;;;-----------------------------------------------------------------------------
;;; 6.  Closure allocation -- creates a new closure on every iteration.

(define (make-adder n) (lambda (x) (+ x n)))

(define (closure-bench n)
  (let loop ((i n) (acc 0))
    (if (= i 0) acc
        (loop (- i 1) ((make-adder i) acc)))))

;;;-----------------------------------------------------------------------------
;;; 7.  Ackermann -- deep recursion, stress-tests the call stack.
;;;     ack(3,6) = 509.  May be slow on ESP32; reduce to ack(3,4)=125 if needed.

(define (ackermann m n)
  (cond ((= m 0) (+ n 1))
        ((= n 0) (ackermann (- m 1) 1))
        (else    (ackermann (- m 1) (ackermann m (- n 1))))))

;;;-----------------------------------------------------------------------------
;;; 8.  Higher-order: map and apply over a list.

(define (map-bench n)
  (list-sum
    (map (lambda (x) (* x x))
         (iota n 1))))

;;;-----------------------------------------------------------------------------
;;; 9.  Sieve of Eratosthenes -- vector set!/ref under iteration.
;;;     Returns count of primes up to n.  sieve(500)=95, sieve(1000)=168.

#|! Micro-benchmarks that DECOMPOSE the fib-iter cost.  Added 2026-09-01.

  fib-iter(45) is 2.4x behind MicroPython and it was not clear WHERE the time goes.  Ad-hoc
  probes over the serial REPL kept producing confident wrong answers, because each one failed to
  control something: `(f 45)` is ~95% fixed cost (named-let closure rebuild + interpreter->NCG
  boundary), a "small values" control built with (- a b) turns out to grow as signed Fibonacci,
  and an in-cache variant carried an extra comparison.  These three run under the SAME protocol as
  every other published figure -- isolated boot, fixed window, verified value.

  All three share ONE loop shape and ONE op count.  Only the named variable changes:

    loop-call(4000)   counter only                      -> loop + call floor, no arithmetic
    loop-add-lo(4000) + one add, results stay <= 4000   -> arithmetic, NO allocation (sint_cache)
    loop-add-hi(4000) + one add, results reach 4e6      -> arithmetic, ONE BOX PER ITERATION

  sint_cache is [-2048, 4096] (LambLisp.h), so lo NEVER allocates and hi ALWAYS does.
    hi - lo  = the true cost of boxing one integer per iteration.
    lo - call = the cost of one int32 add that allocates nothing.
  Keep n=4000 below 4096 or lo starts boxing and the control silently dies -- the exact failure
  these exist to avoid.
|#

(define (loop-call n)
  (let l ((i n))
    (if (= i 0) 0 (l (- i 1)))))

(define (loop-add-lo n)                  ;;; results 0..n, all inside sint_cache -> no allocation
  (let l ((i n) (a 0))
    (if (= i 0) a (l (- i 1) (+ a 1)))))

(define (loop-add-hi n)                  ;;; results 0..1000n, outside sint_cache -> one box each
  (let l ((i n) (a 0))
    (if (= i 0) a (l (- i 1) (+ a 1000)))))

;;; USES `if`/`begin`, NOT `when` -- DELIBERATE, DO NOT "TIDY" IT BACK.  Fixed 2026-09-01.
;;; PERF TRAP -- `when` COSTS 2.8x IN THE AST TIER.  Measured 2026-09-01 on x86: this sieve
;;; ran 61,431 us with `when` and 22,073 us with `if`/`begin`, same answer (46 primes <= 200).
;;; `when` is a T_MACRO (rxrs_syntax.scm), so the AST interpreter calls macroexpand1 ->
;;; sr-dispatch to pattern-match and expand the template ON EVERY EVALUATION, here in the
;;; inner loop.  The BC/NCG tiers are UNAFFECTED -- the compiler expands it once, and BC is
;;; actually FASTER with `when` (86 us vs 113 us) because it inlines to
;;; BC_JUMP_IF_FALSE + body + BC_PUSH_NIL.  So the cost lands on exactly ONE row: the AST tier.
;;;
;;; WHY THAT MATTERS HERE: the AST row is what gets compared against other AST interpreters.
;;; TinyScheme writes its sieve with primitive `if`/`begin` and beats LL AST on the S3
;;; (385,800 us vs ~476,600, four TS runs varying by 0.009%).  Corrected for this macro cost
;;; LL AST would be ~171,000 us -- 2.25x FASTER than TS.  The measured result is a
;;; benchmark-authoring artifact, not interpreter quality.  Do not "fix" it by editing this
;;; file alone: changing the source changes what every historical AST number means.  Either
;;; keep it and annotate the AST row, or change it and RE-RUN the whole AST tier.  Changed and
;;; re-run on 2026-09-01, so AST sieve numbers BEFORE that date are not comparable to ones after.
;;;
;;; `qsort-vec!` and `make-iota-vec` above were changed the same way on the same date and in the
;;; same AST re-run, so the qsort(200) AST row moved too.  NOTHING in this file should use `when`,
;;; `unless` or `case` in a hot loop: they are all T_MACRO and all pay expansion per evaluation in
;;; the AST tier.  Use `if`/`begin`.
(define (sieve n)
  (let ((v (make-vector (+ n 1) #t)))
    (vector-set! v 0 #f)
    (vector-set! v 1 #f)
    (let outer ((i 2))
      (if (<= (* i i) n)
          (begin
            (if (vector-ref v i)
                (let inner ((j (* i i)))
                  (if (<= j n)
                      (begin
                        (vector-set! v j #f)
                        (inner (+ j i))))))
            (outer (+ i 1)))))
    (let count ((i 2) (acc 0))
      (if (> i n) acc
          (count (+ i 1) (if (vector-ref v i) (+ acc 1) acc))))))

;;;-----------------------------------------------------------------------------
;;; 10.  Fold-left -- tail-recursive list consumer, no allocation after iota.

(define (my-foldl f z ls)
  (let loop ((l ls) (acc z))
    (if (null? l) acc
        (loop (cdr l) (f acc (car l))))))

;;;-----------------------------------------------------------------------------
;;; 11.  Binary tree -- allocation stress + GC pressure.
;;;      make-tree(d) builds a balanced tree of depth d; tree-sum counts leaves.
;;;      make-tree(10)=1023 pairs; make-tree(12)=4095; make-tree(16)=65535.

(define (make-tree depth)
  (if (= depth 0) 1
      (cons (make-tree (- depth 1))
            (make-tree (- depth 1)))))

(define (tree-sum t)
  (if (pair? t)
      (+ (tree-sum (car t)) (tree-sum (cdr t)))
      t))

;;;-----------------------------------------------------------------------------
;;; 12.  Memoized Fibonacci -- vector indexed by n; O(1) direct access.
;;;      #f = uncomputed (sentinel); fib values are always non-negative integers
;;;      and therefore truthy in Scheme (even fib(0)=0 is truthy).
;;;      Size 36 covers both ESP32 fib-memo(25) and Linux fib-memo(35).
;;;      fib-memo(35)=9227465.

(define fib-memo-table (make-vector 36 #f))

(define (fib-memo-reset!) (set! fib-memo-table (make-vector 36 #f)))

(define (fib-memo n)
  (let ((cached (vector-ref fib-memo-table n)))
    (if cached
        cached
        (let ((result (if (< n 2) n
                          (+ (fib-memo (- n 1))
                             (fib-memo (- n 2))))))
          (vector-set! fib-memo-table n result)
          result))))

;;;-----------------------------------------------------------------------------
;;; 13.  mul-loop -- tight-loop throughput with a multiply in it, deliberately allocation-free.
;;;
;;;      Every intermediate stays inside LambLisp's small-int cache (-2048..4096), so no cell is
;;;      allocated and no GC work is charged: what is left is the loop, the compare, the decrement
;;;      and one multiply.
;;;
;;;      NAMED FOR WHAT IT MEASURES (renamed from `mul32` 2026-08-23).  It was built to show
;;;      LambLisp using the ESP32 multiply hardware, and it does NOT: measured on the S3 devkit,
;;;      NCG never emits MULL.  ll_vm_ncg_xtensa.cpp's INT32 fast path inlines ADD and SUB with an
;;;      overflow test but jumps unconditionally to the boxing shim for MUL, because detecting
;;;      32-bit multiply overflow needs the high word (MULSH) that the emitter does not produce.
;;;      The measured cost of that shim is small -- 0.75 us/iteration against 0.69 for the same
;;;      loop doing an add -- so what this benchmark really compares is LOOP AND DISPATCH
;;;      efficiency: LambLisp NCG at ~0.75 us/iteration against interpreters that walk their
;;;      evaluator per operation.  Do not cite it as evidence of hardware multiply use.
;;;      mul-loop(1000) = 2187, mul-loop(5000) = 27.

(define (mul-loop-bench n)
  (let loop ((i n) (a 3))
    (if (= i 0) a
        (loop (- i 1) (if (> a 1000) 3 (* a 3))))))

;;;-----------------------------------------------------------------------------
;;; 14.  wide-add -- arithmetic in [2^30, 2^31), the band where the runtimes DIVERGE.
;;;
;;;      LambLisp keeps the full 32-bit range in a T_INT32 cell.  MicroPython tags its small ints
;;;      with one bit, so on a 32-bit port anything at or above 2^30 = 1073741824 becomes a heap
;;;      mpz bignum -- every operand and every result in this loop.  uLisp has no bignum at all and
;;;      will WRAP (a wrong answer, not a slow one); TinyScheme's 64-bit longs cover it natively.
;;;      So this measures a REPRESENTATION difference, not interpreter speed.
;;;
;;;      NAMED FOR WHAT IT MEASURES (renamed from `int32-range` 2026-08-23).  LambLisp's advantage
;;;      here is real but SMALLER than the framing suggests, and the reason is ours: every value in
;;;      this band is outside the small-int cache, so LambLisp ALLOCATES a T_INT32 cell per result.
;;;      Measured on the S3: 6.73 us/iteration against 0.69 for the same loop inside the cache --
;;;      9x, with cells consumed going 919 -> 5919.  LambLisp still wins (45,498 us vs MicroPython's
;;;      67,067), but it wins while paying an allocation the competitor's tagged fixnums avoid
;;;      below 2^30.  The honest reading: a boxed-integer add benchmark that also traps narrow
;;;      fixnums, not a demonstration of free 32-bit arithmetic.
;;;      wide-add(1000) = 1086086827, wide-add(5000) = 1135466827.  Max int32 = 2147483647.

;;;-----------------------------------------------------------------------------
;;; 15.  bignum-mul -- ARBITRARY-PRECISION multiply on the ESP32 RSA/MPI ACCELERATOR.
;;;
;;;      Multiplies two 2048-bit integers, 200 times: 64 x 64 limbs = 4096 limb products.
;;;      2048 bits is the operand size of deployed public-key crypto -- RSA-2048 and the
;;;      RFC 3526 group-14 MODP prime that Diffie-Hellman uses -- so this is the size that
;;;      matters, not a size picked to flatter the peripheral.  It is also the largest pair
;;;      the hardware can take in one go: 2048 x 2048 gives a 4096-bit product, exactly the
;;;      MULT-mode window.
;;;      At that size Lamb::bignum_mul hands the operands to the chip's big-number peripheral via
;;;      mbedtls_mpi_mul_mpi -- CONFIG_MBEDTLS_HARDWARE_MPI=y makes that the hardware path
;;;      (esp_mpi_mul_mpi_hw_op), not the software one.
;;;
;;;      MEASURED, not assumed.  (bignum-hw! #f/#t) A/Bs both paths on ONE binary in ONE boot;
;;;      on an S3 devkit, 400 multiplies per point, both paths returning identical values:
;;;          1024 products 0.97x | 1600 1.10x | 2304 1.22x | 3136 1.34x | 4096 1.48x
;;;      So the size here is chosen because it is where the accelerator actually wins, and the
;;;      threshold in bn_mul_hw (1600 products) is the first measured point that does.  A smaller
;;;      operand would quietly run the software loop and demonstrate nothing.
;;;
;;;      What the competitors do: uLisp (32-bit ints), LispBM (28-bit fixnums) and TinyScheme
;;;      (64-bit longs) have NO arbitrary precision -- they wrap and return a wrong answer, which
;;;      the harness reports as FAIL rather than as a fast time.  Chibi and MicroPython carry real
;;;      software bignums and compete honestly, with no hardware path available to them.
;;;      Operands are built by repeated multiplication rather than expt so the runtimes without
;;;      bignums wrap instead of erroring, and so cannot take the rest of the leg down with them.
;;;      bignum-mul(200) = 737829950, being (3^1292 * 7^729) mod 1000000007.

(define (bigpow base k)                 ;; repeated multiply, NOT expt: see note above
  (let loop ((i k) (a 1)) (if (= i 0) a (loop (- i 1) (* a base)))))
(define bignum-a (bigpow 3 1292))       ;; EXACTLY 2048 bits, 64 limbs -- DH/RSA-2048 operand size
(define bignum-b (bigpow 7  729))       ;; 2047 bits, 64 limbs: product 4095 bits, just inside the
                                        ;; accelerator's 4096-bit MULT window (2050 bits would not fit)

(define (bignum-mul-bench n)
  (let loop ((i n) (last 1))
    (if (= i 0) (remainder last 1000000007)
        (loop (- i 1) (* bignum-a bignum-b)))))

(define (wide-add-bench n)
  (let loop ((i n) (a 1073741827))
    (if (= i 0) a
        (loop (- i 1) (if (> a 2000000000) 1073741827 (+ a 12345))))))

;;;-----------------------------------------------------------------------------
;;; Run suite

(define (run-benchmarks)
  (display "=== Scheme Benchmarks ===") (newline)
  (bench "tak                  (18 12 6)"       (lambda () (tak 18 12 6))              7)
  (bench "list iota+sum        n=10000"         (lambda () (list-sum (iota 10000 1))) 50005000)
  (bench "qsort-vec sum        n=200"           (lambda () (vector-sum (qsort-vec! (make-iota-vec 200)))) 20100)
  (bench "closure make-adder   n=10000"         (lambda () (closure-bench 10000)) 50005000)
  (bench "map x^2 sum          n=500"           (lambda () (map-bench 500))       41791750)
  (display "=== Done ===") (newline))

;;(run-benchmarks)  ; suppressed -- bench-runner.scm calls run-suite directly
