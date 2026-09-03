;;; bench-runner.scm -- Drive benchmarks.scm in interpreter, bytecode, and NCG modes.
;;; Reports times in microseconds.  Auto-detects host vs embedded and scales params.
;;; Copyright 2026 by Frobenius Norm LLC 2026-04-18 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Embedded (ESP32/ESP32-S3) constraints:
;;;   loopTask has 96 KB C-stack (getArduinoLoopTaskStackSize override in src/main.cpp).
;;;   Each NCG call costs ~300-400 bytes C-stack.  bench-timed / run-suite kept
;;;   as bytecode so recursive benchmarks (tak, ackermann) don't multiply wrapper depth.
;;;   NCG functions are selectively compiled -- ncg-compile-environment! excluded.
;;;
;;; Params are the same on all platforms (96 KB stack is sufficient for all inputs).
;;;
;;; Usage:
;;;   (load "ll_tests/benchmarks/bench-runner.scm" 0)   ; from project root
;;;   (load "bench-runner.scm" 0)                        ; from ll_tests/benchmarks/

(define (current-us) (micros))

;;; ---------------------------------------------------------------------------
;;; Platform detection -- lamb-board is set by the C++ runtime.
;;; Defined early so we can choose the right benchmarks.scm path below.

(define bench-embedded?
  (not (and (>= (string-length lamb-board) 6)
            (string=? (substring lamb-board 0 6) "linux_"))))

