;;; P86 Ph2 test -- inner-lambda BC compilation for non-tail named-let.
;;; Copyright 2026 by Frobenius Norm LLC 2026-05-18

(load "ll_tests/benchmarks.scm" 0)

(define (check-p86 label got expected)
  (if (equal? got expected)
    (begin (display "PASS ") (display label) (newline))
    (begin (display "FAIL ") (display label)
           (display " got=") (display got)
           (display " expected=") (display expected)
           (newline))))

;;; 1. qsort-vec! sorts correctly at interpreter level (adjacency check).
(define (vector-sorted? v)
  (let ((n (vector-length v)))
    (let loop ((i 1))
      (if (>= i n) #t
          (if (> (vector-ref v (- i 1)) (vector-ref v i)) #f
              (loop (+ i 1)))))))

(define v1 (make-iota-vec 10))
(define sorted1 (qsort-vec! v1))
(check-p86 "qsort-interp-first"  (vector-ref sorted1 0) 1)
(check-p86 "qsort-interp-last"   (vector-ref sorted1 9) 10)
(check-p86 "qsort-interp-sorted" (vector-sorted? sorted1) #t)

;;; 2. procedure->bytecode on qsort-vec! now succeeds (Ph2 inner-lambda).
(define qsort-bc (procedure->bytecode qsort-vec!))
(check-p86 "qsort-p->bc-is-bytecode" (bytecode? qsort-bc) #t)

;;; 2b. qsort-bc sorts correctly (inner-lambda BC produces correct results).
(define v-bc (vector 5 3 1 4 2 9 7 6 8 10))
(qsort-bc v-bc)
(define (vector-sorted-bc? v)
  (let loop ((i 1))
    (if (>= i (vector-length v)) #t
        (if (> (vector-ref v (- i 1)) (vector-ref v i)) #f
            (loop (+ i 1))))))
(check-p86 "qsort-bc-sorted" (vector-sorted-bc? v-bc) #t)
(check-p86 "qsort-bc-first"  (vector-ref v-bc 0) 1)
(check-p86 "qsort-bc-last"   (vector-ref v-bc 9) 10)

;;; 3. ncg-compile-transitive! on T_PROC is a no-op -- must not crash.
(ncg-compile-transitive! qsort-vec!)
(check-p86 "qsort-ncg-noop" #t #t)

;;; 4. Tail-only named-let still compiles to bytecode.
(define (sum-to n)
  (let loop ((i n) (acc 0))
    (if (= i 0) acc (loop (- i 1) (+ acc i)))))
(define sum-bc (procedure->bytecode sum-to))
(check-p86 "sum-to-is-bytecode"  (bytecode? sum-bc) #t)
(check-p86 "sum-to-result"       (sum-bc 100) 5050)

(display "--- p86 test done ---") (newline)
