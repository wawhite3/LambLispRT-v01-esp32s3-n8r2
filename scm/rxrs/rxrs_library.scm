;;; rxrs_library.scm -- R7RS-small §5.6 define-library / import, ENTIRELY in Scheme (P189).
;;; Copyright 2026 by Frobenius Norm LLC 2026-09-09
;;;
;;; VERIFIED 2026-09-09 on linux_x86_64: conform 1360 pass / 0 fail / 10 exception (was 1355/0/15)
;;; -- the 5 closed are exactly import/only, import/except, import/prefix, import/rename,
;;; define-library/import; the remaining 10 are all call/cc.  Works on all three tiers: AST (conform),
;;; bytecode (startup compile-environment! compiles these nlambdas), and NCG ((ncg-nested 9 leak #f)).
;;; Load cost: 747 live cells, 1 ms (P189 §7 settle-on-both-sides method).
;;;
;;; No C++ and no VM change: LambLisp already exposes the reflection this needs --
;;; dict-add-empty-frame (a private frame), eval-into-an-environment, dict-bind! (into the caller),
;;; interaction-environment, dict-keys, and nlambda (receive the form unevaluated).  See
;;; proposal_r7rs_library_P189.md; the feasibility probe is w3_ai_scripts/probe_r7rs_library.scm.
;;;
;;; This OVERRIDES the C++ `import` (ll_vm_mop3_rxrs.cpp mop3_import, a registered no-op nproc):
;;; grepping src/ for "import" finds a live registration that no longer runs -- it is what makes the
;;; reader treat `import` as taking a NAME, not an expression, and this file inherits that.
;;;
;;; PRIVACY falls out of the construction, it is not enforced: the library's frame is dropped after
;;; the exports are read, so an unexported binding is unreachable.  MACRO EXPORT IS SOUND: a macro
;;; whose template references a library-private helper resolves to THAT library's helper, even across
;;; two libraries with a same-named private helper -- verified 2026-09-09, (lib a)/(lib b) gives the
;;; correct (from-A (A 1) from-B (B 2)) with distinct hygiene aliases.  (P189 §4c predicted a
;;; collision here, measured 2026-09-07; that was already fixed the same day by B314 -- the alias is
;;; keyed on the DEFINITION BINDING PAIR plus a counter, not the name.  B332, which re-filed it from
;;; the stale §4c text, is INVALID/duplicate.)
;;;
;;; EXPORTS ARE SNAPSHOTS (P189 §6): an exported VALUE is copied at define-library time, so a
;;; library that mutates its own exported variable leaves the importer reading a stale value.
;;; Export procedures and macros; a warn fires when a mutable (non-proc, non-macro) value is
;;; exported so the freeze is announced at definition, not debugged at use.
;;;
;;; PORTABILITY ASYMMETRY (P189 §5): code written for another R7RS runs here; code written HERE may
;;; not run there.  A library body sees the whole global environment whether it imported it or not
;;; (the frame's parent IS the interaction environment), so a forgotten import works on LambLisp and
;;; is an unbound-variable error everywhere else.

(define *libraries* (list))   ;;;!< ((<name-list> . <export-alist>) ...), newest-first.

;;; Key on the NAME LIST with equal?, NOT a flattened string: (a b) and the one-symbol (a/b) must
;;; not collide.  Newest-first assoc gives redefinition-wins for free (what a REPL needs).
(define (%library-lookup name) (assoc name *libraries*))

;;; Phase-1 not-found hook.  Phase 2 replaces this with library-name -> file resolution; keeping the
;;; call site here is the difference between ADDING Phase 2 and rewriting for it.
(define (%name->path name)   ;; (a b c) -> "a/b/c"
  (if (null? (cdr name)) (symbol->string (car name))
      (string-append (symbol->string (car name)) "/" (%name->path (cdr name)))))

;;; Phase 2: resolve an unloaded library to a file, load it, and re-check the registry.  Convention:
;;; (a b c) -> "a/b/c.scm", falling back to the last component "c.scm" (the flat-FS common case).
;;; Returns the export alist or #f.  The %library-resolve NAME stayed a hook through Phase 1 so this
;;; is an ADDITION, not a rewrite (P189 §3.3).
(define (%library-resolve name)
  (let ((cand1 (string-append (%name->path name) ".scm"))
        (cand2 (string-append (symbol->string (car (reverse name))) ".scm")))
    (cond ((and (file-exists? cand1) (begin (load cand1 0) (%library-lookup name))) => cdr)
          ((and (file-exists? cand2) (begin (load cand2 0) (%library-lookup name))) => cdr)
          (else #f))))

;;; Phase 2: cond-expand feature requirement matcher (SRFI 0 / R7RS 4.2.1), tested against the
;;; existing (features) -- (lamblisp r7rs ieee-float ...).  and/or/not/library nest.  `library`
;;; tests OUR registry, which the C++ cond-expand cannot.
(define (%feature-satisfied? req)
  (cond ((eq? req (quote else)) #t)
        ((symbol? req) (and (memq req (features)) #t))
        ((pair? req)
         (cond ((eq? (car req) (quote and)) (every %feature-satisfied? (cdr req)))
               ((eq? (car req) (quote or))  (any   %feature-satisfied? (cdr req)))
               ((eq? (car req) (quote not)) (not (%feature-satisfied? (cadr req))))
               ((eq? (car req) (quote library)) (and (%library-lookup (cadr req)) #t))
               (else #f)))
        (else #f)))

(define (%cond-expand-winner ce-clauses)   ;; ((req decl...) ...) -> winning clause's decls, or ()
  (cond ((null? ce-clauses) (list))
        ((%feature-satisfied? (car (car ce-clauses))) (cdr (car ce-clauses)))
        (else (%cond-expand-winner (cdr ce-clauses)))))

;;; Phase 2: flatten cond-expand clauses into a plain declaration list, recursively (a winning clause
;;; may itself hold cond-expand or include).  define-library then processes the flat list.
(define (%expand-decls clauses)
  (if (null? clauses) (list)
      (let ((c (car clauses)))
        (if (and (pair? c) (eq? (car c) (quote cond-expand)))
            (append (%expand-decls (%cond-expand-winner (cdr c))) (%expand-decls (cdr clauses)))
            (cons c (%expand-decls (cdr clauses)))))))


;;; define-library: an nlambda over (<name> <clause> ...).  Make a private frame, run the clauses in
;;; a FIXED order-independent dispatch, then read the exports out and drop the frame.
(define define-library
  (nlambda form
    (let ((name    (car form))
          (clauses (cdr form))
          (env     (dict-add-empty-frame (interaction-environment)))
          (exports (list)))   ;; alist (external-name . internal-name), reversed at the end
      (for-each
        (lambda (c)
          (if (not (pair? c)) (error "define-library: bad clause (not a list)" c))
          (cond
            ;; export: sym  OR  (rename internal external).  Accumulate (external . internal).
            ((eq? (car c) 'export)
             (for-each
               (lambda (e)
                 (cond ((symbol? e) (set! exports (cons (cons e e) exports)))
                       ((and (pair? e) (eq? (car e) 'rename) (pair? (cdr e)) (pair? (cddr e)))
                        (set! exports (cons (cons (caddr e) (cadr e)) exports)))
                       (else (error "define-library: bad export spec" e))))
               (cdr c)))
            ;; begin: evaluate each form INTO the library frame.
            ((eq? (car c) 'begin)
             (for-each (lambda (f) (eval f env)) (cdr c)))
            ;; import inside a library: bind the imported names into the library frame (not silently
            ;; ignored -- P189 §3.2).  Uses the same resolver as top-level import.
            ((eq? (car c) 'import)
             (for-each (lambda (spec)
                         (for-each (lambda (p) (dict-bind! env (car p) (cdr p)))
                                   (%import-set-exports spec)))
                       (cdr c)))
            ;; include / include-ci: delegate to the C++ primitives, EVALUATED INTO the library
            ;; frame -- via eval, env is their env_exec, so the file's definitions land in the frame.
            ;; This is why include-ci is now correct: the C++ include-ci sets the reader case-fold flag
            ;; (reader_fold_case, honouring #!fold-case) which a Scheme read loop could not.  R7RS 5.6.3.
            ((memq (car c) '(include include-ci))
             (eval (cons (car c) (cdr c)) env))
            ;; cond-expand is flattened out by %expand-decls before we get here; a leftover is a bug.
            ((eq? (car c) 'cond-expand)
             (error "define-library: cond-expand should have been flattened -- internal error" c))
            (else (error "define-library: unknown clause" (car c)))))
        (%expand-decls clauses))
      ;; Read each export's VALUE out of the frame (snapshot), warn on a frozen mutable, register.
      (let ((table
             (map (lambda (pr)
                    (let ((ext (car pr)) (val (eval (cdr pr) env)))
                      (if (and (not (procedure? val)) (not (macro? val)))
                          (warn "define-library ~a: exporting non-procedure/non-macro ~a -- it is a FROZEN snapshot (P189 §6)\n" name ext))
                      (cons ext val)))
                  (reverse exports))))
        (set! *libraries* (cons (cons name table) *libraries*))
        name))))

;;; Resolve an import set to an export alist ((name . value) ...).  RECURSIVE post-order walk: an
;;; import set is a tree, so only/except/prefix/rename nest in any order to any depth.  Do NOT turn
;;; this into a flag-collecting loop -- it could not express (only (prefix ...) ...).
(define (%import-set-exports spec)
  (cond
    ((not (pair? spec)) (error "import: bad import set" spec))
    ;; (only <set> id ...) -- id ... MUST be exported, else a later unbound-variable error names a
    ;; symbol the user believes they imported.
    ((eq? (car spec) 'only)
     (let ((tbl (%import-set-exports (cadr spec))) (want (cddr spec)))
       (for-each (lambda (id) (if (not (assq id tbl)) (error "import (only ...): identifier not exported" id))) want)
       (filter (lambda (p) (memq (car p) want)) tbl)))
    ((eq? (car spec) 'except)
     (let ((tbl (%import-set-exports (cadr spec))) (drop (cddr spec)))
       (filter (lambda (p) (not (memq (car p) drop))) tbl)))
    ((eq? (car spec) 'prefix)
     (let ((tbl (%import-set-exports (cadr spec))) (pre (symbol->string (caddr spec))))
       (map (lambda (p) (cons (string->symbol (string-append pre (symbol->string (car p)))) (cdr p))) tbl)))
    ;; (rename <set> (from to) ...) -- from ... MUST be exported.
    ((eq? (car spec) 'rename)
     (let ((tbl (%import-set-exports (cadr spec))) (rl (cddr spec)))
       (for-each (lambda (r) (if (not (assq (car r) tbl)) (error "import (rename ...): identifier not exported" (car r)))) rl)
       (map (lambda (p) (let ((r (assq (car p) rl))) (if r (cons (cadr r) (cdr p)) p))) tbl)))
    ;; (scheme ...) -- maps to the interaction environment (P189 §5).  Reached only via a modifier
    ;; (bare (import (scheme ...)) is short-circuited to a no-op in `import`), so this builds the full
    ;; export alist so prefix/rename over it are HONEST.  except over it cannot be (import never
    ;; unbinds) -- that is warned in `import`.
    ((eq? (car spec) 'scheme)
     (map (lambda (k) (cons k (eval k (interaction-environment))))
          (dict-keys (interaction-environment))))
    ;; otherwise a library NAME (a list of symbols).
    (else
     (let ((hit (%library-lookup spec)))
       (if hit (cdr hit)
           (let ((r (%library-resolve spec)))
             (if r r (error "import: no such library" spec))))))))

;;; import: an nlambda over the import specs.  R7RS import is a top-level ADDITIVE form, so bind into
;;; the interaction environment (current-environment is available, but import is not valid elsewhere).
(define import
  (nlambda specs
    (for-each
      (lambda (spec)
        (cond
          ;; bare (scheme ...) -- every name is already global; binding all of them is pure waste.
          ((and (pair? spec) (eq? (car spec) 'scheme)) 'no-op)
          ;; subtractive/renaming over (scheme ...) that import cannot honour honestly -> warn.
          ((and (pair? spec) (eq? (car spec) 'except) (pair? (cadr spec)) (eq? (car (cadr spec)) 'scheme))
           (warn "import (except (scheme ...) ...): import cannot UNBIND a global; the excluded names stay bound (P189 §5)\n"))
          (else
           (for-each (lambda (p) (dict-bind! (interaction-environment) (car p) (cdr p)))
                     (%import-set-exports spec)))))
      specs)
    'imported))
