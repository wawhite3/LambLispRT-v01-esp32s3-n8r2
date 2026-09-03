// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#ifndef LL_PLATFORM_GENERIC_H
#define LL_PLATFORM_GENERIC_H

#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>
#include <setjmp.h>
#include "assert.h"
#include "unistd.h"

// Default all LL_ feature flags to 0 so they can be used as C++ values, not just #if guards.
#ifndef LL_ARDUINO
#define LL_ARDUINO       0
#endif
#ifndef LL_FAKE_ARDUINO
#define LL_FAKE_ARDUINO  0
#endif
#ifndef LL_POSIX
#define LL_POSIX         0
#endif
#ifndef LL_WIFI
#define LL_WIFI          0
#endif
#ifndef LL_LITTLEFS
#define LL_LITTLEFS      0
#endif
#ifndef LL_STACK_SIZE
#define LL_STACK_SIZE    0
#endif
//! Native C-stack budget for eval() recursion.  The B70 guard raises a catchable
//! "recursion too deep" error once eval has grown this many bytes past its outermost
//! frame -- before the real OS stack guard page is hit (which would SIGSEGV/crash the
//! whole process).  Sized below the platform stack: POSIX main thread = 8 MB; ESP32
//! Arduino loopTask = 96 KB (see getArduinoLoopTaskStackSize() in main.cpp).  Override
//! with -DLL_EVAL_STACK_BUDGET=<bytes> per env if a target uses a different stack.
#ifndef LL_EVAL_STACK_BUDGET
  #if LL_POSIX
  #define LL_EVAL_STACK_BUDGET  (6UL * 1024 * 1024)   /*!< ~6 MB of the 8 MB POSIX stack (2 MB headroom) */
  #else
  #define LL_EVAL_STACK_BUDGET  (40UL * 1024)         /*!< ~40 KB of the 48 KB ESP32 loopTask stack (8 KB headroom); see getArduinoLoopTaskStackSize() in main.cpp -- keep budget < stack so the B70 guard raises a catchable "recursion too deep" before the real stack overflows */
  #endif
#endif
//! Size of the NCG executable (D/IRAM) pool.  B95: this comes out of INTERNAL DRAM, the same scarce
//! region esp_flash_read needs for the DMA bounce buffer behind every LittleFS read into PSRAM.  On
//! the N8R2 (352 KB internal) the original 128 KB left 500 bytes free after setup -- measured with
//! (esp32-heapinfo) -- so every 512-byte FS read returned ESP_ERR_NO_MEM (err 257).  Override with
//! -DLL_NCG_EXEC_POOL_BYTES=<bytes> per env; larger only buys more simultaneously-resident NCG code.
//! LL_NCG_DIRAM_POOL -- NAMED FOR THE CAPABILITY, NOT THE CHIP.
//! The pool needs one property: a D/IRAM ALIAS REGION, where the same physical block is writable
//! through a DRAM address and executable through an IRAM address.  BOTH the ESP32 (LX6) and the
//! ESP32-S3 (LX7) have one, and the IDF exposes it identically via esp_ptr_in_diram_dram() /
//! esp_ptr_diram_dram_to_iram() in esp_memory_utils.h -- a COMMON component, not an S3 one.
//! This guard was `#if LL_ESP32S3` and that was wrong in a way that cost real time: the LX6 boards
//! (4WD, WROVER) got NO pool, every NCG compile fell through to heap_caps_malloc(MALLOC_CAP_EXEC)
//! -- which has ~368 bytes because the IRAM-only region is consumed by static code -- and so NCG
//! HAS NEVER RUN on those boards.  It presents as `alloc_exec: heap_caps_malloc(N) FAILED` and
//! then as tests that quietly SKIP because the driver could not be compiled.
//! Keying a capability off a chip model also means the only way to enable it on another chip is to
//! claim to BE that chip, which puts a false -DLL_ESP32S3 on a non-S3 board and breaks every other
//! thing that flag legitimately selects.  Name the capability; let each SoC declare whether it has it.
#ifndef LL_NCG_DIRAM_POOL
  #if LL_ESP32S3 || LL_ESP32
    #define LL_NCG_DIRAM_POOL 1
  #else
    #define LL_NCG_DIRAM_POOL 0
  #endif
#endif

