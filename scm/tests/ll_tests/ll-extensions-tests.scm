;;; ll-extensions-tests.scm -- LambLisp-specific extension tests.
;;; Copyright 2026 by Frobenius Norm LLC 2026-06-02 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Covers: nlambda, macro, macro?, dict-*, reverse!, gensym.
;;; Produces: ll-ext-pass / ll-ext-fail counters.
;;; Sentinel: --- ll-extensions done ---
;;;
;;; Usage: echo '(load "ll_tests/ll-extensions-tests.scm" 0)' | ./program

;;; -----------------------------------------------------------------------
;;; Test framework (self-contained; redefined by Terminal.scm on ESP32)
;;; -----------------------------------------------------------------------

(define ll-ext-esc (string (integer->char #x1b)))
(define (ll-ext-news fmt . args)
  (apply syslog (string-append ll-ext-esc "[32m" fmt ll-ext-esc "[97m") args))
(define (ll-ext-warn fmt . args)
  (apply syslog (string-append ll-ext-esc "[33m" fmt ll-ext-esc "[97m") args))

(define ll-ext-pass 0)
(define ll-ext-fail 0)

(define (ll-ext-check name expected actual)
  (if (equal? expected actual)
    (begin (set! ll-ext-pass (+ ll-ext-pass 1)) (ll-ext-news "PASS ~a\n" name))
    (begin (set! ll-ext-fail (+ ll-ext-fail 1))
           (ll-ext-warn "FAIL ~a  expected=~a  got=~a\n" name expected actual))))

(define (ll-ext-check-true name actual)
  (if actual
    (begin (set! ll-ext-pass (+ ll-ext-pass 1)) (ll-ext-news "PASS ~a\n" name))
    (begin (set! ll-ext-fail (+ ll-ext-fail 1))
           (ll-ext-warn "FAIL ~a  expected=#t  got=~a\n" name actual))))

(define (ll-ext-check-false name actual)
  (if (not actual)
    (begin (set! ll-ext-pass (+ ll-ext-pass 1)) (ll-ext-news "PASS ~a\n" name))
    (begin (set! ll-ext-fail (+ ll-ext-fail 1))
           (ll-ext-warn "FAIL ~a  expected=#f  got=~a\n" name actual))))

;;; ll-ext-check-raises -- the assertion PASSES when the thunk raises.
;;; Takes a THUNK, not a value: an expression that raises cannot be passed as an argument, because
;;; it raises before the call is made.  That is not a detail -- it is B194: a check whose argument
;;; raises never reaches the counters at all, so the run silently loses the assertion and still
;;; prints ALL PASSED (four B180 checks vanished exactly this way).  See the count guard at the end.
(define (ll-ext-check-raises name thunk16)
  (if (eq? 'll-ext-raised (guard (e (#t 'll-ext-raised)) (thunk16)))
    (begin (set! ll-ext-pass (+ ll-ext-pass 1)) (ll-ext-news "PASS ~a\n" name))
    (begin (set! ll-ext-fail (+ ll-ext-fail 1))
           (ll-ext-warn "FAIL ~a  expected=<raise>  got=<returned normally>\n" name))))

;;; -----------------------------------------------------------------------
;;; nlambda / macro / macro?
;;; -----------------------------------------------------------------------

(ll-ext-news "\n--- nlambda ---\n")

