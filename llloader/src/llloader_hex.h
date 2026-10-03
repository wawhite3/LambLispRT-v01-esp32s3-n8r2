// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- tiny hex <-> bytes helpers, shared by the OTA writer (digest logging) and the
// source rungs (parsing .sha256 sidecars). One home, so the parse never drifts between callers.

#pragma once

#include <stddef.h>
#include <stdint.h>

//! Parse exactly `n` bytes from 2*n hex chars. Returns 0 on success, -1 on any non-hex char.
int  ll_hex_to_bytes(const char *hex, uint8_t *out, size_t n);

//! Write `n` bytes as 2*n lowercase hex chars plus a NUL. `out` must hold 2*n+1 bytes.
void ll_bytes_to_hex(const uint8_t *in, size_t n, char *out);
