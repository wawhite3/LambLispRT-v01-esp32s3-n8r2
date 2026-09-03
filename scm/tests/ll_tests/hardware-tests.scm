;;; hardware-tests.scm -- Freenove 4WD Car Kit ESP32 hardware actuator tests.
;;; Copyright 2026 by Frobenius Norm LLC 2026-06-03 16:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Tests: Buzzer, WS2812 LEDs, Motors, Sonar.
;;; Line tracker not tested (not in use).
;;; PASS/FAIL for actuators = no exception thrown.
;;; Sonar is the only test with a measurable physical return value.
;;;
;;; Usage: (load "ll_tests/hardware-tests.scm" 0)

(define hw-pass 0)
(define hw-fail 0)

(define (hw-check-no-error name thunk13)
  (guard (e (#t (display "FAIL ") (display name)
               (display "  error=") (display e) (newline)
               (set! hw-fail (+ 1 hw-fail))))
    (thunk13)
    (display "PASS ") (display name) (newline)
    (set! hw-pass (+ 1 hw-pass))))

(define (hw-check-true name val)
  (if val
      (begin (display "PASS ") (display name) (newline)
             (set! hw-pass (+ 1 hw-pass)))
      (begin (display "FAIL ") (display name) (display "  expected=#t got=#f") (newline)
             (set! hw-fail (+ 1 hw-fail)))))

;;; B37 PROBE -- report what a binding actually HOLDS, not merely that a test failed.
;;; The LED tests fail with `apply_proc_partial() Bad type ... T_BOOL Bool_t == 0`, i.e. something
;;; is calling #f.  ncg_load_global resolves the callee at RUNTIME via dict_ref, which THROWS on a
;;; miss rather than returning #f, so the symbol is BOUND and its value IS #f -- but the error names
;;; only the type it tripped over, never which binding.  These lines say which, on every run, before
;;; the section that fails.  Cheap, and it turns "5 LED tests failed" into a fact about a binding.
(define (hw-probe name)
  (display "PROBE ") (display name) (display " = ")
  (if (not (defined? name))
      (display "UNBOUND")
      (let ((v (eval name (interaction-environment))))
        (cond ((procedure? v) (display "procedure"))
              ((eq? v #f)     (display "***#f -- THIS IS THE B37 FAILURE***"))
              (else           (display v)))))
  (newline))

;;; Drain a TimedQueue for up to timeout-ms milliseconds.
(define (drain-tq! tq timeout-ms)
  (let ((deadline (+ (millis) timeout-ms)))
    (let loop ()
      (tq)
      (when (< (millis) deadline) (loop)))))

;;; --- Buzzer ---
(display "--- buzzer ---\n")
(hw-probe 'Buzzer.on)
(hw-probe 'Buzzer.off)
(hw-probe 'Buzzer.chirp)
(hw-probe 'Buzzer.bq)
(hw-probe 'Buzzer.queue)   ;; NOTE: referenced by the tests below but NOT defined anywhere
(hw-probe 'delay_ms)

(hw-check-no-error "buzzer/on-off"
  (lambda () (Buzzer.on 1000) (delay_ms 150) (Buzzer.off)))

(hw-check-no-error "buzzer/chirp"
  (lambda ()
    (Buzzer.chirp 200 2000 10 300)
    (drain-tq! Buzzer.queue 400)))

(hw-check-no-error "buzzer/arf"
  (lambda ()
    (Buzzer.arf)
    (drain-tq! Buzzer.queue 1100)))

;;; --- WS2812 LEDs ---
(display "--- leds ---\n")

(hw-probe 'WS2812.setAll)
(hw-probe 'WS2812.off)
;; setAll's own callees -- the #f is one of THESE, not setAll, which probes as bytecode.
(hw-probe 'ws2812-info)
(hw-probe 'WS2812.setLedColorData)
(hw-probe 'WS2812.show)
(hw-probe 'WS2812.setBrightness)
(hw-probe 'have-WS2812)

(hw-check-no-error "led/red"
  (lambda () (WS2812.setAll 128 0 0) (delay_ms 250)))

(hw-check-no-error "led/green"
  (lambda () (WS2812.setAll 0 128 0) (delay_ms 250)))

(hw-check-no-error "led/blue"
  (lambda () (WS2812.setAll 0 0 128) (delay_ms 250)))

(hw-check-no-error "led/navlights"
  (lambda () (WS2812.navLights) (delay_ms 500) (WS2812.off)))

(hw-check-no-error "led/off"
  (lambda () (WS2812.off)))

;;; --- Motors (Motor.set4 is synchronous -- no queue involved) ---
;;; Motor layout clockwise from front-left: FL=0 FR=1 RR=2 RL=3.
;;; 30% power, 300 ms bursts -- enough to confirm spin without driving off a surface.
(display "--- motors ---\n")

(hw-check-no-error "motor/forward"
  (lambda () (Motor.set4 0.3 0.3 0.3 0.3) (delay_ms 300) (Motor.set4 0 0 0 0)))

(hw-check-no-error "motor/reverse"
  (lambda () (Motor.set4 -0.3 -0.3 -0.3 -0.3) (delay_ms 300) (Motor.set4 0 0 0 0)))

(hw-check-no-error "motor/spin-right"
  (lambda () (Motor.set4 0.3 -0.3 -0.3 0.3) (delay_ms 300) (Motor.set4 0 0 0 0)))

(hw-check-no-error "motor/spin-left"
  (lambda () (Motor.set4 -0.3 0.3 0.3 -0.3) (delay_ms 300) (Motor.set4 0 0 0 0)))

;;; --- Sonar ---
(display "--- sonar ---\n")

(Sonar.setup)
;;; Poll up to 250 ms for a real echo (replaces the initial default of 1000 m).
(let sonar-wait ((n 10))
  (delay_ms 25)
  (Sonar.loop)
  (when (and (> n 0) (>= Sonar.latest 1000)) (sonar-wait (- n 1))))

(hw-check-true "sonar/positive"  (> Sonar.latest 0))
(hw-check-true "sonar/plausible" (< Sonar.latest 10.0))

(display "\nTotal: ") (display hw-pass) (display " pass, ")
(display hw-fail) (display " fail") (newline)
(display "--- hardware done ---") (newline)
