// Copyright 2026 by Frobenius Norm LLC 2026-09-04
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"

//! @defgroup llarduino LLArduino -- LambLisp's own Arduino API
//! @ingroup xmop3
//! @brief The NULL (simulated) backend: pin state in memory, no hardware.
//!
//! This is the backend that runs where there is no GPIO to drive -- a developer laptop, an
//! x86 host, a container -- so that the 26 `commonio` procedures (pinMode, digitalWrite,
//! digitalRead, analogRead/Write, tone, ...) can be CALLED AND ASSERTED ON without a board.
//!
//! WHY THAT MATTERS HERE, concretely: of the seven boards where commonio is compiled in, most are
//! unavailable most of the time -- shared with other sessions, unplugged to save power, or in a
//! failed USB port.  On one occasion exactly ONE of seven was reachable.  Anything that can only be
//! tested with a board in hand is, in practice, tested rarely; a recent Arduino 3.x WiFi (
//! regression) reached customers as a boot loop for that reason.
//!
//! IT ANNOUNCES ITSELF AS SIMULATED.  A simulated backend is honest only while nobody can mistake
//! it for hardware, so `llarduino-backend` returns 'null here and the loopback semantics are
//! documented below rather than left to be discovered.  The rule -- never invent a
//! plausible sensor reading -- still binds the REAL backends: on a Pi or Jetson, analogRead has no
//! ADC behind it and must say so instead of returning a number.  Here every value is one the caller
//! itself wrote, which is a different thing from a fabricated measurement.
//! @{

#if LL_ARDUINO

#include <string.h>
#include <time.h>
#include <errno.h>

//! Simulated pin file.  LL_LLA_NPINS is generous because pin NUMBERING is board-specific (a Pi's
//! BCM numbers, an ESP32's GPIO numbers) and this backend must not reject a number that is legal
//! somewhere.  Out-of-range is CLAMPED AWAY FROM MEMORY, never written: a bad pin number is a
//! caller error, not a reason to corrupt the heap.
#define LL_LLA_NPINS 256

struct LL_LlaPin {
  unsigned char mode;      //!< last pinMode()
  unsigned char level;     //!< last digitalWrite(), and what digitalRead() returns
  int           duty;      //!< last analogWrite()
  int           tone_hz;   //!< last tone(); 0 after noTone()
};

static LL_LlaPin ll_lla_pins[LL_LLA_NPINS];
static bool      ll_lla_init_done = false;

static inline bool ll_lla_valid(int pin) { return pin >= 0 && pin < LL_LLA_NPINS; }

static void ll_lla_init_once()
{
  if (ll_lla_init_done) return;
  memset(ll_lla_pins, 0, sizeof(ll_lla_pins));
  ll_lla_init_done = true;
}

static void ll_null_pin_mode(int pin, int mode)
{
  ll_lla_init_once();
  if (!ll_lla_valid(pin)) return;
  ll_lla_pins[pin].mode = (unsigned char) mode;
}

//! LOOPBACK, AND DELIBERATELY SO: digitalRead() returns what digitalWrite() last put here, which is
//! what makes a write-then-read assertion meaningful on a machine with no pins.  It is NOT a claim
//! about electrical behaviour -- nothing here drives anything.
static void ll_null_digital_write(int pin, int val)
{
  ll_lla_init_once();
  if (!ll_lla_valid(pin)) return;
  ll_lla_pins[pin].level = val ? 1 : 0;
}

static int ll_null_digital_read(int pin)
{
  ll_lla_init_once();
  if (!ll_lla_valid(pin)) return 0;
  return ll_lla_pins[pin].level;
}

//! analogWrite records a duty cycle; analogRead reads it back on the SAME pin.  Real hardware does
//! not work this way -- PWM out and ADC in are different subsystems, usually different pins -- and
//! that is precisely why the backend is named `null` and reports itself as simulated.
static void ll_null_analog_write(int pin, int val)
{
  ll_lla_init_once();
  if (!ll_lla_valid(pin)) return;
  ll_lla_pins[pin].duty = val;
}

static int ll_null_analog_read(int pin)
{
  ll_lla_init_once();
  if (!ll_lla_valid(pin)) return 0;
  return ll_lla_pins[pin].duty;
}

static void ll_null_tone_on(int pin, unsigned int freq)   { ll_lla_init_once(); if (ll_lla_valid(pin)) ll_lla_pins[pin].tone_hz = (int) freq; }

static void ll_null_tone_off(int pin)                     { ll_lla_init_once(); if (ll_lla_valid(pin)) ll_lla_pins[pin].tone_hz = 0; }

