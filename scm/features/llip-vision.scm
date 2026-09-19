;;; llip-vision.scm -- P123 Part D: carry a camera frame over LLIP as BINARY, not text.
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-17 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; WHY THIS IS NOT BASE64.  P123 C1 fixes the control wire as newline-delimited s-expressions
;;; and says "no new codec".  A JPEG is binary, so an earlier draft proposed base64 to stay
;;; inside that rule -- unnecessary, because LambLisp ports are ALREADY binary: binary-port?
;;; returns #t for every port (ll_vm_mop3_port.cpp:863) and read-bytevector / write-bytevector /
;;; read-u8 / write-u8 / u8-ready? are all registered.  So a frame rides the SAME TCP port the
;;; move programs use, unencoded.  Measured on the S3-EYE 2026-09-17: a 240x240 frame is 4954
;;; bytes; base64 would have spent 6605 to carry it.
;;;
;;; THE WIRE.  One s-expression header line, then exactly LEN raw bytes with NO trailing newline:
;;;
;;;     (vision-frame SEQ LEN FMT)\n<LEN bytes>
;;;
;;; The header is still read by `read`, so a human or the orchestrator sees ordinary LLIP traffic
;;; and C1's discipline is preserved for everything that is not the payload itself.
;;;
;;; DO NOT send frames through llip-server.scm's read/write file ops.  That path transfers content
;;; as a Scheme STRING LITERAL and its own header (scm/tools/llip-server.scm:145) warns that NUL
;;; bytes may truncate.  A JPEG is full of NULs.  This file exists so that path is never reached for.
;;;
;;; Deps: read-line / read-bytevector! / write-bytevector / write / flush-output-port (C++);
;;;       camera-capture + camera-init only for the capture helpers, which are optional -- the
;;;       codec itself loads and runs on a board with no camera at all, and on Linux.

