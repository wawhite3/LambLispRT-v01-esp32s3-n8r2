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
;;; R7RS 4.2.6  make-parameter / parameterize -- IMPLEMENTED, NOT STUBBED.
;;; The real definitions are in rxrs_continuations.scm (P168), which
;;; setup.scm loads BEFORE this file so the symbols are already bound when
;;; the bytecode compiler resolves them here.
;;;
;;; DO NOT RE-ADD A STUB FOR THESE.  A stub defined in this file loads
;;; AFTER rxrs_continuations.scm and therefore SILENTLY OVERRIDES the
;;; working implementation -- the symptom is that every parameterize /
;;; dynamic-wind / call/cc test raises "not yet implemented" while the
;;; implementation file loads without error, which reads like the shim
;;; failed rather than like it was overwritten.
;;; -----------------------------------------------------------------------

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
;;; Of the gaps listed above, only the LIBRARY keywords remain stubbed here:
;;; P168 implemented call/cc (escape-only), dynamic-wind and the parameter
;;; objects in rxrs_continuations.scm.  What is still a deliberate
;;; hard-real-time design gap is RE-ENTRANT call/cc, which needs a
;;; heap-allocated continuation the bounded-pause GC is built to avoid.
;;; See the exception block in ll_tests/r7rs-tests.scm.
;;; -----------------------------------------------------------------------

;;; call/cc, call-with-current-continuation and dynamic-wind are IMPLEMENTED in
;;; rxrs_continuations.scm (P168), loaded before this file.  call/cc there is
;;; ESCAPE-ONLY -- an escape is a tagged raise -- which covers the escape-shaped
;;; uses and NOT re-entrant ones (invoking k after its extent has exited).  The
;;; remaining r5rs-pitfall cases are exactly the re-entrant ones.  Again: do not
;;; re-add a stub here, it would load later and override the real definition.

;;; define-library / import / only / except / prefix / rename are now IMPLEMENTED, in
;;; scm/rxrs/rxrs_library.scm (P189), loaded from setup.scm just after this file.  The stub macros
;;; that used to sit here (raising "not implemented") were DELETED, not shadowed: after the tiers
;;; compile, a stub could still fire on a top-level `import` while conform stayed green (P189 §2).

