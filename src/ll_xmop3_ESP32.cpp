// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"


#if LL_ESP32

#include "esp_system.h"
#include "esp_efuse.h"
#include "esp_heap_caps.h"
#include "esp_partition.h"
#include "soc/soc_memory_types.h" // esp_ptr_in_dram / esp_ptr_external_ram (arduino-esp32 IDF 4.4; esp_memory_utils.h is IDF 5.x-only)
//! @defgroup xmop3_esp32 ESP32 System
//! @ingroup xmop3
//! @brief LambLisp ESP32 System builtins.
//! @{

//! Report heap free/largest-block for the three caps that matter to flash reads.
//! Returns (internal-free internal-largest dma-free dma-largest spiram-free spiram-largest)
//! and also logs it.  Diagnostic: littlefs reads ENOMEM (esp_partition_read rc 257).
Sexpr_t mop3_esp32_heapinfo(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_esp32_heapinfo()");
  ll_try {
    size_t if_ = heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    size_t il  = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    size_t df  = heap_caps_get_free_size(MALLOC_CAP_DMA);
    size_t dl  = heap_caps_get_largest_free_block(MALLOC_CAP_DMA);
    size_t sf  = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    size_t sl  = heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
    global_printf("[heapinfo] INTERNAL|8BIT free=%u largest=%u | DMA free=%u largest=%u | SPIRAM free=%u largest=%u\n",
                  (unsigned)if_, (unsigned)il, (unsigned)df, (unsigned)dl, (unsigned)sf, (unsigned)sl);
    Sexpr_t res = NIL;
    mop3_gc_protect(res, {
        res = lamb.cons(lamb.mk_integer((LL_int32)sl, env_exec), res, env_exec);
        res = lamb.cons(lamb.mk_integer((LL_int32)sf, env_exec), res, env_exec);
        res = lamb.cons(lamb.mk_integer((LL_int32)dl, env_exec), res, env_exec);
        res = lamb.cons(lamb.mk_integer((LL_int32)df, env_exec), res, env_exec);
        res = lamb.cons(lamb.mk_integer((LL_int32)il, env_exec), res, env_exec);
        res = lamb.cons(lamb.mk_integer((LL_int32)if_, env_exec), res, env_exec);
    });
    return res;
  }
  ll_catch();
}

//! B117 diagnostic: print GC-buffer / cell-block memory placement (INTERNAL vs PSRAM) + sizes.
Sexpr_t mop3_esp32_gcmem(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_esp32_gcmem()");
  ll_try {
    lamb.diag_memory_report();
    return NIL;
  }
  ll_catch();
}

//! Reproduce a raw esp_partition_read under our own logging, to isolate the ENOMEM.
//! (esp32-flash-probe "label" offset len where) where: 0=internal DMA buffer, 1=PSRAM buffer.
//! Logs heap + destination region + rc; returns the esp_partition_read rc as an integer.
Sexpr_t mop3_esp32_flash_probe(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_esp32_flash_probe()");
  ll_try {
    Sexpr_t label_sx = lamb.car(sexpr);
    LL_int32 offset  = lamb.cadr(sexpr)->mustbe_int32();
    LL_int32 len     = lamb.caddr(sexpr)->mustbe_int32();
    LL_int32 where   = lamb.cadddr(sexpr)->mustbe_int32();
    Charst_t label   = label_sx->any_str_get_chars();   // raw chars: str() is the WRITER and would quote/escape

    const esp_partition_t *part =
      esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, label);
    if (!part) {
      global_printf("[flash-probe] partition '%s' NOT FOUND\n", label);
      return lamb.mk_integer(-1, env_exec);
    }
    global_printf("[flash-probe] part '%s' addr=0x%06x size=0x%06x  read off=0x%06x len=%d where=%s\n",
                  label, (unsigned)part->address, (unsigned)part->size,
                  (unsigned)offset, (int)len, where ? "PSRAM" : "INTERNAL-DMA");

    void *buf = (where == 1)
      ? heap_caps_malloc((size_t)len, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)
      : heap_caps_malloc((size_t)len, MALLOC_CAP_DMA);
    if (!buf) {
      global_printf("[flash-probe] buffer alloc FAILED (len=%d where=%s)\n", (int)len, where ? "PSRAM" : "DMA");
      return lamb.mk_integer(-2, env_exec);
    }
    global_printf("[flash-probe] buf=%p in_dram=%d external_ram=%d | before: INT-largest=%u DMA-largest=%u\n",
                  buf, (int)esp_ptr_in_dram(buf), (int)esp_ptr_external_ram(buf),
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA));

    esp_err_t rc = esp_partition_read(part, (size_t)offset, buf, (size_t)len);
    global_printf("[flash-probe] esp_partition_read rc=%d (0x%x)\n", (int)rc, (unsigned)rc);
    heap_caps_free(buf);
    return lamb.mk_integer((LL_int32)rc, env_exec);
  }
  ll_catch();
}

