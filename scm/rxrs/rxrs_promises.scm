;;; Copyright 2026 by Frobenius Norm LLC 2026-05-25
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_promises.scm -- R5RS 4.2.5 / R7RS 6.4  Promises.
;;; Shadows the C++ stubs (which return #<undef>) with correct behavior.

;;; %promise-tag is a unique cons cell; nothing else is eq? to it.
;;; This prevents user lists like '(promise ...) from passing promise?.
(define %promise-tag (list 'promise))

(define (%promise-make forced? val)  (cons %promise-tag (cons forced? val)))
(define (%promise-forced? p)         (car (cdr p)))
(define (%promise-value   p)         (cdr (cdr p)))
(define (%promise-set-forced! p)     (set-car! (cdr p) #t))
(define (%promise-set-value!  p v)   (set-cdr! (cdr p) v))
(define (%promise-redirect!   p q)   (set-cdr! p (cdr q)))  ;;;!< share q's mutable inner pair

#|!
  (promise? x)
  Returns #t if x is a promise created by delay, delay-force, or make-promise.
|#
(define (promise? x)
  (and (pair? x) (eq? (car x) %promise-tag)))

#|!
  (make-promise x)
  If x is already a promise, returns it unchanged.
  Otherwise wraps x in an already-forced promise so (force (make-promise x)) => x.
|#
(define (make-promise x)
  (if (promise? x)
    x
    (%promise-make #t x)))

#|!
  (delay expr)
  Returns a promise that, when forced, evaluates expr in the current lexical environment.
  expr is not evaluated until force is called.  The result is memoized.
|#
(define-syntax delay
  (syntax-rules ()
    ((delay expr)
     (%promise-make #f (lambda () expr)))))

#|!
  (delay-force expr)
  Like delay, but expr is expected to evaluate to a promise.
  force iteratively chases the resulting promise chain without growing the stack,
  enabling O(1)-space lazy streams and recursive lazy structures.
  Also available as: lazy
|#
(define-syntax delay-force
  (syntax-rules ()
    ((delay-force expr)
     (%promise-make #f (lambda () expr)))))

(define-syntax lazy
  (syntax-rules ()
    ((lazy expr)
     (%promise-make #f (lambda () expr)))))

#|!
  (force promise)
  Forces a promise: evaluates its thunk (if not yet done), caches the result, returns it.
  Non-promises are returned unchanged (R7RS).
  delay-force chains are followed iteratively -- no stack growth.
|#
(define (force p)
  (if (not (promise? p))
    p                                           ;; R7RS: non-promises pass through
    (let loop ((promise p))
      (if (%promise-forced? promise)
        (%promise-value promise)                ;; already memoized
        (let ((val ((%promise-value promise)))) ;; call the thunk
          (cond
            ((%promise-forced? promise)         ;; forced during recursive thunk call
             (%promise-value promise))
            ((promise? val)                     ;; delay-force: thunk returned a promise
             (%promise-redirect! promise val)   ;; share val's mutable inner pair
             (loop promise))                    ;; tail call -- iterate, no stack growth
            (else
             (%promise-set-forced! promise)
             (%promise-set-value!  promise val)
             val)))))))

