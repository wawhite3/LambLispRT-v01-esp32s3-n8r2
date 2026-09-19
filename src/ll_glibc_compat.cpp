// Copyright 2026 by Frobenius Norm LLC 2026-09-07 00:00:00
// Free for non-commercial use. Commercial use requires a license.
// ll_glibc_compat.cpp -- portable replacements for glibc-versioned symbols.
//
// WHAT THIS BUYS, AND WHY THE FILE EXISTS AT ALL.  Building on a modern distro makes the linker
// record GLIBC_2.38 version requirements for symbols NOTHING IN OUR SOURCE ASKED FOR: GCC 13 +
// glibc 2.38 headers redirect ordinary strtol/sscanf/fscanf calls to __isoc23_* entry points, and
// fmod/fmodf got new versions in 2.38.  The result refuses to START on any older host:
//
//   ./LambLisp.bin: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
//
// That is B274, and it excluded Debian 12 (2.36), Ubuntu 22.04 LTS (2.35) and RHEL 9 / Rocky 9
// (2.34) from the PUBLISHED linux_x86_64 package -- all of them plausible industrial-automation
// hosts.  The failure happens before main(), so no amount of care inside LambLisp can catch it,
// and it CANNOT REPRODUCE ON THE MACHINE THAT BUILT THE BINARY.  That is why it went unnoticed
// for as long as it did: every host that had run the artifact was the build host or a clone.
//
// The linker flags in boards.json (feature_flags.glibc_compat) redirect all callers here:
//   -Wl,--wrap=<name>          route callers to __wrap_<name>
//   -Wl,--undefined=__wrap_<name>   force this object to be pulled in from the archive
// Both halves are required.  A --wrap with no matching --undefined links clean and does nothing,
// because nothing references the object -- so the bug returns silently.  If you add a wrapper
// here, add BOTH flags there in the same edit.
//
// WAS aarch64-ONLY UNTIL 2026-09-07 (file was ll_glibc_compat_aarch64.cpp).  The same defect had
// been recognised and fixed for the Jetson and left open on x86-64, which is the target most
// customers actually download.  Do not re-narrow the guard.

#if defined(__linux__) && (defined(__aarch64__) || defined(__x86_64__))

#include <stddef.h>   // NULL
#include <errno.h>    // ERANGE
#include <limits.h>   // LONG_MIN, LONG_MAX, LLONG_MIN, LLONG_MAX, ULONG_MAX, ULLONG_MAX
#include <math.h>     // isnan, isinf (these are macros, no versioned symbol)
#include <stdarg.h>   // va_list, for the scanf forwarders
#include <stdio.h>    // FILE, for __isoc99_vfscanf

// ---------------------------------------------------------------------------
// fmod / fmodf -- IEEE 754 remainder via repeated subtraction using hardware divide.
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

//! Single precision twin of the above.  NOT a cast through __wrap_fmod: doing the arithmetic in
//! double and narrowing would double-round, so a value exactly representable in float could come
//! back changed.  is-even? / is-odd? / round on T_FLOAT32 go through here (ll_vm_mop3_rxrs.cpp),
//! and those must be exact for integral floats.
extern "C" float __wrap_fmodf(float x, float y)
{
  if (isnan(x) || isnan(y) || isinf(x) || y == 0.0f)
    return __builtin_nanf("");

  if (isinf(y) || x == 0.0f)
    return x;

  float n = __builtin_truncf(x / y);
  float r = x - n * y;

  if (__builtin_fabsf(r) >= __builtin_fabsf(y))
    r -= __builtin_copysignf(y, r);

  if (r == 0.0f)
    return __builtin_copysignf(0.0f, x);

  return r;
}

// ---------------------------------------------------------------------------
// Integer conversion.
//
// ONE CORE, THREE WIDTHS.  strtol / strtoll / strtoul differ only in how the parsed MAGNITUDE is
// range-checked, so the scanning is written once.  The previous version of this file open-coded
// strtol alone; adding three more copies of that loop would have been four places for a digit-
// table or a sign rule to drift apart.
// ---------------------------------------------------------------------------