//! Read the default factory MAC address from eFuse; returns a 6-byte bytevector.
Sexpr_t mop3_esp32_efuse_mac_get_default(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  byte mac[6];
  esp_efuse_mac_get_default(mac);
  return lamb.mk_bytevector(6, mac, env_exec);
}

//! Return the chip package version from eFuse.
Sexpr_t mop3_esp32_efuse_pkg_ver(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return lamb.mk_integer(esp_efuse_get_pkg_ver(), env_exec); }

//! Read Nbits bits from an eFuse block at a bit offset; returns a bytevector or error code.
Sexpr_t mop3_esp32_efuse_read_block(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_esp32_efuse_read_block()");
  ll_try {
    Sexpr_t blk        = lamb.car(sexpr);
    Sexpr_t bit_offset = lamb.cadr(sexpr);
    Sexpr_t Nbits_sx   = lamb.caddr(sexpr);

    LL_int32 Nbits  = Nbits_sx->mustbe_int32();
    LL_int32 Nbytes = Nbits / 8;
    if (Nbits & 7) Nbytes++;
    Sexpr_t res = lamb.mk_bytevector(Nbytes, 0);
    LL_int32 n;
    ByteVec_t elems;
    res->any_bvec_get_info(n, elems);
    
    auto err = esp_efuse_read_block((esp_efuse_block_t) blk->mustbe_int32(), elems, bit_offset->mustbe_int32(), Nbits);
    if (err != ESP_OK) res = lamb.mk_integer(err, env_exec);
    return res;
  }
  ll_catch();
}

  
//! Write Nbits bits from a bytevector or integer into an eFuse block; returns esp_err_t.
Sexpr_t mop3_esp32_efuse_write_block(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::mop3_esp32_efuse_write_block");
  ll_try {
    Sexpr_t blk        = lamb.car(sexpr);
    Sexpr_t bits       = lamb.cadr(sexpr);
    Sexpr_t bit_offset = lamb.caddr(sexpr);
    Sexpr_t Nbits      = lamb.cadddr(sexpr);

    ByteVec_t p = 0;
    LL_int32 i = 0;
    if (bits->type() == Cell::T_INT32) {
      i = bits->as_int32();
      p = (ByteVec_t) &i;
    }
    else bits->any_bvec_get_info(i, p);
    //DEBT all this is likely wrong
    auto err = esp_efuse_write_block((esp_efuse_block_t) blk->mustbe_int32(), bits, bit_offset->mustbe_int32(), Nbits->mustbe_int32());
    return lamb.mk_integer(err, env_exec);
  }
  ll_catch();
}

#endif

Sexpr_t ESP32_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::ESP32_install_mop3()");
  mop3_try {
    lamb.log("%s installing Mops\n", me);
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } base_procs[] = {
      { ESP32_install_mop3, "ESP32-install-mop3", false },
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
#if LL_ESP32
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } esp32_procs[] = {
      { mop3_esp32_efuse_mac_get_default, "esp32-efuse-mac-get-default", false },
      { mop3_esp32_efuse_pkg_ver,         "esp32-efuse-pkg-ver",         false },
      { mop3_esp32_efuse_read_block,      "esp32-efuse-read-block",      false },
      { mop3_esp32_efuse_write_block,     "esp32-efuse-write-block",     false },
      { mop3_esp32_heapinfo,              "esp32-heapinfo",              false },
      { mop3_esp32_gcmem,                 "esp32-gcmem",                 false },
      { mop3_esp32_flash_probe,           "esp32-flash-probe",           false },
    };
    const int Nesp32_procs = sizeof(esp32_procs)/sizeof(esp32_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nesp32_procs);
    for (int i = 0; i < Nesp32_procs; i++) {
      const auto &p = esp32_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#endif
    return NIL;
  }
  mop3_catch();
}

//! @}
