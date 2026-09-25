// Copyright 2026 by Frobenius Norm LLC 2026-09-15
#ifndef LL_FASTRAM_H
#define LL_FASTRAM_H
#include <stddef.h>

/*! @file ll_fastram.h
  @brief P211 Phase 1 -- fast-RAM reservations made at INSTALLER time and handed to their consumer.

  WHY THIS EXISTS.  Internal DRAM is claimed first-come-first-get, and the largest single claimant on
  an ESP32 board makes its claim from INSIDE the .scm load phase: measured on esp32-s3-eye, the one
  form `(when (positive? (setting 'wifi 0)) (WiFi.begin ...))` in WiFi.scm costs **48,752 bytes** and
  collapses the largest contiguous block from 69,620 to 31,732.  Every claimant that ran before it --
  including the camera's 23,040-byte DMA request ([B428]) -- budgeted against a number that was about
  to be wrong by 48 KB.  That is [B396]'s mechanism, and [B88]'s, and [B60]'s: the same defect three
  times, because nothing orders the claims.

  THE PATTERN, which is [EyeCam]'s camera hole generalised (see ll_xmop3_EyeCam.cpp):

    1. RESERVE at install time, when the pool is still whole and contiguous.
    2. RELEASE immediately before the real consumer allocates, so the consumer lands in the hole.
    3. RELEASE UNCLAIMED at the end of boot, so a board that never uses the subsystem pays nothing.

  Step 3 is what makes this "if it is to be used, allocation first; otherwise not" rather than a
  tax.  Without it every board would pay for WiFi whether or not it ever starts a radio -- and two
  boards in this fleet (4WD, WROVER) boot ONLY because they do not ([B411]).

  BEST-EFFORT BY DESIGN.  A reservation that cannot be met is not an error: the consumer simply
  allocates as it does today.  The WROVER finishes boot with 3,364 bytes free, so a hard failure
  here would brick the very boards this is meant to help.  Every outcome is REPORTED -- a silent
  reservation is how [B410] and [B389] hid, and an unreported success is as useless as an unreported
  failure when you are trying to read a ledger afterwards.
*/

//! Reserve `bytes` of internal DRAM under `tag`.  Returns true if held.  Reports either way.
bool ll_fastram_reserve(const char *tag, size_t bytes);

//! Hand the reservation back so the real consumer can take the hole.  Safe if never reserved.
void ll_fastram_release(const char *tag);

//! Release every reservation still held -- call once boot is past the point anyone would claim.
void ll_fastram_release_unclaimed();

#endif
