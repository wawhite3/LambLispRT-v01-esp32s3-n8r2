;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "WS2812 loading start\n")

(define have-WS2812-code (dict-ref? (current-environment) 'WS2812.begin))
(define have-WS2812-pin (dict-ref? Pins 'pin-WS2812))
(define have-WS2812 (and have-WS2812-code have-WS2812-pin))

(syslog "WS2812 code ~a pin ~a\n" have-WS2812-code have-WS2812-pin)

(define pin-WS2812 (if have-WS2812 (cdr have-WS2812-pin) #f))

(define ws2812-info (2list->obj '(
				   (TYPE_RGB #x06)  ;00 01 10
				   (TYPE_RBG #x09)  ;00 10 01
				   (TYPE_GRB #x12)  ;01 00 10
				   (TYPE_GBR #x21)  ;10 00 01
				   (TYPE_BRG #x18)  ;01 10 00
				   (TYPE_BGR #x24)  ;10 01 00
				   (pin-WS2812   #f)
				   (Nleds        12)
				   (ledchan      0)
				   (ledtype      #x12)
				   )
				 )
  )

(define rgb-colors (2list->obj '(
				 (rgb-black   (  0   0   0))
				 (rgb-red     (255   0   0))
				 (rgb-green   (  0 255   0))
				 (rgb-blue    (  0   0 255))
				 (rgb-cyan    (  0 128 128))
				 (rgb-yellow  (255 255   0))
				 (rgb-magenta (255   0 255))
				 (rgb-white   (255 255 255))
				 )
			       )
  )

(if have-WS2812 (ws2812-info 'pin-WS2812 (cdr have-WS2812))
    (begin
      (define WS2812.begin  Lambda0)
      (define WS2812.show   Lambda0)
      (define WS2812.setBrightness Lambda0)
      (define WS2812.setLedColorData Lambda0)
      )
    )

(news "WS2812.begin success ==> ~a\n"
      (WS2812.begin
       (ws2812-info 'Nleds)
       (ws2812-info 'pin-WS2812)
       (ws2812-info 'ledchan)
       (ws2812-info 'ledtype)
       )
      )


(WS2812.setBrightness 100)

(define (WS2812.setAll r g b)
  (letrec ((maxled (ws2812-info 'Nleds))
	   (fn (lambda (nled)
		 (WS2812.setLedColorData nled r g b)
		 (if (< nled maxled) (fn (+ nled 1)))
		 )
	       )
	   )
    (fn 0)
    (WS2812.show)
    )
  )

(define (WS2812.off) (WS2812.setAll 0 0 0))

(define (WS2812.set index r g b)
  (WS2812.setLedColorData index r g b)
  (WS2812.show)
  )

(define (WS2812.setColor n rgb-color)
  (apply WS2812.set (cons n (rgb-colors rgb-color)))
  )

;; Queued startup self-test (7 slots): flash ALL LEDs red -> green -> blue (250ms each),
;; then off.  Non-blocking, plays over Led.loop.  (Kept small while the per-LED-walk hang
;; -- ~100 slots wedging the boot -- is still under investigation; NOT the Queue append.)
(define (WS2812.test)
  (behavior-queue-seq led-bq
    (lambda () (WS2812.setAll 255 0 0) #t) (wait 250)
    (lambda () (WS2812.setAll 0 255 0) #t) (wait 250)
    (lambda () (WS2812.setAll 0 0 255) #t) (wait 250)
    (lambda () (WS2812.setAll 0 0 0)   #t)))

(define (WS2812.navLights)
  (WS2812.setAll 0 0 0)
  ;;port side red, starboard side green
  ;;middle lights white aft and forward
  (WS2812.setColor  0 'rgb-red)
  (WS2812.setColor 11 'rgb-red)
  (WS2812.setColor  5 'rgb-green)
  (WS2812.setColor  6 'rgb-green)

  (WS2812.setColor  2 'rgb-white)
  (WS2812.setColor  3 'rgb-white)
  (WS2812.setColor  8 'rgb-white)
  (WS2812.setColor  9 'rgb-white)
)


;;; LED behaviour queue (P123 Ph2) -- replaces the bespoke led-queue (TimedQueue).
;;; CORE: shared by the basic Led.blink* helpers below and, where staged, the A2
;;; LED ring service (Leds.scm) + its priority arbiter.  Ticked by Led.loop.
(define led-bq (make-behavior-queue))

;; Queued, non-blocking startup indications (led-bq now exists): the per-LED RGB
;; self-test, then nav-lights held 1s, then clear.  All play over the main loop.
(when have-WS2812
  (WS2812.test)
  (behavior-queue-seq led-bq
    (lambda () (WS2812.navLights) #t)
    (wait 1000)
    (lambda () (WS2812.setAll 0 0 0) #t)))

;;!Blink LED `nled` once: on for on-time ms in `color`, then off for off-time ms.
(define (Led.blinkOnce nled color on-time off-time)
  (when (> on-time  0) (led-bq 'push (once-for on-time  (lambda () (WS2812.setColor nled color)))))
  (when (> off-time 0) (led-bq 'push (once-for off-time (lambda () (WS2812.setColor nled 'rgb-black))))))

;;!Blink the whole ring once: on for on-time ms in `color`, then off for off-time ms.
(define (Led.blinkAll color on-time off-time)
  (when (> on-time  0) (led-bq 'push (once-for on-time  (lambda () (apply WS2812.setAll (rgb-colors color))))))
  (when (> off-time 0) (led-bq 'push (once-for off-time (lambda () (apply WS2812.setAll (rgb-colors 'rgb-black)))))))

;;!Tick the LED queue; call once per main-loop iteration.
(define (Led.loop) (led-bq 'tick))

(syslog "WS2812 Loaded\n")
