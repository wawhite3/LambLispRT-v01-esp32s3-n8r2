// Copyright 2026 by Frobenius Norm LLC 2026-09-22
//
// P231 phase 3 -- LVGL BOUND TO THE PANEL ABSTRACTION, NOT TO A BOARD.
//
// This file names no controller, no bus and no GPIO.  It asks `ll_panel_active()`
// what the board has and binds LVGL to it, which is the whole return on phase 0:
// the same code must serve a SCAN panel (LVGL draws straight into the framebuffer
// the hardware is already reading) and a PUSH panel (LVGL draws into a partial
// buffer and a flush callback sends it over a bus).
//
// *** RENDER MODE IS PER PANEL AND IT IS NOT A PREFERENCE (P231 section 6). ***
// `lv_conf.h` is global, so this choice CANNOT be a compile-time one without
// permanently making one of the two panels pay for the other's model:
//
//   SCAN: point LVGL's draw buffer AT fb() and use LV_DISPLAY_RENDER_MODE_DIRECT.
//         The flush callback then has NOTHING TO COPY -- the pixels are already in
//         the buffer the RGB peripheral scans.  A flush that memcpy'd here would be
//         a full-frame copy, every frame, into a buffer the hardware is reading.
//   PUSH: a partial buffer plus a real flush that calls the panel's blit.
//
// THE TICK IS COOPERATIVE AND BUDGETED, NOT A TASK.  `LV_USE_OS` is `LV_OS_NONE`
// on purpose: this runtime has ONE loop and publishes a worst-case pause, so LVGL
// does not get a thread that can preempt the collector.  `lvgl-tick!` takes a
// budget in milliseconds and RETURNS WHETHER IT FINISHED, because a tick that
// silently runs long is indistinguishable from one that had nothing to do -- and
// on this tree that difference is a published number.
#include "LambLisp.h"
#include "ll_panel.h"

//! Select DIRECT rendering (pixel-correct, repaints the whole framebuffer, takes the main loop)
//! over PARTIAL (a flush copy, slightly unclean glyph edges, leaves the board reachable).
//! Default OFF -- see the block at the render-mode switch for the measurement behind that choice.
/*! STILL 0, AND THE REASON IS NO LONGER THE MAIN LOOP -- IT IS A PROGRESSIVE RECURSIVE ARTEFACT.
    The render task below removed the ORIGINAL objection: with LVGL off the cooperative loop, DIRECT
    no longer costs the REPL.  Verified 2026-09-26 -- `(aitrip-panel-start!)` returns and the board
    answers immediately afterwards, where on 2026-09-24 with DIRECT forced in-loop it never returned.
    DIRECT also removes the flush copy's artefacts: the streaked glyph edges under a label are gone.
    BUT IT IS STILL NOT USABLE ON THIS PANEL.  With DIRECT the image area fills with a MINIATURE OF
    THE WHOLE SCREEN, and another inside that, accumulating over successive render passes -- the
    gradient draws correctly for one flash first, which is what shows it is progressive rather than a
    single bad draw.  That is the signature of the framebuffer being read as a source while it is also
    the render target, and this panel has ONE framebuffer that the RGB peripheral scans continuously.
    A cache flush after each render (esp_cache_msync C2M) was tried on a coherency theory, made it
    worse, and was reverted -- see the render task.
    SO THE NEXT STEP IS A SECOND FRAMEBUFFER, not another render-mode flag: DIRECT needs a target the
    scan is not simultaneously reading.  Until then PARTIAL is the usable default, at the cost of the
    flush-copy artefacts it has always had.
    (Kept as a switch, not deleted: the task work is done and real, so whoever adds the second buffer
    flips this and inherits a reachable board.)
    ORIGINAL RATIONALE, still true of the in-loop case:
    This defaulted to 0 while LVGL rendered inside the cooperative main loop: DIRECT repaints the
    whole framebuffer per refresh, which cannot fit a 3 ms tick, and forcing it was measured on
    2026-09-24 to hang `(aitrip-panel-start!)` over the TCP REPL and never give the board back --
    recoverable only by a filesystem upload over serial.  PARTIAL was chosen to keep the board
    REACHABLE, at the cost of a flush copy whose artefacts are visible: streaked glyph edges, and a
    column that comes and goes at the edge of an image.
    LVGL now runs on its own task (`ll_lv_render_task` below), so a full repaint costs display
    latency instead of the main loop, and the condition this guards is already narrow --
    `LL_LVGL_DIRECT && p->model == LL_PANEL_SCAN && p->fb && p->fb()` -- so only a panel whose
    framebuffer is scanned continuously takes this path.  A push panel is unaffected either way.
    DEFINED HERE AND NOT IN A BUILD FLAG ON PURPOSE: `platformio.ini` is GENERATED from
    `w3_pio/boards.json`, so a `-D` typed into it is erased by the next regeneration -- silently,
    taking the fix with it.  Override it from the build only to turn this OFF for a specific board. */
#ifndef LL_LVGL_DIRECT
  #define LL_LVGL_DIRECT 0
#endif

#if LL_LVGL

#include "lvgl.h"
/*! TJPGD DIRECTLY, BECAUSE LVGL'S DECODER CHAIN ACCEPTS THE IMAGE AND DRAWS NOTHING.
    See ll_lv_show_jpeg() for the measurement that forced this. */
#include "src/libs/tjpgd/tjpgd.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_cache.h"                   // esp_cache_msync -- flush CPU writes for the RGB DMA

/*! Forward declarations: the render-task machinery is defined further down, next to the tick
    mop it replaces, because that is where a reader looking for "who calls lv_timer_handler" will go.
    `lvgl-init` appears earlier in the file and has to start it, hence these. */
static bool ll_lv_lock(uint32_t wait_ms);
static void ll_lv_unlock(void);
static bool ll_lv_task_start(Lamb &lamb);

#define mop3_gc_protect(__thing__, __code__) do { \
    lamb.gc_root_push(__thing__);                 \
    { __code__ };                                 \
    lamb.gc_root_pop();                           \
  } while (0)

static bool          ll_lv_ready = false;
static lv_display_t *ll_lv_disp  = 0;

/*! HANDLES TO THE TWO HUD STRIPS, so Scheme can write live values into them.
    Without these the strips are decoration: `lvgl-smoke` creates them with fixed text and
    nothing can ever change it, which is a HUD that cannot report anything -- the exact defect
    [P123] E15 is about ("the interface must show when it is lying").  A display whose numbers
    cannot move is indistinguishable from one whose numbers happen not to have moved.
    This is deliberately NOT the [P231] phase-4 DSL: that gives Scheme named widgets in general.
    These two pointers give the HUD its two lines now, and cost nothing the DSL will not replace. */
static lv_obj_t     *ll_lv_top = 0;      //!< status strip, top
static lv_obj_t     *ll_lv_bot = 0;      //!< telemetry strip, bottom
static lv_obj_t     *ll_lv_rssi = 0;     //!< link-strength readout, its own object

/*! OBJECT HANDLES FOR SCHEME.  A display layout is application policy, not driver policy: which
    widgets exist, where they sit and what they say differs per target and changes far more often
    than the driver does.  So the C++ side offers GENERIC primitives -- make a label, make a bar,
    set text/position/colour/size/value -- and Scheme decides the arrangement.  Adding a widget
    then costs an edit to a `.scm` file that can be pushed in seconds, rather than a mop, a
    rebuild and a reflash.

    Scheme cannot hold a pointer, so each object is addressed by a small integer index into this
    table.  An out-of-range or stale handle is REFUSED rather than dereferenced: a wrong handle
    must not be able to write through a dangling pointer. */
#define LL_LV_MAX_OBJS 48
static lv_obj_t     *ll_lv_objs[LL_LV_MAX_OBJS];
static int           ll_lv_nobjs = 0;

//! -> handle index, or -1 when the table is full.
static int ll_lv_obj_put(lv_obj_t *o)
{
  int res = -1;
  if (o && ll_lv_nobjs < LL_LV_MAX_OBJS) {
    ll_lv_objs[ll_lv_nobjs] = o;
    res = ll_lv_nobjs++;
  }
  return res;
}

//! -> the object, or NULL for any handle this table does not currently hold.
static lv_obj_t *ll_lv_obj_get(LL_int32 h)
{
  return (h >= 0 && h < ll_lv_nobjs) ? ll_lv_objs[h] : 0;
}

//! LVGL needs a millisecond clock.  esp_timer is used rather than millis() so this
//! file stays free of the Arduino layer, which not every target in this tree has.
static uint32_t ll_lv_tick_cb(void) { return (uint32_t) (esp_timer_get_time() / 1000); }

/*! Flush.  On a SCAN panel this is deliberately a no-op that only reports completion:
    LVGL rendered DIRECTLY into the scanned framebuffer, so there is nothing to move.
    Writing a memcpy here "for symmetry" would cost a full 460,800 B copy per frame
    into a buffer the LCD DMA is concurrently reading -- the exact contention that
    made the first test pattern flicker. */
static void ll_lv_flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px)
{
  const LL_Panel *p = ll_panel_active();
  if (p && p->model == LL_PANEL_SCAN) {
    /*! SCAN + PARTIAL: LVGL rendered into its OWN buffer, so the region must be copied into the
        scanned framebuffer.  THE SOURCE STRIDE IS THE DRAW BUFFER'S, NOT THE AREA WIDTH.  Those
        differ whenever LVGL renders a region narrower than the buffer -- which is every label --
        and copying with the area width as stride shears each row progressively, so text arrives
        chopped and scattered across the screen while wide regions look roughly right.
        `lv_display_get_buf_active` reports the real stride in bytes; ask rather than assume. */
    uint16_t *fb = p->fb ? p->fb() : 0;
    if (fb) {
      lv_draw_buf_t *db = lv_display_get_buf_active(disp);
      const int w = area->x2 - area->x1 + 1;
      const int h = area->y2 - area->y1 + 1;
      const int src_stride = (db && db->header.stride) ? (int) (db->header.stride / 2) : w;
      const uint16_t *src = (const uint16_t *) px;
      for (int r = 0; r < h; r++) {
        const int dy = area->y1 + r;
        if (dy < 0 || dy >= p->h) continue;
        uint16_t       *drow = fb + (size_t) dy * p->w + area->x1;
        const uint16_t *srow = src + (size_t) r * src_stride;
        for (int i = 0; i < w; i++) {
          if (area->x1 + i < p->w) drow[i] = srow[i];
        }
      }
      /*! [B662] PUSH THIS COPY OUT TO PSRAM.  This callback is the path EVERY widget and EVERY
          camera frame takes into the scanned framebuffer, and the RGB peripheral reads that
          framebuffer by DMA -- it does not see our cache.  Without this the scan can fetch a
          region LVGL has just rendered and get the previous contents, which is the "streaked glyph
          edges, and a column that comes and goes at the edge of an image" this file's header has
          recorded as a flush-copy artefact for weeks.  The panel layer owns the call because only
          it knows whether the active panel is the PSRAM-scanned one. */
      extern void ll_panel_fb_writeback(int y, int h);
      ll_panel_fb_writeback(area->y1, h);
    }
  }
  else if (p && p->model == LL_PANEL_PUSH && p->blit) {
    //! PUSH: the pixels really do have to travel.  Not exercised yet -- no push panel
    //! in this tree has been through LVGL -- so treat this arm as untested code.
    extern Lamb *ll_lamb_singleton_for_lvgl(void);
    Lamb *l = ll_lamb_singleton_for_lvgl();
    if (l) p->blit(*l, area->x1, area->y1,
                   area->x2 - area->x1 + 1, area->y2 - area->y1 + 1,
                   (const uint16_t *) px);
  }
  lv_display_flush_ready(disp);
}

