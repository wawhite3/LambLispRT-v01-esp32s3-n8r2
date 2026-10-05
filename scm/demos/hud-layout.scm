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
(define hud-col-gauge  #x4C9CD4)   ;;; the sonar bar's INDICATOR (the fill)
;;; ...and the bar's TRACK.  A bar styled on the indicator alone keeps LVGL's stock track colour
;;; and renders two-tone -- one colour from this palette and one from none.  Dark enough to read
;;; as "empty" against #x14141C without vanishing into it.  R=0x2C, B=0x34, both 4 mod 8, per the
;;; quantisation note above.
(define hud-col-track  #x2C2C34)

;;; Widget handles, filled in by (hud-layout-build!).  #f until then, and every accessor tolerates
;;; #f so a partial build cannot turn a display fault into a crash.
(define hud-w-link  #f)   ;;; top left  -- SSID and address
(define hud-w-clock #f)   ;;; top right -- date and time, ABOVE the signal
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
           (set! hud-w-clock (make-readout scr 300  14 hud-col-text "---- -- -- --:--:--"))
           (set! hud-w-rssi  (make-readout scr 300  36 hud-col-text "-- dBm"))
           (set! hud-w-sonar (make-readout scr  40 418 hud-col-warn "SONAR --   MOT -- --"))
           ;;; VERTICAL, LEFT EDGE, FULL SENSOR RANGE (owner, 2026-09-25).
           ;;; LVGL infers a bar's orientation from its GEOMETRY -- taller than wide means
           ;;; vertical, and it fills upward.  There is no orientation flag to set; get w and h
           ;;; the wrong way round and it silently stays horizontal.
           ;;; x=12..30 is clear of the centred 240x240 camera frame, which occupies x=120..360,
           ;;; so the bar and the picture cannot overlap on this 480-wide panel.
           (set! hud-w-gauge (make-gauge   scr  12  70  18 340 0 4000 hud-col-gauge hud-col-track))
           (set! hud-w-stat  (make-readout scr 360 404 hud-col-text "f0 bad0"))
           #t))))

;;; --- updates -----------------------------------------------------------------------------
;;; Each takes the value, formats it, and writes ONE widget.  Splitting them is what lets a caller
;;; refresh the fast-moving field without repainting the slow ones.

(define (hud-show-link! connected ssid ip)
  (readout-set! hud-w-link
                (if connected (string-append "LINK " ssid "  " ip) "NO LINK")))

;;; --- the clock ---------------------------------------------------------------------------
;;;
;;; AN UNSET CLOCK MUST NOT LOOK LIKE A SET ONE.  `current-second` returns epoch seconds, and a
;;; board that has never reached an NTP server returns a value near zero -- which formats to a
;;; perfectly plausible date in 1970.  On a HUD that is the same failure as a fabricated sonar
;;; reading: an operator cannot tell it from the truth.  Anything before 2001 is therefore shown
;;; as dashes, which says "no time" in a way a date cannot.
(define hud-epoch-2001 978307200)

;;; Epoch seconds -> (year month day hour minute second), UTC.
;;; Days-to-civil after Howard Hinnant: shift the year to start in March so the leap day lands at
;;; the END of the cycle and no month-length table is needed.  Integer arithmetic throughout --
;;; this runs on a board whose float path is not free.
(define (hud-civil-from-epoch secs)
  (let* ((days  (quotient secs 86400))
         (rem   (modulo secs 86400))
         (hh    (quotient rem 3600))
         (mm    (quotient (modulo rem 3600) 60))
         (ss    (modulo rem 60))
         (z     (+ days 719468))
         (era   (quotient (if (>= z 0) z (- z 146096)) 146097))
         (doe   (- z (* era 146097)))
         (yoe   (quotient (- doe (+ (quotient doe 1460)
                                    (- (quotient doe 36524))
                                    (quotient doe 146096)))
                          365))
         (y     (+ yoe (* era 400)))
         (doy   (- doe (+ (* 365 yoe) (quotient yoe 4) (- (quotient yoe 100)))))
         (mp    (quotient (+ (* 5 doy) 2) 153))
         (d     (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1))
         (m     (+ mp (if (< mp 10) 3 -9))))
    (list (if (<= m 2) (+ y 1) y) m d hh mm ss)))

(define (hud-pad2 n)
  (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

;;; SAMPLE THE WALL CLOCK ONCE, THEN COUNT WITH THE MONOTONIC ONE.
;;;
;;; CORRECTED 2026-09-25, SAME DAY IT WAS WRITTEN.  This said `current-second` "is not free and is
;;; not guaranteed to return promptly: on a board whose time has never been set it may go looking
;;; for it", and used that to justify sampling once.  THAT MECHANISM IS FALSE.  `mop3_current_second`
;;; is a plain `gettimeofday` plus a float box (`ll_vm_mop3_rxrs.cpp`) -- it contacts nothing, it
;;; cannot block, and an unset clock simply gives a small number.  There is no network round trip
;;; to keep out of the main loop.
;;;
;;; The OBSERVATION behind it was real -- a refresh tick calling `(current-second)` did leave this
;;; board pingable and unreachable -- but the cause was assigned by reading rather than by testing,
;;; and the reading was wrong.  What actually stalled that loop IS NOT ESTABLISHED; do not repeat
;;; the guess here, and do not treat this paragraph as having identified it.
;;;
;;; SAMPLING ONCE IS KEPT, on its own smaller merits rather than on a fabricated hazard: it costs
;;; one float allocation per sync instead of one per tick, and it makes the displayed second
;;; advance monotonically even if the wall clock is stepped underneath it.  The price is that the
;;; display does not learn about a later NTP sync by itself, which is what `hud-clock-sync!` is
;;; for -- the refresh block calls it when `nettime-tick!` reports the clock changed.
;;;
;;; So the epoch is sampled ONCE, deliberately, and the clock advances on `millis`, which is
;;; monotonic, local and cheap.  The displayed time is then only as good as that one sample -- it
;;; will drift, and it does not learn about an NTP sync that happens later.  `(hud-clock-sync!)`
;;; re-samples when a caller knows the time has changed.
(define hud-clock-epoch0 #f)      ;;; wall-clock seconds at the sample
(define hud-clock-millis0 0)      ;;; (millis) at the same instant

(define (hud-clock-sync!)
  (let ((s (guard (e (#t #f)) (current-second))))
    (set! hud-clock-epoch0 (and s (>= s hud-epoch-2001) (exact (floor s))))
    (set! hud-clock-millis0 (millis))
    hud-clock-epoch0))

;;; -> wall-clock seconds now, or #f if the clock was never successfully sampled.
(define (hud-clock-now)
  (and hud-clock-epoch0
       (+ hud-clock-epoch0 (quotient (- (millis) hud-clock-millis0) 1000))))

;;; (hud-show-clock! SECS) -- SECS from (hud-clock-now), or #f.  1-second resolution.
(define (hud-show-clock! secs)
  (readout-set! hud-w-clock
                (if (and secs (>= secs hud-epoch-2001))
                    (let ((c (hud-civil-from-epoch (exact (floor secs)))))
                      (string-append (number->string (car c)) "-"
                                     (hud-pad2 (cadr c)) "-" (hud-pad2 (caddr c)) " "
                                     (hud-pad2 (cadddr c)) ":"
                                     (hud-pad2 (car (cddddr c))) ":"
                                     (hud-pad2 (cadr (cddddr c)))))
                    "---- -- -- --:--:--")))

(define (hud-show-rssi! dbm)
  (readout-set! hud-w-rssi (if dbm (string-append (number->string dbm) " dBm") "-- dBm")))

;;; Sonar arrives in millimetres, or -1 when the vehicle has no sensor.  A board without a sonar
;;; and a clear path must NOT look the same, so -1 prints as "--" and leaves the gauge empty.
;;; THE GAUGE NOW SPANS THE SENSOR'S FULL RANGE, 0-4000 mm (owner, 2026-09-25).  It was 0-2000
;;; briefly; at that scale everything past 2 m pegged full and the bar could not tell 2 m from 4 m.
;;; Matching `Sonar.range-m` means the bar's top IS the sensor's limit, so the scale means one
;;; thing end to end.
;;;
;;; BUT KNOW WHAT A FULL BAR MEANS, BECAUSE IT IS NOT ONE THING.  `Sonar.range-m` is ALSO the
;;; no-object sentinel: a timeout and an over-range echo both report 4.0 m.  So "nothing detected"
;;; and "a real reading past 2 m" both peg this bar full, and so does a sonar that has STOPPED
;;; UPDATING -- [B625] froze `Sonar.latest` at exactly 4.0 for months, which would have shown a
;;; confidently full bar, the most reassuring display a dead sensor could produce.
;;;
;;; A negative mm (no sensor on the vehicle) is distinct and renders EMPTY with "--" beside it.
;;; The gap is the middle case: full bar does not distinguish far from unknown.  Left as-is rather
;;; than fixed quietly, because the fix is a display-semantics decision, not a bug fix.
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