//! TIMING, not GPIO, and therefore SHARED -- it belongs to this file's dispatch half, not to the
//! null backend.  The earlier note here said it should move "when a second backend lands"; libgpiod
//! has now landed and it does NOT define delayMicroseconds, so there is no duplicate symbol and
//! nothing to move.  A real sleep is a real sleep whether pins are simulated or driven, so every
//! backend shares this one.  If a backend ever needs its own, it goes in that backend and this
//! becomes a dispatch entry -- do not add a second definition beside this one.
//!
//! NOTE ON THIS FILE'S NAME: it is no longer only the null backend.  It now holds the dispatch
//! table, the backend selection, the shared timing, AND the null backend.  The name predates the
//! dispatch layer; read it as llarduino-core.
#if !LL_ESP32   //!< the ESP32 has its own delayMicroseconds in ll_platform_ESP32.cpp
                //!< (esp_rom_delay_us) -- a POSIX nanosleep is wrong on an MCU (P176).
void delayMicroseconds(unsigned long us)
{
  struct timespec ts, rem;
  ts.tv_sec  = (time_t) (us / 1000000UL);
  ts.tv_nsec = (long)   ((us % 1000000UL) * 1000UL);
  //! RESUME ON EINTR.  A bare nanosleep() returns EARLY whenever any signal arrives, and this
  //! process has timers, so `delay_us(2000)` was completing in well under a millisecond -- a delay
  //! that silently does not delay.  Caught by the LLArduino conformance suite's lower bound, which
  //! exists precisely because a too-short sleep still passes every monotonicity check.  This was my
  //! own bug in the first cut of this file, found by the test written to find exactly this.
  while (nanosleep(&ts, &rem) == -1 && errno == EINTR) ts = rem;
}
#endif // !LL_ESP32

//! Inspection hooks so a test can assert on state the Arduino API cannot report back.
//! digitalRead() cannot tell you the MODE, and nothing in the API reads back a duty or a tone, so
//! without these the backend would be only half-observable and half the assertions could not exist.
static int ll_null_pin_mode_get(int pin) { ll_lla_init_once(); return ll_lla_valid(pin) ? (int) ll_lla_pins[pin].mode : -1; }
static int ll_null_pin_duty_get(int pin) { ll_lla_init_once(); return ll_lla_valid(pin) ? ll_lla_pins[pin].duty : -1; }
static int ll_null_pin_tone_get(int pin) { ll_lla_init_once(); return ll_lla_valid(pin) ? ll_lla_pins[pin].tone_hz : -1; }
static int ll_null_npins()                { return LL_LLA_NPINS; }



// ---------------------------------------------------------------------------
// BACKEND DISPATCH -- so a second backend can exist at all
// ---------------------------------------------------------------------------
//! Until now the null backend WAS the implementation: pinMode() and friends were defined
//! directly here, so adding a libgpiod backend would have been two definitions of the same symbol.
//! The public Arduino names now dispatch through a table and each backend fills one in.
//!
//! SELECTION IS AT RUNTIME, NOT COMPILE TIME, and deliberately: the same aarch64 binary runs on a
//! Jetson with a 40-pin header and on a headless x86 box with gpiochips that are NOT header pins.
//! Which backend is correct is a property of the MACHINE, not of the build, so it is decided by
//! probing the machine -- and it falls back to null rather than driving something at random.
struct LLArduinoBackend {
  const char *name;
  void (*pin_mode)(int, int);
  void (*digital_write)(int, int);
  int  (*digital_read)(int);
  void (*analog_write)(int, int);
  int  (*analog_read)(int);
  void (*tone_on)(int, unsigned int);
  void (*tone_off)(int);
  int  (*pin_mode_get)(int);
  int  (*pin_duty_get)(int);
  int  (*pin_tone_get)(int);
  int  (*npins)(void);
};

static const LLArduinoBackend ll_backend_null = {
  "null",
  ll_null_pin_mode, ll_null_digital_write, ll_null_digital_read,
  ll_null_analog_write, ll_null_analog_read,
  ll_null_tone_on, ll_null_tone_off,
  ll_null_pin_mode_get, ll_null_pin_duty_get, ll_null_pin_tone_get, ll_null_npins
};

