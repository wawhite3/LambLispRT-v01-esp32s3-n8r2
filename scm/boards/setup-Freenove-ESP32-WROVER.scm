;;; Copyright 2026 by Frobenius Norm LLC 2026-09-25
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; TARGET SETUP for the `Freenove-ESP32-WROVER` env -- loaded by setup.scm as
;;; setup-<lamb-board>.scm, after every feature and peripheral is defined and before (loop) is
;;; built.  This is a WROVER-CAM: an OV2640 on a classic ESP32 with PSRAM.
;;;
;;; THE CAMERA IS BROUGHT UP HERE, AT THE END OF BOOT, AND THE TIMING IS THE WHOLE POINT [B608].
;;;
;;; `esp_camera_init` needs a CONTIGUOUS ~23 KB internal-DMA block for its line buffer.  Internal
;;; DRAM is also where Scheme definitions land, so every file loaded eats into the same pool --
;;; and the margin is far thinner than it looks.  Measured 2026-09-24, same board, minutes apart:
;;;
;;;   reset, then (camera-init 'jpeg)                        -> ESP_OK in milliseconds
;;;   reset, load ONE .scm file, then (camera-init 'jpeg)    -> never returns
;;;
;;; One additional file tips it.  So the camera must come up BEFORE user code loads, and the end
;;; of boot is the last moment that is still true.
;;;
;;; WHY NOT EARLIER, AND WHY NOT A RESERVATION.  Both were tried and both are worse.  Starting DVP
;;; capture while setup.scm is reading files from flash crashes on camera-DMA-vs-flash-cache
;;; contention.  Reserving the block at install time instead -- which the driver can still do --
;;; starved LittleFS boot reads and SILENTLY CORRUPTED whichever .scm file hit a starved read
;;; ([B88], fixed by switching it off).  A hang is bad; a quietly corrupted library file is worse.
;;;
;;; WHAT REMAINS WRONG.  This is placement, not a cure: the pool is still shared and the margin is
;;; still thin, so a target that grows its library can cross the line again.  The driver now
;;; refuses with #f rather than stalling when the block is too small, so the next time this bites
;;; it says so instead of taking the main loop with it.

(syslog "Target: Freenove-ESP32-WROVER -- OV2640 camera node\n")

;;; Bring the camera up now, in JPEG mode.
;;;
;;; JPEG RATHER THAN RGB565, AND NOT ONLY FOR SIZE.  A 240x240 frame is ~5 KB encoded against
;;; 115,200 raw, which over this radio is the difference between a video feed and a slideshow.
;;; But it is also what the frame header CLAIMS: `llip-vision-capture-send!` writes 'jpeg into
;;; every record regardless of what the sensor is producing, so a camera left in rgb565 puts raw
;;; pixels on the wire under a header that says JPEG.  The receiver hands that to a JPEG decoder,
;;; which rejects it, and the frame is counted bad -- a frame that arrived perfectly and was
;;; discarded because its label was wrong.  Initialising in 'jpeg makes the label true.
;;;
;;; Guarded: a board whose camera is absent or unhappy must still finish booting and reach its
;;; REPL, because that is where someone asks it why.  The result is logged either way -- "the
;;; camera did not come up" is a diagnosis, and silence is not.
(define wrover-camera-ok
  (guard (e (#t (syslog "[wrover] camera-init raised -- continuing without a camera\n") #f))
    (camera-init 'jpeg)))

(syslog "[wrover] camera ~a\n" (if wrover-camera-ok "ready (jpeg)" "NOT available"))
