;;; profibus-sim-slave.scm -- P145 DP slave simulator (one half of the loopback).
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-20 21:50:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Driven by w3_ai_scripts/fieldbus_loopback.sh, which starts the pty bridge,
;;; then feeds each process a `pb-port` definition ahead of the load:
;;;
;;;   (define pb-port "/dev/pts/N")
;;;   (load "ll_tests/profibus-sim-slave.scm" 0)
;;;
;;; The harness (w3_ai_scripts/fieldbus_loopback.sh) defines these before loading:
;;;   pb-port pb-baud pb-ident pb-run-ms  (+ pb-addr / pb-slave-addr)
;;;
;;; Answers a real DP master: FDL_Status, Set_Prm, Chk_Cfg, Slave_Diag and
;;; cyclic Data_Exchange.  Provides 2 input bytes, consumes 1 output byte.

(define pb-baud        (if (defined? 'pb-baud) pb-baud 19200))
(define pb-addr        (if (defined? 'pb-addr) pb-addr 3))
(define pb-ident       (if (defined? 'pb-ident) pb-ident #x0801))
(define pb-run-ms      (if (defined? 'pb-run-ms) pb-run-ms 8000))

(display "sim-slave: opening ") (display pb-port) (newline)

(define self (profibus-slave-open pb-port pb-baud pb-addr pb-ident 2 1))

;;  Accept exactly the configuration the master is going to send:
;;  0x11 = 2 bytes input, 0x20 = 1 byte output.
(profibus-slave-set-cfg self (bytevector #x11 #x20))

;;  Seed the inputs the master will read back.
(profibus-slave-inputs-set! self (bytevector #xDE #xAD))

(define deadline (+ (millis) pb-run-ms))
(define exchanges 0)
(define reached-data-exch #f)
(define last-out 0)

(let loop ()
  (let ((n (profibus-slave-service self)))
    (if (> n 0) (set! exchanges (+ exchanges n)))
    ;; Drain events so the queue never backs up.
    (let drain ()
      (let ((ev (profibus-slave-poll-event self)))
        (if ev (begin
                 (display "sim-slave event: ") (display ev) (newline)
                 (drain)))))
    (if (eq? (profibus-slave-state self) 'data-exch)
        (begin
          (set! reached-data-exch #t)
          ;; Echo the master's output byte back in input byte 1, so the master
          ;; can prove a full round trip through the process image.
          (let ((out (profibus-slave-outputs self)))
            (if (> (bytevector-length out) 0)
                (let ((v (bytevector-u8-ref out 0)))
                  (if (not (= v last-out))
                      (begin (set! last-out v)
                             (profibus-slave-inputs-set! self (bytevector #xDE v))))))))))
  (if (< (millis) deadline) (loop)))

(display "sim-slave: state=")      (display (profibus-slave-state self))
(display " exchanges=")            (display exchanges)
(display " reached-data-exch=")    (display reached-data-exch)
(display " last-out=")             (display last-out)
(newline)
(profibus-slave-close self)
(display "--- sim-slave done ---") (newline)
