// Copyright 2026 by Frobenius Norm LLC 2026-09-08
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"

//! @addtogroup llarduino
//! @brief ESP-IDF backend -- REAL pins on an ESP32, over Apache-2.0 IDF drivers, NO vendor core.
//!
//! This is the P176 "Tier 1 on the metal" backend: it lets an ESP32 build the LLArduino surface
//! (pinMode/digitalWrite/digitalRead/analogWrite/analogRead/tone) with `LL_ARDUINO=1` and WITHOUT
//! `framework-arduinoespressif32`.  Every primitive it calls -- driver/gpio, driver/ledc,
//! esp_timer -- is Apache-2.0 and already present in the ESP-IDF that pioarduino ships, so this
//! backend copies no LGPL Arduino-core code (see P176, "take in at the Apache layer").
//!
//! Selected at RUNTIME by the dispatch table in ll_llarduino_null.cpp, same as the libgpiod
//! backend.  On an ESP32 `ll_idf_available()` is unconditionally true -- unlike a Linux SBC, the
//! GPIO block is on-die and always present, so there is nothing to probe and no way to be on a
//! machine that lacks it.
//!
//! TIMING is NOT here -- it lives in ll_platform_ESP32.cpp (P176 Tier 1, guarded
//! `#if LL_ARDUINO && !LL_ESP_ARDUINO`): millis/micros over esp_timer, delay_ms YIELDS via
//! vTaskDelay (like Arduino delay()), delayMicroseconds/delay_us BUSY-WAIT via esp_rom_delay_us
//! (sub-tick, cannot yield).  This file is GPIO/PWM only, matching ll_llarduino_gpiod.cpp.
//!
//! STATUS: SKELETON (2026-09-08).  Unbuilt -- there is no IDF-only ESP32 env wired yet and no board
//! on the bench.  GPIO and timing bodies are real; the three items that need a decision are marked
//! `// TODO(P176)` and fail SAFE (analogRead refuses rather than fabricates, per the B226/B249
//! rule).  Do not mark this done until it passes the conformance suite A/B against the vendor core
//! on hardware (P176 success criterion 3).
//! @{

#if LL_IDF_GPIO

#include "driver/gpio.h"
#include "driver/ledc.h"
#include <string.h>

//! PIN NUMBERING IS TRIVIAL HERE, unlike the libgpiod backend.  On an ESP32 the Arduino pin number
//! IS the GPIO number -- `digitalWrite(2, HIGH)` drives GPIO2 -- so there is no board map to
//! generate and no (chip, offset) indirection.  The only guard needed is range/validity: not every
//! GPIO number is a legal output (input-only pins, flash-strapping pins), and IDF's own macros are
//! the authority.  A bad pin is a caller error -- refuse it, never clamp it onto a different pin.
static inline bool ll_idf_pin_ok(int pin)         { return pin >= 0 && GPIO_IS_VALID_GPIO((gpio_num_t) pin); }
static inline bool ll_idf_pin_ok_output(int pin)  { return pin >= 0 && GPIO_IS_VALID_OUTPUT_GPIO((gpio_num_t) pin); }

// -------------------------------------------------------------------------------------------------
// Digital GPIO -- driver/gpio
// -------------------------------------------------------------------------------------------------

//! Cache the last mode per pin so pin_mode_get() can report it (the conformance suite asserts on it)
//! and so digitalWrite to an unconfigured pin can be caught rather than silently dropped.  256 is
//! generous -- real parts top out far below -- but pin numbering is chip-specific and this must not
//! reject a number legal on some SoC in the family.
#define LL_IDF_NPINS 64
static signed char ll_idf_mode[LL_IDF_NPINS];   //!< -1 = never configured; else last pinMode()

void ll_idf_pin_mode(int pin, int mode)
{
  if (!ll_idf_pin_ok(pin)) return;
  gpio_config_t cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.pin_bit_mask = 1ULL << pin;
  cfg.intr_type    = GPIO_INTR_DISABLE;
  switch (mode) {
    case OUTPUT:        cfg.mode = GPIO_MODE_OUTPUT; break;
    case INPUT_PULLUP:  cfg.mode = GPIO_MODE_INPUT;  cfg.pull_up_en = GPIO_PULLUP_ENABLE; break;
    case INPUT:
    default:            cfg.mode = GPIO_MODE_INPUT;  break;
  }
  if (gpio_config(&cfg) == ESP_OK && pin < LL_IDF_NPINS) ll_idf_mode[pin] = (signed char) mode;
}

