;;; profinet-tests.scm -- P145 Part B, LambLisp-side PROFINET bindings.
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-20 23:40:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Driven by w3_ai_scripts/profinet_loopback.sh, which starts the mock daemon
;;; and defines `pn-sock` before loading this file.
;;;
;;; Exercises the LambLisp half end to end -- open, HELLO, device model, start,
;;; process image round trip, IOPS/IOCS, events, stats, error mapping -- with
;;; NO p-net, NO GPLv3 code and NO controller.  What it CANNOT test is wire
;;; behaviour; that needs the real daemon and a real IO-Controller.

(define pn-pass 0)
(define pn-fail 0)
(define (pn-check name expected actual)
  (if (equal? expected actual)
      (begin (display "PASS ") (display name) (newline)
             (set! pn-pass (+ pn-pass 1)))
      (begin (display "FAIL ") (display name)
             (display " expected=") (display expected)
             (display " got=") (display actual) (newline)
             (set! pn-fail (+ pn-fail 1)))))

(define (bv->list bv)
  (let loop ((i (- (bytevector-length bv) 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons (bytevector-u8-ref bv i) acc)))))

(define (pn-throws? thunk26)
  (let ((threw #f))
    (guard (e (#t (set! threw #t))) (thunk26))
    threw))

;;; ── 1. Connect + HELLO ───────────────────────────────────────────────────
;;  A missing daemon must raise, not hand back a dead handle.
(pn-check "open nonexistent socket raises" #t
  (pn-throws? (lambda () (profinet-device-open "/tmp/no-such-pn-socket-9173" #x1234 #x0001))))

(define dev (profinet-device-open pn-sock #x1234 #x0001))
(pn-check "device handle is an integer" #t (integer? dev))

;;; ── 2. Device model ──────────────────────────────────────────────────────
(profinet-add-module    dev 1 #x00000010)
(profinet-add-submodule dev 1 1 #x00000001 4 4)

;;  A submodule that was never declared must be rejected locally, before the
;;  daemon is even asked.
(pn-check "undeclared submodule raises" #t
  (pn-throws? (lambda () (profinet-inputs-set! dev 9 9 (bytevector 1 2 3 4)))))

;;; ── 3. Lifecycle ─────────────────────────────────────────────────────────
(pn-check "state before start" 'offline (profinet-state dev))
(pn-check "not connected before start" #f (profinet-connected? dev))

(profinet-start dev "lamb-io-1")
(pn-check "state after start" 'operate (profinet-state dev))
(pn-check "connected after start" #t (profinet-connected? dev))

;;; ── 4. Process image round trip ──────────────────────────────────────────
(profinet-inputs-set! dev 1 1 (bytevector #xDE #xAD #xBE #xEF))
(pn-check "outputs round-trip" '(#xDE #xAD #xBE #xEF)
  (bv->list (profinet-outputs dev 1 1)))

;;  A second publish must propagate -- proves we are not reading a cached copy.
(profinet-inputs-set! dev 1 1 (bytevector 1 2 3 4))
(pn-check "republished data propagates" '(1 2 3 4)
  (bv->list (profinet-outputs dev 1 1)))

;;  Short input is zero-padded to the declared length, never left ragged.
(profinet-inputs-set! dev 1 1 (bytevector #xAA))
(pn-check "short input zero-padded" '(#xAA 0 0 0)
  (bv->list (profinet-outputs dev 1 1)))

;;; ── 5. IOPS / IOCS ───────────────────────────────────────────────────────
(pn-check "iocs good after exchange" 'good (profinet-iocs dev 1 1))
(profinet-iops-set! dev 1 1 #f)          ; declare our own data BAD
(profinet-iops-set! dev 1 1 #t)          ; and good again
(pn-check "iops toggle survives" 'good (profinet-iocs dev 1 1))

;;; ── 6. Events ────────────────────────────────────────────────────────────
;;  The mock replays a scripted DCP sequence; the ORDER matters because it is
;;  the commissioning order a real engineering tool uses.
(define ev1 (profinet-poll-event dev))
(pn-check "first event is dcp-set-name" 'dcp-set-name (car ev1))
(pn-check "name payload"        "lamb-io-1" (cadr ev1))

(define ev2 (profinet-poll-event dev))
(pn-check "second event is dcp-set-ip" 'dcp-set-ip (car ev2))
(pn-check "ip payload is 12 bytes" 12 (bytevector-length (cadr ev2)))
(pn-check "ip address bytes" '(192 168 0 50)
  (list (bytevector-u8-ref (cadr ev2) 0) (bytevector-u8-ref (cadr ev2) 1)
        (bytevector-u8-ref (cadr ev2) 2) (bytevector-u8-ref (cadr ev2) 3)))

(pn-check "third event is connect"   'connect   (car (profinet-poll-event dev)))
(pn-check "fourth event is param-end" 'param-end (car (profinet-poll-event dev)))

;;  Drained queue returns #f, NOT an error -- an empty poll is normal.
(let drain () (if (profinet-poll-event dev) (drain)))
(pn-check "empty queue returns #f" #f (profinet-poll-event dev))

;;; ── 7. Alarms + stats ────────────────────────────────────────────────────
(profinet-alarm dev 1 1 #x0002 (bytevector 1 2))
(define st (profinet-stats dev))
(pn-check "stats has 6 fields" 6 (length st))
(pn-check "cycles counted"     #t (> (car st) 0))
(pn-check "alarm counted"      1  (list-ref st 4))

;;; ── 8. Shutdown ──────────────────────────────────────────────────────────
(profinet-stop dev)
(pn-check "state after stop" 'offline (profinet-state dev))
(profinet-device-close dev)
(pn-check "use after close raises" #t
  (pn-throws? (lambda () (profinet-state dev))))

(newline)
(display "Total: ") (display pn-pass) (display " pass, ")
(display pn-fail) (display " fail") (newline)
(display "--- profinet done ---") (newline)
