;;; Copyright 2026 by Frobenius Norm LLC 2026-06-19 00:00:00
;;; LLIP robot control -- move-program framing + validation (P119 Phase 2).
;;; Pure data: no motor/sensor I/O, so it loads and tests on any LambLisp
;;; (Linux or ESP32). The executor (Phase 3) is the only part that drives Motor.*.

;;; --- vocabulary (must match w3_ai_scripts/llip_move_schema.json) ---
(define llip-verbs       '(forward backward turn-left turn-right wait stop dock))
(define llip-nullary     '(stop dock))               ;;; take no magnitude
(define llip-units       '(s m cm deg))              ;;; s implemented first; m/cm/deg need odometry
(define llip-max-moves   32)                         ;;; program length cap
(define llip-max-seconds 30)                         ;;; per-move duration sanity bound
(define llip-max-degrees 360)

(define (llip-member? x lst) (if (memq x lst) #t #f))
(define (llip-verb? v)       (llip-member? v llip-verbs))
(define (llip-nullary? v)    (llip-member? v llip-nullary))
(define (llip-unit? u)       (llip-member? u llip-units))

;;; A magnitude is (unit value): a known unit and a non-negative, sanely-bounded number.
(define (llip-magnitude-valid? mag)
  (and (pair? mag)
       (llip-unit? (car mag))
       (pair? (cdr mag))
       (number? (cadr mag))
       (>= (cadr mag) 0)
       (if (eq? (car mag) 'deg)
           (<= (cadr mag) llip-max-degrees)
           (<= (cadr mag) llip-max-seconds))))

;;; A move is (verb) for nullary verbs, or (verb (unit value)) otherwise.
(define (llip-move-valid? m)
  (and (pair? m)
       (llip-verb? (car m))
       (if (llip-nullary? (car m))
           (null? (cdr m))
           (and (pair? (cdr m))
                (llip-magnitude-valid? (cadr m))
                (null? (cddr m))))))

;;; Re-validation on the 4WD (defence in depth): every move legal, length capped.
(define (llip-program-valid? moves)
  (and (list? moves)
       (<= (length moves) llip-max-moves)
       (let loop ((ms moves))
         (cond ((null? ms) #t)
               ((llip-move-valid? (car ms)) (loop (cdr ms)))
               (else #f)))))

;;; --- frame access: (move-program (seq N) (ttl T) (moves (...))) ---
(define (llip-field key frame)            ;;; -> value or #f
  (let ((p (assq key (cdr frame))))
    (if p (cadr p) #f)))

(define (llip-mp-seq frame)   (llip-field 'seq frame))
(define (llip-mp-ttl frame)   (llip-field 'ttl frame))
(define (llip-mp-moves frame) (llip-field 'moves frame))

(define (llip-move-program? frame)
  (and (pair? frame)
       (eq? (car frame) 'move-program)
       (number? (llip-mp-seq frame))
       (number? (llip-mp-ttl frame))
       (llip-program-valid? (llip-mp-moves frame))))

;;; --- telemetry builder (up): status in (running done aborted halted) ---
(define (llip-make-telemetry seq move-index status reason sensors)
  (list 'telemetry
        (list 'seq seq)
        (list 'move-index move-index)
        (list 'status status)
        (list 'reason reason)
        (list 'sensors sensors)))
