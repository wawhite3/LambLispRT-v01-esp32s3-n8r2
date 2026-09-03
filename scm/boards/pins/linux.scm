;;; Copyright 2026 by Frobenius Norm LLC 2026-08-04 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; Pin map for native Linux builds (x86-64 / aarch64).  No hardware GPIO -- this
;;; exists only because setup.scm loads Pins.scm unconditionally.  Kept minimal.
(define Pins (alist->dict '((pins-i2c . (13 14)))))
