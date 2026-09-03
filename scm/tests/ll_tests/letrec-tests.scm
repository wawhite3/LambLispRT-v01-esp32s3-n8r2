;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; letrec tests
;;; Tests letrec in various positions, especially inside define bodies.
;;; =======================================================================

(define (check name expected actual)
  (if (equal? expected actual)
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=~a got=~a\n" name expected actual)))


;;; -----------------------------------------------------------------------
;;; Basic letrec
;;; -----------------------------------------------------------------------

(printf "--- basic letrec ---\n")

(check "letrec single"
  120
  (letrec ((fact (lambda (n)
                   (if (= n 0) 1 (* n (fact (- n 1)))))))
    (fact 5)))

(check "letrec mutual"
  #t
  (letrec ((even? (lambda (n) (if (= n 0) #t (odd?  (- n 1)))))
           (odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))))
    (even? 10)))

(check "letrec loop"
  15
  (letrec ((loop (lambda (i acc)
                   (if (= i 0) acc (loop (- i 1) (+ acc i))))))
    (loop 5 0)))


;;; -----------------------------------------------------------------------
;;; letrec inside define body
;;; -----------------------------------------------------------------------

(printf "--- letrec inside define ---\n")

(define (f-letrec-single n)
  (letrec ((count (lambda (i)
                    (if (= i n) i (count (+ i 1))))))
    (count 0)))

(check "letrec inside define single"  5  (f-letrec-single 5))
(check "letrec inside define zero"    0  (f-letrec-single 0))

(define (f-letrec-mutual n)
  (letrec ((even? (lambda (x) (if (= x 0) #t (odd?  (- x 1)))))
           (odd?  (lambda (x) (if (= x 0) #f (even? (- x 1))))))
    (even? n)))

(check "letrec mutual inside define even"  #t  (f-letrec-mutual 10))
(check "letrec mutual inside define odd"   #f  (f-letrec-mutual 7))

(define (f-letrec-list n)
  (letrec ((collect (lambda (i)
                      (if (= i n)
                          (list)
                          (cons i (collect (+ i 1)))))))
    (collect 0)))

(check "letrec list inside define"  '(0 1 2 3 4)  (f-letrec-list 5))
(check "letrec list zero"           '()            (f-letrec-list 0))


;;; -----------------------------------------------------------------------
;;; letrec inside let inside define
;;; -----------------------------------------------------------------------

(printf "--- letrec inside let inside define ---\n")

(define (f-letrec-in-let n)
  (let ((doubled (* n 2)))
    (letrec ((loop (lambda (i acc)
                     (if (= i doubled)
                         acc
                         (loop (+ i 1) (+ acc i))))))
      (loop 0 0))))

(check "letrec in let"  15  (f-letrec-in-let 3))   ;;; 0+1+2+3+4+5 = 15
(check "letrec in let zero"  0  (f-letrec-in-let 0))


;;; -----------------------------------------------------------------------
;;; letrec inside let* inside define (mirrors sr-expand)
;;; -----------------------------------------------------------------------

(printf "--- letrec inside let* inside define ---\n")

(define (f-letrec-in-let* items)
  (let* ((n    (length items))
         (reps (letrec ((collect (lambda (idx)
                                   (if (= idx n)
                                       (list)
                                       (cons (list-ref items idx)
                                             (collect (+ idx 1)))))))
                 (collect 0))))
    reps))

(check "letrec in let* list"   '(a b c)    (f-letrec-in-let* '(a b c)))
(check "letrec in let* empty"  '()         (f-letrec-in-let* '()))
(check "letrec in let* one"    '(42)       (f-letrec-in-let* '(42)))

;;; With a transform function (mirrors iter-b in sr-expand)
(define (f-letrec-transform items xform)
  (let* ((n    (length items))
         (reps (letrec ((collect (lambda (idx)
                                   (if (= idx n)
                                       (list)
                                       (cons (xform (list-ref items idx))
                                             (collect (+ idx 1)))))))
                 (collect 0))))
    reps))

(check "letrec transform"
  '(2 4 6)
  (f-letrec-transform '(1 2 3) (lambda (x) (* x 2))))


;;; -----------------------------------------------------------------------
;;; letrec inside lambda (closure capture)
;;; -----------------------------------------------------------------------

(printf "--- letrec inside lambda ---\n")

(define make-counter
  (lambda (n)
    (letrec ((count (lambda (i)
                      (if (= i n) i (count (+ i 1))))))
      (count 0))))

(check "letrec in lambda"  5  (make-counter 5))

(define make-range
  (lambda (n)
    (letrec ((build (lambda (i)
                      (if (= i n)
                          (list)
                          (cons i (build (+ i 1)))))))
      (build 0))))

(check "letrec in lambda list"  '(0 1 2 3)  (make-range 4))


;;; -----------------------------------------------------------------------
;;; letrec with no accumulator (the sr-expand pattern exactly)
;;; -----------------------------------------------------------------------

(printf "--- letrec no accumulator ---\n")

;;; This is the exact pattern used in sr-expand for ellipsis expansion.
;;; collect takes only idx, returns list built forward.
;;; No '() passed as argument -- only integers.

(define (sr-expand-like sub-list n)
  (letrec ((collect (lambda (idx)
                      (if (= idx n)
                          (list)
                          (cons (list-ref sub-list idx)
                                (collect (+ idx 1)))))))
    (collect 0)))

(check "sr-expand-like zero"   '()          (sr-expand-like '() 0))
(check "sr-expand-like one"    '(a)         (sr-expand-like '(a b c) 1))
(check "sr-expand-like three"  '(a b c)     (sr-expand-like '(a b c) 3))
(check "sr-expand-like nums"   '(10 20 30)  (sr-expand-like '(10 20 30) 3))


;;; -----------------------------------------------------------------------
;;; letrec* inside define
;;; -----------------------------------------------------------------------

(printf "--- letrec* inside define ---\n")

(define (f-letrec*-sequential)
  (letrec* ((x 1)
             (y (+ x 1))
             (z (+ y 1)))
    (list x y z)))

(check "letrec* sequential"  '(1 2 3)  (f-letrec*-sequential))

(define (f-letrec*-mutual n)
  (letrec* ((even? (lambda (x) (if (= x 0) #t (odd?  (- x 1)))))
             (odd?  (lambda (x) (if (= x 0) #f (even? (- x 1))))))
    (even? n)))

(check "letrec* mutual"  #t  (f-letrec*-mutual 6))

(printf "--- done ---\n")

