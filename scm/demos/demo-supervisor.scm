; Copyright 2026 by Frobenius Norm LLC 2026-04-18 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
; demo-supervisor.scm -- LambLisp online demo supervisor.
; Connects to the 4WD car via LLIP; serves telemetry, map, and sandboxed
; viewer eval to a Python web bridge via a local LLIP server.

#|!
@file demo-supervisor.scm
@brief Online demo supervisor -- three-tier LambLisp demo orchestrator.

## Architecture

    Browser ←WS/SSE/HTTP→ demo-web.py ←LLIP/TCP→ demo-supervisor.scm
                                                         |
                                                     LLIP/TCP
                                                         |
                                                    Freenove 4WD

The Python web bridge (w3_ai_scripts/demo-web.py) handles WebSocket,
camera MJPEG, and browser HTTP.  It connects to this supervisor as an
LLIP client on demo-bridge-port.  Commands from the bridge arrive as
LLIP (eval ...) messages; telemetry and map are pushed as LLIP results.

## Load order

    (load "llip-client.scm" 1)
    (load "llip-server.scm" 1)
    (load "demo-sandbox.scm" 1)
    (load "demo-telemetry.scm" 1)
    (load "demo-supervisor.scm" 1)
    (demo-start)

|#

;;; ---------------------------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------------------------

(define demo-car-host      "192.168.1.100") ;;!< 4WD WiFi address -- update per deployment
(define demo-car-port      8080)            ;;!< LLIP port on car
(define demo-car-token     "demo-car")      ;;!< LLIP auth token for car
(define demo-bridge-port   8181)            ;;!< local LLIP port for Python bridge
(define demo-bridge-token  "demo-bridge")   ;;!< LLIP auth token for bridge
(define demo-poll-ms       150)             ;;!< telemetry poll interval
(define demo-sweep-ms      2000)            ;;!< sonar sweep interval
(define demo-max-clients   16)              ;;!< max simultaneous bridge connections

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

