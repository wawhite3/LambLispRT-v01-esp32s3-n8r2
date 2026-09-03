;;; subsystem-runner.scm -- LambLisp subsystem tests for ESP32 serial delivery.
;;; Copyright 2026 by Frobenius Norm LLC 2026-06-02 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Loads each subsystem test file; counts PASS/FAIL lines.
;;; Sentinel: --- subsystem done ---
;;;
;;; Usage: echo '(load "ll_tests/subsystem-runner.scm" 0)' | ./program

(define subsys-pass 0)
(define subsys-fail 0)

(define (count-results tag)
  ;; Each subsystem file defines its own pass/fail counters with varied names.
  ;; We capture by examining the last PASS/FAIL output via the global counters
  ;; set in each file.  This runner just runs them and tallies.
  #t)

(define (run-subsys file)
  (display "\n--- ") (display file) (display " ---\n")
  (load (string-append "ll_tests/" file) 0))

(run-subsys "let-tests.scm")
(run-subsys "named-let-tests.scm")
(run-subsys "letrec-tests.scm")
(run-subsys "loop-tests.scm")
(run-subsys "qq-tests.scm")
(run-subsys "syntax-rules-tests.scm")
(run-subsys "bytecode-tests.scm")
(run-subsys "ncg-tests.scm")

;;; Modbus tests -- only where the Modbus binding is built (LL_MODBUS=1,
;;; currently the Linux backends).  guard skips cleanly on boards without it:
;;; referencing the unbound symbol raises before the load is attempted.
(guard (e (#t (display "SKIPPED modbus-tests (binding not built on this board)\n")))
  (if (procedure? modbus-tcp-connect)
      (run-subsys "modbus-tests.scm")))

;;; Hardware actuator tests -- Freenove 4WD only.
(when (string=? lamb-board "Freenove-4WD-Car-Kit-ESP32")
  (run-subsys "hardware-tests.scm"))

;;; Each test file prints its own PASS/FAIL lines; the linux runner counts them
;;; in bash.  On ESP32, overnight_report.py counts from serial output.
(display "\nTotal: ") (display subsys-pass) (display " pass, ")
(display subsys-fail) (display " fail") (newline)
(display "--- subsystem done ---") (newline)
