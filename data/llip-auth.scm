;;; Copyright 2026 by Frobenius Norm LLC 2026-09-20
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; llip-auth.scm -- [P69] Phase 3: RSA-2048 mutual authentication + DH session key + AES-GCM.
;;;
;;; WHAT IT REPLACES.  LLIP authenticates today with a shared secret sent in clear --
;;; `(auth "secret-token")`, compared by the server (llip-server.scm).  Anyone who can see the
;;; wire has the token, and nothing after it is encrypted: every file push and every eval result
;;; crosses in plaintext.
;;;
;;; THE HANDSHAKE, exactly as P69 specifies it:
;;;
;;;   Client                                      Server
;;;   -> (hello client-pubkey-id nonce-c)
;;;                                       <- (hello server-pubkey-id nonce-s)
;;;   -> (auth-sig SIG-C)   SIG-C = rsa-sign(hmac-sha256(nonce-c, nonce-s), client-priv)
;;;                                       <- (auth-sig SIG-S)   over hmac-sha256(nonce-s, nonce-c)
;;;   -> (dh-offer A)
;;;                                       <- (dh-offer B)
;;;   session-key = hkdf-sha256(dh-shared, nonce-c || nonce-s, 32)
;;;
;;; THE ASYMMETRIC NONCE ORDER IS THE POINT, NOT A DETAIL.  The client signs nonce-c||nonce-s and
;;; the server signs nonce-s||nonce-c.  If both signed the same bytes, an attacker could open a
;;; connection to the server, take the server's signature, and replay it back as its own -- a
;;; reflection attack, and the protocol would authenticate a peer holding no key at all.  Do not
;;; "simplify" these two into one helper with the same argument order.
;;;
;;; EACH SIDE VERIFIES BEFORE IT OFFERS.  The DH offer is sent only after the peer's signature
;;; checks out, so an unauthenticated peer never gets a key exchange to work with.
;;;
;;; NO DOWNGRADE, BY DESIGN.  There is no runtime negotiation back to `(auth token)`; P69 says so
;;; explicitly and the reason is that an attacker who can drop packets could force the weak path.
;;; The legacy route remains a COMPILE-TIME choice for unprovisioned nodes, not a wire option.
;;;
;;; KEY FORMAT -- A DELIBERATE DEVIATION FROM P69 Phase 2, recorded where it is used.  The
;;; proposal stores keys as PKCS#8 / SubjectPublicKeyInfo DER and parses them on the device with
;;; two new C++ mop3s.  These load s-expressions written by `w3_ai_scripts/llip_keygen.py`
;;; instead: an ASN.1 decoder reading an attacker-reachable file on an MCU, for a format nothing
;;; outside this fleet ever reads, buys no interoperability and costs a hand-written parser in the
;;; worst possible place.  `openssl` still generates the key material; it just parses it on the
;;; host.  THE COST: these files are not readable by openssl or ssh.  If a key must ever leave the
;;; fleet, regenerate it as DER.

(syslog "llip-auth loading\n")

