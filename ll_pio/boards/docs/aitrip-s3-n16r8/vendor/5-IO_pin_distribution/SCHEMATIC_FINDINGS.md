<!-- Copyright 2026 by Frobenius Norm LLC 2026-09-21 -->

# What the schematic says that the pin spreadsheet does not

Source: `schematic_sheet1_power_usb_sd_backlight.png` and
`schematic_sheet2_esp32_panel_touch_audio.png` — Shenzhen Jingcai's own 2-sheet circuit diagram
for `ESP32-4848S040`, shipped inside `5-IO pin distribution/` as `1.png` and `2.png`.

**Neither sheet is in any GitHub mirror of this archive.** They are the reason to fetch from
`pan.jczn1688.com` rather than from a mirror, and they overturned two statements we had already
written into `w3_board-aitrip-s3-n16r8.json` and published.

These are read off a raster schematic. Where a trace was not legible with certainty it says so.

---

## 1. The panel reset is an RC power-on reset, not a GPIO — this is a hard constraint

Panel connector `LCD1` (42-pin, "4.0 TFT") pin 6 is `RST`, and sheet 2 shows it driven by
**R16 (10 kΩ to 3V3) with C21 (0.1 µF) and C22 (1 µF)** — a passive power-on reset network.
It is on no GPIO.

We had recorded *"there is no LCD reset pin — reset lives inside the SPI init sequence."* The first
half was wrong and the conclusion was too comfortable. The correct statement:

> **The ST7701 cannot be reset in software at all.** There is a reset line; the MCU cannot drive
> it. If an init sequence leaves the controller in a bad state, the only recovery is a
> **power cycle** — not a reboot, not a re-run of init, and not `EN`/`RST` on the module, which
> resets the ESP32 while the panel's RC network stays charged.

That matters for driver bring-up (P231 phase 1): an init sequence that must be retried needs the
power removed between attempts, so "flash, observe, adjust, re-flash" is not a valid loop for the
handshake itself.

`TP-RST` on the touch FPC is the **same `LCD_RST` net**, so the GT911 shares this behaviour.

## 2. GT911 address 0x5D is structural, not a default

Touch FPC `FPC1` (6-pin, 1.0 mm): `GND / SDA(IO19) / SCL(IO45) / REST(LCD_RST) / INT / GND`,
with SDA and SCL pulled up by R4 and R3 (4.7 kΩ to 3V3).

`TP_INT` reaches the panel connector but **lands on no GPIO**. The GT911 samples INT at the
release of reset to choose between 0x5D and 0x14; with INT unheld and reset owned by an RC network,
the board can only ever present **0x5D**. Hard-code it. A driver that toggles RST to select the
address cannot work here, and cannot be made to work.

## 3. The SD card's MISO is DAT0 — the vendor spreadsheet mislabels it

Sheet 1, connector `TF1` (self-ejecting socket, pins `1 DAT2, 2 CD/DAT3, 3 CMD, 4 VDD, 5 CLK,
6 VSS, 7 DAT0, 8 DAT1, 9 CD, 10 GND`):

| GPIO | schematic net | TF1 pin | SPI role |
|---|---|---|---|
| IO42 | `TF_CS`    | 2 — CD/DAT3 | CS |
| IO47 | `MCU_MOSI` | 3 — CMD     | MOSI |
| IO48 | `TF_CLK`   | 5 — CLK     | SCK |
| IO41 | `MCU_MISO` | 7 — DAT0    | MISO |

The spreadsheet calls IO41 **`TF(D1)`**. The schematic wires it to **DAT0**, which is what MISO is
in SPI mode; `D1` would be pin 8 and is unconnected. The spreadsheet is wrong here and the
schematic wins — a reminder that the xlsx is a summary, not the design.

R15 (10 kΩ) pulls `TF_CS` up; RN1 (10 kΩ network) pulls the data lines up.

## 4. Audio vs relay is a 0-ohm jumper, with designators

`Operating instructions.txt` says the relay and I2S share IO1/IO2/IO40 and that enabling audio means
moving R25/R26/R27 to R21/R22/R23. Sheet 2 gives the mapping:

| GPIO | relay path (fitted) | audio path (empty) | audio signal |
|---|---|---|---|
| IO40 | **R25** → relay1 | R21 | `DIN` |
| IO2  | **R26** → relay2 | R22 | `LRCLK` |
| IO1  | **R27** → relay3 | R23 | `BCLK` |

So it is **one board, not two SKUs**. "Check the variant" was the wrong instruction; the checkable
thing is **which of R21–R23 / R25–R27 are populated**. The amplifier (U4, NS4168) and its output
`JST_1.25_2P` (P7) are fitted regardless — only the three jumpers decide what reaches them.

Relays also leave via header `H1`: `GND, relay1, relay2, relay3, U0RXD, U0TXD, 5V`.

## 5. Things the pin table does not mention at all

* **Battery charging.** U1 charger with three status LEDs, inductor L2, `BAT+`/`BAT-` on a
  `JST_1.25_2P` (P6), power switch SW1, rail `VOUT-BAT`. The backlight boost (U5) and the audio amp
  both run from `VOUT-BAT`, not from 3V3 — so **backlight and audio stay alive on battery**.
* **Auto-reset circuit.** CH340C `DTR`/`RTS` drive T1/T2 (each via a 10 kΩ base resistor, R8/R9)
  onto `IO0` and `RST` — the standard ESP32 auto-program circuit. This is why `esptool` can enter
  the bootloader without the buttons.
* **Backlight is a boost driver, not a GPIO-driven LED.** U5 takes `IO38` as `BL_CTR` on its
  feedback node (via R13/R14), with L1, D2 and `LEDA`/`LEDK` to the panel. PWM on IO38 therefore
  modulates a regulator, so brightness will not be linear in duty cycle.
* **`P2` debug header**: `U0RXD, U0TXD, IO9, RST, GND, 3V3`. **IO9 is also RGB data line `DB10`**,
  so anything attached to that header drives a green data line. *Legibility note: the `IO9` label on
  P2 was read from a low-resolution raster and is the one net on these sheets worth confirming
  against the physical board before relying on it.*
* **The Type-C port is power and USB-to-TTL only.** USB `D+`/`D-` reach the CH340C (U2), never the
  ESP32 — consistent with IO19/IO20 being spent on touch SDA and `DB7`.

## 6. Data-line mapping, confirmed independently

The `LCD1` connector lists `DB1`…`DB17` with `DB12` skipped, and the GPIO under each matches the
spreadsheet exactly. That is now a **second, independent** confirmation of the bus order, from the
design rather than from a summary table — and it confirms the missing `DB0`/`DB12` are a wiring
decision (RGB666 panel driven as RGB565), not a transcription error.