//! Pool size is PER-SoC because the budget is, and B95 is the cautionary number: this comes out of
//! INTERNAL DRAM, the same scarce region esp_flash_read needs for its DMA bounce buffer.
//!   ESP32-S3 (LX7): 352 KB internal -> 32 KB pool, already proven on the N8R2.
//!   ESP32   (LX6): ~320 KB internal and a SMALLER D/IRAM alias window, and the classic ESP32 also
//!                   pays for the PSRAM cache workaround, so it gets 12 KB.  Smaller only limits
//!                   how much native code is simultaneously resident; ncg_exec_pool_init() verifies
//!                   the block really landed in D/IRAM and DISABLES the pool if not, so an
//!                   over-ask degrades to the old fallback rather than to a wrong mapping.
#ifndef LL_NCG_EXEC_POOL_BYTES
  #if LL_ESP32S3
    #define LL_NCG_EXEC_POOL_BYTES  (32UL * 1024)
  #elif LL_ESP32
    //! MEASURED, not guessed: at 12 KB the 4WD filled the pool (12228/12288) partway through
    //! ncg-tests.scm and every later compile fell back to heap_caps_malloc(EXEC), which offers
    //! ~700-800 bytes -- so the seam drivers could not compile and their tests SKIPped.  The whole
    //! subsystem tier still ran in 42 s with LittleFS healthy at 12 KB, so there is headroom below
    //! the B95 cliff; 24 KB is the next step, still well under the S3's proven 32 KB on a chip with
    //! less internal DRAM.  RAISE THIS FURTHER ONLY WITH A LITTLEFS READ TEST IN THE SAME RUN:
    //! B95's failure mode is not a pool error, it is every 512-byte FS read returning ESP_ERR_NO_MEM.
    //! 32 KB, and the number is MEASURED twice over, not guessed.  THE POOL IS A BUMP ALLOCATOR
    //! THAT NEVER RECLAIMS -- ncg_pool_used only ever increases, and finalize() deliberately sets
    //! alloc_base=nullptr for pool allocations so nothing is freed -- so a compile-heavy file has a
    //! HARD CEILING and a bigger pool only moves the failure later.  Observed on the 4WD running
    //! ncg-tests.scm: 12 KB filled at 12228/12288, 24 KB filled at 24548/24576, identical SKIPs.
    //! At 24 KB the still-wanted allocations were 1104 + 1160 + 168 + 156 ~= 2.6 KB, so 32 KB is
    //! the smallest size that clears them -- and it matches the S3's already-proven value on a chip
    //! with only slightly less internal DRAM (~320 KB vs 352 KB), keeping the same ~10%% share.
    //! DO NOT raise further without exercising a LittleFS READ in the same run: B95's failure is
    //! not a pool error, it is every 512-byte FS read returning ESP_ERR_NO_MEM, which presents as
    //! MISSING TEST FILES rather than as an allocation message.
    #define LL_NCG_EXEC_POOL_BYTES  (32UL * 1024)
  #else
    #define LL_NCG_EXEC_POOL_BYTES  (32UL * 1024)
  #endif
#endif
//! Hard cap on the GC rootstack (entries).  Each non-tail recursion level pushes ~5 roots, so this
//! sets the rootstack-bound recursion depth.  Since B72 (markstack now grows on demand,
//! GC_MarkStack::push), the rootstack is no longer coupled to a fixed 65536 markstack and can be sized
//! so the non-expandable **C stack** (LL_EVAL_STACK_BUDGET) is the binding limit: a POSIX 8 MB stack
//! reaches ~40 k depth (~215 k roots) before the C-stack guard fires, so 262144.  ESP32's 96 KB stack
//! caps depth at ~600 (far below 65536 roots), so the cap there is irrelevant -- keep it small.
//! Each entry is a Sexpr_t (8 B) -> POSIX 2 MB; the markstack mirrors it transiently during a mark.
#ifndef LL_ROOTSTACK_MAX
  #if LL_POSIX
  #define LL_ROOTSTACK_MAX  262144
  #else
  #define LL_ROOTSTACK_MAX  65536
  #endif
#endif
//! Physical slack allocated above LL_ROOTSTACK_MAX so the overflow error path (which itself
//! allocates a T_ERROR and pushes a few roots) has real buffer instead of writing OOB (B71).
#ifndef LL_ROOTSTACK_SLACK
#define LL_ROOTSTACK_SLACK  256
#endif
//! Recursion guard's rootstack trip point -- a little below the cap, leaving room for the error path.
#ifndef LL_EVAL_ROOT_DEPTH_MAX
#define LL_EVAL_ROOT_DEPTH_MAX  (LL_ROOTSTACK_MAX - 536)
#endif
#ifndef LL_I2C
#define LL_I2C           0
#endif
#ifndef LL_COMMONIO
#define LL_COMMONIO      0
#endif
#ifndef LL_ESP32
#define LL_ESP32         0
#endif
#ifndef LL_COMPLEX
#define LL_COMPLEX       0
#endif
#ifndef LL_RATIONAL
#define LL_RATIONAL      0
#endif
#ifndef LL_BIGNUM
#define LL_BIGNUM        0
#endif
#ifndef LL_BIGNUM_LIMB_BITS
#define LL_BIGNUM_LIMB_BITS 32
#endif
#ifndef LL_BIGNUM_STRICT_RT
#define LL_BIGNUM_STRICT_RT 0
#endif
#ifndef LL_NDARRAY
#define LL_NDARRAY       0
#endif
#ifndef LL_MODBUS
#define LL_MODBUS        0
#endif
#ifndef LL_PROFIBUS
#define LL_PROFIBUS      0
#endif
#ifndef LL_PROFINET
#define LL_PROFINET      0
#endif
#ifndef LL_CUDA
#define LL_CUDA          0
#endif
#ifndef LL_HIP
#define LL_HIP           0
#endif

