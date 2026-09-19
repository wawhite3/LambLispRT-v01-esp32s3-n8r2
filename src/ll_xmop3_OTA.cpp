// Copyright 2026 by Frobenius Norm LLC 2026-07-08 00:00:00
//
// OTA VM-side handshake -- the LambLisp half of the loader<->VM contract.
//
// The `factory` llloader (a separate ESP-IDF app; see w3_loader/) and this VM run at different
// times with a reboot boundary between them, so the VM passes its request to the loader through the
// NVS namespace "ota-p125" and then reboots into `factory`.  This file exposes that contract as a small
// set of Scheme builtins:
//
//   (ota-request-install!)          -- pending_update = 1  (INSTALL: fetch+write a new ota_0)
//   (ota-request-recover!)          -- pending_update = 2  (RECOVER: re-fetch a known-good image)
//   (ota-request-console!)          -- pending_update = 3  (CONSOLE: operator BLE/UART fallback)
//   (ota-set-network! ssid pass url)    -- write wifi_ssid / wifi_pass / img_url for the network rung
//   (ota-reboot-to-loader)          -- set otadata -> factory, then esp_restart (never returns)
//   (ota-boot-ok!)                  -- confirm THIS image is healthy: cancel the native rollback
//                                       and clear pending_update + install_tries (the anti-loop
//                                       counter owned by the loader, item C).  Call early in a
//                                       known-good boot; it is the true "the installed VM boots"
//                                       proof the loader's install-retry guard waits for.
//
// All NVS / OTA work is ESP-IDF-only.  On the host (linux) builds the C++ below compiles to safe
// no-ops that return #f (or #t for boot-ok!, which is vacuously true off-device), so the VM builds
// and runs GREEN on x86 without any of the ESP-IDF headers.

#include "LambLisp.h"

#if LL_ESP32 || LL_ESP32S3
#include "nvs.h"
#include "nvs_flash.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
//! @defgroup xmop3_loader Over-the-Air Firmware Updates
//! @ingroup xmop3
//! @brief LambLisp Boot-Loader Handshake (OTA) builtins.
//! @{

#define OTA_NS "ota-p125"

// The VM's own startup (or the Arduino core / WiFi) normally inits NVS; do it here too, idempotently,
// so these builtins work even if called before anything else touched NVS.  nvs_flash_init() returns
// ESP_OK when already initialized, so the one-shot guard just avoids repeated work.
static void ota_ensure_nvs(void)
{
  static bool done = false;
  if (done) return;
  esp_err_t e = nvs_flash_init();
  if (e == ESP_ERR_NVS_NO_FREE_PAGES || e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    nvs_flash_erase();
    nvs_flash_init();
  }
  done = true;
}

static esp_err_t ota_set_u8(const char *key, uint8_t v)
{
  nvs_handle_t h;
  esp_err_t e = nvs_open(OTA_NS, NVS_READWRITE, &h);
  if (e != ESP_OK) return e;
  e = nvs_set_u8(h, key, v);
  if (e == ESP_OK) e = nvs_commit(h);
  nvs_close(h);
  return e;
}

static esp_err_t ota_set_str(const char *key, const char *val)
{
  nvs_handle_t h;
  esp_err_t e = nvs_open(OTA_NS, NVS_READWRITE, &h);
  if (e != ESP_OK) return e;
  e = nvs_set_str(h, key, val ? val : "");
  if (e == ESP_OK) e = nvs_commit(h);
  nvs_close(h);
  return e;
}

static esp_err_t ota_erase(const char *key)
{
  nvs_handle_t h;
  esp_err_t e = nvs_open(OTA_NS, NVS_READWRITE, &h);
  if (e != ESP_OK) return e;
  e = nvs_erase_key(h, key);   // ESP_ERR_NVS_NOT_FOUND is benign
  if (e == ESP_OK || e == ESP_ERR_NVS_NOT_FOUND) e = nvs_commit(h);
  nvs_close(h);
  return (e == ESP_ERR_NVS_NOT_FOUND) ? ESP_OK : e;
}
#endif  // LL_ESP32 || LL_ESP32S3

// --- request setters: write pending_update, return #t on success ------------
//! @brief Internal helper: write `pending_update`=`code` to the NVS "ota-p125" namespace; #t on success, #f off-device.
static Sexpr_t ota_mop3_request_pending(Lamb &lamb, Sexpr_t env_exec, uint8_t code)
{
#if LL_ESP32 || LL_ESP32S3
  ota_ensure_nvs();
  return lamb.mk_bool(ota_set_u8("pending_update", code) == ESP_OK, env_exec);
#else
  (void) code;
  return lamb.mk_bool(false, env_exec);
#endif
}

//! @brief `(ota-request-install!)` — ask the loader to INSTALL (`pending_update`=1: fetch + write a new `ota_0`). Returns #t on success, #f off-device.
Sexpr_t ota_mop3_request_install(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  (void) sexpr;
  return ota_mop3_request_pending(lamb, env_exec, 1);
}

