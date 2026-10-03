// Copyright 2026 by Frobenius Norm LLC 2026-09-20 17:52:27
//
// P231 phase 0 -- the panel driver, extracted from ll_xmop3_EyeCam.cpp.
//
// THE FINDING THIS FILE IS THE FIX FOR.  All 98 LCD references lived inside the
// CAMERA driver, under `#if LL_CAMERA`.  A board with a panel and no camera could
// not reach any of it -- not "would have to work around it", could not COMPILE it.
// The ESP32-S3-EYE carries both, so for as long as it was the only panel board the
// fusion cost nothing and was invisible.  P231's two new N16R8 panels are the point
// at which it stops being free.
//
// WHAT IS GENERIC AND WHAT IS THE BOARD'S.  Everything above the ---- BOARD ----
// line is panel-model-independent: the active-panel registry and the `lcd-*` mops,
// which work through `LL_Panel` and never name a controller.  Everything below it
// belongs to one board and is guarded by that board's own macro.
//
// THE MOPS ARE REGISTERED ONLY WHERE THERE IS A PANEL.  On a board without one the
// names stay UNBOUND rather than bound to something that silently does nothing --
// an unbound name tells the caller immediately; a no-op stub makes a missing panel
// look like a working one.  (Carried over from the camera driver, where it was
// already the right decision.)
#include "LambLisp.h"
#include "ll_panel.h"
#include <stdlib.h>                     // malloc/free -- host path for the test pattern
#if LL_ESP32S3 || LL_ESP32
  #include "esp_heap_caps.h"            // heap_caps_malloc -- PSRAM for the test pattern
#endif

//! @defgroup xmop3_panel Panel (LCD/AMOLED/RGB)
//! @ingroup xmop3
//! @brief LambLisp display-panel builtins -- board-independent.
//! @{

// ===========================================================================
// Generic: the active-panel registry
// ===========================================================================

static const LL_Panel *ll_panel_cur   = 0;     //!< the board's panel, or NULL if it has none
static bool            ll_panel_inited = false; //!< true once init() ran AND returned true

const LL_Panel *ll_panel_active(void) { return ll_panel_cur; }
bool            ll_panel_ready(void)  { return ll_panel_cur && ll_panel_inited; }
void            ll_panel_register(const LL_Panel *p) { ll_panel_cur = p; }

/*! The call the CAMERA driver makes.  It is the entire decoupling: the camera hands
    over pixels and geometry and does not know, and must not know, whether that is a
    bus transaction or a store into a framebuffer the hardware is already scanning. */
//! [B662] Defined further down, beside the AITRIP framebuffer it flushes; declared here because
//! the blit is the first writer in the file and every writer of the scanned framebuffer calls it.
void ll_panel_fb_writeback(int y, int h);

void ll_panel_blit_rgb565(Lamb &lamb, int x, int y, int w, int h, const uint16_t *src)
{
  if (!ll_panel_ready() || !src || w <= 0 || h <= 0) return;
  const LL_Panel *p = ll_panel_cur;
  if (p->model == LL_PANEL_PUSH) {
    if (p->blit) p->blit(lamb, x, y, w, h, src);
    return;
  }
  //! SCAN: there is no bus.  Store into the scanned framebuffer, clipped to the panel.
  //! Deliberately NOT a memcpy of the whole region: `src` stride is `w`, the framebuffer
  //! stride is the PANEL width, and they are equal only when the source happens to be
  //! full width -- which a camera thumbnail never is.
  //! [B662] The rows written are flushed at the end -- the scan DMA does not read our cache.
  uint16_t *fb = p->fb ? p->fb() : 0;
  if (!fb) return;
  int dw = (x + w > p->w) ? (p->w - x) : w;
  int dh = (y + h > p->h) ? (p->h - y) : h;
  if (dw <= 0 || dh <= 0) return;
  for (int r = 0; r < dh; r++) {
    const uint16_t *srow = src + (size_t) r * w;
    uint16_t       *drow = fb  + (size_t) (y + r) * p->w + x;
    for (int i = 0; i < dw; i++) drow[i] = srow[i];
  }
  ll_panel_fb_writeback(y, dh);            //!< [B662] the scan DMA does not read our cache
}

/*! Allocate the test-pattern buffer.  PSRAM on an MCU -- a 480x480 pattern is 450 KB and
    has no business in internal DMA RAM, which the band buffer and the camera line buffer are
    already competing for.  Plain malloc on a host so this file is not MCU-only. */
static void *ll_panel_alloc_pattern(size_t nbytes)
{
#if LL_ESP32S3 || LL_ESP32
  return heap_caps_malloc(nbytes, MALLOC_CAP_SPIRAM);
#else
  return malloc(nbytes);
#endif
}

//! Fill through the active panel, whichever model it is.
static void ll_panel_fill_rect(Lamb &lamb, int x, int y, int w, int h, uint16_t color)
{
  if (!ll_panel_ready()) return;
  const LL_Panel *p = ll_panel_cur;
  if (p->fill) { p->fill(lamb, x, y, w, h, color); return; }
  uint16_t *fb = (p->model == LL_PANEL_SCAN && p->fb) ? p->fb() : 0;
  if (!fb) return;
  int dw = (x + w > p->w) ? (p->w - x) : w;
  int dh = (y + h > p->h) ? (p->h - y) : h;
  for (int r = 0; r < dh; r++) {
    uint16_t *drow = fb + (size_t) (y + r) * p->w + x;
    for (int i = 0; i < dw; i++) drow[i] = color;
  }
}

// ===========================================================================
// ---- BOARD: ESP32-S3-EYE, ST7789 240x240 IPS on SPI3 (PUSH model) ----------
// ===========================================================================
// Moved VERBATIM from ll_xmop3_EyeCam.cpp.  The comments below are the expensive
// part -- the UART0 pin conflict, the byte-order pairing, the DMA band sizing and
// the IDF-4.4 power-on sequence were each found the hard way, and a paraphrase
// would lose the symptom each one names.  Behaviour is unchanged; only the gate
// (LL_PANEL_ST7789_EYE, not LL_CAMERA) and the entry points differ.
#if LL_PANEL_ST7789_EYE

#include "driver/spi_master.h"          // spi_bus_initialize, SPI3_HOST, SPI_DMA_CH_AUTO
#include "esp_lcd_panel_io.h"           // esp_lcd_panel_io_spi_config_t, new_panel_io_spi
#include "esp_lcd_panel_vendor.h"       // esp_lcd_panel_dev_config_t, new_panel_st7789
#include "esp_lcd_panel_ops.h"          // reset/init/draw_bitmap/invert/disp_on_off
#include "driver/ledc.h"                // LEDC PWM -- backlight brightness (ACTIVE-LOW panel)
#include "driver/gpio.h"                // gpio_reset_pin -- free DC/CS from the UART0 console
#include "esp_heap_caps.h"

// --- LCD: ST7789 240x240 IPS on SPI3 (S3-EYE only) ---
// --- LCD: ST7789 240x240 IPS on SPI3 (S3-EYE only) ---
#define EYE_LCD_HOST    SPI3_HOST
#define EYE_LCD_SCLK    21
#define EYE_LCD_MOSI    47
#define EYE_LCD_CS      44
#define EYE_LCD_DC      43
#define EYE_LCD_RST     (-1)            //!< reset not wired (tied high on the board)
#define EYE_LCD_BL      48              //!< backlight -- ACTIVE-LOW, LEDC/PWM (per esp-bsp)
#define EYE_BL_TIMER    LEDC_TIMER_1    //!< dedicated timer (camera XCLK uses LEDC_TIMER_0)
#define EYE_BL_CHANNEL  LEDC_CHANNEL_1  //!< dedicated channel (camera XCLK uses LEDC_CHANNEL_0)
#define EYE_LCD_W       240
#define EYE_LCD_H       240
#define EYE_LCD_HZ        (40 * 1000 * 1000)   //!< 40 MHz pclk (10 MHz test ruled out SPI signal integrity)
#define EYE_LCD_BAND_ROWS 16                    //!< 16-row band -> ~15 draw_bitmap calls/frame (was 240,
                                                //!< one per row -> a visible top-to-bottom paint = "wiggle").
                                                //!< ~7.5 KB internal-DMA; falls back to 1 row if the alloc
                                                //!< is tight.  The camera's 23 KB line buffer is reserved
                                                //!< from the same pool and barely fits, so keep the LCD minimal.

static esp_lcd_panel_io_handle_t  ll_lcd_io    = 0;      //!< SPI panel-IO handle
static esp_lcd_panel_handle_t     ll_lcd_panel = 0;      //!< ST7789 panel handle
static bool                       ll_lcd_ok    = false;  //!< true once the panel is initialised
static bool                       ll_bl_ok     = false;  //!< true once the backlight LEDC is set up
static uint16_t                  *ll_lcd_band = 0;      //!< persistent internal-DMA band buffer (reserved at lcd-init)
static int                        ll_lcd_band_rows = 0; //!< rows in ll_lcd_band (EYE_LCD_BAND_ROWS, or fewer if DMA is tight)

/*
  Byte order note (RGB565):
  The OV2640 emits RGB565 in big-endian (byte-swapped) order, and
  esp_lcd_panel_draw_bitmap() ships the buffer to the panel as-is.  On this
  board the pairing lines up, so the camera frame blits directly.  If colours
  look wrong, the fix is one of: byte-swap each 16-bit pixel before blitting,
  set the panel-IO `flags.` swap option, or flip color_space RGB<->BGR below.
*/

//! Set the LCD backlight brightness (0..100 %).  On the ESP32-S3-EYE the backlight is
//! ACTIVE-LOW and PWM-driven: LEDC duty 0 = full brightness, duty 1023 = off (verified
//! against the Espressif esp-bsp bsp_display_brightness_set).  A plain digitalWrite(HIGH)
//! is therefore the DARKEST setting -- the cause of the black screen.  A dedicated timer
//! and channel keep this off the camera's LEDC_TIMER_0/LEDC_CHANNEL_0 (used for XCLK).
static void ll_st7789_set_brightness(Lamb &lamb, int percent)
{
  if (percent < 0)   percent = 0;
  if (percent > 100) percent = 100;
  esp_err_t e;
  if (!ll_bl_ok) {
    ledc_timer_config_t t = {};
    t.speed_mode      = LEDC_LOW_SPEED_MODE;
    t.duty_resolution = LEDC_TIMER_10_BIT;   // 10-bit -> duty 0..1023
    t.timer_num       = EYE_BL_TIMER;
    t.freq_hz         = 5000;
    t.clk_cfg         = LEDC_AUTO_CLK;
    e = ledc_timer_config(&t);
    lamb.log("[eyecam] ledc_timer_config -> %s\n", esp_err_to_name(e));
    ledc_channel_config_t ch = {};
    ch.gpio_num   = EYE_LCD_BL;
    ch.speed_mode = LEDC_LOW_SPEED_MODE;
    ch.channel    = EYE_BL_CHANNEL;
    ch.intr_type  = LEDC_INTR_DISABLE;
    ch.timer_sel  = EYE_BL_TIMER;
    ch.duty       = 0;
    ch.hpoint     = 0;
    e = ledc_channel_config(&ch);
    lamb.log("[eyecam] ledc_channel_config gpio=%d ch=%d -> %s\n",
             (int) EYE_LCD_BL, (int) EYE_BL_CHANNEL, esp_err_to_name(e));
    ll_bl_ok = true;
  }
  uint32_t duty = (1023 * (100 - percent)) / 100;   // active-low: 100% -> 0, 0% -> 1023
  e = ledc_set_duty(LEDC_LOW_SPEED_MODE, EYE_BL_CHANNEL, duty);
  lamb.log("[eyecam] ledc_set_duty %d%% duty=%d -> %s\n", percent, (int) duty, esp_err_to_name(e));
  e = ledc_update_duty(LEDC_LOW_SPEED_MODE, EYE_BL_CHANNEL);
  lamb.log("[eyecam] ledc_update_duty -> %s\n", esp_err_to_name(e));
}

