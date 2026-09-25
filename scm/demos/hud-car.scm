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

;;; (hud-car-run SECS) -- connect to the panel and stream until SECS elapse or the link drops.
;;; Returns (frames-sent seconds).
;;;
;;; A FAILED CAPTURE IS NOT A FAILED SESSION.  `llip-vision-capture-send!` returns #f when the
;;; camera yields no frame, which happens transiently under load.  Dropping the connection on one
;;; missing frame would turn a hiccup into a dead HUD, so the loop continues and the telemetry --
;;; which needs no camera -- keeps flowing.  The panel counts what arrives.
(define (hud-car-run secs)
  (let ((conn (open-tcp-client-port (hud-car-host) (hud-car-port))))
    (if (not conn)
        (begin (syslog "HUD car: cannot reach ~a:~a\n" (hud-car-host) (hud-car-port)) #f)
        (let ((t-end (+ (millis) (* secs 1000))))
          ;; JPEG, NOT RGB565, AND THE LABEL DEPENDS ON IT.  `llip-vision-capture-send!` writes
          ;; 'jpeg into every frame header regardless of what the sensor is producing, so a camera
          ;; left in its default rgb565 mode puts 115,200 raw bytes on the wire under a header that
          ;; says JPEG.  The receiver then hands that to a JPEG decoder, which rejects it, and the
          ;; frame is counted bad -- a frame that arrived perfectly and was discarded because its
          ;; label was wrong.  Initialising in 'jpeg makes the label true, and takes a 240x240 frame
          ;; from ~115 KB to ~5 KB, which over this radio is the difference between video and a
          ;; slideshow.
          (camera-init 'jpeg)
          (syslog "HUD car: streaming to ~a:~a\n" (hud-car-host) (hud-car-port))
          (let loop ((seq 0))
            (if (>= (millis) t-end)
                (begin (close-port conn)
                       (syslog "HUD car: done, ~a frame(s)\n" seq)
                       (list seq secs))
                (begin
                  (hud-car-send-telemetry! conn)
                  (llip-vision-capture-send! conn seq)
                  (loop (+ seq 1)))))))))

(syslog "HUD car loaded\n")
