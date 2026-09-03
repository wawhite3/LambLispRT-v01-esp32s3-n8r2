;;; Copyright 2026 by Frobenius Norm LLC 2026-05-28 20:30:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; B16 regression: GC write barrier correctness during syntax-rules
;;; ellipsis expansion.
;;;
;;; Root cause: set_car_bang / set_cdr_bang / vector_set_bang / reverse_bang
;;; must push the OLD value to the GC markstack during the mark phase
;;; (Yuasa snapshot-at-beginning invariant) when old_val->gc_state() < gcst_issued.
;;; Failing to do so causes a reachable cell to be swept → "both Mfree & Mused"
;;; in integrity_check.
;;;
;;; Fix applied: 2026-04-19.  This file is the green regression test — it
;;; locks in the fix by running the exact scenarios that triggered the
;;; corruption and asserting (lamb-integrity-check) returns #t after each.
;;;
;;; Scenarios:
;;;   1. cond chain — recursive ellipsis expansion (the original trigger)
;;;   2. let lockstep ellipsis — ((var init) ...) binding construction
;;;   3. and/or — recursive ellipsis with let-introduced gensyms
;;;   4. vector-set! during mark phase — exercises vector_set_bang barrier
;;;   5. combined stress — gc! before and after every expansion, 50 rounds
;;; =======================================================================

