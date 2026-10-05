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
  (hud-show-clock! (hud-clock-now))
  (hud-show-link! (WiFi.isConnected) (WiFi.SSID) (WiFi.localIP))
  (hud-show-rssi! (and (WiFi.isConnected) (WiFi.RSSI)))
  (hud-show-stats! hud-frames hud-bad))

;;; ===========================================================================================
;;; NON-BLOCKING RECEIVER [B628] -- the shape every other loop-sharing service in this tree uses.
;;; ===========================================================================================
;;;
;;; `hud-panel-serve` below owns the main loop for its whole window and, worse, could never give
;;; it back: measured 2026-09-25, the panel stopped answering its REPL permanently while still
;;; replying to pings, and only a reset recovered it.  ICMP is answered by lwIP inside the network
;;; stack, independent of the Scheme loop, so a wedged panel looks healthy to every network check
;;; anyone reaches for first.  REPL silence WITH successful pings is the signature.
;;;
;;; AND THE WEDGE PROPAGATES BACKWARDS.  A receiver that stops reading makes the SENDER's write
;;; block once the TCP window fills, so the vehicle's main loop wedged too -- taking its sonar,
;;; its reflexes and its LLIP control channel with it.  One stalled display disabled the robot.
;;;
;;; THE RULE THIS BREAKS: anything sharing the main loop must be a POLL that returns every tick --
;;; `llip-server-poll` is documented exactly that way.  A service that "runs until done" cannot
;;; live on a cooperative loop, because "done" is decided by a peer you do not control.
;;;
;;; TWO BOUNDS, BOTH NECESSARY:
;;;   * `char-ready?` before any read, so a tick with no data costs nothing and never blocks;
;;;   * a DEADLINE inside the record read, because `char-ready?` promises ONE character and a
;;;     record needs a whole line (or LEN bytes).  A peer that sends half a header and dies would
;;;     otherwise block forever on a port that was "ready".
;;; On timeout the connection is CLOSED rather than retried: a peer that cannot finish a record
;;; is not going to, and holding it costs a tick every time round.

