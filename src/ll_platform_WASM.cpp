// Copyright 2026 by Frobenius Norm LLC 2026-09-04 00:00:00
// Free for non-commercial use. Commercial use requires a license.
/*! @file ll_platform_WASM.cpp
  P175: LambPlatform for wasm32 (WASI and Emscripten alike).

  This is the wasm sibling of ll_platform_AMD64.cpp / ll_platform_ARM64.cpp: it supplies
  millis()/micros()/delay and the LambPlatform hooks, and nothing else.  The interpreter core
  needs no wasm-specific code at all -- see the P175 table of "what is already in our favour".
*/
#if LL_WASM32

#include <new>
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

/*! [B593] Cell-block allocation, the host arm.  See ll_platform_generic.h for why this exists.
    `::operator new` with nothrow, NOT `new Cell[n]`: raw storage with no array cookie and no
    element constructors, which is exactly what the collector wants -- expand() memzero's the block
    immediately, so any constructor's work is discarded, and the destructor path finalizes cells by
    hand before releasing.  Cell has no user-declared destructor, no virtuals and POD members only,
    so `delete[]` was running nothing per element; this is behaviour-preserving.
    NOTHROW BECAUSE THE MCU ARM CANNOT THROW: `heap_caps_malloc` returns null, so a caller that
    handles both must get a null here too.  Previously `new Cell[]` threw and the collector's OOM
    bail was unreachable on this target -- the two arms disagreed about the contract. */
void *LambPlatform::cell_block_alloc(unsigned long nbytes)
{ return ::operator new((size_t) nbytes, std::nothrow); }

void  LambPlatform::cell_block_free(void *blk)
{ if (blk) ::operator delete(blk); }

//! [B593] One heap on this target -- say so rather than inventing a distinction.  See the
//! declaration in ll_platform_generic.h for why this is a platform method at all.
const char *LambPlatform::mem_placement(void *p)   { (void) p; return "HEAP    "; }

//! [B627] The hosts run on a real filesystem the OS manages; LambLisp does not own a partition
//! there and the cliff this exists to expose is a flash-controller effect.  Report 0/0, which the
//! accessor documents as "no filesystem", rather than statvfs of whatever directory we happen to
//! be in -- a number that would be true and would answer a different question.
LL_int64 LambPlatform::fs_total()  { return 0; }
LL_int64 LambPlatform::fs_used()   { return 0; }

//! [B508] free_internal() / free_dma(): a HOST HAS NO SUCH DISTINCTION.  On an ESP32 these are the
//! scarce account that `free_heap()` (the aggregate) and `cell_pool_free()` (PSRAM) both hide; here
//! there is one undifferentiated heap, so reporting `free_heap()` is the honest answer and keeps a
//! Scheme probe portable rather than making it guard on the target.  These MUST exist on every
//! platform: they are non-virtual members declared in ll_platform_generic.h and called from
//! ll_xmop3_platform_generic.cpp, which every target compiles -- so omitting one COMPILES CLEAN AND
//! FAILS AT LINK, in every concurrent session's build, naming a file nobody touched.
LL_int32  LambPlatform::free_internal()		{ return free_heap(); }
LL_int32  LambPlatform::free_dma()			{ return free_heap(); }
LL_int32  LambPlatform::largest_free_internal()	{ return free_heap(); }   //!<[B609] no fragmentation story on a host; same figure, so a probe stays portable
LL_int32  LambPlatform::largest_free_dma()	{ return free_heap(); }   //!<[B676] no DMA capability class on a host; same figure, so a probe stays portable
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
