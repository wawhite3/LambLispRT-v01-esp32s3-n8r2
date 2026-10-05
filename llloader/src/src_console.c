// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- console rung (UART transport). See src_console.h.

#include "src_console.h"
#include "llloader_query.h"

#include <string.h>
#include "esp_rom_sys.h"   //!< esp_rom_printf: the only print that survives this rung owning UART0

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "driver/uart.h"

static const char *TAG = "console";

#define CON_UART        UART_NUM_0
/*! 8192, AND ENLARGING IT DOES NOT HELP -- MEASURED, SO DO NOT TRY IT AGAIN.
    The obvious reading of `stalled with N bytes left` is that this ring overflows while
    `ota_writer` is busy in flash and the unabsorbed inflow is dropped.  At 115200 baud, 8192 B is
    ~0.7 s of inflow and the observed shortfall was ~4.6 s worth, so the arithmetic looked
    compelling.  IT IS WRONG.  Measured 2026-09-26 on the 4WD, same 1,927,632-byte image, same
    sender flags, ring raised 8x to 65536:

        CON_RXBUF  8192  -> stalled with 53113 bytes left
        CON_RXBUF 65536  -> stalled with 52998 bytes left      (0.2% different)

    An 8x larger ring recovered 115 bytes, so ring CAPACITY is not the limiting factor and the loss
    is not an overflow of this buffer.
    LEADING HYPOTHESIS, UNTESTED, recorded so the next attempt starts past the one that failed: the
    bytes are lost BEFORE the ring, in the UART's 128-byte hardware FIFO.  An ESP32 flash erase/write
    can stall an ISR that is not in IRAM, and if the UART interrupt does not run the FIFO overruns
    regardless of how large the ring behind it is -- which is exactly the shape of a result that does
    not respond to ring size.  If that is right the fixes are an IRAM-safe UART ISR, real flow
    control, or not streaming during a flash write at all (an ACK per chunk), and NOT a bigger
    buffer.  See [B644]. */
#define CON_RXBUF       8192
#define CON_MAGIC       "LLIM"
#define CON_HDR_LEN     40            // 4 magic + 4 size + 32 sha256
#define CON_WAIT_HDR_MS 300000        // 5 min for an operator to start the push
#define CON_WAIT_BODY_MS 20000        // per-chunk stall timeout once the stream is flowing

/* [B644] FLOW CONTROL.  The link has none, and the loader INTERLEAVES FLASH WRITES WITH ITS READS,
   so the sender streams straight into a UART whose ISR is stalled by the erase/write.  Measured
   over three runs on hardware the shortfall was 3,632 / 18,836 / 53,113 bytes -- 99.82% / 99.08% /
   97.24% delivered -- with no correlation to sender pacing at all: two runs at the SAME --pace 0.30
   differ by 14x.  Raising CON_RXBUF 8x recovered 115 bytes, which is why the ring is not the fix.

   The loader now hands back one CREDIT TOKEN per CON_CREDIT_BYTES consumed, and -- this is the
   whole point -- it emits them at the TOP of the next read, i.e. only once the previous chunk's
   flash write has returned and it is about to block on the UART again.  A sender that waits for
   credit therefore CANNOT have bytes in flight while the loader is in flash, which is the one
   condition every candidate cause here depends on.

   The token is 0x06 (ASCII ACK) because this UART also carries ESP_LOG output: a non-printable
   byte is separable from log text by the sender without framing, so the operator still sees the
   loader's log while the transfer runs.

   COMPATIBLE BOTH WAYS.  A loader without this emits no credit, and the sender falls back to timed
   pacing after its initial window and says so; a sender without it ignores the tokens as stray
   input.  So an old board and a new host, or the reverse, still transfer. */
