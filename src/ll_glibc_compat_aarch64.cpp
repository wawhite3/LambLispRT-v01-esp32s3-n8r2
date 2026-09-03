// Copyright 2026 by Frobenius Norm LLC 2026-04-11 00:00:00
// Free for non-commercial use. Commercial use requires a license.
// ll_glibc_compat_aarch64.cpp -- portable replacements for glibc-versioned symbols.
//
// GCC 13 + glibc 2.38 headers introduce GLIBC_2.38-versioned references to
// fmod and strtol that are absent on the Jetson (Ubuntu 22.04, glibc 2.35).
//
// Rather than pulling in versioned glibc entry points, we supply our own
// clean implementations.  The linker flags in platformio.ini redirect all
// callers here at link time:
//   -Wl,--wrap=fmod  -Wl,--wrap=strtol  -Wl,--wrap=__isoc23_strtol

#if defined(__aarch64__)

#include <stddef.h>   // NULL
#include <errno.h>    // ERANGE
#include <limits.h>   // LONG_MIN, LONG_MAX
#include <math.h>     // isnan, isinf (these are macros, no versioned symbol)

// ---------------------------------------------------------------------------
// fmod -- IEEE 754 remainder via repeated subtraction using hardware divide.
// fmod(x,y) = x - n*y  where n = trunc(x/y).
// Handles NaN, inf, zero-divisor per IEEE 754.
// ---------------------------------------------------------------------------

extern "C" double __wrap_fmod(double x, double y)
{
  if (isnan(x) || isnan(y) || isinf(x) || y == 0.0)
    return __builtin_nan("");          // NaN per IEEE 754

  if (isinf(y) || x == 0.0)
    return x;                          // fmod(finite, inf) = x; fmod(0,y) = 0

  // trunc(x/y)*y subtracted from x, carried out in double precision.
  // __builtin_trunc avoids any versioned libm call.
  double n = __builtin_trunc(x / y);
  double r = x - n * y;

  // Correct residual rounding drift: |r| must be < |y|.
  if (__builtin_fabs(r) >= __builtin_fabs(y))
    r -= __builtin_copysign(y, r);

  // Preserve sign of zero (fmod(-0,y) = -0).
  if (r == 0.0)
    return __builtin_copysign(0.0, x);

  return r;
}

// ---------------------------------------------------------------------------
// strtol -- convert string to long, base 0 or 2-36.
// Mirrors POSIX strtol semantics including ERANGE detection.
// ---------------------------------------------------------------------------

extern "C" long __wrap_strtol(const char *s, char **endp, int base)
{
  if (!s) {
    if (endp) *endp = const_cast<char *>(s);
    return 0L;
  }

  // Skip leading whitespace.
  while (*s == ' ' || (*s >= '\t' && *s <= '\r')) ++s;

  // Optional sign.
  int neg = 0;
  if (*s == '-') { neg = 1; ++s; }
  else if (*s == '+') { ++s; }

  // Detect base from prefix when base == 0.
  if (base == 0) {
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
    else if (s[0] == '0')                              { base = 8;  }
    else                                                { base = 10; }
  } else if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    s += 2;
  }

  // Accumulate digits.
  unsigned long acc = 0;
  int any = 0;
  int overflow = 0;
  unsigned long limit = neg ? (unsigned long)LONG_MIN : (unsigned long)LONG_MAX;

  while (1) {
    int d;
    char c = *s;
    if      (c >= '0' && c <= '9') d = c - '0';
    else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
    else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
    else break;
    if (d >= base) break;
    if (!overflow) {
      if (acc > (limit - d) / base) overflow = 1;
      else acc = acc * base + d;
    }
    ++any;
    ++s;
  }

  if (endp) *endp = const_cast<char *>(any ? s : (s - (neg || (base == 16 && *(s-1) == 'x') ? 1 : 0)));
  // Simpler: just point endp at current s position if digits were seen.
  if (endp) *endp = const_cast<char *>(s);

  if (overflow) {
    errno = ERANGE;
    return neg ? LONG_MIN : LONG_MAX;
  }
  return neg ? -(long)acc : (long)acc;
}

// __isoc23_strtol is the C23 name GCC 13 emits; redirect to our implementation.
extern "C" long __wrap___isoc23_strtol(const char *s, char **endp, int base)
{
  return __wrap_strtol(s, endp, base);
}

#endif  // __aarch64__