#if LL_GPIOD
//! The libgpiod backend lives in ll_llarduino_gpiod.cpp; only its entry points are needed here.
extern bool ll_gpiod_available();
extern void ll_gpiod_pin_mode(int, int);
extern void ll_gpiod_digital_write(int, int);
extern int  ll_gpiod_digital_read(int);
extern void ll_gpiod_analog_write(int, int);
extern int  ll_gpiod_analog_read(int);
extern void ll_gpiod_tone_on(int, unsigned int);
extern void ll_gpiod_tone_off(int);
extern int  ll_gpiod_pin_mode_get(int);
extern int  ll_gpiod_pin_duty_get(int);
extern int  ll_gpiod_pin_tone_get(int);
extern int  ll_gpiod_npins();

static const LLArduinoBackend ll_backend_gpiod = {
  "libgpiod",
  ll_gpiod_pin_mode, ll_gpiod_digital_write, ll_gpiod_digital_read,
  ll_gpiod_analog_write, ll_gpiod_analog_read,
  ll_gpiod_tone_on, ll_gpiod_tone_off,
  ll_gpiod_pin_mode_get, ll_gpiod_pin_duty_get, ll_gpiod_pin_tone_get, ll_gpiod_npins
};
#endif

#if LL_IDF_GPIO
//! The ESP-IDF backend lives in ll_llarduino_espidf.cpp; only its entry points are needed here.
extern bool ll_idf_available();
extern void ll_idf_pin_mode(int, int);
extern void ll_idf_digital_write(int, int);
extern int  ll_idf_digital_read(int);
extern void ll_idf_analog_write(int, int);
extern int  ll_idf_analog_read(int);
extern void ll_idf_tone_on(int, unsigned int);
extern void ll_idf_tone_off(int);
extern int  ll_idf_pin_mode_get(int);
extern int  ll_idf_pin_duty_get(int);
extern int  ll_idf_pin_tone_get(int);
extern int  ll_idf_npins();

static const LLArduinoBackend ll_backend_idf = {
  "esp-idf",
  ll_idf_pin_mode, ll_idf_digital_write, ll_idf_digital_read,
  ll_idf_analog_write, ll_idf_analog_read,
  ll_idf_tone_on, ll_idf_tone_off,
  ll_idf_pin_mode_get, ll_idf_pin_duty_get, ll_idf_pin_tone_get, ll_idf_npins
};
#endif

static const LLArduinoBackend *ll_be = &ll_backend_null;

//! CHOSEN ONCE, ON FIRST USE, BY PROBING THE MACHINE.  libgpiod is preferred where it can actually
//! drive something -- which requires BOTH a usable gpiochip AND a pin map for this board.  Either
//! missing falls back to null, because a pin number with no map does not identify a line and
//! driving one anyway would be arbitrary.  On hardware, arbitrary means a motor.
static void ll_backend_select_once()
{
  static bool done = false;
  if (done) return;
  done = true;
#if LL_IDF_GPIO
  if (ll_idf_available()) { ll_be = &ll_backend_idf; return; }   //!< on-die GPIO: always present
#endif
#if LL_GPIOD
  if (ll_gpiod_available()) { ll_be = &ll_backend_gpiod; return; }
#endif
  ll_be = &ll_backend_null;
}

//! Public Arduino surface -- one line each, straight through the table.
void pinMode(int pin, int mode)                           { ll_backend_select_once(); ll_be->pin_mode(pin, mode); }
void digitalWrite(int pin, int val)                       { ll_backend_select_once(); ll_be->digital_write(pin, val); }
int  digitalRead(int pin)                                 { ll_backend_select_once(); return ll_be->digital_read(pin); }
void analogWrite(int pin, int val)                        { ll_backend_select_once(); ll_be->analog_write(pin, val); }
int  analogRead(int pin)                                  { ll_backend_select_once(); return ll_be->analog_read(pin); }
void tone(int pin, unsigned int freq)                     { ll_backend_select_once(); ll_be->tone_on(pin, freq); }
void tone(int pin, unsigned int freq, unsigned long dur)  { (void) dur; ll_be->tone_on(pin, freq); }
void noTone(int pin)                                      { ll_backend_select_once(); ll_be->tone_off(pin); }

int         ll_llarduino_pin_mode(int pin) { return ll_be->pin_mode_get(pin); }
int         ll_llarduino_pin_duty(int pin) { return ll_be->pin_duty_get(pin); }
int         ll_llarduino_pin_tone(int pin) { return ll_be->pin_tone_get(pin); }
int         ll_llarduino_npins()           { return ll_be->npins(); }
const char *ll_llarduino_backend()         { ll_backend_select_once(); return ll_be->name; }

#endif // LL_ARDUINO
//! @}
