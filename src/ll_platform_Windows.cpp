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


/*! @brief Ask this console to interpret ANSI escapes.  -> 1 if it now will, 0 if it will not.
 *
 *  A Win10+ console does NOT interpret escapes by default: a program must opt in per handle with
 *  ENABLE_VIRTUAL_TERMINAL_PROCESSING, and until it does, every sequence is printed as text.  So
 *  the honest answer to "can I use colour here?" is not a property of the target -- it is the
 *  result of this call.
 *
 *  THREE OUTCOMES, AND ALL THREE ARE CORRECT ANSWERS RATHER THAN ERRORS:
 *    - a modern console accepts the mode    -> 1, escapes are now interpreted;
 *    - stdout is a PIPE or FILE, not a console, so GetConsoleMode fails -> 0, and 0 is right:
 *      escapes in a redirected stream are bytes in a file that nothing will ever interpret;
 *    - a console that refuses to be asked   -> 0.
 *
 *  THE THIRD CASE IS NOT HYPOTHETICAL AND IS WHY THIS RETURNS A VALUE INSTEAD OF JUST TRYING.  A
 *  first version of this call ignored the result -- on the reasoning that failing is harmless --
 *  and that is exactly what made the fix appear not to work: the caller went on emitting escapes
 *  regardless, and old and new binaries rendered an identical 157 literal `[97m`.  A capability
 *  probe that cannot report failure is not a probe.  Wine is worse than a failure and is handled
 *  separately below: there the probe SUCCEEDS and is wrong.
 *
 *  ENABLE_VIRTUAL_TERMINAL_PROCESSING is defined manually: some MinGW-w64 wincon.h vintages omit
 *  it, and the value is fixed ABI, so this costs nothing and removes a toolchain dependency.
 */
#ifndef ENABLE_VIRTUAL_TERMINAL_PROCESSING
#define ENABLE_VIRTUAL_TERMINAL_PROCESSING 0x0004
#endif
int ll_win_enable_vt(void)
{
  int res = 0;
  //! ── WINE ACCEPTS THE MODE AND DOES NOT HONOUR IT, SO THE PROBE MUST BE DISBELIEVED HERE ──
  //! Measured 2026-09-29, and it corrects an earlier reading in this tree that said GetConsoleMode
  //! FAILS under Wine.  It does not: on a Wine console both calls SUCCEED and report the flag set,
  //! and Wine's renderer then prints every sequence as text anyway -- 498 visible artefacts in a
  //! session whose probe had just answered "yes".
  //!
  //! THIS IS THE WORST SHAPE A CAPABILITY PROBE CAN HAVE.  It is not a missing feature, which would
  //! report cleanly; it is a feature that reports PRESENT and is ABSENT, so every layer downstream
  //! behaves correctly on an answer that is false.  The only fix is to stop asking the question
  //! where the answer is known to be a lie.
  //!
  //! `wine_get_version` in ntdll is Wine's own documented "are you running on Wine" export; it
  //! exists nowhere else, so this costs one GetProcAddress and cannot false-positive on Windows.
  //! It is checked BEFORE the console calls, deliberately -- asking first and then discarding the
  //! answer would leave the VT flag set on a console that does not implement it.
  //!
  //! IF A FUTURE WINE IMPLEMENTS VT, this reads as a lost feature under that Wine, and the
  //! remedy is one variable the user already has: LL_COLOR=1.  That is the right way round --
  //! a readable console by default, colour available on request -- because the failure it prevents
  //! (an unreadable first session for someone evaluating the product) is far more expensive than
  //! the failure it causes (plain text for a developer who can type one env var).
  HMODULE ntdll = GetModuleHandleA("ntdll.dll");
  if (ntdll != NULL && GetProcAddress(ntdll, "wine_get_version") != NULL)
    return 0;
  HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
  if (h != INVALID_HANDLE_VALUE && h != NULL) {
    DWORD mode = 0;
    //! GetConsoleMode fails for a non-console handle (a redirect).  It SUCCEEDS under Wine --
    //! which is why Wine is excluded above rather than here.
    if (GetConsoleMode(h, &mode)) {
      if (mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING)
        res = 1;                                                 //! already on -- nothing to do
      else if (SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING))
        res = 1;
      //! A console that reports its mode and then refuses the flag keeps res = 0.  Do NOT assume
      //! the set worked because the get did; that is the assumption this whole comment exists for.
    }
  }
  return res;
}


