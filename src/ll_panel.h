// Copyright 2026 by Frobenius Norm LLC 2026-09-20 17:52:08
//
// P231 phase 0 -- THE PANEL INTERFACE, EXTRACTED FROM THE CAMERA DRIVER.
//
// WHY THIS FILE EXISTS.  Every LCD operation in this tree used to live inside
// `ll_xmop3_EyeCam.cpp`, gated on `#if LL_CAMERA`.  That is not a layering
// blemish, it is a hard blocker: a board with a PANEL AND NO CAMERA could not
// reach a single line of it, because the whole file is preprocessed away.  The
// two halves were fused because only one board -- the ESP32-S3-EYE -- had ever
// carried both, so the accident was invisible for as long as there was one board.
//
// WHAT THE ABSTRACTION MUST SPAN, AND IT IS NOT "TWO CONTROLLERS".  The two
// panels P231 targets differ in WHAT A FRAME UPDATE IS:
//
//   PUSH (SPI/QSPI -- ST7789, CO5300):  you write pixels over a bus when something
//       changes.  An idle screen costs nothing.  `blit` is the operation.
//   SCAN (16-bit parallel RGB):  a peripheral reads a framebuffer forever at the
//       pixel clock.  An idle screen costs FULL REFRESH BANDWIDTH.  There is no bus
//       to write to -- an update is a store into `fb()`, which the hardware finds
//       on its next scan.
//
// So `model` is the field a caller must branch on, and `blit`/`fb` are NULL on
// the model that cannot provide them.  An abstraction that assumes push is not an
// abstraction; it is the S3-EYE with parameters, which is the mistake this file
// exists to avoid making a second time.
//
// A BOARD SUPPLIES `set_brightness`, AND IT MAY BE NULL.  On the S3-EYE it is LEDC
// PWM on an active-low pin; on an AMOLED it is a panel register write and there IS
// no backlight pin; on some boards there is no control at all.  A `#define` cannot
// express that, and a COPIED driver produces a function that exists, is callable,
// and does nothing -- the silent no-op this tree keeps paying for.  NULL here means
// "this panel cannot", which the caller can report; it never means "did nothing".
#ifndef LL_PANEL_H
#define LL_PANEL_H

#include "LambLisp.h"

/*! LL_PANEL_ST7789_EYE -- the ESP32-S3-EYE's built-in ST7789 240x240 on SPI3.
    Set by `[env:esp32-s3-eye]`, via the `panel_st7789_eye` feature in `w3_pio/boards.json`.
    **THAT SENTENCE WAS FALSE FOR THE WHOLE OF [B557], AND IT IS WHY NOBODY LOOKED.**  It read
    "Set explicitly by the `esp32-s3-eye` env" while the env set nothing, so the S3-EYE shipped
    with no display code at all -- the comment is precisely what removed the reason to check.
    If you change where this is set, change this line in the same commit.  It used to be derived as `LL_ESP32S3`
    inside the camera driver (as `LL_CAM_HAS_LCD`), which was correct ONLY because the
    single S3 board with a camera happened to be the single board with this panel.
    Deriving a PANEL from "is this an S3" would put GPIO 43/44/47/48 on every S3 build
    the moment a second S3 camera board existed, so the gate is now named for the board
    it actually describes. */
#ifndef LL_PANEL_ST7789_EYE
  #define LL_PANEL_ST7789_EYE 0
#endif

/*! LL_PANEL_ST7701_AITRIP -- the AITRIP / Guition ESP32-4848S040's ST7701S 480x480
    on the S3's 16-bit parallel RGB peripheral.  The SCAN half of P231's abstraction.
    Set by `[env:esp32s3-aitrip-480x480]` from `w3_pio/boards.json`.
    **SETTING IT IN THIS HEADER IS NOT WHAT TURNS IT ON** -- the `#ifndef` below only
    supplies the OFF default, and a gate that no build defines is dead code that still
    compiles.  That was [B557], found on the ST7789 gate above while adding this one:
    `LL_PANEL_ST7789_EYE` was documented as "set by the esp32-s3-eye env" and was set by
    nothing, so the S3-EYE shipped with no display code at all.  **FIXED 2026-09-23** by adding
    `panel_st7789_eye` to that board's `features`.  A grep for the symbol
    across `platformio.ini` and `w3_pio/boards.json` is the whole check, and it takes a
    second -- do it when you add the third panel.  `verify_truth.sh` section 26 now does it for
    EVERY `LL_*` gate, so the third panel is checked whether or not anyone remembers. */
#ifndef LL_PANEL_ST7701_AITRIP
  #define LL_PANEL_ST7701_AITRIP 0
#endif

//! LL_PANEL -- does THIS build have any panel at all?  Derived, never set by hand.
//! In the header rather than the .cpp because the CAMERA driver must also ask it, to
//! decide whether `camera->lcd` exists -- and a gate that two files must agree on has
//! exactly one home.
#if LL_PANEL_ST7789_EYE || LL_PANEL_ST7701_AITRIP
  #define LL_PANEL 1
#else
  #define LL_PANEL 0
#endif

//! Which of the two display models this panel is.  Decides whether `blit` or `fb` is live.
enum LL_PanelModel {
  LL_PANEL_PUSH = 0,   //!< bus-attached: `blit` sends pixels.  `fb` is NULL.
  LL_PANEL_SCAN = 1    //!< hardware scans a framebuffer: `fb` returns it.  `blit` is NULL.
};

/*! A panel is a CONFIGURATION PLUS FIVE OPERATIONS, supplied by the board.
    Every pointer except `init` may be NULL; a NULL operation is one this panel
    genuinely cannot perform, and callers must treat it as an absence rather than
    substituting a no-op. */
struct LL_Panel {
  const char   *name;          //!< "st7789-240x240-spi3", "co5300-410x502-qspi", "rgb565-480x480-par16"
  int           w, h;          //!< panel geometry in pixels
  LL_PanelModel model;         //!< PUSH or SCAN -- branch on this, not on the name
  bool        (*init)(Lamb &lamb);                                                  //!< bring up bus + controller; idempotent
  void        (*fill)(Lamb &lamb, int x, int y, int w, int h, uint16_t color);       //!< filled rect, RGB565
  void        (*blit)(Lamb &lamb, int x, int y, int w, int h, const uint16_t *src);  //!< PUSH only; NULL on SCAN
  uint16_t   *(*fb)(void);                                                          //!< SCAN only; NULL on PUSH
  void        (*set_brightness)(Lamb &lamb, int percent);                           //!< 0..100, or NULL if the panel has none
  void        (*on_off)(Lamb &lamb, bool on);                                       //!< display on/off, or NULL
};

//! The panel this board registered, or NULL when the board has none.
const LL_Panel *ll_panel_active(void);

//! Register the board's panel.  Called from the board's own section of ll_xmop3_Panel.cpp.
void            ll_panel_register(const LL_Panel *p);

//! True once `init` has run and succeeded.  A draw before this is a no-op, not an error.
bool            ll_panel_ready(void);

/*! Blit RGB565 to the active panel -- the call the CAMERA driver makes.
    This is the whole reason the camera no longer needs to know what a panel is:
    it hands over pixels and geometry, and the panel decides whether that is a bus
    transaction or a store into a scanned framebuffer. */
void            ll_panel_blit_rgb565(Lamb &lamb, int x, int y, int w, int h, const uint16_t *src);

#endif  // LL_PANEL_H
