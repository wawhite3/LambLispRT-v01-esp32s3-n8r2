;;; Copyright 2026 by Frobenius Norm LLC 2026-07-05 01:30:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; TARGET SETUP for the `esp32-s3-eye` env -- loaded by setup.scm as setup-<lamb-board>.scm,
;;; after every feature/peripheral is defined and before (loop) is built.
;;;
;;; A "target" is a combo of language / application / hardware, keyed by the pio env name.  This one
;;; is a dedicated LambLisp CAMERA NODE: ESP32-S3-EYE (OV2640 DVP camera + built-in ST7789 LCD), no
;;; sonar / no motors / no LED strip.  So it runs the eye's OWN main loop (live camera preview + GC),
;;; installed here via the app-loop hook -- NOT the shared robot loop.
(syslog "Target: esp32-s3-eye -- LambLisp camera node (OV2640 + ST7789), REPL on native USB-Serial/JTAG\n")

;; Install the eye's application loop.  setup.scm's (loop) runs (app-loop) in place of the robot
;; loop -- crucial on the eye, whose robot-loop (Sonar.loop)/(Motor.loop) are UNSTAGED (no such HW)
;; and would flood the console with Unbound-key errors every tick.
;; P136 Phase 2's camera preview loop (eye-make-loop, from eye-cam.scm).  eye-cam.scm now parses
;; cleanly (B87 paren bug fixed) and eye-make-loop is a real maker returning the eye's per-tick loop
;; (auto-starts the live camera preview on the first tick, then donates spare time to the GC).
;; Install it as the app-loop so the eye runs the LIVE CAMERA APP -- NOT the flooding robot loop.
;; GUARDED: if eye-make-loop is somehow unbound/broken (throws when referenced, or is not a real
;; procedure), fall back to a minimal no-op app-loop so the eye still boots to a clean, usable REPL
;; over the native USB-Serial/JTAG link (B87 mitigation) rather than falling through to the robot loop.
(set! app-loop
  (guard (e (#t (syslog "eye: eye-make-loop unavailable -- no-op app-loop (clean REPL)\n")
                (lambda () (lambda () #f))))
    (if (procedure? eye-make-loop)
        eye-make-loop
        (lambda () (lambda () #f)))))
