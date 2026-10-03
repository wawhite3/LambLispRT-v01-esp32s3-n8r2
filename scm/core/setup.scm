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
(load "rxrs_continuations.scm" 0) ;;; P168 raise-continuable, dynamic-wind, parameters, escape call/cc
(load "rxrs_promises.scm" 0)      ;;; R5RS/R7RS delay / force / promise?
(load "rxrs_quasiquote.scm" 0)    ;;; quasiquote as a code-generating macro
(load "rxrs_syntax.scm" 0)        ;;; when unless case letrec letrec* let-values etc.
(load "rxrs_library.scm" 0)       ;;; P189 R7RS define-library / import (needs syntax-rules, for-each)
(load "rxrs_srfi.scm" 0)          ;;; SRFI 8/2/26/111/145 bundle (receive, and-let*, cut, boxes, assume)
(load "Lobs.scm")
(load "Behaviors.scm" 0)   ;; P123 A1 cooperative behaviour queue -- CORE infra: the Motor/LED/
;; Buzzer drivers and the LLIP executor are all consumers, so it must
;; load before them.

;;; ─────────────────────────────────────────────────────────────────────────────
;;; SAFE STATE (B312) -- AN ESCAPING EXCEPTION MUST NOT LEAVE ACTUATORS RUNNING.
;;;
;;; The hazard is a property of the RUNNING PROGRAM, not of any test.  A motor is commanded and
;;; then stopped by a later form; if anything between the two raises, the stop never runs and the
;;; wheels keep turning while the error propagates.  On the 4WD that means a car driving off a
;;; bench, and the only visible symptom is an error message about something else entirely.
;;;
;;; Fixing this in the TEST HARNESS was the obvious move and the wrong one: it would make the suite
;;; safe and leave every customer application with the identical defect.  The guard belongs where
;;; the actuators are, so a user program gets it without knowing it exists.
;;;
;;; Each driver registers its own stop as it loads, so the set is exactly the hardware present --
;;; a board with no PCA9685 registers no motor stop, and nothing here needs to know which board it
;;; is on.  Registration is deliberately not a list literal maintained in this file: that list
;;; would go stale the first time someone added a driver, and the failure would be silent.
(define *safe-state-thunks* (list))   ;;;!< innermost-last; a GLOBAL, which is the allocation-free
                                      ;;;!< and B205-proof shape for something written by many
                                      ;;;!< closures and read by one.

;;!Register a nullary thunk that puts one subsystem into its safe state.  Called by drivers at load.
(define (register-safe-state! thunk)
  (set! *safe-state-thunks* (cons thunk *safe-state-thunks*)))

