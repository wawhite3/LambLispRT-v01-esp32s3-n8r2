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

;;!Fletcher-16 over a string's CODEPOINTS -- must match ck() in w3_ai_scripts/llip_tunnel.py
;;!and fletcher16() in tools/llip.  THE THREE ARE ONE INVARIANT IN TWO LANGUAGES, and it is
;;!anchored to how THIS file's string layer indexes: `string-length`/`string-ref` are
;;!CHARACTER-based (R7RS), so this hashes codepoints.  When they were BYTE-based the hosts
;;!correctly hashed UTF-8 bytes (B84) -- and when the string layer became character-indexed,
;;!llip_tunnel.py was left hashing bytes and every non-ASCII file silently failed to push
;;!(B369; 33% of scm/tests/ll_tests).  IF THE INDEXING CHANGES AGAIN, ALL THREE MOVE TOGETHER.
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
(define llip-dest #f)                 ;;;!< [B585] final path; we write a .part beside it
(define llip-n  0)
(define llip-fc 0)
(define llip-xp 0)

;;!(op "path") -- open the destination, reset counters.  -> ACK
;;!
;;! [B585] WE WRITE A `.part` AND RENAME AT `cl`, SO A FAILED PUSH CANNOT DESTROY A GOOD FILE.
;;! This used to `delete-file` the DESTINATION and then stream chunks into it, so a push that died
;;! mid-file left a TRUNCATED file where a complete one had been -- and the original was already gone.
;;! Measured 2026-09-23: a probe push failed at seq 40 of ~54, and the remains still LOADED --
;;! `Lamb::load() finished loading` in 21 ms, running NONE of the suite's ~50 cases.  A cut suite is a
;;! SHORTER suite that passes, which is worse than one that errors, because the tally stays plausible:
;;! had the cut landed mid-suite the reader would have believed the cases before it and not missed the
;;! rest.  The destination is now untouched until a transfer that actually reached `cl`.
;;!
;;! COSTS ONE FILE'S WORTH OF SPARE SPACE, which is the right trade: on a full filesystem the push now
;;! fails at `open-output-file` BEFORE anything is destroyed, instead of half-overwriting the target.
(define (op path)
  (set! llip-dest path)
  (let ((tmp (string-append path ".part")))
    (if (file-exists? tmp) (delete-file tmp))
    (set! llip-fp (open-output-file tmp)))
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
;;!
;;! [B585] THE RENAME HAPPENS HERE, after the port is closed, so the destination is replaced only by a
;;! file the transfer finished writing.  Reaching this line means every chunk passed `da`'s CRC AND
;;! arrived in sequence, which is the real guarantee; the N/FC totals the host checks afterwards are
;;! end-to-end belt-and-braces on top of it.
;;!
;;! RESIDUAL, STATED RATHER THAN IMPLIED: a transfer that COMPLETES with mismatched totals still
;;! replaces the destination -- the host learns from `DONE N FC` and must re-push.  Closing that would
;;! need the host to confirm before the rename, i.e. a new wire op, and an older host would then never
;;! commit at all.  The bug this fixes is the push that never reaches `cl`, which is the one observed.
(define (cl)
  (close-output-port llip-fp) (set! llip-fp #f)
  (if llip-dest
      (let ((tmp (string-append llip-dest ".part")))
        (if (file-exists? tmp)
            (begin
              (if (file-exists? llip-dest) (delete-file llip-dest))
              (rename-file tmp llip-dest)))))
  (llip--emit "DONE " llip-n " " llip-fc))

;;; ---- [P132] THE PULL DIRECTION: sf/sd/sc, the mirror of op/da/cl -----------------------------
;;;
;;; WHY IT EXISTS: `llip recv` has never worked.  The host CLI exits with
;;; "recv needs the device-side pull primitive (llip-send-file); not present in this firmware yet",
;;; so there has been no way to read a file OFF a board -- which is why answering "what settings does
;;; this board actually hold?" required flashing it and inferring, and why a truncated push [B585] had
;;; to be diagnosed from a 21 ms load time instead of by reading what arrived.
;;;
;;; SAME SHAPE AS THE PUSH, deliberately: one open, N chunks each with a sequence number and a
;;; Fletcher-16 over the bytes ON THE WIRE, then a close reporting totals the host can check
;;; end-to-end.  `ck` is the same function `da` verifies with, and the host already has it as
;;; `fletcher16`, so neither side needs new arithmetic.
;;;
;;; CHUNKS ARE HEX, AND THAT IS A V1 CHOICE WITH A REASON.  It doubles the bytes on the wire, which
;;; for pulling a settings file or a log is irrelevant, and it buys two things a quoted string cannot:
;;; nothing needs escaping (a Scheme string on the wire would need the device to escape and the host to
;;; unescape, a second parser to get wrong), and a NUL is just "00" -- a LambLisp string cannot hold one
;;; at all, it SHORTENS the object (B317), which is the same reason the push needed a separate binary
;;; frame.  So this one path pulls text and binary alike.  If the 2x ever matters, base64.scm is present
;;; and the framing does not change.
(define llip-rfp  #f)                   ;;;!< open input port, or #f
(define llip-rseq 0)                    ;;;!< next chunk sequence number
(define llip-rn   0)                    ;;;!< source characters sent so far
(define llip-rfc  0)                    ;;;!< aggregate checksum, mod 65521 like the push
(define llip-rlast "")                  ;;;!< last chunk's hex, for `sr` retries
(define llip-rlseq 0)                   ;;;!< its sequence number

(define llip--hexd "0123456789abcdef")
(define (llip--hex2 n)                  ;;;!< one byte -> exactly two lowercase hex digits
  (string (string-ref llip--hexd (quotient n 16))
          (string-ref llip--hexd (modulo  n 16))))

;;!(sf "path") -- open the file for reading, reset counters.  -> SF | SF-ERR <reason>
(define (sf path)
  (if llip-rfp (begin (close-input-port llip-rfp) (set! llip-rfp #f)))
  (if (not (file-exists? path))
      (llip--emit "SF-ERR no-such-file")
      (begin
        (set! llip-rfp (open-input-file path))
        (set! llip-rseq 0) (set! llip-rn 0) (set! llip-rfc 0)
        (set! llip-rlast "") (set! llip-rlseq 0)
        (llip--emit "SF"))))

;;!(sd) -- emit the NEXT chunk.  -> SD <seq> <ck> <hex> | SD-EOF <n> <fc> | SD-ERR not-open
;;!The host re-requests the same chunk simply by not advancing; a chunk whose ck disagrees is a
;;!re-request, so `sd` is idempotent only in the sense `da` is -- the seq number is the contract.
(define (sd)
  (if (not llip-rfp)
      (llip--emit "SD-ERR not-open")
      (let lp ((i 0) (acc ""))
        (if (>= i 128)
            (llip--send-chunk acc)
            (let ((c (read-char llip-rfp)))
              (if (eof-object? c)
                  (if (= (string-length acc) 0)
                      (begin (llip--emit "SD-EOF " llip-rn " " llip-rfc))
                      (llip--send-chunk acc))
                  (lp (+ i 1) (string-append acc (llip--hex2 (char->integer c))))))))))

(define (llip--send-chunk hex)
  (let ((c (ck hex)))
    (set! llip-rn  (+ llip-rn (quotient (string-length hex) 2)))
    (set! llip-rfc (modulo (+ llip-rfc c) 65521))
    (set! llip-rlast hex)                            ;;;!< kept so `sr` can re-emit it
    (set! llip-rlseq llip-rseq)
    (llip--emit "SD " llip-rseq " " c " " hex)
    (set! llip-rseq (+ llip-rseq 1))))

;;!(sr) -- RE-EMIT the last chunk without advancing.  -> SD <seq> <ck> <hex> | SR-ERR none
;;!
;;!WITHOUT THIS A PULL HAS NO RETRY, and that is not symmetric with the push: `da` can be resent
;;!because the HOST holds the data, while here the device holds it and `sd` had already advanced past
;;!it.  A single corrupted chunk would then force the whole file to restart -- on a 14 KB file at 128
;;!bytes a chunk that is 110 chances to loop forever on a noisy line.  One chunk of buffer removes it.
(define (sr)
  (if (= (string-length llip-rlast) 0)
      (llip--emit "SR-ERR none")
      (llip--emit "SD " llip-rlseq " " (ck llip-rlast) " " llip-rlast)))

;;!(sc) -- close the read side.  -> SC-OK.  Safe to call when nothing is open.
(define (sc)
  (if llip-rfp (begin (close-input-port llip-rfp) (set! llip-rfp #f)))
  (llip--emit "SC-OK"))


;;; P132 quiet-mode toggles -- NON-BLOCKING (they just flip the flag and return; the REPL keeps
;;; looping).  A host enters quiet before streaming frames and leaves it when done.
(define (llt) (lamb-repl-quiet! #t))   ;;!< enter tunnel/quiet mode
(define (en)  (lamb-repl-quiet! #f))   ;;!< leave tunnel/quiet mode (back to interactive)

;;; ---- [P132] sec.6.2: the BINARY CHUNK FRAME (`db`) -----------------------------------------
;;;
;;; WHY op/da/cl IS NOT ENOUGH.  `da` carries its payload as a STRING, and a LambLisp string
;;; cannot hold a NUL at all -- writing one does not set a byte, it SHORTENS the object (B317).
;;; A VM `.bin`, a bytevector, a JPEG: all contain NUL, so none can ride the text frame.  `db`
;;; carries RAW BYTES on the wire with no escaping and no base64, which is also why it costs
;;; nothing in size.
;;;
;;; THE HEADER IS AN ORDINARY EVAL.  `(db SEQ LEN CRC)` is a legal s-expression, so the SAME
;;; non-blocking REPL that handles op/da/cl handles it -- there is no mode switch at the parser.
;;; Evaluating it only ARMS the receiver; it does not read the payload.
;;;
;;; THE PAYLOAD IS DRAINED BY A TICK, NOT BY A BLOCKING READ.  `db-tick!` takes whatever bytes are
;;; available right now and returns, so the main loop keeps servicing Sonar/Led/Buzzer and the
;;; collector between chunks.  That is the whole reason `read-bytevector-avail!` had to exist:
;;; `read-bytevector!` loops on read_u8, which is non-blocking on serial but SPINS on TCP, so its
;;; behaviour depends on the transport the caller happens to be using.
;;;
;;; WHILE ARMED, THE LINE ASSEMBLER MUST NOT TOUCH THE UART.  `(llip-db-armed! #t)` tells the
;;; terminal layer to step aside (ll_vm_term.cpp).  A `\n` inside the payload is then just a data
;;; byte counted against LEN, not a line terminator.  DISARMING IS NOT OPTIONAL: a stuck flag is a
;;; console that looks alive and answers nothing, so every exit path below clears it.

(define db-armed  #f)    ;;!< #t while a chunk's payload is inbound
(define db-need   0)     ;;!< bytes still expected this chunk
(define db-got    0)     ;;!< bytes received so far
(define db-buf    #f)    ;;!< bytevector accumulator, sized LEN
(define db-crc    0)     ;;!< expected Fletcher-16 for the chunk
(define db-seq    0)     ;;!< next expected SEQ

;;!Fletcher-16 over BYTES.  Note this is the byte-wise sibling of `ck` above, which hashes a
;;!string's CODEPOINTS -- the two are not interchangeable and the difference is exactly B369.
;;!The host side must use the byte version for `db` and the codepoint version for `da`.
(define (bv-fletcher16 bv n)
  (let ((a 0) (b 0))
    (let lp ((i 0))
      (if (< i n)
          (begin (set! a (modulo (+ a (bytevector-u8-ref bv i)) 255))
                 (set! b (modulo (+ b a) 255))
                 (lp (+ i 1)))
          (+ (* b 256) a)))))

;;!(db SEQ LEN CRC) -- arm the receiver.  Does NOT read the payload.
(define (db seq len crc)
  (cond
    ((not (= seq db-seq)) (llip--emit "NAK " db-seq))        ;; out of order -> host resends
    ((< len 0)            (llip--emit "NAK " db-seq))
    (else
      (set! db-need len) (set! db-got 0) (set! db-crc crc)
      (set! db-buf (make-bytevector (if (= len 0) 1 len) 0))
      (set! db-armed #t)
      (llip-db-armed! #t)
      ;;! A zero-length chunk completes immediately -- there is no payload to wait for, and
      ;;! leaving it armed would strand the console on a frame that can never finish.
      (if (= len 0) (db-finish!)))))

;;!Complete the current chunk: check the CRC, write the bytes, ACK or NAK, and DISARM.
(define (db-finish!)
  (let ((ok (= (bv-fletcher16 db-buf db-got) db-crc)))
    (if ok
        (begin (if (> db-got 0) (write-bytevector db-buf llip-fp 0 db-got))
               (set! db-seq (+ db-seq 1))
               (llip--emit "ACK " (- db-seq 1)))
        (llip--emit "NAK " db-seq))
    (set! db-armed #f)
    (llip-db-armed! #f)          ;;!< hand input back to the REPL -- on BOTH arms
    ok))

;;!(db-tick!) -- drain whatever is available; call every main-loop iteration.  No-op when not
;;!armed, so it costs one test between transfers.
(define (db-tick!)
  (if db-armed
      (let ((n (read-bytevector-avail! db-buf db-got db-need)))
        (set! db-got  (+ db-got n))
        (set! db-need (- db-need n))
        (if (<= db-need 0) (db-finish!)))))

(syslog "llip-serial loaded\n")
