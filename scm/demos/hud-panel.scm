;;; hud-panel.scm — [P123 Part G] the PANEL half of the mini-HUD: frames off the wire onto glass.
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-22
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; *** UNTESTED END TO END AS OF 2026-09-22. ***  Written while the 4WD was inside a release
;;; sweep and could not be flashed.  Both halves it joins ARE proven separately:
;;;   * `llip-vision-send-frames` on the 4WD (Part D, in its manifest since 2026-09-17);
;;;   * `lvgl-frame-jpeg!` on this panel (this session -- a 1,411-byte JPEG decoded and rendered).
;;; The JOIN has never run.  Do not quote an fps figure from this file until it has.
;;;
;;; THIS FILE IS SMALL BECAUSE THE WIRE ALREADY EXISTED AND I ALMOST MISSED IT.
;;; My first draft of Part G step 3 was a SENDER that pushed each frame as an `#u8(...)` literal
;;; inside an `(eval ...)` -- ~3.4x expansion, and a reimplementation of something already in the
;;; 4WD's manifest.  `features/llip-vision.scm` has carried a binary frame codec since Part D:
;;; one s-expression header line, then exactly LEN raw bytes, unencoded, because every LambLisp
;;; port is already a binary port.  Measured there: a 240x240 frame is 4,954 bytes; base64 would
;;; have spent 6,605.  So the sender exists, the codec exists, and the ONLY missing piece was a
;;; SINK on this end.  `llip-vision-serve` already accepts and loops -- it writes each frame to a
;;; FILE, because Part D's consumer is a VLM on the Jetson and every vision model takes a path.
;;; A HUD's consumer is the glass, so this is that same loop with the file replaced.
;;;
;;; THE FRAME IS NOT WRITTEN TO FLASH, AND THAT IS THE WHOLE DIFFERENCE.  At 10 fps a
;;; write-then-read would be 10 flash writes a second on a part rated for ~100k erase cycles, to
;;; move bytes we are already holding in RAM.

(syslog "Loading HUD panel\n")

