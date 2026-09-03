; Copyright 2026 by Frobenius Norm LLC 2026-04-12 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
; llip-tests.scm -- integration tests for LambLisp Interaction Protocol
;
; These tests require two LambLisp instances on the same network:
;   - SERVER: running llip-server.scm with known cert/key/token
;   - CLIENT: this file, loaded on the other instance
;
; Configure these before loading:
;   (define llip-test-host  "192.168.1.42")
;   (define llip-test-port  8443)
;   (define llip-test-token "secret-token")
;   (define llip-test-cert  #f)   ; or ca-cert PEM string for verification
;
; For plain TCP testing (no TLS):
;   (define llip-test-tcp? #t)
;   (define llip-test-port 8080)
;
; For the devkit over WiFi:
;   (define llip-test-host  "172.16.0.2")
;   (define llip-test-port  8080)
;   (define llip-test-token "testtoken")
;   (define llip-test-tcp?  #t)
;
; Sections 12-20 require llip-client.scm to already be loaded.
;
; Then: (load "llip-tests.scm" 1)

;;; ---------------------------------------------------------------------------
;;; Test harness
;;; ---------------------------------------------------------------------------

(define llip-test-pass 0)
(define llip-test-fail 0)

(define (llip-test-reset!)
  (set! llip-test-pass 0)
  (set! llip-test-fail 0))

(define (llip-check label got expected)
  (if (equal? got expected)
    (begin
      (set! llip-test-pass (+ llip-test-pass 1))
      (display "  pass: ") (display label) (newline))
    (begin
      (set! llip-test-fail (+ llip-test-fail 1))
      (display "  FAIL: ") (display label) (newline)
      (display "    expected: ") (write expected) (newline)
      (display "    got:      ") (write got)      (newline))))

(define (llip-check-true label val)
  (llip-check label (if val #t #f) #t))

(define (llip-test-section name thunk17)
  (display "--- ") (display name) (newline)
  (thunk17))

;;; ---------------------------------------------------------------------------
;;; Configuration defaults (set before loading to override; preserved if already bound)
;;; ---------------------------------------------------------------------------

;;; Helper: return current value of sym if already bound, else fallback.
(define (llip-test-default sym fallback)
  (let ((b (dict-ref? (interaction-environment) sym)))
    (if b (cdr b) fallback)))

(define llip-test-host  (llip-test-default 'llip-test-host  "127.0.0.1"))
(define llip-test-port  (llip-test-default 'llip-test-port  8443))
(define llip-test-token (llip-test-default 'llip-test-token "llip-test-secret"))
(define llip-test-cert  (llip-test-default 'llip-test-cert  #f))
(define llip-test-tcp?  (llip-test-default 'llip-test-tcp?  #f))

;;; ---------------------------------------------------------------------------
;;; Helper: open a test connection
;;; ---------------------------------------------------------------------------

(define (llip-test-connect)
  (if llip-test-tcp?
    (llip-connect-tcp llip-test-host llip-test-port llip-test-token)
    (if llip-test-cert
      (llip-connect llip-test-host llip-test-port llip-test-token llip-test-cert)
      (llip-connect llip-test-host llip-test-port llip-test-token))))

;;; ---------------------------------------------------------------------------
;;; Section 1 -- connection and ping
;;; ---------------------------------------------------------------------------

(llip-test-section "1. connection and ping" (lambda ()
  (define c (llip-test-connect))
  (llip-check-true "connected" c)
  (llip-check-true "ping" (llip-ping c))
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 2 -- write and read back
;;; ---------------------------------------------------------------------------

(llip-test-section "2. write and read" (lambda ()
  (define c (llip-test-connect))
  (define path "/llip-test-wr.txt")
  (llip-check-true "write"      (llip-write c path "hello llip\n"))
  (llip-check      "read back"  (llip-read c path) "hello llip\n")
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 3 -- append
;;; ---------------------------------------------------------------------------

(llip-test-section "3. append" (lambda ()
  (define c (llip-test-connect))
  (define path "/llip-test-ap.txt")
  (llip-write  c path "line1\n")
  (llip-append c path "line2\n")
  (llip-check "appended" (llip-read c path) "line1\nline2\n")
  (llip-delete c path)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 4 -- stat (file-size)
;;; ---------------------------------------------------------------------------

(llip-test-section "4. stat" (lambda ()
  (define c (llip-test-connect))
  (define path "/llip-test-st.txt")
  (llip-write c path "0123456789")
  (llip-check "file size" (llip-stat c path) 10)
  (llip-delete c path)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 5 -- directory listing
;;; ---------------------------------------------------------------------------

(llip-test-section "5. directory-list" (lambda ()
  (define c (llip-test-connect))
  (llip-write c "/llip-ls-a.txt" "a")
  (llip-write c "/llip-ls-b.txt" "b")
  (define listing (llip-ls c "/"))
  ;; SPIFFS returns full paths ("/llip-ls-a.txt"); POSIX returns basenames ("llip-ls-a.txt")
  (define (ls-contains? lst name)
    (or (member name lst) (member (string-append "/" name) lst)))
  (llip-check-true "ls contains a" (ls-contains? listing "llip-ls-a.txt"))
  (llip-check-true "ls contains b" (ls-contains? listing "llip-ls-b.txt"))
  (llip-delete c "/llip-ls-a.txt")
  (llip-delete c "/llip-ls-b.txt")
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 6 -- delete
;;; ---------------------------------------------------------------------------

(llip-test-section "6. delete" (lambda ()
  (define c (llip-test-connect))
  (define path "/llip-test-del.txt")
  (llip-write c path "x")
  (llip-delete c path)
  ;; second read should produce a remote error -- catch it
  (define deleted?
    (guard (e (#t #t))
      (llip-read c path)
      #f))
  (llip-check "deleted" deleted? #t)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 7 -- rename
;;; ---------------------------------------------------------------------------

(llip-test-section "7. rename" (lambda ()
  (define c (llip-test-connect))
  (llip-write c "/llip-old.txt" "renamed")
  (llip-rename c "/llip-old.txt" "/llip-new.txt")
  (llip-check "renamed content" (llip-read c "/llip-new.txt") "renamed")
  (define old-gone?
    (guard (e (#t #t))
      (llip-read c "/llip-old.txt")
      #f))
  (llip-check "old gone" old-gone? #t)
  (llip-delete c "/llip-new.txt")
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 8 -- chunked read
;;; ---------------------------------------------------------------------------

(llip-test-section "8. chunked read" (lambda ()
  (define c (llip-test-connect))
  (define path "/llip-test-chunk.txt")
  (llip-write c path "abcdefghij")
  (llip-check "chunk 0-4" (llip-read-chunk c path 0 4) "abcd")
  (llip-check "chunk 4-4" (llip-read-chunk c path 4 4) "efgh")
  (llip-check "chunk 8-4" (llip-read-chunk c path 8 4) "ij")
  (llip-delete c path)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 9 -- remote load
;;; ---------------------------------------------------------------------------

(llip-test-section "9. remote load" (lambda ()
  (define c (llip-test-connect))
  (define path "/llip-test-load.scm")
  (llip-write c path "(+ 1 2)")
  (llip-check "load result" (llip-load c path) 3)
  (llip-delete c path)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 10 -- path safety (server must reject these)
;;; ---------------------------------------------------------------------------

(llip-test-section "10. path safety" (lambda ()
  (define c (llip-test-connect))
  (define (expect-error thunk18)
    (guard (e (#t #t)) (thunk18) #f))
  (llip-check "reject .." (expect-error (lambda () (llip-read c "/../etc/passwd"))) #t)
  (llip-check "reject no-slash" (expect-error (lambda () (llip-read c "relative"))) #t)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 11 -- upload / download helpers
;;; ---------------------------------------------------------------------------

(llip-test-section "11. upload/download" (lambda ()
  (define c (llip-test-connect))
  ;; Write a local temp file and upload it.
  (let ((local-src "/tmp/llip-up-src.txt")
        (remote    "/llip-upload-test.txt")
        (local-dst "/tmp/llip-up-dst.txt"))
    (let ((p (open-output-file local-src)))
      (write-string "upload-content-123" p)
      (close-port p))
    (llip-upload c local-src remote)
    (llip-download c remote local-dst)
    (let* ((p   (open-input-file local-dst))
           (out (open-output-string)))
      (let loop ()
        (let ((ch (read-char p)))
          (unless (eof-object? ch) (write-char ch out) (loop))))
      (close-port p)
      (llip-check "round-trip" (get-output-string out) "upload-content-123"))
    (llip-delete c remote))
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 12 -- remote eval (synchronous)
;;; ---------------------------------------------------------------------------

(llip-test-section "12. remote eval sync" (lambda ()
  (define c (llip-test-connect))
  ;; Define a helper on the server for use in sections 12-16.
  (llip-eval c '(define (llip-test-fib n) (if (< n 3) 1 (+ (llip-test-fib (- n 1)) (llip-test-fib (- n 2))))))
  (llip-check     "eval arith"        (llip-eval c '(+ 1 2))                   3)
  (llip-check     "eval fib(10)"      (llip-eval c '(llip-test-fib 10))       55)
  (llip-check     "eval string-append" (llip-eval c '(string-append "a" "b"))  "ab")
  (llip-check     "eval list"         (llip-eval c '(list 1 2 3))              '(1 2 3))
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 13 -- eval error propagation
;;; ---------------------------------------------------------------------------

(llip-test-section "13. eval error propagation" (lambda ()
  (define c (llip-test-connect))
  ;; Remote error must propagate as a local Scheme error.
  (define caught-boom?
    (guard (e (#t #t))
      (llip-eval c '(error "boom" "test"))
      #f))
  (llip-check-true "eval/error-propagated" caught-boom?)
  ;; Session must survive an eval error -- ping should still work.
  (llip-check-true "eval/session-survives" (llip-ping c))
  ;; eval of unbound symbol raises remotely.
  (define caught-unbound?
    (guard (e (#t #t))
      (llip-eval c '(this-symbol-does-not-exist-xyzzy))
      #f))
  (llip-check-true "eval/unbound-propagated" caught-unbound?)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 14 -- llip-make-remote
;;; ---------------------------------------------------------------------------

(llip-test-section "14. llip-make-remote" (lambda ()
  (define c (llip-test-connect))
  (define rfib (llip-make-remote c 'llip-test-fib))
  (llip-check "make-remote fib(10)" (rfib 10) 55)
  (llip-check "make-remote fib(12)" (rfib 12) 144)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 15 -- async eval (eval-send / eval-recv)
;;; ---------------------------------------------------------------------------

(llip-test-section "15. async eval" (lambda ()
  (define c (llip-test-connect))
  (llip-eval-send c '(llip-test-fib 15))
  (define result #f)
  (let loop ((tries 0))
    (set! result (llip-eval-recv c))
    (cond
      (result #t)
      ((> tries 100000) (display "  TIMEOUT async eval\n"))
      (else (loop (+ tries 1)))))
  (llip-check "async fib(15)" result 610)
  ;; Second async round-trip on same connection.
  (llip-eval-send c '(+ 10 20))
  (set! result #f)
  (let loop ((tries 0))
    (set! result (llip-eval-recv c))
    (cond
      (result #t)
      ((> tries 100000) (display "  TIMEOUT async eval 2\n"))
      (else (loop (+ tries 1)))))
  (llip-check "async 10+20" result 30)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 16 -- llip-make-remote-async
;;; ---------------------------------------------------------------------------

(llip-test-section "16. llip-make-remote-async" (lambda ()
  (define c (llip-test-connect))
  (define cb-result #f)
  (define fire-async
    (llip-make-remote-async c 'llip-test-fib
      (lambda (v) (set! cb-result v))))
  (fire-async 10)
  (let loop ((tries 0))
    (llip-poll-async c)
    (cond
      (cb-result #t)
      ((> tries 100000) (display "  TIMEOUT make-remote-async\n"))
      (else (loop (+ tries 1)))))
  (llip-check "make-remote-async fib(10)" cb-result 55)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 17 -- error paths (server-side errors)
;;; ---------------------------------------------------------------------------

(llip-test-section "17. error paths" (lambda ()
  (define c (llip-test-connect))
  (define (expect-error thunk19)
    (guard (e (#t #t)) (thunk19) #f))

  ;; read non-existent file
  (llip-check-true "err/read-missing"
    (expect-error (lambda () (llip-read c "/llip-no-such-file-xyzzy.txt"))))

  ;; stat non-existent file
  (llip-check-true "err/stat-missing"
    (expect-error (lambda () (llip-stat c "/llip-no-such-file-xyzzy.txt"))))

  ;; delete non-existent file
  (llip-check-true "err/delete-missing"
    (expect-error (lambda () (llip-delete c "/llip-no-such-file-xyzzy.txt"))))

  ;; rename non-existent source
  (llip-check-true "err/rename-missing"
    (expect-error (lambda () (llip-rename c "/llip-no-src-xyzzy.txt" "/llip-no-dst-xyzzy.txt"))))

  ;; bad path: relative (no leading /)
  (llip-check-true "err/bad-path-relative"
    (expect-error (lambda () (llip-read c "relative-path.txt"))))

  ;; bad path: directory traversal
  (llip-check-true "err/bad-path-dotdot"
    (expect-error (lambda () (llip-read c "/../etc/passwd"))))

  ;; unknown op: send raw, verify server replies (error ...) and keeps session alive
  (let ((port (llip-port c)))
    (llip-send-raw port '(frobnicate "arg"))
    (let ((resp (llip-recv-raw port)))
      (llip-check "err/unknown-op-tag" (and (pair? resp) (car resp)) 'error)))
  (llip-check-true "err/session-after-unknown-op" (llip-ping c))

  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Section 18 -- bad authentication (server closes without sending ok)
;;; ---------------------------------------------------------------------------

(llip-test-section "18. bad auth" (lambda ()
  (define p
    (if llip-test-tcp?
      (open-tcp-client-port llip-test-host llip-test-port)
      (open-tls-client-port llip-test-host llip-test-port)))
  (define hello (llip-recv-raw p))
  (llip-check-true "bad-auth/hello-received"
    (and (pair? hello) (eq? (car hello) 'hello)))
  (llip-send-raw p (list 'auth "DEFINITELY-WRONG-TOKEN"))
  ;; Server closes without sending (ok) -- read must return EOF
  (define resp (llip-recv-raw p))
  (llip-check-true "bad-auth/server-closes" (eof-object? resp))
  (close-port p)))

;;; ---------------------------------------------------------------------------
;;; Section 19 -- sequential connections (poll loop stability)
;;; ---------------------------------------------------------------------------

(llip-test-section "19. sequential connections" (lambda ()
  (define N 10)
  (define successes 0)
  (let loop ((i 0))
    (when (< i N)
      (guard (e (#t #f))
        (define c (llip-test-connect))
        (when (llip-ping c)
          (set! successes (+ successes 1)))
        (llip-disconnect c))
      (loop (+ i 1))))
  (llip-check "sequential/all-10-succeeded" successes N)))

;;; ---------------------------------------------------------------------------
;;; Section 20 -- large file round-trip and chunked read
;;; ---------------------------------------------------------------------------

(llip-test-section "20. large file" (lambda ()
  (define c (llip-test-connect))
  (define path "/llip-t-big.txt")
  ;; Build a 4096-char string: 256 repetitions of a 16-char pattern.
  (define chunk-16 "0123456789abcdef")
  (define big-string
    (let loop ((n 0) (acc ""))
      (if (= n 256)
        acc
        (loop (+ n 1) (string-append acc chunk-16)))))
  (llip-check "large/size" (string-length big-string) 4096)

  ;; Write and read back in full.
  (llip-write c path big-string)
  (llip-check "large/stat"      (llip-stat c path) 4096)
  (llip-check "large/read-full" (llip-read c path) big-string)

  ;; Chunked read: 8 chunks of 512 bytes each, reassemble and compare.
  (define reassembled
    (let loop ((off 0) (acc ""))
      (if (>= off 4096)
        acc
        (loop (+ off 512) (string-append acc (llip-read-chunk c path off 512))))))
  (llip-check "large/reassembled" reassembled big-string)

  (llip-delete c path)
  (llip-disconnect c)))

;;; ---------------------------------------------------------------------------
;;; Summary
;;; ---------------------------------------------------------------------------

(display "llip tests: ")
(display llip-test-pass) (display " pass, ")
(display llip-test-fail) (display " fail")
(newline)

; end of llip-tests.scm
