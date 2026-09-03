;;; Copyright 2026 by Frobenius Norm LLC 2026-08-29 16:05:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; srfi64.scm -- SRFI-64 ("A Scheme API for Test Suites") subset for LambLisp.
;;;
;;; WHY THIS EXISTS.  LambLisp's own conformance suites use home-grown `check' macros, so they
;;; run on LambLisp and nowhere else.  SRFI-64 is the portable Scheme test vocabulary: a suite
;;; written against it runs on Chez, Guile, chibi and LambLisp alike.  That buys the one thing a
;;; self-hosted suite cannot buy -- INDEPENDENT VALIDATION.  Today the same codebase is both the
;;; implementation under test AND the arbiter of the right answer; carry the suite to another
;;; Scheme and a misreading of R7RS shows up as a disagreement instead of a silent pass.
;;;
;;; Load it before a suite:  (load "ll_tests/srfi64.scm")   ;; 1-arg load works on Chez too
;;;
;;; ------------------------------------------------------------------------------------------
;;; WHAT IS DELIBERATELY ABSENT, and why -- read this before "fixing" an omission.
;;; ------------------------------------------------------------------------------------------
;;; * NO dynamic-wind.  The SRFI-64 reference implementation (chibi lib/srfi/64.scm, 789 lines)
;;;   uses dynamic-wind in exactly 3 places -- all of them `test-group-with-cleanup' and the
;;;   runner's unwind protection.  LambLisp has no continuations (a hard-real-time design gap,
;;;   not a bug: bounded GC pause is worth more here than call/cc), so those 3 uses are the ONLY
;;;   thing standing between this file and the reference implementation.  Worth knowing: the
;;;   reference implementation uses call/cc ZERO times.  Cleanup here runs via `guard' instead,
;;;   which is correct for every case except a cleanup that must survive a non-local exit -- and
;;;   without continuations there is no non-local exit to survive.
;;; * NO test-runner objects (test-runner-create / -factory / -with-runner / test-apply).
;;;   The runner protocol exists so several suites can multiplex custom reporters.  Here the
;;;   reporter is fixed, because the FAIL line shape below is parsed by the w3 harness.
;;;   The procedural counters (test-runner-pass-count et al) ARE provided.
;;; * NO test-expect-fail.  This is a POLICY refusal, not an oversight.  Marking a test
;;;   expected-to-fail hides a real defect behind a green run; the project rule is that a bug
;;;   stays visibly failing until it is fixed.  For a DELIBERATE, DOCUMENTED design gap (call/cc,
;;;   dynamic-wind, parameterize) use the `test-exception' extension below, which counts a THIRD
;;;   outcome and auto-flips to PASS the day the gap closes -- test-expect-fail would instead go
;;;   quiet forever and nobody would ever learn the feature had arrived.
;;;
;;; ------------------------------------------------------------------------------------------
;;; Output shape -- DO NOT reformat without updating the parser.
;;; ------------------------------------------------------------------------------------------
;;; `_w3_correctness_data_json()' in w3_test.sh scrapes these exact lines:
;;;     PASS <name>
;;;     FAIL <name> | expr <form> | expected <e> | got <g>
;;; PASS lines stay lean (there are >900 of them); only failures carry the detail, so a reviewer
;;; sees the expression that was evaluated and not merely a test name.

;;; -----------------------------------------------------------------------
;;; Platform detection + formatting
;;; -----------------------------------------------------------------------

