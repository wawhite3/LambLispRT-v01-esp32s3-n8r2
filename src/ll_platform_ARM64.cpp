// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#if LL_ARM64

#include "ll_platform_generic.h"
#include <time.h>
#include <sys/random.h>
#include <errno.h>

// micros()/millis() return PROCESS CPU time, not wall clock -- see ll_platform_AMD64.cpp for rationale
// (reproducible benchmark timings + GC-load% expansion immune to OS descheduling).
static unsigned long ll_wall_micros(void)
{
  struct timespec ts;
  //! B260: WALL CLOCK, NOT CPU TIME.  This was CLOCK_PROCESS_CPUTIME_ID, which STOPS while the
  //! process sleeps -- so micros() advanced 829us across a 500ms nanosleep and every interval
  //! measured over a sleep, a blocking read or any I/O wait was far too short.  Arduino defines
  //! millis()/micros() as TIME SINCE BOOT, and sketches use them for timeouts, debouncing and
  //! scheduling, all of which mean elapsed REAL time.  On embedded the two clocks are effectively
  //! the same, so only the Linux hosts diverged -- which is precisely the host/device difference
  //! P176 exists to remove.  There are no perf measurements on the Linux targets that wanted CPU
  //! time; if one is ever needed, add a SEPARATELY NAMED helper rather than redefining these.
  //! Found by the LLArduino conformance suite: "delay_us(2000) elapsed >= 1ms" failed while a
  //! wall-clock measurement around the whole process proved the sleep itself was real.
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (unsigned long) ((unsigned long long) ts.tv_sec * 1000000ULL
                          + (unsigned long long) ts.tv_nsec / 1000ULL);
}

unsigned long micros(void)
{
  static bool inited = false;
  static unsigned long start_us = 0;
  unsigned long now = ll_wall_micros();
  if (!inited) { start_us = now; inited = true; }
  return now - start_us;
}

unsigned long millis(void)	{ return micros() / 1000; }

void delay_ms(unsigned long ms)	{ unsigned long end = millis() + ms;  while (millis() < end) /*wait*/; }
void delay_us(unsigned long ms)	{ unsigned long end = micros() + ms;  while (micros() < end) /*wait*/; }

LL_int32  LambPlatform::free_stack()			{ return 1<<10; /*just say 1k left*/ }
LL_int32  LambPlatform::free_heap()			{ return 1<<27; /*128 MB -- desktop has plenty of RAM */ }
//! B129: no separate cell pool on a desktop host -- same figure as free_heap().
LL_int32  LambPlatform::cell_pool_free()		{ return free_heap(); }
Bool_t LambPlatform::heap_integrity_check(bool foo)	{ return 1; }
void   LambPlatform::reboot()				{}

void   LambPlatform::rand(byte *buf, LL_int32 len)
{
  ME("LambPlatform::rand()");
  while (len) {
    LL_int32 got = getrandom(buf, len, 0);
    if (got == -1) {
      every(1000, global_printf("%s getrandom() errno %d\n", me, errno));
      break;
    }
    else {
      buf += got;
      len -= got;
    }
  }
}

void LambPlatform::identification()
{
  ME("LambPlatform::identification()");
  global_printf("%s This is aarch64\n", me);
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

#endif

