;;; bacnet.scm — BACnet/IP client (ASHRAE 135 / ISO 16484-5, Annex J) for LambLisp (P109).
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-22
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; WHAT THIS IS, IN THE VOCABULARY A SPECIFICATION WILL ASK IN.  BACnet does not divide the world
;;; into client and server boxes; it assigns a role PER SERVICE, where **A** originates a confirmed
;;; request and **B** executes it and answers.  Conformance is stated as BIBBs (BACnet
;;; Interoperability Building Blocks).  This node has a Device object and both sides of discovery:
;;;
;;;     bacnet-who-is          DM-DDB-A   sends Who-Is, collects I-Am           (initiator)
;;;     bacnet-read-property   DS-RP-A    Data Sharing - ReadProperty           (initiator)
;;;     bacnet-write-property  DS-WP-A    Data Sharing - WriteProperty          (initiator)
;;;     bacnet-device-poll     DM-DDB-B   answers Who-Is with I-Am              (EXECUTES)
;;;     bacnet-device-poll     DS-RP-B    serves ReadProperty on the Device object (EXECUTES)
;;;
;;; SO IT IS DISCOVERABLE AND READABLE: a workstation scanning the network finds it (DM-DDB-B) and
;;; can then read its Device object (DS-RP-B).  That pair is the line between a tool that talks to
;;; BACnet equipment and a node that IS one.
;;;
;;; IT MEETS THE BIBB REQUIREMENTS OF **B-SS** (BACnet Smart Sensor), the smallest standard device
;;; profile -- B-SS requires DS-RP-B and DM-DDB-B, and both are here.  Worded carefully: it MEETS
;;; THE BIBB REQUIREMENTS.  It is not a certified B-SS, because certification is a test-lab
;;; process and a PICS is a document a person signs.
;;;
;;; AND A USEFUL SMART SENSOR NEEDS SENSOR OBJECTS, which this does not have.  The only object is
;;; the Device object, so there is no analog-input whose present-value a workstation could read:
;;; conformant and empty.  Adding input objects is small -- the property store is already a
;;; per-object alist -- and saying so is better than letting "B-SS" imply it.
;;;
;;; STILL ABSENT: ReadPropertyMultiple, COV, alarm and event
;;; handling, segmentation, and MS/TP (BACnet/IP over UDP only).  B-SA and B-ASC need DS-WP-B and
;;; more besides.
;;;
;;; THE BIBB NAMES ABOVE ARE FROM ASHRAE 135 Annex K AND ARE NOT MACHINE-CHECKED HERE.  Before any
;;; of them goes into a compliance table or a datasheet, read them against the standard: a
;;; conformance claim is sales surface, and [B388] is this file's own cautionary record of what an
;;; unverified protocol claim costs once it ships to every customer.
;;;
;;; WHY PURE SCHEME AND NOT bacnet-stack.  P109 proposes binding `bacnet-stack`, which is the right
;;; answer for a full device.  For a client this is ~300 lines over the UDP primitive [B404] added,
;;; it ships to every target with `scm/` at zero flash cost on targets that never load it, and it
;;; carries no GPL-with-linking-exception question into a customer's build.  When P109 Ph2+ needs a
;;; device, the library is the right tool; this file is deliberately not in its way.
;;;
;;; ON THE WIRE (Annex J).  Every frame is
;;;     BVLL:  81 <function> <len16>          len counts the WHOLE frame including these 4 bytes
;;;     NPDU:  01 <control>                   control 04 = expecting a reply
;;;     APDU:  the service, tagged per clause 20
;;; Tags: a CONTEXT tag byte is (number<<4) | 8 | length, an APPLICATION tag byte is
;;; (number<<4) | length, and lengths 6 and 7 in a context tag mean OPENING and CLOSING.
;;; That one rule explains every magic byte below: 0x0C is "context 0, 4 bytes" (an object id),
;;; 0x19 is "context 1, 1 byte" (a property id), 0x3E/0x3F are "open/close tag 3".

(syslog "Loading BACnet/IP client\n")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; constants ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define bacnet-port 47808)              ;;;!< 0xBAC0, the registered BACnet/IP port

;;; RECEIVE BUFFER = the max APDU we advertise, plus the BVLL and NPDU bytes in front of it.
;;; `udp-recv` is (port MAX-BYTES [timeout-ms]) and it TRUNCATES at max-bytes, BSD-style -- so this
;;; number is not a guess, it is the largest frame we have told every peer we will accept.  Passing
;;; a timeout here by mistake silently caps the datagram at that many BYTES: the first draft of
;;; this file did exactly that (`(udp-recv sock 250)`), and it worked in every test, because a
;;; Who-Is is 8 bytes and an I-Am is 21.  A ReadProperty ACK carrying an object-list would have
;;; been cut in half and then failed to parse, on a customer's site, intermittently.
(define bacnet-recv-max (+ 1476 6))

