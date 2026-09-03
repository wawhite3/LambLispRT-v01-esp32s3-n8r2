// Copyright 2026 by Frobenius Norm LLC 2026-07-08 00:00:00
//
// OTA llloader -- BLE console rung (rung 3b). See src_ble_console.h.
//
// A NimBLE GATT peripheral advertises as "LLLOADER" and exposes two write characteristics on a
// Nordic-UART-style service:
//   * control (6E400004-...) -- the operator writes the 40-byte LLIM header (magic + size + sha256)
//   * data    (6E400002-...) -- the operator streams image bytes; each write is pushed into a
//                               FreeRTOS stream buffer that ble_read() drains for the OTA writer.
// This is the wireless twin of the UART console rung: same LLIM frame, same pull-stream contract.

#include "src_ble_console.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/stream_buffer.h"

#include "esp_log.h"
#include "esp_timer.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "ble_console";

#define BLE_DEV_NAME      "LLLOADER"
#define BLE_MAGIC         "LLIM"
#define BLE_HDR_LEN       40           // 4 magic + 4 size (LE) + 32 sha256
#define BLE_WAIT_HDR_MS   300000       // 5 min for an operator to connect + send the header
#define BLE_WAIT_BODY_MS  20000        // per-chunk stall timeout once the stream is flowing
#define BLE_RINGBUF_BYTES 16384        // image bytes buffered between GATT writes and ble_read()

// NUS-style 128-bit UUIDs (bytes little-endian). Service base = Nordic UART Service.
// 6E400001-B5A3-F393-E0A9-E50E24DCCA9E ; control uses ...0004, data uses ...0002.
static const ble_uuid128_t svc_uuid =
    BLE_UUID128_INIT(0x9e,0xca,0xdc,0x24,0x0e,0xe5,0xa9,0xe0,
                     0x93,0xf3,0xa3,0xb5,0x01,0x00,0x40,0x6e);
static const ble_uuid128_t chr_ctrl_uuid =
    BLE_UUID128_INIT(0x9e,0xca,0xdc,0x24,0x0e,0xe5,0xa9,0xe0,
                     0x93,0xf3,0xa3,0xb5,0x04,0x00,0x40,0x6e);
static const ble_uuid128_t chr_data_uuid =
    BLE_UUID128_INIT(0x9e,0xca,0xdc,0x24,0x0e,0xe5,0xa9,0xe0,
                     0x93,0xf3,0xa3,0xb5,0x02,0x00,0x40,0x6e);

// --- shared state (single-shot: one BLE console session at a time) ----------
static StreamBufferHandle_t s_ring;
static volatile bool     s_hdr_ready;
static volatile bool     s_have_sha;
static uint8_t           s_expected_sha[32];
static volatile uint32_t s_size;
static uint8_t           s_hdr_acc[BLE_HDR_LEN];
static volatile int      s_hdr_n;
static uint8_t           s_own_addr_type;
static bool              s_nimble_running;

static image_source_t s_src;
typedef struct { size_t remaining; } ble_ctx_t;
static ble_ctx_t s_ctx;

static void start_advertising(void);

// --- GATT: both write chars land here -----------------------------------------
static int gatt_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void) conn_handle; (void) attr_handle; (void) arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR)
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;

    uint8_t buf[512];
    uint16_t n = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &n) != 0)
        return BLE_ATT_ERR_UNLIKELY;

    const ble_uuid_t *u = ctxt->chr->uuid;
    if (ble_uuid_cmp(u, &chr_ctrl_uuid.u) == 0) {
        for (uint16_t i = 0; i < n && s_hdr_n < BLE_HDR_LEN; i++)
            s_hdr_acc[s_hdr_n++] = buf[i];
        if (s_hdr_n >= BLE_HDR_LEN && !s_hdr_ready) {
            if (memcmp(s_hdr_acc, BLE_MAGIC, 4) != 0) {
                ESP_LOGW(TAG, "bad magic in control frame; resetting");
                s_hdr_n = 0;
                return 0;
            }
            s_size = (uint32_t) s_hdr_acc[4]
                   | ((uint32_t) s_hdr_acc[5] << 8)
                   | ((uint32_t) s_hdr_acc[6] << 16)
                   | ((uint32_t) s_hdr_acc[7] << 24);
            static const uint8_t zero32[32] = {0};
            if (memcmp(s_hdr_acc + 8, zero32, 32) != 0) {
                memcpy(s_expected_sha, s_hdr_acc + 8, 32);
                s_have_sha = true;
            }
            s_hdr_ready = true;
            ESP_LOGI(TAG, "control frame: %u bytes%s", (unsigned) s_size,
                     s_have_sha ? " +sha256" : " UNVERIFIED");
        }
        return 0;
    }
    if (ble_uuid_cmp(u, &chr_data_uuid.u) == 0) {
        if (n && s_ring) xStreamBufferSend(s_ring, buf, n, 0);
        return 0;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            { .uuid = &chr_ctrl_uuid.u, .access_cb = gatt_access_cb,
              .flags = BLE_GATT_CHR_F_WRITE },
            { .uuid = &chr_data_uuid.u, .access_cb = gatt_access_cb,
              .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP },
            { 0 },
        },
    },
    { 0 },
};