void ll_idf_digital_write(int pin, int val)
{
  if (!ll_idf_pin_ok_output(pin)) return;      //!< input-only pin: refuse, do not pretend
  gpio_set_level((gpio_num_t) pin, val ? 1 : 0);
}

int ll_idf_digital_read(int pin)
{
  if (!ll_idf_pin_ok(pin)) return 0;
  return gpio_get_level((gpio_num_t) pin);
}

// -------------------------------------------------------------------------------------------------
// analogWrite / tone -- driver/ledc  (PWM)
// -------------------------------------------------------------------------------------------------
//
// LEDC has a FIXED, SMALL number of channels (8 on most parts, split across two speed modes).  A
// pin must be bound to a channel before it can be driven, and channels are a scarce resource, so we
// allocate lazily and cache pin->channel, exactly as the libgpiod backend caches requested lines.
//
// TWO DECISIONS ARE DEFERRED (// TODO(P176)) because they are policy, not mechanism, and getting
// them wrong is worse than leaving them explicit:
//   1. Channel exhaustion: what analogWrite/tone do on the 9th distinct pin.  Refuse, or evict LRU?
//      Skeleton refuses (returns without driving) rather than silently stealing another pin's channel.
//   2. Duty resolution + freq: analogWrite takes 0..255 (Arduino's 8-bit default); tone takes a
//      frequency.  These want DIFFERENT LEDC timer configs on the same channel pool.  Sketched below
//      at 8-bit / 5 kHz for analogWrite and a per-call freq for tone; confirm against the suite.

#define LL_IDF_LEDC_MAX   8
#define LL_IDF_LEDC_RES   LEDC_TIMER_8_BIT      //!< analogWrite is 0..255
#define LL_IDF_LEDC_HZ    5000                  //!< analogWrite carrier; tone overrides per call
struct LlIdfPwm { int pin; int duty; int tone_hz; ledc_channel_t ch; bool used; };
static LlIdfPwm ll_idf_pwm[LL_IDF_LEDC_MAX];
static bool     ll_idf_ledc_timer_ready = false;

//! Find the channel bound to `pin`, or bind a free one.  Returns nullptr when the pool is full --
//! see decision 1 above.
static LlIdfPwm *ll_idf_pwm_for(int pin)
{
  for (int i = 0; i < LL_IDF_LEDC_MAX; i++)
    if (ll_idf_pwm[i].used && ll_idf_pwm[i].pin == pin) return &ll_idf_pwm[i];
  for (int i = 0; i < LL_IDF_LEDC_MAX; i++) {
    if (!ll_idf_pwm[i].used) {
      // TODO(P176): one shared timer for all analogWrite channels; tone needs its own freq per
      // channel, so this may need a timer per active tone.  Sketched as a single low-speed timer.
      if (!ll_idf_ledc_timer_ready) {
        ledc_timer_config_t t;
        memset(&t, 0, sizeof(t));
        t.speed_mode      = LEDC_LOW_SPEED_MODE;
        t.duty_resolution = LL_IDF_LEDC_RES;
        t.timer_num       = LEDC_TIMER_0;
        t.freq_hz         = LL_IDF_LEDC_HZ;
        t.clk_cfg         = LEDC_AUTO_CLK;
        if (ledc_timer_config(&t) != ESP_OK) return 0;
        ll_idf_ledc_timer_ready = true;
      }
      ledc_channel_config_t c;
      memset(&c, 0, sizeof(c));
      c.gpio_num   = pin;
      c.speed_mode = LEDC_LOW_SPEED_MODE;
      c.channel    = (ledc_channel_t) i;
      c.timer_sel  = LEDC_TIMER_0;
      c.duty       = 0;
      c.hpoint     = 0;
      if (ledc_channel_config(&c) != ESP_OK) return 0;
      ll_idf_pwm[i].used = true; ll_idf_pwm[i].pin = pin; ll_idf_pwm[i].ch = (ledc_channel_t) i;
      ll_idf_pwm[i].duty = 0; ll_idf_pwm[i].tone_hz = 0;
      return &ll_idf_pwm[i];
    }
  }
  return 0;                                    //!< pool full -- refuse (decision 1)
}

