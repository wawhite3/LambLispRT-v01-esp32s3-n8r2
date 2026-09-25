;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.

(syslog "Initializing WiFi\n")

(define have-WiFi (dict-ref? (current-environment) 'WiFi.begin))
(unless have-WiFi
  (warn "No WiFi\n")
  (define WiFi.begin   Lambda0)
  (define WiFi.setSleep Lambda0)
  )

;; WiFi does NOT auto-connect at boot.  Set (wifi . 1) in Settings.scm (with wifi_ssid / wifi_pass)
;; to auto-connect; otherwise an app calls (WiFi.begin ssid pass) explicitly when it needs the radio.
;; Skipping the connect frees internal DRAM (the radio's rx/tx buffers) -- critical on the 2MB-PSRAM
;; S3, where the LittleFS read path needs internal RAM (a starved internal heap is the B60 err-257
;; root cause: WiFi was auto-connecting to a stale SSID, reserving DRAM for a connection that failed).
;;; [B396] WAIT FOR THE RADIO, AND SAY WHAT HAPPENED.
;;;
;;; This fired `WiFi.begin` and moved straight on.  Association is ASYNCHRONOUS and takes seconds,
;;; so a board that never associated produced EXACTLY the output of one that did: nothing.  That is
;;; why "the radio is enabled but never associates" stood in [B396] for months with nobody able to
;;; say why -- the boot path did not know either, so every later diagnosis started from "we do not
;;; know", and the 48,752 bytes of internal DRAM the radio legitimately needs were being spent with
;;; no statement of whether they bought a connection.
;;;
;;; The loop is the one from `net-wait-associated` (network-tests.scm), which was already correct and
;;; already proven -- bounded, and it returns THE INSTANT the radio is up, so an AP that answers
;;; quickly costs almost nothing.  It was in the test and not in the boot path, which is precisely
;;; backwards: the test can afford to discover this late, the boot cannot.
;;;
;;; BOUNDED, AND THE FALLTHROUGH IS REPORTED.  An unbounded wait whose condition cannot occur is
;;; indistinguishable from working.  On expiry this says so and boot CONTINUES -- a board with no
;;; network is still a board, and halting here would turn a degraded node into a dead one.
;;;
;;; `wifi_wait` is settable so a slow AP can be given longer and an impatient target less; 0 skips
;;; the wait entirely and restores the old fire-and-forget behaviour for anyone who wants it, which
;;; is a choice rather than the default.
(when (positive? (setting 'wifi 0))
  (WiFi.begin (setting 'wifi_ssid "") (setting 'wifi_pass ""))
  (WiFi.setSleep #f)           ;disable modem sleep: eliminates ~10ms WiFi preemptions
  (let ((tenths (setting 'wifi_wait 100)))          ;;; 100 tenths = 10 s, as net-wait-associated
    (if (and (positive? tenths) (dict-ref? (current-environment) 'WiFi.isConnected))
        (let loop ((n tenths))
          (cond ((WiFi.isConnected)
                 (syslog "WiFi associated to ~a after ~a ms\n"
                         (setting 'wifi_ssid "") (* 100 (- tenths n))))
                ((<= n 0)
                 (warn "WiFi FAILED to associate to '~a' in ~a ms -- continuing without network\n"
                       (setting 'wifi_ssid "") (* 100 tenths)))
                (else (delay-ms 100) (loop (- n 1)))))
        (syslog "WiFi: not waiting for association (wifi_wait ~a)\n" tenths))))
(syslog "WiFi loaded\n")
