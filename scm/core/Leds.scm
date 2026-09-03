;;; Copyright 2026 by Frobenius Norm LLC 2026-06-21 15:36:00
;;; Free for non-commercial use. Commercial use requires a license.
(info "Loading Leds\n")

#|!
LED ring service (P123 A2) -- generic, robot-agnostic control of the 12-LED
WS2812 ring (see WS2812.scm, Nleds 12).  It owns ZONES, ILLUMINATION, a dedicated
LED behaviour queue, and a PRIORITY ARBITER that plays transient signals over a
persistent base mode.  It knows nothing about what a signal MEANS -- that
vocabulary lives in the robot layer (llip-signals.scm, P123 B4).

Depends on: WS2812.scm (setColor/setBrightness/navLights, ws2812-info, rgb-colors)
            Behaviors.scm (make-behavior-queue, once, once-for, cycle, seq)

The LED queue (led-bq) lives in WS2812.scm and is ticked by Led.loop in the main loop.
|#

;;; ---- small list helper (SRFI-1 append-map is not in the base) ----------
;;!flatmap: append the results of mapping f over lst.
(define (append-map f lst) (apply append (map f lst)))

;;; ---- zone config (board calibration) ----------------------------------
;;; Indices follow WS2812.navLights: port 0,11 · forward 2,3 · starboard 5,6 ·
;;; aft 8,9.  Role split: a front arc of ~6 = illumination; the rest = signals.
(define led-illum-zone  '(0 1 2 3 4 5))     ; front arc, white, for the camera   -- CALIBRATE
(define led-signal-zone '(6 7 8 9 10 11))   ; status / error patterns            -- CALIBRATE
(define led-all (iota (ws2812-info 'Nleds)))
(define led-illum-cap 120)                  ; brightness cap for illumination     -- power budget

;;; ---- primitives -------------------------------------------------------
;;!Set a list of LED indices to a colour symbol (rgb-red, rgb-black, ...).
(define (zone-color! zone rgb)
  (for-each (lambda (i) (WS2812.setColor i rgb)) zone))

;;!Forward arc white for the camera (capped, forward-only); #f clears it.
(define (led-illuminate! on?)
  (if on?
      (begin (WS2812.setBrightness led-illum-cap)
             (zone-color! led-illum-zone 'rgb-white))
      (zone-color! led-illum-zone 'rgb-black)))

;;; ---- the arbiter: a persistent base mode + priority-preempting signals -
;;; A dedicated LED queue (decision 2026-06-19): a motion abort never touches
;;; the lights.  A base mode (idle/running/dock) runs until changed; a transient
;;; signal of >= the current priority aborts the queue, plays, then restores base.
;; led-bq is defined in WS2812.scm (loaded first); this service drives that same queue,
;; so the basic Led.blink* helpers and the arbiter share one LED queue (one Led.loop tick).
(define led-base    (lambda () #f))         ; current base-mode task
(define led-cur-pri -1)                      ; priority of the playing transient, -1 = none

;;!Set the persistent base mode (idle / running / dock ...).  Takes effect now
;;!only if no transient is currently playing; otherwise it is restored afterward.
(define (led-base! task)
  (set! led-base task)
  (when (< led-cur-pri 0)
    (led-bq 'abort)
    (led-bq 'push task)))

;;!Play a transient signal task if its priority >= the current one; when it
;;!finishes, drop back to -1 and restore the base mode.
(define (led-emit! pri task)
  (when (>= pri led-cur-pri)
    (led-bq 'abort)
    (set! led-cur-pri pri)
    (led-bq 'push task)
    (led-bq 'push (once (lambda ()
                          (set! led-cur-pri -1)
                          (led-bq 'push led-base))))))

;; The LED queue (led-bq) is ticked by Led.loop (WS2812.scm) in the main loop.

;;!Hard-clear the arbiter: drop any signal (even a sticky one like the deadman),
;;!reset priority, and restore the base mode.  Used to recover from a latched signal.
(define (led-clear!)
  (led-bq 'abort)
  (set! led-cur-pri -1)
  (led-bq 'push led-base))

;;; ---- blink-pattern helper used by the signal vocabulary ----------------
;;!Blink `zone` in `rgb` against black.  n>0 = N blinks then done (one task via
;;!seq); n=0 = blink forever (a cycle).  on-ms / off-ms are the phase durations.
(define (led-blink zone rgb n on-ms off-ms)
  (if (= n 0)
      (cycle (list on-ms  (lambda () (zone-color! zone rgb)))
             (list off-ms (lambda () (zone-color! zone 'rgb-black))))
      (apply seq
        (append-map
         (lambda (_)
           (list (once-for on-ms  (lambda () (zone-color! zone rgb)))
                 (once-for off-ms (lambda () (zone-color! zone 'rgb-black)))))
         (iota n)))))

;;; ---- battery / peripheral-rail check --------------------------------------
;;!The ESP32 is USB-powered, but the WS2812 ring, sonar, and servos all draw the
;;!battery 5 V rail.  So a lit ring proves the rail is up; a dark ring with a
;;!healthy ADC reading isolates a switch/rail fault from a flat pack; a low ADC
;;!means the cells themselves are depleted.  `(battery-check)` reads the battery
;;!ADC (pin-ADC) and paints the ring as a fuel gauge -- green (good) / yellow
;;!(marginal) / red (low); the number of lit LEDs is remaining charge, a fully
;;!dark ring means no rail power.  Logs the raw count + an estimated voltage.
;;!The two thresholds and the volts scale are CALIBRATE placeholders: set them
;;!against a multimeter on a known-good pack and at the safe cutoff.
(define batt-adc-pin
  (let ((p (dict-ref? Pins 'pin-ADC))) (if p (cdr p) #f)))
(define batt-adc-full        3000)      ; CALIBRATE: ADC count, freshly-charged pack
(define batt-adc-empty       1800)      ; CALIBRATE: ADC count, safe cutoff
(define batt-volts-per-count 0.00256)   ; CALIBRATE: divider * (Vref / 4095)

;;!Lit-LED count for raw ADC `adc` over `nleds`, integer-clamped to 0..nleds.
(define (battery-lit adc nleds)
  (let ((span (- batt-adc-full batt-adc-empty)))
    (if (<= span 0) 0
        (let ((n (quotient (* nleds (- adc batt-adc-empty)) span)))
          (cond ((< n 0) 0) ((> n nleds) nleds) (else n))))))

;;!Read the battery ADC, paint the ring as a fuel gauge, log it, return raw ADC.
(define (battery-check)
  (if (not batt-adc-pin)
      (begin (warn "battery-check: board has no pin-ADC\n") #f)
      (let* ((nleds (ws2812-info 'Nleds))
             (adc   (analogRead batt-adc-pin))
             (lit   (max 1 (battery-lit adc nleds)))  ; >=1 lit when the rail is up
             (rgb   (cond ((> (* lit 2) nleds) 'rgb-green)
                          ((> (* lit 4) nleds) 'rgb-yellow)
                          (else                'rgb-red))))
        (do ((i 0 (+ i 1))) ((= i nleds))
          (WS2812.setLedColorData i 0 0 0))                          ; clear buffer
        (do ((i 0 (+ i 1))) ((= i lit))
          (apply WS2812.setLedColorData (cons i (rgb-colors rgb))))  ; paint lit span
        (WS2812.show)
        (syslog "battery-check: ADC ~a  ~a/~a LEDs  ~~ ~a V\n"
                adc lit nleds (* adc batt-volts-per-count))
        adc)))

(info "Leds Loaded\n")
