// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- network rung.  See src_network.h.

#include "src_network.h"
#include "llloader_hex.h"

#include <string.h>
#include <stdlib.h>

#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_http_client.h"

#include "nvs.h"

static const char *TAG = "net_rung";

#define WIFI_MAX_RETRY   5
#define WIFI_JOIN_MS     20000
#define HTTP_TIMEOUT_MS  20000

#define CONNECTED_BIT  BIT0
#define FAIL_BIT       BIT1

typedef struct {
    esp_http_client_handle_t client;
    bool wifi_up;
} net_ctx_t;

// Single-shot loader: one network source at a time.
static image_source_t     s_src;
static net_ctx_t          s_ctx;
static EventGroupHandle_t  s_wifi_events;
static int                 s_retry;
static bool                s_netif_inited;

// ---- WiFi bring-up ----------------------------------------------------------

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        if (s_retry < WIFI_MAX_RETRY) {
            s_retry++;
            ESP_LOGW(TAG, "wifi disconnected; retry %d/%d", s_retry, WIFI_MAX_RETRY);
            esp_wifi_connect();
        } else {
            xEventGroupSetBits(s_wifi_events, FAIL_BIT);
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        s_retry = 0;
        xEventGroupSetBits(s_wifi_events, CONNECTED_BIT);
    }
}

static esp_err_t wifi_up(const char *ssid, const char *pass)
{
    s_retry = 0;
    s_wifi_events = xEventGroupCreate();
    if (s_wifi_events == NULL) return ESP_ERR_NO_MEM;

    if (!s_netif_inited) {
        ESP_ERROR_CHECK(esp_netif_init());
        ESP_ERROR_CHECK(esp_event_loop_create_default());
        esp_netif_create_default_wifi_sta();
        s_netif_inited = true;
    }

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    esp_event_handler_instance_t any_wifi, got_ip;
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &on_wifi_event, NULL, &any_wifi));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        IP_EVENT, IP_EVENT_STA_GOT_IP, &on_wifi_event, NULL, &got_ip));

    wifi_config_t wc = {0};
    strlcpy((char *) wc.sta.ssid, ssid, sizeof(wc.sta.ssid));
    strlcpy((char *) wc.sta.password, pass, sizeof(wc.sta.password));
    wc.sta.threshold.authmode = pass[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "joining '%s'...", ssid);
    EventBits_t bits = xEventGroupWaitBits(s_wifi_events, CONNECTED_BIT | FAIL_BIT,
                                           pdFALSE, pdFALSE, pdMS_TO_TICKS(WIFI_JOIN_MS));
    esp_err_t rc = (bits & CONNECTED_BIT) ? ESP_OK : ESP_FAIL;
    if (rc != ESP_OK) {
        ESP_LOGE(TAG, "wifi join failed (bits=0x%x)", (unsigned) bits);
    }
    // Event handlers stay registered for the connection's life; torn down in wifi_down().
    return rc;
}

static void wifi_down(void)
{
    esp_wifi_stop();
    esp_wifi_deinit();
    if (s_wifi_events) {
        vEventGroupDelete(s_wifi_events);
        s_wifi_events = NULL;
    }
    // Leave netif/event-loop initialized (single-shot; no need to tear the whole stack down).
}

// ---- NVS config -------------------------------------------------------------

// Read a non-empty string key; returns true and fills buf (NUL-terminated) on success.
static bool nvs_str(nvs_handle_t h, const char *key, char *buf, size_t buflen)
{
    size_t len = buflen;
    return nvs_get_str(h, key, buf, &len) == ESP_OK && len > 1;
}

// ---- sidecar digest ---------------------------------------------------------

