// Copyright 2026 by Frobenius Norm LLC 2026-09-05
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"

//! @addtogroup llarduino
//! @brief libgpiod backend -- REAL pins on a Raspberry Pi or Jetson.
//!
//! This is what makes LLArduino a port rather than a simulation: `(digitalWrite 18 1)` in
//! Scheme drives an actual header pin.  Selected at RUNTIME (see the dispatch table in
//! ll_llarduino_null.cpp) because whether real pins exist is a property of the MACHINE, not the
//! build -- the same aarch64 binary runs on a Jetson with a 40-pin header and on a box whose
//! gpiochips are not header pins at all.
//!
//! libgpiod v1 API, PINNED DELIBERATELY.  v1.6.3 is what both this workstation and the Jetson
//! carry, and libgpiod v2 is SOURCE-INCOMPATIBLE with v1 (different handle types, different
//! request API).  A distro upgrade that silently moved to v2 would break this file, which is the
//! same class of trap as the esptool 4.x/5.x subcommand split and the Arduino 2.x/3.x break behind
//! If v2 support is wanted it goes beside this, not through it.
//! @{

#if LL_GPIOD

#include <gpiod.h>
#include <string.h>
#include <stdio.h>

//! PIN NUMBERING IS THE ACTUAL WORK, not the libgpiod calls.  "Raspberry-Pi compatible" cannot mean
//! passing a number straight to gpiod: the Jetson's lines are named PA.00, PQ.05, PAC.06 -- Tegra
//! SoC naming -- not GPIO17, and not header positions.  The Orin Nano's 40-pin header IS physically
//! RPi-compatible, so the mapping exists and simply has to be written down.
//!
//! THIS TABLE IS GENERATED, NOT TRANSCRIBED.  It comes from NVIDIA's own jetson-gpio data
//! (/usr/lib/python3/dist-packages/Jetson/GPIO/gpio_pin_data.py, JETSON_ORIN_NANO), read on the
//! machine and emitted as C.  Hand-copying 22 rows of pin numbers is exactly the kind of transcription
//! that produces a table which looks right and drives the wrong pin -- and driving the wrong pin on a
//! board with motors attached is not a typo you get to take back.
//! Regenerate rather than edit:
//!     python3 -c "import importlib.util; spec=importlib.util.spec_from_file_location('g', \
//!       '/usr/lib/python3/dist-packages/Jetson/GPIO/gpio_pin_data.py'); m=importlib.util.module_from_spec(spec); \
//!       spec.loader.exec_module(m); [print(r) for r in m.jetson_gpio_data[m.JETSON_ORIN_NANO][0]]"
//! (Note: importing Jetson.GPIO itself FAILS on this unit -- "Could not determine Jetson model" on
//! the Orin Nano Engineering Reference Developer Kit Super -- so load the data module directly.)
struct LLGpiodPin { int bcm; int board; int offset; const char *chip; const char *name; };

