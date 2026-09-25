// Copyright 2026 by Frobenius Norm LLC 2026-07-02
// Free for non-commercial use. Commercial use requires a license.
//
// ESP32-S3-EYE camera (OV2640) + built-in ST7789 LCD -- P136 Phase 2.
//
// A self-contained LambLisp mop binding for the ESP32-S3-EYE dev board.  It
// uses ONLY the ESP-IDF components already bundled in the Arduino-ESP32 core:
//   * esp_camera  -- the OV2640 DVP sensor driver (RGB565 or JPEG frames)
//   * esp_lcd     -- the ST7789 240x240 IPS panel over SPI3
// No external Arduino libraries are required.
//
// Pins are from Espressif's esp-bsp (bsp/esp32_s3_eye), verified against the
// board schematic.  The frame hot-paths (grab + blit, mean-luma) stay in C++;
// Scheme drives the demo one-liners in scm/features/eye-cam.scm.
#include "LambLisp.h"
#include "ll_panel.h"          // P231 phase 0: LL_PANEL, ll_panel_blit_rgb565()


#if LL_CAMERA

#include "esp_camera.h"                 // OV2640 driver: camera_config_t, esp_camera_*
#include "driver/ledc.h"                // LEDC PWM -- backlight brightness (ACTIVE-LOW panel)
#include "esp_heap_caps.h"
void ll_heap_note(const char *tag);   //!< P211: every fast-RAM claim states the remainder              // heap_caps_malloc -- DMA-capable draw buffers (not PSRAM)
//! @defgroup xmop3_camera Camera (ESP32-S3-EYE)
//! @ingroup xmop3
//! @brief LambLisp Camera (ESP32-S3-EYE) builtins.
//! @{

/*! THE PANEL LEFT THIS FILE (P231 phase 0).  It is `ll_xmop3_Panel.cpp` now, behind the
    `LL_Panel` interface in `ll_panel.h`, and this driver asks only ONE question of it:
    is there a panel to send a frame to?  That is `LL_PANEL`.

    What used to be here was `LL_CAM_HAS_LCD`, derived as `LL_ESP32S3` -- correct only by
    accident, because the one S3 board with a camera happened to be the one board with the
    ST7789.  Worse, the panel could not exist WITHOUT this file: all 98 LCD references were
    inside `#if LL_CAMERA`, so a board with a panel and no camera could not compile a line
    of it.  A camera driver is the wrong owner for a display. */


// succeed.  The LCD band is still lazily reserved at lcd-init (row-halving fallback) and the camera hole
// just before esp_camera_init, so restoring camera preview (B87) needs this flipped back ON *and* a
// boot-read-safe reservation strategy (e.g. reserve only after the boot .scm loads finish).
#define EYE_CAM_EARLY_DMA_RESERVE 0

// --- Camera: OV2640 DVP ---
/*! TWO BOARDS, TWO WIRINGS, AND THEY SHARE NO PIN.  These are not interchangeable and a build that
    picks the wrong set configures GPIOs that either do not exist or belong to something else.
    The Freenove numbers are NOT guessed: they are exactly what
    scm/boards/pins/Freenove-4WD-Car-Kit-ESP32.scm already declares (pin-XCLK 21, pin-PCLK 22,
    pin-HREF 23, pin-CSI_VYSNC 25, pin-SIOD 26, pin-SIOC 27, pin-CSI_Y2..Y9 = 4 5 18 19 36 39 34
    35), which is the Freenove WROVER-CAM mapping and differs from the AI-Thinker ESP32-CAM one
    that a web search hands you first.  The Scheme map and this table must agree; if the board is
    ever re-wired, change BOTH -- see [P123] Part D. */
