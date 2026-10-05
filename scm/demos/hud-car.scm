;;; Copyright 2026 by Frobenius Norm LLC 2026-09-23
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; hud-car.scm -- the VEHICLE half of the mini-HUD: camera frames and telemetry to a panel.
;;;
;;; The panel half is demos/hud-panel.scm.  This side runs on the car, which is the only board
;;; carrying both the camera and the sonar, and pushes two kinds of record over one connection:
;;;
;;;   (hud-telemetry SONAR-MM LEFT RIGHT)   one line, no payload
;;;   (vision-frame SEQ LEN FMT) + LEN raw bytes   -- the codec in features/llip-vision.scm
;;;
;;; Both are line-framed s-expressions, so the receiver dispatches on the first element and a
;;; reader that does not understand one record can still find the start of the next.
;;;
;;; TELEMETRY IS SENT BEFORE THE FRAME IT DESCRIBES.  A distance and a picture taken a frame apart
;;; disagree while the vehicle is moving, and a HUD that shows them together is asserting they
;;; belong to the same instant.  Sending the reading first makes it the reading that was true when
;;; the shutter opened, not one sampled after the image had already been encoded and sent.
;;;
;;; SONAR IS SENT IN MILLIMETRES AS AN INTEGER.  `Sonar.latest` is a float in metres; a float
;;; crossing the wire costs its printed representation and arrives needing parsing on a board that
;;; is busy scanning a display.  Millimetres as an exact integer is the same information, and the
;;; panel can render it without touching the numeric tower.

(syslog "Loading HUD car\n")

