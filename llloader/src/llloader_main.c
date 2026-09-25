// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- the Tier-1 `factory` app: a tiny, trusted, Arduino-core-free
// ESP-IDF recovery root.  It is NOT in the normal boot path: otadata points
// straight at ota_0 (the LambLisp VM), and this app runs ONLY as a fallback --
// first-ever boot (ota_0 empty) or after an ESP-IDF native rollback flipped
// otadata back to factory.
//
// Its single job: get a VALID VM image into ota_0 and hand control to it
// (set_boot_partition(ota_0) + reboot).  Everything here is a skeleton stub;
// the image-source ladder (aux-storage -> network -> BLE/UART console) and the
// OTA writer land in Ph2b/Ph6.
//
// Constant-overhead OTA justification: the VM self-updates in place (N bytes);
// this loader is the fixed-k fallback, so total cost is N + k, never the
// universal 2N of an A/B-only scheme on 4 MB parts.

#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_system.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"

#include "nvs.h"
#include "nvs_flash.h"

#include "image_source.h"
#include "ota_writer.h"

static const char *TAG = "llloader";

// --- OTA NVS contract -------------------------------------------------------
// Namespace "ota-p125" holds the loader<->VM handshake.  Key "pending_update" is a
// u8 request set by the VM (or a provisioning tool) before rebooting into us:
//   0 = none            -> NORMAL  (nothing to do; try to boot ota_0 if valid)
//   1 = install         -> INSTALL (fetch + write ota_0 from the source ladder)
//   2 = recover         -> RECOVER (ota_0 bad/rolled-back; re-fetch a known-good)
//   3 = console         -> CONSOLE (operator-driven BLE/UART fallback)
#define OTA_NVS_NAMESPACE "ota-p125"
#define OTA_KEY_PENDING   "pending_update"

// Install-retry anti-loop counter (OTA). DISTINCT from ESP-IDF's native otadata rollback
// (PENDING_VERIFY / mark_valid), which independently reverts a VM that boots but never confirms.
// This counter guards the *install* side: without it, a VM image that keeps failing would be
// re-installed from the ladder forever (fall back to factory -> re-install -> bad -> fall back...).
// Semantics: the loader increments it on ENTERING an install; once it exceeds the max, the loader
// stops re-installing the same failing image and escalates (RECOVER golden, else CONSOLE). It is
// cleared when a healthy image is confirmed -- by do_normal here (ota_0 state VALID) and, as the
// real "the installed image actually boots" proof, by the VM on the host side (OTA item D:
// (ota-boot-ok!) at VM startup clears both pending_update and install_tries).
#define OTA_KEY_INSTALL_TRIES "install_tries"
#define OTA_MAX_INSTALL_TRIES 3

typedef enum {
    LOADER_NORMAL  = 0,
    LOADER_INSTALL = 1,
    LOADER_RECOVER = 2,
    LOADER_CONSOLE = 3,
} loader_action_t;

