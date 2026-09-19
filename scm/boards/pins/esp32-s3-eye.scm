;;; Copyright 2026 by Frobenius Norm LLC 2026-08-04 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; Pin map for the ESP32-S3-EYE (camera pins owned by esp32-camera lib in Ph2).
;;; Generic ESP32-S3 1:1 GPIO passthrough map (pin-gpioN = N).  Shipped to the
;;; device as Pins.scm by this target's manifest -- NO runtime board dispatch;
;;; this is this target's OWN independent copy, free to diverge.

(define Pins
  (alist->dict '(
		  (pin-BOOT  . 0)
		  (pin-gpio1 . 1)
		  (pin-gpio2 . 2)
		  (pin-JTAG  . 3)
		  (pin-gpio4 . 4)

		  (pin-gpio5 . 5)
		  (pin-gpio6 . 6)
		  (pin-gpio7 . 7)
		  (pin-gpio8 . 8)
		  (pin-gpio9 . 9)

		  (pin-gpio10 . 10)
		  (pin-gpio11 . 11)
		  (pin-gpio12 . 12)
		  (pin-SDA0   . 13)	;these should work but are not predefined by esp
		  (pin-SCL0   . 14)

		  (pin-U0RTS . 15)
		  (pin-U0CTS . 16)
		  (pin-U1TXD . 17)
		  (pin-U1RXD . 18)
		  (pin-U1RTS . 19)
		  (pin-U1CTS . 20)

		  (pin-gpio21 . 21)

		  (pin-gpio35 . 35)
		  (pin-gpio36 . 36)
		  (pin-gpio37 . 37)
		  (pin-gpio38 . 38)
		  (pin-gpio39 . 39)
		  (pin-gpio40 . 40)
		  (pin-gpio41 . 41)
		  (pin-gpio42 . 42)

		  (pin-U0TXD  . 43)
		  (pin-U0RXD  . 44)
		  (pin-VSPI   . 45)
		  (pin-LOG    . 46)

		  (pin-gpio47 . 47)

		  (pin-RGBLED . 48)

		  (pins-i2c . (13 14))
		  )
		)
  )