/*! \name [B702] Console input that does not block the main loop.
 *
 *  The generic host implementations are `read() -> getchar()` and, for a no-termios target,
 *  `available() -> 1` unconditionally.  Together those mean "a byte is always available, and
 *  fetching it may block forever" -- correct for BATCH stdin, and wrong for a console, because
 *  `Lamb::loop()` then never turns between keystrokes: no `(loop)` hook, no timers, no idle-GC
 *  donation while a person sits at the prompt.
 *
 *  So on Windows the two are answered by the CONSOLE API rather than the CRT:
 *    - `available()` counts pending character-bearing key events with PeekConsoleInput;
 *    - `read()` takes one character with ReadConsoleA.
 *
 *  THE CRT IS BYPASSED DELIBERATELY.  `getchar()` buffers in the CRT while PeekConsoleInput looks
 *  at the console's own input buffer, so mixing them lets `available()` answer 0 while characters
 *  sit unread in the CRT -- a partial line that stalls until the next keypress.  Using one source
 *  for both questions removes that class of bug rather than timing around it.
 *
 *  WHEN STDIN IS NOT A CONSOLE (a pipe or a file, i.e. every harness and the conformance run)
 *  both fall back to the previous behaviour exactly: `available()` returns 1 and `read()` calls
 *  `getchar()`, so batch input keeps blocking-until-EOF semantics and `exit(0)` on exhaustion.
 *
 *  HONEST LIMIT: with ENABLE_LINE_INPUT set (a real Windows console's default) ReadConsoleA
 *  returns only once Enter is pressed, so the loop still pauses from the first keystroke of a line
 *  until it is submitted.  It turns freely while the prompt is IDLE, which is the case that
 *  matters for a background `(loop)`.  Clearing LINE_INPUT would fix that too and would make us
 *  responsible for echoing, which the line-accumulating branch does not do -- that is a larger
 *  change and is not made here.
 */
//!@{
//! -> a console input handle, or INVALID_HANDLE_VALUE when stdin is a pipe or a file.
static HANDLE ll_win_console_in(void)
{
  HANDLE h = GetStdHandle(STD_INPUT_HANDLE);
  DWORD  mode = 0;
  if (h != NULL && h != INVALID_HANDLE_VALUE && GetConsoleMode(h, &mode)) return h;
  return INVALID_HANDLE_VALUE;
}

int LambStdioClass::available(void)
{
  int res = 1;                                   //!< not a console -> previous behaviour
  HANDLE h = ll_win_console_in();
  if (h != INVALID_HANDLE_VALUE) {
    INPUT_RECORD rec[16];
    DWORD got = 0;
    res = 0;
    if (PeekConsoleInputA(h, rec, 16, &got)) {
      //! Only key-DOWN events carrying a character count.  The buffer also holds key-up, mouse,
      //! focus and window-resize records; counting those would report input that read() cannot
      //! produce, and the caller would spin on a byte that never arrives.
      for (DWORD i = 0; i < got; i++)
        if (rec[i].EventType == KEY_EVENT
            && rec[i].Event.KeyEvent.bKeyDown
            && rec[i].Event.KeyEvent.uChar.AsciiChar != 0)
          res++;
    }
  }
  return res;
}

int LambStdioClass::read(void)
{
  int res;
  HANDLE h = ll_win_console_in();
  if (h == INVALID_HANDLE_VALUE) {
    res = getchar();                             //!< pipe or file: unchanged
  }
  else {
    char  c   = 0;
    DWORD got = 0;
    res = (ReadConsoleA(h, &c, 1, &got, NULL) && got == 1) ? (int) (unsigned char) c : EOF;
  }
  return res;
}
//!@}


/*! @brief Give the CPU back for @a ms milliseconds.  A REAL sleep, not a spin.
 *
 *  This exists because `delay_ms()` is NOT one.  On every host platform it is
 *  `while (millis() < end) /*wait*\/;` (ll_platform_AMD64.cpp:41, ARM64:42, WASM:53) -- a busy
 *  wait, which is the correct shape for a microsecond delay on an MCU and precisely wrong for
 *  handing the core back at an idle prompt.  Measured 2026-09-29: using delay_ms(1) to "yield"
 *  took idle CPU from 49% to 74%, i.e. it made the thing it was meant to fix worse, because the
 *  spin was added ON TOP of the loop's own work.
 */
void ll_win_yield_ms(unsigned ms)
{
  Sleep((DWORD) ms);
}

#endif // LL_WINDOWS
