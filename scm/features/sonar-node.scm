;;; sonar-node.scm -- two-node demo: one board's SONAR drives another board's LED, over LLIP.
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-17 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; SENSOR node (4WD): has the HC-SR04, no usable lamp -- its WS2812 ring is powered from the car's
;;;                    battery pack, which is flat.
;;; LAMP   node (S3):  has the onboard RGB LED (pin-RGBLED 48), no sonar.
;;;
;;; Neither board can show the behaviour alone, which is the honest reason this is two nodes rather
;;; than a contrivance: the split is in the hardware, not in the design.
;;;
;;; WIRE: [P123] C1 verbatim -- newline-delimited s-expressions, read by `read` and written by
;;; `write`, no new codec.  One frame per measurement:
;;;
;;;     (dist <metres>)\n
;;;
;;; ROLES follow [P123] C1 too: the SENSOR is the TCP CLIENT and the LAMP is the SERVER.  That is
;;; not arbitrary -- the mobile, battery-powered node is the one that must be free to drop its
;;; radio and reconnect, so it drives connect/disconnect.  Here the 4WD is on mains USB, but
;;; keeping the roles as specified means the demo exercises the real topology.
;;;
;;; NON-BLOCKING ON THE SENSOR SIDE.  The sonar service and the send share the loop; nothing waits
;;; on the socket.  A blocking send would stall Sonar.loop and, in the real robot, the B5 reflex.

(define sonar-node-port 3333)

;;; ---------------------------------------------------------------- LAMP node (server, the S3)
;;; Accept one sensor, then read frames until EOF, driving the lamp at the rate the distance asks
;;; for.  Returns (frames N last-distance).
(define (sonar-lamp-serve secs)
  (let ((srv (open-tcp-server-port sonar-node-port)))
    (if (not srv)
        (begin (display "RESULT lamp error=cannot-listen") (newline) #f)
        (let ((t-end (+ (millis) (* secs 1000))))
          (display "RESULT lamp listening port=") (display sonar-node-port) (newline)
          (let wait ()
            (let ((conn (server-accept srv)))
              (cond
                ((and (not conn) (< (millis) t-end)) (delay-ms 20) (wait))
                ((not conn)
                 (close-port srv)
                 (display "RESULT lamp error=no-sensor-connected") (newline) #f)
                (else
                 (display "RESULT lamp connected") (newline)
                 (let loop ((n 0) (last -1.0))
                   (if (>= (millis) t-end)
                       (begin
                         (sonar-flash-stop!) (close-port conn) (close-port srv)
                         (display "RESULT lamp frames=") (display n)
                         (display " last_m=") (display last) (newline)
                         (list n last))
                       (let ((line (read-line conn)))
                         (if (eof-object? line)
                             (begin
                               (sonar-flash-stop!) (close-port conn) (close-port srv)
                               (display "RESULT lamp frames=") (display n)
                               (display " last_m=") (display last) (display " eof=#t") (newline)
                               (list n last))
                             (let ((f (guard (e (#t #f)) (read (open-input-string line)))))
                               (if (and (pair? f) (eq? 'dist (car f)) (number? (cadr f)))
                                   (begin
                                     (set! Sonar.latest (cadr f))   ;;; the remote reading IS the input
                                     (sonar-flash-tick!)
                                     (loop (+ n 1) (cadr f)))
                                   (loop n last)))))))))))))))

;;; The lamp must keep flashing BETWEEN frames, not only when one arrives -- a frame arrives every
;;; ~60 ms while an edge may be due every 30 ms, so ticking only on receipt would halve the rate
;;; and make it look like the sonar was slower than it is.
(define (sonar-lamp-pump secs)
  (let ((t-end (+ (millis) (* secs 1000))))
    (let loop () (if (< (millis) t-end) (begin (sonar-flash-tick!) (delay-ms 5) (loop))))))

;;; ---------------------------------------------------------------- SENSOR node (client, the 4WD)
;;; Connect, then every dispositioned ping send one frame.  Returns (sent N).
(define (sonar-sensor-send host secs)
  (let ((conn (open-tcp-client-port host sonar-node-port)))
    (if (not conn)
        (begin (display "RESULT sensor error=cannot-connect host=") (display host) (newline) #f)
        (let ((t-end (+ (millis) (* secs 1000))))
          (display "RESULT sensor connected host=") (display host) (newline)
          (Sonar.start)
          (let loop ((n 0))
            (if (>= (millis) t-end)
                (begin
                  (close-port conn)
                  (display "RESULT sensor sent=") (display n) (newline)
                  (list n))
                (begin
                  (Sonar.loop)                     ;;; services the sonar; never blocks
                  (let ((d Sonar.latest))
                    (write (list 'dist d) conn)
                    (write-string "\n" conn)
                    (flush-output-port conn)
                    (delay-ms 60)                  ;;; ~16 frames/s, matching the sensor's own rate
                    (loop (+ n 1))))))))))
