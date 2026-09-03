// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"
//! @defgroup xmop3_i2c I2C (Wire)
//! @ingroup xmop3
//! @brief LambLisp I2C (Wire) builtins.
//! @{


#if LL_WIRE

TwoWire *LL_Wire = 0;

/*!
  (Wire.setWireTimeout)
  OR
  (Wire.setWireTimeout timeout reset-on-timeout-flag)
  
  With no parameters, some generally useful (but as yet unknown) values are used.
*/

//! Set Wire timeout; no args = 1000 ms default; (timeout reset-on-timeout-flag) form also accepted.
Sexpr_t Wire_mop3_setTimeout(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  if (LL_Wire == 0) LL_Wire = &Wire;
  if (sexpr == NIL) { LL_Wire->setTimeout(1000); /*LL_Wire->setWireTimeout();*/ }	//default 1000 ms according to arduino docs
  else {
    LL_int32 timeout           = lamb.car(sexpr)->mustbe_int32();
    Bool_t reset_on_timeout = lamb.cadr(sexpr) != HASHF;
    //LL_Wire->setWireTimeout(timeout, reset_on_timeout);	//platform-dependent
    LL_Wire->setTimeout(timeout);
  }
  return OBJ_UNDEF;
}

//! Assign SDA and SCL pins before calling Wire.begin.
Sexpr_t Wire_mop3_setPins(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  if (LL_Wire == 0) LL_Wire = &Wire;
  LL_int32 sda = lamb.car(sexpr)->mustbe_int32();
  LL_int32 scl = lamb.cadr(sexpr)->mustbe_int32();
  LL_int32 res = LL_Wire->setPins(sda, scl);
  return lamb.mk_integer(res, env_exec);
}

/*!(begin [ addr ])
  If address is provided , it is our slave bus address.
  If no address is provided, then we are the bus controller.
 */
Sexpr_t Wire_mop3_begin(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Wire_mop3_begin()");
  ll_try {
    if (LL_Wire == 0) LL_Wire = &Wire;
    LL_int32 addr = 0;
    if (sexpr != NIL) addr = lamb.car(sexpr)->mustbe_int32();
    LL_int32 res = 0;
    if (addr) res = LL_Wire->begin(addr);
    else {
      res = LL_Wire->begin();
      LL_Wire->setTimeout(50);	//esp doc says this is default
    }
    return lamb.mk_bool(res, env_exec);
  }
  ll_catch();
}
/*!
  (Wire.requestFrom addr quantity [ release-bus-after ])
  OR
  (Wire.requestFrom addr quantity)

  If not provided, release-bus-after defaults to #t.
*/
Sexpr_t Wire_mop3_requestFrom(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("Wire_mop3_requestFrom()");
  ll_try {
    LL_int32 addr = lamb.car(sexpr)->mustbe_int32();
    sexpr      = lamb.cdr(sexpr);
    LL_int32 qty  = lamb.car(sexpr)->mustbe_int32();
    sexpr      = lamb.cdr(sexpr);
    LL_int32 stop = (sexpr == NIL) ? true : (lamb.car(sexpr) != HASHF);
    LL_int32 res  = LL_Wire->requestFrom(addr, qty, stop);
    
    return lamb.mk_integer(res, env_exec);
  }
  ll_catch();
}

//! Set the I2C clock frequency in Hz.
Sexpr_t Wire_mop3_setClock(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ LL_Wire->setClock(lamb.car(sexpr)->coerce_int32()); return OBJ_UNDEF; }
//! Begin a transmission to the I2C device at the given address.
Sexpr_t Wire_mop3_beginTransmission(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ LL_Wire->beginTransmission(lamb.car(sexpr)->mustbe_int32()); return OBJ_UNDEF; }
//! Return the number of bytes available to read from the I2C buffer.
Sexpr_t Wire_mop3_available(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return lamb.mk_integer(LL_Wire->available(), env_exec); }
//! Read one byte from the I2C receive buffer; returns -1 if none available.
Sexpr_t Wire_mop3_read(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return lamb.mk_integer(LL_Wire->read(), env_exec); }
//! Release the Wire bus and free resources; returns #t on success.
Sexpr_t Wire_mop3_end(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)			{ return lamb.mk_bool(LL_Wire->end(), env_exec); }

