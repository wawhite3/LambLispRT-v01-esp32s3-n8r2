;;; Copyright 2026 by Frobenius Norm LLC 2026-06-29 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; behaviors-tests.scm -- P121 Phase 1 unit tests for the cooperative behaviour
;;; queue (scm/core/Behaviors.scm).  Pure logic: runs on the Linux build with a
;;; MOCK clock (no hardware).  Covers the proposal's Phase-1 cases:
;;;   push/tick ordering, once-for timing, wait timing, cycle wrap, abort flush,
;;;   seq composition, idle? short-circuit.
;;;
;;; The behaviour-queue tasks read time via (millis); we shadow millis with a
;;; settable counter so timing is deterministic.  Behaviors.scm is already loaded
;;; at boot; its tasks resolve `millis` at call time, so tasks created here see
;;; the mock.

(define *bt-time* 0)
(define (millis) *bt-time*)               ;; shadow the builtin -- deterministic clock
(define (advance! dt) (set! *bt-time* (+ *bt-time* dt)))

(define *bt-pass* 0)
(define *bt-fail* 0)
(define (chk name expected got)
  (if (equal? expected got)
      (begin (set! *bt-pass* (+ *bt-pass* 1)) (display "PASS ") (display name) (newline))
      (begin (set! *bt-fail* (+ *bt-fail* 1))
             (display "FAIL ") (display name) (display ": expected ") (write expected)
             (display " got ") (write got) (newline))))

(define (tick-n bq n) (let lp ((i n)) (when (> i 0) (bq 'tick) (lp (- i 1)))))

;;; ---- 1. push/tick FIFO ordering --------------------------------------------
(set! *bt-time* 0)
(let ((log '()) (bq (make-behavior-queue)))
  (bq 'push (once (lambda () (set! log (cons 1 log)))))
  (bq 'push (once (lambda () (set! log (cons 2 log)))))
  (bq 'push (once (lambda () (set! log (cons 3 log)))))
  (chk "push-not-idle" #f (bq 'idle?))
  (tick-n bq 5)
  (chk "fifo-order"  '(1 2 3) (reverse log))
  (chk "fifo-idle-after" #t (bq 'idle?)))

;;; ---- 2. once-for timing: fires once, holds for the duration ----------------
(set! *bt-time* 0)
(let ((c 0) (bq (make-behavior-queue)))
  (bq 'push (once-for 100 (lambda () (set! c (+ c 1)))))
  (bq 'tick)                              ;; t=0: fire once, start holding
  (chk "oncefor-fired-once" 1 c)
  (advance! 50) (bq 'tick)
  (chk "oncefor-still-held" #f (bq 'idle?))
  (chk "oncefor-no-refire"  1 c)
  (advance! 50) (bq 'tick)                ;; t=100: deadline reached -> pop
  (chk "oncefor-done" #t (bq 'idle?))
  (chk "oncefor-fired-exactly-once" 1 c))

;;; ---- 3. wait: holds the head, releases the next task at the deadline -------
(set! *bt-time* 0)
(let ((fired #f) (bq (make-behavior-queue)))
  (bq 'push (wait 200))
  (bq 'push (once (lambda () (set! fired #t))))
  (bq 'tick) (chk "wait-blocks" #f fired)
  (advance! 199) (bq 'tick) (chk "wait-still-blocks" #f fired)
  (advance! 1) (bq 'tick)                 ;; t=200: wait pops
  (bq 'tick)                              ;; next tick runs the once
  (chk "wait-releases" #t fired))

;;; ---- 4. cycle: runs phase thunks in order, holding each, wrapping ----------
(set! *bt-time* 0)
(let ((log '()) (bq (make-behavior-queue)))
  (bq 'push (cycle (list 100 (lambda () (set! log (cons 'A log))))
                   (list 100 (lambda () (set! log (cons 'B log))))))
  (bq 'tick)                              ;; t=0 -> A
  (advance! 100) (bq 'tick)               ;; t=100 -> B
  (advance! 100) (bq 'tick)               ;; t=200 -> wrap to A
  (chk "cycle-wrap" '(A B A) (reverse log))
  (chk "cycle-never-pops" #f (bq 'idle?)))

;;; ---- 5. abort: drops the running task and flushes the queue ----------------
(set! *bt-time* 0)
(let ((ran #f) (bq (make-behavior-queue)))
  (bq 'push (once-for 1000 (lambda () 'noop)))   ;; long-running head
  (bq 'push (once (lambda () (set! ran #t))))     ;; queued behind
  (bq 'tick)                                       ;; start the head
  (chk "abort-busy-before" #f (bq 'idle?))
  (bq 'abort)
  (chk "abort-idle-after" #t (bq 'idle?))
  (tick-n bq 3)
  (chk "abort-flushed-queued" #f ran))             ;; the queued task never ran

;;; ---- 6. seq: several sub-tasks occupy ONE slot, run in order ---------------
(set! *bt-time* 0)
(let ((log '()) (bq (make-behavior-queue)))
  (bq 'push (seq (once (lambda () (set! log (cons 'x log))))
                 (once (lambda () (set! log (cons 'y log))))
                 (once (lambda () (set! log (cons 'z log))))))
  (tick-n bq 6)
  (chk "seq-order" '(x y z) (reverse log))
  (chk "seq-one-slot-done" #t (bq 'idle?)))

;;; ---- 7. idle? short-circuit ------------------------------------------------
(let ((bq (make-behavior-queue)))
  (chk "idle-empty" #t (bq 'idle?))
  (bq 'push (behavior-hold))
  (chk "idle-after-push" #f (bq 'idle?))
  (bq 'tick)
  (chk "idle-hold-stays-busy" #f (bq 'idle?))
  (bq 'abort)
  (chk "idle-after-abort" #t (bq 'idle?)))

(display "behaviors-tests: ") (display *bt-pass*) (display " pass, ")
(display *bt-fail*) (display " fail") (newline)
