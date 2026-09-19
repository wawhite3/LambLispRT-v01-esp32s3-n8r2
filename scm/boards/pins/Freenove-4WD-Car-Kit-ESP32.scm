;;; Copyright 2026 by Frobenius Norm LLC 2026-08-04 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; Pin map for the Freenove 4WD Car Kit ESP32 (classic ESP32-D0WD WROVER-CAM
;;; module on the 4WD chassis).  Shipped to the device as Pins.scm by this
;;; target's manifest -- there is NO runtime board dispatch; each target ships
;;; exactly its own map.
;;; Pins mentioned are all brought off the chip to the module pins.  Pins with a
;;; generic name are available; a functional name indicates a predefined use.

(define Pins
  (alist->dict '(
		 (pin-IR     . 0)
		 (pin-U0TXD  . 1)
		 (pin-buzzer . 2)
		 (pin-U0RXD  . 3)
		 (pin-CSI_Y2 . 4)
		 (pin-CSI_Y3 . 5)

		 (pin-FLASH_CLK . 6)
		 (pin-FLASH_D0  . 7)
		 (pin-FLASH_D1  . 8)
		 (pin-FLASH_D2  . 9)
		 (pin-FLASH_D3  . 10)
		 (pin-FLASH_CMD . 11)

		 (pin-sonar-trig . 12)
		 (pin-SDA0       . 13)
		 (pin-SCL0       . 14)
		 (pin-sonar-echo . 15)

		 (pin-CSI_Y4    . 18)
		 (pin-CSI_Y5    . 19)

		 (pin-XCLK      . 21)
		 (pin-PCLK      . 22)
		 (pin-HREF      . 23)

		 (pin-CSI_VYSNC . 25)
		 (pin-SIOD      . 26)
		 (pin-SIOC      . 27)

		 (pin-WS2812 . 32)
		 (pin-ADC    . 33)
		 (pin-CSI_Y8 . 34)
		 (pin-CSI_Y9 . 35)
		 (pin-CSI_Y6 . 36)
		 (pin-CSI_Y7 . 39)

		 (pins-i2c   . (13 14))
		 (pins-sonar . (12 15))
		 (pin-photo  . 33)
		 )
	       )
  )
