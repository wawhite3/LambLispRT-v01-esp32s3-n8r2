;;; B154 probe v2 -- same arity sweep, but with a LARGE RETAINED LIVE SET first.
;;; v1 (40k calls/arity, tiny heap) found NOTHING.  The reported faults all land beside a
;;; collection with Amax ~16000: a big live set makes the MARK phase span many allocations, so
;;; gcphase==gcphase_marking is true while frames are built.  The alist->hash conversion in
;;; dict_add_keyval_frame conses a bucket per binding and calls vector_set_bang, whose barrier
;;; pushes only the OLD element -- so that window is only exercised when marking is actually on.
(define retained '())
(define (build n) (if (> n 0) (begin (set! retained (cons (list n n n) retained)) (build (- n 1)))))
(build 60000)
(display (list 'RETAINED (length retained))) (newline)
(define bad3 0) (define bad4 0) (define bad8 0) (define nlbad 0)
(define (p3 a b c)           (list a b c))
(define (p4 a b c d)         (list a b c d))
(define (p8 a b c d e f g h) (list a b c d e f g h))
(define (spin n)
  (if (> n 0)
      (begin
        (guard (ex (#t (set! bad3 (+ bad3 1))))
          (if (not (equal? (p3 'A 'B 'C) '(A B C))) (set! bad3 (+ bad3 1))))
        (guard (ex (#t (set! bad4 (+ bad4 1))))
          (if (not (equal? (p4 'A 'B 'C 'D) '(A B C D))) (set! bad4 (+ bad4 1))))
        (guard (ex (#t (set! bad8 (+ bad8 1))))
          (if (not (equal? (p8 'A 'B 'C 'D 'E 'F 'G 'H) '(A B C D E F G H))) (set! bad8 (+ bad8 1))))
        (guard (ex (#t (set! nlbad (+ nlbad 1))))
          (if (not (= 55 (let fib ((n 10) (a 0) (b 1)) (if (= n 0) a (fib (- n 1) b (+ a b))))))
              (set! nlbad (+ nlbad 1))))
        (spin (- n 1)))))
(spin 40000)
(display (list 'ARITY3 bad3 'ARITY4 bad4 'ARITY8 bad8 'NAMEDLET4 nlbad)) (newline)
(exit)
