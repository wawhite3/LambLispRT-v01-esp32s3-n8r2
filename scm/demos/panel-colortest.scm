;;; Copyright 2026 by Frobenius Norm LLC 2026-09-28
;;;
;;; panel-colortest.scm -- HOW MANY COLOURS DOES THIS PANEL ACTUALLY SHOW?
;;;
;;; The tree states, from the wiring, that this board's RGB666 panel is fed over 16 lines with two
;;; data bits unconnected, so red and blue "quantise in steps of 8".  THAT IS A HYPOTHESIS READ
;;; OFF A SCHEMATIC, and it needs care for a reason worth stating: steps of 8 in an 8-bit space is
;;; ALSO what ordinary RGB565 does to red and blue, all by itself, on a perfectly wired panel.  So
;;; the predicted symptom of the defect is indistinguishable from the predicted symptom of no
;;; defect at all, and no amount of looking at photographs settles it.  These patterns are built
;;; to separate the two.
;;;
;;; THE ONLY SENSOR FOR WHAT REACHES THE GLASS IS A HUMAN EYE.  Nothing on the board can read the
;;; panel back: `lvgl-fb-pixel-dma` reads the FRAMEBUFFER, which is what we wrote, and every bit we
;;; are hunting is lost AFTER that point, on the wire.  So the patterns are designed for a reporter
;;; who can only answer "I see a seam" or "I do not", and the burden is on the pattern to make that
;;; answer mean something.
;;;
;;; WHICH IS WHY EVERY PATTERN CARRIES TWO CONTROLS, and they are not decoration:
;;;   * a row whose halves are DELIBERATELY IDENTICAL -- it must show NO seam.  Without it,
;;;     "no seam on bit 0" cannot be told from a reporter who is seeing seams everywhere, or from
;;;     panel non-uniformity being read as a step.
;;;   * a row split BLACK against FULL -- it must show an OBVIOUS seam.  Without it, "no seam"
;;;     cannot be told from a pattern that never drew: a blank screen answers "no seam" to every
;;;     question you ask it, and answers it confidently.
;;; Read the controls FIRST.  If either one disagrees with what it was built to say, the run tells
;;; you nothing about the panel and the instrument is what needs fixing.
;;;
;;; IT DRAWS WITH `lcd-box`, NOT THROUGH LVGL, DELIBERATELY.  `lcd-box` puts an exact RGB565 value
;;; into the panel's framebuffer.  Anything drawn through LVGL has been through a renderer that may
;;; blend, scale or dither, and a test that cannot say whether it is measuring the panel or the
;;; renderer is not a test of the panel.

;;; --- colour construction ---------------------------------------------------------------------
;;; RGB565: red is bits 15..11 (5 bits), green 10..5 (6), blue 4..0 (5).  Built by multiplication
;;; rather than shifts so this file needs no bitwise ops.
(define (ct-c r g b) (+ (* r 2048) (* g 32) b))

(define (ct-pow2 k) (let loop ((i 0) (v 1)) (if (>= i k) v (loop (+ i 1) (* v 2)))))

;;; Channels are 0 = red, 1 = green, 2 = blue.  A test patch lights ONE channel and leaves the
;;; others at zero: a step in a grey patch could be any channel's, which is the question we are
;;; asking, so greys cannot be the instrument.
(define (ct-chan ch v)
  (cond ((= ch 0) (ct-c v 0 0))
        ((= ch 1) (ct-c 0 v 0))
        (else     (ct-c 0 0 v))))

(define (ct-name ch) (cond ((= ch 0) "RED") ((= ch 1) "GREEN") (else "BLUE")))
(define (ct-nbits ch) (if (= ch 1) 6 5))            ;;;!< green gets 6 bits in RGB565
(define (ct-full ch) (- (ct-pow2 (ct-nbits ch)) 1))

;;; The base value every bit test is perturbed from.  Mid-scale with alternating bits, so no single
;;; bit dominates and the patch sits where the eye discriminates best -- a bit tested against black
;;; or against full scale is testing the panel's endpoints, not that bit.
(define (ct-mid ch) (if (= ch 1) 21 10))            ;;;!< 010101 / 01010

(define (ct-bit? v k) (odd? (quotient v (ct-pow2 k))))
(define (ct-set v k)  (if (ct-bit? v k) v (+ v (ct-pow2 k))))
(define (ct-clr v k)  (if (ct-bit? v k) (- v (ct-pow2 k)) v))