#if LL_ESP32S3
  // ESP32-S3-EYE
  #define EYE_CAM_XCLK    15
  #define EYE_CAM_SIOD     4           //!< SCCB SDA
  #define EYE_CAM_SIOC     5           //!< SCCB SCL
  #define EYE_CAM_VSYNC    6
  #define EYE_CAM_HREF     7
  #define EYE_CAM_PCLK    13
  #define EYE_CAM_D0      11           //!< D0..D7 are the sensor's Y2..Y9
  #define EYE_CAM_D1       9
  #define EYE_CAM_D2       8
  #define EYE_CAM_D3      10
  #define EYE_CAM_D4      12
  #define EYE_CAM_D5      18
  #define EYE_CAM_D6      17
  #define EYE_CAM_D7      16
#else
  // Freenove ESP32-WROVER-CAM (classic ESP32) -- the 4WD chassis and the breadboard WROVER
  #define EYE_CAM_XCLK    21
  #define EYE_CAM_SIOD    26           //!< SCCB SDA
  #define EYE_CAM_SIOC    27           //!< SCCB SCL
  #define EYE_CAM_VSYNC   25
  #define EYE_CAM_HREF    23
  #define EYE_CAM_PCLK    22
  #define EYE_CAM_D0       4           //!< Y2
  #define EYE_CAM_D1       5           //!< Y3
  #define EYE_CAM_D2      18           //!< Y4
  #define EYE_CAM_D3      19           //!< Y5
  #define EYE_CAM_D4      36           //!< Y6  (input-only pin -- fine, DVP data is read-only)
  #define EYE_CAM_D5      39           //!< Y7  (input-only)
  #define EYE_CAM_D6      34           //!< Y8  (input-only)
  #define EYE_CAM_D7      35           //!< Y9  (input-only)
#endif

static bool                       ll_cam_ok    = false;  //!< true once the sensor is initialised
static bool                       ll_eyecam_trace = false; //!< per-frame camera->lcd tracing -- OFF: the
                                                           //!< app-loop calls camera->lcd every tick, so a
                                                           //!< log there floods the shared serial line and
                                                           //!< buries REPL and test output.
static pixformat_t                ll_cam_fmt   = PIXFORMAT_RGB565;  //!< current camera pixel format
static void                      *ll_cam_dma_hole = 0; //!< contiguous internal-DMA block reserved early, freed just before esp_camera_init

static camera_config_t ll_eye_cam_config(pixformat_t fmt, framesize_t size)
{
  camera_config_t c = {};
  c.pin_pwdn     = -1;
  c.pin_reset    = -1;
  c.pin_xclk     = EYE_CAM_XCLK;
  c.pin_sccb_sda = EYE_CAM_SIOD;
  c.pin_sccb_scl = EYE_CAM_SIOC;
  c.pin_d7       = EYE_CAM_D7;
  c.pin_d6       = EYE_CAM_D6;
  c.pin_d5       = EYE_CAM_D5;
  c.pin_d4       = EYE_CAM_D4;
  c.pin_d3       = EYE_CAM_D3;
  c.pin_d2       = EYE_CAM_D2;
  c.pin_d1       = EYE_CAM_D1;
  c.pin_d0       = EYE_CAM_D0;
  c.pin_vsync    = EYE_CAM_VSYNC;
  c.pin_href     = EYE_CAM_HREF;
  c.pin_pclk     = EYE_CAM_PCLK;
  c.xclk_freq_hz = 16000000;           // 16 MHz -- 20 MHz overran the DVP DMA (EV-VSYNC-OVF -> torn
                                       //           frames that render as a diagonal colour sweep)
  c.ledc_timer   = LEDC_TIMER_0;
  c.ledc_channel = LEDC_CHANNEL_0;
  c.pixel_format = fmt;
  c.frame_size   = size;
  c.jpeg_quality = 12;                 // 0-63, lower = better (JPEG mode only)
  c.fb_count     = 2;                  // double-buffered
  c.fb_location  = CAMERA_FB_IN_PSRAM;
  // WHEN_EMPTY, not LATEST: the DVP captures on demand and WAITS when buffers are full instead of
  // free-running.  With LATEST the queue backed up whenever the loop stopped consuming (e.g. after
  // eye-live-stop), the DMA overran and HALTED, and every later fb_get returned NULL until a full
  // re-init.  WHEN_EMPTY can never overflow, so intermittent single grabs (frame-brightness,
  // camera-thumb) always return a valid frame.
  c.grab_mode    = CAMERA_GRAB_WHEN_EMPTY;
  return c;
}

