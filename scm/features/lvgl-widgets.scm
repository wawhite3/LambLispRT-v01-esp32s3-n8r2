;;; Copyright 2026 by Frobenius Norm LLC 2026-09-24
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; lvgl-widgets.scm -- the WIDGET layer, composed entirely from the thin LVGL shim.
;;;
;;; THREE LAYERS, AND THIS IS THE MIDDLE ONE.
;;;
;;;   shim     `lv-label-create`, `lv-obj-set-pos`, ...  one LVGL call each, no defaults
;;;   widgets  THIS FILE -- a readout, a gauge: a thing with a place, a colour and a way to
;;;            be updated.  Still says nothing about what is being displayed.
;;;   layout   which widgets exist, where they sit, and what they mean (see demos/hud-panel.scm)
;;;
;;; Keeping the middle layer in Scheme is the point.  A widget is a handful of shim calls in a
;;; fixed order; expressing that in C++ would mean a mop, a rebuild and a reflash for every
;;; arrangement anyone wants to try, and the arrangement is the part that changes most often.
;;; Here it is a file that pushes over LLIP in seconds and can be re-evaluated on a running board.
;;;
;;; A WIDGET IS ITS HANDLE.  These procedures return the integer handle the shim gave them rather
;;; than wrapping it in a record: the handle is already the identity, and a wrapper would add a
;;; layer of indirection whose only job is to be unwrapped again.  The cost is that a handle does
;;; not say which KIND of widget it is -- calling `gauge-set!` on a readout does nothing rather
;;; than raising -- so the layout layer is responsible for keeping them straight.

(syslog "Loading LVGL widgets\n")

;;; (make-readout SCREEN X Y COLOUR [TEXT]) -> handle
;;; A line of text at a fixed place: a label with a position and a colour, nothing more.
;;; The initial text matters more than it looks.  A readout created empty is indistinguishable
;;; from one whose source has never reported, so it is given a visible placeholder and the caller
;;; can pass its own.  "--" is the convention in this tree for "nothing has been said yet".
(define (make-readout screen x y colour . rest)
  (let ((h (lv-label-create screen))
        (txt (if (pair? rest) (car rest) "--")))
    (and h
         (begin
           (lv-label-set-text h txt)
           (lv-obj-set-style-text-color h colour)
           (lv-obj-set-pos h x y)
           h))))

;;; (readout-set! HANDLE TEXT) -> #t/#f  (#f only when HANDLE is #f)
;;; Invalidate explicitly rather than relying on the text change to do it: the shim does exactly
;;; what it is told, which is the property that makes it a shim.
;;;
;;; BUT DO NOT REPAINT A WIDGET WHOSE TEXT DID NOT CHANGE.  This used to invalidate on EVERY call,
;;; and a caller that refreshes on a timer calls it whether or not the value moved.  On this panel
;;; the RGB scan runs continuously out of the framebuffer, so an unnecessary repaint is not merely
;;; wasted work -- it is VISIBLE, as flicker on a field that is displaying a constant.  Measured
;;; 2026-09-26: the clock is refreshed ~10x/s (`aitrip-status-every` 20 ticks at ~200 ticks/s) and
;;; its text changes once per second, so NINE OUT OF TEN of its repaints redrew the identical
;;; string.  Comparing first removes those and costs one string compare.
;;;
;;; The skip is invisible to callers by design: this still answers #t, because the widget does now
;;; show TEXT -- which is the question the caller asked.  Returning #f for "already correct" would
;;; read as failure at every call site.  `readout-writes` counts the repaints that actually
;;; happened, so the two cases can be told apart mechanically by a test rather than by eye.
(define readout-last (list))   ;;;!< alist HANDLE -> the text last written to it
(define readout-writes 0)      ;;;!< repaints actually issued; a test reads this to see the skip

(define (readout-set! h text)
  (and h
       (let ((prev (assoc h readout-last)))
         (if (and prev (string=? (cdr prev) text))
             #t                                    ;;; already showing it: no write, no repaint
             (begin
               (lv-label-set-text h text)
               (lv-obj-invalidate h)
               (set! readout-writes (+ readout-writes 1))
               (if prev
                   (set-cdr! prev text)
                   (set! readout-last (cons (cons h text) readout-last)))
               #t)))))

;;; (make-gauge SCREEN X Y W H LO HI COLOUR) -> handle
;;; A bar with a range.  It is created EMPTY -- at LO, not at some mid-scale value that would look
;;; like a reading.  A gauge showing a plausible number it was never given is the worst thing a
;;; HUD can do, because an operator cannot tell it from a real one.
;;; A BAR HAS TWO PARTS AND BOTH MUST BE STYLED, OR IT COMES OUT TWO-TONE.
;;; `lv-obj-set-style-bg-color` takes PART: 0 = MAIN (the track behind the fill), 1 = INDICATOR
;;; (the fill itself).  Styling only the indicator leaves the track at LVGL's stock colour, so the
;;; gauge renders in our palette AND in a default that belongs to no palette -- which reads as a
;;; rendering fault rather than as a missing style.  Observed on the panel 2026-09-25.
;;; TRACK is optional so the widget layer keeps a sane default without the caller having to know
;;; about parts; the layout passes its own so the gauge matches the rest of the HUD.
(define (make-gauge screen x y w h lo hi colour . rest)
  (let ((g     (lv-bar-create screen))
        (track (if (pair? rest) (car rest) #x2C2C34)))   ;; dark slate; R,B are 4 mod 8 -- see below
    (and g
         (begin
           (lv-obj-set-size g w h)
           (lv-bar-set-range g lo hi)
           (lv-bar-set-value g lo)
           (lv-obj-set-style-bg-color g track  0)   ;; 0 = MAIN: the track
           (lv-obj-set-style-bg-color g colour 1)   ;; 1 = INDICATOR: the fill
           (lv-obj-set-pos g x y)
           g))))

;;; (gauge-set! HANDLE N) -> #t/#f.  LVGL clamps N to the range the gauge was made with.
(define (gauge-set! h n)
  (and h
       (begin (lv-bar-set-value h n)
              (lv-obj-invalidate h)
              #t)))

(syslog "LVGL widgets loaded\n")
