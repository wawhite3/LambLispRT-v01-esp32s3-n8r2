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

(printf "--- done ---\n")