//! Bring up SPI3, the ST7789 panel and the backlight.  Idempotent: the bus/panel half
//! runs once, the backlight is re-applied on every call (that is what makes a second
//! (lcd-init) a cheap way to recover a blanked screen).
static bool ll_st7789_init(Lamb &lamb)
{
  ME("::ll_st7789_init()");
  ll_try {
    esp_err_t e;
    if (!ll_lcd_ok) {
      // 0. GPIO43(DC)/44(CS) are the ESP32-S3 default UART0 console pins, and the
      //    arduino-esp32 core binds the IDF console to UART0 (CONFIG_ESP_CONSOLE_UART_
      //    DEFAULT).  While UART0 holds those pins the panel's DC/CS never reach the
      //    ST7789 -- every draw returns ESP_OK but the screen stays blank.  Reset the
      //    pins to a clean GPIO state (disconnects the UART0 signal + IO_MUX) before the
      //    panel claims them.  The factory firmware sidesteps this by running its console
      //    on USB-Serial-JTAG; we use USB-CDC, so UART0 is free to release here.
      gpio_reset_pin((gpio_num_t) EYE_LCD_DC);
      gpio_reset_pin((gpio_num_t) EYE_LCD_CS);
      lamb.log("[eyecam] freed DC=%d / CS=%d from UART0\n", (int) EYE_LCD_DC, (int) EYE_LCD_CS);

      // 1. Initialise the SPI3 bus (MOSI + SCLK only; this panel is write-only).
      spi_bus_config_t buscfg = {};
      buscfg.mosi_io_num     = EYE_LCD_MOSI;
      buscfg.miso_io_num     = -1;
      buscfg.sclk_io_num     = EYE_LCD_SCLK;
      buscfg.quadwp_io_num   = -1;
      buscfg.quadhd_io_num   = -1;
      // Sized for one band (16 rows).  Keep it modest: a full-frame (115 KB) value reserves a
      // large internal-DMA chunk that starves the camera's ~23 KB DVP line buffer (esp_camera_init
      // then fails with cam_dma_config malloc).
      buscfg.max_transfer_sz = EYE_LCD_W * EYE_LCD_BAND_ROWS * (int) sizeof(uint16_t) + 64;
      e = spi_bus_initialize(EYE_LCD_HOST, &buscfg, SPI_DMA_CH_AUTO);
      lamb.log("[eyecam] spi_bus_initialize host=%d -> %s\n", (int) EYE_LCD_HOST, esp_err_to_name(e));

      // 2. Attach the ST7789 as an SPI panel-IO device.  The bus handle is the
      //    host id cast to esp_lcd_spi_bus_handle_t (a void*), per the esp_lcd API.
      esp_lcd_panel_io_spi_config_t io_config = {};
      io_config.cs_gpio_num       = EYE_LCD_CS;
      io_config.dc_gpio_num       = EYE_LCD_DC;
      io_config.spi_mode          = 0;
      io_config.pclk_hz           = EYE_LCD_HZ;
      io_config.trans_queue_depth = 1;    // serialize: each draw_bitmap blocks until the previous band's
                                          // SPI DMA drains, so the ping-pong band buffer is safe to repack
      io_config.lcd_cmd_bits      = 8;
      io_config.lcd_param_bits    = 8;
      e = esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t) EYE_LCD_HOST, &io_config, &ll_lcd_io);
      lamb.log("[eyecam] new_panel_io_spi -> %s (io=%p)\n", esp_err_to_name(e), (void *) ll_lcd_io);

      // 3. Create and initialise the ST7789 panel.
      esp_lcd_panel_dev_config_t panel_config = {};
      panel_config.reset_gpio_num = EYE_LCD_RST;
      panel_config.color_space    = ESP_LCD_COLOR_SPACE_RGB;   // BGR here if R/B look swapped
      panel_config.bits_per_pixel = 16;
      e = esp_lcd_new_panel_st7789(ll_lcd_io, &panel_config, &ll_lcd_panel);
      lamb.log("[eyecam] new_panel_st7789 -> %s (panel=%p)\n", esp_err_to_name(e), (void *) ll_lcd_panel);

      e = esp_lcd_panel_reset(ll_lcd_panel);        lamb.log("[eyecam] panel_reset -> %s\n", esp_err_to_name(e));
      delay(150);   // ST7789 needs ~120ms after (software) reset before init commands
      e = esp_lcd_panel_init(ll_lcd_panel);         lamb.log("[eyecam] panel_init -> %s\n", esp_err_to_name(e));
      delay(20);

      // The IDF-4.4 esp_lcd ST7789 driver (arduino-esp32 2.0.17) leaves the panel asleep /
      // display-off after panel_init -- so every draw returns ESP_OK but nothing shows.  The
      // IDF-6.x driver sends these itself; here we send the essential power-on sequence
      // explicitly over the version-stable low-level tx_param path.  Harmless if redundant.
      #define LL_ST7789(cmd, ...) do { \
          const uint8_t _p[] = { __VA_ARGS__ }; \
          esp_lcd_panel_io_tx_param(ll_lcd_io, (cmd), sizeof(_p) ? _p : NULL, sizeof(_p)); \
        } while (0)
      esp_lcd_panel_io_tx_param(ll_lcd_io, 0x11, NULL, 0);   // SLPOUT (sleep out)
      delay(120);
      LL_ST7789(0x3A, 0x55);                                 // COLMOD = 16-bit/pixel (RGB565)
      LL_ST7789(0x36, 0x00);                                 // MADCTL = 0 (RGB, no rotation)
      esp_lcd_panel_io_tx_param(ll_lcd_io, 0x21, NULL, 0);   // INVON (IPS panel wants inversion)
      esp_lcd_panel_io_tx_param(ll_lcd_io, 0x13, NULL, 0);   // NORON (normal display mode)
      esp_lcd_panel_io_tx_param(ll_lcd_io, 0x29, NULL, 0);   // DISPON (display on)
      delay(20);
      lamb.log("[eyecam] manual ST7789 power-on sequence sent\n");
      #undef LL_ST7789

      // Reserve the DMA band buffer NOW, before the camera claims internal DMA RAM, so every
      // later fill/blit reuses it.  A per-draw malloc fails once esp_camera_init has run
      // (that was the "LCD dies after camera-init" bug: silent DMA-alloc failure, no draw).
      if (!ll_lcd_band) {
        // Internal DMA-capable SRAM is the scarce resource (the camera's ~23 KB line buffer and this
        // band both draw from it).  Report the budget, then take the largest band that fits by halving
        // on failure -- best refresh speed without starving the camera.
        lamb.log("[eyecam] internal-DMA free=%d largest=%d (before band)\n",
                 (int) heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA),
                 (int) heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA));
        for (int rows = EYE_LCD_BAND_ROWS; rows >= 1; rows = (rows > 1) ? rows / 2 : 0) {
          ll_lcd_band = (uint16_t *) heap_caps_malloc(
              (size_t) EYE_LCD_W * rows * sizeof(uint16_t), MALLOC_CAP_DMA);
          if (ll_lcd_band) { ll_lcd_band_rows = rows; break; }
        }
        //! P211: REPORT largest, NOT ONLY free.  A claim succeeds or fails on the largest
        //! CONTIGUOUS block, and this line reported only the total for months -- which is how a
        //! board with 32 KB free could fail a 23 KB request ([B428]) with nothing in the log saying why.
        lamb.log("[eyecam] LCD band buffer: %d rows @ %p (internal-DMA free now %d, largest %d)\n",
                 ll_lcd_band_rows, (void *) ll_lcd_band,
                 (int) heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA),
                 (int) heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA));
      }
      ll_lcd_ok = true;
    }
    // Backlight full on (active-low LEDC -- see ll_st7789_set_brightness).
    ll_st7789_set_brightness(lamb, 100);
    return true;
  }
  ll_catch();
}

//! Fill an axis-aligned rectangle with one RGB565 colour, one scanline at a time
//! (a single small DMA buffer, so a full-screen clear costs only ~480 bytes).
static void ll_st7789_fill(Lamb &lamb, int x, int y, int w, int h, uint16_t color)
{
  if (!ll_lcd_ok || !ll_lcd_band || w <= 0 || h <= 0) return;
  if (w > EYE_LCD_W) w = EYE_LCD_W;
  const int bandrows = ll_lcd_band_rows;
  const uint16_t be = (uint16_t) ((color >> 8) | (color << 8));    // ST7789 latches big-endian on the wire; esp_lcd
  for (int i = 0; i < w * bandrows; i++) ll_lcd_band[i] = be;      // sends memory order, so store byte-swapped. reuse-safe.
  for (int r = 0; r < h; r += bandrows) {
    int rows = (h - r < bandrows) ? (h - r) : bandrows;
    esp_lcd_panel_draw_bitmap(ll_lcd_panel, x, y + r, x + w, y + r + rows, ll_lcd_band);
  }
}

