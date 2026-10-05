// Copyright 2026 by Frobenius Norm LLC 2026-09-30
// llloader_llip.c -- the loader's bounded LLIP frame reader and writer.  [P253] phase 1.
//
// NO ALLOCATION, NO RECURSION, NO STRING LITERALS IN THE GRAMMAR.  See llloader_llip.h for why
// each of those is a property of the GRAMMAR rather than a promise about this file: the reader
// cannot be made to recurse because the grammar has no nesting past depth 2, and it cannot be
// made to copy an unbounded token because every token's maximum is a compile-time constant from
// the generated vocabulary table.
//
// THE TABLE DECIDES ARITY AND TYPE, NOT THIS FILE.  Grep this file for a field name and you will
// find none: keys are looked up in llloader_frames[].fields and values parsed per
// llloader_frames[].types.  That is deliberate -- a reader that names its own fields is a second
// copy of the vocabulary, and the copy is the one that goes stale.

#include "llloader_llip.h"

#include <stdio.h>
#include <string.h>

//! A symbol is lowercase-alphanumeric plus `-` and `_`.  DELIBERATELY NARROW: tags carry `-`
//! (`ota-install`) and slots carry `_` (`ota_0`), and nothing in the vocabulary needs more.  No
//! uppercase, so a symbol has ONE spelling and a comparison is a memcmp rather than a policy.
static bool ll_is_sym_char(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
}