//! Bring up (or re-affirm) the OV2640.  The ~23 KB internal-DMA line buffer is reserved
//! ONCE, EARLY (from the installer, while the heap is still contiguous) and held for the
//! session -- same rationale as LambLisp's cell block.  Calling this again in the SAME
//! pixel format is a no-op that KEEPS that buffer (re-initing later would free the 23 KB
//! and likely fail to re-grab it, since the heap has since fragmented to ~13 KB).  Only a
//! format change (rgb565<->jpeg) deinits + re-inits.
static bool ll_eye_camera_init(Lamb &lamb, pixformat_t fmt)
{
  if (ll_cam_ok && fmt == ll_cam_fmt) return true;    // already up in this mode -- keep the buffer
  if (ll_cam_ok) { esp_camera_deinit(); ll_cam_ok = false; }
  // Release the contiguous internal-DMA block reserved at boot IMMEDIATELY before
  // esp_camera_init so the freshly-freed hole is what the camera's ~23 KB line buffer lands
  // in (nothing allocates internal DMA between here and the init).
  if (ll_cam_dma_hole) { heap_caps_free(ll_cam_dma_hole); ll_cam_dma_hole = 0; }
  camera_config_t cfg = ll_eye_cam_config(fmt, FRAMESIZE_240X240);
  esp_err_t err = esp_camera_init(&cfg);
  ll_cam_ok = (err == ESP_OK);
  if (ll_cam_ok) ll_cam_fmt = fmt;
  lamb.log("[eyecam] camera_init fmt=%d -> %s\n", (int) fmt, esp_err_to_name(err));
  // Discard the first frames: the OV2640 AEC/AGC and the DVP pipeline need a few frames to
  // settle -- the earliest frames are dark/torn.  Draining them also clears any startup OVF.
  if (ll_cam_ok)
    for (int i = 0; i < 4; i++) { camera_fb_t *fb = esp_camera_fb_get(); if (fb) esp_camera_fb_return(fb); }
  return ll_cam_ok;
}

//! (camera-init [mode]) -> #t/#f.  mode 'rgb565 (default, drives the LCD) or 'jpeg (for capture).
Sexpr_t mop3_camera_init(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_camera_init()");
  ll_try {
    pixformat_t fmt = PIXFORMAT_RGB565;
    if (sexpr != NIL) {
      Sexpr_t mode = lamb.car(sexpr);
      if (mode->is_any_sym_atom() && !strcmp(mode->any_sym_get_chars(), "jpeg"))
        fmt = PIXFORMAT_JPEG;
    }
    return ll_eye_camera_init(lamb, fmt) ? HASHT : HASHF;
  }
  ll_catch();
}