(define hud-panel-srv   #f)             ;;;!< listening port, created once
(define hud-panel-conn  #f)             ;;;!< current sender, or #f
(define hud-panel-read-ms 25)           ;;;!< per-tick ceiling on finishing one record

;;; A CONNECTION THAT NEVER SPEAKS MUST BE DROPPED, OR IT BLOCKS EVERY LATER SENDER.
;;; Measured 2026-09-25 and it is not a corner case: a sender that wedges or is killed leaves its
;;; socket in this board's ACCEPT BACKLOG.  The poll accepts that corpse, holds it, and -- since it
;;; never sends -- `char-ready?` is correctly #f forever, so the close path never runs and no real
;;; sender is ever accepted.  The next vehicle to connect then fills its TCP window with nobody
;;; reading and WEDGES ITSELF.  One dead socket on the display disabled the robot, repeatedly.
;;; The symptom gives no hint: the panel reports "listening", holds a connection, and shows zero
;;; frames, which reads as a vehicle that is not sending.
(define hud-panel-idle-ms 8000)         ;;;!< silence after which a SPOKEN-TO connection is dropped

;;; A CONNECTION THAT HAS NEVER SAID ANYTHING GETS A MUCH SHORTER ROPE THAN ONE THAT HAS.
;;; The two cases are not alike and sharing one timeout was costing real sends.  A live sender
;;; writes as soon as it connects -- the vehicle's codec does exactly that -- so silence right
;;; after accept means the socket is almost certainly finished, while silence from a peer that
;;; has already delivered records is an ordinary gap between frames.  Measured 2026-09-26: a send
;;; that arrives while the slot is still occupied by a previous connection is LOST, not delayed
;;; (checked at +2/+6/+14 s -- the value never appears), so the width of that window is the width
;;; of the hole.  Eight seconds is wider than a whole send cycle; two is not.
;;; THIS NARROWS THE HOLE, IT DOES NOT CLOSE IT -- see the registry entry.  Closing it needs the
;;; port layer to say "peer closed", which `char-ready?` does not report for these sockets.
(define hud-panel-hello-ms 2000)        ;;;!< silence after ACCEPT, before anything is received

;;; A frame body gets its own budget, much larger than the per-line tick budget and still finite.
;;; It exists to stop a stalled or dribbling sender parking the loop, not to pace a healthy one.
;;;
;;; [B689] THIS WAS 500 ms AND IT WAS THE PRIMARY FAULT, not a safety margin.  The old comment
;;; asserted that a 240x240 JPEG "arrives in well under this".  That was never measured and is
;;; FALSE on this link.  Measured A/B on the live pair, same sender, same radio, 76 s per arm:
;;;
;;;     body_ms  500  ->   21 frames = 0.28 fps,  hud-panel-conn 0 at both samples
;;;     body_ms 5000  ->  214 frames = 2.81 fps,  hud-panel-conn 1 at both samples
;;;
;;; Ten times the throughput, and the difference between a link that drops on nearly every frame
;;; and one that stays up.  At 500 ms almost every body missed the ceiling, desynced, and cost the
;;; CONNECTION -- so the sender spent its time reconnecting instead of sending.
;;;
;;; WHY A GENEROUS CEILING IS SAFE HERE: it is not the only backstop.  `hud-panel-idle-ms` (8 s)
;;; still drops a connection that has gone quiet, and `hud-panel-hello-ms` (2 s) still drops one
;;; that never spoke.  This number only bounds a body ALREADY IN PROGRESS, where the cost of being
;;; wrong in the tight direction is the whole session and the cost of being wrong in the loose
;;; direction is a few seconds of patience.
;;;
;;; THE GENERAL SHAPE, worth more than the number: a timeout justified by an UNMEASURED claim about
;;; how long the thing takes.  The comment read like evidence, so nobody re-derived it, and the
;;; budget outlived the conditions it was guessed for.
(define hud-panel-body-ms 5000)         ;;;!< ceiling on ONE frame body, after its header is read
(define hud-panel-spoke #f)             ;;;!< has the held connection delivered a record yet?
(define hud-panel-last-ms 0)            ;;;!< millis of the last accept or successful record

;;; (hud-panel-listen!) -> #t/#f.  Open the listening port.  Idempotent.
(define (hud-panel-listen!)
  (if hud-panel-srv
      #t
      (let ((srv (open-tcp-server-port (hud-listen-port))))
        (set! hud-panel-srv srv)
        (if srv
            (begin (syslog "HUD: listening on ~a (non-blocking)\n" (hud-listen-port)) #t)
            (begin (syslog "HUD: cannot listen on ~a\n" (hud-listen-port)) #f)))))

;;; Read one line, bounded.  Returns the string, or #f on EOF or deadline.
;;; Deliberately NOT `read-line`: that blocks until a newline arrives, which is the bug.
;;; RETURNS THREE DIFFERENT THINGS, AND THE CALLER MUST TELL THEM APART.  It used to answer #f
;;; for both "the peer hung up" and "the deadline passed mid-line", and the caller closed the
;;; connection on either -- so a sender that was merely slower than one tick was dropped as though
;;; it had disconnected, mid-frame, and got EPIPE on its next write.
;;;   'eof      the peer closed            -> the link really is gone
;;;   'timeout  deadline, line incomplete  -> the peer is FINE; ask again next tick
;;;   string    a complete line
;;; THE PARTIAL LINE MUST SURVIVE THE TICK, OR RETURNING 'timeout MAKES THINGS WORSE.
;;; Reading characters and then answering 'timeout DISCARDS them, so the next tick resumes in the
;;; middle of a record and reads the remainder as though it were a whole line.  Measured
;;; 2026-09-26, and it is not theoretical: a sender that wrote `(hud-telemetry 1234 ` then the
;;; rest 1.5 s later had the tail read as the line `0 0)`, which parses to `0`, is not a pair, and
;;; is reported 'malformed -- so keeping the connection alive turned a lost record into a lost
;;; record AND a dropped sender.  The accumulator therefore lives across calls.
;;; It is a single global because this receiver holds exactly ONE connection at a time; it is reset
;;; wherever that connection changes (accept, and every close path), so a new sender can never
;;; inherit the previous one's half-line.
(define hud-panel-partial (list))       ;;;!< reversed chars of a line not yet terminated

(define (hud-read-line-bounded port deadline)
  (let lp ((acc hud-panel-partial))
    (cond
     ((> (millis) deadline)
      (set! hud-panel-partial acc)              ;;;!< resume here next tick
      'timeout)
     ((not (char-ready? port)) (lp acc))         ;; spin, but only until the deadline
     (else
      (let ((c (read-char port)))
        (cond
         ((eof-object? c) (set! hud-panel-partial (list)) 'eof)
         ((char=? c #\newline)
          (set! hud-panel-partial (list))
          (list->string (reverse acc)))
         (else (lp (cons c acc)))))))))

;;; Read one record within the deadline.  Same two record kinds as `hud-read-record`.
;;; -> ('telemetry . vals) | ('frame . bv) | 'eof | 'timeout | 'malformed.
;;; Only 'eof means the connection is finished.  Everything else leaves it usable.
(define (hud-read-record-bounded port deadline)
  (let ((line (hud-read-line-bounded port deadline)))
    (cond
     ((eq? 'eof line)     'eof)
     ((eq? 'timeout line) 'timeout)
     (else
      (let ((hdr (guard (e (#t #f)) (read (open-input-string line)))))
        (cond
         ((not (pair? hdr)) 'malformed)
         ((eq? 'hud-telemetry (car hdr)) (cons 'telemetry (cdr hdr)))
         ((and (eq? 'vision-frame (car hdr)) (= 4 (length hdr))
               (number? (caddr hdr)) (>= (caddr hdr) 0))
          ;; BOUND THE BODY READ, AND ACCEPT THAT FAILING IT COSTS THE CONNECTION.
          ;; Unbounded, the shared helper holds this tick for as long as a peer keeps dribbling
          ;; bytes (its stall counter is reset by progress, so it limits SILENCE, not duration) --
          ;; which parks the cooperative loop and with it the REPL.  Bounded, a body that does not
          ;; finish leaves the header and part of the body already consumed, so the stream cannot
          ;; be re-framed and the only correct action is to drop the link.  That is a DIFFERENT
          ;; outcome from 'timeout, which means "ask me again on the same connection", so it gets
          ;; its own name rather than being folded into one of the others.
          (let ((bv (llip-vision-read-exactly port (caddr hdr)
                                              (+ (millis) hud-panel-body-ms))))
            (if bv (cons 'frame bv) 'desync)))
         (else 'malformed)))))))

;;; (hud-panel-poll!) -> #t if it did work this tick.  CALL FROM THE APP-LOOP, every tick.
;;; Never blocks: no connection -> one non-blocking accept; connection with no data -> returns.
(define (hud-panel-poll!)
  (cond
   ((not hud-panel-srv) #f)
   ((not hud-panel-conn)
    (let ((c (server-accept hud-panel-srv)))     ;;;!< returns #f when nobody is waiting
      (when c
        (set! hud-panel-conn c)
        (set! hud-panel-spoke #f)                ;;;!< on the short rope until it delivers something
        (set! hud-panel-partial (list))          ;;;!< never inherit a previous sender's half-line
        (set! hud-panel-last-ms (millis))
        (syslog "HUD: sender connected\n"))
      (and c #t)))
   ((not (char-ready? hud-panel-conn))
    ;; Idle.  Cheap -- but not free forever, and the budget depends on whether this peer has ever
    ;; spoken: an accepted socket that goes straight to silence is holding the slot against live
    ;; senders, and every one that arrives meanwhile is lost outright.
    (let ((budget (if hud-panel-spoke hud-panel-idle-ms hud-panel-hello-ms)))
      (when (> (- (millis) hud-panel-last-ms) budget)
        (guard (e (#t #f)) (close-port hud-panel-conn))
        (set! hud-panel-conn #f)
        (set! hud-panel-partial (list))
        (syslog "HUD: dropping a sender that sent nothing for ~a ms (spoke=~a)\n"
                budget hud-panel-spoke)))
    #f)
   (else
    (set! hud-panel-last-ms (millis))             ;;;!< it spoke: it is alive
    (let ((r (guard (e (#t 'raised))
               (hud-read-record-bounded hud-panel-conn (+ (millis) hud-panel-read-ms)))))
      (cond
       ;; NOT FINISHED THIS TICK IS NOT A DISCONNECTION.  Keep the link and ask again; dropping
       ;; here is what made a sender that needed two ticks indistinguishable from one that hung up.
       ((eq? 'timeout r) #f)
       ((eq? 'eof r)
        (guard (e (#t #f)) (close-port hud-panel-conn))
        (set! hud-panel-conn #f)
        (set! hud-panel-partial (list))
        (syslog "HUD: sender closed, frames=~a bad=~a\n" hud-frames hud-bad)
        #f)
       ;; SAY WHICH ONE HAPPENED.  The old code logged "sender closed" for every outcome,
       ;; including ones where the sender was demonstrably still connected -- a cause asserted,
       ;; never observed, which is what sends the next reader to the network layer.
       ((or (eq? 'malformed r) (eq? 'raised r) (eq? 'desync r))
        (guard (e (#t #f)) (close-port hud-panel-conn))
        (set! hud-panel-conn #f)
        (set! hud-panel-partial (list))
        (syslog "HUD: dropping sender -- ~a record, frames=~a bad=~a\n" r hud-frames hud-bad)
        #f)
       ((eq? 'telemetry (car r))
        (set! hud-panel-spoke #t)                ;;;!< earns the long idle budget
        (hud-apply-telemetry! (cdr r))
        (hud-show-sonar! hud-sonar-mm hud-motor-l hud-motor-r)
        #t)
       (else
        (set! hud-panel-spoke #t)
        (if (lvgl-frame-jpeg! (cdr r))
            (set! hud-frames (+ hud-frames 1))
            (set! hud-bad (+ hud-bad 1)))
        (when (zero? (modulo (+ hud-frames hud-bad) 10))
          (hud-show-stats! hud-frames hud-bad))
        #t))))))

;;; (hud-panel-start!) -- bring up panel, LVGL and the HUD skeleton, then listen.
;;; Ordering is not arbitrary: `lvgl-init` refuses until `lcd-init` has run (it binds to the
;;; framebuffer, which does not exist before then), and `lvgl-frame-create` needs LVGL up.
(define (hud-panel-prepare!)
  ;; ROTATION COMES FROM A SETTING, because the orientation that suits the RADIO is not
  ;; necessarily the one that suits the viewer.  Measured 2026-09-25 on this board: rotating it
  ;; moved RSSI from -74 dBm to -51 dBm at the same spot -- about 23 dB, more than carrying it
  ;; across the room was worth.  The antenna is directional, so the panel gets mounted whichever
  ;; way the link wants and the IMAGE is what adapts.  0 or 180 only; see (lcd-init).
  (lcd-init (setting 'lcd_rotation 0))
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

;;; DEPRECATED [B628] -- BENCH ONLY, AND IT CAN WEDGE THE BOARD.  Use `hud-panel-listen!` once and
;;; `hud-panel-poll!` from the app-loop instead.
;;;
;;; This owns the main loop for its entire window and, on a peer that stops mid-record, never
;;; returns at all: the panel kept answering pings and never answered its REPL again, recoverable
;;; only by reset, and the sender wedged behind it.  Kept because it is still the simplest way to
;;; drive a one-shot capture on a bench board with nothing else to do, and deleting it would
;;; silently change what existing callers mean.  Do NOT call it from a board that must stay
;;; reachable.
;;;
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
