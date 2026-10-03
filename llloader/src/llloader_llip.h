// Copyright 2026 by Frobenius Norm LLC 2026-09-30
// llloader_llip.h -- the loader's bounded LLIP frame reader and writer.  [P253] phase 1.
//
// THE GRAMMAR IS SMALLER THAN LLIP AND THAT IS THE SECURITY ARGUMENT.  It is generated from
// scm/features/llloader-vocab.scm into llloader_llip_vocab.h, and this reader enforces exactly
// what that table declares:
//
//   * NO STRING LITERAL EXISTS.  The only non-atomic value is a sha256: a BARE token of exactly
//     LLLOADER_SHA256_HEX lowercase hex digits.  There is no quote character in the grammar, so
//     there is nothing for a payload to hide inside and no escape processing to get wrong.
//   * DEPTH IS FIXED AT LLLOADER_MAX_DEPTH (2): frame, then field.  The reader is a flat loop --
//     no recursion, no stack, so a nesting bomb has nothing to grow.
//   * EVERY BOUND IS A COMPILE-TIME CONSTANT.  No allocation of any kind; the caller owns all
//     storage and the parse output is a fixed-size struct.
//   * ARITY AND TYPE COME FROM THE TABLE, NOT FROM THIS FILE.  A frame must carry EXACTLY the
//     fields its vocabulary entry declares, each of the declared type.  Nothing is optional and
//     nothing extra is tolerated, because "tolerated" is where a second interpretation lives.
//
// READ-ONLY BY DESIGN IN PHASE 1: parsing a `command` frame yields a parsed struct and NOTHING
// else.  This file never writes NVS, never touches a partition, and never decides anything.  The
// caller does, and phase 1 has no caller for commands.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "llloader_llip_vocab.h"

typedef enum {
    LLLOADER_LLIP_OK = 0,
    LLLOADER_LLIP_E_LEN,      //!< frame longer than LLLOADER_MAX_FRAME_BYTES, or empty
    LLLOADER_LLIP_E_SYNTAX,   //!< not `(tag (key value) ...)`
    LLLOADER_LLIP_E_DEPTH,    //!< a `(` where LLLOADER_MAX_DEPTH forbids one
    LLLOADER_LLIP_E_TAG,      //!< no such frame in the vocabulary
    LLLOADER_LLIP_E_KEY,      //!< key not declared for this frame
    LLLOADER_LLIP_E_TYPE,     //!< value is not the declared type
    LLLOADER_LLIP_E_FIELDS,   //!< duplicate field, or a declared field absent
    LLLOADER_LLIP_E_RANGE,    //!< integer does not fit int32_t
    LLLOADER_LLIP_E_SYM,      //!< symbol longer than LLLOADER_MAX_SYMBOL, or a bad character
} llloader_llip_err_t;

/*! One field value.  Which member is live is decided by the frame's declared type, so there is no
    tag here to disagree with the table. */
typedef union {
    int32_t i;                            //!< LLLOADER_FT_INTEGER
    bool    b;                            //!< LLLOADER_FT_BOOLEAN
    char    sym[LLLOADER_MAX_SYMBOL + 1]; //!< LLLOADER_FT_SYMBOL, NUL-terminated
    char    hex[LLLOADER_SHA256_HEX + 1]; //!< LLLOADER_FT_HEX, NUL-terminated, lowercase
} llloader_value_t;

typedef struct {
    size_t           frame;                          //!< index into llloader_frames[]
    llloader_value_t v[LLLOADER_MAX_FIELDS];         //!< positional: parallel to frames[frame].fields
} llloader_frame_in_t;

/*! Parse one frame.  `buf` need not be NUL-terminated; `len` is authoritative.
    Returns LLLOADER_LLIP_OK and fills `*out`, or an error and leaves `*out` unspecified. */
llloader_llip_err_t llloader_llip_parse(const char *buf, size_t len, llloader_frame_in_t *out);

/*! A short, stable name for an error -- for a log line or an `(ota-ack ... (reason X))`. */
const char *llloader_llip_errstr(llloader_llip_err_t e);

/*! The frame's index by tag, or LLLOADER_NFRAMES if there is no such frame. */
size_t llloader_llip_frame_by_tag(const char *tag);

/*! --- writer.  A STICKY-ERROR BUILDER, so no call site can overflow and none has to check ---

    Every append is a no-op once the buffer is full or a value is invalid, and `end` reports it
    once.  The alternative -- a return code per append -- is a rule that five call sites obey and
    the sixth does not, and the sixth is the one that truncates a reply into a DIFFERENT valid
    frame.  Truncation is the failure worth designing against here: `(ota-result (rung http)` with
    the tail lost is not malformed to a sloppy reader, it is a shorter frame. */
typedef struct {
    char  *p;
    size_t cap;
    size_t len;
    bool   bad;      //!< sticky: overflow, or a value the grammar does not permit
} llloader_wr_t;

void llloader_wr_begin(llloader_wr_t *w, char *buf, size_t cap, const char *tag);
void llloader_wr_int (llloader_wr_t *w, const char *key, int32_t v);
void llloader_wr_sym (llloader_wr_t *w, const char *key, const char *sym);
void llloader_wr_bool(llloader_wr_t *w, const char *key, bool v);
void llloader_wr_hex (llloader_wr_t *w, const char *key, const char *hex);

/*! --- emit.  REPLY-ONLY OUTPUT: the loader SAYS things; it answers nothing yet. ---

    Writes `frame` to the console followed by a newline, so ONE LINE IS EXACTLY ONE FRAME and a
    reader can pick frames out of the log by `^\(ota-`.  Raw, not through ESP_LOG, deliberately:
    a log prefix (`I (1234) llloader:`) would have to be stripped by every consumer, and the
    timestamp in it is a second, unreliable copy of information the frame does not claim to carry.

    IT CANNOT BLOCK ON A PEER, because there is no peer -- nothing is expected to read this.  That
    is the whole safety argument for doing output before input: no listening window, no parser
    exposed to the wire, nothing to authenticate, and a frame nobody reads costs only the bytes.

    Does nothing if `frame` is NULL or empty, which is what `llloader_wr_end()` leaves behind on
    overflow -- so a builder that failed emits silence rather than a truncated frame. */
/* [P253, owner ruling 2026-09-30] FRAMES GO OUT ON THE UART.  NOT THE RADIO.
 *
 * Queries are answered pre-auth -- no keys, no handshake -- and that is only safe because
 * disclosure is bounded by PHYSICAL ACCESS.  Today the bound is free: src_ble_console.c declares
 * two characteristics, both WRITE, with no NOTIFY and no READ, so the radio cannot carry a reply
 * even if something tried.  The ruling was written down precisely BECAUSE it is currently free --
 * the moment a transport can reply, "UART only" stops being a fact about the hardware and becomes
 * a rule somebody has to honour.
 *
 * SO IF YOU ARE HERE TO SEND FRAMES OVER ANOTHER TRANSPORT: the pre-auth answer has to be
 * revisited in the same change, not afterwards.  An unauthenticated (ota-ladder) over a radio
 * tells anyone in range which image sources the unit accepts.  See the OWNER RULINGS section of
 * w3_ai_exch/proposal_llloader_llip_frames_P253.md.
 */
void llloader_llip_emit(const char *frame);

/*! Close the frame.  Returns the length written, or -1 if anything overflowed or was invalid --
    in which case the buffer holds an empty string rather than a truncated frame. */
int llloader_wr_end(llloader_wr_t *w);