//! (camera->lcd) -> #t/#f.  Grab one RGB565 frame and blit it to the LCD (the hot path).
#if LL_PANEL   // ---- needs a panel to send frames to; absent on the WROVER-CAM / 4WD
Sexpr_t mop3_camera_to_lcd(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_camera_to_lcd()");
  ll_try {
    if (!ll_cam_ok || !ll_panel_ready()) return HASHF;
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) return HASHF;
    const uint16_t *pp = (const uint16_t *) fb->buf;
    //! PER-FRAME DEBUG, OFF BY DEFAULT.  This logged unconditionally, and the eye's app-loop calls
    //! camera->lcd on EVERY tick once the live preview auto-starts -- ~20 lines/second onto the
    //! same serial line the REPL and every test harness read.  It has buried the gcpause
    //! output and the `--- done ---` sentinel under a wall of frame dumps, so a leg that had
    //! ALREADY failed for a different reason (the bench file was missing from the manifest) looked
    //! busy for 146 s instead of obviously broken.  A log inside a frame-rate path is a debugging
    //! aid, never shipped behaviour.
    if (ll_eyecam_trace)
      lamb.log("[eyecam] c2l fb w=%d h=%d len=%d fmt=%d  px0=%04x px1=%04x pxN/2=%04x pxEnd=%04x\n",
               (int) fb->width, (int) fb->height, (int) fb->len, (int) fb->format,
               pp[0], pp[1], pp[(fb->len/2)/2], pp[fb->len/2 - 1]);
    ll_panel_blit_rgb565(lamb, 0, 0, fb->width, fb->height, pp);
    esp_camera_fb_return(fb);
    return HASHT;
  }
  ll_catch();
}

//! (camera-preview [n]) -> n.  Live preview: blit n frames to the LCD (default 300).
Sexpr_t mop3_camera_preview(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_camera_preview()");
  ll_try {
    if (!ll_cam_ok || !ll_panel_ready()) return HASHF;
    LL_int32 n = (sexpr != NIL) ? lamb.car(sexpr)->mustbe_int32() : 300;
    for (LL_int32 i = 0; i < n; i++) {
      camera_fb_t *fb = esp_camera_fb_get();
      if (fb) {
        ll_panel_blit_rgb565(lamb, 0, 0, fb->width, fb->height, (const uint16_t *) fb->buf);
        esp_camera_fb_return(fb);
      }
    }
    return lamb.mk_integer(n, env_exec);
  }
  ll_catch();
}

//! (camera-thumb [n]) -> #t/#f.  Grab one RGB565 frame, nearest-neighbour downsample to n*n
//! (default 24, clamped 4..48), and print it over serial as:
//!    THUMB <n> <srcW> <srcH>
//!    <n rows of n 4-hex RGB565 values, byte-swapped to native>
//! For OFF-DEVICE visual verification (reconstruct the image on the host) without the LCD --
//! isolates a camera/frame fault from an LCD/blit fault.  Output is gated by the quiet REPL,
//! so call (verbose) first.
#endif  // LL_PANEL
Sexpr_t mop3_camera_thumb(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_camera_thumb()");
  ll_try {
    if (!ll_cam_ok) return HASHF;
    // (camera-thumb n)       -> nearest-neighbour subsample of the whole frame.
    // (camera-thumb n x0 y0) -> RAW n*n crop at (x0,y0), every pixel -- full-res detail that reveals
    //                           fine moire / streaks / screen subpixels that subsampling aliases away.
    int n = 24, cx = -1, cy = -1;
    { Sexpr_t a = sexpr;
      if (a != NIL) { Sexpr_t v = lamb.car(a); if (v->is_any_int()) n  = (int) v->as_int32(); a = lamb.cdr(a); }
      if (a != NIL) { Sexpr_t v = lamb.car(a); if (v->is_any_int()) cx = (int) v->as_int32(); a = lamb.cdr(a); }
      if (a != NIL) { Sexpr_t v = lamb.car(a); if (v->is_any_int()) cy = (int) v->as_int32(); } }
    if (n < 4)  n = 4;
    if (n > 48) n = 48;
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) return HASHF;
    const uint16_t *src = (const uint16_t *) fb->buf;
    const int W = fb->width, H = fb->height;
    const bool crop = (cx >= 0 && cy >= 0);
    lamb.log("THUMB %d %d %d %s\n", n, W, H, crop ? "crop" : "sub");
    for (int ty = 0; ty < n; ty++) {
      char line[48 * 4 + 2];
      int  p  = 0;
      int  sy = crop ? (cy + ty) : (ty * H / n);
      if (sy >= H) sy = H - 1;
      for (int tx = 0; tx < n; tx++) {
        int sx = crop ? (cx + tx) : (tx * W / n);
        if (sx >= W) sx = W - 1;
        uint16_t v = src[(size_t) sy * W + sx];
        v = (uint16_t) ((v >> 8) | (v << 8));            // same byte-swap the blit applies
        static const char hx[] = "0123456789abcdef";
        line[p++] = hx[(v >> 12) & 0xf]; line[p++] = hx[(v >> 8) & 0xf];
        line[p++] = hx[(v >> 4)  & 0xf]; line[p++] = hx[v & 0xf];
      }
      line[p++] = '\n'; line[p] = 0;
      lamb.log("%s", line);
    }
    esp_camera_fb_return(fb);
    return HASHT;
  }
  ll_catch();
}

