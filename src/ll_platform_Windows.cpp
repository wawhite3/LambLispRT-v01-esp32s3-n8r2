// Copyright 2026 by Frobenius Norm LLC 2026-09-05 00:00:00
// Free for non-commercial use. Commercial use requires a license.
/*! @file ll_platform_Windows.cpp
  P174 Phase 1 -- THE ONLY FILE IN THE TREE THAT INCLUDES <windows.h>.

  Keep it that way.  Every Windows-specific shim goes here, behind the plain-C declarations in
  ll_platform_Windows.h, so that the rest of the tree calls a name of ours and never sees a Win32
  type, a Win32 macro, or the include-order hazard documented below.

  WHAT BELONGS HERE: a call that has no spelling on Windows and needs a Win32 one instead.
  WHAT DOES NOT: anything faster-on-Windows.  P174 Phase 1 is a LANGUAGE demo, and its whole
  claim is that this is the same interpreter that runs on an ESP32-S3.  A Windows-only fast path
  would make that claim less true and add a second path to keep correct, in exchange for a number
  this target is explicitly forbidden from publishing (see the board comment in w3_pio/boards.json
  and the scope boundary at the top of proposal_mingw_windows_P174.md).

  NOTE this file is deliberately NOT the LambPlatform implementation.  The windows_x86_64 board
  sets -DLL_AMD64=1, so ll_platform_AMD64.cpp already supplies millis()/micros()/delay and the
  LambPlatform hooks, and it does so through clock_gettime(CLOCK_MONOTONIC), which MinGW provides.
  That file needed no Windows arm at all -- the sibling of this one for wasm, ll_platform_WASM.cpp,
  DID need to exist only because wasm is not AMD64.
*/
#include "ll_platform_generic.h"

#if LL_WINDOWS

/*! <windows.h> COMES FIRST, BEFORE ANY LambLisp HEADER THAT DEFINES THE ARDUINO PIN CONSTANTS.

  ll_platform_generic.h (included above, and it is safe -- see below) defines `INPUT`, `OUTPUT`,
  `HIGH` and `LOW` as MACROS, and <winuser.h> declares a struct typedef also called `INPUT`:

      } INPUT,*PINPUT,*LPINPUT;

  With the LambLisp macro already defined, the preprocessor rewrites that to `} 0x0,*PINPUT,...`
  and the compiler says

      winuser.h:2766: error: expected ';' after struct definition
      ll_platform_generic.h:376: error: expected unqualified-id before numeric constant
      winuser.h:2768: error: 'LPINPUT' has not been declared

  -- three errors pointing at a system header and a pin-mode constant, none of them naming the
  include order that caused it.  The `#ifndef INPUT` guard around the Arduino constants does NOT
  protect you: a typedef is not a macro, so the guard is still true.

  So this file #undefs the four constants before pulling in <windows.h>.  Including
  ll_platform_generic.h first is still necessary -- LL_WINDOWS itself comes from there -- so
  undef-then-include is the order that works, rather than trying to include <windows.h> at the
  very top of the file.  Nothing below needs the Arduino constants.
*/
#undef INPUT
#undef OUTPUT
#undef HIGH
#undef LOW

//! BOTH DEFINES ARE LOAD-BEARING.  WIN32_LEAN_AND_MEAN drops the legacy winsock.h, which would
//! collide with the winsock2.h a Phase 2 Winsock port needs -- and that error surfaces in THAT
//! file, naming sockaddr redefinitions, with nothing pointing back here.  NOMINMAX drops the
//! min/max MACROS, which otherwise break std::min/std::max and every numeric_limits<T>::max() in
//! the numeric tower with a syntax error inside <limits>.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <direct.h>       //!< _mkdir
#include <time.h>         //!< struct tm / gmtime_s, for ll_win_set_system_time
#include "ll_platform_Windows.h"

size_t ll_win_self_exe_path(char *buf, size_t cap)
{
  if (!buf || cap < 2) return 0;
  //! THE ANSI (A) FORM, DELIBERATELY.  LambLisp strings are UTF-8 BYTE strings and this whole
  //! file-path layer is char*-based, so GetModuleFileNameW would have to be converted straight
  //! back.  What that costs is an install path outside the system ANSI code page, which is an odd
  //! place to unpack a demo build; what it saves is a wchar conversion layer that would then need
  //! its own correctness argument.  Revisit if this target ever stops being a demo.
  DWORD n = GetModuleFileNameA(NULL, buf, (DWORD) (cap - 1));
  //! TRUNCATION IS NOT AN ERROR TO THIS API -- it fills the buffer, returns the buffer size, and
  //! (before Windows 10) does not even NUL-terminate.  So a path longer than `cap` would hand the
  //! caller a plausible-looking WRONG directory rather than a failure.  Treat "filled it" as
  //! failure and let the caller fall back.
  if (n == 0 || n >= (DWORD) (cap - 1)) return 0;
  buf[n] = '\0';
  return (size_t) n;
}

int ll_win_mkdir(const char *path, int mode)
{
  (void) mode;   //!< no POSIX mode bits on Windows; see the header
  return _mkdir(path);
}

/*! @see ll_platform_Windows.h -- set the system clock from UTC epoch seconds. */
int ll_win_set_system_time(long long utc_seconds)
{
  time_t t = (time_t) utc_seconds;
  struct tm g;
  //! gmtime_s, not gmtime_r: MinGW's msvcrt has the Microsoft spelling, and its argument ORDER is
  //! the reverse of the POSIX one (buffer second, not first).  Getting that backwards compiles.
  if (gmtime_s(&g, &t) != 0) return -1;
  SYSTEMTIME st;
  st.wYear         = (WORD) (g.tm_year + 1900);
  st.wMonth        = (WORD) (g.tm_mon + 1);      //! tm_mon is 0-11, SYSTEMTIME is 1-12
  st.wDayOfWeek    = (WORD) g.tm_wday;
  st.wDay          = (WORD) g.tm_mday;
  st.wHour         = (WORD) g.tm_hour;
  st.wMinute       = (WORD) g.tm_min;
  st.wSecond       = (WORD) (g.tm_sec > 59 ? 59 : g.tm_sec);  //! SYSTEMTIME has no leap second
  st.wMilliseconds = 0;
  //! SetSystemTime takes UTC.  SetLocalTime would apply the machine's time zone twice.
  return SetSystemTime(&st) ? 0 : -1;
}

#endif // LL_WINDOWS
