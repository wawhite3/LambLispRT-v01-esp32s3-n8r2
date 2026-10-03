// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- source ladder rung 1: aux-storage.  Supplies a VM image from a well-known
// file on the LittleFS `storage` partition (the same partition that holds the Scheme apps).
// This is the cheapest, most-local rung: no network, no operator -- just a golden or pending
// image that a prior VM (or a provisioning tool) dropped on the filesystem.

#pragma once

#include "image_source.h"

//! Mount `storage` read-only and return a source over the best available image file, or NULL.
//! want_golden biases toward the pinned known-good image first (RECOVER); otherwise a freshly
//! staged pending image wins (INSTALL). The returned source owns the mount until close().
image_source_t *aux_storage_open(bool want_golden);
