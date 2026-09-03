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
esp_err_t llloader_ota_write(const esp_partition_t *dst, image_source_t *src);
