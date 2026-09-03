;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "LambLisp has control\n")

(load "Compiler.scm" 0)

;;; B200: these three used to fingerprint the dialect by WHAT `(if #f #t)` RETURNS.  Never do that.
;;; R7RS makes a one-armed `if` with a false test UNSPECIFIED, so the probe read a value every
;;; implementation is free to change -- and B192 changed LambLisp's from `#f` to a proper
;;; unspecified object, because `#f` is Scheme's only FALSE value and an unspecified result must
;;; not act as a NO.  The fingerprint then inverted: `LambLisp?` went #f, and `ChezScheme?` went #t
;;; (both `(if #f #t)` and `(printf "")` are now void, so the eqv? succeeded), so every startup on
;;; every target tried to `(load "Chez.scm")` -- a file that exists nowhere in the tree.
;;; This file cannot run under another Scheme in any case: line 3 calls `syslog` and the board
;;; tests below use `lamb-board`, both LambLisp-only, and both run BEFORE any adapter could load.
;;; So state the dialect positively instead of deducing it from a value nobody guarantees.
(define LambLisp?   #t)
(define TinyScheme? #f)
(define ChezScheme? #f)

(define linux?
  (or (string=? lamb-board "linux_x86_64")
      (string=? lamb-board "linux_aarch64")
      (string=? lamb-board "linux_x86_64_cuda")
      (string=? lamb-board "linux_aarch64_cuda")))

(define esp32?
  (or (string=? lamb-board "esp32-s3-devkitc-1")
      (string=? lamb-board "esp32s3-n8r2")
      (string=? lamb-board "Freenove-4WD-Car-Kit-ESP32")))

(define jetson?
  (or (string=? lamb-board "linux_aarch64")
      (string=? lamb-board "linux_aarch64_cuda")))

(if ChezScheme? (load "Chez.scm"))	;some adapters for testing


(define Lambda0 (lambda x nil))
;; B75: fallback stub for builds WITHOUT the C++ analogRead mop (e.g. linux).  Must NOT clobber
;; the real primitive on ESP32 -- keep the existing binding when analogRead is already installed.
(define analogRead
  (if (dict-ref? (current-environment) 'analogRead) analogRead (lambda x 0)))

;;; P123 robot stack: safe no-op queue ticks; overridden when Leds.scm (A2) /
;;; llip-executor.scm (B3) are staged for this target.  Keeps the shared (loop)
;;; valid on builds that don't carry the robot stack.
;;; B5 reactive layer is 4WD-only; these no-op fallbacks keep the shared (loop)
;;; and the executor valid on targets that don't stage llip-reactive.scm.
(define (reactive-tick!)     #f) ;; overridden by llip-reactive.scm; called in the shared loop
(define (llip-feed-deadman!) #f) ;; overridden by llip-reactive.scm

(load "Terminal.scm" 0)
(load "rxrs.scm" 0)
(load "rxrs_cxr.scm" 0)           ;;; R5RS cXXXr / cXXXXr accessor compositions
(load "rxrs_exceptions.scm" 0)    ;;; R7RS error objects + guard
(load "rxrs_promises.scm" 0)      ;;; R5RS/R7RS delay / force / promise?
(load "rxrs_quasiquote.scm" 0)    ;;; quasiquote as a code-generating macro
(load "rxrs_syntax.scm" 0)        ;;; when unless case letrec letrec* let-values etc.
(load "Lobs.scm")
(load "Behaviors.scm" 0)   ;; P123 A1 cooperative behaviour queue -- CORE infra: the Motor/LED/
;; Buzzer drivers and the LLIP executor are all consumers, so it must
;; load before them.

(define most-positive-fixnum  2147483647)   ;; max T_INT on ESP32 (int32)
(define most-negative-fixnum -2147483648)

;; Board-specific configuration: load <board-name>.scm if it exists
(let ((board-scm (string-append lamb-board ".scm")))
  (when (file-exists? board-scm)
    (load board-scm 0)))

;;; P6: Load runtime settings (n_initial_blocks, extension_block_size, gc params, etc.)
(define Settings '())
(when (file-exists? "Settings.scm")
  (let ((port (open-input-file "Settings.scm")))
    (set! Settings (read port))
    (close-input-port port))
  (unless (pair? Settings) (set! Settings '())))


;;; Settings-local.scm -- OPTIONAL, UNTRACKED overlay read straight after Settings.scm.
;;; Bench WiFi credentials live here rather than in Settings.scm, because Settings.scm is tracked
;;; AND rides data/ into the per-target customer packages that `w3 make publish_one` force-pushes
;;; to PUBLIC GitHub repos -- an SSID and password typed into Settings.scm gets published on the
;;; next release.  This name is .gitignore'd, manifests pull it with `optional:` so its absence is
;;; silent, and w3_make_release_one deletes it from the package.  See Settings-local.scm.example.
;;; Its keys override Settings.scm; everything it does not mention is left alone.  Prepending is
;;; enough to override, because `setting` uses assq and takes the FIRST match.
(when (file-exists? "Settings-local.scm")
  (let ((port (open-input-file "Settings-local.scm")))
    (let ((local (read port)))
      (close-input-port port)
      (when (pair? local) (set! Settings (append local Settings))))))

(define (setting key default)
  (let ((p (assq key Settings))) (if p (cdr p) default)))

(Platform.extension-block-size! (setting 'extension_block_size 4096))
(Platform.expand-to-n-blocks!   (setting 'n_initial_blocks 1))
(Platform.gc-budget-ns!         (setting 'gc_budget_ns 25000))
(Platform.gcload-target-pct!    (setting 'gcload_target_pct 50))
(Platform.max-cell-blocks!      (setting 'max_cell_blocks 64))
(Platform.verbosity!            (setting 'verbosity 0))

(load "Pins.scm" 0)
(load "Timers.scm" 0)

;;(load "Neopixel.scm" 0)
(load "ESP32.scm" 0)
(load "CommonIO.scm" 0)
(load "Buzzer.scm" 0)
;; Sonar / I2C / motor-bus peripherals are per-target -- the S3-EYE stages none of them (no sonar,
;; and GPIO13/14 are not a real I2C bus, so I2C.inventory would be 128 x 1s bus-timeouts).  Guard
;; each load with file-exists? so an omitted file is simply absent.
;;
;; app-loop: a target's application layer (loaded below) may install its OWN main loop here.  The
;; default (loop) further down runs it when set, otherwise builds the robot loop (sonar/motor/led
;; ticks).  So a target without robot hardware (the S3-EYE: no sonar/motors) provides its own loop
;; and never references Sonar.loop / Motor.loop -- no fake stubs required.
(define app-loop #f)
(when (file-exists? "Sonar.scm")   (load "Sonar.scm" 0))
(load "WiFi.scm" 0)
(when (file-exists? "I2C.scm")     (load "I2C.scm" 0))
(when (file-exists? "Wire.scm")    (load "Wire.scm" 0))
(when (file-exists? "PCA9685.scm") (load "PCA9685.scm" 0))
(when (file-exists? "PCF8574.scm") (load "PCF8574.scm" 0))
(load "WS2812.scm" 0)
;;; P123 robot stack -- loaded only if staged for this target (per-env manifest);
;;; absence is harmless.  Dependency order: Behaviors -> Leds -> LLIP features.
(when (file-exists? "Leds.scm")         (load "Leds.scm" 0))          ;; A2 LED ring service (needs WS2812; Behaviors loaded above)
(when (file-exists? "llip-frame.scm")   (load "llip-frame.scm" 0))    ;; B2 LLIP framing + validation
(when (file-exists? "llip-signals.scm") (load "llip-signals.scm" 0))  ;; B4 robot LED signal vocabulary
(when (file-exists? "llip-executor.scm")(load "llip-executor.scm" 0)) ;; B3 4WD move DSL executor
(when (file-exists? "llip-reactive.scm")(load "llip-reactive.scm" 0)) ;; B5 reactive layer + safety
(when (file-exists? "llip-serial.scm") (load "llip-serial.scm" 0))  ;; resident receiver for the serial file tunnel
(load "LightSensor.scm" 0)
(when (file-exists? "LCD1602.scm") (load "LCD1602.scm" 0))   ;; I2C char-LCD -- absent on the eye
(when (file-exists? "eye-cam.scm")  (load "eye-cam.scm" 0))   ;; P136 Ph2 camera+ST7789 demo glue (ESP32-S3-EYE only)
(when (file-exists? "Cuda.scm") (load "Cuda.scm"))
(when (file-exists? "rsa.scm")      (load "rsa.scm" 0))
(when (file-exists? "dh_groups.scm") (load "dh_groups.scm" 0))
(when (file-exists? "csv.scm")       (load "csv.scm" 0))       ;; P140 CSV reader/writer
(news "All LambLisp files loaded\n")

;; Per-target APPLICATION setup.  A "target" is now a combo of language / application / hardware,
;; keyed by the pio ENV NAME (= lamb-board, set per-env via -DLL_BOARD_NAME).  Each target may ship
;; a setup-<env>.scm that wires up its own application -- e.g. install its own app-loop (see the
;; app-loop hook above and the (loop) definition below).  Loaded HERE: after every feature and
;; peripheral is defined, and before (loop) is built.  Absence is harmless (default = robot loop).
(let ((target-setup (string-append "setup-" lamb-board ".scm")))
  (when (file-exists? target-setup)
    (news "Loading target setup ~a\n" target-setup)
    (load target-setup 0)))

(load "array.scm" 0)

#|
(load "Tak.scm")
(define (test-tak)
(term "Starting tak\n")
(let* ((t_start (millis))
(res (tak 18 12 6))
(t_end (millis))
(t_elapsed (- t_end t_start))
)
(syslog "T_st ~a T_end ~a T_elapsed ~a res ~a\n" t_start t_end t_elapsed res)
)
)
|#

(define (factorial n)
  (letrec ((fn (lambda (n accum)
		 (if (zero? n) accum
		     (fn (- n 1) (* accum n))
		     )
		 )
	       )
	   )
    (fn n 1)
    )
  )

(define (guard-dog)
  (when (< Sonar.latest 0.100)
    (term "Arf!\n")
    (Buzzer.arf)
    (Led.blinkAll 'rgb-red 5000 1)
    (Motor.motion 1000 1 1 1 1)
    (Motor.motion 100 0 0 0 0)
    (Motor.motion 2000 -0.5 -0.5 -0.5 -0.5)
    (Motor.motion 100 0 0 0 0)
    )
  )

#|
(define incf (nlambda (sym . delta)
(let* ((dt (if (null? delta) 1 (eval (car delta))))
)
(macro () (apply set! `(,sym (+ `,sym `,dt))))
)
)
)
|#
(syslog "free stack is ~a\n" (Platform.free-stack))

;;; P48: bench normalization -- ESP32 only.
;;; Lets lispbm_benchmarks.lisp run on LambLisp with the same names
;;; it uses on LispBM: (systime), (gc), (lbm-heap-state sym).
(when esp32?
  (define systime micros)
  (define (gc) (Platform.gc-idle-task 200000))  ; 200 ms donation -- completes any cycle
  (define (lbm-heap-state sym) 0))              ; stub: GC count not yet exposed (P37)

#|

(let ((test 0)
)
(syslog "incf is ~a\n" incf)
(syslog "(incf test) is ~a\n" (incf test))

(syslog "test is ~a\n" test)
(incf test 5.0)
(syslog "test is ~a\n" test)
(incf test)
(syslog "test is ~a\n" test)
)
(term "30\n")

;;Fibonacci test
(define (fib n)
(if (< n 3) 1
(+ (fib (- n 1)) (fib (- n 2)))
)
)

(syslog "Starting fib mega 2560 claims 30 sec\n")
(syslog "free stack is ~a\n" (Platform.free-stack))
(define t (Stopwatch_ms))
(syslog "~a\n" (fib 23))
(syslog "Finished fib ~a ms\n" (t))
(syslog "free stack is ~a\n" (Platform.free-stack))

;Hofstadter Q sequence			;
(syslog "free stack is ~a\n" (Platform.free-stack))
(define (hofq n)
(syslog "free stack is ~a\n" (Platform.free-stack))
(if (<= n 2) 1
(+
(hofq (- n (hofq (- n 1))))
(hofq (- n (hofq (- n 2))))
)
)
)
(syslog "Starting hofq mega 2560 claims 58 sec\n")
(define t (Stopwatch_ms))
(syslog "~a\n" (hofq 21))
(syslog "Finished hofq ~a ms\n" (t))

(syslog "free stack is ~a\n" (Platform.free-stack))
(define (hofq2 x y)
(syslog "free stack is ~a\n" (Platform.free-stack))
(if (or (< x 1) (< y 1)) 1
(+ (hofq2 (- x (hofq2 (sub1 x) y)) y)
(hofq2 x (- y (hofq2 x (sub1 y))))
)
)
)

(syslog "Starting hofq2 esp32 goal 5.6 sec\n")
(define t (Stopwatch_ms))
(syslog "~a\n" (hofq2 7 8))
(syslog "Finished hofq2 ~a ms\n" (t))
|#

(syslog "Starting click\n")
(Buzzer.click)
(syslog "Finished click\n")

;;;;;;;;
;;;
;;;(loop) start here -- embedded only; on Linux loop is left undefined so Lamb::loop() skips it.
;;;
;;;;;;;;
(define loop-target-ms 3)		;loop budget in ms -- must match idler short threshold
(define loop-deadline-ms (setting 'gc_idle_deadline_ms 10))  ;runtime-settable hard loop ceiling (ms);
					;the GC idle-donation gates on THIS, not the soft target -- set! to retune live

(if linux? #f  ;;; skip loop definition on Linux
    (define loop
      (if app-loop (app-loop)   ;;; a target's app layer may install its own loop-MAKER thunk via app-loop
	  ;; No app-loop installed -> a safe IDLE loop.  There is NO shared robot loop anymore: each
	  ;; target owns its mission (its own scheme files + its own app-loop).  This default only
	  ;; measures the tick and donates spare time to the incremental GC, so an unconfigured board --
	  ;; or the eye before its per-target app-loop applies -- runs CLEAN instead of crashing on
	  ;; unbound robot components (there is currently no sonar/motor stack staged at all).
	  (letrec* ((me "(loop)")
		    (hist (make-vector 100 0))
		    (t_loop (Stopwatch_ms))
		    (idler (make-idler loop-target-ms 10000 15000))
		    )
	    (lambda ()
	      ;;Measure elapsed; donate spare time UP TO loop-deadline-ms (hard ceiling) to GC lookahead.
	      (let* ((elapsed (t_loop))
		     (spare-us (* 1000 (- loop-deadline-ms elapsed))))
		(if (>=i elapsed 100) (set! elapsed 99))
		(vector-set! hist elapsed (+i 1 (vector-ref hist elapsed)))
		(if (idler) (news "~a (loop-stats ~a)\n" me (vector->sparsevec hist 0)))
		(when (> spare-us 0) (Platform.gc-idle-task! spare-us))
		)
	      (set! t_loop (Stopwatch_ms))
	      )
	    ))
      )
    ) ;;; end (if linux? #f (define loop ...))
