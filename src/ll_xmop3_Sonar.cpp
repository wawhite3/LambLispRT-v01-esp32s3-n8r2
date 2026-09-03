/// Copyright 2026 by Frobenius Norm LLC 2026-04-23 00:00:00
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"


#if LL_SONAR

#if LL_ESP32
#include "driver/gpio.h"
#include "esp_attr.h"
#include <climits>
//! @defgroup xmop3_sonar Ultrasonic Sonar (HC-SR04)
//! @ingroup xmop3
//! @brief LambLisp Ultrasonic Sonar (HC-SR04) builtins.
//! @{

/*!
  Two-word ISR interface.  Written by distinct parties with no overlap:
    sonar_start_us  -- written by Sonar::start() before the trigger pulse;
                       read by the ISR and by result().  Zero means idle.
    sonar_end_us    -- written by the FALLING-edge ISR when ECHO goes LOW;
                       read and cleared by result().  Zero means no echo yet.

  Sequence for one measurement:
    1. start(): sonar_end_us=0, sonar_start_us=micros(), fire 10 us trigger
    2. ISR fires on FALLING edge of ECHO: sonar_end_us = micros()
    3. result(): returns sonar_end_us - sonar_start_us, clears sonar_end_us
    4. Caller calls start() again for the next ping.

  ECHO waveform (HC-SR04):
    _____|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|_____
         ^                        ^
    RISING (~450 us after trig)   FALLING = echo received
                                  ISR fires here --> sonar_end_us

  elapsed = sonar_end_us - sonar_start_us
          = sensor_init_delay (~450 us) + acoustic_round_trip
  Caller subtracts SONAR_INIT_US to get the pure round-trip; distance() does this.
*/
static volatile unsigned long sonar_start_us = 0;  //!< set by start(); 0=idle
static volatile unsigned long sonar_end_us   = 0;  //!< set by FALLING ISR; 0=pending
static portMUX_TYPE sonar_mux = portMUX_INITIALIZER_UNLOCKED;  //!< ISR<->result() atomicity

/*! FALLING-edge ISR: ECHO pin went LOW -- echo received (or timeout on sensor side). */
void IRAM_ATTR sonar_echo_isr(void* arg) {
  portENTER_CRITICAL_ISR(&sonar_mux);            // P126 R2: serialize vs result()'s read-clear
  if (sonar_start_us != 0)       // guard: ignore stray edges when idle
    sonar_end_us = micros();
  portEXIT_CRITICAL_ISR(&sonar_mux);
}
#endif  // LL_ESP32

class Sonar {

public:

  const LL_float32          range_meters  = 4.0;       //!< maximum useful range
  const LL_float32          Vs_est_mps    = 343.0;      //!< speed of sound at 20 C
  /*! No-echo timeout (P126 R1): default 50 ms, ABOVE the HC-SR04 ~38 ms no-echo pulse, so every
      ping resolves within its own service window (a no-object ping's late FALLING edge no longer
      crosses into the next ping).  Runtime-tunable via set_timeout_us() / Sonar.timeout-us!,
      clamped to the range round-trip floor.  (Was a const ~25.3 ms -- shorter than the no-echo
      pulse -- which is exactly the F1 stale-echo defect.) */
  static constexpr unsigned long SONAR_TIMEOUT_DEFAULT_US = 50000UL;
  unsigned long             timeout_us = SONAR_TIMEOUT_DEFAULT_US;   //!< settable no-echo timeout
  /*! P126: HC-SR04 transducer ring-down. Back-to-back triggers closer than this
      alternate echo/timeout (the next burst fires while the last still rings), so
      ping() waits out this gap.  Tunable; ~60 ms is the datasheet recommendation. */
  static constexpr unsigned long SONAR_MIN_INTERVAL_DEFAULT_US = 60000UL;
  unsigned long             min_interval_us = SONAR_MIN_INTERVAL_DEFAULT_US;
  unsigned long             last_trigger_us = 0;   //!< micros() of the last trigger (either path)
  /*! HC-SR04 fixed init delay from trigger to ECHO-HIGH (empirical, ~450 us).
      Subtracted in us_to_distance so that distance reflects only acoustic travel. */
  static constexpr unsigned long SONAR_INIT_US  = 450UL;
  static constexpr unsigned long SONAR_TIMEOUT  = ULONG_MAX;  //!< sentinel: no echo

  //! Hard minimum timeout = round-trip at max range + 2 ms; the setter clamps to this.
  unsigned long timeout_floor_us() const {
    return (unsigned long)(2.0 * range_meters * 1000000.0 / Vs_est_mps) + 2000UL;
  }
  //! Runtime-tune the no-echo timeout (clamped to the range floor).
  void set_timeout_us(unsigned long us) {
    unsigned long floor_us = timeout_floor_us();
    timeout_us = (us < floor_us) ? floor_us : us;
  }
  void set_min_interval_us(unsigned long us) { min_interval_us = us; }

