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
    src = network_open(want_golden);
    if (src != NULL) {
        ESP_LOGI(TAG, "using rung 'network'");
        return src;
    }

    // Rung 3: operator console over UART (zero-infrastructure floor).
    src = llloader_console_open(want_golden);
    if (src != NULL) {
        ESP_LOGI(TAG, "using rung 'console'");
        return src;
    }

    // Rung 3b: operator console over BLE (the wireless, no-USB variant of rung 3).  Tried after
    // UART so a bench operator on a cable is served first; BLE waits for a phone/laptop to push.
    src = llloader_ble_console_open(want_golden);
    if (src != NULL) {
        ESP_LOGI(TAG, "using rung 'ble-console'");
        return src;
    }

    ESP_LOGW(TAG, "no image-source rung could supply an image (want_golden=%d)", (int) want_golden);
    return NULL;
}