//! Register a receive callback for slave mode (stub).
Sexpr_t Wire_mop3_onReceive(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return OBJ_UNDEF; }
//! Register a request callback for slave mode (stub).
Sexpr_t Wire_mop3_onRequest(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return OBJ_UNDEF; }
//! Clear the Wire timeout flag (stub).
Sexpr_t Wire_mop3_clearWireTimeoutFlag(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return OBJ_UNDEF; }
//! Return the Wire timeout flag (stub).
Sexpr_t Wire_mop3_getWireTimeoutFlag(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return OBJ_UNDEF; }

//! End the current transmission; optional stop arg; returns #f on success or error string.
Sexpr_t Wire_mop3_endTransmission(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("Wire_mop3_endTransmission()");
  
  Bool_t stop = true;
  if (sexpr != NIL) stop = lamb.car(sexpr) != HASHF;
  LL_int32 res = LL_Wire->endTransmission(stop);
  Sexpr_t res_sx = OBJ_UNDEF;
  if (res == 0) res_sx = HASHF;
  else if (res == 1) res_sx = lamb.mk_string(env_exec, "%s xmit overfow", me);
  else if (res == 2) res_sx = lamb.mk_string(env_exec, "%s xmit addr NAK", me);
  else if (res == 3) res_sx = lamb.mk_string(env_exec, "%s xmit data NAK", me);
  else if (res == 4) res_sx = lamb.mk_string(env_exec, "%s other error", me);
  else if (res == 5) res_sx = lamb.mk_string(env_exec, "%s timeout", me);
  else res_sx = lamb.mk_string(env_exec, "%s unknown error %d", me, res);
  return res_sx;
}

//! Write a byte, character, string, or bytevector to the I2C transmit buffer; returns bytes written.
Sexpr_t Wire_mop3_write(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("Wire_mop3_write()");
  auto wiresend = [](LL_int32 n, uint8_t *buf) { return LL_Wire->write(buf, n); };
  
  LL_int32 ires = 0;
  LL_int32 typ = sexpr->type();
  
  if (sexpr == NIL) {}
  else if (typ == Cell::T_CHAR) ires = LL_Wire->write(sexpr->as_Char_t() & 0xff);
  else if (typ == Cell::T_INT32)  ires = LL_Wire->write(sexpr->as_int32() & 0xff);
  else if (sexpr->is_any_str_atom()) ires = LL_Wire->write(sexpr->any_str_get_chars());
  else if (sexpr->is_any_bvec_atom()) {
    LL_int32 nelems;
    ByteVec_t elems;
    sexpr->any_bvec_get_info(nelems, elems);
    ires = LL_Wire->write(elems, nelems);
  }
  return lamb.mk_integer(ires, env_exec);
}
#endif

//Install all Wire symbols in base environment.
//
Sexpr_t Wire_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Wire_install_mop3()");
  ll_try {
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } base_procs[] = {
      { Wire_install_mop3, "Wire.install-mop3", false },
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
#if LL_WIRE
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } wire_procs[] = {
      { Wire_mop3_begin,               "Wire.begin",               false },
      { Wire_mop3_end,                 "Wire.end",                 false },
      { Wire_mop3_requestFrom,         "Wire.requestFrom",         false },
      { Wire_mop3_beginTransmission,   "Wire.beginTransmission",   false },
      { Wire_mop3_endTransmission,     "Wire.endTransmission",     false },
      { Wire_mop3_write,               "Wire.write",               false },
      { Wire_mop3_available,           "Wire.available",           false },
      { Wire_mop3_read,                "Wire.read",                false },
      { Wire_mop3_setClock,            "Wire.setClock",            false },
      { Wire_mop3_onReceive,           "Wire.onReceive",           false },
      { Wire_mop3_onRequest,           "Wire.onRequest",           false },
      { Wire_mop3_setPins,             "Wire.setPins",             false },
      { Wire_mop3_setTimeout,          "Wire.setTimeout",          false },
      { Wire_mop3_clearWireTimeoutFlag,"Wire.clearWireTimeoutFlag",false },
      { Wire_mop3_getWireTimeoutFlag,  "Wire.getWireTimeoutFlag",  false },
    };
    const int Nwire_procs = sizeof(wire_procs)/sizeof(wire_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nwire_procs);
    for (int i = 0; i < Nwire_procs; i++) {
      const auto &p = wire_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#endif
    return OBJ_UNDEF;
  }
  ll_catch();
}
//! @}
