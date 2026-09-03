;;; ncg-fusion-probe.scm -- P165: verify the NCG fusion peepholes are CORRECT and ACTUALLY FIRING.
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-01 14:30:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; WHY THIS FILE EXISTS, separately from ncg-fusion-ab.scm.  The A/B driver measures SPEED and
;;; needs the heavy benchmarks (fib(33), tak, ackermann) to do it, which takes minutes and is far
;;; too slow for an MCU over a serial line.  This probe answers the two questions that actually
;;; gate a backend port, in about a second, on any build with an NCG backend compiled in:
;;;
;;;   1. Does the fused code COMPUTE THE SAME ANSWER as the unfused code?
;;;   2. Did the procedure actually STAY NCG-COMPILED with fusion on?
;;;
;;; Question 2 is not paranoia, it is B195: a fused emitter that fails to record pc_map[ipc] for
;;; the fused head makes any jump landing there fail finalize(), and the WHOLE procedure silently
;;; reverts to the bytecode interpreter.  The answers stay correct, so a pure results comparison
;;; PASSES while testing none of the native code it was written to test.  `ncg-compiled?` is the
;;; only check that can see it.  Every case below is therefore graded on BOTH.
;;;
;;; Usage:  echo '(load "ll_tests/ncg-fusion-probe.scm" 0)' | ./program
;;;         (or over serial to a board, which is why the output is terse and line-oriented)
;;;
;;; Sentinel: --- ncg-fusion-probe done ---

(define probe-fails 0)
(define probe-runs  0)

;;; Compile PROC-FORM under the requested fusion setting and RETURN the compiled procedure.
;;; Three things here are load-bearing and each was got wrong on the first attempt:
;;;   - the form is re-evaluated every time, so we always start from a fresh uncompiled T_PROC.
;;;     ncg-fuse! is read at COMPILE time, so recompiling an already-native proc tests nothing;
;;;   - ncg-compile takes the BYTECODE (procedure->bytecode p), not the T_PROC;
;;;   - ncg-compile RETURNS the compiled procedure, it does not mutate in place.  Calling it for
;;;     effect and then applying the original leaves you running the interpreter while believing
;;;     you are testing native code -- which reads as "every case failed" against ncg-compiled?.
;;; ncg-fuse! is restored to its previous value, so the setting never leaks between cases.
(define (probe-compile form fuse)
  (let ((prev (ncg-fuse! fuse))
        (env  (interaction-environment)))
    (let* ((p0 (eval form env))
           (p  (ncg-compile (procedure->bytecode p0))))
      (ncg-fuse! prev)
      p)))