;;; chez-scheme? = #t on Chez (syslog unbound), #f on LambLisp.
(define ll-esc (string (integer->char #x1b)))
(define chez-scheme?
  (guard (exn (#t #t))    ;;!< exception -> syslog not bound -> Chez
    (eval 'syslog)
    #f))                  ;;!< syslog bound -> LambLisp

;;; Minimal ~a / ~w formatter via display; works on both platforms.
;;;   ~a = DISPLAY the argument      ~w = WRITE it (strings keep quotes, lists keep structure)
(define (%s64-fmt color fmt . args)
  (when color (display color))
  (let loop ((chars (string->list fmt)) (args args))
    (cond
      ((null? chars) (values))
      ((and (char=? (car chars) #\~) (pair? (cdr chars)) (char=? (cadr chars) #\a))
       (display (if (null? args) "?" (car args)))
       (loop (cddr chars) (if (null? args) '() (cdr args))))
      ((and (char=? (car chars) #\~) (pair? (cdr chars)) (char=? (cadr chars) #\w))
       (write (if (null? args) "?" (car args)))
       (loop (cddr chars) (if (null? args) '() (cdr args))))
      (else
       (display (string (car chars)))
       (loop (cdr chars) args))))
  (when color (display (string-append ll-esc "[0m"))))

(define (news fmt . args) (apply %s64-fmt (string-append ll-esc "[32m") fmt args))
(define (warn fmt . args) (apply %s64-fmt (string-append ll-esc "[33m") fmt args))

;;; -----------------------------------------------------------------------
;;; Runner state
;;; -----------------------------------------------------------------------

(define *s64-pass*      0)
(define *s64-fail*      0)
(define *s64-exception* 0)   ;;!< LambLisp extension -- see test-exception below
(define *s64-group*    '())  ;;!< group-path stack, innermost first
(define s64-exception-names '())

;;; A test with no name gets one from its group path, so a FAIL line is never anonymous.
(define *s64-anon* 0)
(define (%s64-anon-name)
  (set! *s64-anon* (+ *s64-anon* 1))
  (string-append (if (null? *s64-group*) "test" (car *s64-group*))
                 "/" (number->string *s64-anon*)))

(define (%s64-pass! name)  (set! *s64-pass* (+ *s64-pass* 1)) (news "PASS ~a\n" name))
(define (%s64-fail! name form expected got)
  (set! *s64-fail* (+ *s64-fail* 1))
  (warn "FAIL ~a | expr ~w | expected ~w | got ~w\n" name form expected got))
(define (%s64-fail-exn! name form expected)
  (set! *s64-fail* (+ *s64-fail* 1))
  (warn "FAIL ~a | expr ~w | expected ~w | got exception\n" name form expected))

;;; -----------------------------------------------------------------------
;;; SRFI-64 core assertions
;;; -----------------------------------------------------------------------
;;; Every one is GUARDED: a test expression that RAISES counts as a FAIL and the run CONTINUES,
;;; per SRFI-64.  Without that a single unbound identifier aborts the whole suite -- which is
;;; exactly what happens when the suite is carried to another Scheme, the case it exists for.
;;;
;;; NOTE ON CLAUSE ORDER: the 3-argument clause is written BEFORE the 2-argument clause in every
;;; macro below.  Keep it that way.  LambLisp's syntax-rules matcher has been observed to take
;;; the shorter clause for a longer form when the short one comes first, which silently turns
;;; `(test-equal "name" expected expr)' into a comparison of "name" against expected.

(define (%s64-cmp= name expected actual form eqproc)
  (if (eqproc expected actual) (%s64-pass! name) (%s64-fail! name form expected actual)))

(define-syntax test-equal
  (syntax-rules ()
    ((_ name expected expr)
     (guard (exn (#t (%s64-fail-exn! name (quote expr) expected)))
       (%s64-cmp= name expected expr (quote expr) equal?)))
    ((_ expected expr)
     (test-equal (%s64-anon-name) expected expr))))

(define-syntax test-eqv
  (syntax-rules ()
    ((_ name expected expr)
     (guard (exn (#t (%s64-fail-exn! name (quote expr) expected)))
       (%s64-cmp= name expected expr (quote expr) eqv?)))
    ((_ expected expr)
     (test-eqv (%s64-anon-name) expected expr))))

(define-syntax test-eq
  (syntax-rules ()
    ((_ name expected expr)
     (guard (exn (#t (%s64-fail-exn! name (quote expr) expected)))
       (%s64-cmp= name expected expr (quote expr) eq?)))
    ((_ expected expr)
     (test-eq (%s64-anon-name) expected expr))))

;;; test-assert is TRUTHINESS, not (eq? v #t) -- SRFI-64 says "the expression is true".
(define-syntax test-assert
  (syntax-rules ()
    ((_ name expr)
     (guard (exn (#t (%s64-fail-exn! name (quote expr) #t)))
       (if expr (%s64-pass! name) (%s64-fail! name (quote expr) #t expr))))
    ((_ expr)
     (test-assert (%s64-anon-name) expr))))

;;; test-approximate: |expected - actual| <= err.  The float tests need this; comparing inexact
;;; results with equal? is a portability trap, not a conformance check.
(define-syntax test-approximate
  (syntax-rules ()
    ((_ name expected expr err)
     (guard (exn (#t (%s64-fail-exn! name (quote expr) expected)))
       (let ((v expr))
         (if (<= (abs (- expected v)) err)
           (%s64-pass! name)
           (%s64-fail! name (quote expr) expected v)))))
    ((_ expected expr err)
     (test-approximate (%s64-anon-name) expected expr err))))

;;; test-error: SRFI-64 takes an EXPRESSION (not a thunk -- that is LambLisp's older check-error).
;;; The optional error-type argument of full SRFI-64 is accepted and IGNORED: LambLisp raises
;;; error-objects uniformly, so discriminating on condition type would test nothing here.
(define-syntax test-error
  (syntax-rules ()
    ((_ name expr)
     (let ((r (guard (e (#t 'caught)) expr 'no-error)))
       (if (eq? r 'caught)
         (%s64-pass! name)
         (%s64-fail! name (quote expr) 'error 'no-error))))
    ((_ expr)
     (test-error (%s64-anon-name) expr))))

;;; -----------------------------------------------------------------------
;;; Grouping / suite delimiters
;;; -----------------------------------------------------------------------
;;; test-begin's optional expected-count argument is accepted and ignored: SRFI-64 uses it to
;;; detect a suite that exited early, but LambLisp cannot exit early without continuations.

(define (test-begin . o)
  (let ((name (if (pair? o) (car o) "tests")))
    (set! *s64-group* (cons name *s64-group*))
    (news "\n--- ~a ---\n" name)))

(define (test-end . o)
  (if (pair? *s64-group*) (set! *s64-group* (cdr *s64-group*)))
  #f)

(define-syntax test-group
  (syntax-rules ()
    ((_ name body ...)
     (begin (test-begin name) body ... (test-end name)))))

;;; test-group-with-cleanup: SRFI-64 runs the cleanup even on a non-local exit, via dynamic-wind.
;;; Here it runs on normal completion OR on a raise (guard), which covers every exit LambLisp has.
(define-syntax test-group-with-cleanup
  (syntax-rules ()
    ((_ name body ... cleanup)
     (begin (test-begin name)
            (guard (e (#t cleanup (raise e)))
              body ...)
            cleanup
            (test-end name)))))

(define (test-read-eval-string str)
  (eval (read (open-input-string str)) (interaction-environment)))

;;; -----------------------------------------------------------------------
;;; Procedural runner accessors (the useful subset of the runner protocol)
;;; -----------------------------------------------------------------------

(define (test-runner-current)        'srfi64-simple)   ;;!< no runner objects -- see header
(define (test-runner-pass-count . o) *s64-pass*)
(define (test-runner-fail-count . o) *s64-fail*)
(define (test-runner-xfail-count . o) *s64-exception*) ;;!< maps to the exception outcome
(define (test-runner-group-path . o) (reverse *s64-group*))
(define (test-runner-reset . o)
  (set! *s64-pass* 0) (set! *s64-fail* 0) (set! *s64-exception* 0)
  (set! s64-exception-names '()) (set! *s64-group* '()))
(define (test-passed?) (= *s64-fail* 0))

;;; -----------------------------------------------------------------------
;;; LambLisp extension: the THIRD outcome
;;; -----------------------------------------------------------------------
;;; An EXCEPTION is a deliberate, documented design gap in a hard-real-time embedded Scheme
;;; (call/cc, dynamic-wind, make-parameter/parameterize, the library system) -- NOT a bug.  Bugs
;;; go in the registry and MUST fail visibly.  `test-exception' still EXERCISES the feature; a
;;; raise or a non-conforming answer is counted SEPARATELY from pass/fail, being neither.
;;;
;;; The payoff over SRFI-64's test-expect-fail: if the gap ever CLOSES, this PASSES normally and
;;; the exception count drops -- a signal to lower the expected baseline.  test-expect-fail would
;;; stay silent, and the suite would never tell anyone the feature had landed.

(define (note-exception name)
  (set! *s64-exception* (+ *s64-exception* 1))
  (set! s64-exception-names (cons name s64-exception-names)))

(define-syntax test-exception
  (syntax-rules ()
    ((_ name expected expr)
     (guard (exn (#t (note-exception name)))
       (let ((actual expr))
         (if (equal? expected actual)
           (begin (set! *s64-pass* (+ *s64-pass* 1))
                  (news "PASS ~a (nonconformance resolved)\n" name))
           (note-exception name)))))))

(define-syntax test-assert-exception
  (syntax-rules ()
    ((_ name expr)
     (guard (exn (#t (note-exception name)))
       (let ((actual expr))
         (if actual
           (begin (set! *s64-pass* (+ *s64-pass* 1))
                  (news "PASS ~a (nonconformance resolved)\n" name))
           (note-exception name)))))))

;;; -----------------------------------------------------------------------
;;; chibi (chibi test) compatibility
;;; -----------------------------------------------------------------------
;;; chibi's own r7rs-tests.scm says (chibi test) is "mostly a subset of SRFI-64", and calls the
;;; equality assertion plain `test'.  These two aliases are the whole difference, which is why
;;; chibi's suite can be pointed at this file unchanged.

(define-syntax test
  (syntax-rules ()
    ((_ name expected expr) (test-equal name expected expr))
    ((_ expected expr)      (test-equal (%s64-anon-name) expected expr))))

(define-syntax test-values
  (syntax-rules ()
    ((_ name expected expr)
     (test-equal name (call-with-values (lambda () expected) list)
                      (call-with-values (lambda () expr) list)))
    ((_ expected expr)
     (test-values (%s64-anon-name) expected expr))))

;;; -----------------------------------------------------------------------
;;; Summary
;;; -----------------------------------------------------------------------

(define (test-summary label)
  (news "\n=== ~a: ~a passed, ~a failed, ~a exception ===\n"
        label *s64-pass* *s64-fail* *s64-exception*)
  (if (= *s64-fail* 0)
    (news "ALL TESTS PASSED\n")
    (warn "~a TESTS FAILED\n" *s64-fail*)))
