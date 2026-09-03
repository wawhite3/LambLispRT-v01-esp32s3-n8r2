;;; B154 arity probe -- does the fault need the 4..7 binding 2-BUCKET hash frame?
;;; dict_add_keyval_frame: 1..3 bindings -> alist; 4..7 -> mk_hashtbl(2) T_SVEC_IMM (#frame(2));
;;; 8+ -> mk_hashtbl(count) T_SVEC2N_HEAP.  Same workload at each arity, allocation-heavy so the
;;; incremental GC runs inside the calls.  A binding that goes unbound raises -- counted, not fatal.
(define bad3 0) (define bad4 0) (define bad8 0)
(define (p3 a b c)             (list a b c))
(define (p4 a b c d)           (list a b c d))
(define (p8 a b c d e f g h)   (list a b c d e f g h))
(define (spin n)
  (if (> n 0)
      (begin
        (guard (ex (#t (set! bad3 (+ bad3 1))))
          (if (not (equal? (p3 'A 'B 'C) '(A B C))) (set! bad3 (+ bad3 1))))
        (guard (ex (#t (set! bad4 (+ bad4 1))))
          (if (not (equal? (p4 'A 'B 'C 'D) '(A B C D))) (set! bad4 (+ bad4 1))))
        (guard (ex (#t (set! bad8 (+ bad8 1))))
          (if (not (equal? (p8 'A 'B 'C 'D 'E 'F 'G 'H) '(A B C D E F G H))) (set! bad8 (+ bad8 1))))
        (spin (- n 1)))))
(spin 40000)
(display (list 'ARITY3 bad3 'ARITY4 bad4 'ARITY8 bad8)) (newline)
;; named-let form from run_024: 4 bindings (fib n a b), the shape that actually failed
(define nlbad 0)
(define (nlspin n)
  (if (> n 0)
      (begin
        (guard (ex (#t (set! nlbad (+ nlbad 1))))
          (if (not (= 55 (let fib ((n 10) (a 0) (b 1)) (if (= n 0) a (fib (- n 1) b (+ a b))))))
              (set! nlbad (+ nlbad 1))))
        (nlspin (- n 1)))))
(nlspin 20000)
(display (list 'NAMEDLET4 nlbad)) (newline)
(exit)