(define (check-true name actual)
  (if actual
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=#t got=~a\n" name actual)))

(define (check name expected actual)
  (if (equal? expected actual)
      (printf "PASS ~a\n" name)
      (printf "FAIL ~a expected=~a got=~a\n" name expected actual)))

;;; Allocation pressure: build and hold a list of N vectors, forcing the GC
;;; to work.  Returns the list length (keeps the vectors live until called,
;;; then they become collectable).
(define (alloc-pressure n)
  (let loop ((i n) (acc '()))
    (if (= i 0) (length acc)
        (loop (- i 1) (cons (vector i (* i 2) (* i 3)) acc)))))

;;; -----------------------------------------------------------------------
;;; Define test macros (use C++ syntax-rules — always available).
;;; -----------------------------------------------------------------------

(define my-cond
  (syntax-rules (else)
    ((_ (else e ...))           (begin e ...))
    ((_ (test e ...) rest ...)  (if test (begin e ...) (my-cond rest ...)))))

(define my-let
  (syntax-rules ()
    ((_ ((var init) ...) body ...)
     ((lambda (var ...) body ...) init ...))))

(define my-and
  (syntax-rules ()
    ((_)           #t)
    ((_ e)         e)
    ((_ e1 e2 ...) (let ((t e1)) (if t (my-and e2 ...) #f)))))

(define my-or
  (syntax-rules ()
    ((_)           #f)
    ((_ e)         e)
    ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or e2 ...))))))

;;; -----------------------------------------------------------------------
;;; 1. cond chain — the original B16 trigger
;;;
;;; Three-level recursive expansion: (my-cond (#f) (#f) (else 'c)) forces
;;; reverse_bang on the rest-binding list twice while the mark phase may be
;;; active from the preceding alloc-pressure call.
;;; -----------------------------------------------------------------------

(printf "--- B16/1: cond chain ---\n")

(let loop ((i 50))
  (when (> i 0)
    (alloc-pressure 80)
    (let ((r1 (my-cond (#f 'a) (#f 'b) (else 'c)))
          (r2 (my-cond (#t 'yes) (else 'no)))
          (r3 (my-cond (#f 1) (#f 2) (#f 3) (else 4))))
      (if (not (and (equal? r1 'c) (equal? r2 'yes) (equal? r3 4)))
          (printf "FAIL B16/1 iter ~a: r1=~a r2=~a r3=~a\n" i r1 r2 r3)))
    (loop (- i 1))))

(gc!)
(check-true "B16/1 integrity after cond-chain" (lamb-integrity-check))

;;; -----------------------------------------------------------------------
;;; 2. let lockstep ellipsis
;;;
;;; ((var init) ...) pattern requires pairing vars and inits — the binding
;;; list construction uses set_cdr_bang inside the sr-match accumulation.
;;; Three-binding form is the most stressful.
;;; -----------------------------------------------------------------------

(printf "--- B16/2: let lockstep ellipsis ---\n")

(let loop ((i 50))
  (when (> i 0)
    (alloc-pressure 80)
    (let ((r1 (my-let ((x 3) (y 4)) (* x y)))
          (r2 (my-let ((a 1) (b 2) (c 3)) (+ a b c)))
          (r3 (my-let ((p 10) (q 20) (r 30)) (list p q r))))
      (if (not (and (= r1 12) (= r2 6) (equal? r3 '(10 20 30))))
          (printf "FAIL B16/2 iter ~a: r1=~a r2=~a r3=~a\n" i r1 r2 r3)))
    (loop (- i 1))))

(gc!)
(check-true "B16/2 integrity after let-ellipsis" (lamb-integrity-check))

;;; -----------------------------------------------------------------------
;;; 3. and/or recursive ellipsis with gensym hygiene
;;;
;;; Each expansion of (my-and e1 e2 ...) introduces a gensym for 't'.
;;; The gensym cell is a fresh allocation; set_car_bang on the let binding
;;; frame exercises the car write barrier during marking.
;;; -----------------------------------------------------------------------

(printf "--- B16/3: and/or recursive ---\n")

(let loop ((i 50))
  (when (> i 0)
    (alloc-pressure 80)
    (let ((r1 (my-and 1 2 3))
          (r2 (my-and #f 2 3))
          (r3 (my-or #f #f 42))
          (r4 (my-or 1 2 3))
          (r5 (my-and (my-or #f 5) (my-and 1 2 3))))
      (if (not (and (= r1 3) (equal? r2 #f) (= r3 42) (= r4 1) (= r5 3)))
          (printf "FAIL B16/3 iter ~a: r1=~a r2=~a r3=~a r4=~a r5=~a\n"
                  i r1 r2 r3 r4 r5)))
    (loop (- i 1))))

(gc!)
(check-true "B16/3 integrity after and/or" (lamb-integrity-check))

;;; -----------------------------------------------------------------------
;;; 4. vector-set! during mark phase
;;;
;;; Directly exercises the vector_set_bang Yuasa barrier.  Allocate vectors,
;;; trigger GC pressure (leaving the mark phase active), then mutate the
;;; vector elements while the marker may not have visited them yet.
;;; -----------------------------------------------------------------------

(printf "--- B16/4: vector-set! during mark ---\n")

(let loop ((i 50))
  (when (> i 0)
    ;; Allocate pressure to advance the GC into mark phase.
    (alloc-pressure 80)
    ;; Allocate a vector before the mark phase, then mutate it (exercises
    ;; vector_set_bang old-value push for gcst_idle cells).
    (let ((v (make-vector 8 #f)))
      (vector-set! v 0 (cons 1 2))
      (vector-set! v 1 (cons 3 4))
      (vector-set! v 2 'sym)
      (vector-set! v 3 (make-vector 3 99))
      ;; Overwrite again — triggers barrier on the just-written cons cells.
      (vector-set! v 0 (cons 10 20))
      (vector-set! v 3 (list 1 2 3))
      (let ((r (+ (car (vector-ref v 0))
                  (car (vector-ref v 1)))))
        (if (not (= r 13))
            (printf "FAIL B16/4 iter ~a: r=~a\n" i r))))
    (loop (- i 1))))

(gc!)
(check-true "B16/4 integrity after vector-set!" (lamb-integrity-check))

;;; -----------------------------------------------------------------------
;;; 5. Combined stress: gc! before and after every expansion
;;;
;;; This is the reproduction attempt from the P88 registry (2026-05-25):
;;; force a complete GC before every macro expansion so that the expansion
;;; itself runs in a fresh mark phase, maximising the chance that any
;;; set_cdr_bang during reverse_bang encounters gcst_idle cells that the
;;; marker hasn't yet visited.
;;; -----------------------------------------------------------------------

(printf "--- B16/5: gc! before/after every expansion ---\n")

(let loop ((i 50))
  (when (> i 0)
    (gc!)
    (alloc-pressure 60)
    (let ((r1 (my-cond (#f 'a) (#f 'b) (else 'c)))
          (r2 (my-let ((x 3) (y 4)) (* x y)))
          (r3 (my-and 1 2 3))
          (r4 (my-or #f 42)))
      (gc!)
      (if (not (and (equal? r1 'c) (= r2 12) (= r3 3) (= r4 42)))
          (printf "FAIL B16/5 iter ~a: r1=~a r2=~a r3=~a r4=~a\n" i r1 r2 r3 r4))
      (if (not (lamb-integrity-check))
          (printf "FAIL B16/5 integrity at iter ~a\n" i)))
    (loop (- i 1))))

(check-true "B16/5 integrity after combined stress" (lamb-integrity-check))

(printf "--- B16 regression done ---\n")