;;; Suppress the auto-run stubs at the bottom of benchmarks.scm.
(define (bench name thunk05 expected) #f)
(define (run-benchmarks) #f)

;;; Load all benchmark function definitions.
;;; ESP32/SPIFFS requires a leading / on all paths.
;;; Linux: try local dir first, then project-root path.
(if bench-embedded?
  (load "/ll_tests/benchmarks.scm" 0)
  (if (file-exists? "benchmarks.scm")
    (load "benchmarks.scm" 0)
    (load "ll_tests/benchmarks.scm" 0)))

;;; Capture AST pair counts NOW -- procs are still T_PROC before compile-environment!
(define bench-ast-counts
  (list (cons "tak          " (proc-ast-count tak))
        (cons "closure-bench" (proc-ast-count closure-bench))
        (cons "map-bench    " (proc-ast-count map-bench))
        (cons "fib-iter     " (proc-ast-count fib-iter))
        (cons "fib          " (proc-ast-count fib))
        (cons "sieve        " (proc-ast-count sieve))
        (cons "ackermann    " (proc-ast-count ackermann))
        (cons "my-foldl     " (proc-ast-count my-foldl))
        (cons "make-tree    " (proc-ast-count make-tree))
        (cons "tree-sum     " (proc-ast-count tree-sum))
        (cons "fib-memo     " (proc-ast-count fib-memo))
        (cons "filter       " (proc-ast-count filter))
        (cons "make-iota-vec" (proc-ast-count make-iota-vec))
        (cons "vector-sum   " (proc-ast-count vector-sum))
        (cons "qsort-vec!   " (proc-ast-count qsort-vec!))))

;;; ---------------------------------------------------------------------------
;;; Bench timing -- reports µs, no correctness check.

(define (bench-timed name thunk06)
  (bench-timed/v name thunk06 (lambda (r) #t)))   ;;; legacy no-check shim (unused)

;;; ---------------------------------------------------------------------------
;;; Value-verified timing.  Every benchmark carries an a-priori-correct answer
;;; (computed independently, NOT from LambLisp).  A wrong result is marked FAIL
;;; and counted -- a fast-but-wrong benchmark can no longer masquerade as a pass.

(define perf-fail-count 0)
(define (is? v) (lambda (r) (equal? r v)))       ;;; scalar / bignum verifier

;;; Exact a-priori Fibonacci bignums (Python-generated literals).
(define fib-1000-expected  43466557686937456435688527675040625802564660517371780402481729089536555417949051890403879840079255169295922593080322634775209689623239873322471161642996440906533187938298969649928516003704476137795166849228875)
(define fib-10000-expected 33644764876431783266621612005107543310302148460680063906564769974680081442166662368155595513633734025582065332680836159373734790483865268263040892463056431887354544369559827491606602099884183933864652731300088830269235673613135117579297437854413752130520504347701602264758318906527890855154366159582987279682987510631200575428783453215515103870818298969791613127856265033195487140214287532698187962046936097879900350962302291026368131493195275630227837628441540360584402572114334961180023091208287046088923962328835461505776583271252546093591128203925285393434620904245248929403901706233888991085841065183173360437470737908552631764325733993712871937587746897479926305837065742830161637408969178426378624212835258112820516370298089332099905707920064367426202389783111470054074998459250360633560933883831923386783056136435351892133279732908133732642652633989763922723407882928177953580570993691049175470808931841056146322338217465637321248226383092103297701648054726243842374862411453093812206564914032751086643394517512161526545361333111314042436854805106765843493523836959653428071768775328348234345557366719731392746273629108210679280784718035329131176778924659089938635459327894523777674406192240337638674004021330343297496902028328145933418826817683893072003634795623117103101291953169794607632737589253530772552375943788434504067715555779056450443016640119462580972216729758615026968443146952034614932291105970676243268515992834709891284706740862008587135016260312071903172086094081298321581077282076353186624611278245537208532365305775956430072517744315051539600905168603220349163222640885248852433158051534849622434848299380905070483482449327453732624567755879089187190803662058009594743150052402532709746995318770724376825907419939632265984147498193609285223945039707165443156421328157688908058783183404917434556270520223564846495196112460268313970975069382648706613264507665074611512677522748621598642530711298441182622661057163515069260029861704945425047491378115154139941550671256271197133252763631939606902895650288268608362241082050562430701794976171121233066073310059947366875)

;;; B124: time a MEAN over repetitions inside a fixed wall-clock window -- the same contract every
;;; competitor harness uses (MicroPython `bench_timed` loops to 10 s and prints dt//reps; LispBM
;;; `bench-rep` recurses to 10 s and prints (/ us reps); uLisp `bench-timed` counts reps on millis).
;;; This used to time ONE cold execution, so a LambLisp row carried first-touch I-cache/PSRAM misses,
;;; the first NCG entry and whatever GC phase the run happened to start in, while the competitor row
;;; beside it had all of that amortized over thousands of reps.  The distortion scaled inversely with
;;; benchmark length, i.e. it was worst exactly where LambLisp was reported as losing (fib-memo(25),
;;; map-x^2(100)).  Same window as the comps => the two sides of a perf row now measure the same thing.
(define bench-window-us 10000000)   ;;;!< 10 s UPPER TIME bound -- the competitor harnesses' window
;;; REP CAP -- the bound that actually matters on a memory-constrained target.  A pure 10 s window
;;; turns every benchmark into a sustained ALLOCATION SOAK: measured 2026-08-22 on the S3 devkit,
;;; iota(500) ran 3565 reps in its window (~1.8M cons cells, where the single-shot pass allocated
;;; 500), and by the 6th benchmark -- fib-iter(1000), the bignum one -- the heap had reached a
;;; regime the old single-shot suite never touched: reps stopped making progress and the cell hit
;;; its 1500 s timeout with 5 of 42 timings recorded.  The whole AST suite used to take 6.0 s.
;;; A mean over ~20 steady-state reps amortizes the cold-start effects B124 was about -- more reps
;;; buy less noise, not less bias -- so cap reps and keep the window as the secondary bound.
;;; Competitors run thousands of reps in their window; that is fine for THEM (own heaps, own GC)
;;; and does not make their means incomparable to a 20-rep mean.
(define bench-max-reps  20)

;;; NOT pre-expanding here, and the reason is worth keeping.  gc! alone does not create headroom,
;;; so when free cells are scarcer than a benchmark's demand an incremental mark phase starts
;;; mid-run and every later allocation pays write-barrier and marking work.  In ISOLATION that is
;;; worth 1.8x (81,450 us at 6373 free vs 45,116 at 14560), so pre-expanding looked like the fix.
;;; It is not: measured in the suite it changed nothing, because by the time a benchmark runs the
;;; pool already holds ~22,000 free cells across 6 blocks -- four times what wide-add(5000) uses.
;;; Heap size is not the lever either: wide-add is flat at 45.0-45.6 ms from 2 to 8 blocks.
;;;
;;; What actually drives the suite's slow rows is Yuasa pacing.  Amax (ll_vm_mem.cpp) is the peak
;;; "allocated cells at sweep end" and it is MONOTONIC; it sets the mark quantum, so whichever
;;; earlier benchmark set the highest peak permanently raises the per-allocation marking cost for
;;; everything after it.  wide-add costs 45 ms first in a fresh boot and ~177 ms after fifteen
;;; other benchmarks have ratcheted Amax up.  That is a property of the whole suite, not of the
;;; benchmark, and pre-expanding cannot touch it.
;;; ---------------------------------------------------------------------------
;;; ISOLATION MODE -- one benchmark per boot.
;;;
;;; The paragraph above names the disease; this is the cure.  Amax only ratchets UP, so a
;;; benchmark's number depends on WHICH BENCHMARKS RAN BEFORE IT: wide-add(5000) costs 45 ms
;;; first in a fresh boot and ~177 ms after fifteen others have raised the peak.  Nothing in
;;; the output distinguishes the two, so suite ORDER was silently a measurement input.  No
;;; amount of gc!, pre-expansion or rep-averaging removes it -- gc! collects garbage, it does
;;; not lower a monotonic high-water mark.
;;;
;;; The only way to measure a benchmark on the heap state the FIRST benchmark sees is to give
;;; every benchmark a first-benchmark heap, i.e. a fresh boot.  serial_run.py resets the board
;;; over DTR on every invocation, so the host drives one benchmark per invocation: it defines
;;; bench-only to a 1-based index before loading this file, and only that benchmark is timed.
;;; The counter spans all three run-suite calls, so 1..N enumerates Interpreter, Bytecode and
;;; NCG in order and each index names exactly one (mode, benchmark) pair.
;;;
;;; Both compile passes still run in every boot even though only one benchmark is timed.  That
;;; is deliberate: skipping them would measure a benchmark in a VM that never ran the compiler,
;;; which is a different machine from the one the all-in-one suite measures.  The cost is boot
;;; plus two compile passes per row; the benefit is a number that does not depend on its
;;; neighbours.
;;;
;;; bench-only unbound or #f keeps the old single-boot behaviour, which is what linux and Jetson
;;; use -- there is no DTR reset there, and their heaps are not the constrained ones.
(define bench-only    (if (defined? 'bench-only) bench-only #f))
(define bench-counter 0)

(define (bench-timed/v name thunk07 verify)
  (set! bench-counter (+ bench-counter 1))
  (if (and bench-only (not (= bench-only bench-counter)))
      #f                             ; not this boot's benchmark -- do not run, do not print
      (bench-timed/run name thunk07 verify)))

;;; PRE-EXPAND THE HEAP BEFORE TIMING.  Isolation (one boot per benchmark) removed the Amax
;;; ratchet, but it also removed a subsidy the in-suite order had been handing out: an earlier
;;; benchmark had already grown the heap, so later ones never paid block expansion.  Measured on
;;; the S3 devkit 2026-08-25, a fresh boot starts with ONE block -- 10,542 free cells -- against a
;;; settings-clamped ceiling of 8 blocks (~48,590 free after a collection).  So every benchmark
;;; whose working set exceeds ~10.5k cells was allocating blocks INSIDE the timed region:
;;; foldl+iota(500) came out 39% slower isolated than in-suite, and mul-loop(5000) 17% slower,
;;; purely because they now paid an expansion their predecessors used to have paid for them.
;;;
;;; `Platform.expand-to-n-blocks!` is the right instrument and `gc!` is not: gc! reclaims garbage
;;; but never grows the heap, which is why an earlier attempt to "pre-expand" with gc! alone
;;; changed nothing.  Crucially, expand() adds FREE cells and never touches Amax -- Amax is
;;; sampled as LIVE cells at sweep end -- so this buys headroom WITHOUT re-introducing the
;;; monotonic ratchet that isolation exists to eliminate.  Pre-expanding by allocating a big list
;;; and dropping it would NOT be equivalent: that list is live across a sweep and would ratchet
;;; Amax to its size.
;;;
;;; Expanding to the configured maximum (not a hardcoded count) keeps this correct when the
;;; harness changes the settings, and it is the same normalisation the competitors get -- their
;;; heaps are sized at startup too.  What changes is WHEN the blocks are allocated, not how many.
(define (bench-preexpand!)
  (Platform.expand-to-n-blocks! (Platform.max-cell-blocks)))

(define (bench-timed/run name thunk08 verify)
  (bench-preexpand!)                 ; headroom first -- see above; must precede the gc!
  (gc!)                              ; full collection: gc! -> gc_cleanup -> gc_stop, leaves idle
  (let* ((t0     (current-us))
         (result (thunk08)))           ; rep 1 -- its value is the one we verify
    (let loop ((reps 1))
      (if (and (< (- (current-us) t0) bench-window-us)
               (< reps bench-max-reps))
          (begin (thunk08) (loop (+ reps 1)))
          (let* ((dt   (- (current-us) t0))
                 (mean (quotient dt reps))
                 (ok   (verify result)))   ; verify AFTER dt -- never inflates the timing
            (unless ok (set! perf-fail-count (+ perf-fail-count 1)))
            (display name)
            (display "  ")                 ;;; ALWAYS a separator: the names are hand-padded to 17
                                           ;;; chars, and "wide-add(5000)   " is exactly 17, so the
                                           ;;; time abutted it ("wide-add(5000)8879720 us") and
                                           ;;; the harness regex (name WS digits) silently dropped
                                           ;;; the row -- 15 benches reported as a clean 45/45.
            (display mean)
            (display " us reps=")          ; reps reported so both sides of a row stay auditable
            (display reps)
            (unless ok (display "  *** FAIL got=") (display result) (display " ***"))
            (newline))))))

;;; ---------------------------------------------------------------------------
;;; Suite -- each benchmark verified against its known-correct answer.

(define (run-suite label)
  (display "=== ") (display label) (display " ===\n")
  (if bench-embedded?
    (begin
      (bench-timed/v "tak(7,4,1)       " (lambda () (tak 7 4 1)) (is? 4))
      (bench-timed/v "iota(500)        " (lambda () (iota 500))
                     (lambda (r) (and (= (length r) 500) (= (list-sum r) 124750))))
      (bench-timed/v "iota+sum(500)    " (lambda () (list-sum (iota 500))) (is? 124750))
      (bench-timed/v "closure(500)     " (lambda () (closure-bench 500)) (is? 125250))
      (bench-timed/v "map-x^2(100)     " (lambda () (map-bench 100)) (is? 338350))
      (bench-timed/v "fib-iter(1000)   " (lambda () (fib-iter 1000)) (is? fib-1000-expected))
      (bench-timed/v "fib-iter(45)     " (lambda () (fib-iter 45)) (is? 1134903170))
      (bench-timed/v "loop-call(4000)  " (lambda () (loop-call 4000)) (is? 0))
      (bench-timed/v "loop-add-lo(4000)" (lambda () (loop-add-lo 4000)) (is? 4000))
      (bench-timed/v "loop-add-hi(4000)" (lambda () (loop-add-hi 4000)) (is? 4000000))
      (bench-timed/v "sieve(200)       " (lambda () (sieve 200)) (is? 46))
      (bench-timed/v "ackermann(3,1)   " (lambda () (ackermann 3 1)) (is? 13))
      (bench-timed/v "foldl+iota(500)  " (lambda () (fold-left + 0 (iota 500))) (is? 124750))
      (bench-timed/v "tree(8)          " (lambda () (tree-sum (make-tree 8))) (is? 256))
      (bench-timed/v "fib-memo(25)     " (lambda () (fib-memo-reset!) (fib-memo 25)) (is? 75025))
      (bench-timed/v "fib-rec(18)      " (lambda () (fib 18)) (is? 2584))
      (bench-timed/v "qsort(200)       " (lambda () (qsort-vec! (make-iota-vec 200)))
                     (lambda (r) (and (vector-sorted? r) (= (vector-sum r) 20100))))
      (bench-timed/v "mul-loop(5000)   " (lambda () (mul-loop-bench 5000)) (is? 27))
      (bench-timed/v "wide-add(5000)   " (lambda () (wide-add-bench 5000)) (is? 1135466827))
      (bench-timed/v "bignum-mul(200)  " (lambda () (bignum-mul-bench 200)) (is? 737829950)))
    (begin
      (bench-timed/v "tak(18,12,6)     " (lambda () (tak 18 12 6)) (is? 7))
      (bench-timed/v "iota(500)        " (lambda () (iota 500))
                     (lambda (r) (and (= (length r) 500) (= (list-sum r) 124750))))
      (bench-timed/v "iota+sum(10000)  " (lambda () (list-sum (iota 10000))) (is? 49995000))
      (bench-timed/v "closure(10000)   " (lambda () (closure-bench 10000)) (is? 50005000))
      (bench-timed/v "map-x^2(1000)    " (lambda () (map-bench 1000)) (is? 333833500))
      (bench-timed/v "fib-iter(10000)  " (lambda () (fib-iter 10000)) (is? fib-10000-expected))
      (bench-timed/v "fib-iter(45)     " (lambda () (fib-iter 45)) (is? 1134903170))
      (bench-timed/v "loop-call(4000)  " (lambda () (loop-call 4000)) (is? 0))
      (bench-timed/v "loop-add-lo(4000)" (lambda () (loop-add-lo 4000)) (is? 4000))
      (bench-timed/v "loop-add-hi(4000)" (lambda () (loop-add-hi 4000)) (is? 4000000))
      (bench-timed/v "sieve(1000)      " (lambda () (sieve 1000)) (is? 168))
      (bench-timed/v "ackermann(3,6)   " (lambda () (ackermann 3 6)) (is? 509))
      (bench-timed/v "foldl+iota(5000) " (lambda () (fold-left + 0 (iota 5000))) (is? 12497500))
      (bench-timed/v "tree(10)         " (lambda () (tree-sum (make-tree 10))) (is? 1024))
      (bench-timed/v "fib-memo(35)     " (lambda () (fib-memo-reset!) (fib-memo 35)) (is? 9227465))
      (bench-timed/v "fib-rec(28)      " (lambda () (fib 28)) (is? 317811))
      (bench-timed/v "qsort(500)       " (lambda () (qsort-vec! (make-iota-vec 500)))
                     (lambda (r) (and (vector-sorted? r) (= (vector-sum r) 125250))))
      (bench-timed/v "mul-loop(5000)   " (lambda () (mul-loop-bench 5000)) (is? 27))
      (bench-timed/v "wide-add(5000)   " (lambda () (wide-add-bench 5000)) (is? 1135466827))
      (bench-timed/v "bignum-mul(200)  " (lambda () (bignum-mul-bench 200)) (is? 737829950)))))


(define (print-size-report)
  ;; bench-fns built lazily here so variable refs resolve to post-NCG compiled procs.
  (define bench-fns
    (list (cons "tak          " tak)
          (cons "closure-bench" closure-bench)
          (cons "map-bench    " map-bench)
          (cons "fib-iter     " fib-iter)
          (cons "sieve        " sieve)
          (cons "ackermann    " ackermann)
          (cons "my-foldl     " my-foldl)
          (cons "make-tree    " make-tree)
          (cons "tree-sum     " tree-sum)
          (cons "fib-memo     " fib-memo)
          (cons "fib          " fib)
          (cons "filter       " filter)
          (cons "make-iota-vec" make-iota-vec)
          (cons "vector-sum   " vector-sum)
          (cons "qsort-vec!   " qsort-vec!)))
  (define cell-sz (lamb-cell-size))
  (define (pad-num n width)                          ;;; right-align n in a field of width chars
    (let* ((s (number->string n))
           (pad (max 1 (- width (string-length s)))))
      (string-append (make-string pad #\space) s)))
  (define (display-col val width)
    (if val
      (display (pad-num val width))
      (display (make-string width #\-))))
  ;;; Format ratio as x.xx (2 decimal places) using integer arithmetic.
  (define (ratio-str num denom)
    (if (and num denom (> denom 0))
      (let* ((r   (round (/ (* num 100) denom)))
             (int (quotient  r 100))
             (fra (remainder r 100))
             (fstr (if (< fra 10)
                     (string-append "0" (number->string fra))
                     (number->string fra))))
        (string-append (number->string int) "." fstr))
      "-"))
  (display "=== Size Report (bytes) ===\n")
  (display "function          interp-B  bc-B  nc-B  bc/in  nc/in\n")
  (display "----------------- --------  ----  ----  -----  -----\n")
  (for-each
    (lambda (entry)
      (let* ((name  (car entry))
             (proc  (cdr entry))
             (a-ent (assoc name bench-ast-counts))
             (ast   (if a-ent (cdr a-ent) #f))
             (in-b  (if ast (* ast cell-sz) #f))
             (bc    (bc-opcode-count proc))
             (nc    (ncg-code-size   proc)))
        (let* ((bc-r (ratio-str bc in-b))
               (nc-r (ratio-str nc in-b)))
          (display name) (display "  ")
          (display-col in-b 8)  (display "  ")
          (display-col bc   4)  (display "  ")
          (display-col nc   4)  (display "  ")
          (display (string-append (make-string (max 0 (- 5 (string-length bc-r))) #\space) bc-r))
          (display "  ")
          (display (string-append (make-string (max 0 (- 5 (string-length nc-r))) #\space) nc-r))
          (newline))))
    bench-fns)
  (newline))

;;; ---------------------------------------------------------------------------
;;; 1. Interpreter mode (AST).

(run-suite "Interpreter")

;;; ---------------------------------------------------------------------------
;;; 2. Bytecode mode.
;;;
;;; On embedded: selectively compile only benchmark functions.
;;; compile-environment! on ESP32 compiles hundreds of procs from setup.scm and
;;; takes many minutes.  bench-timed / run-suite stay AST so they act as a
;;; trampoline -- recursive benchmarks (tak, ackermann) do not multiply wrapper depth.
;;; On Linux: compile-environment! is fast and safe.

(if bench-embedded?
  (begin
    (set! tak           (procedure->bytecode tak))
    (set! make-adder    (procedure->bytecode make-adder))
    (set! closure-bench (procedure->bytecode closure-bench))
    (set! map-bench     (procedure->bytecode map-bench))
    (set! fib-iter      (procedure->bytecode fib-iter))
    ;;; ADDING A BENCHMARK?  IT MUST BE REGISTERED IN THREE PLACES OR THE TIERS ARE A LIE:
    ;;;   1. bench-timed/v in run-suite (BOTH the embedded and host branches),
    ;;;   2. this procedure->bytecode list  -- or the BC tier runs it INTERPRETED,
    ;;;   3. the ncg-compile-transitive! list below -- or the NCG tier runs it INTERPRETED.
    ;;; Miss 2 and 3 and the benchmark still PASSES and still reports a number for all three
    ;;; tiers -- the SAME number, because it never compiled.  Measured 2026-09-01: loop-call(4000)
    ;;; read 608,193 / 607,636 / 610,588 us for AST/BC/NCG while fib-iter(45) beside it read
    ;;; 10,964 / 1,010 / 572.  Three identical tier numbers is the tell.
    (set! loop-call     (procedure->bytecode loop-call))      ;;; micro: loop+call floor
    (set! loop-add-lo   (procedure->bytecode loop-add-lo))    ;;; micro: add, no allocation
    (set! loop-add-hi   (procedure->bytecode loop-add-hi))    ;;; micro: add, one box per iter
    (set! sieve         (procedure->bytecode sieve))
    (set! ackermann     (procedure->bytecode ackermann))
    (set! my-foldl      (procedure->bytecode my-foldl))
    (set! make-tree     (procedure->bytecode make-tree))
    (set! tree-sum      (procedure->bytecode tree-sum))
    (set! fib-memo      (procedure->bytecode fib-memo))
    ;;; fib-memo-reset! was listed for NCG but NOT here, which made the NCG entry inert:
    ;;; ncg-compile-transitive! returns immediately on anything that is not already bytecode,
    ;;; so it stayed an AST closure in all three tiers.  It is called INSIDE the timed lambda
    ;;; for fib-memo(25)/(35), so those two rows carried an interpreted call in every tier.
    ;;; (It set!s the top-level global fib-memo-table, so it compiles to BC_STORE_GLOBAL --
    ;;; no captured-local boxing involved, cf. B205.)
    (set! fib-memo-reset! (procedure->bytecode fib-memo-reset!))
    (set! fib           (procedure->bytecode fib))
    (set! filter        (procedure->bytecode filter))
    (set! make-iota-vec (procedure->bytecode make-iota-vec))
    (set! vector-sum    (procedure->bytecode vector-sum))
    (set! qsort-vec!    (procedure->bytecode qsort-vec!))
    ;; These two MUST be here as well as in the NCG list below: ncg-compile-transitive!
    ;; works from the bytecode form, so a benchmark listed only for NCG stays an AST
    ;; closure in all three passes -- which is exactly what happened, and why mul32 and
    ;; wide-add reported AST == BC == NCG to within 0.3% while every other benchmark
    ;; gained 2.4x-519x.  LambLisp was being measured with its compiler switched off.
    (set! mul-loop-bench       (procedure->bytecode mul-loop-bench))
    (set! wide-add-bench (procedure->bytecode wide-add-bench))
    (set! bignum-mul-bench  (procedure->bytecode bignum-mul-bench)))
  (compile-environment! (interaction-environment)))
(run-suite "Bytecode")

;;; ---------------------------------------------------------------------------
;;; 3. NCG mode.
;;;
;;; On embedded: selectively compile benchmark functions so bench-timed /
;;; run-suite stay as bytecode (trampoline, no C-stack growth per wrapper call).
;;; On Linux: ncg-compile-environment! is safe.

;;; P86 Ph2: verify qsort-vec! BC produces correct output before NCG.
(unless (vector-sorted? (qsort-vec! (make-iota-vec 200)))
  (error "qsort-vec! BC correctness check FAILED"))

(if bench-embedded?
  (for-each ncg-compile-transitive!
            (list tak make-adder closure-bench
                  map-bench fib-iter sieve ackermann my-foldl
                  make-tree tree-sum fib-memo fib-memo-reset! fib filter
                  make-iota-vec vector-sum qsort-vec! mul-loop-bench wide-add-bench bignum-mul-bench
                  loop-call loop-add-lo loop-add-hi))   ;;; micro-benchmarks: see benchmarks.scm
  (ncg-compile-environment! (interaction-environment)))
(run-suite "NCG")

(unless bench-only (print-size-report))   ; per-boot in isolation mode it is 51x redundant

;;; Tells the host loop where to stop: it walks bench-only = 1, 2, 3 ... and quits on this line,
;;; so the suite can gain or lose benchmarks without the host knowing how many there are.
(when (and bench-only (> bench-only bench-counter))
  (display "=== BENCH INDEX OUT OF RANGE ===\n"))

(display "=== PERF VERIFY: ") (display perf-fail-count) (display " failure(s) ===\n")
(display "--- done ---\n")

; end of bench-runner.scm
