;;; Copyright 2026 by Frobenius Norm LLC 2026-09-25
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; netscan.scm -- ask the BOARD what it can hear, and why it is not joined.
;;;
;;; WHY THIS IS A FILE AND NOT A FORM SOMEONE TYPES.  A board that will not associate is diagnosed
;;; by comparing two things: the SSID it is configured for, and the list of access points its own
;;; antenna can actually reach.  A scan from a workstation answers neither -- measured on this
;;; bench, a 4-inch RGB panel hears 2 access points where a bare devkit sitting beside it hears 5,
;;; because the panel's own display bus costs 10-13 dB on a weak signal.  So the only antenna whose
;;; opinion matters is the one on the board, and the only way to ask it is from the board.
;;;
;;; AND IT MUST BE A DEFINITION, NOT A TYPED EXPRESSION.  Opening the serial port resets an ESP32,
;;; so a board that is off the network can only be questioned over a console that ECHOES every
;;; character of what is typed -- a scan loop typed by hand comes back as several kilobytes of
;;; partial-line echo with the answer buried in it, which is how this was first attempted and why
;;; it failed.  A short call to a definition that already exists on the board produces a short
;;; echo and a readable answer.

(syslog "Loading netscan\n")

;;; `WiFi.status` RETURNS A PAIR -- (3 WL_CONNECTED), (6 WL_DISCONNECTED) -- NOT A BARE INTEGER.
;;; Comparing it with `=` raises `coerce_float64() Bad type ... T_PAIR` rather than returning #f,
;;; so a caller that guards the call sees "not connected" on a board that is perfectly associated.
;;; Take the code out of the pair, and tolerate a bare integer in case the accessor changes back.
(define (net-status-code)
  (let ((s (WiFi.status)))
    (if (pair? s) (car s) s)))

