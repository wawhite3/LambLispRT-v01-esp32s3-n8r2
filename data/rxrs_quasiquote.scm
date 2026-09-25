;;; Copyright 2026 by Frobenius Norm LLC 2026-05-25
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_quasiquote.scm -- macro (code-generator) quasiquote.
;;;
;;; quasiquote is a macro: qq-do-depth walks the template and returns a
;;; Scheme expression built from cons/list/append.  The macro mechanism
;;; evaluates that expression in the caller's environment, so unquoted
;;; sub-expressions resolve correctly without any env parameter.

;;; -----------------------------------------------------------------------
;;; qq-do-depth -- core code generator
;;;
;;; tmpl  : unevaluated template (Scheme data)
;;; depth : nesting depth, starts at 1
;;; Returns: a Scheme expression that, when evaluated, produces the result.
;;; -----------------------------------------------------------------------

(define (qq-do-depth tmpl depth)
  (cond
    ;; Vector template -- expand element list as a list quasiquote, rebuild vector.
    ((vector? tmpl)
     (list 'list->vector (qq-do-depth (vector->list tmpl) depth)))

    ;; Non-pair atom -- emit (quote atom).
    ((not (pair? tmpl))
     (list 'quote tmpl))

    ;; (unquote x) at depth 1 -- emit x as a bare expression for direct eval.
    ((and (eq? (car tmpl) 'unquote) (= depth 1))
     (cadr tmpl))

    ;; (unquote x) at depth > 1 -- reconstruct (unquote ...) as data.
    ((eq? (car tmpl) 'unquote)
     (list 'list (list 'quote 'unquote)
                 (qq-do-depth (cadr tmpl) (- depth 1))))

    ;; (quasiquote x) -- nested quasiquote, increment depth.
    ((eq? (car tmpl) 'quasiquote)
     (list 'list (list 'quote 'quasiquote)
                 (qq-do-depth (cadr tmpl) (+ depth 1))))

    ;; (unquote-splicing x) as car at depth 1 -- append splice onto expanded cdr.
    ((and (pair? (car tmpl))
          (eq? (caar tmpl) 'unquote-splicing)
          (= depth 1))
     (list 'append (car (cdr (car tmpl)))
                   (qq-do-depth (cdr tmpl) depth)))

    ;; (unquote-splicing x) as car at depth > 1 -- reconstruct as data.
    ((and (pair? (car tmpl))
          (eq? (caar tmpl) 'unquote-splicing))
     (list 'cons (list 'list (list 'quote 'unquote-splicing)
                             (qq-do-depth (car (cdr (car tmpl))) (- depth 1)))
                 (qq-do-depth (cdr tmpl) depth)))

    ;; Normal pair (including dotted) -- cons expanded car onto expanded cdr.
    (else
     (list 'cons (qq-do-depth (car tmpl) depth)
                 (qq-do-depth (cdr tmpl) depth)))))

(define (qq-do tmpl)  ;;;!< public entry point; kept for compatibility
  (qq-do-depth tmpl 1))

;;; use-form is bound by macro to (template) -- i.e. cdr of (quasiquote template).
;;; qq-do-depth generates a code expression; the macro evaluates it in caller's env.
(define quasiquote
  (macro use-form
    (qq-do-depth (car use-form) 1)))

(define qq
  (macro use-form
    (qq-do-depth (car use-form) 1)))

