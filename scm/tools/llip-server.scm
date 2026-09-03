; Copyright 2026 by Frobenius Norm LLC 2026-04-12 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
; llip-server.scm -- LambLisp Interaction Protocol server

#|!
@file llip-server.scm
@brief LLIP server -- serves filesystem operations to authenticated remote LambLisp clients.

## Overview

LLIP (LambLisp Interaction Protocol) is a simple line-oriented S-expression protocol that lets
a host machine (running llip-client.scm) read, write, and manage files on a LambLisp target
board (ESP32, Jetson, or any POSIX host) over a TCP or TLS connection.

## Wire protocol

Each message is one S-expression per line, written with `write` and read with `read`.

Session flow:

    Server -> Client:  (hello "llip/1.0")
    Client -> Server:  (auth "secret-token")
    Server -> Client:  (ok)                          ; auth accepted; or server closes on failure

    Client -> Server:  <request>
    Server -> Client:  (ok <value> ...)  or  (error "message")
    ...
    Client -> Server:  (bye)
    Server -> Client:  (ok)                          ; then server closes the connection

## Supported operations

    (ping)                            -> (ok)
    (bye)                             -> (ok)   then close
    (ls "/path")                      -> (ok ("file1" "file2" ...))
    (stat "/path")                    -> (ok <size-bytes>)
    (read "/path")                    -> (ok "<full-file-content>")
    (read "/path" <offset> <n>)       -> (ok "<n-byte-chunk>")
    (write "/path" "<content>")       -> (ok)
    (append "/path" "<content>")      -> (ok)
    (delete "/path")                  -> (ok)
    (rename "/from" "/to")            -> (ok)
    (load "/path")                    -> (ok <last-eval-result>)
    (eval <expr>)                     -> (ok "<write-repr>")   or  (error "msg")

## Path safety

All paths must be absolute (start with `/`), must not contain `..`, and must not contain NUL bytes.
Requests that fail the safety check receive `(error "bad path")`.

## Usage

    (load "llip-server.scm" 1)

    ;; TLS server (production):
    (define srv (llip-make-server 8443 my-cert-pem my-key-pem "secret-token"))

    ;; Plain TCP server (development / LAN only):
    (define srv (llip-make-tcp-server 8080 "secret-token"))

    ;; Call from the main loop -- handles at most one connection per call:
    (llip-server-poll srv)

@see llip-client.scm
@see ll_tests/llip-tests.scm
|#

;;; ---------------------------------------------------------------------------
;;; Path sanitizer
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_server_path Path sanitizers
@brief Internal helpers that validate remote file paths before any I/O.

llip-safe-path? rejects paths that: are not strings, are empty, do not start with `/`,
contain `..` (directory traversal), or contain a NUL byte.
|#

