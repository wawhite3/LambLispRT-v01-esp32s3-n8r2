// Freenove_WS2812_Lib_for_ESP32.h
/**
 * Brief	A library for controlling ws2812 in esp32 platform.
 * Author	ZhentaoLin
 * Company	Freenove
 * Date		2024-02-29

 Updated Aug 2025 white3@Frobeniusnorm.com fwd/back compatibility with rmt changes
 */

#ifndef WS2812_ESP32_h
#define WS2812_ESP32_h

#if LL_WS2812

#if defined(ARDUINO) && ARDUINO >= 100
#include <Arduino.h>
#else
#include "WProgram.h"
#endif

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "Arduino.h"

#include "esp32-hal.h"
#include "esp_arduino_version.h"

/* Select the legacy (core 2.x) RMT API.  Core 3.x replaced the handle-based RMT calls
   -- rmtInit() returning rmt_obj_t*, rmtSetTick(), rmtWrite(handle, ...) -- with
   pin-addressed ones, and removed rmt_obj_t entirely.

   TEST ON THE VERSION MACRO, NOT ON AN RMT NAME.  This was `#ifndef RMT_MEM_NUM_BLOCKS_1`,
   which cannot work: in core 3.x RMT_MEM_NUM_BLOCKS_1 is an ENUM CONSTANT, and #ifndef
   sees only macros.  The test was therefore true on BOTH cores, so the 2.x branch was
   always taken and it was right purely by accident.  The symptom on core 3.x is not a
   version warning but a wall of "'rmt_obj_t' does not name a type" and "cannot convert
   'bool' to 'rmt_ch_dir_t'" out of the 2.x branch -- which reads like a broken library
   rather than a failed version probe. */
#if !defined(ESP_ARDUINO_VERSION_MAJOR) || ESP_ARDUINO_VERSION_MAJOR < 3
#define WS2812_compatibility 1
#endif


//Modify the definition to expand the number of leds
//Supports a maximum of 1100 leds
#define NR_OF_LEDS   256  

#define NR_OF_ALL_BITS 24*NR_OF_LEDS

enum LED_TYPE
{					  //R  G  B
	TYPE_RGB = 0x06,  //00 01 10
	TYPE_RBG = 0x09,  //00 10 01
	TYPE_GRB = 0x12,  //01 00 10
	TYPE_GBR = 0x21,  //10 00 01
	TYPE_BRG = 0x18,  //01 10 00
	TYPE_BGR = 0x24	  //10 01 00
};

class WS2812
{
protected:
	
  uint16_t ledCounts;
  uint8_t pin;
  uint8_t br;
  uint8_t rmt_chn;
  
  uint8_t rOffset;
  uint8_t gOffset;
  uint8_t bOffset;
  
  float realTick;
  rmt_reserve_memsize_t rmt_mem;
  rmt_data_t led_data[NR_OF_ALL_BITS];

#ifdef WS2812_compatibility
  rmt_obj_t* rmt_send = NULL;	//perhaps not used (version dependent)
#endif
  
public:
	WS2812(uint16_t n = 8, uint8_t pin_gpio = 2, uint8_t chn = 0, LED_TYPE t = TYPE_GRB);

	bool begin();
	void setLedCount(uint16_t n);
	void setLedType(LED_TYPE t);
	void setBrightness(uint8_t brightness);

	esp_err_t set_pixel(int index, uint8_t r, uint8_t g, uint8_t b);
	
	esp_err_t setLedColorData(int index, uint32_t rgb);
	esp_err_t setLedColorData(int index, uint8_t r, uint8_t g, uint8_t b);

	esp_err_t setLedColor(int index, uint32_t rgb);
	esp_err_t setLedColor(int index, uint8_t r, uint8_t g, uint8_t b);

	esp_err_t setAllLedsColorData(uint32_t rgb);
	esp_err_t setAllLedsColorData(uint8_t r, uint8_t g, uint8_t b);

	esp_err_t setAllLedsColor(uint32_t rgb);
	esp_err_t setAllLedsColor(uint8_t r, uint8_t g, uint8_t b);

	esp_err_t show();

	uint32_t Wheel(byte pos);
	uint32_t hsv2rgb(uint32_t h, uint32_t s, uint32_t v);
};

#endif

#endif