/*! Scan an optionally-signed integer.  Returns the magnitude; the caller range-checks it.

  `ovf_out` reports overflow of the 64-bit ACCUMULATOR only -- a caller narrowing to long must
  still check its own range.  Accumulation saturates rather than wrapping, so a 200-digit input
  costs no more than a 20-digit one and cannot alias onto a valid value.
*/
static void ll_strto_core(const char *nptr, char **endp, int base,
                          unsigned long long *out, int *neg_out, int *ovf_out)
{
  const char *s = nptr;
  *out = 0ULL;  *neg_out = 0;  *ovf_out = 0;

  if (!s) {
    if (endp) *endp = const_cast<char *>(nptr);
    return;
  }

  // Skip leading whitespace.
  while (*s == ' ' || (*s >= '\t' && *s <= '\r')) ++s;

  // Optional sign.
  int neg = 0;
  if      (*s == '-') { neg = 1; ++s; }
  else if (*s == '+') { ++s; }

  // Detect base from prefix when base == 0.
  if (base == 0) {
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
    else if (s[0] == '0')                            { base = 8;  }
    else                                             { base = 10; }
  } else if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
    s += 2;
  }

  unsigned long long acc = 0ULL;
  int any = 0;
  int overflow = 0;

  while (1) {
    int d;
    char c = *s;
    if      (c >= '0' && c <= '9') d = c - '0';
    else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
    else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
    else break;
    if (d >= base) break;
    if (!overflow) {
      if (acc > (ULLONG_MAX - (unsigned long long) d) / (unsigned long long) base) overflow = 1;
      else acc = acc * (unsigned long long) base + (unsigned long long) d;
    }
    ++any;
    ++s;
  }

  //! POSIX: WITH NO DIGITS CONVERTED, endp GETS THE ORIGINAL nptr -- not the position after a
  //! consumed sign or "0x" prefix.  The version this replaces returned the advanced pointer
  //! unconditionally, so strtol("-", &e, 10) reported e at the NUL with no error: a caller doing
  //! the usual `if (e == s || *e) reject;` accepted a lone "-" as the integer 0.  ll_vm_mk.cpp
  //! and ll_vm_ai_rxrs.cpp both validate exactly that way.
  if (endp) *endp = const_cast<char *>(any ? s : nptr);

  *out = acc;  *neg_out = neg;  *ovf_out = overflow;
}

extern "C" long __wrap_strtol(const char *s, char **endp, int base)
{
  unsigned long long acc;  int neg, ovf;
  ll_strto_core(s, endp, base, &acc, &neg, &ovf);

  const unsigned long long limit = neg ? (unsigned long long) LONG_MAX + 1ULL
                                       : (unsigned long long) LONG_MAX;
  if (ovf || acc > limit) {
    errno = ERANGE;
    return neg ? LONG_MIN : LONG_MAX;
  }
  return neg ? (long) (-(long long) acc) : (long) acc;
}

extern "C" long long __wrap_strtoll(const char *s, char **endp, int base)
{
  unsigned long long acc;  int neg, ovf;
  ll_strto_core(s, endp, base, &acc, &neg, &ovf);

  const unsigned long long limit = neg ? (unsigned long long) LLONG_MAX + 1ULL
                                       : (unsigned long long) LLONG_MAX;
  if (ovf || acc > limit) {
    errno = ERANGE;
    return neg ? LLONG_MIN : LLONG_MAX;
  }
  return neg ? -(long long) acc : (long long) acc;
}

extern "C" unsigned long __wrap_strtoul(const char *s, char **endp, int base)
{
  unsigned long long acc;  int neg, ovf;
  ll_strto_core(s, endp, base, &acc, &neg, &ovf);

  if (ovf || acc > (unsigned long long) ULONG_MAX) {
    errno = ERANGE;
    return ULONG_MAX;
  }
  //! POSIX: a NEGATIVE input is not an error for strtoul -- the value is negated in unsigned
  //! arithmetic, so strtoul("-1") is ULONG_MAX.  Surprising, and load-bearing: dropping the sign
  //! instead would silently turn -1 into 1.
  return neg ? (unsigned long) (0UL - (unsigned long) acc) : (unsigned long) acc;
}

// C23 names GCC 13 emits for the same functions; redirect to our implementations.
extern "C" long          __wrap___isoc23_strtol (const char *s, char **e, int b) { return __wrap_strtol(s, e, b);  }
extern "C" long long     __wrap___isoc23_strtoll(const char *s, char **e, int b) { return __wrap_strtoll(s, e, b); }
extern "C" unsigned long __wrap___isoc23_strtoul(const char *s, char **e, int b) { return __wrap_strtoul(s, e, b); }

// ---------------------------------------------------------------------------
// sscanf / fscanf.
//
// NOT REIMPLEMENTED, AND DELIBERATELY SO.  scanf's format language is large and its edge cases
// are exactly where a hand-rolled version would diverge silently.  glibc has carried the C99
// entry points __isoc99_vsscanf / __isoc99_vfscanf since 2.7 (2007), so they are present on every
// host in B274's table -- Debian 12, Ubuntu 22.04, RHEL 9 -- and on anything older we would still
// be supporting.  Forwarding to them keeps EXACT glibc semantics while dropping the 2.38
// requirement, which is the whole objective.
//
// Declared here rather than taken from <stdio.h> on purpose: the header's redirect is what
// produces __isoc23_* in the first place, so asking for the old names explicitly is the point.
// ---------------------------------------------------------------------------

extern "C" int __isoc99_vsscanf(const char *s, const char *fmt, va_list ap);
extern "C" int __isoc99_vfscanf(FILE *stream, const char *fmt, va_list ap);

extern "C" int __wrap___isoc23_sscanf(const char *s, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  int r = __isoc99_vsscanf(s, fmt, ap);
  va_end(ap);
  return r;
}

extern "C" int __wrap___isoc23_fscanf(FILE *stream, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  int r = __isoc99_vfscanf(stream, fmt, ap);
  va_end(ap);
  return r;
}

#endif  // __linux__ && (__aarch64__ || __x86_64__)
