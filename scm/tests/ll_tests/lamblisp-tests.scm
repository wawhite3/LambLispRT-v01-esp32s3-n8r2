;;; Copyright 2026 by Frobenius Norm LLC 2026-04-08 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; lamblisp-tests.scm -- comprehensive LambLisp test suite
;;; Covers R5RS core, R7RS-small subset, and LambLisp extensions.
;;; Load with: (load "lamblisp-tests.scm" 1)
;;; Pass = green (news), Fail = yellow (warn), summary at end.

;;; -----------------------------------------------------------------------
;;; Test framework
;;; -----------------------------------------------------------------------

;;; news/warn: green/yellow output using ANSI codes -- defined here so the
;;; test file is self-contained on Linux (Terminal.scm not loaded).
;;; On ESP32 these will be redefined by Terminal.scm; that's fine.
;;; Use (integer->char #x1b) for ESC -- reader does not support \x1b; hex escapes in strings.
(define ll-esc (string (integer->char #x1b)))
(define (news fmt . args) (apply syslog (string-append ll-esc "[32m" fmt ll-esc "[97m") args))
(define (warn fmt . args) (apply syslog (string-append ll-esc "[33m" fmt ll-esc "[97m") args))

(define *pass* 0)
(define *fail* 0)

(define (check name expected actual)
  (if (equal? expected actual)
    (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1)) (warn "FAIL ~a  expected=~a  got=~a\n" name expected actual))))

(define (check-true name actual)
  (if actual
    (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1)) (warn "FAIL ~a  expected=#t  got=~a\n" name actual))))

(define (check-false name actual)
  (if (not actual)
    (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1)) (warn "FAIL ~a  expected=#f  got=~a\n" name actual))))

