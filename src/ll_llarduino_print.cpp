// Copyright 2026 by Frobenius Norm LLC 2026-09-04
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"

//! @addtogroup llarduino
//! @brief Print / Stream / Serial -- REAL character I/O, not a simulation.
//!
//! Print and Stream are pure character I/O, and LambStdio already implements exactly that on
//! POSIX, so this is a facade over working plumbing rather than a stand-in.  That is the same
//! footing as millis(): genuinely implemented on the host, not faked.
//!
//! ARDUINO'S QUIRKS ARE MATCHED ON PURPOSE.  Each of these is a place where a host test could pass
//! while a device disagrees, which is the failure criterion 3 is designed to catch:
//!   * println() ends "\r\n", NOT "\n"  -- Arduino has always done this, and a serial monitor shows it
//!   * write() returns a BYTE COUNT     -- callers legitimately sum it
//!   * print(double) defaults to 2 dp   -- not %g, not full precision
//!   * print(int, base) takes BIN/OCT/DEC/HEX and prints NO prefix ("ff", not "0xff")
//! @{

#if LL_ARDUINO

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Print
// ---------------------------------------------------------------------------

size_t Print::write(const uint8_t *buf, size_t n)
{
  size_t w = 0;
  while (n--) w += write(*buf++);
  return w;
}

size_t Print::write(const char *s)      { return s ? write((const uint8_t *) s, strlen(s)) : 0; }
size_t Print::print(char c)             { return write((uint8_t) c); }
size_t Print::print(const char *s)      { return write(s); }
size_t Print::print(const String &s)    { return write(s.c_str()); }

//! Integer formatting.  Arduino prints NO base prefix -- print(255, HEX) is "ff", not "0xff" -- and
//! a NEGATIVE number is only signed in base 10, matching Arduino, where other bases print the
//! unsigned bit pattern.  Both are easy to get subtly wrong and both are observable from a test.
static size_t ll_print_ulong(Print &p, unsigned long v, int base)
{
  char buf[8 * sizeof(unsigned long) + 1];
  int i = 0;
  if (base < 2) base = 10;
  if (v == 0) { buf[i++] = '0'; }
  while (v) { unsigned long d = v % (unsigned long) base; v /= (unsigned long) base;
              //! UPPERCASE, because Arduino's Print::printNumber does `c + 'A' - 10` and the vendor
              //! core is the reference here.  Measured on an ESP32-S3: the vendor
              //! core answered "FF" where this answered "ff" -- the ONE disagreement out of 35
              //! assertions across both backends, and it was mine.  A host-only test could never
              //! have found it: there is nothing on a host to disagree with.
              buf[i++] = (char) (d < 10 ? '0' + d : 'A' + (d - 10)); }
  size_t w = 0;
  while (i--) w += p.write((uint8_t) buf[i]);
  return w;
}

size_t Print::print(long n, int base)
{
  if (base == 10 && n < 0) { size_t w = write((uint8_t) '-'); return w + ll_print_ulong(*this, (unsigned long) (-n), 10); }
  return ll_print_ulong(*this, (unsigned long) n, base);
}

size_t Print::print(int n, int base)            { return print((long) n, base); }
size_t Print::print(unsigned long n, int base)  { return ll_print_ulong(*this, n, base); }

//! Arduino's default is TWO decimal places, not %g and not full precision.
size_t Print::print(double v, int digits)
{
  char buf[64];
  snprintf(buf, sizeof(buf), "%.*f", digits < 0 ? 0 : digits, v);
  return write(buf);
}

//! CRLF -- Arduino's println has always emitted "\r\n".  A host that emits bare "\n" looks correct
//! in a terminal and differs from the device, which is exactly the silent divergence to avoid.
size_t Print::println()                             { return write("\r\n"); }
size_t Print::println(char c)                       { return print(c)          + println(); }
size_t Print::println(const char *s)                { return print(s)          + println(); }
size_t Print::println(const String &s)              { return print(s)          + println(); }
size_t Print::println(int n, int base)              { return print(n, base)    + println(); }
size_t Print::println(long n, int base)             { return print(n, base)    + println(); }
size_t Print::println(unsigned long n, int base)    { return print(n, base)    + println(); }
size_t Print::println(double v, int digits)         { return print(v, digits)  + println(); }

//! HardwareSerial::printf is not standard Arduino Print, but LambLisp's own Stdio layer calls it
//! (ll_platform_Stdio.cpp), so the facade owes it.
size_t Print::printf(const char *fmt, ...)
{
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n < 0) return 0;
  if ((size_t) n >= sizeof(buf)) n = (int) sizeof(buf) - 1;   //!< truncate, never overrun
  return write((const uint8_t *) buf, (size_t) n);
}

// ---------------------------------------------------------------------------
// Serial -- over LambStdio, which is already the host's stdin/stdout
// ---------------------------------------------------------------------------