#define CON_CREDIT_BYTES 4096
#define CON_CREDIT_TOKEN 0x06
/* The OPENING grant must come from the loader, not be assumed by the sender.  MEASURED [B684]:
   `esp_ota_begin` erases the whole ota_0 slot before the first read -- 16.5 s for 4 MB, 36.5 s
   observed -- and during that erase the UART ISR does not run, so bytes are lost in the 128-byte
   HARDWARE FIFO no matter how big the ring is.  A sender that opened with even one 4096-byte
   window lost 3,240 of those 4,096 bytes (`first block: n=856`).  That is [B644]'s own leading
   hypothesis, confirmed: the loss is BEFORE the ring.  So the sender starts with ZERO allowance
   and the loader primes it here, on its first read, i.e. after the erase has completed. */
#define CON_INITIAL_CREDITS 2

typedef struct {
    size_t remaining;
    size_t credit_owed;           // [B644] bytes consumed but not yet credited to the sender
    bool   primed;                // [B684] opening grant sent (after esp_ota_begin's erase)
    bool   installed;
} con_ctx_t;

// Single-shot loader: one console source at a time.
static image_source_t s_src;
static con_ctx_t      s_ctx;

// Read exactly `len` bytes into buf, bounded by an absolute deadline. Returns bytes read
// (== len on success, < len if the deadline passed with the frame incomplete).
//! --- [P253] step C: answering `(ota-state)` / `(ota-ladder)` while waiting for an image ---
//! See src_console.h for why this lives inside the magic scan rather than beside it.
static llloader_status_fn s_status_fn = NULL;

void llloader_console_set_status_provider(llloader_status_fn fn)
{
    s_status_fn = fn;
}

static int read_exact(uint8_t *buf, int len, int64_t deadline_us)
{
    int n = 0;
    while (n < len) {
        int64_t left_us = deadline_us - esp_timer_get_time();
        if (left_us <= 0) break;
        TickType_t ticks = pdMS_TO_TICKS((uint32_t) (left_us / 1000));
        if (ticks == 0) ticks = 1;
        int r = uart_read_bytes(CON_UART, buf + n, len - n, ticks);
        if (r < 0) break;
        n += r;
    }
    return n;
}

static int con_read(image_source_t *self, uint8_t *buf, size_t max)
{
    con_ctx_t *c = (con_ctx_t *) self->ctx;
    if (c->remaining == 0) {
        return 0;  // whole framed image delivered
    }
    /* [B684] The opening grant: the first time we are ready to read, the slot erase is already
       done.  Until this the sender has sent NOTHING, so nothing can have been lost to it. */
    if (!c->primed) {
        for (int i = 0; i < CON_INITIAL_CREDITS; i++) {
            const char tok0 = (char) CON_CREDIT_TOKEN;
            uart_write_bytes(CON_UART, &tok0, 1);
        }
        c->primed = true;
    }
    /* [B644] Release credit HERE, not after the read: reaching this point means the previous
       chunk's flash write has returned, so the sender is only ever in flight while we are
       actually waiting on the UART. */
    while (c->credit_owed >= CON_CREDIT_BYTES) {
        const char tok = (char) CON_CREDIT_TOKEN;
        uart_write_bytes(CON_UART, &tok, 1);
        c->credit_owed -= CON_CREDIT_BYTES;
    }
    size_t want = max < c->remaining ? max : c->remaining;
    int r = uart_read_bytes(CON_UART, buf, want, pdMS_TO_TICKS(CON_WAIT_BODY_MS));
    if (r <= 0) {
        ESP_LOGE(TAG, "stalled with %u bytes left", (unsigned) c->remaining);
        return -1;
    }
    c->remaining -= (size_t) r;
    c->credit_owed += (size_t) r;
    return r;
}

static void con_close(image_source_t *self)
{
    con_ctx_t *c = (con_ctx_t *) self->ctx;
    if (c != NULL && c->installed) {
        uart_driver_delete(CON_UART);
        c->installed = false;
    }
    self->ctx = NULL;
}

