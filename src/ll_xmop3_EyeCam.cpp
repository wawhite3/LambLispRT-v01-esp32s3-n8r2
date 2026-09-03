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


#if LL_CAMERA

#include "esp_camera.h"                 // OV2640 driver: camera_config_t, esp_camera_*
#include "driver/spi_master.h"          // spi_bus_initialize, SPI3_HOST, SPI_DMA_CH_AUTO
#include "esp_lcd_panel_io.h"           // esp_lcd_panel_io_spi_config_t, new_panel_io_spi
#include "esp_lcd_panel_vendor.h"       // esp_lcd_panel_dev_config_t, new_panel_st7789
#include "esp_lcd_panel_ops.h"          // reset/init/draw_bitmap/invert/disp_on_off
#include "driver/ledc.h"                // LEDC PWM -- backlight brightness (ACTIVE-LOW panel)
#include "driver/gpio.h"                // gpio_reset_pin -- free DC/CS from the UART0 console
#include "esp_heap_caps.h"              // heap_caps_malloc -- DMA-capable draw buffers (not PSRAM)
//! @defgroup xmop3_camera Camera (ESP32-S3-EYE)
//! @ingroup xmop3
//! @brief LambLisp Camera (ESP32-S3-EYE) builtins.
//! @{

// --- LCD: ST7789 240x240 IPS on SPI3 ---
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
                                                //!< internal-DMA line buffer barely fits, so keep the LCD minimal

// Reserve the camera's internal-DMA hole + LCD band at INSTALL time (before setup.scm reads the boot
// .scm files from flash)?  OFF for the current eye mission: the camera preview is disabled (no-op
// app-loop, eye-cam.scm malformed, B87), so the camera is never initialized and the early reservation
// only STARVES the boot-time LittleFS reads -- it drops the largest free MALLOC_CAP_DMA block to ~16 KB,
// after which .scm block reads intermittently fail with err 257 (ESP_ERR_NO_MEM) and return GARBAGE,
// corrupting whichever file hits the starved read (llip-serial.scm -> `llt` Unbound; WS2812.scm -> parse
// garbage).  That is B88.  With this OFF, ~32 KB of internal DMA stays free through boot and the reads
// succeed.  The LCD band is still lazily reserved at lcd-init (row-halving fallback) and the camera hole
// just before esp_camera_init, so restoring camera preview (B87) needs this flipped back ON *and* a
// boot-read-safe reservation strategy (e.g. reserve only after the boot .scm loads finish).
#define EYE_CAM_EARLY_DMA_RESERVE 0

// --- Camera: OV2640 DVP ---
#define EYE_CAM_XCLK    15
#define EYE_CAM_SIOD     4             //!< SCCB SDA
#define EYE_CAM_SIOC     5             //!< SCCB SCL
#define EYE_CAM_VSYNC    6
#define EYE_CAM_HREF     7
#define EYE_CAM_PCLK    13
#define EYE_CAM_D0      11
#define EYE_CAM_D1       9
#define EYE_CAM_D2       8
#define EYE_CAM_D3      10
#define EYE_CAM_D4      12
#define EYE_CAM_D5      18
#define EYE_CAM_D6      17
#define EYE_CAM_D7      16

static esp_lcd_panel_io_handle_t  ll_lcd_io    = 0;      //!< SPI panel-IO handle
static esp_lcd_panel_handle_t     ll_lcd_panel = 0;      //!< ST7789 panel handle
static bool                       ll_lcd_ok    = false;  //!< true once the panel is initialised
static bool                       ll_cam_ok    = false;  //!< true once the sensor is initialised
static bool                       ll_eyecam_trace = false; //!< per-frame camera->lcd tracing -- OFF: the
                                                           //!< app-loop calls camera->lcd every tick, so a
                                                           //!< log there floods the shared serial line and
                                                           //!< buries REPL and test output (2026-08-29).
static pixformat_t                ll_cam_fmt   = PIXFORMAT_RGB565;  //!< current camera pixel format
static void                      *ll_cam_dma_hole = 0; //!< contiguous internal-DMA block reserved early, freed just before esp_camera_init
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

// ---------------------------------------------------------------------------
// LCD (esp_lcd + ST7789)
// ---------------------------------------------------------------------------

//! Set the LCD backlight brightness (0..100 %).  On the ESP32-S3-EYE the backlight is
//! ACTIVE-LOW and PWM-driven: LEDC duty 0 = full brightness, duty 1023 = off (verified
//! against the Espressif esp-bsp bsp_display_brightness_set).  A plain digitalWrite(HIGH)
//! is therefore the DARKEST setting -- the cause of the black screen.  A dedicated timer
//! and channel keep this off the camera's LEDC_TIMER_0/LEDC_CHANNEL_0 (used for XCLK).
static void ll_lcd_backlight_set(Lamb &lamb, int percent)
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

