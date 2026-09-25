;;; Copyright 2026 by Frobenius Norm LLC 2026-09-14
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; nettime.scm -- SNTP client (RFC 4330) over UDP.  B402.
;;;
;;; WHY THIS EXISTS.  B170 made TLS check the peer certificate's validity window in our own code,
;;; because the prebuilt Arduino mbedTLS has CONFIG_MBEDTLS_HAVE_TIME_DATE unset and therefore
;;; accepts EXPIRED certificates.  That check fails closed below 2020-01-01, and an ESP32 has no
;;; battery-backed RTC -- so without a time source `net/tls-connect` can never pass.  This is the
;;; time source.
;;;
;;; THIS IS SNTP, NOT NTP, AND THE DIFFERENCE IS NOT PEDANTRY.  RFC 4330 is the single-shot
;;; subset: one request, one reply, use the answer.  It does NOT discipline the clock, keep a
;;; frequency estimate, filter across polls, or reject a falseticker by voting.  For "get the
;;; clock above 2020 so certificates can be checked" that is exactly right.  For anything where
;;; the time itself is the measurement, it is not.
;;;
;;; An earlier draft of this file used RFC 868 over TCP/37 because LambLisp had no UDP primitive.
;;; It now has one (B404: open-udp-port / udp-send / udp-recv), so this is the real protocol.

(syslog "nettime loading\n")

;;; THE NAVY SERVERS.  tick and tock are the US Naval Observatory's public NTP service; USNO is
;;; the DoD time standard and one of the two realisations of UTC in the US (UTC(USNO), alongside
;;; UTC(NIST)).  Addresses are literals because this build has no resolver primitive exposed to
;;; Scheme -- `udp-send` takes whatever string it is handed, and on the ESP32 that string goes to
;;; the lwIP resolver, but a literal removes DNS as a failure mode on a bench with no DNS.
;;;
;;; NIST is listed third ON PURPOSE: it is a different operator, a different clock ensemble and a
;;; different network path, so a fault that takes out both USNO addresses at once -- a route, a
;;; firewall rule, a decommissioning -- does not take the capability with it.
(define nettime-servers
  (list (cons "tick.usno.navy.mil" "192.5.41.40")     ;; USNO master clock 1
        (cons "tock.usno.navy.mil" "192.5.41.41")     ;; USNO master clock 2
        (cons "time.nist.gov"      "132.163.96.1")))  ;; fallback: different operator

(define nettime-ntp-port 123)
(define nettime-timeout-ms 3000)

;;; Seconds between 1900-01-01 and 1970-01-01: 70 years with 17 leap days, (70*365 + 17) * 86400.
(define nettime-epoch-offset 2208988800)

;;; B170's floor as a Unix timestamp (2020-01-01T00:00:00Z).  A reply below this is not "an early
;;; clock", it is a BAD READ -- a truncated datagram, a server answering something that is not
;;; NTP, or a spoof.  Refusing it here keeps a wrong time from being installed as though it were
;;; deliberate, which is worse than having no time at all.
(define nettime-floor 1577836800)

;;; An NTP packet is exactly 48 bytes.  A reply of any other length is not NTP.
(define nettime-packet-len 48)

