// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#if LL_ESP32

#include "ll_platform_generic.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
//! esp_chip_info.h / esp_flash.h must be included EXPLICITLY.  Up to ESP-IDF 4.4 both rode in
//! transitively via esp_system.h; IDF 5 stopped doing that, and the failure names the SYMBOLS
//! rather than the header -- "'esp_chip_info_t' was not declared in this scope",
//! "'esp_flash_get_size' was not declared", "'CHIP_FEATURE_EMB_FLASH' was not declared" -- which
//! reads like the API was removed rather than like a missing #include.  Both headers exist in 4.4
//! as well, so including them unconditionally is correct on either IDF.
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_idf_version.h"   //!< ESP_IDF_VERSION_MAJOR -- esp_chip_info_t differs across IDF 4/5

void LambPlatform::begin()
{
  ME("LambPlatform::LambPlatform()");
  
  loop_start_ms = millis();
  loop_start_us = micros();
  identification();
}

void LambPlatform::end() {}

void LambPlatform::loop(void)	//call this 1st thing in Lamb::loop().
{
  loop_start_ms = millis();
  loop_start_us = micros();
}

void LambPlatform::reboot()			{ esp_restart(); }
#if LL_ARDUINO && !LL_ESP_ARDUINO
//! LLArduino timing on the ESP32, over Apache-2.0 IDF primitives -- P176 Tier 1.  The vendor
//! Arduino core is NOT linked in this build, so millis/micros/delay come from esp_timer here.
//! delay_ms YIELDS (vTaskDelay), matching what Arduino's own delay() does under FreeRTOS: other
//! tasks, the idle task and the watchdog run during a delay -- a busy-wait would starve them on a
//! real-time runtime.  delayMicroseconds / delay_us BUSY-WAIT (esp_rom_delay_us) because sub-tick
//! precision cannot come from vTaskDelay, whose resolution is one FreeRTOS tick (typ. 1 ms).  This
//! REPLACES the shared POSIX delayMicroseconds in ll_llarduino_null.cpp, which is guarded off on
//! LL_ESP32 for exactly this reason.
#include "esp_timer.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
unsigned long micros(void)                { return (unsigned long) esp_timer_get_time(); }
unsigned long millis(void)                { return micros() / 1000UL; }
void delay_us(unsigned long us)           { esp_rom_delay_us(us); }
void delayMicroseconds(unsigned long us)  { esp_rom_delay_us(us); }
void delay_ms(unsigned long ms)           { vTaskDelay(pdMS_TO_TICKS(ms)); }
#else
void delay_ms(unsigned long ms)			{ delay(ms); }
#endif
const char *LambPlatform::name()		{ return "ESP32"; }
LL_int32 LambPlatform::free_heap()			{ return (LL_int32) esp_get_free_heap_size(); }
//! B129: cell blocks come from PSRAM (heap_caps_malloc MALLOC_CAP_SPIRAM, ll_vm_mem.cpp), so the
//! expansion guard must measure PSRAM -- not the aggregate.  Falls back to internal when the part
//! has no PSRAM, matching expand()'s own allocation fallback.
LL_int32 LambPlatform::cell_pool_free()
{
  size_t ps = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
  if (ps > 0) return (LL_int32) ps;
  return (LL_int32) heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
}
//! [B508] INTERNAL DRAM, SEPARATELY.  `free_heap()` is `esp_get_free_heap_size()` -- the AGGREGATE
//! of internal DRAM and PSRAM -- and `cell_pool_free()` reports PSRAM.  Neither can see internal
//! DRAM going, and that is where lwIP puts its small allocations.
//! lwIP's PCBs and socket structures are a few hundred bytes, so they fall UNDER the runtime
//! internal-DRAM threshold set in `identification()` below -- read that block for the number;
//! do not restate it here.  A TCP send buffer (CONFIG_LWIP_TCP_SND_BUF_DEFAULT=5744) does not,
//! and CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP is unset, so nothing steers lwIP to PSRAM wholesale.
//! B508 could not be diagnosed without this number -- the value existed in `ll_heap_note()`'s boot
//! line and was reachable from C++ only, so a Scheme probe could watch the one heap that was fine.
LL_int32 LambPlatform::free_internal()   { return (LL_int32) heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT); }
LL_int32 LambPlatform::free_dma()        { return (LL_int32) heap_caps_get_free_size(MALLOC_CAP_DMA); }
LL_int32 LambPlatform::free_stack()		{ return (LL_int32) uxTaskGetStackHighWaterMark(NULL); }
void  LambPlatform::rand(byte *buf, LL_int32 len)	{ esp_fill_random(buf, (size_t) len); }


