;;; modbus-tests.scm -- unit tests for the P108 Modbus bindings (TCP + RTU framing).
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-05 12:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Usage: echo '(load "ll_tests/modbus-tests.scm" 0)' | ./program
;;;
;;; Runs entirely on one host with NO external hardware and NO external tools:
;;;   - CRC-16 vectors against known-good values
;;;   - MBAP / PDU / RTU frame byte-layout assertions
;;;   - float32 register encode/decode round-trips (both word orders)
;;;   - a localhost TCP loopback: an in-process LambLisp peripheral serves a
;;;     register bank while an in-process LambLisp controller reads/writes it,
;;;     exercising FC01/02/03/04/05/06/15/16, the pending-guard, the response
;;;     timeout, the write callback, and two simultaneous handles.

(define mb-pass 0)
(define mb-fail 0)

(define (mb-check name expected actual)
  (if (equal? expected actual)
      (begin (display "PASS ") (display name) (newline)
             (set! mb-pass (+ mb-pass 1)))
      (begin (display "FAIL ") (display name)
             (display " expected=") (display expected)
             (display " got=") (display actual) (newline)
             (set! mb-fail (+ mb-fail 1)))))

(define (bv->list bv)
  (let loop ((i (- (bytevector-length bv) 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons (bytevector-u8-ref bv i) acc)))))

