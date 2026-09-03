;;; ncg-fusion-ab.scm -- P165: measure the NCG bytecode->native FUSION peepholes, OFF vs ON.
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-30 17:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; WHY THIS FILE EXISTS.  P165's first fusion (F1, the LOAD_CONST-immediate binop) was measured by
;;; hand-editing the emission loop, rebuilding, and timing -- so the number could not be re-checked
;;; without redoing the edit, and the SECOND fusion (F2, the LOAD_LOCAL+LOAD_CONST+binop trigram)
;;; shipped with no measurement at all.  `(ncg-fuse! <bool>)` makes the A/B a property of the
;;; binary: both configurations come from one build, on one host, in one run.
;;;
;;; HOW IT WORKS.  ncg-fuse! is read when a procedure is COMPILED, not when it runs, so each
;;; benchmark is re-evaluated from its source form (a fresh uncompiled T_PROC), compiled under the
;;; requested setting, and bound back to its own name -- recursive self-calls resolve through that
;;; global, so the whole call tree runs in the configuration under test.
;;;
;;; Usage -- needs an NCG-capable build (e.g. linux_x86_64_ncg):
;;;   echo '(load "ll_tests/ncg-fusion-ab.scm" 0)' | ./program
;;;
;;; Sentinel: --- ncg-fusion-ab done ---

(define ab-esc (string (integer->char #x1b)))
(define (ab-news fmt . args)
  (apply syslog (string-append ab-esc "[32m" fmt ab-esc "[97m") args))
(define (ab-warn fmt . args)
  (apply syslog (string-append ab-esc "[33m" fmt ab-esc "[97m") args))

;;; -----------------------------------------------------------------------
;;; Timing
;;; -----------------------------------------------------------------------

(define (ab-us thunk21)                    ;;;!< microseconds for one call of thunk21
  (let ((t0 (micros)))
    (thunk21)
    (- (micros) t0)))

;;; Report the MINIMUM of three runs, not the mean: the minimum is the run least disturbed by the
;;; scheduler, and we are comparing two code shapes, not characterising a distribution.
(define (ab-min3 thunk22)
  (let* ((a (ab-us thunk22)) (b (ab-us thunk22)) (c (ab-us thunk22)))
    (if (< a b) (if (< a c) a c) (if (< b c) b c))))

;;; -----------------------------------------------------------------------
;;; Compile one benchmark under a given fusion setting
;;;
;;; Returns the value the benchmark produced, so the caller can verify OFF and ON agree -- a fusion
;;; that is faster and WRONG is the failure this whole exercise must not miss.
;;; -----------------------------------------------------------------------

(define (ab-compile! name src fuse?)
  (let ((prev (ncg-fuse! fuse?))
        (env  (interaction-environment)))
    (eval src env)                                       ;; fresh, uncompiled T_PROC
    (eval (list 'define name (list 'ncg-compile (list 'procedure->bytecode name))) env)
    (ncg-fuse! prev)
    (ncg-compiled? (eval name env))))                    ;; #f => the backend declined; say so

(define ab-rows 0)
(define ab-bad  0)

(define (ab-run name src call expect)
  (let* ((env      (interaction-environment))
         (thunk23    (lambda () (eval call env)))
         (ok-off   (ab-compile! name src #f))
         (val-off  (eval call env))
         (us-off   (ab-min3 thunk23))
         (ok-on    (ab-compile! name src #t))
         (val-on   (eval call env))
         (us-on    (ab-min3 thunk23)))
    (set! ab-rows (+ ab-rows 1))
    (cond
      ((not (equal? val-off expect))
       (set! ab-bad (+ ab-bad 1))
       (ab-warn "BAD ~a fusion OFF gave ~a, expected ~a\n" name val-off expect))
      ((not (equal? val-on expect))
       (set! ab-bad (+ ab-bad 1))
       (ab-warn "BAD ~a fusion ON gave ~a, expected ~a\n" name val-on expect))
      (else
        (ab-news "~a  OFF ~a us   ON ~a us   delta ~a%~a\n"
                 name us-off us-on
                 (if (= us-off 0) 0 (quotient (* 100 (- us-on us-off)) us-off))
                 (if (and ok-off ok-on) "" "   [WARNING: not NCG-compiled -- timing is not a fusion A/B]"))))))

;;; -----------------------------------------------------------------------
;;; The benchmarks.  These are P165 section 7's losing set: tight recursive workers whose bodies
;;; are the immediate-operand idiom ((- n 1), (= n 0), (< n 2)) the fusions target.  Parameters
;;; match the ones section 8 reports, so the numbers here are comparable to the ones recorded there.
;;; -----------------------------------------------------------------------

(ab-news "\n=== P165 NCG fusion A/B (min of 3, one binary) ===\n")

(ab-run 'ab-fib
        '(define (ab-fib n) (if (< n 2) n (+ (ab-fib (- n 1)) (ab-fib (- n 2)))))
        '(ab-fib 33)
        3524578)

(ab-run 'ab-tak
        '(define (ab-tak x y z)
           (if (not (< y x)) z
               (ab-tak (ab-tak (- x 1) y z) (ab-tak (- y 1) z x) (ab-tak (- z 1) x y))))
        '(ab-tak 24 16 8)
        9)

(ab-run 'ab-ack
        '(define (ab-ack m n)
           (cond ((= m 0) (+ n 1))
                 ((= n 0) (ab-ack (- m 1) 1))
                 (else    (ab-ack (- m 1) (ab-ack m (- n 1))))))
        '(ab-ack 3 7)
        1021)

(if (= ab-bad 0)
  (ab-news "~a benchmarks, all results identical OFF vs ON\n" ab-rows)
  (ab-warn "~a benchmarks, ~a produced a WRONG result -- fusion is not correctness-neutral\n"
           ab-rows ab-bad))
(ab-news "--- ncg-fusion-ab done ---\n")