//! (camera-set key val) -> void.  Tune the OV2640 via its sensor_t control block.
//! keys: framesize brightness contrast hmirror vflip special-effect.
Sexpr_t mop3_camera_set(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_camera_set()");
  ll_try {
    if (!ll_cam_ok) return OBJ_VOID;
    sensor_t *s = esp_camera_sensor_get();
    if (!s) return OBJ_VOID;
    Sexpr_t  key = lamb.car(sexpr);
    LL_int32 val = lamb.cadr(sexpr)->mustbe_int32();
    if (!key->is_any_sym_atom()) return OBJ_VOID;
    const char *k = key->any_sym_get_chars();
    if      (!strcmp(k, "framesize"))      s->set_framesize(s, (framesize_t) val);
    else if (!strcmp(k, "brightness"))     s->set_brightness(s, val);
    else if (!strcmp(k, "contrast"))       s->set_contrast(s, val);
    else if (!strcmp(k, "hmirror"))        s->set_hmirror(s, val);
    else if (!strcmp(k, "vflip"))          s->set_vflip(s, val);
    else if (!strcmp(k, "special-effect")) s->set_special_effect(s, val);
    return OBJ_VOID;
  }
  ll_catch();
}

//! (camera-capture) -> bytevector.  Return one JPEG frame (needs (camera-init 'jpeg));
//! returns #f if no frame is available.
Sexpr_t mop3_camera_capture(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_camera_capture()");
  ll_try {
    if (!ll_cam_ok) return HASHF;
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) return HASHF;
    // Copy the JPEG bytes into a GC-managed T_BVEC_HEAP (payload alloc; freed by the GC).
    Sexpr_t bv = lamb.mk_bytevector((LL_int32) fb->len, (Bytest_t) fb->buf, env_exec);
    esp_camera_fb_return(fb);
    return bv;
  }
  ll_catch();
}

//! (frame-brightness) -> integer 0..255.  Cheap mean luma over a downsampled RGB565
//! frame -- a scalar for trigger-policy demos ("brighten past N -> fire").
Sexpr_t mop3_frame_brightness(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_frame_brightness()");
  ll_try {
    if (!ll_cam_ok) return lamb.mk_integer(-1, env_exec);
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) return lamb.mk_integer(-1, env_exec);
    if (fb->format != PIXFORMAT_RGB565) { esp_camera_fb_return(fb); return lamb.mk_integer(-1, env_exec); }
    // Big-endian RGB565: each pixel is [hi, lo].  Sample every 8th pixel and
    // accumulate an approximate luma (Rec.601 weights on 8-bit expanded channels).
    const uint8_t *p     = fb->buf;
    size_t         npix  = fb->len / 2;
    unsigned long  sum   = 0;
    unsigned long  count = 0;
    for (size_t i = 0; i < npix; i += 8) {
      uint16_t px = (uint16_t)((p[2 * i] << 8) | p[2 * i + 1]);
      int r = ((px >> 11) & 0x1F) << 3;      // 5-bit -> 8-bit
      int g = ((px >> 5)  & 0x3F) << 2;      // 6-bit -> 8-bit
      int b = ( px        & 0x1F) << 3;      // 5-bit -> 8-bit
      sum   += (r * 77 + g * 150 + b * 29) >> 8;
      count += 1;
    }
    esp_camera_fb_return(fb);
    LL_int32 mean = count ? (LL_int32)(sum / count) : 0;
    return lamb.mk_integer(mean, env_exec);
  }
  ll_catch();
}

