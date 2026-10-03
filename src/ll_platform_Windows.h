// Copyright 2026 by Frobenius Norm LLC 2026-09-05 00:00:00
// Free for non-commercial use. Commercial use requires a license.
/*! @file ll_platform_Windows.h
  P174: declarations for the Windows/MinGW shims.  See ll_platform_Windows.cpp.

  THIS HEADER EXISTS SO THAT NOTHING ELSE HAS TO INCLUDE <windows.h>, and that is its whole job.
  It is safe to include unconditionally from any file on any target: with LL_WINDOWS off it
  declares nothing at all, so callers need no #if around the include itself -- only around the
  calls.

  WHY THE ISOLATION MATTERS, concretely.  <windows.h> defines a struct typedef named `INPUT`, and
  ll_platform_generic.h defines the Arduino pin constant `#define INPUT 0x0`.  Include them in the
  wrong order in the same translation unit and the preprocessor rewrites winuser.h's declaration
  to `} 0x0,*PINPUT,*LPINPUT;`, producing errors that point at a system header and at a pin-mode
  constant while naming nothing that would lead you to the include order.  Keeping every Win32
  call in ONE .cpp means exactly one file has to get that order right, instead of every file that
  ever needs a Windows API.  Add new Windows shims THERE, not inline behind an #if elsewhere.

  These are SHIMS, NOT OPTIMIZATIONS.  Each one exists because the POSIX spelling does not exist
  on Windows -- not because Windows could do it faster.  A Windows-only fast path does not belong
  here or anywhere else in this port: P174 Phase 1 is a language demo whose value is being the
  SAME interpreter, and a divergent code path is a second thing to keep correct for no gain.
*/
#ifndef LL_PLATFORM_WINDOWS_H
#define LL_PLATFORM_WINDOWS_H

#include "ll_platform_generic.h"

#if LL_WINDOWS

#include <stddef.h>

/*! Write the running executable's own path into `buf` (NUL-terminated); return its length, or 0.

  Replaces `readlink("/proc/self/exe", ...)`, which is Linux-only -- it is not even POSIX.  Both
  spellings answer the same question and neither is portable, which is why the caller asks through
  a name of ours rather than through either platform's.

  Returning 0 is not fatal to the caller: posix_find_data_dir() then falls back to the relative
  string "data".  Know what that looks like, because it does not look like a path bug -- the VM
  starts normally and then reports a pile of missing .scm files, which reads as a broken
  filesystem image.
*/
size_t ll_win_self_exe_path(char *buf, size_t cap);

/*! mkdir() with the POSIX two-argument shape, ignoring `mode`.

  MinGW's ::mkdir is the MSVC one-argument form -- there is no mode argument, because Windows
  ACLs are not POSIX permission bits.  Passing 0777 does not compile ("too many arguments to
  function 'int mkdir(const char*)'"), which is the good outcome; the bad one would have been a
  silent permission difference.  `mode` is accepted and dropped so the call site reads the same on
  every target.
*/
int ll_win_mkdir(const char *path, int mode);

/*! Set the system clock from a UTC epoch-seconds value; 0 on success, -1 on failure.

  MinGW has `gettimeofday` and NOT `settimeofday`, so an unguarded call there is a COMPILE error
  in ll_vm_mop3_rxrs.cpp -- which is how this was found: the windows_x86_64 build had been failing
  for eleven days while the release kept packaging a 2026-09-07 .exe that predated the call.  That
  is [B422] one platform over: Emscripten lacks the same setter, and only the WASM arm was guarded.

  Windows CAN set its clock, with SE_SYSTEMTIME_NAME privilege, so this is a real implementation
  and not a `#f` stub: reporting "cannot" on a platform that can would be the same lie in the
  other direction.  Without the privilege SetSystemTime fails and this returns -1, which reaches
  Scheme as `#f` -- the documented answer on any host that refuses, exactly as on Linux without
  CAP_SYS_TIME.  Never report success here without checking: [B170] validates certificates against
  this clock, so a caller told the time was set when it was not is worse off than one told plainly.
*/
int ll_win_set_system_time(long long utc_seconds);

#endif // LL_WINDOWS
#endif // LL_PLATFORM_WINDOWS_H