void LLArduinoSerial::begin(unsigned long baud) { LambStdio.begin(baud); }
void LLArduinoSerial::end()                     { LambStdio.end(); }
int  LLArduinoSerial::availableForWrite()       { return LambStdio.availableForWrite(); }
void LLArduinoSerial::flush()                   { LambStdio.flush(); }
size_t LLArduinoSerial::write(uint8_t c)        { return LambStdio.write(c) > 0 ? 1u : 0u; }

//! available() must count the pushed-back byte, or peek() would hide input from a caller that
//! polls available() before reading -- the classic Stream bug.
int LLArduinoSerial::available()
{
  int n = LambStdio.available();
  return (_peeked >= 0) ? n + 1 : n;
}

int LLArduinoSerial::read()
{
  if (_peeked >= 0) { int c = _peeked; _peeked = -1; return c; }
  return LambStdio.read();
}

//! One byte of pushback, which is all Stream promises.  LambStdioClass has no peek of its own.
int LLArduinoSerial::peek()
{
  if (_peeked < 0) _peeked = LambStdio.read();
  return _peeked;
}

LLArduinoSerial Serial;

#endif // LL_ARDUINO
//! @}

// ---------------------------------------------------------------------------
// Fidelity accessors -- compiled for BOTH backends on purpose
// ---------------------------------------------------------------------------
//! Criterion 3 is "the same suite passes against the vendor core AND against LLArduino".
//! These render through whichever Print is compiled in, which is what makes that comparison
//! possible -- Arduino's Print and LLArduino's both declare `virtual size_t write(uint8_t)` and the
//! same print(long,base) / print(double,digits) overloads, so ONE implementation serves both.
//!
//! THEY WERE LL_ARDUINO-ONLY AND THAT WAS THE BUG.  Built that way, the ESP32 run returned #f from
//! every accessor and the suite reported 10 FAILURES that were purely my own stub -- on the ONE
//! backend where comparing against Arduino is the entire point.  A measuring instrument that
//! cannot be pointed at the reference measures nothing.
#if LL_ARDUINO || LL_ESP_ARDUINO
// ---------------------------------------------------------------------------
// Buffer-backed Print, so the FIDELITY CLAIMS ABOVE ARE TESTABLE
// ---------------------------------------------------------------------------

//! Print's Arduino-specific behaviours -- CRLF from println, no 0x prefix from print(n, HEX), two
//! decimal places from print(double) -- were documented in the header and then not exercised by
//! anything, because Print is a C++ class with no Scheme binding.  A documented guarantee that
//! nothing checks is just a comment; this file has already watched that pattern cost days
//! elsewhere in the tree.  These three accessors render THROUGH Print into a buffer, so a Scheme
//! test asserts what a device would actually emit rather than what the comment says.
class LLArduinoBufPrint : public Print {
  char   _b[256];
  size_t _n;
public:
  LLArduinoBufPrint() : _n(0) { _b[0] = '\0'; }
  size_t write(uint8_t c) override {
    if (_n + 1 >= sizeof(_b)) return 0;              //!< truncate, never overrun
    _b[_n++] = (char) c;  _b[_n] = '\0';  return 1;
  }
  const char *str() const { return _b; }
  using Print::write;
};

static char ll_lla_fmtbuf[256];

const char *ll_llarduino_fmt_int(long v, int base)
{
  LLArduinoBufPrint p;  p.print(v, base);
  snprintf(ll_lla_fmtbuf, sizeof(ll_lla_fmtbuf), "%s", p.str());
  return ll_lla_fmtbuf;
}

const char *ll_llarduino_fmt_real(double v, int digits)
{
  LLArduinoBufPrint p;  p.print(v, digits);
  snprintf(ll_lla_fmtbuf, sizeof(ll_lla_fmtbuf), "%s", p.str());
  return ll_lla_fmtbuf;
}

//! Returns println()'s terminator with the bytes VISIBLE as escapes, because the whole point is
//! that it is "\r\n" and not "\n" -- a raw terminator would be invisible in a test's output and
//! an assertion on it would read as passing whichever it was.
const char *ll_llarduino_eol()
{
  LLArduinoBufPrint p;  p.println();
  const char *s = p.str();
  size_t o = 0;
  for (size_t i = 0; s[i] && o + 4 < sizeof(ll_lla_fmtbuf); i++) {
    if      (s[i] == '\r') { ll_lla_fmtbuf[o++] = '\\'; ll_lla_fmtbuf[o++] = 'r'; }
    else if (s[i] == '\n') { ll_lla_fmtbuf[o++] = '\\'; ll_lla_fmtbuf[o++] = 'n'; }
    else                    { ll_lla_fmtbuf[o++] = s[i]; }
  }
  ll_lla_fmtbuf[o] = '\0';
  return ll_lla_fmtbuf;
}

#endif // LL_ARDUINO || LL_ESP_ARDUINO