// --- Small NVS u8 helpers (namespace "ota-p125") --------------------------------
static uint8_t ota_get_u8(const char *key, uint8_t dflt)
{
    nvs_handle_t h;
    if (nvs_open(OTA_NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) return dflt;
    uint8_t v = dflt;
    if (nvs_get_u8(h, key, &v) != ESP_OK) v = dflt;
    nvs_close(h);
    return v;
}

static void ota_set_u8(const char *key, uint8_t val)
{
    nvs_handle_t h;
    if (nvs_open(OTA_NVS_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGW(TAG, "nvs_open rw failed; cannot persist %s", key);
        return;
    }
    esp_err_t e = nvs_set_u8(h, key, val);
    if (e == ESP_OK) e = nvs_commit(h);
    if (e != ESP_OK) ESP_LOGW(TAG, "nvs write %s: %s", key, esp_err_to_name(e));
    nvs_close(h);
}

static void ota_erase_key(const char *key)
{
    nvs_handle_t h;
    if (nvs_open(OTA_NVS_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) return;
    esp_err_t e = nvs_erase_key(h, key);   // ESP_ERR_NVS_NOT_FOUND is benign
    if (e == ESP_OK) nvs_commit(h);
    nvs_close(h);
}

// Returns true when we have already tried to install too many times (caller must escalate rather
// than re-install). Otherwise records this attempt (increment + persist) and returns false.
static bool install_tries_exhausted(const char *what)
{
    uint8_t tries = ota_get_u8(OTA_KEY_INSTALL_TRIES, 0);
    if (tries >= OTA_MAX_INSTALL_TRIES) {
        ESP_LOGE(TAG, "%s: install_tries=%u >= max %d -- NOT re-installing; escalating",
                 what, (unsigned) tries, OTA_MAX_INSTALL_TRIES);
        return true;
    }
    ota_set_u8(OTA_KEY_INSTALL_TRIES, (uint8_t) (tries + 1));
    ESP_LOGW(TAG, "%s: install attempt %u of %d",
             what, (unsigned) (tries + 1), OTA_MAX_INSTALL_TRIES);
    return false;
}

static void install_tries_clear(void)
{
    ota_erase_key(OTA_KEY_INSTALL_TRIES);
}

// --- Partition inspection ----------------------------------------------------
// Log the running slot and the state of ota_0 so a serial watcher can see why
// the loader woke up.  A valid, non-empty ota_0 with a good OTA state means we
// can just boot it; anything else escalates to INSTALL/RECOVER.
static const esp_partition_t *inspect_partitions(void)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    ESP_LOGI(TAG, "running slot: %s @ 0x%08lx (%lu bytes)",
             running ? running->label : "?",
             (unsigned long) (running ? running->address : 0),
             (unsigned long) (running ? running->size : 0));

    const esp_partition_t *ota0 = esp_partition_find_first(
        ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_0, NULL);
    if (ota0 == NULL) {
        ESP_LOGW(TAG, "ota_0 partition not found in table");
        return NULL;
    }

    esp_ota_img_states_t st = ESP_OTA_IMG_UNDEFINED;
    esp_err_t err = esp_ota_get_state_partition(ota0, &st);
    ESP_LOGI(TAG, "ota_0 @ 0x%08lx (%lu bytes) state=%d err=%s",
             (unsigned long) ota0->address, (unsigned long) ota0->size,
             (int) st, esp_err_to_name(err));
    return ota0;
}

// --- NVS request read --------------------------------------------------------
static loader_action_t read_pending_action(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(OTA_NVS_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) {
        ESP_LOGI(TAG, "no %s namespace yet (%s) -> NORMAL",
                 OTA_NVS_NAMESPACE, esp_err_to_name(err));
        return LOADER_NORMAL;
    }
    uint8_t pending = LOADER_NORMAL;
    err = nvs_get_u8(h, OTA_KEY_PENDING, &pending);
    nvs_close(h);
    if (err != ESP_OK) {
        ESP_LOGI(TAG, "%s unset (%s) -> NORMAL",
                 OTA_KEY_PENDING, esp_err_to_name(err));
        return LOADER_NORMAL;
    }
    ESP_LOGI(TAG, "%s = %u", OTA_KEY_PENDING, (unsigned) pending);
    return (loader_action_t) pending;
}

// --- Action stubs ------------------------------------------------------------
// Each returns true if it handed off (rebooted / will reboot), false to fall
// through to CONSOLE.  All real logic (source ladder, OTA writer, image auth)
// is deferred; these only trace the intended control flow.

// Boot into ota_0: mark it the boot partition and restart. Never returns on success.
static bool boot_into(const esp_partition_t *ota0)
{
    esp_err_t err = esp_ota_set_boot_partition(ota0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "set_boot_partition(%s): %s", ota0->label, esp_err_to_name(err));
        return false;
    }
    ESP_LOGI(TAG, "handoff -> %s @ 0x%08lx; restarting",
             ota0->label, (unsigned long) ota0->address);
    esp_restart();   // no return
    return true;
}

// Shared INSTALL/RECOVER core: pull an image off the ladder, stream it into ota_0, and on a
// fully verified write hand control to it. Returns true only if we rebooted (or are about to).
static bool fetch_write_and_boot(const esp_partition_t *ota0, bool want_golden, const char *what)
{
    if (ota0 == NULL) {
        ESP_LOGE(TAG, "%s: no ota_0 partition -- cannot install", what);
        return false;
    }
    image_source_t *src = llloader_select_image_source(want_golden);
    if (src == NULL) {
        ESP_LOGW(TAG, "%s: no image source available -> CONSOLE", what);
        return false;
    }
    esp_err_t err = llloader_ota_write(ota0, src);   // consumes + closes src
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "%s: write failed (%s) -> CONSOLE", what, esp_err_to_name(err));
        return false;
    }
    ESP_LOGI(TAG, "%s: image verified in ota_0; booting it", what);
    return boot_into(ota0);
}

