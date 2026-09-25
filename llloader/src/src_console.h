// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- source ladder rung 3: operator console.  The last resort: when aux-storage and
// network can't supply an image, an operator pushes one over a wire.  This rung implements the
// UART transport (UART0, the programming cable -- always physically present); a BLE transport is
// the wireless variant of the same rung and reuses the same image_source contract.
//
// Wire frame (little-endian), sent by the operator's tool after the READY banner:
//   magic[4]  = 'L','L','I','M'
//   size[4]   = uint32 image length
//   sha256[32]= expected digest, or 32 zero bytes to send UNVERIFIED
//   image[size]
// The sender is w3_ai_scripts/llloader_console_send.py.

#pragma once

#include "image_source.h"

//! Take over UART0, announce READY, and block up to a few minutes for an operator to push an
//! image frame. Returns a streaming source over the framed image, or NULL if none arrives.
//! want_golden is ignored (the operator chooses what to send).
//! Named llloader_console_open (not console_open) -- IDF's esp_stdio exports a `console_open`.
image_source_t *llloader_console_open(bool want_golden);
