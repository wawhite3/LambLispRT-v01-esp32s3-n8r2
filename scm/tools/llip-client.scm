; Copyright 2026 by Frobenius Norm LLC 2026-04-12 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
; llip-client.scm -- LambLisp Interaction Protocol client

#|!
@file llip-client.scm
@brief LLIP client -- connect to a remote LambLisp board and manage its filesystem.

## Overview

LLIP (LambLisp Interaction Protocol) is a line-oriented S-expression protocol that runs
over a plain TCP or TLS connection.  This file provides the client half; the server half
lives in `llip-server.scm`.

## Connection object

A connection is an opaque list `(port)`.  All public API functions take a connection as
their first argument.  Create one with `llip-connect` or `llip-connect-tcp`, and
release it with `llip-disconnect`.

## Usage

    (load "llip-client.scm" 1)

    ;; TLS connection (production) -- no CA verification:
    (define c (llip-connect "192.168.1.42" 8443 "secret-token"))

    ;; TLS connection with CA certificate verification:
    (define c (llip-connect "192.168.1.42" 8443 "secret-token" ca-cert-pem))

    ;; Plain TCP (development / LAN only -- no encryption):
    (define c (llip-connect-tcp "192.168.1.42" 8080 "secret-token"))

    (llip-ping c)                              ; -> #t
    (llip-ls c "/")                            ; -> ("file1.scm" "setup.scm" ...)
    (llip-stat c "/setup.scm")                 ; -> <size-in-bytes>
    (llip-read c "/setup.scm")                 ; -> "<full file content>"
    (llip-read-chunk c "/setup.scm" 0 512)     ; -> "<first 512 bytes>"
    (llip-write c "/boot.scm" "(display 1)\n") ; -> #t  (overwrites)
    (llip-append c "/log.txt" "line\n")        ; -> #t
    (llip-delete c "/old.scm")                 ; -> #t
    (llip-rename c "/old.scm" "/new.scm")      ; -> #t
    (llip-load c "/init.scm")                  ; -> <last-eval-result>
    (llip-upload c "/local/src.scm" "/remote/dst.scm")   ; chunked upload
    (llip-download c "/remote/dst.scm" "/local/dst.scm") ; chunked download
    (llip-disconnect c)

## Error handling

Remote errors (`(error "msg")`) are raised as Scheme errors via `error`.
Use `guard` to catch them.

@see llip-server.scm
@see ll_tests/llip-tests.scm
|#

;;; ---------------------------------------------------------------------------
;;; Low-level send/receive
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_client_io Wire I/O primitives
@brief Internal send/receive helpers.

- llip-send-raw port obj  -- write obj as a `write`-formatted S-expression plus newline,
  then flush the port.  Used for all outgoing messages.
- llip-recv-raw port      -- read one S-expression with `read`.  Blocks until data arrives
  or the connection is closed (returns EOF object on close).
|#

(define (llip-send-raw port obj)
  (write obj port)
  (newline port)
  (flush-output-port port))

(define (llip-recv-raw port)
  (read port))

;;; ---------------------------------------------------------------------------
;;; Connection -- internal representation: (port)
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_client_connect Connection management
@brief Open and close LLIP connections to a remote LambLisp board.

### llip-connect host port-num token [ca-cert-pem]
Open a TLS connection to `host:port-num`, authenticate with `token`, and return a
connection object.  If the optional `ca-cert-pem` string is supplied the server
certificate is verified against it; omit for no verification (insecure).
Raises an error if the connection or authentication fails.
Available only when `LL_WIFI` is defined.

### llip-connect-tcp host port-num token
Open a plain TCP (unencrypted) connection.  Intended for development on a trusted LAN.
Available when `LL_WIFI` or `LL_POSIX` is defined.

### llip-disconnect conn
Send `(bye)`, drain the server acknowledgement, and close the port.
|#