//! Blit a w*h RGB565 image from `src` to the panel at (x,y).  `src` may live in PSRAM
//! (e.g. a camera frame buffer), which SPI DMA CANNOT read -- so every row is copied
//! through a persistent internal-DMA bounce buffer before draw_bitmap.  This is the
//! reason a direct draw_bitmap(fb->buf) silently shows nothing.
static void ll_st7789_blit(Lamb &lamb, int x, int y, int w, int h, const uint16_t *src)
{
  if (!ll_lcd_ok || !ll_lcd_band || w <= 0 || h <= 0 || !src) return;
  const int stride = w;                       // source row stride = actual frame width
  int dw = (w > EYE_LCD_W) ? EYE_LCD_W : w;    // clamp the DRAWN width to the panel
  int dh = (h > EYE_LCD_H) ? EYE_LCD_H : h;    // clamp the DRAWN height to the panel
  const int bandrows = ll_lcd_band_rows;
  for (int r = 0; r < dh; r += bandrows) {
    int rows = (dh - r < bandrows) ? (dh - r) : bandrows;
    for (int rr = 0; rr < rows; rr++) {       // copy `rows` scanlines into the band.
      // The OV2640 fb is ALREADY big-endian RGB565, and the ST7789 (via esp_lcd, which sends memory
      // byte order) also wants big-endian -- so copy the pixels RAW, no swap.  (An earlier byte-swap
      // here double-swapped against the fill path and scrambled every varying pixel into colour
      // streaks -- solid fills survived because a swapped constant is still constant.)
      const uint16_t *srow = src + (size_t) (r + rr) * stride;
      uint16_t       *drow = ll_lcd_band + (size_t) rr * dw;
      for (int i = 0; i < dw; i++) drow[i] = srow[i];
    }
    esp_lcd_panel_draw_bitmap(ll_lcd_panel, x, y + r, x + dw, y + r + rows, ll_lcd_band);
    // draw_bitmap is async fire-and-forget here (neither trans_queue_depth=1 nor on_color_trans_done
    // gate reuse in this arduino-esp32/IDF build), and we pack ~15x faster than the 40 MHz bus drains
    // -- so block for the transfer to complete before repacking the single band buffer:
    //   t = rows * width * 16bit / pclk  (+400us margin).  Busy-wait, but the whole blit still fits
    // well inside the ~46 ms camera frame interval, so it is not the throughput bottleneck.
    delayMicroseconds((uint32_t) rows * dw * 16 / (EYE_LCD_HZ / 1000000) + 400);
  }
}


//! The board's panel record.  `fb` is NULL because this is a PUSH panel -- there is no
//! framebuffer the hardware scans, and a caller that wants one must be told so rather
//! than handed a buffer that reaches no screen.
static const LL_Panel ll_panel_st7789_eye = {
  "st7789-240x240-spi3",
  EYE_LCD_W, EYE_LCD_H,
  LL_PANEL_PUSH,
  ll_st7789_init,
  ll_st7789_fill,
  ll_st7789_blit,
  0,                          //!< fb: PUSH panel, nothing to expose
  ll_st7789_set_brightness,
  0                           //!< on_off: not wired on this board (backlight is the control)
};
#endif  // LL_PANEL_ST7789_EYE

// ===========================================================================
// ---- BOARD: AITRIP / Guition ESP32-4848S040, ST7701S 480x480 (SCAN model) --
// ===========================================================================
// P231 phase 2.  The SCAN half of the abstraction: the S3's LCD_CAM peripheral
// reads a PSRAM framebuffer forever at the pixel clock, so there is no bus to
// write to and `blit` is NULL.  An update is a STORE into fb(); the hardware
// finds it on the next scan.
//
// THE PANEL NEEDS TWO BUSES AND THEY ARE NOT THE SAME BUS.  A 3-wire 9-bit SPI
// (CS 39 / SCK 48 / MOSI 47, bit-banged) runs a 36-command init ONCE; after that
// the panel is driven entirely by the 16 data lines plus DE/HSYNC/VSYNC/PCLK and
// the SPI pins are never touched again.  The SD card shares SCK/MOSI, which is
// why init must finish before anything mounts it.
//
// *** THERE IS NO RESET GPIO, AND THAT IS A DEVELOPMENT CONSTRAINT, NOT A DETAIL. ***
// LCD1 pin 6 is driven by an RC power-on network (R16/C21/C22) on no GPIO.  Three
// independent sources agree: the manufacturer's schematic; the vendor's own demo,
// which passes GFX_NOT_DEFINED for RST; and that demo at runtime, which logs
// `gpio_set_level(226): GPIO output gpio_num error` five times trying to drive a
// pin that is not there.  SO A WEDGED ST7701 CANNOT BE RECOVERED IN SOFTWARE --
// not by a reboot (the module's EN resets the S3 while the panel's RC network
// stays charged), not by re-running init.  It needs POWER REMOVED.  If you are
// iterating on the init sequence, "flash, observe, adjust, re-flash" IS NOT A
// VALID LOOP; power-cycle between attempts or you will be reading the state left
// by the previous attempt and calling it the result of this one.
//! [B655] ROTATION STATE BELONGS TO THE PANEL ABSTRACTION, NOT TO ONE CONTROLLER.
//! This was defined inside `#if LL_PANEL_ST7701_AITRIP` and read by `mop3_lcd_init()`, which sits
//! under the wider `#if LL_PANEL` and is deliberately generic -- it dispatches through
//! `ll_panel_active()` and refuses politely when there is no panel.  So every env with a panel that
//! is NOT the AITRIP ST7701 failed to COMPILE: `esp32-s3-eye` (-DLL_PANEL_ST7789_EYE=1) died with
//! "'ll_ait_rotation_deg' was not declared in this scope".
//! IT SURVIVED BECAUSE THE ONE ENV THAT EXERCISES THE AITRIP PATH BUILDS FINE, and that is the env
//! anyone working on this file builds.  The break only surfaced when a smoke run was needed on the
//! EYE for an unrelated bug -- and it surfaced as `build-upload-fail`, which names the board or the
//! port ([B559]), not a source file that cannot compile for that target.
//! The name still says `ait_`; renaming it is the better end state and touches code that is being
//! actively worked ([P123]/[P231]), so the gate is fixed here and the name is left alone.
static int ll_ait_rotation_deg = 0;              //!< 0 or 180, set by (lcd-init [DEG]); any panel

#if LL_PANEL_ST7701_AITRIP

#include "esp_lcd_panel_rgb.h"          // esp_lcd_new_rgb_panel, esp_lcd_rgb_panel_config_t
#include "esp_lcd_panel_ops.h"          // esp_lcd_panel_reset/init/disp_on_off
#include "driver/ledc.h"                // backlight PWM
#include "ll_fastram.h"                // [B662] display reserves internal DRAM ahead of LambLisp
#include "esp_cache.h"                   // esp_cache_msync -- flush CPU writes out for the RGB DMA [B662]
#include "driver/gpio.h"                // bit-banged 9-bit init SPI
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define AIT_W        480
#define AIT_H        480

// Init SPI -- 3-wire 9-bit, bit-banged.  Shared with the SD card (SCK/MOSI).
#define AIT_SPI_CS   39
#define AIT_SPI_SCK  48
#define AIT_SPI_SDA  47

// RGB sync + clock
#define AIT_DE       18
#define AIT_VSYNC    17
#define AIT_HSYNC    16
#define AIT_PCLK     21
#define AIT_BL       38

/*! Timing.  From the VENDOR'S OWN DEMO (`4.0_LvglWidgets.ino`), not derived:
    hsync fp/pw/bp = 10/8/50, vsync fp/pw/bp = 10/8/20, pclk 16 MHz.
    That gives 548 x 518 total = 283,864 px/frame and **56.4 Hz**, which costs a
    SUSTAINED 26.0 MB/s of PSRAM read whether or not a pixel changed.  P231's table
    estimated 16.4-32.8 MB/s; 26.0 is the real figure and sits inside that bracket.
    It is the number phase 1b's bandwidth arm exists to test against the published
    worst-case GC pause, so do not change these timings without re-running it.
    NOTE the panel's own datasheet (HSD040BPN1-A00) specifies vbp=15/vfp=12 at 60 Hz
    and a 32 us line time (~17.1 MHz).  The vendor's demo uses neither exactly and
    works; these are the numbers with evidence of running on THIS board. */
/*! PIXEL CLOCK.  16 MHz, matching the published reference for this module, as do all the other
    timings here.
    12 MHz WAS TRIED AND CHANGED NOTHING -- recorded so it is not tried again.  The theory was that a
    slower clock would widen the settling window for a red-channel artefact on this panel (see the
    note at the bounce buffer below).  The artefact was identical at 12 MHz.  With hindsight the
    vendor documentation says why: the ceiling for a 16-bit RGB bus is around 40 MHz, so at 16 MHz
    this bus was never near a timing limit and there was no margin to buy. */
//! [B662] 8 MHz, LOWERED FROM 16 DELIBERATELY, AND THE REASON IS MEASURED RATHER THAN PREFERRED.
//! The panel's red channel RAMPS to full brightness over a fixed ~312 ns after a step from black
//! -- analog settling in its source drivers, not anything we send it.  A red region narrower than
//! that ramp never reaches full red at all, which is what the long-standing "dark red column" at
//! every red edge actually is, and what makes camera highlights fringe cyan.
//!
//! Because the ramp is a fixed TIME, a slower pixel clock crosses it in FEWER PIXELS.  Measured on
//! the glass against a calibrated ruler, read as "narrowest red bar that still shows full red":
//!     16 MHz -> 7 px      12 MHz -> 6 px      8 MHz -> ~4.5 px
//! Fitting the 16 and 8 MHz points gives T = 312 ns with a ~2 px floor, and that model predicts
//! the 12 MHz point (5.75 px vs 6 measured) without having been fitted to it.
//!
//! PRICE, STATED SO THE NEXT READER CAN REVERSE THE TRADE KNOWINGLY: refresh falls from ~56 Hz to
//! ~28 Hz (548x518 = 283,864 clocks per frame).  No flicker was visible at 28 Hz on this panel.
//! A slower clock also demands less sustained PSRAM read bandwidth, so it should WIDEN the margin
//! against the [B588] scan desync rather than narrow it.
//!
//! SIX OTHER ARMS WERE NULL AND COULD NOT HAVE BEEN OTHERWISE: drive strength, clock edge, the
//! vendor's own init registers, the inversion selection and the bounce buffer in both directions
//! cannot move an analog settling time.  Only the clock can, by changing how many pixels it spans.
#define AIT_PCLK_HZ  (16 * 1000 * 1000)
//! [B662] arm 2: drive capability for the 16 RGB data lines.  GPIO_DRIVE_CAP_2 (~20 mA) is the
//! IDF default and is what every build before 2026-09-29 ran; CAP_0 is the weakest (~5 mA).
//! Weaker is the direction under test -- see the block at the call site for why down and not up.
#define AIT_DATA_DRIVE GPIO_DRIVE_CAP_3   //!< [B662] STRONGEST. Arm 2 tested the WEAKEST on a ringing theory that is now refuted; a line that is SLOW TO RISE wants more drive, not less, and that direction was never tried.
#define AIT_HSYNC_FP 10
#define AIT_HSYNC_PW 8
#define AIT_HSYNC_BP 50
#define AIT_VSYNC_FP 10
#define AIT_VSYNC_PW 8
#define AIT_VSYNC_BP 20

//! Data lines in BUS order, D0..D15.  Confirmed FOUR ways and they all agree: the
//! vendor's IO pin distribution xlsx, the schematic's LCD1 connector, the vendor's
//! demo source, and the demo RENDERING CORRECTLY on this panel.  The low five are
//! BLUE and the high five RED -- i.e. BGR, which is why the demo passes `true/*BGR*/`.
//! DB0 and DB12 are not wired: this is an 18-bit RGB666 panel fed 16 lines, so the
//! LSB of blue and of red are dropped.  The 5-6-5 is in the COPPER, not a setting.
static const int ait_data_gpios[16] = {
   4,  5,  6,  7, 15,          // B0..B4   (panel DB1..DB5)
   8, 20,  3, 46,  9, 10,      // G0..G5   (panel DB6..DB11)
  11, 12, 13, 14,  0           // R0..R4   (panel DB13..DB17)
};

