;;; Copyright 2026 by Frobenius Norm LLC 2026-07-02
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; ESP32-S3-EYE camera + LCD demo glue -- P136 Phase 2.
;;;
;;; Portable one-liners over the C++ EyeCam binding (ll_xmop3_EyeCam.cpp), which
;;; drives the OV2640 camera (esp_camera) and the ST7789 240x240 IPS LCD (esp_lcd).
;;; The pixel hot-paths live in C++; this file is just the demo choreography.
;;;
;;; API (from the C++ binding):
;;;   (lcd-init)                 -> #t     ;; bring up SPI3 + ST7789 + backlight
;;;   (lcd-clear [rgb565])       -> void   ;; clear screen (default black)
;;;   (lcd-box x y w h rgb565)   -> void   ;; filled rectangle
;;;   (lcd-rgb565! bv x y w h)   -> void   ;; blit a big-endian RGB565 region
;;;   (camera-init ['rgb565|'jpeg]) -> #t/#f
;;;   (camera->lcd)              -> #t/#f  ;; grab one frame + blit (hot path)
;;;   (camera-preview [n])       -> n      ;; live preview, n frames (default 300)
;;;   (camera-set key val)       -> void   ;; framesize/brightness/contrast/hmirror/vflip/special-effect
;;;   (camera-capture)           -> bytevector  ;; one JPEG frame (needs 'jpeg init)
;;;   (frame-brightness)         -> integer 0..255  ;; mean luma, for trigger demos
(info "Loading eye-cam demo\n")

;; RGB565 colour constants (5-6-5 bit packing).
(define red   63488)   ;;;!< #b11111000000_00000
(define green 2016)    ;;;!< #b00000_111111_00000
(define blue  31)      ;;;!< #b00000_000000_11111
(define black 0)
(define white 65535)

;; This eye is physically mounted upside-down (180 deg) in the lab rig, so every camera bring-up
;; corrects the orientation at the sensor (vflip + hmirror).  Adjust here if the mount changes.
(define (eye-orient!)
  (camera-set 'vflip 1)
  (camera-set 'hmirror 1))

;; Bring up the LCD and camera, then run the live preview.  The one-liner demo.
(define (eye-preview)
  (lcd-init)
  (camera-init)
  (eye-orient!)
  (camera-preview))

;; Flash a red/green/blue/white colour splash on the LCD to prove the panel is
;; alive, then hand over to the live camera preview.
(define (eye-demo)
  (lcd-init)
  (for-each (lambda (c) (lcd-clear c) (delay-ms 400))
            (list red green blue white black))
  (camera-init)
  (eye-orient!)
  (camera-preview))

;;; ---------------------------------------------------------------------------
;;; Eye application layer -- the eye's OWN main loop.
;;;
;;; The S3-EYE is its own thing: no sonar, no motors, no LED strip.  So instead of running the
;;; shared robot loop (which ticks Sonar.loop / guard-dog / Motor.loop / Led.loop), the eye installs
;;; its OWN loop via setup.scm's `app-loop` hook -- doing exactly the eye's work: blit the live camera
;;; frame when enabled, then donate spare time to the incremental GC (same budget knobs as the shared
;;; loop).  No robot ticks, no fake stubs.  (camera-preview is a FINITE blocking loop that freezes on
;;; its last frame; the app-loop keeps the panel live while the REPL stays responsive.)
;;;   (eye-live-start) -> 'live     ;; init LCD+camera once, then blit every loop tick
;;;   (eye-live-stop)  -> 'stopped  ;; freeze on the current frame (loop keeps running, just no blit)
(define eye-live? #f)

(define (eye-live-start)
  (lcd-init)
  (camera-init)
  (eye-orient!)
  (set! eye-live? #t)
  'live)

(define (eye-live-stop)
  (set! eye-live? #f)
  'stopped)

;; The eye's main-loop MAKER: a thunk that builds and returns the loop.  The eye's TARGET SETUP
;; (setup-esp32-s3-eye.scm) installs it with (set! app-loop eye-make-loop); setup.scm calls it once
;; at loop-definition time (after loop-target-ms / loop-deadline-ms exist) and uses the returned loop
;; in place of the robot loop.  This file is a pure FEATURE -- it defines capabilities, no wiring.
(define (eye-make-loop)
  (letrec* ((me      "(eye-loop)")
            (started #f)
            (hist    (make-vector 100 0))
            (t_loop  (Stopwatch_ms))
            (idler   (make-idler loop-target-ms 10000 15000)))
    (lambda ()
      (unless started        ;; auto-start the live preview on the FIRST loop tick -- this is safely
        (set! started #t)    ;; AFTER setup.scm has finished reading files from flash (running
        (eye-live-start))    ;; camera-init mid-boot crashes on camera-DMA vs flash-cache contention).
      (when eye-live? (camera->lcd))
      ;; donate spare time up to the hard deadline to the incremental GC (keeps the collector healthy)
      (let* ((elapsed  (t_loop))
             (spare-us (* 1000 (- loop-deadline-ms elapsed))))
        (if (>=i elapsed 100) (set! elapsed 99))
        (vector-set! hist elapsed (+i 1 (vector-ref hist elapsed)))
        (if (idler) (news "~a (loop-stats ~a)\n" me (vector->sparsevec hist 0)))
        (when (> spare-us 0) (Platform.gc-idle-task! spare-us)))
      (set! t_loop (Stopwatch_ms)))))
