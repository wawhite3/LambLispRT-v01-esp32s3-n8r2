;;; Copyright 2026 by Frobenius Norm LLC 2026-05-25
;;; Free for non-commercial use. Commercial use requires a license.
;;; rxrs_syntax_rules.scm -- R5RS-compatible hygienic macros (Scheme implementation).
;;; Overrides the C++ syntax-rules mop3 with this full Scheme version.
;;;
;;; Uses (nlambda use-form ...) with bare symbol rest-arg, returning a macro.
;;; All helpers are top-level defines so they live in the interaction environment.
;;; Mutual recursion (sr-match-one <-> sr-match-list, sr-expand-one <-> sr-expand-reps)
;;; works because both are defined before either is called.
;;;
;;; THE ELLIPSIS IS A PARAMETER, NOT THE SYMBOL `...` (B179).  R7RS 4.3.2's alternate form
;;;   (syntax-rules <ellipsis> (<literal> ...) <syntax rule> ...)
;;; lets the macro writer pick the repetition identifier, so every matcher, expander and hygiene
;;; helper below takes a trailing `ell` argument and compares against THAT -- never against a
;;; hardcoded '... .  If you add a helper that looks at repetition, give it the same trailing
;;; argument: a helper that hardcodes '... works for ordinary macros and silently mis-expands the
;;; alternate form (it will treat a custom ellipsis as an ordinary pattern variable, so `(x :::)`
;;; binds a variable named ::: instead of repeating).  `...` itself is an ORDINARY identifier once
;;; some other symbol is the ellipsis, and can then be matched literally.

;;; -----------------------------------------------------------------------
;;; Utilities
;;; -----------------------------------------------------------------------