static esp_lcd_panel_handle_t ait_panel = 0;
static uint16_t              *ait_fb    = 0;

/*! [B662] THIS SEQUENCE NOW FOLLOWS THE MANUFACTURER'S SHIPPED DRIVER CODE, NOT THEIR VALIDATED
    INIT TEXT -- THE TWO DISAGREE, AND THAT DISAGREEMENT IS AN EXPERIMENT IN PROGRESS.

    `ST7701S_HSD040BPN1_480x480_init_verified_20230531.txt` and the
    `st7701_type1_init_operations[]` table inside their own `Arduino_ST7701_RGBPanel.h` differ in
    FOUR places, mechanically diffed after aligning for two leading ops the code omits:

        0xC2 (INVSEL)   text 21 08   code 31 05     <- inversion selection
        0xB1 (bank 11)  text 30      code 32
        0xB2 (bank 11)  text 87      code 07
        an extra bank-13 `E5 E4` write, present in the code and absent from the text

    We followed the TEXT, because it is the file marked "verified OK".  Their DEMO runs the CODE.
    0xC2 selects the inversion scheme, and the text's own header declares `Inversion : 2dot` --
    inversion is the mechanism behind vertical crosstalk at high-contrast column edges, which is
    exactly the [B662] symptom, and it is untouched by pixel clock or drive strength (both of which
    were changed and produced nothing).

    ALL FOUR ARE ADOPTED AT ONCE ON PURPOSE.  This is a SCREENING test -- does the vendor's init
    remove the artefact at all? -- and bisecting four registers one flash at a time before knowing
    whether any of them matters costs four builds to possibly learn nothing.  If the artefact goes,
    bisect from here; if it does not, the init is ruled out wholesale.  The pre-change file is
    recoverable from git.

    Delays are part of the sequence, not padding: 120 ms after 0x11 (sleep-out) is the
    controller's own requirement and skipping it yields a panel that initialises
    "successfully" and shows nothing.

    ORIGINAL NOTE, kept because the provenance still matters:
    from the PANEL MANUFACTURER's validated file:
    `ST7701S_HSD3.95IPS(HSD040BPN1)480x480_V1.0 -RGB` marked 验证OK ("verified OK"),
    dated 2023-05-31, shipped inside the factory archive and kept at
    w3_pio/boards/docs/aitrip-s3-n16r8/vendor/1-Demo/.  The "72 data bytes" this line used to
    claim was wrong -- a mechanical count says 166 across 36 commands, and nothing had ever
    checked it.
    Transcribed mechanically, not by hand -- see that directory for the source file.
    Delays are part of the sequence, not padding: 120 ms after 0x11 (sleep-out) is the
    controller's own requirement and skipping it yields a panel that initialises
    "successfully" and shows nothing. */
typedef struct { uint8_t cmd; uint8_t n; uint16_t delay_ms; uint8_t data[16]; } ait_init_op_t;
static const ait_init_op_t ait_init_ops[] = {
  { 0xFF,  5,   0, { 0x77, 0x01, 0x00, 0x00, 0x13 } },
  { 0xEF,  1,   0, { 0x08 } },
  { 0xFF,  5,   0, { 0x77, 0x01, 0x00, 0x00, 0x10 } },
  { 0xC0,  2,   0, { 0x3B, 0x00 } },
  { 0xC1,  2,   0, { 0x0D, 0x02 } },
  { 0xC2,  2,   0, { 0x31, 0x05 } },   //!< [B662] VENDOR-CODE value; the validated .txt says 21 08
  { 0xCD,  1,   0, { 0x00 } },
  { 0xB0, 16,   0, { 0x00, 0x11, 0x18, 0x0E, 0x11, 0x06, 0x07, 0x08, 0x07, 0x22, 0x04, 0x12, 0x0F, 0xAA, 0x31, 0x18 } },
  { 0xB1, 16,   0, { 0x00, 0x11, 0x19, 0x0E, 0x12, 0x07, 0x08, 0x08, 0x08, 0x22, 0x04, 0x11, 0x11, 0xA9, 0x32, 0x18 } },
  { 0xFF,  5,   0, { 0x77, 0x01, 0x00, 0x00, 0x11 } },
  { 0xB0,  1,   0, { 0x60 } },
  { 0xB1,  1,   0, { 0x32 } },         //!< [B662] VENDOR-CODE value; the .txt says 30
  { 0xB2,  1,   0, { 0x07 } },         //!< [B662] VENDOR-CODE value; the .txt says 87
  { 0xB3,  1,   0, { 0x80 } },
  { 0xB5,  1,   0, { 0x49 } },
  { 0xB7,  1,   0, { 0x85 } },
  { 0xB8,  1,   0, { 0x21 } },
  { 0xC1,  1,   0, { 0x78 } },
  { 0xC2,  1,  20, { 0x78 } },
  { 0xE0,  3,   0, { 0x00, 0x1B, 0x02 } },
  { 0xE1, 11,   0, { 0x08, 0xA0, 0x00, 0x00, 0x07, 0xA0, 0x00, 0x00, 0x00, 0x44, 0x44 } },
  { 0xE2, 12,   0, { 0x11, 0x11, 0x44, 0x44, 0xED, 0xA0, 0x00, 0x00, 0xEC, 0xA0, 0x00, 0x00 } },
  { 0xE3,  4,   0, { 0x00, 0x00, 0x11, 0x11 } },
  { 0xE4,  2,   0, { 0x44, 0x44 } },
  { 0xE5, 16,   0, { 0x0A, 0xE9, 0xD8, 0xA0, 0x0C, 0xEB, 0xD8, 0xA0, 0x0E, 0xED, 0xD8, 0xA0, 0x10, 0xEF, 0xD8, 0xA0 } },
  { 0xE6,  4,   0, { 0x00, 0x00, 0x11, 0x11 } },
  { 0xE7,  2,   0, { 0x44, 0x44 } },
  { 0xE8, 16,   0, { 0x09, 0xE8, 0xD8, 0xA0, 0x0B, 0xEA, 0xD8, 0xA0, 0x0D, 0xEC, 0xD8, 0xA0, 0x0F, 0xEE, 0xD8, 0xA0 } },
  { 0xEB,  7,   0, { 0x02, 0x00, 0xE4, 0xE4, 0x88, 0x00, 0x40 } },
  { 0xEC,  2,   0, { 0x3C, 0x00 } },
  { 0xED, 16,   0, { 0xAB, 0x89, 0x76, 0x54, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x20, 0x45, 0x67, 0x98, 0xBA } },
  //! [B662] THE VENDOR'S SHIPPED DRIVER RETURNS TO BANK 13 AND WRITES E5 HERE; the validated
  //! .txt does not, and neither did we.  Added as part of the screening test described above.
  { 0xFF,  5,   0, { 0x77, 0x01, 0x00, 0x00, 0x13 } },
  { 0xE5,  1,   0, { 0xE4 } },
  { 0xFF,  5,   0, { 0x77, 0x01, 0x00, 0x00, 0x00 } },
  { 0x3A,  1,   0, { 0x66 } },
  //! MADCTL bit 3 is the RGB/BGR selector.  The vendor's table sets it (0x08 = BGR) because their
  //! demo's graphics stack emits BGR pixels -- it passes `true/*BGR*/` to its library.  LVGL and
  //! the `lcd-*` procedures emit RGB, so with the bit set red and blue arrive exchanged: a light
  //! blue label renders brown and an amber one renders cyan.  Clearing it tells the controller to
  //! take RGB, which is what everything in this tree actually produces.
  { 0x36,  1,   0, { 0x00 } },
  //! [B705] LEAVE THE INVERSION STATE DEFINED, DO NOT INHERIT IT.  This sequence sets gamma,
  //! power, source timing, pixel format and scan direction and then left INVCTRL alone -- so the
  //! panel kept whatever it had, and `(lcd-init)` COULD NOT CLEAR AN INVERTED PANEL.  `0x21` is a
  //! standard DCS command any caller can send, the state survives re-init AND a warm MCU reboot
  //! (the ST7701 has no reset line the MCU can drive -- see SCHEMATIC_FINDINGS.md), so the
  //! strongest recovery available did not cover it.  Cost a false conclusion in [B662]: a panel
  //! still inverted from a much earlier command was read as a VCOM write taking effect, and that
  //! was reported as proof that bank-1 register access worked.  It was not.
  //! The general shape: an init that sets MOST of a chip's state reads as if it sets ALL of it,
  //! and the registers it omits are invisible because they are not in the table.
  { 0x20,  0,   0, {  } },
  { 0x11,  0, 120, {  } },
  { 0x29,  0,  20, {  } },
};

/*! One 9-bit word on the 3-wire SPI: DCX then 8 data bits, MSB first.
    DCX = 0 selects COMMAND, 1 selects DATA -- there is no separate D/C pin, which is
    the whole point of "3-wire".  Bit-banged because this runs 36 times at boot and
    never again; a DMA SPI device here would cost setup and a pin conflict with the SD
    card for no gain. */
static void ait_spi9(bool is_data, uint8_t byte)
{
  gpio_set_level((gpio_num_t) AIT_SPI_SCK, 0);
  gpio_set_level((gpio_num_t) AIT_SPI_SDA, is_data ? 1 : 0);
  gpio_set_level((gpio_num_t) AIT_SPI_SCK, 1);
  for (int i = 7; i >= 0; i--) {
    gpio_set_level((gpio_num_t) AIT_SPI_SCK, 0);
    gpio_set_level((gpio_num_t) AIT_SPI_SDA, (byte >> i) & 1);
    gpio_set_level((gpio_num_t) AIT_SPI_SCK, 1);
  }
}

//! ROTATION IS A MADCTL SUBSTITUTION AT INIT TIME, NOT A RENDER-TIME TRANSFORM.
//!
//! The panel's own scan order is free to change; rotating pixels in software is not.  LVGL's
//! software rotation costs a pass over the framebuffer every frame, and rotating the LAYOUT
//! instead does not work at all for 180 degrees -- it would move the widget boxes and leave every
//! GLYPH upside down, which looks like a font bug rather than an orientation one.
//!
//! WHY IT IS NEEDED AT ALL, since a panel is screwed down once: on this bench the board's own
//! ANTENNA is directional.  Measured 2026-09-25, same position, rotation alone: -74 dBm -> -51 dBm,
//! about 23 dB, more than moving the board across the room was worth.  So the orientation that is
//! right for the radio is not necessarily the one that is right for the viewer, and the cheap one
//! to change is the image.
//!
//! ST7701S MADCTL (0x36): bit7 MY row order, bit6 MX column order, bit5 MV row/col exchange,
//! bit3 BGR.  180 degrees is both axes mirrored, MY|MX = 0xC0.  Bit 3 stays CLEAR: the vendor
//! table sets it for a BGR pipeline and everything in this tree emits RGB.
//!
//! 90 and 270 ARE REFUSED RATHER THAN APPROXIMATED.  They need MV, which exchanges rows and
//! columns -- and while this panel is square so the geometry survives, the framebuffer stride and
//! LVGL's notion of width/height do not follow MADCTL, so the result would be a scrambled image
//! from a call that returned success.  Refusing names the limit; guessing hides it.