image_source_t *llloader_console_open(bool want_golden)
{
    (void) want_golden;  // operator chooses the image

    if (!uart_is_driver_installed(CON_UART)) {
        if (uart_driver_install(CON_UART, CON_RXBUF, 0, 0, NULL, 0) != ESP_OK) {
            ESP_LOGW(TAG, "uart driver install failed -> rung unavailable");
            return NULL;
        }
    }
    // RX (operator->device) is independent of the ESP_LOG TX stream, so log noise never corrupts
    // the inbound frame. Flush any stale bytes before announcing readiness.
    uart_flush_input(CON_UART);
    ESP_LOGW(TAG, "CONSOLE READY -- push LLIM frame within %ds "
                  "(w3_ai_scripts/llloader_console_send.py)", CON_WAIT_HDR_MS / 1000);

    /* RESYNCHRONISE ON THE MAGIC -- DO NOT DEMAND IT AT OFFSET 0.
       This used to read CON_HDR_LEN bytes and reject unless byte 0 began "LLIM", which makes the
       rung fail whenever ANYTHING precedes the header in the RX buffer: a stale byte from an
       earlier attempt, a fragment of a previous push, line noise on the console UART.  One extra
       leading byte was enough to lose the whole recovery, and the report it produced --
       "no valid frame (got 40 bytes)" with CON_HDR_LEN also 40 -- reads like a short read or a
       timeout, which is where the diagnosis went instead.  Observed 2026-09-26: a full 40 bytes
       read well inside the 300 s window and refused on the memcmp.
       This is the LAST rung: INSTALL is exhausted and RECOVER found no golden image, so the board
       is off the network and the console is the only channel left.  It must not be lost to a
       leading byte.  Scanning costs a byte-at-a-time read until the magic lands and nothing after.
       The deadline still bounds the whole search, so a console that never carries a frame still
       gives up exactly as before. */
    int64_t deadline = esp_timer_get_time() + (int64_t) CON_WAIT_HDR_MS * 1000;
    uint8_t hdr[CON_HDR_LEN];

    /* [P253] step C + [B741]: ONE PURE SCANNER OWNS THE RX DECISION.
       It watches for the `LLIM` magic AND answers `(ota-...)` queries that arrive while we wait, and
       it lives in llloader_query.c so both behaviours are host-testable -- 43 arms, including the
       interleaved case that used to require flashing a board and pushing a query and an image at
       once.  What is left here is only the IDF: read a byte, write a reply.

       THE HAND-ROLLED MATCHER THIS REPLACED HAD A REAL BUG ([B741]): its backtrack reset `matched`
       to 1 where `LLIM` needs 2, so a magic embedded after a partial match -- `LLLIM`, the case its
       own comment claimed to handle -- was MISSED, and the symptom was indistinguishable from a
       disconnected cable (300 s of silence, then "rung unavailable"). */
    llloader_rx_t rx;
    llloader_rx_init(&rx);
    for (;;) {
        uint8_t b;
        if (read_exact(&b, 1, deadline) != 1) {
            ESP_LOGW(TAG, "no frame magic within the window (skipped %d, %d to queries)"
                          " -> rung unavailable", rx.skipped, rx.qbytes);
            uart_driver_delete(CON_UART);
            return NULL;
        }
        /* THE PROVIDER IS PASSED, NOT CALLED.  It used to be invoked here, per byte, which meant
           an NVS open plus two reads plus two partition lookups for EVERY received byte -- and
           during an image push those interleave with the flash writes the push is making ([B644]).
           The scanner calls it once, when a frame completes and only if that frame needs it. */
        llloader_rx_ev_t ev = llloader_rx_feed(&rx, (char) b, CON_MAGIC, s_status_fn);
        if (ev == LLLOADER_RX_MAGIC) {
            memcpy(hdr, CON_MAGIC, 4);       /* the scanner consumed them; the header needs them */
            if (rx.skipped != 0 || rx.qbytes != 0) {
                ESP_LOGW(TAG, "resynchronised on frame magic after %d stray byte(s), %d to queries",
                         rx.skipped, rx.qbytes);
            }
            break;
        }
        if (ev == LLLOADER_RX_REPLY) {
            for (int i = 0; i < rx.nreplies; i++) {
                /* STRAIGHT OUT THE UART, not via llloader_llip_emit()/stdout.  stdout is shared
                   with ESP_LOG, and a reply is an ANSWER rather than a narration: through the log
                   stream a log line could interleave into the middle of a frame the asker is
                   parsing.  The owner's ruling is UART only, and this is what that means in code. */
                uart_write_bytes(CON_UART, rx.replies[i], strlen(rx.replies[i]));
                uart_write_bytes(CON_UART, "\n", 1);
            }
            /* esp_rom_printf, NOT ESP_LOGI, AND THIS IS A BUG FIX.  This rung owns UART0 via
               uart_driver_install() for its whole window, and ESP_LOG from inside it DOES NOT REACH
               THE TRANSCRIPT -- measured 2026-10-03: four `(ota-rung ...)` replies were observed
               crossing the wire while the matching "answered a query with 4 frame(s)" line appeared
               in no capture at all.  So the one diagnostic that would explain a query's fate was
               invisible exactly where it was needed, and a query that produced nothing could not be
               told from one that was never seen.  Same UART-ownership problem that crashed the
               button task ([B741]'s neighbour), arriving as a BLIND INSTRUMENT rather than a crash,
               which is the harder half to notice. */
            esp_rom_printf("console: answered a query with %d frame(s)\n", rx.nreplies);
        }
        else if (ev == LLLOADER_RX_BAD_QUERY) {
            /* Report BOTH shapes.  why != OK means it did not parse; why == OK means it parsed and
               produced nothing (a command, an inbound reply, or a reply that could not be built) --
               and those are different findings that used to look identical from outside. */
            if (rx.why != LLLOADER_LLIP_OK) {
                esp_rom_printf("console: query NOT PARSED (%s) -- discarded\n",
                               llloader_llip_errstr(rx.why));
            }
            else if (rx.nreplies < 0) {
                //! A DEFECT, not a policy: the frame was ours and the reply could not be built --
                //! a missing status provider, or a field the writer refused.
                esp_rom_printf("console: query parsed but the reply COULD NOT BE BUILT"
                               " (missing status provider, or a refused field)\n");
            }
            else {
                //! Not a defect: a command needing auth, or an inbound reply.  Nothing to send.
                esp_rom_printf("console: query parsed, nothing to answer"
                               " (a command pre-auth, or an inbound reply)\n");
            }
        }
    }

    int got = read_exact(hdr + 4, CON_HDR_LEN - 4, deadline);
    if (got != CON_HDR_LEN - 4) {
        ESP_LOGW(TAG, "frame header incomplete (got %d of %d after magic) -> rung unavailable",
                 got, CON_HDR_LEN - 4);
        uart_driver_delete(CON_UART);
        return NULL;
    }

    uint32_t size = (uint32_t) hdr[4]
                  | ((uint32_t) hdr[5] << 8)
                  | ((uint32_t) hdr[6] << 16)
                  | ((uint32_t) hdr[7] << 24);
    if (size == 0) {
        ESP_LOGW(TAG, "frame declares 0 bytes -> ignoring");
        uart_driver_delete(CON_UART);
        return NULL;
    }

    memset(&s_src, 0, sizeof(s_src));
    static const uint8_t zero32[32] = {0};
    if (memcmp(hdr + 8, zero32, 32) != 0) {
        memcpy(s_src.expected_sha256, hdr + 8, 32);
        s_src.have_sha256 = true;
    }

    s_ctx.remaining   = size;
    s_ctx.credit_owed = 0;        //!< [B644] explicit: this rung can be entered more than once
    s_ctx.primed      = false;    //!< [B684] re-prime on every entry
    s_ctx.installed   = true;

    s_src.name       = "console-uart";
    s_src.total_size = size;
    s_src.ctx        = &s_ctx;
    s_src.read       = con_read;
    s_src.close      = con_close;

    ESP_LOGI(TAG, "frame accepted: %u bytes%s", (unsigned) size,
             s_src.have_sha256 ? " +sha256" : " UNVERIFIED");
    return &s_src;
}