;;; ---- module state ------------------------------------------------------------------------
(define *llip-privkey*   #f)     ;;!< alist: n e d p q dp dq qinv
(define *llip-pubkey*    #f)     ;;!< alist: n e   -- ours, derived from the private key
(define *llip-trusted*   '())    ;;!< list of peer public-key alists we will talk to

(define (llip--field key name)
  (let ((hit (assq name (cdr key))))
    (if hit (cdr hit) (error "llip-auth: key is missing field" name))))

;;![B541] THE TAG COMES OFF HERE, AT THE BOUNDARY, AND NOWHERE ELSE.
;;!This module stores a key as the whole file form -- `(private-key (n . N) (e . E) ...)` or
;;!`(public-key (n . N) (e . E))` -- tag included, and `llip--field` above is written for that.
;;!`rsa.scm` takes a BARE alist: `rsa-encrypt` opens with `(cdr (assq 'e pub-key))`.  Handing it
;;!a tagged form makes `assq` reach the leading SYMBOL and call `car` on it, which is a hard
;;!error, not a wrong answer -- every handshake died at its first signature with
;;!`Lamb::car() Bad type ... 'private-key'`, on both sides, in every build.
;;!Strip it HERE rather than teaching rsa.scm about the tag: rsa.scm is a general library with
;;!its own callers and the bare alist is its reasonable contract; the tag is ours.
(define (llip--rsa-key k) (cdr k))

;;!(llip-pubkey-id pubkey) -> 8-byte bytevector identifying a key on the wire.
;;!P69 says "first 8 bytes of (sha256 pubkey-der-bytes)".  With no DER, the canonical bytes are
;;!the modulus big-endian -- `bignum->bytevector` of n.  That is a stable, implementation-
;;!independent serialisation of the only field that identifies an RSA key, and both ends compute
;;!it the same way.  IT IS AN IDENTIFIER, NOT A CREDENTIAL: it says which key to look up, and
;;!proves nothing.  The signature is what authenticates.
(define (llip-pubkey-id pubkey)
  (let ((d (sha256 (bignum->bytevector (llip--field pubkey 'n)))))
    (let ((out (make-bytevector 8 0)))
      (let loop ((i 0))
        (if (< i 8) (begin (bytevector-u8-set! out i (bytevector-u8-ref d i)) (loop (+ i 1)))))
      out)))

;;!(llip-load-keys privkey-path trusted-path) -- read our key and the peers we trust.
;;!`trusted-path` may hold one public key or a list of them.
(define (llip-load-keys privkey-path trusted-path)
  (if (not (file-exists? privkey-path)) (error "llip-load-keys: no private key at" privkey-path))
  (set! *llip-privkey* (with-input-from-file privkey-path (lambda () (read))))
  (if (not (eq? (car *llip-privkey*) 'private-key))
      (error "llip-load-keys: not a private key file" privkey-path))
  ;;! Our own public half is DERIVED, never stored twice.  Two copies of one fact drift.
  (set! *llip-pubkey*
        (list 'public-key
              (cons 'n (llip--field *llip-privkey* 'n))
              (cons 'e (llip--field *llip-privkey* 'e))))
  (set! *llip-trusted*
        (if (file-exists? trusted-path)
            (let ((raw (with-input-from-file trusted-path (lambda () (read)))))
              (cond ((and (pair? raw) (eq? (car raw) 'public-key)) (list raw))
                    ((and (pair? raw) (eq? (car raw) 'trusted-keys)) (cdr raw))
                    (else (error "llip-load-keys: unrecognised trusted-keys file" trusted-path))))
            '()))
  (length *llip-trusted*))

;;!Find a trusted key by the id the peer announced.  Returns #f when the peer is unknown --
;;!checked by the caller, which closes the connection.  Compares the ID BYTES, not the key.
(define (llip--trusted-by-id id)
  (let loop ((ks *llip-trusted*))
    (cond ((null? ks) #f)
          ((equal? id (llip-pubkey-id (car ks))) (car ks))
          (else (loop (cdr ks))))))

;;; ---- wire codec ----------------------------------------------------------------------------
;;; [B540] THESE WERE MISSING.  `llip-send` and `llip-recv` were called sixteen times below and
;;; defined nowhere in the tree, so BOTH handshake procedures raised `Unbound key llip-send` on
;;; their first line of real work -- every build, every target, since Phase 4 landed.  The LLIP
;;; handshake had therefore never completed once.  `llip-auth-tests.scm` passed 9/9 throughout,
;;; because it drives the PIECES through in-memory ports and never calls either handshake: a
;;; missing definition is invisible to a suite that never calls the caller.
;;;
;;; ONE S-EXPRESSION PER LINE, AND NOT `read` STRAIGHT OFF THE SOCKET.  This mirrors
;;; llip-transport.scm's llip-frame-write!/llip-frame-read deliberately, and the reason is in
;;; that file's header: the reader's peek can see a SPLIT TCP SEGMENT as EOF mid-datum, so
;;; reading a datum directly from a socket fails intermittently under exactly the conditions a
;;; test on loopback will not reproduce.  Read a LINE first, parse from the string second.
;;; It is duplicated rather than imported because llip-transport.scm is a separate optional
;;; feature and the handshake must not depend on the orchestrator being loaded; if these two
;;; codecs ever diverge, that is a bug in itself -- they are the same wire format.

;;!(llip-send port sexpr) -- write one frame: the datum, a newline, then flush.
(define (llip-send port sexpr)
  (write sexpr port)
  (write-string "\n" port)
  (flush-output-port port))

;;!(llip-recv port) -- read one frame.  RAISES on EOF rather than returning #f: every caller
;;!here immediately pattern-matches the result against an expected message tag, so a #f would
;;!be reported as "expected hello, got #f" -- which names the wrong problem.  A peer that hung
;;!up mid-handshake is a transport failure and should say so.
(define (llip-recv port)
  (let ((line (read-line port)))
    (if (eof-object? line)
        (error "llip-recv: peer closed the connection mid-handshake")
        (read (open-input-string line)))))

;;; ---- the handshake -------------------------------------------------------------------------

(define llip-nonce-bytes 32)

;;!Sign the two nonces in the order this ROLE must use.  See the reflection note in the header:
;;!the orders differ on purpose and the two callers must not share one.
(define (llip--sign-nonces first second)
  (rsa-sign (hmac-sha256 first second) (llip--rsa-key *llip-privkey*)))

(define (llip--verify-nonces peer-key first second sig)
  (rsa-verify (hmac-sha256 first second) sig (llip--rsa-key peer-key)))

(define (llip--derive-session dh-shared nonce-c nonce-s)
  (hkdf-sha256 (bignum->bytevector dh-shared)
               (bytevector-append nonce-c nonce-s)
               32))

;;!(llip-client-handshake port) -> 32-byte session key, or raises.
(define (llip-client-handshake port)
  (if (not *llip-privkey*) (error "llip-client-handshake: call llip-load-keys first"))
  (let* ((nonce-c (ll-random-bytes llip-nonce-bytes)))
    (llip-send port (list 'hello (base64-encode (llip-pubkey-id *llip-pubkey*))
                                 (base64-encode nonce-c)))
    (let ((msg (llip-recv port)))
      (if (or (not (pair? msg)) (not (eq? (car msg) 'hello)))
          (error "llip-client-handshake: expected hello, got" msg))
      (let* ((peer-id (base64-decode (cadr msg)))
             (nonce-s (base64-decode (caddr msg)))
             (peer    (llip--trusted-by-id peer-id)))
        (if (not peer) (error "llip-client-handshake: server key is not trusted"))
        ;; we sign nonce-c||nonce-s; the server signs the reverse
        (llip-send port (list 'auth-sig (base64-encode (bignum->bytevector
                                                        (llip--sign-nonces nonce-c nonce-s)))))
        (let ((sig-msg (llip-recv port)))
          (if (or (not (pair? sig-msg)) (not (eq? (car sig-msg) 'auth-sig)))
              (error "llip-client-handshake: expected auth-sig, got" sig-msg))
          (if (not (llip--verify-nonces peer nonce-s nonce-c
                                        (bytevector->bignum (base64-decode (cadr sig-msg)))))
              (error "llip-client-handshake: server signature did not verify"))
          ;; authenticated -- only now do we offer a key exchange
          (let* ((kp   (diffie-hellman-keygen dh-group-14-prime 2))
                 (pub  (car kp))
                 (priv (cdr kp)))
            (llip-send port (list 'dh-offer (base64-encode (bignum->bytevector pub))))
            (let ((off (llip-recv port)))
              (if (or (not (pair? off)) (not (eq? (car off) 'dh-offer)))
                  (error "llip-client-handshake: expected dh-offer, got" off))
              (llip--derive-session
               (diffie-hellman-shared (bytevector->bignum (base64-decode (cadr off)))
                                      priv dh-group-14-prime)
               nonce-c nonce-s))))))))

;;!(llip-server-handshake port) -> 32-byte session key, or raises.
(define (llip-server-handshake port)
  (if (not *llip-privkey*) (error "llip-server-handshake: call llip-load-keys first"))
  (let ((msg (llip-recv port)))
    (if (or (not (pair? msg)) (not (eq? (car msg) 'hello)))
        (error "llip-server-handshake: expected hello, got" msg))
    (let* ((peer-id (base64-decode (cadr msg)))
           (nonce-c (base64-decode (caddr msg)))
           (nonce-s (ll-random-bytes llip-nonce-bytes))
           (peer    (llip--trusted-by-id peer-id)))
      (if (not peer) (error "llip-server-handshake: client key is not trusted"))
      (llip-send port (list 'hello (base64-encode (llip-pubkey-id *llip-pubkey*))
                                   (base64-encode nonce-s)))
      (let ((sig-msg (llip-recv port)))
        (if (or (not (pair? sig-msg)) (not (eq? (car sig-msg) 'auth-sig)))
            (error "llip-server-handshake: expected auth-sig, got" sig-msg))
        (if (not (llip--verify-nonces peer nonce-c nonce-s
                                      (bytevector->bignum (base64-decode (cadr sig-msg)))))
            (error "llip-server-handshake: client signature did not verify"))
        ;; we sign nonce-s||nonce-c -- the reverse of the client's order
        (llip-send port (list 'auth-sig (base64-encode (bignum->bytevector
                                                        (llip--sign-nonces nonce-s nonce-c)))))
        (let* ((kp   (diffie-hellman-keygen dh-group-14-prime 2))
               (pub  (car kp))
               (priv (cdr kp))
               (off  (llip-recv port)))
          (if (or (not (pair? off)) (not (eq? (car off) 'dh-offer)))
              (error "llip-server-handshake: expected dh-offer, got" off))
          (llip-send port (list 'dh-offer (base64-encode (bignum->bytevector pub))))
          (llip--derive-session
           (diffie-hellman-shared (bytevector->bignum (base64-decode (cadr off)))
                                  priv dh-group-14-prime)
           nonce-c nonce-s))))))

;;; ---- encrypted transport -------------------------------------------------------------------

;;!AES-128-GCM takes a 16-byte key; the session key is 32.  Use the FIRST HALF and say so, rather
;;!than letting a length mismatch be discovered by the mop3's argument check.  The remaining 16
;;!bytes are reserved for a future direction-separated key pair; do not repurpose them silently.
(define (llip--aes-key session-key)
  (let ((k (make-bytevector 16 0)))
    (let loop ((i 0))
      (if (< i 16) (begin (bytevector-u8-set! k i (bytevector-u8-ref session-key i)) (loop (+ i 1)))))
    k))

;;!(llip-send-encrypted port session-key sexpr)
;;!A FRESH RANDOM IV PER MESSAGE, AND THIS IS NOT OPTIONAL: GCM catastrophically fails if an IV is
;;!reused under one key -- two messages with the same IV leak their XOR and, worse, allow the
;;!authentication key to be recovered.  Never derive the IV from a counter that could restart, and
;;!an embedded node DOES restart.
(define (llip-send-encrypted port session-key sexpr)
  (let* ((iv  (ll-random-bytes 12))
         (txt (let ((o (open-output-string))) (write sexpr o) (get-output-string o)))
         (pt  (string->utf8 txt))
         (ct  (llip-aes-gcm-encrypt (llip--aes-key session-key) iv pt)))
    (llip-send port (list 'eval-encrypted (base64-encode iv) (base64-encode ct)))))

;;!(llip-recv-encrypted port session-key) -> the s-expression, or RAISES.
;;!A failed tag raises out of the mop3 and is deliberately NOT caught here: a message that does
;;!not authenticate is not a message, and a caller that got a value back would have no way to
;;!know it was forged.
(define (llip-recv-encrypted port session-key)
  (let ((msg (llip-recv port)))
    (if (or (not (pair? msg)) (not (eq? (car msg) 'eval-encrypted)))
        (error "llip-recv-encrypted: expected eval-encrypted, got" msg))
    (let* ((iv (base64-decode (cadr msg)))
           (ct (base64-decode (caddr msg)))
           (pt (llip-aes-gcm-decrypt (llip--aes-key session-key) iv ct)))
      ;! `read` takes an explicit port here.  There is no `with-input-from-string` in this
      ;! implementation -- only `with-input-from-file` -- so `open-input-string` plus a
      ;! port argument is the route, and it is the better one anyway: no current-input-port
      ;! to save and restore, and nothing to leak if `read` raises on a malformed payload.
      (read (open-input-string (utf8->string pt))))))

(syslog "llip-auth loaded\n")
