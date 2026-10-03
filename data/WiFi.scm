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
;;; THE KNOWN-AP LIST.  `wifi_aps` is a list of (SSID . PASSWORD) pairs; `wifi_ssid`/`wifi_pass`
;;; remain the single-AP spelling and are used when no list is given, so an existing Settings file
;;; keeps working unchanged.  A board that can see more than one network should list them all:
;;; rotation is what turns "the one AP was busy at boot" from a dead node into a slow one.
(define (wifi-ap-list)
  (let ((aps (setting 'wifi_aps '())))
    (if (pair? aps)
        aps
        (list (cons (setting 'wifi_ssid "") (setting 'wifi_pass ""))))))

(define wifi-aps        (wifi-ap-list))
(define wifi-ap-index   0)
(define wifi-last-try   0)       ;;;!< millis of the last WiFi.begin
(define wifi-last-poll  0)       ;;;!< millis of the last status check
(define wifi-was-up     #f)      ;;;!< so the up-edge is announced once, not every tick
(define wifi-tries      0)
(define wifi-cur-ssid   "")      ;;;!< the SSID the radio was last pointed at
(define wifi-backoff-ms 0)       ;;;!< current retry interval; doubles on failure, resets on success

(define (wifi-ap-ref i)
  (let ((n (length wifi-aps)))
    (if (zero? n) (cons "" "") (list-ref wifi-aps (modulo i n)))))

;;; ELAPSED, WRAP-TOLERANT.  `millis` is a 32-bit millisecond counter and wraps after ~49 days.  A
;;; bare (- now then) goes NEGATIVE across the wrap, and a retry gated on `>=` would then wait out
;;; the whole counter -- a board would stop retrying exactly once every seven weeks, which is the
;;; kind of fault nobody ever reproduces.  Treat a negative span as "due now": the worst it can do
;;; is retry one cycle early, once.
(define (wifi-since then)
  (let ((d (- (millis) then))) (if (negative? d) 999999 d)))

;;; (wifi-tick!) -- call from an application loop.  Non-blocking and cheap.
;;;
;;; WHY A TICK AND NOT A LONGER WAIT AT BOOT.  Association is ASYNCHRONOUS, so the boot-time wait can
;;; only ever be a guess at how long the AP will take today -- and a board whose association time
;;; varies (a busy AP, a weak signal, a channel scan) will sooner or later fall outside any fixed
;;; budget.  When it does, the old behaviour left the radio enabled, unassociated, and never tried
;;; again: a headless board then sits unreachable until somebody power-cycles it, and the only way in
;;; is the serial port, which RESETS the board and re-runs the same race.  Widening the budget makes
;;; that rarer without making it recoverable.  Retrying makes it recoverable, which is the property
;;; that matters on a node nobody can reach.
;;;
;;; IT MUST NOT BLOCK.  `WiFi.begin` starts an attempt and returns; this fires it and leaves.  The
;;; NEXT tick reads the result.  Waiting here instead would stall a cooperative loop for seconds --
;;; on a real-time target that is worse than having no network.
;;;
;;; IT MUST ALSO BE CHEAP, because a loop calls it at whatever rate it runs.  Everything is behind a
;;; time gate, so the common case (connected, nothing to do) is one subtraction and one comparison.
(define (wifi-tick!)
  (when (and have-WiFi
             (positive? (setting 'wifi 0))
             (dict-ref? (current-environment) 'WiFi.isConnected)
             (>= (wifi-since wifi-last-poll) (setting 'wifi_poll_ms 1000)))
    (set! wifi-last-poll (millis))
    (if (WiFi.isConnected)
        (begin
          (unless wifi-was-up
            (syslog "WiFi associated to ~a (~a) after ~a attempt(s)\n"
                    (car (wifi-ap-ref wifi-ap-index)) (WiFi.localIP) wifi-tries)
            (set! wifi-backoff-ms (setting 'wifi_retry_ms 15000))   ;;;!< a later drop recovers fast
            (set! wifi-was-up #t)))
        (begin
          ;; SAY SO ON THE DOWN EDGE.  A link that dropped and a link that never came up look the
          ;; same from outside, and they are different faults.
          (when wifi-was-up
            (warn "WiFi link LOST -- retrying\n")
            (set! wifi-was-up #f))
          ;; BACK OFF.  A FIXED RETRY INTERVAL IS NOT FREE ON A BOARD THAT CANNOT ASSOCIATE.
          ;; Each attempt is real radio work, and on a target whose display DMA reads continuously
          ;; from the same memory the radio contends for, a retry every 15 s forever is sustained
          ;; interference rather than an occasional cost.  Measured on the 480x480 panel: while this
          ;; retried 24 times against an AP it could not join, the display desynchronised repeatedly
          ;; and a scan re-sync could not hold it; silencing the retry and re-syncing once left the
          ;; picture stable.  The retry was destabilising the screen it shares a board with.
          ;; So: `wifi_retry_ms` is the FIRST interval, doubling to `wifi_retry_max_ms` (default 4
          ;; minutes).  A board that can associate still recovers in seconds -- the first retry is
          ;; unchanged -- and a board that cannot stops shouting.  The interval resets on a
          ;; successful association, so a link that drops later recovers quickly again.
          (when (>= (wifi-since wifi-last-try) wifi-backoff-ms)
            ;; ONLY ROTATE WHEN THERE IS SOMEWHERE TO ROTATE TO.  With one configured AP every
            ;; index maps to the same entry, so advancing it is pure churn in the log.
            (let* ((next (if (> (length wifi-aps) 1) (+ wifi-ap-index 1) wifi-ap-index))
                   (ap   (wifi-ap-ref next)))
              ;; DO NOT TEAR DOWN AN ATTEMPT THAT IS STILL IN PROGRESS.  This used to
              ;; `WiFi.disconnect` before every retry, on the reasoning that a pending association
              ;; to the old SSID would otherwise hold the radio.  That is true only when the SSID
              ;; CHANGES; when it does not, the disconnect aborts the very attempt that was about to
              ;; succeed, and a retry interval shorter than the association time then prevents the
              ;; association it exists to obtain -- a retry that denies service to itself.
              ;; MEASURED on this board: association has taken 1.1 s, 1.3 s and 7.8 s on different
              ;; boots, so a 15 s interval is NOT comfortably longer than an attempt, and the first
              ;; version of this code ran five disconnect/begin cycles in 70 s without ever
              ;; associating -- against an AP that was up and serving two other boards throughout.
              (when (and (not (string=? (car ap) wifi-cur-ssid))
                         (dict-ref? (current-environment) 'WiFi.disconnect))
                (WiFi.disconnect))
              (set! wifi-ap-index next)
              (set! wifi-cur-ssid (car ap))
              (set! wifi-tries (+ wifi-tries 1))
              (set! wifi-last-try (millis))
              (set! wifi-backoff-ms
                    (min (* 2 (max wifi-backoff-ms (setting 'wifi_retry_ms 15000)))
                         (setting 'wifi_retry_max_ms 240000)))
              (syslog "WiFi retry ~a -> '~a'\n" wifi-tries (car ap))
              (WiFi.begin (car ap) (cdr ap))))))))

(when (positive? (setting 'wifi 0))
  (let ((ap0 (wifi-ap-ref 0)))
    (WiFi.begin (car ap0) (cdr ap0))
    (set! wifi-cur-ssid (car ap0))
    (WiFi.setSleep #f)           ;disable modem sleep: eliminates ~10ms WiFi preemptions
    (set! wifi-last-try (millis))
    (set! wifi-backoff-ms (setting 'wifi_retry_ms 15000))
    (let ((tenths (setting 'wifi_wait 100)))          ;;; 100 tenths = 10 s, as net-wait-associated
      (if (and (positive? tenths) (dict-ref? (current-environment) 'WiFi.isConnected))
          (let loop ((n tenths))
            (cond ((WiFi.isConnected)
                   (set! wifi-was-up #t)
                   (syslog "WiFi associated to ~a after ~a ms\n"
                           (car ap0) (* 100 (- tenths n))))
                  ((<= n 0)
                   ;; NOT the end of the story any more -- `wifi-tick!` keeps trying, and rotates
                   ;; through `wifi_aps` if more than one is configured.  Say which, so a reader of
                   ;; the boot log knows whether to expect recovery or to go and look at the AP.
                   (warn "WiFi did not associate to '~a' in ~a ms -- continuing; retrying every ~a ms across ~a known AP(s)\n"
                         (car ap0) (* 100 tenths) (setting 'wifi_retry_ms 15000) (length wifi-aps)))
                  (else (delay-ms 100) (loop (- n 1)))))
          (syslog "WiFi: not waiting for association (wifi_wait ~a)\n" tenths)))))
(syslog "WiFi loaded\n")
