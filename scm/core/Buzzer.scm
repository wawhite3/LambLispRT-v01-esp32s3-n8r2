;;; Copyright 2026 by Frobenius Norm LLC 2026-06-03 16:30:00
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "Loading Buzzer\n")

(define have-Buzzer-pin (dict-ref? Pins 'pin-buzzer))
(define have-Buzzer have-Buzzer-pin)
(syslog "Buzzer pin ~a\n" have-Buzzer-pin)

(unless have-Buzzer
  ;;; B259: `tone` IS NOT STUBBED HERE.  It is a core commonio builtin, not a Buzzer procedure,
  ;;; and stubbing it from this guard would disable tone() image-wide on any board without a
  ;;; buzzer -- the same defect PCA9685.scm had with delay_ms.  Stub only this module's own names.
  )

(define Buzzer.pin (if have-Buzzer (cdr have-Buzzer-pin) #f))
(define Buzzer.tone tone)
;;; Buzzer behaviour queue (P123 Ph2) -- replaces the bespoke Buzzer.queue (TimedQueue).
(define Buzzer.bq (make-behavior-queue))

;;; ===========================================================================================
;;; THE BUZZER IS SILENT BY DEFAULT (owner, 2026-09-25: "stop all beeping").
;;; ===========================================================================================
;;;
;;; GATED AT `Buzzer.on`, WHICH IS THE ONLY PLACE A TONE CAN START.  Everything audible goes
;;; through here -- `Buzzer.click`, `Buzzer.onoff`, `Buzzer.offon`, `Buzzer.chirp`, and any future
;;; caller.  One gate at the bottom cannot be bypassed; a rule applied per caller holds only until
;;; the next caller is written, which is exactly how this went wrong.
;;;
;;; WHY IT CAME TO THIS, recorded so the default is not quietly reverted as over-cautious.  The
;;; buzzer queue had never drained on this vehicle, because `Buzzer.loop` was never ticked -- the
;;; 4WD had no mission loop at all ([B625]).  Restoring that loop made every queued tone audible
;;; for the first time in months, and what came out was: a one-second 60->4000 Hz siren from
;;; `guard-dog` ([B632]), and TWO boot clicks at 4 kHz, because this file clicked on load and
;;; `setup.scm` clicked again.  Each was fixed in turn and each fix revealed the next noise, which
;;; is the signature of treating symptoms.  Silence is the correct default for a device on a bench
;;; beside people; a board that wants to be heard can say so.
;;;
;;; `Buzzer.off` is deliberately NOT gated -- silencing must work even when sound is disabled, or
;;; a tone started before the setting changed could never be stopped.
;;; DEFAULT IS NOW ON (owner, 2026-09-25: "2 short clicks at low frequency at startup").  It was
;;; briefly 0 while the noise was being tracked down; the gate stays because it is the only place
;;; that can guarantee silence, and `(setting 'buzzer 0)` still silences the board outright.
(define Buzzer.enabled (positive? (setting 'buzzer 1)))

(define (Buzzer.on freq)
  (when Buzzer.enabled (Buzzer.tone Buzzer.pin (floor freq))))
(define (Buzzer.off) (Buzzer.tone Buzzer.pin 0))

;;; ===========================================================================================
;;; HARD CAP: NO TONE LONGER THAN `Buzzer.max-on-ms` (owner, 2026-09-25).
;;; ===========================================================================================
;;;
;;; The owner's instruction after a bench incident is exact: "no more than 1 chirp <10 ms".  This
;;; enforces it in the ONE place every tone must pass through, rather than trusting each caller.
;;;
;;; WHY A CAP AND NOT A FIXED CALLER.  The loud beep came from `guard-dog` calling `Buzzer.arf`,
;;; which is `(Buzzer.chirp 60 4000 100 1000)` -- a FULL SECOND of sweep ([B632]).  Turning that
;;; one caller off is necessary and not sufficient: `Buzzer.onoff` is public, `Buzzer.chirp` builds
;;; on it, and anything -- a demo, a test, a future signal vocabulary -- can queue a long tone
;;; again.  A rule enforced at each call site is a rule that holds until someone adds call site
;;; number six.  The cap holds regardless of who calls.
;;;
;;; IT IS A SETTING so a board that genuinely wants a siren can raise it deliberately, and the
;;; default protects the bench.  Note the queue drains one entry per `Buzzer.loop` tick, so a long
;;; SEQUENCE of capped chirps is still possible -- the cap bounds each TONE, not the total.  That
;;; is the honest limit of this mechanism and the reason `Buzzer.arf` is neutered outright below
;;; rather than merely clamped.
(define Buzzer.max-on-ms (setting 'buzzer_max_on_ms 10))

;;; -> ms clamped into [0, Buzzer.max-on-ms].  Applied to every on-time, from anywhere.
(define (Buzzer.cap-ms ms)
  (cond ((not (number? ms)) 0)
        ((< ms 0)                  0)
        ((> ms Buzzer.max-on-ms)   Buzzer.max-on-ms)
        (else                      ms)))

;;; TONE PITCH: NOT 4 kHz.  The click was 4000 Hz, which is the band smoke and fire alarms are
;;; tuned to precisely BECAUSE it is hard to ignore -- the ear's sensitivity peaks around 3-4 kHz.
;;; For an acknowledgement that is exactly the wrong property: it should be noticed once, not
;;; command the room.  Reported from the bench 2026-09-25, "not like a fire alarm".  A setting, so
;;; a board that wants to be audible across a workshop can raise it deliberately.
;;; 600 Hz, not 1200 and emphatically not 4000.  A TICK is a low, short knock -- the ear reads a
;;; brief low-frequency burst as a mechanical click and a high one as an alarm, which is why smoke
;;; detectors sit at 3-4 kHz.  Low also carries less through a room, which is the point here.
(define Buzzer.click-hz (setting 'buzzer_click_hz 400))

;;; Gap between the two ticks.  Long enough to hear TWO events rather than one ragged buzz, short
;;; enough to read as one signal ("tick tick") rather than two unrelated clicks.
(define Buzzer.tick-gap-ms (setting 'buzzer_tick_gap_ms 120))

;;; TICK LENGTH -- 5 ms (owner, 2026-09-25).  Short enough to be a knock rather than a note: at
;;; 600 Hz a cycle is 1.67 ms, so 5 ms is about three cycles, which is the shortest burst that
;;; still has a recognisable pitch instead of sounding like a pop.  Below ~2 ms it stops being
;;; audible as a tick at all on this piezo.
;;; Separate from `Buzzer.max-on-ms`, which is the CEILING no caller may exceed; this is the
;;; duration the tick actually uses, and it must stay under that ceiling.
(define Buzzer.click-ms (setting 'buzzer_click_ms 5))

;; A single short click -- a quiet acknowledgement.  Queued (non-blocking).
;; NOTE: the old body (Buzzer.on)(delay 8)(Buzzer.off) was BROKEN -- `delay` here is the
;; R7RS promise macro (rxrs_promises.scm shadows the C++ sleep), so (delay 8) built and
;; discarded a promise and the 8 ms hold never happened (tone on+off in the same breath).
(define (Buzzer.click)
  (behavior-queue-seq Buzzer.bq
    (lambda () (Buzzer.on Buzzer.click-hz) #t)   ; one-and-done: tone on
    (wait (Buzzer.cap-ms Buzzer.click-ms))   ; hold at the queue head (non-blocking), capped
    (lambda () (Buzzer.off) #t)))     ; one-and-done: tone off

(define (Buzzer.onoff freq on-time off-time)
  (when (> on-time 0)  (Buzzer.bq 'push (once-for (floor (Buzzer.cap-ms on-time))  (lambda () (Buzzer.on freq)))))
  (when (> off-time 0) (Buzzer.bq 'push (once-for (floor off-time) Buzzer.off)))
  )

(define (Buzzer.offon freq off-time on-time)
  (when (> off-time 0) (Buzzer.bq 'push (once-for (floor off-time) Buzzer.off)))
  (when (> on-time 0)  (Buzzer.bq 'push (once-for (floor (Buzzer.cap-ms on-time)) (lambda () (Buzzer.on freq)))))
  )

(if have-Buzzer
  (define (Buzzer.chirp from to nsteps interval_ms)
    ;;; letrec*, NOT let* -- `queue-all` CALLS ITSELF.  A let* binding is not in scope for its own
    ;;; initializer, so the recursive `(queue-all (+ 1 n))` below is a FREE reference.  Interpreted
    ;;; that works BY ACCIDENT: the closure captures the frame by reference and the binding exists
    ;;; by the time it is called.  COMPILED it does not: the bytecode/NCG compiler gives a let*
    ;;; binding a local SLOT, the self-reference is not a local, so it compiles to a global lookup
    ;;; and fails at run time with
    ;;;     Lamb::dict_ref() Unbound key 'queue-all'
    ;;; -- which names the symbol but not the reason, and points at Buzzer rather than at the form.
    ;;; Measured on the 4WD 2026-09-07: buzzer/chirp and buzzer/arf both FAIL after
    ;;; ncg-compile-environment! and both pass uncompiled.  letrec* keeps the sequential
    ;;; left-to-right evaluation let* was chosen for AND puts every binding in scope for every
    ;;; initializer, so it is correct in all three tiers.
    (letrec* ((f_range   (- to from 0.0))	;0.0 coerces Real_t
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

;;; (Buzzer.beep1) -- THE startup signal: exactly one 5 ms beep.  ONE QUEUE ENTRY, ATOMIC.
;;;
;;; WHY THIS IS NOT `Buzzer.click`, AND WHY EVERY EARLIER ATTEMPT PRODUCED A LONG BEEP.
;;;
;;; `Buzzer.click` pushes THREE entries -- [tone on] [wait N] [tone off] -- and `Buzzer.loop`
;;; drains ONE PER MAIN-LOOP TICK.  So the audible length is not N: it is however long the loop
;;; takes to travel from the first entry to the third.  While the loop is doing anything slow --
;;; `mop3_compile_environment` at start-up, an LLIP transfer, a blocking socket write -- the tone
;;; is ALREADY ON and simply stays on until the loop comes back.  That is the "long beep" reported
;;; from the bench repeatedly on 2026-09-25, and it is why shortening the `wait` never fixed it:
;;; the wait was never what was being heard.
;;;
;;; A SPLIT TONE HAS NO BOUNDED DURATION, and no setting can give it one.  This pushes a SINGLE
;;; entry that turns the tone on, holds it with `delay-ms` -- the real sleep, not the R7RS `delay`
;;; promise macro that silently broke the original click -- and turns it off before returning.  The
;;; loop cannot interleave anything, so 5 ms means 5 ms.
;;;
;;; THE COST, STATED: this blocks the main loop for `Buzzer.click-ms`.  At 5 ms that is above the
;;; 3 ms soft target for exactly one tick, once, at start-up.  That is the trade -- a bounded 5 ms
;;; stall in return for a tone that cannot run away.  Do NOT reuse this for a repeating signal; for
;;; anything periodic, queue it and accept that its length is scheduling-dependent.
(define (Buzzer.beep1)
  (Buzzer.bq 'push
    (lambda ()
      (Buzzer.on Buzzer.click-hz)
      (delay-ms (Buzzer.cap-ms Buzzer.click-ms))
      (Buzzer.off)
      #t)))                             ;;;!< one-and-done: the queue pops it

(define (Buzzer.arf-sweep) (Buzzer.chirp 60 4000 100 1000))
(define (Buzzer.arf) (Buzzer.click))

(define (Buzzer.loop)
  (Buzzer.bq 'tick)
  )

;;; NO CLICK HERE.  This file used to click on LOAD, and `setup.scm` clicks again once the whole
;;; chain is up -- so every boot produced TWO chirps, reported from the bench as "2 beeps still,
;;; a short one and a long one".  Two acknowledgements say nothing one does not.
;;;
;;; setup.scm's is the one kept, deliberately: it fires when the board is actually READY, which is
;;; what an audible acknowledgement is for.  A click here only says "the buzzer file parsed", and
;;; it lands mid-boot where nothing is usable yet.
;;;
;;; The log line stays -- it costs nothing, it is how anyone confirms this file loaded, and unlike
;;; the tone it is not in the room.
(news "Buzzer loaded (no click here -- setup.scm clicks once the board is ready)\n")

;;; B312: a buzzer left sounding is the harmless member of this family, and it is the one a
;;; person actually notices -- so it is worth registering for the same reason the motors are.
(when have-Buzzer (register-safe-state! Buzzer.off))

(news "Buzzer loaded\n")
