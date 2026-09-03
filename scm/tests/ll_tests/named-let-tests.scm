;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; Named let tests
;;; =======================================================================

(define (check name expected actual)
  (if (equal? expected actual)
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=~a got=~a\n" name expected actual)))

(define (check-true name actual)
  (if actual
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=#t got=~a\n" name actual)))


;;; -----------------------------------------------------------------------
;;; Single binding
;;; -----------------------------------------------------------------------

(printf "--- named let: single binding ---\n")

(check "single countdown"
  0
  (let loop ((x 3))
    (if (= x 0) x (loop (- x 1)))))

;;; 5+4+3+2+1+0 = 15
(check "single sum"
  15
  (let loop ((x 5))
    (if (= x 0) 0 (+ x (loop (- x 1))))))

(check "single build list"
  '(1 2 3 4 5)
  (let loop ((x 5))
    (if (= x 0) '() (append (loop (- x 1)) (list x)))))

(check "single accumulate"
  '(5 4 3 2 1)
  (let loop ((x 5) )
    (if (= x 0) '() (cons x (loop (- x 1))))))


;;; -----------------------------------------------------------------------
;;; Two bindings
;;; -----------------------------------------------------------------------

(printf "--- named let: two bindings ---\n")

(check "two bindings sum"
  15
  (let loop ((i 5) (acc 0))
    (if (= i 0) acc (loop (- i 1) (+ acc i)))))

(check "two bindings product"
  120
  (let loop ((i 5) (acc 1))
    (if (= i 0) acc (loop (- i 1) (* acc i)))))

(check "two bindings reverse"
  '(5 4 3 2 1)
  (let loop ((lst '(1 2 3 4 5)) (acc '()))
    (if (null? lst) acc (loop (cdr lst) (cons (car lst) acc)))))

(check "two bindings fibonacci"
  55
  (let loop ((n 10) (a 0) (b 1))
    (if (= n 0) a (loop (- n 1) b (+ a b)))))

;;; Critical: second arg is '() — tests nil-as-value handling
(check "two bindings acc starts nil"
  '(0 1 2 3 4)
  (let loop ((i 0) (acc '()))
    (if (= i 5)
        (reverse acc)
        (loop (+ i 1) (cons i acc)))))

;;; Diagnostic: both args falsy — tests #f and 0 as values
;;; #f is not equal? to 0 in R5RS — test each independently
(check-true "falsy: a starts #f"
  (let loop ((a #f) (b 0))
    (if (eq? a #f)
        (loop #t b)
        (eq? a #t))))

(check-true "falsy: b stays 0"
  (let loop ((a #f) (b 0))
    (if (eq? a #f)
        (loop #t b)
        (= b 0))))

(check-true "falsy: b is integer"
  (let loop ((a #f) (b 0))
    (if (eq? a #f)
        (loop #t b)
        (integer? b))))


;;; -----------------------------------------------------------------------
;;; Three bindings
;;; -----------------------------------------------------------------------

(printf "--- named let: three bindings ---\n")

(check "three bindings sum+product"
  '(6 24)
  (let loop ((i 0) (acc 0) (prod 1))
    (if (= i 4)
        (list acc prod)
        (loop (+ i 1) (+ acc i) (* prod (+ i 1))))))

(check "three bindings list build"
  '(a b c d e)
  (let loop ((i 5) (lst '(e d c b a)) (acc '()))
    (if (= i 0)
        acc
        (loop (- i 1) (cdr lst) (cons (car lst) acc)))))


;;; -----------------------------------------------------------------------
;;; Order matters — verifies arg N maps to formal N
;;; -----------------------------------------------------------------------

(printf "--- named let: order matters ---\n")

(check "order: i increments acc grows"
  '(1 2 3 4 5)
  (let loop ((i 1) (acc '()))
    (if (> i 5)
        (reverse acc)
        (loop (+ i 1) (cons i acc)))))

;;; i decrements, acc accumulates — if swapped, i grows forever
(check "order: i decrements to 0"
  15
  (let loop ((n 5) (acc 0))
    (if (= n 0) acc (loop (- n 1) (+ acc n)))))

;;; All three decrement — result shows final values (0 -1 -2)
(check "order: three args decrement"
  '(0 -1 -2)
  (let loop ((a 3) (b 2) (c 1))
    (if (= a 0)
        (list a b c)
        (loop (- a 1) (- b 1) (- c 1)))))

;;; Verify each position independently
(check "order: first arg controls termination"
  'done
  (let loop ((ctrl 3) (ignored 99))
    (if (= ctrl 0) 'done (loop (- ctrl 1) ignored))))

(check "order: second arg preserved"
  42
  (let loop ((n 3) (val 42))
    (if (= n 0) val (loop (- n 1) val))))

(check "order: args independent"
  '(0 5)
  (let loop ((i 3) (j 2))
    (if (= i 0)
        (list i j)
        (loop (- i 1) (+ j 1)))))


;;; -----------------------------------------------------------------------
;;; Edge cases
;;; -----------------------------------------------------------------------

(printf "--- named let: edge cases ---\n")

(check "zero iterations"
  'done
  (let loop ((n 0))
    (if (= n 0) 'done (loop (- n 1)))))

(check "nil as initial value"
  '(1 2 3)
  (let loop ((lst '(1 2 3)) (acc '()))
    (if (null? lst)
        (reverse acc)
        (loop (cdr lst) (cons (car lst) acc)))))

(check "false as initial value"
  #t
  (let loop ((flag #f))
    (if flag #t (loop #t))))

(check "zero as initial value"
  5
  (let loop ((n 0))
    (if (= n 5) n (loop (+ n 1)))))

(check "nested named let"
  '(0 1 2 3 4)
  (let outer ((i 0) (acc '()))
    (if (= i 5)
        (reverse acc)
        (let inner ((j i))
          (outer (+ i 1) (cons j acc))))))

(check "large iteration"
  1000
  (let loop ((n 0))
    (if (= n 1000) n (loop (+ n 1)))))

(printf "--- done ---\n")
