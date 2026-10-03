idf_component_register(
    SRCS "llloader_main.c"
         "ota_writer.c"
         "source_ladder.c"
         "src_aux_storage.c"
         "src_network.c"
         "src_console.c"
         "src_ble_console.c"
         "llloader_hex.c"
         # [P253] The LLIP frame reader/writer.  IN THE BUILD BEFORE IT HAS A CALLER, ON PURPOSE --
         # so that whoever wires up the first caller is not also discovering a cross-compile break
         # in the trusted root while changing its boot path.
         #
         # THE COST WAS MEASURED, NOT ASSUMED, because the factory partition is at 87.9% with only
         # ~139 KB spare and a free-looking addition there is worth checking.  Two builds of
         # llloader-esp32 on 2026-09-30, the CMakeLists line the only difference:
         #   without:  Flash 1037003 / 1179648 (87.9%)   RAM 46392
         #   with:     Flash 1037003 / 1179648 (87.9%)   RAM 46392
         # Byte-identical -- --gc-sections drops an unreferenced translation unit entirely.  If a
         # later addition here is NOT free, that is the number to compare against.
         #
         # AND IT COMPILES ON BOTH ARCHITECTURES, checked by looking at the OBJECT rather than at
         # the exit code (rc=0 does not prove a file was built -- a mis-spelled SRCS entry is not
         # an error to CMake in every layout):
         #   .../llloader-esp32/src/llloader_llip.c.o        ELF 32-bit, Tensilica Xtensa
         #   .../llloader-esp32c5-8m/src/llloader_llip.c.o   ELF 32-bit, UCB RISC-V, RVC, soft-float
         # Zero warnings in either.  That is the reason this line exists before a caller does.
         "llloader_llip.c"
    INCLUDE_DIRS "."
    REQUIRES app_update esp_partition nvs_flash mbedtls esp_system
    PRIV_REQUIRES esp_timer joltwallet__littlefs
                  esp_wifi esp_netif esp_event esp_http_client esp_driver_uart
                  bt)