(define (llip-has-nul? s)
  ;; Returns #t if string s contains a NUL byte (integer->char 0).
  ;; Cannot use a string literal "\x00" -- the reader null-terminates it.
  (let ((nul (integer->char 0))
        (n   (string-length s)))
    (let loop ((i 0))
      (cond ((= i n) #f)
            ((char=? (string-ref s i) nul) #t)
            (else (loop (+ i 1)))))))

(define (llip-safe-path? p)
  (and (string? p)
       (> (string-length p) 0)
       (char=? (string-ref p 0) #\/)
       (not (llip-string-contains p ".."))
       (not (llip-has-nul? p))))

(define (llip-string-contains str sub)
  ;; Returns #t if str contains sub as a substring.
  (let ((slen (string-length str))
        (sublen (string-length sub)))
    (if (> sublen slen)
      #f
      (let loop ((i 0))
        (cond ((> (+ i sublen) slen) #f)
              ((string=? (substring str i (+ i sublen)) sub) #t)
              (else (loop (+ i 1))))))))

;;; ---------------------------------------------------------------------------
;;; Response helpers
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_server_io Wire I/O helpers
@brief Low-level send/receive and response-formatting helpers used by the dispatcher.

- llip-send: write one S-expression followed by a newline to `port`.
- llip-recv: read one S-expression from `port` (blocks until available or EOF).
- llip-ok:   send `(ok val ...)` -- zero or more values in the payload.
- llip-err:  send `(error msg)`.
|#

(define (llip-send port obj)
  (write obj port)
  (newline port))

(define (llip-recv port)
  (read port))

(define (llip-ok port . vals)
  (llip-send port (cons 'ok vals)))

(define (llip-err port msg)
  (llip-send port (list 'error msg)))

;;; ---------------------------------------------------------------------------
;;; File I/O helpers (read/write entire file as string)
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_server_fileio File I/O helpers
@brief Read and write entire files (or chunks) as Scheme strings.

These helpers are used internally by the dispatcher to implement the `read`, `write`,
`append`, and chunked-read operations.  On embedded targets the file content is
transferred as a Scheme string literal, so binary files containing NUL bytes
may be truncated; use chunked reads for large files to stay within heap limits.

- llip-read-file-string path     -- read entire file, return string.
- llip-write-file-string path s  -- overwrite file with string s.
- llip-append-file-string path s -- append string s to file (read-rewrite, no O_APPEND).
- llip-read-file-chunk path off n -- read up to n chars starting at byte offset off.
|#

(define (llip-read-file-string path)
  ;; Read entire file into a string.
  (let* ((p   (open-input-file path))
         (out (open-output-string)))
    (let loop ()
      (let ((c (read-char p)))
        (if (eof-object? c)
          (begin (close-port p) (get-output-string out))
          (begin (write-char c out) (loop)))))))

(define (llip-write-file-string path content)
  ;; Overwrite file with string content.
  (let ((p (open-output-file path)))
    (write-string content p)
    (close-port p)))

(define (llip-append-file-string path content)
  ;; Append string content to file (open in append mode via "a").
  ;; R7RS has no open-append-file, so read+rewrite.
  (let* ((existing (if (file-exists? path) (llip-read-file-string path) ""))
         (p (open-output-file path)))
    (write-string existing p)
    (write-string content p)
    (close-port p)))

(define (llip-read-file-chunk path offset n)
  ;; Read up to n bytes starting at offset.
  (let* ((p   (open-input-file path))
         (out (open-output-string)))
    (let skip ((i 0))
      (when (< i offset)
        (let ((c (read-char p)))
          (unless (eof-object? c) (skip (+ i 1))))))
    (let loop ((i 0))
      (when (< i n)
        (let ((c (read-char p)))
          (unless (eof-object? c)
            (write-char c out)
            (loop (+ i 1))))))
    (close-port p)
    (get-output-string out)))

;;; ---------------------------------------------------------------------------
;;; Dispatcher -- handles one authenticated request, returns #f on (bye)
;;; ---------------------------------------------------------------------------

#|!
@brief Dispatch one LLIP request that has already been authenticated.
@param conn  An open bidirectional port connected to the client.
@param req   The S-expression read from the wire (must be a pair whose car is the op symbol).
@return #t to continue the session loop; #f to signal that the session should close.

Recognized operations are: ping, bye, ls, stat, read, write, append, delete, rename, load, eval.
Any unrecognized op sends `(error "unknown op")` and returns #t (keep session alive).
|#

(define (llip-dispatch conn req)
  (if (not (pair? req))
    (begin (llip-err conn "bad request") #t)
    (let ((op   (car req))
          (args (cdr req)))
      (cond

        ((eq? op 'ping)
         (llip-ok conn)
         #t)

        ((eq? op 'bye)
         (llip-ok conn)
         #f)  ; signal close

        ((eq? op 'ls)
         (let ((path (if (pair? args) (car args) "/")))
           (if (not (llip-safe-path? path))
             (llip-err conn "bad path")
             (llip-ok conn (directory-list path))))
         #t)

        ((eq? op 'stat)
         (let ((path (and (pair? args) (car args))))
           (if (not (llip-safe-path? path))
             (llip-err conn "bad path")
             (if (not (file-exists? path))
               (llip-err conn "not found")
               (llip-ok conn (file-size path)))))
         #t)

        ((eq? op 'read)
         (let ((path (and (pair? args) (car args))))
           (if (not (llip-safe-path? path))
             (llip-err conn "bad path")
             (if (not (file-exists? path))
               (llip-err conn "not found")
               (if (and (pair? (cdr args)) (pair? (cddr args)))
                 ;; chunked: (read path offset n)
                 (llip-ok conn (llip-read-file-chunk path (cadr args) (caddr args)))
                 ;; full: (read path)
                 (llip-ok conn (llip-read-file-string path))))))
         #t)

        ((eq? op 'write)
         (let ((path    (and (pair? args) (car args)))
               (content (and (pair? args) (pair? (cdr args)) (cadr args))))
           (if (or (not (llip-safe-path? path)) (not (string? content)))
             (llip-err conn "bad args")
             (begin
               (llip-write-file-string path content)
               (llip-ok conn))))
         #t)

        ((eq? op 'append)
         (let ((path    (and (pair? args) (car args)))
               (content (and (pair? args) (pair? (cdr args)) (cadr args))))
           (if (or (not (llip-safe-path? path)) (not (string? content)))
             (llip-err conn "bad args")
             (begin
               (llip-append-file-string path content)
               (llip-ok conn))))
         #t)

        ((eq? op 'delete)
         (let ((path (and (pair? args) (car args))))
           (if (not (llip-safe-path? path))
             (llip-err conn "bad path")
             (if (not (file-exists? path))
               (llip-err conn "not found")
               (begin (delete-file path) (llip-ok conn)))))
         #t)

        ((eq? op 'rename)
         (let ((from (and (pair? args) (car args)))
               (to   (and (pair? args) (pair? (cdr args)) (cadr args))))
           (if (or (not (llip-safe-path? from)) (not (llip-safe-path? to)))
             (llip-err conn "bad path")
             (begin (rename-file from to) (llip-ok conn))))
         #t)

        ((eq? op 'load)
         ;; Read and eval expressions from the file, return the last result.
         ;; Cannot use (load path) directly -- LambLisp's C++ load always returns ().
         (let ((path (and (pair? args) (car args))))
           (if (not (llip-safe-path? path))
             (llip-err conn "bad path")
             (if (not (file-exists? path))
               (llip-err conn "not found")
               (guard (exn (#t (llip-err conn
                                 (if (error-object? exn)
                                   (error-object-message exn)
                                   "load error"))))
                 (let* ((p      (open-input-file path))
                        (result (let loop ((last (if #f #f)))
                                  (let ((expr (read p)))
                                    (if (eof-object? expr)
                                      (begin (close-port p) last)
                                      (loop (eval expr (interaction-environment))))))))
                   (llip-ok conn result))))))
         #t)

        ((eq? op 'eval)
         ;; Evaluate an arbitrary S-expression in the interaction environment.
         ;; Returns (ok <value>) on success, (error "msg") on exception.
         ;; The result is sent as a Scheme datum (like the load op), not as a string.
         (if (not (pair? args))
           (llip-err conn "missing expression")
           (let ((expr (car args)))
             (guard (exn (#t (llip-err conn
                               (if (error-object? exn)
                                 (error-object-message exn)
                                 "eval error"))))
               (llip-ok conn (eval expr (interaction-environment))))))
         #t)

        (else
         (llip-err conn "unknown op")
         #t)))))

;;; ---------------------------------------------------------------------------
;;; Session handler
;;; ---------------------------------------------------------------------------

#|!
@brief Run a complete LLIP session on an already-accepted connection.
@param conn   An open bidirectional port for one accepted client connection.
@param token  The shared secret string that the client must supply in its `(auth ...)` message.

Sends the `(hello "llip/1.0")` banner, reads and checks the auth message, then loops
reading requests and calling llip-dispatch until #f is returned (bye or EOF).
Returns after the session ends; the caller is responsible for closing `conn`.
|#

(define (llip-handle-session conn token)
  ;; Handshake
  (llip-send conn '(hello "llip/1.0"))
  (let ((auth-msg (llip-recv conn)))
    (if (or (not (pair? auth-msg))
            (not (eq? (car auth-msg) 'auth))
            (not (pair? (cdr auth-msg)))
            (not (string=? (cadr auth-msg) token)))
      ;; Auth failed -- send nothing, just close
      #f
      ;; Auth OK
      (begin
        (llip-ok conn)
        (let loop ()
          (let ((req (llip-recv conn)))
            (if (eof-object? req)
              #f
              (when (llip-dispatch conn req)
                (loop)))))))))

;;; ---------------------------------------------------------------------------
;;; Server object and poll function
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_server_public Public server API
@brief Create an LLIP server and poll it from the main loop.

### llip-make-server port-num cert-pem key-pem token
Create a TLS LLIP server.  Returns an opaque server descriptor `(server-port token)`.
`cert-pem` and `key-pem` are PEM-encoded certificate and private key strings.
Available only when `LL_WIFI` is defined (ESP32).

### llip-make-tcp-server port-num token
Create a plain TCP LLIP server (development / LAN use only -- no encryption).
Returns an opaque server descriptor `(server-port token)`.

### llip-server-poll srv
Non-blocking poll.  Call once per main-loop iteration.
If an incoming connection is waiting it is accepted, the full LLIP session runs
to completion (blocking), and the connection is closed before returning.
At most one connection is handled per call.  Returns unspecified.
|#

(define (llip-make-server port-num cert-pem key-pem token)
  ;; Returns a server descriptor list: (server-port token)
  (list (open-tls-server-port port-num cert-pem key-pem) token))

(define (llip-make-tcp-server port-num token)
  ;; Plain TCP -- for development/LAN use only.
  (list (open-tcp-server-port port-num) token))

(define (llip-server-poll srv)
  ;; Non-blocking poll.  Call from main loop.
  ;; Handles at most one connection per call (session runs to completion).
  ;; Catches all exceptions so a bad client cannot kill the poll loop.
  (let ((server-port (car srv))
        (token       (cadr srv)))
    (let ((conn (server-accept server-port)))
      (when conn
        (guard (exn (#t #f))
          (llip-handle-session conn token))
        (close-port conn)))))

; end of llip-server.scm