(define bacnet-bvlc-type #x81)
(define bacnet-bvlc-unicast   #x0a)     ;;;!< Original-Unicast-NPDU
(define bacnet-bvlc-broadcast #x0b)     ;;;!< Original-Broadcast-NPDU

;;; Object types (clause 21).  The ones a client meets on an AHU or a VAV box.
(define bacnet-object-analog-input   0)
(define bacnet-object-analog-output  1)
(define bacnet-object-analog-value   2)
(define bacnet-object-binary-input   3)
(define bacnet-object-binary-output  4)
(define bacnet-object-binary-value   5)
(define bacnet-object-device         8)
(define bacnet-object-multi-state-input  13)
(define bacnet-object-multi-state-output 14)
(define bacnet-object-multi-state-value  19)

;;; Property identifiers (clause 21).  present-value is the one that carries the reading.
(define bacnet-prop-object-name    77)
(define bacnet-prop-object-type    79)
(define bacnet-prop-present-value  85)
(define bacnet-prop-description    28)
(define bacnet-prop-units         117)
(define bacnet-prop-status-flags  111)
(define bacnet-prop-out-of-service 81)
(define bacnet-prop-object-list    76)
(define bacnet-prop-vendor-name   121)
(define bacnet-prop-model-name     70)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; encoding ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; A BACnet object identifier is ONE 32-bit word: 10 bits of type, 22 bits of instance.
;;; Splitting it the other way is the classic BACnet bug -- instance 12 of type 8 is 0x0200000C,
;;; not 0x0800000C -- so both directions live here and the tests check the round trip.
(define (bacnet-objid type instance)
  (bitwise-or (arithmetic-shift type 22) instance))

(define (bacnet-objid-type objid)   (arithmetic-shift objid -22))
(define (bacnet-objid-instance objid) (bitwise-and objid #x3fffff))

(define (bacnet-u8 n) (bytevector (bitwise-and n #xff)))

;;; Unsigned in the FEWEST bytes, which is what clause 20.2.4 requires -- a 1-byte property id
;;; must not be sent as 4.  Some devices accept the padded form; the standard does not.
(define (bacnet-uint-bytes n)
  (cond ((< n #x100)     (struct-pack ">B" n))
        ((< n #x10000)   (struct-pack ">H" n))
        (else            (struct-pack ">I" n))))

;;; Context tag: (number<<4) | 8 | length.  Lengths 6 and 7 are OPENING and CLOSING, so a real
;;; length of 6 or 7 would need the extended form; no field this client sends is that long.
(define (bacnet-context-tag number len)
  (bytevector (bitwise-or (arithmetic-shift number 4) (bitwise-or #x08 len))))

(define (bacnet-context-uint number n)
  (let ((b (bacnet-uint-bytes n)))
    (bytevector-append (bacnet-context-tag number (bytevector-length b)) b)))

(define (bacnet-context-objid number objid)
  (bytevector-append (bacnet-context-tag number 4) (struct-pack ">I" objid)))

(define (bacnet-open-tag number)  (bacnet-context-tag number 6))
(define (bacnet-close-tag number) (bacnet-context-tag number 7))

;;; ONE TAGGING RULE FOR EVERY DATATYPE, INCLUDING EXTENDED LENGTH.  The length nibble holds
;;; 0..4; **5 means the real length follows** -- one octet, or 254 then two, or 255 then four.
;;; Writing that rule once is the point: the first draft open-coded each datatype's tag byte, which
;;; is fine while every value is short and silently wrong for the first object name longer than
;;; three characters.  `bacnet-tag-at` is this function read backwards, and the tests round-trip
;;; the pair so they cannot drift apart.
(define (bacnet-tagged num payload)
  (let ((len (bytevector-length payload))
        (hi  (arithmetic-shift num 4)))
    (bytevector-append
     (cond ((< len 5)     (bytevector (bitwise-or hi len)))
           ((< len 254)   (bytevector (bitwise-or hi 5) len))
           ((< len 65536) (bytevector-append (bytevector (bitwise-or hi 5) 254) (struct-pack ">H" len)))
           (else          (bytevector-append (bytevector (bitwise-or hi 5) 255) (struct-pack ">I" len))))
     payload)))

;;; Application-tagged value.  The tag number IS the datatype (clause 20.2.1.4), so this is where
;;; a Scheme value becomes a BACnet one; get it wrong and the device answers with a Reject PDU
;;; rather than doing anything dangerous, which is the one mercy in this protocol.
;;; A LIST of values encodes as the concatenation -- that is how object-list travels.
(define (bacnet-app-value v)
  (cond ((eq? v 'null)      (bytevector #x00))
        ((eq? v #t)         (bytevector #x11))   ;;;!< boolean puts the VALUE in the length nibble
        ((eq? v #f)         (bytevector #x10))
        ((string? v)
         ;;;!< first payload octet is the character set: 0 = ANSI X3.4 (ASCII)
         (bacnet-tagged 7 (bytevector-append (bytevector #x00) (string->utf8 v))))
        ((and (pair? v) (eq? (car v) 'enumerated))
         (bacnet-tagged 9 (bacnet-uint-bytes (cadr v))))
        ((and (pair? v) (eq? (car v) 'unsigned))
         (bacnet-tagged 2 (bacnet-uint-bytes (cadr v))))
        ((and (pair? v) (eq? (car v) 'objid))
         (bacnet-tagged 12 (struct-pack ">I" (cadr v))))
        ((and (number? v) (inexact? v)) (bacnet-tagged 4 (struct-pack ">f" v)))
        ((and (number? v) (exact? v) (>= v 0)) (bacnet-tagged 2 (bacnet-uint-bytes v)))
        ((null? v) (bytevector))                 ;;;!< an empty list encodes as nothing at all
        ((pair? v)
         (let loop ((l v) (acc (bytevector)))
           (if (null? l) acc (loop (cdr l) (bytevector-append acc (bacnet-app-value (car l)))))))
        (else (error "bacnet: cannot encode value" v))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; framing ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; BVLL + NPDU wrapper.  The length field counts the WHOLE frame including the four BVLL bytes,
;;; which is why it cannot be filled in until the APDU exists.
(define (bacnet-frame function npdu-control apdu)
  (let* ((npdu (bytevector #x01 npdu-control))
         (body (bytevector-append npdu apdu))
         (len  (+ 4 (bytevector-length body))))
    (bytevector-append (bytevector bacnet-bvlc-type function)
                       (struct-pack ">H" len)
                       body)))

;;; Who-Is with no range = "every device, answer me".  Unconfirmed, so NPDU control is 0: asking
;;; for a reply with the expecting-reply bit set is a confirmed-service thing and some devices
;;; will ignore the frame if it is set here.
(define (bacnet-encode-who-is)
  (bacnet-frame bacnet-bvlc-broadcast #x00 (bytevector #x10 #x08)))

;;; ReadProperty (service 12).  Byte 1 is (max-segments<<4)|max-APDU; #x05 is "no segmentation,
;;; 1476 octets", the safe answer for a client that does not implement segmentation.
(define (bacnet-encode-read-property invoke-id objid propid)
  (bacnet-frame bacnet-bvlc-unicast #x04
    (bytevector-append (bytevector #x00 #x05 (bitwise-and invoke-id #xff) #x0c)
                       (bacnet-context-objid 0 objid)
                       (bacnet-context-uint 1 propid))))

;;; WriteProperty (service 15).  The value sits between an opening and closing tag 3 because the
;;; standard types it as ABSTRACT-SYNTAX.ANY -- the device cannot know the datatype from the
;;; property id alone.  Priority (tag 4) is optional and MATTERS: writing present-value without
;;; one takes the lowest priority slot, and on real equipment that is usually not what is wanted.
(define (bacnet-encode-write-property invoke-id objid propid value . opt)
  (let ((priority (if (pair? opt) (car opt) #f)))
    (bacnet-frame bacnet-bvlc-unicast #x04
      (bytevector-append (bytevector #x00 #x05 (bitwise-and invoke-id #xff) #x0f)
                         (bacnet-context-objid 0 objid)
                         (bacnet-context-uint 1 propid)
                         (bacnet-open-tag 3)
                         (bacnet-app-value value)
                         (bacnet-close-tag 3)
                         (if priority (bacnet-context-uint 4 priority) (bytevector))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; decoding ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; VALIDATE BEFORE TRUSTING.  UDP is connectionless: anything on the network can send us bytes
;;; and `udp-recv` will hand them over.  Same discipline as nettime.scm -- check the framing
;;; before reading a value out of it, or a stray packet becomes a sensor reading.
;;; Returns the APDU as (offset . bytevector), or #f.
(define (bacnet-apdu-start bv)
  (let ((n (bytevector-length bv)))
    (cond ((< n 6) #f)
          ((not (= (bytevector-u8-ref bv 0) bacnet-bvlc-type)) #f)
          ((not (= (car (struct-unpack ">H" bv 2)) n)) #f)   ;;;!< declared length must be the real one
          ((not (= (bytevector-u8-ref bv 4) #x01)) #f)       ;;;!< NPDU version
          (else
           ;; NPDU control bit 3 (#x08) = DNET/DADR present; skip it if a router added one.
           (let ((control (bytevector-u8-ref bv 5)))
             (if (= 0 (bitwise-and control #x08))
                 6
                 (let ((dlen (bytevector-u8-ref bv 8)))   ;;;!< 6,7=DNET 8=DLEN then DADR then hop
                   (+ 9 dlen 1))))))))

;;; READ A TAG HEADER PROPERLY, INCLUDING EXTENDED LENGTH (clause 20.2.1.3.1).  The length nibble
;;; is three bits, so it can only carry 0..4 directly; the value **5 means "the real length
;;; follows"** -- one octet, or 254 then two octets, or 255 then four.  Treating 5 as a literal
;;; length is the bug this function exists to not have: it is invisible for short values and wrong
;;; for every string longer than three characters, which is most real object names.
;;;
;;; THE FIRST DRAFT HAD EXACTLY THAT BUG AND A TEST THAT AGREED WITH IT.  A 4-character string
;;; carries 5 octets (one encoding byte + four chars), so nibble 5 and length 5 coincide and
;;; "AHU1" decoded correctly by accident.  The test vector had been written from the same
;;; misunderstanding as the code, so the two confirmed each other -- which is what a test is worth
;;; when its expected value is derived from the implementation rather than from the standard.
;;;
;;; Returns (tag-number context? length data-offset), or #f.
(define (bacnet-tag-at bv off)
  (let ((n (bytevector-length bv)))
    (if (>= off n)
        #f
        (let* ((tag (bytevector-u8-ref bv off))
               (num (arithmetic-shift tag -4))
               (ctx (not (= 0 (bitwise-and tag #x08))))
               (nib (bitwise-and tag #x07)))
          (cond
            ((and ctx (or (= nib 6) (= nib 7)))       ;;;!< opening / closing, no length
             (list num ctx nib (+ off 1)))
            ((< nib 5) (list num ctx nib (+ off 1)))
            ((>= (+ off 1) n) #f)
            (else
             (let ((b (bytevector-u8-ref bv (+ off 1))))
               (cond ((= b 254)
                      (if (>= (+ off 3) n) #f
                          (list num ctx (bacnet-uint-at bv (+ off 2) 2) (+ off 4))))
                     ((= b 255)
                      (if (>= (+ off 5) n) #f
                          (list num ctx (bacnet-uint-at bv (+ off 2) 4) (+ off 6))))
                     (else (list num ctx b (+ off 2)))))))))))

;;; Read ONE application-tagged value at `off`.  Returns (value . next-offset), or #f.
(define (bacnet-decode-app-value bv off)
  (let ((t (bacnet-tag-at bv off)))
    (if (or (not t) (cadr t))                          ;;;!< #f, or a CONTEXT tag where we want data
        #f
        (let ((num (car t)) (len (car (cddr t))) (d (cadr (cddr t))))
          (cond
            ;;;!< NULL AND BOOLEAN HAVE NO PAYLOAD, and boolean is the one datatype whose length
            ;;;!< nibble is the VALUE rather than a byte count (clause 20.2.3): `11` is true, `10`
            ;;;!< is false, and neither is followed by anything.  They must therefore be decoded
            ;;;!< BEFORE the bounds check, because that check reads `len` as a count and a 1-byte
            ;;;!< frame carrying `#x11` looks like "one byte of payload that runs off the end".
            ;;;!< The first version checked bounds first and so returned #f for every TRUE -- and
            ;;;!< the round-trip test caught it only through the HARNESS, which is the arm that
            ;;;!< actually raised `(car #f)`.
            ((= num 0) (cons 'null d))
            ((= num 1) (cons (if (= len 1) #t #f) d))
            ((> (+ d len) (bytevector-length bv)) #f)   ;;;!< a length that runs off the end
            (else
              (cond
                ((= num 2) (cons (bacnet-uint-at bv d len) (+ d len)))
                ((= num 3) (cons (bacnet-int-at bv d len) (+ d len)))
                ((= num 4) (cons (car (struct-unpack ">f" bv d)) (+ d 4)))
                ;;;!< character string: first payload octet is the encoding (0 = ANSI X3.4)
                ((= num 7) (cons (bacnet-string-at bv (+ d 1) (- len 1)) (+ d len)))
                ((= num 9) (cons (list 'enumerated (bacnet-uint-at bv d len)) (+ d len)))
                ((= num 12) (cons (list 'objid (car (struct-unpack ">I" bv d))) (+ d 4)))
                (else #f))))))))

(define (bacnet-uint-at bv off len)
  (let loop ((i 0) (acc 0))
    (if (>= i len) acc
        (loop (+ i 1) (bitwise-or (arithmetic-shift acc 8) (bytevector-u8-ref bv (+ off i)))))))

(define (bacnet-int-at bv off len)
  (let ((u (bacnet-uint-at bv off len))
        (lim (arithmetic-shift 1 (- (* 8 len) 1))))
    (if (>= u lim) (- u (arithmetic-shift 1 (* 8 len))) u)))

(define (bacnet-string-at bv off len)
  (let loop ((i 0) (acc '()))
    (if (>= i len)
        (list->string (reverse acc))
        (loop (+ i 1) (cons (integer->char (bytevector-u8-ref bv (+ off i))) acc)))))

;;; Decode a ReadProperty ComplexACK: 30 <invoke> 0C, then context 0 objid, context 1 propid,
;;; an OPTIONAL context 2 array index, then the value between opening and closing tag 3.
;;;
;;; PARSE THE TAGS; DO NOT SCAN FOR 0x3E.  The first version walked forward looking for the byte
;;; 0x3E as "the opening tag", and that is a bug with a date on it: **property 62 is
;;; `max-apdu-length-accepted`, and 62 IS 0x3E**, so `19 3E` -- the context-tagged property id --
;;; contains the byte being searched for.  Reading that one property returned #f, and any object
;;; or property number containing 0x3E would do the same.  A scan for a magic byte cannot tell a
;;; tag from a value; only walking the structure can.  Found by a test that read max-apdu back.
(define (bacnet-decode-read-ack bv invoke-id)
  (let ((start (bacnet-apdu-start bv))
        (n (bytevector-length bv)))
    (if (or (not start) (>= (+ start 2) n)
            (not (= (bytevector-u8-ref bv start) #x30))
            (not (= (bytevector-u8-ref bv (+ start 1)) (bitwise-and invoke-id #xff)))
            (not (= (bytevector-u8-ref bv (+ start 2)) #x0c)))
        #f
        (let ((o (bacnet-context-objid-at bv (+ start 3) 0)))
          (if (not o)
              #f
              (let ((pr (bacnet-context-uint-at bv (cdr o) 1)))
                (if (not pr)
                    #f
                    (let* ((ix (bacnet-context-uint-at bv (cdr pr) 2))
                           (at (if ix (cdr ix) (cdr pr)))
                           (t  (bacnet-tag-at bv at)))
                      (if (or (not t) (not (cadr t)) (not (= (car t) 3)) (not (= (car (cddr t)) 6)))
                          #f
                          (let ((v (bacnet-decode-app-value bv (cadr (cddr t)))))
                            (if v (car v) #f)))))))))))

;;; A SimpleACK is the whole answer to WriteProperty: 20 <invoke> <service>.
(define (bacnet-decode-simple-ack bv invoke-id service)
  (let ((start (bacnet-apdu-start bv)))
    (and start
         (> (bytevector-length bv) (+ start 2))
         (= (bytevector-u8-ref bv start) #x20)
         (= (bytevector-u8-ref bv (+ start 1)) (bitwise-and invoke-id #xff))
         (= (bytevector-u8-ref bv (+ start 2)) service))))

;;; I-Am: 10 00, then application-tagged objid, max-APDU, segmentation, vendor id.
;;; Returns (device-instance max-apdu vendor-id), or #f.
(define (bacnet-decode-i-am bv)
  (let ((start (bacnet-apdu-start bv)))
    (if (or (not start)
            (<= (bytevector-length bv) (+ start 1))
            (not (= (bytevector-u8-ref bv start) #x10))
            (not (= (bytevector-u8-ref bv (+ start 1)) #x00)))
        #f
        (let* ((a (bacnet-decode-app-value bv (+ start 2))))
          (if (not a)
              #f
              (let* ((objid (cadr (car a)))
                     (b (bacnet-decode-app-value bv (cdr a))))
                (if (not b)
                    #f
                    (let ((c (bacnet-decode-app-value bv (cdr b))))
                      (if (not c)
                          #f
                          (let ((d (bacnet-decode-app-value bv (cdr c))))
                            (list (bacnet-objid-instance objid)
                                  (car b)
                                  (if d (car d) #f))))))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; session ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; A session is (udp-port . invoke-counter-box).  The invoke id must CHANGE between outstanding
;;; requests or a late reply to request N is accepted as the reply to request N+1 -- the same
;;; class of mistake as reading a stale Modbus transaction id.  One byte, wraps at 256.
(define (bacnet-open . opt)
  (let ((sock (open-udp-port (if (pair? opt) (car opt) bacnet-port))))
    (and sock (cons sock (list 0)))))

(define (bacnet-close s)
  (and (pair? s) (close-port (car s))))

(define (bacnet-next-invoke s)
  (let* ((box (cdr s)) (v (car box)))
    (set-car! box (remainder (+ v 1) 256))
    v))

;;; Send one request and wait for a reply this client recognises.  Datagrams that fail validation
;;; are DISCARDED and the wait continues until the deadline: on a live BACnet network the
;;; broadcast traffic of other devices arrives constantly, and treating the first packet that
;;; shows up as the answer is how a client reads someone else's I-Am as its own ReadProperty.
(define (bacnet-request s addr frame decoder timeout-ms)
  (let ((sock (car s)))
    (if (not (udp-send sock addr bacnet-port frame))
        #f
        (let loop ((left timeout-ms))
          (if (<= left 0)
              #f
              (let ((reply (udp-recv sock bacnet-recv-max (if (> left 250) 250 left))))
                (if (not reply)
                    (loop (- left 250))
                    (let ((v (decoder reply)))
                      (if v v (loop (- left 250)))))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; public API ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Read a property.  Returns the decoded value, or #f on timeout/error/reject.
;;; (bacnet-read-property s "192.168.1.50" bacnet-object-analog-input 1 bacnet-prop-present-value)
(define (bacnet-read-property s addr objtype objinst propid . opt)
  (let* ((timeout (if (pair? opt) (car opt) 3000))
         (id (bacnet-next-invoke s))
         (objid (bacnet-objid objtype objinst)))
    (bacnet-request s addr
                    (bacnet-encode-read-property id objid propid)
                    (lambda (bv) (bacnet-decode-read-ack bv id))
                    timeout)))

;;; Write a property.  Returns #t on SimpleACK, #f otherwise.  `priority` is 1..16; omit it only
;;; when writing something that is not commandable.
(define (bacnet-write-property s addr objtype objinst propid value . opt)
  (let* ((priority (if (pair? opt) (car opt) #f))
         (timeout (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) 3000))
         (id (bacnet-next-invoke s))
         (objid (bacnet-objid objtype objinst))
         (frame (if priority
                    (bacnet-encode-write-property id objid propid value priority)
                    (bacnet-encode-write-property id objid propid value))))
    (bacnet-request s addr frame
                    (lambda (bv) (bacnet-decode-simple-ack bv id #x0f))
                    timeout)))

;;; Discover devices.  Broadcasts Who-Is and COLLECTS every I-Am until the window closes -- it
;;; does not stop at the first, because the point of discovery is the whole list.
;;; Returns a list of (device-instance max-apdu vendor-id).
(define (bacnet-who-is s bcast . opt)
  (let ((timeout (if (pair? opt) (car opt) 2000))
        (sock (car s)))
    (if (not (udp-send sock bcast bacnet-port (bacnet-encode-who-is)))
        '()
        (let loop ((left timeout) (found '()))
          (if (<= left 0)
              (reverse found)
              (let ((reply (udp-recv sock bacnet-recv-max (if (> left 250) 250 left))))
                (if (not reply)
                    (loop (- left 250) found)
                    (let ((d (bacnet-decode-i-am reply)))
                      (loop (- left 250)
                            (if (and d (not (member d found))) (cons d found) found))))))))))

;;;;;;;;;;;;;;;;;;;;;;;; the Device object, and DM-DDB-B ;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; THIS IS THE B SIDE -- the half that ANSWERS.  Everything above originates requests; from here
;;; down the application can be asked something and reply, which is the difference between a tool
;;; that talks to BACnet equipment and a thing that is ON a BACnet network.
;;;
;;; DM-DDB-B is exactly one obligation: when a Who-Is arrives that selects us, emit an I-Am.
;;; That is what makes the node DISCOVERABLE -- a workstation's "scan the network" finds it, and
;;; a peer that needs to bind our device instance to an address learns it without being told.
;;;
;;; THE I-Am IS BROADCAST, NOT SENT BACK TO THE ASKER, and here that is forced as well as correct:
;;; `udp-recv` hands back the datagram and NOT the sender's address, so a unicast reply is not
;;; available to us.  The standard broadcasts I-Am anyway -- every listener wants the binding, not
;;; just the one that asked -- so the constraint and the protocol agree.  Worth knowing before
;;; anyone tries to add a unicast path: it needs a primitive change, not a Scheme change.

;;; Device-object property identifiers (clause 12.11).  Required properties, all of them.
(define bacnet-prop-object-identifier          75)
(define bacnet-prop-system-status             112)
(define bacnet-prop-vendor-identifier         120)
(define bacnet-prop-firmware-revision          44)
(define bacnet-prop-application-software-ver   12)
(define bacnet-prop-protocol-version           98)
(define bacnet-prop-protocol-revision         139)
(define bacnet-prop-protocol-services-supported 97)
(define bacnet-prop-protocol-object-types-supported 96)
(define bacnet-prop-max-apdu-length-accepted   62)
(define bacnet-prop-segmentation-supported    107)
(define bacnet-prop-apdu-timeout               11)
(define bacnet-prop-number-of-apdu-retries     73)
(define bacnet-prop-device-address-binding     30)
(define bacnet-prop-database-revision         155)

(define bacnet-segmentation-none 3)     ;;;!< SEGMENTED_NONE; we do not segment, so say so
(define bacnet-max-apdu 1476)           ;;;!< matches the 0x05 we send in every confirmed request

;;; A device is (list 'bacnet-device instance alist).  FOUR of these properties are load-bearing
;;; for DM-DDB-B because they are what an I-Am actually carries -- object-identifier,
;;; max-apdu-length-accepted, segmentation-supported, vendor-identifier.  The rest are RECORDED so
;;; the object is complete and so DS-RP-B has something to serve; until that exists they are
;;; declared, not readable over the wire, and this comment is the difference between the two.
(define (bacnet-make-device instance name . opt)
  (let ((vendor-id   (if (pair? opt) (car opt) 0))
        (vendor-name (if (and (pair? opt) (pair? (cdr opt))) (cadr opt) "Frobenius Norm LLC")))
    (list 'bacnet-device instance
          (list (cons bacnet-prop-object-identifier (list 'objid (bacnet-objid bacnet-object-device instance)))
                (cons bacnet-prop-object-name name)
                (cons bacnet-prop-object-type (list 'enumerated bacnet-object-device))
                (cons bacnet-prop-system-status (list 'enumerated 0))     ;;;!< OPERATIONAL
                (cons bacnet-prop-vendor-name vendor-name)
                (cons bacnet-prop-vendor-identifier vendor-id)
                (cons bacnet-prop-model-name "LambLisp")
                (cons bacnet-prop-firmware-revision "1")
                (cons bacnet-prop-application-software-ver "1")
                (cons bacnet-prop-protocol-version 1)
                (cons bacnet-prop-protocol-revision 14)
                (cons bacnet-prop-max-apdu-length-accepted bacnet-max-apdu)
                (cons bacnet-prop-segmentation-supported (list 'enumerated bacnet-segmentation-none))
                (cons bacnet-prop-apdu-timeout 3000)
                (cons bacnet-prop-number-of-apdu-retries 3)
                (cons bacnet-prop-database-revision 1)
                ;;;!< object-list holds only the Device object itself: this node has no other
                ;;;!< objects, and listing ones it does not have is the claim-without-a-thing
                ;;;!< failure this whole file carries a warning about.
                (cons bacnet-prop-object-list
                      (list (list 'objid (bacnet-objid bacnet-object-device instance))))))))

(define (bacnet-device-instance dev) (cadr dev))
(define (bacnet-device-props dev)    (car (cddr dev)))

(define (bacnet-device-prop dev propid)
  (let ((p (assv propid (bacnet-device-props dev))))
    (if (pair? p) (cdr p) #f)))

(define (bacnet-device-set-prop! dev propid value)
  (let ((p (assv propid (bacnet-device-props dev))))
    (if (pair? p)
        (begin (set-cdr! p value) #t)
        #f)))

;;; I-Am: unconfirmed service 0, four application-tagged values in a fixed order.  Broadcast.
(define (bacnet-encode-i-am dev)
  (let ((objid  (bacnet-objid bacnet-object-device (bacnet-device-instance dev)))
        (vendor (bacnet-device-prop dev bacnet-prop-vendor-identifier))
        (maxapdu (bacnet-device-prop dev bacnet-prop-max-apdu-length-accepted))
        (seg    (bacnet-device-prop dev bacnet-prop-segmentation-supported)))
    (bacnet-frame bacnet-bvlc-broadcast #x00
      (bytevector-append (bytevector #x10 #x00)
                         (bytevector #xc4) (struct-pack ">I" objid)
                         (bacnet-app-value (list 'unsigned maxapdu))
                         (bacnet-app-value seg)
                         (bacnet-app-value (list 'unsigned vendor))))))

;;; Read a CONTEXT-tagged unsigned at `off`.  Returns (value . next), or #f if the tag there is
;;; not context `number`.  Who-Is carries its range this way and nothing else in this file needs it.
(define (bacnet-context-uint-at bv off number)
  (if (>= off (bytevector-length bv))
      #f
      (let* ((tag (bytevector-u8-ref bv off))
             (num (arithmetic-shift tag -4))
             (cls (bitwise-and tag #x08))
             (len (bitwise-and tag #x07)))
        (if (or (not (= num number)) (= cls 0) (= len 0) (> len 4))
            #f
            (cons (bacnet-uint-at bv (+ off 1) len) (+ off 1 len))))))

;;; Decode a Who-Is.  Returns 'all, or (low high), or #f if this frame is not a Who-Is.
;;; THE RANGE IS THE WHOLE POINT OF THE B SIDE: a workstation scanning a large site sends Who-Is
;;; in instance BANDS so every device does not answer at once.  Answering outside our band is a
;;; broadcast storm we caused, so the range is honoured rather than ignored.
(define (bacnet-decode-who-is bv)
  (let ((start (bacnet-apdu-start bv)))
    (if (or (not start)
            (<= (bytevector-length bv) (+ start 1))
            (not (= (bytevector-u8-ref bv start) #x10))
            (not (= (bytevector-u8-ref bv (+ start 1)) #x08)))
        #f
        (let ((lo (bacnet-context-uint-at bv (+ start 2) 0)))
          (if (not lo)
              'all                                  ;;;!< no range = every device answers
              (let ((hi (bacnet-context-uint-at bv (cdr lo) 1)))
                (if (not hi) 'all (list (car lo) (car hi)))))))))

(define (bacnet-who-is-selects? range instance)
  (cond ((eq? range 'all) #t)
        ((pair? range) (and (>= instance (car range)) (<= instance (cadr range))))
        (else #f)))

;;;;;;;;;;;;;;;;;;;;;;;; DS-RP-B: serving a ReadProperty ;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; This is what turns the node from "discoverable" into something with a DEVICE PROFILE.  Every
;;; standard profile -- B-SS, B-SA, B-ASC -- requires DS-RP-B, because a device whose properties
;;; cannot be read is of no use to the workstation that just discovered it.
;;;
;;; A ComplexACK IS UNICAST, unlike the I-Am.  So an answer now has to say WHERE it goes, and
;;; `bacnet-device-answer` returns (frame destination) with destination 'broadcast or 'unicast
;;; rather than a bare frame.  That is why `udp-recv-from` had to be added to the runtime: a
;;; confirmed-service response goes back to the originator, and `udp-recv` discards the sender.

(define bacnet-error-class-object    1)
(define bacnet-error-class-property  2)
(define bacnet-error-code-unknown-object   31)
(define bacnet-error-code-unknown-property 32)

;;; Decode a ConfirmedRequest ReadProperty.  Returns (invoke-id objid propid), or #f.
;;; An optional array index (context 2) is IGNORED rather than mishandled -- see the note on the
;;; answer function; a device that silently drops the index would answer the wrong question.
(define (bacnet-decode-read-request bv)
  (let ((start (bacnet-apdu-start bv))
        (n (bytevector-length bv)))
    (if (or (not start) (>= (+ start 3) n)
            (not (= (bytevector-u8-ref bv start) #x00))        ;;;!< ConfirmedRequest, unsegmented
            (not (= (bytevector-u8-ref bv (+ start 3)) #x0c)))  ;;;!< service 12 = readProperty
        #f
        (let ((invoke (bytevector-u8-ref bv (+ start 2)))
              (o (bacnet-context-objid-at bv (+ start 4) 0)))
          (if (not o)
              #f
              (let ((pr (bacnet-context-uint-at bv (cdr o) 1)))
                (if (not pr) #f (list invoke (car o) (car pr) (cdr pr)))))))))

;;; A context-tagged object identifier at `off`: (objid . next) or #f.
(define (bacnet-context-objid-at bv off number)
  (let ((t (bacnet-tag-at bv off)))
    (if (or (not t) (not (cadr t)) (not (= (car t) number)) (not (= (car (cddr t)) 4))
            (> (+ (cadr (cddr t)) 4) (bytevector-length bv)))
        #f
        (cons (car (struct-unpack ">I" bv (cadr (cddr t)))) (+ (cadr (cddr t)) 4)))))

;;; ComplexACK for ReadProperty: 30 <invoke> 0C, the object and property echoed back, then the
;;; value between an opening and closing tag 3.  Echoing them is not decoration -- the requester
;;; matches the answer to its question with them.
(define (bacnet-encode-read-ack invoke objid propid value)
  (bacnet-frame bacnet-bvlc-unicast #x00
    (bytevector-append (bytevector #x30 (bitwise-and invoke #xff) #x0c)
                       (bacnet-context-objid 0 objid)
                       (bacnet-context-uint 1 propid)
                       (bacnet-open-tag 3)
                       (bacnet-app-value value)
                       (bacnet-close-tag 3))))

;;; Error-PDU: 50 <invoke> <service>, then class and code as application-tagged enumerated.
;;; ANSWERING "I DO NOT HAVE THAT" IS PART OF THE OBLIGATION.  A device that stays silent on an
;;; unknown property makes the requester wait out its timeout and retry, three times, and then
;;; report the device as offline -- so silence costs more than an error does.
(define (bacnet-encode-error invoke service class code)
  (bacnet-frame bacnet-bvlc-unicast #x00
    (bytevector-append (bytevector #x50 (bitwise-and invoke #xff) service)
                       (bacnet-app-value (list 'enumerated class))
                       (bacnet-app-value (list 'enumerated code)))))

;;; DS-RP-B.  Returns (frame 'unicast), or #f if this is not a ReadProperty for us.
;;;
;;; AN ARRAY INDEX IS REFUSED, NOT IGNORED.  `object-list` is an array, and a request for element
;;; N of it is a different question from "the whole array".  Answering the whole thing to a request
;;; for element 3 is a WRONG ANSWER that looks like a right one, which is worse than an error; the
;;; standard has an error code for exactly this and we send it until the array form is implemented.
(define (bacnet-device-answer-read dev bv)
  (let ((r (bacnet-decode-read-request bv)))
    (if (not r)
        #f
        (let* ((invoke (car r))
               (objid  (cadr r))
               (propid (car (cddr r)))
               (rest   (cadr (cddr r)))
               (mine   (bacnet-objid bacnet-object-device (bacnet-device-instance dev)))
               (index  (bacnet-context-uint-at bv rest 2)))
          (cond
            ((not (= objid mine))
             (list (bacnet-encode-error invoke #x0c bacnet-error-class-object
                                        bacnet-error-code-unknown-object) 'unicast))
            (index
             (list (bacnet-encode-error invoke #x0c bacnet-error-class-property
                                        bacnet-error-code-unknown-property) 'unicast))
            (else
             (let ((v (bacnet-device-prop dev propid)))
               (if v
                   (list (bacnet-encode-read-ack invoke objid propid v) 'unicast)
                   (list (bacnet-encode-error invoke #x0c bacnet-error-class-property
                                              bacnet-error-code-unknown-property) 'unicast)))))))))

;;; THE WHOLE OF DM-DDB-B, AND IT IS PURE ON PURPOSE.  Given a device and a received datagram it
;;; returns the frame to broadcast, or #f for "nothing to say".  No socket, so the obligation can
;;; be tested without a network -- which is the only way the range filtering gets exercised at all.

;;; ---- [P109] DS-WP-B: the half that lets something WRITE to us ---------------------------------
;;;
;;; WHY IT COMPLETES A PAIR RATHER THAN ADDING A FEATURE.  DS-RP-B above made this node readable; a
;;; workstation could find it (DM-DDB-B) and interrogate it.  It still could not CHANGE anything, so
;;; every integration was one-way and the file's own "STILL ABSENT" list opened with
;;; "DS-WP-B (nothing can write to us)".  With this, the Device object's properties are writable by
;;; the same peer that can read them, which is what B-SA requires beyond B-SS.
;;;
;;; AN UNKNOWN PROPERTY IS REFUSED, NOT CREATED.  `bacnet-device-set-prop!` returns #f when the
;;; property is not already in the store, and that #f becomes an Error-PDU rather than a new alist
;;; entry.  A device that silently invents a property it was asked to write would answer the NEXT
;;; ReadProperty for it with a value no object model ever declared -- conformant-looking and wrong.
;;; The same reasoning as the array-index refusal in DS-RP-B: answering "I do not have that" is part
;;; of the obligation.

;;!(bacnet-decode-write-request bv) -> (invoke objid propid value) | #f
;;!
;;!VALIDATED TO THE CLOSING TAG.  The value sits between an opening context tag 3 (#x3e) and its
;;!closing partner (#x3f), and BOTH are checked: a frame that opens the wrapper and runs off the end
;;!would otherwise decode as a legitimate write of whatever `decode-app-value` made of the remainder.
;;!UDP is connectionless, so anything on the network can send that.
(define (bacnet-decode-write-request bv)
  (let ((start (bacnet-apdu-start bv))
        (n (bytevector-length bv)))
    (if (or (not start) (>= (+ start 3) n)
            (not (= (bytevector-u8-ref bv start) #x00))          ;;;!< ConfirmedRequest, unsegmented
            (not (= (bytevector-u8-ref bv (+ start 3)) #x0f)))    ;;;!< service 15 = writeProperty
        #f
        (let ((invoke (bytevector-u8-ref bv (+ start 2)))
              (o (bacnet-context-objid-at bv (+ start 4) 0)))
          (if (not o)
              #f
              (let ((pr (bacnet-context-uint-at bv (cdr o) 1)))
                (if (not pr)
                    #f
                    (let ((open (cdr pr)))
                      (if (or (>= open n) (not (= (bytevector-u8-ref bv open) #x3e)))
                          #f
                          (let ((v (bacnet-decode-app-value bv (+ open 1))))
                            (if (or (not v) (>= (cdr v) n)
                                    (not (= (bytevector-u8-ref bv (cdr v)) #x3f)))
                                #f
                                (list invoke (car o) (car pr) (car v)))))))))))))

;;!SimpleACK (PDU type 2): the entire body is three bytes -- type, invoke id, service choice.
;;!Control byte #x00, not #x04: this is a REPLY, and #x04 means "expecting a reply".
(define (bacnet-encode-simple-ack invoke service)
  (bacnet-frame bacnet-bvlc-unicast #x00
    (bytevector #x20 (bitwise-and invoke #xff) (bitwise-and service #xff))))

;;; DS-WP-B.  Returns (frame 'unicast), or #f if this is not a WriteProperty for us.
(define (bacnet-device-answer-write dev bv)
  (let ((r (bacnet-decode-write-request bv)))
    (if (not r)
        #f
        (let* ((invoke (car r))
               (objid  (cadr r))
               (propid (car (cddr r)))
               (value  (cadr (cddr r)))
               (mine   (bacnet-objid bacnet-object-device (bacnet-device-instance dev))))
          (cond
            ((not (= objid mine))
             (list (bacnet-encode-error invoke #x0f bacnet-error-class-object
                                        bacnet-error-code-unknown-object) 'unicast))
            ((not (bacnet-device-set-prop! dev propid value))
             (list (bacnet-encode-error invoke #x0f bacnet-error-class-property
                                        bacnet-error-code-unknown-property) 'unicast))
            (else
             (list (bacnet-encode-simple-ack invoke #x0f) 'unicast)))))))

(define (bacnet-device-answer dev bv)
  (let ((range (bacnet-decode-who-is bv)))
    (if (and range (bacnet-who-is-selects? range (bacnet-device-instance dev)))
        (list (bacnet-encode-i-am dev) 'broadcast)     ;;;!< I-Am goes to everyone, by design
        (let ((rd (bacnet-device-answer-read dev bv)))  ;;;!< a ComplexACK goes back to the asker
          (if rd rd (bacnet-device-answer-write dev bv))))))  ;;;!< [P109] then DS-WP-B

;;; Service one datagram: receive, answer, and send the answer WHERE IT BELONGS.
;;; Returns #t if we answered, #f otherwise.  Call it from the application loop -- a BACnet node
;;; that only answers when someone remembers to poll it is not discoverable, and "discoverable" is
;;; the entire content of DM-DDB-B.
;;;
;;; `udp-recv-from` rather than `udp-recv`: a ComplexACK must go back to the originator, so the
;;; sender's address is not optional here.  An I-Am still broadcasts.
(define (bacnet-device-poll dev s bcast . opt)
  (let* ((timeout (if (pair? opt) (car opt) 100))
         (sock (car s))
         (msg (udp-recv-from sock bacnet-recv-max timeout)))
    (if (not msg)
        #f
        (let* ((frame (car msg))
               (peer  (cadr msg))
               (pport (car (cddr msg)))
               (ans   (bacnet-device-answer dev frame)))
          (if (not ans)
              #f
              (begin
                ;;;!< A UNICAST REPLY GOES TO THE SENDER'S PORT, not to 47808.  On a real site
                ;;;!< every device binds 47808 so the two coincide and the mistake is invisible;
                ;;;!< a test client, a second node on one host, or anything behind NAT binds
                ;;;!< something else, and then the answer is sent to a port nobody is reading.
                ;;;!< The broadcast arm keeps 47808 because that is where listeners are.
                (if (eq? (cadr ans) 'broadcast)
                    (udp-send sock bcast bacnet-port (car ans))
                    (udp-send sock peer pport (car ans)))
                #t))))))

(syslog "BACnet/IP ready (A-side: DM-DDB-A DS-RP-A DS-WP-A; B-side: DM-DDB-B)\n")
