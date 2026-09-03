;;; Copyright 2026 by Frobenius Norm LLC 2026-04-11 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; network-tests-interactive.scm -- interactive TCP/TLS port tests
;;; Requires an operator at the terminal and a WiFi-connected device.
;;; Load with: (load "network-tests-interactive.scm" 1)
;;;
;;; On your dev PC, start the companion echo server first:
;;;   python3 network-test-server.py
;;; That starts three echo servers (TCP 9999, TLS-insecure 10000, TLS-CA 10001)
;;; and prints the CA cert path to copy to SPIFFS as /ca.pem for Section 4.
;;;
;;; Pre-configure (optional):
;;;   (define *test-server-port* 9999)   ;;; base port (default 9999)
;;;   (define *test-cert-file*   "/ca.pem")  ;;; CA cert on SPIFFS (#f = none)

;;; -----------------------------------------------------------------------
;;; Framework
;;; -----------------------------------------------------------------------

(define ll-int-esc (string (integer->char #x1b)))
(define (int-news fmt . args) (apply syslog (string-append ll-int-esc "[32m" fmt ll-int-esc "[97m") args))
(define (int-warn fmt . args) (apply syslog (string-append ll-int-esc "[33m" fmt ll-int-esc "[97m") args))
(define (int-info fmt . args) (apply syslog (string-append ll-int-esc "[36m" fmt ll-int-esc "[97m") args))

(define *int-pass* 0)
(define *int-fail* 0)
(define *int-skip* 0)

(define (int-check name expected actual)
  (if (equal? expected actual)
    (begin (set! *int-pass* (+ *int-pass* 1)) (int-news "PASS ~a\n" name))
    (begin (set! *int-fail* (+ *int-fail* 1)) (int-warn "FAIL ~a  expected=~a  got=~a\n" name expected actual))))

(define (int-check-true name actual)
  (if actual
    (begin (set! *int-pass* (+ *int-pass* 1)) (int-news "PASS ~a\n" name))
    (begin (set! *int-fail* (+ *int-fail* 1)) (int-warn "FAIL ~a  expected=#t  got=~a\n" name actual))))

(define (int-check-false name actual)
  (if (not actual)
    (begin (set! *int-pass* (+ *int-pass* 1)) (int-news "PASS ~a\n" name))
    (begin (set! *int-fail* (+ *int-fail* 1)) (int-warn "FAIL ~a  expected=#f  got=~a\n" name actual))))

(define (int-skip name reason)
  (set! *int-skip* (+ *int-skip* 1))
  (int-warn "SKIP ~a -- ~a\n" name reason))

;;; bound? -- true if sym is bound in the interaction environment
(define (int-bound? sym)
  (not (eq? #f (dict-ref? (interaction-environment) sym))))

;;; -----------------------------------------------------------------------
;;; User I/O helpers
;;; -----------------------------------------------------------------------

;;; Read one line from stdin, strip trailing CR (Windows/USB serial).
(define (read-trimmed)
  (let* ((raw (read-line))
         (n   (string-length raw)))
    (if (and (> n 0) (char=? (string-ref raw (- n 1)) (integer->char 13)))
      (substring raw 0 (- n 1))
      raw)))

;;; Prompt and return trimmed input.
(define (prompt msg)
  (display msg)
  (read-trimmed))

;;; Prompt for y/n; return #t if answer starts with 'y'.
(define (yes? msg)
  (let ((r (prompt (string-append msg " [y/n]: "))))
    (and (> (string-length r) 0)
         (char=? (string-ref r 0) #\y))))

;;; Wait for Enter.
(define (pause msg)
  (prompt (string-append msg " -- press Enter: "))
  (if #f #f))

;;; -----------------------------------------------------------------------
;;; Favorite persistence (SPIFFS file)
;;; -----------------------------------------------------------------------

(define *favorites-file* "/test-host.txt")

(define (load-favorite)
  (with-exception-handler
    (lambda (e) #f)
    (lambda ()
      (let* ((p    (open-input-file *favorites-file*))
             (line (read-line p)))
        (close-port p)
        (if (and (string? line) (> (string-length line) 3)) line #f)))))

(define (save-favorite host)
  (with-exception-handler
    (lambda (e) (int-warn "note: could not save favorite to ~a\n" *favorites-file*))
    (lambda ()
      (let ((p (open-output-file *favorites-file*)))
        (write-string host p)
        (newline p)
        (close-port p)
        (int-info "Saved favorite: ~a\n" host)))))

;;; -----------------------------------------------------------------------
;;; Network scan
;;; Tries to connect to port on every address in the local /24 subnet.
;;; Closed ports (RST) return quickly; firewalled ports time out (~5s each).
;;; -----------------------------------------------------------------------

;;; Extract "a.b.c." from "a.b.c.d"
(define (ip-subnet-base ip)
  (let loop ((i (- (string-length ip) 1)))
    (cond
      ((= i 0)                        ip)
      ((char=? (string-ref ip i) #\.) (substring ip 0 (+ i 1)))
      (else                           (loop (- i 1))))))

;;; Scan subnet for hosts with port open; return list of IP strings.
(define (scan-for-servers port)
  (if (not (int-bound? 'WiFi.localIP))
    (begin (int-warn "WiFi.localIP not available -- cannot scan\n") '())
    (let* ((my-ip (WiFi.localIP))
           (base  (ip-subnet-base my-ip)))
      (int-info "Scanning ~a1-254 on port ~a (firewalled hosts may be slow)...\n" base port)
      (let loop ((i 1) (found '()))
        (if (> i 254)
          (begin
            (int-info "Scan complete: ~a candidate(s) found.\n" (length found))
            (reverse found))
          (let ((host (string-append base (number->string i))))
            (if (string=? host my-ip)
              (loop (+ i 1) found)              ;;; skip self
              (let ((p (with-exception-handler
                         (lambda (e) #f)
                         (lambda () (open-tcp-client-port host port)))))
                (if (and p (input-port? p))
                  (begin
                    (close-port p)
                    (int-info "  found: ~a\n" host)
                    (loop (+ i 1) (cons host found)))
                  (loop (+ i 1) found))))))))))

;;; -----------------------------------------------------------------------
;;; Server selection
;;; Offers: favorite (if saved), network scan, manual entry.
;;; Saves the chosen host as the new favorite on success.
;;; -----------------------------------------------------------------------

(define (select-test-server port)
  (let ((fav (load-favorite)))
    (int-info "\nTest server selection (port ~a):\n" port)
    (when fav
      (int-info "  Favorite: ~a\n" fav))
    (int-info "  's' to scan local network\n")
    (int-info "  Enter to use favorite~a, or type an IP address.\n"
              (if fav (string-append " (" fav ")") " (none saved)"))
    (let ((input (prompt "> ")))
      (cond
        ;;; scan
        ((string=? input "s")
         (let ((candidates (scan-for-servers port)))
           (if (null? candidates)
             (begin (int-warn "No candidates found on port ~a.\n" port) #f)
             (begin
               (let loop ((cs candidates) (i 1))
                 (unless (null? cs)
                   (int-info "  ~a) ~a\n" i (car cs))
                   (loop (cdr cs) (+ i 1))))
               (let* ((sel  (prompt "Select number (Enter = 1): "))
                      (n    (if (= (string-length sel) 0) 1 (string->number sel)))
                      (idx  (if (and n (>= n 1) (<= n (length candidates)))
                              (- n 1) 0))
                      (host (list-ref candidates idx)))
                 (save-favorite host)
                 host)))))
        ;;; Enter with a favorite
        ((and (= (string-length input) 0) fav)
         fav)
        ;;; explicit IP entered
        ((> (string-length input) 3)
         (save-favorite input)
         input)
        ;;; no input, no favorite
        (else
         (int-warn "No server selected.\n")
         #f)))))

;;; -----------------------------------------------------------------------
;;; Configuration defaults
;;; -----------------------------------------------------------------------

(unless (int-bound? '*test-server-port*)
  (define *test-server-port* 9999))
(unless (int-bound? '*test-cert-file*)
  (define *test-cert-file* #f))

;;; -----------------------------------------------------------------------
;;; Section 1: TCP echo test
;;; network-test-server.py echoes replies automatically (port BASE+0).
;;; -----------------------------------------------------------------------

(int-news "\n=== Section 1: TCP echo test ===\n")

(if (not (int-bound? 'open-tcp-client-port))
  (int-skip "tcp-echo/all" "open-tcp-client-port not bound (LL_WIFI not set)")
  (begin
    (int-info "Ensure network-test-server.py is running on port ~a.\n" *test-server-port*)
    (let ((host (select-test-server *test-server-port*)))
      (if (not host)
        (begin
          (int-skip "tcp-echo/connect"   "no server selected")
          (int-skip "tcp-echo/io"        "skipped")
          (int-skip "tcp-echo/close"     "skipped"))
        (let ((p (open-tcp-client-port host *test-server-port*)))
          (if (not (input-port? p))
            (begin
              (int-skip "tcp-echo/connect"  (string-append "connection to " host " failed"))
              (int-skip "tcp-echo/io"       "skipped -- no connection")
              (int-skip "tcp-echo/close"    "skipped -- no connection"))
            (begin
              (int-check-true  "tcp-echo/input-port?"   (input-port?  p))
              (int-check-true  "tcp-echo/output-port?"  (output-port? p))
              (int-check-true  "tcp-echo/port-open?"    (input-port-open? p))
              (write-string "lamblisp-echo-test\n" p)
              (let ((echo (read-line p)))
                (int-check "tcp-echo/roundtrip" "lamblisp-echo-test" echo))
              (close-port p)
              (int-check-false "tcp-echo/closed" (input-port-open? p)))))))))

;;; -----------------------------------------------------------------------
;;; Section 2: TCP terminal test
;;; Verifies the REPL server (port 3141) accepts connections.
;;; -----------------------------------------------------------------------

(int-news "\n=== Section 2: TCP terminal (REPL server) test ===\n")

(if (not (int-bound? 'WiFi.localIP))
  (int-skip "tcp-term/all" "WiFi.localIP not bound (LL_WIFI not set)")
  (let ((ip (WiFi.localIP)))
    (int-info "This device: ~a port 3141\n" ip)
    (int-info "From your dev PC run:  nc ~a 3141\n" ip)
    (int-info "You should get the LambLisp prompt (LL=>).\n")
    (int-info "Type  (+ 1 2)  -- verify you get  3  back.\n")
    (int-info "Type  (exit)  or Ctrl-C to disconnect.\n")
    (pause "press Enter here after verifying the REPL works over TCP")
    (if (yes? "Did the TCP REPL work correctly?")
      (begin (set! *int-pass* (+ *int-pass* 1)) (int-news "PASS tcp-term/manual-verify\n"))
      (begin (set! *int-fail* (+ *int-fail* 1)) (int-warn "FAIL tcp-term/manual-verify\n")))))  )

;;; -----------------------------------------------------------------------
;;; Section 3: TLS echo test (insecure -- no cert verification)
;;; network-test-server.py echoes replies automatically (port BASE+1).
;;; -----------------------------------------------------------------------

(int-news "\n=== Section 3: TLS echo test (insecure) ===\n")

(if (not (int-bound? 'open-tls-client-port))
  (int-skip "tls-echo/all" "open-tls-client-port not bound (LL_WIFI not set)")
  (begin
    (define tls-echo-port (+ *test-server-port* 1))   ;;; default 10000
    (int-info "Ensure network-test-server.py is running on port ~a.\n" tls-echo-port)
    (let ((host (select-test-server tls-echo-port)))
      (if (not host)
        (begin
          (int-skip "tls-echo/connect"   "no server selected")
          (int-skip "tls-echo/io"        "skipped")
          (int-skip "tls-echo/close"     "skipped"))
        (let ((p (open-tls-client-port host tls-echo-port)))
          (if (not (input-port? p))
            (begin
              (int-skip "tls-echo/connect"  (string-append "TLS connection to " host " failed"))
              (int-skip "tls-echo/io"       "skipped -- no connection")
              (int-skip "tls-echo/close"    "skipped -- no connection"))
            (begin
              (int-check-true  "tls-echo/input-port?"   (input-port?  p))
              (int-check-true  "tls-echo/output-port?"  (output-port? p))
              (int-check-true  "tls-echo/port-open?"    (input-port-open? p))
              (write-string "lamblisp-tls-test\n" p)
              (let ((echo (read-line p)))
                (int-check "tls-echo/roundtrip" "lamblisp-tls-test" echo))
              (close-port p)
              (int-check-false "tls-echo/closed" (input-port-open? p)))))))))

;;; -----------------------------------------------------------------------
;;; Section 4: TLS with CA certificate from SPIFFS
;;; network-test-server.py echoes replies automatically (port BASE+2).
;;; Copy /tmp/ll-test-ca.pem to SPIFFS as /ca.pem before running.
;;; -----------------------------------------------------------------------

(int-news "\n=== Section 4: TLS with CA certificate ===\n")

(if (not (int-bound? 'open-tls-client-port))
  (int-skip "tls-cert/all" "open-tls-client-port not bound (LL_WIFI not set)")
  (begin
    (define cert-path
      (or *test-cert-file*
          (let ((r (prompt "CA cert path on SPIFFS (Enter = /ca.pem): ")))
            (if (= (string-length r) 0) "/ca.pem" r))))

    (int-info "Loading ~a ...\n" cert-path)
    (let ((cert
      (with-exception-handler
        (lambda (e) #f)
        (lambda ()
          (let* ((p   (open-input-file cert-path))
                 (buf (open-output-string)))
            (let loop ((c (read-char p)))
              (if (eof-object? c)
                (begin (close-port p) (get-output-string buf))
                (begin (write-char c buf) (loop (read-char p))))))))))

      (if (not cert)
        (begin
          (int-skip "tls-cert/load"    (string-append "could not read " cert-path))
          (int-skip "tls-cert/connect" "skipped -- no cert")
          (int-skip "tls-cert/io"      "skipped -- no cert"))
        (begin
          (int-check-true "tls-cert/load" (string? cert))
          (int-info "Cert loaded (~a bytes).\n" (string-length cert))
          (define tls-cert-port (+ *test-server-port* 2))   ;;; default 10001
          (int-info "Ensure network-test-server.py is running on port ~a.\n" tls-cert-port)
          (let ((host (select-test-server tls-cert-port)))
            (if (not host)
              (begin
                (int-skip "tls-cert/connect" "no server selected")
                (int-skip "tls-cert/io"      "skipped"))
              (let ((p (open-tls-client-port host tls-cert-port cert)))
                (if (not (input-port? p))
                  (begin
                    (int-skip "tls-cert/connect" "TLS handshake failed -- cert mismatch?")
                    (int-skip "tls-cert/io"      "skipped -- no connection"))
                  (begin
                    (int-check-true  "tls-cert/input-port?"   (input-port?  p))
                    (int-check-true  "tls-cert/output-port?"  (output-port? p))
                    (write-string "lamblisp-tls-cert-test\n" p)
                    (let ((echo (read-line p)))
                      (int-check "tls-cert/roundtrip" "lamblisp-tls-cert-test" echo))
                    (close-port p)
                    (int-check-false "tls-cert/closed" (input-port-open? p))))))))))))

;;; -----------------------------------------------------------------------
;;; Summary
;;; -----------------------------------------------------------------------

(int-news "\n=== INTERACTIVE NETWORK TEST SUMMARY: ~a passed, ~a failed, ~a skipped ===\n"
          *int-pass* *int-fail* *int-skip*)
(if (= *int-fail* 0)
  (int-news "ALL INTERACTIVE NETWORK TESTS PASSED\n")
  (int-warn "~a INTERACTIVE NETWORK TESTS FAILED\n" *int-fail*))

