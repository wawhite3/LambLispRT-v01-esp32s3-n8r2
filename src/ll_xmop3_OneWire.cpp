// Copyright 2026 by Frobenius Norm LLC 2026-06-30
// Free for non-commercial use. Commercial use requires a license.
//
// P133 Tier 1 (7.2): 1-Wire bus binding (hardware xmop3, IRAM-timed).
// Bit-level reset/read/write slots are microsecond-precise, so they run with
// interrupts masked (portENTER_CRITICAL) and are marked IRAM_ATTR -- the same
// machinery ll_xmop3_Sonar.cpp uses for HC-SR04 timing.
//
// The pin is configured as open-drain with pull-up (an external 4.7k pull-up to
// 3V3 is still required by the bus): gpio_set_level(pin,0) drives the bus low,
// gpio_set_level(pin,1) releases it to the pull-up.
//
//   (onewire-reset pin)        -> #t/#f   ;; #t if a device pulled presence
//   (onewire-write-byte pin b)
//   (onewire-read-byte pin)    -> byte
//   (onewire-write-bit pin b)
//   (onewire-read-bit pin)     -> 0/1
//   (onewire-search pin)       -> (list rom-bytevector ...)  ;; each is 8 bytes (LSB ROM family first)
//
// On the linux host (LL_ONEWIRE undefined) every proc is a compile-clean no-op so
// the symbols remain bound for load/smoke tests.
//
#include "LambLisp.h"

#if LL_ONEWIRE
#include "driver/gpio.h"
#include "esp_attr.h"
#include "rom/ets_sys.h"
//! @defgroup xmop3_onewire 1-Wire & DS18B20
//! @ingroup xmop3
//! @brief LambLisp 1-Wire & DS18B20 builtins.
//! @{

static portMUX_TYPE onewire_mux = portMUX_INITIALIZER_UNLOCKED;

//! Configure the pin as open-drain + pull-up, released high.  Safe to call repeatedly.
static void onewire_setup_pin(int pin)
{
  gpio_set_direction((gpio_num_t) pin, GPIO_MODE_INPUT_OUTPUT_OD);
  gpio_set_pull_mode((gpio_num_t) pin, GPIO_PULLUP_ONLY);
  gpio_set_level((gpio_num_t) pin, 1);   // release to pull-up
}

//! 1-Wire reset + presence detect.  Returns true if a device pulled the line low.
static bool IRAM_ATTR onewire_reset(int pin)
{
  bool presence;
  portENTER_CRITICAL(&onewire_mux);
  gpio_set_level((gpio_num_t) pin, 0);   // drive low
  esp_rom_delay_us(480);
  gpio_set_level((gpio_num_t) pin, 1);   // release
  esp_rom_delay_us(70);
  presence = (gpio_get_level((gpio_num_t) pin) == 0);
  portEXIT_CRITICAL(&onewire_mux);
  esp_rom_delay_us(410);                  // finish the 480us presence window
  return presence;
}

//! Write a single bit using a standard-speed time slot.
static void IRAM_ATTR onewire_write_bit(int pin, int bit)
{
  portENTER_CRITICAL(&onewire_mux);
  if (bit) {
    gpio_set_level((gpio_num_t) pin, 0);
    esp_rom_delay_us(6);
    gpio_set_level((gpio_num_t) pin, 1);
    esp_rom_delay_us(64);
  } else {
    gpio_set_level((gpio_num_t) pin, 0);
    esp_rom_delay_us(60);
    gpio_set_level((gpio_num_t) pin, 1);
    esp_rom_delay_us(10);
  }
  portEXIT_CRITICAL(&onewire_mux);
}

//! Read a single bit using a standard-speed read slot.
static int IRAM_ATTR onewire_read_bit(int pin)
{
  int bit;
  portENTER_CRITICAL(&onewire_mux);
  gpio_set_level((gpio_num_t) pin, 0);
  esp_rom_delay_us(6);
  gpio_set_level((gpio_num_t) pin, 1);
  esp_rom_delay_us(9);
  bit = gpio_get_level((gpio_num_t) pin);
  portEXIT_CRITICAL(&onewire_mux);
  esp_rom_delay_us(55);
  return bit;
}

//! Write a byte, LSB first.
static void onewire_write_byte(int pin, int b)
{
  for (int i = 0; i < 8; i++) { onewire_write_bit(pin, b & 1); b >>= 1; }
}

//! Read a byte, LSB first.
static int onewire_read_byte(int pin)
{
  int b = 0;
  for (int i = 0; i < 8; i++) if (onewire_read_bit(pin)) b |= (1 << i);
  return b;
}

