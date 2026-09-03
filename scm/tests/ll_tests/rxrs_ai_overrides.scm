;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "Defining quasiquote & helpers\n")
;;; =======================================================================
;;; quasiquote for LambLisp -- macro (code-generator) version
;;;
;;; Old approach: nlambda interpreter that called (eval x (current-environment))
;;; for each unquoted sub-expression, passing the caller's env explicitly.
;;;
;;; New approach (2026-04-23): quasiquote is a macro.  qq-do-depth walks the
;;; template and returns a Scheme expression (as data) built from cons/list/append.
;;; The macro mechanism evaluates that expression in the caller's environment, so
;;; unquoted sub-expressions resolve correctly without any env parameter.
;;; =======================================================================


;;; -----------------------------------------------------------------------
;;; qq-do-depth — core code generator
;;;
;;; tmpl  : unevaluated template (Scheme data)
;;; depth : nesting depth, starts at 1
;;; Returns: a Scheme expression that, when evaluated, produces the result.
;;; -----------------------------------------------------------------------

(define (qq-do-depth tmpl depth)
  (cond

    ;; Non-pair atom — emit (quote atom).
    ((not (pair? tmpl))
     (list 'quote tmpl))

    ;; (unquote x) at depth 1 — emit x as a bare expression for direct eval.
    ((and (eq? (car tmpl) 'unquote) (= depth 1))
     (cadr tmpl))

    ;; (unquote x) at depth > 1 — reconstruct (unquote ...) as data.
    ((eq? (car tmpl) 'unquote)
     (list 'list (list 'quote 'unquote)
                 (qq-do-depth (cadr tmpl) (- depth 1))))

    ;; (quasiquote x) — nested quasiquote, increment depth.
    ((eq? (car tmpl) 'quasiquote)
     (list 'list (list 'quote 'quasiquote)
                 (qq-do-depth (cadr tmpl) (+ depth 1))))

    ;; (unquote-splicing x) as car at depth 1 — append splice onto expanded cdr.
    ((and (pair? (car tmpl))
          (eq? (caar tmpl) 'unquote-splicing)
          (= depth 1))
     (list 'append (car (cdr (car tmpl)))
                   (qq-do-depth (cdr tmpl) depth)))

    ;; (unquote-splicing x) as car at depth > 1 — reconstruct as data.
    ((and (pair? (car tmpl))
          (eq? (caar tmpl) 'unquote-splicing))
     (list 'cons (list 'list (list 'quote 'unquote-splicing)
                             (qq-do-depth (car (cdr (car tmpl))) (- depth 1)))
                 (qq-do-depth (cdr tmpl) depth)))

    ;; Normal pair (including dotted) — cons expanded car onto expanded cdr.
    (else
     (list 'cons (qq-do-depth (car tmpl) depth)
                 (qq-do-depth (cdr tmpl) depth)))))


;;; -----------------------------------------------------------------------
;;; qq-do — public entry point (kept for compatibility)
;;; -----------------------------------------------------------------------

(define (qq-do tmpl)
  (qq-do-depth tmpl 1))


;;; -----------------------------------------------------------------------
;;; quasiquote and qq — macro expanders
;;;
;;; use-form is bound by macro to (template) -- i.e. cdr of (quasiquote template).
;;; qq-do-depth generates a code expression; the macro evaluates it in caller's env.
;;; -----------------------------------------------------------------------

(define quasiquote
  (macro use-form
    (qq-do-depth (car use-form) 1)))

(define qq
  (macro use-form
    (qq-do-depth (car use-form) 1)))

(syslog "Done defining quasiquote & helpers\n")

;;; syntax_rules.scm -- 2026-04-05 10:00:00
#|!
 syntax-rules for LambLisp -- R5RS compatible hygienic macros.

 Uses (nlambda use-form ...) with bare symbol rest-arg, returning a macro.
 All helpers are top-level defines so they live in the interaction environment,
 which is always in the nlambda body's env chain at call time.
 Mutual recursion (sr-match-one <-> sr-match-list, sr-expand-one <-> sr-expand-reps)
 works because both are defined before either is called.
|#


;;; -----------------------------------------------------------------------
;;; Utilities
;;; -----------------------------------------------------------------------

(define (sr-literal? sym literals)  ;;;!< #t if sym is a declared literal keyword
  (and (symbol? sym) (memq sym literals) #t))

(define (sr-pvar? sym literals)  ;;;!< #t if sym is a pattern variable
  (and (symbol? sym)
       (not (eq? sym '_))
       (not (eq? sym '...))
       (not (sr-literal? sym literals))))

(define (sr-ellipsis-next? lst)  ;;;!< #t if next token after car is ...
  (and (pair? lst) (pair? (cdr lst)) (eq? (cadr lst) '...)))

(define (sr-pvars-in pat literals)  ;;;!< collect all pattern variables from pat
  (cond
    ((sr-pvar? pat literals) (list pat))
    ((pair? pat) (append (sr-pvars-in (car pat) literals)
                         (sr-pvars-in (cdr pat) literals)))
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

(define (sr-filter pred lst)  ;;;!< keep elements satisfying pred (filter not in LambLisp)
  (letrec ((loop (lambda (l acc)
                   (if (null? l)
                       (reverse acc)
                       (loop (cdr l) (if (pred (car l)) (cons (car l) acc) acc))))))
    (loop lst (list))))

(define (sr-match-each sub lst literals)  ;;;!< match sub against each element of lst
  (letrec ((loop (lambda (rest acc)
                   (if (null? rest)
                       (reverse acc)
                       (let ((b (sr-match-one sub (car rest) literals)))
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

(define (sr-match-one pat inp literals)  ;;;!< match one pattern element against input
  (cond
    ((eq? pat '_) (list))
    ((sr-literal? pat literals) (if (and (symbol? inp) (eq? pat inp)) (list) #f))
    ((sr-pvar? pat literals) (list (cons pat inp)))
    ((and (null? pat) (null? inp)) (list))
    ((and (pair? pat) (pair? inp)) (sr-match-list pat inp literals))
    ((not (pair? pat)) (if (equal? pat inp) (list) #f))
    (else #f)))

(define (sr-match-list pat-tail inp-tail literals)  ;;;!< match pattern list tail against input tail
  (cond
    ((and (null? pat-tail) (null? inp-tail)) (list))
    ((null? pat-tail) #f)
    ((null? inp-tail)
     (if (not (sr-ellipsis-next? pat-tail))
         #f
         (let* ((sub    (car pat-tail))
                (rest-p (cddr pat-tail))
                (pvars  (sr-pvars-in sub literals))
                (zero-b (map (lambda (v) (cons v (list))) pvars))
                (rest-b (sr-match-list rest-p (list) literals)))
           (sr-merge zero-b rest-b))))
    ((sr-ellipsis-next? pat-tail)
     (let* ((sub    (car pat-tail))
            (rest-p (cddr pat-tail))
            (pvars  (sr-pvars-in sub literals))
            (n-rest (sr-list-len rest-p))
            (n-inp  (if (list? inp-tail) (length inp-tail) -1)))
       (if (< n-inp n-rest)
           #f
           (letrec ((scan (lambda (k)
                            (if (< k 0)
                                #f
                                (let* ((elems    (sr-list-head inp-tail k))
                                       (rest-inp (list-tail inp-tail k))
                                       (each-b   (sr-match-each sub elems literals))
                                       (rest-b   (and each-b (sr-match-list rest-p rest-inp literals))))
                                  (if (and each-b rest-b)
                                      (sr-merge (sr-zip-ell pvars each-b) rest-b)
                                      (scan (- k 1))))))))
             (scan (- n-inp n-rest))))))
    ((not (pair? pat-tail)) (sr-match-one pat-tail inp-tail literals))
    (else (sr-merge (sr-match-one  (car pat-tail) (car inp-tail) literals)
                    (sr-match-list (cdr pat-tail) (cdr inp-tail) literals)))))

(define (sr-match pattern input literals)  ;;;!< match full pattern against input, stripping heads
  (sr-match-list (cdr pattern) (cdr input) literals))


;;; -----------------------------------------------------------------------
;;; Template expansion
;;; -----------------------------------------------------------------------

(define (sr-expand-has-ell? lst)  ;;;!< #t if lst has ... as second element
  (and (pair? lst) (pair? (cdr lst)) (eq? (cadr lst) '...)))

(define (sr-expand-pvars-in t bindings)  ;;;!< collect bound pvars appearing in template t
  (cond
    ((and (symbol? t) (sr-lookup t bindings)) (list t))
    ((pair? t) (append (sr-expand-pvars-in (car t) bindings)
                       (sr-expand-pvars-in (cdr t) bindings)))
    (else (list))))

(define (sr-expand-evars-in sub bindings)  ;;;!< ellipsis-bound pvars in sub (those with list values)
  (sr-filter (lambda (v)
               (let ((p (sr-lookup v bindings)))
                 (and p (list? (cdr p)))))
             (sr-expand-pvars-in sub bindings)))

(define (sr-expand-one t bindings)  ;;;!< expand template t with bindings
  (cond
    ((and (symbol? t) (sr-lookup t bindings)) (cdr (sr-lookup t bindings)))
    ((not (pair? t)) t)
    ((sr-expand-has-ell? t)
     (let* ((sub   (car t))
            (rest  (cddr t))
            (evars (sr-expand-evars-in sub bindings))
            (n     (if (null? evars) 0 (length (cdr (sr-lookup (car evars) bindings)))))
            (iter-b (lambda (idx)
                      (map (lambda (b)
                             (if (memq (car b) evars)
                                 (cons (car b) (list-ref (cdr b) idx))
                                 b))
                           bindings)))
            (reps  (sr-expand-reps sub iter-b n 0)))
       (append reps (sr-expand-one rest bindings))))
    (else (cons (sr-expand-one (car t) bindings)
                (sr-expand-one (cdr t) bindings)))))

(define (sr-expand-reps sub iter-b n idx)  ;;;!< build list of n expansions of sub
  (if (= idx n)
      (list)
      (cons (sr-expand-one sub (iter-b idx))
            (sr-expand-reps sub iter-b n (+ idx 1)))))

(define (sr-expand tmpl bindings)  ;;;!< expand template with bindings (entry point)
  (sr-expand-one tmpl bindings))


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

(define (hy-flatten formals)  ;;;!< flatten formals to symbol list, skipping ...
  (cond
    ((null? formals)        (list))
    ((eq? formals '...)     (list))
    ((symbol? formals)      (list formals))
    ((pair? formals)        (if (eq? (car formals) '...)
                                (hy-flatten (cdr formals))
                                (append (hy-flatten (car formals))
                                        (hy-flatten (cdr formals)))))
    (else (list))))

(define (hy-formals formals subst pvars)  ;;;!< apply substitution to formals, preserving ...
  (cond
    ((null? formals)    (list))
    ((eq? formals '...) '...)
    ((symbol? formals)  (hy-subst formals subst pvars))
    ((pair? formals)    (cons (hy-subst (car formals) subst pvars)
                              (hy-formals (cdr formals) subst pvars)))
    (else formals)))

(define (hy-body body subst pvars)  ;;;!< hygienize a sequence of expressions
  (map (lambda (e) (hy-walk e subst pvars)) body))

(define (hy-bindings binds new-vars init-subst pvars)  ;;;!< hygienize binding pairs; pass ... through
  (map (lambda (b)
         (if (not (pair? b)) b
             (list (hy-subst (car b) new-vars pvars)
                   (hy-walk (cadr b) init-subst pvars))))
       binds))

(define (hy-walk tmpl subst pvars)  ;;;!< walk template tree applying hygiene renaming
  (cond
    ((symbol? tmpl) (hy-subst tmpl subst pvars))
    ((not (pair? tmpl)) tmpl)

    ;; (let ((v e) ...) body ...) -- standard let
    ((and (eq? (car tmpl) 'let) (pair? (cdr tmpl)) (pair? (cadr tmpl)))
     (let* ((binds    (cadr tmpl))
            (body     (cddr tmpl))
            (new-vars (hy-make-subst (map car (sr-filter pair? binds)) pvars))
            (new-s    (append new-vars subst)))
       (cons 'let (cons (hy-bindings binds new-vars subst pvars)
                        (hy-body body new-s pvars)))))

    ;; (let name ((v e) ...) body ...) -- named let
    ((and (eq? (car tmpl) 'let) (pair? (cdr tmpl)) (symbol? (cadr tmpl)))
     (let* ((name     (cadr tmpl))
            (binds    (caddr tmpl))
            (body     (cdddr tmpl))
            (new-name (if (sr-in-pvars? name pvars) name (gensym)))
            (new-vars (hy-make-subst (map car (sr-filter pair? binds)) pvars))
            (new-s    (append (list (cons name new-name)) new-vars subst)))
       (cons 'let (cons new-name (cons (hy-bindings binds new-vars subst pvars)
                                       (hy-body body new-s pvars))))))

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
                                                          (ni (hy-walk (cadr b) cur-s pvars)))
                                                     (build (cdr bs) ns (cons (list nv ni) acc)))))))))
                          (build binds subst (list)))))
       (cons 'let* (cons new-binds (hy-body body new-s pvars)))))

    ;; (letrec ...) and (letrec* ...)
    ((or (eq? (car tmpl) 'letrec) (eq? (car tmpl) 'letrec*))
     (let* ((kw       (car tmpl))
            (binds    (cadr tmpl))
            (body     (cddr tmpl))
            (new-vars (hy-make-subst (map car (sr-filter pair? binds)) pvars))
            (new-s    (append new-vars subst)))
       (cons kw (cons (hy-bindings binds new-vars new-s pvars)
                      (hy-body body new-s pvars)))))

    ;; (lambda formals body ...)
    ((eq? (car tmpl) 'lambda)
     (let* ((formals  (cadr tmpl))
            (body     (cddr tmpl))
            (new-vars (hy-make-subst (hy-flatten formals) pvars))
            (new-s    (append new-vars subst)))
       (cons 'lambda (cons (hy-formals formals new-vars pvars)
                           (hy-body body new-s pvars)))))

    ;; (define (f v ...) body ...)
    ((and (eq? (car tmpl) 'define) (pair? (cdr tmpl)) (pair? (cadr tmpl)))
     (let* ((head     (cadr tmpl))
            (params   (cdr head))
            (body     (cddr tmpl))
            (new-vars (hy-make-subst (hy-flatten params) pvars))
            (new-s    (append new-vars subst)))
       (cons 'define (cons (cons (car head) (hy-formals params new-vars pvars))
                           (hy-body body new-s pvars)))))

    ;; (define v e)
    ((eq? (car tmpl) 'define)
     (list 'define (cadr tmpl) (hy-walk (caddr tmpl) subst pvars)))

    ;; everything else -- recurse uniformly
    (else (cons (hy-walk (car tmpl) subst pvars)
                (hy-walk (cdr tmpl) subst pvars)))))

(define (sr-hygienize tmpl pvars)  ;;;!< entry point -- hygienize template given pvar set
  (hy-walk tmpl (list) pvars))


;;; -----------------------------------------------------------------------
;;; syntax-rules
;;;
;;; nlambda with bare symbol rest-arg -- captures whole arg list.
;;; (syntax-rules (lits...) (pat tmpl) ...)
;;; use-form = (lits... (pat tmpl) ...)
;;;
;;; Returns a macro. The macro uses bare symbol rest-arg too:
;;; (macro use-form ...) -- use-form captures cdr(call-form) = (arg ...).
;;; Body prepends _ giving (_ arg ...) for sr-match.
;;; -----------------------------------------------------------------------

(define syntax-rules
  (nlambda use-form
    (let* ((literals    (car use-form))
           (rules       (cdr use-form))
           (all-pvars   (sr-append-map (lambda (r) (sr-pvars-in (car r) literals)) rules))
           (clean-rules (map (lambda (r) (cons (car r) (sr-hygienize (cadr r) all-pvars))) rules)))
      (macro use-form
        (let ((input (cons '_ use-form)))
          (letrec ((try (lambda (rs)
                          (if (null? rs)
                              (error "syntax-rules: no matching pattern" input)
                              (let ((bindings (sr-match (caar rs) input literals)))
                                (if bindings
                                    (sr-expand (cdar rs) bindings)
                                    (try (cdr rs))))))))
            (try clean-rules)))))))

;;; -----------------------------------------------------------------------
;;; R7RS 6.6  char-foldcase  (Scheme override -- shadows C++ version)
;;; -----------------------------------------------------------------------

(define (char-foldcase c) (char-downcase c))

;;; -----------------------------------------------------------------------
;;; R7RS 6.7  string-foldcase  (Scheme override -- shadows C++ version)
;;; -----------------------------------------------------------------------

(define (string-foldcase s) (string-downcase s))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2.2  let-values  (Scheme override -- shadows C++ version)
;;; Parallel multi-value binding: all inits evaluated in the outer env,
;;; each ((var ...) expr) bound via call-with-values.
;;; -----------------------------------------------------------------------

(define-syntax let-values
  (syntax-rules ()
    ((let-values () body ...)
     (begin body ...))
    ((let-values (((var ...) expr) rest ...) body ...)
     (call-with-values (lambda () expr)
       (lambda (var ...) (let-values (rest ...) body ...))))))

;;; -----------------------------------------------------------------------
;;; R7RS 4.2.2  let*-values  (Scheme override -- shadows C++ version)
;;; Evaluates bindings left-to-right; each ((var ...) expr) calls expr via
;;; call-with-values and binds the returned values to the named vars.
;;; -----------------------------------------------------------------------

(define-syntax let*-values
  (syntax-rules ()
    ((let*-values () body ...)
     (begin body ...))
    ((let*-values (((var ...) expr) rest ...) body ...)
     (call-with-values (lambda () expr)
       (lambda (var ...) (let*-values (rest ...) body ...))))))

;;; -----------------------------------------------------------------------
;;; R7RS 6.4  map  (Scheme override -- shadows C++ version)
;;; Stops on the shortest list (R7RS semantics).  Left-to-right application order.
;;; -----------------------------------------------------------------------

#|!
  (map proc list ...)
  Applies proc to corresponding elements of one or more lists, returning
  a list of results.  Stops when the shortest list is exhausted.
|#
(define (map proc . list-of-lists)
  (letrec
    ((list-cars (lambda (lol)
                  (letrec ((fn (lambda (lol cars)
                                 (if (null? lol) (reverse! cars)
                                   (let ((l (car lol)))
                                     (if (null? l) (list)
                                       (fn (cdr lol) (cons (car l) cars))))))))
                    (fn lol (list)))))
     (list-cdrs (lambda (lol)
                  (letrec ((fn (lambda (lol cdrs)
                                 (if (null? lol) (reverse! cdrs)
                                   (let ((l (car lol)))
                                     (if (null? l) (list)
                                       (fn (cdr lol) (cons (cdr l) cdrs))))))))
                    (fn lol (list)))))
     (map-apply (lambda (lol res)
                  (if (null? lol) (reverse! res)
                    (let ((cars (list-cars lol)))
                      (if (null? cars) (reverse! res)
                        (map-apply (list-cdrs lol) (cons (apply proc cars) res))))))))
    (map-apply list-of-lists (list))))

;;; -----------------------------------------------------------------------
;;; R7RS 6.4  for-each  (Scheme override -- shadows C++ version)
;;; -----------------------------------------------------------------------

#|!
  (for-each proc list ...)
  Like map but called for side effects; result is unspecified.
|#
(define (for-each proc . lists)
  (apply map (cons proc lists))
  *undefined*)

;;; -----------------------------------------------------------------------
;;; R5RS 4.2.5  Promises  (Scheme overrides -- shadow C++ versions)
;;; Representation: ((done? . val-or-thunk))
;;; -----------------------------------------------------------------------

(define (make-promise done? proc) (list (cons done? proc)))

(define promise-done? (lambda (x) (caar x)))
(define promise-value (lambda (x) (cdar x)))

(define (promise-update! new old)
  (set-car! (car old) (promise-done? new))
  (set-cdr! (car old) (promise-value new))
  (set-car! new (car old)))

(define-syntax delay-force
  (syntax-rules ()
    ((delay-force expression)
     (make-promise #f (lambda () expression)))))

(define-syntax delay
  (syntax-rules ()
    ((delay expression)
     (delay-force (make-promise #t expression)))))

(define (force promise)
  (if (promise-done? promise)
    (promise-value promise)
    (let ((promise* ((promise-value promise))))
      (unless (promise-done? promise) (promise-update! promise* promise))
      (force promise))))