void ll_idf_analog_write(int pin, int val)
{
  if (!ll_idf_pin_ok_output(pin)) return;
  LlIdfPwm *p = ll_idf_pwm_for(pin);
  if (!p) return;
  if (val < 0) val = 0; else if (val > 255) val = 255;
  ledc_set_duty(LEDC_LOW_SPEED_MODE, p->ch, (uint32_t) val);
  ledc_update_duty(LEDC_LOW_SPEED_MODE, p->ch);
  p->duty = val; p->tone_hz = 0;
}

void ll_idf_tone_on(int pin, unsigned int freq)
{
  if (!ll_idf_pin_ok_output(pin) || freq == 0) return;
  LlIdfPwm *p = ll_idf_pwm_for(pin);
  if (!p) return;
  ledc_set_freq(LEDC_LOW_SPEED_MODE, LEDC_TIMER_0, freq);   // TODO(P176): shared timer => shared freq
  ledc_set_duty(LEDC_LOW_SPEED_MODE, p->ch, 128);           //!< 50% square wave
  ledc_update_duty(LEDC_LOW_SPEED_MODE, p->ch);
  p->tone_hz = (int) freq; p->duty = 128;
}

void ll_idf_tone_off(int pin)
{
  if (!ll_idf_pin_ok_output(pin)) return;
  LlIdfPwm *p = ll_idf_pwm_for(pin);
  if (!p) return;
  ledc_stop(LEDC_LOW_SPEED_MODE, p->ch, 0);
  p->tone_hz = 0; p->duty = 0;
}

// -------------------------------------------------------------------------------------------------
// analogRead -- adc_oneshot   (NOT every GPIO is an ADC pin)
// -------------------------------------------------------------------------------------------------

int ll_idf_analog_read(int pin)
{
  (void) pin;
  // TODO(P176): route to adc_oneshot, but ONLY for pins physically wired to an ADC channel
  // (ADC1/ADC2 GPIO maps are per-SoC).  Until that map exists, REFUSE -- returning a plausible
  // number for a non-ADC pin is exactly the fabricated-reading failure B226/B249 paid for.  The
  // libgpiod backend makes the same choice for the same reason.
  return -1;
}

// -------------------------------------------------------------------------------------------------
// Inspection getters (the conformance suite asserts on state the Arduino API cannot report)
// -------------------------------------------------------------------------------------------------

int ll_idf_pin_mode_get(int pin) { return (pin >= 0 && pin < LL_IDF_NPINS) ? ll_idf_mode[pin] : -1; }

int ll_idf_pin_duty_get(int pin)
{
  for (int i = 0; i < LL_IDF_LEDC_MAX; i++) if (ll_idf_pwm[i].used && ll_idf_pwm[i].pin == pin) return ll_idf_pwm[i].duty;
  return 0;
}

int ll_idf_pin_tone_get(int pin)
{
  for (int i = 0; i < LL_IDF_LEDC_MAX; i++) if (ll_idf_pwm[i].used && ll_idf_pwm[i].pin == pin) return ll_idf_pwm[i].tone_hz;
  return 0;
}

int ll_idf_npins() { return LL_IDF_NPINS; }

//! On an ESP32 the GPIO block is on-die and always present, so unlike the libgpiod probe there is
//! nothing to detect: if this file is compiled in, the backend is usable.  It still initialises the
//! mode cache once, so pin_mode_get reports -1 (never configured) rather than garbage.
bool ll_idf_available()
{
  static bool inited = false;
  if (!inited) { for (int i = 0; i < LL_IDF_NPINS; i++) ll_idf_mode[i] = -1; inited = true; }
  return true;
}

#endif // LL_IDF_GPIO
//! @}
