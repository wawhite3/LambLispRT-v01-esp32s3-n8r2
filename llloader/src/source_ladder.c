// Copyright 2026 by Frobenius Norm LLC 2026-07-07 00:00:00
//
// OTA llloader -- image-source ladder.  Tries each rung in OTA priority order and returns the
// first that can supply a VM image now.  RUNGS ARE STUBS: this is the Ph2b skeleton that wires
// the writer to a source-selection point; each rung lands as its own commit.
//
// Planned rungs (order = trust/cost, cheapest-local first):
//   1. aux-storage  -- a golden/pending image already on the LittleFS `storage` partition
//   2. network      -- HTTP(S) fetch from the pluggable image server (private isolated net)
//   3. BLE / UART    -- operator pushes an image over the console (last resort)
// `want_golden` (RECOVER) biases rung 1 toward the pinned known-good image over any pending one.

#include "image_source.h"
#include "src_aux_storage.h"
#include "src_network.h"
#include "src_console.h"
#include "src_ble_console.h"

#include "esp_log.h"

static const char *TAG = "src_ladder";

image_source_t *llloader_select_image_source(bool want_golden)
{
    // Rung 1: aux-storage (golden/pending image on the LittleFS `storage` partition).
    image_source_t *src = aux_storage_open(want_golden);
    if (src != NULL) {
        ESP_LOGI(TAG, "using rung 'aux-storage'");
        return src;
    }

    // Rung 2: network (WiFi STA + HTTP fetch from the configured image server).
    //
    // -DLOADER_NO_WIFI=1 REMOVES THIS RUNG AND THE WIFI STACK.  WiFi is the largest single block in
    // the trusted root -- measured at 322,779 B against Bluetooth's 161,164 B -- so this is the
    // bigger of the two size levers, and also the bigger loss: rung 2 is the only UNATTENDED
    // recovery path.  Rungs 3/3b both need a human with a cable or a phone; rung 1 needs an image
    // already on storage.  A fleet that recovers itself needs this one.
#if !defined(LOADER_NO_WIFI)
    src = network_open(want_golden);
    if (src != NULL) {
        ESP_LOGI(TAG, "using rung 'network'");
        return src;
    }
#endif

    // Rung 3: operator console over UART (zero-infrastructure floor).
    src = llloader_console_open(want_golden);
    if (src != NULL) {
        ESP_LOGI(TAG, "using rung 'console'");
        return src;
    }

    // Rung 3b: operator console over BLE (the wireless, no-USB variant of rung 3).  Tried after
    // UART so a bench operator on a cable is served first; BLE waits for a phone/laptop to push.
    //
    // -DLOADER_NO_BLE=1 REMOVES THIS RUNG AND THE ENTIRE BLUETOOTH STACK.  It is the largest single
    // size lever in the trusted root: the BT libraries were measured at 161,164 B of the loader
    // against WiFi's 322,779 B, i.e. ~15% of a binary that sits at 87.8% of its factory slot.
    // WHAT IS LOST IS A REAL RECOVERY PATH, not a convenience.  This rung is the only one that
    // serves a board with no golden image on storage, no network, AND no cable -- a deployed unit
    // an operator cannot physically reach.  Rungs 1-3 all require storage, WiFi, or a wire.
    // So this is a PRODUCT decision about the recovery contract, not a build-tuning knob.
#if !defined(LOADER_NO_BLE)
    src = llloader_ble_console_open(want_golden);
    if (src != NULL) {
        ESP_LOGI(TAG, "using rung 'ble-console'");
        return src;
    }
#endif

    ESP_LOGW(TAG, "no image-source rung could supply an image (want_golden=%d)", (int) want_golden);
    return NULL;
}
