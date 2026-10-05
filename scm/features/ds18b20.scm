;;; Copyright 2026 by Frobenius Norm LLC 2026-06-30
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; P133 Tier 1 (7.2): DS18B20 1-Wire temperature driver.
;;; Portable .scm over the C++ onewire-* bus binding (ll_xmop3_OneWire.cpp).
;;;
;;; Wiring: DS18B20 DATA -> a GPIO, with a 4.7k pull-up from DATA to 3V3.
;;;
;;; API:
;;;   (ds18b20-convert! pin)        ;; start a conversion on all devices (Skip ROM)
;;;   (ds18b20-read pin)     -> C   ;; single-drop blocking read (convert + wait + decode)
;;;   (ds18b20-read-rom pin rom) -> C  ;; addressed read on a multi-drop bus (rom = 8-byte bytevector)
;;;   (ds18b20-scan pin)    -> (rom ...)  ;; ROM codes on the bus (just (onewire-search pin))
(info "Loading ds18b20 driver\n")

(define ds18b20-cmd-skip-rom  #xCC)
(define ds18b20-cmd-match-rom #x55)
(define ds18b20-cmd-convert   #x44)
(define ds18b20-cmd-read-pad  #xBE)

;; Dallas/Maxim CRC8 (poly 0x8C reflected) over the first n bytes of a bytevector.
(define (ds18b20-crc8 bytes n)
  (let loop ((i 0) (crc 0))
    (if (>= i n)
        crc
        (let inner ((j 0) (crc crc) (b (bytevector-u8-ref bytes i)))
          (if (>= j 8)
              (loop (+ i 1) crc)
              (let* ((mix  (bitwise-and (bitwise-xor crc b) 1))
                     (crc1 (arithmetic-shift crc -1))
                     (crc2 (if (= mix 1) (bitwise-xor crc1 #x8C) crc1)))
                (inner (+ j 1) crc2 (arithmetic-shift b -1))))))))

;; Read the 9-byte scratchpad after a ROM-selection sequence has been issued.
;; Returns the bytevector, or #f if the CRC check fails.
(define (ds18b20--read-scratchpad pin)
  (onewire-write-byte pin ds18b20-cmd-read-pad)
  (let ((pad (make-bytevector 9 0)))
    (let loop ((i 0))
      (when (< i 9)
        (bytevector-u8-set! pad i (onewire-read-byte pin))
        (loop (+ i 1))))
    (if (= (ds18b20-crc8 pad 8) (bytevector-u8-ref pad 8))
        pad
        #f)))

;; Decode the temperature (degrees C) from a 9-byte scratchpad bytevector.
(define (ds18b20--decode pad)
  (let* ((lo  (bytevector-u8-ref pad 0))
         (hi  (bytevector-u8-ref pad 1))
         (raw (bitwise-or (arithmetic-shift hi 8) lo))
         (signed (if (>= raw 32768) (- raw 65536) raw)))
    (/ signed 16.0)))

;; Start a temperature conversion on every device on the bus (Skip ROM).
(define (ds18b20-convert! pin)
  (if (onewire-reset pin)
      (begin
        (onewire-write-byte pin ds18b20-cmd-skip-rom)
        (onewire-write-byte pin ds18b20-cmd-convert)
        #t)
      #f))

;; Wait (up to ~1 s) for an in-progress conversion to finish.  The DS18B20 holds
;; the bus low while converting and releases it (read-bit -> 1) when done.
(define (ds18b20--wait-ready pin)
  (let loop ((tries 0))
    (cond ((>= (onewire-read-bit pin) 1) #t)
          ((>= tries 100) #f)            ;; ~1 s cap (10 ms per poll)
          (else (delay-ms 10) (loop (+ tries 1))))))

;; Single-drop blocking read: convert, wait for completion, decode.
;; Returns degrees C, or #f on no-presence / CRC failure.
(define (ds18b20-read pin)
  (if (ds18b20-convert! pin)
      (begin
        (ds18b20--wait-ready pin)
        (if (onewire-reset pin)
            (begin
              (onewire-write-byte pin ds18b20-cmd-skip-rom)
              (let ((pad (ds18b20--read-scratchpad pin)))
                (and pad (ds18b20--decode pad))))
            #f))
      #f))

;; Addressed read on a multi-drop bus.  rom is an 8-byte bytevector from
;; (onewire-search pin).  Assumes a conversion has already been triggered
;; (e.g. with ds18b20-convert!) and completed.
(define (ds18b20-read-rom pin rom)
  (if (onewire-reset pin)
      (begin
        (onewire-write-byte pin ds18b20-cmd-match-rom)
        (let loop ((i 0))
          (when (< i 8)
            (onewire-write-byte pin (bytevector-u8-ref rom i))
            (loop (+ i 1))))
        (let ((pad (ds18b20--read-scratchpad pin)))
          (and pad (ds18b20--decode pad))))
      #f))

;; Enumerate ROM codes present on the bus (each an 8-byte bytevector).
(define (ds18b20-scan pin)
  (onewire-search pin))
