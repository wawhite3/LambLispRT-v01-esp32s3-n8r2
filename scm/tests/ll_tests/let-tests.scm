;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; Tests for let, named let, letrec, let*, letrec*
;;; Each test prints PASS or FAIL with the expected and actual values.
;;; =======================================================================

(define (check name expected actual)
  (if (equal? expected actual)
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=~a got=~a\n" name expected actual)))


;;; -----------------------------------------------------------------------
;;; let
;;; -----------------------------------------------------------------------

(printf "--- let ---\n")

(check "let basic"
  '(1 2)
  (let ((x 1) (y 2)) (list x y)))

(check "let inits see outer env"
  '(1 10)
  (let ((x 10))
    (let ((x 1) (y x))
      (list x y))))

(check "let single binding"
  42
  (let ((x 42)) x))

(check "let sum"
  7
  (let ((x 3) (y 4)) (+ x y)))

(check "let nested"
  '(3 1 3)
  (let ((x 1))
    (let ((x 2) (y x))
      (let ((x 3) (z (+ x y)))
        (list x y z)))))

(check "let body returns last"
  3
  (let ((x 1) (y 2))
    (+ x 0)
    (+ y 1)))


;;; -----------------------------------------------------------------------
;;; named let
;;; -----------------------------------------------------------------------

(printf "--- named let ---\n")

(check "named let single binding countdown"
  0
  (let loop ((x 3))
    (if (= x 0) x (loop (- x 1)))))

(check "named let two bindings sum"
  10
  (let loop ((i 0) (acc 0))
    (if (= i 5) acc (loop (+ i 1) (+ acc i)))))

(check "named let three bindings"
  '(6 24)
  (let loop ((i 0) (acc 0) (prod 1))
    (if (= i 4)
        (list acc prod)
        (loop (+ i 1) (+ acc i) (* prod (+ i 1))))))

(check "named let reverse list"
  '(5 4 3 2 1)
  (let loop ((lst '(1 2 3 4 5)) (acc '()))
    (if (null? lst)
        acc
        (loop (cdr lst) (cons (car lst) acc)))))

(check "named let fibonacci"
  55
  (let loop ((n 10) (a 0) (b 1))
    (if (= n 0) a (loop (- n 1) b (+ a b)))))

(check "named let order matters"
  '(1 2 3 4 5)
  (let loop ((i 5) (acc '()))
    (if (= i 0)
        acc
        (loop (- i 1) (cons i acc)))))

(check "named let two bindings i and acc swap"
  '(0 1 2 3 4)
  (let loop ((i 0) (acc '()))
    (if (= i 5)
        (reverse acc)
        (loop (+ i 1) (cons i acc)))))


;;; -----------------------------------------------------------------------
;;; let*
;;; -----------------------------------------------------------------------

(printf "--- let* ---\n")

(check "let* sequential"
  '(1 2 3)
  (let* ((x 1) (y (+ x 1)) (z (+ y 1)))
    (list x y z)))

(check "let* x rebind"
  '(10 1)
  (let* ((x 1) (y x) (x 10))
    (list x y)))

(check "let* building value"
  '(2 4 8)
  (let* ((base 2)
         (squared (* base base))
         (cubed (* squared base)))
    (list base squared cubed)))

(check "let* each sees previous"
  20
  (let* ((a 1) (b (+ a 2)) (c (+ b 3)) (d (+ c 4)))
    (+ a b c d)))


;;; -----------------------------------------------------------------------
;;; letrec
;;; -----------------------------------------------------------------------

(printf "--- letrec ---\n")

(check "letrec mutual recursion even?"
  #t
  (letrec ((even? (lambda (n) (if (= n 0) #t (odd?  (- n 1)))))
           (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
    (even? 10)))

(check "letrec mutual recursion odd?"
  #t
  (letrec ((even? (lambda (n) (if (= n 0) #t (odd?  (- n 1)))))
           (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
    (odd? 7)))

(check "letrec factorial"
  120
  (letrec ((fact (lambda (n)
                   (if (= n 0) 1 (* n (fact (- n 1)))))))
    (fact 5)))

(check "letrec loop two args"
  15
  (letrec ((loop (lambda (i acc)
                   (if (= i 0) acc (loop (- i 1) (+ acc i))))))
    (loop 5 0)))


;;; -----------------------------------------------------------------------
;;; letrec*
;;; -----------------------------------------------------------------------

(printf "--- letrec* ---\n")

(check "letrec* sequential"
  6
  (letrec* ((x 1)
             (y (+ x 1))
             (f (lambda (n) (+ n x y))))
    (f 3)))

(check "letrec* mutual recursion"
  #t
  (letrec* ((even? (lambda (n) (if (= n 0) #t (odd?  (- n 1)))))
            (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
    (even? 6)))

(check "letrec* building on previous"
  '(1 2 3)
  (letrec* ((a 1)
             (b (+ a 1))
             (c (+ b 1)))
    (list a b c)))
