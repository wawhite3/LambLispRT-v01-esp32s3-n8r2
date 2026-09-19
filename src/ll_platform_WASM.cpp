// Copyright 2026 by Frobenius Norm LLC 2026-09-04 00:00:00
// Free for non-commercial use. Commercial use requires a license.
/*! @file ll_platform_WASM.cpp
  P175: LambPlatform for wasm32 (WASI and Emscripten alike).

  This is the wasm sibling of ll_platform_AMD64.cpp / ll_platform_ARM64.cpp: it supplies
  millis()/micros()/delay and the LambPlatform hooks, and nothing else.  The interpreter core
  needs no wasm-specific code at all -- see the P175 table of "what is already in our favour".
*/
#if LL_WASM32

#include "ll_platform_generic.h"
#include <time.h>

//! CLOCK_MONOTONIC, NOT CLOCK_PROCESS_CPUTIME_ID -- AND THAT IS THE ONE PLACE THIS TARGET
//! DELIBERATELY DIFFERS FROM THE NATIVE HOSTS.
//!
//! ll_platform_AMD64.cpp uses process CPU time on purpose, so benchmark timings and the GC-load%%
//! heap-expansion trigger are immune to OS descheduling.  Under WASI there is no process CPU
//! clock: `CLOCK_PROCESS_CPUTIME_ID` exists only in wasi-libc's *emulation* library
//! (-lwasi-emulated-process-clocks), and that emulation returns WALL TIME -- so asking for it
//! would buy the name without the property, which is worse than not asking, because the next
//! reader would believe the timings were deschedule-proof.
//!
//! THE CONSEQUENCE, AND IT IS NOT A DEFECT HERE: on wasm these numbers are wall clock, so they
//! move with host load, with JIT tiering, and (in a browser) with tab throttling.  That is
//! acceptable because THIS TARGET MUST NEVER PUBLISH A TIMING NUMBER.  P175: "a WASM demo is a
//! LANGUAGE demo.  If it ever displays a timing number, that rule has been broken."  w3_test.sh
//! already classifies host performance as `diagnostic` for the same reason.
static unsigned long ll_wasm_micros(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (unsigned long) ((unsigned long long) ts.tv_sec * 1000000ULL
                          + (unsigned long long) ts.tv_nsec / 1000ULL);
}

unsigned long micros(void)
{
  static bool inited = false;
  static unsigned long start_us = 0;
  unsigned long now = ll_wasm_micros();
  if (!inited) { start_us = now; inited = true; }
  return now - start_us;
}

unsigned long millis(void)	{ return micros() / 1000; }

//! BUSY-WAIT, because wasm32-wasip1 has no thread to sleep and no signal to wake it.  Same shape
//! as the AMD64 file; a browser build should prefer not to call delay at all (it blocks the tab's
//! main thread), which is why nothing in the startup path does.
void delay_ms(unsigned long ms)	{ unsigned long end = millis() + ms;  while (millis() < end) /*wait*/; }
void delay_us(unsigned long us)	{ unsigned long end = micros() + us;  while (micros() < end) /*wait*/; }

//! free_stack(): the wasm shadow stack is whatever `-Wl,-z,stack-size=` reserved (4 MB here; see
//! w3_pio/platforms/wasm32/builder/main.py).  There is no portable way to read __stack_pointer
//! from C, so report a token value exactly as the desktop hosts do -- the REAL recursion guard is
//! LL_EVAL_STACK_BUDGET, which ll_platform_generic.h sizes against that same linker number.
LL_int32  LambPlatform::free_stack()			{ return 1<<10; }
//! free_heap(): wasm32 linear memory can grow to 4 GB but a browser tab will not give it; report
//! 64 MB, which is what the demo profile is sized for and what the GC heuristics reason against.
LL_int32  LambPlatform::free_heap()			{ return 1<<26; }
LL_int32  LambPlatform::cell_pool_free()		{ return free_heap(); }
void   LambPlatform::rand(byte *buf, LL_int32 len)	{ (void) buf; (void) len; }
Bool_t LambPlatform::heap_integrity_check(bool foo)	{ (void) foo; return 1; }
//! reboot(): a wasm module cannot restart itself -- the HOST re-instantiates it.  No-op, like the
//! desktop hosts.
void   LambPlatform::reboot()				{}

void LambPlatform::identification()
{
  ME("LambPlatform::identification()");
#if LL_EMSCRIPTEN
  global_printf("%s This is wasm32 (Emscripten / browser)\n", me);
#else
  global_printf("%s This is wasm32 (WASI)\n", me);
#endif
}

void LambPlatform::begin()
{
  loop_start_ms = millis();
  loop_start_us = micros();
  identification();
}

void LambPlatform::end() {}

void LambPlatform::loop(void)	//call this 1st thing in Lamb::loop().
{
  loop_start_ms = millis();
  loop_start_us = micros();
}

#endif // LL_WASM32