// Board-specific flags (set by platformio.ini build_flags per env)
#ifndef LL_ESP32_S3_DEVKIT_C
#define LL_ESP32_S3_DEVKIT_C              0
#endif
#ifndef LL_ESP32S3_N8R2
#define LL_ESP32S3_N8R2                   0
#endif
#ifndef LL_Freenove_4WD_Car_Kit_ESP32
#define LL_Freenove_4WD_Car_Kit_ESP32     0
#endif
#ifndef LL_Freenove_ESP32_WROVER
#define LL_Freenove_ESP32_WROVER          0
#endif
#ifndef LL_ESP32_N4R4
#define LL_ESP32_N4R4                     0
#endif
#ifndef LL_AMD64
#define LL_AMD64                          0
#endif
#ifndef LL_X86_64
#define LL_X86_64                         0
#endif
#ifndef LL_AARCH64
#define LL_AARCH64                        0
#endif
#ifndef LL_ARM64
#define LL_ARM64                          0
#endif


#if LL_ARDUINO
#include "Arduino.h"
#endif

#if LL_FAKE_ARDUINO
#include <string.h>

unsigned long millis();
unsigned long micros();
void delay_ms(unsigned long ms);

static void delay(unsigned long ms) { delay_ms(ms); }

typedef uint8_t byte;

class LL_String {
public:

  LL_String()				{ ptr = 0;  set(""); }
  LL_String(const char *other)		{ ptr = 0;  set(other);  }
  LL_String(const char *other, int n)	{ ptr = 0;  set(other, n);  }
  LL_String(const LL_String &other)	{ ptr = 0;  set(other.ptr);  }
  
  ~LL_String()	{ if (ptr) { delete[] ptr;  ptr = 0; } }

  void set(const char *s) { set(s, strlen(s)); }

  void set(const char *s, int n) {
    if (ptr) { delete[] ptr;  ptr = 0; }
    char *p = ptr = new char[n + 1];
    while (n--) *p++ = *s++;
    *p = '\0';
  }
  
  LL_String concat(const char *s1, const char *s2) {
    int n1 = strlen(s1);
    int n2 = strlen(s2);
    char *s3 = new char[n1 + n2 + 1];

    char *p = s3;
    while (n1--) *p++ = *s1++;
    while (n2--) *p++ = *s2++;
    *p = '\0';
    return s3;
  }

  LL_String &append(const char *s1) {
    const char *s0 = ptr;
    int n0 = s0 ? strlen(s0) : 0;
    int n1 = strlen(s1);
    char *s2 = new char[n0 + n1 + 1];

    char *p = s2;
    while (n0--) *p++ = *s0++;
    while (n1--) *p++ = *s1++;
    *p = '\0';
    
    if (ptr) { delete[] ptr;  ptr = 0; }
    ptr = s2;
    return *this;
  }

  LL_String substring(int start, int len)	{ return LL_String(&(ptr[start]), len); }
  
  LL_String &operator=(const char *other)	{ set(other); return *this; }
  LL_String &operator=(const LL_String &other)	{ set(other.ptr); return *this; }

  bool operator==(const char *other)		{ return strcmp(ptr, other) == 0; }
  bool operator!=(const char *other)		{ return strcmp(ptr, other) != 0; }
  bool operator==(const LL_String &other)	{ return strcmp(ptr, other.ptr) == 0; }
  bool operator!=(const LL_String &other)	{ return strcmp(ptr, other.ptr) != 0; }
  char &operator[](int ix)			{ return ptr[ix]; }

  LL_String operator+(const char *other)	{ return concat(ptr, other); }
  LL_String operator+(const LL_String &other)	{ return concat(ptr, other.ptr); }
  LL_String operator+(char c)			{ char cstr[2];  cstr[0] = c;  cstr[1] = '\0';  return concat(ptr, cstr); }

