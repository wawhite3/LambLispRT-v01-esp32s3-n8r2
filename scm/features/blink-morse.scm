;;; blink-morse.scm -- Morse test patterns for identifying which lamp a pin actually drives.
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-17 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; WHY MORSE AND NOT A PLAIN BLINK.  Identifying an unknown lamp means telling it apart from
;;; whatever else on the board is already flashing -- on the 4WD the CH340 activity LED flickers
;;; constantly, which is exactly what made an earlier "is it blinking?" test ambiguous.  A plain
;;; 1 Hz blink is easy to confuse with serial traffic; SOS is not confusable with anything.
;;;
;;; BLOCKING, ON PURPOSE, AND ONLY THIS FILE.  These are bench identification tools driven from the
;;; REPL while nothing else is running -- the operator is watching the board, so the VM has nothing
;;; better to do.  Do NOT call them from the main loop or from a behaviour: sonar-flash.scm is the
;;; non-blocking pattern to copy for anything that runs alongside the robot.
;;;
;;; Standard Morse timing, in dot units: dot 1, dash 3, intra-character gap 1, letter gap 3,
;;; word gap 7.

(define morse-dot-ms 200)

;;; The lamp under test.  Both are optional and independent, so one call can drive a bare GPIO and
;;; the WS2812 ring together -- useful when you do not yet know which one is the lamp you can see.
(define morse-gpio #f)                  ;;;!< plain digital pin, or #f
(define morse-use-ring #t)              ;;;!< also flash the WS2812 ring, if the board has one
(define morse-rgb '(255 0 0))

(define (morse-lamp! on?)
  (if morse-gpio (digitalWrite morse-gpio (if on? 1 0)))
  (if (and morse-use-ring have-WS2812)
      (if on?
          (WS2812.setAll (car morse-rgb) (cadr morse-rgb) (caddr morse-rgb))
          (WS2812.off))))

(define (morse-gpio! pin)
  (set! morse-gpio pin)
  (if pin (pinMode pin 1))              ;;; 1 = OUTPUT
  pin)

(define (morse-mark units)
  (morse-lamp! #t) (delay-ms (* units morse-dot-ms))
  (morse-lamp! #f) (delay-ms morse-dot-ms))          ;;; trailing intra-character gap

(define (morse-dot)  (morse-mark 1))
(define (morse-dash) (morse-mark 3))

;;; letter gap is 3 units total; morse-mark already emitted 1, so add 2
(define (morse-letter-gap) (delay-ms (* 2 morse-dot-ms)))
;;; word gap is 7 units total; add 6 beyond the mark's trailing 1
(define (morse-word-gap)   (delay-ms (* 6 morse-dot-ms)))

(define (morse-S) (morse-dot)  (morse-dot)  (morse-dot))
(define (morse-O) (morse-dash) (morse-dash) (morse-dash))

;;; (morse-sos n) -- send SOS n times.  Leaves the lamp OFF and the GPIO back to INPUT, so a pin
;;; that turned out NOT to be a lamp is not left driven.
(define (morse-sos n)
  (let loop ((i 0))
    (if (< i n)
        (begin
          (morse-S) (morse-letter-gap)
          (morse-O) (morse-letter-gap)
          (morse-S) (morse-word-gap)
          (loop (+ i 1)))))
  (morse-lamp! #f)
  (if morse-gpio (pinMode morse-gpio 0))              ;;; 0 = INPUT: stop driving an unknown pin
  (display "RESULT morse=SOS reps=") (display n)
  (display " gpio=") (display morse-gpio)
  (display " ring=") (display (and morse-use-ring have-WS2812))
  (display " dot_ms=") (display morse-dot-ms)
  (newline))
