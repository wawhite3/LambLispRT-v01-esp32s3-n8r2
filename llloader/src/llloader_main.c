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
#include "llloader_llip.h"

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

// --- [P253] reply-only frame output -------------------------------------------------------------
// The loader SAYS things on the console it already logs to.  It answers nothing: no listener, no
// parser exposed to the wire, nothing to authenticate.  See llloader_llip.h.

//! The slot name for a frame, derived from the SUBTYPE and not the label.
//!
//! The two are not the same string.  On this loader's own table (partitions_8M_ota.csv) the label
//! happens to be `ota_0`, but on partitions_8M.csv the same subtype is labelled `app1` -- so a
//! frame built from `->label` would emit a symbol absent from the vocabulary's slot list on some
//! boards and present on others, which is the worst kind of wrong: it works where you test it.
//! Returns NULL for anything that is not an OTA slot, and the caller then emits NO frame rather
//! than a frame with a made-up field.
static const char *slot_name(const esp_partition_t *p)
{
    if (p == NULL) { return NULL; }
    switch (p->subtype) {
    case ESP_PARTITION_SUBTYPE_APP_OTA_0: return "ota_0";
    case ESP_PARTITION_SUBTYPE_APP_OTA_1: return "ota_1";
    default:                              return NULL;
    }
}

static const char *digest_name(llloader_digest_t d)
{
    switch (d) {
    case LLLOADER_DIGEST_OK:       return "ok";
    case LLLOADER_DIGEST_MISMATCH: return "mismatch";
    default:                       return "absent";
    }
}

//! `(ota-result (seq 0) (rung R) (digest D) (action A) (slot S))` -- one per completed write
//! attempt, success or failure.  The verdict a reader wants is the combination: a `mismatch`
//! digest and an `install` action say the image arrived and was rejected, which no single field
//! says on its own.
static void emit_result(const char *action, const esp_partition_t *dst)
{
    const char *slot = slot_name(dst);
    if (slot == NULL) {
        //! NOT AN OTA SLOT -- say so rather than emit a frame with an invented field.  This should
        //! not happen (the writer requires an app/ota partition), which is exactly why it is
        //! reported instead of defaulted.
        ESP_LOGW(TAG, "ota-result suppressed: target is not an OTA slot");
        return;
    }
    const char *rung = llloader_ota_last_rung();
    if (rung == NULL || rung[0] == '\0') { rung = "aux-fs"; }
    char buf[LLLOADER_MAX_FRAME_BYTES];
    llloader_wr_t w;
    llloader_wr_begin(&w, buf, sizeof(buf), "ota-result");
    llloader_wr_int(&w, "seq", 0);                                  //!< 0 = unsolicited
    llloader_wr_sym(&w, "rung",   rung);
    llloader_wr_sym(&w, "digest", digest_name(llloader_ota_last_digest()));
    llloader_wr_sym(&w, "action", action);
    llloader_wr_sym(&w, "slot",   slot);
    if (llloader_wr_end(&w) > 0) { llloader_llip_emit(buf); }
}

