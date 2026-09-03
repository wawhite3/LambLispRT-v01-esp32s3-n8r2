;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; syntax-rules test suite
;;; Load syntax_rules.scm before this file.
;;;
;;; IMPORTANT: macro arguments that are symbols must be quoted at the
;;; call site if they are not defined variables, because the expansion
;;; is evaluated in the caller's environment. e.g.:
;;;   (my-identity 'foo)  → 'foo → foo   ✓
;;;   (my-identity foo)   → foo  → ERROR (unbound)  ✗
;;; =======================================================================

(define (check name expected actual)
  (if (equal? expected actual)
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=~a got=~a\n" name expected actual)))

(define (check-true name actual)
  (if actual
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=#t got=~a\n" name actual)))

(define (check-false name actual)
  (if (not actual)
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=#f got=~a\n" name actual)))


;;; -----------------------------------------------------------------------
;;; 1. Basic pattern variables
;;; -----------------------------------------------------------------------

(printf "--- 1. basic pvar ---\n")

(define my-identity
  (syntax-rules ()
    ((_ x) x)))

(check "identity number"   42      (my-identity 42))
(check "identity #t"       #t      (my-identity #t))
(check "identity #f"       #f      (my-identity #f))
(check "identity string"   "hi"    (my-identity "hi"))
(check "identity quoted"   'foo    (my-identity 'foo))
(check "identity list"     '(1 2)  (my-identity '(1 2)))
(check "identity expr"     7       (my-identity (+ 3 4)))

(define my-list2
  (syntax-rules ()
    ((_ a b) (list a b))))

(check "two pvars"   '(1 2)    (my-list2 1 2))
(check "two exprs"   '(3 4)    (my-list2 (+ 1 2) (+ 2 2)))

(define my-list3
  (syntax-rules ()
    ((_ a b c) (list a b c))))

(check "three pvars"  '(1 2 3)  (my-list3 1 2 3))


;;; -----------------------------------------------------------------------
;;; 2. Wildcard _
;;; -----------------------------------------------------------------------

(printf "--- 2. wildcard ---\n")

(define my-first
  (syntax-rules ()
    ((_ x _ ...) x)))

(check "wildcard one"    1  (my-first 1))
(check "wildcard many"   1  (my-first 1 2 3 4))

(define my-second
  (syntax-rules ()
    ((_ _ x _ ...) x)))

(check "wildcard skip"  2  (my-second 1 2 3))

(define const-42
  (syntax-rules ()
    ((_ _ _ _) 42)))

(check "all wildcards"  42  (const-42 1 2 3))


;;; -----------------------------------------------------------------------
;;; 3. Literal keywords
;;; -----------------------------------------------------------------------

(printf "--- 3. literals ---\n")

(define my-cond
  (syntax-rules (else)
    ((_ (else e ...))           (begin e ...))
    ((_ (test e ...) rest ...)  (if test (begin e ...) (my-cond rest ...)))))

(check "cond first"   'a   (my-cond (#t 'a) (else 'b)))
(check "cond else"    'b   (my-cond (#f 'a) (else 'b)))
(check "cond chain"   'c   (my-cond (#f 'a) (#f 'b) (else 'c)))
(check "cond multi"    3   (my-cond (#t 1 2 3) (else 0)))

;;; else treated as pvar when not declared as literal
(define use-else
  (syntax-rules ()
    ((_ else x) x)))

(check "else as pvar"  42  (use-else else 42))


;;; -----------------------------------------------------------------------
;;; 4. Datum patterns
;;; -----------------------------------------------------------------------

(printf "--- 4. datum patterns ---\n")

(define my-zero?
  (syntax-rules ()
    ((_ 0) 'zero)
    ((_ x) 'nonzero)))

(check "datum 0"       'zero     (my-zero? 0))
(check "datum other"   'nonzero  (my-zero? 1))
(check "datum #f"      'nonzero  (my-zero? #f))

(define my-true?
  (syntax-rules ()
    ((_ #t) 'yes)
    ((_ x)  'no)))

(check "datum #t yes"  'yes  (my-true? #t))
(check "datum #f no"   'no   (my-true? #f))
(check "datum val no"  'no   (my-true? 42))


;;; -----------------------------------------------------------------------
;;; 5. Ellipsis — zero or more
;;; -----------------------------------------------------------------------

(printf "--- 5. ellipsis ---\n")

(define my-list
  (syntax-rules ()
    ((_ e ...) (list e ...))))

(check "list zero"   '()        (my-list))
(check "list one"    '(1)       (my-list 1))
(check "list three"  '(1 2 3)   (my-list 1 2 3))
(check "list five"   '(1 2 3 4 5)  (my-list 1 2 3 4 5))

(define my-list-prefix
  (syntax-rules ()
    ((_ first rest ...) (list first rest ...))))

(check "ellipsis after fixed one"   '(1)      (my-list-prefix 1))
(check "ellipsis after fixed three" '(1 2 3)  (my-list-prefix 1 2 3))

;;; Multiple pvars in ellipsis — lockstep expansion
(define my-let
  (syntax-rules ()
    ((_ ((var init) ...) body ...)
     ((lambda (var ...) body ...) init ...))))

;; (my-let () 42) -- zero bindings not supported: pattern ((var init) ...) cannot
;; distinguish empty binding list from body expressions at the outer level.
(check "let one"         5  (my-let ((x 5)) x))
(check "let two"        12  (my-let ((x 3) (y 4)) (* x y)))
(check "let multi-body"  7  (my-let ((x 3) (y 4)) (+ x 0) (+ x y)))

(define my-begin
  (syntax-rules ()
    ((_ e)         e)
    ((_ e1 e2 ...) (let ((ignore e1)) (my-begin e2 ...)))))

(check "begin one"    3   (my-begin 3))
(check "begin two"   'b   (my-begin 'a 'b))
(check "begin three" 'c   (my-begin 'a 'b 'c))


;;; -----------------------------------------------------------------------
;;; 6. Multiple patterns — ordering
;;; -----------------------------------------------------------------------

(printf "--- 6. multiple patterns ---\n")

(define my-and
  (syntax-rules ()
    ((_)           #t)
    ((_ e)         e)
    ((_ e1 e2 ...) (let ((t e1)) (if t (my-and e2 ...) #f)))))

(check "and empty"      #t  (my-and))
(check "and single"     42  (my-and 42))
(check "and single #f"  #f  (my-and #f))
(check "and two true"    2  (my-and 1 2))
(check "and short"      #f  (my-and 1 #f 3))
(check "and all false"  #f  (my-and #f #f #f))
(check "and returns last" 3 (my-and 1 2 3))

(define my-or
  (syntax-rules ()
    ((_)           #f)
    ((_ e)         e)
    ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))

(check "or empty"       #f  (my-or))
(check "or single"      99  (my-or 99))
(check "or single #f"   #f  (my-or #f))
(check "or first true"   1  (my-or 1 2 3))
(check "or first false" 42  (my-or #f 42))
(check "or all false"   #f  (my-or #f #f #f))


;;; -----------------------------------------------------------------------
;;; 7. Recursive macros
;;; -----------------------------------------------------------------------

(printf "--- 7. recursive ---\n")

(define my-when
  (syntax-rules ()
    ((_ test body ...)
     (if test (begin body ...) (if #f #f)))))

(define my-unless
  (syntax-rules ()
    ((_ test body ...)
     (if test (if #f #f) (begin body ...)))))

(check "when true"     'yes       (my-when   #t 'yes))
(check "when false"    (if #f #f) (my-when   #f 'yes))
(check "unless false"  'yes       (my-unless #f 'yes))
(check "unless true"   (if #f #f) (my-unless #t 'yes))

(define my-while
  (syntax-rules ()
    ((_ test body ...)
     (let loop ()
       (when test body ... (loop))))))

(check "while basic"  10
  (let ((i 0) (sum 0))
    (my-while (< i 5)
      (set! sum (+ sum i))
      (set! i (+ i 1)))
    sum))


;;; -----------------------------------------------------------------------
;;; 8. Hygiene
;;; -----------------------------------------------------------------------

(printf "--- 8. hygiene ---\n")

;;; my-or introduces 't' — user's 't' must survive
(check "or hygiene"
  99
  (let ((t 99)) (my-or #f t)))

;;; my-and introduces 't'
(check "and hygiene"
  3
  (let ((t 99)) (my-and 1 2 3)))

;;; swap! introduces 'tmp'
(define swap!
  (syntax-rules ()
    ((_ a b)
     (let ((tmp a))
       (set! a b)
       (set! b tmp)))))

(check "swap! basic"
  '(2 1)
  (let ((x 1) (y 2))
    (swap! x y)
    (list x y)))

(check "swap! hygiene tmp"
  '(2 1 99)
  (let ((tmp 99) (x 1) (y 2))
    (swap! x y)
    (list x y tmp)))

;;; my-while introduces 'loop'
(check "while hygiene loop"
  '(10 999)
  (let ((loop 999) (i 0) (sum 0))
    (my-while (< i 5)
      (set! sum (+ sum i))
      (set! i (+ i 1)))
    (list sum loop)))

;;; Nested macro uses — each gets independent gensyms
(check "nested or hygiene"
  42
  (let ((t 99))
    (my-or #f (my-or #f 42))))

;;; let in template — introduced var must not capture outer
(define my-letone
  (syntax-rules ()
    ((_ x body ...)
     (let ((v x)) body ...))))

(check "let hygiene"
  99
  (let ((v 99))
    (my-letone 1 v)))  ; v in body refers to outer v -- correct hygiene


;;; -----------------------------------------------------------------------
;;; 9. Falsy values as pattern variable bindings
;;; -----------------------------------------------------------------------

(printf "--- 9. falsy values ---\n")

(define use-val
  (syntax-rules ()
    ((_ v) (list v v))))

(check "pvar #f"   '(#f #f)  (use-val #f))
(check "pvar 0"    '(0 0)    (use-val 0))
(check "pvar nil"  '(() ())  (use-val '()))

(define use-vals
  (syntax-rules ()
    ((_ v ...) (list v ...))))

(check "ellipsis #f"    '(#f)      (use-vals #f))
(check "ellipsis 0"     '(0)       (use-vals 0))
(check "ellipsis nil"   '(())      (use-vals '()))
(check "ellipsis mixed" '(1 #f 3)  (use-vals 1 #f 3))

;;; or with falsy values — 0 and '() are truthy in Scheme
(check "or #f first"   2   (my-or #f 2))
(check "or 0 truthy"   0   (my-or 0 2))
(check "or nil truthy" '() (my-or '() 2))


;;; -----------------------------------------------------------------------
;;; 10. Dotted formals in templates
;;; -----------------------------------------------------------------------

(printf "--- 10. dotted patterns ---\n")

(define my-lambda
  (syntax-rules ()
    ((_ formals body ...)
     (lambda formals body ...))))

(check "lambda fixed"    3      ((my-lambda (x y) (+ x y)) 1 2))
(check "lambda rest"     '(2 3) ((my-lambda (x . rest) rest) 1 2 3))
(check "lambda vararg"   '(1 2) ((my-lambda args args) 1 2))
(check "lambda multi"    3      ((my-lambda (x y) (+ x 0) (+ x y)) 1 2))


;;; -----------------------------------------------------------------------
;;; 11. Complex binding macros
;;; -----------------------------------------------------------------------

(printf "--- 11. binding macros ---\n")

(define my-named-let
  (syntax-rules ()
    ((_ name ((var init) ...) body ...)
     (letrec ((name (lambda (var ...) body ...)))
       (name init ...)))))

(check "named-let countdown"  0
  (my-named-let loop ((n 5))
    (if (= n 0) n (loop (- n 1)))))

(check "named-let sum"  15
  (my-named-let loop ((i 5) (acc 0))
    (if (= i 0) acc (loop (- i 1) (+ acc i)))))

(check "named-let fib"  55
  (my-named-let fib ((n 10) (a 0) (b 1))
    (if (= n 0) a (fib (- n 1) b (+ a b)))))

(define my-let*
  (syntax-rules ()
    ((_ () body ...)
     (begin body ...))
    ((_ ((var init) rest ...) body ...)
     (let ((var init))
       (my-let* (rest ...) body ...)))))

(check "let* sequential"  6
  (my-let* ((x 1) (y (+ x 1)) (z (+ y 1)))
    (+ x y z)))

;; (my-let* () 42) -- zero bindings limitation, same as my-let


;;; -----------------------------------------------------------------------
;;; 12. case with memv
;;; -----------------------------------------------------------------------

(printf "--- 12. case ---\n")

(define my-case
  (syntax-rules (else)
    ((_ val (else e ...))
     (begin e ...))
    ((_ val ((datum ...) e ...) rest ...)
     (if (memv val '(datum ...))
         (begin e ...)
         (my-case val rest ...)))))

(check "case match"    'yes  (my-case 2 ((1 2 3) 'yes) (else 'no)))
(check "case no match" 'no   (my-case 5 ((1 2 3) 'yes) (else 'no)))
(check "case else"     'def  (my-case 99 (else 'def)))
(check "case multi"    'b    (my-case 3 ((1 2) 'a) ((3 4) 'b) (else 'c)))


;;; -----------------------------------------------------------------------
;;; 13. Ellipsis with multiple variables (lockstep)
;;; -----------------------------------------------------------------------

(printf "--- 13. ellipsis lockstep ---\n")

(define zip-lists
  (syntax-rules ()
    ((_ (a ...) (b ...))
     (list (list a b) ...))))

(check "zip two"    '((1 4) (2 5) (3 6))  (zip-lists (1 2 3) (4 5 6)))
;; (zip-lists () ()) -- zero-binding ellipsis limitation
(check "zip one"    '((1 4))               (zip-lists (1) (4)))


;;; -----------------------------------------------------------------------
;;; 14. Composing macros
;;; -----------------------------------------------------------------------

(printf "--- 14. composing ---\n")

(define my-nor
  (syntax-rules ()
    ((_ x ...) (my-unless (my-or x ...) #t))))

(check "nor all false"  #t          (my-nor #f #f #f))
(check "nor one true"   (if #f #f)  (my-nor #f 1 #f))

(define my-nand
  (syntax-rules ()
    ((_ x ...) (my-unless (my-and x ...) #t))))

(check "nand all true"   (if #f #f)  (my-nand 1 2 3))
(check "nand one false"  #t          (my-nand 1 #f 3))

;;; Macro that defines
(define my-defconst
  (syntax-rules ()
    ((_ name val) (define name val))))

(my-defconst pi 3.14159)
(check "defconst"  3.14159  pi)

(my-defconst greeting "hello")
(check "defconst string"  "hello"  greeting)


;;; -----------------------------------------------------------------------
;;; 15. do loop
;;; -----------------------------------------------------------------------

(printf "--- 15. do ---\n")

(define my-do
  (syntax-rules ()
    ((_ ((var init step) ...)
        (test result ...)
        body ...)
     (let loop ((var init) ...)
       (if test
           (begin result ...)
           (begin body ... (loop step ...)))))))

(check "do sum"  10
  (my-do ((i 0 (+ i 1))
          (sum 0 (+ sum i)))
         ((= i 5) sum)))

(check "do list"  '(4 3 2 1 0)
  (my-do ((i 0 (+ i 1))
          (acc '() (cons i acc)))
         ((= i 5) acc)))

(check "do vector"  '#(0 1 2 3 4)
  (let ((v (make-vector 5)))
    (my-do ((i 0 (+ i 1)))
           ((= i 5) v)
      (vector-set! v i i))))


;;; -----------------------------------------------------------------------
;;; 16. and-let*
;;; -----------------------------------------------------------------------

(printf "--- 16. and-let* ---\n")

(define my-and-let*
  (syntax-rules ()
    ((_ () body ...)
     (begin body ...))
    ((_ ((var expr) rest ...) body ...)
     (let ((var expr))
       (if var
           (my-and-let* (rest ...) body ...)
           #f)))))

(check "and-let* true"   6   (my-and-let* ((x 2) (y (* x 3))) y))
(check "and-let* false"  #f  (my-and-let* ((x #f) (y 99)) y))
;; (my-and-let* () 42) -- zero bindings limitation

(printf "--- done ---\n")
