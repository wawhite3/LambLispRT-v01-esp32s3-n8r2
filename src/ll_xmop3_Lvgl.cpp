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
#ifndef LL_LVGL_DIRECT
  #define LL_LVGL_DIRECT 0
#endif

#if LL_LVGL

#include "lvgl.h"
#include "esp_timer.h"

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
        //! TELL LVGL THE PANEL'S BYTE ORDER ONCE, RATHER THAN SWAPPING AT EVERY WRITE SITE.
        //! This framebuffer is consumed as BIG-ENDIAN RGB565 (see ait_fill).  LVGL defaults to
        //! native RGB565, so without this its output lands byte-swapped -- reds read as blues and
        //! an amber bar renders brown.  Setting the format makes LVGL and the `lcd-*` procedures
        //! agree on one convention instead of each patching its own path.
        //! MEASURED, not reasoned: RGB565_SWAPPED renders a near-black background as PURPLE, in
        //! both DIRECT and PARTIAL, so LVGL's native order is what this framebuffer wants.  Note
        //! this DIFFERS from the scalar `lcd-box` path, which does need a swap (see ait_fill) --
        //! the two are not writing through the same code, and the hardware's answer for each was
        //! obtained by looking at the glass rather than by reasoning from the other.
        lv_display_set_color_format(ll_lv_disp, LV_COLOR_FORMAT_RGB565);
        lamb.log("lvgl-init: D after flush_cb + swapped cf\n");
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
          lamb.log("lvgl: NOT direct -- fb unaligned or push panel\n");
          //! PUSH: a partial buffer LVGL owns, flushed over the bus.  A tenth of the
          //! screen, which is the sizing P231 prices.
          const size_t part = (size_t) p->w * (size_t) (p->h / 10) * 2u;
          //! ALIGNMENT IS A HARD PRECONDITION, NOT A PREFERENCE.  `lv_display_set_buffers`
          //! asserts `buf1 == lv_draw_buf_align(buf1, cf)`, and `LV_ASSERT_HANDLER` is
          //! `while(1);` -- so a buffer that merely came back from `heap_caps_malloc` (4/8-byte
          //! aligned) makes the call SPIN FOREVER with no crash and no message.  Measured
          //! 2026-09-24: the board stopped inside that call and produced no output at all.
          void *b1 = heap_caps_aligned_alloc(LV_DRAW_BUF_ALIGN, part, MALLOC_CAP_SPIRAM);
          lamb.log("lvgl-init: G aligned buf=%p\n", b1);
          if (!b1) { lamb.log("lvgl-init: partial buffer alloc failed\n"); res = HASHF; }
          else {
            lamb.log("lvgl-init: H before set_buffers(partial)\n");
            lv_display_set_buffers(ll_lv_disp, b1, 0, part,
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
      lamb.log("lvgl-init: LVGL %s.%s.%s up on %s\n",
               "9", "3", "0", p ? p->name : "?");
    }
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

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

    const int64_t t0 = esp_timer_get_time();
    uint32_t      next = lv_timer_handler();
    //! `lv_timer_handler` returns ms until it next wants running.  Keep pumping only
    //! while it wants to run NOW and we are still inside the budget.
    while (next == 0 && (esp_timer_get_time() - t0) < (int64_t) budget * 1000) {
      next = lv_timer_handler();
    }
    res = (next != 0) ? HASHT : HASHF;
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

/*! (lvgl-frame-create W H) -> #t/#f.  Centres a W x H RGB565 image on the screen. */
static Sexpr_t mop3_lvgl_frame_create(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_create()");
  ll_try {
    Sexpr_t res = HASHF;
    if (!ll_lv_ready) { lamb.log("lvgl-frame-create: (lvgl-init) has not run\n"); return HASHF; }

    const int w = lamb.car(sexpr)->mustbe_int32();
    const int h = lamb.cadr(sexpr)->mustbe_int32();
    if (w <= 0 || h <= 0) { lamb.log("lvgl-frame-create: bad geometry\n"); return HASHF; }

    if (ll_lv_frame_obj) { lv_obj_del(ll_lv_frame_obj); ll_lv_frame_obj = 0; }
    if (ll_lv_frame_buf) { heap_caps_free(ll_lv_frame_buf); ll_lv_frame_buf = 0; }

    const size_t bytes = (size_t) w * (size_t) h * 2u;
    ll_lv_frame_buf = (uint8_t *) heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM);
    if (!ll_lv_frame_buf) {
      AsciiConverter a1;
      lamb.log("lvgl-frame-create: PSRAM alloc of %s B failed\n", a1.dec((LL_int32) bytes));
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
      AsciiConverter a1, a2;
      lamb.log("lvgl-frame: %sx%s RGB565 in PSRAM, composited by LVGL\n",
               a1.dec((LL_int32) w), a2.dec((LL_int32) h));
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

/*! (lvgl-frame-write! BVEC) -> #t/#f.  Copy one RGB565 frame in.  This is the call the
    camera path will make: Part D puts bytes on the wire, this puts them on the glass.
    REFUSES a short buffer rather than reading past it -- a truncated frame is a
    plausible thing to receive over a link, so it must not be a memory error. */
static Sexpr_t mop3_lvgl_frame_write(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lvgl_frame_write()");
  ll_try {
    Sexpr_t res = HASHF;
    if (!ll_lv_frame_buf) { lamb.log("lvgl-frame-write!: no frame\n"); return HASHF; }
    Sexpr_t   bv = lamb.car(sexpr);
    LL_int32  nbytes; ByteVec_t elems;
    bv->any_bvec_get_info(nbytes, elems);
    const LL_int32 want = (LL_int32) (ll_lv_frame_w * ll_lv_frame_h * 2);
    if (nbytes < want) {
      AsciiConverter a1, a2;
      lamb.log("lvgl-frame-write!: short frame, %s of %s bytes -- dropped\n",
               a1.dec(nbytes), a2.dec(want));
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

//! Hand `nbytes` of JPEG to the frame object.  Shared by the test pattern and the wire.
static bool ll_lv_show_jpeg(Lamb &lamb, const uint8_t *src, size_t nbytes)
{
  bool ok = true;
  if (!ll_lv_frame_obj) { lamb.log("jpeg: no frame -- (lvgl-frame-create W H) first\n"); ok = false; }
  if (ok && nbytes > ll_lv_jpg_cap) {
    if (ll_lv_jpg_buf) heap_caps_free(ll_lv_jpg_buf);
    ll_lv_jpg_buf = (uint8_t *) heap_caps_malloc(nbytes, MALLOC_CAP_SPIRAM);
    ll_lv_jpg_cap = ll_lv_jpg_buf ? nbytes : 0;
    if (!ll_lv_jpg_buf) { lamb.log("jpeg: PSRAM alloc failed\n"); ok = false; }
  }
  if (ok) {
    //! Drop BEFORE overwriting the bytes: the cache entry refers to this pointer.
    lv_image_cache_drop(&ll_lv_jpg_dsc);
    memcpy(ll_lv_jpg_buf, src, nbytes);
    memset(&ll_lv_jpg_dsc, 0, sizeof(ll_lv_jpg_dsc));
    ll_lv_jpg_dsc.header.magic = LV_IMAGE_HEADER_MAGIC;
    ll_lv_jpg_dsc.header.cf    = LV_COLOR_FORMAT_RAW;   //!< encoded; the decoder chain sniffs it
    ll_lv_jpg_dsc.data         = ll_lv_jpg_buf;
    ll_lv_jpg_dsc.data_size    = (uint32_t) nbytes;
    ll_lv_jpg_cap_used         = nbytes;
    lv_image_set_src(ll_lv_frame_obj, &ll_lv_jpg_dsc);
    lv_obj_invalidate(ll_lv_frame_obj);

    /*! VERIFY THE DECODE, DO NOT ASSUME IT.  `lv_image_set_src` accepts the pointer whether or
        not any decoder can read the bytes -- so without this, a JPEG the decoder REJECTS is
        indistinguishable from one it renders, and the caller counts twelve good frames while the
        screen stays black.  That is exactly what happened on the first live camera join
        (2026-09-23): frames=12 bad=0, no picture.
        `lv_image_decoder_get_info` is the question actually being asked -- "can anything in the
        decoder chain read this?" -- and it answers without rendering.  A zero-size result is a
        rejected image. */
    lv_image_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    if (lv_image_decoder_get_info(&ll_lv_jpg_dsc, &hdr) != LV_RESULT_OK
        || hdr.w == 0 || hdr.h == 0) {
      AsciiConverter a1;
      lamb.log("jpeg: DECODER REJECTED a %s-byte image -- not displayed\n",
               a1.dec((LL_int32) nbytes));
      ok = false;
    }
    else {
      ll_lv_jpg_w = (int) hdr.w; ll_lv_jpg_h = (int) hdr.h;
    }
  }
  return ok;
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
      { mop3_lvgl_frame_write,   "lvgl-frame-write!"  },
      { mop3_lvgl_frame_jpeg,    "lvgl-frame-jpeg!"   },
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