  LL_String &operator+=(const char *other)	{ return append(other); }
  LL_String &operator+=(const LL_String &other)	{ return append(other.ptr); }
  LL_String &operator+=(char c)			{ char cstr[2];  cstr[0] = c;  cstr[1] = '\0';  return append(cstr); }
  
  char *c_str() const	{ return ptr; }
  int length() const	{ return strlen(ptr); }
  
private:
  char *ptr;
};

typedef LL_String String;
#endif

//! @name Handy directives, macros and utility functions.
//!@{
#define NOTUSED __attribute__((__unused__))			/*!<GCC extension to suppress individual "not used" warnings. */
#define INLINE __attribute__((__inline__))			/*!<GCC extension to encourage inlining a function. */
#define NOINLINE __attribute__((__noinline__))			/*!<GCC extension to avoid inlining a function. */
#define CHECKPRINTF __attribute__((format(printf, 1, 2)))	/*!<GCC extension, turn on checking of printf() const format strings, if they are known at compile time. */
#define CHECKPRINTF_pos2 __attribute__((format(printf, 2, 3)))	/*!<GCC extension, turn on checking of printf() const format strings, if they are known at compile time. */
#define CHECKPRINTF_pos3 __attribute__((format(printf, 3, 4)))	/*!<GCC extension, turn on checking of printf() const format strings, if they are known at compile time. */
#define CHECKPRINTF_pos4 __attribute__((format(printf, 4, 5)))	/*!<GCC extension, turn on checking of printf() const format strings, if they are known at compile time. */

// On Arduino/ESP32, IRAM_ATTR and DRAM_ATTR are already defined by Arduino.h (esp_attr.h).
// On other platforms (Linux, desktop simulation) define them as empty so the same source compiles.
#if !defined(IRAM_ATTR)
#define IRAM_ATTR					/*!<Place function/data in fast on-chip IRAM (ESP32: ~1-cycle fetch). No-op on other platforms. */
#endif
#if !defined(DRAM_ATTR)
#define DRAM_ATTR					/*!<Place data in on-chip DRAM (ESP32: avoids PSRAM latency). No-op on other platforms. */
#endif

//! @name LambLisp imposes a limit on the length of strings, to reduce opportunities for runaway in an embedded system.
//!@{
const unsigned long toString_MAX_LENGTH = 8192;		//!<Global limit on Lamb-generated strings.
//! B167: how much of an offending form an error message may quote back.  Well under
//! toString_MAX_LENGTH so the surrounding message text cannot push the total over it.
const unsigned long LL_ERRFORM_MAX = 400;
String toString(const char *fmt, ...) CHECKPRINTF;	//!<Produce a new string from the format and arguments, respecting the global limit on string length.
//!@}


#define ME(_me_) NOTUSED const char me[] = _me_			/*!<Declare an identifier "const char me[]" without causing "unused variable" warnings and/or code clutter to suppress them. */
#define isdef(sym) (#sym[0])					//!<Determine (cheaply) at runtime if a preprocessor symbol is defined.

void global_printf(const char *fmt, ...);		//!<This function enforces the limit on generated strings.

//!@}

/*! @name These primitive types are shared by LambLisp and the underlying VM.

  Sizing requirements for LambLisp Cells:

  | Each cell contains 3 fields: tag, car, cdr.                                     |
  | The fields are equal in size and sequential in memory.                          |
  | The bytes within each LambLisp Cell are individually addressable.               |
  | Each field can hold a generic computer "word", a signed integer, or an address. |
  | An integer fills the car field, and may also fill the cdr field.                |
  | A real number also fills the car field, and may also fill the cdr field.        |

  Since the beginning of time (Jan 1 1970) the specific organization of these have been platform-dependent.
  There is a (mostly) obvious correspondence between the shared type name and the underlying C++ type.

  Note the difference between *Charst_t* and *CharVec_t*; one is mutable, the other not.  The immutable version may go away.
  The same applies to *Bytest_t* and *ByteVec_t*.
*/
//!@{

typedef unsigned char Byte_t;	//!<Universally known byte type.
typedef bool Bool_t;		//!<Boolean type.
typedef char Char_t;		//!<Character type.
typedef int32_t ll_codepoint_t;  //!< Unicode scalar value (U+0000 – U+10FFFF)

typedef Char_t const *Charst_t;		//!<Pointer to immutable character array.
typedef Byte_t const *Bytest_t;		//!<Pointer to immutable byte array
typedef Char_t *CharVec_t;		//!<Pointer to mutable char array
typedef Byte_t *ByteVec_t;		//!<Pointer to mutable byte array