//! (lcd-init) -> #t.  Bring up SPI3, the ST7789 panel and the backlight.
Sexpr_t mop3_lcd_init(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_init()");
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
        lamb.log("[eyecam] LCD band buffer: %d rows @ %p (internal-DMA free now %d)\n",
                 ll_lcd_band_rows, (void *) ll_lcd_band,
                 (int) heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA));
      }
      ll_lcd_ok = true;
    }
    // Backlight full on (active-low LEDC -- see ll_lcd_backlight_set).
    ll_lcd_backlight_set(lamb, 100);
    return HASHT;
  }
  ll_catch();
}

//! Fill an axis-aligned rectangle with one RGB565 colour, one scanline at a time
//! (a single small DMA buffer, so a full-screen clear costs only ~480 bytes).
static void ll_lcd_fill_rect(Lamb &lamb, int x, int y, int w, int h, uint16_t color)
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
static void ll_lcd_blit_rgb565(Lamb &lamb, int x, int y, int w, int h, const uint16_t *src)
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

//! (lcd-clear [rgb565]) -> void.  Clear the whole screen (default black).
Sexpr_t mop3_lcd_clear(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_clear()");
  ll_try {
    uint16_t color = (sexpr != NIL) ? (uint16_t) lamb.car(sexpr)->mustbe_int32() : 0;
    ll_lcd_fill_rect(lamb, 0, 0, EYE_LCD_W, EYE_LCD_H, color);
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
    ll_lcd_fill_rect(lamb, x, y, w, h, c);
    return OBJ_VOID;
  }
  ll_catch();
}

//! (lcd-rgb565! bvec x y w h) -> void.  Blit a big-endian RGB565 region to the panel.
Sexpr_t mop3_lcd_rgb565(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_rgb565()");
  ll_try {
    if (!ll_lcd_ok) return OBJ_VOID;
    Sexpr_t bv = lamb.car(sexpr);
    int     x  = lamb.cadr(sexpr)->mustbe_int32();
    int     y  = lamb.caddr(sexpr)->mustbe_int32();
    int     w  = lamb.cadddr(sexpr)->mustbe_int32();
    int     h  = lamb.car(lamb.cddddr(sexpr))->mustbe_int32();
    LL_int32  nbytes;
    ByteVec_t elems;
    bv->any_bvec_get_info(nbytes, elems);
    if (nbytes < (LL_int32)(w * h * (int) sizeof(uint16_t))) return OBJ_VOID;   // short buffer: skip
    ll_lcd_blit_rgb565(lamb, x, y, w, h, (const uint16_t *) elems);
    return OBJ_VOID;
  }
  ll_catch();
}

// ---------------------------------------------------------------------------
// Camera (esp_camera + OV2640)
// ---------------------------------------------------------------------------