;;; --- pattern 1: WHICH BITS REACH THE GLASS ----------------------------------------------------
;;; One row per bit.  Left half has the bit CLEAR, right half has it SET, everything else equal --
;;; so the two halves differ by exactly one bit and nothing else.  A bit that reaches the panel
;;; shows a seam down the middle; a bit that does not produces a row of one flat colour.
;;;
;;; This answers a sharper question than "how many levels": it says WHICH bit is missing.  A
;;; dropped LSB and a dropped middle bit both reduce the level count, and they are different
;;; faults with different causes -- one is a wiring choice, the other is a fault.
(define (ct-bits ch)
  (lcd-clear 0)
  (let* ((nb   (ct-nbits ch))
         (rows (+ nb 2))                            ;;;!< nb bit rows + 2 controls
         (h    (quotient 480 rows))
         (m    (ct-mid ch)))
    ;; ROW 1 -- CONTROL, MUST SHOW AN OBVIOUS SEAM.  Proves the pattern drew at all.
    (lcd-box 0 0 240 (- h 2) (ct-chan ch 0))
    (lcd-box 240 0 240 (- h 2) (ct-chan ch (ct-full ch)))
    ;; ROWS 2..nb+1 -- one per bit, most significant first.
    (let loop ((i 1))
      (if (<= i nb)
          (begin
            (let* ((k (- nb i))
                   (y (* i h)))
              (lcd-box 0   y 240 (- h 2) (ct-chan ch (ct-clr m k)))
              (lcd-box 240 y 240 (- h 2) (ct-chan ch (ct-set m k))))
            (loop (+ i 1)))
          #f))
    ;; LAST ROW -- CONTROL, MUST SHOW NO SEAM.  Proves "no seam" is reportable.
    (let ((y (* (+ nb 1) h)))
      (lcd-box 0   y 240 (- h 2) (ct-chan ch m))
      (lcd-box 240 y 240 (- h 2) (ct-chan ch m)))
    (list (ct-name ch) 'rows rows 'row-height h 'bits-tested nb
          'top-row 'CONTROL-must-split 'bottom-row 'CONTROL-must-not-split)))

;;; --- pattern 0: THE PRIMARIES AND SECONDARIES, FULL AND HALF ----------------------------------
;;; Six bars: red, green, blue, cyan, yellow, magenta -- then the same six at half scale.
;;;
;;; THIS IS THE PATTERN THAT CATCHES A WHOLE-CHANNEL FAULT, and it catches it faster than any bit
;;; test because each secondary is built from exactly two primaries.  A channel that is dead, weak
;;; or swapped cannot hide: lose red and yellow collapses toward green while magenta collapses
;;; toward blue, and the two failures point at the same missing channel from opposite directions.
;;; A red/blue swap leaves all six bars present and merely reorders them, which a single-primary
;;; test cannot see at all.
;;;
;;; THE HALF-SCALE ROW IS THE PART THAT EARNS ITS SPACE.  Full-scale bars only ever exercise the
;;; endpoints, where every channel is at 0 or at maximum and a missing low-order bit changes
;;; nothing.  Repeating them at half scale puts every channel in the middle of its range, where a
;;; lost bit or a non-linearity actually moves the colour -- so a hue that is correct on top and
;;; wrong underneath says the fault is in the CODING, not in the wiring of a whole channel.
(define (ct-rgbcym)
  (lcd-clear 0)
  (let ((full (list (ct-c 31 0 0) (ct-c 0 63 0) (ct-c 0 0 31)
                    (ct-c 0 63 31) (ct-c 31 63 0) (ct-c 31 0 31)))
        (half (list (ct-c 15 0 0) (ct-c 0 31 0) (ct-c 0 0 15)
                    (ct-c 0 31 15) (ct-c 15 31 0) (ct-c 15 0 15)))
        (w 80))
    (let loop ((i 0) (f full) (h half))
      (if (pair? f)
          (begin (lcd-box (* i w)   0 w 236 (car f))
                 (lcd-box (* i w) 244 w 236 (car h))
                 (loop (+ i 1) (cdr f) (cdr h)))
          #f))
    (list 'order '(red green blue cyan yellow magenta)
          'top 'full-scale 'bottom 'half-scale 'bar-width w)))

;;; --- pattern 1b: IS THE ARTEFACT AT AN EDGE, AND DOES IT DEPEND ON THE TRANSITION? ------------
;;; Six rows, each split left/right, and EVERY SPLIT IS AT THE SAME X.  That is the control, and it
;;; is the whole design: an artefact that appears in some rows and not others is caused by the
;;; COLOUR TRANSITION, while one that appears in all six alike is POSITIONAL -- a DMA burst
;;; boundary, a bounce-buffer seam, a memory alignment -- and those two have nothing in common
;;; except where they land on the glass.
;;;
;;; Row 3 is the pivot.  It moves ONE channel; rows 4-6 move two in OPPOSITE directions.  If row 3
;;; is clean while 4-6 fringe, the fault is one channel changing late or early RELATIVE TO ANOTHER,
;;; which is a setup/hold problem on the data bus rather than anything about colour depth.  A
;;; bright edge in a camera image is the same kind of transition, so that result would also explain
;;; coloured fringing around highlights in a photograph -- one mechanism, two symptoms that look
;;; unrelated.
;;;
;;; OBSERVED 2026-09-28 BEFORE THIS PATTERN EXISTED, which is why it exists: a white column between
;;; yellow and magenta, and an overlap between cyan and yellow.  The framebuffer was then read
;;; pixel by pixel across that boundary and holds 65504,65504,65504 | 63519,63519,63519 -- the
;;; exact intended values, with no white pixel anywhere in the data.  So the column is created
;;; DOWNSTREAM of the framebuffer.  Read the buffer before blaming the panel, and blame the panel
;;; only after the buffer says it is innocent.
(define (ct-edges)
  (lcd-clear 0)
  (let ((pairs (list (cons 0 65535)         ;;;!< all three rise
                     (cons 65535 0)         ;;;!< all three fall
                     (cons 0 63488)         ;;;!< red alone -- THE PIVOT
                     (cons 65504 63519)     ;;;!< yellow -> magenta: green falls, blue rises
                     (cons 2047 65504)      ;;;!< cyan -> yellow: red rises, blue falls
                     (cons 2016 31))))      ;;;!< green -> blue: green falls, blue rises
    (let loop ((i 0) (p pairs))
      (if (pair? p)
          (begin (lcd-box 0   (* i 80) 240 76 (car (car p)))
                 (lcd-box 240 (* i 80) 240 76 (cdr (car p)))
                 (loop (+ i 1) (cdr p)))
          #f))
    (list 'edges 'boundary-x 240 'rows 6 'pivot-row 3)))

;;; Read the framebuffer ACROSS a boundary, which is the control that says whether an artefact is
;;; in the data or after it.  A column on the glass with clean pixels here is not ours.
(define (ct-scan y x0 x1)
  (let loop ((x x0) (acc (list)))
    (if (> x x1)
        (reverse acc)
        (loop (+ x 1) (cons (list x (lvgl-fb-pixel x y)) acc)))))

;;; --- pattern 2: HOW MANY LEVELS SURVIVE -------------------------------------------------------
;;; Every code value the channel has, as a vertical bar, in order.  Count the bands: if the count
;;; matches the bar count the channel is intact, and if bars merge in PAIRS the low bit is gone.
;;; Where they merge matters as much as how many -- merging only at the dark end is a gamma or
;;; backlight floor, not a lost bit.
(define (ct-ramp ch)
  (lcd-clear 0)
  (let* ((n (+ (ct-full ch) 1))
         (w (quotient 480 n)))
    (let loop ((v 0))
      (if (< v n)
          (begin (lcd-box (* v w) 60 w 360 (ct-chan ch v))
                 (loop (+ v 1)))
          #f))
    (list (ct-name ch) 'bars n 'bar-width w)))

;;; --- pattern 3: DO THE CHANNELS TRACK EACH OTHER ----------------------------------------------
;;; A grey ramp built so all three channels step together.  Green has one more bit than red and
;;; blue, so a grey built by stepping all three at once cannot stay neutral -- any TINT that
;;; appears says the channels are losing precision at different rates, and the direction of the
;;; tint names which channel is short.
(define (ct-grey)
  (lcd-clear 0)
  (let* ((n 32) (w (quotient 480 n)))
    (let loop ((v 0))
      (if (< v n)
          (begin (lcd-box (* v w) 60 w 360 (ct-c v (* v 2) v))
                 (loop (+ v 1)))
          #f))
    (list 'grey 'bars n 'bar-width w)))

;;; --- framebuffer read-back: separates "the panel cannot show it" from "we never wrote it" ------
;;; Reads the value actually sitting in the framebuffer at a point, so a row that looks flat can be
;;; checked for having been written with two different values in the first place.  This CANNOT see
;;; what the glass does -- the loss is downstream of here -- and that limit is the whole reason the
;;; eye is still the sensor.  Returns (X Y VALUE-OR-RC) per the underlying call.
(define (ct-probe x y) (list x y (lvgl-fb-pixel-dma x y)))

(syslog "panel-colortest: (ct-bits CH) (ct-ramp CH) (ct-grey) -- CH 0=red 1=green 2=blue\n")