//! One pass of the Maxim ROM search.  Returns 1 if a ROM was found, 0 otherwise.
static int onewire_search_pass(int pin, uint8_t *rom, int *last_disc, bool *last_dev)
{
  int id_bit_number = 1, last_zero = 0, rom_byte_number = 0, search_result = 0;
  uint8_t rom_byte_mask = 1;
  if (!*last_dev) {
    if (!onewire_reset(pin)) { *last_disc = 0; *last_dev = false; return 0; }
    onewire_write_byte(pin, 0xF0);
    do {
      int id_bit  = onewire_read_bit(pin);
      int cmp_bit = onewire_read_bit(pin);
      if (id_bit == 1 && cmp_bit == 1) break;   // no devices on the bus
      int dir;
      if (id_bit != cmp_bit) {
        dir = id_bit;
      } else {
        if (id_bit_number < *last_disc) dir = ((rom[rom_byte_number] & rom_byte_mask) > 0);
        else                            dir = (id_bit_number == *last_disc);
        if (dir == 0) last_zero = id_bit_number;
      }
      if (dir) rom[rom_byte_number] |=  rom_byte_mask;
      else     rom[rom_byte_number] &= ~rom_byte_mask;
      onewire_write_bit(pin, dir);
      id_bit_number++;
      rom_byte_mask <<= 1;
      if (rom_byte_mask == 0) { rom_byte_number++; rom_byte_mask = 1; }
    } while (rom_byte_number < 8);
    if (id_bit_number >= 65) {
      *last_disc = last_zero;
      if (*last_disc == 0) *last_dev = true;
      search_result = 1;
    }
  }
  if (!search_result || rom[0] == 0) { *last_disc = 0; *last_dev = false; search_result = 0; }
  return search_result;
}
#endif  // LL_ONEWIRE


//! (onewire-reset pin) -> #t/#f
Sexpr_t OneWire_mop3_reset(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::OneWire_mop3_reset()");
  ll_try {
    LL_int32 pin = lamb.car(sexpr)->mustbe_int32();
#if LL_ONEWIRE
    onewire_setup_pin(pin);
    return lamb.mk_bool(onewire_reset(pin), env_exec);
#else
    (void) pin;
    return HASHF;
#endif
  }
  ll_catch();
}

//! (onewire-write-byte pin b)
Sexpr_t OneWire_mop3_write_byte(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::OneWire_mop3_write_byte()");
  ll_try {
    LL_int32 pin = lamb.car(sexpr)->mustbe_int32();
    LL_int32 b   = lamb.cadr(sexpr)->coerce_int32() & 0xff;
#if LL_ONEWIRE
    onewire_setup_pin(pin);
    onewire_write_byte(pin, b);
#else
    (void) pin; (void) b;
#endif
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! (onewire-read-byte pin) -> byte
Sexpr_t OneWire_mop3_read_byte(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::OneWire_mop3_read_byte()");
  ll_try {
    LL_int32 pin = lamb.car(sexpr)->mustbe_int32();
#if LL_ONEWIRE
    onewire_setup_pin(pin);
    return lamb.mk_integer(onewire_read_byte(pin), env_exec);
#else
    (void) pin;
    return lamb.mk_integer(0, env_exec);
#endif
  }
  ll_catch();
}

//! (onewire-write-bit pin b)
Sexpr_t OneWire_mop3_write_bit(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::OneWire_mop3_write_bit()");
  ll_try {
    LL_int32 pin = lamb.car(sexpr)->mustbe_int32();
    LL_int32 b   = lamb.cadr(sexpr)->coerce_int32() & 1;
#if LL_ONEWIRE
    onewire_setup_pin(pin);
    onewire_write_bit(pin, b);
#else
    (void) pin; (void) b;
#endif
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! (onewire-read-bit pin) -> 0/1
Sexpr_t OneWire_mop3_read_bit(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::OneWire_mop3_read_bit()");
  ll_try {
    LL_int32 pin = lamb.car(sexpr)->mustbe_int32();
#if LL_ONEWIRE
    onewire_setup_pin(pin);
    return lamb.mk_integer(onewire_read_bit(pin), env_exec);
#else
    (void) pin;
    return lamb.mk_integer(0, env_exec);
#endif
  }
  ll_catch();
}

//! (onewire-search pin) -> (list rom-bytevector ...), each 8 bytes.
Sexpr_t OneWire_mop3_search(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::OneWire_mop3_search()");
  ll_try {
    LL_int32 pin = lamb.car(sexpr)->mustbe_int32();
#if LL_ONEWIRE
    onewire_setup_pin(pin);
    Sexpr_t acc = NIL;
    uint8_t rom[8] = {0};
    int last_disc = 0;
    bool last_dev = false;
    int guard = 0;
    while (onewire_search_pass(pin, rom, &last_disc, &last_dev) && guard++ < 32) {
      // acc stays rooted across mk_bytevector; cons protects bv + acc internally.
      mop3_gc_protect(acc, {
          Sexpr_t bv = lamb.mk_bytevector((LL_int32) 8, (Bytest_t) rom, env_exec);
          acc = lamb.cons(bv, acc, env_exec);
      });
      if (last_dev) break;
    }
    return lamb.reverse_bang(acc);
#else
    (void) pin;
    return NIL;
#endif
  }
  ll_catch();
}

//! Install all OneWire symbols in base environment.
Sexpr_t OneWire_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::OneWire_install_mop3()");
  ll_try {
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } ow_procs[] = {
      { OneWire_install_mop3,    "OneWire.install-mop3", false },
      { OneWire_mop3_reset,      "onewire-reset",        false },
      { OneWire_mop3_write_byte, "onewire-write-byte",   false },
      { OneWire_mop3_read_byte,  "onewire-read-byte",    false },
      { OneWire_mop3_write_bit,  "onewire-write-bit",    false },
      { OneWire_mop3_read_bit,   "onewire-read-bit",     false },
      { OneWire_mop3_search,     "onewire-search",       false },
    };
    const int Now_procs = sizeof(ow_procs)/sizeof(ow_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Now_procs);
    for (int i = 0; i < Now_procs; i++) {
      const auto &p = ow_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
    return OBJ_UNDEF;
  }
  ll_catch();
}
//! @}
