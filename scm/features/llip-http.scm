;;; llip-http.scm — native LambLisp HTTP/1.0 client for the llama-server
;;; "external HTTP coprocessor" (WP-H of P123).
;;; Copyright 2026 by Frobenius Norm LLC 2026-06-24 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; The LL orchestrator calls llama-server IN-PROCESS via `open-tcp-client-port`
;;; (no subprocess, no Python — "only LL in the stack").  JSON exists ONLY here,
;;; as the thin envelope llama.cpp's /completion API requires; everything the
;;; orchestrator passes around is LLIP (S-expressions).  The "content" the LLM
;;; returns is itself a grammar-constrained LLIP move-program.
;;;
;;; Public:
;;;   (llip-http-post-json host port path body-json) -> response-body-string | #f
;;;   (llip-llm-complete prompt grammar [host [port]]) -> move-program-string | #f

;;; \r CONTAINMENT (CR is a DOS-ism to avoid — but HTTP/RFC-7230 mandates CRLF on the
;;; wire, and llama.cpp's server emits CRLF in its response).  read-line strips only \n,
;;; so we chomp the server's trailing \r RIGHT HERE at the read boundary; no \r ever
;;; propagates into the header/body logic below.
;;; (string-ref / string-length are byte-indexed — correct here: HTTP headers are ASCII.)
(define (llip-http--read-line-nocr port)
  (let ((line (read-line port)))
    (if (eof-object? line)
        line
        (let ((n (string-length line)))
          (if (and (> n 0) (= (char->integer (string-ref line (- n 1))) 13))   ;;;!< 13 = CR
              (substring line 0 (- n 1))
              line)))))

;;; Skip response headers (a blank line ends them — \r already chomped), then read the
;;; body to EOF (server sent Connection: close).  #f if the terminator was never seen.
(define (llip-http--read-response port)
  (let skip-headers ()
    (let ((line (llip-http--read-line-nocr port)))
      (cond
        ((eof-object? line) #f)                        ;;;!< EOF before blank line
        ((= (string-length line) 0)                    ;;;!< blank line = end of headers
         (let read-body ((acc ""))
           (let ((chunk (read-string 4096 port)))
             (if (eof-object? chunk)
                 acc
                 (read-body (string-append acc chunk))))))
        (else (skip-headers))))))

;;; POST a JSON body and return the response body string (or #f on connect failure).
;;; HTTP/1.0 + Connection: close → a simple, unchunked, read-to-EOF response.
(define (llip-http-post-json host port path body)
  (let ((p (open-tcp-client-port host port)))
    (and p
         (begin
           (write-string "POST " p) (write-string path p)
           (write-string " HTTP/1.1\r\n" p)   ;;;!< llama.cpp's cpp-httplib is HTTP/1.1-only; Connection: close still gives a read-to-EOF body
           (write-string "Host: " p) (write-string host p) (write-string "\r\n" p)
           (write-string "Content-Type: application/json\r\n" p)
           (write-string "Content-Length: " p)
           (write-string (number->string (string-length body)) p)  ;;;!< byte count (string-length is byte-indexed → correct)
           (write-string "\r\nConnection: close\r\n\r\n" p)
           (write-string body p)
           (flush-output-port p)
           (let ((resp (llip-http--read-response p)))
             (close-port p)
             resp)))))

;;; The LLM call: a prompt + a GBNF grammar -> the grammar-constrained LLIP
;;; move-program string (the JSON "content" field), or #f.  Optional host/port
;;; default to the local llama-server.
(define (llip-llm-complete prompt grammar . opts)
  (let* ((host (if (pair? opts) (car opts) "127.0.0.1"))
         (port (if (and (pair? opts) (pair? (cdr opts))) (cadr opts) 8080))
         (req  (json-write (list (cons "prompt"      prompt)
                                 (cons "grammar"     grammar)
                                 (cons "n_predict"   256)
                                 (cons "temperature" 0))))
         (resp (llip-http-post-json host port "/completion" req)))
    (and resp
         (let ((c (assoc "content" (json-read resp))))
           (and c (cdr c))))))

(syslog "llip-http loaded (llip-http-post-json, llip-llm-complete)\n")

; end of llip-http.scm
