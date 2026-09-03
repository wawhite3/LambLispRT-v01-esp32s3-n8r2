// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"


#if LL_WS2812

#include "WS2812_ESP32.h"
//! @defgroup xmop3_ws2812 WS2812 / NeoPixel LEDs
//! @ingroup xmop3
//! @brief LambLisp WS2812 / NeoPixel LEDs builtins.
//! @{

//! Write a single NeoPixel directly: (neopixelWrite pin r g b).
Sexpr_t mop3_neopixelWrite(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_neopixelWrite()");
  ll_try {
    LL_int32 args[4];
    for (int i=0; i<4; i++) {
      Sexpr_t arg = lamb.car(sexpr);
      args[i]     = arg->mustbe_int32();
      sexpr       = lamb.cdr(sexpr);
    }
    neopixelWrite(args[0], args[1], args[2], args[3]);
    return OBJ_VOID;
  }
  ll_catch();
}

WS2812 *ws2812 = 0;

//! Initialize WS2812 strip: (WS2812.begin num-leds pin channel led-type).
Sexpr_t WS2812_mop3_begin(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  if (ws2812) { delete ws2812;  ws2812 = 0; }
  ws2812 = new WS2812(lamb.car(sexpr)->as_int32(),			//number of LEDs
		      lamb.cadr(sexpr)->as_int32(),			//LED pin
		      lamb.caddr(sexpr)->as_int32(),			//LED channel
		      (LED_TYPE) lamb.cadddr(sexpr)->mustbe_int32()	//LED type
		      );
  LL_int32 success = ws2812->begin();
  return lamb.mk_integer(success, env_exec);
}

//! Set global brightness scale (0--255) applied to all subsequent show() calls.
Sexpr_t WS2812_mop3_setBrightness(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  LL_int32 brightness = lamb.car(sexpr)->coerce_int32();
  ws2812->setBrightness(brightness);
  return OBJ_UNDEF;
}

//! Set LED color data: (WS2812.setLedColorData index rgb) or (... index r g b).
Sexpr_t WS2812_mop3_setLedColorData(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  LL_int32 index = lamb.car(sexpr)->coerce_int32();
  sexpr       = lamb.cdr(sexpr);
  LL_int32 val   = lamb.car(sexpr)->coerce_int32();

  LL_int32 ires = -1;
  if (lamb.cdr(sexpr) == NIL) ires = ws2812->setLedColorData(index, val);
  else {
    LL_int32 r = val;
    LL_int32 g = lamb.cadr(sexpr)->coerce_int32();
    LL_int32 b = lamb.caddr(sexpr)->coerce_int32();
    ires = ws2812->setLedColorData(index, r, g, b);
  }
  return lamb.mk_integer(ires, env_exec);
}

//! Map a wheel position (0--255) to an RGB packed integer cycling through the color wheel.
Sexpr_t WS2812_mop3_Wheel(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  LL_int32 wh   = lamb.car(sexpr)->mustbe_int32();
  LL_int32 ires = ws2812->Wheel(wh);
  return lamb.mk_integer(ires, env_exec);
}

//! Push the color buffer to the physical LED strip; returns 0 on success.
Sexpr_t WS2812_mop3_show(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  return lamb.mk_integer(ws2812->show(), env_exec);
}

#endif

Sexpr_t WS2812_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WS2812_install_mop3()");
  ll_try {
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } base_procs[] = {
      { WS2812_install_mop3, "WS2812-install-mop3", false },
    };
    const int Nbase_procs = sizeof(base_procs)/sizeof(base_procs[0]);
    for (int i = 0; i < Nbase_procs; i++) {
      const auto &p = base_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#if LL_WS2812
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } ws_procs[] = {
      { WS2812_mop3_begin,          "WS2812.begin",          false },
      { WS2812_mop3_setBrightness,  "WS2812.setBrightness",  false },
      { WS2812_mop3_Wheel,          "WS2812.Wheel",          false },
      { WS2812_mop3_setLedColorData,"WS2812.setLedColorData",false },
      { WS2812_mop3_show,           "WS2812.show",           false },
      { mop3_neopixelWrite,         "neopixelWrite",         false },
    };
    const int Nws_procs = sizeof(ws_procs)/sizeof(ws_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nws_procs);
    for (int i = 0; i < Nws_procs; i++) {
      const auto &p = ws_procs[i];
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