/*! @name B95 payload allocator -- bulk VM payloads belong in PSRAM, not internal DRAM.
  String/symbol characters, vector and bytevector bodies, bignum digits and compiled bytecode are
  PURE DATA: the VM never DMAs out of them.  They must NOT come from plain new/malloc on an ESP32,
  because the IDF only diverts allocations LARGER than SPIRAM_MALLOC_ALWAYSINTERNAL to PSRAM -- so
  the many SMALL payloads a load chain creates (every symbol name, every string literal) all land
  in INTERNAL DRAM.  Internal DRAM is also the only memory a flash read can bounce through, so
  draining it makes every LittleFS read fail with ESP_ERR_NO_MEM (err 257) -- that is B95: the
  setup.scm load chain consumed ~115 KB of internal DRAM and left 1176 bytes, while 1.7 MB of
  PSRAM sat unused.  Allocating these payloads from PSRAM keeps internal DRAM for DMA.

  Falls back to malloc when there is no PSRAM (host builds, non-PSRAM parts) or PSRAM is full, so
  behaviour is unchanged everywhere else.  Pairs with ll_payload_free -- these blocks are freed by
  the GC sweep, so they must NEVER be released with delete[].
*/
//!@{
void *ll_payload_alloc_bytes(size_t nbytes);
void  ll_payload_free(void *p);

//! Typed convenience wrapper.  POD payloads only -- no constructors are run.
template <typename T> static inline T *ll_payload_new(size_t n)
{
  return (T *) ll_payload_alloc_bytes(n * sizeof(T));
}
//!@}

#if LL_AMD64
typedef unsigned long Word_t;	//!<This is a generic computer word, used only for setting and retrieval.  It is not an *unsigned int* used for arithmetic.
typedef void *Ptr_t;		//!<Generic pointer in C++
#endif

#if LL_ARM64
typedef unsigned long Word_t;	//!<This is a generic computer word, used only for setting and retrieval.  It is not an *unsigned int* used for arithmetic.
typedef void *Ptr_t;		//!<Generic pointer in C++
#endif

#if LL_ESP32
typedef unsigned Word_t;	//!<This is a generic computer word, used only for setting and retrieval.  It is not an *unsigned int* used for arithmetic.
typedef void *Ptr_t;		//!<Generic pointer in C++
#endif

typedef int32_t  LL_int32;	//!<LambLisp 32-bit exact integer.

//! @name UTF-8 codepoint helpers
//! R7RS indexes strings by CHARACTER, not by byte.  LambLisp stores strings as NUL-terminated
//! UTF-8, so every index operation has to walk the encoding.  These are the one shared
//! implementation -- encoders were previously duplicated in ll_vm_cell.cpp, ll_vm_mop3_json.cpp
//! and ll_vm_port.cpp, which is how the write path came to encode real UTF-8 while the measure
//! path still counted bytes (B146: `(string-length (list->string (list (integer->char 945))))`
//! returned 2 for a one-character string).
//!@{

//! Bytes in the UTF-8 sequence that starts with lead byte b0.  A continuation or invalid lead
//! counts as 1 so a malformed string still advances and cannot hang a scan.
inline int ll_u8_seqlen(unsigned char b0)
{
  if (b0 < 0x80) return 1;
  if ((b0 & 0xE0) == 0xC0) return 2;
  if ((b0 & 0xF0) == 0xE0) return 3;
  if ((b0 & 0xF8) == 0xF0) return 4;
  return 1;
}

//! Decode the sequence at p; *nb receives its byte length.  Invalid input yields the lead byte
//! itself, matching the reader's pass-through behaviour rather than throwing mid-scan.
inline ll_codepoint_t ll_u8_decode(const char *p, int *nb)
{
  unsigned char b0 = (unsigned char) p[0];
  int n = ll_u8_seqlen(b0);
  if (nb) *nb = n;
  if (n == 1) return (ll_codepoint_t) b0;
  ll_codepoint_t cp = b0 & (0xFF >> (n + 1));
  for (int i = 1; i < n; i++) {
    unsigned char c = (unsigned char) p[i];
    if ((c & 0xC0) != 0x80) { if (nb) *nb = 1; return (ll_codepoint_t) b0; }
    cp = (cp << 6) | (c & 0x3F);
  }
  return cp;
}

