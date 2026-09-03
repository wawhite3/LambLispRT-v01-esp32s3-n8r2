// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"
//! @defgroup xmop3 Hardware & Platform Builtins (xmop3)
//! @brief The C++ `ll_xmop3_*` builtins that expose hardware and platform features to Scheme --
//!        GPIO, buses (I2C/SPI/1-Wire), sensors, displays, LEDs, WiFi, camera, GPU, and platform control.
//! @defgroup xmop3_gpio GPIO & Basic I/O
//! @ingroup xmop3
//! @brief LambLisp GPIO & Basic I/O builtins.
//! @{

#if LL_COMMONIO

#if 0
Ethernet Class

Ethernet.begin()
Ethernet.dnsServerIP()
Ethernet.gatewayIP()
Ethernet.hardwareStatus()
Ethernet.init()
Ethernet.linkStatus()
Ethernet.localIP()
Ethernet.MACAddress()
Ethernet.maintain()
Ethernet.setDnsServerIP()
Ethernet.setGatewayIP()
Ethernet.setLocalIP()
Ethernet.setMACAddress()
Ethernet.setRetransmissionCount()
Ethernet.setRetransmissionTimeout()
Ethernet.setSubnetMask()
Ethernet.subnetMask()

IPAddress Class

IPAddress()

Server Class

Server
EthernetServer()
server.begin()
server.accept()
server.available()
server.write()
server.print()
server.println()

Client Class

Client
EthernetClient()
client.connected()
client.connect()
client.localPort()
client.remoteIP()
client.remotePort()
client.setConnectionTimeout()
client.write()
print()
client.println()
client.available()
client.read()
client.flush()
client.stop()

EthernetUDP Class

EthernetUDP.begin()
EthernetUDP.read()
EthernetUDP.write()
EthernetUDP.beginPacket()
EthernetUDP.endPacket()
EthernetUDP.parsePacket()
EthernetUDP.available()

UDP class

UDP.stop()
UDP.remoteIP()
UDP.remotePort()
      

#endif
//
//Hardware Abstraction Layer
//

