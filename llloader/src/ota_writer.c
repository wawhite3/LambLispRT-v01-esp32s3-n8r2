// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- OTA writer implementation.  See ota_writer.h.

#include "ota_writer.h"
#include "llloader_hex.h"

#include <string.h>
#include <stdlib.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_task_wdt.h"

// IDF 6.x restructured mbedtls into tf-psa-crypto; the classic mbedtls_sha256_* API is now
// private. PSA Crypto (psa/crypto.h) is the public, version-stable hash interface -- correct
// for a trusted root that must not depend on internal header layout.
#include "psa/crypto.h"

static const char *TAG = "ota_writer";

// One flash-page-ish chunk. Big enough to keep esp_ota_write efficient, small enough that peak
// RAM stays trivial on the PSRAM-free trusted root.
#define OTA_CHUNK_BYTES 4096

// Feed the task WDT if this task is subscribed; harmless (ESP_ERR_NOT_FOUND) if it isn't.
static void feed_wdt(void)
{
    esp_err_t err = esp_task_wdt_reset();
    if (err != ESP_OK && err != ESP_ERR_NOT_FOUND) {
        ESP_LOGW(TAG, "wdt reset: %s", esp_err_to_name(err));
    }
}

esp_err_t llloader_ota_write(const esp_partition_t *dst, image_source_t *src)
{
    if (dst == NULL || src == NULL || src->read == NULL) {
        ESP_LOGE(TAG, "bad args (dst=%p src=%p)", (void *) dst, (void *) src);
        return ESP_ERR_INVALID_ARG;
    }
    ESP_LOGI(TAG, "writing image from '%s' -> %s @ 0x%08lx (%lu byte slot, declared %u)",
             src->name ? src->name : "?", dst->label,
             (unsigned long) dst->address, (unsigned long) dst->size,
             (unsigned) src->total_size);

    if (src->total_size != 0 && src->total_size > dst->size) {
        ESP_LOGE(TAG, "declared image %u > slot %lu -- refusing",
                 (unsigned) src->total_size, (unsigned long) dst->size);
        return ESP_ERR_INVALID_SIZE;
    }

    uint8_t *buf = malloc(OTA_CHUNK_BYTES);
    if (buf == NULL) {
        ESP_LOGE(TAG, "no RAM for %d-byte chunk", OTA_CHUNK_BYTES);
        return ESP_ERR_NO_MEM;
    }

    esp_err_t err = ESP_OK;
    psa_hash_operation_t hash = PSA_HASH_OPERATION_INIT;
    bool hash_live = false;

    if (psa_crypto_init() != PSA_SUCCESS ||
        psa_hash_setup(&hash, PSA_ALG_SHA_256) != PSA_SUCCESS) {
        ESP_LOGE(TAG, "PSA SHA-256 init failed");
        err = ESP_FAIL;
        goto done;
    }
    hash_live = true;

    // Subscribe this task so long flash writes don't trip the idle WDT; ignore if already added.
    (void) esp_task_wdt_add(NULL);

    esp_ota_handle_t handle = 0;
    err = esp_ota_begin(dst, OTA_SIZE_UNKNOWN, &handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_begin: %s", esp_err_to_name(err));
        goto done;
    }

    size_t total = 0;
    for (;;) {
        int n = src->read(src, buf, OTA_CHUNK_BYTES);
        if (n < 0) {
            ESP_LOGE(TAG, "source read error at %u bytes", (unsigned) total);
            err = ESP_FAIL;
            break;
        }
        if (n == 0) {
            break;  // clean EOF
        }
        if (psa_hash_update(&hash, buf, (size_t) n) != PSA_SUCCESS) {
            ESP_LOGE(TAG, "psa_hash_update failed at %u", (unsigned) total);
            err = ESP_FAIL;
            break;
        }
        err = esp_ota_write(handle, buf, (size_t) n);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "esp_ota_write at %u: %s", (unsigned) total, esp_err_to_name(err));
            break;
        }
        total += (size_t) n;
        feed_wdt();
    }

    if (err == ESP_OK && total == 0) {
        ESP_LOGE(TAG, "empty image -- refusing");
        err = ESP_ERR_INVALID_SIZE;
    }

    if (err != ESP_OK) {
        esp_ota_abort(handle);
        goto done;
    }

    err = esp_ota_end(handle);   // validates the image's own header/checksum
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_end (image invalid): %s", esp_err_to_name(err));
        goto done;
    }

    // Content authentication: the channel is untrusted, the image is not. Compare our streamed
    // digest to what the source declared. No declared digest = provisioning-only path; warn loud.
    {
        uint8_t got[32];
        size_t olen = 0;
        if (psa_hash_finish(&hash, got, sizeof(got), &olen) != PSA_SUCCESS || olen != 32) {
            ESP_LOGE(TAG, "psa_hash_finish failed");
            err = ESP_FAIL;
            goto done;
        }
        hash_live = false;   // finish consumed the operation
        char gh[65];
        ll_bytes_to_hex(got, 32, gh);
        if (src->have_sha256) {
            if (memcmp(got, src->expected_sha256, 32) != 0) {
                char wh[65];
                ll_bytes_to_hex(src->expected_sha256, 32, wh);
                ESP_LOGE(TAG, "SHA-256 MISMATCH: got %s want %s", gh, wh);
                err = ESP_ERR_INVALID_CRC;
            } else {
                ESP_LOGI(TAG, "SHA-256 OK: %s (%u bytes)", gh, (unsigned) total);
            }
        } else {
            ESP_LOGW(TAG, "source declared NO digest -- wrote %u bytes UNVERIFIED (sha %s)",
                     (unsigned) total, gh);
        }
        goto done;
    }

done:
    (void) esp_task_wdt_delete(NULL);
    if (hash_live) {
        psa_hash_abort(&hash);
    }
    free(buf);
    if (src->close) {
        src->close(src);
    }
    return err;
}
