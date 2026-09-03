;;; network-tests.scm -- TCP and TLS tests for LambLisp, against a LOCAL deterministic peer.
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-29 20:40:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Usage: echo '(load "ll_tests/network-tests.scm" 0)' | ./program
;;; Run the peer FIRST, on a host the board can reach:
;;;     ./w3 nettest serve
;;;
;;; TWO THINGS ABOUT THIS FILE ARE DELIBERATE AND EASY TO "HELPFULLY" UNDO.
;;;
;;; 1. IT TALKS TO OUR OWN SERVER, NOT THE INTERNET.  The previous version dialled
;;;    example.com:80 and :443.  That makes DNS latency, captive portals and somebody else's
;;;    certificate rotation into LambLisp test failures, and the byte-exact assertions this
;;;    suite wants are impossible against a page we do not control.  w3_ai_scripts/net_test_server.py
;;;    answers with fixed bytes, so a FAIL here means LambLisp is broken and nothing else.
;;;
;;; 2. NOTHING IS SKIPPED.  The previous version called net-skip on every failure path --
;;;    "connection failed -- no WiFi?" counted as neither pass nor fail, so a board with no
;;;    network reported a clean run having tested nothing.  That is the exact shape of B42 and
;;;    the subsystem 0/0 bug: a green result that measured nothing.  Registry policy is explicit
;;;    (never skip a test, never mark it expected-to-fail).  So a missing precondition is a hard
;;;    FAIL here, with a message naming the fix.  If that turns a run red, the run WAS red.

(define net-pass 0)
(define net-fail 0)

(define (net-check name expected actual)
  (if (equal? expected actual)
      (begin (display "PASS ") (display name) (newline)
             (set! net-pass (+ net-pass 1)))
      (begin (display "FAIL ") (display name)
             (display " expected=") (write expected)
             (display " got=") (write actual) (newline)
             (set! net-fail (+ net-fail 1)))))

