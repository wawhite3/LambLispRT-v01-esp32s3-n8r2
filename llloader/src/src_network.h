// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- source ladder rung 2: network.  Brings up WiFi STA and streams a VM image
// over plain HTTP from a configured image server.  Per OTA the recovery net is a PRIVATE,
// ISOLATED network with a per-node token, so the channel is unencrypted (LOADER_NO_TLS) and the
// image is authenticated by its own SHA-256, not by TLS.
//
// Config lives in NVS namespace "ota-p125":
//   wifi_ssid    (str)  -- AP to join
//   wifi_pass    (str)  -- WPA2 passphrase (omit/empty for an open AP)
//   img_url      (str)  -- URL of the pending image, e.g. http://10.0.0.1:8080/llvm.img
//   img_url_gold (str)  -- optional URL of the pinned golden image (RECOVER prefers this)
//   img_token    (str)  -- optional value sent as the Authorization header
// The digest sidecar is fetched from "<img_url>.sha256" (64 hex chars) when present.

#pragma once

#include "image_source.h"

//! Join WiFi, open the configured image URL, and return a streaming source, or NULL if the rung
//! is unconfigured / WiFi won't join / the server won't serve. Owns WiFi + the HTTP connection
//! until close(). want_golden prefers img_url_gold.
image_source_t *network_open(bool want_golden);
