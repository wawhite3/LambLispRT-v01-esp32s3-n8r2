;;; llip-orchestrator.scm — WP-C of P123: the all-LambLisp orchestrator (Jetson side).
;;; Copyright 2026 by Frobenius Norm LLC 2026-06-24 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Owns ALL I/O + state; the LLM stays a pure text function (it never opens files or
;;; sockets — the orchestrator does).  Loop: goal -> plan (LLM) -> move-program frame
;;; -> send (transport) -> recv telemetry -> done / replan / halt.
;;;
;;; Deps: llip-http.scm (llip-llm-complete) and llip-frame.scm (validators/accessors).
;;; Transport is PLUGGABLE so WP-B (LLIP-over-TCP to the 4WD) slots in without changing
;;; this file: a transport is (cons send! recv) where (send! frame) writes a move-program
;;; and (recv) returns a telemetry frame.

;;; --- planner inputs -------------------------------------------------------------
;;; GBNF grammar — MIRRORS w3_ai_scripts/llip_move.gbnf; keep the two in sync (the
;;; grammar makes invalid model output impossible, so plans are guaranteed-valid).
(define llip-grammar
  (string-append
   "root   ::= \"(\" move (\" \" move)* \")\"\n"
   "move   ::= \"(\" verb \" (\" unit \" \" number \"))\" | \"(stop)\" | \"(dock)\"\n"
   "verb   ::= \"forward\" | \"backward\" | \"turn-left\" | \"turn-right\" | \"wait\"\n"
   "unit   ::= \"s\" | \"m\" | \"cm\" | \"deg\"\n"
   "number ::= [0-9]+ (\".\" [0-9]+)?\n"))

(define llip-system
  (string-append
   "You are the motion planner for a 4-wheel robot. Translate the user's instruction "
   "into a short, safe move program using only the move vocabulary. Output ONLY the "
   "program (a list of move forms), nothing else.\n"
   "Verbs: forward, backward, turn-left, turn-right, wait (each takes one magnitude "
   "(unit value)); stop and dock take none. Units: s = seconds, deg = degrees.\n"
   "\"go forward for two seconds then stop\" -> ((forward (s 2)) (stop))\n"
   "\"turn right 90 degrees and dock\"       -> ((turn-right (deg 90)) (dock))"))

;;; qwen ChatML prompt (matches llip_planner.py — the productionized B1 path).
(define (llip-build-prompt instruction)
  (string-append "<|im_start|>system\n" llip-system "<|im_end|>\n"
                 "<|im_start|>user\n" instruction "<|im_end|>\n"
                 "<|im_start|>assistant\n"))

;;; --- deliberative tier: instruction -> validated move list (or #f) --------------
(define (llip-plan instruction . opts)
  (let* ((host (if (pair? opts) (car opts) "127.0.0.1"))
         (port (if (and (pair? opts) (pair? (cdr opts))) (cadr opts) 8080))
         (text (llip-llm-complete (llip-build-prompt instruction) llip-grammar host port)))
    (and text
         (let ((moves (guard (e (#t #f)) (read (open-input-string text)))))
           (and (llip-program-valid? moves) moves)))))

;;; --- move-program frame builder -------------------------------------------------
(define (llip-make-move-program seq ttl moves)
  (list 'move-program (list 'seq seq) (list 'ttl ttl) (list 'moves moves)))

;;; --- replan policy (recommended HYBRID, C5) -------------------------------------
;;; Auto-recover obstacle-type aborts; deadman / unreachable-planner / unknown -> halt.
(define (llip-recoverable? reason)
  (if (memq reason '(obstacle obstacle-front obstacle-left obstacle-right)) #t #f))

(define (llip-recovery-instruction goal reason)
  (string-append "The previous plan stopped because of " (symbol->string reason)
                 ". Back up a little and turn to get around it, then continue: " goal))

;;; --- the orchestrator loop ------------------------------------------------------
;;; Returns (done SEQ) | (halt REASON).  transport = (cons send! recv).
;;; opts: ttl (default 4s), max-replans (default 5), host, port.
(define (llip-orchestrate goal transport . opts)
  (let ((ttl   (if (pair? opts) (car opts) 4))
        (send! (car transport))
        (recv  (cdr transport)))
    (let loop ((instruction goal) (seq 1) (tries 0))
      (if (> tries 5)
          (list 'halt 'too-many-replans)
          (let ((moves (llip-plan instruction)))
            (if (not moves)
                (list 'halt 'plan-failed)               ;;; unreachable planner / invalid -> halt
                (begin
                  (send! (llip-make-move-program seq ttl moves))
                  (let* ((telem  (recv))
                         (status (llip-field 'status telem))
                         (reason (llip-field 'reason telem)))
                    (cond
                      ((eq? status 'done) (list 'done seq))
                      ((eq? status 'aborted)
                       (if (llip-recoverable? reason)
                           (loop (llip-recovery-instruction goal reason) (+ seq 1) (+ tries 1))
                           (list 'halt reason)))         ;;; deadman / unknown -> halt
                      (else (list 'halt (list 'unexpected-status status))))))))))))

(syslog "llip-orchestrator loaded (llip-plan, llip-orchestrate)\n")

; end of llip-orchestrator.scm
