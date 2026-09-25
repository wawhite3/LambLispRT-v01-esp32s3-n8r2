idf_component_register(
    SRCS "llloader_main.c"
         "ota_writer.c"
         "source_ladder.c"
         "src_aux_storage.c"
         "src_network.c"
         "src_console.c"
         "src_ble_console.c"
         "llloader_hex.c"
    INCLUDE_DIRS "."
    REQUIRES app_update esp_partition nvs_flash mbedtls esp_system
    PRIV_REQUIRES esp_timer joltwallet__littlefs
                  esp_wifi esp_netif esp_event esp_http_client esp_driver_uart
                  bt)