;;; THE CODEC MUST BE LOADED HERE, AND ITS ABSENCE MUST BE ANNOUNCED.
;;;
;;; This file calls `llip-vision-capture-send!`, which lives in features/llip-vision.scm.  BEING IN
;;; THE MANIFEST IS NOT ENOUGH: the manifest puts the file on the filesystem, and nothing loads it.
;;; Without this the symbol is unbound, the FIRST frame raises, and `hud-car-run` aborts having
;;; already connected and logged "streaming to ..." -- so the vehicle looks healthy from every angle
;;; and the panel reports `frames 0 bad 0`, which is exactly what a correct receiver shows when
;;; nobody is sending.  Two zeroes, opposite causes, no way to tell them apart from the bench.
;;;
;;; This is the panel half's defect in mirror image; that side was fixed to load the codec AND to say
;;; so when the file is missing, and this side was left as it was.  When one end of a protocol is
;;; repaired, check the other -- the two halves share a failure mode, not just a wire format.
(if (file-exists? "llip-vision.scm") (load "llip-vision.scm" 0) #f)
(if (defined? 'llip-vision-capture-send!)
    #t
    (warn "HUD car: llip-vision.scm absent -- telemetry will work, camera frames CANNOT\n"))

(define (hud-car-port)     (setting 'hud_port 8082))
(define (hud-car-host)     (setting 'hud_host "10.42.1.10"))
(define (hud-car-frame-w)  (setting 'hud_frame_w 240))
(define (hud-car-frame-h)  (setting 'hud_frame_h 240))

;;; Sonar, as an exact integer count of millimetres.  `Sonar.latest` is maintained by `Sonar.loop`;
;;; this reads it rather than pinging, so it never competes with the obstacle reflex for the sensor.
;;; Returns -1 when there is no sonar on this board, which the panel renders as "--" rather than as
;;; a distance -- an absent sensor and a clear path must not look the same.
(define (hud-car-sonar-mm)
  (if (defined? 'Sonar.latest)
      (exact (round (* 1000 Sonar.latest)))
      -1))

;;; Motor state as two small integers, -100..100 percent.  Absent drive -> 0 0.
(define (hud-car-motor-l) (if (defined? 'Motor.left-pct)  Motor.left-pct  0))
(define (hud-car-motor-r) (if (defined? 'Motor.right-pct) Motor.right-pct 0))

;;; Write one telemetry record.  Cheap enough to send with every frame: one short line.
(define (hud-car-send-telemetry! port)
  (write (list 'hud-telemetry (hud-car-sonar-mm) (hud-car-motor-l) (hud-car-motor-r)) port)
  (write-string "\n" port)
  (flush-output-port port))

;;; ---------------------------------------------------------------------------------------------
;;; [B690] THE LINK IS STATE, AND IT IS OWNED BY A TICK -- NOT BY ONE BLOCKING CALL.
;;;
;;; This used to be a single `hud-car-run` that opened ONE connection and looped until its deadline,
;;; never asking whether the far end was still there.  When the panel hung up ([B689] drops the link
;;; if one frame body misses its 500 ms deadline) the vehicle noticed nothing: it did not reconnect,
;;; did not log, and did not return -- it held its REPL for the remaining ~57 minutes of its run
;;; while sending into a dead socket.  The panel showed the LAST DECODED FRAME as a still image,
;;; which looks exactly like a live picture of a stationary scene, and both boards looked healthy
;;; from every angle.  It took a frame counter on the glass to tell the two apart.
;;;
;;; EITHER DEFECT ALONE IS SURVIVABLE -- a receiver that drops a bad link is correct, and a sender
;;; that reconnects makes a drop cost one gap.  Together they turn one late frame body into a dead
;;; HUD for the rest of the session.  This is the sender half.
;;;
;;; THE SHAPE IS `wifi-tick!`'s, DELIBERATELY: the entry named it as the thing to copy, and it is
;;; the same problem -- an asynchronous link that can drop at any time, on a board nobody can reach
;;; once it stops answering.  Non-blocking, cheap, everything behind a time gate, backoff on retry,
;;; and a message on the DOWN edge because a link that dropped and a link that never came up look
;;; identical from outside.

(define hud-car-conn       #f)   ;;;!< live port, or #f when disconnected
(define hud-car-seq        0)    ;;;!< frames sent across ALL connections this session
(define hud-car-drops      0)    ;;;!< how many times the link went away -- the number worth seeing
(define hud-car-was-up     #f)   ;;;!< for down-edge logging
(define hud-car-last-try   0)    ;;;!< millis of the last connect attempt
(define hud-car-backoff    0)    ;;;!< current retry interval, doubling to hud_retry_max_ms
(define hud-car-last-frame 0)    ;;;!< millis of the last frame sent, for the rate gate
(define hud-car-cam-ready  #f)   ;;;!< camera-init is once per boot, NOT once per connection

;;; ELAPSED, WRAP-TOLERANT -- the same reasoning as `wifi-since`, and it is not theoretical here
;;; either: `millis` is a 32-bit millisecond counter that wraps after ~49 days, a bare subtraction
;;; goes NEGATIVE across the wrap, and a retry gated on `>=` would then wait out the whole counter.
;;; A vehicle would stop reconnecting exactly once every seven weeks.  Treat negative as "due now".
(define (hud-car-since then)
  (let ((d (- (millis) then))) (if (negative? d) 999999 d)))

;;; Drop the link and say so ONCE.  Safe to call when already disconnected.
(define (hud-car-disconnect! why)
  (when hud-car-conn
    (guard (e (#t #f)) (close-port hud-car-conn))
    (set! hud-car-conn #f)
    (set! hud-car-drops (+ hud-car-drops 1))
    (set! hud-car-last-try (millis))
    (when hud-car-was-up
      (warn "HUD car: link LOST (~a) after ~a frame(s), drop ~a -- retrying\n"
            why hud-car-seq hud-car-drops))
    (set! hud-car-was-up #f)))

;;; Try to connect, behind the backoff gate.  Returns #t if the link is up on return.
;;;
;;; `open-tcp-client-port` RETURNS #f ON FAILURE and that is load-bearing here -- it did not always.
;;; Until [B474] every opener returned a truthy port wrapping a dead socket, so `(if conn ...)`
;;; passed with nothing listening and writes vanished.  A reconnect loop built on the old behaviour
;;; would "succeed" instantly, forever, and spin frames into nowhere.
(define (hud-car-connect!)
  (if hud-car-conn
      #t
      (if (< (hud-car-since hud-car-last-try) hud-car-backoff)
          #f                                   ;;;!< still backing off: cheap, no radio work
          (begin
            (set! hud-car-last-try (millis))
            (let ((c (guard (e (#t #f))
                            (open-tcp-client-port (hud-car-host) (hud-car-port)))))
              (if (not c)
                  (begin
                    ;; BACK OFF.  A vehicle that cannot reach the panel is doing real radio work on
                    ;; every attempt, and it shares a board with a camera; retrying flat out is
                    ;; sustained interference rather than an occasional cost.  Same argument as
                    ;; `wifi-tick!`'s, which measured it against a display on the receiving end.
                    (set! hud-car-backoff
                          (min (setting 'hud_retry_max_ms 60000)
                               (max (setting 'hud_retry_ms 2000) (* 2 hud-car-backoff))))
                    #f)
                  (begin
                    (set! hud-car-conn c)
                    (set! hud-car-backoff (setting 'hud_retry_ms 2000))  ;;;!< next drop recovers fast
                    (set! hud-car-was-up #t)
                    ;; ONCE PER BOOT, NOT ONCE PER CONNECTION.  Re-initialising the camera on every
                    ;; reconnect would make a flapping link reset the sensor repeatedly, and the
                    ;; mode is a property of the CAMERA, not of the socket.
                    ;; JPEG, NOT RGB565, AND THE LABEL DEPENDS ON IT: `llip-vision-capture-send!`
                    ;; writes 'jpeg into every frame header regardless of what the sensor produces,
                    ;; so a camera left in rgb565 puts 115,200 raw bytes on the wire under a header
                    ;; that says JPEG.  The receiver hands that to a JPEG decoder, which rejects it,
                    ;; and counts the frame bad -- a frame that arrived perfectly, discarded because
                    ;; its label was wrong.  It is also ~5 KB instead of ~115 KB, which over this
                    ;; radio is the difference between video and a slideshow.
                    (unless hud-car-cam-ready
                      (guard (e (#t #f)) (camera-init 'jpeg))
                      (set! hud-car-cam-ready #t))
                    (syslog "HUD car: streaming to ~a:~a\n" (hud-car-host) (hud-car-port))
                    #t))))))) 

;;; (hud-car-tick!) -- call from an application loop.  Non-blocking and cheap.
;;;
;;; IT MUST NOT BLOCK, which is the half of [B690] that is NOT about reconnecting.  The old blocking
;;; run held the REPL for its whole duration, so the board could not be asked anything and could not
;;; be told to stop -- `neteval` connected and returned no output, and recovery meant a serial reset,
;;; which reboots the board and destroys the state being investigated.  A sender that blocks for an
;;; hour with no way in is its own hazard, independent of the reconnect question.
;;;
;;; A FAILED CAPTURE IS NOT A FAILED LINK.  `llip-vision-capture-send!` returns #f when the camera
;;; yields no frame, which happens transiently under load; dropping the connection on one missing
;;; frame would turn a hiccup into a dead HUD.  Only a RAISE is treated as the link going away.
;;;
;;; WHAT THIS CANNOT DO, STATED SO NOBODY RELIES ON IT: a TCP write to a socket the peer has closed
;;; is buffered locally and succeeds, so the drop surfaces on a LATER write, not the one after the
;;; close.  Expect to lose a frame or two before the reconnect starts.  That is a property of TCP,
;;; not something this code can tighten -- the alternative is an application-level ack, which costs
;;; a round trip per frame on the link that is already the bottleneck.
(define (hud-car-tick!)
  (when (hud-car-connect!)
    (when (>= (hud-car-since hud-car-last-frame) (setting 'hud_frame_ms 200))
      (set! hud-car-last-frame (millis))
      (let* ((t0 (millis))
             (r  (guard (e (#t 'raised))
                        (hud-car-send-telemetry! hud-car-conn)
                        (llip-vision-capture-send! hud-car-conn hud-car-seq)
                        'sent))
             (dt (- (millis) t0)))
        (cond
          ;; A RAISE IS THE EASY CASE AND THE RARE ONE.  Kept first because when it does fire it is
          ;; unambiguous, but do not expect it: see the stall arm below for why.
          ((eq? r 'raised) (hud-car-disconnect! "write raised"))
          ;; THE STALL IS THE REAL DETECTOR, AND IT EXISTS BECAUSE THE RAISE DOES NOT FIRE.
          ;; [B690] Measured 2026-10-04 on this pair: a write to a socket the panel had stopped
          ;; draining took 14 ms, then 2020 ms, then 10017 ms on three successive frames -- rising,
          ;; and those are TIMEOUT values, not transfer times.  The sender raised NOTHING, logged
          ;; `streaming` throughout, and put 33 of 35 frames into a socket the panel never read:
          ;; `hud-frames` stood at 2 with `hud-bad` 0, so they were not corrupt, they never arrived.
          ;; A TCP write to a peer that has stopped reading is buffered locally and SUCCEEDS, so
          ;; "no error occurred" is not evidence of a live link and cannot be made into evidence.
          ;; DURATION is the one signal a sender gets for free: at `hud_frame_ms` 200 a healthy
          ;; frame costs ~14 ms, so a write past `hud_write_stall_ms` is not slow, it is stuck.
          ;; This is still one-sided and therefore still a HEURISTIC -- a genuinely slow link on a
          ;; bad radio day will trip it and reconnect, which costs a gap and is the cheaper error.
          ;; The principled fix is an ACK from the panel, which would also measure the receiver's
          ;; true rate instead of inferring it; that is a protocol change and is noted in [B690].
          ((>= dt (setting 'hud_write_stall_ms 1500))
           (hud-car-disconnect! (string-append "write stalled " (number->string dt) " ms")))
          (else (set! hud-car-seq (+ hud-car-seq 1))))))))

;;; (hud-car-run SECS) -- stream for SECS seconds, reconnecting as needed.  Returns
;;; (frames-sent drops seconds).
;;;
;;; THIS STILL BLOCKS, AND THAT IS NOW A CHOICE RATHER THAN THE ONLY OPTION.  It is a bounded driver
;;; over `hud-car-tick!`, kept because it is what a bench session types; a board that must stay
;;; answerable while streaming calls the TICK from its own loop instead, beside `(wifi-tick!)`.
;;; What it no longer does is treat the first drop as the end of the session.
(define (hud-car-run secs)
  (let ((t-end (+ (millis) (* secs 1000)))
        (seq0  hud-car-seq)
        (drop0 hud-car-drops))
    (let loop ()
      (if (>= (millis) t-end)
          (begin
            (hud-car-disconnect! "run complete")
            (syslog "HUD car: done, ~a frame(s), ~a drop(s)\n"
                    (- hud-car-seq seq0) (- hud-car-drops drop0))
            (list (- hud-car-seq seq0) (- hud-car-drops drop0) secs))
          (begin
            (hud-car-tick!)
            (delay-ms 20)                      ;;;!< yield; the rate gate lives in the tick
            (loop))))))

(syslog "HUD car loaded\n")
