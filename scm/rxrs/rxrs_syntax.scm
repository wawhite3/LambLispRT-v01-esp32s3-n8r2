;;; Copyright 2026 by Frobenius Norm LLC 2026-05-25
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_syntax.scm -- syntax-rules overrides for common special forms.
;;;
;;; These redefine C++ T_MOP3_NPROC versions as T_MACRO so that:
;;; (a) the bytecode compiler can inline them via macroexpand1 at compile time,
;;; (b) they expand hygienically.
;;;
;;; Load after rxrs_syntax_rules.scm so these use the Scheme syntax-rules.

;;; -----------------------------------------------------------------------
;;; R5RS 4.2.1  when / unless
;;; -----------------------------------------------------------------------

(define when
  (syntax-rules ()
    ((when test)
     (if #f #f))
    ((when test body ...)
     (if test (begin body ...) (if #f #f)))))

(define unless
  (syntax-rules ()
    ((unless test)
     (if #f #f))
    ((unless test body ...)
     (if (not test) (begin body ...) (if #f #f)))))

;;; -----------------------------------------------------------------------
;;; R5RS / R7RS 4.2.1  case
;;; -----------------------------------------------------------------------

(define case
  (syntax-rules (else =>)
    ((case key)
     (if #f #f))
    ((case key (else => proc))
     (proc key))
    ((case key (else expr ...))
     (begin expr ...))
    ((case key ((datum ...) => proc) rest ...)
     (if (memv key (quote (datum ...)))
       (proc key)
       (case key rest ...)))
    ((case key ((datum ...) expr ...) rest ...)
     (if (memv key (quote (datum ...)))
       (begin expr ...)
       (case key rest ...)))))

;;; -----------------------------------------------------------------------
;;; R5RS 4.2.2  letrec / letrec*
;;; Redefining as T_MACRO lets the bytecode compiler expand these at compile
;;; time instead of blocking on nproc-call.
;;; -----------------------------------------------------------------------

;;; B190: an EMPTY body is a SYNTAX ERROR (R7RS 4.2.2: a <body> is one or more expressions), and
;;; letrec needs its own rule because it cannot inherit let's C++ check.  It expands to
;;;     (let ((var #f) ...) (set! var init) ... body ...)
;;; whose body is NON-empty even when the user wrote none -- the (set! var init) forms fill it --
;;; so mop3_let sees a well-formed body and returns the last set!'s value.  That is why
;;; (letrec ((x 1))) used to evaluate to the SYMBOL x.  These first rules must stay FIRST:
;;; syntax-rules tries patterns in order, and the general rules below match an empty body too.
(define letrec
  (syntax-rules ()
    ((letrec (binding ...))
     (error "letrec: empty body -- a letrec body needs at least one expression (R7RS 4.2.2)"))
    ((letrec () body ...)
     (let () body ...))
    ((letrec ((var init) ...) body ...)
     (let ((var #f) ...)
       (set! var init) ...
       body ...))))

(define letrec*
  (syntax-rules ()
    ((letrec* (binding ...))
     (error "letrec*: empty body -- a letrec* body needs at least one expression (R7RS 4.2.2)"))
    ((letrec* () body ...)
     (let () body ...))
    ((letrec* ((var init) ...) body ...)
     (let* ((var #f) ...)
       (set! var init) ...
       body ...))))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2.2  let-values / let*-values
;;; -----------------------------------------------------------------------

(define let-values
  (syntax-rules ()
    ((let-values () body ...)
     (begin body ...))
    ((let-values (((var ...) expr) rest ...) body ...)
     (call-with-values (lambda () expr)
       (lambda (var ...) (let-values (rest ...) body ...))))))

(define let*-values
  (syntax-rules ()
    ((let*-values () body ...)
     (begin body ...))
    ((let*-values (((var ...) expr) rest ...) body ...)
     (call-with-values (lambda () expr)
       (lambda (var ...) (let*-values (rest ...) body ...))))))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2.6  make-parameter / parameterize  (stubs -- not yet implemented)
;;; Defined here so the bytecode compiler can resolve these symbols at
;;; compile time; otherwise an unbound-key C++ exception escapes any
;;; runtime guard and stalls the interpreter.  Tests that use these
;;; will get a Scheme error caught by guard and counted as FAIL.
;;; -----------------------------------------------------------------------

(define (make-parameter val . rest)
  (error "make-parameter: not yet implemented" val))

(define-syntax parameterize
  (syntax-rules ()
    ((_ bindings body ...)
     (error "parameterize: not yet implemented"))))

;;; -----------------------------------------------------------------------
;;; R7RS gaps that were UNBOUND rather than stubbed  (added 2026-08-29)
;;; Every documented gap now fails the SAME way: a Scheme error naming the
;;; feature, catchable by guard, with error-object? true and a message you
;;; can print.  Before this, make-parameter/parameterize raised a proper
;;; error-object while call/cc, dynamic-wind and the library keywords were
;;; simply absent -- so they surfaced as a VM-internal
;;;   Lamb::dict_ref() Unbound key 'call/cc'
;;; which error-object? rejects, error-object-message cannot read, and which
;;; reads like a typo rather than a design decision.  A caller could not tell
;;; "not implemented" from "you misspelled it".
;;; These are deliberate hard-real-time design gaps, not oversights: full
;;; call/cc requires a heap-allocated continuation the bounded-pause GC is
;;; built to avoid.  See the exception block in ll_tests/r7rs-tests.scm.
;;; -----------------------------------------------------------------------

(define (call-with-current-continuation proc)
  (error "call-with-current-continuation: not yet implemented (hard-real-time design gap)" proc))

(define (call/cc proc)
  (error "call/cc: not yet implemented (hard-real-time design gap)" proc))

(define (dynamic-wind before thunk after)
  (error "dynamic-wind: not yet implemented (requires continuations)" before))

(define-syntax define-library
  (syntax-rules ()
    ((_ rest ...)
     (error "define-library: the R7RS library system is not implemented"))))

;;; Import-set keywords -- only meaningful inside `import', and unbound on their own.
(define-syntax only
  (syntax-rules () ((_ rest ...) (error "only: the R7RS library system is not implemented"))))
(define-syntax except
  (syntax-rules () ((_ rest ...) (error "except: the R7RS library system is not implemented"))))
(define-syntax prefix
  (syntax-rules () ((_ rest ...) (error "prefix: the R7RS library system is not implemented"))))
(define-syntax rename
  (syntax-rules () ((_ rest ...) (error "rename: the R7RS library system is not implemented"))))