(define (hud-listen-port) (setting 'hud_port 8082))

;;;!< Camera geometry.  MUST match what the 4WD sends: [P123] G3 decided the car sends at panel
;;;!< scale and the panel scales nothing, so a mismatch here is a wrong-sized image, not a resize.
(define (hud-cam-w) (setting 'hud_frame_w 240))
(define (hud-cam-h) (setting 'hud_frame_h 240))

(define hud-frames 0)
(define hud-bad 0)

;;; Latest telemetry from the vehicle.  -1 means "not reported", which is rendered as "--" and is
;;; deliberately distinct from a real reading: a vehicle with no sonar and a vehicle with a clear
;;; path must not produce the same display.
(define hud-sonar-mm -1)
(define hud-motor-l 0)
(define hud-motor-r 0)

;;; Read one record.  The vehicle sends two kinds, both line-framed so that a record this reader
;;; does not understand still leaves the stream positioned at the start of the next one:
;;;   (hud-telemetry SONAR-MM LEFT RIGHT)          -- no payload
;;;   (vision-frame SEQ LEN FMT) + LEN raw bytes   -- codec in features/llip-vision.scm
;;; Returns ('telemetry . values), ('frame . bytevector), or #f at EOF or on a malformed header.
(define (hud-read-record port)
  (let ((line (read-line port)))
    (if (eof-object? line)
        #f
        (let ((hdr (guard (e (#t #f)) (read (open-input-string line)))))
          (cond
            ((not (pair? hdr)) #f)
            ((eq? 'hud-telemetry (car hdr))
             (cons 'telemetry (cdr hdr)))
            ((and (eq? 'vision-frame (car hdr))
                  (= 4 (length hdr))
                  (number? (caddr hdr))
                  (>= (caddr hdr) 0))
             (let ((bv (llip-vision-read-exactly port (caddr hdr))))
               (and bv (cons 'frame bv))))
            (else #f))))))

;;; Apply a telemetry record.  Tolerant of a short list so an older vehicle build that sends only
;;; a distance still updates the distance instead of being discarded whole.
(define (hud-apply-telemetry! vals)
  (when (pair? vals)
    (set! hud-sonar-mm (car vals))
    (when (pair? (cdr vals))  (set! hud-motor-l (cadr vals)))
    (when (and (pair? (cdr vals)) (pair? (cddr vals))) (set! hud-motor-r (caddr vals)))))

;;; The bottom strip: distance and drive, or "--" where nothing has been reported.
(define (hud-telemetry-text)
  (string-append
   "SONAR " (if (negative? hud-sonar-mm) "--" (string-append (number->string hud-sonar-mm) "mm"))
   "   MOT " (number->string hud-motor-l) " " (number->string hud-motor-r)))

;;; ---------------------------------------------------------------------------
;;; The status strip -- SSID and RSSI (owner, 2026-09-23)
;;; ---------------------------------------------------------------------------
;;;
;;; WHY THE LINK BELONGS ON THE GLASS AND NOT IN A LOG.  This panel is a WROOM-1 behind a 4-inch
;;; LCD: [B562] measured it hearing 2 access points where a bare S3 devkit hears 5, and its own
;;; RGB bus costs a further 10-13 dB on a weak signal.  So the link is the most likely thing to
;;; degrade, and the frame rate is what degrades FIRST -- silently, because a slow camera feed and
;;; a stationary scene look identical.  RSSI on screen is what lets an operator tell "nothing is
;;; moving" from "nothing is arriving", which is [P123] E15 applied to the wire.
;;;
;;; RSSI IS SIGNED AND SMALL: -68 is good, -75 is fair, -85 is trouble.  Shown raw rather than as
;;; bars because a number can be read out loud to whoever is holding the other end of the problem.

(define (hud-link-text)
  (if (WiFi.isConnected)
      (string-append "*LINK " (WiFi.SSID) "  " (number->string (WiFi.RSSI)) "dBm")
      "NO LINK"))

;;; Refresh the strips.  Cheap, but not free -- `WiFi.RSSI` queries the radio -- so the caller
;;; decides the cadence rather than doing it per frame.  At 10 fps a per-frame refresh would ask
;;; the radio ten times a second to redraw a number that changes on a scale of seconds.
;;; Drive the LAYOUT layer, not the old C++ HUD mops.  `lvgl-status!` and `lvgl-telemetry!` write
;;; objects that `lvgl-smoke` creates, and this panel's layout no longer uses it -- so those calls
;;; return #f and nothing appears, which looks like a dead link rather than a wiring mistake.
(define (hud-refresh-status!)
  (hud-show-link! (WiFi.isConnected) (WiFi.SSID) (WiFi.localIP))
  (hud-show-rssi! (and (WiFi.isConnected) (WiFi.RSSI)))
  (hud-show-stats! hud-frames hud-bad))

;;; (hud-panel-start!) -- bring up panel, LVGL and the HUD skeleton, then listen.
;;; Ordering is not arbitrary: `lvgl-init` refuses until `lcd-init` has run (it binds to the
;;; framebuffer, which does not exist before then), and `lvgl-frame-create` needs LVGL up.
(define (hud-panel-prepare!)
  (lcd-init)
  (lvgl-init)
  (load "lvgl-widgets.scm" 0)
  (load "hud-layout.scm" 0)
  (hud-layout-build!)
  (lvgl-frame-create (hud-cam-w) (hud-cam-h))
  ;; Show the telemetry line before anything arrives, so "no reading yet" is visible as "--"
  ;; rather than as an empty row that could equally mean the widget failed to build.
  (hud-show-sonar! hud-sonar-mm hud-motor-l hud-motor-r)
  ;; Show the link BEFORE any frame arrives.  A HUD that is blank until the first frame cannot
  ;; tell an operator whether it is waiting for the car or has no network -- which is the first
  ;; question asked when nothing appears.
  (hud-refresh-status!)
  (lvgl-tick! 40)                          ;;;!< first full-screen render is 20-40 ms (P231 ph.3)
  #t)

;;; Serve frames until the link closes.  Returns (frames bad).
;;;
;;; A BAD FRAME IS NOT A FATAL FRAME.  `llip-vision-read` returns #f for a truncated read or a
;;; malformed header, which over a link measured at -75 dBm ([B562]) is an ordinary event rather
;;; than a protocol violation.  Counting and continuing is right; closing the connection on the
;;; first bad frame would turn one lost packet into a dead HUD.
;;;
;;; THE TICK IS INSIDE THE LOOP AND BUDGETED.  LVGL renders nothing until `lvgl-tick!` runs, so a
;;; receive loop without one accepts frames forever and shows the first.  The budget is an
;;; argument for the same reason [P231] phase 3 made it one: this runtime publishes a worst-case
;;; pause and a UI does not get to exceed it silently.
(define (hud-panel-serve secs)
  (let ((srv (open-tcp-server-port (hud-listen-port))))
    (if (not srv)
        (begin (syslog "HUD: cannot listen on ~a\n" (hud-listen-port)) #f)
        (let ((t-end (+ (millis) (* secs 1000))))
          (syslog "HUD: listening on ~a\n" (hud-listen-port))
          (let wait ()
            (let ((conn (server-accept srv)))
              (cond
                ;; TICK LVGL WHILE WAITING.  Without this the display is frozen between the one
                ;; render at prepare time and the first arriving record: a HUD that has been
                ;; waiting ten seconds looks identical to one that has crashed, and the RSSI it
                ;; shows is however old the last paint was.  The wait is the state an operator is
                ;; most likely to be looking at, so it is the state that must stay live.
                ((and (not conn) (< (millis) t-end))
                 (hud-refresh-status!)
                 (lvgl-tick! 15)
                 (delay-ms 20)
                 (wait))
                ((not conn)
                 (close-port srv) (syslog "HUD: no sender connected\n") #f)
                (else
                 (syslog "HUD: sender connected\n")
                 (let loop ()
                   (let ((r (hud-read-record conn)))
                     (if (not r)
                         (begin
                           (close-port conn) (close-port srv)
                           (syslog "HUD: link closed, frames=~a bad=~a\n" hud-frames hud-bad)
                           (list hud-frames hud-bad))
                         (begin
                           (if (eq? 'telemetry (car r))
                               ;; Telemetry arrives just before the frame it describes, so apply it
                               ;; and draw it now -- the strip must agree with the picture below it.
                               (begin (hud-apply-telemetry! (cdr r))
                                      (hud-show-sonar! hud-sonar-mm hud-motor-l hud-motor-r))
                               (if (lvgl-frame-jpeg! (cdr r))
                                   (set! hud-frames (+ hud-frames 1))
                                   (set! hud-bad (+ hud-bad 1))))
                           ;; Every 10th frame: ~1 s at 10 fps.  See hud-refresh-status! for why
                           ;; this is not per-frame.
                           (when (zero? (modulo (+ hud-frames hud-bad) 10))
                             (hud-refresh-status!))
                           (lvgl-tick! 20)
                           (loop)))))))))))))

;;; (hud-panel-run SECS) -- the whole demo in one call, for a board that boots into it.
(define (hud-panel-run secs)
  (hud-panel-prepare!)
  (hud-panel-serve secs))

;;; (hud-panel-stats) -> (frames bad).  [P123] E15: the interface must show when it is lying.
;;; A HUD showing a stale picture is indistinguishable from one showing a current picture of a
;;; stationary scene -- the bad count is the only thing that tells an operator which they have.
(define (hud-panel-stats) (list hud-frames hud-bad))

(syslog "HUD panel loaded\n")
