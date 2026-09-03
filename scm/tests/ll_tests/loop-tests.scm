;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
;;; Tests for looping constructs in LambLisp
;;; Run each expression and note the result.

;;; --- letrec with '() as first argument ---
(letrec ((f (lambda (x y) (cons x y))))
  (f '() '()))
;;; expected: (() . ())  i.e. (())... actually (() ) 
;;; if fails: LambLisp chokes on '() as first arg

(letrec ((f (lambda (x y) (cons x y))))
  (f 1 '()))
;;; expected: (1)

(letrec ((f (lambda (x y) (cons x y))))
  (f '() 1))
;;; expected: (() . 1)  i.e. (() . 1)

;;; --- reverse ---
(reverse '())
;;; expected: ()

(reverse '(1 2 3))
;;; expected: (3 2 1)

;;; --- the exact sr-match-each body ---
(letrec ((loop (lambda (tail acc)
                 (if (null? tail)
                     (reverse acc)
                     (let ((b (list (cons 'x (car tail)))))
                       (loop (cdr tail) (cons b acc)))))))
  (loop '() '()))
;;; expected: ()

(letrec ((loop (lambda (tail acc)
                 (if (null? tail)
                     (reverse acc)
                     (let ((b (list (cons 'x (car tail)))))
                       (loop (cdr tail) (cons b acc)))))))
  (loop '(1 2 3) '()))
;;; expected: (((x . 1)) ((x . 2)) ((x . 3)))

