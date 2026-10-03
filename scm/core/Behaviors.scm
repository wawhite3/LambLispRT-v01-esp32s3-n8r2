;;; Copyright 2026 by Frobenius Norm LLC 2026-06-19 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
(info "Loading Behaviors\n")

#|!
General cooperative task / behaviour queue.

A *task* is a step-thunk: a procedure of no arguments, called once per main-loop
tick, that returns #t when finished (pop it) or #f to keep running.  That return
value is the ENTIRE protocol -- you queue bare lambdas, no wrappers needed:

  (bq 'push (lambda () (led-on) #t))          ; one-and-done   (does it, pops)
  (bq 'push (lambda () (button-pressed?)))    ; wait for event (pops when true)
  (bq 'push (wait 200))                        ; wait a time    (the one helper)

A multi-step behaviour is just several of these pushed in order.  The only timing
that isn't trivial to inline is the drift-free clock, so `wait` is the one helper;
time is merely one kind of predicate (the file's `while-do` makes this explicit).

Cooperative and non-blocking: each `tick` runs one slice, interleaving with the
rest of the main loop (sensors, comms, reflexes).  Motor moves, the LLIP executor
(P119), and reactive behaviours are all just consumers of this module.
|#

;;; ---- the universal constructor ----------------------------------------

;;!Run (action) every tick while (pred); done when (pred) is false. The basis of all below.
(define (while-do pred action)
  (lambda ()
    (if (pred) (begin (action) #f) #t)))

;;!Run (action) every tick until (pred) becomes true (do-while-not).
(define (until-do pred action)
  (while-do (lambda () (not (pred))) action))

;;; ---- one-shot / completion --------------------------------------------

;;!Do (action) exactly once, then pop.
(define (once action)
  (lambda () (action) #t))

;;!A task that does nothing and never finishes (pure hold / placeholder).
(define (behavior-hold)
  (lambda () #f))

;;; ---- time-based wrappers (all built on while-do) ----------------------
;;; t-end is captured lazily on the first tick, so a task may sit queued a while
;;; before its clock starts.

;;!Run (action) every tick for `ms` milliseconds (do-while-time).
(define (for-ms ms action)
  (let ((t-end #f))
    (while-do
     (lambda ()
       (unless t-end (set! t-end (+ (millis) ms)))
       (< (millis) t-end))
     action)))

;;!Do (action) once, then hold the slot for `ms` ms before popping.
;;!The "do once then run down the timer" pattern (e.g. a single motor move).
(define (once-for ms action)
  (let ((t-end #f) (fired #f))
    (while-do
     (lambda ()
       (unless t-end (set! t-end (+ (millis) ms)))
       (< (millis) t-end))
     (lambda ()
       (unless fired (action) (set! fired #t))))))

;;!Wait `ms` ms, then do (action) once and pop (deferred action / start delay).
(define (after-ms ms action)
  (let ((t-end #f))
    (lambda ()
      (unless t-end (set! t-end (+ (millis) ms)))
      (if (< (millis) t-end)
          #f
          (begin (action) #t)))))

;;!Hold the slot for `ms` ms doing nothing (pure delay / inter-move gap).
(define (wait-ms ms)
  (after-ms ms (lambda () #f)))

;;!THE canonical timer task: hold the queue head for `ms` ms, then pop (#t).  The
;;!deadline is latched on the FIRST tick at the head -- so a wait queued behind other
;;!tasks doesn't start its clock until it actually runs -- and compared against live
;;!(millis), so it never drifts.  Together with bare step-thunks for events and
;;!one-shots this is the WHOLE timing vocabulary; the older for-ms / once-for /
;;!after-ms / wait-ms are just `wait` + a step-thunk in disguise.
(define (wait ms)
  (let ((end #f))
    (lambda ()
      (unless end (set! end (+ (millis) ms)))   ;; latch deadline once, when we reach the head
      (>= (millis) end))))                        ;; live compare -> drift-free

;;; ---- repeating behaviours (never pop; ended only by queue abort) -------

;;!Run (action) every tick, forever.
(define (forever action)
  (while-do (lambda () #t) action))

;;!Cycle through phases forever; each phase is (list duration-ms thunk).  Runs a
;;!phase's thunk once, holds duration-ms, then advances, wrapping at the end.  A
;;!whole blink/animation is ONE task instead of many queued frames -- e.g.
;;!  (cycle (list 250 WS2812.navLights) (list 250 WS2812.off))   ; blink forever
(define (cycle . phases)
  (let ((ps '()) (t-end #f))
    (lambda ()
      (when (or (not t-end) (>= (millis) t-end))
        (when (null? ps) (set! ps phases))     ;; wrap around
        (let ((ph (car ps)))
          ((cadr ph))
          (set! t-end (+ (millis) (car ph)))
          (set! ps (cdr ps))))
      #f)))                                     ;; never done

;;; ---- sequential composition -------------------------------------------

;;!Compose sub-tasks into ONE task: run them in order, advancing to the next as
;;!each returns #t; done (#t) when all are consumed.  Lets a multi-step animation
;;!or move-sequence occupy a SINGLE queue slot -- e.g. a bounded N-blink built
;;!from alternating `once-for` tasks (see Leds.scm `led-blink`).  One sub-task
;;!runs per tick-slice; advancing to the next happens on the tick after it finishes.
(define (seq . tasks)
  (let ((ts tasks))
    (lambda ()
      (if (null? ts)
          #t
          (begin
            (when ((car ts)) (set! ts (cdr ts)))   ;; head finished -> advance
            (null? ts))))))                         ;; #t once the last is consumed

;;; ---- the queue --------------------------------------------------------

#|!
make-behavior-queue returns a message-dispatch procedure; drive it once per
main-loop iteration with ('tick):

  (define bq (make-behavior-queue))
  (bq 'push (once-for 1000 (lambda () (Motor.setAll 0.5))))   ; enqueue a task
  (bq 'tick)                                                  ; call every loop
  (bq 'abort)                                                 ; flush + drop current
  (bq 'idle?)                                                 ; #t when queue empty

A task occupies the head until its own step-thunk returns #t, so a long timed
move is never popped early.  `abort` is the reactive e-stop: drop the running
task and flush everything behind it.
|#
(define (make-behavior-queue)
  (let ((q (Queue))      ;; FIFO of step-thunks; (q x) enqueues, (q) dequeues or #f
        (current #f)     ;; step-thunk currently running, or #f when queue empty
        (n 0))           ;; # tasks waiting in q (excludes current); lets an idle tick short-circuit O(1)
    (lambda (msg . args)
      (case msg
        ((push) (q (car args)) (set! n (+ n 1)))
        ((tick)
         ;; idle fast path: nothing running and nothing queued -> do nothing, no (q) dequeue call
         (when (or current (> n 0))
           (unless current (set! current (q)) (set! n (- n 1)))
           (when (and current (current))   ;; have a task and its step finished -> pop and pull next
             (if (> n 0)
                 (begin (set! current (q)) (set! n (- n 1)))
                 (set! current #f)))))
        ((abort)
         (set! current #f)
         (let drain () (when (> n 0) (q) (set! n (- n 1)) (drain))))
        ((idle?) (and (not current) (= n 0)))
        (else (error "behavior-queue: unknown message" msg))))))

;;!Push several tasks in order (convenience over repeated 'push).
(define (behavior-queue-seq bq . tasks)
  (for-each (lambda (tk) (bq 'push tk)) tasks))
