;;; llip-transport.scm — WP-B of P123: LLIP-over-TCP transport (orchestrator <-> 4WD).
;;; Copyright 2026 by Frobenius Norm LLC 2026-06-25 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Jetson = TCP server (orchestrator); 4WD = TCP client (it duty-cycles its WiFi for
;;; power, so the client drives connect/disconnect).  LLIP framing: ONE s-expression
;;; per line.  recv uses read-line (blocking after the B55 fix) + parse-from-string,
;;; NOT `read` directly off the socket (the reader's peek can see a split TCP segment
;;; as EOF mid-datum).  A frame is a single line because `write` emits a flat s-expr.
;;;
;;; Plugs into WP-C: `(llip-conn-transport conn)` is exactly the `(cons send! recv)`
;;; pair `llip-orchestrate` expects, so the stub transport swaps out for real TCP with
;;; no change to the orchestrator.
;;;
;;; Deps: read-line/write/open-tcp-{client,server}-port/server-accept/delay-ms (C++);
;;;       llip-orchestrate (llip-orchestrator.scm) for the server convenience wrapper;
;;;       llip-make-telemetry / llip-mp-seq (llip-frame.scm) for the demo run-fn.

;;; --- frame codec (both sides) ---------------------------------------------------
(define (llip-frame-write! port frame)
  (write frame port)
  (write-string "\n" port)
  (flush-output-port port))

(define (llip-frame-read port)                 ;;; -> frame | #f (EOF or parse failure)
  (let ((line (read-line port)))
    (if (eof-object? line)
        #f
        (guard (e (#t #f)) (read (open-input-string line))))))

;;; --- orchestrator (server) side -------------------------------------------------
;;; server-accept is non-blocking; poll it (20 ms) until a client connects.
(define (llip-accept server-port)
  (let loop ()
    (let ((conn (server-accept server-port)))
      (if conn conn (begin (delay-ms 20) (loop))))))

;;; A WP-C transport bound to one connection: (cons send! recv).
(define (llip-conn-transport conn)
  (cons (lambda (frame) (llip-frame-write! conn frame))   ;;; send! a move-program
        (lambda () (llip-frame-read conn))))               ;;; recv a telemetry

;;; Serve ONE 4WD session: accept -> run the orchestrator loop over the connection ->
;;; close (the close signals the 4WD to disconnect / drop WiFi).  Returns (done N)|(halt R).
(define (llip-serve-once server-port goal . opts)
  (let ((conn (llip-accept server-port)))
    (let ((result (apply llip-orchestrate goal (llip-conn-transport conn) opts)))
      (close-port conn)
      result)))

;;; --- 4WD (client) side ----------------------------------------------------------
;;; Connect, then loop: recv a move-program -> run it -> send telemetry, until the
;;; orchestrator closes the connection (EOF).  run-fn: (move-program-frame) -> telemetry.
(define (llip-4wd-serve host port run-fn)
  (let ((conn (open-tcp-client-port host port)))
    (and conn
         (let loop ((n 0))
           (let ((mp (llip-frame-read conn)))
             (if (not mp)
                 (begin (close-port conn) (list 'disconnected n))   ;;; orchestrator closed
                 (let ((telem (run-fn mp)))
                   (llip-frame-write! conn telem)
                   (loop (+ n 1)))))))))

;;; A stub run-fn for bring-up / loopback tests: reports the program done immediately,
;;; echoing its seq.  The real 4WD swaps this for move-run-frame! + live telemetry.
(define (llip-4wd-stub-run mp)
  (llip-make-telemetry (or (llip-mp-seq mp) 0) 0 'done #f '()))

(syslog "llip-transport loaded (llip-serve-once, llip-4wd-serve, llip-conn-transport)\n")

; end of llip-transport.scm
