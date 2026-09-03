;;; profibus-sim-master.scm -- P145 DP master simulator (the other half).
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-20 21:50:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Driven by w3_ai_scripts/fieldbus_loopback.sh.  Expects `pb-port` to be
;;; defined ahead of the load (see profibus-sim-slave.scm).
;;;
;;; The harness (w3_ai_scripts/fieldbus_loopback.sh) defines these before loading:
;;;   pb-port pb-baud pb-ident pb-run-ms  (+ pb-addr / pb-slave-addr)
;;;
;;; Brings one slave from OFFLINE all the way to DATA_EXCH and exchanges I/O,
;;; then asserts on the result.  This is P145 test case 5: the whole state
;;; machine, both directions, with no hardware.

(define pb-pass 0)
(define pb-fail 0)
(define (pb-check name expected actual)
  (if (equal? expected actual)
      (begin (display "PASS ") (display name) (newline)
             (set! pb-pass (+ pb-pass 1)))
      (begin (display "FAIL ") (display name)
             (display " expected=") (display expected)
             (display " got=") (display actual) (newline)
             (set! pb-fail (+ pb-fail 1)))))

(define pb-baud        (if (defined? 'pb-baud) pb-baud 19200))
(define pb-slave-addr  (if (defined? 'pb-slave-addr) pb-slave-addr 3))
(define pb-ident       (if (defined? 'pb-ident) pb-ident #x0801))
(define pb-run-ms      (if (defined? 'pb-run-ms) pb-run-ms 6000))

(display "sim-master: opening ") (display pb-port) (newline)

(define bus (profibus-open pb-port pb-baud))
(profibus-set-address bus 1)
(profibus-set-timing bus 200 1)          ; generous slot time for a cooperative peer

(define sl (profibus-add-slave bus pb-slave-addr pb-ident 2 1))
(profibus-set-cfg sl (bytevector #x11 #x20))   ; 2 bytes in, 1 byte out
(profibus-set-watchdog sl 2000)
(profibus-outputs-set! sl (bytevector #x5A))

(pb-check "initial state offline" 'offline (profibus-state sl))

(profibus-start bus)

(define deadline (+ (millis) pb-run-ms))
(define events '())
(define saw-data-exch #f)

(let loop ()
  (profibus-service bus)
  (let drain ()
    (let ((ev (profibus-poll-event bus)))
      (if ev (begin (set! events (cons ev events)) (drain)))))
  (if (eq? (profibus-state sl) 'data-exch) (set! saw-data-exch #t))
  (if (and (< (millis) deadline)
           (not (and saw-data-exch
                     (= (bytevector-u8-ref (profibus-inputs sl) 1) #x5A))))
      (loop)))

(display "sim-master: state=") (display (profibus-state sl))
(display " inputs=")           (display (profibus-inputs sl))
(display " stats=")            (display (profibus-stats bus))
(newline)
(display "sim-master: events=") (display (reverse events)) (newline)

;;; ── Assertions ───────────────────────────────────────────────────────────
(pb-check "reached data-exch" 'data-exch (profibus-state sl))
(pb-check "slave-up event seen" #t
          (if (assq 'slave-up (map (lambda (e) (cons (car e) #t)) events)) #t #f))
;;  Input byte 0 is the constant the slave seeded; byte 1 echoes our output,
;;  which proves the process image round-tripped in BOTH directions.
(pb-check "input byte 0 constant" #xDE (bytevector-u8-ref (profibus-inputs sl) 0))
(pb-check "output echoed back"    #x5A (bytevector-u8-ref (profibus-inputs sl) 1))
(pb-check "cycles counted" #t (> (car (profibus-stats bus)) 0))
(pb-check "no fcs errors"  0  (list-ref (profibus-stats bus) 3))

;;  Now change the output and prove the NEW value propagates -- this is the
;;  double-buffer publish path, not just the initial handshake.
(profibus-outputs-set! sl (bytevector #xC3))
(define d2 (+ (millis) 3000))
(let loop2 ()
  (profibus-service bus)
  (if (and (< (millis) d2)
           (not (= (bytevector-u8-ref (profibus-inputs sl) 1) #xC3)))
      (loop2)))
(pb-check "republished output propagates" #xC3 (bytevector-u8-ref (profibus-inputs sl) 1))

(profibus-stop bus)
(profibus-close bus)

(newline)
(display "Total: ") (display pb-pass) (display " pass, ")
(display pb-fail) (display " fail") (newline)
(display "--- sim-master done ---") (newline)
