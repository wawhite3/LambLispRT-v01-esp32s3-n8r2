// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- hex helpers. See llloader_hex.h.

#include "llloader_hex.h"

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int ll_hex_to_bytes(const char *hex, uint8_t *out, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        int hi = hexval(hex[i * 2]), lo = hexval(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i] = (uint8_t) ((hi << 4) | lo);
    }
    return 0;
}

void ll_bytes_to_hex(const uint8_t *in, size_t n, char *out)
{
    static const char *H = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[i * 2]     = H[(in[i] >> 4) & 0xF];
        out[i * 2 + 1] = H[in[i] & 0xF];
    }
    out[n * 2] = '\0';
}
