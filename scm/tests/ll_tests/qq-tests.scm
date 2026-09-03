;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; quasiquote tests — load quasiquote.scm first
;;; =======================================================================


;;; -----------------------------------------------------------------------
;;; Part 1: Atoms
;;; -----------------------------------------------------------------------

`42                        ;;; → 42
`foo                       ;;; → foo
`#t                        ;;; → #t
`#f                        ;;; → #f
`"hello"                   ;;; → "hello"


;;; -----------------------------------------------------------------------
;;; Part 2: Plain lists — no substitution
;;; -----------------------------------------------------------------------

`(a b c)                   ;;; → (a b c)
`(a (b c) d)               ;;; → (a (b c) d)
`((a 1) (b 2))             ;;; → ((a 1) (b 2))
`()                        ;;; → ()


;;; -----------------------------------------------------------------------
;;; Part 3: Substitution — including falsy values
;;; -----------------------------------------------------------------------

(let ((x 42))   `(a ,x c)) ;;; → (a 42 c)
(let ((x #f))   `(a ,x c)) ;;; → (a #f c)
(let ((x '()))  `(a ,x c)) ;;; → (a () c)
(let ((x 0))    `(a ,x c)) ;;; → (a 0 c)


;;; -----------------------------------------------------------------------
;;; Part 4: Expressions in unquote
;;; -----------------------------------------------------------------------

(let ((b 41))        `(a ,(+ b 1) c))    ;;; → (a 42 c)
(let ((x 3) (y 4))   `(sum ,(+ x y)))    ;;; → (sum 7)
(let ((x 5))         `,(* x x))          ;;; → 25
`,(+ 1 2)                                ;;; → 3


;;; -----------------------------------------------------------------------
;;; Part 5: Multiple substitutions
;;; -----------------------------------------------------------------------

(let ((a 1) (b 2) (c 3)) `(,a ,b ,c))    ;;; → (1 2 3)
(let ((addr #x5f) (freq 50.0))
  `((address ,addr) (frequency ,freq)))   ;;; → ((address 95) (frequency 50.0))


;;; -----------------------------------------------------------------------
;;; Part 6: Splice
;;; -----------------------------------------------------------------------

(let ((xs '(1 2 3))) `(a ,@xs b))        ;;; → (a 1 2 3 b)
(let ((xs '()))      `(a ,@xs b))        ;;; → (a b)
(let ((xs '(1 2 3))) `(,@xs))            ;;; → (1 2 3)
(let ((xs '(1 2)) (ys '(3 4)))
  `(,@xs ,@ys))                          ;;; → (1 2 3 4)
(let ((xs '(1 2 3))) `(a b ,@xs))        ;;; → (a b 1 2 3)
(let ((xs '(1 2 3))) `(,@xs a b))        ;;; → (1 2 3 a b)


;;; -----------------------------------------------------------------------
;;; Part 7: Dotted pairs
;;; -----------------------------------------------------------------------

(let ((x 99))  `(a . ,x))               ;;; → (a . 99)
(let ((x 'b))  `(a . ,x))               ;;; → (a . b)


;;; -----------------------------------------------------------------------
;;; Part 8: Nested lists
;;; -----------------------------------------------------------------------

(let ((ch 4) (lo 500) (hi 2500))
  `(Servo (,ch ,lo ,hi)))               ;;; → (Servo (4 500 2500))

(let ((x 1) (y 2))
  `((a ,x) (b ,y)))                     ;;; → ((a 1) (b 2))


;;; -----------------------------------------------------------------------
;;; Part 9: Vector as value
;;; -----------------------------------------------------------------------

(let ((v (vector 1 2 3))) `(pins ,v))   ;;; → (pins '#(1 2 3))

(let ((mp (vector '(14 15) '(13 12) '(11 10) '(8 9))))
  `(MotorPins ,mp))                     ;;; → (MotorPins '#((14 15) (13 12) (11 10) (8 9)))


;;; -----------------------------------------------------------------------
;;; Part 10: Nested quasiquote
;;;
;;; At depth 1: , evaluates, ,@ splices
;;; At depth 2: , and ,@ are reconstructed as data — NOT evaluated
;;; -----------------------------------------------------------------------

;;; Basic nested quasiquote — inner , must NOT evaluate.
`(outer `(inner ,(+ 1 2)))
;;; → (outer (quasiquote (inner (unquote (+ 1 2)))))

;;; Outer unquote evaluates, inner does not.
(let ((x 99))
  `(outer ,x `(inner ,(+ 1 2))))
;;; → (outer 99 (quasiquote (inner (unquote (+ 1 2)))))

;;; Two levels of nesting.
`(a `(b `(c ,(+ 1 2))))
;;; → (a (quasiquote (b (quasiquote (c (unquote (+ 1 2)))))))

;;; Inner splice at depth 2 — must be reconstructed as data.
`(outer `(inner ,@xs))
;;; → (outer (quasiquote (inner (unquote-splicing xs))))

;;; Outer splice evaluates, inner does not.
(let ((xs '(1 2 3)))
  `(outer ,@xs `(inner ,@ys)))
;;; → (outer 1 2 3 (quasiquote (inner (unquote-splicing ys))))


;;; -----------------------------------------------------------------------
;;; Part 11: Config and code generation
;;; -----------------------------------------------------------------------

(let ((motor-pins (vector '(14 15) '(13 12) '(11 10) '(8 9))))
  `((default-address #x5f)
    (Servo2 (2 500 2500))
    (MotorPins ,motor-pins)))
;;; → ((default-address 95) (Servo2 (2 500 2500))
;;;    (MotorPins '#((14 15) (13 12) (11 10) (8 9))))

(define (make-adder n)
  `(lambda (x) (+ x ,n)))
(make-adder 5)
;;; → (lambda (x) (+ x 5))

(define (make-begin . exprs)
  `(begin ,@exprs))
(make-begin '(display "a") '(newline))
;;; → (begin (display "a") (newline))

(define (make-if test then else)
  `(if ,test ,then ,else))
(make-if '(> x 0) 'positive 'non-positive)
;;; → (if (> x 0) positive non-positive)

'((14 15) (13 12) (11 10) (8 9))
(apply list->vector '((14 15) (13 12) (11 10) (8 9)))
(let ((v (apply list->vector '((14 15) (13 12) (11 10) (8 9))))) `(MotorPins ,v))
