;;; Copyright 2026 by Frobenius Norm LLC 2026-06-21 15:44:00
;;; Free for non-commercial use. Commercial use requires a license.
(info "Loading llip-executor\n")

#|!
4WD Move DSL executor (P123 B3) -- the EXECUTIVE tier.  Turns a validated LLIP
move program into motor action on a cooperative motion behaviour queue.

SAFETY -- interpret, NOT eval: a fixed `case` dispatch (verb -> binder) IS the
restricted environment.  No move program can express anything but the seven
verbs; an unknown verb is an error, not arbitrary code.  Each move becomes one
`once-for` task driving `Motor.set4` through the behaviour queue, so a long timed
move holds its slot and never blocks the main loop -- and the reactive layer can
preempt it with `(move-estop!)` (aborts motor-bq + cuts motors) at any instant.

Depends on: Behaviors.scm (make-behavior-queue, once, once-for)
            PCA9685.scm   (Motor.set4, Motor.estop!)
            llip-frame.scm (llip-program-valid?, llip-make-telemetry, llip-mp-*)
            llip-signals.scm (robot-signal!)
|#

;;; ---- calibration -- MEASURE on the real 4WD (see P123 "Hardware calibration")
;;; Motor.set halves its arg (PCA9685.scm:128), already folded into these values.
(define move-drive-speed 0.6)     ; -1..1 fed to Motor.set4 for forward/back   -- CALIBRATE
(define move-turn-speed  0.6)     ; -1..1 for in-place turns                    -- CALIBRATE
(define move-turn-dps    180)     ; degrees per second at move-turn-speed       -- MEASURE
(define move-mps         0.30)    ; metres per second at move-drive-speed       -- MEASURE

;;!Convert a unit-tagged magnitude (unit value) to a duration in ms.
;;!Timed (s) is exact; metric (deg/m/cm) is open-loop dead-reckoning pending odometry.
(define (move-mag->ms mag)
  (let ((u (car mag)) (v (cadr mag)))
    (cond ((eq? u 's)   (* v 1000))
          ((eq? u 'deg) (* (/ v move-turn-dps) 1000))
          ((eq? u 'm)   (* (/ v move-mps) 1000))
          ((eq? u 'cm)  (* (/ (/ v 100.0) move-mps) 1000))
          (else 0))))

;;!Tank drive: left side, right side -> the four motors.
;;; MotorPins are CLOCKWISE fl,fr,rr,rl (PCA9685.scm:38), so LEFT = m0(fl),m3(rl)
;;; and RIGHT = m1(fr),m2(rr): hence (Motor.set4 l r r l).
;;; *** CALIBRATE: command (move-tank! 0.5 0.5); if it doesn't track straight,
;;; permute order/signs until it does, then fix this mapping. ***
(define (move-tank! l r) (Motor.set4 l r r l))

;;; ---- per-verb binders: each enqueues ONE timed task on the motion queue -----
(define (mv-forward    bq mag) (bq 'push (once-for (move-mag->ms mag) (lambda () (move-tank! move-drive-speed move-drive-speed)))))
(define (mv-backward   bq mag) (bq 'push (once-for (move-mag->ms mag) (lambda () (move-tank! (- move-drive-speed) (- move-drive-speed))))))
(define (mv-turn-left  bq mag) (bq 'push (once-for (move-mag->ms mag) (lambda () (move-tank! (- move-turn-speed) move-turn-speed)))))
(define (mv-turn-right bq mag) (bq 'push (once-for (move-mag->ms mag) (lambda () (move-tank! move-turn-speed (- move-turn-speed))))))
(define (mv-wait       bq mag) (bq 'push (once-for (move-mag->ms mag) (lambda () (move-tank! 0 0)))))
(define (mv-stop       bq)     (bq 'push (once (lambda () (move-tank! 0 0)))))
(define (mv-dock       bq)     (bq 'push (once (lambda () (move-tank! 0 0) (robot-signal! 'dock)))))

;;!The dispatch IS the sandbox: verb -> binder, nothing else is reachable.
(define (move-exec! bq m)
  (case (car m)
    ((forward)   (mv-forward    bq (cadr m)))
    ((backward)  (mv-backward   bq (cadr m)))
    ((turn-left) (mv-turn-left  bq (cadr m)))
    ((turn-right)(mv-turn-right bq (cadr m)))
    ((wait)      (mv-wait       bq (cadr m)))
    ((stop)      (mv-stop       bq))
    ((dock)      (mv-dock       bq))
    (else (error "move-exec!: unknown verb" (car m)))))

;;; ---- telemetry "up" channel ------------------------------------------------
;;; The executor tracks seq/move-index so it can report status.  Transport is
;;; Ph6 (closed loop); for now `llip-emit` just prints -- override it to wire a link.
(define move-cur-seq   0)
(define move-cur-index 0)
(define llip-emit (lambda (frame) (news "LLIP-UP ~a\n" frame)))
(define (llip-report status reason)
  (llip-emit (llip-make-telemetry move-cur-seq move-cur-index status reason '())))
(define (llip-report-aborted reason) (llip-report 'aborted reason))

;;; ---- the shared motion behaviour queue -------------------------------------
;;; The executor drives motor-bq, defined in PCA9685.scm (core) and ticked by
;;; Motor.loop in the main loop -- so the legacy Motor.motion and these LLIP moves
;;; share ONE motion queue.

;;!Reactive e-stop: drop every queued/running move AND cut the motors (Motor.estop!
;;!aborts motor-bq + zeroes the motors).  The reactive layer (B5) calls this, then
;;!raises the appropriate robot-signal!.
(define (move-estop!) (Motor.estop!))

;;; ---- run a program ---------------------------------------------------------
;;!Execute a validated move list on `bq`.  Reject the WHOLE program if any move
;;!is invalid (defence in depth -- the planner is grammar-constrained, but the
;;!4WD never trusts the link).
(define (move-run-program! bq moves)
  (if (llip-program-valid? moves)
      (begin (robot-signal! 'running)
             (for-each (lambda (m) (move-exec! bq m)) moves))
      (begin (robot-signal! 'bad-move)
             (llip-report-aborted 'invalid-program))))

;;!Execute a full (move-program (seq N) (ttl T) (moves (...))) frame on the
;;!motion queue: record seq for telemetry, then run its moves.
(define (move-run-frame! frame)
  (llip-feed-deadman!)                 ;; a received frame proves the link is alive (B5 heartbeat)
  (if (llip-move-program? frame)
      (begin (set! move-cur-seq (llip-mp-seq frame))
             (set! move-cur-index 0)
             (move-run-program! motor-bq (llip-mp-moves frame)))
      (begin (robot-signal! 'bad-move)
             (llip-report-aborted 'invalid-frame))))

(info "llip-executor Loaded\n")
