;;; Copyright 2026 by Frobenius Norm LLC 2026-09-23
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; TARGET SETUP for the `esp32s3-aitrip-480x480` env -- loaded by setup.scm as
;;; setup-<lamb-board>.scm, after every feature and peripheral is defined and before (loop) is
;;; built.
;;;
;;; This target is a 4.0-inch 480x480 ST7701 RGB panel node.  It brings the panel and LVGL up and
;;; shows the board's state as text, so that a running panel is distinguishable from a failed one
;;; from the front: without it both are a black screen.
;;;
;;; DRAWING GOES THROUGH LVGL, NOT THROUGH THE RAW `lcd-*` PROCEDURES.  Those write pixels straight
;;; into the framebuffer the display hardware is scanning, which means the caller owns the colour
;;; format, the orientation and the refresh pacing -- three things LVGL already does correctly.
;;; `lcd-init` is still ours because LVGL performs no panel bring-up; everything above it is LVGL's.

(syslog "Target: esp32s3-aitrip-480x480 -- 480x480 ST7701 RGB panel node\n")

;;; The state line.  RSSI is signed and small: -53 is good, -75 is marginal, -85 is trouble.  It is
;;; shown as a number rather than as bars because a number can be read out to whoever is holding
;;; the other end of the problem.
(define (aitrip-state-text)
  (if (WiFi.isConnected)
      (string-append "LINK " (WiFi.SSID) "  " (WiFi.localIP))
      (if (positive? (setting 'wifi 0))
          (string-append "NO LINK -- seeking " (setting 'wifi_ssid "?"))
          "RADIO OFF")))

;;; RSSI lives in its own widget and is written on its own.  Keeping it out of the state line is
;;; what stops that line flickering: LVGL repaints the whole of an object whose text changed, so a
;;; line carrying SSID, address and signal together redraws entirely every time the signal moves a
;;; decibel.  The address and SSID change almost never; the signal changes constantly.
(define (aitrip-rssi-text)
  (if (WiFi.isConnected)
      (string-append (number->string (WiFi.RSSI)) " dBm")
      "-- dBm"))

;;; Bring the panel and LVGL up, and put the state on the glass.
;;; NOTE WHAT IS ABSENT: `lvgl-smoke`.  That mop builds a status strip, a centre label and a bar
;;; in C++, which is the layout this file now gets from Scheme instead.  Calling both puts TWO
;;; layouts on the glass at once -- a doubled top line and two bars, each half correct, which
;;; reads as a rendering fault rather than as two things drawing.  Observed 2026-09-24.
;;; `lvgl-smoke` remains a useful bring-up probe on a board with no layout; it is not one here.
(define (aitrip-panel-start!)
  (lcd-init)
  (lvgl-init)
  (load "lvgl-widgets.scm" 0)       ;; widget layer, composed from the thin shim
  (load "hud-layout.scm" 0)         ;; which widgets exist, where, and what they mean
  (hud-layout-build!)
  (hud-show-link! (WiFi.isConnected) (WiFi.SSID) (WiFi.localIP))
  (hud-show-rssi! (and (WiFi.isConnected) (WiFi.RSSI)))
  (hud-show-sonar! -1 0 0)
  (hud-show-stats! 0 0)
  (lvgl-tick! 40)                   ;; first full render
  #t)

;;; THE PANEL IS BROUGHT UP ON THE FIRST LOOP TICK, NOT AT LOAD TIME, AND THE DELAY IS THE POINT.
;;;
;;; Starting the RGB scan while the runtime is still loading its library leaves the scan
;;; permanently unstable: the picture tears and loses horizontal alignment, and it does not recover
;;; when the loading finishes.  The display streams this framebuffer out of PSRAM continuously, and
;;; initialising it while files are being read and the collector is walking a PSRAM heap starves
;;; that stream at the moment it is establishing timing.
;;;
;;; Measured on this board, same firmware and same drawing, only the moment differing: initialised
;;; during setup, the picture cycles between correct and streaked; initialised once the system is
;;; idle, it is stable indefinitely.
;;;
;;; `app-loop` is run by setup.scm in place of the robot loop, and its first tick happens after
;;; every file is loaded -- which is the quiet moment the panel needs.
;;; `app-loop` IS A LOOP *MAKER*, NOT THE LOOP.  setup.scm builds the main loop with
;;;     (define loop (if app-loop (app-loop) <default idle loop>))
;;; so it CALLS app-loop once and uses what comes back as the per-tick procedure.  Installing the
;;; tick procedure directly is the mistake that shape invites: it runs exactly once, at setup, and
;;; `loop` then becomes whatever that single call returned -- not a procedure.  The board still
;;; boots and the REPL still echoes, so it looks alive; what stops is everything the main loop
;;; drives, including the LLIP serial receiver and the TCP REPL.  The symptom is remote access
;;; disappearing while the console works, which does not point at the loop at all.
(define aitrip-panel-up #f)

;;; Tick counter for the status refresh.  The state line is not static: RSSI moves, the link can
;;; drop, and the IP can change on a DHCP renew.  Drawing it once at start-up produces a display
;;; that looks live and is not -- which is the failure this panel exists to prevent, so refreshing
;;; it is not a nicety.
;;;
;;; NOT EVERY TICK.  `WiFi.RSSI` queries the radio, and the loop turns over far faster than the
;;; number changes.  Once every 60 ticks is a second or two: fast enough that a dropped link is
;;; visible while someone is standing in front of the panel, slow enough not to tax the radio.
(define aitrip-tick-count 0)
(define aitrip-link-was 'unknown) ;;; last seen link state; the status line is rewritten only on
                                 ;;; change.  'unknown rather than #f so the FIRST refresh always
                                 ;;; differs and draws the line once, whatever the radio is doing.
(define aitrip-status-every 60)

;;; THE PANEL IS OPT-IN AT BOOT, AND THE DEFAULT IS OFF.
;;; A display brought up automatically inside the main loop can STOP that loop: in DIRECT render
;;; mode LVGL repaints the whole 480x480 framebuffer, and a repaint that outruns the tick budget
;;; starves everything else the loop drives -- the LLIP receiver and the TCP REPL both vanish while
;;; WiFi keeps answering pings, so the board looks alive and cannot be reached.  Recovering from
;;; that costs a filesystem upload over serial, because every remote path is gone.
;;;
;;; So the board always boots to a REACHABLE state, and the panel is started deliberately:
;;;   (setting 'panel_autostart 1) in Settings-local.scm, or
;;;   (aitrip-panel-start!) over the TCP REPL once the board is up.
(define (aitrip-autostart?) (positive? (setting 'panel_autostart 0)))

(set! app-loop
  (lambda ()                            ;; <- the MAKER: called once, returns the tick below
    (lambda ()                          ;; <- the TICK: called every iteration forever
      (if (and (not aitrip-panel-up) (not (aitrip-autostart?)))
          (set! aitrip-panel-up #t))    ;; not starting: mark done so the tick stays cheap
      (if (not aitrip-panel-up)
          (begin
            (set! aitrip-panel-up #t)   ;; set FIRST: a panel fault must not retry on every tick
            ;; A panel fault must not cost the REPL -- the board still has to come up so someone
            ;; can ask it why.  Logged rather than swallowed: "nothing was drawn" is itself a
            ;; diagnosis, and on this board it is the only one visible from the front.
            (guard (e (#t (syslog "[panel] start FAILED -- panel not initialised: ~a\n" e)))
              (aitrip-panel-start!)))
          (begin
            ;; Steady state: let LVGL animate and repaint within a bounded slice, so the display
            ;; stays responsive without the tick exceeding the runtime's published pause budget.
            (set! aitrip-tick-count (+ aitrip-tick-count 1))
            ;; Only the RSSI widget is rewritten on the refresh tick.  The state line is drawn
            ;; once at start-up and again only if the link state itself changes, so a steady link
            ;; leaves it untouched and unflickering.
            (when (zero? (modulo aitrip-tick-count aitrip-status-every))
              (guard (e (#t #f))              ;; a radio hiccup must not stop the loop
                (hud-show-rssi! (and (WiFi.isConnected) (WiFi.RSSI)))
                (let ((now (WiFi.isConnected)))
                  (when (not (eq? now aitrip-link-was))
                    (set! aitrip-link-was now)
                    (hud-show-link! now (WiFi.SSID) (WiFi.localIP))))))
            (lvgl-tick! 10))))))