// --- GAP: keep advertising across disconnects until the frame is in ----------
static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void) arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        ESP_LOGI(TAG, "connect %s", event->connect.status == 0 ? "ok" : "failed");
        if (event->connect.status != 0) start_advertising();
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnect; re-advertising");
        if (!s_hdr_ready) start_advertising();
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        if (!s_hdr_ready) start_advertising();
        break;
    default:
        break;
    }
    return 0;
}

static void start_advertising(void)
{
    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *) BLE_DEV_NAME;
    fields.name_len = strlen(BLE_DEV_NAME);
    fields.name_is_complete = 1;
    if (ble_gap_adv_set_fields(&fields) != 0) {
        ESP_LOGW(TAG, "adv_set_fields failed");
        return;
    }
    struct ble_gap_adv_params advp;
    memset(&advp, 0, sizeof(advp));
    advp.conn_mode = BLE_GAP_CONN_MODE_UND;
    advp.disc_mode = BLE_GAP_DISC_MODE_GEN;
    int rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &advp, gap_event, NULL);
    if (rc != 0) ESP_LOGW(TAG, "adv_start rc=%d", rc);
}

static void on_sync(void)
{
    if (ble_hs_util_ensure_addr(0) != 0) {
        ESP_LOGW(TAG, "no BLE address available");
        return;
    }
    if (ble_hs_id_infer_auto(0, &s_own_addr_type) != 0) {
        ESP_LOGW(TAG, "infer_auto failed");
        return;
    }
    start_advertising();
}

static void host_task(void *param)
{
    (void) param;
    nimble_port_run();               // returns only after nimble_port_stop()
    nimble_port_freertos_deinit();
}

// --- image_source read/close --------------------------------------------------
static int ble_read(image_source_t *self, uint8_t *buf, size_t max)
{
    ble_ctx_t *c = (ble_ctx_t *) self->ctx;
    if (c->remaining == 0) return 0;
    size_t want = max < c->remaining ? max : c->remaining;
    size_t got = xStreamBufferReceive(s_ring, buf, want, pdMS_TO_TICKS(BLE_WAIT_BODY_MS));
    if (got == 0) {
        ESP_LOGE(TAG, "BLE stalled with %u bytes left", (unsigned) c->remaining);
        return -1;
    }
    c->remaining -= got;
    return (int) got;
}

static void ble_stop(void)
{
    if (s_nimble_running) {
        if (nimble_port_stop() == 0) nimble_port_deinit();
        s_nimble_running = false;
    }
    if (s_ring) {
        vStreamBufferDelete(s_ring);
        s_ring = NULL;
    }
}

static void ble_close(image_source_t *self)
{
    ble_stop();
    if (self) self->ctx = NULL;
}

image_source_t *llloader_ble_console_open(bool want_golden)
{
    (void) want_golden;   // operator chooses the image over BLE

    s_hdr_ready = false; s_have_sha = false; s_hdr_n = 0; s_size = 0;
    s_ring = xStreamBufferCreate(BLE_RINGBUF_BYTES, 1);
    if (s_ring == NULL) {
        ESP_LOGW(TAG, "no RAM for ring buffer -> rung unavailable");
        return NULL;
    }

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "nimble_port_init: %s -> rung unavailable", esp_err_to_name(err));
        vStreamBufferDelete(s_ring); s_ring = NULL;
        return NULL;
    }
    s_nimble_running = true;

    ble_hs_cfg.sync_cb = on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    if (ble_gatts_count_cfg(gatt_svcs) != 0 || ble_gatts_add_svcs(gatt_svcs) != 0) {
        ESP_LOGE(TAG, "gatt register failed -> rung unavailable");
        ble_stop();
        return NULL;
    }
    ble_svc_gap_device_name_set(BLE_DEV_NAME);
    nimble_port_freertos_init(host_task);

    ESP_LOGW(TAG, "BLE READY -- advertising as '%s'; push an LLIM control frame within %ds",
             BLE_DEV_NAME, BLE_WAIT_HDR_MS / 1000);

    int64_t deadline = esp_timer_get_time() + (int64_t) BLE_WAIT_HDR_MS * 1000;
    while (!s_hdr_ready && esp_timer_get_time() < deadline)
        vTaskDelay(pdMS_TO_TICKS(100));

    if (!s_hdr_ready) {
        ESP_LOGW(TAG, "no control frame -> rung unavailable");
        ble_stop();
        return NULL;
    }
    if (s_size == 0) {
        ESP_LOGW(TAG, "control frame declares 0 bytes -> ignoring");
        ble_stop();
        return NULL;
    }

    memset(&s_src, 0, sizeof(s_src));
    s_ctx.remaining  = s_size;
    if (s_have_sha) {
        memcpy(s_src.expected_sha256, s_expected_sha, 32);
        s_src.have_sha256 = true;
    }
    s_src.name       = "ble-console";
    s_src.total_size = s_size;
    s_src.ctx        = &s_ctx;
    s_src.read       = ble_read;
    s_src.close      = ble_close;
    return &s_src;
}