static uint8_t ait_madctl_for_rotation(int deg)
{
  return (deg == 180) ? 0xC0 : 0x00;
}

static void ait_send_init(Lamb &lamb)
{
    const int n = (int) (sizeof(ait_init_ops) / sizeof(ait_init_ops[0]));
  lamb.log("ST7701S init: %s commands\n", ascii.dec((LL_int32) n));
  for (int i = 0; i < n; i++) {
    const ait_init_op_t *op = &ait_init_ops[i];
    gpio_set_level((gpio_num_t) AIT_SPI_CS, 0);
    ait_spi9(false, op->cmd);
    //! Substitute MADCTL as it goes out rather than mutating the static table: the table is
    //! `const` and shared, and a table that changed under a second call to `lcd-init` would make
    //! the panel's state depend on how many times it had been initialised.
    if (op->cmd == 0x36 && op->n == 1) {
      ait_spi9(true, ait_madctl_for_rotation(ll_ait_rotation_deg));
    }
    else {
      for (int j = 0; j < op->n; j++) ait_spi9(true, op->data[j]);
    }
    gpio_set_level((gpio_num_t) AIT_SPI_CS, 1);
    if (op->delay_ms) vTaskDelay(pdMS_TO_TICKS(op->delay_ms));
  }
}

static void ait_set_brightness(Lamb &lamb, int percent)
{
  if (percent < 0)   percent = 0;
  if (percent > 100) percent = 100;
  //! ACTIVE HIGH here, unlike the S3-EYE's active-low backlight -- and unlike it,
  //! IO38 does not drive an LED directly: it is BL_CTR into the FEEDBACK node of a
  //! boost regulator (U5).  So brightness is NOT linear in duty cycle, and a
  //! calibration curve belongs here if anyone ever needs real photometric steps.
  ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, (uint32_t) ((percent * 8191) / 100));
  ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
}

static uint16_t *ait_framebuffer(void) { return ait_fb; }

// The scan framebuffer holds RGB565 in BIG-ENDIAN byte order, so a colour must be byte-swapped on
// the way in: storing 0xF800 (red) on this little-endian core places the bytes [00 F8] in memory,
// which the panel reads as 0x00F8 (blue).  This matches `lcd-rgb565!`, which documents its input
// as a big-endian RGB565 region and blits it through unchanged.  Callers of the `lcd-*` procedures
// therefore pass NATIVE RGB565, and the conversion happens here -- the single place that writes a
// scalar colour into the scan buffer.
/*! [B662] PUSH CPU WRITES OUT TO PSRAM, BECAUSE THE SCAN DMA DOES NOT READ OUR CACHE.
    The framebuffer lives in PSRAM (`cfg.flags.fb_in_psram`) and the RGB peripheral fetches it by
    DMA.  A CPU store lands in cache and reaches PSRAM whenever the cache feels like it, so the
    scan can read a line the CPU has already "written" and get the PREVIOUS contents.

    THE MANUFACTURER'S DRIVER DOES THIS AFTER EVERY FRAMEBUFFER WRITE -- six `Cache_WriteBack_Addr`
    call sites in `vendor/1-Demo/Arduino_ST7701_RGBPanel.cpp`, including one per PIXEL in
    `writePixelPreclipped`.  This driver did it NOWHERE, and the owner reports the factory demo
    shows none of the red-edge artefact this file has chased for weeks.

    AND IT IS WHY "THE FRAMEBUFFER IS EXACT" WAS NOT EVIDENCE.  That check read pixels back with
    `lvgl-fb-pixel`, i.e. with the CPU, THROUGH THE SAME CACHE THE WRITES WENT INTO -- so it returns
    the intended value whether or not PSRAM ever received it.  A verification that shares the
    suspect component with the thing it verifies cannot fail, and this one could not.

    Flushes the whole SPAN OF ROWS touched, not the exact rectangle: rows are contiguous in the
    framebuffer, so one range covers them, and over-flushing costs time rather than correctness.
    UNALIGNED is set because a caller's y/h are arbitrary and the sync must not be refused for
    landing off a cache-line boundary -- a refused flush is the silent version of this whole bug. */
static void ait_fb_writeback(Lamb &lamb, int y, int h)
{
  if (!ait_fb || h <= 0) return;
  if (y < 0) { h += y; y = 0; }
  if (y + h > AIT_H) h = AIT_H - y;
  if (h <= 0) return;
  void        *addr  = (void *) (ait_fb + (size_t) y * AIT_W);
  const size_t nbyte = (size_t) h * AIT_W * sizeof(uint16_t);
  const esp_err_t rc = esp_cache_msync(addr, nbyte,
                                       ESP_CACHE_MSYNC_FLAG_DIR_C2M | ESP_CACHE_MSYNC_FLAG_UNALIGNED);
  if (rc != ESP_OK) {
    //! SAY SO RATHER THAN DEGRADE QUIETLY.  A refused flush reproduces the original defect exactly,
    //! and silently -- which is how it survived this long.
    static bool moaned = false;
    if (!moaned) { moaned = true; lamb.log("ST7701S: cache msync REFUSED (%s) -- scan may read stale lines\n",
                                           ascii.dec((LL_int32) rc)); }
  }
}

static void ait_fill(Lamb &lamb, int x, int y, int w, int h, uint16_t color)
{
  if (!ait_fb) return;                       //!< guard BEFORE any scaffolding -- nothing to unwind
  if (x < 0) { w += x; x = 0; }
  if (y < 0) { h += y; y = 0; }
  if (x + w > AIT_W) w = AIT_W - x;
  if (y + h > AIT_H) h = AIT_H - y;
  /*! NO BYTE SWAP.  This used to `__builtin_bswap16(color)` on the belief that the scan buffer is
      consumed big-endian.  IT IS NOT: the RGB peripheral fetches the 16-bit word and drives the data
      lines with it as stored, so a swap here is pure corruption -- every fill drew the wrong colour.
      MEASURED both ways on the board: a fill asking for red 0xF800 stored 0x00F8 and the glass showed
      BLUE (0x00F8 is r0,g7,b24); LVGL writes the same 0xF800 unswapped through its own path and the
      glass shows RED.  One framebuffer, so only one convention can be right, and LVGL's is.
      WHY THE WRONG VERSION LASTED: the only caller that runs on every boot fills with 0x0000 (black
      before the backlight), and black is swap-invariant -- so the one code path everybody sees could
      not expose it.  The rest are bring-up and diagnostic calls, and a diagnostic that fills the
      screen the wrong colour still fills the screen. */
  for (int r = 0; r < h; r++) {
    uint16_t *row = ait_fb + (size_t) (y + r) * AIT_W + x;
    for (int c = 0; c < w; c++) row[c] = color;
  }
  ait_fb_writeback(lamb, y, h);
}

static void ait_on_off(Lamb &lamb, bool on)
{
  if (ait_panel) esp_lcd_panel_disp_on_off(ait_panel, on);
}

