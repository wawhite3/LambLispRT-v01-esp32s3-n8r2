;;; Copyright 2026 by Frobenius Norm LLC 2026-08-29 16:40:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; r7rs-tests-srfi64.scm -- R7RS-small conformance suite, written against SRFI-64.
;;;
;;; Run on LambLisp: (load "ll_tests/r7rs-tests-srfi64.scm" 0)
;;; Run on Chez:     (load "chez-r6-to-r7.scm") then this file
;;;
;;; RELATION TO r7rs-tests.scm.  This is the SAME suite in the PORTABLE test vocabulary.  Every
;;; assertion from r7rs-tests.scm is here, mechanically converted:
;;;     check        -> test-equal        check-error     -> test-error   (thunk unwrapped:
;;;     check-true   -> test-assert                                        SRFI-64 takes an
;;;     check-false  -> test-equal ... #f                                  EXPRESSION, not a thunk)
;;;     check-guard  -> test-equal        check-exception -> test-exception
;;; The conversion was verified BEHAVIOUR-NEUTRAL before anything was added: the converted suite
;;; alone scores 876 passed / 0 failed / 24 exception, identical to r7rs-tests.scm.  A final
;;; section then adds cases ported from chibi-scheme's tests/r7rs-tests.scm.
;;;
;;; WHY BOTH SUITES EXIST.  A self-hosted suite cannot validate itself: the same codebase is both
;;; the implementation under test AND the arbiter of the right answer, so a MISREADING of R7RS
;;; passes silently.  Written in SRFI-64, this file also runs on Chez, Guile and chibi, where a
;;; misreading shows up as a disagreement instead of a green run.
;;;
;;; That is not a hypothetical.  Porting one chibi section -- roughly 60 assertions -- turned up
;;; SEVEN defects that had survived 900 home-grown assertions.  Six are FIXED (2026-08-29); the
;;; tests below hold them fixed:
;;;   B171  FIXED -- reader mishandles numeric prefixes: #x-1f reads as 0, #e1e10 reads as 1, #X1f raises
;;;   B172  FIXED -- string->number returns #f for +inf.0/-inf.0/+nan.0; infnan is case-sensitive
;;;   B174  FIXED -- #e on a decimal or exponent does not produce an exact number
;;;   B175  FIXED -- SEGFAULT: an unterminated string literal crashes the reader
;;;   B176  FIXED -- write does not bar |+i| / |+inf.0| / |+nan.0|, so write->read turns them into numbers
;;;   B177  FIXED -- define-values rejects (), (a . r) and a symbol formal with an internal VM error
;;;   B179  OPEN  -- syntax-rules custom-ellipsis form unimplemented (raises an internal VM
;;;               error).  Its one test below is the only expected failure in this file.
;;; Every one of them lived in the gap between two things our own suite tested SEPARATELY and never
;;; tested AGAINST EACH OTHER -- `string->number' versus the reader, `write' versus `read'.  An
;;; outside suite looked at the seam because it had no idea where our seams were.
;;;
;;; The B179 test FAILS, on purpose, and must keep failing until that bug is fixed.  Per the bug
;;; registry policy nothing here is skipped or marked expected-to-fail.
;;;
;;; The framework lives in ll_tests/srfi64.scm; read its header for which SRFI-64 features are
;;; deliberately absent (dynamic-wind, runner objects, test-expect-fail) and why.

(load "ll_tests/srfi64.scm")

;;; -----------------------------------------------------------------------
;;; R7RS 4.1  Primitive expression types
;;; -----------------------------------------------------------------------

(news "\n--- 4.1.2 quote ---\n")
(test-equal "quote/sym"    'foo          'foo)
(test-equal "quote/list"   '(1 2 3)      '(1 2 3))
(test-equal "quote/nested" '(a (b c) d)  '(a (b c) d))
(test-equal "quote/nil"    '()           '())
(test-equal "quote/bool"   #t            '#t)
(test-equal "quote/num"    42            '42)
(test-equal "quote/str"    "hi"          "hi")

(news "--- 4.1.4 lambda ---\n")
(test-equal "lambda/call"       6   ((lambda (x y) (* x y)) 2 3))
(test-equal "lambda/rest"       '(2 3 4) ((lambda (x . rest) rest) 1 2 3 4))
(test-equal "lambda/rest-all"   '(1 2 3) ((lambda args args) 1 2 3))
(test-equal "lambda/closure"    10  (let ((x 3)) ((lambda (y) (+ x y)) 7)))
(test-equal "lambda/multi-body" 3  ((lambda (x) (+ x 1) (+ x 2)) 1))

(news "--- 4.1.5 if ---\n")
(test-equal "if/true"          1    (if #t 1 2))
(test-equal "if/false"         2    (if #f 1 2))
(test-equal "if/truthy-0"      1    (if 0 1 2))
(test-equal "if/truthy-nil"    1    (if '() 1 2))
(test-equal "if/no-else"       'ok  (if #t 'ok))
(test-equal "if/false-no-else" 'ok  (begin (if #f (error "bad")) 'ok))

(news "--- 4.1.6 set! ---\n")
(test-equal "set!"         20  (let ((x 10)) (set! x 20) x))
(test-equal "set!/closure" 99  (let ((x 1))
                                 (define (f) x)
                                 (set! x 99)
                                 (f)))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2  Derived expression types
;;; -----------------------------------------------------------------------

(news "\n--- 4.2.1 cond ---\n")
(test-equal "cond/first"      'a  (cond (#t 'a) (else 'b)))
(test-equal "cond/second"     'b  (cond (#f 'a) (#t 'b) (else 'c)))
(test-equal "cond/else"       'c  (cond (#f 'a) (#f 'b) (else 'c)))
(test-equal "cond/no-else"    'ok (begin (cond (#t 'ok)) 'ok))
(test-equal "cond/multi-expr" 3   (cond (#t 1 2 3)))
(test-equal "cond/=>"         8   (cond (4 => (lambda (x) (* x 2)))))
(test-equal "cond/=>-false"   'b  (cond (#f => (lambda (x) 'a)) (else 'b)))
(test-equal "cond/value"      5   (cond (5)))

(news "--- 4.2.1 case ---\n")
(test-equal "case/first"       'a  (case 1 ((1) 'a) ((2) 'b) (else 'c)))
(test-equal "case/second"      'b  (case 2 ((1) 'a) ((2) 'b) (else 'c)))
(test-equal "case/else"        'c  (case 9 ((1) 'a) ((2) 'b) (else 'c)))
(test-equal "case/multi-datum" 'ab (case 2 ((1 3) 'odd) ((2 4) 'ab) (else 'other)))
(test-equal "case/char"        'y  (case #\b ((#\a) 'x) ((#\b) 'y) (else 'z)))
(test-equal "case/multi-body"  3   (case 1 ((1) 1 2 3) (else 0)))

(news "--- 4.2.1 when / unless ---\n")
(test-equal "when/true"    3    (when #t 1 2 3))
(test-equal "when/false"   'ok  (begin (when #f (error "bad")) 'ok))
(test-equal "unless/false" 3    (unless #f 1 2 3))
(test-equal "unless/true"  'ok  (begin (unless #t (error "bad")) 'ok))

(news "--- 4.2.1 and / or ---\n")
(test-equal "and/empty"     #t   (and))
(test-equal "and/single"    5    (and 5))
(test-equal "and/true"      3    (and 1 2 3))
(test-equal "and/short"     #f   (and 1 #f 3))
(test-equal "and/value"     #f   (and #f))
(test-equal "or/empty"      #f   (or))
(test-equal "or/single"     5    (or 5))
(test-equal "or/first"      1    (or 1 2 3))
(test-equal "or/skip-false" 2    (or #f 2 3))
(test-equal "or/all-false"  #f   (or #f #f #f))
(test-equal "or/value"      0    (or #f 0))

(news "--- 4.2.2 let ---\n")
(test-equal "let/basic"     3    (let ((x 1) (y 2)) (+ x y)))
(test-equal "let/body-seq"  6    (let ((x 2)) (define y 3) (* x y)))
(test-equal "let/shadow"    10   (let ((x 5)) (let ((x (* x 2))) x)))
(test-equal "let*/basic"    6    (let* ((x 1) (y (+ x 2)) (z (* y 2))) z))
(test-equal "let*/depends"  3    (let* ((x 1) (x (+ x 1)) (x (+ x 1))) x))
(test-equal "letrec/mutual" #t
  (letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
           (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
    (even? 10)))
(test-equal "letrec*/order" 3    (letrec* ((x 1) (y (+ x 2)) (z (* x y))) z))
(test-equal "named-let/fib" 55   (let fib ((n 10) (a 0) (b 1))
                                  (if (= n 0) a (fib (- n 1) b (+ a b)))))
(test-equal "named-let/sum" 15   (let loop ((i 5) (acc 0))
                                  (if (= i 0) acc (loop (- i 1) (+ acc i)))))

(news "--- 4.2.2 let-values ---\n")
(test-equal "let-values/2" 3    (let-values (((a b) (values 1 2))) (+ a b)))
(test-equal "let-values/3" 6    (let-values (((a b c) (values 1 2 3))) (+ a b c)))

(news "--- 4.2.3 begin ---\n")
(test-equal "begin/seq"    3    (begin 1 2 3))
(test-equal "begin/effect" 2    (let ((x 0)) (begin (set! x 1) (set! x 2)) x))

(news "--- 4.2.4 do ---\n")
(test-equal "do/sum" 10   (do ((i 0 (+ i 1)) (s 0 (+ s i)))
                                   ((= i 5) s)))
(test-equal "do/vector" '#(0 1 2 3 4)
  (let ((v (make-vector 5)))
    (do ((i 0 (+ i 1))) ((= i 5) v) (vector-set! v i i))))
(test-equal "do/no-body" 120  (do ((n 5 (- n 1)) (p 1 (* p n)))
                                   ((= n 0) p)))
(test-equal "do/string-build" "abcde"
  (let ((s (make-string 5 #\a)))
    (do ((i 0 (+ i 1)))
      ((= i 5) s)
      (string-set! s i (integer->char (+ (char->integer #\a) i))))))

(news "--- 4.2.5 delay / force ---\n")
(define p1 (delay (+ 1 2)))
(test-assert "promise?/delay" (promise? p1))
(test-equal "promise?/non"    #f (promise? 42))
(test-equal "force/value"     3      (force p1))
(test-equal "force/memoized"  3      (force p1))

(define *side* 0)
(define p-side (delay (begin (set! *side* (+ *side* 1)) *side*)))
(force p-side)
(force p-side)
(test-equal "force/once" 1      *side*)

(test-equal "make-promise/val" 42     (force (make-promise 42)))
(test-assert "make-promise/id" (let ((p (delay 1))) (eq? p (make-promise p))))

(define (lazy-from n) (delay-force (cons n (lazy-from (+ n 1)))))
(define (stream-ref s n)
  (let ((p (force s)))
    (if (= n 0) (car p) (stream-ref (cdr p) (- n 1)))))
(test-equal "delay-force/0"  0      (stream-ref (lazy-from 0) 0))
(test-equal "delay-force/10" 10     (stream-ref (lazy-from 0) 10))
(test-equal "delay-force/50" 50     (stream-ref (lazy-from 0) 50))

(news "--- 4.2.7 guard ---\n")
(test-equal "guard/match"     42     (guard (e ((equal? e 42) e)) (raise 42)))
(test-equal "guard/else"      'def   (guard (e ((equal? e 1) 'one) (else 'def)) (raise 99)))
(test-equal "guard/no-raise"  'ok    (guard (e (else 'caught)) 'ok))
(test-equal "guard/error-obj" "msg"  (guard (e ((error-object? e) (error-object-message e)))
                                    (error "msg" 1 2)))
;;; guard/reraise: R7RS allows with-exception-handler to return from raise.
;;; Chez (R6RS) treats raise as non-continuable -- handler must not return.
;;; Skip on Chez.
(when (not chez-scheme?)
  (test-equal "guard/reraise" 99
    (with-exception-handler
      (lambda (e) e)
      (lambda ()
        (guard (e ((equal? e 42) 'got-42))
          (raise 99))))))

(news "--- 4.2.8 quasiquote ---\n")
(test-equal "quasi/basic"     '(1 2 3)       `(1 2 3))
(test-equal "quasi/unquote"   '(1 99 3)      `(1 ,(+ 90 9) 3))
(test-equal "quasi/splicing"  '(1 2 3 4 5)   `(1 ,@(list 2 3 4) 5))
(test-equal "quasi/nested-1"  '(1 (2 3) 4)   `(1 (,(+ 1 1) 3) 4))
(test-equal "quasi/empty-spl" '(1 2)         `(1 ,@'() 2))
(test-equal "quasi/computed"  '(a 6 b)       (let ((x 6)) `(a ,x b)))
(test-equal "quasi/list-spl"  '(0 1 2 3 4)   `(0 ,@(list 1 2 3) 4))

(news "--- 4.2.9 case-lambda ---\n")
(define cl
  (case-lambda
    (()        'zero)
    ((x)       (list 'one x))
    ((x y)     (list 'two x y))
    ((x y . z) (list 'rest x y z))))
(test-equal "case-lambda/0"    'zero           (cl))
(test-equal "case-lambda/1"    '(one 5)        (cl 5))
(test-equal "case-lambda/2"    '(two 3 4)      (cl 3 4))
(test-equal "case-lambda/rest" '(rest 1 2 (3 4 5)) (cl 1 2 3 4 5))
;;; err: use a cl without rest clause so 3 args matches nothing
(test-error "case-lambda/err"
  ((case-lambda (() 'zero) ((x) x) ((x y) (+ x y))) 1 2 3))

(news "--- 4.3 syntax ---\n")
(define-syntax swap!
  (syntax-rules ()
    ((swap! a b) (let ((t a)) (set! a b) (set! b t)))))
(test-equal "define-syntax/swap" '(2 1)
  (let ((x 1) (y 2)) (swap! x y) (list x y)))

(define-syntax my-or
  (syntax-rules ()
    ((my-or)         #f)
    ((my-or e)       e)
    ((my-or e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))
(test-equal "define-syntax/or-t" 5    (my-or #f #f 5))
(test-equal "define-syntax/or-f" #f   (my-or #f #f))
(test-equal "define-syntax/or-0" #f   (my-or))

(test-equal "let-syntax" '(2 1)
  (let-syntax ((xchg (syntax-rules ()
                        ((xchg a b) (let ((t a)) (set! a b) (set! b t))))))
    (let ((p 1) (q 2)) (xchg p q) (list p q))))

(test-equal "letrec-syntax" 10
  (letrec-syntax ((my-and (syntax-rules ()
                             ((my-and)        #t)
                             ((my-and e)      e)
                             ((my-and e1 e2 ...) (if e1 (my-and e2 ...) #f)))))
    (my-and 1 2 10)))

;;; -----------------------------------------------------------------------
;;; R7RS 5  Program structure
;;; -----------------------------------------------------------------------

(news "\n--- 5.3 define ---\n")
(define r7-x 42)
(test-equal "define/var" 42  r7-x)
(define (r7-add a b) (+ a b))
(test-equal "define/proc" 7   (r7-add 3 4))
(define (r7-fact n) (if (= n 0) 1 (* n (r7-fact (- n 1)))))
(test-equal "define/recursive" 120 (r7-fact 5))
(define (r7-varargs x . rest) (cons x rest))
(test-equal "define/varargs" '(1 2 3) (r7-varargs 1 2 3))

(news "--- 5.3.3 define-values ---\n")
(define-values (dv-a dv-b dv-c) (values 10 20 30))
(test-equal "define-values/a" 10  dv-a)
(test-equal "define-values/b" 20  dv-b)
(test-equal "define-values/c" 30  dv-c)
(define-values (dv-x dv-y) (values 'p 'q))
(test-equal "define-values/2a" 'p  dv-x)
(test-equal "define-values/2b" 'q  dv-y)

;;; -----------------------------------------------------------------------
;;; R7RS 6.1  Equivalence predicates
;;; -----------------------------------------------------------------------

(news "\n--- 6.1 eq? ---\n")
(test-assert "eq?/sym"       (eq? 'foo 'foo))
(test-equal "eq?/diff-sym"   #f (eq? 'foo 'bar))
(test-assert "eq?/#t"        (eq? #t #t))
(test-assert "eq?/#f"        (eq? #f #f))
(test-equal "eq?/#t-#f"      #f (eq? #t #f))
(test-assert "eq?/nil"       (eq? '() '()))
(test-equal "eq?/nil-#f"     #f (eq? '() #f))
(test-assert "eq?/same-pair" (let ((p (cons 1 2))) (eq? p p)))
(test-equal "eq?/diff-pairs" #f (eq? (cons 1 2) (cons 1 2)))

(news "--- 6.1 eqv? ---\n")
(test-assert "eqv?/sym"     (eqv? 'foo 'foo))
(test-assert "eqv?/int"     (eqv? 42 42))
(test-assert "eqv?/#t"      (eqv? #t #t))
(test-assert "eqv?/#f"      (eqv? #f #f))
(test-assert "eqv?/char"    (eqv? #\a #\a))
(test-assert "eqv?/nil"     (eqv? '() '()))
(test-equal "eqv?/int-real" #f (eqv? 1 1.0))
(test-equal "eqv?/diff-int" #f (eqv? 1 2))
(test-equal "eqv?/str"      #f (eqv? "a" "a"))

(news "--- 6.1 equal? ---\n")
(test-assert "equal?/int"     (equal? 42 42))
(test-assert "equal?/str"     (equal? "hello" "hello"))
(test-assert "equal?/list"    (equal? '(1 2 3) '(1 2 3)))
(test-assert "equal?/nested"  (equal? '(1 (2 3)) '(1 (2 3))))
(test-assert "equal?/vec"     (equal? '#(1 2 3) '#(1 2 3)))
(test-assert "equal?/bvec"    (equal? (bytevector 1 2) (bytevector 1 2)))
(test-assert "equal?/nil"     (equal? '() '()))
(test-assert "equal?/#f"      (equal? #f #f))
(test-equal "equal?/diff-str" #f (equal? "abc" "abd"))
(test-equal "equal?/diff-vec" #f (equal? '#(1 2) '#(1 3)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.2  Numbers
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 type predicates ---\n")
(test-assert "number?/int"       (number? 0))
(test-assert "number?/real"      (number? 3.14))
(test-equal "number?/sym"        #f (number? 'x))
(test-assert "integer?/0"        (integer? 0))
(test-assert "integer?/neg"      (integer? -5))
(test-equal "integer?/real"      #f (integer? 3.14))
(test-assert "real?/int"         (real? 5))
(test-assert "real?/0"           (real? 0))
(test-assert "real?/neg"         (real? -1))
(test-assert "real?/float"       (real? 1.5))
(test-assert "rational?/int"     (rational? 5))
(test-assert "exact?/int"        (exact? 5))
(test-assert "exact?/0"          (exact? 0))
(test-equal "exact?/float"       #f (exact? 1.5))
(test-assert "inexact?/float"    (inexact? 1.5))
(test-equal "inexact?/int"       #f (inexact? 5))
(test-assert "exact-integer?/5"  (exact-integer? 5))
(test-equal "exact-integer?/1.5" #f (exact-integer? 1.5))

(news "--- 6.2 zero? positive? negative? odd? even? ---\n")
(test-assert "zero?/0"      (zero? 0))
(test-equal "zero?/1"       #f (zero? 1))
(test-assert "zero?/0.0"    (zero? 0.0))
(test-assert "positive?/1"  (positive? 1))
(test-equal "positive?/0"   #f (positive? 0))
(test-equal "positive?/-1"  #f (positive? -1))
(test-assert "negative?/-1" (negative? -1))
(test-equal "negative?/0"   #f (negative? 0))
(test-assert "odd?/1"       (odd? 1))
(test-equal "odd?/2"        #f (odd? 2))
(test-assert "odd?/-3"      (odd? -3))
(test-assert "even?/0"      (even? 0))
(test-assert "even?/4"      (even? 4))
(test-equal "even?/7"       #f (even? 7))

(news "--- 6.2 max / min ---\n")
(test-equal "max/2"     5    (max 3 5))
(test-equal "max/multi" 7    (max 1 7 3 5 2))
(test-equal "max/neg"   -1   (max -3 -1 -5))
(test-equal "min/2"     3    (min 3 5))
(test-equal "min/multi" 1    (min 4 1 7 3))

(news "--- 6.2 arithmetic ---\n")
(test-equal "+/0"     0    (+))
(test-equal "+/1"     5    (+ 5))
(test-equal "+/2"     7    (+ 3 4))
(test-equal "+/multi" 15   (+ 1 2 3 4 5))
(test-equal "-/1"     -5   (- 5))
(test-equal "-/2"     3    (- 8 5))
(test-equal "-/multi" 0    (- 10 3 4 3))
(test-equal "*/0"     1    (*))
(test-equal "*/1"     7    (* 7))
(test-equal "*/2"     12   (* 3 4))
(test-equal "*/multi" 120  (* 1 2 3 4 5))
(test-equal "//2"     4    (/ 12 3))
(test-equal "abs/pos" 5    (abs 5))
(test-equal "abs/neg" 5    (abs -5))
(test-equal "abs/0"   0    (abs 0))

(news "--- 6.2 quotient / remainder / modulo ---\n")
(test-equal "quotient/pos"  3    (quotient 10 3))
(test-equal "quotient/neg"  -3   (quotient -10 3))
(test-equal "remainder/pos" 1    (remainder 10 3))
(test-equal "remainder/neg" -1   (remainder -10 3))
(test-equal "modulo/pos"    1    (modulo 10 3))
(test-equal "modulo/neg"    2    (modulo -10 3))
(test-equal "modulo/-neg"   -2   (modulo 10 -3))

(news "--- 6.2 gcd / lcm ---\n")
(test-equal "gcd/2"    4    (gcd 12 8))
(test-equal "gcd/0"    5    (gcd 5 0))
(test-equal "gcd/0-0"  0    (gcd 0 0))
(test-equal "gcd/1arg" 7    (gcd 7))
(test-equal "gcd/0arg" 0    (gcd))
(test-equal "lcm/2"    12   (lcm 4 6))
(test-equal "lcm/1arg" 5    (lcm 5))
(test-equal "lcm/0arg" 1    (lcm))

(news "--- 6.2 floor / ceiling / truncate / round ---\n")
(test-equal "floor/pos"    3.0  (floor 3.7))
(test-equal "floor/neg"    -4.0  (floor -3.7))
(test-equal "floor/int"    5    (floor 5))
(test-equal "ceiling/pos"  4.0  (ceiling 3.2))
(test-equal "ceiling/neg"  -3.0  (ceiling -3.7))
(test-equal "ceiling/int"  5    (ceiling 5))
(test-equal "truncate/pos" 3.0  (truncate 3.9))
(test-equal "truncate/neg" -3.0  (truncate -3.9))
(test-equal "truncate/int" 5    (truncate 5))
(test-equal "round/down"   2.0  (round 2.4))
(test-equal "round/up"     3.0  (round 2.6))
(test-equal "round/half-e" 2.0  (round 2.5))
(test-equal "round/half-o" 4.0  (round 3.5))
(test-equal "round/neg"    -2.0  (round -2.5))
(test-equal "round/int"    5    (round 5))

(news "--- 6.2 exact / inexact conversion ---\n")
(test-equal "exact->inexact" 1.0  (exact->inexact 1))
(test-equal "inexact->exact" 3    (inexact->exact 3.0))
(test-equal "exact/alias"    2.0  (exact->inexact 2))
(test-equal "inexact/alias"  4    (inexact->exact 4.0))

(news "--- 6.2 special floats ---\n")
(test-assert "+inf.0/pos"   (> +inf.0 1e308))
(test-assert "-inf.0/neg"   (< -inf.0 -1e308))
(test-assert "+inf.0/inf?"  (infinite? +inf.0))
(test-assert "-inf.0/inf?"  (infinite? -inf.0))
(test-equal "+inf.0/finite" #f (finite? +inf.0))
(test-equal "-inf.0/finite" #f (finite? -inf.0))
(test-equal "+inf.0/nan?"   #f (nan? +inf.0))
(test-assert "+nan.0/nan?"  (nan? +nan.0))
(test-equal "+nan.0/finite" #f (finite? +nan.0))
(test-assert "+inf.0/num?"  (number? +inf.0))
(test-assert "+inf.0/real?" (real? +inf.0))
(test-assert "arith/+inf"   (= +inf.0 (+ +inf.0 1)))
(test-assert "arith/-inf"   (= -inf.0 (- -inf.0 1)))

(news "--- 6.2 expt / sqrt ---\n")
(test-equal "expt/int" 8    (expt 2 3))
(test-equal "expt/0"   1    (expt 5 0))
(test-equal "expt/1"   7    (expt 7 1))
(test-assert "sqrt/4"  (= 2.0 (sqrt 4)))
(test-assert "sqrt/9"  (= 3.0 (sqrt 9)))

(news "--- 6.2 comparisons ---\n")
(test-assert "=/2"       (= 3 3))
(test-assert "=/float"   (= 3 3.0))
(test-equal "=/diff"     #f (= 3 4))
(test-assert "</chain"   (< 1 2 3 4))
(test-equal "</chain-eq" #f (< 1 2 2 3))
(test-assert ">/chain"   (> 4 3 2 1))
(test-assert "<=/eq"     (<= 2 2 3))
(test-assert ">=/eq"     (>= 3 2 2))

(news "--- 6.2 number->string / string->number ---\n")
(test-equal "n->s/10"    "0"    (number->string 0))
(test-equal "n->s/pos"   "42"   (number->string 42))
(test-equal "n->s/neg"   "-7"   (number->string -7))
(test-equal "n->s/16"    "ff"   (string-downcase (number->string 255 16)))
(test-equal "n->s/2"     "1010" (number->string 10 2))
(test-equal "n->s/8"     "17"   (number->string 15 8))
(test-equal "s->n/int"   42     (string->number "42"))
(test-equal "s->n/neg"   -7     (string->number "-7"))
(test-equal "s->n/float" 3.14   (string->number "3.14"))
(test-equal "s->n/16"    255    (string->number "ff" 16))
(test-equal "s->n/2"     10     (string->number "1010" 2))
(test-equal "s->n/8"     15     (string->number "17" 8))
(test-equal "s->n/bad"   #f     (string->number "xyz"))
(test-equal "s->n/empty" #f     (string->number ""))
;;; Rational literals + #e/#i exactness + #b/#o/#d/#x radix prefixes (R7RS 7.1.1).  string->number
;;; previously returned #f for "1/2" (no rational parsing).  Matches Chez/Chibi (cross-impl probe).
(test-equal "s->n/rat"         1/2    (string->number "1/2"))
(test-equal "s->n/rat-reduce"  2     (string->number "6/3"))          ; reduces to integer
(test-equal "s->n/rat-reduce2" 1/2  (string->number "2/4"))          ; reduces
(test-equal "s->n/rat-neg"     -1/2   (string->number "-3/6"))
(test-equal "s->n/rat-zero"    #f     (string->number "1/0"))          ; denom 0 -> #f
(test-equal "s->n/hashx"       255    (string->number "#xff"))         ; #x radix prefix
(test-equal "s->n/hashb"       5      (string->number "#b101"))
(test-equal "s->n/hasho"       15     (string->number "#o17"))
(test-equal "s->n/exact-i"     .5     (string->number "#i1/2"))        ; #i forces inexact
(test-equal "s->n/exact-e"     10     (string->number "#e10"))         ; #e exact (no-op on int)
(test-equal "s->n/prefix2"     16.0   (string->number "#x#i10"))       ; combined radix+exactness prefix


;;; --- coverage added 2026-08-29: exercised by the chibi R7RS suite, absent here ---------
(test-equal "acos/1"                   0.0  (acos 1))
(test-assert "acos/0"                  (< (abs (- (acos 0) 1.5707963)) 1e-5))   ;;!< pi/2
(test-assert "acos/-1"                 (< (abs (- (acos -1) 3.1415926)) 1e-5))  ;;!< pi
(test-assert "acos/cos-roundtrip"      (< (abs (- (acos (cos 0.5)) 0.5)) 1e-5))
(test-equal "inexact/int"              3.0  (inexact 3))
(test-equal "inexact/idempotent"       3.5 (inexact 3.5))
(test-equal "exact/float"              3    (exact 3.0))
(test-equal "exact/idempotent"         3    (exact 3))
(test-assert "exact/inexact-roundtrip" (= 7 (exact (inexact 7))))
(test-equal "rationalize/exact"        1/3  (rationalize 3/10 1/10))   ;;!< the R7RS 6.2.6 example
(test-assert "rationalize/inexact"     (< (abs (- (rationalize .3 1/10) (/ 1.0 3))) 1e-5))

;;; -----------------------------------------------------------------------
;;; R7RS 6.3  Booleans
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 booleans ---\n")
(test-assert "boolean?/#t"  (boolean? #t))
(test-assert "boolean?/#f"  (boolean? #f))
(test-equal "boolean?/0"    #f (boolean? 0))
(test-equal "boolean?/nil"  #f (boolean? '()))
(test-assert "not/#f"       (not #f))
(test-equal "not/#t"        #f (not #t))
(test-equal "not/0"         #f (not 0))
(test-equal "not/nil"       #f (not '()))
(test-equal "not/str"       #f (not ""))
(test-assert "boolean=?/tt" (boolean=? #t #t))
(test-assert "boolean=?/ff" (boolean=? #f #f))
(test-equal "boolean=?/tf"  #f (boolean=? #t #f))

;;; -----------------------------------------------------------------------
;;; R7RS 6.4  Pairs and lists
;;; -----------------------------------------------------------------------

(news "\n--- 6.4 pairs ---\n")
(test-assert "pair?/cons" (pair? (cons 1 2)))
(test-assert "pair?/list" (pair? '(1)))
(test-equal "pair?/nil"   #f (pair? '()))
(test-equal "pair?/atom"  #f (pair? 5))
(test-equal "cons/dot"    '(1 . 2)  (cons 1 2))
(test-equal "cons/list"   '(1 2 3)  (cons 1 '(2 3)))
(test-equal "car/list"    1         (car '(1 2 3)))
(test-equal "cdr/list"    '(2 3)    (cdr '(1 2 3)))
(test-equal "car/dot"     1         (car '(1 . 2)))
(test-equal "cdr/dot"     2         (cdr '(1 . 2)))

(news "--- 6.4 list predicates ---\n")
(test-assert "null?/nil"    (null? '()))
(test-equal "null?/pair"    #f (null? '(1)))
(test-equal "null?/0"       #f (null? 0))
(test-assert "list?/proper" (list? '(1 2 3)))
(test-assert "list?/nil"    (list? '()))
(test-equal "list?/dotted"  #f (list? '(1 . 2)))
(test-equal "list?/cyclic"  #f (list? (let ((x (list 1 2)))
                                         (set-cdr! (cdr x) x) x)))

(news "--- 6.4 list operations ---\n")
(test-equal "list/3"       '(1 2 3)    (list 1 2 3))
(test-equal "list/nil"     '()         (list))
(test-equal "length/3"     3           (length '(1 2 3)))
(test-equal "length/0"     0           (length '()))
(test-equal "append/2"     '(1 2 3 4)  (append '(1 2) '(3 4)))
(test-equal "append/3"     '(1 2 3 4 5) (append '(1 2) '(3 4) '(5)))
(test-equal "append/nil-l" '(1 2)      (append '() '(1 2)))
(test-equal "append/l-nil" '(1 2)      (append '(1 2) '()))
(test-equal "reverse"      '(3 2 1)    (reverse '(1 2 3)))
(test-equal "reverse/nil"  '()         (reverse '()))
(test-equal "list-tail/2"  '(3 4)      (list-tail '(1 2 3 4) 2))
(test-equal "list-tail/0"  '(1 2)      (list-tail '(1 2) 0))
(test-equal "list-ref/0"   1           (list-ref '(1 2 3) 0))
(test-equal "list-ref/2"   3           (list-ref '(1 2 3) 2))
(test-equal "make-list/3"  '(x x x)    (make-list 3 'x))
(test-equal "make-list/0"  '()         (make-list 0 'z))

(news "--- 6.4 list mutation ---\n")
(test-equal "set-car!"  '(9 2)   (let ((p (list 1 2))) (set-car! p 9) p))
(test-equal "set-cdr!"  '(1 9)   (let ((p (list 1 2))) (set-cdr! p '(9)) p))
(test-equal "list-set!" '(1 9 3) (let ((l (list 1 2 3))) (list-set! l 1 9) l))

(news "--- 6.4 list search ---\n")
(test-equal "memq/found"   '(b c)   (memq 'b '(a b c)))
(test-equal "memq/miss"    #f       (memq 'd '(a b c)))
(test-equal "memv/found"   '(2 3)   (memv 2 '(1 2 3)))
(test-equal "member/found" '(2 3)   (member 2 '(1 2 3)))
(test-equal "member/equal" '("b" "c") (member "b" '("a" "b" "c")))
(test-equal "assq/found"   '(b 2)   (assq 'b '((a 1) (b 2) (c 3))))
(test-equal "assq/miss"    #f       (assq 'd '((a 1) (b 2))))
(test-equal "assv/found"   '(2 x)   (assv 2 '((1 a) (2 x) (3 b))))
(test-equal "assoc/str"    '("b" 2) (assoc "b" '(("a" 1) ("b" 2) ("c" 3))))

(news "--- 6.4 cXXr / cXXXr / cXXXXr ---\n")
(test-equal "caar"   1   (caar '((1 2) 3)))
(test-equal "cadr"   2   (cadr '(1 2 3)))
(test-equal "cdar"   '(2) (cdar '((1 2) 3)))
(test-equal "cddr"   '(3) (cddr '(1 2 3)))
(test-equal "caaar"  1   (caaar '(((1)))))
(test-equal "caddr"  3   (caddr '(1 2 3 4)))
(test-equal "cdddr"  '(4) (cdddr '(1 2 3 4)))
(test-equal "cadddr" 4  (cadddr '(1 2 3 4 5)))
(test-equal "cddddr" '(5) (cddddr '(1 2 3 4 5)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.5  Symbols
;;; -----------------------------------------------------------------------

(news "\n--- 6.5 symbols ---\n")
(test-assert "symbol?/sym"    (symbol? 'hello))
(test-equal "symbol?/str"     #f (symbol? "hello"))
(test-equal "symbol?/num"     #f (symbol? 42))
(test-equal "symbol->string"  "foo"  (symbol->string 'foo))
(test-equal "string->symbol"  'bar   (string->symbol "bar"))
(test-assert "symbol=?/2"     (symbol=? 'x 'x))
(test-equal "symbol=?/diff"   #f (symbol=? 'x 'y))
(test-assert "symbol=?/3"     (symbol=? 'a 'a 'a))
(test-equal "symbol=?/3-diff" #f (symbol=? 'a 'a 'b))

;;; -----------------------------------------------------------------------
;;; R7RS 6.6  Characters
;;; -----------------------------------------------------------------------

(news "\n--- 6.6 characters ---\n")
(test-assert "char?/ok"       (char? #\a))
(test-equal "char?/str"       #f (char? "a"))
(test-assert "char=?/eq"      (char=? #\a #\a))
(test-equal "char=?/ne"       #f (char=? #\a #\b))
(test-assert "char<?/lt"      (char<? #\a #\b))
(test-equal "char<?/eq"       #f (char<? #\b #\b))
(test-assert "char>?/gt"      (char>? #\b #\a))
(test-assert "char<=?/eq"     (char<=? #\a #\a))
(test-assert "char<=?/lt"     (char<=? #\a #\b))
(test-assert "char>=?/eq"     (char>=? #\b #\b))
(test-assert "char>=?/gt"     (char>=? #\b #\a))
(test-assert "char<?/chain"   (char<? #\a #\b #\c))
(test-assert "char-alpha?"    (char-alphabetic? #\z))
(test-equal "char-alpha?/dig" #f (char-alphabetic? #\5))
(test-assert "char-num?"      (char-numeric? #\9))
(test-equal "char-num?/a"     #f (char-numeric? #\a))
(test-assert "char-ws?/sp"    (char-whitespace? #\space))
(test-assert "char-ws?/nl"    (char-whitespace? #\newline))
(test-assert "char-upper?"    (char-upper-case? #\Z))
(test-equal "char-upper?/lc"  #f (char-upper-case? #\z))
(test-assert "char-lower?"    (char-lower-case? #\a))
(test-equal "char-lower?/uc"  #f (char-lower-case? #\A))
(test-equal "char->int/a"     97   (char->integer #\a))
(test-equal "char->int/A"     65   (char->integer #\A))
(test-equal "char->int/0"     48   (char->integer #\0))
(test-equal "int->char/97"    #\a  (integer->char 97))
(test-equal "char-upcase"     #\A  (char-upcase #\a))
(test-equal "char-downcase"   #\a  (char-downcase #\A))
(test-equal "digit-value/5"   5    (digit-value #\5))
(test-equal "digit-value/0"   0    (digit-value #\0))
(test-equal "digit-value/9"   9    (digit-value #\9))
(test-equal "digit-value/x"   #f   (digit-value #\x))

(news "--- 6.6 char-ci ---\n")
(test-assert "char-ci=?"      (char-ci=? #\A #\a))
(test-assert "char-ci=?/both" (char-ci=? #\a #\A))
(test-assert "char-ci<?"      (char-ci<? #\a #\B))
(test-equal "char-ci<?/eq"    #f (char-ci<? #\A #\a))
(test-assert "char-ci>?"      (char-ci>? #\B #\a))
(test-assert "char-ci<=?"     (char-ci<=? #\A #\a))
(test-assert "char-ci>=?"     (char-ci>=? #\a #\A))

;;; -----------------------------------------------------------------------
;;; R7RS 6.7  Strings
;;; -----------------------------------------------------------------------

(news "\n--- 6.7 strings ---\n")
(test-assert "string?/ok"      (string? "hello"))
(test-equal "string?/sym"      #f (string? 'hello))
(test-equal "make-string/ch"   "aaa"   (make-string 3 #\a))
(test-equal "make-string/0"    ""      (make-string 0 #\x))
(test-equal "string/3"         "abc"   (string #\a #\b #\c))
(test-equal "string-length"    5       (string-length "hello"))
(test-equal "string-length/0"  0       (string-length ""))
(test-equal "string-ref/0"     #\h     (string-ref "hello" 0))
(test-equal "string-ref/4"     #\o     (string-ref "hello" 4))
(test-equal "substring/mid"    "ell"   (substring "hello" 1 4))
(test-equal "substring/full"   "hi"    (substring "hi" 0 2))
(test-equal "substring/empty"  ""      (substring "hello" 2 2))
(test-equal "string-append/2"  "ab"    (string-append "a" "b"))
(test-equal "string-append/3"  "abc"   (string-append "a" "b" "c"))
(test-equal "string-append/0"  ""      (string-append))
(test-equal "string->list"     '(#\h #\i) (string->list "hi"))
(test-equal "string->list/sub" '(#\e #\l) (string->list "hello" 1 3))
(test-equal "list->string"     "hi"    (list->string '(#\h #\i)))
(test-equal "string-copy/full" "abc"  (string-copy "abc"))
(test-equal "string-copy/sub"  "bc"   (string-copy "abcd" 1 3))
(test-assert "string=?"        (string=? "abc" "abc"))
(test-equal "string=?/ne"      #f (string=? "abc" "abd"))
(test-assert "string<?"        (string<? "abc" "abd"))
(test-equal "string<?/eq"      #f (string<? "abc" "abc"))
(test-assert "string>?"        (string>? "abd" "abc"))
(test-assert "string<=?/eq"    (string<=? "abc" "abc"))
(test-assert "string>=?/eq"    (string>=? "abc" "abc"))
(test-equal "string-upcase"    "HELLO" (string-upcase "hello"))
(test-equal "string-downcase"  "hello" (string-downcase "HELLO"))

(news "--- 6.7 string mutation ---\n")
(test-equal "string-set!" "hXllo"
  (let ((s (string-copy "hello"))) (string-set! s 1 #\X) s))
(test-equal "string-fill!" "xxx"
  (let ((s (make-string 3 #\a))) (string-fill! s #\x) s))
(test-equal "string-fill!/range" "aXXa"
  (let ((s (string-copy "aaaa"))) (string-fill! s #\X 1 3) s))
(test-equal "string-copy!/full" "XYZ"
  (let ((s (make-string 3 #\a))) (string-copy! s 0 "XYZ") s))
(test-equal "string-copy!/range" "hXYlo"
  (let ((s (string-copy "hello"))) (string-copy! s 1 "XYZ" 0 2) s))
(test-equal "string-copy!/at" "abXYe"
  (let ((s (string-copy "abcde"))) (string-copy! s 2 "XY") s))

(news "--- 6.7 string-ci ---\n")
(test-assert "string-ci=?"  (string-ci=? "Hello" "hello"))
(test-assert "string-ci<?"  (string-ci<? "abc" "ABD"))
(test-assert "string-ci>?"  (string-ci>? "ABD" "abc"))
(test-assert "string-ci<=?" (string-ci<=? "ABC" "abc"))
(test-assert "string-ci>=?" (string-ci>=? "abc" "ABC"))

;;; -----------------------------------------------------------------------
;;; R7RS 6.8  Vectors
;;; -----------------------------------------------------------------------

(news "\n--- 6.8 vectors ---\n")
(test-assert "vector?/vec"       (vector? '#(1 2)))
(test-equal "vector?/list"       #f (vector? '(1 2)))
(test-equal "vector/3"           '#(1 2 3)  (vector 1 2 3))
(test-equal "vector/0"           '#()       (vector))
(test-equal "make-vector/3"      '#(0 0 0)  (make-vector 3 0))
(test-equal "make-vector/0"      '#()       (make-vector 0 'x))
(test-equal "vector-length"      3         (vector-length '#(1 2 3)))
(test-equal "vector-length/0"    0       (vector-length '#()))
(test-equal "vector-ref/0"       1         (vector-ref '#(1 2 3) 0))
(test-equal "vector-ref/2"       3         (vector-ref '#(1 2 3) 2))
(test-equal "vector->list"       '(1 2 3)  (vector->list '#(1 2 3)))
(test-equal "vector->list/sub"   '(2 3) (vector->list '#(1 2 3 4) 1 3))
(test-equal "list->vector"       '#(1 2 3)  (list->vector '(1 2 3)))
(test-equal "list->vector/0"     '#()      (list->vector '()))
(test-equal "vector->string"     "abc"    (vector->string '#(#\a #\b #\c)))
(test-equal "string->vector"     '#(#\a #\b #\c) (string->vector "abc"))
(test-equal "string->vector/sub" '#(#\b #\c) (string->vector "abcd" 1 3))
(test-equal "vector-copy/full"   '#(1 2 3) (vector-copy '#(1 2 3)))
(test-equal "vector-copy/sub"    '#(2 3)   (vector-copy '#(1 2 3 4) 1 3))
(test-equal "vector-copy/from"   '#(3 4)   (vector-copy '#(1 2 3 4) 2))
(test-equal "vector-append/2"    '#(1 2 3 4) (vector-append '#(1 2) '#(3 4)))
(test-equal "vector-append/3"    '#(1 2 3 4 5) (vector-append '#(1 2) '#(3) '#(4 5)))
(test-equal "vector-append/0"    '#()       (vector-append))

;;; Vector WRITE/DISPLAY -- regression for the bug where write printed a vector as
;;; "#vector(N 0xADDR)" (length + pointer) instead of "#(e0 e1 ...)".  The value-comparison checks
;;; above never caught it because they compare via equal?, not printed form.  (Found by the
;;; Chez/Chibi cross-impl probe; fixed in Cell::str, ll_vm_cell.cpp.)
(news "--- 6.8 vector write/display ---\n")
(define (%vec-write v)   (let ((p (open-output-string))) (write   v p) (get-output-string p)))
(define (%vec-display v) (let ((p (open-output-string))) (display v p) (get-output-string p)))
(test-equal "vector-write/3"      "#(1 2 3)"                (%vec-write   (vector 1 2 3)))
(test-equal "vector-write/empty"  "#()"                     (%vec-write   (vector)))
(test-equal "vector-write/nested" "#(1 #(2 3))"             (%vec-write   (vector 1 (vector 2 3))))
(test-equal "vector-write/str"    "#(\"a\" b)"              (%vec-write   (vector "a" 'b)))
(test-equal "vector-display/3"    "#(1 2 3)"                (%vec-display (vector 1 2 3)))
(test-equal "vector-write/big"    "#(0 0 0 0 0 0 0 0 0 0)"  (%vec-write   (make-vector 10 0)))

;;; Inexact-real write -- R7RS 7.1.1 requires an inexact number to be written distinguishably from
;;; an exact one, so a whole-valued float must show a decimal point (1.0, not 1) or it reads back as
;;; exact.  And bytevector write must be #u8(...), not the internal #bytevector(N ptr).  (Found by the
;;; Chez/Chibi cross-impl write-diff probe; fixed in Cell::str via ll_real_str + the #u8 render.)
(news "--- 6.8 inexact-real + bytevector write ---\n")
(test-equal "float-write/whole"   "1.0"          (%vec-write 1.0))
(test-equal "float-write/100"     "100.0"        (%vec-write 100.0))
(test-equal "float-write/negzero" "-0.0"         (%vec-write -0.0))
(test-equal "float-write/round"   "2.0"          (%vec-write (round 2.5)))
(test-equal "float-write/frac"    "1.5"          (%vec-write 1.5))
(test-equal "float-write/e->i"    "1.0"          (%vec-write (exact->inexact 1)))
(test-equal "bytevector-write"    "#u8(1 2 3)"   (%vec-write (bytevector 1 2 3)))
(test-equal "bytevector-write/0"  "#u8()"        (%vec-write (bytevector)))

(news "--- 6.8 vector mutation ---\n")
(test-equal "vector-set!" '#(1 9 3)
  (let ((v (vector 1 2 3))) (vector-set! v 1 9) v))
(test-equal "vector-fill!" '#(7 7 7)
  (let ((v (vector 1 2 3))) (vector-fill! v 7) v))
(test-equal "vector-fill!/range" '#(1 7 7 4)
  (let ((v (vector 1 2 3 4))) (vector-fill! v 7 1 3) v))
(test-equal "vector-copy!/full" '#(9 8 7)
  (let ((v (vector 1 2 3))) (vector-copy! v 0 '#(9 8 7)) v))
(test-equal "vector-copy!/at" '#(1 9 8 4)
  (let ((v (vector 1 2 3 4))) (vector-copy! v 1 '#(9 8) 0 2) v))

;;; -----------------------------------------------------------------------
;;; R7RS 6.9  Bytevectors
;;; -----------------------------------------------------------------------

(news "\n--- 6.9 bytevectors ---\n")
(test-assert "bytevector?/ok" (bytevector? (bytevector 1 2)))
(test-equal "bytevector?/vec" #f (bytevector? '#(1 2)))
(test-equal "bytevector/3"    (bytevector 1 2 3)  (bytevector 1 2 3))
(test-equal "make-bvec"       (bytevector 0 0 0)  (make-bytevector 3 0))
(test-equal "bvec-length"     3     (bytevector-length (bytevector 1 2 3)))
(test-equal "bvec-length/0"   0     (bytevector-length (bytevector)))
(test-equal "bvec-u8-ref"     2     (bytevector-u8-ref (bytevector 1 2 3) 1))
(test-equal "bvec-copy/full"  (bytevector 1 2 3) (bytevector-copy (bytevector 1 2 3)))
(test-equal "bvec-copy/sub"   (bytevector 2 3)   (bytevector-copy (bytevector 1 2 3) 1))
(test-equal "bvec-copy/range" (bytevector 2 3)   (bytevector-copy (bytevector 1 2 3 4) 1 3))
(test-equal "bvec-append"     (bytevector 1 2 3 4) (bytevector-append (bytevector 1 2) (bytevector 3 4)))
(test-equal "bvec-u8-set!"    (bytevector 1 99 3)
  (let ((b (bytevector 1 2 3))) (bytevector-u8-set! b 1 99) b))

(news "--- 6.9 utf8 conversion ---\n")
(test-equal "string->utf8"     (bytevector 104 101 108 108 111) (string->utf8 "hello"))
(test-equal "utf8->string"     "hello"  (utf8->string (bytevector 104 101 108 108 111)))
(test-equal "utf8->string/sub" "el"   (utf8->string (bytevector 104 101 108 108 111) 1 3))


;;; --- coverage added 2026-08-29: exercised by the chibi R7RS suite, absent here ---------
(test-equal "bytevector-copy!/range"
       (bytevector 10 1 2 3 50)
       (let ((to (bytevector 10 20 30 40 50)) (from (bytevector 1 2 3 4 5)))
         (bytevector-copy! to 1 from 0 3)
         to))
(test-equal "bytevector-copy!/whole"
       (bytevector 1 2 3)
       (let ((to (bytevector 0 0 0)))
         (bytevector-copy! to 0 (bytevector 1 2 3))
         to))

;;; -----------------------------------------------------------------------
;;; R7RS 6.10  Control features
;;; -----------------------------------------------------------------------

(news "\n--- 6.10 apply ---\n")
(test-equal "apply/list"   6     (apply + '(1 2 3)))
(test-equal "apply/mixed"  10    (apply + 1 2 '(3 4)))
(test-equal "apply/empty"  0     (apply + '()))
(test-equal "apply/single" -5    (apply - '(5)))
(test-equal "apply/lambda" 7     (apply (lambda (a b) (+ a b)) '(3 4)))

(news "--- 6.10 map ---\n")
(test-equal "map/1"      '(2 4 6)     (map (lambda (x) (* x 2)) '(1 2 3)))
(test-equal "map/2lists" '(5 7 9)     (map + '(1 2 3) '(4 5 6)))
(test-equal "map/3lists" '(9 12 15)   (map + '(1 2 3) '(4 5 6) '(4 5 6)))
(test-equal "map/nil"    '()          (map car '()))
(test-equal "map/pairs"  '(1 4 9)     (map * '(1 2 3) '(1 2 3)))

(news "--- 6.10 for-each ---\n")
(test-equal "for-each/1" '(3 2 1)
  (let ((acc '()))
    (for-each (lambda (x) (set! acc (cons x acc))) '(1 2 3))
    acc))
(test-equal "for-each/2" '((1 . 4) (2 . 5) (3 . 6))
  (let ((acc '()))
    (for-each (lambda (x y) (set! acc (cons (cons x y) acc))) '(1 2 3) '(4 5 6))
    (reverse acc)))

(news "--- 6.10 string-map / string-for-each ---\n")
(test-equal "string-map/1"    "ABC"    (string-map char-upcase "abc"))
(test-equal "string-map/2"    "ace"    (string-map (lambda (a b) b) "abc" "ace"))
(test-equal "string-for-each" '(#\c #\b #\a)
  (let ((acc '()))
    (string-for-each (lambda (c) (set! acc (cons c acc))) "abc")
    acc))

(news "--- 6.10 vector-map / vector-for-each ---\n")
(test-equal "vector-map/1"    '#(2 4 6)   (vector-map (lambda (x) (* x 2)) '#(1 2 3)))
(test-equal "vector-map/2"    '#(5 7 9)   (vector-map + '#(1 2 3) '#(4 5 6)))
(test-equal "vector-for-each" '(3 2 1)
  (let ((acc '()))
    (vector-for-each (lambda (x) (set! acc (cons x acc))) '#(1 2 3))
    acc))

(news "--- 6.10 values / call-with-values ---\n")
(test-equal "values/1" 5     (call-with-values (lambda () 5) (lambda (x) x)))
(test-equal "values/2" 3     (call-with-values (lambda () (values 1 2)) +))
(test-equal "values/3" 6     (call-with-values (lambda () (values 1 2 3)) +))
(test-equal "cwv/list" '(a b) (call-with-values (lambda () (values 'a 'b)) list))

;;; -----------------------------------------------------------------------
;;; R7RS 6.11  Exceptions
;;; -----------------------------------------------------------------------

(news "\n--- 6.11 raise / with-exception-handler ---\n")
;;; Use guard instead of with-exception-handler for portability:
;;; Chez (R6RS) raise is non-continuable -- handlers cannot return normally.
(test-equal "raise/catch" 42    (guard (e (#t e)) (raise 42)))
(test-equal "raise/str"   "oops" (guard (e (#t e)) (raise "oops")))
(test-equal "no-raise"    'ok   (guard (e (else 'caught)) 'ok))
(test-equal "error/catch" 'ok   (guard (e (else 'ok)) (error "msg")))

(news "--- 6.11 error objects ---\n")
(test-equal "error-object?"   #t    (guard (e (#t (error-object? e)))    (error "test" 1 2)))
(test-equal "error-message"   "test" (guard (e (#t (error-object-message e))) (error "test" 1 2)))
(test-equal "error-irritants" '(1 2 3)
  (guard (e (#t (error-object-irritants e))) (error "test" 1 2 3)))
(test-equal "error-irritants/0" '()
  (guard (e (#t (error-object-irritants e))) (error "none")))
(test-equal "error-object?/sym" #f (error-object? 'foo))
(test-equal "error-object?/str" #f (error-object? "msg"))

(news "--- 6.11 guard ---\n")
(test-equal "guard/cond" 'got-5
  (guard (e ((equal? e 5) 'got-5)) (raise 5)))
(test-equal "guard/else" 'default
  (guard (e ((equal? e 1) 'one) (else 'default)) (raise 99)))
(test-equal "guard/no-raise" 'body
  (guard (e (else 'caught)) 'body))
(test-equal "guard/error-obj" '("bad" (1 2))
  (guard (e ((error-object? e) (list (error-object-message e) (error-object-irritants e))))
    (error "bad" 1 2)))
;;; guard/reraise: R7RS allows with-exception-handler handler to return from raise.
;;; Chez (R6RS) treats raise as non-continuable -- skip on Chez.
(when (not chez-scheme?)
  (test-equal "guard/reraise" 99
    (with-exception-handler
      (lambda (e) e)
      (lambda () (guard (e ((equal? e 42) 'nope)) (raise 99))))))

;;; -----------------------------------------------------------------------
;;; R7RS 6.12  Environments and eval
;;; -----------------------------------------------------------------------

(news "\n--- 6.12 eval ---\n")
(test-equal "eval/arith"      10   (eval '(+ 3 7) (interaction-environment)))
(test-equal "eval/let"        6    (eval '(let ((x 2)) (* x 3)) (interaction-environment)))
(test-equal "eval/define"     'ok  (begin (eval '(define eval-test 42) (interaction-environment)) 'ok))
(test-equal "eval/use-define" 42   (eval 'eval-test (interaction-environment)))


;;; --- coverage added 2026-08-29: exercised by the chibi R7RS suite, absent here ---------
;;; R7RS-small has no `environment?` predicate (that is an R6RS-ism, and LambLisp does not bind
;;; it), so the useful assertion is that the returned object WORKS as an eval environment.
(test-assert "scheme-report-environment/5"   (not (eq? #f (scheme-report-environment 5))))
(test-equal "scheme-report-environment/eval" 7
       (eval (quote (+ 3 4)) (scheme-report-environment 5)))
;;; `exit' is bound but deliberately NOT invoked: calling it would end the test run.  R7RS 6.14
;;; only requires that it exist and terminate; its effect is untestable from inside the suite.
(test-assert "exit/bound" (procedure? exit))

;;; -----------------------------------------------------------------------
;;; R7RS 6.14  Time
;;; -----------------------------------------------------------------------

(news "\n--- 6.14 time ---\n")
(test-assert "jiffies-per-second" (> (jiffies-per-second) 0))
(test-assert "current-jiffy"      (>= (current-jiffy) 0))
(test-assert "current-second"     (>= (current-second) 0))
(test-assert "jiffies-monotone"   (<= (current-jiffy) (current-jiffy)))

;;; -----------------------------------------------------------------------
;;; Tail calls
;;; -----------------------------------------------------------------------

(news "\n--- tail calls ---\n")
(define (tc-count n acc)
  (if (= n 0) acc (tc-count (- n 1) (+ acc 1))))
(test-equal "tail/10k"  10000  (tc-count 10000 0))
(test-equal "tail/100k" 100000 (tc-count 100000 0))

(define (tc-even? n)
  (if (= n 0) #t (tc-odd? (- n 1))))
(define (tc-odd? n)
  (if (= n 0) #f (tc-even? (- n 1))))
(test-assert "tail/mutual-even" (tc-even? 10000))
(test-equal "tail/mutual-odd"   #f (tc-odd? 10000))

;;; -----------------------------------------------------------------------
;;; Section 5.5 -- define-record-type
;;; -----------------------------------------------------------------------

(news "\n--- 5.5 define-record-type ---\n")

;;; Basic record: point with x and y fields (both mutable)
(define-record-type <point>
  (make-point x y)
  point?
  (x point-x set-point-x!)
  (y point-y set-point-y!))

(define p1 (make-point 3 4))
(test-assert "drt/point?"     (point? p1))
(test-equal "drt/point?/non"  #f (point? 42))
(test-equal "drt/point?/pair" #f (point? '(a b)))
(test-equal "drt/point-x"     3   (point-x p1))
(test-equal "drt/point-y"     4   (point-y p1))

(set-point-x! p1 10)
(set-point-y! p1 20)
(test-equal "drt/set-x!" 10  (point-x p1))
(test-equal "drt/set-y!" 20  (point-y p1))

;;; Read-only record: immutable pair (no mutators)
(define-record-type <ipair>
  (make-ipair head tail)
  ipair?
  (head ipair-head)
  (tail ipair-tail))

(define ip (make-ipair 'a '(b c)))
(test-assert "drt/ipair?"    (ipair? ip))
(test-equal "drt/ipair?/non" #f (ipair? p1))
(test-equal "drt/ipair-head" 'a       (ipair-head ip))
(test-equal "drt/ipair-tail" '(b c)   (ipair-tail ip))

;;; Predicate distinguishes different record types
(test-equal "drt/pred/cross1" #f (point? ip))
(test-equal "drt/pred/cross2" #f (ipair? p1))

;;; Record with single field
(define-record-type <box>
  (make-box value)
  box?
  (value unbox set-box!))

(define b (make-box 99))
(test-assert "drt/box?" (box? b))
(test-equal "drt/unbox" 99   (unbox b))
(set-box! b 100)
(test-equal "drt/set-box!" 100  (unbox b))

;;; Two independent instances are not eq? to each other
(define b2 (make-box 100))
(test-equal "drt/box/not-eq" #f (eq? b b2))
(test-assert "drt/box/equal" (equal? (unbox b) (unbox b2)))

;;; Records are not eq? to plain vectors with same values
(test-equal "drt/not-vector" #f (point? (vector 0 3 4)))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2.2  let*-values
;;; -----------------------------------------------------------------------

(news "\n--- 4.2.2 let*-values ---\n")
(test-equal "let*-values/basic" 3       ;;; a=1 b=2 c=3; (* a c)=3
  (let*-values (((a b) (values 1 2))
                ((c)   (+ a b)))
    (* a c)))
(test-equal "let*-values/chain" 7       ;;; x=3 y=4 z=7 w=7
  (let*-values (((x y) (values 3 4))
                ((z)   (+ x y))
                ((w)   (* z 1)))
    w))
(test-equal "let*-values/single" '(a b)
  (let*-values (((p q) (values 'a 'b)))
    (list p q)))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2.10  call-with-current-continuation
;;; -----------------------------------------------------------------------

(news "\n--- 4.2.10 call-with-current-continuation ---\n")
(test-exception "call/cc/normal" 5
  (call-with-current-continuation (lambda (k) 5)))
(test-exception "call/cc/escape" 42
  (call-with-current-continuation (lambda (k) (k 42))))
(test-exception "call/cc/abort" 3
  (+ 1 (call-with-current-continuation (lambda (k) (+ 100 (k 2))))))
(test-assert-exception "call/cc/proc?"
  (procedure? (call-with-current-continuation (lambda (k) k))))
(test-exception "call/cc-alias" 42
  (call/cc (lambda (k) (k 42))))
(test-exception "call/cc/reentry" '(0 1 2)
  (let ((result '()) (k-save #f))
    (call-with-current-continuation (lambda (k) (set! k-save k)))
    (when (< (length result) 3)
      (set! result (append result (list (length result))))
      (k-save #f))
    result))

(news "\n--- dynamic-wind ---\n")
(test-exception "dynamic-wind/order" '(before during after)
  (let ((log '()))
    (dynamic-wind
      (lambda () (set! log (append log '(before))))
      (lambda () (set! log (append log '(during))))
      (lambda () (set! log (append log '(after)))))
    log))
(test-exception "dynamic-wind/escape" '(before during after done)
  (let ((log '()))
    (call-with-current-continuation
      (lambda (k)
        (dynamic-wind
          (lambda () (set! log (append log '(before))))
          (lambda () (set! log (append log '(during))) (k #f))
          (lambda () (set! log (append log '(after)))))))
    (set! log (append log '(done)))
    log))
(test-exception "dynamic-wind/raise" '(before after)
  (let ((log '()))
    (guard (e (#t log))
      (dynamic-wind
        (lambda () (set! log (append log '(before))))
        (lambda () (raise 'oops))
        (lambda () (set! log (append log '(after))))))))

(news "\n--- call-with-values ---\n")
(test-equal "call-with-values/basic" 3
  (call-with-values (lambda () (values 1 2)) +))
(test-equal "call-with-values/single" 42
  (call-with-values (lambda () 42) (lambda (x) x)))
(test-equal "call-with-values/multi" '(a b c)
  (call-with-values (lambda () (values 'a 'b 'c)) list))

;;; -----------------------------------------------------------------------
;;; R7RS 6.2  Additional R7RS number operations
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 square ---\n")
(test-equal "square/0"   0     (square 0))
(test-equal "square/5"   25    (square 5))
(test-equal "square/-3"  9     (square -3))
(test-equal "square/1.5" 2.25  (square 1.5))

(news "--- 6.2 floor-quotient / floor-remainder / floor/ ---\n")
(test-equal "floor-quotient/pp"  3    (floor-quotient 10 3))
(test-equal "floor-quotient/np"  -4   (floor-quotient -10 3))
(test-equal "floor-quotient/pn"  -4   (floor-quotient 10 -3))
(test-equal "floor-quotient/nn"  3    (floor-quotient -10 -3))
(test-equal "floor-remainder/pp" 1    (floor-remainder 10 3))
(test-equal "floor-remainder/np" 2    (floor-remainder -10 3))
(test-equal "floor-remainder/pn" -2   (floor-remainder 10 -3))
(test-equal "floor-remainder/nn" -1   (floor-remainder -10 -3))
(test-equal "floor//vals"        '(3 1)
  (let-values (((q r) (floor/ 10 3))) (list q r)))
(test-equal "floor//neg" '(-4 2)
  (let-values (((q r) (floor/ -10 3))) (list q r)))

(news "--- 6.2 truncate-quotient / truncate-remainder / truncate/ ---\n")
(test-equal "truncate-quotient/pp"  3    (truncate-quotient 10 3))
(test-equal "truncate-quotient/np"  -3   (truncate-quotient -10 3))
(test-equal "truncate-quotient/pn"  -3   (truncate-quotient 10 -3))
(test-equal "truncate-quotient/nn"  3    (truncate-quotient -10 -3))
(test-equal "truncate-remainder/pp" 1    (truncate-remainder 10 3))
(test-equal "truncate-remainder/np" -1   (truncate-remainder -10 3))
(test-equal "truncate-remainder/pn" 1    (truncate-remainder 10 -3))
(test-equal "truncate-remainder/nn" -1   (truncate-remainder -10 -3))
(test-equal "truncate//vals"        '(3 1)
  (let-values (((q r) (truncate/ 10 3))) (list q r)))
(test-equal "truncate//neg" '(-3 -1)
  (let-values (((q r) (truncate/ -10 3))) (list q r)))

(news "--- 6.2 exact-integer-sqrt ---\n")
(test-equal "exact-integer-sqrt/0" '(0 0)
  (let-values (((s r) (exact-integer-sqrt 0))) (list s r)))
(test-equal "exact-integer-sqrt/1" '(1 0)
  (let-values (((s r) (exact-integer-sqrt 1))) (list s r)))
(test-equal "exact-integer-sqrt/4" '(2 0)
  (let-values (((s r) (exact-integer-sqrt 4))) (list s r)))
(test-equal "exact-integer-sqrt/14" '(3 5)
  (let-values (((s r) (exact-integer-sqrt 14))) (list s r)))
(test-equal "exact-integer-sqrt/25" '(5 0)
  (let-values (((s r) (exact-integer-sqrt 25))) (list s r)))
(test-equal "exact-integer-sqrt/26" '(5 1)
  (let-values (((s r) (exact-integer-sqrt 26))) (list s r)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.2  Rational numbers
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 rational numbers ---\n")

;;; Detect whether this build has LL_RATIONAL support via the reader.
;;; string->number does not parse rationals; read does.
;;; On boards without LL_RATIONAL, 1/3 is read as an unbound symbol, not a number.
(define ll-has-rational?
  (number? (read (open-input-string "1/3"))))

(if (not ll-has-rational?)
  (skip "6.2 rational numbers (LL_RATIONAL not enabled on this board)")
  (begin

    ;;; Reader literals
    (test-equal "rat/reader-half"  1/2    1/2)
    (test-equal "rat/reader-neg"  -3/4   -3/4)
    (test-equal "rat/reader-reduce" 3/2    6/4)            ;;; reader normalizes
    (test-equal "rat/reader-to-int" 2      4/2)            ;;; denominator 1 -> integer

    ;;; Predicates
    (test-assert  "rat/number?"    (number?   1/3))
    (test-assert  "rat/rational?"  (rational? 1/3))
    (test-assert  "rat/real?"      (real?     1/3))
    (test-equal "rat/integer?"  #f (integer?  1/3))
    (test-assert  "rat/exact?"     (exact?    1/3))
    (test-equal "rat/inexact?"  #f (inexact?  1/3))
    (test-assert  "rat/rational?/float" (rational? 1.5))   ;;; finite inexact reals are rational (R7RS)
    (test-equal "rat/rational?/inf" #f (rational? +inf.0))

    ;;; numerator / denominator
    (test-equal "rat/numerator"    1      (numerator   1/3))
    (test-equal "rat/denominator"  3      (denominator 1/3))
    (test-equal "rat/numerator/neg" -1      (numerator  -1/3))
    (test-equal "rat/denominator/neg" 3      (denominator -1/3))
    (test-equal "rat/numerator/int" 5      (numerator   5))
    (test-equal "rat/denominator/int" 1      (denominator 5))

    ;;; zero? positive? negative?
    (test-equal "rat/zero?"     #f (zero?     1/3))
    (test-assert  "rat/zero?/0"    (zero?     0/1))       ;;; 0/anything -> integer 0
    (test-assert  "rat/positive?"  (positive? 1/3))
    (test-equal "rat/positive?/n" #f (positive? -1/3))
    (test-assert  "rat/negative?"  (negative? -1/3))
    (test-equal "rat/negative?/p" #f (negative? 1/3))

    ;;; Arithmetic -- exact results
    (test-equal "rat/add"          5/6    (+ 1/2 1/3))
    (test-equal "rat/sub"          1/6    (- 1/2 1/3))
    (test-equal "rat/mul"          1/6    (* 1/2 1/3))
    (test-equal "rat/div"          3/2    (/ 1/2 1/3))
    (test-equal "rat/add-int"      5/3    (+ 2/3 1))
    (test-equal "rat/mul-reduce"   1/4    (* 1/2 1/2))
    (test-equal "rat/div-to-int"   2      (/ 1/2 1/4))
    (test-equal "rat/negate"      -1/3    (- 1/3))
    (test-equal "rat/recip"        3/1    (/ 1/3))        ;;; 3/1 normalizes to 3
    (test-equal "rat/recip/int"    3      (/ 1/3))

    ;;; Mixed exact/inexact -> inexact
    (test-assert  "rat/add-inexact" (inexact? (+ 1/2 0.5)))
    (test-assert  "rat/mul-inexact" (inexact? (* 1/3 1.0)))

    ;;; Comparisons
    (test-assert  "rat/eq"         (= 1/2 1/2))
    (test-assert  "rat/eq-int"     (= 2/4 1/2))
    (test-assert  "rat/lt"         (< 1/3 1/2))
    (test-equal "rat/lt-false"  #f (< 1/2 1/3))
    (test-assert  "rat/le"         (<= 1/3 1/3))
    (test-assert  "rat/gt"         (> 1/2 1/3))
    (test-assert  "rat/ge"         (>= 1/2 1/2))
    (test-assert  "rat/chain"      (< 1/4 1/3 1/2 2/3))

    ;;; abs
    (test-equal "rat/abs/pos"      1/3    (abs  1/3))
    (test-equal "rat/abs/neg"      1/3    (abs -1/3))

    ;;; max / min
    (test-equal "rat/max"          2/3    (max 1/3 1/2 2/3))
    (test-equal "rat/min"          1/3    (min 1/3 1/2 2/3))

    ;;; floor / ceiling / truncate / round
    (test-equal "rat/floor/pos"    1      (floor    7/4))
    (test-equal "rat/floor/neg"   -2      (floor   -7/4))
    (test-equal "rat/ceiling/pos"  2      (ceiling  7/4))
    (test-equal "rat/ceiling/neg" -1      (ceiling -7/4))
    (test-equal "rat/truncate/pos" 1      (truncate 7/4))
    (test-equal "rat/truncate/neg" -1      (truncate -7/4))
    (test-equal "rat/round/down"   1      (round    5/4))  ;;; 1.25 -> 1
    (test-equal "rat/round/up"     2      (round    7/4))  ;;; 1.75 -> 2
    (test-equal "rat/round/half-even-2" 2      (round    5/2))  ;;; 2.5 -> 2 (banker's)
    (test-equal "rat/round/half-even-4" 4      (round    7/2))  ;;; 3.5 -> 4 (banker's)

    ;;; exact->inexact / inexact->exact
    (test-assert  "rat/e2i/inexact" (inexact? (exact->inexact 1/3)))
    (test-assert  "rat/e2i/approx" (< (abs (- (exact->inexact 1/3) 0.333333)) 1e-5))
    (test-assert  "rat/i2e/exact"  (exact? (inexact->exact 0.5)))
    (test-equal       "rat/i2e/half" 1/2    (inexact->exact 0.5))
    (test-equal       "rat/i2e/int" 3      (inexact->exact 3.0))

    ;;; expt
    (test-equal "rat/expt/pos"     1/8    (expt 1/2 3))
    (test-equal "rat/expt/neg"     8      (expt 1/2 -3))
    (test-equal "rat/expt/zero"    1      (expt 1/3 0))

    ;;; number->string
    (test-equal "rat/n2s"          "1/3"  (number->string 1/3))
    (test-equal "rat/n2s/neg"      "-1/3" (number->string -1/3))

  )) ;;; end ll-has-rational?

;;; gcd / lcm -- do not require LL_RATIONAL
(test-equal "rat/gcd/ints" 4      (gcd 12 8))
(test-equal "rat/lcm/ints" 12     (lcm 4 6))

;;; -----------------------------------------------------------------------
;;; R7RS 6.2  Complex numbers
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 complex numbers ---\n")
(test-assert "complex?/int"  (complex? 5))
(test-assert "complex?/real" (complex? 3.14))
(if ll-has-rational? (test-assert "complex?/rat" (complex? 1/3)) (skip "complex?/rat"))
(define c1 (make-rectangular 3 4))
(test-assert "complex?/cpx"  (complex? c1))
(test-equal "real-part/cpx"  3    (real-part c1))
(test-equal "imag-part/cpx"  4    (imag-part c1))
(test-equal "real-part/real" 5    (real-part 5))
(test-equal "imag-part/real" 0    (imag-part 5))
(test-equal "magnitude/cpx"  5    (magnitude (make-rectangular 3 4)))
(test-equal "magnitude/neg"  3    (magnitude -3))
(test-equal "magnitude/zero" 0    (magnitude 0))
(test-equal "angle/pos"      0    (angle 1))
(test-assert "angle/neg"     (let ((a (angle -1)))
                                   (< (abs (- a (* 4 (atan 1.0)))) 1e-5)))
(define c2 (make-rectangular 0 1))
(test-equal "make-rectangular/r" 0    (real-part c2))
(test-equal "make-rectangular/i" 1    (imag-part c2))
(define c3 (make-polar 2 0))
(test-assert "make-polar/r" (< (abs (- (real-part c3) 2.0)) 1e-5))
(test-assert "make-polar/i" (< (abs (imag-part c3)) 1e-5))
(define ca (make-rectangular 1 2))
(define cb (make-rectangular 3 4))
(test-assert "cpx-add" (= (+ ca cb) (make-rectangular 4 6)))
(test-assert "cpx-sub" (= (- cb ca) (make-rectangular 2 2)))
(test-assert "cpx-mul" (= (* ca cb) (make-rectangular -5 10)))
(test-assert "cpx-div" (let ((q (/ ca cb))) ;;; (1+2i)/(3+4i) = 11/25 + 2/25*i
                                   (and (< (abs (- (real-part q) 0.44)) 1e-5)
                                        (< (abs (- (imag-part q) 0.08)) 1e-5))))
(test-assert "cpx-sqrt-neg" (let ((r (sqrt -1)))
                                   (< (abs (- (imag-part r) 1)) 1e-5)))
(test-assert "cpx-number?" (number? (make-rectangular 1 2)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.4  list-copy
;;; -----------------------------------------------------------------------

(news "\n--- 6.4 list-copy ---\n")
(test-equal "list-copy/basic"  '(1 2 3)  (list-copy '(1 2 3)))
(test-equal "list-copy/nil"    '()       (list-copy '()))
(test-equal "list-copy/not-eq" #f
  (let ((l '(1 2 3))) (eq? l (list-copy l))))
(test-assert  "list-copy/car-eq"
  (let* ((item (list 'x)) (l (list item)) (l2 (list-copy l)))
    (eq? (car l) (car l2))))    ; shallow copy -- car is shared

;;; -----------------------------------------------------------------------
;;; R7RS 6.6  char-foldcase
;;; -----------------------------------------------------------------------

(news "\n--- 6.6 char-foldcase ---\n")
(test-equal "char-foldcase/upper" #\a  (char-foldcase #\A))
(test-equal "char-foldcase/lower" #\a  (char-foldcase #\a))
(test-equal "char-foldcase/digit" #\5  (char-foldcase #\5))
(test-equal "char-foldcase/z"     #\z  (char-foldcase #\Z))

;;; -----------------------------------------------------------------------
;;; R7RS 6.7  string-foldcase
;;; -----------------------------------------------------------------------

(news "\n--- 6.7 string-foldcase ---\n")
(test-equal "string-foldcase/upper" "hello" (string-foldcase "HELLO"))
(test-equal "string-foldcase/mixed" "world" (string-foldcase "World"))
(test-equal "string-foldcase/lower" "abc"   (string-foldcase "abc"))
(test-equal "string-foldcase/empty" ""      (string-foldcase ""))

;;; -----------------------------------------------------------------------
;;; R7RS 6.12  make-parameter / parameterize
;;; -----------------------------------------------------------------------

(news "\n--- 6.12 parameters ---\n")
;;; make-parameter / parameterize may be unbound; guard the defines so later tests still run.
(define r7-p  (guard (e (#t #f)) (make-parameter 10)))
(define r7-p2 (guard (e (#t #f)) (make-parameter 5 (lambda (x) (* x 2)))))
(test-exception "make-parameter/get"   10   (r7-p))
(test-exception "parameterize/local"   20   (parameterize ((r7-p 20)) (r7-p)))
(test-exception "parameterize/restore" 10   (begin (parameterize ((r7-p 20)) #f) (r7-p)))
(test-exception "parameterize/nested"  30
  (parameterize ((r7-p 20))
    (parameterize ((r7-p 30)) (r7-p))))
(test-exception "parameterize/outer" 20
  (parameterize ((r7-p 20))
    (parameterize ((r7-p 30)) #f)
    (r7-p)))
(test-exception "parameterize/body-val"     99   (parameterize ((r7-p 5)) 99))
(test-exception "make-parameter/conv"       10   (r7-p2))
(test-exception "parameterize/conv"         6    (parameterize ((r7-p2 3)) (r7-p2)))
(test-exception "parameterize/conv-restore" 10 (begin (parameterize ((r7-p2 3)) #f) (r7-p2)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.13  Ports and I/O
;;; -----------------------------------------------------------------------

;;; --- coverage added 2026-08-29: exercised by the chibi R7RS suite, absent here ---------
(test-equal "write-bytevector/count" 3
       (let ((o (open-output-string)))
         (write-bytevector (bytevector 65 66 67) o)
         (string-length (get-output-string o))))
(test-equal "write-bytevector/bytes" "ABC"
       (let ((o (open-output-string)))
         (write-bytevector (bytevector 65 66 67) o)
         (get-output-string o)))

(news "\n--- 6.13 port predicates ---\n")
(test-assert "input-port?/stdin"   (input-port?  (current-input-port)))
(test-assert "output-port?/stdout" (output-port? (current-output-port)))
(test-assert "output-port?/stderr" (output-port? (current-error-port)))
(test-assert "port?/in"            (port? (current-input-port)))
(test-assert "port?/out"           (port? (current-output-port)))
(test-equal "port?/num"            #f (port? 42))
(test-equal "port?/str"            #f (port? "hello"))
(test-assert "input-port-open?"    (input-port-open?  (current-input-port)))
(test-assert "output-port-open?"   (output-port-open? (current-output-port)))

(news "--- 6.13 string input ports ---\n")
(let ((p (open-input-string "hello")))
  (test-assert  "open-input-string/port?" (input-port? p))
  (test-equal "read-char/h"  #\h  (read-char p))
  (test-equal "peek-char/e"  #\e  (peek-char p))
  (test-equal "read-char/e"  #\e  (read-char p))
  (test-assert  "char-ready?"     (char-ready? p))
  (test-equal "read-char/l"  #\l  (read-char p)))

(let ((p (open-input-string "(1 2 3) 42")))
  (test-equal "read/list"    '(1 2 3) (read p))
  (test-equal "read/num"     42       (read p))
  (test-assert  "read/eof"            (eof-object? (read p))))

(test-assert "eof-object?/eof"  (eof-object? (read  (open-input-string ""))))
(test-equal "eof-object?/num"   #f (eof-object? 42))
(test-equal "eof-object?/str"   #f (eof-object? ""))
(test-assert "eof-object?/char" (eof-object? (read-char (open-input-string ""))))

(let ((p (open-input-string "first line\nsecond line")))
  (test-equal "read-line/1" "first line"   (read-line p))
  (test-equal "read-line/2" "second line"  (read-line p))
  (test-assert "read-line/eof"         (eof-object? (read-line p))))

(news "--- 6.13 string output ports ---\n")
(let ((p (open-output-string)))
  (test-assert  "open-output-string/port?" (output-port? p))
  (write 42 p)
  (test-equal "write/num"  "42"      (get-output-string p)))

(let ((p (open-output-string)))
  (display "hello" p)
  (test-equal "display/str" "hello"   (get-output-string p)))

(let ((p (open-output-string)))
  (write "hi" p)
  (test-equal "write/str"  "\"hi\""  (get-output-string p)))

(let ((p (open-output-string)))
  (write-char #\A p)
  (test-equal "write-char" "A"       (get-output-string p)))

(let ((p (open-output-string)))
  (write-string "xyz" p)
  (test-equal "write-string" "xyz"     (get-output-string p)))

(let ((p (open-output-string)))
  (write-string "abcde" p 1 3)
  (test-equal "write-string/sub" "bc"     (get-output-string p)))

(let ((p (open-output-string)))
  (newline p)
  (test-equal "newline/port" "\n"      (get-output-string p)))

(news "--- 6.13 bytevector ports ---\n")
(let ((p (open-input-bytevector (bytevector 10 20 30))))
  (test-equal "read-u8/1"   10   (read-u8 p))
  (test-equal "peek-u8/2"   20   (peek-u8 p))
  (test-equal "read-u8/2"   20   (read-u8 p))
  (test-assert "u8-ready?"       (u8-ready? p))
  (test-assert "read-u8/eof"     (eof-object? (begin (read-u8 p) (read-u8 p)))))

(let ((p (open-output-bytevector)))
  (test-assert  "open-output-bvec/port?" (output-port? p))
  (write-u8 42 p)
  (write-u8 99 p)
  (test-equal "get-output-bytevector" (bytevector 42 99) (get-output-bytevector p)))

(news "--- 6.13 call-with-port ---\n")
(test-equal "call-with-port/read" '(1 2)
  (call-with-port (open-input-string "(1 2)") read))
(test-equal "call-with-port/write" "42"
  (call-with-port (open-output-string) (lambda (p) (write 42 p) (get-output-string p))))

(news "--- 6.13 with-exception-handler in port ops ---\n")
(test-error "read-char/closed"
  (let ((p (open-input-string "")))
      (close-input-port p)
      (read-char p)))

;;; -----------------------------------------------------------------------
;;; B96 -- equal? must TERMINATE on cyclic structure (R7RS 6.1: "equal? ... must
;;; always terminate even if its arguments contain cycles").  Also exercises the
;;; datum-label write<->read round-trip end to end.  Format-independent (uses
;;; equal?/eq?, not exact printed strings).
;;; -----------------------------------------------------------------------
(news "--- B96 cyclic equal? ---\n")
(test-assert "equal?/cyclic-cdr-terminates"
  (let ((a (list 1 2 3)) (b (list 1 2 3)))
    (set-cdr! (cddr a) a) (set-cdr! (cddr b) b)
    (equal? a b)))
(test-equal "equal?/cyclic-cdr-different" #f
  (let ((a (list 1 2 3)) (b (list 1 2 9)))
    (set-cdr! (cddr a) a) (set-cdr! (cddr b) b)
    (equal? a b)))
(test-assert "equal?/cyclic-car-terminates"
  (let ((a (list 0 0)) (b (list 0 0)))
    (set-car! a a) (set-car! b b)
    (equal? a b)))
(test-assert "equal?/cyclic-cdr-roundtrip"
  (let ((c (list 1 2 3)))
    (set-cdr! (cddr c) c)
    (equal? c (read (open-input-string
                     (let ((p (open-output-string))) (write c p) (get-output-string p)))))))
(test-assert "equal?/cyclic-car-roundtrip"
  (let ((v (list 0 0)))
    (set-car! v v)
    (equal? v (read (open-input-string
                     (let ((p (open-output-string))) (write v p) (get-output-string p)))))))

;;; -----------------------------------------------------------------------
;;; Summary
;;; -----------------------------------------------------------------------


;;; =======================================================================
;;; R7RS-small spec-example coverage additions (de-novo audit, 2026-08-12)
;;; Every evaluation example the report prints that was not already present
;;; verbatim.  Green = must pass; check-exception = accepted call/cc-family
;;; gap (B1); check-guard/check-error = reveals a real gap (fails visibly).
;;; =======================================================================
(news "\n--- spec-audit: primitive & derived expressions (4.1-4.2) ---\n")
(test-equal "quote/empty-list"              '() '())
(test-equal "lambda/rest-all"               '(3 4 5 6) ((lambda x x) 3 4 5 6))
(test-equal "cond/else-equal"               'equal (cond ((> 3 3) 'greater) ((< 3 3) 'less) (else 'equal)))
(test-equal "let-values/exact-integer-sqrt" 35 (let-values (((root rem) (exact-integer-sqrt 32))) (* root rem)))
(test-equal "let*-values/swap"              '(x y x y)
  (let ((a 'a) (b 'b) (x 'x) (y 'y))
    (let*-values (((a b) (values x y)) ((x y) (values a b))) (list a b x y))))
(test-equal "delay/stream-integers" 2
  (let () (define integers (letrec ((next (lambda (n) (delay (cons n (next (+ n 1))))))) (next 0)))
    (define (stream-car s) (car (force s))) (define (stream-cdr s) (cdr (force s)))
    (stream-car (stream-cdr (stream-cdr integers)))))
(test-equal "delay/count-memoized" '(6 6)
  (let () (define count 0) (define x 5)
    (define p (delay (begin (set! count (+ count 1)) (if (> count x) count (force p)))))
    (let ((first (force p))) (set! x 10) (list first (force p)))))
(define spec-range (case-lambda ((e) (spec-range 0 e))
                                ((b e) (do ((r '() (cons b r)) (b b (+ b 1))) ((>= b e) (reverse r))))))
(test-equal "case-lambda/range-1arg" '(0 1 2) (spec-range 3))
(test-equal "case-lambda/range-2arg" '(3 4) (spec-range 3 5))
(test-equal "quasiquote/nested-foo"  '(a (quasiquote (b (unquote (foo 3)) d)) e) `(a `(b ,(foo ,(+ 1 2)) d) e))

(news "--- spec-audit: macros, define, equivalence, booleans (4.3/5/6.1/6.3) ---\n")
(test-equal "let-syntax/given-that" 'now
  (let-syntax ((given-that (syntax-rules () ((given-that t s1 s2 ...) (if t (begin s1 s2 ...))))))
    (let ((if #t)) (given-that if (set! if 'now)) if)))
(test-equal "let-syntax/referential-transparency" 'outer
  (let ((x 'outer)) (let-syntax ((m (syntax-rules () ((m) x)))) (let ((x 'inner)) (m)))))
;; B109 (FIXED): a free template identifier bound to a user-defined PROCEDURE or MACRO resolves in
;; the DEFINITION scope, not the use scope (R7RS 4.3.1 referential transparency).  Verified vs Chez
;; and Chibi (both give 500 / 20).  Fixed by CHICKEN-style def-env aliasing in sr_expand_ann.
(define (b109-helper x) (* x 100))
(define-syntax b109-use-helper (syntax-rules () ((_ n) (b109-helper n))))
(test-equal "syntax-rules/hygiene-free-procedure" 500
  (let ((b109-helper (lambda (x) (+ x 1)))) (b109-use-helper 5)))
(define-syntax b109-dbl (syntax-rules () ((_ x) (* 2 x))))
(define-syntax b109-use-dbl (syntax-rules () ((_ n) (b109-dbl n))))
(test-equal "syntax-rules/hygiene-free-macro" 20
  (let-syntax ((b109-dbl (syntax-rules () ((_ x) (+ 1 x))))) (b109-use-dbl 10)))
;; B121: a macro may MUTATE a free variable -- a free template identifier must expand to a live
;; binding reference, not a snapshot of its value (a quoted value cannot be a set! target).
(define b121-counter 0)
(define-syntax b121-bump (syntax-rules () ((_) (set! b121-counter (+ b121-counter 1)))))
(test-equal "syntax-rules/set!-free-variable" 2 (begin (b121-bump) (b121-bump) b121-counter))
(define b121-seen 0)
(define-syntax b121-read (syntax-rules () ((_) b121-seen)))
(test-equal "syntax-rules/free-ref-is-live" 7 (begin (set! b121-seen 7) (b121-read)))
(test-equal "letrec-syntax/my-or"           7
  (letrec-syntax ((my-or (syntax-rules () ((my-or) #f) ((my-or e) e)
                          ((my-or e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...)))))))
    (let ((x #f) (y 7) (temp 8) (let odd?) (if even?)) (my-or x (let temp) (if y) y))))
(define-syntax be-like-begin
  (syntax-rules () ((be-like-begin name)
    (define-syntax name (syntax-rules () ((name expr (... ...)) (begin expr (... ...))))))))
(be-like-begin spec-sequence)
(test-equal "syntax-rules/be-like-begin" 4 (spec-sequence 1 2 3 4))
(define-values (spec-root spec-rem) (exact-integer-sqrt 32))
(test-equal "define-values/exact-integer-sqrt" 35 (* spec-root spec-rem))
(define-record-type <pare> (kons x y) pare? (x kar set-kar!) (y kdr))
(test-assert "define-record-type/pare?-kons" (pare? (kons 1 2)))
(test-equal "define-record-type/pare?-cons"  #f (pare? (cons 1 2)))
(test-equal "define-record-type/kar"         1 (kar (kons 1 2)))
(test-equal "define-record-type/kdr"         2 (kdr (kons 1 2)))
(test-equal "define-record-type/set-kar!"    3 (let ((k (kons 1 2))) (set-kar! k 3) (kar k)))
(test-equal "eqv?/nan"                       #f (eqv? 0.0 +nan.0))
(test-assert "equal?/circular-datum-labels"  (equal? '#1=(a b . #1#) '#2=(a b a b . #2#)))

(news "--- spec-audit: numbers (6.2) modulo/remainder sign matrix + expt ---\n")
(test-equal "modulo/13-4"        1 (modulo 13 4))
(test-equal "remainder/13-4"     1 (remainder 13 4))
(test-equal "modulo/-13-4"       3 (modulo -13 4))
(test-equal "remainder/-13-4"    -1 (remainder -13 4))
(test-equal "modulo/13--4"       -3 (modulo 13 -4))
(test-equal "remainder/13--4"    1 (remainder 13 -4))
(test-equal "modulo/-13--4"      -1 (modulo -13 -4))
(test-equal "remainder/-13--4"   -1 (remainder -13 -4))
(test-equal "remainder/-13--4.0" -1.0 (remainder -13 -4.0))
;; B120: an INEXACT integer is still an integer (R7RS 6.2.6) -- result is inexact.
(test-equal "quotient/-13--4.0"                    3.0  (quotient -13 -4.0))
(test-equal "modulo/-13--4.0"                      -1.0  (modulo -13 -4.0))
(test-equal "remainder/-13.0-4"                    -1.0  (remainder -13.0 4))
(test-equal "floor-remainder/-13-4.0"              3.0 (floor-remainder -13 4.0))
(test-assert "remainder/inexact-result-is-inexact" (inexact? (remainder -13 -4.0)))
(test-equal "expt/0-0"                             1 (expt 0 0))

(news "--- spec-audit: pairs, lists, symbols (6.4/6.5) ---\n")
(test-equal "list?/cyclic-spec"           #f (list? (let ((x (list 'a))) (set-cdr! x x) x)))
(test-equal "make-list/2-3"               '(3 3) (make-list 2 3))
(test-equal "list-tail/abcd-2"            '(c d) (list-tail '(a b c d) 2))
(test-equal "string->symbol/mISSISSIppi"  'mISSISSIppi (string->symbol "mISSISSIppi"))
(test-assert "string->symbol/eq-bitBlt"   (eq? 'bitBlt (string->symbol "bitBlt")))
(test-assert "string->symbol/eq-LollyPop" (eq? 'LollyPop (string->symbol (symbol->string 'LollyPop))))

(news "--- spec-audit: vectors, bytevectors, control (6.8/6.9/6.10) ---\n")
(test-equal "vector-copy/mutable-copy" '#(3 8 2 8) (let* ((a '#(1 8 2 8)) (b (vector-copy a))) (vector-set! b 0 3) b))
(test-equal "vector-copy/range"        '#(8 2) (let* ((a '#(1 8 2 8)) (b (vector-copy a))) (vector-set! b 0 3) (vector-copy b 1 3)))
(test-equal "bytevector/6"             (bytevector 1 3 5 1 3 5) (bytevector 1 3 5 1 3 5))
(test-equal "bytevector/0"             (bytevector) (bytevector))
(test-equal "string->utf8/lambda"      (bytevector #xCE #xBB) (string->utf8 "λ"))
(test-equal "map/+uneven"              '(5 7 9) (map + '(1 2 3) '(4 5 6 7)))
(test-equal "cwv/values-4-5"           5 (call-with-values (lambda () (values 4 5)) (lambda (a b) b)))
(test-equal "cwv/star-minus"           -1 (call-with-values * -))

(news "--- spec-audit: eval, exceptions (6.11/6.12) ---\n")
(test-equal "eval/environment" 21 (eval '(* 7 3) (environment '(scheme base))))
;; raise-continuable resumption is part of the accepted call/cc-family gap (B1):
(test-exception "raise-continuable/65" 65
  (with-exception-handler
    (lambda (con) (if (string? con) 42 77))
    (lambda () (+ (raise-continuable "should be a number") 23))))
;; null-environment (B108 fixed): a syntax-only env; lambda (core) works, procedures are not visible.
(test-equal "eval/null-environment" 20
  (let ((f (eval '(lambda (f x) (f x x)) (null-environment 5)))) (f + 10)))
(test-error "null-environment/no-procedures"       ;; verify the split: `+` is NOT in null-env
  (eval '(+ 1 2) (null-environment 5)))
;; NOT added: R7RS's (string-set! <literal> ...) / (set-car! <constant> ...) "=> error" cases are
;; "it is an error" = UNDEFINED behavior; detection is OPTIONAL, so LambLisp not signalling is
;; conformant. They are not testable pass/fail evaluation examples (spec-permitted UB, not a defect).

;;; =======================================================================================
;;; R7RS-small LIBRARY COVERAGE -- inventory gap-fill.  A full inventory of the R7RS-small
;;; standard libraries (Appendix A) found these procedures IMPLEMENTED but previously not
;;; exercised by the suite; each is tested here so the conformance run accounts for the whole
;;; library.  The genuinely-unimplemented identifiers at the end are surfaced as EXCEPTIONS
;;; (deliberate embedded gaps) via check-true-exception, so they are enumerated in every report
;;; and auto-flip to PASS if ever implemented.
;;; =======================================================================================
(news "\n--- coverage: cxr (3rd/4th level) ---\n")
;; full binary tree of pairs to depth 4: every c[ad]{2,4}r path reaches a distinct node, so each
;; accessor is checked against its explicit car/cdr composition (correct by construction).
(define cxr-t
  (letrec ((mk (lambda (d n) (if (= d 0) n (cons (mk (- d 1) (* n 2)) (mk (- d 1) (+ (* n 2) 1)))))))
    (mk 4 1)))
(test-assert "caadr"  (eqv? (caadr cxr-t)  (car (car (cdr cxr-t)))))
(test-assert "cadar"  (eqv? (cadar cxr-t)  (car (cdr (car cxr-t)))))
(test-assert "cdaar"  (eqv? (cdaar cxr-t)  (cdr (car (car cxr-t)))))
(test-assert "cdadr"  (eqv? (cdadr cxr-t)  (cdr (car (cdr cxr-t)))))
(test-assert "cddar"  (eqv? (cddar cxr-t)  (cdr (cdr (car cxr-t)))))
(test-assert "caaaar" (eqv? (caaaar cxr-t) (car (car (car (car cxr-t))))))
(test-assert "caaadr" (eqv? (caaadr cxr-t) (car (car (car (cdr cxr-t))))))
(test-assert "caadar" (eqv? (caadar cxr-t) (car (car (cdr (car cxr-t))))))
(test-assert "caaddr" (eqv? (caaddr cxr-t) (car (car (cdr (cdr cxr-t))))))
(test-assert "cadaar" (eqv? (cadaar cxr-t) (car (cdr (car (car cxr-t))))))
(test-assert "cadadr" (eqv? (cadadr cxr-t) (car (cdr (car (cdr cxr-t))))))
(test-assert "caddar" (eqv? (caddar cxr-t) (car (cdr (cdr (car cxr-t))))))
(test-assert "cdaaar" (eqv? (cdaaar cxr-t) (cdr (car (car (car cxr-t))))))
(test-assert "cdaadr" (eqv? (cdaadr cxr-t) (cdr (car (car (cdr cxr-t))))))
(test-assert "cdadar" (eqv? (cdadar cxr-t) (cdr (car (cdr (car cxr-t))))))
(test-assert "cdaddr" (eqv? (cdaddr cxr-t) (cdr (car (cdr (cdr cxr-t))))))
(test-assert "cddaar" (eqv? (cddaar cxr-t) (cdr (cdr (car (car cxr-t))))))
(test-assert "cddadr" (eqv? (cddadr cxr-t) (cdr (cdr (car (cdr cxr-t))))))
(test-assert "cdddar" (eqv? (cdddar cxr-t) (cdr (cdr (cdr (car cxr-t))))))

(news "--- coverage: inexact trig ---\n")
(test-assert "sin/0"  (= (sin 0) 0))
(test-assert "cos/0"  (= (cos 0) 1))
(test-assert "tan/0"  (= (tan 0) 0))
(test-assert "asin/0" (= (asin 0) 0))
(test-assert "exp/0"  (= (exp 0) 1))

(news "--- coverage: ports ---\n")
(test-assert "textual-port?"     (textual-port? (open-output-string)))
(test-assert "binary-port?"      (binary-port?  (open-output-bytevector)))
(test-assert "eof-object"        (eof-object? (eof-object)))
(test-assert "close-port"        (let ((p (open-output-string))) (close-port p) (not (output-port-open? p))))
(test-assert "close-output-port" (let ((p (open-output-string))) (close-output-port p) #t))
(test-assert "flush-output-port" (let ((p (open-output-string))) (flush-output-port p) #t))
(test-equal "read-string"        "abc" (read-string 3 (open-input-string "abcdef")))
(test-assert "read-bytevector"   (equal? (read-bytevector 2 (open-input-bytevector (bytevector 1 2 3))) (bytevector 1 2)))
(test-assert "read-bytevector!"  (let ((bv (make-bytevector 3 0)))
                                 (read-bytevector! bv (open-input-bytevector (bytevector 9 8 7)))
                                 (equal? bv (bytevector 9 8 7))))

(news "--- coverage: write-simple / write-shared ---\n")
(test-equal "write-simple" "(1 2 3)" (let ((p (open-output-string))) (write-simple '(1 2 3) p) (get-output-string p)))
(test-equal "write-shared" "(1 2 3)" (let ((p (open-output-string))) (write-shared '(1 2 3) p) (get-output-string p)))

(news "--- coverage: cond-expand ---\n")
(test-equal "cond-expand/else" 'ok (cond-expand (else 'ok)))

(news "--- coverage: file I/O ---\n")
(test-equal "file/call-with" "hello"
  (begin (call-with-output-file "cov-tmp.txt" (lambda (p) (write-string "hello" p)))
         (call-with-input-file  "cov-tmp.txt" (lambda (p) (read-string 5 p)))))
(test-assert "file-exists?"     (file-exists? "cov-tmp.txt"))
(test-assert "delete-file"      (begin (delete-file "cov-tmp.txt") (not (file-exists? "cov-tmp.txt"))))
(test-equal "file/with-to-from" "world"
  (begin (with-output-to-file "cov-t2.txt" (lambda () (write-string "world")))
         (with-input-from-file "cov-t2.txt" (lambda () (read-string 5)))))
(test-assert "file/cleanup2" (begin (delete-file "cov-t2.txt") #t))
(test-equal "file/open"      "data"
  (begin (let ((p (open-output-file "cov-t3.txt"))) (write-string "data" p) (close-port p))
         (let* ((p (open-input-file "cov-t3.txt")) (s (read-string 4 p))) (close-port p) s)))
(test-assert "file/cleanup3" (begin (delete-file "cov-t3.txt") #t))
(test-assert "file/binary"
  (begin (let ((p (open-binary-output-file "cov-b.bin"))) (write-u8 65 p) (write-u8 66 p) (close-port p))
         (let* ((p (open-binary-input-file "cov-b.bin")) (a (read-u8 p)) (b (read-u8 p)))
           (close-port p) (delete-file "cov-b.bin") (and (= a 65) (= b 66)))))

(news "--- coverage: syntax-error ---\n")
(test-error "syntax-error" (eval '(syntax-error "boom") (interaction-environment)))

(news "--- coverage: include-ci ---\n")
;; include-ci reads case-insensitively: DEFINE folds to define, so cov-inc-val gets bound.
(call-with-output-file "cov-inc.scm" (lambda (p) (write-string "(DEFINE cov-inc-val 42)" p)))
(include-ci "cov-inc.scm")
(test-equal "include-ci" 42 cov-inc-val)
(delete-file "cov-inc.scm")

;;; R7RS 5.6 -- the LIBRARY system: define-library / import / export / import-sets.  The library
;;; system is a DELIBERATE design gap on this hard-real-time embedded target (like call/cc and
;;; dynamic-wind): the whole program is one image, so per-library namespaces add no value.  These
;;; are EXERCISED and counted as EXCEPTIONS (not failures) so every report enumerates them, and each
;;; auto-flips to PASS if the library system is ever implemented.
(news "--- 5.6 library system (embedded design gap) ---\n")
(test-exception "define-library/import" 42
  (begin
    (define-library (conform testlib)
      (export answer)
      (begin (define answer 42)))
    (import (conform testlib))
    answer))
(test-exception "import/only" 1
  (begin (define-library (conform onlylib) (export a b) (begin (define a 1) (define b 2)))
         (import (only (conform onlylib) a)) a))
(test-exception "import/except" 2
  (begin (define-library (conform exclib) (export a b) (begin (define a 1) (define b 2)))
         (import (except (conform exclib) a)) b))
(test-exception "import/prefix" 1
  (begin (define-library (conform prelib) (export a) (begin (define a 1)))
         (import (prefix (conform prelib) pre:)) pre:a))
(test-exception "import/rename" 1
  (begin (define-library (conform renlib) (export a) (begin (define a 1)))
         (import (rename (conform renlib) (a aa))) aa))

;;; (scheme process-context) + (features) -- now implemented (ll_xmop3_platform_generic.cpp).
;;; exit/emergency-exit are tested for existence + type ONLY (never invoked -- they terminate).
(news "--- coverage: process-context + features ---\n")
(test-assert "features"                  (and (list? (features)) (memq 'r7rs (features)) #t))
(test-assert "command-line"              (list? (command-line)))
(test-assert "get-environment-variable"  (let ((v (get-environment-variable "PATH"))) (or (string? v) (eq? v #f))))
(test-assert "get-environment-variables" (list? (get-environment-variables)))
(test-assert "exit"                      (procedure? exit))
(test-assert "emergency-exit"            (procedure? emergency-exit))

(news "--- coverage: file-error? / read-error? ---\n")
;; open-input-file on a missing file signals a file-error (R7RS); read signals a read-error on
;; malformed input.  Verify each predicate recognizes its own kind and NOT the other / user errors.
(test-assert "file-error?"                (file-error? (guard (e (#t e)) (open-input-file "no-such-file-zzz999.scm"))))
(test-assert "file-error?/not-user"       (not (file-error? (guard (e (#t e)) (error "plain user error")))))
(test-assert "file-error?/not-read"       (not (file-error? (guard (e (#t e)) (read (open-input-string "(1 2"))))))
(test-assert "read-error?/eof"            (read-error? (guard (e (#t e)) (read (open-input-string "(1 2")))))
(test-assert "read-error?/bad-bytevector" (read-error? (guard (e (#t e)) (read (open-input-string "#u8(300)")))))
(test-assert "read-error?/not-user"       (not (read-error? (guard (e (#t e)) (error "plain user error")))))
(test-assert "read-error?/not-file"       (not (read-error? (guard (e (#t e)) (open-input-file "no-such-file-zzz999.scm")))))

;;; =======================================================================
;;; Ported from chibi-scheme tests/r7rs-tests.scm (2026-08-29)
;;; =======================================================================
;;; Cases chibi's suite exercises that LambLisp's own suite never did.  Most of chibi's 981
;;; assertions duplicate coverage already above -- the identifier measurement puts LambLisp at 424
;;; distinct procedures against chibi's 378 -- so this section is deliberately NOT a transcription.
;;; It is the RESIDUE: the places where an independently written suite looked somewhere ours never
;;; did.  The residue is small, and it was not empty, which is the argument for keeping it.
;;;
;;; The largest find: LambLisp had ~900 assertions about numbers and NONE of them fed a prefixed
;;; literal to the READER -- they all went through `string->number'.  The two are separate parsers.
;;; They disagree.  See B171 / B172 / B174.

(news "\n--- chibi 6.2: numeric literal syntax, READER + WRITER round trip ---\n")
;;; chibi's `test-numeric-syntax' in procedure form: read the text, check the VALUE, then write the
;;; value back and check the text is one of the accepted spellings.  Reading alone is half a test --
;;; a reader and a writer that are wrong in the same direction agree with each other.
(define (ll-read-str s)  (read (open-input-string s)))
(define (ll-write-str x) (let ((o (open-output-string))) (write x o) (get-output-string o)))
(define (num-syntax name str expect writes)
  (test-equal (string-append "num/" name "/read") expect (ll-read-str str))
  (test-assert (string-append "num/" name "/write")
               (and (member (ll-write-str (ll-read-str str)) writes) #t)))

(num-syntax "1"        "1"      1     '("1"))
(num-syntax "+1"       "+1"     1     '("1"))
(num-syntax "-1"       "-1"    -1     '("-1"))
(num-syntax "1.0"      "1.0"    1.0   '("1.0" "1."))
(num-syntax "1dot"     "1."     1.0   '("1.0" "1."))
(num-syntax "dot1"     ".1"     0.1   '("0.1" ".1" "100.0e-3"))
(num-syntax "-dot1"    "-.1"   -0.1   '("-0.1" "-.1" "-100.0e-3"))
(num-syntax "1e2"      "1e2"    100.0 '("100.0" "100."))
(num-syntax "1E2"      "1E2"    100.0 '("100.0" "100."))
(num-syntax "bignum"   "123456789012345678901234567890"
            123456789012345678901234567890 '("123456789012345678901234567890"))

;;; Radix prefixes.  #d and the lower-case radices on a POSITIVE integer are the subset our own
;;; suite happened to cover, and they pass.
(num-syntax "b101"     "#b101"  5     '("5"))
(num-syntax "o777"     "#o777"  511   '("511"))
(num-syntax "x1f"      "#x1f"   31    '("31"))
(num-syntax "xAB"      "#xAB"   171   '("171"))
(num-syntax "d10"      "#d10"   10    '("10"))
(num-syntax "d-10"     "#d-10" -10    '("-10"))
(num-syntax "e10"      "#e10"   10    '("10"))
(num-syntax "i1"       "#i1"    1.0   '("1.0" "1."))
(num-syntax "i-1"      "#i-1"  -1.0   '("-1.0" "-1."))
(num-syntax "i1.5"     "#i1.5"  1.5   '("1.5"))

;;; B171 -- a SIGN after a radix prefix is dropped and the reader silently returns 0.
;;; These FAIL on purpose and must keep failing until B171 is fixed.  `string->number' gets every
;;; one of them right, which is the whole point: two parsers, one stale.
(num-syntax "x-1f"     "#x-1f" -31    '("-31"))
(num-syntax "b-101"    "#b-101" -5    '("-5"))
(num-syntax "o-777"    "#o-777" -511  '("-511"))

;;; B171 -- combined exactness+radix prefixes, required by R7RS 7.1.1 in EITHER order.
(num-syntax "e-x10"    "#e#x10" 16    '("16"))
(num-syntax "x-e10"    "#x#e10" 16    '("16"))

;;; B171 -- uppercase prefixes.  R7RS 2.1: letters are case-insensitive outside character and
;;; string constants.  `string->number' accepts all of these; the reader raises.
(num-syntax "X1f"      "#X1f"   31    '("31"))
(num-syntax "B101"     "#B101"  5     '("5"))
(num-syntax "O777"     "#O777"  511   '("511"))
(num-syntax "D10"      "#D10"   10    '("10"))
(num-syntax "I1"       "#I1"    1.0   '("1.0" "1."))

;;; B171 -- under a prefix the reader parses a leading integer and DISCARDS the rest of the token.
;;; `#e1e10' off by a factor of 10^10, with no diagnostic, is the worst of these.
(num-syntax "e1/2"     "#e1/2"  1/2   '("1/2"))
(num-syntax "i1/2"     "#i1/2"  0.5   '("0.5" ".5"))
(num-syntax "e1.5"     "#e1.5"  3/2   '("3/2"))
(num-syntax "e1e10"    "#e1e10" 10000000000 '("10000000000"))
(num-syntax "i1e2"     "#i1e2"  100.0 '("100.0" "100."))

;;; Rationals and complex read correctly (both types are implemented; only the PREFIXED forms
;;; above are broken).
(num-syntax "1/2"      "1/2"    1/2   '("1/2"))
(num-syntax "6/3"      "6/3"    2     '("2"))
(num-syntax "1+2i"     "1+2i"   1+2i  '("1+2i"))

;;; infnan.  The reader accepts the lower-case spellings; equal? on NaN is #f by definition, so
;;; NaN is checked with the predicate rather than by comparison.
(test-equal  "num/+inf.0/read"  +inf.0 (ll-read-str "+inf.0"))
(test-equal  "num/-inf.0/read"  -inf.0 (ll-read-str "-inf.0"))
(test-assert "num/+nan.0/read"  (nan? (ll-read-str "+nan.0")))
(test-equal  "num/1e400/read"   +inf.0 (ll-read-str "1e400"))
(test-equal  "num/+inf.0/write" "+inf.0" (ll-write-str +inf.0))
(test-equal  "num/-inf.0/write" "-inf.0" (ll-write-str -inf.0))
;;; B172 -- uppercase infnan reads as a SYMBOL, which is the quiet kind of wrong: it binds and
;;; prints without complaint where a number was meant.
(test-equal  "num/+INF.0/read"  +inf.0 (ll-read-str "+INF.0"))
(test-equal  "num/+Inf.0/read"  +inf.0 (ll-read-str "+Inf.0"))
(test-assert "num/+NAN.0/read"  (nan? (ll-read-str "+NAN.0")))
;;; B172 -- string->number rejects every infnan literal that the reader accepts.
(test-equal  "num/s->n/+inf.0"  +inf.0 (string->number "+inf.0"))
(test-equal  "num/s->n/-inf.0"  -inf.0 (string->number "-inf.0"))
(test-assert "num/s->n/+nan.0"  (nan? (string->number "+nan.0")))
(test-equal  "num/s->n/1e400"   +inf.0 (string->number "1e400"))
;;; B174 -- #e must yield an EXACT number.  LambLisp has T_RATIONAL, so 3/2 is representable;
;;; this is a parser gap, not a missing numeric type.
(test-equal  "num/s->n/#e1.0"   1     (string->number "#e1.0"))
(test-equal  "num/s->n/#e1.5"   3/2   (string->number "#e1.5"))
(test-equal  "num/s->n/#e1e10"  10000000000 (string->number "#e1e10"))
(test-assert "num/s->n/#e-exact" (exact? (string->number "#e1.0")))

(news "--- chibi 6.13: symbol write syntax (|...| bars) ---\n")
;;; chibi's `test-write-syntax': a symbol whose name is not readable bare must be written with
;;; bars, so that write output reads back as the same symbol.  Round-trip, not just output shape.
(define (sym-write name obj expect)
  (test-equal (string-append "symwrite/" name) expect (ll-write-str obj))
  (test-equal (string-append "symwrite/" name "/roundtrip") obj (ll-read-str (ll-write-str obj))))
(sym-write "dot"       '|.|        "|.|")
(sym-write "space"     '|a b|      "|a b|")
(sym-write "comma"     '|,a|       "|,a|")
(sym-write "empty"     '||         "||")
(sym-write "digit"     '|2|        "|2|")
(sym-write "plus3"     '|+3|       "|+3|")
(sym-write "minusdot4" '|-.4|      "|-.4|")
;;; B176 -- these three are written WITHOUT bars, so write->read returns a NUMBER, not
;;; the symbol.  A type change across a round trip, with no error raised anywhere.
(sym-write "plusi"     '|+i|       "|+i|")
(sym-write "inf"       '|+inf.0|   "|+inf.0|")
(sym-write "nan"       '|+nan.0|   "|+nan.0|")
;;; A symbol that IS readable bare must NOT be barred -- writing "|a|" for 'a is legal but ugly,
;;; and chibi asserts the plain form.
(test-equal "symwrite/plain" "a" (ll-write-str '|a|))

(news "--- chibi 6.13: read errors on malformed input ---\n")
;;; chibi's `test-read-error'.  LambLisp's suite tested read-error? on two inputs; these are the
;;; rest of chibi's list.  An input that is malformed must RAISE, not return a value.
(define (read-fails name str)
  (test-assert (string-append "readerr/" name)
               (guard (e (#t #t)) (read (open-input-string str)) #f)))
(read-fails "unterminated-list"   "(1 2")
;;; B175 (FIXED 2026-08-29) -- this used to SEGFAULT: the string scanner did not stop at EOF, so
;;; autobuf_t::upsize() announced `overflow 65544 > 65536' ~66k times while the append kept writing
;;; past the clamped buffer until the process died.  It lived after the summary so the crash could
;;; not swallow the other ~950 results; now it is back inline with its siblings.
(read-fails "unterminated-string" "\"abc")
(read-fails "unterminated-bvec"   "#u8(1 2")
(read-fails "bvec-overflow"       "#u8(300)")
(read-fails "bad-dot"             "(1 . 2 3)")
(read-fails "close-only"          ")")

(news "--- chibi 4.3.2: syntax-rules corner cases ---\n")
;;; The ellipsis ESCAPE `(... x)': inside a template, (... x) means a literal x, ellipsis and all.
;;; It is how a macro writes a macro.  LambLisp's own suite never used it.
(define-syntax elli-esc-1
  (syntax-rules ()
    ((_)     '(... ...))
    ((_ x)   '(... (x ...)))
    ((_ x y) '(... (... x y)))))
(test-equal "sr/ellipsis-escape/0" '...     (elli-esc-1))
(test-equal "sr/ellipsis-escape/1" '(a ...) (elli-esc-1 a))

;;; A macro that DEFINES a macro -- the escape's reason for existing.
(define-syntax be-like-begin1
  (syntax-rules ()
    ((be-like-begin1 name)
     (define-syntax name
       (syntax-rules ()
         ((name expr (... ...))
          (begin expr (... ...))))))))
(be-like-begin1 sequence1)
(test-equal "sr/macro-defining-macro" 3 (sequence1 0 1 2 3))

;;; `_' is a wildcard in a PATTERN but an ordinary symbol in a TEMPLATE (R7RS 4.3.2).
(define-syntax underscore
  (syntax-rules ()
    ((foo _) '_)))
(test-equal "sr/underscore-in-template" '_ (underscore foo))

;;; `_' matches without binding, so several may appear in one pattern.
(define-syntax count-to-2
  (syntax-rules ()
    ((_) 0)
    ((_ _) 1)
    ((_ _ _) 2)
    ((_ . _) 'many)))
(test-equal "sr/underscore-arity" '(2 0 many)
            (list (count-to-2 a b) (count-to-2) (count-to-2 a b c d)))

;;; A LITERAL takes priority over the ellipsis: with `...' declared literal, it matches itself.
(define-syntax elli-lit-1
  (syntax-rules ... (...)
    ((_ x) '(x ...))))
;;; B179 -- the alternate `(syntax-rules <ellipsis> (literals) rules)' form of R7RS 4.3.2
;;; is unimplemented and raises an internal Lamb::car() Bad type rather than a Scheme error.
(test-equal "sr/literal-beats-ellipsis" '(100 ...) (elli-lit-1 100))

(news "--- chibi 6.13: closed ports ---\n")
;;; chibi checks the port PREDICATES after a close, and that writing to a closed port signals.
;;; LambLisp's suite closed ports but never asked what the port then reported about itself.
(test-equal "port/output-open?/after-close" #f
            (let ((o (open-output-string))) (close-output-port o) (output-port-open? o)))
(test-equal "port/input-open?/after-close" #f
            (let ((i (open-input-string "abc"))) (close-input-port i) (input-port-open? i)))
;;; chibi asserts that writing to a closed port signals.  R7RS says only that a closed port is
;;; "incapable of accepting characters" -- writing to one is "an error", i.e. UNDEFINED behavior,
;;; and detection is OPTIONAL.  LambLisp not signalling is therefore CONFORMANT, so the assertion
;;; is on what is actually specified: the write must not corrupt the already-captured output.
;;; (Same convention as the string-set!-on-a-literal note in 6.7 above.)
(test-equal "port/closed-output-preserved" "hi"
            (let ((o (open-output-string)))
              (write-string "hi" o)
              (let ((captured (get-output-string o)))
                (close-output-port o)
                (guard (e (#t #t)) (write-char #\a o))
                captured)))
(test-assert "port/close-twice-ok"
             (let ((o (open-output-string)))
               (close-output-port o) (close-output-port o) #t))

(news "--- chibi: assorted residue ---\n")
;;; `,@' outside quasiquote is still a DATUM: (read "'(1 ,@2)") is a list containing an
;;; unquote-splicing form, not an error.  Tests that the reader's abbreviation table is complete.
(test-equal "read/unquote-splicing-datum"
            '(quote (1 (unquote-splicing 2)))
            (ll-read-str "'(1 ,@2)"))
(test-equal "read/unquote-datum"
            '(quote (1 (unquote 2)))
            (ll-read-str "'(1 ,2)"))
(test-equal "read/quasiquote-datum"
            '(quasiquote (1 2))
            (ll-read-str "`(1 2)"))

;;; B177 -- define-values accepts only a proper NON-EMPTY formals list.  R7RS 5.3.3 gives it
;;; lambda's full <formals> grammar, so all three shapes below are required; the two here
;;; escape as internal Lamb::car() Bad type errors.
(test-equal "define-values/zero" 'ok
            (let () (define-values () (values)) 'ok))
(test-equal "define-values/rest" '(1 2 3)
            (let () (define-values (a . rest) (values 1 2 3)) (cons a rest)))

;;; list-set! on a literal-free list.
(test-equal "list-set!" '(0 ("Sue" "Sue") "Anna")
            (let ((ls (list 0 '(2 2 2 2) "Anna")))
              (list-set! ls 1 (list "Sue" "Sue"))
              ls))

;;; `do' returning the accumulator, and a named let building two lists -- chibi's shapes, which
;;; exercise the step/test/command split more than our own do tests.
(test-equal "do/vector-fill" '#(0 1 2 3 4)
            (do ((vec (make-vector 5))
                 (i 0 (+ i 1)))
                ((= i 5) vec)
              (vector-set! vec i i)))
(test-equal "do/sum" 25
            (let ((x '(1 3 5 7 9)))
              (do ((x x (cdr x))
                   (sum 0 (+ sum (car x))))
                  ((null? x) sum))))
(test-equal "named-let/partition" '((6 1 3) (-5 -2))
            (let loop ((numbers '(3 -2 1 6 -5)) (nonneg '()) (neg '()))
              (cond ((null? numbers) (list nonneg neg))
                    ((>= (car numbers) 0)
                     (loop (cdr numbers) (cons (car numbers) nonneg) neg))
                    (else
                     (loop (cdr numbers) nonneg (cons (car numbers) neg))))))

;;; B177 -- a bare symbol formal, the third shape R7RS 5.3.3 requires.
(test-equal "define-values/symbol" '(1 2 3)
            (let () (define-values all (values 1 2 3)) all))

;;; -----------------------------------------------------------------------
;;; Summary
;;; -----------------------------------------------------------------------

(test-summary "R7RS TEST SUMMARY (SRFI-64)")

(define r7rs-srfi64-pass      *s64-pass*)
(define r7rs-srfi64-fail      *s64-fail*)
(define r7rs-srfi64-exception *s64-exception*)
(define r7rs-srfi64-exception-names s64-exception-names)
;; Expected exceptions in a clean run: call/cc (6) + dynamic-wind (3) + make-parameter/parameterize
;; (9) + raise-continuable (1) + library system (5) = 24.  All are deliberate hard-real-time
;; embedded design gaps.  If this number ever DROPS, a gap closed -- lower the baseline.  If it
;; RISES, something regressed.
(define r7rs-srfi64-exception-expected 24)
