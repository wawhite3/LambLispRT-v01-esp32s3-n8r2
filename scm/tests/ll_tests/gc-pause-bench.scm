;;; gc-pause-bench.scm -- GC worst-case pause benchmark (P96).
;;; Copyright 2026 by Frobenius Norm LLC 2026-05-23 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Usage: (load "/ll_tests/gc-pause-bench.scm" 1)
;;; Requires gc-pause-bench mop3 (ll_vm_mop3_extra.cpp).
;;;
;;; CROSS-INTERPRETER MATCH (2026-06-25): heap-size = the common application-object count used
;;; by the competitor gcpause tier (30000). LL ALSO carries its ~10,209-cell prelude baseline,
;;; so total live ~= 40,209 -- the point: LL pays for its libraries and STILL keeps a bounded
;;; per-quantum pause.
;;;
;;; KNOWN SETTINGS REQUIRED (pushed by the gcpause test runner before this loads -- the test
;;; downloads its own known config, it does NOT assume device state). The runner pushes
;;; cell_block_size = 12288 (small, boot-safe block-0) and max_cell_blocks = 18, so the heap can
;;; grow via small blocks to ~(baseline + heap-size)*2 total (~50% free headroom for churn).
;;; cell_block_size / max_cell_blocks need a reboot to apply, so the runner writes Settings + reboots.
;;;
;;; B117 (2026-08-16): the ORIGINAL plan -- one big block (cell_block_size ~96000, max_cell_blocks 1,
;;; "no expand during measurement") -- BROKE BOOT on the ESP32-S3: allocating a single large PSRAM
;;; cell block at startup exhausts INTERNAL DRAM (measured: internal free 116,892 B normal -> 380 B),
;;; starving the littlefs read buffer so the boot .scm chain fails with `err 257` (ESP_ERR_NO_MEM)
;;; and the bench never loads. A block0 <= ~12288 boots; larger single blocks do not (independent of
;;; whether cells land in PSRAM -- they do, via B115). Fix: keep block0 small and reach the needed
;;; pool by EXPANSION across small blocks (max_cell_blocks 18). Verified: worst-case pause is
;;; unchanged by this (identical ~54.3 ms at max_blocks 16 vs 18), so the multi-block heap does not
;;; perturb the measurement; it just lets the device boot. Result is repeatable to +-0.1%.

