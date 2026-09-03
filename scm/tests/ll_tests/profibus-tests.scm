;;; profibus-tests.scm -- unit tests for the P145 PROFIBUS DP bindings.
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-20 21:30:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Usage: echo '(load "ll_tests/profibus-tests.scm" 0)' | ./program
;;;
;;; Runs entirely on one host with NO hardware and NO external tools:
;;;   - FDL telegram byte layouts against the values published in P145
;;;   - FCS (arithmetic sum mod 256) vectors
;;;   - build/parse round-trips, SAP addressing, FCB toggle
;;;   - malformed-telegram rejection
;;;   - handle validation and the argument guards
;;;   - the software-responder baud ceiling (a refusal, not a silent failure)
;;;
;;; The master<->slave state machine over a real serial pair is a SEPARATE
;;; test -- see profibus-sim-master.scm / profibus-sim-slave.scm, driven by
;;; w3_ai_scripts/fieldbus_loopback.sh, because it needs two processes.

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

(define (bv->list bv)
  (let loop ((i (- (bytevector-length bv) 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons (bytevector-u8-ref bv i) acc)))))

(define (pb-throws? thunk25)
  (let ((threw #f))
    (guard (e (#t (set! threw #t))) (thunk25))
    threw))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 1. The worked telegrams published in P145
;;;    These byte strings appear verbatim in the proposal.  If the code and the
;;;    document ever disagree, one of them is wrong -- that is the point.
;;; ─────────────────────────────────────────────────────────────────────────

;;  Set_Prm: master 1 -> slave 3, ident 0x0801, WD 1000 ms, min T_SDR 11.
(pb-check "set-prm bytes"
  '(#x68 #x0C #x0C #x68 #x83 #x81 #x5D #x3D #x3E #x88 #x0A #x0A #x0B #x08 #x01 #x00 #x8C #x16)
  (bv->list (__profibus-set-prm 3 1 #f #x88 1000 11 #x0801 0)))

;;  Chk_Cfg with FCB toggled to 1: cfg = 1 byte in (0x10), 1 byte out (0x20).
(pb-check "chk-cfg bytes"
  '(#x68 #x07 #x07 #x68 #x83 #x81 #x7D #x3E #x3E #x10 #x20 #x2D #x16)
  (bv->list (__profibus-chk-cfg 3 1 #t (bytevector #x10 #x20))))

;;  Data_Exchange: no SAPs, one output byte.
(pb-check "data-exchange bytes"
  '(#x68 #x04 #x04 #x68 #x03 #x01 #x7D #xFF #x80 #x16)
  (bv->list (__profibus-data-exchange 3 1 #t (bytevector #xFF))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 2. FCS -- arithmetic sum mod 256 (NOT a CRC; PROFIBUS is simpler than Modbus)
;;; ─────────────────────────────────────────────────────────────────────────
(pb-check "fcs empty"      0   (__profibus-fcs (bytevector)))
(pb-check "fcs 1+2+3"      6   (__profibus-fcs (bytevector 1 2 3)))
(pb-check "fcs wraps"      0   (__profibus-fcs (bytevector 200 56)))
(pb-check "fcs 255x2"      254 (__profibus-fcs (bytevector 255 255)))
;;  The Set_Prm FCS is the sum of DA..last DU, which is bytes 4..15 of the frame.
(pb-check "fcs matches set-prm"
  #x8C
  (__profibus-fcs (bytevector #x83 #x81 #x5D #x3D #x3E #x88 #x0A #x0A #x0B #x08 #x01 #x00)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 3. Parse -- SAP addressing and field extraction
;;; ─────────────────────────────────────────────────────────────────────────
(define p-setprm (__profibus-parse (__profibus-set-prm 3 1 #f #x88 1000 11 #x0801 0)))
(pb-check "parse kind"  'sd2 (list-ref p-setprm 0))
(pb-check "parse da"    3    (list-ref p-setprm 1))
(pb-check "parse sa"    1    (list-ref p-setprm 2))
(pb-check "parse fc"    #x5D (list-ref p-setprm 3))
(pb-check "parse dsap"  61   (list-ref p-setprm 4))   ; Set_Prm
(pb-check "parse ssap"  62   (list-ref p-setprm 5))   ; master DP SAP
(pb-check "parse du-len" 7   (bytevector-length (list-ref p-setprm 6)))
;;  The DU is the parameter block AFTER the SAP pair: status, wd1, wd2, tsdr, ident-hi, ident-lo, group
(pb-check "parse du bytes" '(#x88 #x0A #x0A #x0B #x08 #x01 #x00)
  (bv->list (list-ref p-setprm 6)))

;;  Data_Exchange carries no SAPs, so dsap/ssap come back as #f.
(define p-dx (__profibus-parse (__profibus-data-exchange 3 1 #t (bytevector #xAA #xBB))))
(pb-check "parse no-sap dsap" #f (list-ref p-dx 4))
(pb-check "parse no-sap ssap" #f (list-ref p-dx 5))
(pb-check "parse no-sap du"   '(#xAA #xBB) (bv->list (list-ref p-dx 6)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 4. FCB toggle -- the alternating bit that distinguishes a retransmission
;;;    from a new request.  0x5D (FCB=0) vs 0x7D (FCB=1), same service.
;;; ─────────────────────────────────────────────────────────────────────────
(pb-check "fcb 0 -> 0x5D" #x5D
  (list-ref (__profibus-parse (__profibus-data-exchange 3 1 #f (bytevector 1))) 3))
(pb-check "fcb 1 -> 0x7D" #x7D
  (list-ref (__profibus-parse (__profibus-data-exchange 3 1 #t (bytevector 1))) 3))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 5. Malformed telegrams are REJECTED, each with its own reason
;;; ─────────────────────────────────────────────────────────────────────────
(define (corrupt bv i newval)
  (let* ((n (bytevector-length bv))
         (out (make-bytevector n 0)))
    (let loop ((k 0))
      (if (< k n)
          (begin (bytevector-u8-set! out k (if (= k i) newval (bytevector-u8-ref bv k)))
                 (loop (+ k 1)))
          out))))

(define good (__profibus-data-exchange 3 1 #t (bytevector #xAA #xBB)))
(define glen (bytevector-length good))

;;  FCS is the second-to-last byte; ED is the last.
(pb-check "reject bad fcs" 'bad-checksum
  (__profibus-parse (corrupt good (- glen 2) #x00)))
(pb-check "reject bad ed" 'bad-end-delimiter
  (__profibus-parse (corrupt good (- glen 1) #x00)))
(pb-check "reject le/ler mismatch" 'bad-length
  (__profibus-parse (corrupt good 2 #x09)))
(pb-check "reject bad start delim" 'bad-start-delimiter
  (__profibus-parse (corrupt good 0 #x99)))
(pb-check "reject short frame" 'short
  (__profibus-parse (bytevector #x68 #x04)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 6. Watchdog factorisation -- T_WD = WD_Fact_1 * WD_Fact_2 * 10 ms.
;;;    A balanced pair is what real masters emit (1000 ms -> 10 x 10).
;;; ─────────────────────────────────────────────────────────────────────────
(define (prm-wd-bytes ms)
  (let ((du (list-ref (__profibus-parse (__profibus-set-prm 3 1 #f #x88 ms 11 #x0801 0)) 6)))
    (list (bytevector-u8-ref du 1) (bytevector-u8-ref du 2))))

(pb-check "wd 1000ms -> 10x10" '(10 10) (prm-wd-bytes 1000))
(pb-check "wd 0 disables"      '(0 0)   (prm-wd-bytes 0))
(pb-check "wd 100ms"           100      (let ((f (prm-wd-bytes 100))) (* (car f) (cadr f) 10)))
;;  Rounding is always UP: a longer watchdog is safe, a shorter one is not.
(pb-check "wd 25ms rounds up"  #t       (>= (let ((f (prm-wd-bytes 25))) (* (car f) (cadr f) 10)) 25))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 7. Handle validation -- a bad handle raises, it does not corrupt state
;;; ─────────────────────────────────────────────────────────────────────────
(pb-check "bad bus handle raises"   #t (pb-throws? (lambda () (profibus-stats 99))))
(pb-check "bad slave handle raises" #t (pb-throws? (lambda () (profibus-state 99))))
(pb-check "negative handle raises"  #t (pb-throws? (lambda () (profibus-stats -1))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 8. The baud ceiling is a REFUSAL, not a silent intermittent failure.
;;;    A cooperative responder cannot meet T_SDR above ~500 kbit/s, so
;;;    profibus-slave-open must reject 1.5 Mbit/s outright (P145 R3).
;;; ─────────────────────────────────────────────────────────────────────────
(pb-check "slave-open refuses 1.5Mbaud" #t
  (pb-throws? (lambda () (profibus-slave-open "/dev/null" 1500000 3 #x0801 1 1))))

;;  Opening a port that does not exist must raise, not return a bogus handle.
(pb-check "open nonexistent port raises" #t
  (pb-throws? (lambda () (profibus-open "/dev/nonexistent-pb-port" 19200))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 9. Address validation
;;; ─────────────────────────────────────────────────────────────────────────
(pb-check "address 126 rejected" #t
  (pb-throws? (lambda () (profibus-slave-open "/dev/null" 19200 126 #x0801 1 1))))

(newline)
(display "Total: ") (display pb-pass) (display " pass, ")
(display pb-fail) (display " fail") (newline)
(display "--- profibus done ---") (newline)
