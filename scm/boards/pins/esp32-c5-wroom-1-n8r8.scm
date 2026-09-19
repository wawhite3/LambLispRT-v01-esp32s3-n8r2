;;; Copyright 2026 by Frobenius Norm LLC 2026-09-09 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; Pin map for the ESP32-C5-WROOM-1-N8R8 (8MB flash, 8MB quad PSRAM -- MEASURED 2026-09-11,
;;; both boards reporting 8388608 bytes), as
;;; carried on an ESP32-C5-DevKitC-1 board.  SHARED BY BOTH C5 UNITS: the envs
;;; esp32-c5-wroom-1-n8r8-00 and -01 are two physical boards of the same type and both
;;; manifests stage this one file -- exactly as the two N8R2 units share one pin map.
;;; RENAMED 2026-09-11 from esp32-c5-devkitc-1-n8r8.scm: the name now follows the MODULE
;;; (which is what fixes the memory) rather than the carrier board.  The memory itself was
;;; unchanged by the rename -- it was measured off both boards, not read off a part number.
;;; Shipped to the device as Pins.scm by this target's manifest -- NO runtime board
;;; dispatch; this is this target's OWN independent copy, free to diverge.
;;;
;;; WHY THIS FILE EXISTS.  Until 2026-09-09 this target's manifest mapped
;;; `boards/pins/linux.scm -> Pins.scm` -- the LINUX pin map, on a microcontroller.  The
;;; manifest had been cloned from a host target and never re-based (B336), and nothing
;;; caught it because no C5 pin map existed to notice the absence of.
;;;
;;; EVERY VALUE BELOW IS READ FROM ESPRESSIF'S OWN esp32c5 ARDUINO VARIANT --
;;; framework-arduinoespressif32/variants/esp32c5/pins_arduino.h -- and the GPIO range
;;; from soc_caps.h (SOC_GPIO_PIN_COUNT 29, so GPIO0..28 exist).  NOTHING here is
;;; inferred from another board or guessed: a wrong pin number is a short circuit, not a
;;; failed test.
;;;
;;; NOT VERIFIED AGAINST HARDWARE.  These are the chip/variant defaults.  No peripheral
;;; is wired to this bare DevKitC-1, so nothing here has been confirmed by a device
;;; responding on a pin.  Confirm before trusting a specific line for real wiring.

(define Pins
  (alist->dict '(
		 ;; I2C -- variant defaults SDA=0 SCL=1
		 (pin-SDA0   . 0)
		 (pin-SCL0   . 1)

		 ;; Low-power I2C instance (SDA1/SCL1 in the variant)
		 (pin-LP-SDA . 2)
		 (pin-LP-SCL . 3)

		 ;; ADC-capable, variant A0..A5 = GPIO1..6
		 (pin-A0 . 1)
		 (pin-A1 . 2)
		 (pin-A2 . 3)
		 (pin-A3 . 4)
		 (pin-A4 . 5)
		 (pin-A5 . 6)

		 ;; SPI -- variant SS=6 MOSI=8 MISO=9 SCK=10
		 (pin-SS   . 6)
		 (pin-MOSI . 8)
		 (pin-MISO . 9)
		 (pin-SCK  . 10)

		 ;; UART0 -- variant TX=11 RX=12.  NOTE these are the pins behind the
		 ;; CP210x bridge, which is where the REPL appears: this env carries no
		 ;; ARDUINO_USB_CDC_ON_BOOT, so Serial goes to UART0, not to native USB.
		 (pin-U0TXD . 11)
		 (pin-U0RXD . 12)

		 ;; 1:1 GPIO passthrough for the parts that exist (SOC_GPIO_PIN_COUNT 29)
		 (pin-gpio0  . 0)
		 (pin-gpio1  . 1)
		 (pin-gpio2  . 2)
		 (pin-gpio3  . 3)
		 (pin-gpio4  . 4)

		 (pin-gpio5  . 5)
		 (pin-gpio6  . 6)
		 (pin-gpio7  . 7)
		 (pin-gpio8  . 8)
		 (pin-gpio9  . 9)

		 (pin-gpio10 . 10)
		 (pin-gpio11 . 11)
		 (pin-gpio12 . 12)
		 (pin-gpio13 . 13)
		 (pin-gpio14 . 14)

		 (pin-gpio15 . 15)
		 (pin-gpio16 . 16)
		 (pin-gpio17 . 17)
		 (pin-gpio18 . 18)
		 (pin-gpio19 . 19)

		 (pin-gpio20 . 20)
		 (pin-gpio21 . 21)
		 (pin-gpio22 . 22)
		 (pin-gpio23 . 23)
		 (pin-gpio24 . 24)

		 (pin-gpio25 . 25)
		 (pin-gpio26 . 26)
		 (pin-gpio27 . 27)
		 (pin-gpio28 . 28)

		 ;; Addressable RGB LED -- variant PIN_RGB_LED 27
		 (pin-RGBLED . 27)

		 (pins-i2c . (0 1))
		 )
	       )
  )
