;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "Loading Sonar\n")

(define have-Sonar-code (dict-ref? (current-environment) 'Sonar.begin))
;; (pins-sonar . (trig echo)) -- #f if the board map has no sonar.  (Using the individual
;; pin-sonar-trig/echo here was a bug: `and` returns only the echo pair, so (cdr ...) gave
;; the lone echo pin instead of the (trig echo) list, breaking Sonar.setup's (car/cadr).)
(define have-Sonar-pins (dict-ref? Pins 'pins-sonar))

(define have-Sonar (and have-Sonar-code have-Sonar-pins))

(define Sonar.pins
  (if have-Sonar (cdr have-Sonar-pins)
      '(0 0)))

(syslog "Sonar pins: ~a\n" Sonar.pins)

(define Sonar.range-m 4.0)              ;P126 R4: mirrors C++ range_meters; "nothing within this"
(define Sonar.latest Sonar.range-m)     ;init: nothing in range

;;; P126 R1: tune the no-echo timeout at runtime (default 50 ms in C++); ms convenience.
(define (Sonar.timeout-ms! ms) (Sonar.timeout-us! (* ms 1000)))

(define (Sonar.setup)
  (let* ((me   'Sonar.setup)
         (tpin (car  Sonar.pins))
         (epin (cadr Sonar.pins)))
    (Sonar.begin tpin epin)
    (Sonar.arm!)                    ;arm first ping (stamps the clock the stall check reads)
    (info "(~a) tpin ~a epin ~a\n" me tpin epin)
    Sonar.latest))

;;; P126 R4: continuous send-or-expect.  Every tick the sonar is either EXPECTing the in-flight
;;; return, or -- the instant the prior ping is dispositioned (echo OR timeout) -- it SENDs the
;;; next ping at loop time.  Both no-object dispositions (timeout, over-range echo) report the
;;; rated max range so the obstacle reflex can un-latch.
;;; Sonar.result returns: #f = still waiting, 0 = timeout, integer = elapsed us.
;;; RE-ARM AFTER A STALL, NOT ONLY AFTER A DISPOSITION [B625].
;;;
;;; The cond below starts the next ping only on a disposition -- an echo or a timeout.  On #f it
;;; returns early, because #f means "still in flight" and re-pinging mid-flight would be wrong.
;;; But #f is ALSO what `Sonar.result` returns when nothing is in flight at all, and those two
;;; states are indistinguishable from here.  So if the machine ever reaches "idle, nothing armed",
;;; this loop waits for a disposition that can never come and `Sonar.latest` freezes -- at
;;; `Sonar.range-m`, which reads as a confident CLEAR PATH.
;;;
;;; It is not hypothetical and it is easy to cause: ANY diagnostic that calls `(Sonar.result)`
;;; once consumes the pending result, and the sonar is dead until reboot.  That happened while
;;; investigating B625 -- the probe silently disabled the thing it was probing, which is the
;;; failure mode a diagnostic must never have.
;;;
;;; A ping resolves within the no-echo timeout (50 ms default, P126 R1), so a #f persisting well
;;; past that means nothing is armed, whatever the reason.  Re-arm and say so once.
(define Sonar.stale-ms 250)             ;;;!< 5x the default 50 ms timeout -- never mid-flight
(define Sonar.last-start-ms 0)          ;;;!< set by every arm, read by the stall check
(define Sonar.restarts 0)               ;;;!< counted so a recurring stall is visible, not silent

(define (Sonar.arm!)
  (set! Sonar.last-start-ms (millis))
  (Sonar.start))

(define Sonar.loop
  (let ((me       'Sonar.loop)
        (t_report (AutoTimer_ms 10000)))
    (lambda ()
      (let ((t (Sonar.result)))
        (cond
          ((not t)                               ;EXPECT: in-flight ping not yet resolved --
                                                 ;or nothing armed, which looks identical
           (when (> (- (millis) Sonar.last-start-ms) Sonar.stale-ms)
             (set! Sonar.restarts (+ Sonar.restarts 1))
             (info "(~a) no result for ~a ms -- re-arming (restart ~a)\n"
                   me Sonar.stale-ms Sonar.restarts)
             (Sonar.arm!))
           Sonar.latest)
          ((zero? t)                             ;TIMEOUT: nothing in range
           (set! Sonar.latest Sonar.range-m)
           (Sonar.arm!))                         ;SEND: launch next ping immediately
          (else                                  ;GOT ECHO (real, or over-range no-echo terminator)
           (let ((d (Sonar.us->distance t)))     ;C++ already clamps to range-m; belt-and-suspenders
             (set! Sonar.latest (if (> d Sonar.range-m) Sonar.range-m d)))
           (Sonar.arm!))))                       ;SEND
      (unless (t_report)
        (info "(~a) distance ~a meters\n" me Sonar.latest))
      Sonar.latest)))

;;; P126 R5: Sonar.ping / Sonar.poke BLOCK up to the timeout (~50 ms) -- TEST/BENCH ONLY.
;;; Never call them from Sonar.loop or the 3 ms main loop (they would blow the loop budget);
;;; the loop uses the non-blocking Sonar.start / Sonar.result pair above.

(unless have-Sonar
  (warn "Sonar not available, code: ~a, pins: ~a\n" have-Sonar-code have-Sonar-pins)
  (define Sonar.begin  Lambda0)
  (define Sonar.start  Lambda0)
  (define Sonar.result (lambda () #f))
  (define Sonar.setup  Lambda0)
  (define Sonar.loop   Lambda0)
  (define Sonar.poke   Lambda0)
  (define Sonar.timeout-ms! Lambda0))

(Sonar.setup)