static const LLGpiodPin ll_gpiod_map_orin_nano[] = {
  {   4,   7, 144, "tegra234-gpio", "PAC.06" },   //!< GPIO09
  {   5,  29, 105, "tegra234-gpio", "PQ.05" },   //!< GPIO01
  {   6,  31, 106, "tegra234-gpio", "PQ.06" },   //!< GPIO11
  {   7,  26, 137, "tegra234-gpio", "PZ.07" },   //!< SPI0_CS1
  {   8,  24, 136, "tegra234-gpio", "PZ.06" },   //!< SPI0_CS0
  {   9,  21, 134, "tegra234-gpio", "PZ.04" },   //!< SPI0_MISO
  {  10,  19, 135, "tegra234-gpio", "PZ.05" },   //!< SPI0_MOSI
  {  11,  23, 133, "tegra234-gpio", "PZ.03" },   //!< SPI0_SCK
  {  12,  32,  41, "tegra234-gpio", "PG.06" },   //!< GPIO07
  {  13,  33,  43, "tegra234-gpio", "PH.00" },   //!< GPIO13
  {  16,  36, 113, "tegra234-gpio", "PR.05" },   //!< UART1_CTS
  {  17,  11, 112, "tegra234-gpio", "PR.04" },   //!< UART1_RTS
  {  18,  12,  50, "tegra234-gpio", "PH.07" },   //!< I2S0_SCLK
  {  19,  35,  53, "tegra234-gpio", "PI.02" },   //!< I2S0_FS
  {  20,  38,  52, "tegra234-gpio", "PI.01" },   //!< I2S0_SDIN
  {  21,  40,  51, "tegra234-gpio", "PI.00" },   //!< I2S0_SDOUT
  {  22,  15,  85, "tegra234-gpio", "PN.01" },   //!< GPIO12
  {  23,  16, 126, "tegra234-gpio", "PY.04" },   //!< SPI1_CS1
  {  24,  18, 125, "tegra234-gpio", "PY.03" },   //!< SPI1_CS0
  {  25,  22, 123, "tegra234-gpio", "PY.01" },   //!< SPI1_MISO
  {  26,  37, 124, "tegra234-gpio", "PY.02" },   //!< SPI1_MOSI
  {  27,  13, 122, "tegra234-gpio", "PY.00" },   //!< SPI1_SCK
};
static const int ll_gpiod_map_orin_nano_n =
  (int) (sizeof(ll_gpiod_map_orin_nano) / sizeof(ll_gpiod_map_orin_nano[0]));

//! The active map, chosen by ll_gpiod_probe().  NULL means "no map for this machine" -- which is a
//! REFUSAL to guess, not a failure: without a map, a pin number means nothing and driving anything
//! would be arbitrary.
static const LLGpiodPin *ll_gpiod_map   = 0;
static int               ll_gpiod_map_n = 0;

//! One requested line per pin, cached.  libgpiod requires a line be REQUESTED before use and the
//! request carries its direction, so changing pinMode means releasing and re-requesting.
struct LLGpiodLine { struct gpiod_line *line; int mode; };
static struct gpiod_chip *ll_gpiod_chip = 0;
static LLGpiodLine        ll_gpiod_lines[64];
static int                ll_gpiod_lines_n = 0;

static const LLGpiodPin *ll_gpiod_find(int bcm)
{
  for (int i = 0; i < ll_gpiod_map_n; i++)
    if (ll_gpiod_map[i].bcm == bcm) return &ll_gpiod_map[i];
  return 0;                                  //!< unmapped pin: do nothing, never guess an offset
}

//! Board detection.  /proc/device-tree/compatible is unambiguous where it exists and absent on x86,
//! which is exactly the discrimination needed: a machine with no device tree has no header to drive.
static bool ll_gpiod_compatible_has(const char *needle)
{
  FILE *f = fopen("/proc/device-tree/compatible", "rb");
  if (!f) return false;                      //!< x86 and friends: no device tree, no header
  char buf[512];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = '\0';
  //! The file is NUL-SEPARATED, not a C string -- scan the whole buffer, not just the first entry.
  for (size_t i = 0; i < n; ) {
    if (strstr(buf + i, needle)) return true;
    i += strlen(buf + i) + 1;
  }
  return false;
}

//! Returns true when real pins are available AND we know how to number them.  Both halves matter:
//! a gpiochip with no pin map is worse than no gpiochip, because it invites driving lines by
//! accident.
static bool ll_gpiod_probe()
{
  if (ll_gpiod_compatible_has("nvidia,tegra234")) {
    ll_gpiod_map   = ll_gpiod_map_orin_nano;
    ll_gpiod_map_n = ll_gpiod_map_orin_nano_n;
  }
  //! Raspberry Pi would slot in here with its own table (brcm,bcm2711 / brcm,bcm2712).  It is NOT
  //! guessed from the Jetson's: on a Pi the BCM number IS the line offset on gpiochip0, which is a
  //! different relationship, and assuming otherwise would drive arbitrary lines.
  if (!ll_gpiod_map) return false;

  ll_gpiod_chip = gpiod_chip_open_by_label(ll_gpiod_map[0].chip);
  if (!ll_gpiod_chip) ll_gpiod_chip = gpiod_chip_open_by_name("gpiochip0");
  return ll_gpiod_chip != 0;                 //!< no chip (or no permission) -> caller falls back
}

