;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(info "Loading Timers\n")

;;;Stopwatch returns a procedure.  When called, the procedure returns the time (in ms) between the creation of the Stopwatch and the call.
#|
Usage:
(define elapsed (Stopwatch))
(code)
(more code)
(info "That took ~a time units\n" (elapsed))
|#

(define (Stopwatch_ms)
  (let ((t_start (millis)))
    (lambda ()
      (-i (millis) t_start))
    )
  )

(define (Stopwatch_us)
  (let ((t_start (micros)))
    (lambda ()
      (-i (micros) t_start))
    )
  )

;;;AutoTimer accepts a duration in milliseconds, returns a countdown procedure.
;;;The counter automatically restarts and returns #f when expired, otherwise returns the remaining time.
;;;The procedure is created in the "expired" state.  To start it running, call it immediately, as in (let ((t (AutoTimer_ms 1000))) (until (t) 'not-running))
;;;When the specified interval is 0, the timer will always return #f.
;;;
(define (AutoTimer_ms interval)
  (let* ((me "(AutoTimer_ms)")
	 (t_int (floor interval))	;ensure an integer
	 (t_end (millis))		;starts expired
	 )
    (lambda ()
      (let* ((now (millis))		;get current time
	     (t_rem (-i t_end now)))	;compute remaining time
	(if (positive? t_rem) t_rem	;if still running then return remaining time
	    (begin			;else not running, restart timer and return #f
	      (set! t_end (+i now t_int))
	      #f
	      )
	    )
	)
      )
    )
  )

(define (KitchenTimer_any timeFetcher . duration)
  (let* (
	 (t_dur (if (null? duration) 0 (car duration)))
	 (t_end (+ (timeFetcher) t_dur))
	 )
	 (alist->obj `(
		       (remaining ,(lambda ()
				     (let ((now (timeFetcher)))
				       (if (>= now t_end) 0 (-i t_end now))
				       )
				     )
				  )
		       (set!     ,(lambda (dur) (set! t_end (+i dur (timeFetcher)))))
		       (expired? ,(lambda () (>= (timeFetcher) t_end)))
		       (running? ,(lambda () (<  (timeFetcher) t_end)))
		       )
		     )
	 )
  )

(define (KitchenTimer_ms . duration)
  (KitchenTimer_any millis (if (null? duration) 0 (car duration)))
  )

(define (KitchenTimer_us . duration)
  (KitchenTimer_any micros (if (null? duration) 0 (car duration)))
  )

;;;Oneshot-tf returns a procedure that returns #t once and #f thereafter.
#|
Usage:
This example will print "oshot 1" but not "oshot 2".

(define oshot (Oneshot-tf))
(if (oshot) (info "oshot 1\n"))
(if (oshot) (info "oshot 2\n"))

|#
(define (Oneshot-tf)
  (let ((shot #f))
    (lambda ()
      (if shot #f
	  (begin (set! shot #t) #t)
	  )
      )
    )
  )

(define Oneshot Oneshot-tf)

(define uptime_ms
  (let ((t (Stopwatch_ms)))
    (lambda () (t))
    )
  )

;;Return #t if this loop has time available before the configured idle limit.
(define (is-idle idle_threshold) (< (Platform.loop-elapsed-ms) idle_threshold))

;;Return a procedure that, when called, returns #t if the interval has passed *and* this is a short loop.
;;When #t gets returned the interval timer is restarted.
;;
(define (make-idler idle-threshold quiet-interval max-interval)
  (let ((t (Stopwatch_ms))
	)
    (lambda ()
      (let* ((elapsed (t))
	     (tf (or (>= elapsed max-interval)
		     (and (>= elapsed quiet-interval)
			  (is-idle idle-threshold))
		     )
		 )
	     )
	(if tf (set! t (Stopwatch_ms)))
	tf
	)
      )
    )
  )