(define (net-connected?)
  (if (defined? 'WiFi.isConnected) (WiFi.isConnected) (equal? (net-status-code) 3)))

;;; A NEGATIVE RETURN FROM `WiFi.scanNetworks` IS AN ERROR CODE, NOT A COUNT.  The underlying
;;; Arduino call returns -1 while a scan is still running and -2 when the scan FAILED outright, and
;;; both are radio faults rather than quiet airwaves.  Treating them as a count is not a cosmetic
;;; slip: -2 compares as less than every index, so a loop written the obvious way reports "0 of -2
;;; networks matched" and the caller concludes the access point is out of range.  That is a WRONG
;;; DIAGNOSIS handed over with the same confidence as a right one -- observed 2026-09-25, when this
;;; procedure's first version said an access point broadcasting at full strength was unreachable.
(define (net-scan-failed? n) (and (number? n) (negative? n)))

(define (net-scan-code-text n)
  (cond ((equal? n -1) "scan still running")
        ((equal? n -2) "scan FAILED -- the radio did not complete it")
        (else "scan returned an unknown negative code")))

;;; (net-scan) -> the number of access points heard, or a NEGATIVE error code.  Callers must test
;;; with `net-scan-failed?` before using the value as a count.  The order is whatever the radio
;;; returned; sorting it would hide the fact that two scans seconds apart can disagree, which is
;;; itself the finding on a marginal link.
;;; A FAILED SCAN IS USUALLY THE BOARD'S OWN RECONNECT, NOT A BROKEN RADIO.  After an association
;;; attempt fails the station keeps retrying in the background, and a scan requested while that is
;;; in flight returns -2 -- so the board reports "scan FAILED" on hardware that is working
;;; perfectly, at exactly the moment someone is trying to find out why it will not join.  Idling
;;; the station clears it and the retry resumes by itself.
;;;
;;; ONLY WHEN THERE IS NOTHING TO LOSE.  `WiFi.disconnect` on an associated board would drop a good
;;; link to answer a question about a link that is already good, so the retry is guarded on NOT
;;; being connected.  A diagnostic that breaks what it was called to inspect is worse than no
;;; diagnostic: the next reading is of a board this procedure disturbed.
(define (net-scan-once) (WiFi.scanNetworks))

(define (net-scan)
  (let ((n (let ((first (net-scan-once)))
             (if (and (net-scan-failed? first) (not (net-connected?)))
                 (begin
                   (syslog "netscan: first scan returned ~a; quiescing the station and retrying once\n"
                           first)
                   ;; AUTO-RECONNECT IS WHY A DISCONNECT ALONE IS NOT ENOUGH.  `WiFi.disconnect`
                   ;; drops the association but leaves the station's retry armed, so it is dialling
                   ;; again within milliseconds and the scan is refused for the same reason as
                   ;; before -- which looks exactly like the disconnect having no effect.  Measured
                   ;; 2026-09-25: disconnect + 500 ms still returned -2.  Turn the retry off, scan,
                   ;; then put it back, because leaving a board that cannot reconnect by itself is
                   ;; a far worse state than the one being diagnosed.
                   (if (defined? 'WiFi.setAutoReconnect) (WiFi.setAutoReconnect #f) #f)
                   (WiFi.disconnect)
                   (delay-ms 800)
                   (let ((again (net-scan-once)))
                     (if (defined? 'WiFi.setAutoReconnect) (WiFi.setAutoReconnect #t) #f)
                     again))
                 first))))
    (if (net-scan-failed? n)
        (begin (syslog "netscan: ~a (code ~a) -- this is NOT \"no networks\"\n"
                       (net-scan-code-text n) n)
               n)
        (begin
          (syslog "netscan: ~a network(s) heard by this board\n" n)
          (let lp ((i 0))
            (if (>= i n)
                n
                (begin (syslog "netscan:   ~a dBm  ~a\n" (WiFi.RSSI i) (WiFi.SSID i))
                       (lp (+ i 1)))))))))

;;; (net-why) -> #t if joined, else #f.  THE DIAGNOSTIC: it does the cross-reference itself.
;;;
;;; "Configured for X" and "X is not in range" are each half an answer, and a human holding both
;;; halves still has to notice they contradict.  This says which of the three cases it is, in one
;;; line: not configured at all, configured for an access point nobody can hear, or configured for
;;; one that IS in range -- which narrows it to the credential or the association itself and is the
;;; only case where reaching for the password is the right next move.
(define (net-why)
  (let ((want (setting 'wifi_ssid "")))
    (if (net-connected?)
        (begin (syslog "netwhy: JOINED ~a at ~a dBm, address ~a\n"
                       (WiFi.SSID) (WiFi.RSSI) (WiFi.localIP))
               #t)
        (let ((n (net-scan)))
          (let lp ((i 0) (found #f))
            (cond
             ;; The error code is checked FIRST and on its own.  Folding it into the search would
             ;; make a failed scan indistinguishable from a successful one that matched nothing --
             ;; the two call for opposite actions (fix the radio / move the board), so they must
             ;; never share an answer.
             ((net-scan-failed? n)
              (syslog "netwhy: NOT JOINED and the scan did not run (~a) -- nothing can be concluded about whether ~a is in range\n"
                      (net-scan-code-text n) want)
              #f)
             ((< i n) (lp (+ i 1) (or found (and (equal? (WiFi.SSID i) want)
                                                 (WiFi.RSSI i)))))
             ((string=? want "")
              (syslog "netwhy: NOT JOINED and no wifi_ssid is configured\n") #f)
             ;; HEARING AN ACCESS POINT IS NOT THE SAME AS BEING ABLE TO JOIN IT.  A scan
             ;; succeeds at signal levels an association cannot survive: the scan needs one beacon
             ;; to arrive intact, the association needs a sustained bidirectional exchange, and the
             ;; board's transmit path has to carry the return leg -- which a scan never exercises.
             ;; So "it is in the scan list" must NOT be reported as "the signal is fine".
             ;;
             ;; This said exactly that, and said it about a -84 dBm reading -- pointing the reader
             ;; at the password while the actual finding sat in the number on the same line
             ;; (2026-09-25).  Below -80 dBm the honest answer is that the link is too weak, and
             ;; the next move is the antenna or the placement, not the credential.
             ((and found (< found -80))
              (syslog "netwhy: NOT JOINED -- ~a is audible at ~a dBm but that is TOO WEAK to associate; move the board or the access point, do not go looking at the password\n"
                      want found)
              #f)
             (found
              (syslog "netwhy: NOT JOINED -- ~a IS in range at ~a dBm, strong enough to associate, so the fault is the credential or the association rather than the signal\n"
                      want found)
              #f)
             (else
              (syslog "netwhy: NOT JOINED -- ~a is NOT among the ~a network(s) this board can hear\n"
                      want n)
              #f)))))))

;;; (net-radio) -> #t if the radio answers as working hardware.
;;;
;;; SEPARATE "THE RADIO IS BROKEN" FROM "THE RADIO CANNOT REACH ANYTHING".  Those two produce the
;;; same visible result -- a board with no address -- and they call for completely different next
;;; moves: one is a bench fault, the other is a placement or credential problem.  Measured
;;; 2026-09-25 on this panel: two different access points both failed to associate and every scan
;;; returned -2, which is the pattern that means the question has stopped being about the network.
;;;
;;; The MAC is the useful probe because it is read from eFuse through the same driver stack that a
;;; scan uses, but needs no air time and cannot fail for any reason to do with reception.  A radio
;;; that reports its own address and still cannot scan is initialised and deaf; one that cannot
;;; even do that never came up, and nothing about access points is worth investigating until it
;;; does.  The IDF driver's own logging is compiled out in this build, so this is the substitute
;;; for the `wifi:` lines that would otherwise say which it is.
(define (net-radio)
  (let* ((mac  (guard (e (#t #f)) (WiFi.macAddress)))
         (mode (guard (e (#t #f)) (if (defined? 'WiFi.mode) (WiFi.mode net-wifi-mode-sta) 'absent)))
         (ok   (and (string? mac) (> (string-length mac) 0)
                    (not (string=? mac "00:00:00:00:00:00")))))
    (syslog "netradio: mac=~a set-sta=~a status=~a -- ~a\n"
            (if mac mac "<call raised>") mode (net-status-code)
            (if ok "radio answers" "RADIO DID NOT COME UP"))
    ok))

;;; (net-rejoin) -> #t if it associated, else #f.  Drive the radio by hand, without a reflash.
;;;
;;; WHY THIS EXISTS.  The boot path associates once, waits ten seconds and moves on -- correctly,
;;; because a board with no network is still a board and halting there would turn a degraded node
;;; into a dead one.  But it leaves no way to try AGAIN except a reset, and on a board reached only
;;; over serial a reset is how you lose whatever state you were trying to inspect.  This retries in
;;; place, so "does it join at all" and "does it join from HERE" become separate questions.
;;;
;;; THE MODE IS SET EXPLICITLY.  A station that has been idled for a scan, or left in whatever mode
;;; a previous experiment wanted, does not necessarily come back as a station -- and `WiFi.begin`
;;; on a radio in the wrong mode fails in a way that looks exactly like a bad password.
;;;
;;; BOUNDED, AND THE FALLTHROUGH IS REPORTED.  An unbounded wait whose condition cannot occur is
;;; indistinguishable from one that is still working.  Fifteen seconds is half again the boot
;;; path's ten, because the case this is reached for is the one where ten was not enough.
(define net-wifi-mode-sta 1)

(define (net-rejoin)
  (let ((want (setting 'wifi_ssid "")))
    (if (string=? want "")
        (begin (syslog "netrejoin: no wifi_ssid is configured -- nothing to join\n") #f)
        (begin
          (WiFi.disconnect)
          (delay-ms 300)
          (if (defined? 'WiFi.mode) (WiFi.mode net-wifi-mode-sta) #f)
          ;; The credential is read from the settings and never logged: this procedure prints the
          ;; SSID, the signal and the verdict, which is everything a diagnosis needs and nothing
          ;; that would put a password into a transcript someone later pastes into a report.
          (WiFi.begin want (setting 'wifi_pass ""))
          (let lp ((n 150))
            (cond
             ((net-connected?)
              (syslog "netrejoin: JOINED ~a after ~a ms at ~a dBm, address ~a\n"
                      want (* 100 (- 150 n)) (WiFi.RSSI) (WiFi.localIP))
              #t)
             ((<= n 0)
              (syslog "netrejoin: did NOT join ~a within 15000 ms -- status ~a\n"
                      want (net-status-code))
              #f)
             (else (delay-ms 100) (lp (- n 1)))))))))

;;; (net-selftest) -> #t if every arm behaves.  RESIDENT, AND THAT IS THE POINT TWICE OVER.
;;;
;;; First: a predicate that has only ever been watched AGREEING has not been tested.  `net-scan`'s
;;; first version was read, looked right, and reported an access point broadcasting at full
;;; strength as out of range, because -2 compares below every index.  What would have caught it is
;;; feeding it the value that should make it say the other thing -- so that feeding is written down
;;; here rather than left to whoever remembers.
;;;
;;; Second: the only console a disconnected board has ECHOES every character typed at it, and a
;;; sentinel the harness waits for is satisfied by the echo of its own source text before anything
;;; is evaluated.  A two-arm check typed as an expression therefore returns kilobytes of
;;; partial-line echo and no verdict -- observed twice on 2026-09-25.  A short call to a resident
;;; definition has a short echo, which is what makes the answer readable at all.
;;;
;;; The verdict names BOTH arms whichever way it goes: "ok" alone cannot be told from a check that
;;; did not run.
(define (net-selftest)
  (let* ((neg  (net-scan-failed? -2))          ;; must be true  -- an error code
         (neg1 (net-scan-failed? -1))          ;; must be true  -- still running
         (pos  (net-scan-failed? 3))           ;; must be false -- a real count
         (zero (net-scan-failed? 0))           ;; must be false -- genuinely no networks
         (ok   (and neg neg1 (not pos) (not zero))))
    (syslog "netselftest: -2=~a -1=~a 3=~a 0=~a  expected #t #t #f #f -- ~a\n"
            neg neg1 pos zero (if ok "PASS" "FAIL"))
    ok))

(syslog "netscan loaded\n")

