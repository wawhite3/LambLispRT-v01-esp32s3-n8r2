;;; Copyright 2026 by Frobenius Norm LLC 2026-06-21 15:38:00
;;; Free for non-commercial use. Commercial use requires a license.
(info "Loading llip-signals\n")

#|!
Robot LED signal vocabulary (P123 B4) -- the thin robot-layer consumer of the
generic LED ring service (Leds.scm, A2).  It assigns MEANING to ring patterns.

Two kinds of signal:
  * BASE modes (idle / running / dock) are persistent -- set via `led-base!`,
    they run until the next base mode replaces them.
  * MOMENTARY signals (bad-move / obstacle / low-battery) are BOUNDED blinks
    (n>0) that auto-restore the base mode -- played via `led-emit!` with a
    priority; a higher- or equal-priority signal preempts a lower one.
  * The DEADMAN is the one sticky signal: forever (n=0), highest priority, and
    the only signal that paints the WHOLE ring (`led-all`), overriding the
    forward illumination -- safety wins.

  Event         Kind        Pattern (zone)              Colour   Priority
  ----------------------------------------------------------------------------
  idle/ready    base        nav lights                  nav        --
  running       base        slow pulse (signal zone)    green      --
  dock          base        slow pulse (signal zone)    blue       --
  bad-move      momentary3  fast blink (signal zone)    red        2
  obstacle      momentary5  fast flash (signal zone)    red        3
  low-battery   momentary3  slow blink (signal zone)    yellow     1
  deadman       sticky      continuous SOS (whole ring) red        4

Depends on: Leds.scm (led-base!/led-emit!/led-blink, led-signal-zone, led-all)
            WS2812.scm (navLights)  Behaviors.scm (cycle)
|#

;;!Raise a robot LED signal.  Base modes persist; momentary signals blink a
;;!bounded number of times and restore the base; the deadman is sticky.
(define (robot-signal! event)
  (case event
    ;; --- base modes: persist until changed (led-base!) ---
    ((idle)        (led-base! (cycle (list 1000 (lambda () (WS2812.navLights))))))
    ((running)     (led-base! (led-blink led-signal-zone 'rgb-green 0 400 400)))
    ((dock)        (led-base! (led-blink led-signal-zone 'rgb-blue  0 400 400)))
    ;; --- momentary signals: bounded blink, then auto-restore base (led-emit!) ---
    ((bad-move)    (led-emit! 2 (led-blink led-signal-zone 'rgb-red    3 120 120)))
    ((obstacle)    (led-emit! 3 (led-blink led-signal-zone 'rgb-red    5  80  80)))
    ((low-battery) (led-emit! 1 (led-blink led-signal-zone 'rgb-yellow 3 600 600)))
    ;; --- sticky safety: highest priority, whole ring, overrides illumination ---
    ((deadman)     (led-emit! 4 (led-blink led-all 'rgb-red 0 100 100)))
    (else (error "robot-signal!: unknown event" event))))

(info "llip-signals Loaded\n")
