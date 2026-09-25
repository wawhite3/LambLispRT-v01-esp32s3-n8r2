;;; Copyright 2026 by Frobenius Norm LLC 2026-05-25
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_exceptions.scm -- R7RS 6.11  Exception objects and guard.
;;; raise / raise-continuable / with-exception-handler are C++ mop3.
;;; error objects are represented as (error-object "message" (irritant ...)).

(define (error message . irritants)   (raise (list 'error-object message irritants)))
(define (error-object? obj)           (and (pair? obj) (eq? (car obj) 'error-object)))
(define (error-object-message obj)    (cadr obj))
(define (error-object-irritants obj)  (caddr obj))

#|!
  (guard (var clause ...) body ...)
  Evaluates body; if an exception is raised, binds the raised object to var
  and evaluates the cond clauses.  If no clause matches, re-raises the object.
  If the last clause is (else ...) the second rule handles it directly.
|#
(define-syntax guard
  (syntax-rules (else)
    ((guard (var (else e1 e2 ...)) body ...)
     (with-exception-handler (lambda (var) e1 e2 ...) (lambda () body ...)))
    ((guard (var clause ...) body ...)
     (with-exception-handler (lambda (var) (cond clause ... (else (raise var)))) (lambda () body ...)))))

