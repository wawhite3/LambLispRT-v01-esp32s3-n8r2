// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- console rung (UART transport). See src_console.h.

#include "src_console.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "driver/uart.h"

static const char *TAG = "console";

#define CON_UART        UART_NUM_0
#define CON_RXBUF       8192
#define CON_MAGIC       "LLIM"
#define CON_HDR_LEN     40            // 4 magic + 4 size + 32 sha256
#define CON_WAIT_HDR_MS 300000        // 5 min for an operator to start the push
#define CON_WAIT_BODY_MS 20000        // per-chunk stall timeout once the stream is flowing

typedef struct {
    size_t remaining;
    bool   installed;
} con_ctx_t;

// Single-shot loader: one console source at a time.
static image_source_t s_src;
static con_ctx_t      s_ctx;

// Read exactly `len` bytes into buf, bounded by an absolute deadline. Returns bytes read
// (== len on success, < len if the deadline passed with the frame incomplete).
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
    size_t want = max < c->remaining ? max : c->remaining;
    int r = uart_read_bytes(CON_UART, buf, want, pdMS_TO_TICKS(CON_WAIT_BODY_MS));
    if (r <= 0) {
        ESP_LOGE(TAG, "stalled with %u bytes left", (unsigned) c->remaining);
        return -1;
    }
    c->remaining -= (size_t) r;
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

    int64_t deadline = esp_timer_get_time() + (int64_t) CON_WAIT_HDR_MS * 1000;
    uint8_t hdr[CON_HDR_LEN];
    int got = read_exact(hdr, CON_HDR_LEN, deadline);
    if (got != CON_HDR_LEN || memcmp(hdr, CON_MAGIC, 4) != 0) {
        ESP_LOGW(TAG, "no valid frame (got %d bytes) -> rung unavailable", got);
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

    s_ctx.remaining = size;
    s_ctx.installed = true;

    s_src.name       = "console-uart";
    s_src.total_size = size;
    s_src.ctx        = &s_ctx;
    s_src.read       = con_read;
    s_src.close      = con_close;

    ESP_LOGI(TAG, "frame accepted: %u bytes%s", (unsigned) size,
             s_src.have_sha256 ? " +sha256" : " UNVERIFIED");
    return &s_src;
}