//! Read digital pin state; returns #t if HIGH, #f if LOW.
Sexpr_t mop3_cio_digitalRead(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{  return lamb.mk_bool(digitalRead(lamb.car(sexpr)->mustbe_int32()) != 0, env_exec); }
//! Write digital pin HIGH/LOW.  Level is Scheme-truthy (only #f is LOW) with one pragmatic
//! extension: a NUMERIC ZERO also drives LOW.  So (digitalWrite p #f) and (digitalWrite p 0)
//! both give LOW; (digitalWrite p #t) and (digitalWrite p 1) give HIGH.
Sexpr_t mop3_cio_digitalWrite(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  Sexpr_t v = lamb.cadr(sexpr);
  bool high = (v != HASHF);                               // Scheme falsiness: only #f is LOW...
  if (v->is_any_int()) {                                  // ...but a numeric 0 is LOW too
    if (v->type() == Cell::T_INT32)      high = (v->as_int32() != 0);
    else if (v->type() == Cell::T_INT64) high = (v->as_int64() != 0);
    // T_BIGNUM is never zero (0 is stored as T_INT32) -> stays HIGH
  }
  else if (v->is_any_real()) {
    high = (v->type() == Cell::T_FLOAT32) ? (v->as_float32() != 0.0f) : (v->as_float64() != 0.0);
  }
  digitalWrite(lamb.car(sexpr)->mustbe_int32(), high);
  return OBJ_VOID;
}
//! Configure a pin as INPUT, INPUT_PULLUP, or OUTPUT.
Sexpr_t mop3_cio_pinMode(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{  pinMode(lamb.car(sexpr)->mustbe_int32(), lamb.cadr(sexpr)->mustbe_int32());  return OBJ_VOID; }
//! Read analog pin; returns raw ADC integer value.
Sexpr_t mop3_cio_analogRead(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{  return lamb.mk_integer(analogRead(lamb.car(sexpr)->mustbe_int32()), env_exec); }
//! Write analog PWM value to pin.
Sexpr_t mop3_cio_analogWrite(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{  analogWrite(lamb.car(sexpr)->mustbe_int32(), lamb.cadr(sexpr)->mustbe_int32());  return OBJ_VOID; }
//! Delay execution by the given number of milliseconds.
Sexpr_t mop3_cio_delay_ms(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{  delay(lamb.car(sexpr)->mustbe_int32());  return HASHT; }
//! Delay execution by the given number of microseconds.
Sexpr_t mop3_cio_delay_us(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{  delayMicroseconds(lamb.car(sexpr)->mustbe_int32());  return HASHT; }

//! Set ADC resolution in bits (stub -- platform-dependent).
Sexpr_t mop3_cio_analogReadResolution(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return OBJ_UNDEF; }
//! Set ADC voltage reference (stub -- platform-dependent).
Sexpr_t mop3_cio_analogReference(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return OBJ_UNDEF; }
//! Set DAC/PWM resolution in bits (stub -- platform-dependent).
Sexpr_t mop3_cio_analogWriteResolution(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return OBJ_UNDEF; }
//! Stop tone generation on a pin (stub).
Sexpr_t mop3_cio_noTone(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Measure a pulse on a pin; returns duration in microseconds (stub).
Sexpr_t mop3_cio_pulseIn(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Like pulseIn but supports longer pulses (stub).
Sexpr_t mop3_cio_pulseInLong(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return OBJ_UNDEF; }
//! Shift in a byte of data one bit at a time (stub).
Sexpr_t mop3_cio_shiftIn(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Shift out a byte of data one bit at a time (stub).
Sexpr_t mop3_cio_shiftOut(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }

//! Generate a square wave tone on a pin at the given frequency and optional duration (ms).
Sexpr_t mop3_cio_tone(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  LL_int32 pin = lamb.car(sexpr)->mustbe_int32();
  LL_int32 freq = lamb.cadr(sexpr)->coerce_int32();
  if (lamb.cddr(sexpr) == NIL) tone(pin, freq);
  else {
    LL_int32 dur = lamb.caddr(sexpr)->coerce_int32();
    tone(pin, freq, dur);
  }
  return OBJ_UNDEF;
}

//! Return a bitmask with only bit n set (stub).
Sexpr_t mop3_cio_bit(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Clear a specific bit in an integer (stub).
Sexpr_t mop3_cio_bitClear(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Read a specific bit from an integer (stub).
Sexpr_t mop3_cio_bitRead(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Set a specific bit in an integer (stub).
Sexpr_t mop3_cio_bitSet(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Write a specific bit in an integer (stub).
Sexpr_t mop3_cio_bitWrite(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Return the high byte of a two-byte integer (stub).
Sexpr_t mop3_cio_highByte(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Return the low byte of a two-byte integer (stub).
Sexpr_t mop3_cio_lowByte(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return OBJ_UNDEF; }
//! Attach an ISR to a digital pin interrupt (stub).
Sexpr_t mop3_cio_attachInterrupt(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return OBJ_UNDEF; }
//! Detach the ISR from a digital pin interrupt (stub).
Sexpr_t mop3_cio_detachInterrupt(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return OBJ_UNDEF; }
//! Return the interrupt number for a given digital pin (stub).
Sexpr_t mop3_cio_digitalPinToInterrupt(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return OBJ_UNDEF; }
//! Re-enable interrupts globally (stub).
Sexpr_t mop3_cio_interrupts(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return OBJ_UNDEF; }
//! Disable interrupts globally (stub).
Sexpr_t mop3_cio_noInterrupts(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return OBJ_UNDEF; }

#endif

Sexpr_t CommonIO_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::CommonIO_install_mop3()");

  ll_try {
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } base_procs[] = {
      { CommonIO_install_mop3, "CommonIO-install-mop3", false },
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
#if LL_COMMONIO
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } cio_procs[] = {
      { mop3_cio_digitalRead,              "digitalRead",              false },
      { mop3_cio_digitalWrite,             "digitalWrite",             false },
      { mop3_cio_pinMode,                  "pinMode",                  false },
      { mop3_cio_analogRead,               "analogRead",               false },
      { mop3_cio_analogReadResolution,     "analogReadResolution",     false },
      { mop3_cio_analogReference,          "analogReference",          false },
      { mop3_cio_analogWrite,              "analogWrite",              false },
      { mop3_cio_analogWriteResolution,    "analogWriteResolution",    false },
      { mop3_cio_noTone,                   "noTone",                   false },
      { mop3_cio_pulseIn,                  "pulseIn",                  false },
      { mop3_cio_pulseInLong,              "pulseInLong",              false },
      { mop3_cio_shiftIn,                  "shiftIn",                  false },
      { mop3_cio_shiftOut,                 "shiftOut",                 false },
      { mop3_cio_tone,                     "tone",                     false },
      { mop3_cio_delay_ms,                 "delay_ms",                 false },
      { mop3_cio_delay_us,                 "delay_us",                 false },
      { mop3_cio_bit,                      "bit",                      false },
      { mop3_cio_bitClear,                 "bitClear",                 false },
      { mop3_cio_bitRead,                  "bitRead",                  false },
      { mop3_cio_bitSet,                   "bitSet",                   false },
      { mop3_cio_bitWrite,                 "bitWrite",                 false },
      { mop3_cio_highByte,                 "highByte",                 false },
      { mop3_cio_lowByte,                  "lowByte",                  false },
      { mop3_cio_attachInterrupt,          "attachInterrupt",          false },
      { mop3_cio_detachInterrupt,          "detachInterrupt",          false },
      { mop3_cio_digitalPinToInterrupt,    "digitalPinToInterrupt",    false },
      { mop3_cio_interrupts,               "interrupts",               false },
      { mop3_cio_noInterrupts,             "noInterrupts",             false },
    };
    const int Ncio_procs = sizeof(cio_procs)/sizeof(cio_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Ncio_procs);
    for (int i = 0; i < Ncio_procs; i++) {
      const auto &p = cio_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#endif

#if LL_COMMONIO
    static const struct { int val; const char *name; }
      INT_constants[] = {

#define _make_intbinding_(_sym_) { _sym_, #_sym_ }
      _make_intbinding_(HIGH),
      _make_intbinding_(LOW),
      _make_intbinding_(INPUT),
      _make_intbinding_(INPUT_PULLUP),
      _make_intbinding_(OUTPUT)
#undef _make_intbinding_

    };
    
    const LL_int32 Nconst = sizeof(INT_constants)/sizeof(INT_constants[0]);
    lamb.log("%s defining %d constants\n", me, Nconst);
    for (int i=0; i<Nconst; i++) {
      auto p = INT_constants[i];
      Sexpr_t sym = lamb.mk_symbol(p.name, NIL);
      Sexpr_t val = lamb.mk_integer(p.val, sym);
      lamb.dict_bind_bang(env_target, sym, val, env_exec);
    }
#endif
    
    return NIL;
  }
  
  ll_catch();
}
//! @}
