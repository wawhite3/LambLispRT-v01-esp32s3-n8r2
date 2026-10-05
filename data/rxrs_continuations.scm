;;; Copyright 2026 by Frobenius Norm LLC 2026-09-05 14:20:28
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_continuations.scm -- P168: escape-only continuations, dynamic-wind, parameters.
;;;
;;; WHY THIS FILE EXISTS, AND WHY IT IS SCHEME AND NOT C++.
;;; `raise-continuable` must return a value to the RAISE POINT: the handler's value becomes the
;;; value of the (raise-continuable ...) expression, so `(+ (raise-continuable x) 23)` still has
;;; to compute the +23.  The C++ mop3 cannot do that -- it throws, and the catch unwinds past the
;;; pending work, which is never reached.  Resuming needs no call/cc: the raise point is still on
;;; the stack, so calling the handler is an ORDINARY NESTED CALL.  The only thing missing was that
;;; the handler was not REACHABLE from the raise point -- the C++ mop3 keeps it in a C++ local and
;;; relies on try/catch to deliver control.
;;;
;;; A handler list in a SCHEME variable fixes exactly that.  The first design put the handler stack
;;; on the C stack, which dragged in the NCG unwind path (a longjmp invalidates C stack state and
;;; the JIT boundary pad would have had to restore it) and was rejected: "if it needs new detailed
;;; NCG then it's not worth it."  A longjmp does not touch a heap list.  That is the whole reason
;;; there is no C++ in this file and no codegen change of any kind.
;;;
;;; `raise` IS DELIBERATELY UNTOUCHED -- it still throws, so `guard` keeps the unwinding semantics
;;; the rest of the library is built on.  `raise-continuable` never throws.  That split is the
;;; entire risk surface of this file.
;;;
;;; MEASURED (P168): conform goes from 1337 pass / 0 fail / 33 exception to 1355 / 0 / 15, with
;;; ZERO new failures, verified in all three tiers (AST, bytecode, NCG).  The NCG tier matters
;;; because startup auto-compiles ~223 procedures, so this file WILL be compiled -- "works
;;; interpreted" would not have been good enough.
;;;
;;; A NOTE ON B205, WHICH IS FIXED -- read this before "hardening" anything here.
;;; P168 was designed while B205 was open: compiled closures captured enclosing locals BY VALUE, so
;;; "one lambda writes it, another reads it" silently gave the wrong answer under bytecode and NCG.
;;; This file was written to avoid that shape -- every mutable thing here is either a GLOBAL
;;; (*handlers*) or a variable one closure both reads and writes (make-parameter's `val`).
;;; **B205 was FIXED 2026-09-02 in master (cb9d43e)** and the cross-closure idiom now works in every
;;; tier -- verified 2026-09-05, AST and compiled both answer (in out) for the classic
;;; dynamic-wind trace idiom.  The structure here is kept because it is simple and correct, NOT
;;; because the language still forbids the alternative.  Do not propagate the old constraint as if
;;; it were still live.

(define %weh with-exception-handler)   ; the C++ mop3, kept for the throwing path
(define *handlers* (list))             ;;;!< innermost-first stack of installed handlers

#|!
  (with-exception-handler handler thunk)
  Wraps the C++ mop3 so the handler is also reachable from `raise-continuable` (which needs to CALL
  it, not be thrown to).  The throwing path is unchanged: %weh still delivers control via catch.
  The handler list is restored on BOTH exits -- normal return and the handler path -- because a
  longjmp past this frame must not leave a stale handler installed.
|#
(define (with-exception-handler handler thunk)
  (let ((saved *handlers*))
    (set! *handlers* (cons handler *handlers*))
    (let ((r (%weh (lambda (e) (set! *handlers* saved) (handler e)) thunk)))
      (set! *handlers* saved)
      r)))

#|!
  (raise-continuable obj)
  Calls the innermost handler and RETURNS ITS VALUE to the raise point.  R7RS 6.11 requires the
  handler to run with the OUTER handler installed, which is why the list is popped around the call.
  With no handler installed there is nothing to return to, so it degrades to `raise`.
|#
(define (raise-continuable obj)
  (if (null? *handlers*)
      (raise obj)                        ;; no handler installed: behave as `raise`
      (let ((h (car *handlers*)) (saved *handlers*))
        (set! *handlers* (cdr *handlers*))   ;; R7RS 6.11: handler runs with the OUTER handler
        (let ((v (h obj)))
          (set! *handlers* saved)
          v))))

#|!
  (dynamic-wind before thunk after)
  `after` runs on the normal exit and on the error unwind -- the handler runs it and re-raises, so
  the exception continues to propagate unchanged.  Complete for the escapes this implementation can
  produce, because there is no re-entrant continuation that could resume into the extent again.

  The ordinary idiom -- set a flag or append to a log in before/after and read it OUTSIDE -- used
  to be broken under BC/NCG by B205 (compiled closures captured enclosing locals by value).  B205 is
  FIXED (2026-09-02, master cb9d43e); measured 2026-09-05, the trace idiom answers (in out)
  identically interpreted and compiled.  No workaround is needed and none should be documented.
|#
(define (dynamic-wind before thunk after)
  (before)
  (let ((r (%weh (lambda (e) (after) (raise e)) thunk)))
    (after)
    r))

#|!
  (call-with-current-continuation f) -- ESCAPE-ONLY.
  An escape IS a tagged raise: `k` throws a uniquely-tagged pair, and the handler installed here
  catches its own tag and returns the value.  Any other exception is re-raised untouched.

  TWO LIMITS, both inherent and neither hidden:
  1. RE-ENTRANT continuations are absent and this does not fake them.  `(set! cont k)` and invoking
     k AFTER its extent has exited cannot work at any price here -- that needs real call/cc.
  2. A `guard` with a CATCH-ALL clause sitting between a call/cc and its `k` WILL SWALLOW THE
     ESCAPE, because the escape is a raise and the guard catches it first.  This is inherent to
     exceptions-as-escapes; it is written here so it is read rather than discovered.
|#
(define (call-with-current-continuation f)
  (let* ((tag (list 'cont))              ;; fresh pair => unique identity, compared with eq?
         (k   (lambda (v) (raise (cons tag v)))))
    (%weh (lambda (e) (if (and (pair? e) (eq? (car e) tag)) (cdr e) (raise e)))
          (lambda () (f k)))))
(define call/cc call-with-current-continuation)

#|!
  (make-parameter init [converter])
  A parameter is a closure over one mutable cell.  The converter runs on the initial value and on
  every `parameterize` entry, but NOT on the value restored on exit -- restoring a converted value
  through the converter would convert it twice.
  `val` is read and written by the SAME closure -- a shape that was always safe, including while
  B205 was open.
|#
(define (make-parameter init . conv)
  (let* ((cv  (if (pair? conv) (car conv) (lambda (x) x)))
         (val (cv init)))
    (lambda args
      (cond ((null? args) val)
            ((eq? (car args) '<set-conv>) (set! val (cv (cadr args))))
            ((eq? (car args) '<set-raw>)  (set! val (cadr args)))
            (else (error "parameter: bad call"))))))

;;; Two-list walk.  Written out rather than using for-each so this file depends on nothing loaded
;;; after it.
(define (%fe2 f a b) (if (pair? a) (begin (f (car a) (car b)) (%fe2 f (cdr a) (cdr b)))))

#|!
  (%parameterize-run params new-values thunk)
  The runtime half of `parameterize`.  New values go through the converter (<set-conv>), restored
  values do not (<set-raw>).
|#
(define (%parameterize-run ps nv thunk)
  (let ((olds (map (lambda (x) (x)) ps)))
    (dynamic-wind
      (lambda () (%fe2 (lambda (x w) (x '<set-conv> w)) ps nv))
      thunk
      (lambda () (%fe2 (lambda (x w) (x '<set-raw> w)) ps olds)))))

#|!
  (parameterize ((param value) ...) body ...)
  Expands to a call to an ORDINARY PROCEDURE rather than building the lambdas inline.  This is a
  style choice, not a workaround: the inline version was once thought to be broken inside a
  procedure body, but that was a missing GC root in mop3_sr_hygienize (fixed in the B251 sweep),
  not a hygiene rule.  The helper form is kept because it is one less thing for a reader to hold.
|#
(define-syntax parameterize
  (syntax-rules ()
    ((_ ((p v) ...) body ...)
     (%parameterize-run (list p ...) (list v ...) (lambda () body ...)))))
