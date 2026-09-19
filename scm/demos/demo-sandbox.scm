; Copyright 2026 by Frobenius Norm LLC 2026-04-18 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
; demo-sandbox.scm -- Viewer expression sandbox for LambLisp online demo.
; Checks expressions against a whitelist before forwarding to the car.

#|!
@file demo-sandbox.scm
@brief Sandbox for viewer-submitted Scheme expressions.

Viewer expressions are checked against a whitelist of safe procedure names.
Only calls to whitelisted top-level symbols are permitted.  Nested lambda,
define, set!, load, and any I/O are rejected.  Accepted expressions are
forwarded to the car via LLIP and the result is returned as a string.

Rate limiting: each client-id may submit at most sandbox-rate-limit
expressions per sandbox-rate-window-ms milliseconds.
|#

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(define sandbox-rate-limit      3)     ;;!< max expressions per window per client
(define sandbox-rate-window-ms  2000)  ;;!< rate window in ms

;;; Procedures that viewers may call on the car.
(define sandbox-whitelist
  '(robot-move!
    robot-stop
    robot-turn!
    robot-sweep
    robot-pose
    set-leds!
    set-led!
    leds-off
    buzzer-beep
    get-sonar
    get-battery
    get-light
    get-heading))

;;; ---------------------------------------------------------------------------
;;; Rate limiter -- alist of (client-id . (count . window-start-ms))
;;; ---------------------------------------------------------------------------

(define sandbox-rate-table '())

(define (sandbox-rate-ok? client-id now-ms)
  (let ((entry (assoc client-id sandbox-rate-table)))
    (if (not entry)
      (begin
        (set! sandbox-rate-table
              (cons (cons client-id (cons 1 now-ms)) sandbox-rate-table))
        #t)
      (let* ((count (cadr entry))
             (win   (cddr entry))
             (age   (- now-ms win)))
        (cond
          ((>= age sandbox-rate-window-ms)
           ;; window expired -- reset
           (set-cdr! entry (cons 1 now-ms))
           #t)
          ((< count sandbox-rate-limit)
           ;; within window, under limit
           (set-cdr! entry (cons (+ count 1) win))
           #t)
          (else #f))))))                ;;!< over limit

;;; ---------------------------------------------------------------------------
;;; Expression checker -- returns #t if expr is safe to forward
;;; ---------------------------------------------------------------------------

(define sandbox-forbidden-heads
  '(define set! define-syntax load eval apply
    open-input-file open-output-file
    open-tcp-client-port open-tcp-server-port
    system shell))

(define (sandbox-safe? expr)
  (cond
    ((not (pair? expr)) #t)            ;;!< atom -- always safe
    ((not (symbol? (car expr))) #f)    ;;!< non-symbol head -- reject
    ((memq (car expr) sandbox-forbidden-heads) #f)
    ((not (memq (car expr) sandbox-whitelist)) #f) ;;!< not in whitelist
    (else
     ;; args must all be atoms or safe nested calls
     (let loop ((args (cdr expr)))
       (cond
         ((null? args) #t)
         ((pair? (car args)) (and (sandbox-safe? (car args)) (loop (cdr args))))
         (else (loop (cdr args))))))))

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

;;; (sandbox-eval expr-string client-id car-conn now-ms)
;;; -> (list 'ok result-string) | (list 'error msg-string)
(define (sandbox-eval expr-string client-id car-conn now-ms)
  (cond
    ((not (sandbox-rate-ok? client-id now-ms))
     (list 'error "rate limit exceeded -- please wait"))
    (else
     (let ((expr (guard (e (#t #f))
                   (read (open-input-string expr-string)))))
       (cond
         ((not expr)
          (list 'error "parse error"))
         ((not (sandbox-safe? expr))
          (list 'error "expression not permitted"))
         (else
          (guard (e (#t (list 'error (condition/report-string e))))
            (let ((result (llip-eval car-conn expr)))
              (list 'ok (with-output-to-string (lambda () (write result))))))))))))