static bool ll_is_hex_char(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

//! Space, tab, newline and carriage return only.  A frame arrives over a UART or a socket, so CR
//! is normal and must not be a syntax error; anything else non-printing is NOT whitespace here.
static bool ll_is_ws(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static size_t ll_skip_ws(const char *b, size_t len, size_t i)
{
    while (i < len && ll_is_ws(b[i])) { i++; }
    return i;
}

/*! Copy one symbol token into `dst`.  No scaffolding is held, so the guard clauses return early
    (CLAUDE.md's stated exception to single-exit). */
static llloader_llip_err_t ll_take_symbol(const char *b, size_t len, size_t *i,
                                          char *dst, size_t dstcap)
{
    size_t n = 0;
    size_t j = *i;
    if (j >= len || !ll_is_sym_char(b[j])) { return LLLOADER_LLIP_E_SYNTAX; }
    while (j < len && ll_is_sym_char(b[j])) {
        if (n + 1 >= dstcap) { return LLLOADER_LLIP_E_SYM; }   //!< bound BEFORE the copy
        dst[n++] = b[j++];
    }
    dst[n] = '\0';
    *i = j;
    return LLLOADER_LLIP_OK;
}

/*! One value of the declared type.  `t` comes from the generated table, so an unhandled type is a
    generator/reader disagreement and is reported as E_TYPE rather than silently accepted. */
static llloader_llip_err_t ll_take_value(const char *b, size_t len, size_t *i,
                                         llloader_field_type_t t, llloader_value_t *out)
{
    size_t j = *i;
    llloader_llip_err_t res = LLLOADER_LLIP_OK;

    switch (t) {
    case LLLOADER_FT_INTEGER: {
        bool neg = false;
        int64_t acc = 0;
        size_t digits = 0;
        if (j < len && b[j] == '-') { neg = true; j++; }
        while (j < len && b[j] >= '0' && b[j] <= '9') {
            acc = acc * 10 + (b[j] - '0');
            j++;
            digits++;
            //! RANGE IS CHECKED INSIDE THE LOOP, not after it.  Checked after, a long run of
            //! digits overflows int64 first and the check then reads a wrapped value as in range.
            if (acc > 2147483648LL) { res = LLLOADER_LLIP_E_RANGE; break; }
        }
        if (res == LLLOADER_LLIP_OK) {
            if (digits == 0) {
                res = LLLOADER_LLIP_E_TYPE;
            } else if (neg ? (acc > 2147483648LL) : (acc > 2147483647LL)) {
                res = LLLOADER_LLIP_E_RANGE;
            } else {
                out->i = (int32_t) (neg ? -acc : acc);
            }
        }
        break;
    }
    case LLLOADER_FT_BOOLEAN:
        if (j + 1 < len && b[j] == '#' && (b[j + 1] == 't' || b[j + 1] == 'f')) {
            out->b = (b[j + 1] == 't');
            j += 2;
        }
        else { res = LLLOADER_LLIP_E_TYPE; }
        break;
    case LLLOADER_FT_SYMBOL:
        res = ll_take_symbol(b, len, &j, out->sym, sizeof(out->sym));
        break;
    case LLLOADER_FT_HEX: {
        //! EXACTLY LLLOADER_SHA256_HEX characters.  Not "at most", not "at least": a digest of any
        //! other length is not a short digest, it is a different kind of object, and accepting one
        //! would be the first string of variable length in this grammar.
        size_t n = 0;
        while (j + n < len && ll_is_hex_char(b[j + n]) && n < LLLOADER_SHA256_HEX) { n++; }
        if (n != LLLOADER_SHA256_HEX || (j + n < len && ll_is_hex_char(b[j + n]))) {
            res = LLLOADER_LLIP_E_TYPE;
        } else {
            memcpy(out->hex, b + j, LLLOADER_SHA256_HEX);
            out->hex[LLLOADER_SHA256_HEX] = '\0';
            j += n;
        }
        break;
    }
    default:
        res = LLLOADER_LLIP_E_TYPE;
        break;
    }

    if (res == LLLOADER_LLIP_OK) { *i = j; }
    return res;
}

size_t llloader_llip_frame_by_tag(const char *tag)
{
    size_t res = LLLOADER_NFRAMES;
    for (size_t k = 0; k < LLLOADER_NFRAMES; k++) {
        if (strcmp(llloader_frames[k].tag, tag) == 0) { res = k; break; }
    }
    return res;
}

llloader_llip_err_t llloader_llip_parse(const char *buf, size_t len, llloader_frame_in_t *out)
{
    llloader_llip_err_t res = LLLOADER_LLIP_OK;
    //! ONE EXIT.  The loop below has a dozen ways to reject a frame; with a return at each one, a
    //! later edit that needs to record a rejection has a dozen places to remember.
    do {
        if (buf == NULL || out == NULL) { res = LLLOADER_LLIP_E_SYNTAX; break; }
        //! LENGTH FIRST, BEFORE ANY CHARACTER IS EXAMINED.  This is the bound that makes every
        //! other bound reachable: an over-long frame is refused without being scanned.
        if (len == 0 || len > LLLOADER_MAX_FRAME_BYTES) { res = LLLOADER_LLIP_E_LEN; break; }

        size_t i = ll_skip_ws(buf, len, 0);
        if (i >= len || buf[i] != '(') { res = LLLOADER_LLIP_E_SYNTAX; break; }
        i++;
        i = ll_skip_ws(buf, len, i);

        char tag[LLLOADER_MAX_SYMBOL + 1];
        res = ll_take_symbol(buf, len, &i, tag, sizeof(tag));
        if (res != LLLOADER_LLIP_OK) { break; }

        size_t f = llloader_llip_frame_by_tag(tag);
        if (f >= LLLOADER_NFRAMES) { res = LLLOADER_LLIP_E_TAG; break; }
        const llloader_frame_t *fr = &llloader_frames[f];
        if (fr->nfields > LLLOADER_MAX_FIELDS) { res = LLLOADER_LLIP_E_FIELDS; break; }
        out->frame = f;

        uint32_t seen = 0;          //!< one bit per declared field; LLLOADER_MAX_FIELDS <= 32
        size_t   npairs = 0;
        for (;;) {
            i = ll_skip_ws(buf, len, i);
            if (i >= len) { res = LLLOADER_LLIP_E_SYNTAX; break; }
            if (buf[i] == ')') { i++; break; }
            if (buf[i] != '(') { res = LLLOADER_LLIP_E_SYNTAX; break; }
            i++;

            //! COUNT PAIRS AGAINST THE DECLARED BOUND, not against the frame's arity alone.  A
            //! frame repeating a key is caught by `seen` below; this catches a frame whose pairs
            //! outnumber anything the vocabulary permits, before the work of parsing them.
            if (++npairs > LLLOADER_MAX_FIELDS) { res = LLLOADER_LLIP_E_FIELDS; break; }

            i = ll_skip_ws(buf, len, i);
            char key[LLLOADER_MAX_SYMBOL + 1];
            res = ll_take_symbol(buf, len, &i, key, sizeof(key));
            if (res != LLLOADER_LLIP_OK) { break; }

            size_t x = fr->nfields;
            for (size_t k = 0; k < fr->nfields; k++) {
                if (strcmp(fr->fields[k], key) == 0) { x = k; break; }
            }
            if (x >= fr->nfields) { res = LLLOADER_LLIP_E_KEY; break; }
            if (seen & (1u << x))  { res = LLLOADER_LLIP_E_FIELDS; break; }
            seen |= (1u << x);

            i = ll_skip_ws(buf, len, i);
            //! DEPTH: a `(` here would be a nested value, which LLLOADER_MAX_DEPTH forbids.  This
            //! is the ONLY place nesting could appear, which is what makes the reader flat.
            if (i < len && buf[i] == '(') { res = LLLOADER_LLIP_E_DEPTH; break; }
            res = ll_take_value(buf, len, &i, fr->types[x], &out->v[x]);
            if (res != LLLOADER_LLIP_OK) { break; }

            i = ll_skip_ws(buf, len, i);
            if (i >= len || buf[i] != ')') { res = LLLOADER_LLIP_E_SYNTAX; break; }
            i++;
        }
        if (res != LLLOADER_LLIP_OK) { break; }

        //! NOTHING IS OPTIONAL.  A frame carrying a subset of its declared fields is refused
        //! rather than filled with defaults: a default is a value this end invented, and an
        //! `(ota-install)` whose `golden` was defaulted is a decision made by the parser.
        if (seen != ((fr->nfields == 32u) ? 0xFFFFFFFFu : ((1u << fr->nfields) - 1u))) {
            res = LLLOADER_LLIP_E_FIELDS;
            break;
        }

        //! TRAILING BYTES ARE A REJECTION, not ignored.  Two frames in one buffer must not parse
        //! as the first one: the caller would act on frame 1 and never see frame 2.
        i = ll_skip_ws(buf, len, i);
        if (i != len) { res = LLLOADER_LLIP_E_SYNTAX; break; }
    } while (0);
    return res;
}

const char *llloader_llip_errstr(llloader_llip_err_t e)
{
    const char *res = "unknown";
    switch (e) {
    case LLLOADER_LLIP_OK:       res = "ok";       break;
    case LLLOADER_LLIP_E_LEN:    res = "length";   break;
    case LLLOADER_LLIP_E_SYNTAX: res = "syntax";   break;
    case LLLOADER_LLIP_E_DEPTH:  res = "depth";    break;
    case LLLOADER_LLIP_E_TAG:    res = "tag";      break;
    case LLLOADER_LLIP_E_KEY:    res = "key";      break;
    case LLLOADER_LLIP_E_TYPE:   res = "type";     break;
    case LLLOADER_LLIP_E_FIELDS: res = "fields";   break;
    case LLLOADER_LLIP_E_RANGE:  res = "range";    break;
    case LLLOADER_LLIP_E_SYM:    res = "symbol";   break;
    default:                                       break;
    }
    return res;
}

// ── writer ────────────────────────────────────────────────────────────────────────────────────

static void ll_wr_raw(llloader_wr_t *w, const char *s, size_t n)
{
    if (w->bad) { return; }
    //! +1 for the closing `)` that end() still owes, so a frame can never be left unterminated
    //! by a successful append.  Reserving it here rather than in end() means the FIRST append
    //! that would make termination impossible is the one that fails.
    if (w->len + n + 1 >= w->cap) { w->bad = true; return; }
    memcpy(w->p + w->len, s, n);
    w->len += n;
}

static void ll_wr_key(llloader_wr_t *w, const char *key)
{
    ll_wr_raw(w, " (", 2);
    ll_wr_raw(w, key, strlen(key));
    ll_wr_raw(w, " ", 1);
}

void llloader_wr_begin(llloader_wr_t *w, char *buf, size_t cap, const char *tag)
{
    w->p = buf;
    w->cap = cap;
    w->len = 0;
    w->bad = (buf == NULL || cap < 4 || tag == NULL);
    if (cap > 0 && buf != NULL) { buf[0] = '\0'; }
    ll_wr_raw(w, "(", 1);
    if (tag != NULL) { ll_wr_raw(w, tag, strlen(tag)); }
}

void llloader_wr_int(llloader_wr_t *w, const char *key, int32_t v)
{
    char d[12];
    size_t n = 0;
    uint32_t mag = (v < 0) ? (uint32_t) (-(int64_t) v) : (uint32_t) v;
    char rev[11];
    size_t r = 0;
    do { rev[r++] = (char) ('0' + (mag % 10u)); mag /= 10u; } while (mag != 0u && r < sizeof(rev));
    if (v < 0) { d[n++] = '-'; }
    while (r > 0) { d[n++] = rev[--r]; }
    ll_wr_key(w, key);
    ll_wr_raw(w, d, n);
    ll_wr_raw(w, ")", 1);
}

void llloader_wr_bool(llloader_wr_t *w, const char *key, bool v)
{
    ll_wr_key(w, key);
    ll_wr_raw(w, v ? "#t" : "#f", 2);
    ll_wr_raw(w, ")", 1);
}

void llloader_wr_sym(llloader_wr_t *w, const char *key, const char *sym)
{
    //! THE WRITER VALIDATES WHAT IT EMITS.  A symbol from a runtime source (an NVS value, a
    //! ladder rung name) that does not fit the grammar would produce a frame our own reader
    //! refuses -- and the failure would surface at the PEER, as a syntax error in our output.
    if (sym == NULL) { w->bad = true; return; }
    size_t n = strlen(sym);
    if (n == 0 || n > LLLOADER_MAX_SYMBOL) { w->bad = true; return; }
    for (size_t k = 0; k < n; k++) {
        if (!ll_is_sym_char(sym[k])) { w->bad = true; return; }
    }
    ll_wr_key(w, key);
    ll_wr_raw(w, sym, n);
    ll_wr_raw(w, ")", 1);
}

void llloader_wr_hex(llloader_wr_t *w, const char *key, const char *hex)
{
    if (hex == NULL || strlen(hex) != LLLOADER_SHA256_HEX) { w->bad = true; return; }
    for (size_t k = 0; k < LLLOADER_SHA256_HEX; k++) {
        if (!ll_is_hex_char(hex[k])) { w->bad = true; return; }
    }
    ll_wr_key(w, key);
    ll_wr_raw(w, hex, LLLOADER_SHA256_HEX);
    ll_wr_raw(w, ")", 1);
}

int llloader_wr_end(llloader_wr_t *w)
{
    int res = -1;
    if (!w->bad && w->len + 1 < w->cap) {
        w->p[w->len++] = ')';
        w->p[w->len] = '\0';
        //! THE FRAME MUST NOT EXCEED THE READER'S OWN BOUND.  A reply we can build but the peer
        //! must refuse is worse than an overflow we report here: it fails at the far end, in
        //! someone else's log.
        if (w->len <= LLLOADER_MAX_FRAME_BYTES) { res = (int) w->len; }
    }
    if (res < 0 && w->cap > 0 && w->p != NULL) {
        w->p[0] = '\0';   //!< an EMPTY string, never a truncated frame -- see the header
        w->len = 0;
        w->bad = true;
    }
    return res;
}


void llloader_llip_emit(const char *frame)
{
    //! AN EMPTY FRAME IS SILENCE, NOT AN EMPTY LINE.  llloader_wr_end() leaves "" on overflow, so
    //! this is the path a builder takes when it failed; emitting a bare newline would put a line
    //! in the transcript that a reader could mistake for a frame it failed to parse.
    if (frame == NULL || frame[0] == '\0') { return; }
    fputs(frame, stdout);
    fputc('\n', stdout);
    //! FLUSH, because the frames worth emitting are the ones sent just before something goes
    //! wrong -- a progress frame before a failed write, a death record before a reset.  Buffered
    //! output is lost at exactly the moment it was the point.
    fflush(stdout);
}
