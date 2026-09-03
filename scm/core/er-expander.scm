;;; Copyright 2026 by Frobenius Norm LLC
;;; Explicit-renaming macro expander + syntax-rules, IN SCHEME on the ER C++ primitives
;;; (identifier? identifier->symbol bound-identifier=? free-identifier=? %er-memo %er-rename
;;; %ident-env gensym).  Original implementation of the standard ER/syntax-rules algorithm --
;;; not copied from any implementation.  Running the expander in Scheme means the base evaluator
;;; roots everything automatically, so the C++ manual-rooting GC bug class does not exist here.

;;; ---- syntactic environment R : alist of (bound-id . binding) --------------------------------
;;; binding is either a gensym (a lexical variable, alpha-renamed) or (macro <transformer> <def-env>).
(define (er-macro-b? b) (and (pair? b) (eq? (car b) 'er-macro)))
(define (er-mb-xform b) (cadr b))
(define (er-mb-env   b) (caddr b))

(define (er-assq id R)                         ; find (id . binding) by bound-identifier=?
  (cond ((null? R) #f)
        ((bound-identifier=? (caar R) id) (car R))
        (else (er-assq id (cdr R)))))

;;; A reference resolves to: its alpha-renamed gensym if bound here; else, if it is a renamed
;;; identifier, whatever it means in its OWN definition env (referential transparency); else itself.
(define (er-resolve id R)
  (let ((b (er-assq id R)))
    (cond ((and b (not (er-macro-b? (cdr b)))) (cdr b))     ; lexical variable -> gensym
          ((%ident-env id) => (lambda (em) (er-resolve (identifier->symbol id) em)))
          (else (identifier->symbol id)))))

;;; Global ER macros (top-level define-syntax): symbol -> (er-macro <transformer> <def-env='()>).
(define *er-macros* '())
(define (er-global-macro sym) (let ((p (assq sym *er-macros*))) (and p (cdr p))))
(define (er-install-macro! name tval)
  (let ((proc (if (and (pair? tval) (eq? (car tval) 'er-transformer)) (cadr tval) tval)))
    (set! *er-macros* (cons (cons name (list 'er-macro proc '())) *er-macros*))
    name))

;;; The macro binding a head denotes (locally, free-in-its-def-env, or global), else #f.
(define (er-macro-binding head R)
  (let ((b (er-assq head R)))
    (cond ((and b (er-macro-b? (cdr b))) (cdr b))
          (b #f)                                            ; locally a variable -> not a macro
          ((%ident-env head)
           => (lambda (em)
                (let ((b2 (er-assq (identifier->symbol head) em)))
                  (if (and b2 (er-macro-b? (cdr b2))) (cdr b2)
                      (er-global-macro (identifier->symbol head))))))
          (else (er-global-macro (identifier->symbol head))))))

;;; head is the keyword `name` iff it is an identifier, not shadowed by a local binding, base = name.
(define (er-kw? head R name)
  (and (identifier? head)
       (not (er-assq head R))
       (eq? (identifier->symbol head) name)))

(define (make-rename def-env)                  ; the `rename` handed to a transformer
  (let ((memo (%er-memo)))
    (lambda (id) (%er-rename id def-env memo))))

(define (er-compare a b) (free-identifier=? a b))   ; the `compare` handed to a transformer

;;; ---- the expander ---------------------------------------------------------------------------
(define (er-expand-list forms R) (map (lambda (f) (er-expand f R)) forms))

(define (er-rename-formals formals R)          ; -> (cons new-formals R2), handles proper/improper/rest
  (cond
    ((identifier? formals) (let ((g (gensym))) (cons g (cons (cons formals g) R))))
    ((pair? formals)
     (let* ((g  (gensym))
            (rest (er-rename-formals (cdr formals) (cons (cons (car formals) g) R))))
       (cons (cons g (car rest)) (cdr rest))))
    (else (cons '() R))))

(define (er-lambda form R)
  (let* ((fr   (er-rename-formals (cadr form) R))
         (R2   (cdr fr)))
    (cons (identifier->symbol (car form))       ; keep 'lambda
          (cons (car fr) (er-expand-list (cddr form) R2)))))

(define (er-let form R)                         ; (let ((v e)...) body...) -> ((lambda (v...) body) e...)
  (let ((binds (cadr form)) (body (cddr form)))
    (er-expand
      (cons (cons 'lambda (cons (map car binds) body)) (map cadr binds)) R)))

(define (er-letrec form R)                      ; bind all vars first, then expand inits+body
  (let* ((binds (cadr form)) (body (cddr form))
         (R2 (fold-right (lambda (b acc) (cons (cons (car b) (gensym)) acc)) R binds)))
    (cons (identifier->symbol (car form))       ; keep letrec/letrec*
          (cons (map (lambda (b) (list (cdr (er-assq (car b) R2)) (er-expand (cadr b) R2))) binds)
                (er-expand-list body R2)))))

(define (er-named-let form R)                   ; (let name ((v e)...) body...)
  (let ((name (cadr form)) (binds (caddr form)) (body (cdddr form)))
    (er-expand
      (cons (list 'letrec (list (list name (cons 'lambda (cons (map car binds) body)))) name)
            (map cadr binds)) R)))

(define (er-let-syntax form R rec)              ; let-syntax / letrec-syntax
  (let* ((binds (cadr form)) (body (cddr form))
         (mbs   (map (lambda (b)
                       (let ((tv (er-make-transformer (cadr b))))
                         (list 'er-macro (if (and (pair? tv) (eq? (car tv) 'er-transformer)) (cadr tv) tv) R)))
                     binds))
         (R2    (let zip ((bs binds) (ms mbs) (acc R))     ; LambLisp fold-right is single-list; zip manually
                  (if (null? bs) acc (zip (cdr bs) (cdr ms) (cons (cons (caar bs) (car ms)) acc))))))
    (if rec (for-each (lambda (mb) (set-car! (cddr mb) R2)) mbs))   ; letrec-syntax: def-env = R2 (self+siblings)
    (cons 'begin (er-expand-list body R2))))

(define (er-define form R)                      ; (define name val) or (define (f . args) body...)
  (let ((target (cadr form)))
    (if (pair? target)
        (er-define (list 'define (car target) (cons 'lambda (cons (cdr target) (cddr form)))) R)
        (list 'define (identifier->symbol target) (er-expand (caddr form) R)))))  ; global name kept, val expanded

(define (er-strip x)                            ; symbol-ify identifiers, keep structure (for name-only forms)
  (cond ((identifier? x) (identifier->symbol x))
        ((pair? x) (cons (er-strip (car x)) (er-strip (cdr x))))
        ((vector? x) (list->vector (map er-strip (vector->list x))))
        (else x)))

;;; Cycle-safe test: does x contain a renamed identifier (T_IDENT)?  Renamed ids only ever come from
;;; FINITE template literals; circular/shared data is always pattern-var source data with none.  So a
;;; quoted datum needs stripping ONLY when this returns #t -- and this returns #t only on finite data,
;;; so the subsequent er-strip never deep-walks a cycle.  `seen` guards against circular source data.
(define (er-has-ident? x seen)
  (cond ((and (identifier? x) (not (symbol? x))) #t)   ; a T_IDENT (plain symbols are fine as-is)
        ((pair? x) (if (memq x seen) #f
                       (let ((s (cons x seen))) (or (er-has-ident? (car x) s) (er-has-ident? (cdr x) s)))))
        ((vector? x) (er-has-ident? (vector->list x) seen))
        (else #f)))

(define (er-cond form R)                        ; clauses: (else e...) / (test => recip) / (test e...)
  (cons 'cond
    (map (lambda (cl)
           (cond ((er-kw? (car cl) R 'else) (cons 'else (er-expand-list (cdr cl) R)))
                 ((and (pair? (cdr cl)) (er-kw? (cadr cl) R '=>))
                  (list (er-expand (car cl) R) '=> (er-expand (caddr cl) R)))
                 (else (er-expand-list cl R))))
         (cdr form))))

(define (er-let* form R)                        ; desugar to nested let
  (let ((binds (cadr form)) (body (cddr form)))
    (if (null? binds)
        (er-expand (cons 'let (cons '() body)) R)
        (er-expand (list 'let (list (car binds)) (cons 'let* (cons (cdr binds) body))) R))))

(define (er-do form R)                          ; (do ((v init step)...) (test e...) cmd...)
  (let* ((specs (cadr form))
         (R2 (fold-right (lambda (s acc) (cons (cons (car s) (gensym)) acc)) R specs))
         (new-specs (map (lambda (s)
                           (let ((g (cdr (er-assq (car s) R2))))
                             (if (null? (cddr s))
                                 (list g (er-expand (cadr s) R))
                                 (list g (er-expand (cadr s) R) (er-expand (caddr s) R2)))))
                         specs))
         (tc (caddr form)))
    (cons 'do (cons new-specs
      (cons (cons (er-expand (car tc) R2) (er-expand-list (cdr tc) R2))
            (er-expand-list (cdddr form) R2))))))

(define (er-case-lambda form R)                 ; each clause is like a lambda
  (cons 'case-lambda
    (map (lambda (cl)
           (let ((fr (er-rename-formals (car cl) R)))
             (cons (car fr) (er-expand-list (cdr cl) (cdr fr)))))
         (cdr form))))

(define (er-define-values form R)               ; names are global bindings; only expr is expanded
  (list 'define-values (er-strip (cadr form)) (er-expand (caddr form) R)))

;;; head is a T_MACRO (old, non-ER macro) bound globally and not shadowed locally
(define (er-old-macro? head R)
  (and (identifier? head) (not (er-assq head R))
       (let ((s (identifier->symbol head)))
         (and (defined? s) (macro? (eval s (interaction-environment)))))))

(define (er-bridge form R)                       ; expand one step via legacy macroexpand1, then re-expand
  ;; legacy macroexpand1 keys on a SYMBOL head; ER may have renamed the head to a T_IDENT, which it
  ;; can't resolve (-> returns form unchanged -> we'd re-bridge forever).  Hand it a symbol head; the
  ;; args keep their renamed identifiers so hygiene survives the re-walk.
  (er-expand (eval (list 'macroexpand1 (cons (identifier->symbol (car form)) (cdr form)))
                   (interaction-environment)) R))

;;; Build a transformer value from a transformer SPEC, without destroying rule-identifier hygiene.
;;; A (syntax-rules ...) spec is handled directly (keyword matched by base symbol; escaped (... ...)
;;; T_IDENTs stay ellipsis-recognizable) so its rules keep their T_IDENTs -- essential for a macro that
;;; DEFINES a macro (pitfall 3.3).  Any other transformer expression (er-macro-transformer, a proc) is
;;; eval'd; strip renamed ids there so eval can resolve a macro-generated head (be-like-begin).
(define (er-make-transformer spec)
  (if (and (pair? spec) (identifier? (car spec)) (eq? (identifier->symbol (car spec)) 'syntax-rules))
      (er-rules->transformer (cadr spec) (cddr spec))
      (eval (er-strip spec) (interaction-environment))))

(define (er-dispatch mb form R)                 ; run a macro use, re-expand its output
  (let ((newform ((er-mb-xform mb) form (make-rename (er-mb-env mb)) er-compare)))
    (er-expand newform R)))

(define (er-expand form R)
  (cond
    ((identifier? form) (er-resolve form R))
    ((not (pair? form)) form)                                    ; self-evaluating literal
    (else
     (let* ((head (car form))
            (mb   (and (identifier? head) (er-macro-binding head R))))
       (cond
         (mb (er-dispatch mb form R))
         ((er-kw? head R 'quote)                                  ; strip renamed ids -> symbols, but
          (list 'quote (if (er-has-ident? (cadr form) '())        ; only when present (else keep verbatim,
                           (er-strip (cadr form)) (cadr form))))   ; preserving cycles/sharing of source data)
         ((er-kw? head R 'lambda) (er-lambda form R))
         ((er-kw? head R 'let)    (if (identifier? (cadr form)) (er-named-let form R) (er-let form R)))
         ((or (er-kw? head R 'letrec) (er-kw? head R 'letrec*)) (er-letrec form R))
         ((er-kw? head R 'let-syntax)    (er-let-syntax form R #f))
         ((er-kw? head R 'letrec-syntax) (er-let-syntax form R #t))
         ((er-kw? head R 'define-syntax)                          ; top-level: register global ER macro
          ;; the transformer spec may carry renamed ids (T_IDENT) when a macro GENERATED this
          ;; define-syntax (e.g. be-like-begin); eval can't resolve a T_IDENT head, so strip to symbols.
          (er-install-macro! (identifier->symbol (cadr form)) (er-make-transformer (caddr form)))
          (list 'quote (identifier->symbol (cadr form))))        ; no-op value
         ((er-kw? head R 'define) (er-define form R))
         ((er-kw? head R 'cond) (er-cond form R))
         ((er-kw? head R 'let*) (er-let* form R))
         ((er-kw? head R 'do)   (er-do form R))
         ((er-kw? head R 'case-lambda) (er-case-lambda form R))
         ((er-kw? head R 'define-values) (er-define-values form R))
         ((er-kw? head R 'define-record-type) (er-strip form))    ; all names, no sub-expressions
         ((or (er-kw? head R 'if) (er-kw? head R 'begin) (er-kw? head R 'and)
              (er-kw? head R 'or) (er-kw? head R 'set!) (er-kw? head R 'when) (er-kw? head R 'unless))
          (cons (identifier->symbol head) (er-expand-list (cdr form) R)))
         ((er-old-macro? head R) (er-bridge form R))              ; legacy T_MACRO -> expand + re-walk
         (else (er-expand-list form R)))))))                      ; application

;;; ---- syntax-rules on ER (standard match/instantiate algorithm, original code) ----------------
(define (er-macro-transformer proc) (list 'er-transformer proc))

(define sr-fail (list 'sr-fail))
(define (sr-ellipsis? x) (and (identifier? x) (eq? (identifier->symbol x) '...)))

(define (sr-pvars pat lits)
  (cond ((identifier? pat)
         (if (or (eq? (identifier->symbol pat) '_) (sr-ellipsis? pat) (sr-memq pat lits)) '() (list pat)))
        ((pair? pat) (append (sr-pvars (car pat) lits) (sr-pvars (cdr pat) lits)))
        ((vector? pat) (sr-pvars (vector->list pat) lits))
        (else '())))

(define (sr-memq id lst)                        ; literal membership by name
  (and (pair? lst)
       (or (and (identifier? (car lst)) (eq? (identifier->symbol (car lst)) (identifier->symbol id)))
           (sr-memq id (cdr lst)))))

(define (sr-match pat inp lits compare binds)
  (cond
    ((eq? binds sr-fail) sr-fail)
    ((identifier? pat)
     (cond ((eq? (identifier->symbol pat) '_) binds)
           ((sr-memq pat lits) (if (and (identifier? inp) (compare inp pat)) binds sr-fail))
           (else (cons (cons (identifier->symbol pat) inp) binds))))
    ((and (pair? pat) (pair? (cdr pat)) (sr-ellipsis? (cadr pat)))
     (sr-match-ell (car pat) (cddr pat) inp lits compare binds))
    ((pair? pat)
     (if (pair? inp)
         (sr-match (cdr pat) (cdr inp) lits compare (sr-match (car pat) (car inp) lits compare binds))
         sr-fail))
    ((null? pat) (if (null? inp) binds sr-fail))
    (else (if (equal? pat inp) binds sr-fail))))

(define (sr-match-ell sub rest inp lits compare binds)
  (let ((svars (sr-pvars sub lits)) (nrest (length rest)))
    (if (or (not (list? inp)) (< (length inp) nrest)) sr-fail
        (let loop ((k (- (length inp) nrest)) (in inp) (acc (map (lambda (v) (cons v '())) svars)))
          (if (= k 0)
              (sr-match rest in lits compare
                        (append (map (lambda (p) (cons (identifier->symbol (car p)) (cons 'sr-ell (reverse (cdr p))))) acc)
                                binds))
              (let ((b1 (sr-match sub (car in) lits compare '())))
                (if (eq? b1 sr-fail) sr-fail
                    (loop (- k 1) (cdr in)
                          (map (lambda (p) (cons (car p) (cons (cdr (assq (identifier->symbol (car p)) b1)) (cdr p)))) acc)))))))))

(define (sr-inst tmpl binds rename)
  (cond
    ((identifier? tmpl)
     (let ((b (assq (identifier->symbol tmpl) binds))) (if b (cdr b) (rename tmpl))))
    ((and (pair? tmpl) (sr-ellipsis? (car tmpl)) (pair? (cdr tmpl)))   ; (... escaped) -> escaped verbatim-ish
     (sr-inst-esc (cadr tmpl) binds rename))
    ((and (pair? tmpl) (pair? (cdr tmpl)) (sr-ellipsis? (cadr tmpl)))
     (append (sr-inst-ell (car tmpl) binds rename) (sr-inst (cddr tmpl) binds rename)))
    ((pair? tmpl) (cons (sr-inst (car tmpl) binds rename) (sr-inst (cdr tmpl) binds rename)))
    (else tmpl)))

(define (sr-inst-esc tmpl binds rename)         ; (... tmpl): ellipses in tmpl are literal
  (cond ((identifier? tmpl) (let ((b (assq (identifier->symbol tmpl) binds))) (if b (cdr b) (rename tmpl))))
        ((pair? tmpl) (cons (sr-inst-esc (car tmpl) binds rename) (sr-inst-esc (cdr tmpl) binds rename)))
        (else tmpl)))

(define (sr-inst-ell sub binds rename)
  (let* ((svars (sr-pvars sub '()))
         (evars (filter (lambda (v) (let ((b (assq (identifier->symbol v) binds)))
                                      (and b (pair? (cdr b)) (eq? (cadr b) 'sr-ell)))) svars)))
    (if (null? evars) '()
        (let ((lists (map (lambda (v) (cddr (assq (identifier->symbol v) binds))) evars)))
          (apply map (lambda vals
                       (sr-inst sub (append (map (lambda (v x) (cons (identifier->symbol v) x)) evars vals) binds) rename))
                 lists)))))

(define (sr-apply form rules lits rename compare)
  (cond ((null? rules) (error "syntax-rules: no matching rule" form))
        (else (let ((binds (sr-match (cdr (caar rules)) (cdr form) lits compare '())))
                (if (eq? binds sr-fail) (sr-apply form (cdr rules) lits rename compare)
                    (sr-inst (cadar rules) binds rename))))))

(define (er-rules->transformer lits rules)      ; core of syntax-rules; identifiers preserved for hygiene
  (er-macro-transformer (lambda (form rename compare) (sr-apply form rules lits rename compare))))

(define er-syntax-rules
  (nlambda spec (er-rules->transformer (car spec) (cdr spec))))

;;; top-level entry: expand a form in the empty syntactic env.
(define (er-expand-top form) (er-expand form '()))
