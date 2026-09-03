;;; Copyright 2026 by Frobenius Norm LLC 2026-06-03 16:30:00
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "Loading Buzzer\n")

(define have-Buzzer-pin (dict-ref? Pins 'pin-buzzer))
(define have-Buzzer have-Buzzer-pin)
(syslog "Buzzer pin ~a\n" have-Buzzer-pin)

(unless have-Buzzer
  (define tone Lambda0)
  )

(define Buzzer.pin (if have-Buzzer (cdr have-Buzzer-pin) #f))
(define Buzzer.tone tone)
;;; Buzzer behaviour queue (P123 Ph2) -- replaces the bespoke Buzzer.queue (TimedQueue).
(define Buzzer.bq (make-behavior-queue))

(define (Buzzer.on freq) (Buzzer.tone Buzzer.pin (floor freq)))
(define (Buzzer.off) (Buzzer.tone Buzzer.pin 0))

;; A single short click -- a quiet acknowledgement.  Queued (non-blocking).
;; NOTE: the old body (Buzzer.on)(delay 8)(Buzzer.off) was BROKEN -- `delay` here is the
;; R7RS promise macro (rxrs_promises.scm shadows the C++ sleep), so (delay 8) built and
;; discarded a promise and the 8 ms hold never happened (tone on+off in the same breath).
(define (Buzzer.click)
  (behavior-queue-seq Buzzer.bq
    (lambda () (Buzzer.on 4000) #t)   ; one-and-done: tone on
    (wait 8)                          ; hold 8 ms at the queue head (non-blocking)
    (lambda () (Buzzer.off) #t)))     ; one-and-done: tone off

(define (Buzzer.onoff freq on-time off-time)
  (when (> on-time 0)  (Buzzer.bq 'push (once-for (floor on-time)  (lambda () (Buzzer.on freq)))))
  (when (> off-time 0) (Buzzer.bq 'push (once-for (floor off-time) Buzzer.off)))
  )

(define (Buzzer.offon freq off-time on-time)
  (when (> off-time 0) (Buzzer.bq 'push (once-for (floor off-time) Buzzer.off)))
  (when (> on-time 0)  (Buzzer.bq 'push (once-for (floor on-time) (lambda () (Buzzer.on freq)))))
  )

(if have-Buzzer
  (define (Buzzer.chirp from to nsteps interval_ms)
    (let* ((f_range   (- to from 0.0))		;0.0 coerces Real_t
	   (f_quantum (/ f_range nsteps))	;freq step change
	   (t_quantum (/ interval_ms nsteps))	;time step change
	   (queue-step (lambda (freq) (Buzzer.onoff freq t_quantum 0)))
	   (queue-all  (lambda (n)
			 (let ((f (+ from (* n f_quantum))))
			   (when (<= f to)
			     (queue-step f)
			     (queue-all (+ 1 n))))))
	   )
      (queue-all 0)
      (Buzzer.bq 'push (once-for 1 (lambda () (Buzzer.off))))
      nil))
  (define (Buzzer.chirp . ignord) nil))

(define (Buzzer.arf) (Buzzer.chirp 60 4000 100 1000))

(define (Buzzer.loop)
  (Buzzer.bq 'tick)
  )

(news "Click\n")
(Buzzer.click)
(news "done Click\n")

(news "Buzzer loaded\n")