//! Encode cp into out (at least 4 bytes); returns the byte count.  No NUL is written.
inline int ll_u8_encode(ll_codepoint_t cp, char *out)
{
  if (cp < 0x80)    { out[0] = (char) cp; return 1; }
  if (cp < 0x800)   { out[0] = (char)(0xC0 | (cp >> 6));  out[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
  if (cp < 0x10000) { out[0] = (char)(0xE0 | (cp >> 12)); out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
                      out[2] = (char)(0x80 | (cp & 0x3F)); return 3; }
  out[0] = (char)(0xF0 | (cp >> 18));         out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); out[3] = (char)(0x80 | (cp & 0x3F));  return 4;
}

//! CHARACTER count of a NUL-terminated UTF-8 string (R7RS string-length).
inline LL_int32 ll_u8_strlen(const char *s)
{
  LL_int32 n = 0;
  for (const char *p = s; *p; n++) p += ll_u8_seqlen((unsigned char) *p);
  return n;
}

//! Byte pointer to character index k, or NULL if k is past the end.  k == length returns the
//! terminator, so a caller can use it as an exclusive range end.
inline const char *ll_u8_index(const char *s, LL_int32 k)
{
  const char *p = s;
  for (LL_int32 i = 0; i < k; i++) {
    if (!*p) return 0;
    p += ll_u8_seqlen((unsigned char) *p);
  }
  return p;
}
//!@}

typedef int64_t  LL_int64;	//!<LambLisp 64-bit exact integer.
typedef float   LL_float32;	//!<LambLisp IEEE 754 single-precision (32-bit).
typedef double  LL_float64;	//!<LambLisp IEEE 754 double-precision (64-bit).

static_assert(sizeof(Word_t)    == sizeof(Ptr_t),  "Word_t size must be == Ptr_t size\n");
static_assert(sizeof(Word_t)    >= sizeof(LL_int32), "Word_t size must be >= LL_int32 size\n");
static_assert(sizeof(LL_float32) == 4,              "LL_float32 must be 4 bytes\n");
static_assert(sizeof(LL_float64) == 8,              "LL_float64 must be 8 bytes\n");
//!@}

//The AsciiConverter class mitigates printf formatting problems caused by different int sizes on different processors, when using printf-style format string (%u, %d %lu %ld etc).
class AsciiConverter {
public:

  char *dec(Word_t n) {
    LL_int32 ix  = buffer_size - 1;
    char *ptr = &(buffer[ix]);

    *ptr = '\0';
    do {
      Word_t d = n % 10;
      n /= 10;
      char c = d + '0';
      *--ptr = c;
    } while (n);
    return ptr;
  }

  char *dec(LL_int32 n) {
    if (n >= 0) return dec((Word_t) n);
    if (n == INT32_MIN) return dec((LL_int64) n);   //!< B82: -INT32_MIN overflows int32; int64 path prints it in full
    char *ptr = dec(-n);
    *--ptr = '-';
    return ptr;
  }

  char *dec(LL_int64 n) {
    // Full 64-bit signed decimal; avoids conflict with dec(Word_t) on 64-bit platforms.
    LL_int32 ix = buffer_size - 1;
    char *ptr = &(buffer[ix]);
    *ptr = '\0';
    bool neg = (n < 0);
    uint64_t uv = neg ? (n == INT64_MIN ? (uint64_t) 9223372036854775808ULL : (uint64_t) -n)
                      : (uint64_t) n;
    do { *--ptr = (char)('0' + (uv % 10)); uv /= 10; } while (uv);
    if (neg) *--ptr = '-';
    return ptr;
  }

  char *hex(Word_t n) {
    LL_int32 ix   = buffer_size - 1;
    char *ptr  = &(buffer[ix]);
    LL_int32 nibs = sizeof(Word_t) * 2;

    *ptr = '\0';
    while (nibs--) {
      Word_t d = n & 0x0f;
      n >>= 4;
      char c = (d < 10) ? (d + '0') : (d - 10 + 'a');
      *--ptr = c;
    }
    return ptr;

  }

  char *dec(LL_float32 n) {
    snprintf(buffer, buffer_size, "%f", (LL_float64) n);
    return buffer;
  }

private:
  static const LL_int32 buffer_size = 128;
  char buffer[buffer_size];
};

extern AsciiConverter ascii;
  
class LambPlatform {
public:

  //! @name Interaction with the underlying runtime platform.
  //!@{
  LambPlatform() {}
  ~LambPlatform() { end(); }

  void begin(void);
  void loop(void);			//!<Perform any platform-specific activity needed at loop() time.  Call only once per loop at beginning main loop().
  void end(void);
  
  void reboot(void);
  
  const char *name();			//!<Return a pointer to a chacter array containing a description of the runtime platform.
  void identification(void);		//!<Emit a string with the complete detailed description of the platform.

  LL_int32 free_heap();
  /*! @brief B129: free space in the pool cell BLOCKS are actually allocated from.
      expand() used to test free_heap(), which on ESP32 is esp_get_free_heap_size() -- the AGGREGATE
      of internal DRAM and PSRAM -- and then allocated specifically from MALLOC_CAP_SPIRAM.  It could
      therefore believe there was room when the space was in the wrong pool, let the cell heap grow
      until PSRAM was full, and starve the PAYLOADS (strings, bignum digits, vectors, bytecode) that
      share that pool.  A bignum payload then got NULL and the board died with StoreProhibited.
      On non-ESP32 targets this is just free_heap(). */
  LL_int32 cell_pool_free();			//!<Return the unused space available for LambLisp expansion.  Whether this is *total* space or *largest* space is platform-dependent.  Accuracy is specifically not guaranteed.
  LL_int32 free_stack();			//!<Return the unused execution stack space available.  Accuracy is specifically not guaranteed.
  Bool_t heap_integrity_check(Bool_t complain=false);	//!<Run intensive heap check; print errors if found; return true if errors found.

  //!Return a real number between -1.0 and +1.0.  May include -1.0 but not +1.0.
  LL_float32 rand11() {
    const int max_int = (~((unsigned int) 0)) >> 1;
    const int min_int = -max_int - 1;
    const LL_float32 min  = (LL_float32) min_int;
    
    LL_int32 n;
    rand((byte *) &n, sizeof(n));
    return (n / min);
  }
  
  LL_float32 rand01()			{ return (rand11() + 1.0) / 2.0; }

  void rand(byte *buf, LL_int32 len);	//!<Fill a buffer with the highest-quality random numbers available on this platform.
  void rand11(LL_float32 *buf, LL_int32 n)	{ while (n--) *buf++ = rand11(); }
  void rand01(LL_float32 *buf, LL_int32 n)	{ while (n--) *buf++ = rand01(); }

  LL_int32 loop_elapsed_ms()	{ return millis() - loop_start_ms; }	//!<Return the time elapsed since the beginning of the current loop().
  LL_int32 loop_elapsed_us()	{ return micros() - loop_start_us; }	//!<Return the time elapsed since the beginning of the current loop().

  //!@}

private:
  LL_int32 loop_start_ms;
  LL_int32 loop_start_us;
};

extern LambPlatform lambPlatform;

//! @name Elide the differences between platform "files" with this typedef.
//!@{
#if LL_LITTLEFS
#include "LittleFS.h"
typedef File File_Native;
#endif

#if LL_POSIX
#include <stdio.h>
typedef FILE* File_Native;
#endif
//!@}

/*! \class LL_File
  
  The *file* type is ultimately provided by the underlying operating system, not by LambLisp.
  This class elides the differences between file types on different platforms, providing a POSIX-like interface.

  Note that there is no *open* operation on files.
  A file is opened by the *file system* and then a *file* is returned.
  After a *file* is closed, the same file object cannot be opened again; instead a new file must be requested from the *file system*.
*/
//!@{
class LL_File {
public:

  LL_File();
  ~LL_File();

  bool isOpen() { return _path != ""; }
  int read(void);
  int write(byte b);
  int seek(unsigned long target, int whence=SEEK_SET);
  int tell();
  int size();
  int close();

  int read(byte *b, int n) {
    LL_int32 nread = 0;
    while (n--) {
      int ch = read();
      if (ch == EOF) return nread;
      b[nread++] = ch;
    }
    return nread;
  }
  
  int read(char *s, int n) { return read((byte *) s, n); }  
  int write(const byte *b, int n) { while (n--) write(*b++); return n; }
  int write(const char *s, int n) { while (n--) write((byte) *s++); return n; }
  int peek();
  
  File_Native _theFile;
  String _path;
  String _mode;

private:

};
//!@}

/*! \class LL_File_System

  The "file system" type elides the differences between different underlying platforms.
  For example, it will deal with the leading '/' required by LittleFS.
  This minimal file system interface is platform-independent.
*/
class LL_File_System {
public:
  LL_File *open(const char *path, const char *mode);
  bool exists(const char *path);
  int rm(const char *path);
  int mv(const char *from, const char *to);
  int mkdir(const char *path);

private:
};

extern LL_File_System ll_file_system;

/*! \name WiFi and Wire, in case we need to rationalize conflicting implementations.
 */
//!@{
#if LL_WIRE
#include "Wire.h"
extern TwoWire *LL_Wire;
#endif

#if LL_WIFI
#include "WiFi.h"
#include "WiFiClientSecure.h"
extern WiFiClass *LL_WiFi;
#endif
//!@}

/*! \class LambStdioClass
  
  A wrapper around the underlying stdin/stdout implementation.
  On an embedded system, this class will use the primary serial in/out (`Serial` on Arduino-compatibles).
  On Linux, this class will set the terminal to byte-at-a-time mode (called "non-CANONICAL" mode).
*/
class LambStdioClass {
public:
  int setTxBufferSize(int n);
  int setRxBufferSize(int n);
  
  void begin(void) { begin(115200); }
  void begin(unsigned long baudrate);
  void end();
  int available(void);
  int availableForWrite(void);
  int read(void);
  int write(uint8_t c);
  int write(char c) { return write((uint8_t) c); }
  
  void flush(void);

  int read(byte *buf, int max) {
    int nread = 0;
    while (max--) {
      int b = read();
      if (b == EOF) break;
      *buf++ = b;
    }
    return nread;
  }

  int read(char *s, int max)		{ return read((uint8_t *) s, max); }
  int write(const char *s, int n)	{ return write((uint8_t *) s, n); }
  int write(const byte *b, size_t n)	{ int i=n;  while (i--) write(*b++);  return n; }
  int write(const char *s)		{ int i=0;  while (*s) { write(*s++); i++; }  return i; }
  
  operator bool() { return true; }
};

extern LambStdioClass LambStdio;

typedef byte uuid_t[16];

//!Macro to do something once after the system awakens.
#define once(_once_something) do {		\
    static bool _visited_ = false;		\
    if (!_visited_) {				\
      _visited_ = true;				\
      { _once_something; }			\
    }						\
  } while (0)					\
    //
