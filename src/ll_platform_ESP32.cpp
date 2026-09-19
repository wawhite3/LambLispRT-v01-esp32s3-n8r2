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
  heap_caps_malloc_extmem_enable(0x400); //1k, why?
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
