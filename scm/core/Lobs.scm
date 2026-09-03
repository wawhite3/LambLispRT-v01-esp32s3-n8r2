;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
#|! @name LambLisp Object System - LOBS

Lobs is based on the LambLisp first-class type *hierarchical dictionary*.
A *flat dictionary* is a single frame containing a set of (key . value) dotted pairs.  Frames may be implemented as association lists or something more complex like hash tables or vectors.

A *hierarchicl dictionary" is a list of frames, rather than a single frame as in the flat dictionary.

Each frame type is optimized for speed, so small frames are alists (association lists) while larger ones are hash tables of alists.

When a key (such as a symbol) is sought in the environment to determine its value, frames are searched from top to bottom, until the symbol is found or the end of the frame list is reached.
Internally Scheme uses the dictionary data structure to contain the execution environment as the application proceeds.
The execution environment has, as its last 2 frames, the frames containing the Scheme base environment and the Scheme interaction environment.

|#

(info "Loading Lobs\n")

(define (alist-swap alist)
  (let* ((fn (lambda (alist res)
	       (if (null? alist) res
		   (begin
		     (let* ((pair (car alist))
			    (new-pair (cons (var pair) (cdr pair)))
			    )
		       (fn (cdr alist) (cons new-pair res))
		       )
		     )
		   )
	       )
	     )
	 )
    (fn alist nil)
    )
  )

(define (alist-subset keys alist)
  (letrec ((fn (lambda (keys result)
		 (if (null? keys) result
		     (let ((pair (assq (car keys) alist))
			   )
		       (if pair
			   (fn (cdr keys) (cons pair result))
			   (fn (cdr keys) result)
			   )
		       )
		     )
		 )
	       )
	   )
    (fn keys nil)
    )
  )

(define (dict->obj dict-in)
  (let* ((dict-out (dict-add-alist-frame dict-in '((__dict__) (__self__))))
	 (dict-rdwr (lambda (key . args)
		      (if (null? args)
			  (dict-ref dict-out key)
			  (dict-rebind! dict-out key (car args))
			  )
		      )
		    )
	 )
    (dict-rebind! dict-out '__dict__ dict-out)
    (dict-rebind! dict-out '__self__ dict-rdwr)
    dict-rdwr
    )
  )

(define (typed-obj type dict-in)
  (let ((obj (dict->obj dict-in)))
    (obj '__type__ type)
    obj))

(define (lobs-type? obj type)
  (and (procedure? obj)
       (equal? (obj '__type__) type)))

(define (dict->alist dict)
  (letrec ((fn (lambda (dict keys alist)
		(if (null? keys) alist
		    (let ((pair (dict-ref dict (car keys)))
			  )
		      (fn dict (cdr keys) (cons pair alist))
		      )
		    )
		)
	       )
	   )
    (fn dict (dict-keys dict) nil)
    )
  )

(define (dict-swap dict)   (alist->dict (alist-swap (dict->alist dict))))
(define (alist->obj alist) (dict->obj (alist->dict alist)))
(define (2list->obj 2list) (dict->obj (2list->dict 2list)))

(define (Queue)
  (let ((qhead nil)
        (qtail nil))   ; qtail = last cons of qhead, so enqueue is O(1) -- no append/copy/garbage
    (lambda args       ; no args = pop the front item; else enqueue each arg at the tail
      (if (null? args)
          (if (null? qhead) #f                      ; nothing to pop
              (let ((res (car qhead)))
                (set! qhead (cdr qhead))
                (if (null? qhead) (set! qtail nil))  ; emptied -> drop the tail pointer
                res))
          (begin                                     ; enqueue O(1)/item: fresh cons spliced at the tail
            (for-each
             (lambda (x)
               (let ((cell (cons x nil)))
                 (if (null? qhead)
                     (begin (set! qhead cell) (set! qtail cell))
                     (begin (set-cdr! qtail cell) (set! qtail cell)))))
             args)
            qhead)))))

(define (Stack)
  (let ((top nil)
	)
    (lambda args	;if no args, pop the top item off the stack, otherwise prepend args stack.
      (if (null? args)		;no args, pop
	  (if (null? top) #f	;if no items on stack return #f
	      (let ((res (car top)))	;cache top item
		(set! top (cdr top))	;;remove top item from stack
		res			;;return popped item
		)
	      )
	  (begin	;arg(s) provided, append current stack to args, return new stack.
	    (set! top (append args top))
	    top		;ret val is the stack list
	    )
	  )
      )
    )
  )

(define (TimedQueue)
  (let* ((expiry 0)
	 (q (Queue))
	 (loop (lambda ()
		 (when (>= (millis) expiry)
		   (let ((next (q))
			 )
		     (when next
		       (set! expiry (+ (millis) (car next)))
		       ((cdr next))
		       )
		     )
		   )
		 )
	       )
	 (add (lambda (t task)
		(q (cons t task))
		)
	      )
	 )
    (lambda args
      (if (null? args) (loop)
	  (add (car args) (cadr args))
	  )
      )
    )
  )
