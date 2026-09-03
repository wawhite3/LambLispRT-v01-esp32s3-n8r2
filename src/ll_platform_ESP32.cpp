// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#if LL_ESP32

#include "ll_platform_generic.h"
#include "esp_system.h"
#include "esp_heap_caps.h"

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
void delay_ms(unsigned long ms)			{ delay(ms); }
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

  global_printf("\n");
  global_printf("%s IDF_target : %s, chip_model : %d, model_name %s, rev %d, full_rev %d\n",
		me, CONFIG_IDF_TARGET, chip_info.model, chip_names[((unsigned) chip_info.model) % Nchips], chip_info.revision, chip_info.full_revision);
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