(define (mb-throws? thunk20)
  (let ((threw #f))
    (guard (e (#t (set! threw #t))) (thunk20))
    threw))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 1. CRC-16 (Modbus, poly 0xA001) — known-good vectors
;;; ─────────────────────────────────────────────────────────────────────────
;;  "123456789" (ASCII 49..57) -> 0x4B37, the canonical CRC16/MODBUS check value.
(mb-check "crc16-123456789" #x4B37
  (__modbus-crc16 (bytevector 49 50 51 52 53 54 55 56 57)))
;;  Empty input -> 0xFFFF (initial value, no bytes folded).
(mb-check "crc16-empty" #xFFFF (__modbus-crc16 (bytevector)))
;;  Single 0x00 byte -> 0x40BF.
(mb-check "crc16-one-zero" #x40BF (__modbus-crc16 (bytevector 0)))
;;  PDU of an FC03 read (unit 1, addr 0, count 2): 01 03 00 00 00 02 -> 0x0BC4.
(mb-check "crc16-fc03-pdu" #x0BC4
  (__modbus-crc16 (bytevector 1 3 0 0 0 2)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 2. Frame byte layouts (MBAP header, PDU, RTU CRC placement)
;;; ─────────────────────────────────────────────────────────────────────────
;;  TCP FC03 read-holding, unit 1, txn 1, addr 0, count 2.
;;  MBAP: txn=0001 proto=0000 len=0006 unit=01, then PDU 03 0000 0002.
(mb-check "tcp-fc03-frame" '(0 1 0 0 0 6 1 3 0 0 0 2)
  (bv->list (__modbus-tcp-frame 1 1 'read-holding 0 2)))
;;  RTU FC03 read-holding: unit 01, PDU 03 0000 0002, CRC 0x0BC4 low-byte-first.
(mb-check "rtu-fc03-frame" '(1 3 0 0 0 2 #xC4 #x0B)
  (bv->list (__modbus-rtu-frame 1 'read-holding 0 2)))
;;  TCP FC06 write single register, addr 9, value 1500 (0x05DC).
(mb-check "tcp-fc06-frame" '(0 5 0 0 0 6 1 6 0 9 #x05 #xDC)
  (bv->list (__modbus-tcp-frame 1 5 'write-register 9 1500)))
;;  TCP FC16 write multiple registers, addr 10, values #(1500 0):
;;  len=0x0B, fc=0x10, addr=000A, count=0002, byte-count=04, data 05DC 0000.
(mb-check "tcp-fc16-frame" '(0 7 0 0 0 #x0B 1 #x10 0 #x0A 0 2 4 #x05 #xDC 0 0)
  (bv->list (__modbus-tcp-frame 1 7 'write-registers 10 (vector 1500 0))))
;;  TCP FC05 write single coil #t -> value word 0xFF00.
(mb-check "tcp-fc05-frame-on" '(0 1 0 0 0 6 1 5 0 0 #xFF 0)
  (bv->list (__modbus-tcp-frame 1 1 'write-coil 0 #t)))
;;  TCP FC05 write single coil #f -> value word 0x0000.
(mb-check "tcp-fc05-frame-off" '(0 1 0 0 0 6 1 5 0 0 0 0)
  (bv->list (__modbus-tcp-frame 1 1 'write-coil 0 #f)))
;;  TCP FC0F write multiple coils #(#t #f #t #t) -> 1 byte, bits LSB-first = 0x0D.
(mb-check "tcp-fc0f-frame" '(0 1 0 0 0 8 1 #x0F 0 0 0 4 1 #x0D)
  (bv->list (__modbus-tcp-frame 1 1 'write-coils 0 (vector #t #f #t #t))))
;;  Unknown fc symbol raises.
(mb-check "unknown-fc-raises" #t
  (mb-throws? (lambda () (__modbus-tcp-frame 1 1 'bogus-fc 0 2))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 3. Localhost TCP loopback: in-process peripheral + controller
;;; ─────────────────────────────────────────────────────────────────────────
;; B178: ON ESP32 THE lwIP TCPIP TASK DOES NOT EXIST UNTIL A NETIF IS CREATED, and Modbus TCP
;; needs it -- 127.0.0.1 is served by lwIP's loopback interface, which is part of that stack, so
;; even a purely in-process loopback requires it.  Until 2026-08-29 calling in without it did not
;; fail, it PANICKED the board ("assert failed: tcpip_send_msg_wait_sem ... (Invalid mbox)") and
;; rebooted mid-suite; the C++ side now raises instead, and this brings the stack up so the
;; section can actually run.
;;
;; WiFi.mode(WIFI_STA) creates the STA netif and starts that task WITHOUT associating to an access
;; point -- no SSID, no credentials, no radio link, nothing external.  That is all loopback needs,
;; which keeps this suite self-contained on the board exactly as it is on a host.
;;
;; On hosts there is no WiFi binding at all, so the symbol is unbound and the guard makes this a
;; no-op.  POSIX loopback is always available and needs no setup.
(define (mb-ensure-net!)
  (guard (e (#t #f))
    (WiFi.mode 1)                       ;; 1 = WIFI_STA
    #t))
(mb-ensure-net!)

(define port 15020)
(define unit-id 1)
(define periph (modbus-tcp-peripheral-open port unit-id))
(define conn   (modbus-tcp-connect "127.0.0.1" port unit-id))

;; Interleave: serve the peripheral, then poll the controller, until a result.
(define (poll-until tok)
  (let loop ((n 0))
    (modbus-peripheral-poll periph)
    (let ((r (modbus-poll tok)))
      (cond (r r)
            ((> n 200000) (error "modbus poll-until: no response"))
            (else (loop (+ n 1)))))))

(define (poll-until-f32 tok)
  (let loop ((n 0))
    (modbus-peripheral-poll periph)
    (let ((r (modbus-poll-float32 tok)))
      (cond (r r)
            ((> n 200000) (error "modbus poll-until-f32: no response"))
            (else (loop (+ n 1)))))))

;; Seed the register bank from the Scheme side.
(modbus-peripheral-hreg!   periph 0 111)
(modbus-peripheral-hreg!   periph 1 222)
(modbus-peripheral-hreg!   periph 2 333)
(modbus-peripheral-hreg!   periph 3 444)
(modbus-peripheral-ireg!   periph 0 235)
(modbus-peripheral-ireg!   periph 1 10132)
(modbus-peripheral-coil!   periph 0 #t)
(modbus-peripheral-coil!   periph 1 #f)
(modbus-peripheral-coil!   periph 2 #t)
(modbus-peripheral-dinput! periph 0 #t)
(modbus-peripheral-dinput! periph 1 #t)

;; FC03 read holding
(mb-check "read-holding" #(111 222 333 444)
  (poll-until (modbus-request conn 'read-holding 0 4)))

;; FC04 read input registers
(mb-check "read-input" #(235 10132)
  (poll-until (modbus-request conn 'read-input 0 2)))

;; FC01 read coils
(mb-check "read-coils" #(#t #f #t)
  (poll-until (modbus-request conn 'read-coils 0 3)))

;; FC02 read discrete inputs
(mb-check "read-discrete" #(#t #t)
  (poll-until (modbus-request conn 'read-discrete-inputs 0 2)))

;; FC06 write single register, then read it back
(mb-check "write-register-ok" #t
  (poll-until (modbus-request conn 'write-register 0 1500)))
(mb-check "write-register-readback" #(1500)
  (poll-until (modbus-request conn 'read-holding 0 1)))
(mb-check "write-register-scheme-side" 1500 (modbus-peripheral-hreg periph 0))

;; FC16 write multiple registers, then read back
(mb-check "write-registers-ok" #t
  (poll-until (modbus-request conn 'write-registers 4 (vector 10 20 30 40))))
(mb-check "write-registers-readback" #(10 20 30 40)
  (poll-until (modbus-request conn 'read-holding 4 4)))

;; FC05 write single coil, then read back
(mb-check "write-coil-ok" #t
  (poll-until (modbus-request conn 'write-coil 5 #t)))
(mb-check "write-coil-readback" #(#t)
  (poll-until (modbus-request conn 'read-coils 5 1)))
(mb-check "write-coil-scheme-side" #t (modbus-peripheral-coil periph 5))

;; FC15 write multiple coils, then read back
(mb-check "write-coils-ok" #t
  (poll-until (modbus-request conn 'write-coils 8 (vector #t #f #t #t))))
(mb-check "write-coils-readback" #(#t #f #t #t)
  (poll-until (modbus-request conn 'read-coils 8 4)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 4. Float32 register encode/decode round-trips (both word orders)
;;; ─────────────────────────────────────────────────────────────────────────
;; Split a float into its two 16-bit registers (big-endian words = 'abcd order).
(define f32-words (struct-unpack ">HH" (struct-pack ">f" 3.5)))
(define hi-word (car  f32-words))
(define lo-word (cadr f32-words))

(define (about= a b) (< (abs (- a b)) 0.001))

;; 'abcd : register[addr]=high word, register[addr+1]=low word
(modbus-peripheral-hreg! periph 20 hi-word)
(modbus-peripheral-hreg! periph 21 lo-word)
(mb-check "float32-abcd" #t
  (about= 3.5 (poll-until-f32 (modbus-request-float32 conn 20 'abcd))))

;; 'cdab : words swapped
(modbus-peripheral-hreg! periph 22 lo-word)
(modbus-peripheral-hreg! periph 23 hi-word)
(mb-check "float32-cdab" #t
  (about= 3.5 (poll-until-f32 (modbus-request-float32 conn 22 'cdab))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 5. Write callback (on-write!)
;;; ─────────────────────────────────────────────────────────────────────────
(define cb-table #f)
(define cb-addr  #f)
(define cb-vals  #f)
(modbus-peripheral-on-write! periph
  (lambda (table addr vals)
    (set! cb-table table)
    (set! cb-addr  addr)
    (set! cb-vals  vals)))

(poll-until (modbus-request conn 'write-register 2 4242))
(mb-check "on-write-table" 'holding cb-table)
(mb-check "on-write-addr"  2        cb-addr)
(mb-check "on-write-vals"  #(4242)  cb-vals)

(poll-until (modbus-request conn 'write-coils 0 (vector #t #t)))
(mb-check "on-write-coils-table" 'coils   cb-table)
(mb-check "on-write-coils-addr"  0        cb-addr)
(mb-check "on-write-coils-vals"  #(#t #t) cb-vals)

;;; ─────────────────────────────────────────────────────────────────────────
;;; 6. Pending guard — second request while one is outstanding raises
;;; ─────────────────────────────────────────────────────────────────────────
(define t-pending (modbus-request conn 'read-holding 0 1))
(mb-check "pending-guard" #t
  (mb-throws? (lambda () (modbus-request conn 'read-holding 0 1))))
(poll-until t-pending)   ;; drain the outstanding request to clear pending

;;; ─────────────────────────────────────────────────────────────────────────
;;; 7. Response timeout — poll raises when no peripheral serves the request
;;; ─────────────────────────────────────────────────────────────────────────
(define conn-to (modbus-tcp-connect "127.0.0.1" port unit-id))
(modbus-set-timeout conn-to 50)
(define t-to (modbus-request conn-to 'read-holding 0 1))
;; Never call peripheral-poll for this connection, so no response ever arrives.
(mb-check "timeout-raises" #t
  (mb-throws?
    (lambda ()
      (let loop ()
        (modbus-poll t-to)     ;; returns #f until the 50 ms deadline, then raises
        (loop)))))
(modbus-close conn-to)

;;; ─────────────────────────────────────────────────────────────────────────
;;; 8. Multiple handles / multiple peripherals coexisting
;;; ─────────────────────────────────────────────────────────────────────────
(define port2   15021)
(define periph2 (modbus-tcp-peripheral-open port2 unit-id))
(define conn2   (modbus-tcp-connect "127.0.0.1" port2 unit-id))
(modbus-peripheral-hreg! periph2 0 7777)

(define (poll-until2 tok)
  (let loop ((n 0))
    (modbus-peripheral-poll periph2)
    (let ((r (modbus-poll tok)))
      (cond (r r)
            ((> n 200000) (error "poll-until2: no response"))
            (else (loop (+ n 1)))))))

(mb-check "multi-handle-conn2" #(7777)
  (poll-until2 (modbus-request conn2 'read-holding 0 1)))
;; conn (handle 0) still works independently
(mb-check "multi-handle-conn1" #(1500)
  (poll-until (modbus-request conn 'read-holding 0 1)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 9. Peripheral accessor bounds + idle poll
;;; ─────────────────────────────────────────────────────────────────────────
(mb-check "hreg-oob-raises" #t
  (mb-throws? (lambda () (modbus-peripheral-hreg periph 100000))))
(mb-check "coil-oob-raises" #t
  (mb-throws? (lambda () (modbus-peripheral-coil periph -1))))
(mb-check "ireg-roundtrip" 4321
  (begin (modbus-peripheral-ireg! periph 5 4321) (modbus-peripheral-ireg periph 5)))
(mb-check "dinput-roundtrip" #f
  (begin (modbus-peripheral-dinput! periph 5 #f) (modbus-peripheral-dinput periph 5)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; Cleanup + summary
;;; ─────────────────────────────────────────────────────────────────────────
(modbus-close conn)
(modbus-close conn2)
(modbus-peripheral-close periph)
(modbus-peripheral-close periph2)

(display "Total: ") (display mb-pass) (display " pass, ")
(display mb-fail) (display " fail") (newline)
(display "--- modbus done ---") (newline)