static bool ait_init(Lamb &lamb)
{
  bool res = true;                           //!< SINGLE EXIT -- see CLAUDE.md
    if (ait_panel) return true;                //!< idempotent, and nothing acquired yet

  // --- backlight OFF first, so a half-initialised panel is not shown ---
  ledc_timer_config_t lt = {};
  lt.speed_mode = LEDC_LOW_SPEED_MODE; lt.duty_resolution = LEDC_TIMER_13_BIT;
  lt.timer_num  = LEDC_TIMER_0;        lt.freq_hz = 5000; lt.clk_cfg = LEDC_AUTO_CLK;
  ledc_timer_config(&lt);
  ledc_channel_config_t lc = {};
  lc.gpio_num = AIT_BL; lc.speed_mode = LEDC_LOW_SPEED_MODE; lc.channel = LEDC_CHANNEL_0;
  lc.timer_sel = LEDC_TIMER_0; lc.duty = 0; lc.hpoint = 0;
  ledc_channel_config(&lc);

  // --- 3-wire init SPI, bit-banged.  CS idles high. ---
  gpio_config_t io = {};
  io.mode = GPIO_MODE_OUTPUT;
  io.pin_bit_mask = (1ULL << AIT_SPI_CS) | (1ULL << AIT_SPI_SCK) | (1ULL << AIT_SPI_SDA);
  gpio_config(&io);
  gpio_set_level((gpio_num_t) AIT_SPI_CS, 1);
  gpio_set_level((gpio_num_t) AIT_SPI_SCK, 1);
  ait_send_init(lamb);

  // --- the RGB peripheral: it owns the framebuffer and scans it forever ---
  esp_lcd_rgb_panel_config_t cfg = {};
  cfg.clk_src            = LCD_CLK_SRC_DEFAULT;
  cfg.data_width         = 16;
  cfg.bits_per_pixel     = 16;
  cfg.num_fbs            = 1;              //!< ONE buffer: see P123 G2 on tearing.  A second
                                           //!< costs another 460,800 B AND doubles the scan-side
                                           //!< PSRAM pressure that P231 1b is about to measure
                                           //!< against a PUBLISHED GC pause figure.  Do not raise
                                           //!< this until that arm has run.
  cfg.psram_trans_align  = 64;
  /*! BOUNCE BUFFERS -- THE FIX FOR VISIBLE FLICKER, and P231 predicted this exact symptom.
      With `fb_in_psram` and no bounce buffer, the LCD's DMA fetches every pixel straight from
      PSRAM at the pixel clock.  Any contention on that bus -- the CPU, the collector walking a
      PSRAM heap, WiFi -- starves the LCD FIFO, and an underrun shows as FLICKER: the panel is
      still scanning, it just gets bad data for part of a line.
      The symptom does NOT look like a bandwidth problem.  It looks like a bad cable, a bad
      panel, or a wrong timing, and that is why it is worth naming here: observed 2026-09-22 on
      the very first test pattern this driver drew.
      A bounce buffer decouples the two: the DMA fills a small INTERNAL-DRAM buffer from PSRAM in
      bursts and the LCD drains that, so PSRAM latency stops being in the pixel-clock critical
      path.  Two buffers of h_res*10 px = 2 x 9,600 B of internal DRAM, which this board has.
      P231 called this "a phase-2 question, not an assumption" -- this is that question being
      answered on hardware rather than assumed either way.
      *** CONFIRMED BY THE OWNER ON THE GLASS, 2026-09-22. *** Before: "there is a test pattern
      but it is flickering".  After, same board, same pattern, only this change: "screen looks
      good".  Two arms, one difference.  The confirmation is VISUAL, not instrumented -- nothing
      counted an underrun -- so if flicker ever returns under load (the collector walking PSRAM,
      WiFi bursting), raising bounce_buffer_size_px is the first lever, not a rewrite. */
  /*! 20 ROWS, RAISED FROM 10.  Two buffers at 20 rows cost 38,400 B of internal DRAM against
      19,200 B at 10.  That budget is worth watching on this part: internal exhaustion does not fail
      at the allocation that causes it, it surfaces in whatever next needs DMA-capable memory, so
      spend it deliberately.  Measured here with ~100 KB internal left afterwards.
      40 rows was also tried and changed nothing observable, so 20 is the provision that earns its
      keep; raising this further is not the lever for anything still outstanding.

      A SEPARATE, RED-CHANNEL ARTEFACT EXISTS ON THIS PANEL AND MORE BUFFER DOES NOT ADDRESS IT.
      Characterised by filling the framebuffer with uniform colours and reading every pixel back:

        * RED ONLY.  Uniform green and uniform blue are clean.  A magenta field loses its red and
          keeps its blue.
        * It appears at the FIRST PIXELS AFTER A RED RUN BEGINS ALONG A SCANLINE, and follows the
          data rather than the screen: a red rectangle starting mid-line puts the artefact at the
          rectangle's edge, while a full-screen red fill puts it at the panel's edge.
        * Red is held near its PREVIOUS value rather than scaled -- on a field of r=31 it reads near
          the background's red, and on a field of r=4 it reads near zero.  That makes it independent
          of the size of the red step, which rules out a proportional slew and points at the red bits
          not being latched for the first pixels of a run.
        * The framebuffer is CORRECT at those pixels, confirmed with a cache-invalidating read so the
          value is the one the display controller fetches and not a cached copy.
        * Independent of which code writes the framebuffer: the graphics path and the scalar fill
          path produce it identically, so it is not a rendering or flush artefact.
        * Unaffected by bounce buffer size at 4x provision, and the RGB timings here already match
          the published reference for this module.

      The remaining software-accessible lever is the PIXEL CLOCK -- a slower clock gives the data
      lines longer to settle before the panel latches them.  If it survives that, what is left is the
      wiring: this module drives an RGB666 panel over 16 data lines with two bits unconnected, and
      red is the high-bit group.
      Do NOT reach for a second framebuffer for this: it costs 460,800 B and addresses tearing, which
      is a different symptom with a different cause. */
  /*! [B662] ARM 5 -- THE VENDOR'S BUILD HAS NO BOUNCE BUFFER AT ALL, AND OURS HAS 9,600 PX.
      `Arduino_ESP32RGBPanel` defaults `bounce_buffer_size_px` to 0, and the 2023-era library the
      vendor demo was built against did not expose the parameter at all -- so their panel scans
      straight out of PSRAM.  This is the last configuration difference known between us and any
      driver of this board that works, and it is the one that sits ON THE PIXEL PATH: with a bounce
      buffer the DMA stages lines into internal RAM first, without one the peripheral fetches from
      PSRAM directly.

      EXPECT THE ROLL TO COME BACK, AND THAT IS NOT A FAILED ARM.  The block at line ~731 records
      that raising this value is the first lever against scan desync, because a starved RGB DMA
      makes the peripheral emit dummy bytes and the panel's read address never re-aligns.  Setting
      it to 0 removes that margin deliberately.  If the edge artefact is unchanged AND the display
      rolls, the answer is still informative: the pixel path is not where the artefact comes from,
      and the value goes straight back up.  Read the EDGE ROWS, not the alignment. */
  //! [B662] ARM 5 RESULT: NULL FOR THE ARTEFACT, POSITIVE FOR INSTABILITY -- REVERTED.
  //! Setting this to 0 (the vendor's default, and not even a parameter in the library their demo
  //! was built against) left the edge column exactly as it was AND made the display flicker, with
  //! a red stripe walking left to right across the glass.  That is the scan desync this value
  //! exists to prevent, observed directly rather than argued from: with no bounce buffer the RGB
  //! DMA fetches straight from PSRAM, starves, and the peripheral emits dummy bytes.
  //! So the 9,600 px is LOAD-BEARING for stability and irrelevant to the artefact, and the block
  //! above is right that raising it is the first lever against desync.  Do not set it to 0 again
  //! expecting the artefact to move; it does not.
  /*! [B662] ARM 6 -- RAISE IT.  Dose-response on the one knob that touches the FETCH PATH.
      Arm 5 set this to 0 (the vendor's default, and not a parameter at all in the library their
      demo was built against).  Measured on the glass: THE COLUMN WAS THE SAME WIDTH, and what
      changed instead was FLICKER -- minimal on the top row and worse on every row below it.  That
      progressive-down-the-frame signature is DMA starvation accumulating within a frame, and it is
      what this buffer exists to prevent.  So the bounce buffer governs STABILITY and, at 0 vs
      W*20, does not govern the artefact.

      W*40 asks whether MORE margin moves it, which 0 -> W*20 did not.  A null here closes the
      fetch-path class the same way arm 3 closed the ST7701 command interface: not one setting
      ruled out, but a whole mechanism.

      SIZE RISK, STATED BECAUSE IT DECIDES THE FALLBACK.  The IDF allocates TWO bounce buffers of
      this size in INTERNAL DRAM: W*40 = 19,200 px = 38,400 B each, so 76,800 B against the ~114 KB
      free measured on this board tonight.  It should fit and it is not comfortable.  If
      `esp_lcd_new_rgb_panel` fails, the log a few lines below says so and the answer is W*32 --
      DO NOT read an allocation failure as a null result. */
  //! [B662] ARMS 5 AND 6 BRACKET THIS VALUE AND NEITHER MOVED THE ARTEFACT.  0 -> the display
  //! flickers, worse on each row down the frame (DMA starvation accumulating within a frame);
  //! W*40 -> no flicker, column unchanged, and 38 KB of internal DRAM gone (114 KB free -> 76 KB,
  //! measured).  W*20 is stable and costs half of that, so it stands.  Raising it is still the
  //! first lever against DESYNC, as the block above says -- it is simply not a lever on the edge
  //! artefact, and spending internal DRAM here to chase that is spending it for nothing.
  cfg.bounce_buffer_size_px = AIT_W * 20;   //!< [B662] MEASURED, do not raise: W*32 leaves only 16 KB internal DRAM free with the HUD up and flickers WORSE, W*40 fails to allocate outright (init false, blank screen). Bigger is not better here.
  cfg.de_gpio_num        = AIT_DE;
  cfg.pclk_gpio_num      = AIT_PCLK;
  cfg.vsync_gpio_num     = AIT_VSYNC;
  cfg.hsync_gpio_num     = AIT_HSYNC;
  cfg.disp_gpio_num      = -1;             //!< no DISP pin on this board
  for (int i = 0; i < 16; i++) cfg.data_gpio_nums[i] = ait_data_gpios[i];
  cfg.timings.pclk_hz           = AIT_PCLK_HZ;
  cfg.timings.h_res             = AIT_W;
  cfg.timings.v_res             = AIT_H;
  cfg.timings.hsync_front_porch = AIT_HSYNC_FP;
  cfg.timings.hsync_pulse_width = AIT_HSYNC_PW;
  cfg.timings.hsync_back_porch  = AIT_HSYNC_BP;
  cfg.timings.vsync_front_porch = AIT_VSYNC_FP;
  cfg.timings.vsync_pulse_width = AIT_VSYNC_PW;
  cfg.timings.vsync_back_porch  = AIT_VSYNC_BP;
  /*! [B662] ARM 4 -- WE LATCH ON THE OPPOSITE PCLK EDGE FROM EVERY OTHER DRIVER OF THIS BOARD.
      This was 1.  The manufacturer's demo does not set it at all, and the library it is built
      against (`Arduino_ESP32RGBPanel`) defaults `pclk_active_neg` to 0 -- so their panel samples
      on the other edge from ours.  ESPHome's independent config for this exact board says the
      same thing in its own words: `pclk_inverted: False`.
      It moves the sampling instant by HALF A PIXEL CLOCK, 31 ns at 16 MHz, which is the right
      order for a one-pixel artefact at a data transition -- and it is untouched by arms 1-3
      (pixel clock, drive strength, init registers), all of which were null. */
  //! [B662] ARM 4 RESULT: NULL, and REVERTED to 1 here.  Flipping to the vendor's default 0 --
  //! the edge their demo and ESPHome both use -- changed the artefact in no row.  Reverted rather
  //! than left at 0 so that later arms are single changes from the configuration this board has
  //! actually run for months, not from an untested one that merely happens to be equivalent.
  cfg.timings.flags.pclk_active_neg = 1;
  cfg.flags.fb_in_psram  = 1;              //!< 460,800 B will not fit internal DRAM

  //! [B662] Hand the reservation back so THIS allocation lands in the hole the installer held.
  //! Releasing later, or not at all, would leave the panel allocating from a pool LambLisp has
  //! already picked over -- which is the state this whole reservation exists to prevent.
  ll_fastram_release("panel-scan");            //!< the bounce buffers land in THIS hole
  esp_err_t err = esp_lcd_new_rgb_panel(&cfg, &ait_panel);
  if (err != ESP_OK) {
    lamb.log("ST7701S: esp_lcd_new_rgb_panel failed (%s)\n", ascii.dec((LL_int32) err));
    ait_panel = 0;
    res = false;
  }
  if (res && esp_lcd_panel_init(ait_panel) != ESP_OK) {
    lamb.log("ST7701S: esp_lcd_panel_init failed\n");
    res = false;
  }
  /*! DATA-BUS DRIVE STRENGTH, SET AFTER THE PERIPHERAL HAS CLAIMED THE PINS -- [B662] ARM 2.
      `esp_lcd_new_rgb_panel` configures these GPIOs itself, so anything set BEFORE it is
      overwritten and the change reads as having no effect.  It must come after panel init.

      WHY WEAKER AND NOT STRONGER, which is the counter-intuitive half.  The edge artefact on this
      panel is one pixel wide and sits at data TRANSITIONS.  An earlier model of it -- red arriving
      late -- pointed at RAISING drive to speed the edge up; that model is dead ([B662], refuted by
      a fringe BRIGHTER than both its neighbours, which a late arrival cannot produce).  What
      survives is consistent with overshoot or crosstalk, and both get WORSE with a faster edge.
      So this arm goes down, not up.

      IT IS A NAMED CONSTANT BECAUSE IT IS AN EXPERIMENT.  The previous arm (PCLK 16 -> 12 MHz)
      changed the artefact not at all, which ruled out settling TIME; this one changes edge RATE,
      which is the other axis and is invariant under a clock-period change.  If it also does
      nothing, the next reader should not have to rediscover which knobs have been turned:
      both are recorded in [B662] with their results. */
  if (res) {
    for (int i = 0; i < 16; i++)
      gpio_set_drive_capability((gpio_num_t) ait_data_gpios[i], AIT_DATA_DRIVE);
    lamb.log("ST7701S: data-bus drive capability set to %s [B662 arm 2]\n",
             ascii.dec((LL_int32) AIT_DATA_DRIVE));
  }
  if (res) {
    void *fb0 = 0;
    if (esp_lcd_rgb_panel_get_frame_buffer(ait_panel, 1, &fb0) != ESP_OK || !fb0) {
      lamb.log("ST7701S: no framebuffer returned\n");
      res = false;
    }
    else ait_fb = (uint16_t *) fb0;
  }
  if (res) {
    ait_fill(lamb, 0, 0, AIT_W, AIT_H, 0x0000);   //!< black before the backlight comes up
    ait_set_brightness(lamb, 100);
    /*! RE-SYNC THE SCAN ONCE, HERE, BECAUSE BRINGING THE PANEL UP IS ITSELF A STARVING EVENT.
        If the RGB DMA is ever starved, the peripheral emits dummy bytes to hold its output timing,
        and those bytes desynchronise the panel's READ address from its OUTPUT address.  The picture
        is then permanently displaced -- rows appear shifted, with what runs off one edge wrapped
        round to the other -- and it STAYS that way, because nothing in the ordinary refresh path
        re-aligns it.
        MEASURED: the displacement was present on EVERY cold boot, survived power cycles, reflashes
        and a fresh application start, and one restart cleared it completely.  A fault that arrives
        identically on every boot is not an occasional contention event -- it happens during this
        initialisation, while the framebuffer is being allocated and first filled and the scan has
        just started.
        WHY IT MISLEADS: the framebuffer is CORRECT throughout, so every check made from the CPU side
        agrees that the data is right, and the fault looks like a drawing bug.  Confirmed by sampling
        the same pixels repeatedly while the display was visibly wrong -- six reads over 24 seconds,
        bit-identical.  The memory was never the problem; the scan had lost its place.
        The call is deferred by the driver to the next VSYNC, so the picture snaps back at a frame
        boundary instead of tearing further. */
    esp_lcd_rgb_panel_restart(ait_panel);
    lamb.log("ST7701S 480x480 RGB up: %s Hz pclk, fb in PSRAM\n", ascii.dec((LL_int32) AIT_PCLK_HZ));
  }
  return res;                                     //!< SINGLE EXIT
}