static LLGpiodLine *ll_gpiod_line_for(int bcm, int want_mode)
{
  const LLGpiodPin *p = ll_gpiod_find(bcm);
  if (!p || !ll_gpiod_chip) return 0;
  for (int i = 0; i < ll_gpiod_lines_n; i++) {
    if (ll_gpiod_lines[i].line &&
        gpiod_line_offset(ll_gpiod_lines[i].line) == (unsigned) p->offset) {
      if (ll_gpiod_lines[i].mode == want_mode) return &ll_gpiod_lines[i];
      //! Direction changed: a request carries its direction, so it must be released and retaken.
      gpiod_line_release(ll_gpiod_lines[i].line);
      ll_gpiod_lines[i].line = gpiod_chip_get_line(ll_gpiod_chip, p->offset);
      if (!ll_gpiod_lines[i].line) return 0;
      int rc = (want_mode == OUTPUT) ? gpiod_line_request_output(ll_gpiod_lines[i].line, "lamblisp", 0)
                                     : gpiod_line_request_input(ll_gpiod_lines[i].line, "lamblisp");
      if (rc < 0) return 0;
      ll_gpiod_lines[i].mode = want_mode;
      return &ll_gpiod_lines[i];
    }
  }
  if (ll_gpiod_lines_n >= (int) (sizeof(ll_gpiod_lines) / sizeof(ll_gpiod_lines[0]))) return 0;
  struct gpiod_line *l = gpiod_chip_get_line(ll_gpiod_chip, p->offset);
  if (!l) return 0;
  int rc = (want_mode == OUTPUT) ? gpiod_line_request_output(l, "lamblisp", 0)
                                 : gpiod_line_request_input(l, "lamblisp");
  if (rc < 0) return 0;
  ll_gpiod_lines[ll_gpiod_lines_n].line = l;
  ll_gpiod_lines[ll_gpiod_lines_n].mode = want_mode;
  return &ll_gpiod_lines[ll_gpiod_lines_n++];
}

void ll_gpiod_pin_mode(int pin, int mode)      { ll_gpiod_line_for(pin, mode == OUTPUT ? OUTPUT : INPUT); }
void ll_gpiod_digital_write(int pin, int val)  { LLGpiodLine *l = ll_gpiod_line_for(pin, OUTPUT); if (l) gpiod_line_set_value(l->line, val ? 1 : 0); }
int  ll_gpiod_digital_read(int pin)            { LLGpiodLine *l = ll_gpiod_line_for(pin, INPUT);  return l ? gpiod_line_get_value(l->line) : 0; }

//! NO ADC AND NO PWM HERE, AND THEY MUST NOT PRETEND.  Neither a Pi nor a Jetson has an ADC on the
//! header -- analogRead conventionally means an EXTERNAL converter (MCP3008 over SPI, ADS1115 over
//! I2C) -- and analogWrite needs a PWM chip wired to that specific pin.  The rule holds: a
//! fabricated sensor reading is worse than an error, because it is plausible.  -1 says "unsupported
//! on this backend"; it is never a measurement.
int  ll_gpiod_analog_read(int pin)             { (void) pin; return -1; }
void ll_gpiod_analog_write(int pin, int val)   { (void) pin; (void) val; }
void ll_gpiod_tone_on(int pin, unsigned int f) { (void) pin; (void) f; }
void ll_gpiod_tone_off(int pin)                { (void) pin; }
int  ll_gpiod_pin_mode_get(int pin)            { const LLGpiodPin *p = ll_gpiod_find(pin); return p ? 1 : -1; }
int  ll_gpiod_pin_duty_get(int pin)            { (void) pin; return -1; }
int  ll_gpiod_pin_tone_get(int pin)            { (void) pin; return -1; }
int  ll_gpiod_npins()                          { return ll_gpiod_map_n; }
bool ll_gpiod_available()                      { return ll_gpiod_probe(); }

#endif // LL_GPIOD
//! @}