(define demo-car-conn   #f)   ;;!< LLIP connection to car
(define demo-bridge-srv #f)   ;;!< LLIP server for Python bridge
(define demo-bridge-clients '()) ;;!< list of active bridge connections
(define demo-last-poll  0)    ;;!< ms of last telemetry poll
(define demo-last-sweep 0)    ;;!< ms of last sonar sweep
(define demo-cmd-queue  '())  ;;!< (client-id expr-string) pending commands
(define demo-history    '())  ;;!< last 20 viewer expressions (for new clients)

;;; ---------------------------------------------------------------------------
;;; Car control helpers -- thin wrappers around LLIP eval
;;; ---------------------------------------------------------------------------

(define (car-eval expr)
  (llip-eval demo-car-conn expr))

(define (car-move! dir ms)    (car-eval `(robot-move! ',dir ,ms)))
(define (car-stop)            (car-eval '(robot-stop)))
(define (car-turn! deg)       (car-eval `(robot-turn! ,deg)))
(define (car-sweep)           (car-eval '(robot-sweep)))
(define (car-set-leds! pat)   (car-eval `(set-leds! ',pat)))
(define (car-leds-off)        (car-eval '(leds-off)))

;;; ---------------------------------------------------------------------------
;;; Demo loop helpers
;;; ---------------------------------------------------------------------------

(define (demo-poll-telemetry! now)
  (when (>= (- now demo-last-poll) demo-poll-ms)
    (telem-poll! demo-car-conn now)
    (set! demo-last-poll now)))

(define (demo-poll-sweep! now)
  (when (>= (- now demo-last-sweep) demo-sweep-ms)
    (let ((result (guard (e (#t '())) (car-sweep))))
      (when (pair? result)
        (grid-update-sweep! result)))
    (set! demo-last-sweep now)))

;;; Accept new bridge connections (non-blocking).
(define (demo-accept-bridges!)
  (when (< (length demo-bridge-clients) demo-max-clients)
    (let ((conn (llip-server-accept demo-bridge-srv)))
      (when conn
        (set! demo-bridge-clients (cons conn demo-bridge-clients))
        (demo-send-history! conn)
        (demo-accept-bridges!)))))   ;;!< drain -- accept more if available

;;; Remove dead bridge connections.
(define (demo-cull-bridges!)
  (set! demo-bridge-clients
        (filter (lambda (c) (llip-alive? c)) demo-bridge-clients)))

;;; Push a telemetry+map update to all bridge connections.
(define (demo-push-all! now)
  (when (>= (- now demo-last-poll) demo-poll-ms)
    (let ((msg `(telemetry ,(telem->json) ,(grid->ascii))))
      (for-each
        (lambda (c)
          (guard (e (#t #f))
            (llip-send-result c msg)))
        demo-bridge-clients))))

;;; Send recent command history to a newly connected bridge.
(define (demo-send-history! conn)
  (for-each
    (lambda (h)
      (guard (e (#t #f))
        (llip-send-result conn `(history . ,h))))
    (reverse demo-history)))

;;; ---------------------------------------------------------------------------
;;; Command dispatch from bridge clients
;;; ---------------------------------------------------------------------------

;;; Bridge sends (eval expr-string client-id) via LLIP.
;;; We check one pending command per loop tick to keep things smooth.
(define (demo-read-commands!)
  (for-each
    (lambda (conn)
      (let ((msg (llip-poll conn)))   ;;!< non-blocking read
        (when (and msg (pair? msg) (eq? (car msg) 'eval))
          (let ((expr-string (cadr msg))
                (client-id   (caddr msg)))
            (set! demo-cmd-queue
                  (append demo-cmd-queue
                          (list (list client-id expr-string conn))))))))
    demo-bridge-clients))

(define (demo-dispatch-one!)
  (when (pair? demo-cmd-queue)
    (let* ((item      (car demo-cmd-queue))
           (client-id (car item))
           (expr-str  (cadr item))
           (conn      (caddr item))
           (now       (elapsed-ms))
           (result    (sandbox-eval expr-str client-id demo-car-conn now)))
      (set! demo-cmd-queue (cdr demo-cmd-queue))
      ;; record in history
      (set! demo-history
            (let ((h (cons expr-str (if (eq? (car result) 'ok) (cadr result) (cadr result)))))
              (if (> (length demo-history) 20)
                (append (cdr demo-history) (list h))
                (append demo-history (list h)))))
      ;; broadcast result to all clients
      (for-each
        (lambda (c)
          (guard (e (#t #f))
            (llip-send-result c `(eval-result ,client-id ,expr-str ,result))))
        demo-bridge-clients))))

;;; ---------------------------------------------------------------------------
;;; Main loop
;;; ---------------------------------------------------------------------------

(define (demo-loop)
  (let loop ()
    (let ((now (elapsed-ms)))
      (demo-accept-bridges!)
      (demo-read-commands!)
      (demo-dispatch-one!)
      (demo-poll-telemetry! now)
      (demo-poll-sweep! now)
      (demo-push-all! now)
      (when (zero? (modulo (inexact->exact (floor (/ now 5000))) 1))
        (demo-cull-bridges!))         ;;!< cull dead connections every 5 s
      (loop))))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(define (demo-start)
  (display "demo-supervisor: connecting to car at ")
  (display demo-car-host) (display ":") (display demo-car-port) (newline)
  (set! demo-car-conn
        (llip-connect-tcp demo-car-host demo-car-port demo-car-token))
  (display "demo-supervisor: car connected.") (newline)

  (display "demo-supervisor: starting bridge server on port ")
  (display demo-bridge-port) (newline)
  (set! demo-bridge-srv
        (llip-make-server demo-bridge-port demo-bridge-token))

  (display "demo-supervisor: entering main loop.") (newline)
  (demo-loop))

