;;; Copyright 2026 by Frobenius Norm LLC 2026-09-30
;;; llloader-vocab.scm -- the LLIP frame vocabulary for the OTA LOADER.  [P253] phase 1.
;;;
;;; A SIBLING OF llip-frame.scm, NOT PART OF IT (owner, 2026-09-30).  The robot-control vocabulary
;;; and a bootloader's have no reason to version together, and coupling them means a move-program
;;; change can invalidate a generated C header INSIDE THE TRUSTED ROOT.  Two files, one generator.
;;;
;;; PURE DATA, like llip-frame.scm: no OTA calls here, so it loads and validates on any LambLisp
;;; including the host.  The executor is the loader's C, which this file never touches.
;;;
;;; THE LOADER PARSES A DELIBERATELY SMALLER GRAMMAR THAN LLIP AS A WHOLE.  It needs the frames
;;; addressed to it, not the language -- and the limits below are the security argument made
;;; STRUCTURAL rather than promised: no general strings (the only string form is exactly 64 hex, a
;;; sha256, so a literal cannot carry a payload), a fixed depth of 2 (no stack, no recursion), and a
;;; bounded frame (nothing to exhaust).  See [P253] for why the surface is smaller than the HTTP
;;; client the loader already runs.
;;;
;;; NO MANIFEST NAMES THIS FILE, AND THAT IS DELIBERATE -- NOT AN OMISSION.  Its consumer is the
;;; LOADER's C, via the generated `w3_loader/src/llloader_llip_vocab.h`; the loader is a separate
;;; ESP-IDF project with no LambLisp and no filesystem image, so there is nothing for a `data/`
;;; entry to serve.  `llip-frame.scm` rides `Freenove-4WD-Car-Kit-ESP32.manifest` because a
;;; LambLisp on that board reads it at runtime.  If a LambLisp node ever needs to SPEAK these
;;; frames rather than have them compiled in, add it to that node's manifest then -- and say
;;; which node, because "shipped to every target" is how a vocabulary acquires consumers nobody
;;; can enumerate.
;;;
;;; GENERATED CONSUMER: `python3 w3_ai_scripts/llip_vocab_gen.py --write` (`--check` in
;;; `verify_truth.sh` section 29 keeps it honest).  Editing the header instead of this file is
;;; the mistake the DO-NOT-EDIT banner exists to stop; the generator's `--check` is what makes
;;; the banner more than a request.

