;;; Copyright 2026 by Frobenius Norm LLC 2026-04-10 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; quiet-tests.scm -- Quiet per-step correctness test runner
;;;
;;; Mirrors r7rs-tests.scm + lamblisp-tests.scm.  Only outputs FAILs.
;;; Each check/check-true/check-false/check-error call adds one thunk.
;;; step runs one thunk per call (returns #t while tests remain, #f when done).
;;; run  runs all remaining thunks then prints summary.
;;;
;;; Usage:
;;;   (load "quiet-tests.scm")    ;; collects thunks, runs at EOF
;;;
;;; One-per-loop usage (call step from your main loop):
;;;   (load "quiet-tests.scm" 1)  ;; collects thunks only (no auto-run)
;;;   ... then call (bench-step) each iteration

;;; ---------------------------------------------------------------------------
;;; Infrastructure
;;; ---------------------------------------------------------------------------

;;; LambLisp-only feature flag.
;;; Load chez-compat.scm BEFORE this file to set it to #f on Chez Scheme.
;;; The guard pattern preserves an existing binding (set by compat), else defaults to #t.
(define *bench-lamblisp-only*
  (guard (e (#t #t)) *bench-lamblisp-only*))

(define *bench-pass*  0)
(define *bench-fail*  0)
(define *bench-queue* '())   ;;!< thunk list, reversed during collection
(define *bench-vec*   #f)    ;;!< #f until bench-init! is called
(define *bench-idx*   0)
(define *bench-total* 0)

(define (bench-add! thunk27)
  (set! *bench-queue* (cons thunk27 *bench-queue*)))

(define (bench-init!)
  (set! *bench-vec*   (list->vector (reverse *bench-queue*)))
  (set! *bench-total* (vector-length *bench-vec*))
  (set! *bench-idx*   0)
  (set! *bench-queue* '()))

;;; (bench name expected actual) -- quiet check; args are pre-evaluated
(define (bench name expected actual)
  (let ((n name) (e expected) (a actual))
    (bench-add!
     (lambda ()
       (if (equal? e a)
           (set! *bench-pass* (+ *bench-pass* 1))
           (begin
             (set! *bench-fail* (+ *bench-fail* 1))
             (display "FAIL ") (display n)
             (display "  expected=") (write e)
             (display "  got=") (write a) (newline)))))))

(define (bench-true name actual)
  (let ((n name) (a actual))
    (bench-add!
     (lambda ()
       (if a
           (set! *bench-pass* (+ *bench-pass* 1))
           (begin
             (set! *bench-fail* (+ *bench-fail* 1))
             (display "FAIL ") (display n)
             (display "  expected=#t  got=") (write a) (newline)))))))

(define (bench-false name actual)
  (let ((n name) (a actual))
    (bench-add!
     (lambda ()
       (if (not a)
           (set! *bench-pass* (+ *bench-pass* 1))
           (begin
             (set! *bench-fail* (+ *bench-fail* 1))
             (display "FAIL ") (display n)
             (display "  expected=#f  got=") (write a) (newline)))))))

;;; (bench-error name thunk) -- thunk called INSIDE the deferred thunk.
;;; Uses guard so handler escape works on both LambLisp and Chez (non-continuable).
(define (bench-error name thunk28)
  (let ((n name) (t thunk28))
    (bench-add!
     (lambda ()
       (let ((r (guard (e (#t 'caught))
                  (t)
                  'no-error)))
         (if (eq? r 'caught)
             (set! *bench-pass* (+ *bench-pass* 1))
             (begin
               (set! *bench-fail* (+ *bench-fail* 1))
               (display "FAIL ") (display n)
               (display "  expected error, got none\n"))))))))

;;; Run one thunk; returns #t while tests remain, #f when summary printed
(define (bench-step)
  (when (not *bench-vec*) (bench-init!))
  (cond
   ((< *bench-idx* *bench-total*)
    ((vector-ref *bench-vec* *bench-idx*))
    (set! *bench-idx* (+ *bench-idx* 1))
    #t)
   (else
    (display "\n=== BENCH SUMMARY: ")
    (display *bench-pass*) (display " passed, ")
    (display *bench-fail*) (display " failed / ")
    (display *bench-total*) (display " total ===\n")
    #f)))

;;; Run all remaining tests then print summary
(define (bench-run)
  (when (not *bench-vec*) (bench-init!))
  (let loop ()
    (when (< *bench-idx* *bench-total*)
      ((vector-ref *bench-vec* *bench-idx*))
      (set! *bench-idx* (+ *bench-idx* 1))
      (loop)))
  (display "\n=== BENCH SUMMARY: ")
  (display *bench-pass*) (display " passed, ")
  (display *bench-fail*) (display " failed / ")
  (display *bench-total*) (display " total ===\n"))

;;; ---------------------------------------------------------------------------
;;; 6.1  Equivalence predicates                              (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(bench-true  "eq?/symbols"        (eq? 'foo 'foo))
(bench-false "eq?/diff-symbols"   (eq? 'foo 'bar))
(bench-true  "eq?/#t"             (eq? #t #t))
(bench-true  "eq?/#f"             (eq? #f #f))
(bench-false "eq?/#t-#f"          (eq? #t #f))
(bench-true  "eq?/nil"            (eq? '() '()))
(bench-true  "eq?/same-pair"      (let ((x '(1 2))) (eq? x x)))
(bench-false "eq?/diff-pairs"     (eq? '(1 2) '(1 2)))
(bench-true  "eq?/char"           (eq? #\a #\a))

(bench-true  "eqv?/symbols"       (eqv? 'foo 'foo))
(bench-true  "eqv?/integers"      (eqv? 42 42))
(bench-true  "eqv?/#t"            (eqv? #t #t))
(bench-true  "eqv?/#f"            (eqv? #f #f))
(bench-true  "eqv?/chars"         (eqv? #\a #\a))
(bench-true  "eqv?/nil"           (eqv? '() '()))
(bench-false "eqv?/diff-ints"     (eqv? 1 2))
(bench-false "eqv?/int-float"     (eqv? 1 1.0))

(bench-true  "equal?/atoms"       (equal? 42 42))
(bench-true  "equal?/strings"     (equal? "hello" "hello"))
(bench-true  "equal?/lists"       (equal? '(1 2 3) '(1 2 3)))
(bench-true  "equal?/nested"      (equal? '(1 (2 3) 4) '(1 (2 3) 4)))
(bench-true  "equal?/vectors"     (equal? '#(1 2 3) '#(1 2 3)))
(bench-false "equal?/diff"        (equal? '(1 2) '(1 3)))
(bench-true  "equal?/nil"         (equal? '() '()))
(bench-true  "equal?/#f"          (equal? #f #f))
(bench-true  "equal?/#t"          (equal? #t #t))

;;; ---------------------------------------------------------------------------
;;; 6.2  Numbers                                             (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(bench-true  "number?"            (number? 42))
(bench-true  "number?/float"      (number? 3.14))
(bench-false "number?/str"        (number? "3"))
(bench-true  "integer?/exact"     (integer? 3))
(bench-true  "integer?/inexact"   (integer? 3.0))
(bench-false "integer?/frac"      (integer? 3.5))
(bench-true  "exact?"             (exact? 3))
(bench-false "exact?/float"       (exact? 3.0))
(bench-false "inexact?"           (inexact? 3))
(bench-true  "inexact?/float"     (inexact? 3.0))
(bench-true  "zero?"              (zero? 0))
(bench-false "zero?/nonzero"      (zero? 1))
(bench-true  "positive?"          (positive? 1))
(bench-false "positive?/neg"      (positive? -1))
(bench-true  "negative?"          (negative? -1))
(bench-false "negative?/pos"      (negative? 1))
(bench-true  "odd?"               (odd? 3))
(bench-false "odd?/even"          (odd? 4))
(bench-true  "even?"              (even? 4))
(bench-false "even?/odd"          (even? 3))

(bench "+"                        6     (+ 1 2 3))
(bench "+/zero"                   0     (+))
(bench "-"                        7     (- 10 3))
(bench "-/negate"                 -5    (- 5))
(bench "*"                        24    (* 2 3 4))
(bench "*/one"                    1     (*))
(bench "/"                        3     (/ 12 4))
(bench "quotient"                 3     (quotient 10 3))
(bench "quotient/neg"             -3    (quotient -10 3))
(bench "remainder"                1     (remainder 10 3))
(bench "remainder/neg"            -1    (remainder -10 3))
(bench "modulo"                   1     (modulo 10 3))
(bench "modulo/neg"               2     (modulo -10 3))
(bench "abs/neg"                  5     (abs -5))
(bench "abs/pos"                  5     (abs 5))
(bench "max"                      5     (max 1 3 5 2 4))
(bench "min"                      1     (min 3 1 4 1 5))
(bench "gcd"                      4     (gcd 12 8))
(bench "lcm"                      24    (lcm 12 8))
(bench "expt"                     1024  (expt 2 10))
(bench "expt/0"                   1     (expt 5 0))
(bench "floor"                    3.0   (floor 3.7))
(bench "ceiling"                  4.0   (ceiling 3.2))
(bench "truncate"                 3.0   (truncate 3.7))
(bench "truncate/neg"             -3.0  (truncate -3.7))
(bench "round/half-up"            4.0   (round 3.5))
(bench "round/half-even"          4.0   (round 4.5))
(bench "round/down"               3.0   (round 3.4))
(bench "sqrt/inexact"             2.0   (sqrt 4.0))
(bench "floor->exact"             3     (floor->exact 3.7))
(bench "ceiling->exact"           4     (ceiling->exact 3.2))
(bench "truncate->exact"          3     (truncate->exact 3.7))
(bench "round->exact"             4     (round->exact 3.5))
(bench "exact->inexact"           3.0   (exact->inexact 3))
(bench "inexact->exact"           3     (inexact->exact 3.0))
(bench "number->string"           "42"  (number->string 42))
(bench "number->string/hex"       "ff"  (number->string 255 16))
(bench "string->number"           42    (string->number "42"))
(bench "string->number/hex"       255   (string->number "ff" 16))
(bench-false "string->number/bad" (string->number "abc"))
(bench-true  "boolean?"           (boolean? #t))
(bench-false "boolean?/num"       (boolean? 0))
(bench-true  "not/#f"             (not #f))
(bench-false "not/#t"             (not #t))
(bench-false "not/0"              (not 0))
(bench-false "not/nil"            (not '()))

;;; ---------------------------------------------------------------------------
;;; 6.3  Characters                                          (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(bench-true  "char?"              (char? #\a))
(bench-false "char?/str"          (char? "a"))
(bench       "char->int/A"        65    (char->integer #\A))
(bench       "char->int/a"        97    (char->integer #\a))
(bench       "char->int/0"        48    (char->integer #\0))
(bench       "char->int/sp"       32    (char->integer #\space))
(bench       "char->int/nl"       10    (char->integer #\newline))
(bench       "int->char/65"       #\A   (integer->char 65))
(bench-true  "char-alpha?"        (char-alphabetic? #\a))
(bench-false "char-alpha?/0"      (char-alphabetic? #\0))
(bench-true  "char-num?"          (char-numeric? #\5))
(bench-false "char-num?/a"        (char-numeric? #\a))
(bench-true  "char-ws?/sp"        (char-whitespace? #\space))
(bench-true  "char-ws?/nl"        (char-whitespace? #\newline))
(bench-false "char-ws?/a"         (char-whitespace? #\a))
(bench-true  "char-upper?"        (char-upper-case? #\A))
(bench-false "char-upper?/a"      (char-upper-case? #\a))
(bench-true  "char-lower?"        (char-lower-case? #\a))
(bench-false "char-lower?/A"      (char-lower-case? #\A))
(bench       "char-upcase"        #\A   (char-upcase #\a))
(bench       "char-downcase"      #\a   (char-downcase #\A))
(bench-true  "char=?"             (char=? #\a #\a))
(bench-false "char=?/diff"        (char=? #\a #\b))
(bench-true  "char<?"             (char<? #\a #\b))
(bench-false "char<?/rev"         (char<? #\b #\a))

;;; ---------------------------------------------------------------------------
;;; 6.4  Strings                                             (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(bench-true  "string?"            (string? "hi"))
(bench-false "string?/sym"        (string? 'hi))
(bench       "string-length"      5     (string-length "hello"))
(bench       "string-length/empty" 0   (string-length ""))
(bench       "string-ref/0"       #\h   (string-ref "hello" 0))
(bench       "string-ref/4"       #\o   (string-ref "hello" 4))
(bench       "substring"          "el"  (substring "hello" 1 3))
(bench       "substring/full"     "hello" (substring "hello" 0 5))
(bench       "string-append"      "hello world" (string-append "hello" " " "world"))
(bench       "string-append/0"    ""    (string-append))
(bench       "string->list"       '(#\a #\b #\c) (string->list "abc"))
(bench       "list->string"       "abc" (list->string '(#\a #\b #\c)))
(bench       "string-copy"        "hi"  (string-copy "hi"))
(bench-true  "string=?"           (string=? "abc" "abc"))
(bench-false "string=?/diff"      (string=? "abc" "abd"))
(bench-true  "string<?"           (string<? "abc" "abd"))
(bench-false "string<?/rev"       (string<? "abd" "abc"))
(bench-true  "string>?"           (string>? "abd" "abc"))
(bench-true  "string<=?/eq"       (string<=? "abc" "abc"))
(bench-true  "string>=?/eq"       (string>=? "abc" "abc"))
(bench       "string-upcase"      "HELLO" (string-upcase "hello"))
(bench       "string-downcase"    "hello" (string-downcase "HELLO"))
(bench       "number->str/3"      "3"   (number->string 3))
(bench       "string->number/3.14" 3.14 (string->number "3.14"))

;;; string-contains (R7RS large / SRFI-13)
(bench       "string-contains"    6     (string-contains "hello world" "world"))
(bench-false "string-contains/no" (string-contains "hello" "xyz"))

;;; ---------------------------------------------------------------------------
;;; 4.1  Primitive expression types                          (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(bench       "quote/sym"          'foo          'foo)
(bench       "quote/list"         '(1 2 3)      '(1 2 3))
(bench       "quote/nil"          '()           '())
(bench       "lambda/call"        6             ((lambda (x y) (* x y)) 2 3))
(bench       "lambda/rest"        '(2 3 4)      ((lambda (x . rest) rest) 1 2 3 4))
(bench       "lambda/rest-all"    '(1 2 3)      ((lambda args args) 1 2 3))
(bench       "lambda/closure"     10            (let ((x 3)) ((lambda (y) (+ x y)) 7)))
(bench       "lambda/multi-body"  3             ((lambda (x) (+ x 1) (+ x 2)) 1))
(bench       "if/true"            1             (if #t 1 2))
(bench       "if/false"           2             (if #f 1 2))
(bench       "if/truthy-0"        1             (if 0 1 2))
(bench       "if/truthy-nil"      1             (if '() 1 2))
(bench       "if/no-else"         'ok           (if #t 'ok))
(bench       "set!"               20            (let ((x 10)) (set! x 20) x))

;;; ---------------------------------------------------------------------------
;;; 4.2  Derived expression types                            (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(bench       "cond/first"         1    (cond (#t 1) (else 2)))
(bench       "cond/second"        2    (cond (#f 1) (#t 2) (else 3)))
(bench       "cond/else"          3    (cond (#f 1) (#f 2) (else 3)))
(bench       "cond/=>"            4    (cond (2 => (lambda (x) (* x 2)))))
(bench       "cond/multi-body"    3    (cond (#t 1 2 3)))
(bench       "case/match"         'b   (case 2 ((1) 'a) ((2) 'b) (else 'c)))
(bench       "case/else"          'c   (case 5 ((1) 'a) ((2) 'b) (else 'c)))
(bench       "case/multi-datum"   'ab  (case 2 ((1 3) 'odd) ((2 4) 'ab) (else 'c)))
(bench       "and/all-true"       3    (and 1 2 3))
(bench       "and/false"          #f   (and 1 #f 3))
(bench       "and/empty"          #t   (and))
(bench       "or/skip-false"      2    (or #f 2 3))
(bench       "or/all-false"       #f   (or #f #f))
(bench       "or/empty"           #f   (or))
(bench       "when/true"          3    (when #t 1 2 3))
(bench       "unless/false"       3    (unless #f 1 2 3))

(bench       "let"                3    (let ((x 1) (y 2)) (+ x y)))
(bench       "let/shadow"         1    (let ((x 1)) (let ((x 2) (y x)) y)))
(bench       "let*"               3    (let* ((x 1) (y (+ x 2))) y))
(bench       "letrec/fact"        120  (letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 5)))
(bench-true  "letrec/mutual"
  (letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
           (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
    (even? 10)))
(bench       "letrec*"            4    (letrec* ((x 1) (y (+ x 2)) (z (+ x y))) z))
(bench       "named-let/sum"      55   (let loop ((i 10) (acc 0))
                                         (if (= i 0) acc (loop (- i 1) (+ acc i)))))
(bench       "named-let/fact"     120  (let fact ((n 5) (acc 1))
                                         (if (= n 0) acc (fact (- n 1) (* acc n)))))

(bench       "do/sum"             10
  (do ((i 0 (+ i 1)) (sum 0 (+ sum i)))
    ((= i 5) sum)))
(bench       "do/build-list"      '(4 3 2 1 0)
  (do ((i 0 (+ i 1)) (acc '() (cons i acc)))
    ((= i 5) acc)))
(bench       "do/vector"          '#(0 1 2 3 4)
  (let ((v (make-vector 5)))
    (do ((i 0 (+ i 1)))
      ((= i 5) v)
      (vector-set! v i i))))

(bench       "quasiquote/lit"     '(1 2 3)     `(1 2 3))
(bench       "unquote"            '(1 99 3)    `(1 ,(+ 90 9) 3))
(bench       "unquote-splicing"   '(1 2 3 4 5) `(1 ,@(list 2 3 4) 5))
(bench       "quasi-nested"       '(1 (2 3) 4) `(1 (,(+ 1 1) 3) 4))
(bench       "quasi-empty-splice" '(1 2)       `(1 ,@'() 2))

;;; ---------------------------------------------------------------------------
;;; 5.x  Definitions                                         (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(define bench-testval 42)
(bench       "define/var"         42    bench-testval)
(define (bench-testadd a b) (+ a b))
(bench       "define/proc"        7     (bench-testadd 3 4))
(define (bench-testfact n) (if (= n 0) 1 (* n (bench-testfact (- n 1)))))
(bench       "define/recursive"   120   (bench-testfact 5))

(define-values (bench-va bench-vb bench-vc) (values 10 20 30))
(bench       "define-values/a"    10    bench-va)
(bench       "define-values/b"    20    bench-vb)
(bench       "define-values/c"    30    bench-vc)

;;; ---------------------------------------------------------------------------
;;; 5.5  define-record-type                                  (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(define-record-type <bench-point>
  (bench-make-point x y)
  bench-point?
  (x bench-point-x)
  (y bench-point-y))

(define bench-pt (bench-make-point 3 4))
(bench-true  "point?"             (bench-point? bench-pt))
(bench-false "point?/false"       (bench-point? '(3 4)))
(bench       "point-x"            3    (bench-point-x bench-pt))
(bench       "point-y"            4    (bench-point-y bench-pt))

;;; ---------------------------------------------------------------------------
;;; 6.5  Pairs and lists                                     (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(bench-true  "null?/nil"          (null? '()))
(bench-false "null?/pair"         (null? '(1)))
(bench-true  "pair?/pair"         (pair? '(1 2)))
(bench-false "pair?/nil"          (pair? '()))
(bench-false "pair?/atom"         (pair? 42))
(bench-true  "list?/proper"       (list? '(1 2 3)))
(bench-true  "list?/nil"          (list? '()))
(bench-false "list?/dotted"       (list? '(1 . 2)))
(bench       "car"                1          (car '(1 2 3)))
(bench       "cdr"                '(2 3)     (cdr '(1 2 3)))
(bench       "cadr"               2          (cadr '(1 2 3)))
(bench       "caddr"              3          (caddr '(1 2 3)))
(bench       "cons/list"          '(1 2 3)   (cons 1 '(2 3)))
(bench       "cons/dotted"        '(1 . 2)   (cons 1 2))
(bench       "list"               '(1 2 3)   (list 1 2 3))
(bench       "length"             3          (length '(1 2 3)))
(bench       "length/nil"         0          (length '()))
(bench       "append/two"         '(1 2 3 4) (append '(1 2) '(3 4)))
(bench       "append/nil-left"    '(1 2)     (append '() '(1 2)))
(bench       "append/nil-right"   '(1 2)     (append '(1 2) '()))
(bench       "reverse"            '(3 2 1)   (reverse '(1 2 3)))
(bench       "reverse/nil"        '()        (reverse '()))
(bench       "list-tail"          '(3 4)     (list-tail '(1 2 3 4) 2))
(bench       "list-ref"           2          (list-ref '(1 2 3) 1))
(bench       "map/sq"             '(1 4 9 16) (map (lambda (x) (* x x)) '(1 2 3 4)))
(bench       "map/two-lists"      '(5 7 9)   (map + '(1 2 3) '(4 5 6)))
(bench       "filter"             '(1 3 5)   (filter odd? '(1 2 3 4 5)))
(bench       "assoc/hit"          '(b 2)     (assoc 'b '((a 1) (b 2) (c 3))))
(bench-false "assoc/miss"         (assoc 'd '((a 1) (b 2))))
(bench       "assq/hit"           '(b . 2)   (assq 'b '((a . 1) (b . 2))))
(bench       "member/hit"         '(3 4)     (member 3 '(1 2 3 4)))
(bench-false "member/miss"        (member 5 '(1 2 3)))
(bench       "memq/hit"           '(b c)     (memq 'b '(a b c)))

(bench       "for-each/side-effect" 15
  (let ((sum 0))
    (for-each (lambda (x) (set! sum (+ sum x))) '(1 2 3 4 5))
    sum))

(bench       "fold-left"          15    (fold-left  + 0 '(1 2 3 4 5)))
(bench       "fold-right/cons"    '(1 2 3) (fold-right cons '() '(1 2 3)))

;;; ---------------------------------------------------------------------------
;;; 6.6  Vectors                                             (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(bench-true  "vector?"            (vector? (vector 1 2)))
(bench-false "vector?/list"       (vector? '(1 2)))
(bench       "vector-length"      3     (vector-length (vector 1 2 3)))
(bench       "vector-ref"         20    (vector-ref (vector 10 20 30) 1))
(bench       "make-vector"        (vector 0 0 0) (make-vector 3 0))
(bench       "vector"             (vector 1 2 3) (vector 1 2 3))
(bench       "vector->list"       '(1 2 3) (vector->list (vector 1 2 3)))
(bench       "list->vector"       (vector 1 2 3) (list->vector '(1 2 3)))
(bench       "vector-set!"        99
  (let ((v (vector 1 2 3)))
    (vector-set! v 1 99)
    (vector-ref v 1)))
(bench       "vector-fill!"       (vector 7 7 7)
  (let ((v (vector 1 2 3)))
    (vector-fill! v 7)
    v))

;;; ---------------------------------------------------------------------------
;;; 6.7  Bytevectors                                         (r7rs)
;;; ---------------------------------------------------------------------------

(bench-true  "bytevector?"        (bytevector? (bytevector 1 2)))
(bench-false "bytevector?/vec"    (bytevector? (vector 1 2)))
(bench       "bvec-length"        3     (bytevector-length (bytevector 1 2 3)))
(bench       "bvec-ref"           20    (bytevector-u8-ref (bytevector 10 20 30) 1))
(bench       "make-bytevector"    (bytevector 0 0 0) (make-bytevector 3 0))
(bench       "bytevector"         (bytevector 1 2 3) (bytevector 1 2 3))
(bench       "bvec-set!"          99
  (let ((v (bytevector 1 2 3)))
    (bytevector-u8-set! v 1 99)
    (bytevector-u8-ref v 1)))
(bench       "bvec-copy"          (bytevector 2 3)
  (bytevector-copy (bytevector 1 2 3) 1 3))
(bench       "utf8->string"       "hi"   (utf8->string (bytevector 104 105)))
(bench       "string->utf8"       (bytevector 104 105) (string->utf8 "hi"))

;;; ---------------------------------------------------------------------------
;;; 6.8  Control features                                    (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(bench       "apply/sum"          6     (apply + '(1 2 3)))
(bench       "apply/mixed"        10    (apply + 1 2 '(3 4)))
(bench       "apply/list"         '(1 2 3) (apply list '(1 2 3)))

(bench       "values/single"      42    (call-with-values (lambda () 42) (lambda (x) x)))
(bench       "values/multi"       3     (call-with-values (lambda () (values 1 2)) +))

;;; ---------------------------------------------------------------------------
;;; 6.9  Exceptions                                          (r7rs + lamblisp)
;;; ---------------------------------------------------------------------------

(bench-error "error/basic"        (lambda () (error "test error")))
(bench-error "error/irritants"    (lambda () (error "msg" 1 2 3)))

;;; Use guard for all exception tests (guard correctly handles non-continuable
;;; on both LambLisp and Chez via call/cc; with-exception-handler returning from
;;; non-continuable raise is forbidden in R7RS and raises &non-continuable on Chez).

(bench       "with-exc-handler/msg" "oops"
  (guard (e (#t (if (error-object? e) (error-object-message e) "?")))
    (error "oops" 42)))

(bench-true  "error-object?"
  (guard (e (#t (error-object? e)))
    (error "test")))

(bench       "error-object-message" "boom"
  (guard (e (#t (error-object-message e)))
    (error "boom" 1 2)))

(bench       "error-object-irritants" '(1 2)
  (guard (e (#t (error-object-irritants e)))
    (error "msg" 1 2)))

(bench       "raise/non-error"    42
  (guard (e (#t e))
    (raise 42)))

(bench       "guard/match"        "test"
  (guard (e (#t (error-object-message e)))
    (error "test" 1)))

(bench       "guard/no-match->reraise" 'caught
  (guard (outer (#t 'caught))
    (guard (e ((string? e) e))
      (error "test"))))

(bench       "guard/else"         'handled
  (guard (e (else 'handled))
    (error "anything")))

;;; ---------------------------------------------------------------------------
;;; 6.13  Ports                                              (r7rs)
;;; ---------------------------------------------------------------------------

(bench-true  "input-port?"        (input-port? (open-input-string "x")))
(bench-true  "output-port?"       (output-port? (open-output-string)))

(bench       "read/list"          '(1 2 3)
  (read (open-input-string "(1 2 3)")))
(bench       "read/num"           42
  (read (open-input-string "42")))
(bench       "read/str"           "hello"
  (read (open-input-string "\"hello\"")))
(bench-true  "read/eof"
  (eof-object? (read (open-input-string ""))))

(bench       "read-char"          #\h
  (read-char (open-input-string "hello")))
(bench       "peek-char"          #\h
  (let ((p (open-input-string "hello")))
    (peek-char p)
    (read-char p)))
(bench-true  "eof-object?"
  (eof-object? (read-char (open-input-string ""))))

(bench       "write/num"          "42"
  (let ((p (open-output-string)))
    (write 42 p)
    (get-output-string p)))
(bench       "write/str"          "\"hi\""
  (let ((p (open-output-string)))
    (write "hi" p)
    (get-output-string p)))
(bench       "display/str"        "hi"
  (let ((p (open-output-string)))
    (display "hi" p)
    (get-output-string p)))
(bench       "write-char"         "A"
  (let ((p (open-output-string)))
    (write-char #\A p)
    (get-output-string p)))
(bench       "write-string"       "xyz"
  (let ((p (open-output-string)))
    (write-string "xyz" p)
    (get-output-string p)))
(bench       "write-string/sub"   "bc"
  (let ((p (open-output-string)))
    (write-string "abcde" p 1 3)
    (get-output-string p)))
(bench       "newline/port"       "\n"
  (let ((p (open-output-string)))
    (newline p)
    (get-output-string p)))

(bench       "read-u8"            10
  (read-u8 (open-input-bytevector (bytevector 10 20 30))))
(bench       "peek-u8"            20
  (let ((p (open-input-bytevector (bytevector 10 20 30))))
    (read-u8 p)
    (peek-u8 p)))
(bench-true  "u8-ready?"
  (u8-ready? (open-input-bytevector (bytevector 1 2))))
(bench-true  "read-u8/eof"
  (eof-object? (let ((p (open-input-bytevector (bytevector)))) (read-u8 p))))

(bench       "get-output-bytevector" (bytevector 42 99)
  (let ((p (open-output-bytevector)))
    (write-u8 42 p)
    (write-u8 99 p)
    (get-output-bytevector p)))

(bench       "call-with-port/read"  '(1 2)
  (call-with-port (open-input-string "(1 2)") read))
(bench       "call-with-port/write" "42"
  (call-with-port (open-output-string) (lambda (p) (write 42 p) (get-output-string p))))

(bench-error "read-char/closed"
  (lambda ()
    (let ((p (open-input-string "")))
      (close-input-port p)
      (read-char p))))

;;; ---------------------------------------------------------------------------
;;; Tail recursion                                           (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(define (bench-countdown n) (if (= n 0) 'done (bench-countdown (- n 1))))
(bench       "tail/countdown"     'done  (bench-countdown 100000))

(define (bench-even? n) (if (= n 0) #t (bench-odd?  (- n 1))))
(define (bench-odd?  n) (if (= n 0) #f (bench-even? (- n 1))))
(bench-true  "tail/mutual-even"   (bench-even? 10000))
(bench-false "tail/mutual-odd"    (bench-odd?  10000))

(bench       "tail/named-let"     100000
  (let loop ((n 100000) (acc 0))
    (if (= n 0) acc (loop (- n 1) (+ acc 1)))))

;;; ---------------------------------------------------------------------------
;;; Closures and higher-order                                (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(bench       "closure/adder"      7
  (let ((make-adder (lambda (x) (lambda (y) (+ x y)))))
    ((make-adder 3) 4)))

(bench       "closure/counter"    '(1 2 3)
  (let* ((n 0)
         (bump! (lambda () (set! n (+ n 1)) n)))
    (list (bump!) (bump!) (bump!))))

(bench       "closure/accumulator" 15
  (let ((sum 0))
    (let ((add! (lambda (x) (set! sum (+ sum x)))))
      (for-each add! '(1 2 3 4 5)))
    sum))

;;; ---------------------------------------------------------------------------
;;; Syntax-rules macros                                      (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(define-syntax bench-my-and
  (syntax-rules ()
    ((_) #t)
    ((_ e) e)
    ((_ e1 e2 ...) (if e1 (bench-my-and e2 ...) #f))))

(bench-true  "syntax-rules/and/empty"   (bench-my-and))
(bench       "syntax-rules/and/all"     3    (bench-my-and 1 2 3))
(bench-false "syntax-rules/and/short"   (bench-my-and 1 #f 3))

(define-syntax bench-my-or
  (syntax-rules ()
    ((_) #f)
    ((_ e) e)
    ((_ e1 e2 ...) (let ((t e1)) (if t t (bench-my-or e2 ...))))))

(bench-false "syntax-rules/or/empty"    (bench-my-or))
(bench       "syntax-rules/or/skip"     3    (bench-my-or #f #f 3))
(bench-false "syntax-rules/or/all-f"    (bench-my-or #f #f #f))

(define-syntax bench-swap!
  (syntax-rules ()
    ((_ a b) (let ((tmp a)) (set! a b) (set! b tmp)))))

(bench       "syntax-rules/swap!"  '(2 1)
  (let ((x 1) (y 2))
    (bench-swap! x y)
    (list x y)))

(define-syntax bench-my-let
  (syntax-rules ()
    ((_ ((v e) ...) body ...)
     ((lambda (v ...) body ...) e ...))))

(bench       "syntax-rules/let"   3   (bench-my-let ((x 1) (y 2)) (+ x y)))

;;; Ellipsis with literal
(define-syntax bench-my-list-of
  (syntax-rules ()
    ((_ x ...) (list x ...))))

(bench       "syntax-rules/ellipsis" '(1 2 3) (bench-my-list-of 1 2 3))
(bench       "syntax-rules/ellipsis/0" '()    (bench-my-list-of))

;;; ---------------------------------------------------------------------------
;;; LambLisp extension: nlambda                              (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(when *bench-lamblisp-only*
  ;;; eval defers compilation so Chez doesn't choke on nlambda/macro?/dict syntax
  (eval
    '(begin
       ;;; nlambda receives unevaluated args as a list
       (define bench-my-quote2 (nlambda args (car args)))
       (bench       "nlambda/sym"        'hello  (bench-my-quote2 hello))
       (bench       "nlambda/list"       '(1 2)  (bench-my-quote2 (1 2)))
       (bench       "nlambda/num"        42      (bench-my-quote2 42))

       ;;; nlambda body sees caller's environment
       (define bench-nl-outer 77)
       (define bench-nl-test (nlambda args bench-nl-outer))
       (bench       "nlambda/caller-env" 77      (bench-nl-test))

       ;;; nlambda rest-arg captures all args
       (define bench-getargs (nlambda all all))
       (bench       "nlambda/rest"       '(1 (+ 1 1) foo)  (bench-getargs 1 (+ 1 1) foo)))))

;;; ---------------------------------------------------------------------------
;;; LambLisp extension: macro?                               (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(when *bench-lamblisp-only*
  (eval
    '(begin
       (define bench-my-when3
         (syntax-rules ()
           ((_ test body ...) (if test (begin body ...) 'undef))))
       (bench-true  "macro?/macro"       (macro? bench-my-when3))
       (bench-false "macro?/proc"        (macro? car))
       (bench-false "macro?/lambda"      (macro? (lambda (x) x))))))

;;; ---------------------------------------------------------------------------
;;; LambLisp extension: dict                                 (lamblisp-tests)
;;; ---------------------------------------------------------------------------

(when *bench-lamblisp-only*
  (eval
    '(begin
       (let ((d (dict-add-empty-frame '())))
         (dict-bind! d 'x 10 d)
         (dict-bind! d 'y 20 d)
         (bench       "dict-ref/x"       10    (dict-ref d 'x))
         (bench       "dict-ref/y"       20    (dict-ref d 'y))
         (bench       "dict-ref?/hit"    10    (cdr (dict-ref? d 'x)))
         (bench-true  "dict-ref?/miss"   (eq? #f (dict-ref? d 'z)))
         (dict-rebind! d 'x 42 d)
         (bench       "dict-rebind!/x"   42    (dict-ref d 'x))
         (let ((ks (dict-keys d)))
           (bench-true "dict-keys/x"     (memq 'x ks))
           (bench-true "dict-keys/y"     (memq 'y ks))))
       (let ((d1 (dict-add-empty-frame '())))
         (dict-bind! d1 'base 99 d1)
         (let ((d2 (dict-add-alist-frame '() '((a . 1) (b . 2)) d1)))
           (bench       "dict-alist/a"   1     (dict-ref d2 'a))
           (bench       "dict-alist/b"   2     (dict-ref d2 'b))
           (bench       "dict-inherit"   99    (dict-ref d2 'base)))))))

;;; ---------------------------------------------------------------------------
;;; Auto-run
;;; ---------------------------------------------------------------------------

(bench-run)