  // --- temperature-compensated speed of sound ---
  const LL_float32 gamma  = 1.40;
  const LL_float32 Tc0_k  = 273.15;
  const LL_float32 M      = 0.0289645;
  const LL_float32 R      = 8.31446261815324;
  const LL_float32 factor = gamma * R / M;

  LL_float32 us_to_distance(unsigned long elapsed_us, LL_float32 Tc = 20.0) {
    static LL_float32 Tc_prev = 20.0;
    static LL_float32 Vs_mps  = Vs_est_mps;
    if (Tc != Tc_prev) {
      Vs_mps  = sqrt(factor * (Tc0_k + Tc));
      Tc_prev = Tc;
    }
    long acoustic_us = (long)elapsed_us - (long)SONAR_INIT_US;
    if (acoustic_us <= 0) acoustic_us = 0;
    LL_float32 d = Vs_mps * (LL_float32) acoustic_us / 2000000.0f;
    return (d > range_meters) ? range_meters : d;   // P126 R1: over-range echo -> rated max ("no object")
  }

  void begin(int _pin_trig, int _pin_echo) {
    ME("Sonar::begin()");
    pin_trig = _pin_trig;
    pin_echo = _pin_echo;

    pinMode(pin_trig, OUTPUT);
    digitalWrite(pin_trig, LOW);
    pinMode(pin_echo, INPUT);

#if LL_ESP32
    esp_err_t err = gpio_install_isr_service(ESP_INTR_FLAG_IRAM);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE)
      global_printf("Sonar::begin gpio_install_isr_service err %d\n", err);

    gpio_set_intr_type((gpio_num_t)pin_echo, GPIO_INTR_NEGEDGE);  //FALLING edge only
    gpio_isr_handler_add((gpio_num_t)pin_echo, sonar_echo_isr, (void*) (intptr_t)pin_echo);
    gpio_intr_enable((gpio_num_t)pin_echo);
#endif
  }

  /*! Arm and fire one ping.  Returns immediately on ESP32; result() delivers the echo. */
  void start() {
#if LL_ESP32
    sonar_end_us   = 0;             // clear previous result before arming
    sonar_start_us = micros();      // record trigger time (ISR subtracts this)
    last_trigger_us = sonar_start_us;   // P126: drives ping()'s inter-ping settle gate
    gpio_set_level((gpio_num_t)pin_trig, 1);
    esp_rom_delay_us(10);
    gpio_set_level((gpio_num_t)pin_trig, 0);
#else
    last_ping_us = ping_blocking();
#endif
  }

  /*! Poll for echo.
      Returns: 0            -- still waiting (no echo yet, within timeout)
               SONAR_TIMEOUT -- timed out; no echo within range_meters
               other        -- elapsed microseconds (start to FALLING edge) */
  unsigned long result() {
#if LL_ESP32
    // P126 R2/R3: atomic sample/validate/clear vs the (possibly other-core) ISR; unsigned compare.
    unsigned long elapsed = 0, rc = 0;            // rc: 0 waiting, 1 echo, 2 timeout
    portENTER_CRITICAL(&sonar_mux);
    unsigned long start = sonar_start_us, end = sonar_end_us;
    if (end != 0) {
      elapsed = end - start; rc = 1;              // wrap-safe unsigned delta
      sonar_end_us   = 0;                         // consume result
      sonar_start_us = 0;                         // mark idle
    } else if (start != 0 && (micros() - start) > timeout_us) {   // unsigned compare (was signed cast)
      rc = 2;
      sonar_start_us = 0;                         // disarm on timeout
    }
    portEXIT_CRITICAL(&sonar_mux);
    return (rc == 1) ? elapsed : (rc == 2) ? SONAR_TIMEOUT : 0;
#else
    return last_ping_us;
#endif
  }

  /*! Blocking ping: start() then spin on result(). */
  unsigned long ping() {
#if LL_ESP32
    // P126: honor the HC-SR04 inter-ping settle gap so consecutive blocking reads
    // don't alternate echo/timeout (transducer ring-down from the previous burst).
    while ((unsigned long)(micros() - last_trigger_us) < min_interval_us)
      esp_rom_delay_us(200);
    start();
    unsigned long r;
    while ((r = result()) == 0) {}
    return (r == SONAR_TIMEOUT) ? 0 : r;
#else
    return ping_blocking();
#endif
  }

  LL_float32 poke() {
    unsigned long t = ping();
    return (t == 0) ? -1.0f : us_to_distance(t);
  }

private:
  LL_int32 pin_trig, pin_echo;
#if !LL_ESP32
  unsigned long last_ping_us = 0;

  unsigned long ping_blocking() {
    const unsigned long to = timeout_us;          // honor the (tunable) timeout on the host path too
    digitalWrite(pin_trig, HIGH);
    delayMicroseconds(10);
    digitalWrite(pin_trig, LOW);
    return pulseIn(pin_echo, HIGH, to);
  }
