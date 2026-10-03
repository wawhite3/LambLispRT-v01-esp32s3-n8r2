// Copyright 2026 by Frobenius Norm LLC 2026-09-18 20:42:11
#ifndef LL_EXEC_CAP_H
#define LL_EXEC_CAP_H

//! @file ll_exec_cap.h
//! @brief The ONE place that asks whether this build can allocate executable memory.  [B360]
//!
//! Include this instead of naming MALLOC_CAP_EXEC anywhere.  Six sites used to name it directly and
//! three of them are not native-code-generation code at all -- a boot banner in main.cpp and two
//! lines of the NCG pass-level budget gate, all under a plain `#if LL_ESP32`, which every ESP32
//! target compiles.  That is why this is its own header rather than a local `#ifdef` at each site:
//! the question is one question, and the answer has to be given once.
//!
//! IT LIVES HERE AND NOT IN ll_platform_generic.h ON PURPOSE (2026-09-18): that header was being
//! renamed tree-wide by another session at the time, and a self-contained question deserves a
//! self-contained file more than it deserves to be the 40th topic in a 1400-line header.  If you
//! are consolidating headers later, moving it back is fine -- keep the probe and the assertion
//! together, they are the whole content.

#include "ll_platform_generic.h"   //!< LL_ESP32

//! LL_HAVE_EXEC_CAP -- IS THERE AN EXECUTABLE-MEMORY CAPABILITY ON THIS IDF BUILD?  [B360]
//!
//! ESP-IDF v6 made MALLOC_CAP_EXEC CONDITIONAL.  Migration guide, verbatim: "Since ESP-IDF v6.0,
//! the definition of MALLOC_CAP_EXEC is conditional, meaning that if CONFIG_ESP_SYSTEM_MEMPROT is
//! enabled, MALLOC_CAP_EXEC will not be defined."  A bare reference then fails to COMPILE -- and it
//! takes the WHOLE FIRMWARE with it, not just native code generation, because three of the six
//! references are boot-time and pass-level DIAGNOSTICS in `#if LL_ESP32` code that every ESP32
//! target compiles.  Up to and including 5.x the macro was always defined and merely returned NULL
//! at runtime, which is the silent dead tier B354 measured (1678 attempts, 1678 NULLs).
//!
//! USE THIS FLAG.  Do NOT write `#if defined(MALLOC_CAP_EXEC)` at a call site, and above all do NOT
//! define a replacement value for the macro.  0 is a VALID capability request meaning "no
//! constraints", so `heap_caps_malloc(sz, 0)` succeeds and hands back ORDINARY DATA memory -- the
//! NCG then copies a procedure into it and calls it.  A "fallback cap" therefore converts a compile
//! error into a Guru Meditation at the first compiled call, which is strictly the worse trade.
//! When this flag is 0: an ALLOCATION site must fail and say why; a REPORTING site must read zero
//! free, because there is no executable heap to measure.
//!
//! THE PROBE INCLUDES ITS OWN HEADER, AND IS ASSERTED AGAINST ANSWERING WRONG.  `!defined(
//! MALLOC_CAP_EXEC)` is equally true when the heap header merely is not in scope yet, which would
//! read as "memprot is on" on EVERY IDF and silently disable NCG behind a #warning nobody reads --
//! absence encoded as an answer.  So pull esp_heap_caps.h in here rather than depending on include
//! order, and assert MALLOC_CAP_INTERNAL, which is unconditional in every IDF: if THAT is missing
//! the header did not arrive and this is a build error, not a memprot verdict.
#if LL_ESP32
#include "esp_heap_caps.h"
#if !defined(MALLOC_CAP_INTERNAL)
#error "B360: esp_heap_caps.h did not supply MALLOC_CAP_INTERNAL, so the MALLOC_CAP_EXEC probe below cannot tell 'memory protection is enabled' from 'the header is missing' -- and would answer the first on every IDF, silently disabling native code generation."
#endif
//! THE `#ifndef` IS THE WHOLE TEST APPARATUS, AND IT WAS MISSING FOR SIX BUILDS.
//! On ESP-IDF 5.5 the macro is always defined, so this flag always reads 1 and every guarded arm
//! below is code NOTHING IN THE FLEET COMPILES -- "it builds" proves only that the flag reads 1.
//! `W3_EXTRA_FLAGS="-DLL_HAVE_EXEC_CAP=0" w3 make one <env>` is the disagreeing input, and it works
//! ONLY because of the `#ifndef`: without it this header REDEFINES the macro to 1 after the command
//! line set it to 0, and the build succeeds having compiled the opposite arm.  Measured 2026-09-18:
//! six "verified both ways" builds were all the same way, and the entry and commit that reported
//! them had to be retracted.  Do not remove the guard, and do not trust a green build here without
//! also seeing the memprot-only string in the binary.
#ifndef LL_HAVE_EXEC_CAP
#if defined(MALLOC_CAP_EXEC)
#define LL_HAVE_EXEC_CAP 1
#else
#define LL_HAVE_EXEC_CAP 0
#endif
#endif
#else
#ifndef LL_HAVE_EXEC_CAP
#define LL_HAVE_EXEC_CAP 0                //!<Not an ESP32: no heap-caps allocator at all.
#endif
#endif

//! ll_exec_heap_free() -- HOW MUCH EXECUTABLE HEAP IS LEFT, on a build that may have none.  [B360]
//!
//! Every reporting site goes through here rather than naming MALLOC_CAP_EXEC, because a diagnostic
//! is exactly where the macro's disappearance does the most damage: the two in ncg_exec_budget_spent()
//! and the one in main.cpp sit under a plain `#if LL_ESP32`, so they compile on EVERY ESP32 target,
//! and under IDF 6 + memprot they would fail the build of a part that never runs the NCG at all.
//!
//! ZERO IS THE TRUTH, NOT A PLACEHOLDER.  When the capability does not exist there is no executable
//! heap, so "0 bytes free" is the correct report and the budget gate correctly reads the tier as
//! spent.  Do not "improve" this by substituting MALLOC_CAP_INTERNAL: that would report a healthy
//! number for a tier that cannot be allocated from, which is the shape of B354 (a dead tier that
//! reported itself as an ordinary NCG timing for 1678 consecutive failures).
#if LL_ESP32
inline unsigned ll_exec_heap_free()
{
#if LL_HAVE_EXEC_CAP
  return (unsigned) heap_caps_get_free_size(MALLOC_CAP_EXEC);
#else
  return 0u;
#endif
}
#endif

#endif  // LL_EXEC_CAP_H