// GET "<url>.sha256" and parse 64 hex chars into out[32]. Best-effort; false if absent/malformed.
static bool fetch_sidecar_sha(const char *url, const char *token, uint8_t out[32])
{
    char surl[224];
    int n = snprintf(surl, sizeof(surl), "%s.sha256", url);
    if (n <= 0 || n >= (int) sizeof(surl)) return false;

    esp_http_client_config_t cfg = { .url = surl, .timeout_ms = HTTP_TIMEOUT_MS };
    esp_http_client_handle_t cl = esp_http_client_init(&cfg);
    if (cl == NULL) return false;
    if (token) esp_http_client_set_header(cl, "Authorization", token);

    bool ok = false;
    if (esp_http_client_open(cl, 0) == ESP_OK) {
        esp_http_client_fetch_headers(cl);
        if (esp_http_client_get_status_code(cl) == 200) {
            char hex[65] = {0};
            int r = esp_http_client_read(cl, hex, 64);
            if (r == 64 && ll_hex_to_bytes(hex, out, 32) == 0) {
                ok = true;
            }
        }
        esp_http_client_close(cl);
    }
    esp_http_client_cleanup(cl);
    return ok;
}

// ---- image_source ----------------------------------------------------------

static int net_read(image_source_t *self, uint8_t *buf, size_t max)
{
    net_ctx_t *c = (net_ctx_t *) self->ctx;
    int r = esp_http_client_read(c->client, (char *) buf, max);
    if (r > 0) return r;
    if (r == 0) {
        if (esp_http_client_is_complete_data_received(c->client)) return 0;  // clean EOF
        ESP_LOGE(TAG, "connection closed before full image");
        return -1;
    }
    return -1;  // r < 0
}

static void net_close(image_source_t *self)
{
    net_ctx_t *c = (net_ctx_t *) self->ctx;
    if (c != NULL) {
        if (c->client != NULL) {
            esp_http_client_close(c->client);
            esp_http_client_cleanup(c->client);
            c->client = NULL;
        }
        if (c->wifi_up) {
            wifi_down();
            c->wifi_up = false;
        }
    }
    self->ctx = NULL;
}

image_source_t *network_open(bool want_golden)
{
    nvs_handle_t h;
    if (nvs_open("ota-p125", NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGI(TAG, "no OTA NVS config -> rung unavailable");
        return NULL;
    }
    char ssid[64], pass[80], url[192], token[128];
    bool have_ssid  = nvs_str(h, "wifi_ssid", ssid, sizeof(ssid));
    bool have_pass  = nvs_str(h, "wifi_pass", pass, sizeof(pass));
    bool have_url   = false;
    if (want_golden) have_url = nvs_str(h, "img_url_gold", url, sizeof(url));
    if (!have_url)   have_url = nvs_str(h, "img_url", url, sizeof(url));
    bool have_token = nvs_str(h, "img_token", token, sizeof(token));
    nvs_close(h);

    if (!have_ssid || !have_url) {
        ESP_LOGI(TAG, "network rung not configured (ssid=%d url=%d)", have_ssid, have_url);
        return NULL;
    }
    if (!have_pass) pass[0] = '\0';

    if (wifi_up(ssid, pass) != ESP_OK) {
        wifi_down();
        return NULL;
    }

    memset(&s_src, 0, sizeof(s_src));
    if (fetch_sidecar_sha(url, have_token ? token : NULL, s_src.expected_sha256)) {
        s_src.have_sha256 = true;
    }

    esp_http_client_config_t cfg = { .url = url, .timeout_ms = HTTP_TIMEOUT_MS };
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (client == NULL) {
        wifi_down();
        return NULL;
    }
    if (have_token) esp_http_client_set_header(client, "Authorization", token);

    if (esp_http_client_open(client, 0) != ESP_OK) {
        ESP_LOGE(TAG, "http open failed: %s", url);
        esp_http_client_cleanup(client);
        wifi_down();
        return NULL;
    }
    int clen   = esp_http_client_fetch_headers(client);
    int status = esp_http_client_get_status_code(client);
    if (status != 200) {
        ESP_LOGE(TAG, "http status %d for %s", status, url);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        wifi_down();
        return NULL;
    }

    memset(&s_ctx, 0, sizeof(s_ctx));
    s_ctx.client  = client;
    s_ctx.wifi_up = true;

    s_src.name       = "network";
    s_src.total_size = clen > 0 ? (size_t) clen : 0;
    s_src.ctx        = &s_ctx;
    s_src.read       = net_read;
    s_src.close      = net_close;

    ESP_LOGI(TAG, "streaming %s (%d bytes)%s", url, clen,
             s_src.have_sha256 ? " +sha256" : " UNVERIFIED");
    return &s_src;
}
