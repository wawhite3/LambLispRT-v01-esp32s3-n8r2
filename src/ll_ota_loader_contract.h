// Copyright 2026 by Frobenius Norm LLC 2026-10-03
// GENERATED from scm/features/llloader-vocab.scm -- DO NOT EDIT
//
// The VM's half of the loader<->VM NVS contract (namespace "ota-p125").  The factory
// loader is a separate ESP-IDF project, so the two ends cannot share a header -- they
// share a SOURCE, and each gets a generated one.  Editing this file instead of the
// vocabulary puts the two ends back out of step, which is the failure it exists to stop:
// a key name wrong on one side is not an error anywhere, it just reads as "nothing
// pending" forever.

#pragma once

// The value written into `pending_update`.  THESE ARE INDICES INTO THE ACTION LIST, so
// the order in the vocabulary is the wire protocol; the loader's `loader_action_t` is
// generated from the same list and the generator refuses if the two disagree.
#define LL_OTA_PENDING_NORMAL   0
#define LL_OTA_PENDING_INSTALL  1
#define LL_OTA_PENDING_RECOVER  2
#define LL_OTA_PENDING_CONSOLE  3

// NVS keys.  Spelled once, here, from the vocabulary.
#define LL_OTA_KEY_PENDING_UPDATE  "pending_update"   // u8
#define LL_OTA_KEY_INSTALL_TRIES   "install_tries"   // u8
#define LL_OTA_KEY_DEATH_REASON    "death_reason"   // str
#define LL_OTA_KEY_DEATH_COUNT     "death_count"   // u8

// A death reason is a SYMBOL carried in an `ota-death` frame, so it obeys the frame
// grammar's symbol bound.  Write a longer one and the loader's reader refuses the frame
// at the exact moment it matters -- hence the bound is shared, not restated.
#define LL_OTA_MAX_REASON 24