//

//!Macro to do something every so often.
#define every(_every_so_often_ms, _every_something_to_do) do {	\
    static unsigned long _every_next = 0;			\
    unsigned long _every_now = millis();			\
    if (_every_now >= _every_next) {				\
      { _every_something_to_do; }				\
      _every_next = _every_now + (_every_so_often_ms);		\
    }								\
  } while (0)							\
    //
//

/*!
  The embedded debug catcher ensures that an address is available to be set as a breaskpoint for a hardware debugger.
  This useful in cases where the generated code has been heavily inlined.
  Undefine this symbol if not using a hardware debugger, or redefine it to point to a different breakpoint target.
*/
void embedded_debug_catcher();
#define ll_debug_catcher embedded_debug_catcher()
//#define ll_debug_catcher ll_term.flush()

// ── Settings file paths ──────────────────────────────────────────────────────
#if LL_LITTLEFS
#define LAMB_SETTINGS_PATH  "/Settings-Lamb.scm"   //!< Pre-allocation settings (C++ pre-reader, before heap).
#define SETTINGS_PATH       "/Settings.scm"         //!< Runtime settings (Scheme reader, after startup).
#else
#define LAMB_SETTINGS_PATH  "Settings-Lamb.scm"   //!< cwd-relative (matches setup.scm's "Settings.scm"; program runs from data_staged/<env>)
#define SETTINGS_PATH       "Settings.scm"
#endif

