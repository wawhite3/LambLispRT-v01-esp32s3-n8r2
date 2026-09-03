;;; Copyright 2026 by Frobenius Norm LLC 2026-05-25
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_cxr.scm -- R5RS 6.3.2  cXXXr and cXXXXr compositions.
;;; The 2-level forms (caar cadr cdar cddr) are built into the C++ VM.
;;; Pure a-chains use (caNr n x); pure d-chains use (cdNr n x).
;;; Mixed chains compose with the 2-level builtins.

;;; -----------------------------------------------------------------------
;;; 3-level (8 total)
;;; -----------------------------------------------------------------------

(define (caaar x) (caNr 3 x))           (define (cdaar x) (cdr (caar x)))
(define (caadr x) (car (cadr x)))       (define (cdadr x) (cdr (cadr x)))
(define (cadar x) (car (cdar x)))       (define (cddar x) (cdr (cdar x)))
(define (caddr x) (car (cddr x)))       (define (cdddr x) (cdNr 3 x))

;;; -----------------------------------------------------------------------
;;; 4-level (16 total)
;;; -----------------------------------------------------------------------

(define (caaaar x) (caNr 4 x))          (define (cdaaar x) (cdr (caNr 3 x)))
(define (caaadr x) (caNr 2 (cadr x)))   (define (cdaadr x) (cdr (caadr x)))
(define (caadar x) (caNr 2 (cdar x)))   (define (cdadar x) (cdr (cadar x)))
(define (caaddr x) (car (caddr x)))     (define (cdaddr x) (cdr (caddr x)))
(define (cadaar x) (car (cdaar x)))     (define (cddaar x) (cdNr 2 (caar x)))
(define (cadadr x) (car (cdadr x)))     (define (cddadr x) (cdNr 2 (cadr x)))
(define (caddar x) (car (cddar x)))     (define (cdddar x) (cdNr 3 (car x)))
(define (cadddr x) (car (cdddr x)))     (define (cddddr x) (cdNr 4 x))