;;; The client request: LI=0 (no warning), VN=4, Mode=3 (client) -> 0x23 in byte 0, rest zero.
;;; A server ignores every other field in a client request, so zeros are correct and also make
;;; the request carry no information about us.
(define (nettime-request)
  (let ((b (make-bytevector nettime-packet-len 0)))
    (bytevector-u8-set! b 0 #x23)
    b))

;;; Big-endian 32-bit read at offset k.
(define (nettime-be32 bv k)
  (+ (* (bytevector-u8-ref bv k)       16777216)
     (* (bytevector-u8-ref bv (+ k 1))    65536)
     (* (bytevector-u8-ref bv (+ k 2))      256)
     (bytevector-u8-ref bv (+ k 3))))

;;; VALIDATE THE REPLY BEFORE TRUSTING IT.  UDP is connectionless: anything on the network can
;;; send us 48 bytes, and `udp-recv` will hand them over.  These are the cheap checks that RFC
;;; 4330 sec.5 calls for and that cost nothing:
;;;   * length is exactly 48
;;;   * mode is 4 (server) -- a reply, not someone else's request reflected at us
;;;   * stratum is 1..15 -- 0 is a "kiss-o'-death" or unsynchronised, 16+ is unusable
;;;   * transmit timestamp is non-zero -- a zero means the server never set its clock
;;; Returns the transmit timestamp's seconds field, or #f.
(define (nettime-parse reply)
  (if (or (not (bytevector? reply))
          (not (= (bytevector-length reply) nettime-packet-len)))
      #f
      (let* ((li-vn-mode (bytevector-u8-ref reply 0))
             (mode       (modulo li-vn-mode 8))
             (stratum    (bytevector-u8-ref reply 1))
             (xmit-sec   (nettime-be32 reply 40)))   ;; transmit timestamp, seconds since 1900
        (cond ((not (= mode 4))                      #f)   ;; not a server reply
              ((or (= stratum 0) (> stratum 15))     #f)   ;; kiss-o'-death or unsynchronised
              ((= xmit-sec 0)                        #f)   ;; server clock unset
              (else xmit-sec)))))

;;; Query ONE server.  Returns Unix seconds, or #f.
(define (nettime-fetch-from addr)
  (let ((sock (open-udp-port)))
    (if (not (port? sock))
        #f
        (let ((sent (udp-send sock addr nettime-ntp-port (nettime-request))))
          (if (not sent)
              (begin (close-port sock) #f)
              (let* ((reply (udp-recv sock nettime-packet-len nettime-timeout-ms))
                     (xmit  (nettime-parse reply)))
                (close-port sock)
                (if (not xmit)
                    #f
                    (let ((unix (- xmit nettime-epoch-offset)))
                      (if (< unix nettime-floor) #f unix)))))))))

;;; Try each server in turn; first plausible answer wins.  Returns Unix seconds or #f.
;;; Logs WHICH server answered: provenance cannot be reconstructed from a timestamp afterwards,
;;; and "which clock did this board believe" is the first question asked when a cert check argues
;;; with a log line.
(define (nettime-fetch)
  (let loop ((rest nettime-servers))
    (if (null? rest)
        (begin (syslog "nettime: no server answered\n") #f)
        (let* ((entry (car rest))
               (name  (car entry))
               (t     (nettime-fetch-from (cdr entry))))
          (if t
              (begin (syslog "nettime: ") (syslog name) (syslog " -> ")
                     (syslog (number->string t)) (syslog "\n")
                     t)
              (loop (cdr rest)))))))

;;; ------------------------------------------------------------------------------------------
;;; Install the fetched time.  `set-system-time!` is the C++ half (B402); until it exists this
;;; reports what it would have done rather than silently appearing to work.
;;; The capability test uses `(defined? 'sym)`, the C++ primitive -- NOT `net-bound?`, which looks
;;; like the natural choice but is defined at network-tests.scm:56 and exists only while that
;;; suite is loaded.  A feature file calling it would work under test and fail at boot.
(define (nettime-sync!)
  (let ((t (nettime-fetch)))
    (cond ((not t)
           (syslog "nettime-sync!: no time obtained; clock unchanged\n")
           #f)
          ((not (defined? 'set-system-time!))
           (syslog "nettime-sync!: got ") (syslog (number->string t))
           (syslog " but set-system-time! is unbound -- see B402; clock unchanged\n")
           t)
          (else
           (set-system-time! t)
           (syslog "nettime-sync!: clock set\n")
           t))))

(syslog "nettime loaded\n")

;;; ============================================================================================
;;; POLICY LAYER -- P227.  Owner decisions 2026-09-19: X=3600, default-on gated by wifi,
;;; server list from settings.  Everything below is policy over the primitives above; it adds
;;; no capability and changes none of them.
;;; ============================================================================================

;;; THE SERVER LIST COMES FROM SETTINGS, FISHER FIRST.  A board on the bench LAN should not leave
;;; the building for time it can get in one hop, and putting the local server first makes the
;;; AIR-GAPPED case the default-correct one instead of a special case someone has to remember.
;;; The public servers stay as the off-bench fallback, so a customer device with no local server
;;; still works.  Absent setting -> the built-in list above, so no existing board changes
;;; behaviour silently on upgrade.
;;;
;;; KEEP IT A LIST.  A single configurable host would quietly delete the different-operator
;;; redundancy the built-in list has on purpose (see THE NAVY SERVERS above) -- one firewall rule
;;; would then take the capability out entirely.
(define nettime-policy-servers
  (let ((s (setting 'ntp_servers #f)))
    (cond ((and (pair? s) (pair? (car s))) s)          ;; ((name . addr) ...)
          ((pair? s) (map (lambda (a) (cons a a)) s))  ;; ("addr" ...)
          (else nettime-servers))))

;;; X = 3600 s (owner).  A setting, not a constant: an ESP32 crystal drifts tens of ppm, so an
;;; hour costs well under a second -- but that is an ESTIMATE, and the delta logged on each sync
;;; is what would let someone MEASURE it and change this on evidence.
(define nettime-period-s (setting 'ntp_period_s 3600))

;;; ------------------------------------------------------------------------------------------
;;; OBSERVE, NEVER ESTABLISH.  This predicate must not associate, DHCP, or retry -- it asks
;;; whether a link ALREADY exists and returns.
;;;
;;; THIS IS THE SAFETY PROPERTY OF THE WHOLE FEATURE, NOT A PREFERENCE.  [B434] measured the C5's
;;; worst-case pause at ~1020 us and traced it to the RADIO, not the collector; [B396]/[B60]
;;; record association starving internal DRAM.  A clock that silently brought WiFi up would
;;; therefore change the latency profile of a hard-real-time runtime and the memory picture every
;;; bench number rests on -- and do it INVISIBLY, because the only outward sign is a correct
;;; clock.  If you ever need a device that dials for time, that is a separate decision with a
;;; latency cost attached; do not let it arrive as a side effect of this.
(define (nettime-link-up?)
  (and (defined? 'WiFi.status)
       (= (WiFi.status) 3)))          ;; wl_status_t WL_CONNECTED; see gc-pause-bench.scm:117

;;; State.  `had-link` drives the transition edge; `next-due` carries the backoff.
(define nettime-last-sync 0)
(define nettime-had-link #f)
(define nettime-fails 0)
(define nettime-next-due 0)

;;; ------------------------------------------------------------------------------------------
;;; One tick.  Cheap and side-effect-free unless it actually syncs, so it is safe to call often.
;;;
;;; RUN IT FROM THE IDLE HOOK, NOT THE MUTATOR.  A sync is a network round trip with a 3 s
;;; timeout; performed inside a timed `cons` it would be recorded as a GC pause exactly as [B215]
;;; records heap expansion being, and misattributed the same way.
;;;
;;; SYNCS ON THE TRANSITION AS WELL AS ON THE PERIOD.  A board can sit for hours with no link and
;;; then acquire one; waiting out a full X after that would leave a known-wrong clock in place for
;;; no reason.
(define (nettime-tick!)
  (let ((link (nettime-link-up?))
        (now  (if (defined? 'current-second) (exact (floor (current-second))) 0)))
    (cond
     ((not link)
      (set! nettime-had-link #f)
      #f)
     ((or (not nettime-had-link)                    ;; no-link -> link edge
          (and (>= now nettime-next-due)
               (>= (- now nettime-last-sync) nettime-period-s)))
      (set! nettime-had-link #t)
      (let ((before now)
            (t (let ((saved nettime-servers))
                 (set! nettime-servers nettime-policy-servers)
                 (let ((r (nettime-fetch))) (set! nettime-servers saved) r))))
        (cond
         ((and t (> t nettime-floor) (defined? 'set-system-time!))
          (set-system-time! t)
          (set! nettime-last-sync t)
          (set! nettime-fails 0)
          (set! nettime-next-due 0)
          ;;; LOG BOTH VALUES AND THE DELTA.  A silent success is indistinguishable from a task
          ;;; that never ran -- the failure this tree keeps re-finding -- and the delta is the
          ;;; only thing that makes drift measurable, hence the only thing that could justify
          ;;; changing nettime-period-s on evidence rather than by taste.
          (syslog "nettime: clock ") (syslog (number->string before))
          (syslog " -> ") (syslog (number->string t))
          (syslog " (delta ") (syslog (number->string (- t before))) (syslog " s)\n")
          t)
         (else
          ;;; BACK OFF, DO NOT HAMMER.  These are other people's servers when off-bench, and a
          ;;; board with no route would otherwise send three datagrams every tick forever.
          (set! nettime-fails (+ nettime-fails 1))
          (set! nettime-next-due (+ now (min nettime-period-s
                                             (* 60 (expt 2 (min nettime-fails 6))))))
          (syslog "nettime: sync failed (") (syslog (number->string nettime-fails))
          (syslog " consecutive); next try in ")
          (syslog (number->string (- nettime-next-due now))) (syslog " s\n")
          #f))))
     (else (set! nettime-had-link #t) #f))))

(syslog "nettime policy loaded (P227)\n")
