;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "Loading light sensor functions\n")

(define have-light-sensor-pins (dict-ref? Pins 'pin-photo))
(define have-light-sensor have-light-sensor-pins)
(define light-sensor-pin 0)
(
 when have-light-sensor
  (set! light-sensor-pin (cdr have-light-sensor-pins))
  )

(define (light-sensor) (/ (analogRead light-sensor-pin) 4096.0))

(unless have-light-sensor
  (set! light-sensor Lambda0)
  )

(syslog "Light sensor reads ~a\n" (light-sensor))
