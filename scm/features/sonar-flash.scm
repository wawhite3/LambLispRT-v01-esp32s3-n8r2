;;; sonar-flash.scm -- proximity alarm: flash the WS2812 ring faster as the target gets closer.
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-17 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; NON-BLOCKING BY CONSTRUCTION.  sonar-flash-tick! does work only when the LEDs are actually due
;;; to change and returns immediately otherwise, so it can sit in the 3 ms main loop beside
;;; Sonar.loop.  A `(delay-ms period)` implementation would have been three lines shorter and would
;;; have stalled the B5 obstacle reflex for up to a second at long range -- i.e. it would blind the
;;; robot precisely when the alarm says there is something to avoid.
;;;
;;; RATE IS LINEAR IN DISTANCE, deliberately.  Period runs from `sonar-flash-near-ms` at contact to
;;; `sonar-flash-far-ms` at the sensor's rated range, so "getting closer" is a steady acceleration
;;; rather than a curve that does nothing until the last few centimetres.  Both ends are named
;;; constants because they are a UX choice, not physics.
;;;
;;; Deps: Sonar.scm (Sonar.latest, Sonar.range-m), WS2812.scm (WS2812.setAll), millis, and
;;;       optionally digitalWrite/pinMode for a second LED.

(define sonar-flash-near-ms   60)       ;;;!< period at zero distance -- fastest visible flash
(define sonar-flash-far-ms  1000)       ;;;!< period at the rated range -- a slow "clear" pulse
(define sonar-flash-rgb '(60 0 0))      ;;;!< colour while ON (60, not 255: an onboard RGB
;;;!< LED sits inches from the operator and is painfully bright at full scale)
(define sonar-flash-use-ring #t)        ;;;!< drive the external ring too, where there is one

;;; THERE IS NO ONBOARD USER LED ON THE FREENOVE 4WD -- ESTABLISHED 2026-09-17, DO NOT HUNT FOR ONE.
;;; The pin map accounts for every usable GPIO, and each plausible "onboard LED" candidate is a
;;; real peripheral that driving would disturb:
;;;
;;;     GPIO 0  pin-IR        GPIO 1  U0TXD (the serial console)
;;;     GPIO 2  pin-BUZZER    <- the classic devkit LED pin here SOUNDS THE BUZZER
;;;     GPIO 3  U0RXD         GPIO 4,5  CSI_Y2/Y3 (camera data)
;;;     6-11 flash   12,15 sonar   13,14 I2C   18-27,34-39 camera   32 WS2812   33 ADC
;;;
;;; The two indicators visible on the board are NOT under software control: green is power, and
;;; the flashing amber is CH340 serial activity -- it flashes because bytes are moving on the USB
;;; link, which is why it appears to respond to anything you run.  Confirmed by driving the ring
;;; through RED/GREEN/BLUE/OFF while both stayed as they were.
;;;
;;; So on THIS board the WS2812 ring IS the onboard lamp and the hook below has nothing to target.
;;; It is kept because the same file ships to boards that do have one (and the WROVER-CAM pin map
;;; is a separate question) -- but on the 4WD, leave it #f.  A guess here is not a wasted blink,
;;; it is a buzzer blast or a disturbed camera bus.
(define sonar-flash-onboard-pin #f)
(define (sonar-flash-onboard! pin)
  (set! sonar-flash-onboard-pin pin)
  (if pin (pinMode pin 1))              ;;; 1 = OUTPUT
  pin)

;;; Distance (m) -> flash period (ms).  Pure; testable with no hardware present.
(define (sonar-flash-period-ms d)
  (let* ((rng (if (> Sonar.range-m 0) Sonar.range-m 4.0))
         (c   (cond ((not (number? d)) rng)          ;;; no reading yet -> treat as "clear"
                    ((< d 0) 0)
                    ((> d rng) rng)
                    (else d)))
         (f   (/ c rng)))                            ;;; 0 at contact, 1 at rated range
    (inexact->exact
      (round (+ sonar-flash-near-ms
                (* f (- sonar-flash-far-ms sonar-flash-near-ms)))))))

(define sonar-flash-on?    #f)
(define sonar-flash-next    0)
(define sonar-flash-last-ms 0)          ;;;!< last period used, exposed for tests/telemetry

;;; Set both lamps together, so "the same pace" is one decision applied twice rather than two
;;; timers that can drift apart.
;;; THE ONBOARD RGB LED IS THE PORTABLE "onboard lamp", and it is found the same way the ring is:
;;; by asking the pin map.  Boards declaring `pin-RGBLED` (S3 at 48, C5 at 27) drive it through
;;; ledrgb! / neopixelWrite; boards declaring `pin-WS2812` (4WD, WROVER) drive the external ring.
;;; A board may have either, both, or neither -- all three cases are handled here rather than by
;;; the caller, so "the same pace" stays ONE decision applied to whatever lamps exist.
;;; NOTE ledrgb! only became usable on 2026-09-17 ([B456]): it had never been defined on any board.
(define sonar-flash-use-rgbled
  (guard (e (#t #f)) (and (procedure? ledrgb!) pin-RGBLED #t)))

(define (sonar-flash-set! on?)
  (set! sonar-flash-on? on?)
  (if (and have-WS2812 sonar-flash-use-ring)
      (if on?
          (WS2812.setAll (car sonar-flash-rgb) (cadr sonar-flash-rgb) (caddr sonar-flash-rgb))
          (WS2812.off)))
  (if sonar-flash-use-rgbled
      (if on?
          (ledrgb! (car sonar-flash-rgb) (cadr sonar-flash-rgb) (caddr sonar-flash-rgb))
          (ledrgb! 0 0 0)))
  (if sonar-flash-onboard-pin
      (digitalWrite sonar-flash-onboard-pin (if on? 1 0))))

;;; Call every main-loop tick.  Returns the period currently in force (ms).
(define (sonar-flash-tick!)
  (let* ((d   Sonar.latest)
         (per (sonar-flash-period-ms d))
         (now (millis)))
    (set! sonar-flash-last-ms per)
    (if (>= now sonar-flash-next)
        (begin
          ;; half-period toggle: `per` is a full on+off cycle, so each edge is per/2
          (set! sonar-flash-next (+ now (quotient per 2)))
          (sonar-flash-set! (not sonar-flash-on?))))
    per))

(define (sonar-flash-stop!)
  (sonar-flash-set! #f)
  (set! sonar-flash-next 0))

;;; --- test / demo driver ---------------------------------------------------------------
;;; Runs the alarm for `ms` milliseconds, servicing the sonar too, and reports what it saw.
;;; Prints one RESULT line so the serial harness can parse it.
(define (sonar-flash-run ms)
  (if (not have-Sonar)
      (begin (display "RESULT flash error=no-sonar") (newline))
      (let ((t-end (+ (millis) ms)))
        (sonar-flash-stop!)
        (let loop ((edges 0) (pmin 1000000) (pmax 0) (dmin 99.0) (dmax -1.0) (was #f))
          (if (>= (millis) t-end)
              (begin
                (sonar-flash-stop!)
                (display "RESULT flash edges=") (display edges)
                (display " period_min_ms=") (display pmin)
                (display " period_max_ms=") (display pmax)
                (display " d_min_m=") (display dmin)
                (display " d_max_m=") (display dmax)
                (newline))
              (begin
                (Sonar.loop)                          ;;; keep the sonar serviced -- the whole point
                (let* ((per (sonar-flash-tick!))
                       (d   Sonar.latest)
                       (dn  (if (number? d) d dmin)))
                  (loop (if (eq? was sonar-flash-on?) edges (+ edges 1))
                        (min pmin per) (max pmax per)
                        (min dmin dn)  (max dmax dn)
                        sonar-flash-on?))))))))

;;; (sonar-flash-demo from-m to-m secs) -- drive the alarm from a SWEPT distance instead of the
;;; sonar, so the rate change is visible on a board that has a lamp but no sensor.  This is how the
;;; behaviour was demonstrated on esp32s3-n8r2-01, which has the onboard RGB LED (pin-RGBLED 48)
;;; and no sonar, after the 4WD -- which has the sensor -- turned out to have flat batteries and so
;;; could not light its ring at all.
(define (sonar-flash-demo from-m to-m secs)
  (let* ((t0 (millis)) (ms (* secs 1000)))
    (sonar-flash-stop!)
    (let loop ((edges 0) (pmin 1000000) (pmax 0))
      (let ((el (- (millis) t0)))
        (if (>= el ms)
            (begin
              (sonar-flash-stop!)
              (display "RESULT demo edges=") (display edges)
              (display " period_min_ms=") (display pmin)
              (display " period_max_ms=") (display pmax)
              (display " rgbled=") (display sonar-flash-use-rgbled)
              (display " ring=") (display (and have-WS2812 sonar-flash-use-ring))
              (newline))
            (let* ((f (/ (exact->inexact el) ms))
                   (d (+ from-m (* f (- to-m from-m))))
                   (was sonar-flash-on?))
              (set! Sonar.latest d)
              (let ((per (sonar-flash-tick!)))
                (loop (if (eq? was sonar-flash-on?) edges (+ edges 1))
                      (min pmin per) (max pmax per)))))))))