// ── Pre-allocation settings ──────────────────────────────────────────────────
/*!
  Read from LAMB_SETTINGS_PATH before any cells exist.
  Default matches the hardcoded initial cell block size.
  Silent if file is missing (first-boot safe).
*/
struct LambPreSettings {
  LL_int32 cell_block_size      = 8 * 1024;   //!< Cells in the initial GC block (8K default; perf pushes 16K to match comps).
  LL_int32 extension_block_size = 4 * 1024;   //!< Cells per on-demand expansion block (4K).
  LL_int32 ncg_frame_pool_size  = 16;        //!< NcgFrames pre-allocated into the free-list pool at startup.
  void load();               //!< Reads LAMB_SETTINGS_PATH_RAW via fopen; silent if missing.
};

//! @name C++ *try* and *catch* are used to process code faults detected by the LambLisp VM.
//! To cleanly unwind after an error is detected, each *catch* has uniform behavior, which is captured in this macro.
//!@{
#define ll_try try

#define ll_catch(__code_before_rethrow__)				\
  catch (Sexpr_t __err__) {						\
    if (__err__->type() != Cell::T_ERROR)				\
      throw NIL->mk_error("ll_catch() BUG in %s bad type %s", me, __err__->dump().c_str()); \
    									\
    global_printf("\r[%d] %s ll_catch(): %s\n", millis(), me, __err__->error_get_chars()); \
									\
    ll_debug_catcher;							\
    __code_before_rethrow__;						\
    throw __err__;							\
  }									\
  //

#define ll_catch_terminal						\
  catch (Sexpr_t __err__) {						\
    if (__err__->type() != Cell::T_ERROR)				\
      global_printf("\r[%d] %s ll_catch_terminal: non-error type %d\n",	\
                    millis(), me, __err__->type());			\
    else								\
      global_printf("\r[%d] %s ll_catch_terminal: %s\n",		\
                    millis(), me, __err__->error_get_chars());		\
    ll_debug_catcher;							\
  }									\
  //
//!@}


#endif
