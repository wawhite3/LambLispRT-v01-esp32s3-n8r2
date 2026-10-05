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
#include "llloader_query.h"   //!< [P253] step C: llloader_status_t and the reply builder

//! Take over UART0, announce READY, and block up to a few minutes for an operator to push an
//! image frame. Returns a streaming source over the framed image, or NULL if none arrives.
//! want_golden is ignored (the operator chooses what to send).
//! Named llloader_console_open (not console_open) -- IDF's esp_stdio exports a `console_open`.
image_source_t *llloader_console_open(bool want_golden);

/*! --- [P253] step C: answering queries WHILE waiting for an image ---

    WHY THE QUERY PATH LIVES IN THIS RUNG AND NOT BESIDE IT.  The wait above scans RX byte-at-a-time
    for the `LLIM` magic and DISCARDS everything before it, for five minutes.  A query sent in that
    window is therefore swallowed as pre-magic garbage -- no reply, no error, and from outside the
    unit looks dead.  That is the exact symptom [P253] exists to remove, so the answerer has to be
    inside the same loop rather than a second listener competing for the same UART.

    THE IMAGE STILL WINS RX.  Magic matching is unaffected: a `(` only starts a line buffer, and a
    byte that could begin `LLIM` is still offered to the matcher.  A listener that silently ate an
    image push would be the worst outcome in this proposal, which is why it is stated here.

    The loader registers a PROVIDER rather than handing over a snapshot, so each answer is computed
    when the question is asked -- `install_tries` can change during a five-minute window, and a
    stale `(ota-status ...)` is worse than a slow one.  Registering NULL (the default) means queries
    are parsed and acknowledged as unanswerable rather than silently dropped. */
//! Register who can describe this unit.  Called by llloader_main.c, which owns the OTA partition
//! handle and the NVS helpers; this rung deliberately knows nothing about either.
void llloader_console_set_status_provider(llloader_status_fn fn);
