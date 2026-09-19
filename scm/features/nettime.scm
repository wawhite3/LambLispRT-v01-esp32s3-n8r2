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