;;; --- capability probe ----------------------------------------------------------
;;; #t only where a camera driver is actually compiled in.  Guarded, because on a target without
;;; LL_CAMERA the name is unbound and a bare reference would raise at load time rather than
;;; letting the caller choose what to do.
(define (llip-vision-camera?)
  (guard (e (#t #f))
    (procedure? camera-capture)))

;;; --- JPEG sanity ---------------------------------------------------------------
;;; FF D8 FF is the JPEG SOI marker.  Verified on the S3-EYE 2026-09-17: (255 216 255).
;;; Cheap enough to run on every received frame, and it catches a desynchronised stream --
;;; the failure a length-prefixed binary protocol actually has -- at the point of use.
(define (llip-vision-jpeg? bv)
  (and (bytevector? bv)
       (>= (bytevector-length bv) 3)
       (= 255 (bytevector-u8-ref bv 0))
       (= 216 (bytevector-u8-ref bv 1))
       (= 255 (bytevector-u8-ref bv 2))))

;;; --- send ----------------------------------------------------------------------
;;; Write one frame: header line, then the bytes.  Returns the byte count written.
(define (llip-vision-write! port bv seq fmt)
  (write (list 'vision-frame seq (bytevector-length bv) fmt) port)
  (write-string "\n" port)
  (write-bytevector bv port)
  (flush-output-port port)
  (bytevector-length bv))

;;; --- receive -------------------------------------------------------------------
;;; Read exactly n bytes, looping over short reads.  A SOCKET MAY RETURN FEWER BYTES THAN ASKED
;;; -- a TCP segment boundary lands wherever it lands -- so a single read-bytevector! is wrong
;;; here even though it works every time on a local pipe.  Returns the bytevector, or #f on EOF
;;; before n bytes arrived (a truncated frame is never silently short: the caller must see #f).
(define (llip-vision-read-exactly port n)
  (let ((bv (make-bytevector n 0)))
    (let loop ((got 0))
      (if (>= got n)
          bv
          (let ((r (read-bytevector! bv port got n)))
            (if (or (eof-object? r) (not (number? r)) (<= r 0))
                #f
                (loop (+ got r))))))))

;;; Read one frame.  -> (SEQ LEN FMT BYTEVECTOR), or #f on EOF / a malformed or truncated frame.
(define (llip-vision-read port)
  (let ((line (read-line port)))
    (if (eof-object? line)
        #f
        (let ((hdr (guard (e (#t #f)) (read (open-input-string line)))))
          (if (not (and (pair? hdr)
                        (eq? 'vision-frame (car hdr))
                        (= 4 (length hdr))
                        (number? (caddr hdr))
                        (>= (caddr hdr) 0)))
              #f
              (let ((bv (llip-vision-read-exactly port (caddr hdr))))
                (and bv (list (cadr hdr) (caddr hdr) (cadddr hdr) bv))))))))

;;; --- capture + send, the 4WD side ----------------------------------------------
;;; Grab one JPEG and put it on the wire.  -> byte count, or #f if there is no camera or no frame.
;;; Deliberately does NOT call camera-init: the format is a session decision (rgb565 drives the
;;; LCD, jpeg is for capture) and re-initing per frame would free and re-grab the ~23 KB internal
;;; DMA line buffer on a heap that has since fragmented -- the B428 failure.
(define (llip-vision-capture-send! port seq)
  (if (not (llip-vision-camera?))
      #f
      (let ((bv (camera-capture)))
        (and (bytevector? bv)
             (llip-vision-write! port bv seq 'jpeg)))))

;;; --- receiving side: accept frames and put them where a VLM can read them -----------------
;;; [P123] D2/D3.  The receiver is a LambLisp node too -- both ends run the same codec, which is
;;; the point of the frame format being s-expression header + raw bytes rather than a bespoke
;;; binary protocol only one side understands.
;;;
;;; WRITES THE JPEG TO A FILE rather than holding it in memory: D3 hands the frame to a VLM, and
;;; every vision model on the Jetson takes a path, not a bytevector.  Keeping it in memory would
;;; only mean writing it out later, on a node where PSRAM is not the constraint.
(define (llip-vision-write-file path bv)
  (let ((p (open-output-file path)))
    (write-bytevector bv p)
    (close-port p)
    (bytevector-length bv)))

;;; Serve ONE connection: read frames until EOF, writing each to <dir>/frame-<seq>.jpg.
;;; Returns (frames-written last-path last-bytes), or #f if it could not listen.
;;; NOT a loop over many clients -- one sensor, one session, which is what D2 needs and what
;;; C2's event-driven model implies.  A multi-client version is a different program.
(define (llip-vision-serve port dir secs)
  (let ((srv (open-tcp-server-port port)))
    (if (not srv)
        (begin (display "RESULT vision error=cannot-listen port=") (display port) (newline) #f)
        (let ((t-end (+ (millis) (* secs 1000))))
          (display "RESULT vision listening port=") (display port) (newline)
          (let wait ()
            (let ((conn (server-accept srv)))
              (cond
                ((and (not conn) (< (millis) t-end)) (delay-ms 20) (wait))
                ((not conn) (close-port srv)
                            (display "RESULT vision error=no-sensor") (newline) #f)
                (else
                 (display "RESULT vision connected") (newline)
                 (let loop ((n 0) (last "") (bytes 0))
                   (let ((f (llip-vision-read conn)))
                     (if (not f)
                         (begin
                           (close-port conn) (close-port srv)
                           (display "RESULT vision frames=") (display n)
                           (display " last=") (display last)
                           (display " bytes=") (display bytes)
                           (display " jpeg=") (display (> bytes 0))
                           (newline)
                           (list n last bytes))
                         (let* ((seq (car f))
                                (bv  (cadddr f))
                                (pth (string-append dir "/frame-"
                                                    (number->string seq) ".jpg"))
                                (nb  (llip-vision-write-file pth bv)))
                           ;; report per frame so a stalled sensor is visible as it happens,
                           ;; not only in a summary that never prints
                           (display "RESULT vision frame seq=") (display seq)
                           (display " bytes=") (display nb)
                           (display " jpeg?=") (display (llip-vision-jpeg? bv))
                           (display " -> ") (display pth) (newline)
                           (loop (+ n 1) pth nb)))))))))))))

;;; --- sending side: the counterpart to llip-vision-serve ---------------------------------
;;; [P123] D2.  `llip-vision-capture-send!` takes an ALREADY-OPEN port, which left the part that
;;; opens the connection and drives the loop living in whatever one-off script last needed it.
;;; This is that part, so the next session types a call instead of rebuilding the reasoning.
;;;
;;; GUARD THE CONNECT AND MEAN IT.  Until [B474] `open-tcp-client-port` returned a TRUTHY port for a
;;; peer it could not reach, so `(if conn ...)` tested nothing and an unroutable host presented as a
;;; codec failure -- which is how D2 lost an hour to a network fault that looked like framing.  The
;;; constructors now hand back #f, so this guard is real; do not remove it on the grounds that it
;;; "can't be false".
;;;
;;; -> (frames-sent bytes-sent), or #f if the peer is unreachable.
(define (llip-vision-send-frames host port n)
  (let ((conn (open-tcp-client-port host port)))
    (if (not conn)
        (begin
          (display "RESULT vision error=cannot-connect host=") (display host)
          (display " port=") (display port) (newline)
          #f)
        (begin
          (display "RESULT vision connected host=") (display host)
          (display " port=") (display port) (newline)
          (let loop ((seq 0) (sent 0) (bytes 0))
            (if (>= seq n)
                (begin
                  (close-port conn)
                  (display "RESULT vision sent frames=") (display sent)
                  (display " bytes=") (display bytes) (newline)
                  (list sent bytes))
                ;; Report per frame BEFORE the next capture: a send that stalls mid-run must be
                ;; visible as the frame it stalled on, not as a summary that never prints.
                (let ((nb (llip-vision-capture-send! conn seq)))
                  (display "RESULT vision frame seq=") (display seq)
                  (display " bytes=") (display (if nb nb 0))
                  (display " ok=") (display (if nb #t #f)) (newline)
                  (if nb
                      (loop (+ seq 1) (+ sent 1) (+ bytes nb))
                      (begin
                        (close-port conn)
                        (display "RESULT vision sent frames=") (display sent)
                        (display " bytes=") (display bytes)
                        (display " aborted=capture-or-write-failed") (newline)
                        (list sent bytes))))))))))
