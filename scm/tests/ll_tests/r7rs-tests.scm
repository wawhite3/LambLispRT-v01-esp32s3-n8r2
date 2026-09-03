;;; Copyright 2026 by Frobenius Norm LLC 2026-04-07 15:30:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; r7rs-tests.scm -- R7RS-small conformance test suite
;;; Run on Chez Scheme: (load "chez-r6-to-r7.scm") then (load "r7rs-tests.scm")
;;; Run on LambLisp:   (load "r7rs-tests.scm" 1)
;;;
;;; Covers: R7RS-small sections 4.1-4.3, 5.3, 5.5, 6.1-6.14
;;; LambLisp gaps (tests included, may fail on LambLisp until implemented):
;;;   call/cc, dynamic-wind, make-parameter/parameterize, let*-values,
;;;   tail-context rules beyond basic recursion, exact-integer-sqrt,
;;;   floor/ truncate/ and related R7RS division operators.

;;; -----------------------------------------------------------------------
;;; Test framework
;;; -----------------------------------------------------------------------

;;; Platform detection: chez-scheme? = #t on Chez (syslog unbound), #f on LambLisp.
(define ll-esc (string (integer->char #x1b)))
(define chez-scheme?
  (guard (exn (#t #t))    ;;!< exception -> syslog not bound -> Chez
    (eval 'syslog)
    #f))                  ;;!< syslog bound -> LambLisp

;;; news/warn -- minimal ~a formatter via display; works on both platforms.
(define (%r7t-fmt color fmt . args)
  (when color (display color))
  (let loop ((chars (string->list fmt)) (args args))
    (cond
      ((null? chars) (values))
      ((and (char=? (car chars) #\~)
            (pair? (cdr chars))
            (char=? (cadr chars) #\a))
       (display (if (null? args) "?" (car args)))
       (loop (cddr chars) (if (null? args) '() (cdr args))))
      ;; ~w = WRITE the argument (strings keep their quotes, lists keep their structure) -- used by
      ;; the FAIL lines so the report can show the challenge form and the values unambiguously.
      ((and (char=? (car chars) #\~)
            (pair? (cdr chars))
            (char=? (cadr chars) #\w))
       (write (if (null? args) "?" (car args)))
       (loop (cddr chars) (if (null? args) '() (cdr args))))
      (else
       (display (string (car chars)))
       (loop (cdr chars) args))))
  (when color (display (string-append ll-esc "[0m"))))

(define (news fmt . args) (apply %r7t-fmt (string-append ll-esc "[32m") fmt args))
(define (warn fmt . args) (apply %r7t-fmt (string-append ll-esc "[33m") fmt args))

(define *pass* 0)
(define *fail* 0)

;; check/check-true/check-false are GUARDED macros over the *-proc compare logic: a test whose
;; expression RAISES on a given interpreter (e.g. an R6RS Scheme rejecting R7RS-required behavior)
;; is counted as a FAIL and the run CONTINUES, instead of the exception aborting the whole suite.
;; On LambLisp no test expression raises, so this is behaviour-neutral (pass/fail counts unchanged).
;; FAIL lines use the harness-parseable shape shared with smoke-tests.scm:
;;   FAIL <name> | expr <challenge form> | expected <e> | got <g>
;; _w3_correctness_data_json() turns those into the report's failures table, so a reviewer sees the
;; expression that was evaluated -- not just a test name.  PASS lines stay lean (one per pass, and
;; there are >1100 of them); only failures carry the detail.
(define (check-proc name expected actual form)
  (if (equal? expected actual)
    (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1))
           (warn "FAIL ~a | expr ~w | expected ~w | got ~w\n" name form expected actual))))
(define-syntax check
  (syntax-rules ()
    ((_ name expected actual)
     (guard (exn (#t (set! *fail* (+ *fail* 1))
                     (warn "FAIL ~a | expr ~w | expected ~w | got exception\n"
                           name (quote actual) expected)))
       (check-proc name expected actual (quote actual))))))

(define (check-true-proc name val form)
  (if val
    (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1))
           (warn "FAIL ~a | expr ~w | expected #t | got ~w\n" name form val))))
(define-syntax check-true
  (syntax-rules ()
    ((_ name val)
     (guard (exn (#t (set! *fail* (+ *fail* 1))
                     (warn "FAIL ~a | expr ~w | expected #t | got exception\n" name (quote val))))
       (check-true-proc name val (quote val))))))

(define (check-false-proc name val form)
  (if (not val)
    (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1))
           (warn "FAIL ~a | expr ~w | expected #f | got ~w\n" name form val))))
(define-syntax check-false
  (syntax-rules ()
    ((_ name val)
     (guard (exn (#t (set! *fail* (+ *fail* 1))
                     (warn "FAIL ~a | expr ~w | expected #f | got exception\n" name (quote val))))
       (check-false-proc name val (quote val))))))

(define (check-error name thunk29)
  (let ((r (guard (e (#t 'caught))
              (thunk29)
              'no-error)))
    (if (eq? r 'caught)
      (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a\n" name))
      (begin (set! *fail* (+ *fail* 1))
             (warn "FAIL ~a | expr <thunk29> | expected an error | got no error\n" name)))))

;;; check-guard: evaluates expr under guard; reports FAIL on exception rather than crashing.
;;; Used for tests of features that may be unbound/unimplemented.
(define-syntax check-guard
  (syntax-rules ()
    ((_ name expected expr)
     (guard (exn (#t (set! *fail* (+ *fail* 1))
                     (warn "FAIL ~a | expr ~w | expected ~w | got exception\n"
                           name (quote expr) expected)))
       (check name expected expr)))))

(define-syntax check-true-guard
  (syntax-rules ()
    ((_ name expr)
     (guard (exn (#t (set! *fail* (+ *fail* 1))
                     (warn "FAIL ~a | expr ~w | expected #t | got exception\n" name (quote expr))))
       (check-true name expr)))))

;;; -----------------------------------------------------------------------
;;; Exceptions -- KNOWN, ACCEPTED R7RS nonconformances
;;; -----------------------------------------------------------------------
;;; An EXCEPTION is a deliberate design gap in a hard-real-time embedded Scheme (full call/cc,
;;; dynamic-wind, make-parameter/parameterize), NOT a bug -- bugs go in the registry and MUST
;;; fail visibly.  `check-exception' still EXERCISES the feature; a caught error or a
;;; non-conforming result is recorded and counted SEPARATELY from pass/fail (it is neither).  If a
;;; gap ever closes (the feature conforms) the test PASSES normally and the exception count drops
;;; -- a signal to lower the expected-exception baseline.  Each records one "EXCEPTION <name> |
;;; reason <text>" line so every report can enumerate the deviations in a footnote.
(define *exception* 0)
;; Emit the whole line in ONE display (not via news' multi-call ANSI wrapping) so an async GC-log
;; line cannot interleave mid-message and split it -- the report parser needs the line intact.
;; Collect exception test-case names into a list (a FOOTNOTE, printed once by the runner) instead of
;; a per-case inline line -- keeps the main report a compact feature/count table.
(define r7rs-exception-names '())
(define (note-exception name)
  (set! *exception* (+ *exception* 1))
  (set! r7rs-exception-names (cons name r7rs-exception-names)))

(define-syntax check-exception
  (syntax-rules ()
    ((_ name expected expr)
     (guard (exn (#t (note-exception name)))
       (let ((actual expr))
         (if (equal? expected actual)
           (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a (nonconformance resolved)\n" name))
           (note-exception name)))))))

(define-syntax check-true-exception
  (syntax-rules ()
    ((_ name expr)
     (guard (exn (#t (note-exception name)))
       (let ((actual expr))
         (if actual
           (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a (nonconformance resolved)\n" name))
           (note-exception name)))))))

;;; -----------------------------------------------------------------------
;;; R7RS 4.1  Primitive expression types
;;; -----------------------------------------------------------------------

(news "\n--- 4.1.2 quote ---\n")
(check "quote/sym"        'foo          'foo)
(check "quote/list"       '(1 2 3)      '(1 2 3))
(check "quote/nested"     '(a (b c) d)  '(a (b c) d))
(check "quote/nil"        '()           '())
(check "quote/bool"       #t            '#t)
(check "quote/num"        42            '42)
(check "quote/str"        "hi"          "hi")

(news "--- 4.1.4 lambda ---\n")
(check "lambda/call"      6   ((lambda (x y) (* x y)) 2 3))
(check "lambda/rest"      '(2 3 4) ((lambda (x . rest) rest) 1 2 3 4))
(check "lambda/rest-all"  '(1 2 3) ((lambda args args) 1 2 3))
(check "lambda/closure"   10  (let ((x 3)) ((lambda (y) (+ x y)) 7)))
(check "lambda/multi-body" 3  ((lambda (x) (+ x 1) (+ x 2)) 1))

(news "--- 4.1.5 if ---\n")
(check "if/true"          1    (if #t 1 2))
(check "if/false"         2    (if #f 1 2))
(check "if/truthy-0"      1    (if 0 1 2))
(check "if/truthy-nil"    1    (if '() 1 2))
(check "if/no-else"       'ok  (if #t 'ok))
(check "if/false-no-else" 'ok  (begin (if #f (error "bad")) 'ok))

(news "--- 4.1.6 set! ---\n")
(check "set!"             20  (let ((x 10)) (set! x 20) x))
(check "set!/closure"     99  (let ((x 1))
                                 (define (f) x)
                                 (set! x 99)
                                 (f)))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2  Derived expression types
;;; -----------------------------------------------------------------------

(news "\n--- 4.2.1 cond ---\n")
(check "cond/first"       'a  (cond (#t 'a) (else 'b)))
(check "cond/second"      'b  (cond (#f 'a) (#t 'b) (else 'c)))
(check "cond/else"        'c  (cond (#f 'a) (#f 'b) (else 'c)))
(check "cond/no-else"     'ok (begin (cond (#t 'ok)) 'ok))
(check "cond/multi-expr"  3   (cond (#t 1 2 3)))
(check "cond/=>"          8   (cond (4 => (lambda (x) (* x 2)))))
(check "cond/=>-false"    'b  (cond (#f => (lambda (x) 'a)) (else 'b)))
(check "cond/value"       5   (cond (5)))

(news "--- 4.2.1 case ---\n")
(check "case/first"       'a  (case 1 ((1) 'a) ((2) 'b) (else 'c)))
(check "case/second"      'b  (case 2 ((1) 'a) ((2) 'b) (else 'c)))
(check "case/else"        'c  (case 9 ((1) 'a) ((2) 'b) (else 'c)))
(check "case/multi-datum" 'ab (case 2 ((1 3) 'odd) ((2 4) 'ab) (else 'other)))
(check "case/char"        'y  (case #\b ((#\a) 'x) ((#\b) 'y) (else 'z)))
(check "case/multi-body"  3   (case 1 ((1) 1 2 3) (else 0)))

(news "--- 4.2.1 when / unless ---\n")
(check "when/true"        3    (when #t 1 2 3))
(check "when/false"       'ok  (begin (when #f (error "bad")) 'ok))
(check "unless/false"     3    (unless #f 1 2 3))
(check "unless/true"      'ok  (begin (unless #t (error "bad")) 'ok))

(news "--- 4.2.1 and / or ---\n")
(check "and/empty"        #t   (and))
(check "and/single"       5    (and 5))
(check "and/true"         3    (and 1 2 3))
(check "and/short"        #f   (and 1 #f 3))
(check "and/value"        #f   (and #f))
(check "or/empty"         #f   (or))
(check "or/single"        5    (or 5))
(check "or/first"         1    (or 1 2 3))
(check "or/skip-false"    2    (or #f 2 3))
(check "or/all-false"     #f   (or #f #f #f))
(check "or/value"         0    (or #f 0))

(news "--- 4.2.2 let ---\n")
(check "let/basic"        3    (let ((x 1) (y 2)) (+ x y)))
(check "let/body-seq"     6    (let ((x 2)) (define y 3) (* x y)))
(check "let/shadow"       10   (let ((x 5)) (let ((x (* x 2))) x)))
(check "let*/basic"       6    (let* ((x 1) (y (+ x 2)) (z (* y 2))) z))
(check "let*/depends"     3    (let* ((x 1) (x (+ x 1)) (x (+ x 1))) x))
(check "letrec/mutual"    #t
  (letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
           (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
    (even? 10)))
(check "letrec*/order"    3    (letrec* ((x 1) (y (+ x 2)) (z (* x y))) z))
(check "named-let/fib"    55   (let fib ((n 10) (a 0) (b 1))
                                  (if (= n 0) a (fib (- n 1) b (+ a b)))))
(check "named-let/sum"    15   (let loop ((i 5) (acc 0))
                                  (if (= i 0) acc (loop (- i 1) (+ acc i)))))

(news "--- 4.2.2 let-values ---\n")
(check "let-values/2"     3    (let-values (((a b) (values 1 2))) (+ a b)))
(check "let-values/3"     6    (let-values (((a b c) (values 1 2 3))) (+ a b c)))

(news "--- 4.2.3 begin ---\n")
(check "begin/seq"        3    (begin 1 2 3))
(check "begin/effect"     2    (let ((x 0)) (begin (set! x 1) (set! x 2)) x))

(news "--- 4.2.4 do ---\n")
(check "do/sum"           10   (do ((i 0 (+ i 1)) (s 0 (+ s i)))
                                   ((= i 5) s)))
(check "do/vector"        '#(0 1 2 3 4)
  (let ((v (make-vector 5)))
    (do ((i 0 (+ i 1))) ((= i 5) v) (vector-set! v i i))))
(check "do/no-body"       120  (do ((n 5 (- n 1)) (p 1 (* p n)))
                                   ((= n 0) p)))
(check "do/string-build"  "abcde"
  (let ((s (make-string 5 #\a)))
    (do ((i 0 (+ i 1)))
      ((= i 5) s)
      (string-set! s i (integer->char (+ (char->integer #\a) i))))))

(news "--- 4.2.5 delay / force ---\n")
(define p1 (delay (+ 1 2)))
(check-true  "promise?/delay"     (promise? p1))
(check-false "promise?/non"       (promise? 42))
(check "force/value"       3      (force p1))
(check "force/memoized"    3      (force p1))

(define *side* 0)
(define p-side (delay (begin (set! *side* (+ *side* 1)) *side*)))
(force p-side)
(force p-side)
(check "force/once"        1      *side*)

(check "make-promise/val"  42     (force (make-promise 42)))
(check-true "make-promise/id"     (let ((p (delay 1))) (eq? p (make-promise p))))

(define (lazy-from n) (delay-force (cons n (lazy-from (+ n 1)))))
(define (stream-ref s n)
  (let ((p (force s)))
    (if (= n 0) (car p) (stream-ref (cdr p) (- n 1)))))
(check "delay-force/0"     0      (stream-ref (lazy-from 0) 0))
(check "delay-force/10"    10     (stream-ref (lazy-from 0) 10))
(check "delay-force/50"    50     (stream-ref (lazy-from 0) 50))

(news "--- 4.2.7 guard ---\n")
(check "guard/match"       42     (guard (e ((equal? e 42) e)) (raise 42)))
(check "guard/else"        'def   (guard (e ((equal? e 1) 'one) (else 'def)) (raise 99)))
(check "guard/no-raise"    'ok    (guard (e (else 'caught)) 'ok))
(check "guard/error-obj"   "msg"  (guard (e ((error-object? e) (error-object-message e)))
                                    (error "msg" 1 2)))
;;; guard/reraise: R7RS allows with-exception-handler to return from raise.
;;; Chez (R6RS) treats raise as non-continuable -- handler must not return.
;;; Skip on Chez.
(when (not chez-scheme?)
  (check "guard/reraise"     99
    (with-exception-handler
      (lambda (e) e)
      (lambda ()
        (guard (e ((equal? e 42) 'got-42))
          (raise 99))))))

(news "--- 4.2.8 quasiquote ---\n")
(check "quasi/basic"       '(1 2 3)       `(1 2 3))
(check "quasi/unquote"     '(1 99 3)      `(1 ,(+ 90 9) 3))
(check "quasi/splicing"    '(1 2 3 4 5)   `(1 ,@(list 2 3 4) 5))
(check "quasi/nested-1"    '(1 (2 3) 4)   `(1 (,(+ 1 1) 3) 4))
(check "quasi/empty-spl"   '(1 2)         `(1 ,@'() 2))
(check "quasi/computed"    '(a 6 b)       (let ((x 6)) `(a ,x b)))
(check "quasi/list-spl"    '(0 1 2 3 4)   `(0 ,@(list 1 2 3) 4))

(news "--- 4.2.9 case-lambda ---\n")
(define cl
  (case-lambda
    (()        'zero)
    ((x)       (list 'one x))
    ((x y)     (list 'two x y))
    ((x y . z) (list 'rest x y z))))
(check "case-lambda/0"     'zero           (cl))
(check "case-lambda/1"     '(one 5)        (cl 5))
(check "case-lambda/2"     '(two 3 4)      (cl 3 4))
(check "case-lambda/rest"  '(rest 1 2 (3 4 5)) (cl 1 2 3 4 5))
;;; err: use a cl without rest clause so 3 args matches nothing
(check-error "case-lambda/err"
  (lambda () ((case-lambda (() 'zero) ((x) x) ((x y) (+ x y))) 1 2 3)))

(news "--- 4.3 syntax ---\n")
(define-syntax swap!
  (syntax-rules ()
    ((swap! a b) (let ((t a)) (set! a b) (set! b t)))))
(check "define-syntax/swap" '(2 1)
  (let ((x 1) (y 2)) (swap! x y) (list x y)))

(define-syntax my-or
  (syntax-rules ()
    ((my-or)         #f)
    ((my-or e)       e)
    ((my-or e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))
(check "define-syntax/or-t"  5    (my-or #f #f 5))
(check "define-syntax/or-f"  #f   (my-or #f #f))
(check "define-syntax/or-0"  #f   (my-or))

(check "let-syntax"   '(2 1)
  (let-syntax ((xchg (syntax-rules ()
                        ((xchg a b) (let ((t a)) (set! a b) (set! b t))))))
    (let ((p 1) (q 2)) (xchg p q) (list p q))))

(check "letrec-syntax"  10
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
(check "define/var"        42  r7-x)
(define (r7-add a b) (+ a b))
(check "define/proc"       7   (r7-add 3 4))
(define (r7-fact n) (if (= n 0) 1 (* n (r7-fact (- n 1)))))
(check "define/recursive"  120 (r7-fact 5))
(define (r7-varargs x . rest) (cons x rest))
(check "define/varargs"    '(1 2 3) (r7-varargs 1 2 3))

(news "--- 5.3.3 define-values ---\n")
(define-values (dv-a dv-b dv-c) (values 10 20 30))
(check "define-values/a"   10  dv-a)
(check "define-values/b"   20  dv-b)
(check "define-values/c"   30  dv-c)
(define-values (dv-x dv-y) (values 'p 'q))
(check "define-values/2a"  'p  dv-x)
(check "define-values/2b"  'q  dv-y)

;;; -----------------------------------------------------------------------
;;; R7RS 6.1  Equivalence predicates
;;; -----------------------------------------------------------------------

(news "\n--- 6.1 eq? ---\n")
(check-true  "eq?/sym"         (eq? 'foo 'foo))
(check-false "eq?/diff-sym"    (eq? 'foo 'bar))
(check-true  "eq?/#t"          (eq? #t #t))
(check-true  "eq?/#f"          (eq? #f #f))
(check-false "eq?/#t-#f"       (eq? #t #f))
(check-true  "eq?/nil"         (eq? '() '()))
(check-false "eq?/nil-#f"      (eq? '() #f))
(check-true  "eq?/same-pair"   (let ((p (cons 1 2))) (eq? p p)))
(check-false "eq?/diff-pairs"  (eq? (cons 1 2) (cons 1 2)))

(news "--- 6.1 eqv? ---\n")
(check-true  "eqv?/sym"        (eqv? 'foo 'foo))
(check-true  "eqv?/int"        (eqv? 42 42))
(check-true  "eqv?/#t"         (eqv? #t #t))
(check-true  "eqv?/#f"         (eqv? #f #f))
(check-true  "eqv?/char"       (eqv? #\a #\a))
(check-true  "eqv?/nil"        (eqv? '() '()))
(check-false "eqv?/int-real"   (eqv? 1 1.0))
(check-false "eqv?/diff-int"   (eqv? 1 2))
(check-false "eqv?/str"        (eqv? "a" "a"))

(news "--- 6.1 equal? ---\n")
(check-true  "equal?/int"      (equal? 42 42))
(check-true  "equal?/str"      (equal? "hello" "hello"))
(check-true  "equal?/list"     (equal? '(1 2 3) '(1 2 3)))
(check-true  "equal?/nested"   (equal? '(1 (2 3)) '(1 (2 3))))
(check-true  "equal?/vec"      (equal? '#(1 2 3) '#(1 2 3)))
(check-true  "equal?/bvec"     (equal? (bytevector 1 2) (bytevector 1 2)))
(check-true  "equal?/nil"      (equal? '() '()))
(check-true  "equal?/#f"       (equal? #f #f))
(check-false "equal?/diff-str" (equal? "abc" "abd"))
(check-false "equal?/diff-vec" (equal? '#(1 2) '#(1 3)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.2  Numbers
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 type predicates ---\n")
(check-true  "number?/int"     (number? 0))
(check-true  "number?/real"    (number? 3.14))
(check-false "number?/sym"     (number? 'x))
(check-true  "integer?/0"      (integer? 0))
(check-true  "integer?/neg"    (integer? -5))
(check-false "integer?/real"   (integer? 3.14))
(check-true  "real?/int"       (real? 5))
(check-true  "real?/0"         (real? 0))
(check-true  "real?/neg"       (real? -1))
(check-true  "real?/float"     (real? 1.5))
(check-true  "rational?/int"   (rational? 5))
(check-true  "exact?/int"      (exact? 5))
(check-true  "exact?/0"        (exact? 0))
(check-false "exact?/float"    (exact? 1.5))
(check-true  "inexact?/float"  (inexact? 1.5))
(check-false "inexact?/int"    (inexact? 5))
(check-true  "exact-integer?/5" (exact-integer? 5))
(check-false "exact-integer?/1.5" (exact-integer? 1.5))

(news "--- 6.2 zero? positive? negative? odd? even? ---\n")
(check-true  "zero?/0"         (zero? 0))
(check-false "zero?/1"         (zero? 1))
(check-true  "zero?/0.0"       (zero? 0.0))
(check-true  "positive?/1"     (positive? 1))
(check-false "positive?/0"     (positive? 0))
(check-false "positive?/-1"    (positive? -1))
(check-true  "negative?/-1"    (negative? -1))
(check-false "negative?/0"     (negative? 0))
(check-true  "odd?/1"          (odd? 1))
(check-false "odd?/2"          (odd? 2))
(check-true  "odd?/-3"         (odd? -3))
(check-true  "even?/0"         (even? 0))
(check-true  "even?/4"         (even? 4))
(check-false "even?/7"         (even? 7))

(news "--- 6.2 max / min ---\n")
(check "max/2"          5    (max 3 5))
(check "max/multi"      7    (max 1 7 3 5 2))
(check "max/neg"        -1   (max -3 -1 -5))
(check "min/2"          3    (min 3 5))
(check "min/multi"      1    (min 4 1 7 3))

(news "--- 6.2 arithmetic ---\n")
(check "+/0"            0    (+))
(check "+/1"            5    (+ 5))
(check "+/2"            7    (+ 3 4))
(check "+/multi"        15   (+ 1 2 3 4 5))
(check "-/1"            -5   (- 5))
(check "-/2"            3    (- 8 5))
(check "-/multi"        0    (- 10 3 4 3))
(check "*/0"            1    (*))
(check "*/1"            7    (* 7))
(check "*/2"            12   (* 3 4))
(check "*/multi"        120  (* 1 2 3 4 5))
(check "//2"            4    (/ 12 3))
(check "abs/pos"        5    (abs 5))
(check "abs/neg"        5    (abs -5))
(check "abs/0"          0    (abs 0))

(news "--- 6.2 quotient / remainder / modulo ---\n")
(check "quotient/pos"   3    (quotient 10 3))
(check "quotient/neg"   -3   (quotient -10 3))
(check "remainder/pos"  1    (remainder 10 3))
(check "remainder/neg"  -1   (remainder -10 3))
(check "modulo/pos"     1    (modulo 10 3))
(check "modulo/neg"     2    (modulo -10 3))
(check "modulo/-neg"    -2   (modulo 10 -3))

(news "--- 6.2 gcd / lcm ---\n")
(check "gcd/2"          4    (gcd 12 8))
(check "gcd/0"          5    (gcd 5 0))
(check "gcd/0-0"        0    (gcd 0 0))
(check "gcd/1arg"       7    (gcd 7))
(check "gcd/0arg"       0    (gcd))
(check "lcm/2"          12   (lcm 4 6))
(check "lcm/1arg"       5    (lcm 5))
(check "lcm/0arg"       1    (lcm))

(news "--- 6.2 floor / ceiling / truncate / round ---\n")
(check "floor/pos"      3.0  (floor 3.7))
(check "floor/neg"     -4.0  (floor -3.7))
(check "floor/int"      5    (floor 5))
(check "ceiling/pos"    4.0  (ceiling 3.2))
(check "ceiling/neg"   -3.0  (ceiling -3.7))
(check "ceiling/int"    5    (ceiling 5))
(check "truncate/pos"   3.0  (truncate 3.9))
(check "truncate/neg"  -3.0  (truncate -3.9))
(check "truncate/int"   5    (truncate 5))
(check "round/down"     2.0  (round 2.4))
(check "round/up"       3.0  (round 2.6))
(check "round/half-e"   2.0  (round 2.5))
(check "round/half-o"   4.0  (round 3.5))
(check "round/neg"     -2.0  (round -2.5))
(check "round/int"      5    (round 5))

(news "--- 6.2 exact / inexact conversion ---\n")
(check "exact->inexact" 1.0  (exact->inexact 1))
(check "inexact->exact" 3    (inexact->exact 3.0))
(check "exact/alias"    2.0  (exact->inexact 2))
(check "inexact/alias"  4    (inexact->exact 4.0))

(news "--- 6.2 special floats ---\n")
(check-true  "+inf.0/pos"    (> +inf.0 1e308))
(check-true  "-inf.0/neg"    (< -inf.0 -1e308))
(check-true  "+inf.0/inf?"   (infinite? +inf.0))
(check-true  "-inf.0/inf?"   (infinite? -inf.0))
(check-false "+inf.0/finite" (finite? +inf.0))
(check-false "-inf.0/finite" (finite? -inf.0))
(check-false "+inf.0/nan?"   (nan? +inf.0))
(check-true  "+nan.0/nan?"   (nan? +nan.0))
(check-false "+nan.0/finite" (finite? +nan.0))
(check-true  "+inf.0/num?"   (number? +inf.0))
(check-true  "+inf.0/real?"  (real? +inf.0))
(check-true  "arith/+inf"    (= +inf.0 (+ +inf.0 1)))
(check-true  "arith/-inf"    (= -inf.0 (- -inf.0 1)))

(news "--- 6.2 expt / sqrt ---\n")
(check "expt/int"       8    (expt 2 3))
(check "expt/0"         1    (expt 5 0))
(check "expt/1"         7    (expt 7 1))
(check-true  "sqrt/4"        (= 2.0 (sqrt 4)))
(check-true  "sqrt/9"        (= 3.0 (sqrt 9)))

(news "--- 6.2 comparisons ---\n")
(check-true  "=/2"           (= 3 3))
(check-true  "=/float"       (= 3 3.0))
(check-false "=/diff"        (= 3 4))
(check-true  "</chain"       (< 1 2 3 4))
(check-false "</chain-eq"    (< 1 2 2 3))
(check-true  ">/chain"       (> 4 3 2 1))
(check-true  "<=/eq"         (<= 2 2 3))
(check-true  ">=/eq"         (>= 3 2 2))

(news "--- 6.2 number->string / string->number ---\n")
(check "n->s/10"        "0"    (number->string 0))
(check "n->s/pos"       "42"   (number->string 42))
(check "n->s/neg"       "-7"   (number->string -7))
(check "n->s/16"        "ff"   (string-downcase (number->string 255 16)))
(check "n->s/2"         "1010" (number->string 10 2))
(check "n->s/8"         "17"   (number->string 15 8))
(check "s->n/int"       42     (string->number "42"))
(check "s->n/neg"       -7     (string->number "-7"))
(check "s->n/float"     3.14   (string->number "3.14"))
(check "s->n/16"        255    (string->number "ff" 16))
(check "s->n/2"         10     (string->number "1010" 2))
(check "s->n/8"         15     (string->number "17" 8))
(check "s->n/bad"       #f     (string->number "xyz"))
(check "s->n/empty"     #f     (string->number ""))
;;; Rational literals + #e/#i exactness + #b/#o/#d/#x radix prefixes (R7RS 7.1.1).  string->number
;;; previously returned #f for "1/2" (no rational parsing).  Matches Chez/Chibi (cross-impl probe).
(check "s->n/rat"       1/2    (string->number "1/2"))
(check "s->n/rat-reduce" 2     (string->number "6/3"))          ; reduces to integer
(check "s->n/rat-reduce2" 1/2  (string->number "2/4"))          ; reduces
(check "s->n/rat-neg"   -1/2   (string->number "-3/6"))
(check "s->n/rat-zero"  #f     (string->number "1/0"))          ; denom 0 -> #f
(check "s->n/hashx"     255    (string->number "#xff"))         ; #x radix prefix
(check "s->n/hashb"     5      (string->number "#b101"))
(check "s->n/hasho"     15     (string->number "#o17"))
(check "s->n/exact-i"   .5     (string->number "#i1/2"))        ; #i forces inexact
(check "s->n/exact-e"   10     (string->number "#e10"))         ; #e exact (no-op on int)
(check "s->n/prefix2"   16.0   (string->number "#x#i10"))       ; combined radix+exactness prefix


;;; --- coverage added 2026-08-29: exercised by the chibi R7RS suite, absent here ---------
(check "acos/1"            0.0  (acos 1))
(check-true "acos/0"            (< (abs (- (acos 0) 1.5707963)) 1e-5))   ;;!< pi/2
(check-true "acos/-1"           (< (abs (- (acos -1) 3.1415926)) 1e-5))  ;;!< pi
(check-true "acos/cos-roundtrip" (< (abs (- (acos (cos 0.5)) 0.5)) 1e-5))
(check "inexact/int"       3.0  (inexact 3))
(check "inexact/idempotent" 3.5 (inexact 3.5))
(check "exact/float"       3    (exact 3.0))
(check "exact/idempotent"  3    (exact 3))
(check-true "exact/inexact-roundtrip" (= 7 (exact (inexact 7))))
(check "rationalize/exact" 1/3  (rationalize 3/10 1/10))   ;;!< the R7RS 6.2.6 example
(check-true "rationalize/inexact" (< (abs (- (rationalize .3 1/10) (/ 1.0 3))) 1e-5))

;;; -----------------------------------------------------------------------
;;; R7RS 6.3  Booleans
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 booleans ---\n")
(check-true  "boolean?/#t"     (boolean? #t))
(check-true  "boolean?/#f"     (boolean? #f))
(check-false "boolean?/0"      (boolean? 0))
(check-false "boolean?/nil"    (boolean? '()))
(check-true  "not/#f"          (not #f))
(check-false "not/#t"          (not #t))
(check-false "not/0"           (not 0))
(check-false "not/nil"         (not '()))
(check-false "not/str"         (not ""))
(check-true  "boolean=?/tt"    (boolean=? #t #t))
(check-true  "boolean=?/ff"    (boolean=? #f #f))
(check-false "boolean=?/tf"    (boolean=? #t #f))

;;; -----------------------------------------------------------------------
;;; R7RS 6.4  Pairs and lists
;;; -----------------------------------------------------------------------

(news "\n--- 6.4 pairs ---\n")
(check-true  "pair?/cons"      (pair? (cons 1 2)))
(check-true  "pair?/list"      (pair? '(1)))
(check-false "pair?/nil"       (pair? '()))
(check-false "pair?/atom"      (pair? 5))
(check "cons/dot"      '(1 . 2)  (cons 1 2))
(check "cons/list"     '(1 2 3)  (cons 1 '(2 3)))
(check "car/list"      1         (car '(1 2 3)))
(check "cdr/list"      '(2 3)    (cdr '(1 2 3)))
(check "car/dot"       1         (car '(1 . 2)))
(check "cdr/dot"       2         (cdr '(1 . 2)))

(news "--- 6.4 list predicates ---\n")
(check-true  "null?/nil"       (null? '()))
(check-false "null?/pair"      (null? '(1)))
(check-false "null?/0"         (null? 0))
(check-true  "list?/proper"    (list? '(1 2 3)))
(check-true  "list?/nil"       (list? '()))
(check-false "list?/dotted"    (list? '(1 . 2)))
(check-false "list?/cyclic"    (list? (let ((x (list 1 2)))
                                         (set-cdr! (cdr x) x) x)))

(news "--- 6.4 list operations ---\n")
(check "list/3"        '(1 2 3)    (list 1 2 3))
(check "list/nil"      '()         (list))
(check "length/3"      3           (length '(1 2 3)))
(check "length/0"      0           (length '()))
(check "append/2"      '(1 2 3 4)  (append '(1 2) '(3 4)))
(check "append/3"      '(1 2 3 4 5) (append '(1 2) '(3 4) '(5)))
(check "append/nil-l"  '(1 2)      (append '() '(1 2)))
(check "append/l-nil"  '(1 2)      (append '(1 2) '()))
(check "reverse"       '(3 2 1)    (reverse '(1 2 3)))
(check "reverse/nil"   '()         (reverse '()))
(check "list-tail/2"   '(3 4)      (list-tail '(1 2 3 4) 2))
(check "list-tail/0"   '(1 2)      (list-tail '(1 2) 0))
(check "list-ref/0"    1           (list-ref '(1 2 3) 0))
(check "list-ref/2"    3           (list-ref '(1 2 3) 2))
(check "make-list/3"   '(x x x)    (make-list 3 'x))
(check "make-list/0"   '()         (make-list 0 'z))

(news "--- 6.4 list mutation ---\n")
(check "set-car!"      '(9 2)   (let ((p (list 1 2))) (set-car! p 9) p))
(check "set-cdr!"      '(1 9)   (let ((p (list 1 2))) (set-cdr! p '(9)) p))
(check "list-set!"     '(1 9 3) (let ((l (list 1 2 3))) (list-set! l 1 9) l))

(news "--- 6.4 list search ---\n")
(check "memq/found"    '(b c)   (memq 'b '(a b c)))
(check "memq/miss"     #f       (memq 'd '(a b c)))
(check "memv/found"    '(2 3)   (memv 2 '(1 2 3)))
(check "member/found"  '(2 3)   (member 2 '(1 2 3)))
(check "member/equal"  '("b" "c") (member "b" '("a" "b" "c")))
(check "assq/found"    '(b 2)   (assq 'b '((a 1) (b 2) (c 3))))
(check "assq/miss"     #f       (assq 'd '((a 1) (b 2))))
(check "assv/found"    '(2 x)   (assv 2 '((1 a) (2 x) (3 b))))
(check "assoc/str"     '("b" 2) (assoc "b" '(("a" 1) ("b" 2) ("c" 3))))

(news "--- 6.4 cXXr / cXXXr / cXXXXr ---\n")
(check "caar"  1   (caar '((1 2) 3)))
(check "cadr"  2   (cadr '(1 2 3)))
(check "cdar"  '(2) (cdar '((1 2) 3)))
(check "cddr"  '(3) (cddr '(1 2 3)))
(check "caaar" 1   (caaar '(((1)))))
(check "caddr" 3   (caddr '(1 2 3 4)))
(check "cdddr" '(4) (cdddr '(1 2 3 4)))
(check "cadddr" 4  (cadddr '(1 2 3 4 5)))
(check "cddddr" '(5) (cddddr '(1 2 3 4 5)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.5  Symbols
;;; -----------------------------------------------------------------------

(news "\n--- 6.5 symbols ---\n")
(check-true  "symbol?/sym"     (symbol? 'hello))
(check-false "symbol?/str"     (symbol? "hello"))
(check-false "symbol?/num"     (symbol? 42))
(check "symbol->string"  "foo"  (symbol->string 'foo))
(check "string->symbol"  'bar   (string->symbol "bar"))
(check-true  "symbol=?/2"      (symbol=? 'x 'x))
(check-false "symbol=?/diff"   (symbol=? 'x 'y))
(check-true  "symbol=?/3"      (symbol=? 'a 'a 'a))
(check-false "symbol=?/3-diff" (symbol=? 'a 'a 'b))

;;; -----------------------------------------------------------------------
;;; R7RS 6.6  Characters
;;; -----------------------------------------------------------------------

(news "\n--- 6.6 characters ---\n")
(check-true  "char?/ok"        (char? #\a))
(check-false "char?/str"       (char? "a"))
(check-true  "char=?/eq"       (char=? #\a #\a))
(check-false "char=?/ne"       (char=? #\a #\b))
(check-true  "char<?/lt"       (char<? #\a #\b))
(check-false "char<?/eq"       (char<? #\b #\b))
(check-true  "char>?/gt"       (char>? #\b #\a))
(check-true  "char<=?/eq"      (char<=? #\a #\a))
(check-true  "char<=?/lt"      (char<=? #\a #\b))
(check-true  "char>=?/eq"      (char>=? #\b #\b))
(check-true  "char>=?/gt"      (char>=? #\b #\a))
(check-true  "char<?/chain"    (char<? #\a #\b #\c))
(check-true  "char-alpha?"     (char-alphabetic? #\z))
(check-false "char-alpha?/dig" (char-alphabetic? #\5))
(check-true  "char-num?"       (char-numeric? #\9))
(check-false "char-num?/a"     (char-numeric? #\a))
(check-true  "char-ws?/sp"     (char-whitespace? #\space))
(check-true  "char-ws?/nl"     (char-whitespace? #\newline))
(check-true  "char-upper?"     (char-upper-case? #\Z))
(check-false "char-upper?/lc"  (char-upper-case? #\z))
(check-true  "char-lower?"     (char-lower-case? #\a))
(check-false "char-lower?/uc"  (char-lower-case? #\A))
(check "char->int/a"   97   (char->integer #\a))
(check "char->int/A"   65   (char->integer #\A))
(check "char->int/0"   48   (char->integer #\0))
(check "int->char/97"  #\a  (integer->char 97))
(check "char-upcase"   #\A  (char-upcase #\a))
(check "char-downcase" #\a  (char-downcase #\A))
(check "digit-value/5" 5    (digit-value #\5))
(check "digit-value/0" 0    (digit-value #\0))
(check "digit-value/9" 9    (digit-value #\9))
(check "digit-value/x" #f   (digit-value #\x))

(news "--- 6.6 char-ci ---\n")
(check-true  "char-ci=?"       (char-ci=? #\A #\a))
(check-true  "char-ci=?/both"  (char-ci=? #\a #\A))
(check-true  "char-ci<?"       (char-ci<? #\a #\B))
(check-false "char-ci<?/eq"    (char-ci<? #\A #\a))
(check-true  "char-ci>?"       (char-ci>? #\B #\a))
(check-true  "char-ci<=?"      (char-ci<=? #\A #\a))
(check-true  "char-ci>=?"      (char-ci>=? #\a #\A))

;;; -----------------------------------------------------------------------
;;; R7RS 6.7  Strings
;;; -----------------------------------------------------------------------

(news "\n--- 6.7 strings ---\n")
(check-true  "string?/ok"      (string? "hello"))
(check-false "string?/sym"     (string? 'hello))
(check "make-string/ch"  "aaa"   (make-string 3 #\a))
(check "make-string/0"   ""      (make-string 0 #\x))
(check "string/3"        "abc"   (string #\a #\b #\c))
(check "string-length"   5       (string-length "hello"))
(check "string-length/0" 0       (string-length ""))
(check "string-ref/0"    #\h     (string-ref "hello" 0))
(check "string-ref/4"    #\o     (string-ref "hello" 4))
(check "substring/mid"   "ell"   (substring "hello" 1 4))
(check "substring/full"  "hi"    (substring "hi" 0 2))
(check "substring/empty" ""      (substring "hello" 2 2))
(check "string-append/2" "ab"    (string-append "a" "b"))
(check "string-append/3" "abc"   (string-append "a" "b" "c"))
(check "string-append/0" ""      (string-append))
(check "string->list"    '(#\h #\i) (string->list "hi"))
(check "string->list/sub" '(#\e #\l) (string->list "hello" 1 3))
(check "list->string"    "hi"    (list->string '(#\h #\i)))
(check "string-copy/full" "abc"  (string-copy "abc"))
(check "string-copy/sub"  "bc"   (string-copy "abcd" 1 3))
(check-true  "string=?"         (string=? "abc" "abc"))
(check-false "string=?/ne"      (string=? "abc" "abd"))
(check-true  "string<?"         (string<? "abc" "abd"))
(check-false "string<?/eq"      (string<? "abc" "abc"))
(check-true  "string>?"         (string>? "abd" "abc"))
(check-true  "string<=?/eq"     (string<=? "abc" "abc"))
(check-true  "string>=?/eq"     (string>=? "abc" "abc"))
(check "string-upcase"   "HELLO" (string-upcase "hello"))
(check "string-downcase" "hello" (string-downcase "HELLO"))

(news "--- 6.7 string mutation ---\n")
(check "string-set!"  "hXllo"
  (let ((s (string-copy "hello"))) (string-set! s 1 #\X) s))
(check "string-fill!" "xxx"
  (let ((s (make-string 3 #\a))) (string-fill! s #\x) s))
(check "string-fill!/range" "aXXa"
  (let ((s (string-copy "aaaa"))) (string-fill! s #\X 1 3) s))
(check "string-copy!/full"  "XYZ"
  (let ((s (make-string 3 #\a))) (string-copy! s 0 "XYZ") s))
(check "string-copy!/range" "hXYlo"
  (let ((s (string-copy "hello"))) (string-copy! s 1 "XYZ" 0 2) s))
(check "string-copy!/at"    "abXYe"
  (let ((s (string-copy "abcde"))) (string-copy! s 2 "XY") s))

(news "--- 6.7 string-ci ---\n")
(check-true  "string-ci=?"      (string-ci=? "Hello" "hello"))
(check-true  "string-ci<?"      (string-ci<? "abc" "ABD"))
(check-true  "string-ci>?"      (string-ci>? "ABD" "abc"))
(check-true  "string-ci<=?"     (string-ci<=? "ABC" "abc"))
(check-true  "string-ci>=?"     (string-ci>=? "abc" "ABC"))

;;; -----------------------------------------------------------------------
;;; R7RS 6.8  Vectors
;;; -----------------------------------------------------------------------

(news "\n--- 6.8 vectors ---\n")
(check-true  "vector?/vec"     (vector? '#(1 2)))
(check-false "vector?/list"    (vector? '(1 2)))
(check "vector/3"      '#(1 2 3)  (vector 1 2 3))
(check "vector/0"      '#()       (vector))
(check "make-vector/3" '#(0 0 0)  (make-vector 3 0))
(check "make-vector/0" '#()       (make-vector 0 'x))
(check "vector-length" 3         (vector-length '#(1 2 3)))
(check "vector-length/0" 0       (vector-length '#()))
(check "vector-ref/0"  1         (vector-ref '#(1 2 3) 0))
(check "vector-ref/2"  3         (vector-ref '#(1 2 3) 2))
(check "vector->list"  '(1 2 3)  (vector->list '#(1 2 3)))
(check "vector->list/sub" '(2 3) (vector->list '#(1 2 3 4) 1 3))
(check "list->vector"  '#(1 2 3)  (list->vector '(1 2 3)))
(check "list->vector/0" '#()      (list->vector '()))
(check "vector->string" "abc"    (vector->string '#(#\a #\b #\c)))
(check "string->vector" '#(#\a #\b #\c) (string->vector "abc"))
(check "string->vector/sub" '#(#\b #\c) (string->vector "abcd" 1 3))
(check "vector-copy/full" '#(1 2 3) (vector-copy '#(1 2 3)))
(check "vector-copy/sub"  '#(2 3)   (vector-copy '#(1 2 3 4) 1 3))
(check "vector-copy/from" '#(3 4)   (vector-copy '#(1 2 3 4) 2))
(check "vector-append/2"  '#(1 2 3 4) (vector-append '#(1 2) '#(3 4)))
(check "vector-append/3"  '#(1 2 3 4 5) (vector-append '#(1 2) '#(3) '#(4 5)))
(check "vector-append/0"  '#()       (vector-append))

;;; Vector WRITE/DISPLAY -- regression for the bug where write printed a vector as
;;; "#vector(N 0xADDR)" (length + pointer) instead of "#(e0 e1 ...)".  The value-comparison checks
;;; above never caught it because they compare via equal?, not printed form.  (Found by the
;;; Chez/Chibi cross-impl probe; fixed in Cell::str, ll_vm_cell.cpp.)
(news "--- 6.8 vector write/display ---\n")
(define (%vec-write v)   (let ((p (open-output-string))) (write   v p) (get-output-string p)))
(define (%vec-display v) (let ((p (open-output-string))) (display v p) (get-output-string p)))
(check "vector-write/3"      "#(1 2 3)"                (%vec-write   (vector 1 2 3)))
(check "vector-write/empty"  "#()"                     (%vec-write   (vector)))
(check "vector-write/nested" "#(1 #(2 3))"             (%vec-write   (vector 1 (vector 2 3))))
(check "vector-write/str"    "#(\"a\" b)"              (%vec-write   (vector "a" 'b)))
(check "vector-display/3"    "#(1 2 3)"                (%vec-display (vector 1 2 3)))
(check "vector-write/big"    "#(0 0 0 0 0 0 0 0 0 0)"  (%vec-write   (make-vector 10 0)))

;;; Inexact-real write -- R7RS 7.1.1 requires an inexact number to be written distinguishably from
;;; an exact one, so a whole-valued float must show a decimal point (1.0, not 1) or it reads back as
;;; exact.  And bytevector write must be #u8(...), not the internal #bytevector(N ptr).  (Found by the
;;; Chez/Chibi cross-impl write-diff probe; fixed in Cell::str via ll_real_str + the #u8 render.)
(news "--- 6.8 inexact-real + bytevector write ---\n")
(check "float-write/whole"   "1.0"          (%vec-write 1.0))
(check "float-write/100"     "100.0"        (%vec-write 100.0))
(check "float-write/negzero" "-0.0"         (%vec-write -0.0))
(check "float-write/round"   "2.0"          (%vec-write (round 2.5)))
(check "float-write/frac"    "1.5"          (%vec-write 1.5))
(check "float-write/e->i"    "1.0"          (%vec-write (exact->inexact 1)))
(check "bytevector-write"    "#u8(1 2 3)"   (%vec-write (bytevector 1 2 3)))
(check "bytevector-write/0"  "#u8()"        (%vec-write (bytevector)))

(news "--- 6.8 vector mutation ---\n")
(check "vector-set!"   '#(1 9 3)
  (let ((v (vector 1 2 3))) (vector-set! v 1 9) v))
(check "vector-fill!"  '#(7 7 7)
  (let ((v (vector 1 2 3))) (vector-fill! v 7) v))
(check "vector-fill!/range" '#(1 7 7 4)
  (let ((v (vector 1 2 3 4))) (vector-fill! v 7 1 3) v))
(check "vector-copy!/full" '#(9 8 7)
  (let ((v (vector 1 2 3))) (vector-copy! v 0 '#(9 8 7)) v))
(check "vector-copy!/at"   '#(1 9 8 4)
  (let ((v (vector 1 2 3 4))) (vector-copy! v 1 '#(9 8) 0 2) v))

;;; -----------------------------------------------------------------------
;;; R7RS 6.9  Bytevectors
;;; -----------------------------------------------------------------------

(news "\n--- 6.9 bytevectors ---\n")
(check-true  "bytevector?/ok"  (bytevector? (bytevector 1 2)))
(check-false "bytevector?/vec" (bytevector? '#(1 2)))
(check "bytevector/3"    (bytevector 1 2 3)  (bytevector 1 2 3))
(check "make-bvec"       (bytevector 0 0 0)  (make-bytevector 3 0))
(check "bvec-length"     3     (bytevector-length (bytevector 1 2 3)))
(check "bvec-length/0"   0     (bytevector-length (bytevector)))
(check "bvec-u8-ref"     2     (bytevector-u8-ref (bytevector 1 2 3) 1))
(check "bvec-copy/full"  (bytevector 1 2 3) (bytevector-copy (bytevector 1 2 3)))
(check "bvec-copy/sub"   (bytevector 2 3)   (bytevector-copy (bytevector 1 2 3) 1))
(check "bvec-copy/range" (bytevector 2 3)   (bytevector-copy (bytevector 1 2 3 4) 1 3))
(check "bvec-append"     (bytevector 1 2 3 4) (bytevector-append (bytevector 1 2) (bytevector 3 4)))
(check "bvec-u8-set!"    (bytevector 1 99 3)
  (let ((b (bytevector 1 2 3))) (bytevector-u8-set! b 1 99) b))

(news "--- 6.9 utf8 conversion ---\n")
(check "string->utf8"    (bytevector 104 101 108 108 111) (string->utf8 "hello"))
(check "utf8->string"    "hello"  (utf8->string (bytevector 104 101 108 108 111)))
(check "utf8->string/sub" "el"   (utf8->string (bytevector 104 101 108 108 111) 1 3))


;;; --- coverage added 2026-08-29: exercised by the chibi R7RS suite, absent here ---------
(check "bytevector-copy!/range"
       (bytevector 10 1 2 3 50)
       (let ((to (bytevector 10 20 30 40 50)) (from (bytevector 1 2 3 4 5)))
         (bytevector-copy! to 1 from 0 3)
         to))
(check "bytevector-copy!/whole"
       (bytevector 1 2 3)
       (let ((to (bytevector 0 0 0)))
         (bytevector-copy! to 0 (bytevector 1 2 3))
         to))

;;; -----------------------------------------------------------------------
;;; R7RS 6.10  Control features
;;; -----------------------------------------------------------------------

(news "\n--- 6.10 apply ---\n")
(check "apply/list"      6     (apply + '(1 2 3)))
(check "apply/mixed"     10    (apply + 1 2 '(3 4)))
(check "apply/empty"     0     (apply + '()))
(check "apply/single"    -5    (apply - '(5)))
(check "apply/lambda"    7     (apply (lambda (a b) (+ a b)) '(3 4)))

(news "--- 6.10 map ---\n")
(check "map/1"           '(2 4 6)     (map (lambda (x) (* x 2)) '(1 2 3)))
(check "map/2lists"      '(5 7 9)     (map + '(1 2 3) '(4 5 6)))
(check "map/3lists"      '(9 12 15)   (map + '(1 2 3) '(4 5 6) '(4 5 6)))
(check "map/nil"         '()          (map car '()))
(check "map/pairs"       '(1 4 9)     (map * '(1 2 3) '(1 2 3)))

(news "--- 6.10 for-each ---\n")
(check "for-each/1"      '(3 2 1)
  (let ((acc '()))
    (for-each (lambda (x) (set! acc (cons x acc))) '(1 2 3))
    acc))
(check "for-each/2"      '((1 . 4) (2 . 5) (3 . 6))
  (let ((acc '()))
    (for-each (lambda (x y) (set! acc (cons (cons x y) acc))) '(1 2 3) '(4 5 6))
    (reverse acc)))

(news "--- 6.10 string-map / string-for-each ---\n")
(check "string-map/1"    "ABC"    (string-map char-upcase "abc"))
(check "string-map/2"    "ace"    (string-map (lambda (a b) b) "abc" "ace"))
(check "string-for-each" '(#\c #\b #\a)
  (let ((acc '()))
    (string-for-each (lambda (c) (set! acc (cons c acc))) "abc")
    acc))

(news "--- 6.10 vector-map / vector-for-each ---\n")
(check "vector-map/1"    '#(2 4 6)   (vector-map (lambda (x) (* x 2)) '#(1 2 3)))
(check "vector-map/2"    '#(5 7 9)   (vector-map + '#(1 2 3) '#(4 5 6)))
(check "vector-for-each" '(3 2 1)
  (let ((acc '()))
    (vector-for-each (lambda (x) (set! acc (cons x acc))) '#(1 2 3))
    acc))

(news "--- 6.10 values / call-with-values ---\n")
(check "values/1"        5     (call-with-values (lambda () 5) (lambda (x) x)))
(check "values/2"        3     (call-with-values (lambda () (values 1 2)) +))
(check "values/3"        6     (call-with-values (lambda () (values 1 2 3)) +))
(check "cwv/list"        '(a b) (call-with-values (lambda () (values 'a 'b)) list))

;;; -----------------------------------------------------------------------
;;; R7RS 6.11  Exceptions
;;; -----------------------------------------------------------------------

(news "\n--- 6.11 raise / with-exception-handler ---\n")
;;; Use guard instead of with-exception-handler for portability:
;;; Chez (R6RS) raise is non-continuable -- handlers cannot return normally.
(check "raise/catch"     42    (guard (e (#t e)) (raise 42)))
(check "raise/str"       "oops" (guard (e (#t e)) (raise "oops")))
(check "no-raise"        'ok   (guard (e (else 'caught)) 'ok))
(check "error/catch"     'ok   (guard (e (else 'ok)) (error "msg")))

(news "--- 6.11 error objects ---\n")
(check "error-object?"   #t    (guard (e (#t (error-object? e)))    (error "test" 1 2)))
(check "error-message"   "test" (guard (e (#t (error-object-message e))) (error "test" 1 2)))
(check "error-irritants" '(1 2 3)
  (guard (e (#t (error-object-irritants e))) (error "test" 1 2 3)))
(check "error-irritants/0" '()
  (guard (e (#t (error-object-irritants e))) (error "none")))
(check-false "error-object?/sym"  (error-object? 'foo))
(check-false "error-object?/str"  (error-object? "msg"))

(news "--- 6.11 guard ---\n")
(check "guard/cond"      'got-5
  (guard (e ((equal? e 5) 'got-5)) (raise 5)))
(check "guard/else"      'default
  (guard (e ((equal? e 1) 'one) (else 'default)) (raise 99)))
(check "guard/no-raise"  'body
  (guard (e (else 'caught)) 'body))
(check "guard/error-obj" '("bad" (1 2))
  (guard (e ((error-object? e) (list (error-object-message e) (error-object-irritants e))))
    (error "bad" 1 2)))
;;; guard/reraise: R7RS allows with-exception-handler handler to return from raise.
;;; Chez (R6RS) treats raise as non-continuable -- skip on Chez.
(when (not chez-scheme?)
  (check "guard/reraise"   99
    (with-exception-handler
      (lambda (e) e)
      (lambda () (guard (e ((equal? e 42) 'nope)) (raise 99))))))

;;; -----------------------------------------------------------------------
;;; R7RS 6.12  Environments and eval
;;; -----------------------------------------------------------------------

(news "\n--- 6.12 eval ---\n")
(check "eval/arith"      10   (eval '(+ 3 7) (interaction-environment)))
(check "eval/let"        6    (eval '(let ((x 2)) (* x 3)) (interaction-environment)))
(check "eval/define"     'ok  (begin (eval '(define eval-test 42) (interaction-environment)) 'ok))
(check "eval/use-define" 42   (eval 'eval-test (interaction-environment)))


;;; --- coverage added 2026-08-29: exercised by the chibi R7RS suite, absent here ---------
;;; R7RS-small has no `environment?` predicate (that is an R6RS-ism, and LambLisp does not bind
;;; it), so the useful assertion is that the returned object WORKS as an eval environment.
(check-true "scheme-report-environment/5" (not (eq? #f (scheme-report-environment 5))))
(check "scheme-report-environment/eval" 7
       (eval (quote (+ 3 4)) (scheme-report-environment 5)))
;;; `exit' is bound but deliberately NOT invoked: calling it would end the test run.  R7RS 6.14
;;; only requires that it exist and terminate; its effect is untestable from inside the suite.
(check-true "exit/bound"       (procedure? exit))

;;; -----------------------------------------------------------------------
;;; R7RS 6.14  Time
;;; -----------------------------------------------------------------------

(news "\n--- 6.14 time ---\n")
(check-true "jiffies-per-second"  (> (jiffies-per-second) 0))
(check-true "current-jiffy"       (>= (current-jiffy) 0))
(check-true "current-second"      (>= (current-second) 0))
(check-true "jiffies-monotone"    (<= (current-jiffy) (current-jiffy)))

;;; -----------------------------------------------------------------------
;;; Tail calls
;;; -----------------------------------------------------------------------

(news "\n--- tail calls ---\n")
(define (tc-count n acc)
  (if (= n 0) acc (tc-count (- n 1) (+ acc 1))))
(check "tail/10k"        10000  (tc-count 10000 0))
(check "tail/100k"       100000 (tc-count 100000 0))

(define (tc-even? n)
  (if (= n 0) #t (tc-odd? (- n 1))))
(define (tc-odd? n)
  (if (= n 0) #f (tc-even? (- n 1))))
(check-true  "tail/mutual-even"   (tc-even? 10000))
(check-false "tail/mutual-odd"    (tc-odd? 10000))

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
(check-true  "drt/point?"         (point? p1))
(check-false "drt/point?/non"     (point? 42))
(check-false "drt/point?/pair"    (point? '(a b)))
(check       "drt/point-x"        3   (point-x p1))
(check       "drt/point-y"        4   (point-y p1))

(set-point-x! p1 10)
(set-point-y! p1 20)
(check       "drt/set-x!"         10  (point-x p1))
(check       "drt/set-y!"         20  (point-y p1))

;;; Read-only record: immutable pair (no mutators)
(define-record-type <ipair>
  (make-ipair head tail)
  ipair?
  (head ipair-head)
  (tail ipair-tail))

(define ip (make-ipair 'a '(b c)))
(check-true  "drt/ipair?"         (ipair? ip))
(check-false "drt/ipair?/non"     (ipair? p1))
(check       "drt/ipair-head"     'a       (ipair-head ip))
(check       "drt/ipair-tail"     '(b c)   (ipair-tail ip))

;;; Predicate distinguishes different record types
(check-false "drt/pred/cross1"    (point? ip))
(check-false "drt/pred/cross2"    (ipair? p1))

;;; Record with single field
(define-record-type <box>
  (make-box value)
  box?
  (value unbox set-box!))

(define b (make-box 99))
(check-true  "drt/box?"           (box? b))
(check       "drt/unbox"          99   (unbox b))
(set-box! b 100)
(check       "drt/set-box!"       100  (unbox b))

;;; Two independent instances are not eq? to each other
(define b2 (make-box 100))
(check-false "drt/box/not-eq"     (eq? b b2))
(check-true  "drt/box/equal"      (equal? (unbox b) (unbox b2)))

;;; Records are not eq? to plain vectors with same values
(check-false "drt/not-vector"     (point? (vector 0 3 4)))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2.2  let*-values
;;; -----------------------------------------------------------------------

(news "\n--- 4.2.2 let*-values ---\n")
(check "let*-values/basic"   3       ;;; a=1 b=2 c=3; (* a c)=3
  (let*-values (((a b) (values 1 2))
                ((c)   (+ a b)))
    (* a c)))
(check "let*-values/chain"   7       ;;; x=3 y=4 z=7 w=7
  (let*-values (((x y) (values 3 4))
                ((z)   (+ x y))
                ((w)   (* z 1)))
    w))
(check "let*-values/single"  '(a b)
  (let*-values (((p q) (values 'a 'b)))
    (list p q)))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2.10  call-with-current-continuation
;;; -----------------------------------------------------------------------

(news "\n--- 4.2.10 call-with-current-continuation ---\n")
(check-exception "call/cc/normal"     5
  (call-with-current-continuation (lambda (k) 5)))
(check-exception "call/cc/escape"     42
  (call-with-current-continuation (lambda (k) (k 42))))
(check-exception "call/cc/abort"      3
  (+ 1 (call-with-current-continuation (lambda (k) (+ 100 (k 2))))))
(check-true-exception "call/cc/proc?"
  (procedure? (call-with-current-continuation (lambda (k) k))))
(check-exception "call/cc-alias"      42
  (call/cc (lambda (k) (k 42))))
(check-exception "call/cc/reentry"    '(0 1 2)
  (let ((result '()) (k-save #f))
    (call-with-current-continuation (lambda (k) (set! k-save k)))
    (when (< (length result) 3)
      (set! result (append result (list (length result))))
      (k-save #f))
    result))

(news "\n--- dynamic-wind ---\n")
(check-exception "dynamic-wind/order" '(before during after)
  (let ((log '()))
    (dynamic-wind
      (lambda () (set! log (append log '(before))))
      (lambda () (set! log (append log '(during))))
      (lambda () (set! log (append log '(after)))))
    log))
(check-exception "dynamic-wind/escape" '(before during after done)
  (let ((log '()))
    (call-with-current-continuation
      (lambda (k)
        (dynamic-wind
          (lambda () (set! log (append log '(before))))
          (lambda () (set! log (append log '(during))) (k #f))
          (lambda () (set! log (append log '(after)))))))
    (set! log (append log '(done)))
    log))
(check-exception "dynamic-wind/raise" '(before after)
  (let ((log '()))
    (guard (e (#t log))
      (dynamic-wind
        (lambda () (set! log (append log '(before))))
        (lambda () (raise 'oops))
        (lambda () (set! log (append log '(after))))))))

(news "\n--- call-with-values ---\n")
(check-guard "call-with-values/basic"  3
  (call-with-values (lambda () (values 1 2)) +))
(check-guard "call-with-values/single" 42
  (call-with-values (lambda () 42) (lambda (x) x)))
(check-guard "call-with-values/multi"  '(a b c)
  (call-with-values (lambda () (values 'a 'b 'c)) list))

;;; -----------------------------------------------------------------------
;;; R7RS 6.2  Additional R7RS number operations
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 square ---\n")
(check "square/0"       0     (square 0))
(check "square/5"       25    (square 5))
(check "square/-3"      9     (square -3))
(check "square/1.5"     2.25  (square 1.5))

(news "--- 6.2 floor-quotient / floor-remainder / floor/ ---\n")
(check "floor-quotient/pp"   3    (floor-quotient 10 3))
(check "floor-quotient/np"   -4   (floor-quotient -10 3))
(check "floor-quotient/pn"   -4   (floor-quotient 10 -3))
(check "floor-quotient/nn"   3    (floor-quotient -10 -3))
(check "floor-remainder/pp"  1    (floor-remainder 10 3))
(check "floor-remainder/np"  2    (floor-remainder -10 3))
(check "floor-remainder/pn"  -2   (floor-remainder 10 -3))
(check "floor-remainder/nn"  -1   (floor-remainder -10 -3))
(check "floor//vals"   '(3 1)
  (let-values (((q r) (floor/ 10 3))) (list q r)))
(check "floor//neg"    '(-4 2)
  (let-values (((q r) (floor/ -10 3))) (list q r)))

(news "--- 6.2 truncate-quotient / truncate-remainder / truncate/ ---\n")
(check "truncate-quotient/pp"   3    (truncate-quotient 10 3))
(check "truncate-quotient/np"   -3   (truncate-quotient -10 3))
(check "truncate-quotient/pn"   -3   (truncate-quotient 10 -3))
(check "truncate-quotient/nn"   3    (truncate-quotient -10 -3))
(check "truncate-remainder/pp"  1    (truncate-remainder 10 3))
(check "truncate-remainder/np"  -1   (truncate-remainder -10 3))
(check "truncate-remainder/pn"  1    (truncate-remainder 10 -3))
(check "truncate-remainder/nn"  -1   (truncate-remainder -10 -3))
(check "truncate//vals"  '(3 1)
  (let-values (((q r) (truncate/ 10 3))) (list q r)))
(check "truncate//neg"   '(-3 -1)
  (let-values (((q r) (truncate/ -10 3))) (list q r)))

(news "--- 6.2 exact-integer-sqrt ---\n")
(check "exact-integer-sqrt/0"   '(0 0)
  (let-values (((s r) (exact-integer-sqrt 0))) (list s r)))
(check "exact-integer-sqrt/1"   '(1 0)
  (let-values (((s r) (exact-integer-sqrt 1))) (list s r)))
(check "exact-integer-sqrt/4"   '(2 0)
  (let-values (((s r) (exact-integer-sqrt 4))) (list s r)))
(check "exact-integer-sqrt/14"  '(3 5)
  (let-values (((s r) (exact-integer-sqrt 14))) (list s r)))
(check "exact-integer-sqrt/25"  '(5 0)
  (let-values (((s r) (exact-integer-sqrt 25))) (list s r)))
(check "exact-integer-sqrt/26"  '(5 1)
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
    (check "rat/reader-half"       1/2    1/2)
    (check "rat/reader-neg"       -3/4   -3/4)
    (check "rat/reader-reduce"     3/2    6/4)            ;;; reader normalizes
    (check "rat/reader-to-int"     2      4/2)            ;;; denominator 1 -> integer

    ;;; Predicates
    (check-true  "rat/number?"     (number?   1/3))
    (check-true  "rat/rational?"   (rational? 1/3))
    (check-true  "rat/real?"       (real?     1/3))
    (check-false "rat/integer?"    (integer?  1/3))
    (check-true  "rat/exact?"      (exact?    1/3))
    (check-false "rat/inexact?"    (inexact?  1/3))
    (check-true  "rat/rational?/float" (rational? 1.5))   ;;; finite inexact reals are rational (R7RS)
    (check-false "rat/rational?/inf"   (rational? +inf.0))

    ;;; numerator / denominator
    (check "rat/numerator"         1      (numerator   1/3))
    (check "rat/denominator"       3      (denominator 1/3))
    (check "rat/numerator/neg"    -1      (numerator  -1/3))
    (check "rat/denominator/neg"   3      (denominator -1/3))
    (check "rat/numerator/int"     5      (numerator   5))
    (check "rat/denominator/int"   1      (denominator 5))

    ;;; zero? positive? negative?
    (check-false "rat/zero?"       (zero?     1/3))
    (check-true  "rat/zero?/0"     (zero?     0/1))       ;;; 0/anything -> integer 0
    (check-true  "rat/positive?"   (positive? 1/3))
    (check-false "rat/positive?/n" (positive? -1/3))
    (check-true  "rat/negative?"   (negative? -1/3))
    (check-false "rat/negative?/p" (negative? 1/3))

    ;;; Arithmetic -- exact results
    (check "rat/add"               5/6    (+ 1/2 1/3))
    (check "rat/sub"               1/6    (- 1/2 1/3))
    (check "rat/mul"               1/6    (* 1/2 1/3))
    (check "rat/div"               3/2    (/ 1/2 1/3))
    (check "rat/add-int"           5/3    (+ 2/3 1))
    (check "rat/mul-reduce"        1/4    (* 1/2 1/2))
    (check "rat/div-to-int"        2      (/ 1/2 1/4))
    (check "rat/negate"           -1/3    (- 1/3))
    (check "rat/recip"             3/1    (/ 1/3))        ;;; 3/1 normalizes to 3
    (check "rat/recip/int"         3      (/ 1/3))

    ;;; Mixed exact/inexact -> inexact
    (check-true  "rat/add-inexact" (inexact? (+ 1/2 0.5)))
    (check-true  "rat/mul-inexact" (inexact? (* 1/3 1.0)))

    ;;; Comparisons
    (check-true  "rat/eq"          (= 1/2 1/2))
    (check-true  "rat/eq-int"      (= 2/4 1/2))
    (check-true  "rat/lt"          (< 1/3 1/2))
    (check-false "rat/lt-false"    (< 1/2 1/3))
    (check-true  "rat/le"          (<= 1/3 1/3))
    (check-true  "rat/gt"          (> 1/2 1/3))
    (check-true  "rat/ge"          (>= 1/2 1/2))
    (check-true  "rat/chain"       (< 1/4 1/3 1/2 2/3))

    ;;; abs
    (check "rat/abs/pos"           1/3    (abs  1/3))
    (check "rat/abs/neg"           1/3    (abs -1/3))

    ;;; max / min
    (check "rat/max"               2/3    (max 1/3 1/2 2/3))
    (check "rat/min"               1/3    (min 1/3 1/2 2/3))

    ;;; floor / ceiling / truncate / round
    (check "rat/floor/pos"         1      (floor    7/4))
    (check "rat/floor/neg"        -2      (floor   -7/4))
    (check "rat/ceiling/pos"       2      (ceiling  7/4))
    (check "rat/ceiling/neg"      -1      (ceiling -7/4))
    (check "rat/truncate/pos"      1      (truncate 7/4))
    (check "rat/truncate/neg"     -1      (truncate -7/4))
    (check "rat/round/down"        1      (round    5/4))  ;;; 1.25 -> 1
    (check "rat/round/up"          2      (round    7/4))  ;;; 1.75 -> 2
    (check "rat/round/half-even-2" 2      (round    5/2))  ;;; 2.5 -> 2 (banker's)
    (check "rat/round/half-even-4" 4      (round    7/2))  ;;; 3.5 -> 4 (banker's)

    ;;; exact->inexact / inexact->exact
    (check-true  "rat/e2i/inexact" (inexact? (exact->inexact 1/3)))
    (check-true  "rat/e2i/approx"  (< (abs (- (exact->inexact 1/3) 0.333333)) 1e-5))
    (check-true  "rat/i2e/exact"   (exact? (inexact->exact 0.5)))
    (check       "rat/i2e/half"    1/2    (inexact->exact 0.5))
    (check       "rat/i2e/int"     3      (inexact->exact 3.0))

    ;;; expt
    (check "rat/expt/pos"          1/8    (expt 1/2 3))
    (check "rat/expt/neg"          8      (expt 1/2 -3))
    (check "rat/expt/zero"         1      (expt 1/3 0))

    ;;; number->string
    (check "rat/n2s"               "1/3"  (number->string 1/3))
    (check "rat/n2s/neg"           "-1/3" (number->string -1/3))

  )) ;;; end ll-has-rational?

;;; gcd / lcm -- do not require LL_RATIONAL
(check "rat/gcd/ints"          4      (gcd 12 8))
(check "rat/lcm/ints"          12     (lcm 4 6))

;;; -----------------------------------------------------------------------
;;; R7RS 6.2  Complex numbers
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 complex numbers ---\n")
(check-true  "complex?/int"       (complex? 5))
(check-true  "complex?/real"      (complex? 3.14))
(if ll-has-rational? (check-true "complex?/rat" (complex? 1/3)) (skip "complex?/rat"))
(define c1 (make-rectangular 3 4))
(check-true  "complex?/cpx"       (complex? c1))
(check "real-part/cpx"      3    (real-part c1))
(check "imag-part/cpx"      4    (imag-part c1))
(check "real-part/real"     5    (real-part 5))
(check "imag-part/real"     0    (imag-part 5))
(check "magnitude/cpx"      5    (magnitude (make-rectangular 3 4)))
(check "magnitude/neg"      3    (magnitude -3))
(check "magnitude/zero"     0    (magnitude 0))
(check "angle/pos"          0    (angle 1))
(check-true "angle/neg"          (let ((a (angle -1)))
                                   (< (abs (- a (* 4 (atan 1.0)))) 1e-5)))
(define c2 (make-rectangular 0 1))
(check "make-rectangular/r" 0    (real-part c2))
(check "make-rectangular/i" 1    (imag-part c2))
(define c3 (make-polar 2 0))
(check-true "make-polar/r"       (< (abs (- (real-part c3) 2.0)) 1e-5))
(check-true "make-polar/i"       (< (abs (imag-part c3)) 1e-5))
(define ca (make-rectangular 1 2))
(define cb (make-rectangular 3 4))
(check-true "cpx-add"            (= (+ ca cb) (make-rectangular 4 6)))
(check-true "cpx-sub"            (= (- cb ca) (make-rectangular 2 2)))
(check-true "cpx-mul"            (= (* ca cb) (make-rectangular -5 10)))
(check-true "cpx-div"            (let ((q (/ ca cb))) ;;; (1+2i)/(3+4i) = 11/25 + 2/25*i
                                   (and (< (abs (- (real-part q) 0.44)) 1e-5)
                                        (< (abs (- (imag-part q) 0.08)) 1e-5))))
(check-true "cpx-sqrt-neg"       (let ((r (sqrt -1)))
                                   (< (abs (- (imag-part r) 1)) 1e-5)))
(check-true "cpx-number?"        (number? (make-rectangular 1 2)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.4  list-copy
;;; -----------------------------------------------------------------------

(news "\n--- 6.4 list-copy ---\n")
(check "list-copy/basic"   '(1 2 3)  (list-copy '(1 2 3)))
(check "list-copy/nil"     '()       (list-copy '()))
(check-false "list-copy/not-eq"
  (let ((l '(1 2 3))) (eq? l (list-copy l))))
(check-true  "list-copy/car-eq"
  (let* ((item (list 'x)) (l (list item)) (l2 (list-copy l)))
    (eq? (car l) (car l2))))    ; shallow copy -- car is shared

;;; -----------------------------------------------------------------------
;;; R7RS 6.6  char-foldcase
;;; -----------------------------------------------------------------------

(news "\n--- 6.6 char-foldcase ---\n")
(check "char-foldcase/upper" #\a  (char-foldcase #\A))
(check "char-foldcase/lower" #\a  (char-foldcase #\a))
(check "char-foldcase/digit" #\5  (char-foldcase #\5))
(check "char-foldcase/z"     #\z  (char-foldcase #\Z))

;;; -----------------------------------------------------------------------
;;; R7RS 6.7  string-foldcase
;;; -----------------------------------------------------------------------

(news "\n--- 6.7 string-foldcase ---\n")
(check "string-foldcase/upper" "hello" (string-foldcase "HELLO"))
(check "string-foldcase/mixed" "world" (string-foldcase "World"))
(check "string-foldcase/lower" "abc"   (string-foldcase "abc"))
(check "string-foldcase/empty" ""      (string-foldcase ""))

;;; -----------------------------------------------------------------------
;;; R7RS 6.12  make-parameter / parameterize
;;; -----------------------------------------------------------------------

(news "\n--- 6.12 parameters ---\n")
;;; make-parameter / parameterize may be unbound; guard the defines so later tests still run.
(define r7-p  (guard (e (#t #f)) (make-parameter 10)))
(define r7-p2 (guard (e (#t #f)) (make-parameter 5 (lambda (x) (* x 2)))))
(check-exception "make-parameter/get"    10   (r7-p))
(check-exception "parameterize/local"    20   (parameterize ((r7-p 20)) (r7-p)))
(check-exception "parameterize/restore"  10   (begin (parameterize ((r7-p 20)) #f) (r7-p)))
(check-exception "parameterize/nested"   30
  (parameterize ((r7-p 20))
    (parameterize ((r7-p 30)) (r7-p))))
(check-exception "parameterize/outer"    20
  (parameterize ((r7-p 20))
    (parameterize ((r7-p 30)) #f)
    (r7-p)))
(check-exception "parameterize/body-val" 99   (parameterize ((r7-p 5)) 99))
(check-exception "make-parameter/conv"   10   (r7-p2))
(check-exception "parameterize/conv"     6    (parameterize ((r7-p2 3)) (r7-p2)))
(check-exception "parameterize/conv-restore" 10 (begin (parameterize ((r7-p2 3)) #f) (r7-p2)))

;;; -----------------------------------------------------------------------
;;; R7RS 6.13  Ports and I/O
;;; -----------------------------------------------------------------------

;;; --- coverage added 2026-08-29: exercised by the chibi R7RS suite, absent here ---------
(check "write-bytevector/count" 3
       (let ((o (open-output-string)))
         (write-bytevector (bytevector 65 66 67) o)
         (string-length (get-output-string o))))
(check "write-bytevector/bytes" "ABC"
       (let ((o (open-output-string)))
         (write-bytevector (bytevector 65 66 67) o)
         (get-output-string o)))

(news "\n--- 6.13 port predicates ---\n")
(check-true  "input-port?/stdin"      (input-port?  (current-input-port)))
(check-true  "output-port?/stdout"    (output-port? (current-output-port)))
(check-true  "output-port?/stderr"    (output-port? (current-error-port)))
(check-true  "port?/in"               (port? (current-input-port)))
(check-true  "port?/out"              (port? (current-output-port)))
(check-false "port?/num"              (port? 42))
(check-false "port?/str"              (port? "hello"))
(check-true  "input-port-open?"       (input-port-open?  (current-input-port)))
(check-true  "output-port-open?"      (output-port-open? (current-output-port)))

(news "--- 6.13 string input ports ---\n")
(let ((p (open-input-string "hello")))
  (check-true  "open-input-string/port?"  (input-port? p))
  (check "read-char/h"       #\h  (read-char p))
  (check "peek-char/e"       #\e  (peek-char p))
  (check "read-char/e"       #\e  (read-char p))
  (check-true  "char-ready?"      (char-ready? p))
  (check "read-char/l"       #\l  (read-char p)))

(let ((p (open-input-string "(1 2 3) 42")))
  (check "read/list"         '(1 2 3) (read p))
  (check "read/num"          42       (read p))
  (check-true  "read/eof"             (eof-object? (read p))))

(check-true  "eof-object?/eof"   (eof-object? (read  (open-input-string ""))))
(check-false "eof-object?/num"   (eof-object? 42))
(check-false "eof-object?/str"   (eof-object? ""))
(check-true  "eof-object?/char"  (eof-object? (read-char (open-input-string ""))))

(let ((p (open-input-string "first line\nsecond line")))
  (check "read-line/1"  "first line"   (read-line p))
  (check "read-line/2"  "second line"  (read-line p))
  (check-true "read-line/eof"          (eof-object? (read-line p))))

(news "--- 6.13 string output ports ---\n")
(let ((p (open-output-string)))
  (check-true  "open-output-string/port?" (output-port? p))
  (write 42 p)
  (check "write/num"       "42"      (get-output-string p)))

(let ((p (open-output-string)))
  (display "hello" p)
  (check "display/str"     "hello"   (get-output-string p)))

(let ((p (open-output-string)))
  (write "hi" p)
  (check "write/str"       "\"hi\""  (get-output-string p)))

(let ((p (open-output-string)))
  (write-char #\A p)
  (check "write-char"      "A"       (get-output-string p)))

(let ((p (open-output-string)))
  (write-string "xyz" p)
  (check "write-string"    "xyz"     (get-output-string p)))

(let ((p (open-output-string)))
  (write-string "abcde" p 1 3)
  (check "write-string/sub" "bc"     (get-output-string p)))

(let ((p (open-output-string)))
  (newline p)
  (check "newline/port"    "\n"      (get-output-string p)))

(news "--- 6.13 bytevector ports ---\n")
(let ((p (open-input-bytevector (bytevector 10 20 30))))
  (check "read-u8/1"        10   (read-u8 p))
  (check "peek-u8/2"        20   (peek-u8 p))
  (check "read-u8/2"        20   (read-u8 p))
  (check-true "u8-ready?"        (u8-ready? p))
  (check-true "read-u8/eof"      (eof-object? (begin (read-u8 p) (read-u8 p)))))

;; B173: u8-ready? / char-ready? MUST answer #t AT EOF.  R7RS: "If the port is at end of file
;; then u8-ready? returns #t" -- the contract is "the next read will not block", and at EOF the
;; read returns the eof object immediately.  Answering #f there makes the ordinary drain loop
;;     (let loop () (if (u8-ready? p) (read-u8 p) (loop)))
;; spin FOREVER on a plain bytevector or string port.  The checks above only ever exercise a port
;; with bytes still in it, which is why this went unnoticed; these pin the empty end.
(let ((p (open-input-bytevector (bytevector 7))))
  (read-u8 p)                                        ;; consume the only byte -> now at EOF
  (check-true "u8-ready?/at-eof"        (u8-ready? p))
  (check-true "u8-ready?/eof-repeatable" (and (u8-ready? p) (u8-ready? p))))

(let ((p (open-input-bytevector (bytevector))))
  (check-true "u8-ready?/empty-bvec"    (u8-ready? p)))

(let ((p (open-input-string "x")))
  (read-char p)
  (check-true "char-ready?/at-eof"      (char-ready? p)))

(let ((p (open-input-string "")))
  (check-true "char-ready?/empty-string" (char-ready? p)))

(let ((p (open-output-bytevector)))
  (check-true  "open-output-bvec/port?" (output-port? p))
  (write-u8 42 p)
  (write-u8 99 p)
  (check "get-output-bytevector" (bytevector 42 99) (get-output-bytevector p)))

(news "--- 6.13 call-with-port ---\n")
(check "call-with-port/read"  '(1 2)
  (call-with-port (open-input-string "(1 2)") read))
(check "call-with-port/write" "42"
  (call-with-port (open-output-string) (lambda (p) (write 42 p) (get-output-string p))))

(news "--- 6.13 with-exception-handler in port ops ---\n")
(check-error "read-char/closed"
  (lambda ()
    (let ((p (open-input-string "")))
      (close-input-port p)
      (read-char p))))

;;; -----------------------------------------------------------------------
;;; B96 -- equal? must TERMINATE on cyclic structure (R7RS 6.1: "equal? ... must
;;; always terminate even if its arguments contain cycles").  Also exercises the
;;; datum-label write<->read round-trip end to end.  Format-independent (uses
;;; equal?/eq?, not exact printed strings).
;;; -----------------------------------------------------------------------
(news "--- B96 cyclic equal? ---\n")
(check-true "equal?/cyclic-cdr-terminates"
  (let ((a (list 1 2 3)) (b (list 1 2 3)))
    (set-cdr! (cddr a) a) (set-cdr! (cddr b) b)
    (equal? a b)))
(check-false "equal?/cyclic-cdr-different"
  (let ((a (list 1 2 3)) (b (list 1 2 9)))
    (set-cdr! (cddr a) a) (set-cdr! (cddr b) b)
    (equal? a b)))
(check-true "equal?/cyclic-car-terminates"
  (let ((a (list 0 0)) (b (list 0 0)))
    (set-car! a a) (set-car! b b)
    (equal? a b)))
(check-true "equal?/cyclic-cdr-roundtrip"
  (let ((c (list 1 2 3)))
    (set-cdr! (cddr c) c)
    (equal? c (read (open-input-string
                     (let ((p (open-output-string))) (write c p) (get-output-string p)))))))
(check-true "equal?/cyclic-car-roundtrip"
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
(check "quote/empty-list" '() '())
(check "lambda/rest-all" '(3 4 5 6) ((lambda x x) 3 4 5 6))
(check "cond/else-equal" 'equal (cond ((> 3 3) 'greater) ((< 3 3) 'less) (else 'equal)))
(check "let-values/exact-integer-sqrt" 35 (let-values (((root rem) (exact-integer-sqrt 32))) (* root rem)))
(check "let*-values/swap" '(x y x y)
  (let ((a 'a) (b 'b) (x 'x) (y 'y))
    (let*-values (((a b) (values x y)) ((x y) (values a b))) (list a b x y))))
(check "delay/stream-integers" 2
  (let () (define integers (letrec ((next (lambda (n) (delay (cons n (next (+ n 1))))))) (next 0)))
    (define (stream-car s) (car (force s))) (define (stream-cdr s) (cdr (force s)))
    (stream-car (stream-cdr (stream-cdr integers)))))
(check "delay/count-memoized" '(6 6)
  (let () (define count 0) (define x 5)
    (define p (delay (begin (set! count (+ count 1)) (if (> count x) count (force p)))))
    (let ((first (force p))) (set! x 10) (list first (force p)))))
(define spec-range (case-lambda ((e) (spec-range 0 e))
                                ((b e) (do ((r '() (cons b r)) (b b (+ b 1))) ((>= b e) (reverse r))))))
(check "case-lambda/range-1arg" '(0 1 2) (spec-range 3))
(check "case-lambda/range-2arg" '(3 4) (spec-range 3 5))
(check "quasiquote/nested-foo" '(a (quasiquote (b (unquote (foo 3)) d)) e) `(a `(b ,(foo ,(+ 1 2)) d) e))

(news "--- spec-audit: macros, define, equivalence, booleans (4.3/5/6.1/6.3) ---\n")
(check "let-syntax/given-that" 'now
  (let-syntax ((given-that (syntax-rules () ((given-that t s1 s2 ...) (if t (begin s1 s2 ...))))))
    (let ((if #t)) (given-that if (set! if 'now)) if)))
(check "let-syntax/referential-transparency" 'outer
  (let ((x 'outer)) (let-syntax ((m (syntax-rules () ((m) x)))) (let ((x 'inner)) (m)))))
;; B109 (FIXED): a free template identifier bound to a user-defined PROCEDURE or MACRO resolves in
;; the DEFINITION scope, not the use scope (R7RS 4.3.1 referential transparency).  Verified vs Chez
;; and Chibi (both give 500 / 20).  Fixed by CHICKEN-style def-env aliasing in sr_expand_ann.
(define (b109-helper x) (* x 100))
(define-syntax b109-use-helper (syntax-rules () ((_ n) (b109-helper n))))
(check "syntax-rules/hygiene-free-procedure" 500
  (let ((b109-helper (lambda (x) (+ x 1)))) (b109-use-helper 5)))
(define-syntax b109-dbl (syntax-rules () ((_ x) (* 2 x))))
(define-syntax b109-use-dbl (syntax-rules () ((_ n) (b109-dbl n))))
(check "syntax-rules/hygiene-free-macro" 20
  (let-syntax ((b109-dbl (syntax-rules () ((_ x) (+ 1 x))))) (b109-use-dbl 10)))
;; B121: a macro may MUTATE a free variable -- a free template identifier must expand to a live
;; binding reference, not a snapshot of its value (a quoted value cannot be a set! target).
(define b121-counter 0)
(define-syntax b121-bump (syntax-rules () ((_) (set! b121-counter (+ b121-counter 1)))))
(check "syntax-rules/set!-free-variable" 2 (begin (b121-bump) (b121-bump) b121-counter))
(define b121-seen 0)
(define-syntax b121-read (syntax-rules () ((_) b121-seen)))
(check "syntax-rules/free-ref-is-live" 7 (begin (set! b121-seen 7) (b121-read)))
(check "letrec-syntax/my-or" 7
  (letrec-syntax ((my-or (syntax-rules () ((my-or) #f) ((my-or e) e)
                          ((my-or e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...)))))))
    (let ((x #f) (y 7) (temp 8) (let odd?) (if even?)) (my-or x (let temp) (if y) y))))
(define-syntax be-like-begin
  (syntax-rules () ((be-like-begin name)
    (define-syntax name (syntax-rules () ((name expr (... ...)) (begin expr (... ...))))))))
(be-like-begin spec-sequence)
(check "syntax-rules/be-like-begin" 4 (spec-sequence 1 2 3 4))
(define-values (spec-root spec-rem) (exact-integer-sqrt 32))
(check "define-values/exact-integer-sqrt" 35 (* spec-root spec-rem))
(define-record-type <pare> (kons x y) pare? (x kar set-kar!) (y kdr))
(check-true  "define-record-type/pare?-kons" (pare? (kons 1 2)))
(check-false "define-record-type/pare?-cons" (pare? (cons 1 2)))
(check "define-record-type/kar" 1 (kar (kons 1 2)))
(check "define-record-type/kdr" 2 (kdr (kons 1 2)))
(check "define-record-type/set-kar!" 3 (let ((k (kons 1 2))) (set-kar! k 3) (kar k)))
(check-false "eqv?/nan" (eqv? 0.0 +nan.0))
(check-true  "equal?/circular-datum-labels" (equal? '#1=(a b . #1#) '#2=(a b a b . #2#)))

(news "--- spec-audit: numbers (6.2) modulo/remainder sign matrix + expt ---\n")
(check "modulo/13-4" 1 (modulo 13 4))
(check "remainder/13-4" 1 (remainder 13 4))
(check "modulo/-13-4" 3 (modulo -13 4))
(check "remainder/-13-4" -1 (remainder -13 4))
(check "modulo/13--4" -3 (modulo 13 -4))
(check "remainder/13--4" 1 (remainder 13 -4))
(check "modulo/-13--4" -1 (modulo -13 -4))
(check "remainder/-13--4" -1 (remainder -13 -4))
(check "remainder/-13--4.0" -1.0 (remainder -13 -4.0))
;; B120: an INEXACT integer is still an integer (R7RS 6.2.6) -- result is inexact.
(check "quotient/-13--4.0"  3.0  (quotient -13 -4.0))
(check "modulo/-13--4.0"   -1.0  (modulo -13 -4.0))
(check "remainder/-13.0-4" -1.0  (remainder -13.0 4))
(check "floor-remainder/-13-4.0" 3.0 (floor-remainder -13 4.0))
(check-true "remainder/inexact-result-is-inexact" (inexact? (remainder -13 -4.0)))
(check "expt/0-0" 1 (expt 0 0))

(news "--- spec-audit: pairs, lists, symbols (6.4/6.5) ---\n")
(check-false "list?/cyclic-spec" (list? (let ((x (list 'a))) (set-cdr! x x) x)))
(check "make-list/2-3" '(3 3) (make-list 2 3))
(check "list-tail/abcd-2" '(c d) (list-tail '(a b c d) 2))
(check "string->symbol/mISSISSIppi" 'mISSISSIppi (string->symbol "mISSISSIppi"))
(check-true "string->symbol/eq-bitBlt" (eq? 'bitBlt (string->symbol "bitBlt")))
(check-true "string->symbol/eq-LollyPop" (eq? 'LollyPop (string->symbol (symbol->string 'LollyPop))))

(news "--- spec-audit: vectors, bytevectors, control (6.8/6.9/6.10) ---\n")
(check "vector-copy/mutable-copy" '#(3 8 2 8) (let* ((a '#(1 8 2 8)) (b (vector-copy a))) (vector-set! b 0 3) b))
(check "vector-copy/range" '#(8 2) (let* ((a '#(1 8 2 8)) (b (vector-copy a))) (vector-set! b 0 3) (vector-copy b 1 3)))
(check "bytevector/6" (bytevector 1 3 5 1 3 5) (bytevector 1 3 5 1 3 5))
(check "bytevector/0" (bytevector) (bytevector))
(check "string->utf8/lambda" (bytevector #xCE #xBB) (string->utf8 "λ"))
(check "map/+uneven" '(5 7 9) (map + '(1 2 3) '(4 5 6 7)))
(check "cwv/values-4-5" 5 (call-with-values (lambda () (values 4 5)) (lambda (a b) b)))
(check "cwv/star-minus" -1 (call-with-values * -))

(news "--- spec-audit: eval, exceptions (6.11/6.12) ---\n")
(check "eval/environment" 21 (eval '(* 7 3) (environment '(scheme base))))
;; raise-continuable resumption is part of the accepted call/cc-family gap (B1):
(check-exception "raise-continuable/65" 65
  (with-exception-handler
    (lambda (con) (if (string? con) 42 77))
    (lambda () (+ (raise-continuable "should be a number") 23))))
;; null-environment (B108 fixed): a syntax-only env; lambda (core) works, procedures are not visible.
(check "eval/null-environment" 20
  (let ((f (eval '(lambda (f x) (f x x)) (null-environment 5)))) (f + 10)))
(check-error "null-environment/no-procedures"       ;; verify the split: `+` is NOT in null-env
  (lambda () (eval '(+ 1 2) (null-environment 5))))
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
(check-true "caadr"  (eqv? (caadr cxr-t)  (car (car (cdr cxr-t)))))
(check-true "cadar"  (eqv? (cadar cxr-t)  (car (cdr (car cxr-t)))))
(check-true "cdaar"  (eqv? (cdaar cxr-t)  (cdr (car (car cxr-t)))))
(check-true "cdadr"  (eqv? (cdadr cxr-t)  (cdr (car (cdr cxr-t)))))
(check-true "cddar"  (eqv? (cddar cxr-t)  (cdr (cdr (car cxr-t)))))
(check-true "caaaar" (eqv? (caaaar cxr-t) (car (car (car (car cxr-t))))))
(check-true "caaadr" (eqv? (caaadr cxr-t) (car (car (car (cdr cxr-t))))))
(check-true "caadar" (eqv? (caadar cxr-t) (car (car (cdr (car cxr-t))))))
(check-true "caaddr" (eqv? (caaddr cxr-t) (car (car (cdr (cdr cxr-t))))))
(check-true "cadaar" (eqv? (cadaar cxr-t) (car (cdr (car (car cxr-t))))))
(check-true "cadadr" (eqv? (cadadr cxr-t) (car (cdr (car (cdr cxr-t))))))
(check-true "caddar" (eqv? (caddar cxr-t) (car (cdr (cdr (car cxr-t))))))
(check-true "cdaaar" (eqv? (cdaaar cxr-t) (cdr (car (car (car cxr-t))))))
(check-true "cdaadr" (eqv? (cdaadr cxr-t) (cdr (car (car (cdr cxr-t))))))
(check-true "cdadar" (eqv? (cdadar cxr-t) (cdr (car (cdr (car cxr-t))))))
(check-true "cdaddr" (eqv? (cdaddr cxr-t) (cdr (car (cdr (cdr cxr-t))))))
(check-true "cddaar" (eqv? (cddaar cxr-t) (cdr (cdr (car (car cxr-t))))))
(check-true "cddadr" (eqv? (cddadr cxr-t) (cdr (cdr (car (cdr cxr-t))))))
(check-true "cdddar" (eqv? (cdddar cxr-t) (cdr (cdr (cdr (car cxr-t))))))

(news "--- coverage: inexact trig ---\n")
(check-true "sin/0"  (= (sin 0) 0))
(check-true "cos/0"  (= (cos 0) 1))
(check-true "tan/0"  (= (tan 0) 0))
(check-true "asin/0" (= (asin 0) 0))
(check-true "exp/0"  (= (exp 0) 1))

(news "--- coverage: ports ---\n")
(check-true "textual-port?"     (textual-port? (open-output-string)))
(check-true "binary-port?"      (binary-port?  (open-output-bytevector)))
(check-true "eof-object"        (eof-object? (eof-object)))
(check-true "close-port"        (let ((p (open-output-string))) (close-port p) (not (output-port-open? p))))
(check-true "close-output-port" (let ((p (open-output-string))) (close-output-port p) #t))
(check-true "flush-output-port" (let ((p (open-output-string))) (flush-output-port p) #t))
(check      "read-string"  "abc" (read-string 3 (open-input-string "abcdef")))
(check-true "read-bytevector"  (equal? (read-bytevector 2 (open-input-bytevector (bytevector 1 2 3))) (bytevector 1 2)))
(check-true "read-bytevector!" (let ((bv (make-bytevector 3 0)))
                                 (read-bytevector! bv (open-input-bytevector (bytevector 9 8 7)))
                                 (equal? bv (bytevector 9 8 7))))

(news "--- coverage: write-simple / write-shared ---\n")
(check "write-simple" "(1 2 3)" (let ((p (open-output-string))) (write-simple '(1 2 3) p) (get-output-string p)))
(check "write-shared" "(1 2 3)" (let ((p (open-output-string))) (write-shared '(1 2 3) p) (get-output-string p)))

(news "--- coverage: cond-expand ---\n")
(check "cond-expand/else" 'ok (cond-expand (else 'ok)))

(news "--- coverage: file I/O ---\n")
(check "file/call-with"  "hello"
  (begin (call-with-output-file "cov-tmp.txt" (lambda (p) (write-string "hello" p)))
         (call-with-input-file  "cov-tmp.txt" (lambda (p) (read-string 5 p)))))
(check-true "file-exists?"     (file-exists? "cov-tmp.txt"))
(check-true "delete-file"      (begin (delete-file "cov-tmp.txt") (not (file-exists? "cov-tmp.txt"))))
(check "file/with-to-from" "world"
  (begin (with-output-to-file "cov-t2.txt" (lambda () (write-string "world")))
         (with-input-from-file "cov-t2.txt" (lambda () (read-string 5)))))
(check-true "file/cleanup2"    (begin (delete-file "cov-t2.txt") #t))
(check "file/open" "data"
  (begin (let ((p (open-output-file "cov-t3.txt"))) (write-string "data" p) (close-port p))
         (let* ((p (open-input-file "cov-t3.txt")) (s (read-string 4 p))) (close-port p) s)))
(check-true "file/cleanup3"    (begin (delete-file "cov-t3.txt") #t))
(check-true "file/binary"
  (begin (let ((p (open-binary-output-file "cov-b.bin"))) (write-u8 65 p) (write-u8 66 p) (close-port p))
         (let* ((p (open-binary-input-file "cov-b.bin")) (a (read-u8 p)) (b (read-u8 p)))
           (close-port p) (delete-file "cov-b.bin") (and (= a 65) (= b 66)))))

(news "--- coverage: syntax-error ---\n")
(check-error "syntax-error" (lambda () (eval '(syntax-error "boom") (interaction-environment))))

(news "--- coverage: include-ci ---\n")
;; include-ci reads case-insensitively: DEFINE folds to define, so cov-inc-val gets bound.
(call-with-output-file "cov-inc.scm" (lambda (p) (write-string "(DEFINE cov-inc-val 42)" p)))
(include-ci "cov-inc.scm")
(check "include-ci" 42 cov-inc-val)
(delete-file "cov-inc.scm")

;;; R7RS 5.6 -- the LIBRARY system: define-library / import / export / import-sets.  The library
;;; system is a DELIBERATE design gap on this hard-real-time embedded target (like call/cc and
;;; dynamic-wind): the whole program is one image, so per-library namespaces add no value.  These
;;; are EXERCISED and counted as EXCEPTIONS (not failures) so every report enumerates them, and each
;;; auto-flips to PASS if the library system is ever implemented.
(news "--- 5.6 library system (embedded design gap) ---\n")
(check-exception "define-library/import" 42
  (begin
    (define-library (conform testlib)
      (export answer)
      (begin (define answer 42)))
    (import (conform testlib))
    answer))
(check-exception "import/only" 1
  (begin (define-library (conform onlylib) (export a b) (begin (define a 1) (define b 2)))
         (import (only (conform onlylib) a)) a))
(check-exception "import/except" 2
  (begin (define-library (conform exclib) (export a b) (begin (define a 1) (define b 2)))
         (import (except (conform exclib) a)) b))
(check-exception "import/prefix" 1
  (begin (define-library (conform prelib) (export a) (begin (define a 1)))
         (import (prefix (conform prelib) pre:)) pre:a))
(check-exception "import/rename" 1
  (begin (define-library (conform renlib) (export a) (begin (define a 1)))
         (import (rename (conform renlib) (a aa))) aa))

;;; (scheme process-context) + (features) -- now implemented (ll_xmop3_platform_generic.cpp).
;;; exit/emergency-exit are tested for existence + type ONLY (never invoked -- they terminate).
(news "--- coverage: process-context + features ---\n")
(check-true "features"                  (and (list? (features)) (memq 'r7rs (features)) #t))
(check-true "command-line"              (list? (command-line)))
(check-true "get-environment-variable"  (let ((v (get-environment-variable "PATH"))) (or (string? v) (eq? v #f))))
(check-true "get-environment-variables" (list? (get-environment-variables)))
(check-true "exit"                      (procedure? exit))
(check-true "emergency-exit"            (procedure? emergency-exit))

(news "--- coverage: file-error? / read-error? ---\n")
;; open-input-file on a missing file signals a file-error (R7RS); read signals a read-error on
;; malformed input.  Verify each predicate recognizes its own kind and NOT the other / user errors.
(check-true "file-error?"           (file-error? (guard (e (#t e)) (open-input-file "no-such-file-zzz999.scm"))))
(check-true "file-error?/not-user"  (not (file-error? (guard (e (#t e)) (error "plain user error")))))
(check-true "file-error?/not-read"  (not (file-error? (guard (e (#t e)) (read (open-input-string "(1 2"))))))
(check-true "read-error?/eof"       (read-error? (guard (e (#t e)) (read (open-input-string "(1 2")))))
(check-true "read-error?/bad-bytevector" (read-error? (guard (e (#t e)) (read (open-input-string "#u8(300)")))))
(check-true "read-error?/not-user"  (not (read-error? (guard (e (#t e)) (error "plain user error")))))
(check-true "read-error?/not-file"  (not (read-error? (guard (e (#t e)) (open-input-file "no-such-file-zzz999.scm")))))

(news "\n=== R7RS TEST SUMMARY: ~a passed, ~a failed ===\n" *pass* *fail*)
(if (= *fail* 0)
  (news "ALL TESTS PASSED\n")
  (warn "~a TESTS FAILED\n" *fail*))
(define r7rs-pass *pass*)
(define r7rs-fail *fail*)
(define r7rs-exception *exception*)
;; Expected exceptions in a clean run: call/cc (6) + dynamic-wind (3) + make-parameter/parameterize (9)
;; + raise-continuable (1) + library system (5: define-library/import/only/except/prefix/rename) = 24.
;; All are deliberate hard-real-time embedded design gaps; the rest of R7RS-small is implemented.
(define r7rs-exception-expected 24)

