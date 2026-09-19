// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "ll_platform_generic.h"

#include <stdio.h>
#include <string.h>

AsciiConverter ascii;

#include <stdlib.h>
#if LL_ESP32
#include "esp_heap_caps.h"
#endif

/*! B95: allocate a bulk VM payload, preferring PSRAM (see ll_platform_generic.h).
  The PSRAM probe is done ONCE and cached: on a part without PSRAM every payload would otherwise
  pay a failing heap_caps_malloc before falling back.
*/
void *ll_payload_alloc_bytes(size_t nbytes)
{
  if (nbytes == 0) nbytes = 1;      //!< new T[0] yields a unique non-null pointer; match that
#if LL_ESP32
  static int psram_ok = -1;
  if (psram_ok < 0) {
    void *probe = heap_caps_malloc(8, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    psram_ok = probe ? 1 : 0;
    if (probe) heap_caps_free(probe);
  }
  if (psram_ok) {
    void *p = heap_caps_malloc(nbytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (p) return p;                //!< PSRAM full -> fall through to internal, never fail here
  }
#endif
  return malloc(nbytes);
}

void ll_payload_free(void *p)
{
  free(p);                          //!< free() handles heap_caps_malloc blocks on the IDF
}

//! Definitions for the two globals declared beside `LambPreSettings` -- see the header for why each
//! exists.  `ll_va_list_max` MUST hold a usable value from static init: `va_list_expand()` formats
//! log lines long before `load()` is reachable (there is no filesystem yet), so a zero here would
//! cap every early message at nothing.
LambPreSettings ll_pre_settings;
LL_int32        ll_va_list_max = (LL_int32) toString_MAX_LENGTH;

//! Inclusive bounds for `va_list_max`.  The FLOOR is the start size -- a cap below the buffer the
//! function begins with would make the very first message a truncation.  The CEILING is
//! `autobuf_t`'s own `_max_`: past it `upsize()` raises (B175), and raising inside the formatter
//! means throwing while building the message the throw needs formatted.
#define LL_VA_LIST_MAX_FLOOR   1024
#define LL_VA_LIST_MAX_CEILING 65536

void LambPreSettings::load()
{
  LL_File *f = ll_file_system.open(LAMB_SETTINGS_PATH, "r");
  if (!f || !f->isOpen()) { delete f; return; }
  char line[256], key[64];
  long val;
  int len = 0, c;
  while (true) {
    c = f->read();
    if (c == '\n' || c == EOF) {
      line[len] = '\0';
      if (len > 0) {
        const char *p = line;
        while (*p == '(' || *p == ' ' || *p == '\t' || *p == '\r') p++;
        if (sscanf(p, "%63[a-zA-Z0-9_] . %ld", key, &val) == 2) {
          if      (strcmp(key, "cell_block_size")      == 0) cell_block_size      = (LL_int32) val;
          else if (strcmp(key, "extension_block_size") == 0) extension_block_size = (LL_int32) val;
          else if (strcmp(key, "gc_total_marked")      == 0) gc_total_marked      = (LL_int32) val;   //!< B247
          else if (strcmp(key, "ncg_frame_pool_size")  == 0) ncg_frame_pool_size  = (LL_int32) val;
          else if (strcmp(key, "va_list_max")          == 0) va_list_max          = (LL_int32) val;
          else if (strcmp(key, "boot_pending")         == 0) boot_pending         = (LL_int32) val;   //!< B441
        }
      }
      len = 0;
      if (c == EOF) break;
    }
    else if (len < (int) sizeof(line) - 1) line[len++] = (char) c;
  }
  f->close();
  delete f;

  //! CLAMP, THEN PUBLISH -- in that order, and never publish the raw value.  An out-of-range
  //! `va_list_max` is not a user error worth refusing a boot over, but it IS unrepresentable
  //! downstream: below the start size every message truncates, above `autobuf_t::_max_` the
  //! formatter raises while formatting.  Clamping here means no consumer has to re-check.
  if (va_list_max < LL_VA_LIST_MAX_FLOOR)   va_list_max = LL_VA_LIST_MAX_FLOOR;
  if (va_list_max > LL_VA_LIST_MAX_CEILING) va_list_max = LL_VA_LIST_MAX_CEILING;
  ll_va_list_max  = va_list_max;

  //! B441: SELF-RESET A SETTING THAT DID NOT SURVIVE ITS OWN BOOT.
  //! `gc_total_marked` is a persisted LIVE SET and the heap is sized at 2x it (ll_vm_mem.cpp).  A
  //! run that drove the live set above what this board can hold therefore writes a number the NEXT
  //! boot cannot satisfy -- measured 2026-09-16 on esp32-s3-devkitc-1: a gcpause bench at 53% fill
  //! left 75,980, the next reset asked for 151,960 cells against 2.09 MB of PSRAM, and `setup()`
  //! threw std::bad_alloc 50 times in a row.  Nothing linked the brick to the bench, because the
  //! bench had SUCCEEDED, and a firmware-only reflash does not clear it.
  //! The sentinel makes that self-correcting: if the previous boot set `boot_pending` and never
  //! cleared it, the values it was using did not survive, so drop the risky one and carry on with
  //! the built-in default.  A boot that ignores a bad hint is recoverable; a boot that dies on one
  //! is not, and it dies identically every time.
  //! ONLY `gc_total_marked` IS DISCARDED.  The others are operator intent -- a hand-set
  //! cell_block_size or va_list_max should survive a crash it probably did not cause -- whereas
  //! this one is a machine-written hint whose only defence is that it is cheap to recompute.
  if (boot_pending) {
    if (gc_total_marked > 0) {
      global_printf("[settings] previous boot did not complete with gc_total_marked=%s -- "
                    "discarding it and using the default heap size (B441)\n",
                    ascii.dec(gc_total_marked));
      gc_total_marked = 0;
    }
  }
  ll_pre_settings = *this;     //!< B417: the GC's rewrite reads this to preserve keys it does not own
  //! ARM THE SENTINEL BEFORE THE RISKY VALUE IS USED, not after.  Written here because everything
  //! downstream -- the heap sizing, the exec pool, setup.scm -- happens after load() returns, and a
  //! sentinel armed after the dangerous step would never see the failure it exists to catch.
  ll_pre_settings_write(1);
}

//! B441: one writer for the settings file, so a key added to LambPreSettings cannot be silently
//! dropped by a caller that predates it.  Best-effort: a board with no writable FS simply keeps
//! whatever it had, which is the pre-B441 behaviour and is safe.
void ll_pre_settings_write(LL_int32 boot_pending)
{
  LL_File *f = ll_file_system.open(LAMB_SETTINGS_PATH, "w");
  if (!f || !f->isOpen()) { delete f; return; }
  AsciiConverter b1, b2, b3, b4, b5, b6;
  auto put = [&](const char *t) { f->write((const byte *) t, strlen(t)); };
  put("; Settings-Lamb.scm -- auto-written by the VM.  Reboot required.\n");
  put("; boot_pending 1 means a boot was attempted with these values and did not finish (B441).\n");
  put("((cell_block_size . ");      put(b1.dec(ll_pre_settings.cell_block_size));      put(")\n");
  put(" (extension_block_size . "); put(b2.dec(ll_pre_settings.extension_block_size)); put(")\n");
  put(" (ncg_frame_pool_size . ");  put(b3.dec(ll_pre_settings.ncg_frame_pool_size));  put(")\n");
  put(" (va_list_max . ");          put(b4.dec(ll_pre_settings.va_list_max));          put(")\n");
  put(" (gc_total_marked . ");      put(b5.dec(ll_pre_settings.gc_total_marked));      put(")\n");
  put(" (boot_pending . ");         put(b6.dec(boot_pending));                         put("))\n");
  f->close();
  delete f;
}

//! B441: the VM is up, so whatever it read was survivable.  Clearing the sentinel is what makes the
//! next boot TRUST the stored values rather than discard them -- without this the mechanism would
//! reset `gc_total_marked` on every single boot and the persistence would be pointless.
void ll_settings_boot_ok(void)
{
  if (!ll_pre_settings.boot_pending && ll_pre_settings.gc_total_marked == 0) return;  //!< nothing armed
  ll_pre_settings.boot_pending = 0;
  ll_pre_settings_write(0);
}

//! B70: state for ll_catch()'s one-line-per-ERROR logging (see the macro in ll_platform_generic.h).
//! Not thread-local and not reset anywhere: it only ever needs to answer "is this the same error I
//! just logged?", and a stale value from a previous unwind can at worst suppress one duplicate line
//! before the counter resets on the next distinct object.
const void *ll_catch_last_err = 0;
int         ll_catch_repeats  = 0;