Bool_t LambPlatform::heap_integrity_check(Bool_t complain)
{
  //every(10000, global_printf("LambPlatform::heap_integrity_check() happening now\n")); return heap_caps_check_integrity_all(true);
  const char msg[] = "==> LambPlatform::heap_integrity_check() failed <==\n";
  bool valid = heap_caps_check_integrity_all(complain);
  if (!valid) {
    LambStdio.write(msg, strlen(msg));
    delay(100);
  }
  
  return valid;
}

void LambPlatform::identification(void)
{
  ME("LambPlatform::identification()");
  
  const char *chip_names[] = { "NONE0", "ESP32", "ESP32_S2", "NONE3", "NONE4", "ESP32-C3","ESP32-H2", "NONE7", "NONE8", "ESP32-S3", "NONE10" };
  const unsigned Nchips    = sizeof(chip_names)/sizeof(chip_names[0]);

  esp_chip_info_t chip_info;
  esp_chip_info(&chip_info);
  if (chip_info.model >= Nchips) chip_info.model = (esp_chip_model_t) 0;
  
  bool hasFlash = chip_info.features & CHIP_FEATURE_EMB_FLASH; 
  uint32_t flash_size = 0;

  if (esp_flash_get_size(NULL, &flash_size) != ESP_OK) global_printf("%s Get flash size failed", me);

  //! esp_chip_info_t CHANGED SHAPE IN ESP-IDF 5, and the two fields did not merely get renamed --
  //! `revision` CHANGED MEANING.  Up to 4.4 it was a uint8_t holding the wafer MAJOR version, with a
  //! separate uint16_t `full_revision` holding MXX (major*100 + minor).  IDF 5 deleted
  //! `full_revision` and widened `revision` to uint16_t carrying MXX itself.  So a build that just
  //! drops the missing field does NOT keep printing the same thing: `rev` silently changes from 0
  //! to 0..99-scaled MXX, and nothing warns, because both are integers that print fine.  Derive
  //! both values explicitly so the two IDFs produce identical output.
#if ESP_IDF_VERSION_MAJOR >= 5
  const unsigned chip_rev_major = (unsigned) chip_info.revision / 100u;   //!< MXX -> M
  const unsigned chip_rev_full  = (unsigned) chip_info.revision;          //!< already MXX
#else
  const unsigned chip_rev_major = (unsigned) chip_info.revision;          //!< 4.x: major only
  const unsigned chip_rev_full  = (unsigned) chip_info.full_revision;     //!< 4.x: MXX
#endif

  global_printf("\n");
  global_printf("%s IDF_target : %s, chip_model : %d, model_name %s, rev %u, full_rev %u\n",
		me, CONFIG_IDF_TARGET, chip_info.model, chip_names[((unsigned) chip_info.model) % Nchips], chip_rev_major, chip_rev_full);
  global_printf("%s cores : %d, embedded flash : %lu, features 0x%08x\n",
		me, chip_info.cores, (unsigned long) flash_size, chip_info.features);

#define yesno(_tf_) ((_tf_) ? "yes" : "no")
  global_printf("%s EMB_FLASH : %s, EMB_PSRAM : %s, 80211 : %s, 802154 : %s, BT : %s, BLE : %s\n",
		me,
		yesno(chip_info.features & CHIP_FEATURE_EMB_FLASH),
		yesno(chip_info.features & CHIP_FEATURE_EMB_PSRAM),
		yesno(chip_info.features & CHIP_FEATURE_WIFI_BGN),
		yesno(chip_info.features & CHIP_FEATURE_IEEE802154),
		yesno(chip_info.features & CHIP_FEATURE_BT),
		yesno(chip_info.features & CHIP_FEATURE_BLE)
		);
#undef yesno
  //! THE INTERNAL-DRAM THRESHOLD FOR THE WHOLE PROJECT IS SET HERE, AND IT IS 1 KB.  Every
  //! capability-less allocation -- plain `new`, `malloc`, an Arduino `String`, a `realloc` --
  //! resolves to `heap_caps_malloc_default()`, which consults this one static and TRIES PSRAM
  //! FIRST only for sizes STRICTLY GREATER than the limit.  At or below it, internal DRAM first.
  //!
  //! **DO NOT QUOTE `CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL` AS THE THRESHOLD.**  That symbol is
  //! only the value the IDF installs at boot: `esp_psram.c` calls
  //! `heap_caps_malloc_extmem_enable(CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL)` under
  //! `#if CONFIG_SPIRAM_USE_MALLOC` while bringing PSRAM up.  The Arduino sdkconfig sets it to
  //! 4096.  THIS CALL RUNS LATER AND OVERWRITES IT WITH 1024 -- the same static, last writer
  //! wins -- on EVERY ESP32 env, since it is inside the file-wide `#if LL_ESP32`, reached from
  //! `LambPlatform::begin()`, with no per-part guard: S3, classic WROVER and RISC-V C5 alike.
  //! Three comments in this tree quoted 4096 and were wrong by 4x for months, each written by
  //! someone who read the config and never found this line.  They now point here rather than
  //! carry their own copy; if you change the argument, this block is the one place to change.
  //!
  //! WHY 1 KB, WHICH THE ORIGINAL `//1k, why?` DID NOT SAY.  `git blame` returns the ROOT commit
  //! (60bba20f, 2026-01-01) -- the line is older than this repository and has no recorded
  //! rationale.  But the DIRECTION answers it: lowering the limit moves the 1 KB - 4 KB band OUT
  //! of internal DRAM and into PSRAM, so it BUYS BACK internal DRAM.  That is the only account
  //! this project ever runs dry, and three measurements say so -- [B95] (setup.scm drained
  //! ~115 KB and finished with 1176 bytes free while 1.7 MB of PSRAM sat unused; LittleFS then
  //! failed ESP_ERR_NO_MEM 257, because flash reads bounce through internal DRAM), [P211]
  //! (~1,600 interned symbol names, tens of bytes each, ~17 KB parked below the threshold on a
  //! WROVER that finishes boot with 3,364 bytes free), and [B411] (running it dry is a MUTE BOOT
  //! LOOP, not an error).  So: deduced from the direction of the change and consistent with
  //! everything measured, NOT a rationale anyone wrote down.  Treat it as such.
  //!
  //! IT IS A PREFERENCE, NOT A PIN -- AND THE TREE HAS BEEN OVERSTATING THIS.  After choosing a
  //! pool by size, `heap_caps_malloc_default()` does:
  //!
  //!     if (r==NULL && size > 0) { /* try again while being less picky */
  //!         r = heap_caps_malloc_base(size, MALLOC_CAP_DEFAULT); }
  //!
  //! so a sub-1 KB allocation LANDS IN PSRAM when internal DRAM is exhausted.  Nothing says
  //! "FORCED" or "pinned", whatever the older comments claim.  The consequence is the nasty one:
  //! internal exhaustion DOES NOT FAIL AT THE MALLOC THAT EXHAUSTED IT.  It degrades silently,
  //! and the error surfaces at some later caller that genuinely needed DMA-capable or
  //! interrupt-safe memory -- a different subsystem, a different stack trace, no mention of the
  //! allocation that actually spent the budget.  Assume this shape before blaming the reporter.
  //!
  //! THE DEFAULT IS "EXTERNAL DISABLED", which is why the call takes a limit at all: the static
  //! initialises to MALLOC_DISABLE_EXTERNAL_ALLOCS (-1), in which state EVERY capability-less
  //! allocation is internal-only at any size.  Enabling PSRAM for `malloc` and setting the
  //! threshold are one operation, so there is no way to say "enable, keep the current limit".
  //!
  //! UNRELATED TO `-mfix-esp32-psram-cache-issue`, though both are PSRAM and both are ours.  That
  //! flag is the CPU-3.2 silicon erratum workaround for ESP32-classic (LX6) rev < 3 -- a
  //! code-generation filter that suppresses instruction sequences which corrupt external memory.
  //! It changes what the compiler EMITS, not where the allocator PUTS things, and it lives in
  //! `chip_flags` on the two LX6 boards in `w3_pio/boards.json` (see the `_psram_note` there:
  //! it must not return to the shared block, because the S3 toolchain does not have the option).
  //!
  //! THE RULE THAT FOLLOWS: allocate a bulk VM payload with an explicit `MALLOC_CAP_SPIRAM` --
  //! use `ll_payload_alloc_bytes` -- never with `new`/`malloc`.  Sizing something past a
  //! threshold is NOT a way to move it to PSRAM, and for anything allocated with an explicit
  //! capability (the UART rings, lwIP's pools) this threshold does not apply at all.  Lowering
  //! the argument further would push MORE traffic into PSRAM, which is slower and not
  //! DMA-capable; it has never been measured, so it is not a free win either way.
  //!
  //! NOTE THE API IS UNDOCUMENTED UPSTREAM: `heap_caps_malloc_extmem_enable` appears in
  //! `esp_heap_caps.h` and in `heap_caps.c`, and NOWHERE in the ESP-IDF programming guide's
  //! external-RAM or heap chapters.  Read the implementation, not the docs -- there are none.
  heap_caps_malloc_extmem_enable(0x400);   //!< 1 KB -- see the block above before changing this.
  global_printf("Heap free:       %d / %d\n",  ESP.getFreeHeap(), ESP.getHeapSize());
  global_printf("Heap max alloc:  %d\n",       ESP.getMaxAllocHeap());
  global_printf("Heap min free:   %d\n",       ESP.getMinFreeHeap());
  global_printf("Chip model       %s rev %d\n",ESP.getChipModel(), ESP.getChipRevision());
  global_printf("PSRAM free:      %d / %d\n",  ESP.getFreePsram(), ESP.getPsramSize());
  global_printf("PSRAM max alloc: %d\n",       ESP.getMaxAllocPsram());
  global_printf("PSRAM min free:  %d\n",       ESP.getMinFreePsram());
  global_printf("Flash size:      %dK\n",      ESP.getFlashChipSize() / 1024);
  global_printf("Flash speed:     %u\n",       ESP.getFlashChipSpeed());
  global_printf("Flash mode:      %d\n",       ESP.getFlashChipMode());
  global_printf("Chip revision:   %d\n",       ESP.getChipRevision());
  global_printf("Chip model:      %s\n",       ESP.getChipModel());
  global_printf("Chip cores:      %d\n",       ESP.getChipCores());
  global_printf("Chip freq:       %u Mhz\n",   ESP.getCpuFreqMHz());
  global_printf("Cycle count:     %u\n",       ESP.getCycleCount());
  global_printf("SDK version:     %s\n",       ESP.getSdkVersion());
  global_printf("Sketch size:     %u\n",       ESP.getSketchSize());
  global_printf("Sketch MD5:      <skipped>\n" /*%s, ESP.getSketchMD5().c_str()*/);	//takes too long
  global_printf("Sketch free:     %u\n",       ESP.getFreeSketchSpace());
  delay(10);
  //DEBT review above for completeness
}

#endif