(define my-quote2 (nlambda args (car args)))
(ll-ext-check "nlambda/sym"      'hello   (my-quote2 hello))
(ll-ext-check "nlambda/list"     '(1 2)   (my-quote2 (1 2)))
(ll-ext-check "nlambda/num"      42       (my-quote2 42))

(define nl-outer 77)
(define nl-test  (nlambda args nl-outer))
(ll-ext-check "nlambda/caller-env" 77   (nl-test))

(ll-ext-news "--- macro ---\n")
(define my-when3
  (macro use-form
    (let ((test (car use-form))
          (body (cdr use-form)))
      (list 'if test (cons 'begin body) #f))))
(ll-ext-check "macro/true"    'result   (my-when3 #t 'result))
(ll-ext-check "macro/false"   #f        (my-when3 #f 'never))

(define my-swap!
  (macro use-form
    (let ((a (car use-form)) (b (cadr use-form)))
      `(let ((t ,a)) (set! ,a ,b) (set! ,b t)))))
(let ((x 1) (y 2))
  (my-swap! x y)
  (ll-ext-check "macro/swap" '(2 1) (list x y)))

(ll-ext-check-true  "macro?/macro"   (macro? my-when3))
(ll-ext-check-false "macro?/proc"    (macro? car))
(ll-ext-check-false "macro?/lambda"  (macro? (lambda (x) x)))

;;; -----------------------------------------------------------------------
;;; dict
;;; -----------------------------------------------------------------------

(ll-ext-news "\n--- dict ---\n")
(define d (dict-add-empty-frame '()))
(dict-bind! d 'x 10 d)
(dict-bind! d 'y 20 d)
(ll-ext-check "dict-ref/x"       10    (dict-ref d 'x))
(ll-ext-check "dict-ref/y"       20    (dict-ref d 'y))
(ll-ext-check "dict-ref?/hit"    10    (cdr (dict-ref? d 'x)))
(ll-ext-check-true  "dict-ref?/miss"   (eq? #f (dict-ref? d 'z)))

(dict-rebind! d 'x 42 d)
(ll-ext-check "dict-rebind!/x"   42    (dict-ref d 'x))

(let ((ks (dict-keys d)))
  (ll-ext-check-true "dict-keys/x"   (memq 'x ks))
  (ll-ext-check-true "dict-keys/y"   (memq 'y ks)))

(define d2 (dict-add-alist-frame '() '((a . 1) (b . 2)) d))
(ll-ext-check "dict-alist/a"     1    (dict-ref d2 'a))
(ll-ext-check "dict-alist/b"     2    (dict-ref d2 'b))

;;; -----------------------------------------------------------------------
;;; reverse! / gensym
;;; -----------------------------------------------------------------------

(ll-ext-news "\n--- reverse! ---\n")
(ll-ext-check "reverse!/3"    '(3 2 1)  (reverse! (list 1 2 3)))
(ll-ext-check "reverse!/nil"  '()       (reverse! (list)))
(ll-ext-check "reverse!/1"    '(42)     (reverse! (list 42)))

(ll-ext-news "--- gensym ---\n")
(let ((g1 (gensym)) (g2 (gensym)) (g3 (gensym)))
  (ll-ext-check-true  "gensym/unique-12"   (not (eq? g1 g2)))
  (ll-ext-check-true  "gensym/unique-13"   (not (eq? g1 g3)))
  (ll-ext-check-true  "gensym/symbol?"     (symbol? g1)))

;;; -----------------------------------------------------------------------
;;; crc32 -- native CRC-32 (IEEE 802.3 / zlib) over a bytevector, optional [start end).
;;; Expected values cross-checked against Python zlib.crc32.
;;; -----------------------------------------------------------------------
(ll-ext-news "--- crc32 ---\n")
(let ((bv9 (bytevector 49 50 51 52 53 54 55 56 57)))   ;; ASCII "123456789"
  (ll-ext-check "crc32/check-value"  3421780262 (crc32 bv9))        ;; canonical #xCBF43926
  (ll-ext-check "crc32/slice-full"   3421780262 (crc32 bv9 0 9))
  (ll-ext-check "crc32/empty"        0          (crc32 (bytevector)))
  (ll-ext-check "crc32/zero-range"   0          (crc32 bv9 3 3)))
(let ((bv256 (make-bytevector 256 0)))
  (let loop ((i 0)) (when (< i 256) (bytevector-u8-set! bv256 i i) (loop (+ i 1))))
  (ll-ext-check "crc32/bytes-0..255" 688229491  (crc32 bv256))
  (ll-ext-check "crc32/slice-0..127" 610602327  (crc32 bv256 0 128))
  (ll-ext-check "crc32/from-128"     1179250845 (crc32 bv256 128)))

;;; -----------------------------------------------------------------------
;;; defined? -- is a symbol bound?  (mop3, uses the CALLING environment)
;;; -----------------------------------------------------------------------

(ll-ext-check "defined?/bound-primitive"   #t (defined? 'car))
(ll-ext-check "defined?/unbound"           #f (defined? 'no-such-symbol-zqx9173))
;;  The caller's locals are visible: this is why defined? is a mop3 and not a
;;  Scheme lambda -- a lambda would see its own definition environment instead.
(ll-ext-check "defined?/caller-local"      #t (let ((zz 1)) (defined? 'zz)))
(ll-ext-check "defined?/caller-local-miss" #f (let ((zz 1)) (defined? 'no-such-zz-9173)))
(ll-ext-check "defined?/lambda-arg"        #t ((lambda (aa) (defined? 'aa)) 7))
(ll-ext-check "defined?/shadowed"          #t (let ((car 2)) (defined? 'car)))
(ll-ext-check "defined?/explicit-env"      #t (defined? 'car (current-environment)))
;;  A non-symbol raises rather than silently answering #f.
(ll-ext-check "defined?/non-symbol-raises" 'raised
  (guard (e (#t 'raised)) (defined? 42)))

;;; -----------------------------------------------------------------------
;;; GC: heap expansion + Amax decay (P153).  Sized to the target heap so it is safe on embedded:
;;; the burst is bounded by current free (cannot OOM) and the decay loop stops at the first decaying
;;; cycle (fast on a small heap, where cycles fire often).
;;; -----------------------------------------------------------------------
(define (gc-amax)   (list-ref (Platform.gc-diag) 0))            ;; gc-diag[0] = Amax (best estimate of true live)
(define (gc-churn n) (do ((k 0 (+ k 1))) ((= k n) #f) (cons k k)))  ;; allocate n throwaway pairs -> drives gc_pass cycles

;; Amax decay (P153): hold a LIVE burst that nearly fills current free so a gc cycle ratchets Amax up
;; to the burst peak; then drop it and drive allocation-only cycles -- Amax must decay geometrically
;; back down toward the true (small) live set.  (gc! is a synchronous drain that bypasses gc_pass and
;; does NOT run the decay, so this must be exercised with real allocation.)
(define gc-amax-base (gc-amax))
(define gc-burst-n (max 4000 (- (Platform.nfree) 1500)))   ;; <= free -> fits without OOM; small heap -> small burst
(define gc-burst (let loop ((i gc-burst-n) (acc '())) (if (= i 0) acc (loop (- i 1) (cons i acc)))))
(gc-churn 2000)                       ;; free is ~gone now -> a cycle fires, ratcheting Amax to the live burst
(ll-ext-check-true "gc/decay-burst-live" (pair? gc-burst))  ;; keep the burst reachable across the ratchet
(define gc-amax-peak (gc-amax))
(set! gc-burst #f)                    ;; burst now collectable
;; drive cycles until Amax drops below the peak -- stops at the first decaying cycle; the cap makes a
;; broken decay FAIL the check (each churn is bounded) instead of looping forever.
(define gc-amax-after
  (let loop ((i 0) (a gc-amax-peak))
    (if (or (< a gc-amax-peak) (>= i 400000)) a
        (begin (gc-churn 2000) (loop (+ i 2000) (gc-amax))))))
(ll-ext-check-true "gc/amax-ratcheted-up"       (> gc-amax-peak gc-amax-base))
(ll-ext-check-true "gc/amax-decays-after-burst" (< gc-amax-after gc-amax-peak))

;; Expansion: expand-to-n-blocks! adds real cell blocks (it honours max-cell-blocks, so it cannot
;; over-commit memory) -- verify the pool actually grew.
(define gc-blocks0 (Platform.n-cell-blocks))
(Platform.expand-to-n-blocks! (+ gc-blocks0 2))
(ll-ext-check-true "gc/expansion-grows-heap" (> (Platform.n-cell-blocks) gc-blocks0))

;;; -----------------------------------------------------------------------
;;; B180 / B190 -- EMPTY BODIES.
;;;
;;; B180: an empty body sequence must TERMINATE, not infinite-loop.  A regression re-introduces a
;;; hang here, which the suite timeout surfaces -- that invariant is still carried by every case
;;; below, whether the case ends in a value or in a raise.
;;;
;;; B190: terminating is not enough -- WHAT it terminates with matters.  B180's fix returned NIL,
;;; a legitimate Scheme value that satisfies null?, survives being stored and passed, and only
;;; failed much later at a coercion, so `(+ 1 (let ((x 1))))` reported a Bad type at the innocent
;;; `+`.  R7RS 4.2.2 gives let/let*/letrec a <body> of ONE OR MORE expressions, so the let family
;;; now RAISES.  `begin` and `do` are deliberately NOT in that group -- see their cases below.
;;; -----------------------------------------------------------------------
(ll-ext-check-raises "b190/empty-let"          (lambda () (let ())))
(ll-ext-check-raises "b190/empty-let-binding"  (lambda () (let ((x 1)))))
(ll-ext-check-raises "b190/empty-let*"         (lambda () (let* ())))
(ll-ext-check-raises "b190/empty-let*-binding" (lambda () (let* ((x 1)))))
(ll-ext-check-raises "b190/empty-letrec"       (lambda () (letrec ())))
(ll-ext-check-raises "b190/empty-letrec-bind"  (lambda () (letrec ((x 1)))))
(ll-ext-check-raises "b190/empty-named-let"    (lambda () (let lp ((n 1)))))
;; The reason B190 was filed: the empty body must not detonate at some unrelated arithmetic.
(ll-ext-check-raises "b190/empty-let-in-arith" (lambda () (+ 1 (let ((x 1))))))

;; `(begin)` is NOT an error: R7RS gives begin a definition-context splice form in which it is
;; legal, and the evaluator cannot tell that context from expression position -- so it yields the
;; unspecified object.  What it must NOT yield is NIL, which is what made B190 hide.
(ll-ext-check-true  "b180/empty-begin"         (begin (begin) #t))
(ll-ext-check-false "b190/begin-is-not-null"   (null? (begin)))
(ll-ext-check-false "b190/void-matches-if"     (null? (if #f #f)))

;; `do` with no result expressions is explicitly legal (R7RS 4.2.4: "if no <expression>s are
;; present, the value is unspecified"), so it returns, and returns non-NIL.  B190's entry listed
;; `do` as affected; that part was wrong and this case pins the correct behavior.
(ll-ext-check-true  "b180/do-empty-result"     (begin (do ((k 0 (+ k 1))) ((= k 3)) k) #t))
(ll-ext-check-false "b190/do-empty-not-null"   (null? (do ((k 0 (+ k 1))) ((= k 3)) k)))

;;; -----------------------------------------------------------------------
;;; B190 / B191 -- THE COMPILED PATH MUST AGREE WITH THE INTERPRETED ONE.
;;;
;;; B190 was first fixed only in the mop3s, so `(let ((x 1)))` raised when interpreted and returned
;;; the unspecified object when bytecode-compiled: one interpreter disagreeing with itself about
;;; the same source.  The compiler now REFUSES the form (procedure->bytecode hands back the
;;; uncompiled proc), so the interpreter raises exactly as it does uncompiled.
;;;
;;; B191 is why these use procedure->bytecode rather than compile-environment!: every Scheme error
;;; raised inside a bytecode-compiled procedure used to SEGFAULT the VM (the BC interpreter calls
;;; the NCG shims, whose error path longjmp'd through a null ncg_err_ctx).  A crash here is B191
;;; returning -- the suite dies rather than reporting.
;;; -----------------------------------------------------------------------
(define (b190-empty-let-proc) (let ((x 1))))
(ll-ext-check-false  "b190/compiler-refuses-empty-let"
                     (bytecode? (procedure->bytecode b190-empty-let-proc)))
(ll-ext-check-raises "b190/compiled-empty-let-raises"
                     (lambda () ((procedure->bytecode b190-empty-let-proc))))

(define (b191-bad-car) (car 5))
(define b191-compiled (procedure->bytecode b191-bad-car))
(ll-ext-check-true   "b191/proc-did-compile"   (bytecode? b191-compiled))
(ll-ext-check-raises "b191/error-in-compiled-proc-raises" (lambda () (b191-compiled)))
(ll-ext-check-true   "b191/vm-survived"        #t)

;;; -----------------------------------------------------------------------
;;; Summary
;;; -----------------------------------------------------------------------

;;; B194: an assertion whose ARGUMENT raises never reaches the counters -- `load` reports the error
;;; and moves to the next top-level form, so the check silently disappears and the run still prints
;;; "0 failed / ALL PASSED".  That is how four B180 checks vanished unnoticed.  A declared total is
;;; the only tell the suite has: if fewer assertions ran than this file contains, say so LOUDLY.
;;; UPDATE THIS NUMBER when adding or removing an assertion -- a mismatch fails the suite by design.
(define ll-ext-expected-checks 62)
(define ll-ext-ran (+ ll-ext-pass ll-ext-fail))   ;;;!< snapshot BEFORE the guard adds its own failure
(if (not (= ll-ext-ran ll-ext-expected-checks))
  (begin
    (set! ll-ext-fail (+ ll-ext-fail 1))
    (ll-ext-warn "FAIL ll-ext/assertion-count  expected=~a  ran=~a  -- ASSERTIONS VANISHED (a check raised outside a thunk, or the declared total is stale)\n"
                 ll-ext-expected-checks ll-ext-ran)))

(ll-ext-news "\n=== ll-extensions: ~a passed, ~a failed ===\n" ll-ext-pass ll-ext-fail)
(if (= ll-ext-fail 0)
  (ll-ext-news "ALL PASSED\n")
  (ll-ext-warn "~a FAILED\n" ll-ext-fail))

