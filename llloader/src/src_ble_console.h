// Copyright 2026 by Frobenius Norm LLC 2026-07-08 00:00:00
//
// OTA llloader -- BLE console rung (rung 3b): the wireless variant of the UART console.
// A NimBLE GATT peripheral (Nordic-UART-style) exposes a control characteristic carrying the
// LLIM frame header (magic + size + sha256) and a data characteristic streaming the image bytes
// into a FreeRTOS stream buffer that con_read drains -- the same pull-stream image_source contract
// as every other rung, so the OTA writer consumes it blind.

#pragma once

#include "image_source.h"

//! Bring up NimBLE, advertise as an image-push peripheral, and wait for an operator to push the
//! LLIM control frame. Returns an image_source streaming the announced image, or NULL if BLE could
//! not start / no frame arrived before the timeout. `want_golden` is ignored (operator chooses).
image_source_t *llloader_ble_console_open(bool want_golden);
