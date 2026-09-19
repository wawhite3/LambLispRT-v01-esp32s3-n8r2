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
(when (positive? (setting 'wifi 0))
  (WiFi.begin (setting 'wifi_ssid "") (setting 'wifi_pass ""))
  (WiFi.setSleep #f))          ;disable modem sleep: eliminates ~10ms WiFi preemptions
(syslog "WiFi loaded\n")