/*! The board's panel record.  `blit` is NULL because this is a SCAN panel -- there is
    no bus transaction to make.  A caller that wants pixels on screen takes fb() and
    stores into it, which is exactly what P123 Part G's camera rectangle needs and why
    `ll_panel_blit_rgb565` can serve both models from one call. */
static const LL_Panel ll_panel_st7701_aitrip = {
  "st7701s-480x480-par16",
  AIT_W, AIT_H,
  LL_PANEL_SCAN,
  ait_init,
  ait_fill,
  0,                          //!< blit: SCAN panel, there is no bus to push to
  ait_framebuffer,
  ait_set_brightness,
  ait_on_off
};
#endif  // LL_PANEL_ST7701_AITRIP

// ===========================================================================
// Generic: the `lcd-*` mops.  These name no controller and no bus.
// ===========================================================================
#if LL_PANEL

/*! (lcd-init [DEGREES]) -> #t / #f.  Bring up the board's panel.  Idempotent.

    DEGREES is 0 (default) or 180, applied as a MADCTL substitution -- see the note at
    `ait_send_init`.  90 and 270 are REFUSED rather than approximated, because they need MADCTL's
    MV bit and neither the framebuffer stride nor LVGL's width/height follow it; the result would
    be a scrambled image from a call that reported success.

    THE ROTATION ONLY TAKES EFFECT ON A PANEL THAT IS NOT ALREADY UP, because this is idempotent
    and the init sequence is where MADCTL is sent.  That is worth stating plainly: calling
    `(lcd-init 180)` on a running panel returns #t and changes NOTHING, which is exactly the shape
    of bug this tree keeps finding -- an operation that did nothing reporting the same success as
    one that worked.  Set it on the first call, or reboot. */
Sexpr_t mop3_lcd_init(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_init()");
  ll_try {
    const LL_Panel *p = ll_panel_active();
    if (!p) return HASHF;                       //!< no panel on this board: say so, do not pretend
    if (sexpr != NIL) {
      const LL_int32 deg = lamb.car(sexpr)->mustbe_int32();
            if (deg != 0 && deg != 180) {
        lamb.log("[panel] lcd-init: rotation %s unsupported -- only 0 and 180; leaving at %s\n",
                 ascii.dec(deg), AsciiConverter().dec((LL_int32) ll_ait_rotation_deg));
        return HASHF;                           //!< refuse loudly; do NOT silently use 0
      }
      if (ll_panel_ready() && (int) deg != ll_ait_rotation_deg)
        lamb.log("[panel] lcd-init: panel already up -- rotation %s NOT applied, reboot to change\n",
                 ascii.dec(deg));
      ll_ait_rotation_deg = (int) deg;
    }
    if (!ll_panel_ready()) ll_panel_inited = p->init ? p->init(lamb) : false;
    lamb.log("[panel] %s %dx%d %s -> %s\n", p->name, p->w, p->h,
             (p->model == LL_PANEL_PUSH) ? "push" : "scan",
             ll_panel_inited ? "ready" : "FAILED");
    return ll_panel_inited ? HASHT : HASHF;
  }
  ll_catch();
}

/*! (lcd-backlight [percent]) -> #t / #f.  Set brightness 0..100 (default 100).
    RETURNS #f WHEN THE PANEL HAS NO BRIGHTNESS CONTROL, and that return value is the
    whole point of the interface: an AMOLED has no backlight, some panels have no
    control at all, and the alternative -- a function that accepts the call and does
    nothing -- is indistinguishable from a working one.  P231 names this as the
    argument for phase 0 in one line. */
Sexpr_t mop3_lcd_backlight(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_backlight()");
  ll_try {
    const LL_Panel *p = ll_panel_active();
    if (!p || !p->set_brightness) return HASHF;
    int pct = 100;
    if (sexpr != NIL) {
      Sexpr_t a = lamb.car(sexpr);
      if (a->is_any_int())       pct = (int) a->as_int32();
      else if (a->is_any_real()) pct = (int) a->as_float32();
    }
    p->set_brightness(lamb, pct);
    return HASHT;
  }
  ll_catch();
}

//! (lcd-clear [rgb565]) -> void.  Clear the whole panel (default black).
/*! (lcd-restart) -> #t/#f.  Restart the RGB scan-out DMA.

    THE DEFECT THIS EXISTS FOR: if the DMA is ever starved -- by PSRAM contention, a flash access, or
    any other bus master -- the LCD peripheral emits dummy bytes to keep its output timing.  Those
    bytes desynchronise the panel's read address from its output address, and the result is a
    PERMANENTLY SHIFTED image: the picture scrolls up or sideways and STAYS there, because nothing in
    the normal refresh path ever re-aligns it.

    WHY IT LOOKS LIKE A SOFTWARE BUG AND IS NOT.  The framebuffer is still perfectly correct -- it is
    the SCAN that has lost its place -- so every check you can make from the CPU side says the data is
    right, and the obvious conclusion (that the drawing code is at fault) is wrong.  Verified here by
    sampling the same framebuffer pixels repeatedly while the glass was visibly wrong: six reads over
    24 seconds, bit-identical, while the display showed a rolled frame.

    The restart is deferred, not immediate: the driver sets a flag and does the work in the next VSYNC
    handler, so the picture snaps back at a frame boundary rather than tearing further. */
