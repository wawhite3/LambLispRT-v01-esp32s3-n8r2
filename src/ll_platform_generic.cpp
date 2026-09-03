// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "ll_platform_generic.h"

#include <stdio.h>
#include <string.h>

AsciiConverter ascii;

#include <stdlib.h>
#if LL_ESP32
#include "esp_heap_caps.h"
#endif

/*! B95: allocate a bulk VM payload, preferring PSRAM (see ll_platform_generic.h).
  The PSRAM probe is done ONCE and cached: on a part without PSRAM every payload would otherwise
  pay a failing heap_caps_malloc before falling back.
*/
void *ll_payload_alloc_bytes(size_t nbytes)
{
  if (nbytes == 0) nbytes = 1;      //!< new T[0] yields a unique non-null pointer; match that
#if LL_ESP32
  static int psram_ok = -1;
  if (psram_ok < 0) {
    void *probe = heap_caps_malloc(8, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    psram_ok = probe ? 1 : 0;
    if (probe) heap_caps_free(probe);
  }
  if (psram_ok) {
    void *p = heap_caps_malloc(nbytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (p) return p;                //!< PSRAM full -> fall through to internal, never fail here
  }
#endif
  return malloc(nbytes);
}

void ll_payload_free(void *p)
{
  free(p);                          //!< free() handles heap_caps_malloc blocks on the IDF
}

void LambPreSettings::load()
{
  LL_File *f = ll_file_system.open(LAMB_SETTINGS_PATH, "r");
  if (!f || !f->isOpen()) { delete f; return; }
  char line[256], key[64];
  long val;
  int len = 0, c;
  while (true) {
    c = f->read();
    if (c == '\n' || c == EOF) {
      line[len] = '\0';
      if (len > 0) {
        const char *p = line;
        while (*p == '(' || *p == ' ' || *p == '\t' || *p == '\r') p++;
        if (sscanf(p, "%63[a-zA-Z0-9_] . %ld", key, &val) == 2) {
          if      (strcmp(key, "cell_block_size")      == 0) cell_block_size      = (LL_int32) val;
          else if (strcmp(key, "extension_block_size") == 0) extension_block_size = (LL_int32) val;
          else if (strcmp(key, "ncg_frame_pool_size")  == 0) ncg_frame_pool_size  = (LL_int32) val;
        }
      }
      len = 0;
      if (c == EOF) break;
    }
    else if (len < (int) sizeof(line) - 1) line[len++] = (char) c;
  }
  f->close();
  delete f;
}
