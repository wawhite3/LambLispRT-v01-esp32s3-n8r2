// Copyright 2026 by Frobenius Norm LLC 2026-09-15
#include "LambLisp.h"
#include "ll_fastram.h"
#include <string.h>          //!< strcmp -- slot lookup by tag; not pulled in by LambLisp.h

#if LL_ESP32
#include "esp_heap_caps.h"
void ll_heap_note(const char *tag);      //!< the boot-phase internal-DRAM tracer (ll_vm_lamb.cpp)

//! A reservation slot.  Deliberately a fixed small table rather than a container: this runs during
//! C++ setup, before the VM heap exists, and must not itself allocate from the pool it is rationing.
namespace {
  struct Slot { const char *tag; void *p; size_t bytes; };
  const int   LL_FASTRAM_MAX_SLOTS = 8;
  Slot        slots[LL_FASTRAM_MAX_SLOTS] = {};
  int         nslots = 0;

  Slot *find(const char *tag) {
    for (int i = 0; i < nslots; i++)
      if (slots[i].tag && tag && !strcmp(slots[i].tag, tag)) return &slots[i];
    return nullptr;
  }
}

bool ll_fastram_reserve(const char *tag, size_t bytes)
{
  if (!tag || bytes == 0)            return false;
  if (find(tag))                     return true;               //!< idempotent
  if (nslots >= LL_FASTRAM_MAX_SLOTS) {
    global_printf("[fastram] %s REFUSED -- slot table full (%d)\n", tag, LL_FASTRAM_MAX_SLOTS);
    return false;
  }
  //! MALLOC_CAP_INTERNAL|8BIT, matching what the consumers actually contend for.  NOT
  //! MALLOC_CAP_DMA: a DMA-capable reservation is a NARROWER claim and would hand the consumer a
  //! hole it may not be able to use, while leaving the wider pool just as fragmented.
  void *p = heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!p) {
    //! NOT AN ERROR.  The consumer allocates exactly as it does today; it simply does not get the
    //! ordering benefit.  Hard-failing here would brick the boards this exists to help -- the
    //! WROVER finishes boot with 3,364 bytes free.
    global_printf("[fastram] %s reserve %u FAILED -- consumer will allocate unordered (largest %u)\n",
                  tag, (unsigned) bytes,
                  (unsigned) heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    return false;
  }
  slots[nslots].tag = tag; slots[nslots].p = p; slots[nslots].bytes = bytes; nslots++;
  global_printf("[fastram] %s reserved %u\n", tag, (unsigned) bytes);
  ll_heap_note("claim: fastram reserve");       //!< the updated stat, after every claim
  return true;
}

void ll_fastram_release(const char *tag)
{
  Slot *s = find(tag);
  if (!s || !s->p) return;
  heap_caps_free(s->p);
  global_printf("[fastram] %s released %u to its consumer\n", s->tag, (unsigned) s->bytes);
  s->p = nullptr;
  ll_heap_note("release: fastram to consumer");
}

void ll_fastram_release_unclaimed()
{
  //! SAY WHICH OF THE TWO STATES THIS IS.  An unconditional ledger line printing identical numbers
  //! cannot distinguish "nothing was held" from "the release did not work", and both readers of
  //! this output -- another session, and its author -- had to go to the source to tell.  Same
  //! defect as the LCD band reporting `free` without `largest`: output that cannot fail informs
  //! nobody.  So the quiet case says so in one line and does not print a ledger it did not change.
  int freed = 0;
  for (int i = 0; i < nslots; i++) {
    if (!slots[i].p) continue;
    global_printf("[fastram] %s UNCLAIMED -- releasing %u (subsystem never started)\n",
                  slots[i].tag, (unsigned) slots[i].bytes);
    heap_caps_free(slots[i].p);
    slots[i].p = nullptr;
    freed++;
  }
  if (freed == 0) {
    global_printf("[fastram] sweep: nothing held -- every reservation reached its consumer\n");
    return;                                  //!< nothing moved, so print no ledger line
  }
  ll_heap_note("release: fastram unclaimed");
}

#else   // not ESP32 -- no scarce internal pool to ration
bool ll_fastram_reserve(const char *, size_t) { return false; }
void ll_fastram_release(const char *)         { }
void ll_fastram_release_unclaimed()           { }
#endif
