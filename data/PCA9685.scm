;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
#| @name PCA9685 Interface

PCA9685 originally designed as a 16 channel LED controller, now used as a general-purpose PWM controller.

|#
(news "Loading PCA9685 Interface\n")

(define have-pca9685 (dict-ref? (current-environment) 'PCA9685.begin))

(news "Loading PCA9685 Interface 10\n")
(unless have-pca9685
  (define PCA9685.begin Lambda0)
  (define PCA9685.setChannelServoPulseDuration Lambda0)
  (define PCA9685.setChannelDutyCycle Lambda0)
  (define delay_ms Lambda0)
  )

(news "Loading PCA9685 Interface 30\n")

(define pca9685-info (2list->obj
		      `(
			;;device attributes
			(default-address #x5f)
			(servo-frequency 50.0)
			
			;;servo name, pin number, operating region pulse width min & max in us
			(Xservo  (0 500 2500))
			(Yservo  (1 1500 2500))	;can't go all the way down due to mechanical interference
			(Servo2  (2 500 2500))
			(Servo3  (3 500 2500))
			(Servo4  (4 500 2500))
			(Servo5  (5 500 2500))
			(Servo6  (6 500 2500))
			(Servo7  (7 100 2500))

			;;Motors are listed clockwise from fl, fr, rr, rl
			;;Motors are operated by duty cycle 0 .. 100% at the PWM level.
			(MotorPins ,'#((14 15) (13 12) (11 10) (8  9)))
			)
		      )
  )

(news "Loading PCA9685 Interface 35\n")

(PCA9685.begin (pca9685-info 'default-address))

(news "Loading PCA9685 Interface 40\n")
;;(PCA9685.setSingleDeviceToFrequency (dict-ref 'PCA9685-Info 'servo-frequency))

;;Set a channel to a pulsewidth given in microseconds.
;(define pcapw PCA9685.setChannelServoPulseDuration)

;;Return a (lambda (frac) ...) that will set the servo channel pulse width to the range -1..1, scaled into the operating region

(define (make-servo chan pwmin pwmax)
  (let* ((pwspan (- pwmax pwmin)))
    (lambda (plusminus1) (PCA9685.setChannelServoPulseDuration chan (+ pwmin (* (+ 0.5 (/ plusminus1 2.0)) pwspan))))
    )
  )

(news "Creating servos\n")

(define xservo
  (let ((xsv (apply make-servo (pca9685-info 'Xservo))))
    (lambda (plusminus1) (xsv (- plusminus1)))
    )
  )

(define yservo (apply make-servo (pca9685-info 'Yservo)))
(define servo2 (apply make-servo (pca9685-info 'Servo2)))
(define servo3 (apply make-servo (pca9685-info 'Servo3)))
(define servo4 (apply make-servo (pca9685-info 'Servo4)))
(define servo5 (apply make-servo (pca9685-info 'Servo5)))
(define servo6 (apply make-servo (pca9685-info 'Servo6)))
(define servo7 (apply make-servo (pca9685-info 'Servo7)))

(syslog "all servos created\n")

;; Startup: just CENTER the servos -- no exercise sweep.  The old sweep
;; (center/L/R/center/tilt-down/up/mid/ahead) cost 6 x (delay_ms 2000) = ~12 s
;; of every boot and moves nothing useful (and nothing at all on a flat battery).
(syslog "pan/tilt center (startup sweep removed)\n")
(xservo 0)
(yservo 0)

#|!
The motors respond over the full range of the PWM at 50 Hz (which is what it's set to).
Therefore we can use the duty cycle setter rather than scaling the pulsewidth over an application-specific operating range, as was done above.
|#
(define (Motor.setpins pin-fwd pin-bak frac)
  (if (< frac 0) (let ((tmp pin-fwd))
		   (set! pin-fwd pin-bak)
		   (set! pin-bak tmp)
		   (set! frac (- frac))
		   )
      )
  (PCA9685.setChannelDutyCycle pin-fwd (* 100.0 frac) 0)	;0 == no phase shift
  (PCA9685.setChannelDutyCycle pin-bak 0 0)
  )

;;!Last value written to each motor channel ('unset forces the first write).  The
;;!loop and the motion queue re-assert the same value every tick, so without this
;;!Motor.set would spam 8 I2C writes per loop -- the dominant loop cost (and far
;;!worse when the bus NAKs on a flat battery).  I2C only on change.
(define Motor.last (make-vector 4 'unset))

;;!Set the motor to the range -1..1.  Touches I2C ONLY when the command changes.
(define Motor.set
  (let ((allmotorpins (pca9685-info 'MotorPins)))
    (lambda (n plusminus1)
      (unless (eqv? plusminus1 (vector-ref Motor.last n))
	(vector-set! Motor.last n plusminus1)
	(let* ((motorpins (vector-ref allmotorpins n))
	       (frac (/ plusminus1 2.0)))
	  (Motor.setpins (car motorpins) (cadr motorpins) frac))))))

(define (Motor.set4 m0 m1 m2 m3) (Motor.set 0 m0) (Motor.set 1 m1) (Motor.set 2 m2) (Motor.set 3 m3))

(define (Motor.setAll speed)
  (letrec ((fn (lambda (Mz)
		 (Motor.set Mz speed)
		 (when (< Mz 3) (fn (+ 1 Mz)))
		 )
	       )
	   )
    (fn 0)
    )
  )

(Motor.setAll 0)

;;; Motion behaviour queue (P123 Ph3) -- replaces the bespoke MotionQueue/MotionExpiry.
;;; SHARED with the LLIP executor (llip-executor.scm); ticked by Motor.loop each main loop.
(define motor-bq (make-behavior-queue))

;;!Queue a timed motion: hold (m0 m1 m2 m3) for `duration` ms, then the next task runs.
(define (Motor.motion duration m0 m1 m2 m3)
  (motor-bq 'push (once-for duration (lambda () (Motor.set4 m0 m1 m2 m3)))))

;;!Tick the motion queue; call once per main-loop iteration.  Auto-stops the motors
;;!whenever the queue is idle (no motion queued) -- the safe default on empty.
(define Motor.loop
  (let ((was-idle #t))   ;; motors are 0 at load; auto-stop only on the running->idle EDGE,
    (lambda ()           ;; not every idle loop (that re-ran Motor.set4 = 5 wasted closure calls/loop)
      (motor-bq 'tick)
      (let ((idle (motor-bq 'idle?)))
        (when (and idle (not was-idle)) (Motor.set4 0 0 0 0))
        (set! was-idle idle)))))

;;!Emergency stop (P123 B3/B5): drop all queued/running motion and cut all four motors NOW.
(define (Motor.estop!)
  (motor-bq 'abort)
  (do ((i 0 (+ i 1))) ((= i 4)) (vector-set! Motor.last i 'unset))  ;; force the stop to the bus (bypass the change-cache)
  (Motor.set4 0 0 0 0))

(when have-pca9685
  (Motor.motion 1000 0.5 0.5 0.5 0.5)
  (Motor.motion 1000 0 0 0 0)
  (Motor.motion 1000 -0.5 -0.5 -0.5 -0.5)
  (Motor.motion 1000 0 0 0 0))

(syslog "PCA9685 loaded\n")
