;;; Copyright 2026 by Frobenius Norm LLC 2026-07-02 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; Board-specific init for the ESP32-S3-EYE (P136 camera node).
;;; Loaded by setup.scm when lamb-board = "esp32-s3-eye".
;;; Phase 1: nothing to do -- just confirm we booted on the native USB CDC.
;;; Phase 2 will arm the OV2640 camera (esp32-camera / CAMERA_MODEL_ESP32S3_EYE).
(syslog "Board: ESP32-S3-EYE (P136 camera node) -- REPL on native USB-Serial/JTAG\n")