//! @brief `(ota-request-recover!)` — ask the loader to RECOVER (`pending_update`=2: re-fetch a known-good image). Returns #t on success, #f off-device.
Sexpr_t ota_mop3_request_recover(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  (void) sexpr;
  return ota_mop3_request_pending(lamb, env_exec, 2);
}

//! @brief `(ota-request-console!)` — ask the loader for the CONSOLE fallback (`pending_update`=3: operator BLE/UART). Returns #t on success, #f off-device.
Sexpr_t ota_mop3_request_console(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  (void) sexpr;
  return ota_mop3_request_pending(lamb, env_exec, 3);
}

//! @brief `(ota-set-network! ssid pass url)` — write the network-rung config keys `wifi_ssid` / `wifi_pass` / `img_url` (all strings) to NVS. Returns #t on success, #f off-device.
Sexpr_t ota_mop3_set_network(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::ota_mop3_set_network()");
  const char *ssid = lamb.car(sexpr)->mustbe_any_str_t()->any_str_get_chars();
  const char *pass = lamb.car(lamb.cdr(sexpr))->mustbe_any_str_t()->any_str_get_chars();
  const char *url  = lamb.car(lamb.cdr(lamb.cdr(sexpr)))->mustbe_any_str_t()->any_str_get_chars();
#if LL_ESP32 || LL_ESP32S3
  ota_ensure_nvs();
  esp_err_t e = ota_set_str("wifi_ssid", ssid);
  if (e == ESP_OK) e = ota_set_str("wifi_pass", pass);
  if (e == ESP_OK) e = ota_set_str("img_url",  url);
  return lamb.mk_bool(e == ESP_OK, env_exec);
#else
  (void) ssid; (void) pass; (void) url;
  return lamb.mk_bool(false, env_exec);
#endif
}

//! @brief `(ota-reboot-to-loader)` — point otadata at the `factory` llloader partition and `esp_restart`; never returns on device. Returns #f if there is no factory partition (or off-device).
Sexpr_t ota_mop3_reboot_to_loader(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::ota_mop3_reboot_to_loader()");
  (void) sexpr;
#if LL_ESP32 || LL_ESP32S3
  const esp_partition_t *factory = esp_partition_find_first(
      ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_FACTORY, NULL);
  if (factory == NULL) {
    lamb.log("%s no factory partition -- cannot enter loader\n", me);
    return lamb.mk_bool(false, env_exec);
  }
  esp_err_t e = esp_ota_set_boot_partition(factory);
  if (e != ESP_OK) {
    lamb.log("%s set_boot_partition(factory) failed: %s\n", me, esp_err_to_name(e));
    return lamb.mk_bool(false, env_exec);
  }
  lamb.log("%s handing off to factory llloader; restarting\n", me);
  esp_restart();      // never returns
  return HASHT;       // unreachable
#else
  return lamb.mk_bool(false, env_exec);
#endif
}

//! @brief `(ota-boot-ok!)` — confirm THIS image is healthy: cancel the native OTA rollback and clear `pending_update` + `install_tries` (the loader's anti-loop counter). The loader's install-retry guard waits for this. Returns #t (vacuously #t off-device).
Sexpr_t ota_mop3_boot_ok(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::ota_mop3_boot_ok()");
  (void) sexpr;
#if LL_ESP32 || LL_ESP32S3
  ota_ensure_nvs();
  esp_ota_mark_app_valid_cancel_rollback();   // native PENDING_VERIFY -> VALID (benign if disabled)
  ota_erase("pending_update");
  ota_erase("install_tries");
  lamb.log("%s VM marked healthy; cleared pending_update + install_tries\n", me);
  return lamb.mk_bool(true, env_exec);
#else
  return lamb.mk_bool(true, env_exec);
#endif
}

// ---------------------------------------------------------------------------
// Installer (always defined; host build registers no-op variants).
// ---------------------------------------------------------------------------
//! @brief Installer: bind the OTA loader-handshake builtins (`ota-request-install!` / `-recover!` / `-console!`, `ota-set-network!`, `ota-reboot-to-loader`, `ota-boot-ok!`) into `env_target`.
Sexpr_t ota_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::ota_install_mop3()");
  ll_try {
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } procs[] = {
      { ota_install_mop3,           "ota.install-mop3",      false },
      { ota_mop3_request_install,   "ota-request-install!",  false },
      { ota_mop3_request_recover,   "ota-request-recover!",  false },
      { ota_mop3_request_console,   "ota-request-console!",  false },
      { ota_mop3_set_network,           "ota-set-network!",          false },
      { ota_mop3_reboot_to_loader,  "ota-reboot-to-loader",  false },
      { ota_mop3_boot_ok,           "ota-boot-ok!",          false },
    };
    const int Nprocs = sizeof(procs)/sizeof(procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nprocs);
    for (int i = 0; i < Nprocs; i++) {
      const auto &p = procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
    return NIL;
  }
  ll_catch();
}
//! @}
