// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- OTA writer.  Streams an image_source into a target app partition (ota_0)
// using the ESP-IDF OTA API, verifying the streamed bytes' SHA-256 against the source's
// declared digest before the image is allowed to become bootable.  This is the one place
// that touches flash for an update; every source rung funnels through here.

#pragma once

#include "esp_err.h"
#include "esp_partition.h"
#include "image_source.h"

//! Stream `src` into `dst` (must be an app/ota partition), hashing as we go.
//!
//! On success the image is written AND validated (esp_ota_end) but NOT yet marked bootable --
//! the caller decides whether to esp_ota_set_boot_partition(dst) + reboot, so a verify step or
//! a policy gate can sit in between.  Returns ESP_OK only if every byte was written, esp_ota_end
//! accepted the image, and (when src->have_sha256) the digest matched.
//!
//! Feeds the task WDT across the write loop.  Peak RAM is one chunk buffer.
//!
//! EMITS `(ota-progress ...)` FRAMES while it writes ([P253] reply-only path) -- output only, on
//! the console it already logs to.  See llloader_llip.h for why output precedes input.
esp_err_t llloader_ota_write(const esp_partition_t *dst, image_source_t *src);

//! What the digest check concluded.  Spelled to match the `digest` field of the `ota-result` frame
//! in scm/features/llloader-vocab.scm -- ok | mismatch | absent.
typedef enum {
    LLLOADER_DIGEST_ABSENT = 0,   //!< the source declared none; the image was written UNVERIFIED
    LLLOADER_DIGEST_OK,
    LLLOADER_DIGEST_MISMATCH,
} llloader_digest_t;

/*! The rung name and digest verdict of the LAST write.
 *
 *  WHY AN ACCESSOR RATHER THAN OUT-PARAMETERS: these two facts are known only inside the writer
 *  (the caller never sees the rung -- `llloader_select_image_source()` returns an opaque source
 *  that the writer consumes and closes) while `action` and `slot` are known only to the caller.
 *  An `ota-result` frame needs all four, so one of the two has to reach the other.  Widening the
 *  write function's signature changes a trusted-root API that three call sites use; a read-only
 *  accessor adds no parameter and no caller is obliged to use it.
 *
 *  NOT REENTRANT, and it does not need to be: the loader writes one image at a time, single
 *  threaded, and then reboots.  Stated rather than assumed, because a static in the trusted root
 *  is exactly the thing a later concurrent caller would silently corrupt. */
llloader_digest_t llloader_ota_last_digest(void);
const char       *llloader_ota_last_rung(void);   //!< "" before the first write