;;; Grade one case on BOTH axes: same answer OFF vs ON, and still native with fusion ON.
(define (probe name form . args)
  (set! probe-runs (+ probe-runs 1))
  (let* ((p-off (probe-compile form #f))
         (p-on  (probe-compile form #t))
         (r-off (apply p-off args))
         (r-on  (apply p-on  args))
         (nat   (ncg-compiled? p-on))
         (same  (equal? r-off r-on)))
    (if (and same nat)
        (syslog "  ok   ~a => ~a~%" name r-on)
        (begin
          (set! probe-fails (+ probe-fails 1))
          (cond
           ((not same)
            (syslog "  FAIL ~a  MISMATCH off=~a on=~a~%" name r-off r-on))
           (else
            ;; B195 shape: the answer is right because it fell back to bytecode.
            (syslog "  FAIL ~a  NOT-NCG-COMPILED with fusion on (answer ~a is right but native code was DISCARDED)~%"
                    name r-on)))))))

(syslog "~%######## NCG FUSION PROBE (P165) ########~%")

;;; ---- F1: LOAD_CONST(int32) + <binop> -- constant folded as the RHS immediate --------------
;;; `a` is the only stacked operand.  (car (list n)) keeps n off the LOAD_LOCAL path so the
;;; F1 bigram is what gets emitted rather than the F2 trigram.
(syslog "-- F1 (LOAD_CONST + binop) --~%")
(probe 'f1-add   '(lambda (n) (+ (car (list n)) 7))    35)
(probe 'f1-sub   '(lambda (n) (- (car (list n)) 7))    35)
(probe 'f1-mul   '(lambda (n) (* (car (list n)) 7))    35)
(probe 'f1-neg   '(lambda (n) (+ (car (list n)) -9))   35)   ;; negative immediate
(probe 'f1-negv  '(lambda (n) (- (car (list n)) 7))   -35)   ;; negative operand (sign-extension)
(probe 'f1-and   '(lambda (n) (bitwise-and (car (list n)) 12)) 30)
(probe 'f1-or    '(lambda (n) (bitwise-or  (car (list n)) 12)) 30)
(probe 'f1-xor   '(lambda (n) (bitwise-xor (car (list n)) 12)) 30)
(probe 'f1-lt    '(lambda (n) (<  (car (list n)) 10))  35)
(probe 'f1-le    '(lambda (n) (<= (car (list n)) 10))  10)
(probe 'f1-gt    '(lambda (n) (>  (car (list n)) 10))  35)
(probe 'f1-ge    '(lambda (n) (>= (car (list n)) 10))  10)
(probe 'f1-eq    '(lambda (n) (=  (car (list n)) 10))  10)

;;; ---- F2: LOAD_LOCAL + LOAD_CONST(int32) + <binop> -- neither operand spilled ---------------
(syslog "-- F2 (LOAD_LOCAL + LOAD_CONST + binop) --~%")
(probe 'f2-add   '(lambda (n) (+ n 7))    35)
(probe 'f2-sub   '(lambda (n) (- n 1))    35)
(probe 'f2-mul   '(lambda (n) (* n 3))    35)
(probe 'f2-neg   '(lambda (n) (+ n -9))   35)
(probe 'f2-negv  '(lambda (n) (- n 1))   -35)
(probe 'f2-and   '(lambda (n) (bitwise-and n 12)) 30)
(probe 'f2-or    '(lambda (n) (bitwise-or  n 12)) 30)
(probe 'f2-xor   '(lambda (n) (bitwise-xor n 12)) 30)
(probe 'f2-lt    '(lambda (n) (<  n 2))   35)
(probe 'f2-le    '(lambda (n) (<= n 2))    2)
(probe 'f2-gt    '(lambda (n) (>  n 2))   35)
(probe 'f2-ge    '(lambda (n) (>= n 2))    2)
(probe 'f2-eq    '(lambda (n) (=  n 2))    2)

;;; ---- Overflow and the numeric-tower slow path ---------------------------------------------
;;; The fast path is int32-only; these MUST leave it.  On Xtensa the ADD/SUB overflow tests and
;;; the MUL routing are the subtlest code in the backend and this is the one backend with no
;;; 64-bit safety net, so a wrong answer here is the expected shape of a porting error.
(syslog "-- overflow / slow path --~%")
(probe 'ovf-mul  '(lambda (n) (* n 2))    2000000000)   ;; int32 overflow -> int64 promotion
(probe 'ovf-add  '(lambda (n) (+ n 1))    2147483647)   ;; INT32_MAX + 1
(probe 'ovf-sub  '(lambda (n) (- n 1))   -2147483648)   ;; INT32_MIN - 1
(probe 'slow-flo '(lambda (n) (+ n 1))    2.5)          ;; float `a` -> shim, immediate must not be used raw
(probe 'slow-cmp '(lambda (n) (< n 2))    1.5)          ;; float compare via ncg_num_cmp

;;; ---- Fused head as a jump target (the B195 shape, directly) --------------------------------
;;; A loop whose back-edge lands on the fused head.  If pc_map/the block reset is wrong for the
;;; fused head, finalize() fails and the whole procedure loses its native code.
(syslog "-- fused head as jump target (B195) --~%")
(probe 'loop-sum '(lambda (n)
                    (let loop ((i 0) (acc 0))
                      (if (< i n) (loop (+ i 1) (+ acc i)) acc)))
       100)
(probe 'loop-cnt '(lambda (n)
                    (let loop ((i n) (acc 0))
                      (if (> i 0) (loop (- i 1) (+ acc 2)) acc)))
       50)

(syslog "~%probe: ~a run, ~a failed~%" probe-runs probe-fails)
(syslog "VERDICT ~a~%" (if (= probe-fails 0) "PASS" "FAIL"))
(syslog "--- ncg-fusion-probe done ---~%")
