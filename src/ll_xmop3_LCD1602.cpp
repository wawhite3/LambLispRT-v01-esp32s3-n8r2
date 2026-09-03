// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"


#if LL_LCD1602

#include "LiquidCrystal_I2C.h"
//! @defgroup xmop3_lcd1602 LCD1602 Character Display
//! @ingroup xmop3
//! @brief LambLisp LCD1602 Character Display builtins.
//! @{

typedef LiquidCrystal_I2C LCD1602;

LCD1602 *lcd1602 = 0;

//! Initialize the LCD1602 at the given I2C address with cols x rows dimensions.
Sexpr_t LCD1602_mop3_begin(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  LL_int32 addr = lamb.car(sexpr)->mustbe_int32();
  LL_int32 cols = lamb.cadr(sexpr)->mustbe_int32();
  LL_int32 rows = lamb.caddr(sexpr)->mustbe_int32();
  
  if (lcd1602) { delete lcd1602;  lcd1602 = 0; }
  lcd1602 = new LiquidCrystal_I2C(addr, cols, rows);
  //lcd1602->begin(cols, rows, LCD_5x8DOTS);
  lcd1602->init();
  lcd1602->backlight();
  lcd1602->setCursor(0, 0);
  return OBJ_UNDEF;
}

//! Clear the LCD display and return cursor to home.
Sexpr_t LCD1602_mop3_clear(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ lcd1602->clear();   return OBJ_UNDEF; }
//! Move cursor to the home position (0, 0).
Sexpr_t LCD1602_mop3_home(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ lcd1602->home();    return OBJ_UNDEF; }

//! Turn the display on or off; optional arg defaults to #t (on).
Sexpr_t LCD1602_mop3_display(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  Bool_t onoff = true;
  if (sexpr != NIL) onoff = lamb.car(sexpr) != HASHF;
  if (onoff) lcd1602->display(); else lcd1602->noDisplay();
  return OBJ_UNDEF;
}

//! Show or hide the cursor; optional arg defaults to #t (show).
Sexpr_t LCD1602_mop3_cursor(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  Bool_t onoff = true;
  if (sexpr != NIL) onoff = lamb.car(sexpr) != HASHF;
  if (onoff) lcd1602->cursor(); else lcd1602->noCursor();
  return OBJ_UNDEF;
}

//! Turn backlight on or off; optional arg defaults to #t (on).
Sexpr_t LCD1602_mop3_backlight(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  Bool_t onoff = true;
  if (sexpr != NIL) onoff = lamb.car(sexpr) != HASHF;
  if (onoff) lcd1602->backlight(); else lcd1602->noBacklight();
  return OBJ_UNDEF;
}

//! Write a string at the current cursor position.
Sexpr_t LCD1602_mop3_write(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  const char *s = lamb.car(sexpr)->mustbe_any_str_t()->any_str_get_chars();
  lcd1602->print(s);
  return OBJ_UNDEF;
}

//! Move cursor to (0,0) then write a string -- convenience for full-line refresh.
Sexpr_t LCD1602_mop3_print(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  const char *s = lamb.car(sexpr)->mustbe_any_str_t()->any_str_get_chars();
  lcd1602->setCursor(0, 0);
  lcd1602->print(s);
  return OBJ_UNDEF;
}

//! Move cursor to column col and row row (zero-based).
Sexpr_t LCD1602_mop3_setCursor(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  LL_int32 col = lamb.car(sexpr)->mustbe_int32();
  LL_int32 row = lamb.cadr(sexpr)->mustbe_int32();
  lcd1602->setCursor(col, row);
  return OBJ_UNDEF;
}

#endif

Sexpr_t LCD1602_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::LCD1602_install_mop3()");
  ll_try {
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } base_procs[] = {
      { LCD1602_install_mop3, "LCD1602-install-mop3", false },
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
#if LL_LCD1602
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } lcd_procs[] = {
      { LCD1602_mop3_begin,      "LCD1602.begin",     false },
      { LCD1602_mop3_clear,      "LCD1602.clear",     false },
      { LCD1602_mop3_home,       "LCD1602.home",      false },
      { LCD1602_mop3_display,    "LCD1602.display",   false },
      { LCD1602_mop3_backlight,  "LCD1602.backlight", false },
      { LCD1602_mop3_cursor,     "LCD1602.cursor",    false },
      { LCD1602_mop3_setCursor,  "LCD1602.setCursor", false },
      { LCD1602_mop3_write,      "LCD1602.write",     false },
      { LCD1602_mop3_print,      "LCD1602.print",     false },
    };
    const int Nlcd_procs = sizeof(lcd_procs)/sizeof(lcd_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nlcd_procs);
    for (int i = 0; i < Nlcd_procs; i++) {
      const auto &p = lcd_procs[i];
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
