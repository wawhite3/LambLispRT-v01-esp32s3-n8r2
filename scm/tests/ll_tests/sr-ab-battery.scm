;;; Copyright 2026 by Frobenius Norm LLC 2026-08-31
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; sr-ab-battery.scm -- ONE battery of syntax-rules cases, run against EITHER implementation.
;;;
;;; LambLisp has two syntax-rules:
;;;   C++     src/ll_vm_mop3_syntax_rules.cpp -- installed as a mop3 before any .scm loads, and
;;;           therefore the one every build actually uses (rxrs_syntax.scm needs syntax-rules to
;;;           exist in order to define when/unless/case/letrec, so it cannot be Scheme).
;;;   Scheme  scm/rxrs/rxrs_syntax_rules.scm -- shipped in the Linux manifests, loaded by NOBODY.
;;;           An explicit (load "rxrs_syntax_rules.scm") replaces the binding.
;;;
;;; A second implementation that nothing exercises drifts silently, and the drift is only visible
;;; as a DIFFERENCE.  So this file does not assert "correct": it PRINTS what each implementation
;;; answers, one `SRAB <name> <value>` line per case, and the driver diffs the two runs.  Cases
;;; where they agree are silent; every disagreement is a finding, whichever side is wrong.
;;;
;;; Run it via w3_ai_scripts/sr_ab.sh -- do not read one run in isolation, a single run tells you
;;; nothing about conformance, only what one implementation happens to do.

;;; A case that RAISES prints RAISED rather than aborting the file.  This matters: `load` reports an
;;; error and moves to the next top-level form, so an unguarded raise would silently drop the case
;;; and both runs would agree by omission -- the B194 failure, where four checks vanished and the
;;; suite still printed ALL PASSED.  See the count guard at the end.

;;; QUIET THE VM's OWN LOGGING FIRST.  The interpreter writes "[142] LambMemoryManager::gc_pass() ..."
;;; to the SAME stream as `display`, mid-line, and the driver strips a bracketed line number and
;;; everything after it -- so a GC landing inside a case ERASES that case's value and the A/B run
;;; reports a divergence that is really just a garbage collection.  It is nondeterministic: three
;;; runs of this file disagreed about three different cases.  (quiet) removes the periodic traces;
;;; an ll_catch() error trace still prints, but that is deterministic -- it happens exactly when a
;;; case raises.  If `quiet` is missing the raise is reported and `load` moves on, so this line
;;; cannot cost a case.
(quiet)

(define srab-count 0)

