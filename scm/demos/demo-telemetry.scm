; Copyright 2026 by Frobenius Norm LLC 2026-04-18 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
; demo-telemetry.scm -- Telemetry polling and map maintenance for LambLisp demo.

#|!
@file demo-telemetry.scm
@brief Poll car sensors via LLIP; maintain occupancy grid map.

Telemetry is stored as a flat alist:
  ((sonar . N)        distance in cm
   (battery . N)      percent 0-100
   (light . N)        ADC raw 0-4095
   (heading . N)      degrees 0-359 (dead reckoning)
   (pose-x . N)       cm from origin
   (pose-y . N)       cm from origin
   (loop-ms . N)      last car loop time in ms
   (ncells . N)       GC free cells)

The occupancy grid is a flat vector: grid[y*W + x].
  0 = unknown, 1 = free, 2 = occupied.
|#

;;; ---------------------------------------------------------------------------
;;; Telemetry state
;;; ---------------------------------------------------------------------------

(define telem-data '())                ;;!< current alist
(define telem-timestamp 0)             ;;!< ms when last updated

(define (telem-get key)
  (let ((p (assq key telem-data)))
    (if p (cdr p) 0)))

(define (telem-set! key val)
  (let ((p (assq key telem-data)))
    (if p
      (set-cdr! p val)
      (set! telem-data (cons (cons key val) telem-data)))))

;;; ---------------------------------------------------------------------------
;;; Occupancy grid
;;; ---------------------------------------------------------------------------

(define grid-W 100)                    ;;!< cells wide (10 cm each = 10 m)
(define grid-H 100)                    ;;!< cells tall
(define grid-data (make-vector (* grid-W grid-H) 0))
(define grid-origin-x 50)             ;;!< car starts at centre
(define grid-origin-y 50)

(define (grid-ref x y)
  (if (and (>= x 0) (< x grid-W) (>= y 0) (< y grid-H))
    (vector-ref grid-data (+ (* y grid-W) x))
    -1))

(define (grid-set! x y val)
  (when (and (>= x 0) (< x grid-W) (>= y 0) (< y grid-H))
    (vector-set! grid-data (+ (* y grid-W) x) val)))

;;; Mark cells free along a ray from (ox oy) toward angle deg, distance cm.
(define (grid-ray! ox oy angle-deg dist-cm occupied?)
  (let* ((rad  (* angle-deg (/ 3.14159265 180.0)))
         (dx   (cos rad))
         (dy   (sin rad))
         (steps (inexact->exact (floor (/ dist-cm 10)))))  ;;!< 10 cm per cell
    (let loop ((i 0))
      (when (< i steps)
        (let ((cx (inexact->exact (round (+ ox (* i dx)))))
              (cy (inexact->exact (round (+ oy (* i dy))))))
          (when (= (grid-ref cx cy) 0)
            (grid-set! cx cy 1))       ;;!< mark free
          (loop (+ i 1)))))
    ;; mark endpoint occupied if hit
    (when occupied?
      (let ((ex (inexact->exact (round (+ ox (* steps dx)))))
            (ey (inexact->exact (round (+ oy (* steps dy))))))
        (grid-set! ex ey 2)))))

;;; Update map from a sweep result: list of (angle-deg . dist-cm) pairs.
(define (grid-update-sweep! sweep-result)
  (let* ((px (+ grid-origin-x (inexact->exact (round (/ (telem-get 'pose-x) 10)))))
         (py (+ grid-origin-y (inexact->exact (round (/ (telem-get 'pose-y) 10)))))
         (heading (telem-get 'heading)))
    (for-each
      (lambda (reading)
        (let* ((rel-angle (car reading))
               (dist      (cdr reading))
               (abs-angle (modulo (+ heading rel-angle) 360))
               (occupied? (< dist 200)))    ;;!< < 200 cm = wall
          (grid-ray! px py abs-angle dist occupied?)))
      sweep-result)))

;;; Render grid as an ASCII string (for SSE push or HTTP GET /map).
(define (grid->ascii)
  (let ((out (open-output-string)))
    (let yloop ((y 0))
      (when (< y grid-H)
        (let xloop ((x 0))
          (when (< x grid-W)
            (write-char
              (case (grid-ref x y)
                ((0) #\?)
                ((1) #\.)
                ((2) #\#)
                (else #\space))
              out)
            (xloop (+ x 1))))
        (write-char #\newline out)
        (yloop (+ y 1))))
    (get-output-string out)))

;;; ---------------------------------------------------------------------------
;;; Telemetry poll -- call periodically from supervisor loop
;;; ---------------------------------------------------------------------------

(define (telem-poll! car-conn now-ms)
  (guard (e (#t #f))  ;;!< ignore errors -- car may be momentarily busy
    (let ((t (llip-eval car-conn
               '(list (cons 'sonar   (get-sonar))
                      (cons 'battery (get-battery))
                      (cons 'light   (get-light))
                      (cons 'heading (robot-heading))
                      (cons 'pose-x  (car  (robot-pose)))
                      (cons 'pose-y  (cadr (robot-pose)))
                      (cons 'loop-ms (loop-elapsed-ms))
                      (cons 'ncells  (gc-free-cells))))))
      (when (pair? t)
        (for-each (lambda (p) (telem-set! (car p) (cdr p))) t)
        (set! telem-timestamp now-ms)
        #t))))

;;; Render telemetry as a JSON-like string for SSE.
(define (telem->json)
  (string-append
    "{"
    "\"sonar\":"   (number->string (telem-get 'sonar))   ","
    "\"battery\":" (number->string (telem-get 'battery)) ","
    "\"light\":"   (number->string (telem-get 'light))   ","
    "\"heading\":" (number->string (telem-get 'heading)) ","
    "\"pose_x\":"  (number->string (telem-get 'pose-x))  ","
    "\"pose_y\":"  (number->string (telem-get 'pose-y))  ","
    "\"loop_ms\":" (number->string (telem-get 'loop-ms)) ","
    "\"ncells\":"  (number->string (telem-get 'ncells))
    "}"))