//! (lcd-backlight [percent]) -> void.  Set backlight brightness 0..100 (default 100).
//! Handy for demos: (lcd-backlight 0) blanks the screen without tearing down the panel,
//! (lcd-backlight 100) restores it.  Independent of panel content, so it also isolates a
//! backlight fault from a draw fault when bringing up new hardware.

#endif // LL_CAMERA

//! Installer -- always compiles; registers the eye mops only under LL_CAMERA.
Sexpr_t EyeCam_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::EyeCam_install_mop3()");
  ll_try {
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    {
      Sexpr_t proc = lamb.mk_Mop3_procst_t(EyeCam_install_mop3, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol("EyeCam-install-mop3", env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#if LL_CAMERA
    static const struct { Lamb::Mop3st_t func; const char *name; } eye_procs[] = {
      { mop3_camera_init,      "camera-init"      },
#if LL_PANEL
      { mop3_camera_to_lcd,    "camera->lcd"      },
      { mop3_camera_preview,   "camera-preview"   },
#endif
      { mop3_camera_thumb,     "camera-thumb"     },
      { mop3_camera_set,       "camera-set"       },
      { mop3_camera_capture,   "camera-capture"   },
      { mop3_frame_brightness, "frame-brightness" },
    };
    const int Neye_procs = sizeof(eye_procs)/sizeof(eye_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Neye_procs);
    for (int i = 0; i < Neye_procs; i++) {
      const auto &p = eye_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
    // Reserve a contiguous internal-DMA HOLE for the camera NOW -- the installer runs right
    // after the cell block but BEFORE setup.scm loads, so the heap is still contiguous (~48 KB
    // block).  We do NOT init the camera here: starting DVP capture while setup.scm reads files
    // from flash crashes on camera-DMA-vs-flash-cache contention (boot loop).  Instead we hold
    // an empty placeholder and free it right before esp_camera_init (in camera-init), so the
    // camera's ~23 KB line buffer lands in this reserved contiguous region even though the rest
    // of the heap has fragmented to ~13 KB by then (the recurring 23 KB DMA-malloc failure).
    // Reserve the camera hole NOW.  setup.scm's cell-heap EXPANSION (startup needs >8192 cells
    // -> a new internal block) also comes out of DMA-capable RAM.
    //! THE LCD BAND USED TO BE RESERVED HERE TOO, AND IS NOT ANY MORE: it belongs to the panel
    //! driver (P231 phase 0) and is claimed lazily at (lcd-init).  The two claims still COMPETE
    //! for the same internal-DMA pool, so whichever runs second can still come back NULL -- that
    //! coupling is real and did not move with the code.  If a blank screen returns after a camera
    //! change, this is the interaction to suspect.
#if EYE_CAM_EARLY_DMA_RESERVE
    ll_cam_dma_hole = heap_caps_malloc(24 * 1024, MALLOC_CAP_DMA);
    ll_heap_note("claim: camera DMA hole");
    lamb.log("%s reserved camera hole %p; largest free DMA now %d\n",
             me, ll_cam_dma_hole,
             (int) heap_caps_get_largest_free_block(MALLOC_CAP_DMA));
#else
    lamb.log("%s early DMA reserve OFF (B88): band+hole lazy; largest free DMA now %d\n",
             me, (int) heap_caps_get_largest_free_block(MALLOC_CAP_DMA));
#endif
#endif
    return NIL;
  }
  ll_catch();
}
//! @}