;;!Run every registered safe-state thunk.  EACH IS GUARDED SEPARATELY: a driver whose stop itself
;;!throws (an unbound binding on a half-configured board, a bus error on the very fault we are
;;!reacting to) must not prevent the OTHER actuators from being stopped.  That is the whole reason
;;!this is a loop over guarded calls rather than one guard around the lot.
(define (run-safe-state!)
  (let run-next ((ts *safe-state-thunks*))
    (when (pair? ts)
      (guard (e (#t #t))                ;;; deliberately swallowed -- see above
        ((car ts)))
      (run-next (cdr ts)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; DEAD MODE -- WHEN THE VM IS UNFIT TO CONTINUE, HAND THE UNIT TO THE LOADER.
;;;
;;; `run-safe-state!` above answers "an error is propagating, stop the actuators".  This answers
;;; the harder case: the VM cannot usefully continue AT ALL, and something outside it has to take
;;; over.  The factory loader is that something -- it is a separate application in its own
;;; partition, so it is still there when this one is not.
;;;
;;; THE ORDER IS THE WHOLE REQUIREMENT, AND IT IS OUTPUTS FIRST.  A machine whose VM dies with the
;;; motors running does not need a diagnostic; it needs to stop.  So `run-safe-state!` runs before
;;; a single byte is recorded and before the reboot is requested -- and because each registered
;;; thunk is guarded separately, a driver whose own stop throws cannot keep the others from running.
;;;
;;; THE REASON IS REQUIRED AND IS NOT DEFAULTED.  `ota-die!` refuses a reason that is not a symbol
;;; of at most 24 characters from [a-z0-9_-], rather than substituting one: a default would be this
;;; code's opinion about a failure it knows nothing about, recorded as if the application had said
;;; it.  The loader never interprets a reason, only carries it, so an application picks its own
;;; vocabulary and needs no change in the loader to add to it.
;;;
;;; WHAT IT DOES NOT COVER, SAID PLAINLY: this is a mode the program must REACH.  A hard crash or a
;;; hang never gets here -- and the VM deliberately disables the task watchdog (see main.cpp) so a
;;; long evaluation is not killed, which means a hung VM does not reboot either.  Those cases are
;;; the loader's own fall-through and a watchdog question, not this procedure's.
;;;
;;; It lives in setup.scm rather than a file of its own because only 14 of 25 manifests ship any
;;; given core file, and a last-resort facility that is absent on some targets is not one.  P251
;;; (manifest profiles) is what would make a separate file safe.

;;; THE Nth DEATH LATCHES; THE ONES BEFORE IT RETRY (owner, 2026-09-30).
;;;
;;; A death is not automatically a verdict on the unit.  The first one may be a transient -- a brown-
;;; out, a bus glitch, a one-off condition -- and a unit that hands itself to the loader over a
;;; transient has taken itself out of service for no reason.  So the early deaths are recorded,
;;; safed and RETRIED; only when the count reaches `dead-latch-after` does the unit stop retrying
;;; and hand over.  That bounds the other failure too: a genuinely broken unit cannot flap between
;;; the VM and the loader indefinitely, because the count only goes one way.
;;; *** THE LATCH HAS NO EXIT YET.  DO NOT LET A FIELDED UNIT REACH THIS COUNT. ***
;;; The Nth death hands the unit to the factory loader -- and the loader's console mode is an empty
;;; `for(;;)` spin today.  Nothing there clears `pending_update`, and Scheme cannot run in the
;;; loader, so a latched unit DOES NOT COME BACK WITHOUT USB RECOVERY.  Measured 2026-09-30: deaths
;;; 1 and 2 were run on esp32s3-n8r2-00 and behaved correctly; death 3 was deliberately NOT run for
;;; this reason.  The owner has the exit as TBD ([P255], parked) -- a press-and-hold on the board,
;;; read by the loader, is the recorded candidate.  Until it exists, treat this number as a limit
;;; whose handover is unimplemented: safe to approach, not safe to reach.
(define dead-latch-after 3)   ;;;!< Nth death hands the unit to the loader.  3 matches the loader's
                              ;;;!< own OTA_MAX_INSTALL_TRIES, so the two anti-loop limits agree.

;;!#t when a death count means "stop retrying and hand over".  Separated from `dead!` ON PURPOSE:
;;!this is the whole of the policy and it is a pure function, so it can be exercised for every n on
;;!a host build -- where the recorder returns #f and the branch below can never be reached.
(define (dead-latch? n)
  (and (number? n) (>= n dead-latch-after)))

;;!Declare this VM unfit to continue.  Makes every registered actuator safe, records `reason` and
;;!bumps the death count, then either RETRIES (an early death) or hands the unit to the factory
;;!loader's operator console (the Nth).  DOES NOT RETURN on device, either way -- both arms reboot.
;;!Returns #f if nothing could be recorded -- on a host build, or because `reason` was refused --
;;!having still made the outputs safe, which is the half that matters most and always works.
(define (dead! reason)
  (run-safe-state!)                        ;;; outputs safe FIRST -- see above
  (let ((n (if (defined? 'ota-record-death!) (ota-record-death! reason) #f)))
    (cond
      ((not n)
       ;;; Nothing was recorded: no OTA builtins, a host build, or a reason the recorder refused.
       ;;; The three are distinguished by what the recorder logged, not here.  Returning is the
       ;;; honest move -- the outputs are safe and there is nothing to hand over to.
       (warn "dead!: nothing recorded -- outputs are safe, but no handoff is possible\n")
       #f)
      ((dead-latch? n)
       ;;; `syslog` is printf-style: its FIRST argument is a format string and the rest are its
       ;;; arguments.  Passing several strings would print only the first and silently drop the
       ;;; numbers -- so the message is assembled, not listed.
       (syslog (string-append "dead!: death " (number->string n)
                              " of " (number->string dead-latch-after)
                              " -- handing the unit to the loader\n"))
       (ota-request-console!)
       (ota-reboot-to-loader))             ;;; no return
      (else
       (syslog (string-append "dead!: death " (number->string n)
                              " of " (number->string dead-latch-after)
                              " -- retrying a normal boot\n"))
       (Platform.reboot)))))                ;;; no return

;;!Declare the application healthy and clear the death streak.  CALL THIS ON EVIDENCE OF WORKING --
;;!a completed work cycle, a passed self-test -- and NOT merely on having started.  `(ota-boot-ok!)`
;;!deliberately does not do it: that runs early in a boot, so clearing the count there would reset
;;!the streak before the failure that increments it, and a unit dying every cycle would never reach
;;!the latch threshold.
(define (dead-clear!)
  (if (defined? 'ota-clear-death!) (ota-clear-death!) #f))

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

;;; PER-ENV OVERLAY, MERGED ON TOP -- `Settings-env.scm`.
;;;
;;; Three layers now, each answering a different question: Settings.scm is what the RUNTIME needs,
;;; Settings-local.scm is what this SITE provides (the bench credentials, shared by every target),
;;; and this file is what THIS TARGET differs by -- a panel's rotation, a vehicle's HUD port, an
;;; NTP server that only some boards can reach.  It is staged under a fixed name, so a board never
;;; needs to know which env it was built as; the manifest maps
;;; `runtime-defaults/Settings-env.<target>.scm -> Settings-env.scm`.
;;;
;;; WHY AN OVERLAY AND NOT A PER-ENV COPY OF THE WHOLE FILE.  Until now a target that differed in one
;;; setting had to provide the ENTIRE file, credentials included, by mapping a different source to
;;; `Settings-local.scm`.  Two consequences, both of which cost a day: every such target carries a
;;; duplicate of the shared credentials that can drift silently, and a single wrong mapping replaces
;;; a board's whole configuration rather than one key.  Measured 2026-09-28: three boards came up
;;; with their radios disabled, each looking like a different fault, because a replacement file
;;; reached them carrying `(wifi . 0)` -- a legitimate setting, so nothing reported an error.
;;; AN OVERLAY CANNOT DO THAT, AND THE PROPERTY IS SUBTRACTION, NOT DISCIPLINE.  A replacement file
;;; removes every key it OMITS; an overlay removes nothing -- it can only override keys it NAMES.
;;; So a target that does not differ in its radio does not mention its radio, and no mistake in its
;;; overlay can turn the radio off.  That is also why credentials stay in the layer below: this file
;;; is TRACKED and scm/ ships wholesale to public repos, so an SSID written here is published.
;;;
;;; Prepended AFTER the local file, so it wins -- `setting` takes the FIRST assq match, and the
;;; narrower statement should beat the broader one.
(when (file-exists? "Settings-env.scm")
  (let ((port (open-input-file "Settings-env.scm")))
    (let ((envset (read port)))
      (close-input-port port)
      (if (pair? envset)
          (begin (set! Settings (append envset Settings))
                 (syslog "Settings-env.scm: ~a per-env override(s)\n" (length envset)))
          ;; SAY SO RATHER THAN IGNORE IT.  A malformed overlay that is silently skipped leaves a
          ;; board running the shared defaults while the tree says it is configured otherwise, which
          ;; is the same class of silent-wrong-state this layer exists to remove.
          (warn "Settings-env.scm present but not an alist -- per-env settings IGNORED\n")))))

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
(when (file-exists? "base64.scm")   (load "base64.scm" 0))  ;; P69 Ph3 -- BEFORE llip-auth, which uses it
(when (file-exists? "rsa.scm")      (load "rsa.scm" 0))
(when (file-exists? "dh_groups.scm") (load "dh_groups.scm" 0))
(when (file-exists? "llip-auth.scm") (load "llip-auth.scm" 0))  ;; P69 Ph3 -- after rsa + dh + base64
(when (file-exists? "csv.scm")       (load "csv.scm" 0))       ;; P140 CSV reader/writer
(when (file-exists? "bacnet.scm")    (load "bacnet.scm" 0))    ;; P109 BACnet/IP client
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

;;; ALERTING AND DRIVING ARE SEPARATE DECISIONS, AND ONLY THE ALERT IS ON BY DEFAULT.  [B632]
;;; This used to alert AND drive all four motors -- forward 1 s, then reverse 2 s -- on a single
;;; `Sonar.latest` reading below 0.100 m.  Making the whole feature opt-in stopped the accident (a
;;; vehicle moved with nobody commanding it, the moment [B625]'s frozen sonar was fixed), but it did
;;; not answer the question underneath: whether ONE reading from ONE ultrasonic sensor should move a
;;; vehicle at all.  It should not, and not because of a threshold value -- a sonar reports 4.0 m for
;;; a timeout, for an over-range echo and for a dead 5 V rail, so the sensor cannot distinguish
;;; "clear" from "not answering", and an actuator driven off it inherits that ambiguity.
;;;
;;; So the motion is behind its OWN setting, off by default, and the alert is not.  An operator who
;;; wants the bark gets the bark; the drive is a second, deliberate decision they have to make in
;;; writing.  `guard_dog` enables the dog; `guard_dog_drive` lets it move.
;;;
;;; NOT WIDENED TO A SAFER MOTION, deliberately.  Bounding it (slower, shorter, one direction) would
;;; read as making it safe while leaving a vehicle that lunges at a bad reading, which is the same
;;; defect with better manners.  The reviewable question is whether it drives, so that is the knob.
(define guard-dog-drive? (positive? (setting 'guard_dog_drive 0)))  ;;;!< motion: OFF unless asked

(define (guard-dog)
  (when (< Sonar.latest 0.100)
    (term "Arf!\n")
    (Buzzer.arf)                        ;;;!< one short click now, NOT the old 1 s 60->4000 Hz sweep
    (Led.blinkAll 'rgb-red 5000 1)
    (when guard-dog-drive?
      ;;; Reached only when BOTH `guard_dog` and `guard_dog_drive` are set.  Unchanged from the
      ;;; original sequence on purpose: if it is going to move, it should move the way the entry
      ;;; and the review describe, not a variant nobody has looked at.
      (Motor.motion 1000 1 1 1 1)
      (Motor.motion 100 0 0 0 0)
      (Motor.motion 2000 -0.5 -0.5 -0.5 -0.5)
      (Motor.motion 100 0 0 0 0))
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

;;; STARTUP SIGNAL: tick ... tick (owner, 2026-09-25).  Two short low clicks, and the ONLY sound
;;; this tree makes on a healthy boot.  Buzzer.scm no longer clicks on load -- two acknowledgements
;;; said nothing one did not -- so this is the single place a boot becomes audible, and it fires
;;; here because here is where the board is actually READY.
;;; STARTUP SIGNAL: exactly ONE 5 ms beep at 400 Hz (owner, 2026-09-25), and the only sound a
;;; healthy boot makes.  `Buzzer.beep1` is atomic -- one queue entry that turns the tone on, holds
;;; it, and turns it off -- because a tone split across queue entries lasts as long as the loop
;;; takes to drain them, which is what produced the long beeps this replaces.
(syslog "Starting beep\n")
(Buzzer.beep1)
(syslog "Finished beep\n")

;;;;;;;;
;;;
;;;(loop) start here -- embedded only; on Linux loop is left undefined so Lamb::loop() skips it.
;;;
;;;;;;;;
(define loop-target-ms 3)		;loop budget in ms -- must match idler short threshold
(define loop-deadline-ms (setting 'gc_idle_deadline_ms 10))  ;runtime-settable hard loop ceiling (ms);
					;the GC idle-donation gates on THIS, not the soft target -- set! to retune live
;;; B273: WHICH idle-GC pacing strategy the C++ loop uses.  Two strategies, both supported, because
;;; they regulate different things and neither replaces the other:
;;;   'deadline -- give the collector (loop-deadline-ms - elapsed).  Frames become equal against a
;;;                FIXED reference and the leftover is real headroom, so a STEADY loop still feeds
;;;                the collector.
;;;   'jitter   -- give it (mean-of-recent-frames - elapsed), positive only.  Lengthens short frames
;;;                toward the running mean, so frame times bunch up; needs NO declared period, which
;;;                is what you want when the workload has no meaningful one.  A steady loop is never
;;;                below its own average, so this donates NOTHING -- fine as a regulator, useless as
;;;                a way to feed the collector.  This was the only behaviour before B273.
;;;   'auto     -- 'deadline when loop-deadline-ms is set and positive, else 'jitter.  (default)
;;;   'off      -- no idle collection (diagnostic only).
;;; An unrecognised value behaves as 'auto: a typo must never silently stop the collector.
(define gc-idle-strategy 'auto)

(if linux? #f  ;;; skip loop definition on Linux
    (define loop
      (if app-loop (app-loop)   ;;; a target's app layer may install its own loop-MAKER thunk via app-loop
	  ;; No app-loop installed -> a safe IDLE loop.  There is NO shared robot loop anymore: each
	  ;; target owns its mission (its own scheme files + its own app-loop).  This default only
	  ;; measures the tick and donates spare time to the incremental GC, so an unconfigured board --
	  ;; or the eye before its per-target app-loop applies -- runs CLEAN instead of crashing on
	  ;; unbound robot components (there is currently no sonar/motor stack staged at all).
	  ;;; B288: THE IDLE LOOP MUST NOT ALLOCATE PER TICK.  `t_loop` used to hold a Stopwatch_ms and
	  ;;; the last line of the lambda was `(set! t_loop (Stopwatch_ms))` -- and Stopwatch_ms returns
	  ;;; a CLOSURE over a `let` frame (Timers.scm:14), so EVERY iteration of the loop that exists to
	  ;;; donate spare time to the collector was itself handing the collector a fresh closure and
	  ;;; frame to collect.  An idle loop that allocates is not idle, and this is the default loop on
	  ;;; every non-Linux target -- so it runs on the ESP32s, where a bounded GC pause is the product
	  ;;; claim, and in the browser demo.
	  ;;; MEASURED in the wasm demo 2026-09-06, 25 s of pure idle with NO input: 2 heap expand()s and
	  ;;; one gc_urgent fell-behind alarm, from nothing but this loop turning over at 4 Hz.
	  ;;; A plain millisecond stamp does the same job and allocates nothing.  Note `t_last` is written
	  ;;; and read by the SAME closure, which is one of the two shapes B205 does NOT break -- do not
	  ;;; "tidy" it into a form where one lambda writes it and another reads it.
	  (letrec* ((me "(loop)")
		    (hist (make-vector 100 0))
		    (t_last (millis))
		    (idler (make-idler loop-target-ms 10000 15000))
		    )
	    (lambda ()
	      ;;Measure elapsed; donate spare time UP TO loop-deadline-ms (hard ceiling) to GC lookahead.
	      (let* ((now (millis))
		     (elapsed (-i now t_last))
		     (spare-us (* 1000 (- loop-deadline-ms elapsed))))
		(if (>=i elapsed 100) (set! elapsed 99))
		(vector-set! hist elapsed (+i 1 (vector-ref hist elapsed)))
		(if (idler) (news "~a (loop-stats ~a)\n" me (vector->sparsevec hist 0)))
		;;; KEEP THE RADIO COMING BACK.  Association is asynchronous and its boot-time wait is
		;;; bounded, so a board that is slow on one boot ends up enabled-but-unassociated and,
		;;; without this, never tries again -- a headless node then needs a power cycle, and the
		;;; only way in is a serial port whose own reset re-runs the race that lost.  `wifi-tick!`
		;;; is self-gated (it does nothing until `wifi_poll_ms` has passed, and nothing at all
		;;; when `wifi` is 0), so the cost here is one subtraction and one compare per iteration.
		;;; Guarded: this is the DEFAULT loop for every target that installs no app-loop, and a
		;;; radio fault must degrade the network rather than stop the loop that feeds the collector.
		(if (defined? 'wifi-tick!) (guard (e (#t #f)) (wifi-tick!)))
		(when (> spare-us 0) (Platform.gc-idle-task! spare-us))
		(set! t_last now)
		)
	      )
	    ))
      )
    ) ;;; end (if linux? #f (define loop ...))

;;; [B589] DRAIN AN ARMED `db` PAYLOAD FROM THE LOOP -- THE ONE LINE P132 SPECIFIED AND NOBODY WROTE.
;;;
;;; `db-tick!` exists in features/llip-serial.scm, its firmware support exists (`llip-db-armed!`,
;;; `read-bytevector-avail!`), the host sends the frames -- and it was called FROM NOWHERE in the
;;; whole tree.  So `(db SEQ LEN CRC)` armed the receiver, handed the UART over, and nothing ever
;;; read the payload: the transfer hung, the host reported `chunk 0 not acknowledged ... last
;;; response: ''`, and because the tunnel runs the device in quiet mode there was no error to see.
;;; P132 sec.6.2 says it in terms -- "db-tick! is added to the main loop next to Sonar.loop" and
;;; "the main loop checks db-armed before Term.poll" -- so this is a written design with an
;;; unwritten line, which is indistinguishable from a design nobody implemented.
;;;
;;; WRAPPED HERE, FOR THE REASON B312 GIVES BELOW: a target may install its own loop via app-loop
;;; (the S3-EYE and the aitrip panel both do), so a tick written into the DEFAULT body would serve
;;; only the loop that drives no hardware and miss every board that has a mission.  Wrapping after
;;; the definition covers both.
;;;
;;; INSIDE B312's GUARD, DELIBERATELY: this wrap is applied FIRST, so B312's wrap encloses it and a
;;; fault in the receiver reaches run-safe-state! like any other loop fault.  A serial transfer is
;;; not a reason to leave actuators running.
;;;
;;; GATED ON THE FILE, NOT ON A BOUND SYMBOL.  `db-armed` only exists when llip-serial.scm is
;;; staged; an ungated wrap would raise every iteration on a target without it -- and via B312 that
;;; means run-safe-state! plus a re-raise, i.e. a board that stops dead because a feature it does
;;; not have is absent.  `file-exists?` is the same test the load above uses.
(if (or linux? (not (file-exists? "llip-serial.scm"))) #f
    (set! loop
      (let ((inner loop))            ;;; read-only capture, as B312 does; not the B205 shape
        (lambda ()
          (if db-armed (db-tick!))   ;;; a VARIABLE test, not a call, when idle -- P132 sec.6.2.4
          (inner)))))

;;; B312: GUARD THE LOOP, WHATEVER THE LOOP TURNED OUT TO BE.
;;; Wrapping here rather than inside the default loop above is the point: a target may install its
;;; own via `app-loop`, and each target owns its mission -- so a guard written into the default
;;; body would protect exactly the loop that drives no hardware, and miss every real robot.
;;; Wrapping AFTER the definition covers both cases with one piece of code.
;;;
;;; The exception is RE-RAISED, not swallowed.  Stopping the actuators is not the same as handling
;;; the fault: the error must still reach whoever is watching, or a robot that silently stops and
;;; keeps looping is a worse failure than one that halts loudly.  Safe state FIRST, then propagate.
(if linux? #f
    (set! loop
      (let ((inner loop))            ;;; read-only capture; not the cross-closure shape B205 broke
        (lambda ()
          (guard (e (#t (run-safe-state!) (raise e)))
            (inner))))))


;;; CONFIRM THIS IMAGE -- the call the entire OTA ladder waits for, and that NOTHING made ([B724]).
;;;
;;; WHY IT IS HERE AT ALL.  `ota-boot-ok!` cancels the native rollback and erases `pending_update`
;;; and the loader's `install_tries` retry counter.  Until 2026-10-01 it had ZERO call sites: every
;;; mention in the tree was documentation telling the reader to call it.  The consequence was not a
;;; missing nicety -- it made BOTH paths that clear `install_tries` unreachable, because the loader's
;;; own `install_tries_clear()` is gated on `ota_0` being `ESP_OTA_IMG_VALID`, and the only thing that
;;; ever sets VALID is the `esp_ota_mark_app_valid_cancel_rollback()` inside this very procedure.  So
;;; the counter only ever went UP, and after three install attempts in the lifetime of a unit the
;;; loader's ordinary repair rung was exhausted FOREVER -- every later entry skipped INSTALL, found no
;;; golden image, and fell to the operator console, which needs a human with a UART.  Measured on
;;; esp32s3-n32r16-00 2026-09-30: `install_tries=3 >= max 3` on a board that had never been installed
;;; to in that session, and recovery cost a 1.8 MB image push.
;;;
;;; WHAT THIS CALL CLAIMS, PRECISELY: *this image completed its own initialisation*.  Everything
;;; loaded, the target's own `setup-<env>.scm` ran, and `(loop)` is built and guarded.  It does NOT
;;; claim the application WORKS -- `README-extended.md` is right that starting is not health.
;;;
;;; THE TREE SAID BOTH THINGS AND THE OWNER RULED (2026-10-01).  `README-extended.md` carries, two
;;; bullets apart, "the new VM confirms itself by calling `ota-boot-ok!` EARLY in a good boot" and
;;; "call it ONLY AFTER you are satisfied the new image is actually working ... calling it too early
;;; would defeat the rollback".  `ota_mop3_boot_ok`'s own comment takes the first side.  Nobody had to
;;; resolve it while nothing called it.  The ruling is EARLY AND UNCONDITIONAL, and the reasoning is
;;; worth keeping: the stricter reading is only available to a unit that ships an application able to
;;; judge its own health, and the units we ship do not -- so "late" in practice meant NEVER, which is
;;; the defect above.  A confirmation that no shipped target can issue protects nothing.
;;;
;;; THE DEATH COUNT IS DELIBERATELY NOT CLEARED HERE, and `ota-boot-ok!` does not touch it -- see the
;;; comment in `ota_mop3_boot_ok`.  That counter answers a different question: not "did this image
;;; start" but "does it keep WORKING".  Clearing it on a boot would reset the streak before the
;;; failure that increments it, so a unit dying every cycle would flap forever and never latch.
;;; `(dead-clear!)` is the explicit reset, for an application that has evidence it is working.
;;;
;;; GATED ON `defined?`, like `dead!` above: the OTA builtins exist only on an ESP32 target, and on a
;;; host build this must be a no-op rather than an unbound-variable error at the end of startup.
(if (defined? 'ota-boot-ok!) (ota-boot-ok!) #f)