#endif
};

Sonar *sonar = 0;  //!< Sonar singleton.

//! Initialize the Sonar singleton with trigger and echo pin numbers.
Sexpr_t Sonar_mop3_begin(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  if (sonar) { delete sonar; sonar = 0; }
  sonar = new Sonar;
  LL_int32 pin_trig = lamb.car(sexpr)->mustbe_int32();
  LL_int32 pin_echo = lamb.cadr(sexpr)->mustbe_int32();
  sonar->begin(pin_trig, pin_echo);
  return OBJ_UNDEF;
}

/*! Start a ping.  On ESP32: non-blocking.  On other platforms: blocks on pulseIn. */
Sexpr_t Sonar_mop3_start(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  sonar->start();
  return OBJ_UNDEF;
}

/*! Returns:
      #f      -- echo not yet received (still within timeout window)
      0       -- timed out, no echo; caller should re-arm with Sonar.start
      integer -- elapsed microseconds; caller should convert and re-arm */
Sexpr_t Sonar_mop3_result(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  unsigned long t = sonar->result();
  if (t == 0)                   return HASHF;
  if (t == Sonar::SONAR_TIMEOUT) return lamb.mk_integer(0, env_exec);
  return lamb.mk_integer(t, env_exec);
}

//! Blocking ping: fire trigger, wait for echo, return elapsed microseconds or #f on timeout.
Sexpr_t Sonar_mop3_ping(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  unsigned long t = sonar->ping();
  return (t == 0) ? HASHF : lamb.mk_integer(t, env_exec);
}

//! Blocking ping converted to distance in meters; returns #f on timeout.
Sexpr_t Sonar_mop3_poke(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  LL_float32 d = sonar->poke();
  return (d < 0) ? HASHF : lamb.mk_float32(d, env_exec);
}

//! Convert elapsed microseconds to distance in meters; optional Celsius temperature arg.
Sexpr_t Sonar_mop3_us_to_distance(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  unsigned long us  = (unsigned long)lamb.car(sexpr)->coerce_int32();
  LL_float32        Tc  = (lamb.cdr(sexpr) != NIL) ? lamb.cadr(sexpr)->coerce_float32() : 20.0f;
  return lamb.mk_float32(sonar->us_to_distance(us, Tc), env_exec);
}

//! (Sonar.timeout-us! <us>) -- set the no-echo timeout at runtime; returns the
//! effective (clamped-to-range-floor) value so the caller can confirm it.
Sexpr_t Sonar_mop3_set_timeout_us(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  unsigned long us = (unsigned long)lamb.car(sexpr)->coerce_int32();
  sonar->set_timeout_us(us);
  return lamb.mk_integer(sonar->timeout_us, env_exec);
}

//! (Sonar.min-interval-us! <us>) -- set the HC-SR04 inter-ping settle gap at runtime;
//! returns the effective value.  Larger = steadier readings, lower max ping rate.
Sexpr_t Sonar_mop3_set_min_interval_us(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  unsigned long us = (unsigned long)lamb.car(sexpr)->coerce_int32();
  sonar->set_min_interval_us(us);
  return lamb.mk_integer(sonar->min_interval_us, env_exec);
}

#endif  // LL_SONAR

//! Install all Sonar symbols in base environment.
Sexpr_t Sonar_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Sonar_install_mop3()");
  ll_try {
#if LL_SONAR
    if (sonar) { delete sonar; sonar = 0; }
    sonar = new Sonar;
#endif
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } base_procs[] = {
      { Sonar_install_mop3, "Sonar.install-mop3", false },
    };
    const int Nbase_procs = sizeof(base_procs)/sizeof(base_procs[0]);
    for (int i = 0; i < Nbase_procs; i++) {
      const auto &p = base_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#if LL_SONAR
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } sonar_procs[] = {
      { Sonar_mop3_begin,          "Sonar.begin",       false },
      { Sonar_mop3_start,          "Sonar.start",       false },
      { Sonar_mop3_result,         "Sonar.result",      false },
      { Sonar_mop3_ping,           "Sonar.ping",        false },
      { Sonar_mop3_poke,           "Sonar.poke",        false },
      { Sonar_mop3_us_to_distance, "Sonar.us->distance",false },
      { Sonar_mop3_set_timeout_us, "Sonar.timeout-us!", false },
      { Sonar_mop3_set_min_interval_us, "Sonar.min-interval-us!", false },
    };
    const int Nsonar_procs = sizeof(sonar_procs)/sizeof(sonar_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nsonar_procs);
    for (int i = 0; i < Nsonar_procs; i++) {
      const auto &p = sonar_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#endif
    return OBJ_UNDEF;
  }
  ll_catch();
}
//! @}