;;; --- the loader's own actions.  THESE ARE `loader_action_t` IN w3_loader/src/llloader_main.c,
;;; IN ORDER, AND THE ORDER IS THE WIRE VALUE: normal=0 install=1 recover=2 console=3, which is
;;; what the VM writes into NVS `pending_update` via (ota-request-install!) and friends.
;;;
;;; [B716] `llip_vocab_gen.py --check` PARSES THAT ENUM AND REFUSES IF THIS LIST DISAGREES, because
;;; the first version of this list read `(install recover boot verify golden)` -- taken from prose
;;; in the loader's comments instead of from the enum.  `golden` is the want_golden FLAG, `boot` and
;;; `verify` are steps inside an install, `normal` was missing, and so was `console`: the loader's
;;; ONLY triggered mode and the fall-through for every failed path, i.e. the one value an
;;; (ota-state) reply most needs to be able to name.  The generator turned that misreading into a C
;;; enum inside the trusted root without complaint -- a generated consumer that matches a wrong
;;; source is as wrong as a hand-copied one, and more convincing.
;;;
;;; TWO CHECKS, BECAUSE NEITHER SEES THE OTHER'S HALF: the generator compares the NAMES and their
;;; order; the host suite (w3_loader/test) asserts the NUMBERS (normal==0 ... console==3).  A
;;; reorder made consistently in BOTH files passes the name check and silently renumbers the wire
;;; protocol, so a request for RECOVER would arrive as INSTALL -- measured, and the suite catches
;;; exactly that.  Add an action here and in the enum, and the checks will tell you if you did one.
(define llloader-actions  '(normal install recover console))

;;; --- the OTA source ladder.  THESE ARE THE `image_source_t.name` STRINGS THE RUNGS ASSIGN,
;;; in ladder order, NOT the words source_ladder.c's header comment uses.  `llip_vocab_gen.py
;;; --check` greps w3_loader/src/ for each one and refuses if any is unspelled.
;;;
;;; [B719] The first version read `(aux-fs http ble console)` -- taken from that header comment
;;; ("1. aux-storage / 2. network / 3. BLE / UART") instead of from the assignments, so three of
;;; the four were wrong.  Caught at the moment of FIRST USE, emitting `(rung ...)` in a reply:
;;; the name would have gone on the wire absent from the generated `llloader_rung_t`, and the
;;; reader could not have caught it -- it validates that a value IS a symbol, not that the symbol
;;; is a member of this list.
;;;
;;; AND IT WAS [B716] A SECOND TIME.  That entry was this same defect in `llloader-actions`, fixed
;;; four hours earlier by checking ACTIONS and stopping there -- the site, not the class.  Three
;;; lists in this file describe code; `llloader-slots` was audited at the same time and is correct.
(define llloader-rungs    '(aux-fs network ble-console console-uart))

;;; --- partition slots a frame may name ---
;;; `factory` IS A SLOT A FRAME MAY NAME, and it was missing: `(ota-status ... (slot factory))` is
;;; the normal answer, because a unit that can answer a query is BY DEFINITION running the loader out
;;; of the factory slot.  Without it the one reply step C exists to send could not name where it came
;;; from. ([P253] step C, 2026-10-03)
(define llloader-slots    '(factory ota_0 ota_1))

;;; --- the loader<->VM NVS contract, namespace "ota-p125".  [P255] phase 0.
;;;
;;; ONE HOME FOR THE KEY NAMES AND THEIR TYPES.  Both ends of a reboot boundary read these: the VM
;;; writes them (src/ll_xmop3_OTA.cpp) and the factory loader reads them (w3_loader/src).  A key
;;; name misspelt on one side is not an error anywhere -- `nvs_get_*` simply returns NOT_FOUND and
;;; the reader takes its default, so the handshake silently degrades to "nothing pending".  Hence
;;; the names live here and are generated into a header for each side.
;;;
;;; `death_reason` IS A SYMBOL, NOT FREE TEXT, and its bound is llloader-max-symbol: the loader
;;; relays it inside an `ota-death` frame, and that frame has to satisfy the same grammar as every
;;; other.  The application chooses its own failure vocabulary -- the loader never interprets a
;;; reason, only carries it -- so a new reason needs no change in the trusted root.
(define llloader-nvs-keys
  '((pending_update u8)     ;;; the requested action; one of llloader-actions, by INDEX
    (install_tries  u8)     ;;; loader-owned anti-loop counter
    (death_reason   str)    ;;; [P255] why the VM declared itself dead; symbol, <= llloader-max-symbol
    (death_count    u8)))   ;;; [P255] deaths since the last (ota-boot-ok!)

;;; --- grammar limits.  The loader REFUSES anything outside these, before acting. ---
(define llloader-max-frame-bytes 512)   ;;; whole frame
(define llloader-max-fields      12)    ;;; (key value) pairs per frame
(define llloader-max-depth       2)     ;;; frame -> field.  Fixed: no recursion in the reader.
(define llloader-max-symbol      24)    ;;; bytes
(define llloader-sha256-hex      64)    ;;; exactly; the ONLY string form accepted

;;; --- frames.  (tag (key value) ...), the shape llip-frame.scm already uses. ---
;;; SEQ 0 MEANS UNSOLICITED.  A reply to a query echoes that query's `seq`; a frame the loader
;;; emits on its own -- progress during an install, a result, a death record at boot -- has no
;;; request to echo and carries 0.  Decided when the reply-only path was built, because the
;;; alternative (a per-boot counter) makes an unsolicited frame indistinguishable from an answer to
;;; someone's question, and a reader acting on the wrong one is a worse failure than losing the
;;; ability to order progress frames -- which `bytes`/`of` already give.
;;;
;;; `query` frames are READ-ONLY and answerable before authentication if the owner allows it
;;; ([P253] open question 2); `command` frames set the pending action the loader already reads
;;; from NVS, and require an authenticated session.
(define llloader-frames
  '((ota-state   query   (seq))
    (ota-ladder  query   (seq))
    (ota-install command (seq slot size sha256 golden))
    (ota-recover command (seq golden))
    (ota-ack     reply   (seq accepted pending reason))
    (ota-result  reply   (seq rung digest action slot))
    (ota-progress reply  (seq rung bytes of))
    (ota-death   reply   (seq reason count))      ;;; [P255] why this unit is in the loader
    ;;; --- [P253] step C: the answers to the two queries.  Added 2026-10-03.
    ;;; `ota-status` answers `(ota-state)`: this unit's whole condition in one frame -- where it is
    ;;; running, what it thinks of ota_0, what action is pending, how many install attempts it has
    ;;; spent, and the death record that explains why it is here at all.  ONE frame rather than
    ;;; several because the fields are only meaningful together: `tries 3` is alarming beside
    ;;; `image absent` and unremarkable beside `image valid`.
    (ota-status  reply   (seq slot image pending tries reason count))
    ;;; `ota-rung` answers `(ota-ladder)`: ONE FRAME PER RUNG, in priority order.  The flat grammar
    ;;; has no list value (depth 2, scalar fields), so a single frame cannot carry four rung names --
    ;;; and repeating a frame is already how `ota-progress` reports a sequence, so this needs no new
    ;;; reader behaviour.
    ;;; IT REPORTS `order`, NOT `available`, AND THAT IS DELIBERATE.  Availability cannot be answered
    ;;; honestly without OPENING each rung, and opening the console rung starts a 300 s wait -- so an
    ;;; `available` field would either lie or have side effects.  The ladder's ORDER is static, known
    ;;; at compile time, and is the thing an operator actually needs: it says what this build will
    ;;; try and in what sequence.
    (ota-rung    reply   (seq rung order))))

;;; --- field types, so a generator can emit a C table and a validator can check one ---
(define llloader-field-types
  '((seq      integer)
    (slot     symbol)      ;;; one-of llloader-slots
    (size     integer)
    (sha256   hex)         ;;; exactly llloader-sha256-hex chars
    (golden   boolean)
    (accepted boolean)
    (pending  symbol)      ;;; one-of llloader-actions (`normal` IS the "nothing pending" value)
    (reason   symbol)
    (rung     symbol)      ;;; one-of llloader-rungs
    (digest   symbol)      ;;; ok | mismatch | absent
    (action   symbol)      ;;; one-of llloader-actions, or `refused`
    (bytes    integer)
    (of       integer)
    (count    integer)     ;;; [P255] death_count
    ;;; --- [P253] step C additions, 2026-10-03
    (image    symbol)      ;;; ota_0's OTA state as the loader sees it: valid | undefined | absent
    (tries    integer)     ;;; install_tries -- the loader's anti-loop counter ([B724])
    (order    integer)))   ;;; 1-based position of a rung in the ladder
