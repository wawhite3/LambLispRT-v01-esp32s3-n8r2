;;; Copyright 2026 by Frobenius Norm LLC 2026-07-02 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; llip-serial.scm -- LOOP-BASED, NON-BLOCKING LLIP receiver over the serial REPL.
;;;
;;; This is NOT a blocking loop.  The frame verbs (op/da/cl) are plain top-level functions
;;; that the normal REPL -- itself non-blocking and loop-based (it assembles a line across
;;; main-loop ticks and evaluates it when complete) -- evaluates ONE LINE AT A TIME.  Nothing
;;; blocks: the main loop keeps ticking Sonar/Led/Buzzer/etc between frames.
;;;
;;; Combined with P132 quiet mode ((llt) = quiet on, (en) = quiet off), the console emits no
;;; per-char echo and no input-form echo (quiet gates BOTH the terminal redisplay and the loop's
;;; "Input: <form>" log), so a host tool sends one frame line, reads one ACK line, and moves on --
;;; literal sentinels are safe (the marker is no longer echoed back in the input).  The REPL's own
;;; "Output: <value>" print is NOT suppressed (a driver may want to read results), but it prints
;;; AFTER each frame's ACK/each form's own output, so it never confuses the host.
;;;
;;; Wire protocol (host -> REPL; each line is a normal eval; reply one line each):
;;;   (llt)                   quiet mode ON   -- silence echo + async flood while tunneling
;;;   (op "path")             open+truncate, reset seq/counters      -> ACK
;;;   (da SEQ CRC "chunk")    CRC ok & SEQ==expected -> write          -> ACK SEQ  (else NAK exp)
;;;   (cl)                    close; report chars + aggregate cksum    -> DONE N FC
;;;   (en)                    quiet mode OFF  -- back to interactive
;;;   <any other s-expr>      evaluated normally; in quiet mode only its own (display ...) output
;;;                           streams -- this is how a host RUNS a command (e.g. a test runner).
;;; Stop-and-wait ARQ: per-frame Fletcher-16 (ck) + sequence number; the host retransmits on
;;; NAK/timeout.  This is the reliability LLIP gets free from TCP but must supply over raw serial.

(syslog "llip-serial loading\n")

;;!Fletcher-16 over a string's codepoints -- must match ck() in llip_tunnel.py byte-for-byte.
(define (ck s)
  (let ((a 0) (b 0) (L (string-length s)))
    (let lp ((i 0))
      (if (< i L)
          (begin
            (set! a (modulo (+ a (char->integer (string-ref s i))) 255))
            (set! b (modulo (+ b a) 255))
            (lp (+ i 1)))
          (+ (* b 256) a)))))

;;!Write one reply line and flush: strings verbatim, non-strings via `write` (numbers print bare).
;;!Uses write-string (NOT log), so replies are NOT suppressed by quiet mode.
(define (llip--emit . parts)
  (for-each (lambda (p) (if (string? p) (write-string p) (write p))) parts)
  (write-string "\n")
  (flush-output-port (current-output-port)))

;;; File-transfer ARQ state.  op/da/cl are SEPARATE per-line REPL evals, so the state is global:
;;; fp=open file port, n=chars written, fc=aggregate checksum, xp=next expected sequence number.
(define llip-fp #f)
(define llip-n  0)
(define llip-fc 0)
(define llip-xp 0)

;;!(op "path") -- open + truncate the destination file, reset counters.  -> ACK
(define (op path)
  (if (file-exists? path) (delete-file path))
  (set! llip-fp (open-output-file path))
  (set! llip-n 0) (set! llip-fc 0) (set! llip-xp 0)
  (llip--emit "ACK"))

;;!(da SEQ CRC "chunk") -- write one chunk if the CRC checks and SEQ is the expected next one.
;;!CRC bad / wrong seq -> NAK <expected>; in-order -> ACK SEQ; duplicate (lost ACK) -> re-ACK.
(define (da sq cr d)
  (cond
    ((not (= cr (ck d)))              (llip--emit "NAK " llip-xp))   ;; corrupt -> ask for resend
    ((= sq llip-xp)                                                    ;; in-order, good
     (write-string d llip-fp)
     (set! llip-n  (+ llip-n (string-length d)))
     (set! llip-fc (modulo (+ llip-fc cr) 65521))
     (set! llip-xp (+ llip-xp 1))
     (llip--emit "ACK " sq))
    ((= sq (- llip-xp 1))            (llip--emit "ACK " sq))          ;; duplicate -> re-ACK
    (else                            (llip--emit "NAK " llip-xp))))   ;; out-of-window -> resync

;;!(cl) -- close the file and report totals for the host's end-to-end check.  -> DONE N FC
(define (cl)
  (close-output-port llip-fp) (set! llip-fp #f)
  (llip--emit "DONE " llip-n " " llip-fc))

;;; P132 quiet-mode toggles -- NON-BLOCKING (they just flip the flag and return; the REPL keeps
;;; looping).  A host enters quiet before streaming frames and leaves it when done.
(define (llt) (lamb-repl-quiet! #t))   ;;!< enter tunnel/quiet mode
(define (en)  (lamb-repl-quiet! #f))   ;;!< leave tunnel/quiet mode (back to interactive)

(syslog "llip-serial loaded\n")