(define (sr-literal? sym literals)  ;;;!< #t if sym is a declared literal keyword
  (and (symbol? sym) (memq sym literals) #t))

(define (sr-pvar? sym literals ell)  ;;;!< #t if sym is a pattern variable
  (and (symbol? sym)
       (not (eq? sym '_))
       (not (eq? sym ell))
       (not (sr-literal? sym literals))))

(define (sr-ellipsis-next? lst ell)  ;;;!< #t if the token after car is the ellipsis
  (and (pair? lst) (pair? (cdr lst)) (eq? (cadr lst) ell)))

(define (sr-pvars-in pat literals ell)  ;;;!< collect all pattern variables from pat
  (cond
    ((sr-pvar? pat literals ell) (list pat))
    ((pair? pat) (append (sr-pvars-in (car pat) literals ell)
                         (sr-pvars-in (cdr pat) literals ell)))
    ;; A vector pattern is matched as its element list (Scheme48's model), so its pattern
    ;; variables must be collected the same way -- otherwise #(a b) contributes none, and the
    ;; ellipsis machinery silently treats a as unbound.
    ((vector? pat) (sr-pvars-in (vector->list pat) literals ell))
    (else (list))))

(define (sr-lookup sym bindings)
  #|!< look up sym in alist -- returns PAIR or #f, never test value as boolean |#
  (cond
    ((null? bindings) #f)
    ((eq? (caar bindings) sym) (car bindings))
    (else (sr-lookup sym (cdr bindings)))))

(define (sr-merge b1 b2)  ;;;!< merge two binding alists -- #f = SR_FAIL
  (and b1 b2 (append b1 b2)))

(define (sr-list-len lst)  ;;;!< length of proper list, -1 for improper
  (letrec ((count (lambda (l n)
                    (cond ((null? l) n)
                          ((pair? l) (count (cdr l) (+ n 1)))
                          (else -1)))))
    (count lst 0)))

(define (sr-list-head lst k)  ;;;!< first k elements of lst
  (if (= k 0) (list)
      (cons (car lst) (sr-list-head (cdr lst) (- k 1)))))

(define (sr-filter pred lst)  ;;;!< keep elements satisfying pred
  (letrec ((loop (lambda (l acc)
                   (if (null? l)
                       (reverse acc)
                       (loop (cdr l) (if (pred (car l)) (cons (car l) acc) acc))))))
    (loop lst (list))))

(define (sr-match-each sub lst literals ell)  ;;;!< match sub against each element of lst
  (letrec ((loop (lambda (rest acc)
                   (if (null? rest)
                       (reverse acc)
                       (let ((b (sr-match-one sub (car rest) literals ell)))
                         (if b (loop (cdr rest) (cons b acc)) #f))))))
    (loop lst (list))))

(define (sr-zip-ell pvars each-binds)  ;;;!< zip per-element bindings into ellipsis bindings
  (map (lambda (pvar)
         (cons pvar (map (lambda (b)
                           (let ((p (sr-lookup pvar b)))
                             (if p (cdr p) #f)))
                         each-binds)))
       pvars))


;;; -----------------------------------------------------------------------
;;; Pattern matching
;;; -----------------------------------------------------------------------

(define (sr-match-one pat inp literals ell)  ;;;!< match one pattern element against input
  (cond
    ((eq? pat '_) (list))
    ((sr-literal? pat literals) (if (and (symbol? inp) (eq? pat inp)) (list) #f))
    ((sr-pvar? pat literals ell) (list (cons pat inp)))
    ((and (null? pat) (null? inp)) (list))
    ;; A PAIR PATTERN MUST BE ABLE TO MATCH THE EMPTY LIST.  This used to require (pair? inp), so a
    ;; sub-pattern like (a ...) could never match the input (), even though that is precisely the
    ;; zero-repetition case sr-match-list already handles in its (null? inp-tail) branch.  The
    ;; consequence was that ANY ellipsis group containing an empty list failed the whole match:
    ;; (m (1 2) (3) ()) against ((a ...) ...) raised "no matching rule" -- and it raised during
    ;; macroexpand1 inside read_list, i.e. at READ time, so `guard` could not catch it and the
    ;; entire enclosing form was discarded with no diagnostic.
    ((and (pair? pat) (or (pair? inp) (null? inp))) (sr-match-list pat inp literals ell))
    ;; Vectors match as their element lists -- the Scheme48 model.  Both sides must be vectors; a
    ;; vector pattern must not match a list, or #(a b) would match (1 2).
    ((and (vector? pat) (vector? inp))
     (sr-match-list (vector->list pat) (vector->list inp) literals ell))
    ((vector? pat) #f)
    ((not (pair? pat)) (if (equal? pat inp) (list) #f))
    (else #f)))

(define (sr-match-list pat-tail inp-tail literals ell)  ;;;!< match pattern list tail against input tail
  (cond
    ((and (null? pat-tail) (null? inp-tail)) (list))
    ((null? pat-tail) #f)
    ((null? inp-tail)
     (if (not (sr-ellipsis-next? pat-tail ell))
         #f
         (let* ((sub    (car pat-tail))
                (rest-p (cddr pat-tail))
                (pvars  (sr-pvars-in sub literals ell))
                (zero-b (map (lambda (v) (cons v (list))) pvars))
                (rest-b (sr-match-list rest-p (list) literals ell)))
           (sr-merge zero-b rest-b))))
    ((sr-ellipsis-next? pat-tail ell)
     (let* ((sub    (car pat-tail))
            (rest-p (cddr pat-tail))
            (pvars  (sr-pvars-in sub literals ell))
            (n-rest (sr-list-len rest-p))
            (n-inp  (if (list? inp-tail) (length inp-tail) -1)))
       (if (< n-inp n-rest)
           #f
           (letrec ((scan (lambda (k)
                            (if (< k 0)
                                #f
                                (let* ((elems    (sr-list-head inp-tail k))
                                       (rest-inp (list-tail inp-tail k))
                                       (each-b   (sr-match-each sub elems literals ell))
                                       (rest-b   (and each-b (sr-match-list rest-p rest-inp literals ell))))
                                  (if (and each-b rest-b)
                                      (sr-merge (sr-zip-ell pvars each-b) rest-b)
                                      (scan (- k 1))))))))
             (scan (- n-inp n-rest))))))
    ((not (pair? pat-tail)) (sr-match-one pat-tail inp-tail literals ell))
    (else (sr-merge (sr-match-one  (car pat-tail) (car inp-tail) literals ell)
                    (sr-match-list (cdr pat-tail) (cdr inp-tail) literals ell)))))

(define (sr-match pattern input literals ell)  ;;;!< match full pattern against input, stripping heads
  (sr-match-list (cdr pattern) (cdr input) literals ell))


;;; -----------------------------------------------------------------------
;;; Template expansion
;;; -----------------------------------------------------------------------

(define (sr-expand-has-ell? lst ell)  ;;;!< #t if lst has the ellipsis as second element
  (and (pair? lst) (pair? (cdr lst)) (eq? (cadr lst) ell)))

(define (sr-expand-pvars-in t bindings)  ;;;!< collect bound pvars appearing in template t
  (cond
    ((and (symbol? t) (sr-lookup t bindings)) (list t))
    ((pair? t) (append (sr-expand-pvars-in (car t) bindings)
                       (sr-expand-pvars-in (cdr t) bindings)))
    ((vector? t) (sr-expand-pvars-in (vector->list t) bindings))
    (else (list))))

(define (sr-expand-evars-in sub bindings)  ;;;!< ellipsis-bound pvars in sub
  (sr-filter (lambda (v)
               (let ((p (sr-lookup v bindings)))
                 (and p (list? (cdr p)))))
             (sr-expand-pvars-in sub bindings)))

(define (sr-expand-one t bindings ell)  ;;;!< expand template t with bindings
  (cond
    ((and (symbol? t) (sr-lookup t bindings)) (cdr (sr-lookup t bindings)))
    ;; A VECTOR TEMPLATE SUBSTITUTES, exactly like the list it is expanded as (Scheme48's model).
    ;; Without this it fell to the (not (pair? t)) clause below and was returned VERBATIM, so
    ;; ((_ a b) #(a b)) expanded to #(a b) -- a plausible-looking vector holding the pattern
    ;; variable NAMES, with nothing raised.  A silent wrong answer, which is worse than the two
    ;; vector gaps that at least failed loudly.  Ellipsis inside a vector works for free, because
    ;; the element list goes through the same expander.
    ((vector? t) (list->vector (sr-expand-one (vector->list t) bindings ell)))
    ((not (pair? t)) t)
    ((sr-expand-has-ell? t ell)
     (let* ((sub    (car t))
            (rest   (cddr t))
            (evars  (sr-expand-evars-in sub bindings))
            (n      (if (null? evars) 0 (length (cdr (sr-lookup (car evars) bindings)))))
            (iter-b (lambda (idx)
                      (map (lambda (b)
                             (if (memq (car b) evars)
                                 (cons (car b) (list-ref (cdr b) idx))
                                 b))
                           bindings)))
            (reps   (sr-expand-reps sub iter-b n 0 ell)))
       (append reps (sr-expand-one rest bindings ell))))
    (else (cons (sr-expand-one (car t) bindings ell)
                (sr-expand-one (cdr t) bindings ell)))))

(define (sr-expand-reps sub iter-b n idx ell)  ;;;!< build list of n expansions of sub
  (if (= idx n)
      (list)
      (cons (sr-expand-one sub (iter-b idx) ell)
            (sr-expand-reps sub iter-b n (+ idx 1) ell))))

(define (sr-expand tmpl bindings ell)  ;;;!< expand template with bindings (entry point)
  (sr-expand-one tmpl bindings ell))


;;; -----------------------------------------------------------------------
;;; Hygiene
;;; -----------------------------------------------------------------------

(define (sr-append-map f lst)  ;;;!< flatmap -- append results of mapping f over lst
  (letrec ((loop (lambda (l acc)
                   (if (null? l)
                       (reverse acc)
                       (letrec ((inner (lambda (items a)
                                         (if (null? items) a
                                             (inner (cdr items) (cons (car items) a))))))
                         (loop (cdr l) (inner (f (car l)) acc)))))))
    (loop lst (list))))

(define (sr-in-pvars? sym pvars)  ;;;!< #t if sym is in pvars list
  (and (symbol? sym) (memq sym pvars) #t))

(define (hy-subst sym subst pvars)  ;;;!< substitute sym via subst, unless it is a pvar
  (if (sr-in-pvars? sym pvars)
      sym
      (let ((p (assq sym subst)))
        (if p (cdr p) sym))))

(define (hy-make-subst syms pvars)  ;;;!< create fresh gensym substitution for non-pvar syms
  (map (lambda (s) (cons s (gensym)))
       (sr-filter (lambda (s) (not (sr-in-pvars? s pvars))) syms)))

(define (hy-flatten formals ell)  ;;;!< flatten formals to symbol list, skipping the ellipsis
  (cond
    ((null? formals)    (list))
    ((eq? formals ell)  (list))
    ((symbol? formals)  (list formals))
    ((pair? formals)    (if (eq? (car formals) ell)
                            (hy-flatten (cdr formals) ell)
                            (append (hy-flatten (car formals) ell)
                                    (hy-flatten (cdr formals) ell))))
    (else (list))))

(define (hy-formals formals subst pvars ell)  ;;;!< apply substitution to formals, preserving ellipsis
  (cond
    ((null? formals)    (list))
    ((eq? formals ell)  ell)
    ((symbol? formals)  (hy-subst formals subst pvars))
    ((pair? formals)    (cons (hy-subst (car formals) subst pvars)
                              (hy-formals (cdr formals) subst pvars ell)))
    (else formals)))

(define (hy-body body subst pvars ell)  ;;;!< hygienize a sequence of expressions
  (map (lambda (e) (hy-walk e subst pvars ell)) body))

(define (hy-bindings binds new-vars init-subst pvars ell)  ;;;!< hygienize binding pairs; pass ellipsis through
  (map (lambda (b)
         (if (not (pair? b)) b
             (list (hy-subst (car b) new-vars pvars)
                   (hy-walk (cadr b) init-subst pvars ell))))
       binds))

(define (hy-walk tmpl subst pvars ell)  ;;;!< walk template tree applying hygiene renaming
  (cond
    ((symbol? tmpl) (hy-subst tmpl subst pvars))
    ;; Descend into vector templates too: a free identifier inside #( ... ) needs the same renaming
    ;; a free identifier in a list gets, or hygiene has a hole shaped exactly like a vector.
    ((vector? tmpl) (list->vector (map (lambda (e) (hy-walk e subst pvars ell)) (vector->list tmpl))))
    ((not (pair? tmpl)) tmpl)

    ;; (let ((v e) ...) body ...) -- standard let
    ((and (eq? (car tmpl) 'let) (pair? (cdr tmpl)) (pair? (cadr tmpl)))
     (let* ((binds    (cadr tmpl))
            (body     (cddr tmpl))
            (new-vars (hy-make-subst (map car (sr-filter pair? binds)) pvars))
            (new-s    (append new-vars subst)))
       (cons 'let (cons (hy-bindings binds new-vars subst pvars ell)
                        (hy-body body new-s pvars ell)))))

    ;; (let name ((v e) ...) body ...) -- named let
    ((and (eq? (car tmpl) 'let) (pair? (cdr tmpl)) (symbol? (cadr tmpl)))
     (let* ((name     (cadr tmpl))
            (binds    (caddr tmpl))
            (body     (cdddr tmpl))
            (new-name (if (sr-in-pvars? name pvars) name (gensym)))
            (new-vars (hy-make-subst (map car (sr-filter pair? binds)) pvars))
            (new-s    (append (list (cons name new-name)) new-vars subst)))
       (cons 'let (cons new-name (cons (hy-bindings binds new-vars subst pvars ell)
                                       (hy-body body new-s pvars ell))))))

    ;; (let* ((v e) ...) body ...)
    ((eq? (car tmpl) 'let*)
     (let* ((binds     (cadr tmpl))
            (body      (cddr tmpl))
            (new-vars  (hy-make-subst (map car (sr-filter pair? binds)) pvars))
            (new-s     (append new-vars subst))
            (new-binds (letrec ((build (lambda (bs cur-s acc)
                                         (if (null? bs)
                                             (reverse acc)
                                             (let ((b (car bs)))
                                               (if (not (pair? b))
                                                   (build (cdr bs) cur-s (cons b acc))
                                                   (let* ((nv (cdr (assq (car b) new-vars)))
                                                          (ns (cons (cons (car b) nv) cur-s))
                                                          (ni (hy-walk (cadr b) cur-s pvars ell)))
                                                     (build (cdr bs) ns (cons (list nv ni) acc)))))))))
                          (build binds subst (list)))))
       (cons 'let* (cons new-binds (hy-body body new-s pvars ell)))))

    ;; (letrec ...) and (letrec* ...)
    ((or (eq? (car tmpl) 'letrec) (eq? (car tmpl) 'letrec*))
     (let* ((kw       (car tmpl))
            (binds    (cadr tmpl))
            (body     (cddr tmpl))
            (new-vars (hy-make-subst (map car (sr-filter pair? binds)) pvars))
            (new-s    (append new-vars subst)))
       (cons kw (cons (hy-bindings binds new-vars new-s pvars ell)
                      (hy-body body new-s pvars ell)))))

    ;; (lambda formals body ...)
    ((eq? (car tmpl) 'lambda)
     (let* ((formals  (cadr tmpl))
            (body     (cddr tmpl))
            (new-vars (hy-make-subst (hy-flatten formals ell) pvars))
            (new-s    (append new-vars subst)))
       (cons 'lambda (cons (hy-formals formals new-vars pvars ell)
                           (hy-body body new-s pvars ell)))))

    ;; (define (f v ...) body ...)
    ((and (eq? (car tmpl) 'define) (pair? (cdr tmpl)) (pair? (cadr tmpl)))
     (let* ((head     (cadr tmpl))
            (params   (cdr head))
            (body     (cddr tmpl))
            (new-vars (hy-make-subst (hy-flatten params ell) pvars))
            (new-s    (append new-vars subst)))
       (cons 'define (cons (cons (car head) (hy-formals params new-vars pvars ell))
                           (hy-body body new-s pvars ell)))))

    ;; (define v e)
    ((eq? (car tmpl) 'define)
     (list 'define (cadr tmpl) (hy-walk (caddr tmpl) subst pvars ell)))

    ;; everything else -- recurse uniformly
    (else (cons (hy-walk (car tmpl) subst pvars ell)
                (hy-walk (cdr tmpl) subst pvars ell)))))

(define (sr-hygienize tmpl pvars ell)  ;;;!< entry point -- hygienize template given pvar set
  (hy-walk tmpl (list) pvars ell))


;;; -----------------------------------------------------------------------
;;; syntax-rules -- Scheme implementation; overrides C++ mop3 version.
;;;
;;; (syntax-rules (lits...) (pat tmpl) ...)
;;; (syntax-rules <ellipsis> (lits...) (pat tmpl) ...)   -- R7RS 4.3.2 alternate form, B179
;;; use-form = (lits... (pat tmpl) ...)  -- captured by nlambda bare symbol
;;;
;;; Returns a macro whose body prepends _ to give (_ arg ...) for sr-match.
;;; -----------------------------------------------------------------------

(define syntax-rules
  (nlambda use-form
    ;; WHICH FORM IS THIS?  The element after the keyword is the literals LIST in the ordinary form
    ;; and the ellipsis IDENTIFIER in the alternate one, so `symbol?` decides.  () is not a symbol,
    ;; and neither is a non-empty literals list, so the ordinary form can never be misread as the
    ;; alternate one -- but note this DOES mean an alternate-form ellipsis must be a symbol, which
    ;; R7RS requires anyway.
    (let* ((alt?        (symbol? (car use-form)))
           (ell-given   (if alt? (car use-form) '...))
           (literals    (if alt? (cadr use-form) (car use-form)))
           (rules       (if alt? (cddr use-form) (cdr use-form)))
           ;; DECLARING THE ELLIPSIS A LITERAL TURNS REPETITION OFF (R7RS 4.3.2).  That is the point
           ;; of (syntax-rules ... (...) ((_ x) '(x ...))): with ... a literal it must match and
           ;; expand as ITSELF, so this macro has no ellipsis at all.  A fresh gensym cannot appear
           ;; in any pattern or template the reader produced, so it is the "no ellipsis" marker --
           ;; every ellipsis test below is (eq? tok ell) and none of them can now fire.
           (ell         (if (memq ell-given literals) (gensym) ell-given))
           (all-pvars   (sr-append-map (lambda (r) (sr-pvars-in (car r) literals ell)) rules))
           (clean-rules (map (lambda (r) (cons (car r) (sr-hygienize (cadr r) all-pvars ell))) rules)))
      (macro use-form
        (let ((input (cons '_ use-form)))
          (letrec ((try (lambda (rs)
                          (if (null? rs)
                              (error "syntax-rules: no matching pattern" input)
                              (let ((bindings (sr-match (caar rs) input literals ell)))
                                (if bindings
                                    (sr-expand (cdar rs) bindings ell)
                                    (try (cdr rs))))))))
            (try clean-rules)))))))

;;; R7RS 6.6  char-foldcase -- unicode case-folding; Latin-1 uses downcase
(define (char-foldcase c) (char-downcase c))

;;; R7RS 6.7  string-foldcase
(define (string-foldcase s) (string-downcase s))

