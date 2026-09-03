;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; bytecode compiler test suite
;;;
;;; Tests procedure->bytecode, bytecode?, and correct execution of
;;; all bytecode instructions emitted by the compiler.
;;;
;;; Load with: (load "bytecode-tests.scm" 1)
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

;;; Compile a lambda and call it -- the canonical pattern for all tests.
(define (bc-compile-and-call proc . args)
  (apply (procedure->bytecode proc) args))


;;; -----------------------------------------------------------------------
;;; 1. bytecode? predicate
;;; -----------------------------------------------------------------------

(printf "--- 1. bytecode? predicate ---\n")

(define bc-add1 (procedure->bytecode (lambda (x) (+ x 1))))

(check-true  "bytecode? T_BYTECODE"       (bytecode? bc-add1))
(check-false "bytecode? lambda"           (bytecode? (lambda (x) x)))
(check-false "bytecode? integer"          (bytecode? 42))
(check-false "bytecode? boolean"          (bytecode? #t))
(check-false "bytecode? nil"              (bytecode? '()))
(check-false "bytecode? native proc +"   (bytecode? +))

;;; Variadic lambdas compile correctly (B14 fixed 2026-05-19).
(let ((p (lambda (x . rest) x)))
  (check-true "variadic proc compiled"     (bytecode? (procedure->bytecode p))))
(check "variadic fixed-arg"   1      ((procedure->bytecode (lambda (x . rest) x)) 1 2 3))
(check "variadic rest-arg"    '(2 3) ((procedure->bytecode (lambda (x . rest) rest)) 1 2 3))
(check "variadic rest-empty"  '()    ((procedure->bytecode (lambda (x . rest) rest)) 1))
(check "variadic bare-symbol" '(1 2) ((procedure->bytecode (lambda args args)) 1 2))


;;; -----------------------------------------------------------------------
;;; 2. Constants: LOAD_CONST, PUSH_NIL
;;; -----------------------------------------------------------------------

(printf "--- 2. constants ---\n")

(define bc-ret-42   (procedure->bytecode (lambda () 42)))
(define bc-ret-t    (procedure->bytecode (lambda () #t)))
(define bc-ret-f    (procedure->bytecode (lambda () #f)))
(define bc-ret-nil  (procedure->bytecode (lambda () '())))
(define bc-ret-str  (procedure->bytecode (lambda () "hello")))
(define bc-ret-sym  (procedure->bytecode (lambda () 'foo)))

(check "const 42"     42      (bc-ret-42))
(check "const #t"     #t      (bc-ret-t))
(check "const #f"     #f      (bc-ret-f))
(check "const nil"    '()     (bc-ret-nil))
(check "const string" "hello" (bc-ret-str))
(check "const symbol" 'foo    (bc-ret-sym))


;;; -----------------------------------------------------------------------
;;; 3. Local variables: LOAD_LOCAL, STORE_LOCAL
;;; -----------------------------------------------------------------------

(printf "--- 3. locals ---\n")

(define bc-identity (procedure->bytecode (lambda (x) x)))
(define bc-swap     (procedure->bytecode (lambda (a b) (list b a))))
(define bc-3args    (procedure->bytecode (lambda (a b c) (+ a (* b c)))))

(check "identity 7"    7         (bc-identity 7))
(check "identity #f"   #f        (bc-identity #f))
(check "swap"          '(2 1)    (bc-swap 1 2))
(check "3 args arith"  7         (bc-3args 1 2 3))

;;; set! of local via STORE_LOCAL
(define bc-local-set!
  (procedure->bytecode
   (lambda (x)
     (set! x (* x 2))
     x)))

(check "local set! double"  8   (bc-local-set! 4))
(check "local set! zero"    0   (bc-local-set! 0))


;;; -----------------------------------------------------------------------
;;; 4. Global variables: LOAD_GLOBAL, STORE_GLOBAL
;;; -----------------------------------------------------------------------

(printf "--- 4. globals ---\n")

(define bc-test-global 100)

(define bc-read-global
  (procedure->bytecode (lambda () bc-test-global)))

(define bc-write-global
  (procedure->bytecode
   (lambda (v)
     (set! bc-test-global v))))

(check "read global"   100   (bc-read-global))
(bc-write-global 999)
(check "write global"  999   bc-test-global)
(bc-write-global 100)

;;; Global function call via LOAD_GLOBAL + CALL
(define bc-call-global
  (procedure->bytecode (lambda (x) (car x))))

(check "call car via global"  1  (bc-call-global '(1 2 3)))


;;; -----------------------------------------------------------------------
;;; 5. Function calls: CALL, BC_PUSH_NIL, BC_POP
;;; -----------------------------------------------------------------------

(printf "--- 5. function calls ---\n")

(define bc-add     (procedure->bytecode (lambda (a b) (+ a b))))
(define bc-mul     (procedure->bytecode (lambda (a b) (* a b))))
(define bc-sub     (procedure->bytecode (lambda (a b) (- a b))))
(define bc-cons-ab (procedure->bytecode (lambda (a b) (cons a b))))

(check "add 3 4"    7    (bc-add 3 4))
(check "mul 6 7"    42   (bc-mul 6 7))
(check "sub 10 3"   7    (bc-sub 10 3))
(check "cons"       '(1 . 2)  (bc-cons-ab 1 2))

;;; Nested calls
(define bc-nested
  (procedure->bytecode (lambda (x) (+ (* x x) 1))))

(check "nested call x^2+1  3"   10  (bc-nested 3))
(check "nested call x^2+1  5"   26  (bc-nested 5))

;;; begin (sequences of expressions, BC_POP for non-last)
(define bc-begin-seq
  (procedure->bytecode
   (lambda (x)
     (+ x 1)
     (+ x 2)
     (+ x 3))))

(check "begin last value"   13  (bc-begin-seq 10))


;;; -----------------------------------------------------------------------
;;; 6. Conditionals: if, JUMP_IF_FALSE, JUMP
;;; -----------------------------------------------------------------------

(printf "--- 6. conditionals ---\n")

(define bc-abs
  (procedure->bytecode
   (lambda (x)
     (if (< x 0) (- x) x))))

(check "abs -5"    5   (bc-abs -5))
(check "abs  5"    5   (bc-abs  5))
(check "abs  0"    0   (bc-abs  0))

;;; if with no else returns the UNSPECIFIED value when false, not NIL.
;;; B192 (in master 5848a0f) made one-armed `if`, `when`, `unless` and unmatched `cond` all
;;; return OBJ_VOID on every tier; `(if #f #f)` is how Scheme source names that value.  This
;;; expectation said '() until B232 -- it had been failing on every run since B192 landed.
(define bc-if-no-else
  (procedure->bytecode
   (lambda (x)
     (if (> x 0) 'pos))))

(check "if no-else true"   'pos   (bc-if-no-else 1))
(check "if no-else false"  (if #f #f) (bc-if-no-else -1))

;;; nested if
(define bc-sign
  (procedure->bytecode
   (lambda (x)
     (if (> x 0) 1
         (if (< x 0) -1 0)))))

(check "sign  3"    1   (bc-sign  3))
(check "sign -3"   -1   (bc-sign -3))
(check "sign  0"    0   (bc-sign  0))


;;; -----------------------------------------------------------------------
;;; 7. and / or short-circuit
;;; -----------------------------------------------------------------------

(printf "--- 7. and / or ---\n")

(define bc-and2
  (procedure->bytecode (lambda (a b) (and a b))))

(define bc-or2
  (procedure->bytecode (lambda (a b) (or a b))))

(check "and #t #t"   #t   (bc-and2 #t #t))
(check "and #f #t"   #f   (bc-and2 #f #t))
(check "and #t #f"   #f   (bc-and2 #t #f))
(check "and #f #f"   #f   (bc-and2 #f #f))

;;; and returns last value when all truthy
(check "and 1 2"     2    (bc-and2 1 2))
;;; and returns first false
(check "and #f 2"    #f   (bc-and2 #f 2))

(check "or  #t #t"   #t   (bc-or2 #t #t))
(check "or  #f #t"   #t   (bc-or2 #f #t))
(check "or  #t #f"   #t   (bc-or2 #t #f))
(check "or  #f #f"   #f   (bc-or2 #f #f))

;;; or returns first truthy value
(check "or  1  2"    1    (bc-or2 1 2))
(check "or  #f 5"    5    (bc-or2 #f 5))

;;; (and) = #t, (or) = #f
(define bc-and0 (procedure->bytecode (lambda () (and))))
(define bc-or0  (procedure->bytecode (lambda () (or))))

(check "and empty"   #t   (bc-and0))
(check "or  empty"   #f   (bc-or0))


;;; -----------------------------------------------------------------------
;;; 8. cond
;;; -----------------------------------------------------------------------

(printf "--- 8. cond ---\n")

(define bc-cond-classify
  (procedure->bytecode
   (lambda (x)
     (cond ((< x 0)  'negative)
           ((= x 0)  'zero)
           ((> x 0)  'positive)))))

(check "cond neg"   'negative   (bc-cond-classify -1))
(check "cond zero"  'zero       (bc-cond-classify  0))
(check "cond pos"   'positive   (bc-cond-classify  1))

(define bc-cond-else
  (procedure->bytecode
   (lambda (x)
     (cond ((= x 1) 'one)
           ((= x 2) 'two)
           (else     'other)))))

(check "cond 1"      'one    (bc-cond-else 1))
(check "cond 2"      'two    (bc-cond-else 2))
(check "cond other"  'other  (bc-cond-else 99))


;;; -----------------------------------------------------------------------
;;; 9. let
;;; -----------------------------------------------------------------------

(printf "--- 9. let ---\n")

(define bc-let1
  (procedure->bytecode
   (lambda (x)
     (let ((y (* x 2)))
       (+ y 1)))))

(check "let simple"   9   (bc-let1 4))

(define bc-let2
  (procedure->bytecode
   (lambda (a b)
     (let ((sum (+ a b))
           (prod (* a b)))
       (- sum prod)))))

;;; let binds simultaneously: sum=5, prod=6, result=-1
(check "let simultaneous"  -1   (bc-let2 2 3))

;;; Nested let
(define bc-let-nested
  (procedure->bytecode
   (lambda (x)
     (let ((a (+ x 1)))
       (let ((b (+ a 1)))
         (* a b))))))

(check "let nested 5"   42   (bc-let-nested 5))   ;; a=6, b=7, 6*7=42


;;; -----------------------------------------------------------------------
;;; 10. let*
;;; -----------------------------------------------------------------------

(printf "--- 10. let* ---\n")

(define bc-letstar
  (procedure->bytecode
   (lambda (x)
     (let* ((a (+ x 1))
            (b (* a 2))
            (c (+ a b)))
       c))))

;;; x=3: a=4, b=8, c=12
(check "let* chain"   12   (bc-letstar 3))

(define bc-letstar-shadow
  (procedure->bytecode
   (lambda (x)
     (let* ((x (+ x 1))
            (x (* x x)))
       x))))

;;; x=3 -> x=4 -> x=16
(check "let* shadow"   16   (bc-letstar-shadow 3))


;;; -----------------------------------------------------------------------
;;; 11. Internal defines (letrec* semantics in begin)
;;; -----------------------------------------------------------------------

(printf "--- 11. internal defines ---\n")

(define bc-internal-def
  (procedure->bytecode
   (lambda (x)
     (define y (* x 2))
     (define z (+ y 1))
     z)))

(check "internal define"   11   (bc-internal-def 5))


;;; -----------------------------------------------------------------------
;;; 12. Named let (loop)
;;; -----------------------------------------------------------------------

(printf "--- 12. named let ---\n")

(define bc-sum-to-n
  (procedure->bytecode
   (lambda (n)
     (let loop ((i n) (acc 0))
       (if (= i 0)
           acc
           (loop (- i 1) (+ acc i)))))))

(check "named-let sum 0"    0     (bc-sum-to-n 0))
(check "named-let sum 5"   15     (bc-sum-to-n 5))
(check "named-let sum 10"  55     (bc-sum-to-n 10))

(define bc-list-rev
  (procedure->bytecode
   (lambda (lst)
     (let loop ((l lst) (acc '()))
       (if (null? l)
           acc
           (loop (cdr l) (cons (car l) acc)))))))

(check "named-let reverse"   '(3 2 1)   (bc-list-rev '(1 2 3)))
(check "named-let reverse nil"  '()     (bc-list-rev '()))

;;; Named let with multiple iterations -- fibonacci
(define bc-fib-loop
  (procedure->bytecode
   (lambda (n)
     (let loop ((i n) (a 0) (b 1))
       (if (= i 0)
           a
           (loop (- i 1) b (+ a b)))))))

(check "fib-loop 0"    0   (bc-fib-loop  0))
(check "fib-loop 1"    1   (bc-fib-loop  1))
(check "fib-loop 7"   13   (bc-fib-loop  7))
(check "fib-loop 10"  55   (bc-fib-loop 10))


;;; -----------------------------------------------------------------------
;;; 13. Global (non-self) tail call
;;; -----------------------------------------------------------------------

(printf "--- 13. global tail call ---\n")

;;; Compile a function that tail-calls another bytecode function.
(define bc-helper (procedure->bytecode (lambda (x) (* x 10))))

(define bc-tail-global
  (procedure->bytecode (lambda (x) (bc-helper (+ x 1)))))

(check "global tail call 4"   50   (bc-tail-global 4))
(check "global tail call 0"   10   (bc-tail-global 0))


;;; -----------------------------------------------------------------------
;;; 14. Recursive (non-named-let) functions via globals
;;; -----------------------------------------------------------------------

(printf "--- 14. recursion via globals ---\n")

;;; Mutually recursive functions are compiled as global calls,
;;; so each recursive call goes through the global lookup at runtime.
(define bc-fact
  (procedure->bytecode
   (lambda (n)
     (if (= n 0)
         1
         (* n (bc-fact (- n 1)))))))

(check "bc-fact 0"    1     (bc-fact 0))
(check "bc-fact 5"  120     (bc-fact 5))

(define bc-even?
  (procedure->bytecode
   (lambda (n)
     (if (= n 0) #t (bc-odd? (- n 1))))))

(define bc-odd?
  (procedure->bytecode
   (lambda (n)
     (if (= n 0) #f (bc-even? (- n 1))))))

(check "bc-even? 4"  #t   (bc-even? 4))
(check "bc-even? 5"  #f   (bc-even? 5))
(check "bc-odd?  5"  #t   (bc-odd?  5))
(check "bc-odd?  4"  #f   (bc-odd?  4))


;;; -----------------------------------------------------------------------
;;; 15. quote
;;; -----------------------------------------------------------------------

(printf "--- 15. quote ---\n")

(define bc-quoted-list
  (procedure->bytecode (lambda () '(1 2 3))))

(define bc-quoted-sym
  (procedure->bytecode (lambda () 'hello)))

(check "quoted list"   '(1 2 3)   (bc-quoted-list))
(check "quoted sym"    'hello     (bc-quoted-sym))


;;; -----------------------------------------------------------------------
;;; 16. Closures capturing globals
;;; -----------------------------------------------------------------------

(printf "--- 16. closures / globals capture ---\n")

;;; A bytecode proc closes over its definition environment; globals
;;; added after compilation should still be visible via LOAD_GLOBAL.
(define bc-scale-factor 3)

(define bc-scaled
  (procedure->bytecode (lambda (x) (* x bc-scale-factor))))

(check "scale by global 3"   15   (bc-scaled 5))

(set! bc-scale-factor 10)
(check "scale after set! 10"  50   (bc-scaled 5))

(set! bc-scale-factor 3)


;;; -----------------------------------------------------------------------
;;; 17. bytecode-disasm returns a list
;;; -----------------------------------------------------------------------

(printf "--- 17. bytecode-disasm ---\n")

(define disasm-result (bytecode-disasm bc-add1))

(check-true "disasm is pair" (pair? disasm-result))

;;; The disasm of (lambda (x) (+ x 1)) should have LOAD_LOCAL, LOAD_CONST,
;;; a CALL or similar, and RETURN.
(define (disasm-contains? disasm opname)
  (let loop ((l disasm))
    (if (null? l) #f
        (if (and (pair? (car l)) (eq? (caar l) opname))
            #t
            (loop (cdr l))))))

(check-true  "disasm has RETURN"     (disasm-contains? disasm-result 'RETURN))
(check-true  "disasm has LOAD_LOCAL" (disasm-contains? disasm-result 'LOAD_LOCAL))


;;; -----------------------------------------------------------------------
;;; 18. Boundary / edge cases
;;; -----------------------------------------------------------------------

(printf "--- 18. edge cases ---\n")

;;; Empty begin in body (body with only defines)
(define bc-only-defines
  (procedure->bytecode
   (lambda ()
     (define x 42)
     x)))

(check "body only define"  42  (bc-only-defines))

;;; Multiple values in set! across calls
(define bc-counter-state 0)

(define bc-counter-bump!
  (procedure->bytecode
   (lambda ()
     (set! bc-counter-state (+ bc-counter-state 1))
     bc-counter-state)))

(check "counter bump 1"  1   (bc-counter-bump!))
(check "counter bump 2"  2   (bc-counter-bump!))
(check "counter bump 3"  3   (bc-counter-bump!))

;;; Large constant values (tests correct constant pool indexing)
(define bc-many-consts
  (procedure->bytecode
   (lambda () (+ 1 2 3 4 5))))

;;; (+ 1 2 3 4 5) compiles as nested calls; result = 15
(check "many consts"   15  (bc-many-consts))


;;; -----------------------------------------------------------------------
;;; 19. Phase 7 -- inner lambda / BC_MAKE_CLOSURE
;;; -----------------------------------------------------------------------

(printf "--- 19. Phase 7 closures ---\n")

;;; make-adder: outer local n is captured in inner lambda.
(define bc-make-adder
  (procedure->bytecode
   (lambda (n)
     (lambda (x) (+ x n)))))

(check-true  "bc-make-adder bytecode?"  (bytecode? bc-make-adder))

(define bc-add5  (bc-make-adder 5))
(define bc-add7  (bc-make-adder 7))

;;; Each closure is independent.
(check "add5 3"   8   (bc-add5 3))
(check "add5 10"  15  (bc-add5 10))
(check "add7 3"   10  (bc-add7 3))
(check "add5 unchanged"  8  (bc-add5 3))

;;; Inner result is a T_BYTECODE (compiled closure, not a T_PROC).
(check-true  "add5 bytecode?"  (bytecode? bc-add5))

;;; Multiple captured locals.
(define bc-adder-mult
  (procedure->bytecode
   (lambda (a b)
     (lambda (x) (+ x a b)))))

(check "two captures"  15  ((bc-adder-mult 3 7) 5))
(check "two captures"  12  ((bc-adder-mult 2 5) 5))

;;; Inner lambda with no outer locals (ncap=0 path).
(define bc-always-42
  (procedure->bytecode
   (lambda ()
     (lambda () 42))))

(check "no capture"  42  ((bc-always-42)))

;;; Tail call inside inner lambda.
(define bc-tail-inner
  (procedure->bytecode
   (lambda (n)
     (lambda (acc)
       (if (= n 0) acc
           ((bc-tail-inner (- n 1)) (+ acc 1)))))))

(check "tail inner"  5  ((bc-tail-inner 5) 0))

;;; Disasm of outer contains MAKE_CLOSURE.
(define disasm-adder (bytecode-disasm bc-make-adder))
(define (disasm-has-op? disasm opname)
  (let loop ((l disasm))
    (cond ((null? l) #f)
          ((and (pair? (car l)) (eq? (caar l) opname)) #t)
          (else (loop (cdr l))))))

(check-true  "outer has MAKE_CLOSURE"  (disasm-has-op? disasm-adder 'MAKE_CLOSURE))

;;; Quasiquote BC compilation (quasiquote is expanded at compile time into cons/list/append/quote).
(let ((x 7))
  (check "qq atom"          7            ((procedure->bytecode (lambda (x) `7)) x))
  (check "qq sym"           'a           ((procedure->bytecode (lambda (x) `a)) x))
  (check "qq unquote"       7            ((procedure->bytecode (lambda (x) `,x)) x))
  (check "qq list"          '(a b)       ((procedure->bytecode (lambda (x) `(a b))) x))
  (check "qq list unquote"  '(a 7 b)    ((procedure->bytecode (lambda (x) `(a ,x b))) x))
  (check "qq nested"        '(a (b 7))  ((procedure->bytecode (lambda (x) `(a (b ,x)))) x))
  (let ((xs '(1 2 3)))
    (check "qq splice"  '(a 1 2 3 b)  ((procedure->bytecode (lambda (xs) `(a ,@xs b))) xs))))

(printf "--- done ---\n")
