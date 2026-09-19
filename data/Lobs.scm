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
  ;;; letrec*, NOT let* -- `fn` CALLS ITSELF, and a let* binding is not in scope for its own
  ;;; initializer.  Interpreted this works BY ACCIDENT (the closure holds the frame by reference and
  ;;; the binding exists by call time); COMPILED it does not -- the bytecode/NCG compiler gives a
  ;;; let* binding a local SLOT, so the self-call is not a local and compiles to a global lookup
  ;;; that fails with `Lamb::dict_ref() Unbound key 'fn'`.  Same defect as Buzzer.chirp's
  ;;; `queue-all`, which failed exactly that way on the 4WD once ncg-compile-environment! had run.
  ;;; letrec* keeps let*'s sequential left-to-right evaluation AND scopes every binding over every
  ;;; initializer, so it is correct in all three tiers.
  (letrec* ((fn (lambda (alist res)
	       (if (null? alist) res
		   (begin
		     (let* ((pair (car alist))
			    ;;; B286: was `(cons (var pair) (cdr pair))` -- TWO defects in one line.
			    ;;; `var` is bound NOWHERE in the tree, so this raised "Unbound key 'var'"
			    ;;; on the first element and alist-swap (and dict-swap, its only caller)
			    ;;; had never run since it was written.  And even with `car` in place of
			    ;;; `var` it built (car . cdr), which is a COPY, not a swap.
			    (new-pair (cons (cdr pair) (car pair)))
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

;;; dict->alist IS A C++ BUILTIN (Lamb::dict_to_alist, ll_vm_dict.cpp) AND THIS FILE USED TO
;;; SHADOW IT WITH A BROKEN SCHEME VERSION.  Removed 2026-09-05.  Two separate defects in one
;;; definition, and the shadowing is why neither was visible from the C++ side:
;;;
;;;   1. WRONG RESULT.  It built its list from `(dict-ref dict key)`, which returns the VALUE.
;;;      `dict-ref?` is the one that returns the (key . value) PAIR.  So `dict->alist` returned
;;;      a list of values -- (2 1) for a dict of ((a . 1) (b . 2)) -- which is `dict-values`
;;;      with the order reversed, not an alist at all.  That also broke `dict-swap` below, whose
;;;      `alist-swap` does (cdr pair) on every element.
;;;   2. O(n^2).  dict-keys followed by a dict-ref per key is exactly the pattern the C++
;;;      dict_to_2list comment says it was written to eliminate; this reintroduced it in Scheme.
;;;
;;; The builtin is single-pass and returns real pairs, so the fix is to STOP SHADOWING IT rather
;;; than repair the shadow.  If a Scheme-level dict->alist is ever wanted again, note that a
;;; `define` here silently overrides a correct builtin of the same name and nothing warns.

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