;;; OCCUPANCY IS AN INPUT, NOT A CONSTANT.  The sweep runs this file at several live-set sizes so
;;; the pause can be characterised against how FULL the heap is, not just how big it is -- those
;;; are different axes and the old single value confounded them.  The driver injects
;;; `(define w3-gcpause-heap N)` ahead of the load; absent that this keeps the historical 30000,
;;; which is the count the competitor gcpause tier uses, so a bare load still compares like for
;;; like.  Guarded with defined? rather than a redefine so the file stays loadable on its own.
(define heap-size (if (defined? 'w3-gcpause-heap) w3-gcpause-heap 30000))
(define baseline   10209)   ; LL's prelude live-cell baseline (~; grows slowly with the library)
(define cellpop    (+ baseline heap-size))   ; total live cell population the GC manages
;;; 30 turnovers => ~30 GC CYCLES, matching the stopping rule every competitor uses (they churn
;;; until their collector has run 30 collections).  Was 6, which is ample for the PAUSE figure --
;;; the worst-case pause recurs every cycle, so 6 turnovers catch it in seconds, and the old
;;; 12M-alloc churn added no signal while taking >300 s on embedded (B114).
;;;
;;; It is NOT ample for the GC-LOAD figure, and that is why this changed.  GC load is a fraction of
;;; RUN TIME, so it depends on how hard the workload allocates: at 6 turnovers LambLisp performed
;;; ~241,000 allocations in 4.0 s (~60,000/s) while LispBM performed 20,209 in 11.8 s (~1,720/s) --
;;; a 35x difference in allocation RATE.  Comparing the resulting loads (58.1% vs 3.4%) would read
;;; as "LambLisp's collector is 17x less efficient" when it mostly says LambLisp did 12x the
;;; allocations in a third of the time.  Same collector work per unit of application work; wildly
;;; different application work.  Equalising the stopping rule removes that confound.
;;;
;;; A fixed ALLOCATION count cannot be the shared rule: TinyScheme manages ~25 allocs/s here (it
;;; collects every ~26 allocations against a 30,000-object live set), so any count large enough to
;;; be meaningful for the others runs it past the harness timeout.  Collections are the unit every
;;; runtime can complete.
(define n-cycles   30)
;;; ALLOCATION BUDGET IS SET BY COLLECTIONS WANTED, NOT BY LIVE SET.
;;; The obvious `n-cycles x cellpop` is the wrong shape for an occupancy sweep, and wrong in the
;;; direction that hurts: a collection happens roughly every (pool - live) allocations, so a FULL
;;; heap collects often and an empty one rarely.  Scaling the budget by the live set therefore
;;; asks the 80%-full cell -- where every allocation is slowest and collections are already
;;; frequent -- to do the MOST allocations.  Measured: that cell ran past a 300s timeout while the
;;; 20% cell finished in seconds, and the two were not even comparable, because they saw wildly
;;; different collection counts.
;;; The driver knows the pool and the occupancy, so it computes n-cycles x (pool - live) and
;;; injects it; every cell then sees ~the same number of COLLECTIONS, which is the thing being
;;; compared.  The fallback keeps this file loadable standalone.
;;; Reported as gc-allocs, so a short run can never be mistaken for a full one.
(define n-allocs-cap 3000000)
(define n-allocs
  (if (defined? 'w3-gcpause-allocs)
      w3-gcpause-allocs
      (let ((want (* n-cycles cellpop)))
        (if (> want n-allocs-cap) n-allocs-cap want))))

(display "GC pause bench: ") (display n-allocs)
(display " allocs, live heap ") (display heap-size) (display " cells") (newline)

;;; MEASURED GC LOAD for LambLisp.  Every competitor derives its load by summing allocation
;;; pauses over 1 ms, because a stop-the-world collector cannot hide a collection inside a normal
;;; allocation.  THAT METHOD CANNOT MEASURE THIS COLLECTOR: an incremental GC chops collection
;;; into ~us slices spread across every allocation, forms no >1 ms outliers, and so scores 0% --
;;; which reads as "LambLisp never collects" rather than "LambLisp never blocks".  The honest
;;; figure comes from the VM's own monotonic GC clock, sampled either side of the same workload.
;;; (Platform.gc-diag) index 10 is total us inside gc_pass since boot; it never resets.
;;; Emitted under the SAME field names the competitors use so the report needs no special case --
;;; the instrument differs and the chart hatches LambLisp's bar to say so, but the quantity
;;; (fraction of run time spent collecting) is the same quantity.
;;; ═══════════════════════════════════════════════════════════════════════════════════════════
;;; WARM UP UNTIL THE HEAP HAS STOPPED EXPANDING -- THEN MEASURE.  DO NOT REMOVE.
;;; ═══════════════════════════════════════════════════════════════════════════════════════════
;;; THIS HAS BEEN REDISCOVERED AT LEAST THREE TIMES.  Each time it looks like a GC regression and
;;; each time it is heap growth being charged to the collector:
;;;
;;;   2026-08 -- a residual 54 ms "pause" traced to a synchronous expand() inside a timed cons
;;;              (Amax briefly counts floating garbage).  Fixed then by a steady-state warmup.
;;;   2026-08-31 (B215) -- the gcpause SWEEP added a condition that grows to all available memory.
;;;              On the S3-EYE it went from 1 block to 24 DURING the measured window and reported
;;;              worst = 853,910 us against 94 us for the single-block condition.  The datasheet
;;;              reader then took max() across sweep conditions and was about to publish 36,916 us
;;;              as LambLisp's worst-case GC pause, against a true steady-state ~112 us.
;;;
;;; WHY IT IS NOT A GC PAUSE.  Growing the heap performs a SYNCHRONOUS PSRAM BLOCK ALLOCATION, and
;;; it happens inside a timed `cons`, so the allocator's cost lands in the pause histogram.  The
;;; collector is not involved and says so: in the 853 ms case `gc-urgent-n` and `gc-urgent-max`
;;; were both 0 -- it never once fell behind -- and `gt1ms` equalled `gt5ms` exactly (14 = 14),
;;; which is what a handful of allocation stalls looks like and is NOT what a pause distribution
;;; looks like.
;;;
;;; HOW TO TELL, NEXT TIME, IN ONE STEP: compare `gc-nblocks-warm` with `gc-nblocks` below.  If
;;; they differ, the heap grew while being measured and the worst-pause figure is contaminated --
;;; do not report it as a pause, and do not go looking in the collector for it.
;;;
;;; The warmup runs THE SAME WORKLOAD as the measurement (not a synthetic churn) so it reaches the
;;; same steady state; results are discarded.  It stops when the block count has been unchanged
;;; across two consecutive rounds, or at the round cap -- and if it hits the cap it SAYS SO rather
;;; than measuring anyway and leaving the contamination to be discovered downstream.
(define warm-rounds-max 8)
;;; WARMUP IS BUDGETED FROM n-allocs, NOT FROM cellpop, for the same reason n-allocs is (above).
;;; `2 x cellpop` scales with the LIVE set, so at high occupancy the warmup alone asked for more
;;; allocations than the measurement -- and at the slowest per-allocation rate.  Half the measured
;;; budget is ample: the heap is taken to its ceiling explicitly below, so the warmup no longer has
;;; to GROW anything, it only has to let Amax settle.
(define warm-allocs     (quotient n-allocs 2))

(define warm-result
  (let loop ((round 0) (prev (Platform.n-cell-blocks)) (stable 0))
    (if (or (>= stable 2) (>= round warm-rounds-max))
        (list round prev stable)
        (begin
          (gc-pause-bench warm-allocs heap-size)      ; same shape as the measured call; discarded
          (let ((now (Platform.n-cell-blocks)))
            (loop (+ round 1) now (if (= now prev) (+ stable 1) 0)))))))


;;; TAKE THE HEAP TO ITS CEILING BEFORE MEASURING -- EXPANSION MUST BE IMPOSSIBLE, NOT MERELY
;;; UNLIKELY.  The warmup above grows the heap by running the workload, which works only if the
;;; workload happens to demand every block; anything it does not touch can still expand DURING the
;;; timed region, and a synchronous block allocation inside a timed cons lands in the pause
;;; histogram as though it were a collector pause.  That is not a small effect: it is the whole
;;; difference between 853,910 us and 273 us (B215), and it is well identified in the VM's own log.
;;;
;;; Asking for the cap explicitly removes the question.  expand-to-n-blocks! allocates up front and
;;; honours max-cell-blocks, so after this call there is no block left to add and no expansion can
;;; occur inside the measurement -- rather than us checking afterwards whether one did.
;;; gc-nblocks-warm is read AFTER this, so warm == end remains the one-step check that the timed
;;; region was clean.
(Platform.expand-to-n-blocks! (Platform.max-cell-blocks))

;;; CHECK THE YUASA BOUND, DO NOT INFER IT FROM A PAUSE.
;;; yuasa_N is the pool the collector needs to keep up at the current Amax.  If total_cells() < N
;;; the collector expands MID-RUN, and one block expansion costs ~300 us -- which is why a
;;; condition that expanded reported a 280 us "worst pause" while its median was 1 us.  A single
;;; 300 us outlier among ~49,000 passes is an EXPANSION SIGNATURE, not a collector pause, and
;;; before this the only way to tell was to notice the block count had moved.
;;; Now the bound is readable (gc-diag 11/12), so state it: if pool < N the run is mis-provisioned
;;; and any tail figure it produces is about the allocator, not the GC.
(define gcd0    (Platform.gc-diag))
(define yuasa-M (list-ref gcd0 11))
(define yuasa-N (list-ref gcd0 12))
(define pool    (* (Platform.n-cell-blocks) (Platform.cell-block-size)))
(display "gc-yuasa-M     ") (display yuasa-M) (newline)
(display "gc-yuasa-N     ") (display yuasa-N) (newline)
(display "gc-pool-cells  ") (display pool) (newline)
(if (< pool yuasa-N)
    (begin
      (display "gc-yuasa-VIOLATION 1") (newline)
      (display ";; pool ") (display pool) (display " < yuasa_N ") (display yuasa-N)
      (display " -- the collector WILL expand during the timed region; the worst-pause figure")
      (newline)
      (display ";; below will contain a ~300us block allocation and is NOT a collector pause")
      (newline))
    (begin (display "gc-yuasa-VIOLATION 0") (newline)))

(display "gc-warm-rounds ") (display (list-ref warm-result 0)) (newline)
(display "gc-nblocks-cap ") (display (Platform.max-cell-blocks)) (newline)
(display "gc-nblocks-warm ") (display (Platform.n-cell-blocks)) (newline)
(if (< (list-ref warm-result 2) 2)
    (begin
      (display "gc-warm-UNSTABLE 1")
      (newline)
      (display ";; heap still expanding after ")
      (display warm-rounds-max)
      (display " warmup rounds -- the pause figure below INCLUDES expansion stalls (B215)")
      (newline))
    (begin (display "gc-warm-UNSTABLE 0") (newline)))

;;; Sampled AFTER the warmup, deliberately: gc-diag index 10 is a cumulative since-boot counter, so
;;; taking it before the warmup would charge the warmup's collection time to the measured run.
(define gc0   (list-ref (Platform.gc-diag) 10))
(define wall0 (Platform.micros))

;;; MEASURE UNDER (quiet).  B231: the VM logs from inside the allocator, so a log line emitted
;;; during the measured region is charged to whichever mutator cons happened to trigger it.  On the
;;; ESP32-S3 that put a lone ~280us sample in the histogram and set the reported worst case, which
;;; is the collector being blamed for the VM's logging.
;;;
;;; This is only SAFE to rely on because the macros were fixed to short-circuit: info/news/warn used
;;; to build the whole message with toString() and let the Send function discard it, so (quiet)
;;; suppressed the output but not the cost -- measuring under (quiet) would have changed nothing.
;;; With the fix the string is never built, so this genuinely removes the work.
;;;
;;; (quiet) returns the PREVIOUS setting; restore it rather than forcing verbose, so loading this
;;; file cannot turn logging on for a caller that deliberately turned it off.
(define was-quiet (quiet))

(let* ((r       (gc-pause-bench n-allocs heap-size))
       (ignore1 (quiet was-quiet))            ;; restore BEFORE reporting, so results still print
       (worst   (list-ref r 0))
       (mean    (list-ref r 1))
       (cnt-1ms (list-ref r 2))
       (cnt-5ms (list-ref r 3)))
  (display "gc-pause-worst ") (display worst)   (display " us") (newline)
  (display "gc-pause-mean  ") (display mean)    (display " us") (newline)
  (display "gc-pause->1ms  ") (display cnt-1ms) (newline)
  (display "gc-pause->5ms  ") (display cnt-5ms) (newline)
  ;; MEASURED collection time, not estimated from bucket midpoints: the sum of every pause over
  ;; 1 ms.  For a stop-the-world collector that IS its GC time, because a collection cannot hide
  ;; inside a normal allocation.  LambLisp's incremental collector forms no such pauses, so this
  ;; reads ~0 for it and its GC load comes from the VM counters below -- both are fractions of run
  ;; time, but they are not the same instrument and must not be presented as one.
  (display "gc-pause-sumus ") (display (list-ref r 4)) (newline)
  ;; Pause-duration histogram: 16 log-spaced ns buckets.  Buckets start at element 5 (element 4 is
  ;; the pause sum above) -- they were at 4 before that field existed.
  (display "gc-pause-hist")
  (let loop ((i 5))
    (if (< i 21)
        (begin (display " ") (display (list-ref r i)) (loop (+ i 1)))))
  (newline)
  (display "gc-pause-heap  ") (display heap-size) (newline)
  ;;; B229: allocations discarded because they fell in the FIRST collection cycle of the measured
  ;;; region.  The first pass of a cycle measures a per-cell mark cost 5-8x the steady state, so a
  ;;; time-budgeted quantum overshoots once, on that pass -- which is the single outlier this bench
  ;;; kept reporting.  Excluding it makes the figure describe the steady state the datasheet claims.
  ;;; Printed so the exclusion is VISIBLE: a silently trimmed distribution is worse than a noisy one.
  (display "gc-discarded   ") (display (list-ref r 21)) (newline)
  ;;; Pause attribution -- see the comment block in mop3_gc_pause_bench.  worst-ngc-d 0 with
  ;;; worst-nfree-d -1 means the worst cons did NO collector work at all.  ctrl-worst is a
  ;;; non-allocating window timed by the same harness in the same loop: a large value there
  ;;; cannot be the collector's doing and indicts the platform (flash-cache stall, WiFi/BLE
  ;;; task, FreeRTOS tick) instead.
  (display "gc-worst-i     ") (display (list-ref r 22)) (newline)
  (display "gc-worst-ngc-d ") (display (list-ref r 23)) (newline)
  (display "gc-worst-nfree-d ") (display (list-ref r 24)) (newline)
  (display "gc-ctrl-worst  ") (display (list-ref r 25)) (newline)
  (display "gc-ctrl-over100 ") (display (list-ref r 26)) (newline)
  (display "gc-worst-grow-d ") (display (list-ref r 27)) (newline)
  (display "gc-markstack-grows ") (display (list-ref r 28)) (newline)
  (display "gc-worst-urgent-d ") (display (list-ref r 29)) (newline)
  (display "gc-urgent-calls ") (display (list-ref r 30)) (newline)
  (display "gc-urgent-max-us ") (display (list-ref r 31)) (newline)
  (display "gc-startmark-max-us ") (display (list-ref r 32)) (newline)
  (display "gc-startmark-nroots ") (display (list-ref r 33)) (newline)
  (display "gc-extraroots-max-us ") (display (list-ref r 34)) (newline)
  (display "gc-extraroots-pushes ") (display (list-ref r 35)) (newline)
  ;;; B147 attribution: the COLLECTOR's own view of the same run, beside the mutator's.
  ;;; (Platform.gc-diag) -> (pass-max-us urgent-max-us urgent-calls).  Printed with `display`
  ;;; deliberately: warn() output cannot survive the embedded path (W3_REPL_QUIET suppresses it at
  ;;; the source and serial_run.py drops any line naming LambMemory or gc_pass), so a warn-based
  ;;; probe reports nothing whatever happens and reads as a clean result.
  ;;; If gc-pause-worst is tens of ms while BOTH of these stay small, the pause is not in the
  ;;; collector at all and this bench is charging foreign time to GC.
  ;; POPULATION AND LOAD.  gcload alone does not compare across runtimes -- a collector with a
  ;; bigger heap or fewer live objects is doing different work -- so report the population the
  ;; figure is a fraction OF.  Field order follows (Platform.gc-diag); the labels here were stale
  ;; once before, printing indices 0/1/2 as passmax/urgmax/urgcnt after the list was reordered.
  (let ((d (Platform.gc-diag)))
    (display "gc-amax        ") (display (list-ref d 0)) (newline)   ; peak TRUE LIVE
    (display "gc-live        ") (display (list-ref d 1)) (newline)   ; live at last mark
    (display "gc-npass-idle  ") (display (list-ref d 2)) (newline)
    (display "gc-npass-work  ") (display (list-ref d 3)) (newline)
    (display "gc-t-mark-ns   ") (display (list-ref d 4)) (newline)   ; measured per-cell cost
    (display "gc-t-sweep-ns  ") (display (list-ref d 5)) (newline)
    (display "gc-mark-q      ") (display (list-ref d 6)) (newline)
    (display "gc-sweep-q     ") (display (list-ref d 7)) (newline)
    (display "gc-urgent-max  ") (display (list-ref d 8)) (newline)
    (display "gc-urgent-n    ") (display (list-ref d 9)) (newline))
  (display "gc-wall-us     ") (display (- (Platform.micros) wall0)) (newline)
  (display "gc-allocs      ") (display n-allocs) (newline)
  (display "gc-collections ") (display n-cycles) (newline)
  (display "gc-load-us     ") (display (- (list-ref (Platform.gc-diag) 10) gc0)) (newline)
  ;;; B229: ASK THE VM FOR THE POOL.  This was (n-cell-blocks * cell-block-size), which is the true
  ;;; pool only when every block is the same size.  In the low-occupancy condition the base block is
  ;;; 65,536 cells and the expansions are 8,192, so it reported 4,194,304 against a true 581,632 --
  ;;; 7.2x too large -- and gc-cellfree and every occupancy figure inherited the error.
  ;;; Platform.total-cells is baseBlockSize + NexpansionBlocks * expansionBlockSize, computed once
  ;;; in the VM.  Do not re-derive a quantity the VM already owns.
  (display "gc-cellpop     ") (display (Platform.total-cells)) (newline)
  (display "gc-blocks      ") (display (Platform.n-cell-blocks))
  (display " base ") (display (Platform.cell-block-size))
  (display " exp ")  (display (Platform.extension-block-size)) (newline)
  ;;; FREE = pop - live, consistent with the `used` above.  Platform.nfree is the CURRENT free
  ;;; list, which excludes floating garbage and so would not sum with a live-based `used`.
  (display "gc-cellfree    ")
  (display (- (Platform.total-cells) (list-ref (Platform.gc-diag) 1))) (newline)
  ;;; USED = pop - free.  Emitted explicitly so the three numbers can be compared across runtimes
  ;;; at a glance: cellpop is equal by configuration (65,536 everywhere), but USED is not, because
  ;;; object representation differs -- TinyScheme boxes integers with no fixnum cache, so 30,000
  ;;; app objects cost it ~60,000 cells where LambLisp's sint cache makes them cost ~30,000.
  ;;; Free headroom drives collection frequency, so anything derived from collection rate is only
  ;;; comparable when these three are known.  Do not make a reader derive them from allocs/colls.
  ;;; USED = LIVE AT LAST MARK, not (pop - nfree).
  ;;; LambLisp has no forced-collection primitive -- the collector is incremental, so there is no
  ;;; (gc) to call before sampling the way the stop-the-world comps do.  It does not need one:
  ;;; (Platform.gc-diag) index 1 is _dbg_live_marked, true live from the last COMPLETED mark, which
  ;;; is precisely the post-collection figure.
  ;;; (pop - nfree) is live PLUS everything allocated during the current cycle, and for an
  ;;; incremental collector that is most of the pool by design: measured 2026-08-29, doubling the
  ;;; pool 65,536 -> 131,072 left (pop - nfree) at 89% occupancy instead of the predicted 31%,
  ;;; because the extra headroom simply became floating garbage.  Reporting that as "used" makes
  ;;; occupancy a pacing artefact rather than a statement about the live set.
  (display "gc-cellused    ") (display (list-ref (Platform.gc-diag) 1)) (newline)
  (display "gc-nblocks     ") (display (Platform.n-cell-blocks)) (newline)
(display "--- done ---") (newline))