(define (check-error name thunk15)
  (let ((result
    (with-exception-handler
      (lambda (e) 'caught)
      (lambda () (thunk15) 'no-error))))
    (if (eq? result 'caught)
      (begin (set! *pass* (+ *pass* 1)) (news "PASS ~a\n" name))
      (begin (set! *fail* (+ *fail* 1)) (warn "FAIL ~a  expected error, got none\n" name)))))

;;; -----------------------------------------------------------------------
;;; 6.1  Equivalence predicates
;;; -----------------------------------------------------------------------

(news "\n--- 6.1 eq? ---\n")
(check-true  "eq?/symbols"        (eq? 'foo 'foo))
(check-false "eq?/diff-symbols"   (eq? 'foo 'bar))
(check-true  "eq?/#t"             (eq? #t #t))
(check-true  "eq?/#f"             (eq? #f #f))
(check-false "eq?/#t-#f"          (eq? #t #f))
(check-true  "eq?/nil"            (eq? '() '()))
(check-true  "eq?/same-pair"      (let ((x '(1 2))) (eq? x x)))
(check-false "eq?/diff-pairs"     (eq? '(1 2) '(1 2)))
(check-true  "eq?/char"           (eq? #\a #\a))

(news "--- 6.1 eqv? ---\n")
(check-true  "eqv?/symbols"       (eqv? 'foo 'foo))
(check-true  "eqv?/integers"      (eqv? 42 42))
(check-true  "eqv?/#t"            (eqv? #t #t))
(check-true  "eqv?/#f"            (eqv? #f #f))
(check-true  "eqv?/chars"         (eqv? #\a #\a))
(check-true  "eqv?/nil"           (eqv? '() '()))
(check-false "eqv?/diff-ints"     (eqv? 1 2))
(check-false "eqv?/int-float"     (eqv? 1 1.0))

(news "--- 6.1 equal? ---\n")
(check-true  "equal?/atoms"       (equal? 42 42))
(check-true  "equal?/strings"     (equal? "hello" "hello"))
(check-true  "equal?/lists"       (equal? '(1 2 3) '(1 2 3)))
(check-true  "equal?/nested"      (equal? '(1 (2 3) 4) '(1 (2 3) 4)))
(check-true  "equal?/vectors"     (equal? '#(1 2 3) '#(1 2 3)))
(check-false "equal?/diff"        (equal? '(1 2) '(1 3)))
(check-true  "equal?/nil"         (equal? '() '()))
(check-true  "equal?/#f"          (equal? #f #f))
(check-true  "equal?/#t"          (equal? #t #t))
(check-true  "equal?/bytevec"     (equal? (bytevector 1 2) (bytevector 1 2)))

;;; -----------------------------------------------------------------------
;;; 6.2  Numbers -- type predicates
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 number type predicates ---\n")
(check-true  "number?/int"        (number? 42))
(check-true  "number?/real"       (number? 3.14))
(check-false "number?/sym"        (number? 'x))
(check-false "number?/str"        (number? "3"))
(check-true  "complex?/int"       (complex? 5))   ;;; R7RS: all numbers are complex
(check-true  "real?/int"          (real? 5))
(check-true  "real?/float"        (real? 1.5))
(check-true  "rational?/int"      (rational? 5))
(check-true  "rational?/float"    (rational? 1.5))   ;;; finite inexact reals are rational (R7RS)
(check-true  "rational?/rat"      (rational? 1/3))
(check-false "rational?/inf"      (rational? +inf.0))
(check-true  "number?/rat"        (number?   1/3))
(check-true  "real?/rat"          (real?     1/3))
(check-false "integer?/rat"       (integer?  1/3))
(check-true  "exact?/rat"         (exact?    1/3))
(check-false "inexact?/rat"       (inexact?  1/3))
(check-true  "integer?/int"       (integer? 5))
(check-false "integer?/float"     (integer? 3.14))
(check-true  "exact-integer?/int" (exact-integer? 5))
(check-false "exact-integer?/flt" (exact-integer? 5.0))
(check-true  "exact?/int"         (exact? 5))
(check-false "exact?/float"       (exact? 1.5))
(check-true  "inexact?/float"     (inexact? 1.5))
(check-false "inexact?/int"       (inexact? 5))
(check-true  "zero?/0"            (zero? 0))
(check-false "zero?/1"            (zero? 1))
(check-true  "positive?/1"        (positive? 1))
(check-false "positive?/0"        (positive? 0))
(check-false "positive?/-1"       (positive? -1))
(check-true  "negative?/-1"       (negative? -1))
(check-false "negative?/0"        (negative? 0))
(check-true  "odd?/1"             (odd? 1))
(check-false "odd?/2"             (odd? 2))
(check-true  "odd?/-3"            (odd? -3))
(check-true  "even?/2"            (even? 2))
(check-false "even?/3"            (even? 3))
(check-true  "even?/0"            (even? 0))

;;; -----------------------------------------------------------------------
;;; 6.2  Numbers -- arithmetic
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 arithmetic ---\n")
(check "+/0-args"       0    (+))
(check "+/2"            10   (+ 3 7))
(check "+/multi"        15   (+ 1 2 3 4 5))
(check "-/negate"       -3   (- 3))
(check "-/2"            5    (- 10 5))
(check "-/multi"        4    (- 10 3 2 1))
(check "*/1-arg"        1    (*))
(check "*/2"            12   (* 3 4))
(check "*/multi"        120  (* 1 2 3 4 5))
(check "//2"            4    (/ 12 3))
(check "quotient/pos"   3    (quotient 10 3))
(check "quotient/neg"   -3   (quotient -10 3))
(check "remainder/pos"  1    (remainder 10 3))
(check "remainder/neg"  -1   (remainder -10 3))
(check "modulo/pos"     1    (modulo 10 3))
(check "modulo/neg"     2    (modulo -10 3))
(check "gcd/2"          4    (gcd 12 8))
(check "gcd/0"          5    (gcd 5 0))
(check "gcd/0-args"     0    (gcd))
(check "lcm/2"          12   (lcm 4 6))
(check "lcm/0-args"     1    (lcm))   ;;; R7RS: (lcm) = 1, the LCM identity element
(check "abs/pos"        5    (abs 5))
(check "abs/neg"        5    (abs -5))
(check "max/ints"       5    (max 1 3 5 2))
(check "min/ints"       1    (min 3 1 5 2))
(check "expt/int"       8    (expt 2 3))
(check "expt/0"         1    (expt 5 0))

(news "--- 6.2 floor / ceiling / truncate / round ---\n")
(check "floor/pos"      3.0  (floor 3.7))
(check "floor/neg"      -4.0 (floor -3.7))
(check "ceiling/pos"    4.0  (ceiling 3.2))
(check "ceiling/neg"    -3.0 (ceiling -3.7))
(check "truncate/pos"   3.0  (truncate 3.7))
(check "truncate/neg"   -3.0 (truncate -3.7))
(check "round/up"       4.0  (round 3.6))
(check "round/down"     3.0  (round 3.4))
(check "round/half-even-4" 4.0 (round 3.5))   ;;; banker's rounding
(check "round/half-even-6" 6.0 (round 5.5))

(news "--- 6.2 real math ---\n")
(check-true  "sqrt/4"         (= 2.0 (sqrt 4)))
(check-true  "sqrt/2-approx"  (< (abs (- (sqrt 2) 1.41421356)) 1e-6))
(check-true  "exp/0"          (= 1.0 (exp 0)))
(check-true  "exp/1-approx"   (< (abs (- (exp 1) 2.71828182)) 1e-6))
(check-true  "log/1"          (= 0.0 (log 1)))
(check-true  "log/e-approx"   (< (abs (- (log (exp 1)) 1.0)) 1e-5))
(check-true  "sin/0"          (= 0.0 (sin 0)))
(check-true  "cos/0"          (= 1.0 (cos 0)))
(check-true  "sin-cos-identity" (< (abs (- (+ (* (sin 0.5) (sin 0.5)) (* (cos 0.5) (cos 0.5))) 1.0)) 1e-5))

(news "--- 6.2 exact<->inexact ---\n")
(check "exact->inexact"  1.0  (exact->inexact 1))
(check "inexact->exact"  1    (inexact->exact 1.0))
(check-true  "inexact/3.5" (inexact? (exact->inexact 3)))
(check-true  "exact/back"  (exact? (inexact->exact 3.0)))

(news "--- 6.2 comparisons ---\n")
(check-true  "=/2"            (= 3 3))
(check-false "=/diff"         (= 3 4))
(check-true  "</2"            (< 1 2))
(check-false "</eq"           (< 2 2))
(check-true  ">/2"            (> 2 1))
(check-true  "<=/eq"          (<= 2 2))
(check-true  "<=/lt"          (<= 1 2))
(check-true  ">=/eq"          (>= 2 2))
(check-true  ">=/gt"          (>= 3 2))
(check-true  "</chain"        (< 1 2 3 4))
(check-false "</chain-false"  (< 1 2 2 3))
(check-true  "=/chain"        (= 3 3 3))

(news "--- 6.2 floor-quotient / truncate-quotient ---\n")
(check "floor-quotient/pos"    3    (floor-quotient 13 4))
(check "floor-quotient/neg"    -4   (floor-quotient -13 4))
(check "floor-remainder/pos"   1    (floor-remainder 13 4))
(check "floor-remainder/neg"   3    (floor-remainder -13 4))
(check "truncate-quotient/pos" 3    (truncate-quotient 13 4))
(check "truncate-quotient/neg" -3   (truncate-quotient -13 4))
(check "truncate-remainder/pos" 1   (truncate-remainder 13 4))
(check "truncate-remainder/neg" -1  (truncate-remainder -13 4))

(news "--- 6.2 exact-integer-sqrt ---\n")
(check "exact-integer-sqrt/9"  '(3 0)
  (call-with-values (lambda () (exact-integer-sqrt 9)) list))
(check "exact-integer-sqrt/10" '(3 1)
  (call-with-values (lambda () (exact-integer-sqrt 10)) list))
(check "exact-integer-sqrt/0"  '(0 0)
  (call-with-values (lambda () (exact-integer-sqrt 0)) list))

(news "--- 6.2 number<->string ---\n")
(check "number->string/10"     "42"     (number->string 42))
(check "number->string/16"     "2a"     (number->string 42 16))
(check "number->string/2"      "101010" (number->string 42 2))
(check "number->string/8"      "52"     (number->string 42 8))
(check "string->number/10"     42       (string->number "42"))
(check "string->number/16"     255      (string->number "ff" 16))
(check "string->number/2"      10       (string->number "1010" 2))
(check "string->number/float"  3.14     (string->number "3.14"))
(check "string->number/bad"    #f       (string->number "xyz"))
(check "string->number/empty"  #f       (string->number ""))

;;; -----------------------------------------------------------------------
;;; 6.2  Rational numbers
;;; -----------------------------------------------------------------------

(news "\n--- 6.2 rational numbers ---\n")

;;; Reader literals
(check "rat/half"              1/2    1/2)
(check "rat/neg"              -3/4   -3/4)
(check "rat/reduce"            3/2    6/4)
(check "rat/to-int"            2      4/2)

;;; numerator / denominator
(check "rat/numerator"         1      (numerator   1/3))
(check "rat/denominator"       3      (denominator 1/3))
(check "rat/numerator/int"     5      (numerator   5))
(check "rat/denominator/int"   1      (denominator 5))

;;; Arithmetic
(check "rat/add"               5/6    (+ 1/2 1/3))
(check "rat/sub"               1/6    (- 1/2 1/3))
(check "rat/mul"               1/6    (* 1/2 1/3))
(check "rat/div"               3/2    (/ 1/2 1/3))
(check "rat/negate"           -1/3    (- 1/3))
(check "rat/recip"             3      (/ 1/3))
(check "rat/add-int"           5/3    (+ 2/3 1))
(check-true "rat/add-inexact"  (inexact? (+ 1/2 0.5)))

;;; Comparisons
(check-true  "rat/eq"          (= 1/2 2/4))
(check-true  "rat/lt"          (< 1/3 1/2))
(check-true  "rat/le"          (<= 1/3 1/3))
(check-true  "rat/gt"          (> 1/2 1/3))
(check-true  "rat/chain"       (< 1/4 1/3 1/2))

;;; abs
(check "rat/abs/pos"           1/3    (abs  1/3))
(check "rat/abs/neg"           1/3    (abs -1/3))

;;; floor / ceiling / truncate / round
(check "rat/floor/pos"         1      (floor    7/4))
(check "rat/floor/neg"        -2      (floor   -7/4))
(check "rat/ceiling/pos"       2      (ceiling  7/4))
(check "rat/ceiling/neg"      -1      (ceiling -7/4))
(check "rat/truncate/pos"      1      (truncate 7/4))
(check "rat/truncate/neg"     -1      (truncate -7/4))
(check "rat/round/half-even"   2      (round    5/2))  ;;; banker's rounding

;;; exact->inexact / inexact->exact
(check-true "rat/e2i"          (inexact? (exact->inexact 1/3)))
(check      "rat/i2e"          1/2    (inexact->exact 0.5))

;;; expt
(check "rat/expt/pos"          1/8    (expt 1/2 3))
(check "rat/expt/neg"          8      (expt 1/2 -3))

;;; number->string
(check "rat/n2s"               "1/3"  (number->string 1/3))

;;; -----------------------------------------------------------------------
;;; 6.3  Booleans
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 booleans ---\n")
(check-true  "boolean?/#t"        (boolean? #t))
(check-true  "boolean?/#f"        (boolean? #f))
(check-false "boolean?/num"       (boolean? 0))
(check-false "boolean?/nil"       (boolean? '()))
(check-true  "not/#f"             (not #f))
(check-false "not/#t"             (not #t))
(check-false "not/0"              (not 0))
(check-false "not/nil"            (not '()))
(check-true  "boolean=?/tt"       (boolean=? #t #t))
(check-true  "boolean=?/ff"       (boolean=? #f #f))
(check-false "boolean=?/tf"       (boolean=? #t #f))
(check-true  "boolean=?/multi"    (boolean=? #t #t #t))

;;; -----------------------------------------------------------------------
;;; 6.3  Pairs and lists
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 pairs and lists ---\n")
(check-true  "pair?/cons"         (pair? (cons 1 2)))
(check-true  "pair?/list"         (pair? '(1 2)))
(check-false "pair?/nil"          (pair? '()))
(check-false "pair?/atom"         (pair? 42))
(check-true  "null?/nil"          (null? '()))
(check-false "null?/pair"         (null? '(1)))
(check-true  "list?/proper"       (list? '(1 2 3)))
(check-true  "list?/nil"          (list? '()))
(check-false "list?/dotted"       (list? '(1 . 2)))
(check "cons/pair"    '(1 . 2)    (cons 1 2))
(check "cons/list"    '(1 2)      (cons 1 '(2)))
(check "car"          1           (car '(1 2 3)))
(check "cdr"          '(2 3)      (cdr '(1 2 3)))
(check "cadr"         2           (cadr '(1 2 3)))
(check "caddr"        3           (caddr '(1 2 3)))
(check "caar"         1           (caar '((1 2) 3)))
(check "cdar"         '(2)        (cdar '((1 2) 3)))
(check "caaar"        1           (caaar '(((1 2) 3) 4)))
(check "caadr"        3           (caadr '(1 (3 4) 5)))
(check "cadar"        2           (cadar '((1 2) 3)))
(check "cdaar"        '(2)        (cdaar '(((1 2) 3) 4)))
(check "cdadr"        '(4)        (cdadr '(1 (3 4) 5)))
(check "cddar"        '(3)        (cddar '((1 2 3) 4)))
(check "cdddr"        '(4)        (cdddr '(1 2 3 4)))
(check "cadddr"       4           (cadddr '(1 2 3 4 5)))

(check "list"         '(1 2 3)    (list 1 2 3))
(check "list/empty"   '()         (list))
(check "make-list/0"  '()         (make-list 0 #f))
(check "make-list/3"  '(0 0 0)    (make-list 3 0))
(check "length"       3           (length '(1 2 3)))
(check "length/nil"   0           (length '()))
(check "append/2"     '(1 2 3 4)  (append '(1 2) '(3 4)))
(check "append/nil"   '(1 2)      (append '() '(1 2)))
(check "append/3"     '(1 2 3 4 5) (append '(1 2) '(3 4) '(5)))
(check "append/right" '(1 . 2)    (append '() '(1 . 2)))
(check "reverse"      '(3 2 1)    (reverse '(1 2 3)))
(check "reverse/nil"  '()         (reverse '()))
(check "list-tail"    '(3 4)      (list-tail '(1 2 3 4) 2))
(check "list-ref"     3           (list-ref '(1 2 3 4) 2))

(news "--- list mutation ---\n")
(check "set-car!"     '(99 2 3)   (let ((x (list 1 2 3))) (set-car! x 99) x))
(check "set-cdr!"     '(1 99)     (let ((x (list 1 2 3))) (set-cdr! x '(99)) x))
(check "list-set!"    '(1 99 3)   (let ((x (list 1 2 3))) (list-set! x 1 99) x))

(news "--- list search ---\n")
(check "memq/found"   '(2 3)      (memq 2 '(1 2 3)))
(check "memq/miss"    #f          (memq 5 '(1 2 3)))
(check "memv/found"   '(2 3)      (memv 2 '(1 2 3)))
(check "memv/miss"    #f          (memv 5 '(1 2 3)))
(check "member/found" '(2 3)      (member 2 '(1 2 3)))
(check "member/miss"  #f          (member 5 '(1 2 3)))
(check "assq/found"   '(b 2)      (assq 'b '((a 1) (b 2) (c 3))))
(check "assq/miss"    #f          (assq 'd '((a 1) (b 2))))
(check "assv/found"   '(2 x)      (assv 2 '((1 a) (2 x) (3 b))))
(check "assv/miss"    #f          (assv 5 '((1 a) (2 x))))
(check "assoc/found"  '("b" 2)    (assoc "b" '(("a" 1) ("b" 2))))
(check "assoc/miss"   #f          (assoc "z" '(("a" 1) ("b" 2))))

;;; -----------------------------------------------------------------------
;;; 6.3  Symbols
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 symbols ---\n")
(check-true  "symbol?/sym"        (symbol? 'foo))
(check-false "symbol?/str"        (symbol? "foo"))
(check-false "symbol?/num"        (symbol? 42))
(check "symbol->string"   "foo"   (symbol->string 'foo))
(check "string->symbol"   'foo    (string->symbol "foo"))
(check-true  "symbol=?/eq"        (symbol=? 'foo 'foo))
(check-false "symbol=?/diff"      (symbol=? 'foo 'bar))
(check-true  "symbol=?/multi"     (symbol=? 'x 'x 'x))

;;; -----------------------------------------------------------------------
;;; 6.3  Characters
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 characters ---\n")
(check-true  "char?/#\\a"         (char? #\a))
(check-false "char?/str"          (char? "a"))
(check-true  "char=?/eq"          (char=? #\a #\a))
(check-false "char=?/diff"        (char=? #\a #\b))
(check-true  "char<?/lt"          (char<? #\a #\b))
(check-false "char<?/eq"          (char<? #\a #\a))
(check-true  "char>?/gt"          (char>? #\b #\a))
(check-true  "char<=?/eq"         (char<=? #\a #\a))
(check-true  "char<=?/lt"         (char<=? #\a #\b))
(check-true  "char>=?/eq"         (char>=? #\a #\a))
(check-true  "char>=?/gt"         (char>=? #\b #\a))
(check-true  "char-alphabetic?/a" (char-alphabetic? #\a))
(check-false "char-alphabetic?/5" (char-alphabetic? #\5))
(check-true  "char-numeric?/5"    (char-numeric? #\5))
(check-false "char-numeric?/a"    (char-numeric? #\a))
(check-true  "char-whitespace?/sp" (char-whitespace? #\space))
(check-true  "char-whitespace?/nl" (char-whitespace? #\newline))
(check-true  "char-upper-case?/A" (char-upper-case? #\A))
(check-false "char-upper-case?/a" (char-upper-case? #\a))
(check-true  "char-lower-case?/a" (char-lower-case? #\a))
(check-false "char-lower-case?/A" (char-lower-case? #\A))
(check "char->integer/a"  97      (char->integer #\a))
(check "char->integer/A"  65      (char->integer #\A))
(check "char->integer/0"  48      (char->integer #\0))
(check "char->integer/λ"  955     (char->integer #\λ))  ;; B12 fix: UTF-8 multi-byte literal
(check "integer->char/97" #\a     (integer->char 97))
(check "char-upcase"      #\A     (char-upcase #\a))
(check "char-downcase"    #\a     (char-downcase #\A))
(check "digit-value/5"    5       (digit-value #\5))
(check "digit-value/0"    0       (digit-value #\0))
(check "digit-value/9"    9       (digit-value #\9))

(news "--- char-ci ---\n")
(check-true  "char-ci=?/aA"       (char-ci=? #\a #\A))
(check-true  "char-ci<?/aB"       (char-ci<? #\a #\B))
(check-true  "char-ci>?/Ba"       (char-ci>? #\B #\a))
(check-true  "char-ci<=?/Aa"      (char-ci<=? #\A #\a))
(check-true  "char-ci>=?/aA"      (char-ci>=? #\a #\A))

;;; -----------------------------------------------------------------------
;;; 6.3  Strings
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 strings ---\n")
(check-true  "string?/str"        (string? "hello"))
(check-false "string?/sym"        (string? 'hello))
(check-false "string?/num"        (string? 42))
(check "string"         "abc"     (string #\a #\b #\c))
(check "make-string/3"  "aaa"     (make-string 3 #\a))
(check "make-string/0"  ""        (make-string 0 #\x))
(check "string-length"  5         (string-length "hello"))
(check "string-length/empty" 0    (string-length ""))
(check "string-ref"     #\e       (string-ref "hello" 1))
(check "substring"      "ell"     (substring "hello" 1 4))
(check "substring/full" "hello"   (substring "hello" 0 5))
(check "string-append/2" "hello world" (string-append "hello" " " "world"))
(check "string-append/0" ""       (string-append))
(check "string->list"   '(#\h #\i) (string->list "hi"))
(check "list->string"   "hi"      (list->string '(#\h #\i)))
(check "string-copy"    "abc"     (string-copy "abc"))
(check "string-copy/sub" "bc"     (string-copy "abcd" 1 3))
(check-true  "string=?/eq"        (string=? "abc" "abc"))
(check-false "string=?/diff"      (string=? "abc" "abd"))
(check-true  "string<?/lt"        (string<? "abc" "abd"))
(check-false "string<?/eq"        (string<? "abc" "abc"))
(check-true  "string>?/gt"        (string>? "abd" "abc"))
(check-true  "string<=?/eq"       (string<=? "abc" "abc"))
(check-true  "string>=?/eq"       (string>=? "abc" "abc"))
(check "string-upcase"   "HELLO"  (string-upcase "hello"))
(check "string-downcase" "hello"  (string-downcase "HELLO"))

(news "--- string mutation ---\n")
(check "string-set!"    "hXllo"
  (let ((s (string-copy "hello"))) (string-set! s 1 #\X) s))
(check "string-fill!"   "xxx"
  (let ((s (make-string 3 #\a))) (string-fill! s #\x) s))
(check "string-copy!"   "hXYlo"
  (let ((s (string-copy "hello")))
    (string-copy! s 1 "XYZ" 0 2)
    s))

(news "--- string-ci ---\n")
(check-true  "string-ci=?"        (string-ci=? "Hello" "hello"))
(check-true  "string-ci<?"        (string-ci<? "abc" "ABD"))
(check-true  "string-ci>?"        (string-ci>? "ABD" "abc"))
(check-true  "string-ci<=?"       (string-ci<=? "ABC" "abc"))
(check-true  "string-ci>=?"       (string-ci>=? "abc" "ABC"))

;;; -----------------------------------------------------------------------
;;; 6.3  Vectors
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 vectors ---\n")
(check-true  "vector?/vec"        (vector? '#(1 2 3)))
(check-false "vector?/list"       (vector? '(1 2 3)))
(check "vector"         '#(1 2 3) (vector 1 2 3))
(check "make-vector/3"  '#(0 0 0) (make-vector 3 0))
(check "make-vector/0"  '#()      (make-vector 0 0))
(check "vector-length"  3         (vector-length '#(1 2 3)))
(check "vector-ref"     2         (vector-ref '#(1 2 3) 1))
(check "vector->list"   '(1 2 3)  (vector->list '#(1 2 3)))
(check "vector->list/sub" '(2 3)  (vector->list '#(1 2 3) 1))
(check "list->vector"   '#(1 2 3) (list->vector '(1 2 3)))
(check "vector->string" "abc"     (vector->string '#(#\a #\b #\c)))
(check "string->vector" '#(#\a #\b #\c) (string->vector "abc"))
(check "vector-copy"    '#(2 3)   (vector-copy '#(1 2 3) 1 3))
(check "vector-copy/all" '#(1 2)  (vector-copy '#(1 2) 0))
(check "vector-append"  '#(1 2 3 4) (vector-append '#(1 2) '#(3 4)))

(news "--- vector mutation ---\n")
(check "vector-set!"    '#(1 99 3)
  (let ((v (vector 1 2 3))) (vector-set! v 1 99) v))
(check "vector-fill!"   '#(7 7 7)
  (let ((v (vector 1 2 3))) (vector-fill! v 7) v))
(check "vector-copy!"   '#(1 9 8 4)
  (let ((v (vector 1 2 3 4))) (vector-copy! v 1 '#(9 8) 0 2) v))

;;; -----------------------------------------------------------------------
;;; 6.3  Bytevectors
;;; -----------------------------------------------------------------------

(news "\n--- 6.3 bytevectors ---\n")
(check-true  "bytevector?"        (bytevector? (bytevector 1 2 3)))
(check-false "bytevector?/vec"    (bytevector? '#(1 2 3)))
(check-false "bytevector?/str"    (bytevector? "abc"))
(check "bytevector-length" 3      (bytevector-length (bytevector 1 2 3)))
(check "bytevector-u8-ref" 2      (bytevector-u8-ref (bytevector 1 2 3) 1))
(check "make-bytevector"   (bytevector 0 0 0) (make-bytevector 3 0))
(check "bytevector-copy"   (bytevector 2 3)   (bytevector-copy (bytevector 1 2 3) 1 3))
(check "bytevector-append" (bytevector 1 2 3 4) (bytevector-append (bytevector 1 2) (bytevector 3 4)))
(check "bytevector-u8-set!" (bytevector 1 99 3)
  (let ((b (bytevector 1 2 3))) (bytevector-u8-set! b 1 99) b))

(news "--- utf8 conversion ---\n")
(check "string->utf8"     (bytevector 104 105) (string->utf8 "hi"))
(check "utf8->string"     "hi"                 (utf8->string (bytevector 104 105)))
(check "string->utf8/sub" (bytevector 105)     (string->utf8 "hi" 1))

;;; -----------------------------------------------------------------------
;;; 4.1  Core syntax
;;; -----------------------------------------------------------------------

(news "\n--- 4.1 quote / if / begin / set! ---\n")
(check "quote/sym"        'foo     'foo)
(check "quote/list"       '(1 2)   '(1 2))
(check "quote/nested"     '(a (b c)) '(a (b c)))
(check "if/true"          1        (if #t 1 2))
(check "if/false"         2        (if #f 1 2))
(check "if/no-else"       'ok      (if #t 'ok))
(check "if/0-truthy"      'yes     (if 0 'yes 'no))
(check "if/nil-truthy"    'yes     (if '() 'yes 'no))
(check "begin"            3        (begin 1 2 3))
(check "begin/single"     42       (begin 42))
(check "set!"             10       (let ((x 5)) (set! x 10) x))

;;; -----------------------------------------------------------------------
;;; 4.2  Derived expressions
;;; -----------------------------------------------------------------------

(news "\n--- 4.2 cond ---\n")
(check "cond/first"       1   (cond (#t 1) (else 2)))
(check "cond/second"      2   (cond (#f 1) (#t 2) (else 3)))
(check "cond/else"        3   (cond (#f 1) (#f 2) (else 3)))
(check "cond/=>"          4   (cond (2 => (lambda (x) (* x 2)))))
(check "cond/multi-body"  3   (cond (#t 1 2 3)))

(news "--- 4.2 case ---\n")
(check "case/match"       'b   (case 2 ((1) 'a) ((2) 'b) (else 'c)))
(check "case/else"        'c   (case 5 ((1) 'a) ((2) 'b) (else 'c)))
(check "case/multi-datum" 'ab  (case 2 ((1 3) 'odd) ((2 4) 'ab) (else 'c)))

(news "--- 4.2 and / or ---\n")
(check "and/all-true"     3    (and 1 2 3))
(check "and/false"        #f   (and 1 #f 3))
(check "and/empty"        #t   (and))
(check "and/single"       5    (and 5))
(check "or/first-true"    1    (or 1 2 3))
(check "or/skip-false"    2    (or #f 2 3))
(check "or/all-false"     #f   (or #f #f))
(check "or/empty"         #f   (or))
(check "or/single"        5    (or 5))

(news "--- 4.2 when / unless ---\n")
(check "when/true"        3    (when #t 1 2 3))
(check "when/false"       'ok  (begin (when #f (error "bad")) 'ok))
(check "unless/false"     3    (unless #f 1 2 3))
(check "unless/true"      'ok  (begin (unless #t (error "bad")) 'ok))

(news "--- 4.2 let / let* / letrec / letrec* ---\n")
(check "let"              3    (let ((x 1) (y 2)) (+ x y)))
(check "let/shadow"       1    (let ((x 1)) (let ((x 2) (y x)) y)))   ;;; inner y sees outer x=1
(check "let*"             3    (let* ((x 1) (y (+ x 2))) y))
(check "letrec/fact"      120  (letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 5)))
(check "letrec/mutual"    #t
  (letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
           (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
    (even? 10)))
(check "letrec*"          4    (letrec* ((x 1) (y (+ x 2)) (z (+ x y))) z))

(news "--- 4.2 named let ---\n")
(check "named-let/sum"    55   (let loop ((i 10) (acc 0))
                                 (if (= i 0) acc (loop (- i 1) (+ acc i)))))
(check "named-let/fact"   120  (let fact ((n 5) (acc 1))
                                 (if (= n 0) acc (fact (- n 1) (* acc n)))))

(news "--- 4.2 do ---\n")
(check "do/sum"           10
  (do ((i 0 (+ i 1)) (sum 0 (+ sum i)))
    ((= i 5) sum)))
(check "do/build-list"    '(4 3 2 1 0)
  (do ((i 0 (+ i 1)) (acc '() (cons i acc)))
    ((= i 5) acc)))
(check "do/vector"        '#(0 1 2 3 4)
  (let ((v (make-vector 5)))
    (do ((i 0 (+ i 1)))
      ((= i 5) v)
      (vector-set! v i i))))

(news "--- 4.2 quasiquote ---\n")
(check "quasiquote/lit"   '(1 2 3)     `(1 2 3))
(check "unquote"          '(1 99 3)    `(1 ,(+ 90 9) 3))
(check "unquote-splicing" '(1 2 3 4 5) `(1 ,@(list 2 3 4) 5))
(check "quasi-nested"     '(1 (2 3) 4) `(1 (,(+ 1 1) 3) 4))
(check "quasi-empty-splice" '(1 2)     `(1 ,@'() 2))
(check "quasi-list-of"    '(a b c)     `(a ,@(cdr '(x b c))))

;;; -----------------------------------------------------------------------
;;; 5.x  Definitions
;;; -----------------------------------------------------------------------

(news "\n--- 5.x define ---\n")
(define test-val 42)
(check "define/var"       42   test-val)
(define (test-add a b) (+ a b))
(check "define/proc"      7    (test-add 3 4))
(define (test-fact n) (if (= n 0) 1 (* n (test-fact (- n 1)))))
(check "define/recursive" 120  (test-fact 5))
(define-values (va vb vc) (values 10 20 30))
(check "define-values/a"  10   va)
(check "define-values/b"  20   vb)
(check "define-values/c"  30   vc)

;;; -----------------------------------------------------------------------
;;; 5.5  define-record-type
;;; -----------------------------------------------------------------------

(news "\n--- define-record-type ---\n")
(define-record-type <point>
  (make-point x y)
  point?
  (x point-x)
  (y point-y))
(define pt (make-point 3 4))
(check-true  "point?"              (point? pt))
(check-false "point?/false"        (point? '(3 4)))
(check-false "point?/num"          (point? 42))
(check "point-x"         3         (point-x pt))
(check "point-y"         4         (point-y pt))

(define-record-type <counter>
  (make-counter n)
  counter?
  (n counter-n counter-set-n!))
(define c (make-counter 0))
(counter-set-n! c 5)
(check "record-mutable"  5         (counter-n c))

;;; -----------------------------------------------------------------------
;;; Lambda -- rest args, closures, mutual recursion
;;; -----------------------------------------------------------------------

(news "\n--- lambda rest args ---\n")
(define (gather . args) args)
(check "rest/all-0"       '()        (gather))
(check "rest/all-3"       '(1 2 3)   (gather 1 2 3))
(define (head-rest a b . rest) (list a b rest))
(check "rest/mixed"       '(1 2 (3 4)) (head-rest 1 2 3 4))
(check "rest/mixed-min"   '(1 2 ())    (head-rest 1 2))

(news "--- closures ---\n")
(define (make-adder n) (lambda (x) (+ x n)))
(define add5  (make-adder 5))
(define add10 (make-adder 10))
(check "closure/add5"     8    (add5 3))
(check "closure/add10"    13   (add10 3))
(check-false "closure/independent" (= (add5 0) (add10 0)))

(define (make-counter2)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define ctr1 (make-counter2))
(define ctr2 (make-counter2))
(check "closure/ctr1-a"   1    (ctr1))
(check "closure/ctr1-b"   2    (ctr1))
(check "closure/ctr2-ind" 1    (ctr2))    ;;; independent from ctr1
(check "closure/ctr1-c"   3    (ctr1))

(define (make-pair-fns)
  (let ((val 0))
    (list (lambda (x) (set! val x))
          (lambda () val))))
(let ((fns (make-pair-fns)))
  (let ((setter (car fns)) (getter (cadr fns)))
    (setter 42)
    (check "closure/shared-state" 42 (getter))))

(news "--- mutual recursion ---\n")
(define (my-even? n) (if (= n 0) #t (my-odd? (- n 1))))
(define (my-odd?  n) (if (= n 0) #f (my-even? (- n 1))))
(check-true  "mutual/even/10"  (my-even? 10))
(check-false "mutual/even/7"   (my-even? 7))
(check-true  "mutual/odd/7"    (my-odd? 7))

;;; -----------------------------------------------------------------------
;;; case-lambda
;;; -----------------------------------------------------------------------

(news "\n--- case-lambda ---\n")
(define flexible
  (case-lambda
    (()      'zero)
    ((x)     (list 'one x))
    ((x y)   (list 'two x y))
    ((x y z) (list 'three x y z))
    (rest    (list 'many (length rest)))))
(check "case-lambda/0"    'zero           (flexible))
(check "case-lambda/1"    '(one 10)       (flexible 10))
(check "case-lambda/2"    '(two 10 20)    (flexible 10 20))
(check "case-lambda/3"    '(three 1 2 3)  (flexible 1 2 3))
(check "case-lambda/many" '(many 5)       (flexible 1 2 3 4 5))

;;; -----------------------------------------------------------------------
;;; Tail calls
;;; -----------------------------------------------------------------------

(news "\n--- tail calls ---\n")
(define (count-down n) (if (= n 0) 'done (count-down (- n 1))))
(check "tail/if"          'done   (count-down 100000))

(define (count-cond n)
  (cond ((= n 0) 'done) (else (count-cond (- n 1)))))
(check "tail/cond"        'done   (count-cond 100000))

(define (count-let n)
  (let ((m (- n 1)))
    (if (= n 0) 'done (count-let m))))
(check "tail/let"         'done   (count-let 100000))

(define (count-begin n)
  (if (= n 0) 'done (begin (count-begin (- n 1)))))
(check "tail/begin"       'done   (count-begin 100000))

(define (sum-tail n acc)
  (if (= n 0) acc (sum-tail (- n 1) (+ acc n))))
(check "tail/accumulate"  5050    (sum-tail 100 0))

;;; -----------------------------------------------------------------------
;;; 6.6  Higher-order procedures
;;; -----------------------------------------------------------------------

(news "\n--- 6.6 apply ---\n")
(check "apply/list"       6     (apply + '(1 2 3)))
(check "apply/mixed"      10    (apply + 1 2 '(3 4)))
(check "apply/0"          0     (apply + '()))
(check "apply/single"     5     (apply (lambda (x) x) '(5)))

(news "--- 6.6 map ---\n")
(check "map/single"       '(2 4 6)    (map (lambda (x) (* x 2)) '(1 2 3)))
(check "map/two-lists"    '(5 7 9)    (map + '(1 2 3) '(4 5 6)))
(check "map/nil"          '()         (map car '()))

(news "--- 6.6 for-each ---\n")
(check "for-each"         '(3 2 1)
  (let ((acc '()))
    (for-each (lambda (x) (set! acc (cons x acc))) '(1 2 3))
    acc))
(check "for-each/two"     '(5 7 9)
  (let ((acc '()))
    (for-each (lambda (a b) (set! acc (cons (+ a b) acc))) '(1 2 3) '(4 5 6))
    (reverse acc)))

(news "--- 6.6 string-map / string-for-each ---\n")
(check "string-map/1"     "ABC"    (string-map char-upcase "abc"))
(check "string-for-each"  '(#\c #\b #\a)
  (let ((acc '()))
    (string-for-each (lambda (c) (set! acc (cons c acc))) "abc")
    acc))

(news "--- 6.6 vector-map / vector-for-each ---\n")
(check "vector-map/1"     '#(2 4 6)  (vector-map (lambda (x) (* x 2)) '#(1 2 3)))
(check "vector-map/2"     '#(5 7 9)  (vector-map + '#(1 2 3) '#(4 5 6)))
(check "vector-for-each"  '(3 2 1)
  (let ((acc '()))
    (vector-for-each (lambda (x) (set! acc (cons x acc))) '#(1 2 3))
    acc))

;;; -----------------------------------------------------------------------
;;; Type predicates
;;; -----------------------------------------------------------------------

(news "\n--- type predicates ---\n")
(check-true  "procedure?/lambda"  (procedure? (lambda (x) x)))
(check-true  "procedure?/builtin" (procedure? car))
(check-true  "procedure?/case"    (procedure? (case-lambda ((x) x))))
(check-false "procedure?/num"     (procedure? 42))
(check-false "procedure?/sym"     (procedure? 'foo))

;;; -----------------------------------------------------------------------
;;; 6.10  Multiple values
;;; -----------------------------------------------------------------------

(news "\n--- 6.10 values / call-with-values ---\n")
(check "values/single"    5   (call-with-values (lambda () 5) (lambda (x) x)))
(check "values/two"       3   (call-with-values (lambda () (values 1 2)) (lambda (a b) (+ a b))))
(check "values/three"     6   (call-with-values (lambda () (values 1 2 3)) (lambda (a b c) (+ a b c))))

(news "--- let-values / let*-values ---\n")
(check "let-values"       7   (let-values (((a b c) (values 1 2 4))) (+ a b c)))
(check "let-values/two"   '(3 7)
  (let-values (((a b) (values 1 2))
               ((c d) (values 3 4)))
    (list (+ a b) (+ c d))))
(check "let*-values"      10
  (let*-values (((a b) (values 1 2))
                ((c)   (+ a b 7)))
    c))

;;; -----------------------------------------------------------------------
;;; 6.11  Exceptions
;;; -----------------------------------------------------------------------

(news "\n--- 6.11 raise / with-exception-handler ---\n")
(check "raise/catch"      'caught
  (with-exception-handler
    (lambda (e) 'caught)
    (lambda () (raise 'oops))))

(check "raise/value"      'oops
  (with-exception-handler
    (lambda (e) e)
    (lambda () (raise 'oops))))

(check "no-raise"         42
  (with-exception-handler
    (lambda (e) 'caught)
    (lambda () 42)))

(check "raise/list"       '(a b)
  (with-exception-handler
    (lambda (e) e)
    (lambda () (raise '(a b)))))

(news "--- 6.11 error / error-object ---\n")
(check "error-object?"    #t
  (with-exception-handler
    (lambda (e) (error-object? e))
    (lambda () (error "test" 1 2 3))))

(check "error-message"    "test"
  (with-exception-handler
    (lambda (e) (error-object-message e))
    (lambda () (error "test" 1 2 3))))

(check "error-irritants"  '(1 2 3)
  (with-exception-handler
    (lambda (e) (error-object-irritants e))
    (lambda () (error "test" 1 2 3))))

(check-false "error-object?/sym"  (error-object? 'foo))
(check-false "error-object?/str"  (error-object? "msg"))

(news "--- 6.11 guard ---\n")
(check "guard/match"      'got-42
  (guard (e ((equal? e 42) 'got-42))
    (raise 42)))

(check "guard/else"       'default
  (guard (e ((equal? e 99) 'nope) (else 'default))
    (raise 42)))

(check "guard/no-raise"   'ok
  (guard (e (else 'caught))
    'ok))

(check "guard/error-obj"  "oops"
  (guard (e ((error-object? e) (error-object-message e)))
    (error "oops" 1 2)))

(check "guard/reraise"    'outer
  (with-exception-handler
    (lambda (e) 'outer)
    (lambda ()
      (guard (e ((equal? e 'other) 'nope))
        (raise 'inner)))))

(news "--- 6.11 check-error helper ---\n")
(check-error "check-error/car-nil"  (lambda () (car '())))
(check-error "check-error/bad-add"  (lambda () (+ 'x 1)))

;;; -----------------------------------------------------------------------
;;; 6.4  Promises  (delay / force / delay-force)
;;; -----------------------------------------------------------------------

(news "\n--- 6.4 promises ---\n")
(define p-simple (delay (+ 1 2)))
(check-true  "promise?/delay"     (promise? p-simple))
(check-false "promise?/int"       (promise? 42))
(check "force/simple"    3        (force p-simple))
(check "force/memoized"  3        (force p-simple))   ;;; second force same result

;;; Memoization: forcing twice returns same object
(define p-memo (delay (list 1 2 3)))
(check-true "force/memoize-same" (eq? (force p-memo) (force p-memo)))

(check "make-promise/val"   42    (force (make-promise 42)))
(check "make-promise/pass"  #t    (let ((p (delay 5))) (eq? p (make-promise p))))

(news "--- delay-force / iterative streams ---\n")
(define (integers-from n)
  (delay-force (cons n (integers-from (+ n 1)))))
(define (stream-ref s n)
  (if (= n 0) (car (force s)) (stream-ref (cdr (force s)) (- n 1))))
(check "delay-force/0"      0     (stream-ref (integers-from 0) 0))
(check "delay-force/4"      4     (stream-ref (integers-from 0) 4))
(check "delay-force/99"     99    (stream-ref (integers-from 0) 99))

;;; -----------------------------------------------------------------------
;;; 7.1  Syntax -- let-syntax / letrec-syntax / define-syntax
;;; -----------------------------------------------------------------------

(news "\n--- let-syntax ---\n")
(check "let-syntax/swap"   '(2 1)
  (let-syntax ((swap! (syntax-rules ()
                        ((swap! a b)
                         (let ((t a)) (set! a b) (set! b t))))))
    (let ((x 1) (y 2))
      (swap! x y)
      (list x y))))

(news "--- letrec-syntax ---\n")
(check "letrec-syntax/my-or" 10
  (letrec-syntax ((my-or (syntax-rules ()
                            ((my-or)        #f)
                            ((my-or e)      e)
                            ((my-or e1 e2)  (let ((t e1)) (if t t (my-or e2)))))))
    (my-or #f 10)))

(news "--- define-syntax ---\n")
(define-syntax my-and
  (syntax-rules ()
    ((my-and)           #t)
    ((my-and e)         e)
    ((my-and e1 e2 ...) (if e1 (my-and e2 ...) #f))))

(check "define-syntax/true"  6    (my-and 2 3 6))
(check "define-syntax/false" #f   (my-and 2 #f 6))
(check "define-syntax/empty" #t   (my-and))
(check "define-syntax/one"   5    (my-and 5))

;;; -----------------------------------------------------------------------
;;; syntax-rules -- patterns, ellipsis, literals
;;; -----------------------------------------------------------------------

(news "\n--- syntax-rules: basic patterns ---\n")
(define-syntax my-if
  (syntax-rules ()
    ((my-if test then else) (cond (test then) (else else)))))
(check "sr/my-if-t"    1   (my-if #t 1 2))
(check "sr/my-if-f"    2   (my-if #f 1 2))

(news "--- syntax-rules: ellipsis ---\n")
(define-syntax my-list
  (syntax-rules ()
    ((my-list x ...) (list x ...))))
(check "sr/ellipsis-0"  '()        (my-list))
(check "sr/ellipsis-3"  '(1 2 3)   (my-list 1 2 3))

(define-syntax my-let
  (syntax-rules ()
    ((my-let ((var init) ...) body ...)
     ((lambda (var ...) body ...) init ...))))
(check "sr/my-let"  3  (my-let ((x 1) (y 2)) (+ x y)))
(check "sr/my-let/body" 6  (my-let ((x 1) (y 2)) (define z 3) (+ x y z)))

(news "--- syntax-rules: literals ---\n")
(define-syntax my-case-kw
  (syntax-rules (=>)
    ((my-case-kw val => proc)  (proc val))
    ((my-case-kw val)          val)))
(check "sr/literal-=>-yes"  10  (my-case-kw 5 => (lambda (x) (* x 2))))
(check "sr/literal-=>-no"   5   (my-case-kw 5))

(news "--- syntax-rules: nested ellipsis ---\n")
(define-syntax my-cond
  (syntax-rules (else)
    ((my-cond (else e ...))          (begin e ...))
    ((my-cond (test e ...) rest ...) (if test (begin e ...) (my-cond rest ...)))))
(check "sr/my-cond/t"     1  (my-cond (#t 1) (else 2)))
(check "sr/my-cond/f"     2  (my-cond (#f 1) (#t 2) (else 3)))
(check "sr/my-cond/else"  3  (my-cond (#f 1) (else 2 3)))

(news "--- syntax-rules: hygiene ---\n")
(define-syntax hyg-or
  (syntax-rules ()
    ((hyg-or e1 e2) (let ((t e1)) (if t t e2)))))
(define t 'outer)
(check "sr/hygiene"  'outer  (hyg-or #f t))   ;;; inner 't' must not capture outer 't'

;;; -----------------------------------------------------------------------
;;; 6.12  Environments and eval
;;; -----------------------------------------------------------------------

(news "\n--- eval / interaction-environment ---\n")
(check "eval/simple"     10   (eval '(+ 3 7) (interaction-environment)))
(check "eval/let"         6   (eval '(let ((x 2)) (* x 3)) (interaction-environment)))
(check "eval/quote"       'a  (eval ''a (interaction-environment)))
(check "eval/define"      99
  (begin
    (eval '(define eval-test-var 99) (interaction-environment))
    eval-test-var))

;;; -----------------------------------------------------------------------
;;; 6.13  Ports and I/O
;;; -----------------------------------------------------------------------

(news "\n--- 6.13 port predicates ---\n")
(check-true  "input-port?"           (input-port? (current-input-port)))
(check-true  "output-port?"          (output-port? (current-output-port)))
(check-true  "input-port?/out"       (input-port? (current-output-port)))  ;;; stdout is bidirectional in LambLisp
(check-false "output-port?/in"       (output-port? (current-input-port)))
(check-true  "port?/in"              (port? (current-input-port)))
(check-true  "port?/out"             (port? (current-output-port)))
(check-true  "input-port-open?/cur"  (input-port-open? (current-input-port)))
(check-true  "output-port-open?/cur" (output-port-open? (current-output-port)))

(news "--- 6.13 string ports ---\n")
(define sp (open-input-string "hello"))
(check-true  "open-input-string"     (input-port? sp))
(check "read-char/1"     #\h         (read-char sp))
(check "read-char/2"     #\e         (read-char sp))
(check "peek-char"       #\l         (peek-char sp))
(check "peek-no-advance" #\l         (read-char sp))   ;;; peek didn't advance
(check "read-char/4"     #\l         (read-char sp))
(check "read-char/5"     #\o         (read-char sp))
(check-true  "eof-object?"           (eof-object? (read-char sp)))
(check-true  "eof-object/val"        (eof-object? (eof-object)))

(define op (open-output-string))
(check-true  "open-output-string"    (output-port? op))
(write-char #\h op)
(write-char #\i op)
(check "get-output-string"  "hi"     (get-output-string op))

(news "--- 6.13 read from string port ---\n")
(define rp (open-input-string "(+ 1 2)"))
(check "read/list"       '(+ 1 2)    (read rp))
(define rp2 (open-input-string "42 #t \"hello\""))
(check "read/int"        42          (read rp2))
(check "read/bool"       #t          (read rp2))
(check "read/str"        "hello"     (read rp2))

(news "--- 6.13 write / display to string port ---\n")
(define wp (open-output-string))
(display "abc" wp)
(check "display/str"     "abc"       (get-output-string wp))

(define wp2 (open-output-string))
(write "abc" wp2)
(check "write/str"       "\"abc\""   (get-output-string wp2))

(define wp3 (open-output-string))
(write '(1 "two" #t) wp3)
(check "write/list"      "(1 \"two\" #t)"  (get-output-string wp3))

;;; -----------------------------------------------------------------------
;;; syntax-error
;;; -----------------------------------------------------------------------

(news "\n--- syntax-error ---\n")
(check-error "syntax-error/basic"
  (lambda ()
    (eval '(let-syntax ((bad (syntax-rules ()
                               ((bad) (syntax-error "deliberate")))))
             (bad))
          (interaction-environment))))

;;; -----------------------------------------------------------------------
;;; LambLisp extensions -- nlambda / macro / macro?
;;; -----------------------------------------------------------------------

(news "\n--- nlambda ---\n")

;;; nlambda receives the unevaluated argument list as a single value
(define my-quote2 (nlambda args (car args)))
(check "nlambda/sym"      'hello   (my-quote2 hello))
(check "nlambda/list"     '(1 2)   (my-quote2 (1 2)))
(check "nlambda/num"      42       (my-quote2 42))

;;; nlambda body sees caller's environment
(define nl-outer 77)
(define nl-test  (nlambda args nl-outer))
(check "nlambda/caller-env" 77   (nl-test))

(news "--- macro ---\n")
(define my-when3
  (macro use-form
    (let ((test (car use-form))
          (body (cdr use-form)))
      (list 'if test (cons 'begin body) #f))))
(check "macro/true"    'result   (my-when3 #t 'result))
(check "macro/false"   #f        (my-when3 #f 'never))

(define my-swap!
  (macro use-form
    (let ((a (car use-form)) (b (cadr use-form)))
      `(let ((t ,a)) (set! ,a ,b) (set! ,b t)))))
(let ((x 1) (y 2))
  (my-swap! x y)
  (check "macro/swap" '(2 1) (list x y)))

(check-true  "macro?/macro"   (macro? my-when3))
(check-false "macro?/proc"    (macro? car))
(check-false "macro?/lambda"  (macro? (lambda (x) x)))

;;; -----------------------------------------------------------------------
;;; LambLisp extensions -- dict
;;; -----------------------------------------------------------------------

(news "\n--- dict ---\n")
(define d (dict-add-empty-frame '()))
(dict-bind! d 'x 10 d)
(dict-bind! d 'y 20 d)
(check "dict-ref/x"       10    (dict-ref d 'x))
(check "dict-ref/y"       20    (dict-ref d 'y))
(check "dict-ref?/hit"    10    (cdr (dict-ref? d 'x)))
(check-true  "dict-ref?/miss"   (eq? #f (dict-ref? d 'z)))

(dict-rebind! d 'x 42 d)
(check "dict-rebind!/x"   42    (dict-ref d 'x))

(let ((ks (dict-keys d)))
  (check-true "dict-keys/x"   (memq 'x ks))
  (check-true "dict-keys/y"   (memq 'y ks)))

(define d2 (dict-add-alist-frame '() '((a . 1) (b . 2)) d))
(check "dict-alist/a"     1    (dict-ref d2 'a))
(check "dict-alist/b"     2    (dict-ref d2 'b))

;;; -----------------------------------------------------------------------
;;; LambLisp extensions -- reverse! / gensym
;;; -----------------------------------------------------------------------

(news "\n--- reverse! ---\n")
(check "reverse!/3"    '(3 2 1)  (reverse! (list 1 2 3)))
(check "reverse!/nil"  '()       (reverse! (list)))
(check "reverse!/1"    '(42)     (reverse! (list 42)))

(news "--- gensym ---\n")
(let ((g1 (gensym)) (g2 (gensym)) (g3 (gensym)))
  (check-true  "gensym/unique-12"   (not (eq? g1 g2)))
  (check-true  "gensym/unique-13"   (not (eq? g1 g3)))
  (check-true  "gensym/symbol?"     (symbol? g1)))

;;; -----------------------------------------------------------------------
;;; Summary
;;; -----------------------------------------------------------------------

(news "\n=== TEST SUMMARY: ~a passed, ~a failed ===\n" *pass* *fail*)
(if (= *fail* 0)
  (news "ALL TESTS PASSED\n")
  (warn "~a TESTS FAILED\n" *fail*))
(define lamblisp-test-pass *pass*)
(define lamblisp-test-fail *fail*)