//! `(ota-death (seq 0) (reason R) (count N))` -- why this unit is in the loader, from the record
//! the VM's `(dead!)` left in NVS ([P255]).  Emitted once at boot, when a record exists.
//!
//! THIS IS THE FIRST TIME THE DEATH RECORD IS VISIBLE WITHOUT RUNNING THE VM, which is the point:
//! a latched unit never reaches the VM, so until now the only reader of that record was the thing
//! that could not run.
static void emit_death_if_any(void)
{
    nvs_handle_t h;
    if (nvs_open(OTA_NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) { return; }
    char   reason[LLLOADER_MAX_SYMBOL + 1] = "";
    size_t len = sizeof(reason);
    esp_err_t e = nvs_get_str(h, LLLOADER_KEY_DEATH_REASON, reason, &len);
    uint8_t count = 0;
    if (nvs_get_u8(h, LLLOADER_KEY_DEATH_COUNT, &count) != ESP_OK) { count = 0; }
    nvs_close(h);
    if (e != ESP_OK || reason[0] == '\0') { return; }   //!< no record: nothing to say
    char buf[LLLOADER_MAX_FRAME_BYTES];
    llloader_wr_t w;
    llloader_wr_begin(&w, buf, sizeof(buf), "ota-death");
    llloader_wr_int(&w, "seq", 0);
    llloader_wr_sym(&w, "reason", reason);
    llloader_wr_int(&w, "count", (int32_t) count);
    if (llloader_wr_end(&w) > 0) { llloader_llip_emit(buf); }
    else { ESP_LOGW(TAG, "ota-death not emitted: reason '%s' does not fit the frame grammar", reason); }
}

// Shared INSTALL/RECOVER core: pull an image off the ladder, stream it into ota_0, and on a
// fully verified write hand control to it. Returns true only if we rebooted (or are about to).
//! `action` is the vocabulary's action symbol (`install` / `recover`) for the emitted frame, and is
//! passed rather than derived from `what` or from `want_golden`: `what` is an uppercase log string,
//! and want_golden is a SOURCE preference that happens to correlate with RECOVER today.  Deriving
//! the action from either would be right by coincidence.
static bool fetch_write_and_boot(const esp_partition_t *ota0, bool want_golden, const char *what,
                                 const char *action)
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
    //! EMITTED ON BOTH ARMS, BEFORE THE BRANCH.  A result frame only on success would make the
    //! interesting case -- the write that failed -- the silent one, which is backwards: that is
    //! the run somebody is trying to understand.
    emit_result(action, ota0);
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
        // Clear the install-retry counter.
        //
        // THIS IS THE ONLY PLACE THE LOADER CAN CLEAR IT, AND UNTIL 2026-10-01 IT WAS UNREACHABLE.
        // The comment here used to read "belt-and-suspenders; the VM also clears it on boot".  That
        // was FALSE, and false in the direction that costs most: a reader who checked found an
        // explicit assurance that another path covered them.  `ota-boot-ok!` is the VM side, and it
        // had ZERO call sites -- every mention in the tree was documentation telling the reader to
        // call it.  Since `ota-boot-ok!` is also the only thing that ever sets VALID, the two paths
        // were not redundant, they were ONE path, and it was not wired.  `install_tries` therefore
        // only ever rose, and at OTA_MAX_INSTALL_TRIES this rung was exhausted for the life of the
        // unit ([B724]).  `scm/core/setup.scm` now calls `(ota-boot-ok!)` at the end of startup.
        install_tries_clear();
        ESP_LOGI(TAG, "NORMAL: ota_0 VALID; handoff");
        return boot_into(ota0);
    }
    // UNCONFIRMED IS NOT BROKEN -- hand off, and do NOT clear the anti-loop counter.  Two states
    // mean "nobody has told me this image is good", and they must be treated alike:
    //
    //   ESP_OTA_IMG_UNDEFINED  written through the OTA API, not yet self-confirmed.
    //   ESP_ERR_NOT_FOUND      no otadata entry for this slot AT ALL -- which is what an image
    //                          flashed with esptool looks like, i.e. EVERY development build.
    //
    // THE SECOND ONE USED TO FALL THROUGH TO "not bootable -> INSTALL", AND THAT WAS A TRAP WITH A
    // ONE-COMMAND REPRODUCTION (owner's ruling, 2026-10-01): `w3 make upload_app <env>` followed by
    // `(ota-reboot-to-loader)` reliably walked a HEALTHY board down the whole ladder -- INSTALL
    // (exhausted, see [B724]), RECOVER (no golden image on a dev board), console -- and the board
    // then needed an operator with a UART and a 1.8 MB image push.  Measured on esp32s3-n32r16-00
    // 2026-09-30, on a board that booted that very image perfectly by itself a minute earlier.
    //
    // The distinction the old code drew was not "good vs bad", it was "written by the OTA API vs
    // written by anything else", which is not a statement about the image.  The counter is still not
    // cleared here, so the anti-loop guarantee is unchanged: confirming an image remains the VM's
    // job and nothing here pretends to do it.
    if (e == ESP_OK && st == ESP_OTA_IMG_UNDEFINED) {
        ESP_LOGI(TAG, "NORMAL: ota_0 UNDEFINED (unconfirmed); handoff");
        return boot_into(ota0);
    }
    if (e == ESP_ERR_NOT_FOUND) {
        ESP_LOGI(TAG, "NORMAL: ota_0 has no otadata state (esptool-written?); unconfirmed, handoff");
        return boot_into(ota0);
    }
    ESP_LOGW(TAG, "NORMAL: ota_0 state=%d err=%s not bootable -> INSTALL",
             (int) st, esp_err_to_name(e));
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
    return fetch_write_and_boot(ota0, false, "INSTALL", "install");
}

static bool do_recover(const esp_partition_t *ota0)
{
    // RECOVER is the escalation target and biases toward a locally-pinned golden image, so it is
    // intentionally NOT gated by install_tries. If it too finds no source / fails, we drop to
    // CONSOLE (fetch_write_and_boot returns false and app_main falls through to do_console).
    ESP_LOGI(TAG, "RECOVER: ota_0 rolled back; prefer known-good golden image");
    return fetch_write_and_boot(ota0, true, "RECOVER", "recover");
}

// THIS IS A ONE-WAY DOOR TODAY, AND IT IS THE TERMINAL STATE OF THE TRUSTED ROOT.
//
// Every failed path in app_main() falls through to here (`if (!handed_off) do_console()`), and so
// does an explicit `pending_update = CONSOLE` request.  Nothing below clears `pending_update`, and
// the VM cannot run to clear it either -- so a unit that arrives here NEVER LEAVES without USB
// recovery, and from the outside it is indistinguishable from a bricked board: one warning, then
// silence forever.
//
// TWO THINGS DEPEND ON THIS BEING FINISHED, so it is not merely an unfinished feature:
//   * the VM's DEAD mode latches into this state on its Nth death ([P255]).  That latch was proven
//     on hardware for deaths 1 and 2 on 2026-09-30; death 3 was deliberately not run, because it
//     would have needed a reflash to undo.  `dead-latch-after` in scm/core/setup.scm carries the
//     matching warning.
//   * the exit from it is TBD by the owner -- a press-and-hold on a board button, sampled HERE,
//     because this is the only actor alive on a latched unit ([P255], parked).
//
// The frame reader this would be built on already exists and is tested: llloader_llip.{h,c}, 70
// host arms, `w3 test loader` ([P253] phase 1).  What is missing is the transport loop and the
// owner's ruling on whether a query is answerable before authentication is provisioned.
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
    emit_death_if_any();          //!< [P253]/[P255] say WHY we are here, before deciding anything
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
