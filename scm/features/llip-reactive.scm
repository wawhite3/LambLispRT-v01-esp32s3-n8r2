;;; Copyright 2026 by Frobenius Norm LLC 2026-06-22 09:00:00
;;; Free for non-commercial use. Commercial use requires a license.
(info "Loading llip-reactive\n")

#|!
Reactive layer + safety (P123 B5) -- the REACTIVE tier: lowest in the stack,
highest in priority.  Safety lives on the 4WD, not the planner; the robot must
stay safe even when the plan is wrong, stale, or the link drops.

Run (reactive-tick!) every main-loop iteration BEFORE the motor tick (Motor.loop), so a reflex
or the deadman can VETO the executor before it advances another move.  A trip
calls (move-estop!) -- abort the motion queue + cut the motors -- raises a robot
signal, and reports an aborted telemetry frame so the deliberative layer re-plans.
The plan supplies INTENT; this layer GUARANTEES safety.

Depends on: Sonar.scm (Sonar.latest, metres)
            llip-executor.scm (move-estop!, llip-report)
            llip-signals.scm (robot-signal!)  Leds.scm (led-clear!)
|#

;;; ---- tunables -- CALIBRATE on the real 4WD ----
(define reflex-obstacle-m 0.15)   ; trip: front sonar below this (metres)
(define reflex-clear-m    0.25)   ; re-arm: front sonar back above this (hysteresis)
(define deadman-ms        1500)   ; halt if no valid frame within this many ms

;;!Preempt the current plan: drop queued/running moves, cut the motors, raise a
;;!signal, and report an aborted frame up so the planner can react (Ph6).
(define (reactive-veto! signal reason)
  (move-estop!)
  (robot-signal! signal)
  (llip-report 'aborted reason))

;;; ---- obstacle reflex (front sonar) -----------------------------------------
;;; Edge-triggered with hysteresis: veto ONCE when an obstacle appears; re-arm
;;; only after it clears, so a re-plan (back up / turn) can run without being
;;; estopped every tick.
(define reflex-obstacle-latched #f)
(define (reactive-reflexes!)
  (let ((d Sonar.latest))
    (cond ((and (not reflex-obstacle-latched) (> d 0) (< d reflex-obstacle-m))
           (set! reflex-obstacle-latched #t)
           (reactive-veto! 'obstacle 'obstacle-front))
          ((and reflex-obstacle-latched (> d reflex-clear-m))
           (set! reflex-obstacle-latched #f)))))

;;; ---- deadman / heartbeat ---------------------------------------------------
;;; Fed by the frame-receive path (move-run-frame!).  If no valid frame arrives
;;; within deadman-ms, halt and flag.  Latched so we halt once; clears the sticky
;;; deadman LED on recovery.
(define deadman-last    #f)        ; millis of last received frame, #f = never fed
(define deadman-latched #f)
;;!Call when an LLIP frame arrives -- resets the heartbeat.
(define (llip-feed-deadman!) (set! deadman-last (millis)))
(define (reactive-deadman!)
  (when deadman-last
    (if (> (- (millis) deadman-last) deadman-ms)
        (unless deadman-latched                ; trip once
          (set! deadman-latched #t)
          (move-estop!)
          (robot-signal! 'deadman))
        (when deadman-latched                  ; recovered: clear the sticky LED
          (set! deadman-latched #f)
          (led-clear!)))))

;;!Run the reactive vetoes; call BEFORE the motor tick (Motor.loop) every main-loop iteration.
(define (reactive-tick!)
  (reactive-reflexes!)
  (reactive-deadman!))

(info "llip-reactive Loaded\n")
