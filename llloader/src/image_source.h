// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- image-source interface.  The loader's INSTALL/RECOVER actions need a VM
// image from SOMEWHERE; the OTA source ladder is aux-storage -> network -> BLE/UART console,
// tried in order.  Each rung implements this one small interface, and the OTA writer
// (ota_writer.c) consumes it blind -- it neither knows nor cares which rung produced the bytes.
//
// A source is a pull stream: the writer repeatedly calls read() for the next chunk until EOF.
// This keeps peak RAM at one chunk (never the whole ~1.5 MB image), which matters on a part
// whose trusted root deliberately avoids PSRAM.

#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct image_source_s image_source_t;

struct image_source_s {
    const char *name;              //!< human label for logs, e.g. "aux-fs", "http", "ble"
    size_t      total_size;        //!< expected image bytes, or 0 if the rung can't know yet

    bool        have_sha256;       //!< true if expected_sha256 carries a digest to verify against
    uint8_t     expected_sha256[32];

    void       *ctx;               //!< rung-private state (file handle, socket, ring buffer...)

    //! Pull the next chunk.  Returns >0 bytes written into buf, 0 on clean EOF, <0 on error.
    //! The writer stops on 0 (success) or <0 (abort); it may call read() many times.
    int  (*read)(image_source_t *self, uint8_t *buf, size_t max);

    //! Release rung-private resources.  Safe to call exactly once after a read loop ends.
    void (*close)(image_source_t *self);
};

//! Walk the OTA source ladder and return the first rung that has an image ready, or NULL if
//! none can supply one right now (loader then falls through to the operator CONSOLE).
//! `want_golden` biases toward a locally-pinned known-good image first (RECOVER path).
image_source_t *llloader_select_image_source(bool want_golden);