//! Build the OV2640 config for the given pixel format / frame size.
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
Sexpr_t mop3_camera_to_lcd(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_camera_to_lcd()");
  ll_try {
    if (!ll_cam_ok || !ll_lcd_ok) return HASHF;
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) return HASHF;
    const uint16_t *pp = (const uint16_t *) fb->buf;
    //! PER-FRAME DEBUG, OFF BY DEFAULT.  This logged unconditionally, and the eye's app-loop calls
    //! camera->lcd on EVERY tick once the live preview auto-starts -- ~20 lines/second onto the
    //! same serial line the REPL and every test harness read.  On 2026-08-29 it buried the gcpause
    //! output and the `--- done ---` sentinel under a wall of frame dumps, so a leg that had
    //! ALREADY failed for a different reason (the bench file was missing from the manifest) looked
    //! busy for 146 s instead of obviously broken.  A log inside a frame-rate path is a debugging
    //! aid, never shipped behaviour.
    if (ll_eyecam_trace)
      lamb.log("[eyecam] c2l fb w=%d h=%d len=%d fmt=%d  px0=%04x px1=%04x pxN/2=%04x pxEnd=%04x\n",
               (int) fb->width, (int) fb->height, (int) fb->len, (int) fb->format,
               pp[0], pp[1], pp[(fb->len/2)/2], pp[fb->len/2 - 1]);
    ll_lcd_blit_rgb565(lamb, 0, 0, fb->width, fb->height, pp);
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
    if (!ll_cam_ok || !ll_lcd_ok) return HASHF;
    LL_int32 n = (sexpr != NIL) ? lamb.car(sexpr)->mustbe_int32() : 300;
    for (LL_int32 i = 0; i < n; i++) {
      camera_fb_t *fb = esp_camera_fb_get();
      if (fb) {
        ll_lcd_blit_rgb565(lamb, 0, 0, fb->width, fb->height, (const uint16_t *) fb->buf);
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
Sexpr_t mop3_lcd_backlight(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_backlight()");
  ll_try {
    int pct = 100;
    if (sexpr != NIL) {
      Sexpr_t a = lamb.car(sexpr);
      if (a->is_any_int())       pct = (int) a->as_int32();
      else if (a->is_any_real()) pct = (int) a->as_float32();
    }
    ll_lcd_backlight_set(lamb, pct);
    return OBJ_VOID;
  }
  ll_catch();
}

//! (lcd-testpat) -> #t.  Blit a KNOWN 240x240 pattern through the SAME path as camera->lcd
//! (byte-swap + banded draw) -- nothing to do with the camera.  Four horizontal zones:
//!   rows   0- 59 : vertical colour bars   (R G B W x2)  -- X-varying solid data
//!   rows  60-119 : horizontal colour bars (R G B W)     -- Y-varying solid data
//!   rows 120-179 : smooth grayscale ramp  (black->white L->R)
//!   rows 180-239 : fine 2px vertical black/white stripes -- high-frequency detail
//! Whatever the panel shows per zone pinpoints the display-path corruption (I control every input pixel).
Sexpr_t mop3_lcd_testpat(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_lcd_testpat()");
  ll_try {
    if (!ll_lcd_ok) return HASHF;
    static uint16_t *pat = 0;
    if (!pat) pat = (uint16_t *) heap_caps_malloc((size_t) EYE_LCD_W * EYE_LCD_H * sizeof(uint16_t),
                                                  MALLOC_CAP_SPIRAM);
    if (!pat) return HASHF;
    static const uint16_t bars[4] = { 0xF800, 0x07E0, 0x001F, 0xFFFF };   // R G B W (native RGB565)
    for (int y = 0; y < EYE_LCD_H; y++) {
      for (int x = 0; x < EYE_LCD_W; x++) {
        uint16_t c;
        if      (y <  60) c = bars[(x * 8 / EYE_LCD_W) & 3];               // vertical bars
        else if (y < 120) c = bars[((y - 60) * 4 / 60) & 3];              // horizontal bars
        else if (y < 180) { int g = x * 31 / (EYE_LCD_W - 1);             // grayscale ramp
                            c = (uint16_t) ((g << 11) | ((2 * g) << 5) | g); }
        else              c = ((x / 2) & 1) ? 0xFFFF : 0x0000;            // fine 2px stripes
        pat[y * EYE_LCD_W + x] = (uint16_t) ((c >> 8) | (c << 8));        // big-endian: the blit swaps it back
      }
    }
    ll_lcd_blit_rgb565(lamb, 0, 0, EYE_LCD_W, EYE_LCD_H, pat);
    lamb.log("[eyecam] test pattern blitted\n");
    return HASHT;
  }
  ll_catch();
}

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
      { mop3_lcd_init,         "lcd-init"         },
      { mop3_lcd_backlight,    "lcd-backlight"    },
      { mop3_lcd_clear,        "lcd-clear"        },
      { mop3_lcd_box,          "lcd-box"          },
      { mop3_lcd_rgb565,       "lcd-rgb565!"      },
      { mop3_camera_init,      "camera-init"      },
      { mop3_camera_to_lcd,    "camera->lcd"      },
      { mop3_camera_preview,   "camera-preview"   },
      { mop3_camera_thumb,     "camera-thumb"     },
      { mop3_camera_set,       "camera-set"       },
      { mop3_camera_capture,   "camera-capture"   },
      { mop3_frame_brightness, "frame-brightness" },
      { mop3_lcd_testpat,      "lcd-testpat"      },
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
    // Reserve BOTH the LCD band buffer AND the camera hole NOW.  setup.scm's cell-heap
    // EXPANSION (startup needs >8192 cells -> a new internal block) also comes out of DMA-capable
    // RAM, so if we wait until lcd-init the band's heap_caps_malloc returns NULL and no draw shows
    // (blank white).  The band persists; the hole is freed into the camera at camera-init.
#if EYE_CAM_EARLY_DMA_RESERVE
    ll_lcd_band_rows = EYE_LCD_BAND_ROWS;
    ll_lcd_band = (uint16_t *) heap_caps_malloc((size_t) EYE_LCD_W * ll_lcd_band_rows * sizeof(uint16_t), MALLOC_CAP_DMA);
    ll_cam_dma_hole = heap_caps_malloc(24 * 1024, MALLOC_CAP_DMA);
    lamb.log("%s reserved LCD band %p (%d rows) + camera hole %p; largest free DMA now %d\n",
             me, (void *) ll_lcd_band, ll_lcd_band_rows, ll_cam_dma_hole,
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
