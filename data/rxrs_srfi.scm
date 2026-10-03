;;; rxrs_srfi.scm -- small, widely-used SRFIs, ENTIRELY in Scheme over existing primitives.
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-09
;;;
;;; The "zero-risk bundle" (all NEW names, nothing shadowed): SRFI 8 receive, SRFI 2 and-let*,
;;; SRFI 26 cut/cute, SRFI 111 boxes, SRFI 145 assume.  No C++ change.  Each reuses primitives that
;;; already exist: call-with-values (receive), syntax-rules (the macros), define-record-type (boxes).
;;; SRFI 1's list library is a separate, larger proposal (it must consolidate scattered defs and
;;; match exact fold arg-order), not part of this bundle.

;;; ---- SRFI 8: receive -------------------------------------------------------------------------
;;; (receive formals mv-expr body ...) -- bind the multiple values of mv-expr to formals over body.
(define-syntax receive
  (syntax-rules ()
    ((_ formals mv-expr body0 body ...)
     (call-with-values (lambda () mv-expr) (lambda formals body0 body ...)))))

;;; ---- SRFI 2: and-let* ------------------------------------------------------------------------
;;; Guarded LET*: each claw is (var expr) | (expr) | bound-var.  Short-circuits on the first false.
;;; With a body, returns the body; with NO body, returns the value of the last claw (SRFI 2 exact).
(define-syntax and-let*
  (syntax-rules ()
    ((_ ()) #t)
    ((_ () body0 body ...) (begin body0 body ...))
    ;; last claw, no body -> its VALUE (not #t)
    ((_ ((var expr)))       (let ((var expr)) var))
    ((_ ((expr)))           expr)
    ((_ (bound-var))        bound-var)
    ;; recursive: claw then more claws and/or body
    ((_ ((var expr) claw ...) body ...) (let ((var expr)) (and var (and-let* (claw ...) body ...))))
    ((_ ((expr)     claw ...) body ...) (and expr       (and-let* (claw ...) body ...)))
    ((_ (bound-var  claw ...) body ...) (and bound-var  (and-let* (claw ...) body ...)))))

;;; ---- SRFI 26: cut / cute ---------------------------------------------------------------------
;;; (cut proc arg-or-<> ...) -> a lambda with one parameter per <>, in order; <...> = rest args.
;;; cute is cut except non-slot argument expressions are evaluated ONCE, at cute time.
;;;
;;; The textbook SRFI-26 macro reuses one template identifier `x` per <> and relies on hygiene to
;;; make each expansion's `x` DISTINCT.  LambLisp's syntax-rules does NOT uniquify a repeated
;;; template identifier across recursive expansion (measured: two <> both became `x`, giving
;;; (lambda (x x) ...) -- see B333).  So we thread an explicit SUPPLY of distinct slot names and
;;; consume one per <>.  Cap: 12 positional slots (plus an optional <...> rest), which is generous.
(define-syntax cut
  (syntax-rules (<> <...>)
    ((_ . args) (%srfi26-cut (s01 s02 s03 s04 s05 s06 s07 s08 s09 s10 s11 s12) () () . args))))

(define-syntax %srfi26-cut
  (syntax-rules (<> <...>)
    ((_ supply (slot ...) (proc arg ...))          (lambda (slot ...) (proc arg ...)))
    ((_ supply (slot ...) (proc arg ...) <...>)    (lambda (slot ... . rest) (apply proc arg ... rest)))
    ((_ (s0 s ...) (slot ...) (pos ...) <> se ...) (%srfi26-cut (s ...) (slot ... s0) (pos ... s0) se ...))
    ((_ supply (slot ...) (pos ...) nse se ...)    (%srfi26-cut supply (slot ...) (pos ... nse) se ...))))

(define-syntax cute
  (syntax-rules (<> <...>)
    ((_ . args) (%srfi26-cute (s01 s02 s03 s04 s05 s06 s07 s08 s09 s10 s11 s12) () () () . args))))

(define-syntax %srfi26-cute
  (syntax-rules (<> <...>)
    ((_ supply (slot ...) binds (proc arg ...))         (let binds (lambda (slot ...) (proc arg ...))))
    ((_ supply (slot ...) binds (proc arg ...) <...>)   (let binds (lambda (slot ... . rest) (apply proc arg ... rest))))
    ((_ (s0 s ...) (slot ...) binds (pos ...) <> se ...) (%srfi26-cute (s ...) (slot ... s0) binds (pos ... s0) se ...))
    ((_ supply (slot ...) (bind ...) (pos ...) nse se ...)
     (%srfi26-cute supply (slot ...) (bind ... (b nse)) (pos ... b) se ...))))

;;; ---- SRFI 111: boxes -------------------------------------------------------------------------
;;; A single mutable cell, as a DISTINCT type (define-record-type gives box? for free).
(define-record-type <box> (box value) box? (value unbox set-box!))

;;; ---- SRFI 145: assume ------------------------------------------------------------------------
;;; (assume expr msg ...) -- an assertion the caller states is always true.  On #f, raise with the
;;; failing expression (quoted) and any messages; otherwise return #t.  (SRFI 145 leaves the true
;;; value unspecified; #t is a fine choice.)
(define-syntax assume
  (syntax-rules ()
    ((_ expr msg ...) (if expr #t (error "SRFI 145 assumption violated" (quote expr) msg ...)))))
