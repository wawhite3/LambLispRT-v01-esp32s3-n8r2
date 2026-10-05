// Copyright 2026 by Frobenius Norm LLC 2026-10-03
// llloader_query.c -- [P253] step C: answer `(ota-state)` and `(ota-ladder)`.  See the header for
// why this is pure and for the owner's pre-auth / UART-only ruling.
#include "llloader_query.h"

#include <string.h>

//! Field indices are POSITIONAL, parallel to the generated `llloader_fields_*` arrays, which is the
//! contract `llloader_frame_in_t` already uses.  Naming them here rather than writing 0..6 at the
//! call sites means a vocabulary reorder breaks the build at ONE place instead of silently swapping
//! two same-typed fields -- `tries` and `count` are both integers, so a swap would compile, run,
//! and report a death count as an install counter.
enum { Q_SEQ = 0 };                                            //!< ota-state / ota-ladder: (seq)
enum { S_SEQ = 0, S_SLOT, S_IMAGE, S_PENDING, S_TRIES, S_REASON, S_COUNT };  //!< ota-status
enum { R_SEQ = 0, R_RUNG, R_ORDER };                           //!< ota-rung

/*! `(ota-status (seq N) (slot S) (image I) (pending P) (tries T) (reason R) (count C))`
    ONE frame, not several, because the fields are only meaningful together: `tries 3` is alarming
    beside `image absent` and unremarkable beside `image valid`. */
static int reply_status(int32_t seq, const llloader_status_t *st,
                        char out[][LLLOADER_MAX_FRAME_BYTES])
{
    llloader_wr_t w;
    llloader_wr_begin(&w, out[0], LLLOADER_MAX_FRAME_BYTES, "ota-status");
    llloader_wr_int(&w, "seq",     seq);
    llloader_wr_sym(&w, "slot",    st->slot);
    llloader_wr_sym(&w, "image",   st->image);
    llloader_wr_sym(&w, "pending", st->pending);
    llloader_wr_int(&w, "tries",   st->tries);
    llloader_wr_sym(&w, "reason",  st->reason);
    llloader_wr_int(&w, "count",   st->count);
    return (llloader_wr_end(&w) > 0) ? 1 : -1;
}

/*! `(ota-rung (seq N) (rung R) (order K))` x LLLOADER_RUNG_COUNT, in ladder order.

    ONE FRAME PER RUNG because the grammar has no list value, and repeating a frame is already how
    `(ota-progress ...)` reports a sequence -- so this needs no new reader behaviour.

    IT REPORTS `order`, NOT `available`.  Availability cannot be answered honestly without OPENING
    each rung, and opening the console rung starts a 300 s wait -- an `available` field would
    therefore either lie or have side effects.  `order` is static, known at compile time, and is
    what an operator actually needs: what this build will try, and in what sequence. */
static int reply_ladder(int32_t seq, char out[][LLLOADER_MAX_FRAME_BYTES], int max_out)
{
    int n = 0;
    for (int r = 0; r < (int) LLLOADER_RUNG_COUNT; r++) {
        if (n >= max_out) {
            //! REFUSE RATHER THAN TRUNCATE.  A partial ladder is a WRONG answer, not a short one:
            //! a reader that receives three of four rungs has been told this build lacks the
            //! fourth.  Better no answer and a log line the operator can see.
            return -1;
        }
        llloader_wr_t w;
        llloader_wr_begin(&w, out[n], LLLOADER_MAX_FRAME_BYTES, "ota-rung");
        llloader_wr_int(&w, "seq",   seq);
        llloader_wr_sym(&w, "rung",  llloader_rung_t_names[r]);
        llloader_wr_int(&w, "order", r + 1);        //!< 1-based: `order 1` is tried first
        if (llloader_wr_end(&w) <= 0) return -1;
        n++;
    }
    return n;
}

int llloader_query_reply(const llloader_frame_in_t *in, const llloader_status_t *st,
                         char out[][LLLOADER_MAX_FRAME_BYTES], int max_out)
{
    if (in == NULL || out == NULL || max_out <= 0) return -1;

    //! COMPARE BY TAG INDEX, NOT BY STRING.  `llloader_llip_frame_by_tag()` is the generated
    //! lookup; resolving the two tags here means a renamed frame fails to RESOLVE (and this
    //! returns 0, answering nothing) rather than silently never matching a hardcoded literal.
    const size_t i_state  = llloader_llip_frame_by_tag("ota-state");
    const size_t i_ladder = llloader_llip_frame_by_tag("ota-ladder");

    const int32_t seq = in->v[Q_SEQ].i;

    if (in->frame == i_state && i_state != LLLOADER_NFRAMES) {
        if (st == NULL) return -1;
        return reply_status(seq, st, out);
    }
    if (in->frame == i_ladder && i_ladder != LLLOADER_NFRAMES) {
        return reply_ladder(seq, out, max_out);
    }
    //! NOT A QUERY WE ANSWER -- and that is not an error.  `(ota-install ...)` and
    //! `(ota-recover ...)` are COMMANDS requiring an authenticated session, which does not exist
    //! yet; answering them here would be the trusted root acting on an unauthenticated instruction.
    //! Zero says "nothing to send", and the caller must not treat it as a failure.
    return 0;
}

// --- the RX scanner.  See the header for why the image-wins-RX rule lives here. ---

void llloader_rx_init(llloader_rx_t *rx)
{
    memset(rx, 0, sizeof(*rx));
}

