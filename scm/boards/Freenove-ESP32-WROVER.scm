;;; Copyright 2026 by Frobenius Norm LLC 2026-07-02 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; Board-specific init for the standalone Freenove ESP32-WROVER-E (classic ESP32).
;;; Loaded by setup.scm BEFORE the peripheral modules -- so do NOT reference module
;;; state here (Sonar.pins / light-sensor etc. are not bound yet).  Sonar self-arms
;;; later in Sonar.scm (Sonar.setup on GPIO12/15).  Nothing to do here.