static void ll_lv_log_cb(lv_log_level_t level, const char *buf);   //!< fwd
static Lamb *ll_lv_lamb = 0;
Lamb *ll_lamb_singleton_for_lvgl(void) { return ll_lv_lamb; }

//! LVGL's log sink.  Prefixed so its lines are attributable at a glance in a mixed transcript.
static void ll_lv_log_cb(lv_log_level_t level, const char *buf)
{
  (void) level;
  if (ll_lv_lamb && buf) ll_lv_lamb->log("LVGL: %s\n", buf);
}

/*! (lvgl-init) -> #t / #f.  Idempotent.  Requires the panel to be up already:
    LVGL binds to fb(), and fb() is NULL until the panel's own init has run. */
static Sexpr_t mop3_lvgl_init(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_init()");
  ll_try {
    Sexpr_t res = HASHT;
    if (ll_lv_ready) return HASHT;             //!< guard before any scaffolding

    const LL_Panel *p = ll_panel_active();
    if (!p || !ll_panel_ready()) {
      lamb.log("lvgl-init: no panel, or (lcd-init) has not run -- refusing\n");
      res = HASHF;
    }
    else {
      ll_lv_lamb = &lamb;
      //! ROUTE LVGL'S OWN DIAGNOSTICS TO THE CONSOLE BEFORE ANYTHING CAN FAIL.
      //! `LV_ASSERT_HANDLER` is `while(1);` -- a failed assertion does not crash, it SPINS, and
      //! with `LV_LOG_PRINTF 0` and no print callback the reason is written nowhere.  The result
      //! is a board that stops inside an LVGL call with no output at all, which reads as a
      //! hardware or DMA fault rather than as LVGL refusing a bad argument.
      lv_log_register_print_cb(ll_lv_log_cb);
      lamb.log("lvgl-init: A before lv_init\n");
      lv_init();
      lamb.log("lvgl-init: B after lv_init\n");
      lv_tick_set_cb(ll_lv_tick_cb);
      ll_lv_disp = lv_display_create(p->w, p->h);
      lamb.log("lvgl-init: C after display_create\n");
      if (!ll_lv_disp) {
        lamb.log("lvgl-init: lv_display_create failed\n");
        res = HASHF;
      }
      else {
        lv_display_set_flush_cb(ll_lv_disp, ll_lv_flush_cb);
        //! THE FRAMEBUFFER'S BYTE ORDER IS NATIVE RGB565, AND EVERY WRITER USES IT.  The RGB
        //! peripheral fetches the 16-bit word and drives the data lines with it as stored, so there
        //! is no swap anywhere: LVGL is left at its default and `ait_fill` stores `color` unchanged.
        //! MEASURED, not reasoned, on the glass in both directions:
        //!   LV_COLOR_FORMAT_RGB565_SWAPPED renders a near-black background as PURPLE (both DIRECT
        //!   and PARTIAL), and a fill that byte-swapped red 0xF800 to 0x00F8 showed BLUE, which is
        //!   exactly (r0,g7,b24).  Unswapped, both paths show the colour asked for.
        //!
        //! CORRECTED 2026-09-27.  This block used to assert the buffer was consumed BIG-ENDIAN and,
        //! on that basis, that the scalar `lcd-box` path "does need a swap".  The measurement it
        //! quoted was real; the MODEL built on top of it was invented, and the invented half is what
        //! the next reader inherited -- it licensed a `__builtin_bswap16` in `ait_fill` that made
        //! every `lcd-clear`/`lcd-box`/`lcd-rgb565!` draw the wrong colour for as long as it stood.
        //! One framebuffer admits ONE convention; if two writers disagree, at most one is right, and
        //! the way to find out is to ask the glass rather than to explain the other path away.
        lv_display_set_color_format(ll_lv_disp, LV_COLOR_FORMAT_RGB565);
        lamb.log("lvgl-init: D after flush_cb + native RGB565 cf\n");
        //! DIRECT mode hands LVGL the LIVE scan framebuffer, and `lv_display_set_buffers`
        //! then initialises 460,800 bytes of PSRAM while the LCD peripheral is already
        //! streaming that same memory at 26 MB/s.  Measured 2026-09-24: the call never
        //! returns -- no crash, no log, the board simply stops inside it.  PARTIAL mode gives
        //! LVGL a small buffer of its own and pays a flush copy per region instead.
        //! DIRECT is correct for a SCAN panel and needs no flush copy at all.  It was disabled
        //! while `lv_display_set_buffers` was hanging -- that turned out to be the LV_DRAW_BUF_ALIGN
        //! assert (a silent `while(1);`), not the mode.  PARTIAL then rendered into LVGL's own
        //! buffer, whose ROW STRIDE is not the area width, so copying it with the area width as
        //! stride sheared every narrow region -- text most visibly.  DIRECT removes the copy, and
        //! with it the stride question.  The framebuffer must satisfy the same 64-byte alignment.
        /*! *** DIRECT RENDERS CORRECTLY AND CAN STARVE THE MAIN LOOP.  READ THIS BEFORE CHANGING
            THE RENDER MODE. ***

            In DIRECT mode LVGL repaints the WHOLE framebuffer -- 480x480 here -- on every
            refresh.  If that repaint outruns the caller's tick budget it does not degrade
            gracefully: it consumes the loop, and everything else the loop drives stops.  On this
            board that is the LLIP serial receiver and the TCP REPL, both of which simply vanish.

            THE RESULTING FAILURE LOOKS FINE FROM EVERY ANGLE AT ONCE, which is why it is worth a
            comment rather than a memory.  The display is correct.  The firmware has not crashed.
            WiFi keeps answering pings, because the network stack runs in its own task.  So the
            board is alive, right-looking, and unreachable by every remote path simultaneously --
            and the obvious conclusion, that the network broke, is wrong.  Recovery costs a
            filesystem upload over serial, since no remote channel survives.

            Observed 2026-09-24 on the AITRIP panel.  The mitigation in the Scheme layer is that
            the panel is OPT-IN at boot (`panel_autostart`, default 0), so a board always comes up
            reachable and the display is started deliberately.  If you make DIRECT the
            unconditional default, pair it with a tick budget that can actually cover a
            full-screen repaint, or drive LVGL from its own task. */

        //! PARTIAL IS THE DEFAULT BECAUSE IT KEEPS THE BOARD REACHABLE, NOT BECAUSE IT RENDERS
        //! BETTER.  It does not: its flush copy produces slightly unclean glyph edges where
        //! DIRECT is pixel-correct.  But DIRECT repaints the whole framebuffer per refresh and
        //! takes the main loop with it (see the block above), and a board that renders perfectly
        //! and cannot be reached is not usable.  Measured 2026-09-24: with DIRECT forced,
        //! `(aitrip-panel-start!)` over the TCP REPL never returned and the REPL never answered
        //! again; with PARTIAL the same call leaves the board responsive.
        //!
        //! `LL_LVGL_DIRECT` selects DIRECT for anyone who wants pixel-correct output and either
        //! accepts the cost or drives LVGL from its own task.  That is the real fix and it is not
        //! done here; this is the safe default until it is.
        if (LL_LVGL_DIRECT && p->model == LL_PANEL_SCAN && p->fb && p->fb()) {
          //! THE POINT OF THE WHOLE ABSTRACTION: LVGL's draw buffer IS the scanned
          //! framebuffer.  No flush copy, no second buffer, no tearing beyond what
          //! the scan already implies (P123 G2).
          const size_t bytes = (size_t) p->w * (size_t) p->h * 2u;
          lamb.log("lvgl-init: E before set_buffers\n");
          lv_display_set_buffers(ll_lv_disp, (void *) p->fb(), 0, bytes,
                                 LV_DISPLAY_RENDER_MODE_DIRECT);
          lamb.log("lvgl: DIRECT into the scan framebuffer fb=%p, no flush copy\n", (void *) p->fb());
        }
        else {
          //! NAME THE REASON THAT ACTUALLY APPLIES.  This line used to read "fb unaligned or
          //! push panel", which on this board names neither: the framebuffer is aligned and
          //! the panel IS a scan panel, so a reader chasing a display fault was sent to look
          //! at alignment and at the panel model, both of which are fine.  The condition has
          //! four terms and the one that is false is almost always the build switch.
          lamb.log("lvgl: PARTIAL -- LL_LVGL_DIRECT=%d scan_panel=%d fb=%p\n",
                   (int) LL_LVGL_DIRECT, (int) (p->model == LL_PANEL_SCAN),
                   (void *) (p->fb ? p->fb() : nullptr));
          //! PUSH: a partial buffer LVGL owns, flushed over the bus.  A tenth of the
          //! screen, which is the sizing P231 prices.
          const size_t part = (size_t) p->w * (size_t) (p->h / 10) * 2u;
          //! ALIGNMENT IS A HARD PRECONDITION, NOT A PREFERENCE.  `lv_display_set_buffers`
          //! asserts `buf1 == lv_draw_buf_align(buf1, cf)`, and `LV_ASSERT_HANDLER` is
          //! `while(1);` -- so a buffer that merely came back from `heap_caps_malloc` (4/8-byte
          //! aligned) makes the call SPIN FOREVER with no crash and no message.  Measured
          //! 2026-09-24: the board stopped inside that call and produced no output at all.
          /*! [B662] THE DRAW BUFFER GOES IN INTERNAL DRAM IF IT FITS, NOT PSRAM -- THIS IS THE
              FLICKER FIX, AND IT IS A BANDWIDTH ARGUMENT RATHER THAN A CAPACITY ONE.

              The RGB peripheral streams the framebuffer out of PSRAM CONTINUOUSLY at ~26 MB/s.
              A draw buffer in PSRAM makes every flush copy READ from that same bus as well as
              write to it, so the renderer competes with the scan twice per copy.  Starve the scan
              and it emits dummy bytes: the symptom is SHORT HORIZONTAL DISCONTINUITIES with an
              occasional larger flash -- a LINE-timing failure, which is what was observed.

              MEASURED, three arms, only the renderer varying:
                factory firmware (LVGL, draw buffer 200 lines in INTERNAL DRAM) -> no flicker
                ours, LVGL on  (48 lines in PSRAM)                              -> flicker
                ours, LVGL off (nothing rendering)                              -> no flicker
              The manufacturer's own demo allocates `screenWidth * 200` with MALLOC_CAP_INTERNAL
              (vendor/1-Demo/4.0_LvglWidgets.ino:144).  We cannot afford 192 KB -- internal DRAM
              measured ~31 KB free with the HUD up -- but the LOCATION is the variable that matters,
              not the size, so take the largest slice of internal that will fit.

              IT SHRINKS RATHER THAN FAILING, AND SAYS WHICH IT GOT.  A fixed internal request would
              fail on a board whose internal DRAM is already committed and silently leave us on the
              PSRAM path, i.e. exactly the bug, reported as success.  The log line names the region
              and the line count so the arm can be shown to have applied. */
          //! [B662] Release the display's DRAW-BUFFER reservation here, immediately before the
          //! allocation it was held for -- the panel reserved it at install time, while the pool
          //! was still whole, so this lands in that hole instead of in what LambLisp left behind.
          { void ll_fastram_release(const char *); ll_fastram_release("panel-draw"); }
          void *b1 = 0;
          size_t part_used = 0;
          const char *where = "PSRAM";
          //! Start at the size the PANEL RESERVED for us (h/20 = 24 lines), not at h/10: the
          //! reservation is what guarantees the memory is there, so asking for twice it merely
          //! fails once before landing on the same answer.  Measured: 24 lines in internal DRAM is
          //! where the flicker stopped.
          for (size_t lines = (size_t) (p->h / 20); lines >= 8u && !b1; lines /= 2u) {
            const size_t want = (size_t) p->w * lines * 2u;
            b1 = heap_caps_aligned_alloc(LV_DRAW_BUF_ALIGN, want,
                                         MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
            if (b1) { part_used = want; where = "INTERNAL"; }
          }
          if (!b1) {                                  //!< internal is full: the old behaviour
            b1 = heap_caps_aligned_alloc(LV_DRAW_BUF_ALIGN, part, MALLOC_CAP_SPIRAM);
            part_used = part;
          }
          lamb.log("lvgl-init: G draw buffer in %s, %s lines, %s bytes, buf=%p [B662]\n",
                   where, ascii.dec((LL_int32) (part_used / (size_t) p->w / 2u)),
                   ascii.dec((LL_int32) part_used), b1);
          if (!b1) { lamb.log("lvgl-init: partial buffer alloc failed\n"); res = HASHF; }
          else {
            lamb.log("lvgl-init: H before set_buffers(partial)\n");
            lv_display_set_buffers(ll_lv_disp, b1, 0, part_used,
                                   LV_DISPLAY_RENDER_MODE_PARTIAL);
            lamb.log("lvgl-init: I after set_buffers(partial)\n");
            lamb.log("lvgl: PARTIAL buffer, flush over the bus\n");
          }
        }
      }
    }
    if (res == HASHT) {
      //! CLEAR THE FRAMEBUFFER ONCE, HERE.  PARTIAL mode repaints only dirty areas, so anything
      //! LVGL has not yet drawn shows whatever was in PSRAM when the framebuffer was allocated --
      //! which looks like scrambled text rather than like an empty screen.  One clear at init is
      //! not the per-frame full-screen copy that starves the scan; it happens once.
      if (p && p->model == LL_PANEL_SCAN && p->fb && p->fb()) {
        uint16_t *fb = p->fb();
        const size_t px = (size_t) p->w * (size_t) p->h;
        for (size_t i = 0; i < px; i++) fb[i] = 0;
      }
      ll_lv_ready = true;
      /*! START THE RENDER TASK LAST, AFTER `ll_lv_ready`.    It calls `lv_timer_handler`
          immediately, so nothing may still be half-built when it first runs.  Started here rather
          than lazily in `lvgl-tick!` so a board that never ticks still repaints, and so a failure to
          create it is reported once at init instead of silently every tick.
          If it does not start, `lvgl-tick!` keeps pumping LVGL on the main loop exactly as before --
          the display is then in the old PARTIAL-shaped situation rather than broken. */
      ll_lv_task_start(lamb);
      lamb.log("lvgl-init: LVGL %s.%s.%s up on %s\n",
               "9", "3", "0", p ? p->name : "?");
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! --- LVGL ON ITS OWN TASK ----------------------------------------------------------
    WHY THIS EXISTS.  This panel is scanned continuously out of PSRAM, so the only way to get
    pixel-correct output is `LV_DISPLAY_RENDER_MODE_DIRECT` -- LVGL rendering straight into the
    framebuffer, no flush copy.  But a 480x480 repaint cannot fit the cooperative loop's 3 ms tick,
    and forcing DIRECT while rendering INSIDE that loop was measured on 2026-09-24 to take the board
    out entirely: `(aitrip-panel-start!)` over the TCP REPL never returned and the REPL never
    answered again, recoverable only by a filesystem upload over serial.  PARTIAL was the safe
    default, and its flush copy is what streaks under a label and flickers a column at an image edge.
    The source has named the real fix since that day -- "drive LVGL from its own task" -- and this is
    it.  Rendering moves off the main loop, so a full repaint costs the DISPLAY latency instead of
    costing the REPL.

    THE MUTEX IS NOT OPTIONAL.  LVGL is not thread-safe: every `lv_*` call, from this task and from
    every mop, must hold it.  A recursive mutex, because the mops nest (a `frame-jpeg!` both writes
    the buffer and invalidates the object, and `lvgl-init` builds widgets while holding it).
    HOLD IT BRIEFLY AND NEVER ACROSS A BLOCKING CALL -- the main loop takes it too, so anything that
    sleeps while holding it stalls the REPL, which is the exact failure this change exists to avoid. */
static SemaphoreHandle_t ll_lv_mux  = 0;
static TaskHandle_t      ll_lv_task = 0;
static volatile bool     ll_lv_task_run = false;

//! -> true when the caller now holds the LVGL lock.  Answers true when there is no mutex yet, so
//! code paths that run before `lvgl-init` behave exactly as they did before this change.
static bool ll_lv_lock(uint32_t wait_ms)
{
  if (!ll_lv_mux) return true;
  return xSemaphoreTakeRecursive(ll_lv_mux, pdMS_TO_TICKS(wait_ms)) == pdTRUE;
}

static void ll_lv_unlock(void)
{
  if (ll_lv_mux) xSemaphoreGiveRecursive(ll_lv_mux);
}

/*! The render task.  Nothing else belongs in here: it takes the lock, lets LVGL do its work, and
    gives the lock back.  The delay is OUTSIDE the lock on purpose -- holding it while sleeping would
    block every mop and therefore the main loop. */
static void ll_lv_render_task(void *arg)
{
  (void) arg;
  while (ll_lv_task_run) {
    uint32_t next = 10;
    if (ll_lv_lock(50)) {
      next = lv_timer_handler();
      /*! CACHE FLUSH TRIED HERE AND REVERTED -- IT MADE THE DISPLAY WORSE, NOT BETTER.
          The theory was sound on its face: in DIRECT mode LVGL's draw buffer IS the framebuffer, that
          framebuffer is in PSRAM, the CPU writes it through the cache and the RGB peripheral DMAs it
          straight out of memory -- so a dirty cache line is not what gets scanned.  The symptom fitted
          too: a cache line is 64 bytes = 32 pixels, a 240-wide image centred on a 480-wide panel
          starts at x=120, and 120 is 24 pixels into a line, so the one partial line would be exactly
          at the edge where a stale strip was visible.
          `esp_cache_msync(fb, w*h*2, ESP_CACHE_MSYNC_FLAG_DIR_C2M)` here, inside the lock and after
          `lv_timer_handler`, produced a RECURSIVE display instead: the image area showed a miniature
          of the whole screen, and another inside that.  Reported from the bench 2026-09-26.  The cause
          of THAT is not established either -- it is recorded so the next person does not re-derive the
          coherency argument, find it plausible, and rediscover the same result. */
      ll_lv_unlock();
    }
    if (next == 0 || next > 30) next = (next == 0) ? 1 : 30;
    vTaskDelay(pdMS_TO_TICKS(next));
  }
  ll_lv_task = 0;
  vTaskDelete(NULL);
}

//! Start the render task once.  Idempotent; returns true if the task is running afterwards.
static bool ll_lv_task_start(Lamb &lamb)
{
  if (ll_lv_task) return true;
  if (!ll_lv_mux) {
    ll_lv_mux = xSemaphoreCreateRecursiveMutex();
    if (!ll_lv_mux) { lamb.log("lvgl: mutex alloc failed -- staying on the main loop\n"); return false; }
  }
  ll_lv_task_run = true;
  //! Core 1: the LambLisp main loop runs on the loopTask, and a full repaint should not compete with
  //! it for the same core.  8 KB is measured-generous for LVGL's own stack; the draw buffers are in
  //! PSRAM and not on it.
  const BaseType_t rc = xTaskCreatePinnedToCore(ll_lv_render_task, "lvgl", 8192, 0, 4,
                                                &ll_lv_task, 1);
  if (rc != pdPASS) {
    ll_lv_task_run = false; ll_lv_task = 0;
    lamb.log("lvgl: render task create failed -- staying on the main loop\n");
    return false;
  }
  lamb.log("lvgl: render task running on core 1 -- DIRECT repaints no longer touch the main loop\n");
  return true;
}

/*! RAII, NOT A HAND-WRITTEN PAIR.  Every mop below has several exits -- guard clauses, a SINGLE
    EXIT `res`, and `ll_catch()` which unwinds -- and a hand-placed `ll_lv_unlock()` in front of each
    is correct exactly until someone adds the next branch.  That is the same defect CLAUDE.md records
    for `gc_root_pop` and for `return` inside a gc_protect block, so it is not repeated here: the
    destructor runs on every path including the throwing one.
    `held` is recorded rather than assumed -- a timed-out take must not give back a lock it never
    got, which would release the render task's. */
struct LlLvGuard {
  bool held;
  explicit LlLvGuard(uint32_t wait_ms = 200) { held = ll_lv_lock(wait_ms); }
  ~LlLvGuard() { if (held) ll_lv_unlock(); }
  LlLvGuard(const LlLvGuard &) = delete;
  LlLvGuard &operator=(const LlLvGuard &) = delete;
};


/*! (lvgl-tick! MS) -> #t if LVGL finished its work inside the budget, #f if it was
    still busy when the budget ran out.  THE RETURN VALUE IS THE POINT: a UI that
    quietly overruns is how a runtime that publishes a worst-case pause stops being
    able to. */
static Sexpr_t mop3_lvgl_tick(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_tick()");
  ll_try {
    Sexpr_t res = HASHF;
    if (!ll_lv_ready) return HASHF;            //!< guard before scaffolding

    LL_int32 budget = 8;
    if (sexpr != NIL && lamb.car(sexpr) != NIL) budget = lamb.car(sexpr)->mustbe_int32();
    if (budget < 1) budget = 1;

    /*! WHEN THE RENDER TASK OWNS RENDERING, THIS MUST NOT ALSO RENDER.    Two threads inside
        `lv_timer_handler` is precisely what the mutex forbids, and calling it from the main loop is
        what made a DIRECT repaint take the REPL down.  So with the task running this becomes a
        yield: the caller's app-loop keeps its shape and its budget argument, and the answer is #t
        because LVGL is never "still busy" from this loop's point of view any more.
        KEPT WORKING WITHOUT THE TASK, deliberately -- if the task failed to start, the old
        in-loop pumping is still the behaviour, so a board is never left with nothing driving LVGL. */
    if (ll_lv_task) {
      res = HASHT;
    }
    else {
      const int64_t t0 = esp_timer_get_time();
      uint32_t      next = lv_timer_handler();
      //! `lv_timer_handler` returns ms until it next wants running.  Keep pumping only
      //! while it wants to run NOW and we are still inside the budget.
      while (next == 0 && (esp_timer_get_time() - t0) < (int64_t) budget * 1000) {
        next = lv_timer_handler();
      }
      res = (next != 0) ? HASHT : HASHF;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-smoke) -> #t.  Build a few real widgets so the stack is proved end to end:
    LVGL allocates from its PSRAM pool, renders into the scanned framebuffer, and the
    result is visible without any flush copy.

    THIS REPLACED A CALL TO `lv_demo_widgets`, AND THE REASON IS A BUILD FACT WORTH
    RECORDING.  Running the vendor's own demo would have made phase 2 directly
    comparable to phase 1's baseline, which is why P231 wanted it -- but LVGL's
    PlatformIO package compiles only its `src/` directory, and `demos/` is a SIBLING
    of that, so `lv_demo_widgets` resolves at COMPILE time (the header is found) and
    vanishes at LINK.  Exactly the "compiles clean, fails at LINK" shape.  Getting it
    back means overriding the package's source filter, which is worth doing when the
    baseline comparison is actually needed and is not worth blocking bring-up for.

    These widgets are also the ones P123 Part G needs -- two label strips and a bar --
    so this is the HUD's skeleton rather than a throwaway. */
static Sexpr_t mop3_lvgl_smoke(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_smoke()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = HASHF;
    if (!ll_lv_ready) { lamb.log("lvgl-smoke: (lvgl-init) has not run\n"); return HASHF; }

    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x101418), LV_PART_MAIN);

    lv_obj_t *top = lv_label_create(scr);
    //! Overwritten by `lvgl-status!` as soon as the HUD runs; dashes until then.
    lv_label_set_text(top, "LambLisp   link --   f --   bad --");
    lv_obj_set_style_text_color(top, lv_color_hex(0x8fd8e8), LV_PART_MAIN);
    lv_obj_align(top, LV_ALIGN_TOP_LEFT, 12, 18);
    ll_lv_top = top;

    /*! The link-strength readout is a SEPARATE object from the status strip, and that is the
        point rather than a layout choice.  LVGL invalidates and repaints the whole of any object
        whose text changes, so a single line carrying SSID, address and RSSI together redraws all
        of it every time the signal moves a decibel -- which is visible as the line flickering.
        RSSI is the only part that changes on a timescale of seconds, so it gets its own object
        and the rest of the line is written once and left alone. */
    lv_obj_t *rssi = lv_label_create(scr);
    lv_label_set_text(rssi, "-- dBm");
    lv_obj_set_style_text_color(rssi, lv_color_hex(0x8fd8e8), LV_PART_MAIN);
    lv_obj_align(rssi, LV_ALIGN_TOP_RIGHT, -12, 18);
    ll_lv_rssi = rssi;

    lv_obj_t *mid = lv_label_create(scr);
    lv_label_set_text(mid, "ST7701S 480x480  scan  LVGL 9.3.0");
    lv_obj_set_style_text_color(mid, lv_color_hex(0xe6eaf0), LV_PART_MAIN);
    lv_obj_align(mid, LV_ALIGN_CENTER, 0, 0);

    lv_obj_t *bar = lv_bar_create(scr);
    lv_obj_set_size(bar, 400, 22);
    lv_obj_align(bar, LV_ALIGN_BOTTOM_MID, 0, -46);
    /*! EMPTY, NOT A PLAUSIBLE VALUE.  This used to be set to 1240 -- a fabricated sonar reading
        that looked exactly like a live one.  [P123] E15 says the interface must show when it is
        lying, and a bar sitting at 62% of full scale because someone typed a number is the purest
        form of the lie: an operator cannot tell it from a real reading of 1240 mm.  It stays empty
        until step 5 feeds it real sonar. */
    lv_bar_set_range(bar, 0, 2000);
    lv_bar_set_value(bar, 0, LV_ANIM_OFF);

    lamb.log("lvgl-smoke: scr=%p top=%p\n", (void *) scr, (void *) top);
    lv_obj_t *bot = lv_label_create(scr);
    //! NO FABRICATED TELEMETRY.  This read "sonar 1240mm   MOT L+ R+ 60%" -- invented values that
    //! an operator would read as live.  Dashes say "not connected yet" in a way a number cannot.
    lv_label_set_text(bot, "sonar --      MOT -- --      (no telemetry)");
    lv_obj_set_style_text_color(bot, lv_color_hex(0xf0a552), LV_PART_MAIN);
    lv_obj_align(bot, LV_ALIGN_BOTTOM_MID, 0, -14);
    ll_lv_bot = bot;

    lamb.log("lvgl-smoke: bot=%p -- strips built\n", (void *) bot);
    res = HASHT;
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-status! STRING) / (lvgl-telemetry! STRING) -> #t/#f.
    Write the top and bottom HUD strips.  Returns #f if `lvgl-smoke` has not created them, rather
    than pretending: a caller that thinks it updated the display and did not is worse than one
    told it failed.  The text is copied by LVGL (`lv_label_set_text`), so the Scheme string may be
    collected immediately after -- no rooting needed here. */
static Sexpr_t mop3_lvgl_status(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_status()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = HASHF;
    if (ll_lv_top && sexpr != NIL) {
      lv_label_set_text(ll_lv_top, lamb.car(sexpr)->mustbe_any_str_t()->any_str_get_chars());
      lv_obj_invalidate(ll_lv_top);
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/* ---------------------------------------------------------------------------------------------
   THIN SHIM OVER LVGL.  Each procedure below is ONE LVGL call and nothing else: no defaults, no
   convenience pairings, no layout.  That is deliberate.  A shim that quietly does two things --
   sets a range AND an initial value, or a text colour AND an indicator colour -- is a widget
   wearing a primitive's name, and every widget built on it inherits a decision it cannot see or
   undo.  Policy belongs one layer up, in Scheme, where it can be read and changed without a
   rebuild.

   Objects are addressed by small integer handles: Scheme cannot hold a pointer, and a handle can
   be range-checked, which a pointer cannot.  A stale or out-of-range handle is refused rather
   than dereferenced.

   Naming mirrors LVGL's own (`lv-obj-set-pos` for `lv_obj_set_pos`) so that LVGL's documentation
   is directly usable from Scheme, and so a reader can tell shim from policy by the name alone.
   --------------------------------------------------------------------------------------------- */

//! Read handle H from arg position 0; returns NULL if absent, stale or out of range.
static lv_obj_t *ll_lv_arg_obj(Lamb &lamb, Sexpr_t sexpr)
{
  return (sexpr != NIL) ? ll_lv_obj_get(lamb.car(sexpr)->mustbe_int32()) : 0;
}

/*! (lv-screen-active) -> handle | #f. */
static Sexpr_t mop3_lv_screen_active(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_screen_active()");
  ll_try {
    Sexpr_t res = HASHF;
    if (ll_lv_ready) {
      int h = ll_lv_obj_put(lv_screen_active());
      if (h >= 0) res = lamb.mk_int32((LL_int32) h, env_exec);
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-label-create PARENT) -> handle | #f. */
static Sexpr_t mop3_lv_label_create(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_label_create()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *par = ll_lv_arg_obj(lamb, sexpr);
    if (ll_lv_ready && par) {
      int h = ll_lv_obj_put(lv_label_create(par));
      if (h >= 0) res = lamb.mk_int32((LL_int32) h, env_exec);
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-bar-create PARENT) -> handle | #f. */
static Sexpr_t mop3_lv_bar_create(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_bar_create()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *par = ll_lv_arg_obj(lamb, sexpr);
    if (ll_lv_ready && par) {
      int h = ll_lv_obj_put(lv_bar_create(par));
      if (h >= 0) res = lamb.mk_int32((LL_int32) h, env_exec);
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-label-set-text HANDLE STRING) -> #t/#f. */
static Sexpr_t mop3_lv_label_set_text(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_label_set_text()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *o = ll_lv_arg_obj(lamb, sexpr);
    if (o && lamb.cdr(sexpr) != NIL) {
      lv_label_set_text(o, lamb.cadr(sexpr)->mustbe_any_str_t()->any_str_get_chars());
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-obj-set-pos HANDLE X Y) -> #t/#f. */
static Sexpr_t mop3_lv_obj_set_pos(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_obj_set_pos()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *o = ll_lv_arg_obj(lamb, sexpr);
    if (o && lamb.cdr(sexpr) != NIL && lamb.cddr(sexpr) != NIL) {
      lv_obj_set_pos(o, (int32_t) lamb.cadr(sexpr)->mustbe_int32(),
                        (int32_t) lamb.caddr(sexpr)->mustbe_int32());
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-obj-set-size HANDLE W H) -> #t/#f. */
static Sexpr_t mop3_lv_obj_set_size(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_obj_set_size()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *o = ll_lv_arg_obj(lamb, sexpr);
    if (o && lamb.cdr(sexpr) != NIL && lamb.cddr(sexpr) != NIL) {
      lv_obj_set_size(o, (int32_t) lamb.cadr(sexpr)->mustbe_int32(),
                         (int32_t) lamb.caddr(sexpr)->mustbe_int32());
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-obj-set-style-text-color HANDLE RGB888) -> #t/#f. */
static Sexpr_t mop3_lv_set_text_color(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_set_text_color()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *o = ll_lv_arg_obj(lamb, sexpr);
    if (o && lamb.cdr(sexpr) != NIL) {
      lv_obj_set_style_text_color(o, lv_color_hex((uint32_t) lamb.cadr(sexpr)->mustbe_int32()),
                                  LV_PART_MAIN);
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-obj-set-style-bg-color HANDLE RGB888 PART) -> #t/#f.  PART 0 = MAIN, 1 = INDICATOR. */
static Sexpr_t mop3_lv_set_bg_color(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_set_bg_color()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *o = ll_lv_arg_obj(lamb, sexpr);
    if (o && lamb.cdr(sexpr) != NIL) {
      LL_int32 part = (lamb.cddr(sexpr) != NIL) ? lamb.caddr(sexpr)->mustbe_int32() : 0;
      lv_obj_set_style_bg_color(o, lv_color_hex((uint32_t) lamb.cadr(sexpr)->mustbe_int32()),
                                part ? LV_PART_INDICATOR : LV_PART_MAIN);
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-bar-set-range HANDLE LO HI) -> #t/#f. */
static Sexpr_t mop3_lv_bar_set_range(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_bar_set_range()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *o = ll_lv_arg_obj(lamb, sexpr);
    if (o && lamb.cdr(sexpr) != NIL && lamb.cddr(sexpr) != NIL) {
      lv_bar_set_range(o, (int32_t) lamb.cadr(sexpr)->mustbe_int32(),
                          (int32_t) lamb.caddr(sexpr)->mustbe_int32());
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-bar-set-value HANDLE N) -> #t/#f.  No animation: a HUD reports, it does not perform. */
static Sexpr_t mop3_lv_bar_set_value(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_bar_set_value()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *o = ll_lv_arg_obj(lamb, sexpr);
    if (o && lamb.cdr(sexpr) != NIL) {
      lv_bar_set_value(o, (int32_t) lamb.cadr(sexpr)->mustbe_int32(), LV_ANIM_OFF);
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lv-obj-invalidate HANDLE) -> #t/#f.  Mark dirty so the next tick repaints it. */
static Sexpr_t mop3_lv_obj_invalidate(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lv_obj_invalidate()");
  ll_try {
    Sexpr_t res = HASHF;
    lv_obj_t *o = ll_lv_arg_obj(lamb, sexpr);
    if (o) { lv_obj_invalidate(o); res = HASHT; }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-rssi! STRING) -> #t/#f.  Write the link-strength readout only.  Returns #f if
    `lvgl-smoke` has not built it, rather than reporting a write that did not happen. */
static Sexpr_t mop3_lvgl_rssi(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_rssi()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = HASHF;
    if (ll_lv_rssi && sexpr != NIL) {
      lv_label_set_text(ll_lv_rssi, lamb.car(sexpr)->mustbe_any_str_t()->any_str_get_chars());
      lv_obj_invalidate(ll_lv_rssi);
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

static Sexpr_t mop3_lvgl_telemetry(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_telemetry()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = HASHF;
    if (ll_lv_bot && sexpr != NIL) {
      lv_label_set_text(ll_lv_bot, lamb.car(sexpr)->mustbe_any_str_t()->any_str_get_chars());
      lv_obj_invalidate(ll_lv_bot);
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/* ------------------------------------------------------------------------
   P123 Part G step 2 -- THE CAMERA RECTANGLE, AS AN LVGL OBJECT.

   G1 said the HUD's real requirement is "a way to write a rectangle of pixels
   into the framebuffer that LVGL also owns".  The obvious reading of that is
   wrong, and the panel layer already offers the wrong thing: `lcd-rgb565!`
   writes straight into fb() via ll_panel_blit_rgb565, which is correct when
   nothing else owns the buffer -- and this display is in
   LV_DISPLAY_RENDER_MODE_DIRECT, so LVGL owns it.  Pixels written behind
   LVGL's back survive exactly until the next redraw of that area, and then
   vanish with no error.  A camera frame that appears and then disappears
   whenever a label updates is a miserable thing to debug.

   So the frame is an `lv_image` over a buffer WE own.  LVGL composites it like
   any other object: it knows the area is occupied, redraws around it, and never
   paints over it.  Updating a frame is a memcpy into that buffer plus an
   invalidate -- no full-screen redraw, which is what keeps a 15 fps camera from
   costing 15 full renders a second.

   THE BUFFER IS NOT THE FRAMEBUFFER AND THAT COSTS 115,200 B OF PSRAM at
   240x240.  That is the price of letting LVGL composite, and it is worth it:
   the alternative is re-blitting the camera rectangle after every LVGL redraw,
   i.e. doing the copy anyway plus tracking when to do it. */
static uint8_t       *ll_lv_frame_buf = 0;
static lv_image_dsc_t ll_lv_frame_dsc;
static lv_obj_t      *ll_lv_frame_obj = 0;
static int            ll_lv_frame_w = 0, ll_lv_frame_h = 0;

/*! Camera-surface rotation in degrees CLOCKWISE (0/90/180/270), applied by `ll_jd_out` as it
    writes.  Set with `(lvgl-frame-rotate! DEG)`.  This is INDEPENDENT of `(lcd-init DEG)`, which
    turns the whole panel and only supports 0 and 180 -- the two exist because the panel's
    orientation is chosen by the radio and the mounting, while the image's orientation is chosen by
    where the camera happens to be pointing. */
static int ll_lv_frame_rot = 0;


/*! (lvgl-frame-create W H) -> #t/#f.  Centres a W x H RGB565 image on the screen. */
static Sexpr_t mop3_lvgl_frame_create(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_create()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = HASHF;
    if (!ll_lv_ready) { lamb.log("lvgl-frame-create: (lvgl-init) has not run\n"); return HASHF; }

    const int w = lamb.car(sexpr)->mustbe_int32();
    const int h = lamb.cadr(sexpr)->mustbe_int32();
    if (w <= 0 || h <= 0) { lamb.log("lvgl-frame-create: bad geometry\n"); return HASHF; }

    if (ll_lv_frame_obj) { lv_obj_del(ll_lv_frame_obj); ll_lv_frame_obj = 0; }
    if (ll_lv_frame_buf) { heap_caps_free(ll_lv_frame_buf); ll_lv_frame_buf = 0; }

    const size_t bytes = (size_t) w * (size_t) h * 2u;
    /*! 64-BYTE ALIGNED, BECAUSE `LV_DRAW_BUF_ALIGN` IS 64 AND PLAIN malloc IS NOT.
        This file ALREADY aligns the display's own draw buffers that way (see the
        `heap_caps_aligned_alloc(LV_DRAW_BUF_ALIGN, ...)` above), and lv_conf.h sets the value
        explicitly for the "ESP32-S3 PSRAM cache line" -- but the IMAGE SOURCE buffer was left on
        plain `heap_caps_malloc`, which gives 4-8 byte alignment.  So the one buffer LVGL reads
        pixels OUT of was the one not meeting the alignment it is told to expect.
        THE SYMPTOM THAT POINTED HERE: a vertical bar down one edge of the displayed image while
        `(lvgl-frame-pixel)` reads the BUFFER as correct at those exact coordinates -- so the defect
        is between the buffer and the glass, and this was the assumption we were not meeting.
        `bytes` is w*h*2 = 115,200 for 240x240, an exact multiple of 64, which
        `heap_caps_aligned_alloc` requires. */
    ll_lv_frame_buf = (uint8_t *) heap_caps_aligned_alloc(64, bytes, MALLOC_CAP_SPIRAM);
    if (!ll_lv_frame_buf) {
            lamb.log("lvgl-frame-create: PSRAM alloc of %s B failed\n", ascii.dec((LL_int32) bytes));
      res = HASHF;
    }
    else {
      memset(ll_lv_frame_buf, 0, bytes);
      memset(&ll_lv_frame_dsc, 0, sizeof(ll_lv_frame_dsc));
      ll_lv_frame_dsc.header.magic  = LV_IMAGE_HEADER_MAGIC;
      ll_lv_frame_dsc.header.cf     = LV_COLOR_FORMAT_RGB565;
      ll_lv_frame_dsc.header.w      = (uint32_t) w;
      ll_lv_frame_dsc.header.h      = (uint32_t) h;
      ll_lv_frame_dsc.header.stride = (uint32_t) (w * 2);
      ll_lv_frame_dsc.data_size     = (uint32_t) bytes;
      ll_lv_frame_dsc.data          = ll_lv_frame_buf;

      ll_lv_frame_obj = lv_image_create(lv_screen_active());
      lv_image_set_src(ll_lv_frame_obj, &ll_lv_frame_dsc);
      lv_obj_align(ll_lv_frame_obj, LV_ALIGN_CENTER, 0, 0);
      ll_lv_frame_w = w; ll_lv_frame_h = h;
            lamb.log("lvgl-frame: %sx%s RGB565 in PSRAM, composited by LVGL\n",
               ascii.dec((LL_int32) w), ascii.dec((LL_int32) h));
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-frame-testpat) -> #t.  Fill the frame with a gradient.  Step 2 is "static
    image first: no wire, no camera, no timing" -- this is that, generated rather than
    loaded so it needs no filesystem either. */
static Sexpr_t mop3_lvgl_frame_testpat(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_testpat()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = HASHF;
    if (!ll_lv_frame_buf) { lamb.log("lvgl-frame-testpat: no frame\n"); return HASHF; }
    uint16_t *px = (uint16_t *) ll_lv_frame_buf;
    for (int y = 0; y < ll_lv_frame_h; y++) {
      for (int x = 0; x < ll_lv_frame_w; x++) {
        const uint16_t r = (uint16_t) ((x * 31) / (ll_lv_frame_w - 1));
        const uint16_t g = (uint16_t) ((y * 63) / (ll_lv_frame_h - 1));
        const uint16_t b = (uint16_t) (31 - ((x * 31) / (ll_lv_frame_w - 1)));
        px[y * ll_lv_frame_w + x] = (uint16_t) ((r << 11) | (g << 5) | b);
      }
    }
    lv_obj_invalidate(ll_lv_frame_obj);        //!< only this area redraws, not the screen
    res = HASHT;
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-frame-fill! RGB565) -> #t/#f.  Fill the camera surface with ONE colour.
    Companion to `lvgl-frame-testpat`: the gradient answers "does the path carry varying data",
    this answers "does the panel carry a SINGLE value cleanly".

    WHY A UNIFORM FIELD IS THE RIGHT INSTRUMENT FOR A SUSPECTED DISPLAY FAULT.  A gradient cannot
    distinguish a per-channel or per-lane defect from the picture: every column already differs from
    its neighbour, so a column that comes out wrong has a plausible innocent explanation.  Fill the
    surface with one value and every pixel is its own control -- ANY structure visible on the glass
    is introduced after the framebuffer, because there is no structure in the data to misrender.
    Choose the two colours so the suspect channel is the only difference: a fault in one channel
    shows on a fill that USES that channel and disappears on one that does not.

    THIS PANEL WIRES AN RGB666 DISPLAY TO 16 DATA LINES WITH DB0 AND DB12 UNCONNECTED, so red and
    blue quantise in steps of 8 while green keeps all six bits -- green is the only channel with live
    wiring on every bit.  A green fill against a magenta one (magenta being green's absence) is
    therefore the two-arm test for the green path specifically.

    ALWAYS READ THE BUFFER BACK, with `lvgl-frame-pixel` or `lvgl-fb-pixel`, before believing what
    the glass shows.  A fill that did not happen and a fill the panel renders wrong look identical
    from the front, and that ambiguity is what makes an artefact get re-diagnosed repeatedly. */
/*! (lvgl-frame-rotate! DEG) -> DEG or #f.  Rotate the camera surface, degrees CLOCKWISE.
    0, 90, 180 and 270 only; anything else is REFUSED rather than rounded, because a rotation that
    silently did nothing is indistinguishable from a camera that is mounted the way you expected.
    Takes effect on the NEXT frame decoded -- it changes where the decoder writes, not what is
    already on the surface. */
static Sexpr_t mop3_lvgl_frame_rotate(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_rotate()");
  ll_try {
    Sexpr_t res = HASHF;
    if (sexpr == NIL) res = lamb.mk_integer((LL_int32) ll_lv_frame_rot, env_exec);
    else {
      const LL_int32 d = lamb.car(sexpr)->mustbe_int32();
      if (d == 0 || d == 90 || d == 180 || d == 270) {
        ll_lv_frame_rot = (int) d;
        res = lamb.mk_integer(d, env_exec);
      }
      else lamb.log("lvgl-frame-rotate!: %s is not 0/90/180/270 -- unchanged\n", ascii.dec(d));
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

static Sexpr_t mop3_lvgl_frame_fill(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_fill()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = HASHF;
    if (!ll_lv_frame_buf) { lamb.log("lvgl-frame-fill!: no frame\n"); return HASHF; }
    if (!lamb.car(sexpr)->is_any_int()) {
      lamb.log("lvgl-frame-fill!: wants one RGB565 integer 0..65535\n");
      return HASHF;                            //!< guard clause: no scaffolding acquired beyond the RAII lock
    }
    const LL_int32 v = lamb.car(sexpr)->mustbe_int32();
    if (v < 0 || v > 65535) {
      lamb.log("lvgl-frame-fill!: %s is not an RGB565 value\n", ascii.dec(v));
      return HASHF;
    }
    uint16_t *px = (uint16_t *) ll_lv_frame_buf;
    const uint16_t c = (uint16_t) v;
    const int n = ll_lv_frame_w * ll_lv_frame_h;
    for (int i = 0; i < n; i++) px[i] = c;
    lv_obj_invalidate(ll_lv_frame_obj);        //!< only this area redraws, not the screen
    res = HASHT;
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-frame-write! BVEC) -> #t/#f.  Copy one RGB565 frame in.  This is the call the
    camera path will make: Part D puts bytes on the wire, this puts them on the glass.
    REFUSES a short buffer rather than reading past it -- a truncated frame is a
    plausible thing to receive over a link, so it must not be a memory error. */
static Sexpr_t mop3_lvgl_frame_write(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_write()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = HASHF;
    if (!ll_lv_frame_buf) { lamb.log("lvgl-frame-write!: no frame\n"); return HASHF; }
    Sexpr_t   bv = lamb.car(sexpr);
    LL_int32  nbytes; ByteVec_t elems;
    bv->any_bvec_get_info(nbytes, elems);
    const LL_int32 want = (LL_int32) (ll_lv_frame_w * ll_lv_frame_h * 2);
    if (nbytes < want) {
            lamb.log("lvgl-frame-write!: short frame, %s of %s bytes -- dropped\n",
               ascii.dec(nbytes), ascii.dec(want));
      res = HASHF;
    }
    else {
      memcpy(ll_lv_frame_buf, elems, (size_t) want);
      lv_obj_invalidate(ll_lv_frame_obj);
      res = HASHT;
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/* ------------------------------------------------------------------------
   P123 Part G step 3 -- JPEG STRAIGHT ONTO THE GLASS.

   Part D is already done at both ends: the 4WD captures JPEG (D1, proven on
   hardware) and LLIP carries it byte-exact (D2, "a 4,677-byte JPEG crossed
   byte-exact ... six runs, six deliveries").  So the panel end does NOT need a
   new wire or a new capture -- it needs a decoder, and LVGL ships one.

   WHY JPEG RATHER THAN THE RGB565 PATH ABOVE, and it is a wire decision not a
   picture-quality one.  G4 priced 240x240 RGB565 at 115,200 B PER FRAME, so
   10 fps is 1.15 MB/s against a practical ESP32 TCP ceiling of 1-2 MB/s SHARED
   WITH TELEMETRY.  The 4WD's JPEGs are a few KB: ~5 KB at 10 fps is ~50 KB/s,
   twenty times under budget.  E4 guessed the cheaper first cut was RGB565 at
   panel scale precisely because it assumed decoding was "unpriced work on the
   watch" -- it is not unpriced here, it is LV_USE_TJPGD, a config flag over a
   decoder LVGL already vendors.

   BOTH PATHS ARE KEPT.  `lvgl-frame-write!` (RGB565) stays because it is the
   one that cannot fail on a frame the decoder rejects, and because a camera
   that can emit RGB565 directly skips a decode on an MCU that has other work.
   Which one the HUD uses is a measurement, not a preference, and the
   measurement needs the real link.

   THE CACHE DROP IS LOAD-BEARING.  LVGL caches decoded images KEYED ON THE
   SOURCE POINTER.  Feeding successive frames through one `lv_image_dsc_t`
   without dropping it shows FRAME ONE FOREVER: every later frame is a cache
   hit on a pointer that has not changed.  The picture is correct, static, and
   gives no error -- the worst kind of wrong, and exactly what a camera feed
   that "works but never updates" would look like. */
static uint8_t       *ll_lv_jpg_buf = 0;
static size_t         ll_lv_jpg_cap = 0;
static lv_image_dsc_t ll_lv_jpg_dsc;
static int            ll_lv_jpg_w = 0, ll_lv_jpg_h = 0;
static size_t         ll_lv_jpg_cap_used = 0;

static const uint8_t ll_lv_test_jpg[] = {
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x06, 0x04, 0x05, 0x06, 0x05, 0x04, 0x06,
  0x06, 0x05, 0x06, 0x07, 0x07, 0x06, 0x08, 0x0A, 0x10, 0x0A, 0x0A, 0x09, 0x09, 0x0A, 0x14, 0x0E,
  0x0F, 0x0C, 0x10, 0x17, 0x14, 0x18, 0x18, 0x17, 0x14, 0x16, 0x16, 0x1A, 0x1D, 0x25, 0x1F, 0x1A,
  0x1B, 0x23, 0x1C, 0x16, 0x16, 0x20, 0x2C, 0x20, 0x23, 0x26, 0x27, 0x29, 0x2A, 0x29, 0x19, 0x1F,
  0x2D, 0x30, 0x2D, 0x28, 0x30, 0x25, 0x28, 0x29, 0x28, 0xFF, 0xDB, 0x00, 0x43, 0x01, 0x07, 0x07,
  0x07, 0x0A, 0x08, 0x0A, 0x13, 0x0A, 0x0A, 0x13, 0x28, 0x1A, 0x16, 0x1A, 0x28, 0x28, 0x28, 0x28,
  0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28,
  0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28,
  0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0xFF, 0xC0,
  0x00, 0x11, 0x08, 0x00, 0xF0, 0x00, 0xF0, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11,
  0x01, 0xFF, 0xC4, 0x00, 0x16, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0xFF, 0xC4, 0x00, 0x15, 0x10, 0x01, 0x01,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11,
  0xFF, 0xC4, 0x00, 0x16, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x07, 0xFF, 0xC4, 0x00, 0x16, 0x11, 0x01, 0x01, 0x01,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x13,
  0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00, 0xD6, 0x95,
  0x14, 0xAC, 0xC3, 0x36, 0xBF, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B,
  0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5,
  0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45,
  0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29,
  0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x68, 0xA5, 0x45, 0x2A, 0xEC,
  0xD2, 0xDA, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66,
  0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A,
  0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9,
  0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51,
  0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0x29, 0x51, 0x4A, 0xBB, 0x34, 0x96, 0xBA, 0x54,
  0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52,
  0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99,
  0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96,
  0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA,
  0x54, 0x52, 0x99, 0x96, 0x8A, 0x54, 0x0B, 0xB3, 0x4B, 0x6B, 0xA5, 0x40, 0x66, 0x5A, 0xE9, 0x50,
  0x19, 0x96, 0xBA, 0x54, 0x06, 0x65, 0xAE, 0x95, 0x01, 0x99, 0x6B, 0xA5, 0x40, 0x66, 0x5A, 0xE9,
  0x50, 0x19, 0x96, 0xBA, 0x54, 0x06, 0x65, 0xAE, 0x95, 0x01, 0x99, 0x6B, 0xA5, 0x40, 0x66, 0x5A,
  0xE9, 0x50, 0x19, 0x96, 0xBA, 0x54, 0x06, 0x65, 0xAE, 0x95, 0x01, 0x99, 0x6B, 0xA5, 0x40, 0x66,
  0x5A, 0xE9, 0x50, 0x19, 0x96, 0x8A, 0x54, 0x0B, 0x73, 0x4B, 0x6B, 0xA5, 0x40, 0x66, 0x5A, 0xE9,
  0x50, 0x19, 0x96, 0xBA, 0x54, 0x06, 0x65, 0xAE, 0x95, 0x01, 0x99, 0x6B, 0xA5, 0x40, 0x66, 0x5A,
  0xE9, 0x50, 0x19, 0x96, 0xBA, 0x54, 0x06, 0x65, 0xAE, 0x95, 0x01, 0x99, 0x6B, 0xA5, 0x40, 0x66,
  0x5A, 0xE9, 0x50, 0x19, 0x96, 0xBA, 0x54, 0x06, 0x65, 0xAE, 0x95, 0x01, 0x99, 0x6B, 0xA5, 0x40,
  0x66, 0x5A, 0xE9, 0x50, 0x19, 0x96, 0x8A, 0x54, 0x52, 0xAE, 0xCD, 0x25, 0xAE, 0x95, 0x14, 0xA6,
  0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65,
  0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE,
  0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95,
  0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14,
  0xA6, 0x65, 0xA2, 0x95, 0x14, 0xAB, 0xB3, 0x4B, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45,
  0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29,
  0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99,
  0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B,
  0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x68, 0xA5,
  0x4D, 0x2A, 0xEC, 0xD2, 0xDA, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9,
  0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53,
  0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A,
  0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66,
  0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0xA9, 0x53, 0x4A, 0x66, 0x5A, 0x29, 0x51, 0x4A, 0xBB, 0x34,
  0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96,
  0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA,
  0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54,
  0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52,
  0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0x8A, 0x54, 0x52, 0xAE, 0xCD, 0x2D, 0xAE, 0x95, 0x14,
  0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6,
  0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65,
  0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE,
  0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95,
  0x14, 0xA6, 0x65, 0xA2, 0x95, 0x14, 0xAB, 0x73, 0x4B, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5,
  0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45,
  0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29,
  0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99,
  0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x68,
  0xA5, 0x45, 0x2A, 0xFC, 0xD2, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A,
  0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9,
  0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51,
  0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A,
  0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0xE9, 0x51, 0x4A, 0x66, 0x5A, 0x29, 0x51, 0x4A, 0xB7,
  0x34, 0xB6, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99,
  0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96,
  0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA,
  0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0xBA, 0x54,
  0x52, 0x99, 0x96, 0xBA, 0x54, 0x52, 0x99, 0x96, 0x8A, 0x54, 0x52, 0xAE, 0xCD, 0x2D, 0xAE, 0x95,
  0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14,
  0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6,
  0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65,
  0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE, 0x95, 0x14, 0xA6, 0x65, 0xAE,
  0x95, 0x14, 0xA6, 0x65, 0xA2, 0x95, 0x14, 0xAB, 0xB3, 0x49, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B,
  0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5,
  0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45,
  0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29,
  0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99, 0x6B, 0xA5, 0x45, 0x29, 0x99,
  0x6F, 0xFF, 0xD9,
};

/*! --- JPEG -> the frame's OWN RGB565 BUFFER, decoded by us -------------------------------------
    WHY WE DO NOT HAND THE JPEG TO LVGL.  `lv_image_set_src` with an encoded (LV_COLOR_FORMAT_RAW)
    descriptor puts the image in the hands of LVGL's decoder chain, and on this board that chain
    ACCEPTS the bytes and renders nothing.  Bisected on esp32s3-aitrip-480x480 2026-09-26, by eye,
    because every software check reported success throughout:
      * an RGB565 gradient written straight into this frame buffer DISPLAYS -- so the image widget,
        its geometry, the colour format and the RGB scan-out are all sound;
      * pointing the SAME widget at a JPEG blanks it, every time, including the 1,411-byte one
        compiled into the firmware.
    So the fault is confined to decode-to-render, and the buffer path is known good.  Therefore:
    decode into that buffer and leave the widget pointing at it permanently.

    AND THIS IS WHY IT WENT UNNOTICED FOR SO LONG.  `lv_image_decoder_get_info` was used as the
    proof of a successful decode.  For a memory source it is nearly vacuous: it runs `is_jpg()` --
    a three-byte FF D8 FF test -- and then copies back the width and height THE CALLER SUPPLIED.
    It never decodes.  So it answered OK for every frame while the glass stayed blank, and a
    "verified" render was really a verified magic number.  `lv_tjpgd`'s `decoder_open` then fills
    in w/h, sets RGB888, and returns OK WITHOUT decoding either -- it is a streaming `get_area`
    decoder and expects LVGL to pull regions later, which is the step that never produced pixels
    here. Raising `LV_CACHE_DEF_SIZE` from 0 was tried on the theory that those regions had nowhere
    to live; it did not help and was reverted.
    THE ONLY TRUSTWORTHY CHECK ON THIS PATH IS A HUMAN LOOKING AT THE PANEL, or a pixel read back
    out of this buffer.  Do not reintroduce a decoder-info check and call it verification. */
struct ll_jpg_feed { const uint8_t *p; size_t len; size_t off; };

//! tjpgd input: hand over bytes from memory.  `buf == NULL` means SKIP, not read.
static size_t ll_jd_in(JDEC *jd, uint8_t *buf, size_t n)
{
  ll_jpg_feed *f = (ll_jpg_feed *) jd->device;
  const size_t left = f->len - f->off;
  if (n > left) n = left;
  if (buf && n) memcpy(buf, f->p + f->off, n);
  f->off += n;
  return n;
}

/*! tjpgd output: an RGB888 rectangle (JD_FORMAT 0), converted to RGB565 into the frame buffer.
    The packing is the one `mop3_lvgl_frame_testpat` uses, which is the packing PROVEN to display
    on this panel -- matched deliberately rather than derived, so the two paths cannot disagree.
    Advances `src` for every pixel even when clipped, or the rectangle would shear. */

static int ll_jd_out(JDEC *jd, void *bitmap, JRECT *rect)
{
  LV_UNUSED(jd);
  /*! TJPGD EMITS **BGR**, NOT RGB, AND ITS OWN COMMENT SAYS OTHERWISE.  `JD_FORMAT 0` is documented
      as "RGB output" and `jd_decomp`'s prototype comment repeats it, but the packing loop in
      tjpgd.c writes B, then G, then R (lines 885-887 of the vendored copy).  Taking the comment at
      its word swaps red and blue on every pixel.

      AND THAT MISLED ME INTO A SECOND, WRONG FIX -- worth the space because the two faults are
      indistinguishable on the obvious test image.  The built-in test JPEG is a vertical gradient
      from orange/red at the top to blue at the bottom.  Swap red and blue in it and you get blue at
      the top and red at the bottom, which is EXACTLY what a vertical flip of the correct image
      looks like.  Reported from the bench as "blue top red bottom", that was first taken for an
      inverted row order; inverting the rows then produced a correct-looking orientation for the
      wrong reason, and would have left every real camera frame mirrored top-to-bottom.
      What settles it is reading the BUFFER rather than the glass: `(lvgl-frame-pixel 120 4)`
      returned 64000 = (r31,g16,b0), and 64000 is precisely a BGR-misread of the host-decoded pixel
      at the OTHER end of the gradient -- so both the swap and the bogus flip were visible in one
      number.  The host comparison is the instrument; the eye cannot separate these two. */
  /*! ROTATION IS APPLIED HERE, AT THE DESTINATION INDEX, AND NOT BY THE PANEL.
      The ST7701's MADCTL offers 0 and 180 only -- 90 and 270 need its MV bit, and neither the
      framebuffer stride nor LVGL's width/height follow that, so the panel would show a scrambled
      image from a call that reported success.  Rotating the CAMERA SURFACE instead costs nothing:
      the decoder is already writing pixel by pixel, so turning the write index is free, and the
      surface is square, so no geometry changes.
      `ll_lv_frame_rot` is degrees CLOCKWISE as the viewer sees it: 90 sends the image's top edge to
      the viewer's right. */
  const uint8_t *src = (const uint8_t *) bitmap;
  const int W = ll_lv_frame_w, H = ll_lv_frame_h;
  for (int y = rect->top; y <= rect->bottom; y++) {
    for (int x = rect->left; x <= rect->right; x++) {
      const uint8_t b = src[0], g = src[1], r = src[2];   //!< BGR, per tjpgd.c:885-887
      src += 3;
      if (y < 0 || y >= H || x < 0 || x >= W) continue;   //!< clipped, but src already advanced
      int dx = x, dy = y;
      switch (ll_lv_frame_rot) {
        case  90: dx = (H - 1) - y; dy = x;             break;
        case 180: dx = (W - 1) - x; dy = (H - 1) - y;   break;
        case 270: dx = y;           dy = (W - 1) - x;   break;
        default:  break;                                 //!< 0
      }
      if (dx < 0 || dx >= W || dy < 0 || dy >= H) continue;
      //! The packing `mop3_lvgl_frame_testpat` uses, which is the one proven to display here.
      ((uint16_t *) ll_lv_frame_buf)[(size_t) dy * (size_t) W + (size_t) dx] =
        (uint16_t) (((uint16_t) (r >> 3) << 11)
                  | ((uint16_t) (g >> 2) <<  5)
                  |  (uint16_t) (b >> 3));
    }
  }
  return 1;                                    //!< non-zero = continue
}

//! Hand `nbytes` of JPEG to the frame object.  Shared by the test pattern and the wire.
static bool ll_lv_show_jpeg(Lamb &lamb, const uint8_t *src, size_t nbytes)
{
  bool ok = true;
  if (!ll_lv_frame_obj || !ll_lv_frame_buf) {
    lamb.log("jpeg: no frame -- (lvgl-frame-create W H) first\n");
    ok = false;
  }
  //! The workspace is tjpgd's own recommendation (lv_tjpgd uses the same 4096).  Internal DRAM is
  //! not required, and this runs once per frame, so it is allocated and freed per call rather than
  //! held -- a permanent 4 KB in a board this tight is not worth saving 20 us.
  uint8_t *work = 0;
  if (ok) {
    work = (uint8_t *) heap_caps_malloc(4096, MALLOC_CAP_SPIRAM);
    if (!work) { lamb.log("jpeg: workspace alloc failed\n"); ok = false; }
  }
  if (ok) {
    ll_jpg_feed feed = { src, nbytes, 0 };
    JDEC        jd;
    JRESULT     rc = jd_prepare(&jd, ll_jd_in, work, 4096, &feed);
    if (rc != JDR_OK) {
      lamb.log("jpeg: jd_prepare rejected %s bytes (rc=%s)\n",
               ascii.dec((LL_int32) nbytes), AsciiConverter().dec((LL_int32) rc));
      ok = false;
    }
    else {
      /*! SIZE MISMATCH IS A WARNING, NOT A REFUSAL.  The decoder writes what fits and clips the
          rest, so a frame that is not exactly the widget's size still shows -- which is far more
          useful than a blank panel while someone reconciles two numbers. */
      if ((int) jd.width != ll_lv_frame_w || (int) jd.height != ll_lv_frame_h)
        lamb.log("jpeg: image is %sx%s, frame is %sx%s -- clipped\n",
                 ascii.dec((LL_int32) jd.width),  AsciiConverter().dec((LL_int32) jd.height),
                 AsciiConverter().dec((LL_int32) ll_lv_frame_w),
                 AsciiConverter().dec((LL_int32) ll_lv_frame_h));
      rc = jd_decomp(&jd, ll_jd_out, 0);
      if (rc != JDR_OK) {
        lamb.log("jpeg: jd_decomp failed (rc=%s)\n", ascii.dec((LL_int32) rc));
        ok = false;
      }
      else {
        ll_lv_jpg_w = (int) jd.width; ll_lv_jpg_h = (int) jd.height;
        ll_lv_jpg_cap_used = nbytes;
        /*! KEEP THE WIDGET ON THE RGB565 DESCRIPTOR.  It already points there from
            `lvgl-frame-create`; re-setting it costs nothing and makes this function correct even
            if something else pointed the widget at an encoded source in between. */
        lv_image_set_src(ll_lv_frame_obj, &ll_lv_frame_dsc);
        lv_obj_invalidate(ll_lv_frame_obj);
      }
    }
  }
  if (work) heap_caps_free(work);
  return ok;                                   //!< SINGLE EXIT
}

/*! (lvgl-frame-pixel X Y) -> the RGB565 value in the frame buffer at X,Y, or #f.
    EXISTS BECAUSE "IS THE PICTURE RIGHT?" HAD NO ANSWER EXCEPT A HUMAN SQUINTING AT THE GLASS.
    Every software check on this path was vacuous -- `lv_image_decoder_get_info` tests three bytes
    and echoes back the caller's own dimensions -- so a blank panel and a correct one produced
    identical output for weeks, and the only instrument that ever disagreed was a human looking at
    the panel.
    This reads the actual pixel, which makes the question mechanical: decode the same image on the
    host, compare a handful of coordinates, and a wrong orientation, a wrong colour order or a
    corrupted column shows up as numbers instead of as an adjective.
    Reads the BUFFER, not the panel, so it proves what was decoded and not what was scanned out --
    those are different claims and this one is the narrower. */
static Sexpr_t mop3_lvgl_frame_pixel(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_pixel()");
  ll_try {
    Sexpr_t res = HASHF;
    const LL_int32 x = lamb.car(sexpr)->mustbe_int32();
    const LL_int32 y = lamb.car(lamb.cdr(sexpr))->mustbe_int32();
    if (ll_lv_frame_buf && x >= 0 && y >= 0 && x < ll_lv_frame_w && y < ll_lv_frame_h) {
      const uint16_t px = ((const uint16_t *) ll_lv_frame_buf)[(size_t) y * (size_t) ll_lv_frame_w
                                                               + (size_t) x];
      res = lamb.mk_integer((LL_int32) px, env_exec);
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-fb-pixel X Y) -> the RGB565 value in the SCANNED FRAMEBUFFER at screen X,Y, or #f.
    THE COMPANION TO `lvgl-frame-pixel`, AND THE ONE THAT SPLITS THE REMAINING QUESTION IN TWO.
    That one reads the image SOURCE buffer and has read correct at every coordinate sampled, including
    the exact ones where an artefact is visible -- which proves the data is right and says nothing
    about what reaches the glass.  This reads the other end: the framebuffer the RGB peripheral
    scans, after LVGL has composited into it.
      source correct + framebuffer WRONG  -> the compositing or the flush copy put it there
      source correct + framebuffer RIGHT  -> nothing in software did; it is the scan or the wiring
    Without this the two are indistinguishable by any check we own, and the only instrument left is a
    person describing a colour -- which is how an artefact here survived several confident fixes. */
static Sexpr_t mop3_lvgl_fb_pixel(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_fb_pixel()");
  ll_try {
    Sexpr_t res = HASHF;
    const LL_int32  x = lamb.car(sexpr)->mustbe_int32();
    const LL_int32  y = lamb.car(lamb.cdr(sexpr))->mustbe_int32();
    const LL_Panel *p = ll_panel_active();
    const uint16_t *fb = (p && p->fb) ? p->fb() : 0;
    if (fb && x >= 0 && y >= 0 && x < p->w && y < p->h)
      res = lamb.mk_integer((LL_int32) fb[(size_t) y * (size_t) p->w + (size_t) x], env_exec);
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-fb-pixel-dma X Y) -> RGB565 or #f.  Read the framebuffer pixel THE DISPLAY CONTROLLER
    WOULD FETCH, by invalidating the containing cache line first.

    WHY THIS EXISTS, AND WHY `lvgl-fb-pixel` ALONE CAN MISLEAD.  `lvgl-fb-pixel` is an ordinary CPU
    read, so it is served from the data cache -- the same cache the CPU wrote through.  The RGB DMA
    does NOT go through that cache; it fetches from PSRAM.  So the two can disagree, and when they
    do, a CPU read reports the framebuffer as perfect while the panel scans out something else.

    THE TRAP IS THAT THE CPU READ LOOKS LIKE GROUND TRUTH.  Reading the source buffer and the
    framebuffer and finding both pixel-exact FEELS like proof that the data is correct all the way
    down, and it licenses the conclusion "the fault is downstream of everything we own, therefore not
    ours".  That inference has an unchecked antecedent: both readers share a cache with the writer,
    so neither can see what the DMA sees.  Pair the two readers and the antecedent becomes testable
    -- a DISAGREEMENT localises the fault to write-back, an AGREEMENT genuinely does put it past us.

    HAZARD, stated because this is a diagnostic and not a general-purpose accessor: an invalidate
    DISCARDS any dirty bytes in that cache line rather than writing them back, so calling this while
    a render is in flight can drop up to one line's worth of just-drawn pixels. It is 64 bytes and the
    next repaint restores them, which is an acceptable price for a measurement and NOT acceptable
    inside a render path. */
static Sexpr_t mop3_lvgl_fb_pixel_dma(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_fb_pixel_dma()");
  ll_try {
    Sexpr_t res = HASHF;
    const LL_int32  x = lamb.car(sexpr)->mustbe_int32();
    const LL_int32  y = lamb.car(lamb.cdr(sexpr))->mustbe_int32();
    const LL_Panel *p = ll_panel_active();
    const uint16_t *fb = (p && p->fb) ? p->fb() : 0;
    if (fb && x >= 0 && y >= 0 && x < p->w && y < p->h) {
      const uint16_t *addr = fb + (size_t) y * (size_t) p->w + (size_t) x;
      /*! REPORT THE INVALIDATE'S STATUS, DO NOT ASSUME IT HAPPENED.  If esp_cache_msync refuses the
          call -- wrong alignment, a region it does not consider cacheable, a flag combination it
          rejects -- the read below simply returns the CACHED value, and this mop becomes an
          expensive alias for the plain reader.  It would then AGREE with it unconditionally, and an
          agreement from an instrument that cannot disagree is indistinguishable from a real result.
          So the caller gets (PIXEL RC): rc 0 means the line really was invalidated and the pixel is
          what memory holds; any other rc means the comparison is void, not that the buffers match. */
      /*! ALIGN TO THE CACHE LINE -- AN UNALIGNED INVALIDATE IS REFUSED, NOT SILENTLY WIDENED.
          `ESP_CACHE_MSYNC_FLAG_UNALIGNED` is tolerated for a WRITE-BACK but rejected for an
          INVALIDATE (M2C) with ESP_ERR_INVALID_ARG (258), because dropping a partial line would
          discard a neighbour's dirty bytes that were never written back.  Measured here: every call
          with that flag returned 258 and the read fell through to the CACHED value, so the mop
          agreed with the plain reader unconditionally and looked like a clean negative result.
          So round the address DOWN to a 64-byte boundary and invalidate a whole line.  64 is used
          rather than a queried line size because it is the larger of the two the S3 data cache
          uses, and over-aligning an invalidate is safe where under-aligning is refused. */
      const uintptr_t line = (uintptr_t) addr & ~(uintptr_t) 63;
      const esp_err_t rc = esp_cache_msync((void *) line, 64, ESP_CACHE_MSYNC_FLAG_DIR_M2C);
      Sexpr_t px = lamb.mk_integer((LL_int32) *addr, env_exec);
      lamb.gc_root_push(px);
      Sexpr_t rcv = lamb.mk_integer((LL_int32) rc, env_exec);
      lamb.gc_root_pop();
      res = lamb.cons(px, lamb.cons(rcv, NIL, env_exec), env_exec);
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-frame-info) -> (w h bytes) of the last image the DECODER accepted, or #f.
    Exists because "what did the camera actually send?" is the first question when a frame does
    not appear, and guessing it from the sender's configuration is how you chase the wrong end. */
static Sexpr_t mop3_lvgl_frame_info(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_info()");
  ll_try {
    Sexpr_t res = HASHF;
    if (ll_lv_jpg_w > 0) {
      Sexpr_t n = lamb.mk_integer((LL_int32) ll_lv_jpg_cap_used, env_exec);
      lamb.gc_root_push(n);
      Sexpr_t h = lamb.mk_integer((LL_int32) ll_lv_jpg_h, env_exec);
      lamb.gc_root_push(h);
      Sexpr_t w = lamb.mk_integer((LL_int32) ll_lv_jpg_w, env_exec);
      lamb.gc_root_push(w);
      res = lamb.cons(w, lamb.cons(h, lamb.cons(n, NIL, env_exec), env_exec), env_exec);
      lamb.gc_root_pop(3);
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-frame-jpeg! BVEC) -> #t/#f.  THE call the camera path makes. */
static Sexpr_t mop3_lvgl_frame_jpeg(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_jpeg()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t   bv = lamb.car(sexpr);
    LL_int32  nbytes; ByteVec_t elems;
    bv->any_bvec_get_info(nbytes, elems);
    Sexpr_t res = HASHF;
    if (nbytes < 4) lamb.log("lvgl-frame-jpeg!: %d bytes is not an image -- dropped\n", (int) nbytes);
    else res = ll_lv_show_jpeg(lamb, (const uint8_t *) elems, (size_t) nbytes) ? HASHT : HASHF;
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

/*! (lvgl-frame-jpeg-testpat) -> #t.  Decode a real 1,411-byte JPEG built into the
    firmware, so the decoder is proved WITHOUT the 4WD, the link or the camera.
    Step 3 otherwise has three things that can fail and one symptom. */
static Sexpr_t mop3_lvgl_frame_jpeg_testpat(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_jpeg_testpat()");
  ll_try {
    LlLvGuard _lvg;                            //!< LVGL is not thread-safe; the render task holds this too
    Sexpr_t res = ll_lv_show_jpeg(lamb, ll_lv_test_jpg, sizeof(ll_lv_test_jpg)) ? HASHT : HASHF;
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

#endif  // LL_LVGL

/*! Installer.  Defined UNCONDITIONALLY so main.cpp's table needs no #if -- on a build
    without LVGL it binds nothing, which leaves `lvgl-*` UNBOUND rather than stubbed.
    An unbound symbol raises; a stub returns success and does nothing. */
Sexpr_t Lvgl_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Lvgl_install_mop3()");
  ll_try {
    Sexpr_t env_target = lamb.car(sexpr);
    (void) env_target;
#if LL_LVGL
    static const struct { Lamb::Mop3st_t func; const char *name; } lvgl_procs[] = {
      { mop3_lvgl_init,          "lvgl-init"          },
      { mop3_lvgl_tick,          "lvgl-tick!"         },
      { mop3_lvgl_smoke,         "lvgl-smoke"         },
      { mop3_lvgl_frame_create,  "lvgl-frame-create"  },
      { mop3_lvgl_frame_testpat, "lvgl-frame-testpat" },
      { mop3_lvgl_frame_fill,    "lvgl-frame-fill!"   },
      { mop3_lvgl_frame_rotate,  "lvgl-frame-rotate!" },
      { mop3_lvgl_frame_write,   "lvgl-frame-write!"  },
      { mop3_lvgl_frame_jpeg,    "lvgl-frame-jpeg!"   },
      { mop3_lvgl_frame_pixel,   "lvgl-frame-pixel"   },
      { mop3_lvgl_fb_pixel,      "lvgl-fb-pixel"      },
      { mop3_lvgl_fb_pixel_dma,  "lvgl-fb-pixel-dma"  },
      { mop3_lvgl_frame_jpeg_testpat, "lvgl-frame-jpeg-testpat" },
      { mop3_lvgl_status,        "lvgl-status!"       },
      { mop3_lvgl_telemetry,     "lvgl-telemetry!"    },
      { mop3_lvgl_rssi,          "lvgl-rssi!"         },
      { mop3_lv_screen_active,   "lv-screen-active"   },
      { mop3_lv_label_create,    "lv-label-create"    },
      { mop3_lv_bar_create,      "lv-bar-create"      },
      { mop3_lv_label_set_text,  "lv-label-set-text"  },
      { mop3_lv_obj_set_pos,     "lv-obj-set-pos"     },
      { mop3_lv_obj_set_size,    "lv-obj-set-size"    },
      { mop3_lv_set_text_color,  "lv-obj-set-style-text-color" },
      { mop3_lv_set_bg_color,    "lv-obj-set-style-bg-color"   },
      { mop3_lv_bar_set_range,   "lv-bar-set-range"   },
      { mop3_lv_bar_set_value,   "lv-bar-set-value"   },
      { mop3_lv_obj_invalidate,  "lv-obj-invalidate"  },
      { mop3_lvgl_frame_info,    "lvgl-frame-info"    }
    };
    const int n = (int) (sizeof(lvgl_procs) / sizeof(lvgl_procs[0]));
    lamb.log("%s defining %d Mops\n", me, n);
    for (int i = 0; i < n; i++) {
      Sexpr_t proc = lamb.mk_Mop3_procst_t(lvgl_procs[i].func, env_exec);
      lamb.gc_root_push(proc);
      Sexpr_t sym = lamb.mk_symbol(lvgl_procs[i].name, env_exec);
      lamb.gc_root_pop();
      lamb.dict_bind_bang(env_target, sym, proc, env_exec);
    }
#endif
    return NIL;
  }
  ll_catch();
}