(define (llip-connect host port-num token . rest)
  ;; rest = optional ca-cert-pem string
  ;; Connection object: (port pending-callback) -- pending-callback is #f when idle.
  (let* ((ca-cert (if (pair? rest) (car rest) #f))
         (p (if ca-cert
              (open-tls-client-port host port-num ca-cert)
              (open-tls-client-port host port-num))))
    (llip-do-handshake p token)
    (list p #f)))

(define (llip-connect-tcp host port-num token)
  ;; Plain TCP -- development/LAN use only.
  ;; Connection object: (port pending-callback) -- pending-callback is #f when idle.
  (let ((p (open-tcp-client-port host port-num)))
    (llip-do-handshake p token)
    (list p #f)))

(define (llip-do-handshake port token)
  ;; Read hello, send auth, check response.
  (let ((hello (llip-recv-raw port)))
    (if (or (not (pair? hello)) (not (eq? (car hello) 'hello)))
      (error "llip-connect: bad hello" hello)
      (begin
        (llip-send-raw port (list 'auth token))
        (let ((resp (llip-recv-raw port)))
          (if (or (not (pair? resp)) (not (eq? (car resp) 'ok)))
            (error "llip-connect: auth failed" resp)
            #t))))))

(define (llip-port conn) (car conn))

;;; ---------------------------------------------------------------------------
;;; Core RPC -- send a request, receive and check response
;;; ---------------------------------------------------------------------------

#|!
@brief Send one LLIP request and return the server response.
@param conn  Connection object returned by llip-connect or llip-connect-tcp.
@param req   A list whose car is the op symbol, e.g. `(list 'read "/foo.scm")`.
@return The full response S-expression, e.g. `(ok "content")`.
Raises a Scheme error if the response is malformed or if the server returns `(error ...)`.
|#

(define (llip-call conn req)
  (llip-send-raw (llip-port conn) req)
  (let ((resp (llip-recv-raw (llip-port conn))))
    (if (not (pair? resp))
      (error "llip: bad response" resp)
      (if (eq? (car resp) 'error)
        (error "llip remote error" (if (pair? (cdr resp)) (cadr resp) resp))
        resp))))

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_client_api Public client API
@brief High-level filesystem and eval operations over an LLIP connection.

All procedures take a connection `conn` as their first argument and raise a Scheme
error on remote failure (the server replied with `(error ...)`).

- llip-ping conn                -- send `(ping)`; returns `#t`.
- llip-ls   conn path           -- list directory `path`; returns a list of filename strings.
- llip-stat conn path           -- return file size in bytes as an integer.
- llip-read conn path           -- return full file content as a string.
- llip-read-chunk conn path off n -- return up to `n` characters starting at byte offset `off`.
- llip-write  conn path content -- overwrite remote file with `content` string; returns `#t`.
- llip-append conn path content -- append `content` to remote file; returns `#t`.
- llip-delete conn path         -- delete remote file; returns `#t`.
- llip-rename conn from to      -- rename remote file from `from` to `to`; returns `#t`.
- llip-load   conn path         -- load and eval remote file; returns the last expression value.

The server `(eval <expr>)` op evaluates an arbitrary S-expression in the server's interaction
environment and returns the result as a Scheme value.  See the `llip_client_eval` group below.
|#

(define (llip-ping conn)
  (llip-call conn '(ping))
  #t)

(define (llip-ls conn path)
  ;; Returns list of filename strings.
  (let ((resp (llip-call conn (list 'ls path))))
    (if (pair? (cdr resp)) (cadr resp) (list))))

(define (llip-stat conn path)
  ;; Returns file size in bytes.
  (let ((resp (llip-call conn (list 'stat path))))
    (if (pair? (cdr resp)) (cadr resp) 0)))

(define (llip-read conn path)
  ;; Returns full file content as string.
  (let ((resp (llip-call conn (list 'read path))))
    (if (pair? (cdr resp)) (cadr resp) "")))

(define (llip-read-chunk conn path offset n)
  ;; Returns up to n bytes from offset as string.
  (let ((resp (llip-call conn (list 'read path offset n))))
    (if (pair? (cdr resp)) (cadr resp) "")))

(define (llip-write conn path content)
  ;; Overwrite remote file with content string.
  (llip-call conn (list 'write path content))
  #t)

(define (llip-append conn path content)
  ;; Append content string to remote file.
  (llip-call conn (list 'append path content))
  #t)

(define (llip-delete conn path)
  ;; Delete remote file at path.  Raises an error if the file does not exist.
  (llip-call conn (list 'delete path))
  #t)

(define (llip-rename conn from to)
  ;; Rename remote file from `from` to `to`.  Both paths must be absolute.
  (llip-call conn (list 'rename from to))
  #t)

(define (llip-load conn path)
  ;; Load and eval a remote file; returns the last evaluated value.
  (let ((resp (llip-call conn (list 'load path))))
    (if (pair? (cdr resp)) (cadr resp) (list))))

(define (llip-disconnect conn)
  (llip-send-raw (llip-port conn) '(bye))
  (llip-recv-raw (llip-port conn))  ; drain (ok)
  (close-port (llip-port conn)))

;;; ---------------------------------------------------------------------------
;;; Remote eval
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_client_eval Remote eval
@brief Evaluate Scheme expressions on the remote server and retrieve the result.

Two modes are provided: synchronous (blocks until the result arrives) and
async (send now, poll in the main loop).

### Synchronous

#### llip-eval conn expr
Send `(eval expr)` to the server, block until the result arrives, return the
result as a Scheme value.  Raises a Scheme error on remote exception.

    (llip-eval c '(+ 1 2))          => 3
    (llip-eval c '(list 1 2))       => (1 2)
    (llip-eval c '(fib 30))         => 832040

#### llip-eval-read conn expr
Alias for `llip-eval`.  Kept for compatibility.

#### llip-make-remote conn proc-name
Return a local lambda that evaluates `(proc-name arg ...)` on the remote server.

    (define remote-fib (llip-make-remote c 'fib))
    (remote-fib 30)                  => 832040

### Async (non-blocking, for use in a control loop)

#### llip-eval-send conn expr
Send the eval request and return immediately.  Does NOT wait for the response.
Only one request may be in flight at a time.  The connection must be idle
(not in a pending `llip-make-remote-async` call).

    (llip-eval-send cuda-conn '(run-inference sensor-vec))

#### llip-eval-recv conn
Poll for the response without blocking.  Returns `#f` if no data has arrived yet,
or the Scheme result value when complete.  Raises a Scheme error if the remote eval threw.

    (define result (llip-eval-recv cuda-conn))  ; #f until ready

#### llip-eval-recv-read conn
Alias for `llip-eval-recv`.  Kept for compatibility.  Returns `#f` if not yet available.

#### llip-make-remote-async conn proc-name on-result
Return a lambda that sends `(proc-name arg ...)` asynchronously.
`on-result` is a one-argument callback invoked (from the poll loop) when
the response arrives.

    (define fire-inference
      (llip-make-remote-async cuda-conn 'run-inference
        (lambda (v) (apply-actuation v))))
    (fire-inference sensor-vec)     ; returns immediately
    ;; in loop: (llip-poll-async cuda-conn)
|#

;;; Synchronous eval

(define (llip-eval conn expr)
  ;; Evaluate expr on the remote server.  Returns the result as a Scheme value.
  (let ((resp (llip-call conn (list 'eval expr))))
    (if (pair? (cdr resp)) (cadr resp) (if #f #f))))  ; unspecified when no payload

(define (llip-eval-read conn expr)
  ;; Alias for llip-eval -- kept for compatibility.
  (llip-eval conn expr))

(define (llip-make-remote conn proc-name)
  ;; Return a local procedure forwarding calls to proc-name on the remote server.
  (lambda args
    (llip-eval conn (cons proc-name args))))

;;; Async eval -- connection state: (port pending-callback)
;;; pending-callback is #f when idle, a one-arg procedure when a reply is in flight.

(define (llip-async-conn? conn)
  ;; Returns #t if conn has a pending async request in flight.
  (and (pair? (cdr conn)) (procedure? (cadr conn))))

(define (llip-eval-send conn expr)
  ;; Send (eval expr) without waiting for the response.
  ;; conn must be idle (no pending request).  Returns unspecified.
  (when (llip-async-conn? conn)
    (error "llip-eval-send: request already in flight"))
  (llip-send-raw (llip-port conn) (list 'eval expr)))

(define (llip-eval-recv conn)
  ;; Non-blocking poll.  Returns #f if no data yet, or the Scheme result value when ready.
  ;; Raises on remote error.
  (if (not (char-ready? (llip-port conn)))
    #f
    (let ((resp (llip-recv-raw (llip-port conn))))
      (if (not (pair? resp))
        (error "llip: bad response" resp)
        (if (eq? (car resp) 'error)
          (error "llip remote error" (if (pair? (cdr resp)) (cadr resp) resp))
          (if (pair? (cdr resp)) (cadr resp) (if #f #f)))))))

(define (llip-eval-recv-read conn)
  ;; Alias for llip-eval-recv -- kept for compatibility.
  (llip-eval-recv conn))

(define (llip-make-remote-async conn proc-name on-result)
  ;; Return a procedure that sends (proc-name arg ...) asynchronously.
  ;; on-result is called with the result value when llip-poll-async delivers it.
  ;; Sets a pending callback on conn; call llip-poll-async from the main loop.
  (lambda args
    (when (llip-async-conn? conn)
      (error "llip-make-remote-async: request already in flight"))
    (set-car! (cdr conn) on-result)
    ;; Send directly -- do NOT call llip-eval-send here, as it would see the
    ;; callback we just set and raise "already in flight".
    (llip-send-raw (llip-port conn) (list 'eval (cons proc-name args)))))

(define (llip-poll-async conn)
  ;; Call once per loop iteration when a llip-make-remote-async request is in flight.
  ;; If the response has arrived, invokes the callback and clears the pending state.
  ;; Returns #t if a result was delivered, #f if still waiting.
  (when (llip-async-conn? conn)
    (let ((v (llip-eval-recv-read conn)))
      (when v
        (let ((cb (cadr conn)))
          (set-car! (cdr conn) #f)  ; clear pending
          (cb v)
          #t)))))

;;; ---------------------------------------------------------------------------
;;; Streaming copy helpers
;;; ---------------------------------------------------------------------------

#|!
@defgroup llip_client_streaming Streaming file transfer helpers
@brief Copy files between local and remote filesystems in fixed-size chunks.

`llip-chunk-size` (default 512) controls the transfer granularity.  Using chunks keeps
peak heap usage bounded on memory-constrained boards.

### llip-upload conn local-path remote-path
Read the local file at `local-path` in chunks of `llip-chunk-size` bytes and write them
to `remote-path` on the server, using `llip-write` for the first chunk and `llip-append`
for subsequent chunks.  The remote file is fully overwritten.

### llip-download conn remote-path local-path
Read the remote file at `remote-path` in chunks and write them to the local file at
`local-path`, overwriting it.  Returns after the remote file is fully transferred.

### llip-read-local-chunk path offset n
Read up to `n` characters from the local file starting at byte offset `offset`.
Returns a (possibly shorter) string.  Used internally by llip-upload.
|#

(define llip-chunk-size 512)

(define (llip-upload conn local-path remote-path)
  ;; Copy a local file to a remote path in chunks.
  (let loop ((off 0) (first? #t))
    (let ((chunk (llip-read-local-chunk local-path off llip-chunk-size)))
      (when (> (string-length chunk) 0)
        (if first?
          (llip-write conn remote-path chunk)
          (llip-append conn remote-path chunk))
        (when (= (string-length chunk) llip-chunk-size)
          (loop (+ off llip-chunk-size) #f))))))

(define (llip-download conn remote-path local-path)
  ;; Copy a remote file to a local path in chunks.
  (let ((out (open-output-file local-path)))
    (let loop ((off 0))
      (let ((chunk (llip-read-chunk conn remote-path off llip-chunk-size)))
        (when (> (string-length chunk) 0)
          (write-string chunk out)
          (when (= (string-length chunk) llip-chunk-size)
            (loop (+ off llip-chunk-size))))))
    (close-port out)))

(define (llip-read-local-chunk path offset n)
  ;; Read up to n bytes of a local file starting at offset.
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

; end of llip-client.scm
