// Copyright 2026 by Frobenius Norm LLC 2026-10-03
// llloader_query.h -- [P253] step C: the answers to the loader's two read-only queries.
//
// WHY THIS IS A SEPARATE MODULE AND NOT A BRANCH IN src_console.c: everything here is PURE.  It
// takes a parsed query frame plus a snapshot of the unit's condition and returns the frames to send.
// No NVS, no UART, no esp_* call -- so the POLICY (which query is answered, with which fields, in
// what order) is testable on a laptop, and only the GATHERING of the snapshot needs a board.  The
// loader's whole reason for existing is to work when nothing else does; the part of it that can be
// refuted without hardware should be as large as possible.
//
// THE OWNER'S RULING ([P253] Q2, 2026-09-30): both queries are answered PRE-AUTHENTICATION, on the
// UART ONLY.  No auth branch in the trusted root and no split between the two queries.
//
// "UART ONLY" IS CURRENTLY FREE AND MUST STILL BE WRITTEN DOWN.  `src_ble_console.c` declares two
// characteristics, both WRITE-only, and contains zero occurrences of NOTIFY or READ -- the radio
// physically cannot carry a reply today.  So the constraint costs nothing to honour now, which is
// precisely why it is recorded: the day someone adds a NOTIFY characteristic it becomes a rule to
// obey rather than a fact about the hardware.
#ifndef LLLOADER_QUERY_H
#define LLLOADER_QUERY_H

#include "llloader_llip.h"

//! The unit's condition at the moment a query is answered.  Every member is a value the caller has
//! ALREADY read; this module never goes looking, so a test can state a condition that no board on
//! the bench happens to be in.
typedef struct {
    const char *slot;      //!< running slot: `factory` in practice -- a unit answering a query is
                           //!< by definition running the loader.
    const char *image;     //!< ota_0 as the loader sees it: `valid` | `undefined` | `absent`.
    const char *pending;   //!< pending action: `normal` | `install` | `recover` | `console`.
    int32_t     tries;     //!< install_tries, the anti-loop counter ([B724]).
    const char *reason;    //!< death reason, or `none` when there is no record ([P255]).
    int32_t     count;     //!< death count.
} llloader_status_t;

/*! Who can describe this unit.  The typedef lives here, with the struct it fills, so the pure
    scanner below can CALL it rather than be handed a snapshot -- see llloader_rx_feed(). */
typedef void (*llloader_status_fn)(llloader_status_t *out);

//! Most frames one query can produce: `(ota-ladder)` answers with one `(ota-rung ...)` per rung.
#define LLLOADER_QUERY_MAX_REPLIES LLLOADER_RUNG_COUNT

/*! Build the reply frames for a parsed query.

    Returns the number of frames written into `out`, 0 if `in` is not a query this answers, or -1 if
    a frame could not be built (which the caller must report rather than send a truncated frame).

    `seq` IS ECHOED FROM THE QUERY, NOT INVENTED.  An unsolicited frame uses seq 0; a reply carries
    the asker's number, so a reader with two questions outstanding can tell the answers apart.  That
    is the whole reason the field exists and it is the one thing a reply must not get wrong. */
int llloader_query_reply(const llloader_frame_in_t *in, const llloader_status_t *st,
                         char out[][LLLOADER_MAX_FRAME_BYTES], int max_out);

/*! --- the RX scanner: one byte in, one decision out ---

    WHY THIS IS HERE AND NOT IN src_console.c.  The console rung must do two things with the same
    byte stream: watch for the `LLIM` image magic, and answer `(ota-...)` queries that arrive while
    it waits.  The RULE between them -- **the image always wins RX** -- is the single most
    consequential line in [P253] ("a listener that silently eats an image push is the worst outcome
    in this proposal"), and while it lived inside a loop wrapped around `uart_read_bytes()` the only
    way to test it was to flash a board and push both at once.

    Moved here it is a pure state machine: feed it bytes, read the events.  So the interleaving, the
    partial-magic backtrack, the paren counting and the discard-don't-parse rule are all host arms.
    Only `uart_read_bytes` / `uart_write_bytes` stay on the IDF side of the boundary. */
typedef enum {
    LLLOADER_RX_NEED_MORE = 0,  //!< nothing decided yet; keep feeding
    LLLOADER_RX_MAGIC,          //!< the 4 magic bytes completed -- the caller reads the header next
    LLLOADER_RX_REPLY,          //!< a query completed and produced frames to send
    LLLOADER_RX_BAD_QUERY,      //!< a `( ... )` line arrived and was NOT a frame; nothing to send
} llloader_rx_ev_t;

typedef struct {
    char win[4];                             //!< sliding window of the last 4 bytes (see rx_feed)
    long seen;                               //!< bytes fed, so a short stream cannot false-match
    int  len;                                //!< bytes buffered in `line`
    int  depth;                              //!< paren depth of the line being buffered
    int  skipped;                            //!< bytes discarded while hunting the magic
    int  qbytes;                             //!< bytes that went to the query buffer
    char line[LLLOADER_MAX_FRAME_BYTES];
    //! Set when the event is LLLOADER_RX_REPLY / BAD_QUERY.
    int  nreplies;
    llloader_llip_err_t why;                 //!< why a BAD_QUERY was rejected, for the log
    char replies[LLLOADER_QUERY_MAX_REPLIES][LLLOADER_MAX_FRAME_BYTES];
} llloader_rx_t;

//! Zero `rx` before the first byte.  `magic` is the 4-byte image magic (CON_MAGIC).
void llloader_rx_init(llloader_rx_t *rx);

/*! Feed one received byte.  `st` may be NULL (then `(ota-state)` is refused rather than answered).

    THE ORDER INSIDE IS THE GUARANTEE: the byte is offered to the magic matcher first, and only
    reaches the query buffer if it could not continue the magic.  That is why an image push cannot
    be eaten by the query path -- it is structural, not a matter of care. */
/*! IT TAKES THE PROVIDER, NOT A SNAPSHOT, AND THAT IS A BUG FIX NOT A STYLE CHOICE.
    The first version took `const llloader_status_t *`, which forced the caller to BUILD a snapshot
    before every byte -- and src_console.c duly did: an NVS open, two `nvs_get_*`, an
    `esp_partition_find_first` and an `esp_ota_get_state_partition` PER RECEIVED BYTE.  During a
    1.8 MB image push that is millions of NVS transactions interleaved with the flash writes the
    image itself is making, which is the [B644] contention shape exactly.
    Passing the function means it is called ONCE, when a frame has actually completed and only if
    that frame needs it -- `(ota-ladder)` needs no status at all.  `fn` may be NULL. */
llloader_rx_ev_t llloader_rx_feed(llloader_rx_t *rx, char b, const char *magic,
                                  llloader_status_fn fn);

#endif // LLLOADER_QUERY_H