Sexpr_t mop3_lcd_restart(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_restart()");
  ll_try {
    Sexpr_t res = HASHF;
    /*! THE BODY IS GUARDED, THE MOP IS NOT.  `ait_panel` and `esp_lcd_rgb_panel_restart` both live
        inside `#if LL_PANEL_ST7701_AITRIP`, so referring to them from out here is a SCOPE error on
        every board that does not define that panel -- and a scope error is not something the gate
        can save, because the compiler still parses this text with the block elided.  A build on the
        panel board cannot expose it: there the guard is 1 and everything resolves.
        The mop stays REGISTERED on every target on purpose, so a caller on a non-panel board gets a
        message saying why rather than an unbound symbol. */
#if LL_PANEL_ST7701_AITRIP
    if (!ait_panel) {
      lamb.log("lcd-restart: RGB panel not initialised -- call (lcd-init) first\n");
    }
    else {
      const esp_err_t rc = esp_lcd_rgb_panel_restart(ait_panel);
      if (rc != ESP_OK) lamb.log("lcd-restart: refused, rc %s\n", ascii.dec((LL_int32) rc));
      else              res = HASHT;
    }
#else
    lamb.log("lcd-restart: no RGB scan panel on this target -- nothing to re-sync\n");
#endif
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

Sexpr_t mop3_lcd_clear(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_clear()");
  ll_try {
    const LL_Panel *p = ll_panel_active();
    if (!p) return OBJ_VOID;
    uint16_t color = (sexpr != NIL) ? (uint16_t) lamb.car(sexpr)->mustbe_int32() : 0;
    ll_panel_fill_rect(lamb, 0, 0, p->w, p->h, color);
    return OBJ_VOID;
  }
  ll_catch();
}

//! (lcd-box x y w h rgb565) -> void.  Draw a filled rectangle.
Sexpr_t mop3_lcd_box(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_box()");
  ll_try {
    int      x = lamb.car(sexpr)->mustbe_int32();
    int      y = lamb.cadr(sexpr)->mustbe_int32();
    int      w = lamb.caddr(sexpr)->mustbe_int32();
    int      h = lamb.cadddr(sexpr)->mustbe_int32();
    uint16_t c = (uint16_t) lamb.car(lamb.cddddr(sexpr))->mustbe_int32();
    ll_panel_fill_rect(lamb, x, y, w, h, c);
    return OBJ_VOID;
  }
  ll_catch();
}

/*! (lcd-cmd CMD BYTE ...) -> #t / #f.  Send one raw command to the ST7701S over its 3-wire SPI.
    [B662] EXISTS SO A REGISTER QUESTION COSTS A REPL LINE INSTEAD OF A BUILD AND A FLASH.
    Six arms of this investigation each cost a full rebuild, a Jetson sync and a reflash -- twenty
    minutes apiece -- to change one byte.  Registers are exactly the thing worth sweeping, and a
    sweep at twenty minutes a value does not happen.  With this, the panel's entire register map is
    reachable from the TCP REPL while a test pattern is on the glass.

    IT IS A LOADED GUN AND THAT IS THE POINT.  There is no validation of the command, the data
    length, or the bank you happen to be in -- the caller is expected to know the ST7701S map, and
    writing the wrong register can leave the panel dark, scrambled, or drawing more current than it
    should.  `(lcd-init 180)` puts it back; a power cycle certainly does.  Do not wire this into
    anything that runs unattended.

    BANK SWITCHING IS THE CALLER'S JOB.  The ST7701S multiplexes its register space: bank 0 is the
    display/gamma set and bank 1 holds power and source-drive timing, selected by
    `(lcd-cmd #xFF #x77 #x01 #x00 #x00 #x10)` and `... #x11` respectively.  A write to a bank-1
    register while bank 0 is selected lands on a DIFFERENT REGISTER and usually does something
    visible, which reads as the register having an effect it does not have. */
Sexpr_t mop3_lcd_cmd(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_cmd()");
  ll_try {
    Sexpr_t res = HASHF;
#if LL_PANEL_ST7701_AITRIP
    if (sexpr == NIL) { lamb.log("lcd-cmd: needs at least a command byte\n"); }
    else {
      uint8_t cmd = (uint8_t) lamb.car(sexpr)->mustbe_int32();
      gpio_set_level((gpio_num_t) AIT_SPI_CS, 0);
      ait_spi9(false, cmd);
      LL_int32 n = 0;
      for (Sexpr_t p = lamb.cdr(sexpr); p != NIL; p = lamb.cdr(p)) {
        ait_spi9(true, (uint8_t) lamb.car(p)->mustbe_int32());
        n++;
      }
      gpio_set_level((gpio_num_t) AIT_SPI_CS, 1);
      AsciiConverter a1, a2;
      lamb.log("lcd-cmd: sent %s with %s data byte(s)\n", a1.hex(cmd), a2.dec(n));
      res = HASHT;
    }
#else
    lamb.log("lcd-cmd: no ST7701S panel on this target\n");
#endif
    return res;                                //!< SINGLE EXIT
  }
  ll_catch();
}

//! (lcd-rgb565! bvec x y w h) -> void.  Blit a big-endian RGB565 region to the panel.
Sexpr_t mop3_lcd_rgb565(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_rgb565()");
  ll_try {
    if (!ll_panel_ready()) return OBJ_VOID;
    Sexpr_t bv = lamb.car(sexpr);
    int     x  = lamb.cadr(sexpr)->mustbe_int32();
    int     y  = lamb.caddr(sexpr)->mustbe_int32();
    int     w  = lamb.cadddr(sexpr)->mustbe_int32();
    int     h  = lamb.car(lamb.cddddr(sexpr))->mustbe_int32();
    LL_int32  nbytes;
    ByteVec_t elems;
    bv->any_bvec_get_info(nbytes, elems);
    if (nbytes < (LL_int32)(w * h * (int) sizeof(uint16_t))) return OBJ_VOID;   // short buffer: skip
    ll_panel_blit_rgb565(lamb, x, y, w, h, (const uint16_t *) elems);
    return OBJ_VOID;
  }
  ll_catch();
}

/*! (lcd-testpat) -> #t.  Blit a KNOWN pattern through the SAME path a camera frame takes,
    so a blank screen can be attributed to the panel rather than to the source.  Four zones:
      top quarter    : vertical colour bars   (R G B W x2)  -- X-varying solid data
      second quarter : horizontal colour bars (R G B W)     -- Y-varying solid data
      third quarter  : smooth grayscale ramp  (black->white L->R)
      bottom quarter : fine 2px vertical black/white stripes -- high-frequency detail
    Sized from the ACTIVE PANEL rather than a 240x240 #define, so it is a real test on a
    410x502 or 480x480 panel instead of a patch in one corner. */
Sexpr_t mop3_lcd_testpat(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_testpat()");
  ll_try {
    Sexpr_t res = HASHF;
    const LL_Panel *p = ll_panel_active();
    if (ll_panel_ready() && p) {
      const int W = p->w, H = p->h;
      static uint16_t *pat = 0;
      static int       patw = 0, path = 0;
      if (pat && (patw != W || path != H)) { free(pat); pat = 0; }   //!< geometry changed: re-make
      if (!pat) {
        pat = (uint16_t *) ll_panel_alloc_pattern((size_t) W * H * sizeof(uint16_t));
        patw = W; path = H;
      }
      if (pat) {
        static const uint16_t bars[4] = { 0xF800, 0x07E0, 0x001F, 0xFFFF };  // R G B W (native RGB565)
        for (int y = 0; y < H; y++) {
          for (int x = 0; x < W; x++) {
            uint16_t c;
            if      (y < H/4)   c = bars[(x * 8 / W) & 3];                   // vertical bars
            else if (y < H/2)   c = bars[((y - H/4) * 4 / (H/4 ? H/4 : 1)) & 3];  // horizontal bars
            else if (y < 3*H/4) { int g = x * 31 / (W - 1);                  // grayscale ramp
                                  c = (uint16_t) ((g << 11) | ((2 * g) << 5) | g); }
            else                c = ((x / 2) & 1) ? 0xFFFF : 0x0000;         // fine 2px stripes
            pat[y * W + x] = (uint16_t) ((c >> 8) | (c << 8));               // big-endian: the blit swaps back
          }
        }
        ll_panel_blit_rgb565(lamb, 0, 0, W, H, pat);
        res = HASHT;
      }
    }
    return res;                    //!< SINGLE EXIT -- see CLAUDE.md; nothing below may be skipped
  }
  ll_catch();
}
#endif  // LL_PANEL

/*! Installer.  Defined UNCONDITIONALLY so main.cpp's table needs no #if -- on a board
    with no panel it binds nothing, which is the correct outcome and leaves `lcd-*`
    unbound rather than stubbed. */
/*! [B662] THE PUBLIC WRITEBACK -- DEFINED OUTSIDE EVERY PANEL GATE, ON PURPOSE.
    Every writer of a scanned framebuffer calls this: `ll_panel_blit_rgb565` stores camera
    thumbnails, and LVGL's flush callback copies every widget and every camera frame.  Those calls
    are UNGATED because the writers are, so the definition must be too.

    [B725] IT WAS NOT, AND IT BROKE A BOARD THAT HAS NOTHING TO DO WITH THIS WORK.  The declaration
    at the top of this file and the call in `ll_panel_blit_rgb565` were both outside any `#if`,
    while this definition sat INSIDE `#if LL_PANEL_ST7701_AITRIP` -- so `esp32-s3-eye`, which
    builds with `LL_PANEL_ST7789_EYE`, compiled the call and linked against nothing:

        ld: undefined reference to `ll_panel_fb_writeback(int, int)'

    The `#else` arm below was already written and was UNREACHABLE, which is the trap: the comment
    said "a no-op on any panel that is not the AITRIP" and the code could not deliver it.  A
    conditional that cannot be reached reads exactly like one that can.

    AND THE PRE-PUSH GATE COULD NOT HAVE CAUGHT IT: it compiles `esp32s3-n8r2`, which carries NO
    panel flags at all, so no panel code path is reachable from the one env that is checked. */
void ll_panel_fb_writeback(int y, int h)
{
#if LL_PANEL_ST7701_AITRIP
  extern Lamb *ll_lamb_singleton_for_lvgl(void);
  Lamb *l = ll_lamb_singleton_for_lvgl();
  if (l) ait_fb_writeback(*l, y, h);
#else
  //! A PUSH panel's pixels travel over a bus and were never subject to cache coherency.
  (void) y; (void) h;
#endif
}

Sexpr_t Panel_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Panel_install_mop3()");
  ll_try {
    Sexpr_t env_target = lamb.car(sexpr);
    (void) env_target;
#if LL_PANEL
    #if LL_PANEL_ST7789_EYE
      ll_panel_register(&ll_panel_st7789_eye);
    #endif
    #if LL_PANEL_ST7701_AITRIP
      ll_panel_register(&ll_panel_st7701_aitrip);
      /*! [B662] THE DISPLAY IS A REQUIRED CONSUMER AND MUST BE AHEAD OF LAMBLISP IN THE INTERNAL
          DRAM QUEUE.  P211 established "system first, LambLisp from the remainder" and wired the
          RADIO into it -- the display was never entered, because the panel comes up LATER, on
          `lcd-init`, by which time `ll_ncg_exec_pool_claim_late()` (main.cpp:294) has already
          taken its 32 KB and the .scm load phase has taken the rest.

          So the panel reserves here, at INSTALL time, while the pool is still whole: the scan's
          bounce buffers (2 x W*20 px) plus LVGL's draw buffer.  `ait_init` releases it immediately
          before `esp_lcd_new_rgb_panel`, so the real allocation lands in the hole, and
          `ll_fastram_release_unclaimed()` at the end of boot gives it back on any board that never
          starts a panel -- which is every board in this fleet but one.

          Best-effort by design, like every other reservation here: a board that cannot meet it
          simply allocates as it does today. */
      /*! ONE RESERVATION PER CONSUMER, NOT ONE PER SUBSYSTEM.  The first version of this asked for
          bounce+draw as a SINGLE 84,480-byte block and was refused outright -- the largest
          contiguous block at install time is 71,668, so the display got no priority at all and
          LVGL's draw buffer scraped 12 lines from what was left.  Measured:
              [fastram] panel reserve 84480 FAILED -- consumer will allocate unordered (largest 71668)
          Two consumers allocate at DIFFERENT MOMENTS (the scan's bounce buffers at
          `esp_lcd_new_rgb_panel`, LVGL's draw buffer later at `lv_display_set_buffers`), so they
          need two reservations released at two points.  Bundling them also guarantees the larger
          total is the one tested against fragmentation, which is the worst of both. */
      {
        const size_t bounce = (size_t) AIT_W * 20u * 2u * 2u;         //!< two bounce buffers
        /*! 24 LINES, NOT 48, AND THE NUMBER IS MEASURED RATHER THAN CHOSEN.
            There is ~71 KB contiguous at install time and the scan's bounce buffers take 38,400 of
            it, so a 48-line (46,080 B) draw reservation CANNOT fit and was refused:
                [fastram] panel-draw reserve 46080 FAILED -- ... (largest 32756)
            24 lines fits, and 24 lines is the size at which the flicker stopped on the glass.
            Asking for what fits makes the outcome deterministic; asking for 48 left the allocator's
            shrink loop to discover the same answer by failing, which works and reports a scarier
            ledger than the situation deserves. */
        const size_t draw   = (size_t) AIT_W * (AIT_H / 20u) * 2u;    //!< LVGL, 24 lines
        //! PINNED: this board is compiled WITH a panel, so the display is a REQUIRED consumer and
        //! the sweep must not take its memory back.  It starts from the app-loop's first tick,
        //! which is AFTER `ll_fastram_release_unclaimed()` -- measured, the reservations were swept
        //! as "subsystem never started" moments before the subsystem started.
        ll_fastram_reserve_pinned("panel-scan", bounce);
        ll_fastram_reserve_pinned("panel-draw", draw);
      }
    #endif
    static const struct { Lamb::Mop3st_t func; const char *name; } panel_procs[] = {
      { mop3_lcd_init,      "lcd-init"      },
      { mop3_lcd_backlight, "lcd-backlight" },
      { mop3_lcd_clear,     "lcd-clear"     },
      { mop3_lcd_restart,   "lcd-restart"   },
      { mop3_lcd_box,       "lcd-box"       },
      { mop3_lcd_cmd,       "lcd-cmd"       },
      { mop3_lcd_rgb565,    "lcd-rgb565!"   },
      { mop3_lcd_testpat,   "lcd-testpat"   },
    };
    const int Npanel_procs = sizeof(panel_procs)/sizeof(panel_procs[0]);
    lamb.log("%s defining %d Mops (panel %s)\n", me, Npanel_procs,
             ll_panel_active() ? ll_panel_active()->name : "none");
    for (int i = 0; i < Npanel_procs; i++) {
      const auto &p = panel_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#endif
    return NIL;
  }
  ll_catch();
}

//! @}
