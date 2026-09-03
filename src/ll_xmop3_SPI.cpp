// Copyright 2026 by Frobenius Norm LLC 2026-06-30
// Free for non-commercial use. Commercial use requires a license.
//
// P133 Tier 1 (7.1): SPI bus binding (hardware xmop3).
// Wraps the Arduino SPI / SPIClass API, mirroring the shape of ll_xmop3_Wire.cpp.
// CS (chip-select) is deliberately NOT owned by the bus -- the caller drives CS
// with digitalWrite (CommonIO), as adafruit_bus_device.SPIDevice does.
//
//   (SPI.begin sck miso mosi)             ;; bind HW SPI pins (or defaults if all -1)
//   (SPI.beginTransaction clock-hz mode)  ;; mode 0..3; sets clock/polarity/phase
//   (SPI.endTransaction)
//   (SPI.transfer byte)            -> byte ;; full-duplex single byte
//   (SPI.transfer-bytevector! bv)         ;; in-place full-duplex block transfer
//   (SPI.write-bytevector bv)             ;; write-only (MOSI), discard MISO
//
// On the linux host (LL_SPI undefined) every proc is a compile-clean no-op so the
// symbols remain bound for load/smoke tests.
//
#include "LambLisp.h"

#if LL_SPI
#include <SPI.h>
//! @defgroup xmop3_spi SPI Bus
//! @ingroup xmop3
//! @brief LambLisp SPI Bus builtins.
//! @{

static bool spi_begun = false;
#endif


//! (SPI.begin [sck miso mosi]) -- start the HW SPI peripheral on the given pins (or defaults).
Sexpr_t SPI_mop3_begin(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::SPI_mop3_begin()");
  ll_try {
#if LL_SPI
    if (sexpr == NIL) {
      SPI.begin();
    }
    else {
      LL_int32 sck  = lamb.car(sexpr)->mustbe_int32();
      LL_int32 miso = lamb.cadr(sexpr)->mustbe_int32();
      LL_int32 mosi = lamb.car(lamb.cddr(sexpr))->mustbe_int32();
      SPI.begin(sck, miso, mosi, -1);   // ss = -1: caller manages CS
    }
    spi_begun = true;
#endif
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! (SPI.beginTransaction clock-hz [mode]) -- open a transaction; mode 0..3 (default 0).
Sexpr_t SPI_mop3_beginTransaction(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::SPI_mop3_beginTransaction()");
  ll_try {
#if LL_SPI
    LL_int32 clock = lamb.car(sexpr)->coerce_int32();
    LL_int32 mode  = (lamb.cdr(sexpr) != NIL) ? lamb.cadr(sexpr)->coerce_int32() : 0;
    uint8_t dmode;
    switch (mode & 3) {
      case 1:  dmode = SPI_MODE1; break;
      case 2:  dmode = SPI_MODE2; break;
      case 3:  dmode = SPI_MODE3; break;
      default: dmode = SPI_MODE0; break;
    }
    SPI.beginTransaction(SPISettings((uint32_t) clock, MSBFIRST, dmode));
#endif
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! (SPI.endTransaction) -- close the current transaction.
Sexpr_t SPI_mop3_endTransaction(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
#if LL_SPI
  SPI.endTransaction();
#endif
  return OBJ_UNDEF;
}

//! (SPI.transfer byte) -> byte -- full-duplex single-byte exchange.
Sexpr_t SPI_mop3_transfer(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::SPI_mop3_transfer()");
  ll_try {
    LL_int32 out = lamb.car(sexpr)->coerce_int32() & 0xff;
#if LL_SPI
    LL_int32 in = SPI.transfer((uint8_t) out);
    return lamb.mk_integer(in, env_exec);
#else
    return lamb.mk_integer(0, env_exec);
#endif
  }
  ll_catch();
}

//! (SPI.transfer-bytevector! bv) -- in-place full-duplex block transfer; returns bv.
Sexpr_t SPI_mop3_transfer_bytevector(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::SPI_mop3_transfer-bytevector!()");
  ll_try {
    Sexpr_t bv = lamb.car(sexpr);
    if (!bv->is_any_bvec_atom()) throw NIL->mk_error("%s: expected bytevector", me);
    LL_int32 nelems; ByteVec_t elems;
    bv->any_bvec_get_info(nelems, elems);
#if LL_SPI
    SPI.transfer(elems, (size_t) nelems);   // reads & writes in place
#endif
    return bv;
  }
  ll_catch();
}

//! (SPI.write-bytevector bv) -- write-only (MOSI), MISO discarded; returns byte count.
Sexpr_t SPI_mop3_write_bytevector(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::SPI_mop3_write-bytevector()");
  ll_try {
    Sexpr_t bv = lamb.car(sexpr);
    if (!bv->is_any_bvec_atom()) throw NIL->mk_error("%s: expected bytevector", me);
    LL_int32 nelems; ByteVec_t elems;
    bv->any_bvec_get_info(nelems, elems);
#if LL_SPI
    for (LL_int32 i = 0; i < nelems; i++) SPI.transfer(elems[i]);
#endif
    return lamb.mk_integer(nelems, env_exec);
  }
  ll_catch();
}

//! (SPI.end) -- release the SPI peripheral.
Sexpr_t SPI_mop3_end(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
#if LL_SPI
  if (spi_begun) { SPI.end(); spi_begun = false; }
#endif
  return OBJ_UNDEF;
}

//! Install all SPI symbols in base environment.
Sexpr_t SPI_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::SPI_install_mop3()");
  ll_try {
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } spi_procs[] = {
      { SPI_install_mop3,               "SPI.install-mop3",          false },
      { SPI_mop3_begin,                 "SPI.begin",                 false },
      { SPI_mop3_end,                   "SPI.end",                   false },
      { SPI_mop3_beginTransaction,      "SPI.beginTransaction",      false },
      { SPI_mop3_endTransaction,        "SPI.endTransaction",        false },
      { SPI_mop3_transfer,              "SPI.transfer",              false },
      { SPI_mop3_transfer_bytevector,   "SPI.transfer-bytevector!",  false },
      { SPI_mop3_write_bytevector,      "SPI.write-bytevector",      false },
    };
    const int Nspi_procs = sizeof(spi_procs)/sizeof(spi_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nspi_procs);
    for (int i = 0; i < Nspi_procs; i++) {
      const auto &p = spi_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
    return OBJ_UNDEF;
  }
  ll_catch();
}
//! @}
