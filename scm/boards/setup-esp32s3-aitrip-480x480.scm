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
  ;; ROTATION COMES FROM A SETTING, because the orientation that suits the RADIO is not
  ;; necessarily the one that suits the viewer.  Measured 2026-09-25 on this board: rotating it
  ;; moved RSSI from -74 dBm to -51 dBm at the same spot -- about 23 dB, more than carrying it
  ;; across the room was worth.  The antenna is directional, so the panel gets mounted whichever
  ;; way the link wants and the IMAGE is what adapts.  0 or 180 only; see (lcd-init).
  (lcd-init (setting 'lcd_rotation 0))
  (lvgl-init)
  (load "lvgl-widgets.scm" 0)       ;; widget layer, composed from the thin shim
  (load "hud-layout.scm" 0)         ;; which widgets exist, where, and what they mean
  ;; The BINARY FRAME CODEC, and it must be loaded BEFORE hud-panel.scm needs it.  [B641]
  ;; `hud-read-record-bounded` calls `llip-vision-read-exactly` to read a frame body; that
  ;; procedure lives here.  BEING IN THE MANIFEST IS NOT ENOUGH -- the manifest only puts the
  ;; file on the filesystem, and this file was shipped for days while nothing loaded it.  The
  ;; symbol was therefore unbound, every frame header raised, `hud-panel-poll!`'s guard turned
  ;; the raise into #f, and #f is this protocol's EOF -- so the panel hung up on a healthy
  ;; vehicle and reported `frames 0 bad 0`.  Telemetry was unaffected (it touches no codec),
  ;; which is exactly why it read as a camera or network fault for three sessions.
  (if (file-exists? "llip-vision.scm") (load "llip-vision.scm" 0) #f)
  ;; The HUD RECEIVER -- telemetry and camera frames from the vehicle.  Loaded here so the
  ;; app-loop's poll has something to call; without it the panel builds a display that nothing
  ;; ever feeds, which looks identical to a vehicle that is not sending.
  (if (file-exists? "hud-panel.scm") (load "hud-panel.scm" 0) #f)
  ;; SAY SO IF THE CODEC IS MISSING, rather than discovering it one dropped frame at a time.
  ;; A receiver that cannot read a body is not a receiver; announce it at boot, where it is
  ;; read, instead of laundering it into an EOF on every frame.
  (if (defined? 'llip-vision-read-exactly)
      #t
      (syslog "HUD: llip-vision.scm absent -- telemetry will work, camera frames CANNOT\n"))
  (hud-layout-build!)
  (hud-show-link! (WiFi.isConnected) (WiFi.SSID) (WiFi.localIP))
  (hud-show-rssi! (and (WiFi.isConnected) (WiFi.RSSI)))
  ;; NTP IS NOT DONE HERE, AND A ONE-SHOT SYNC AT START-UP IS WHY.  Measured 2026-09-25: at 18.7 s
  ;; after boot this board still reads WL_DISCONNECTED, so a sync attempted at panel start fails
  ;; with `could not send data: 118` and never runs again -- the clock then shows dashes forever
  ;; on a board that associated four seconds later.  `nettime-tick!` exists for this: it costs
  ;; nothing while there is no link and syncs ON THE no-link -> link EDGE, so it catches the
  ;; association whenever it happens rather than guessing when that will be.  It is called from
  ;; the refresh block below.
  (if (file-exists? "nettime.scm") (load "nettime.scm" 0) #f)
  (hud-clock-sync!)                 ;; sample whatever the clock says now; dashes until NTP lands
  (hud-show-clock! (hud-clock-now))
  ;; [B628] Open the listening socket ONCE here; the app-loop polls it every tick.  Guarded so a
  ;; port already in use leaves a working display rather than an unstarted panel.
  ;; The camera image: a centred 240x240 RGB565 surface the receiver decodes JPEGs into.  The
  ;; vehicle's camera is initialised at FRAMESIZE_240X240 and hud-panel.scm states the car sends
  ;; at panel scale and the panel scales nothing -- so these two numbers are one agreement, not
  ;; two settings, and changing either alone produces a wrong-sized picture rather than a resize.
  (if (defined? 'lvgl-frame-create)
      (guard (e (#t #f)) (lvgl-frame-create (hud-cam-w) (hud-cam-h)))
      #f)
  ;; CAMERA IMAGE ORIENTATION, AND IT IS NOT THE SAME THING AS `lcd_rotation`.  That one turns the
  ;; WHOLE PANEL -- clock, link line and picture together -- and exists because the glass is mounted
  ;; upside down in the enclosure.  This turns ONLY the decoded camera image inside its surface,
  ;; because the vehicle's camera has its own mounting angle that has nothing to do with the panel's.
  ;; Conflating them rotates the text along with the picture and looks like a display fault.
  ;; WHY THIS LINE EXISTS AT ALL: `lvgl-frame-rotate!` had NO Scheme caller anywhere in scm/, so the
  ;; capability was reachable only by typing it at the REPL and died at the next reboot -- a setting
  ;; that has to be re-applied by hand after every boot is indistinguishable, from the front, from
  ;; one that does not work.  Applied here, at panel start, so it survives a restart like every
  ;; other panel setting.  Degrees clockwise; 0, 90, 180 or 270.
  (if (and (defined? 'lvgl-frame-rotate!) (positive? (setting 'hud_frame_rot 0)))
      (guard (e (#t (syslog "[panel] frame rotation FAILED: ~a\n" e)))
        (lvgl-frame-rotate! (setting 'hud_frame_rot 0)))
      #f)
  ;; OPEN THE RECEIVER, AND SAY SO IF IT DID NOT OPEN.  The guard here is deliberate -- a port that
  ;; is momentarily in use must leave a WORKING DISPLAY rather than an unstarted panel -- but
  ;; discarding its result hid the one post-condition the receiver depends on.  A panel whose socket
  ;; never opened comes up fully painted, reports `frames 0 bad 0`, and is indistinguishable from a
  ;; healthy one waiting for a vehicle: the counters read the same and the glass looks the same.
  ;; So keep the guard and REPORT, rather than choosing between them.
  (if (defined? 'hud-panel-listen!)
      (if (guard (e (#t #f)) (hud-panel-listen!))
          #t
          (warn "HUD: receiver did NOT open -- no vehicle can connect; will retry from the loop\n"))
      #f)
  (hud-show-sonar! -1 0 0)
  (hud-show-stats! 0 0)
  (lvgl-tick! 40)                   ;; first full render
  ;; RE-SYNC THE SCAN AFTER THE FIRST PAINT, NOT ONLY AT PANEL INIT.
  ;;
  ;; A starved RGB DMA makes the peripheral emit dummy bytes, which desynchronise the panel's read
  ;; address from its output address; the picture is then displaced and STAYS displaced, because
  ;; nothing in the ordinary refresh path re-aligns it.  The driver already re-syncs once when the
  ;; panel comes up -- but bringing LVGL up and painting the first full screen is ITSELF a starving
  ;; event, and it happens after that point: buffers are allocated, the whole framebuffer is written,
  ;; and the loader is still reading .scm files from flash.  So the init-time re-sync fires too early
  ;; to cover the very work that displaces the scan.
  ;; MEASURED: with the init re-sync alone the display came up blank, then rolled; one re-sync here
  ;; brought it back and a second aligned it.  Cost is one deferred flag the driver services at the
  ;; next VSYNC, so the picture snaps at a frame boundary rather than tearing.
  (if (defined? 'lcd-restart) (lcd-restart) #f)
  (lvgl-tick! 10)
  (if (defined? 'lcd-restart) (lcd-restart) #f)
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
;;; A clock displayed to the second must be REFRESHED at least that often, or it lies by
;;; up to its own resolution -- a reading that is simply late is indistinguishable from a
;;; stopped one.  20 ticks is comfortably under a second at this loop rate.
(define aitrip-status-every 20)

;;; RSSI IS REFRESHED SLOWER THAN THE CLOCK, AND FOR THE OPPOSITE REASON.
;;; `readout-set!` now skips a repaint when the text is unchanged, which silences every steady
;;; field for free -- the clock included, since it holds one string for a whole second.  RSSI is
;;; the field that defeats that: dBm from the radio moves on nearly every sample, so the text
;;; genuinely differs each time and the skip never fires.  Refreshed at the status rate it
;;; repainted ~10x/s, which is what showed as flicker on the line under LINK (owner, 2026-09-26).
;;; A second's resolution on signal strength loses an operator nothing -- nobody acts on a 100 ms
;;; change in dBm -- and the VALUE stays exact; only the refresh slows.  Multiplier, not a second
;;; tick counter, so it cannot drift out of step with the status tick.
(define aitrip-rssi-every 10)   ;;;!< status ticks between RSSI repaints: ~1 Hz at 10 Hz status

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
            ;; [B628] THE HUD RECEIVER IS POLLED, NOT SERVED.  One non-blocking step per tick:
            ;; accept if nobody is connected, read at most one record if data is ready, return.
            ;; The blocking `hud-panel-serve` it replaces could keep the loop forever, which cost
            ;; this board its REPL and wedged the sending vehicle behind it.  Guarded because a
            ;; receive fault must never be able to stop the display loop.
            (when (defined? 'hud-panel-poll!)
              (guard (e (#t #f)) (hud-panel-poll!)))
            ;; WHAT GETS REWRITTEN HERE, AND HOW OFTEN -- the three rates are deliberate.
            ;; The state line is drawn once at start-up and again only if the link state itself
            ;; changes, so a steady link never touches it.  The clock is offered every status
            ;; tick because a second-resolution clock must be refreshed at least that often to
            ;; avoid lying by its own resolution -- but `readout-set!` drops the ~9 in 10 of those
            ;; that would redraw an identical string, so it repaints about once a second.  RSSI is
            ;; the one field whose text really does differ every sample, so no comparison can help
            ;; it and it is rate-limited instead; see `aitrip-rssi-every`.
            (when (zero? (modulo aitrip-tick-count aitrip-status-every))
              (guard (e (#t #f))              ;; a radio hiccup must not stop the loop
                ;; RETRY THE ASSOCIATION.  This panel is headless and its only other route in is
                ;; serial, which resets the board -- so a lost association must be recovered from
                ;; inside the loop or not at all.  Measured on this board: association took 1.1 s,
                ;; 1.3 s and 7.8 s across four boots and outright missed a 10 s budget on the
                ;; fourth, so the race is real rather than theoretical.  `wifi-tick!` is self-gated
                ;; and non-blocking; it starts an attempt and leaves the result to the next tick.
                (if (defined? 'wifi-tick!) (wifi-tick!))
                ;; RETRY THE RECEIVER the way the radio is retried.  A port busy at boot is exactly
                ;; the transient the guard above exists for, and retrying turns a permanent dead
                ;; receiver into a delayed one.  Idempotent: `hud-panel-listen!` returns immediately
                ;; when the socket is already open, so this costs one test per status tick.
                ;; ONLY WITH A NETWORK.  Opening a listening socket before the stack is up used to
                ;; ABORT THE CHIP -- NetworkServer::begin reaches lwip_select, which takes a
                ;; semaphore that does not exist yet, and an assert reboots the board.  A Scheme
                ;; guard cannot catch that; an assert aborts, it does not raise.  So this retry,
                ;; written to make a busy port recoverable, turned a board with no association into
                ;; a REBOOT LOOP: listen, abort, reboot, listen.  The runtime now refuses the open
                ;; honestly (see ll_vm_port.cpp), and this asks first as well, because a retry that
                ;; cannot succeed should not run.
                (if (and (defined? 'hud-panel-listen!) (not hud-panel-srv) (WiFi.isConnected))
                    (guard (e (#t #f))
                      (if (hud-panel-listen!)
                          (syslog "HUD: receiver opened on retry\n")
                          #f)))
                ;; Let nettime decide whether a sync is due; re-sample our epoch only when it
              ;; actually set the clock, so a failed attempt cannot overwrite a good reading.
              (if (defined? 'nettime-tick!)
                  (guard (e (#t #f))
                    (if (nettime-tick!) (hud-clock-sync!) #f)))
                (hud-show-clock! (hud-clock-now))
                (when (zero? (modulo aitrip-tick-count
                                     (* aitrip-status-every aitrip-rssi-every)))
                  (hud-show-rssi! (and (WiFi.isConnected) (WiFi.RSSI))))
                (let ((now (WiFi.isConnected)))
                  (when (not (eq? now aitrip-link-was))
                    (set! aitrip-link-was now)
                    (hud-show-link! now (WiFi.SSID) (WiFi.localIP))))))
            (lvgl-tick! 10))))))