(define (net-check-true name actual) (net-check name #t (if actual #t #f)))

;;; A precondition that is not met is a FAILURE, not a skip -- see note 2 above.
(define (net-require name ok hint)
  (if ok
      (begin (display "PASS ") (display name) (newline)
             (set! net-pass (+ net-pass 1)) #t)
      (begin (display "FAIL ") (display name) (display "  ") (display hint) (newline)
             (set! net-fail (+ net-fail 1)) #f)))

;;; NOT-BUILT is the ONE outcome that counts as neither pass nor fail, and it is deliberately
;;; narrow: it applies ONLY to "this procedure does not exist in this build", never to a
;;; connection that failed.  The rule the old file broke was counting a DOWN NETWORK as a
;;; non-result, so a board that reached nothing reported a clean run.  Refusing to test TLS on a
;;; build that has no TLS client is a different thing entirely -- there is no code to exercise.
;;; It prints on its own NOCAP line so it can never be misread as a pass, and the harness's
;;; "Total: N pass, M fail" is unaffected because nothing was proved either way.
(define (net-nocap name reason)
  (display "NOCAP ") (display name) (display " -- ") (display reason) (newline))

(define (net-bound? sym)
  (not (eq? #f (dict-ref? (interaction-environment) sym))))

(define (net-throws? thunk24)
  (let ((threw #f)) (guard (e (#t (set! threw #t))) (thunk24)) threw))

;;; ─────────────────────────────────────────────────────────────────────────
;;; Peer configuration.  Defaults match net_test_server.py; override any of them in
;;; Settings-local.scm (untracked -- it is also where the WiFi credentials live).
;;; ─────────────────────────────────────────────────────────────────────────
(define net-host      (setting 'net_test_host      "10.42.0.1"))
(define net-tcp-port  (setting 'net_test_tcp_port  15080))
(define net-http-port (setting 'net_test_http_port 15081))
(define net-tls-port  (setting 'net_test_tls_port  15082))
(define net-ca-file   (setting 'net_test_ca        "net-test-ca.pem"))

(define (slurp path)
  (if (file-exists? path)
      (let ((p (open-input-file path)))
        (let loop ((acc '()))
          (let ((c (read-char p)))
            (if (eof-object? c)
                (begin (close-input-port p) (list->string (reverse acc)))
                (loop (cons c acc))))))
      #f))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 1. Preconditions.  Each is a real check with a real verdict.
;;; ─────────────────────────────────────────────────────────────────────────
(display "--- preconditions ---") (newline)

(define have-tcp
  (net-require "net/tcp-proc-bound" (net-bound? 'open-tcp-client-port)
    "open-tcp-client-port is not bound -- this build lacks LL_WIFI/LL_POSIX networking"))

(define have-tls
  (if (net-bound? 'open-tls-client-port)
      (net-require "net/tls-proc-bound" #t "")
      (begin (net-nocap "net/tls-*"
               "open-tls-client-port is not bound: TLS lives behind LL_WIFI, so host builds have no TLS client at all (P164 proposes adding it). Nothing to test, so this is not counted either way.")
             #f)))

;; On ESP32 the radio must be associated; on a host the stack is always there.  WiFi.isConnected
;; is bound only where there is a radio, so its absence means "host, nothing to associate".
(define net-up
  (if (net-bound? 'WiFi.isConnected)
      (net-require "net/wifi-associated" (WiFi.isConnected)
        "WiFi is not connected -- set (wifi . 1) with wifi_ssid/wifi_pass in Settings-local.scm (see Settings-local.scm.example)")
      #t))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 2. TCP against the line-echo port.  PING -> PONG, everything else verbatim.
;;; ─────────────────────────────────────────────────────────────────────────
(display "--- tcp echo ---") (newline)

(if (not (and have-tcp net-up))
    (net-require "net/tcp-echo" #f "prerequisites failed -- see above")
    (let ((p (open-tcp-client-port net-host net-tcp-port)))
      (if (not (net-require "net/tcp-connect" (input-port? p)
                 (string-append "cannot reach the test peer at " net-host
                                " -- is `./w3 nettest serve` running, and reachable from this board?")))
          #f
          (begin
            (net-check-true "net/tcp-input-port?"  (input-port?  p))
            (net-check-true "net/tcp-output-port?" (output-port? p))
            (net-check-true "net/tcp-open?"        (input-port-open? p))

            (write-string "PING\n" p)
            (net-check "net/tcp-ping" "PONG" (read-line p))

            ;; Exercise the B169/B173 pair over a REAL socket rather than a string port.
            ;; POLL, do not test once: the echo is a network round trip, so an immediate
            ;; (u8-ready? p) legitimately answers #f because nothing has arrived YET -- that is
            ;; the correct answer, not a defect, and asserting #t on the first call tests the
            ;; loopback latency instead of the predicate.  Polling until ready is precisely what
            ;; u8-ready? is for; the bound turns a hang into a readable failure.
            (write-string "Z\n" p)
            (net-check-true "net/tcp-u8-ready"
              (let loop ((n 0))
                (cond ((u8-ready? p) #t)
                      ((> n 20000)   #f)          ;; bounded: never wedge the suite
                      (else (loop (+ n 1))))))
            (net-check      "net/tcp-read-u8"   90 (read-u8 p))     ;; #\Z
            (net-check      "net/tcp-read-rest" "" (read-line p))

            (write-string "verbatim-line\n" p)
            (net-check "net/tcp-echo-verbatim" "verbatim-line" (read-line p))

            (close-port p)
            (net-check "net/tcp-closed" #f (input-port-open? p))))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 3. Plain HTTP -- byte-exact body, which is only possible against our own server.
;;; ─────────────────────────────────────────────────────────────────────────
(display "--- http ---") (newline)

(define (http-get-body port-num)
  (let ((p (open-tcp-client-port net-host port-num)))
    (if (not (input-port? p))
        #f
        (begin
          (write-string "GET /hello HTTP/1.0\r\nHost: lamblisp\r\nConnection: close\r\n\r\n" p)
          (let loop ((line (read-line p)))            ;; consume headers to the blank line
            (if (or (eof-object? line) (string=? line "") (string=? line "\r"))
                (let ((body (read-line p)))
                  (close-port p)
                  body)
                (loop (read-line p))))))))

(if (not (and have-tcp net-up))
    (net-require "net/http" #f "prerequisites failed -- see above")
    (net-check "net/http-hello" "hello-lamblisp" (http-get-body net-http-port)))

;;; ─────────────────────────────────────────────────────────────────────────
;;; 4. TLS.  B168: a CA is now mandatory unless 'insecure-skip-verify is passed explicitly.
;;;    B170: the peer certificate's validity window is checked, and that check FAILS CLOSED
;;;    on an unset clock -- an ESP32 boots at the epoch, so the board must set its time first.
;;; ─────────────────────────────────────────────────────────────────────────
(display "--- tls ---") (newline)

(define net-ca (slurp net-ca-file))

(if (not (and have-tls net-up))
    (if have-tls
        (net-require "net/tls" #f "prerequisites failed -- see above")
        #f)                             ;; no TLS in this build: already reported NOCAP
    (begin
      ;; B168 regression: no CA and no explicit opt-out must be REFUSED, not silently insecure.
      (net-check-true "net/tls-no-ca-refused"
        (net-throws? (lambda () (open-tls-client-port net-host net-tls-port))))

      (if (not (net-require "net/tls-ca-present" (string? net-ca)
                 (string-append "CA file " net-ca-file " is not on this filesystem -- copy "
                                "w3_ai_exch/net_test_certs/ca.pem onto the device as that name")))
          #f
          (let ((p (open-tls-client-port net-host net-tls-port net-ca)))
            (if (not (net-require "net/tls-connect" (input-port? p)
                       "TLS connect failed -- peer down, CA mismatch, or the board clock is unset (B170 fails closed below 2020-01-01)"))
                #f
                (begin
                  (net-check-true "net/tls-input-port?"  (input-port?  p))
                  (net-check-true "net/tls-output-port?" (output-port? p))
                  (write-string "GET /hello HTTP/1.0\r\nHost: lamblisp\r\nConnection: close\r\n\r\n" p)
                  (let loop ((line (read-line p)))
                    (if (or (eof-object? line) (string=? line "") (string=? line "\r"))
                        (net-check "net/tls-hello" "hello-lamblisp" (read-line p))
                        (loop (read-line p))))
                  (close-port p)
                  (net-check "net/tls-closed" #f (input-port-open? p))))))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; Summary -- the two lines the harness reads.
;;; ─────────────────────────────────────────────────────────────────────────
(display "Total: ") (display net-pass) (display " pass, ")
(display net-fail) (display " fail") (newline)
(display "--- network done ---") (newline)