(define (srab name thunk)
  (set! srab-count (+ srab-count 1))
  (display "SRAB ")
  (display name)
  (display " ")
  (display (guard (e (#t 'RAISED)) (thunk)))
  ;; EXPLICIT TERMINATOR.  The VM interleaves its own "[142] LambMemoryManager::gc_pass() ..." trace
  ;; into display output ON THE SAME LINE, and the driver strips from "[NNN]" onward -- so a GC
  ;; landing mid-value silently ERASED that value and the case then read as an empty string, i.e.
  ;; a fake divergence against the other implementation.  Observed on `reorder` in 1 run of 4 even
  ;; after (quiet).  With this marker the driver can tell "the value is empty" from "the line was
  ;; cut", and report the second as TRUNCATED instead of inventing a disagreement.
  (display " ;;END")
  (newline))

;;; --- basics -------------------------------------------------------------------------------
(define-syntax sr-or2 (syntax-rules () ((_ a b) (let ((t a)) (if t t b)))))
(srab "or2/false-first" (lambda () (sr-or2 #f 42)))
(srab "or2/true-first"  (lambda () (sr-or2 7 42)))

(define-syntax sr-swap (syntax-rules () ((_ a b) (list b a))))
(srab "reorder" (lambda () (sr-swap 1 2)))

;;; Multiple rules, chosen by arity -- rule ORDER matters and the first match must win.
(define-syntax sr-arity
  (syntax-rules ()
    ((_)        'none)
    ((_ a)      'one)
    ((_ a b)    'two)
    ((_ a b . r) 'many)))
(srab "arity/0" (lambda () (sr-arity)))
(srab "arity/1" (lambda () (sr-arity 1)))
(srab "arity/2" (lambda () (sr-arity 1 2)))
(srab "arity/3" (lambda () (sr-arity 1 2 3)))

;;; --- literals (B121: a free literal must match as an IDENTIFIER, not by value) ---------------
(define-syntax sr-lit
  (syntax-rules (else =>)
    ((_ else x)  (list 'saw-else x))
    ((_ => x)    (list 'saw-arrow x))
    ((_ y x)     (list 'saw-other y x))))
(srab "literal/else"  (lambda () (sr-lit else 1)))
(srab "literal/arrow" (lambda () (sr-lit => 1)))
(srab "literal/other" (lambda () (sr-lit zzz 1)))

;;; --- ellipsis -----------------------------------------------------------------------------
(define-syntax sr-list (syntax-rules () ((_ x ...) (list x ...))))
(srab "ellipsis/zero"  (lambda () (sr-list)))
(srab "ellipsis/three" (lambda () (sr-list 1 2 3)))

(define-syntax sr-pairs (syntax-rules () ((_ (a b) ...) (list (list a ...) (list b ...)))))
(srab "ellipsis/pairs" (lambda () (sr-pairs (1 2) (3 4) (5 6))))

;;; Nested ellipsis (B107).
(define-syntax sr-nest (syntax-rules () ((_ (a ...) ...) (list (list a ...) ...))))
(srab "ellipsis/nested" (lambda () (sr-nest (1 2) (3) ())))

;;; Ellipsis followed by a fixed tail -- the matcher must not let `...` eat the tail.
(define-syntax sr-tail (syntax-rules () ((_ a ... z) (list 'init (list a ...) 'last z))))
(srab "ellipsis/fixed-tail" (lambda () (sr-tail 1 2 3)))
(srab "ellipsis/tail-only"  (lambda () (sr-tail 9)))

;;; --- dotted tails (B152) --------------------------------------------------------------------
(define-syntax sr-dotted (syntax-rules () ((_ a . rest) (list 'head a 'rest 'rest))))
(srab "dotted/pattern" (lambda () (sr-dotted 1 2 3)))

;;; --- vectors (B153) -------------------------------------------------------------------------
(define-syntax sr-vec (syntax-rules () ((_ #(a b)) (list 'vec a b))))
(srab "vector/pattern" (lambda () (sr-vec #(1 2))))

(define-syntax sr-vec-out (syntax-rules () ((_ a b) #(a b))))
(srab "vector/template" (lambda () (sr-vec-out 1 2)))

;;; --- hygiene (B106/B108/B109) ---------------------------------------------------------------
;;; The template's `t` must not capture the caller's `t`.
(define-syntax sr-hyg (syntax-rules () ((_ e) (let ((t 'inner)) (list t e)))))
(srab "hygiene/no-capture" (lambda () (let ((t 'outer)) (sr-hyg t))))

;;; A free identifier in the template refers to the DEFINITION environment.
(define sr-free-val 'from-def-env)
(define-syntax sr-free (syntax-rules () ((_) sr-free-val)))
(srab "hygiene/free-identifier" (lambda () (let ((sr-free-val 'from-use-env)) (sr-free))))

;;; --- recursion ------------------------------------------------------------------------------
(define-syntax sr-my-and
  (syntax-rules ()
    ((_)          #t)
    ((_ e)        e)
    ((_ e r ...)  (if e (sr-my-and r ...) #f))))
(srab "recursive/and-true"  (lambda () (sr-my-and 1 2 3)))
(srab "recursive/and-false" (lambda () (sr-my-and 1 #f 3)))

;;; --- the unspecified value (B192/B193) ------------------------------------------------------
;;; A macro expanding to a one-armed `if` must yield the SAME unspecified object either way.
(define-syntax sr-when1 (syntax-rules () ((_ c body) (if c body (if #f #f)))))
(srab "unspecified/is-void" (lambda () (eq? (sr-when1 #f 1) (if #f #f))))
(srab "unspecified/truthy"  (lambda () (if (sr-when1 #f 1) 'TRUTHY 'FALSY)))

;;; --- custom ellipsis (B179 -- expected to differ; that is the point) -------------------------
;;; R7RS 4.3.2's alternate form  (syntax-rules <ellipsis> (<literal> ...) <rule> ...)  lets the
;;; macro writer name the repetition identifier, so a macro can write a macro without the
;;; (... ...) escape and so `...` itself becomes an ordinary identifier that can be matched.
;;;
;;; EVERY case here goes through `eval` of a QUOTED form, and that is load-bearing, not style.  An
;;; implementation that does not support the alternate form raises inside `define-syntax` -- at
;;; DEFINITION time -- and a define-syntax written directly in this file is evaluated as the file
;;; loads, outside any guard, so the case would VANISH rather than print RAISED, and two runs that
;;; both lose it would agree by omission (the B194 failure this file exists to prevent).  Quoting
;;; defers the definition into the thunk, where the guard can catch it.  Do not "simplify" these to
;;; a bare define-syntax.
(srab "custom-ellipsis"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-ce (syntax-rules ::: () ((_ x :::) (list x :::))))
                 (sr-ce 1 2 3))
              (interaction-environment))))

;;; Zero, one and several repetitions of a custom ellipsis -- zero is the interesting one: the
;;; matcher's empty-input branch has to recognise the CUSTOM symbol to bind x to no elements at all,
;;; and an implementation that only recognises `...` fails this while passing the three-element case
;;; by accident (it would bind ::: as an ordinary pattern variable).
(srab "custom-ellipsis/zero"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-ce0 (syntax-rules ::: () ((_ x :::) (list 'n x :::))))
                 (sr-ce0))
              (interaction-environment))))
(srab "custom-ellipsis/one"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-ce1 (syntax-rules ::: () ((_ x :::) (list 'n x :::))))
                 (sr-ce1 7))
              (interaction-environment))))
(srab "custom-ellipsis/several"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-ce3 (syntax-rules ::: () ((_ x :::) (list 'n x :::))))
                 (sr-ce3 1 2 3))
              (interaction-environment))))

;;; Nested custom ellipsis -- the B107 case with a chosen symbol.
(srab "custom-ellipsis/nested"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-cen (syntax-rules ooo () ((_ (a ooo) ooo) (list (list a ooo) ooo))))
                 (sr-cen (1 2) (3) ()))
              (interaction-environment))))

;;; `...` IS AN ORDINARY IDENTIFIER once some other symbol is the ellipsis, so declaring it a
;;; literal makes it match ITSELF in the input.
(srab "custom-ellipsis/dots-literal"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-ced (syntax-rules ::: (...) ((_ a ... b) (list 'lit a b))))
                 (sr-ced 1 ... 2))
              (interaction-environment))))

;;; The R7RS 4.3.2 case quoted in B179: the ellipsis is `...` AND `...` is declared a literal, which
;;; means this macro has no repetition at all -- `...` matches and expands as itself.
(srab "custom-ellipsis/dots-in-template"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-cel (syntax-rules ... (...) ((_ x) '(x ...))))
                 (sr-cel 100))
              (interaction-environment))))

;;; WHY THE FORM EXISTS: a macro that writes a macro, with no (... ...) escape anywhere.
(srab "custom-ellipsis/macro-writes-macro"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-blb
                   (syntax-rules ()
                     ((_ name)
                      (define-syntax name (syntax-rules ::: () ((_ e :::) (begin e :::)))))))
                 (sr-blb sr-seq)
                 (sr-seq 1 2 9))
              (interaction-environment))))

;;; CONTROL.  The ordinary form must be untouched by all of the above -- same eval path, same
;;; expander, default ellipsis.  If threading the ellipsis broke the default, this case moves and
;;; every other ellipsis case in this file moves with it.
(srab "ordinary-form/unaffected"
      (lambda ()
        (eval '(let ()
                 (define-syntax sr-ord (syntax-rules (=>) ((_ => x ...) (list 'arrow x ...))))
                 (sr-ord => 1 2 3))
              (interaction-environment))))

;;; --- summary --------------------------------------------------------------------------------
;;; DECLARED TOTAL.  A case whose thunk raises outside the guard, or a define-syntax that fails at
;;; definition time, removes the case entirely -- and two runs that both lose the same case AGREE,
;;; which would read as conformance.  So the count is part of the result: if fewer cases ran than
;;; this file contains, say so loudly and let the driver fail.
;;; UPDATE THIS NUMBER when adding or removing a case.
(define srab-expected 34)
(display "SRAB-COUNT ")
(display srab-count)
(display " expected ")
(display srab-expected)
(newline)
(if (not (= srab-count srab-expected))
  (begin
    (display "SRAB-FAIL cases vanished -- a case raised outside its guard, or the declared total is stale")
    (newline)))
(display "--- sr-ab done ---")
(newline)