static bool do_install(const esp_partition_t *ota0);
static bool do_recover(const esp_partition_t *ota0);

static bool do_normal(const esp_partition_t *ota0)
{
    // otadata should already point at ota_0; factory only runs on fallback. If ota_0 already
    // holds a valid image, just hand off. If it's empty/undefined, escalate to INSTALL.
    if (ota0 == NULL) {
        ESP_LOGW(TAG, "NORMAL: no ota_0 -> escalate to INSTALL");
        return do_install(ota0);
    }
    esp_ota_img_states_t st = ESP_OTA_IMG_UNDEFINED;
    esp_err_t e = esp_ota_get_state_partition(ota0, &st);
    if (e == ESP_OK && st == ESP_OTA_IMG_VALID) {
        // ota_0 is confirmed-good: the system is healthy, so any prior install succeeded.
        // Clear the install-retry counter (belt-and-suspenders; the VM also clears it on boot).
        install_tries_clear();
        ESP_LOGI(TAG, "NORMAL: ota_0 VALID; handoff");
        return boot_into(ota0);
    }
    if (e == ESP_OK && st == ESP_OTA_IMG_UNDEFINED) {
        // Written but not yet self-confirmed: bootable, but do NOT clear the anti-loop counter --
        // this image has not yet proven it boots (that is the VM's mark-valid job).
        ESP_LOGI(TAG, "NORMAL: ota_0 UNDEFINED (unconfirmed); handoff");
        return boot_into(ota0);
    }
    ESP_LOGW(TAG, "NORMAL: ota_0 state=%d not bootable -> INSTALL", (int) st);
    return do_install(ota0);
}

static bool do_install(const esp_partition_t *ota0)
{
    // Anti-loop: if we've already burned our install attempts on a failing image, stop
    // re-installing it and escalate to RECOVER (which prefers a known-good golden image).
    if (install_tries_exhausted("INSTALL")) {
        ESP_LOGW(TAG, "INSTALL exhausted -> escalate to RECOVER (golden)");
        return do_recover(ota0);
    }
    ESP_LOGI(TAG, "INSTALL: fetch VM from source ladder -> ota_0");
    return fetch_write_and_boot(ota0, false, "INSTALL");
}

static bool do_recover(const esp_partition_t *ota0)
{
    // RECOVER is the escalation target and biases toward a locally-pinned golden image, so it is
    // intentionally NOT gated by install_tries. If it too finds no source / fails, we drop to
    // CONSOLE (fetch_write_and_boot returns false and app_main falls through to do_console).
    ESP_LOGI(TAG, "RECOVER: ota_0 rolled back; prefer known-good golden image");
    return fetch_write_and_boot(ota0, true, "RECOVER");
}

static void do_console(void)
{
    ESP_LOGW(TAG, "CONSOLE: operator fallback (BLE/UART) -- Ph2b stub; idling");
    // TODO(Ph2b): NimBLE or UART mini-REPL to accept an image push manually.
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "OTA llloader boot (factory / trusted recovery root)");

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "nvs erase+reinit (%s)", esp_err_to_name(err));
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    const esp_partition_t *ota0 = inspect_partitions();
    loader_action_t action = read_pending_action();

    bool handed_off = false;
    switch (action) {
    case LOADER_NORMAL:  handed_off = do_normal(ota0);      break;
    case LOADER_INSTALL: handed_off = do_install(ota0);     break;
    case LOADER_RECOVER: handed_off = do_recover(ota0);     break;
    case LOADER_CONSOLE: default:                           break;
    }

    if (!handed_off) {
        do_console();  // never returns
    }
}