/*! Close out a buffered `( ... )` line: parse it, and answer if it is a query we answer. */
static llloader_rx_ev_t rx_line_done(llloader_rx_t *rx, llloader_status_fn fn)
{
    rx->nreplies = 0;
    rx->why = LLLOADER_LLIP_OK;

    llloader_frame_in_t in;
    llloader_llip_err_t e = llloader_llip_parse(rx->line, (size_t) rx->len, &in);
    rx->len = 0;
    rx->depth = 0;
    if (e != LLLOADER_LLIP_OK) {
        //! DISCARDED, NOT PARSED.  [P253] step C names this arm: send `(ota-state (seq 1` and stop,
        //! and the listener must time out and discard.  The caller logs `why`; we never reply to
        //! something we could not parse, because that would mean guessing what was asked.
        rx->why = e;
        return LLLOADER_RX_BAD_QUERY;
    }

    //! GATHERED HERE AND NOWHERE ELSE: once, for a frame that actually arrived.  `(ota-ladder)`
    //! ignores it, but building it is cheap compared with having built one per byte.
    llloader_status_t st;
    llloader_status_t *stp = NULL;
    if (fn != NULL) { memset(&st, 0, sizeof(st)); fn(&st); stp = &st; }

    int n = llloader_query_reply(&in, stp, rx->replies, LLLOADER_QUERY_MAX_REPLIES);
    //! RECORD n WHATEVER IT IS, so the caller can tell 0 from -1.  Collapsing them cost a round
    //! trip on [B743]: the diagnostic said "a command pre-auth, OR the reply could not be built",
    //! which are a non-finding and a defect respectively.
    rx->nreplies = n;
    if (n > 0) { return LLLOADER_RX_REPLY; }
    //! n == 0 is a COMMAND or an inbound reply -- not ours to act on pre-auth, and not an error.
    //! n < 0 could not be built; either way there is nothing to send, and BAD_QUERY with
    //! why == LLLOADER_LLIP_OK distinguishes "parsed fine, no answer" from "did not parse".
    return LLLOADER_RX_BAD_QUERY;
}

llloader_rx_ev_t llloader_rx_feed(llloader_rx_t *rx, char b, const char *magic,
                                  llloader_status_fn fn)
{
    /*! (1) A SLIDING 4-BYTE WINDOW, NOT A MATCH COUNTER WITH A BACKTRACK.

        THE BACKTRACK THIS REPLACES WAS WRONG, AND ITS OWN COMMENT NAMED THE CASE IT FAILED.
        src_console.c carried `matched = (b == CON_MAGIC[0]) ? 1 : 0` under a comment reading "A
        partial match that breaks may itself start a new one ("LLLIM"), so retry this byte against
        position 0" -- and `LLLIM` is exactly what it gets wrong.  The magic is `LLIM`, so after two
        `L`s a third should leave TWO bytes matched (the longest prefix of `LLIM` that is also a
        suffix of `LLL`), not one.  Resetting to 1 means the following `I` is compared against
        `magic[1]`, which is `L`, and the magic embedded at offset 1 is MISSED.
        Found 2026-10-03 by the first host arm ever pointed at this loop (B741).

        A window is correct by construction rather than by reasoning about overlaps: hold the last
        four bytes, compare, done.  No partial state to get wrong, and it costs four bytes of RAM.

        IT ALSO STRENGTHENS IMAGE-WINS-RX.  Every byte updates the window, including bytes buffered
        into a query line -- so a TRUNCATED query cannot block a recovery image push.  An operator
        whose query was cut off mid-frame can simply start pushing, and the magic is still seen.
        With the old counter the magic was offered the byte first but any partial query state was
        left dangling; with the window the two are independent. */
    rx->win[0] = rx->win[1];
    rx->win[1] = rx->win[2];
    rx->win[2] = rx->win[3];
    rx->win[3] = b;
    rx->seen++;
    if (rx->seen >= 4 && rx->win[0] == magic[0] && rx->win[1] == magic[1]
                      && rx->win[2] == magic[2] && rx->win[3] == magic[3]) {
        //! Drop any half-buffered query line: those bytes preceded an image push and are not a
        //! frame anybody is waiting on an answer to.
        rx->len = 0;
        rx->depth = 0;
        return LLLOADER_RX_MAGIC;
    }

    //! (2) Not the magic.  A `(` opens a query line, and a line in progress keeps consuming.
    if (rx->depth > 0 || b == '(') {
        rx->qbytes++;
        if (rx->len >= LLLOADER_MAX_FRAME_BYTES) {
            //! Past the grammar's own bound, so it cannot be one of ours whatever follows.
            rx->len = 0;
            rx->depth = 0;
            rx->why = LLLOADER_LLIP_E_LEN;
            rx->nreplies = 0;
            return LLLOADER_RX_BAD_QUERY;
        }
        rx->line[rx->len++] = b;
        if (b == '(') { rx->depth++; return LLLOADER_RX_NEED_MORE; }
        if (b != ')') { return LLLOADER_RX_NEED_MORE; }
        if (--rx->depth > 0) { return LLLOADER_RX_NEED_MORE; }   //!< a field closed, not the frame
        return rx_line_done(rx, fn);
    }

    //! (3) Neither magic nor query: discarded, and counted so the caller can report how much
    //! noise preceded a push.  No match state to repair -- the window above already holds whatever
    //! overlap this byte might begin.
    rx->skipped++;
    return LLLOADER_RX_NEED_MORE;
}
