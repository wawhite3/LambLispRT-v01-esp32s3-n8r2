// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- aux-storage rung.  See src_aux_storage.h.
//
// Image layout on the `storage` LittleFS partition:
//   /storage/vm_pending.img     -- a freshly staged VM to install (INSTALL path)
//   /storage/vm_golden.img      -- a pinned known-good VM (RECOVER path)
//   /storage/vm_*.img.sha256    -- optional sidecar: 64 hex chars, the image's SHA-256
// A missing/empty file is simply "no image on this rung"; a missing sidecar means the writer
// proceeds UNVERIFIED (logged loud) -- provisioning convenience, not the shipping default.

#include "src_aux_storage.h"
#include "llloader_hex.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>

#include "esp_log.h"
#include "esp_littlefs.h"

static const char *TAG = "aux_storage";

#define AUX_MOUNT   "/storage"
#define AUX_LABEL   "storage"
#define AUX_PENDING "/storage/vm_pending.img"
#define AUX_GOLDEN  "/storage/vm_golden.img"

// Single-shot loader: at most one aux source is live at a time, so file-static state is fine.
typedef struct {
    FILE *fp;
    bool  mounted;
} aux_ctx_t;

static image_source_t s_src;
static aux_ctx_t      s_ctx;

// Load the optional "<img>.sha256" sidecar into src->expected_sha256.
static void load_sidecar_sha(const char *img_path, image_source_t *src)
{
    char p[128];
    snprintf(p, sizeof(p), "%s.sha256", img_path);
    FILE *f = fopen(p, "rb");
    if (f == NULL) {
        return;  // no sidecar -> unverified path
    }
    char hex[65] = {0};
    size_t n = fread(hex, 1, 64, f);
    fclose(f);
    if (n == 64 && ll_hex_to_bytes(hex, src->expected_sha256, 32) == 0) {
        src->have_sha256 = true;
    } else {
        ESP_LOGW(TAG, "sidecar %s malformed -- ignoring", p);
    }
}

static int aux_read(image_source_t *self, uint8_t *buf, size_t max)
{
    aux_ctx_t *c = (aux_ctx_t *) self->ctx;
    size_t n = fread(buf, 1, max, c->fp);
    if (n == 0 && ferror(c->fp)) {
        return -1;
    }
    return (int) n;  // 0 = clean EOF
}

static void aux_close(image_source_t *self)
{
    aux_ctx_t *c = (aux_ctx_t *) self->ctx;
    if (c != NULL) {
        if (c->fp != NULL) {
            fclose(c->fp);
            c->fp = NULL;
        }
        if (c->mounted) {
            esp_vfs_littlefs_unregister(AUX_LABEL);
            c->mounted = false;
        }
    }
    self->ctx = NULL;
}

image_source_t *aux_storage_open(bool want_golden)
{
    esp_vfs_littlefs_conf_t conf = {
        .base_path              = AUX_MOUNT,
        .partition_label        = AUX_LABEL,
        .format_if_mount_failed = false,  // NEVER format the app FS
        .dont_mount             = false,
    };
    esp_err_t err = esp_vfs_littlefs_register(&conf);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "mount '%s' failed: %s -> rung unavailable", AUX_LABEL, esp_err_to_name(err));
        return NULL;
    }

    // RECOVER prefers the pinned golden image; INSTALL prefers a freshly staged pending image.
    const char *cands[2];
    if (want_golden) { cands[0] = AUX_GOLDEN;  cands[1] = AUX_PENDING; }
    else             { cands[0] = AUX_PENDING; cands[1] = AUX_GOLDEN;  }

    for (int i = 0; i < 2; i++) {
        struct stat st;
        if (stat(cands[i], &st) != 0 || st.st_size <= 0) {
            continue;
        }
        FILE *fp = fopen(cands[i], "rb");
        if (fp == NULL) {
            ESP_LOGW(TAG, "stat ok but open failed: %s", cands[i]);
            continue;
        }
        memset(&s_ctx, 0, sizeof(s_ctx));
        s_ctx.fp = fp;
        s_ctx.mounted = true;

        memset(&s_src, 0, sizeof(s_src));
        s_src.name       = "aux-fs";
        s_src.total_size = (size_t) st.st_size;
        s_src.ctx        = &s_ctx;
        s_src.read       = aux_read;
        s_src.close      = aux_close;
        load_sidecar_sha(cands[i], &s_src);

        ESP_LOGI(TAG, "image %s (%ld bytes)%s", cands[i], (long) st.st_size,
                 s_src.have_sha256 ? " +sha256" : " UNVERIFIED");
        return &s_src;
    }

    ESP_LOGI(TAG, "no image (looked for %s, %s)", cands[0], cands[1]);
    esp_vfs_littlefs_unregister(AUX_LABEL);
    return NULL;
}
