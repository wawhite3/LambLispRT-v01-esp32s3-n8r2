;;; Copyright 2026 by Frobenius Norm LLC 2026-09-24
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; hud-layout.scm -- the LAYOUT layer: which widgets exist on the 480x480 panel, where they sit,
;;; and what each one means.  Built entirely from features/lvgl-widgets.scm, which is built
;;; entirely from the thin LVGL shim.  Nothing here touches a C++ mop that knows about a HUD.
;;;
;;; WHY THE ARRANGEMENT LIVES HERE AND NOT IN THE DRIVER.  This is the part that changes: a field
;;; moves, a colour is wrong, a reading needs more room.  In C++ each of those is a rebuild and a
;;; reflash; here it is a file that pushes in seconds and can be re-evaluated on a running board.
;;;
;;; SCREEN GEOMETRY.  480x480.  The camera image is 240x240 and sits centred, leaving a band top
;;; and bottom for text.  Positions are absolute rather than aligned-to-parent: this panel is
;;; mounted in a fixed orientation and absolute coordinates are what an operator can check against
;;; a ruler when something lands in the wrong place.

(syslog "Loading HUD layout\n")

;;; Colours are NATIVE RGB565 as far as the shim is concerned, but these are RGB888 literals --
;;; LVGL converts.  Chosen for contrast on a dark background rather than for decoration: a HUD is
;;; read at a glance and in bad light.
;;; EVERY RED AND BLUE CHANNEL VALUE IS CONGRUENT TO 4 (MOD 8), AND THAT IS NOT DECORATION.
;;; This board wires an RGB666 panel to 16 data lines with DB0 and DB12 unconnected, so the least
;;; significant bit of red and of blue is dropped in COPPER -- red and blue quantise in steps of 8
;;; while green keeps its full six bits.  LVGL anti-aliases glyph edges by blending text and
;;; background; across that blend green moves smoothly while red and blue step, so any value
;;; sitting near a step boundary flips coarsely and leaves the pixel green-dominant.  That is the
;;; green fringing on light text.
;;;
;;; Choosing each red and blue value at the MIDDLE of its quantisation bucket (x4, xC -- i.e. 4
;;; mod 8) puts every channel as far from a boundary as it can be, so a blend must travel the full
;;; half-bucket before anything steps.  Green is left free: it loses no bits.
;;;
;;; When picking a new colour, check it: (modulo (quotient rgb 65536) 8) and the blue equivalent
;;; should both be 4.  A value ending in 0 or 8 sits exactly ON a boundary and is the worst choice.
(define hud-col-bg     #x14141C)   ;;; near-black, slightly blue
(define hud-col-text   #x7CC4DC)   ;;; pale cyan -- the steady state
(define hud-col-warn   #xEC9C44)   ;;; amber -- attention, not alarm
(define hud-col-good   #x74CC8C)   ;;; green -- associated / healthy
(define hud-col-gauge  #x4C9CD4)   ;;; the sonar bar's indicator

;;; Widget handles, filled in by (hud-layout-build!).  #f until then, and every accessor tolerates
;;; #f so a partial build cannot turn a display fault into a crash.
(define hud-w-link  #f)   ;;; top left  -- SSID and address
(define hud-w-rssi  #f)   ;;; top right -- signal, the only fast-moving field
(define hud-w-sonar #f)   ;;; bottom    -- distance and drive
(define hud-w-gauge #f)   ;;; bottom    -- distance as a bar
(define hud-w-stat  #f)   ;;; bottom    -- frames / bad counters

;;; (hud-layout-build!) -> #t/#f.  Create every widget.  Call ONCE, after (lvgl-init).
;;;
;;; RSSI IS A SEPARATE WIDGET FROM THE LINK LINE, AND THAT IS NOT COSMETIC.  LVGL repaints the
;;; whole of any object whose text changed.  A single line carrying SSID, address and signal
;;; redraws entirely every time the signal moves a decibel, which is visible as the line
;;; flickering -- measured on this panel.  The address changes almost never and the signal changes
;;; constantly, so they are different objects.
(define (hud-layout-build!)
  (let ((scr (lv-screen-active)))
    (and scr
         (begin
           (lv-obj-set-style-bg-color scr hud-col-bg 0)
           (set! hud-w-link  (make-readout scr  12  14 hud-col-text "NO LINK"))
           (set! hud-w-rssi  (make-readout scr 360  14 hud-col-text "-- dBm"))
           (set! hud-w-sonar (make-readout scr  12 404 hud-col-warn "SONAR --   MOT -- --"))
           (set! hud-w-gauge (make-gauge   scr  12 436 456 16 0 2000 hud-col-gauge))
           (set! hud-w-stat  (make-readout scr 360 404 hud-col-text "f0 bad0"))
           #t))))

;;; --- updates -----------------------------------------------------------------------------
;;; Each takes the value, formats it, and writes ONE widget.  Splitting them is what lets a caller
;;; refresh the fast-moving field without repainting the slow ones.

(define (hud-show-link! connected ssid ip)
  (readout-set! hud-w-link
                (if connected (string-append "LINK " ssid "  " ip) "NO LINK")))

(define (hud-show-rssi! dbm)
  (readout-set! hud-w-rssi (if dbm (string-append (number->string dbm) " dBm") "-- dBm")))

;;; Sonar arrives in millimetres, or -1 when the vehicle has no sensor.  A board without a sonar
;;; and a clear path must NOT look the same, so -1 prints as "--" and leaves the gauge empty.
(define (hud-show-sonar! mm left right)
  (readout-set! hud-w-sonar
                (string-append "SONAR " (if (negative? mm) "--" (number->string mm))
                               (if (negative? mm) "" "mm")
                               "   MOT " (number->string left) " " (number->string right)))
  (gauge-set! hud-w-gauge (if (negative? mm) 0 mm)))

(define (hud-show-stats! frames bad)
  (readout-set! hud-w-stat
                (string-append "f" (number->string frames) " bad" (number->string bad))))

(syslog "HUD layout loaded\n")
