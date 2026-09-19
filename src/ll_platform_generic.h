// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#ifndef LL_PLATFORM_GENERIC_H
#define LL_PLATFORM_GENERIC_H

#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>
#include <setjmp.h>
#include <type_traits>   //!< std::enable_if / std::is_same -- guards AsciiConverter::dec(int), see there
#include "assert.h"
#include "unistd.h"

// Default all LL_ feature flags to 0 so they can be used as C++ values, not just #if guards.
//! TWO MUTUALLY EXCLUSIVE BACKENDS FOR THE SAME API.  Read this before editing either.
//!   LL_ESP_ARDUINO = 1  -> build against ESPRESSIF'S Arduino core (framework-arduinoespressif32).
//!   LL_ARDUINO     = 1  -> build against LAMBLISP'S OWN implementation ("LLArduino").
//!
//! RENAMED 2026-09-18 (B485).  These were `LL_ARDUINO` (Espressif) and `LLARDUINO` (ours) -- ONE
//! UNDERSCORE APART, MEANING OPPOSITE THINGS, and `LLARDUINO` was the only flag in the codebase
//! not carrying the `LL_` prefix every other one uses.  That cost an hour of red master across the
//! whole fleet: `delay_ms` is declared only under OUR backend, a call to it from shared code
//! compiled on the host and broke every ESP32 target, and the author had read the declaration line
//! and still not seen which guard it sat under.  The names now differ by a whole token, and the
//! one that means "Espressif's core" finally SAYS so.
//!
//! Note the swap when reading history: before this rename, `LL_ARDUINO` meant Espressif's core --
//! the OPPOSITE of what it means now.  A commit older than 2026-09-18 that tests `LL_ARDUINO` is
//! talking about `LL_ESP_ARDUINO`.
#ifndef LL_ESP_ARDUINO
#define LL_ESP_ARDUINO       0
#endif
//! LL_ARDUINO was formerly called LL_FAKE_ARDUINO.  RENAMED because "fake" was wrong in the
//! direction that costs something: it reads as a toy, and readers treat toys as untested and
//! optional.  It is neither.  Every Linux and Jetson build runs on it, the whole host test suite
//! runs on it, and the Windows (MinGW) and WebAssembly targets CANNOT use Espressif's core at all -- there
//! this is the only implementation there will ever be.  See w3_ai_exch/proposal_llarduino_P176.md.
#ifndef LL_ARDUINO
#define LL_ARDUINO  0
#endif
#ifndef LL_POSIX
#define LL_POSIX         0
#endif
//! WebAssembly.  LL_WASM is the umbrella ("this is a wasm32 target"); LL_WASI and
//! LL_EMSCRIPTEN name the two HOSTS, which differ only in their I/O and filesystem shims.
//!
//! LL_WASM IMPLIES LL_POSIX HERE, AND THAT IS DELIBERATE: wasi-libc gives us open/read/write/
//! stat/opendir/readdir/clock_gettime, which is every LL_POSIX guard the interpreter core
//! actually needs.  What it does NOT give is the *rest* of what LL_POSIX has historically meant
//! on Linux -- sockets (netdb.h does not exist), termios (termios.h does not exist), and
//! mmap/mprotect with PROT_EXEC (there are no executable pages in wasm at all).  So every
//! LL_POSIX block that reaches for one of those is now spelled `LL_POSIX && !LL_WASM`.
//!
//! THE SYMPTOM IF YOU FORGET: it is NOT a link error.  wasi-libc ships sys/mman.h and
//! sys/socket.h as headers with no working implementation behind them, so the code COMPILES and
//! then fails at run time (or links to a stub that returns -1) -- which is the expensive kind of
//! failure because the build says SUCCESS.  Grep for LL_WASM before adding a POSIX call.
#ifndef LL_WASM
#define LL_WASM          0
#endif
#ifndef LL_WASI
#define LL_WASI          0
#endif
#ifndef LL_EMSCRIPTEN
#define LL_EMSCRIPTEN    0
#endif
//! Native Windows, cross-built with MinGW-w64.  Set by the windows_x86_64 board.
//!
//! LL_WINDOWS IMPLIES LL_POSIX AND SUBTRACTS, exactly as LL_WASM does -- MinGW's msvcrt gives us
//! stdio, open/read/write, stat, <dirent.h> and clock_gettime, which is every LL_POSIX guard the
//! interpreter core actually needs.  What it does NOT give is the rest of what LL_POSIX has meant
//! on Linux: <termios.h> (absent), BSD sockets (Winsock instead -- SOCKET not int, closesocket,
//! WSAPoll), mmap/mprotect with PROT_EXEC (VirtualAlloc instead), and /proc/self/exe.  So an
//! LL_POSIX block reaching for one of those is spelled `LL_POSIX && !LL_WINDOWS`.
//!
//! THE SYMPTOM IF YOU FORGET is a COMPILE error here, not a silent one -- MinGW simply lacks the
//! headers -- which makes this the mild half of the port.  The dangerous half is LLP64: Windows
//! x64 has 32-bit `long` with 64-bit pointers, so anything storing a pointer in a `long` compiles
//! clean and then CORRUPTS, with a GC walking garbage as the first symptom.  That is why Word_t is
//! uintptr_t, and why it carries a static_assert: on this target that
//! assertion is the only thing standing between the cell layout and silent truncation.
#ifndef LL_WINDOWS
#define LL_WINDOWS       0
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
//! Native C-stack budget for eval() recursion.  The recursion guard raises a catchable
//! "recursion too deep" error once eval has grown this many bytes past its outermost
//! frame -- before the real OS stack guard page is hit (which would SIGSEGV/crash the
//! whole process).  Sized below the platform stack: POSIX main thread = 8 MB; ESP32
//! Arduino loopTask = 96 KB (see getArduinoLoopTaskStackSize() in main.cpp).  Override
//! with -DLL_EVAL_STACK_BUDGET=<bytes> per env if a target uses a different stack.
#ifndef LL_EVAL_STACK_BUDGET
  #if LL_WASM
  //! WASM HAS NO 8 MB STACK.  The linear-memory shadow stack is exactly what the LINKER was told
  //! to reserve (`-Wl,-z,stack-size=`, default 64 KB), and overrunning it does not fault -- it
  //! silently walks into static data below __stack_pointer, so the first symptom is corrupted
  //! globals, not a crash at the overrun.  This budget MUST stay below the linker's stack-size in
  //! w3_pio/platforms/wasm32/builder/main.py; change one and you must change the other.
  #define LL_EVAL_STACK_BUDGET  (3UL * 1024 * 1024)   /*!< 3 MB of the 4 MB wasm stack (1 MB headroom) */
  #elif LL_POSIX
  #define LL_EVAL_STACK_BUDGET  (6UL * 1024 * 1024)   /*!< ~6 MB of the 8 MB POSIX stack (2 MB headroom) */
  #else
  #define LL_EVAL_STACK_BUDGET  (40UL * 1024)         /*!< ~40 KB of the 48 KB ESP32 loopTask stack (8 KB headroom); see getArduinoLoopTaskStackSize() in main.cpp -- keep budget < stack so the recursion guard raises a catchable "recursion too deep" before the real stack overflows */
  #endif
#endif

//! FLOOR for a RUNTIME-lowered budget -- see `(recursion-limit N)` (mop3_recursion_limit,
//! ll_vm_mop3_extra.cpp).  The budget is settable from Scheme so a test, or someone hunting a
//! runaway recursion, can make the B70 guard trip at shallow depth instead of after ~39 k frames
//! and ~20 s.  THE CLAMP IS NOT COSMETIC: a budget small enough to be exceeded by the REPL's own
//! frames trips on the very `(recursion-limit ...)` call that would restore it, so the session can
//! only be ended by killing the process -- there is no depth shallow enough to recover from.
//! 16 KB is ~100 eval levels on POSIX (~160 B/level) and ~240 on the ESP32 (~68 B/level): deep
//! enough that a top-level restore always fits, shallow enough that provoking the guard is instant.
#ifndef LL_EVAL_STACK_BUDGET_MIN
#define LL_EVAL_STACK_BUDGET_MIN  (16UL * 1024)
#endif
//! DEFINED HERE, ABOVE THE FIRST USE, ON PURPOSE: LL_NCG_DIRAM_POOL below tests LL_RISCV32,
//! and a #define that lands AFTER its own use reads as 0 -- the guard would silently take the
//! wrong arm on any target that does not pass -DLL_RISCV32 on the command line.
//! ISA flags.  NAME THE ISA, NOT THE CHIP.
//! The Xtensa NCG backend was formerly guarded `#if LL_XTENSA || LL_ESP32`, and
//! LL_XTENSA WAS DEFINED NOWHERE IN THE TREE -- so in practice LL_ESP32 alone selected it.
//! LL_ESP32 means "an Espressif SoC" (heap_caps, Arduino, the 32-bit Word_t typedef); it does
//! NOT mean Xtensa, and every Espressif part newer than the S3 is RISC-V.  An ESP32-C3/C6 env
//! must set -DLL_ESP32=1 for all of the above, and that would have compiled the XTENSA backend
//! into a RISC-V build -- 24-bit Xtensa opcodes fed to an RV32 core.
//! Both flags are now set explicitly per board in w3_pio/boards.json (chip_flags), the guards
//! read `#if LL_XTENSA` / `#if LL_RISCV32`, and a target matching NEITHER fails at LINK with
//! `undefined reference to ncg_make_backend` -- loudly, which is the point.
#ifndef LL_XTENSA
#define LL_XTENSA                         0
#endif
#ifndef LL_RISCV32
#define LL_RISCV32                        0
#endif

//! Size of the NCG executable (D/IRAM) pool.  This comes out of INTERNAL DRAM, the same scarce
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
//! HAS NEVER RUN on those boards.
//!
//! **CORRECTED 2026-09-16: THE POOL IS A RESERVATION, NOT AN ACCESS MECHANISM, AND THE ~368 BYTES
//! MEASURE ONLY ONE OF TWO EXECUTABLE REGIONS.**  Measured on Freenove-ESP32-WROVER with NO POOL AT
//! ALL (`(ncg-exec-pool-tiers)` -> `((diram 0 0))`, because WiFi's reservation preceded it):
//! **29 of 40 procedures compiled to native, 56,753 bytes**, every one of them through the
//! `heap_caps_malloc(MALLOC_CAP_EXEC)` path this note calls unusable.  154x the figure above.
//!
//! WHY, from the ESP32 memory map in soc.h:182-199 --
//!     SOC_IRAM_LOW       0x40080000   SOC_IRAM_HIGH       0x400AA000
//!     SOC_DIRAM_IRAM_LOW 0x400A0000   SOC_DIRAM_IRAM_HIGH 0x400C0000
//!     SOC_DIRAM_DRAM_LOW 0x3FFE0000   SOC_DIRAM_DRAM_HIGH 0x40000000
//! **The IRAM window OVERLAPS the D/IRAM region** (0x400A0000-0x400AA000), so MALLOC_CAP_EXEC is
//! not confined to the IRAM-ONLY area that static code consumes -- it also draws from D/IRAM, which
//! is the SAME PHYSICAL SRAM the pool reserves.  Confirmed from the addresses: native code compiled
//! on the WROVER with no pool landed at 0x3fff0030, 0x3fff042c, 0x3fff0460 -- inside
//! SOC_DIRAM_DRAM, not in the IRAM-only window.
//!
//! SO THE POOL'S VALUE IS TIMING, NOT CAPABILITY.  D/IRAM is dual-bus and executable whether or not
//! anything reserved it; `heap_caps_malloc(MALLOC_CAP_EXEC)` takes it on demand.  What the pool buys
//! is claiming that memory EARLY, before the `.scm` chain and the radio spend the same region as
//! DATA.  "NCG has never run on those boards" described a state in which D/IRAM had been exhausted
//! by the time anything tried to compile -- not a hardware limit, and not a property of
//! MALLOC_CAP_EXEC.  Do not read the ~368 figure as the executable memory available on an LX6.
//!
//! **THE NUMBER WAS ON THE CONSOLE THE WHOLE TIME.**  `main.cpp:201` prints, at every boot, 43 ms
//! in, before LambLisp claims anything:
//!
//!     [43] ::setup() free EXEC/IRAM heap: 110924 bytes          <- Freenove-ESP32-WROVER
//!
//! **110,924 bytes free**, while this note said ~368 and called 32 KB "the only fast exec memory it
//! will ever have".  The silicon reason is the ESP32 datasheet's three-block internal SRAM:
//! SRAM0 (192 KB, instruction bus), **SRAM1 (128 KB, BOTH buses -- 0x3FFE0000-0x40000000 as data,
//! 0x400A0000-0x400C0000 as instructions)**, SRAM2 (200 KB, data only).  SRAM1 is one physical
//! memory behind two windows, so anything written through the data view executes through the
//! instruction view; `SOC_DIRAM_INVERTED 1` only means that view runs backwards on this part.
//!
//! SO THERE ARE TWO EXECUTABLE REGIONS AND THE ~368 MEASURED THE OTHER ONE.  The SRAM0 tail
//! (0x40080000-0x400A0000) is executable but is where static code links, and lies outside
//! SOC_BYTE_ACCESSIBLE (which ends at 0x40000000) so it is MALLOC_CAP_32BIT rather than 8BIT.  That
//! region really does have ~368 bytes free.  It is not the region generated code lands in.
//!
//! WHAT IS STILL TRUE: SRAM1's 128 KB is CONTESTED -- the .scm chain, LittleFS buffers and the radio
//! all draw from it as DATA -- so the usable figure is whatever remains, not 128 KB, and there is no
//! overflow tier when it is gone.  That is the real mechanism behind "NCG has never run on those
//! boards": a race for SRAM1, not a hardware wall.
//!
//! AND THE LESSON, which is the same one P211 paid for the same day: a printed number read through a
//! belief that makes it unremarkable is not evidence, it is decoration.  `after setup.scm load` had
//! shown 70 KB for months and was read as "the Scheme library is expensive" rather than "one form
//! costs 48 KB".  This one had shown 110,924 at every boot.  It presents as `alloc_exec: heap_caps_malloc(N) FAILED` and
//! then as tests that quietly SKIP because the driver could not be compiled.
//! Keying a capability off a chip model also means the only way to enable it on another chip is to
//! claim to BE that chip, which puts a false -DLL_ESP32S3 on a non-S3 board and breaks every other
//! thing that flag legitimately selects.  Name the capability; let each SoC declare whether it has it.

//! ESP32-C3 / C6 (RISC-V) -- WHY THEY ARE NOT IN THIS LIST YET.
//! The ADDRESSING is already solved for them: the C3 has the same aliased D/IRAM shape as the
//! S3 (soc.h SOC_DIRAM_DRAM_LOW 0x3FC80000 / IRAM_LOW 0x40380000, no SOC_DIRAM_INVERTED) and on
//! the C6 both LOWs are 0x40800000, so esp_ptr_diram_dram_to_iram() degenerates to the identity
//! and alloc_exec's per-word mapping is correct on both AS WRITTEN, with no #if.
//! What is NOT solved is PERMISSION, and it is a different question from addressing: the stock
//! Arduino sdkconfig ships CONFIG_ESP_SYSTEM_MEMPROT_FEATURE=y (+ _LOCK=y) on the C3 and
//! CONFIG_ESP_SYSTEM_PMP_IDRAM_SPLIT=y on the C6, and the IDF's own Kconfig says allocating with
//! MALLOC_CAP_EXEC is not possible while that is on.  The S3 works only because ITS shipped
//! config has memprot OFF -- a Kconfig default, NOT a capability the C-series lost
//! (SOC_CPU_IDRAM_SPLIT_USING_PMP is a switch; MALLOC_CAP_EXEC is still defined there).
//! So this is a BUILD-CONFIGURATION question with a known switch, not a hardware wall -- and it
//! requires a real C3 and a real C6 and has NOT been run.  Turning the pool
//! on here without that measurement would claim a capability nobody has observed; leaving it off
//! costs only speed, because a failed alloc_exec makes ncg_compile fall back to the bytecode
//! interpreter, which is a supported state.  When Phase 0 passes, add the chip here AND give it
//! its own LL_NCG_EXEC_POOL_BYTES measured against a LittleFS read in the same run.
//! The `&& !LL_RISCV32` is load-bearing, not tidiness: a C-series env sets -DLL_ESP32=1 (it needs
//! heap_caps, Arduino and the 32-bit Word_t), so without it the pool would switch ON for a chip
//! whose Phase 0 has never been run.  It would not fail politely either -- ncg_exec_pool_init()
//! only checks that the block is IN the D/IRAM range, which it is, so the pool would be USED and
//! the first call into it would fault on the PMP/PMS split, i.e. a crash instead of the graceful
//! "compile fell back to bytecode".
#ifndef LL_NCG_DIRAM_POOL
  #if (LL_ESP32S3 || LL_ESP32) && !LL_RISCV32
    #define LL_NCG_DIRAM_POOL 1
  #else
    #define LL_NCG_DIRAM_POOL 0
  #endif
#endif

//! LL_NCG_RISCV_POOL -- the same idea as LL_NCG_DIRAM_POOL, for a C-series part whose PMP split
//! has been cleared.  RESERVE EARLY OR NOT AT ALL: measured on c5-01, internal DRAM free is
//! ~106 KB at pool-init time (largest block ~90 KB), ~33 KB once idle at the REPL, and ~10 KB
//! during a perf sweep -- at which point a 2,180-byte exec allocation FAILS on fragmentation, and
//! the NCG column comes out empty for a reason that has nothing to do with code generation
//! (P173 sec.11.6f).  A pool taken at init survives that, because it is taken before the heap is
//! carved up.
//!
//! EVERY W^X STATEMENT IN THIS FILE IS ABOUT **INTERNAL SRAM**, AND NEVER ABOUT PSRAM.  [B408]
//! On both the S3 and the C5, ALL PSRAM is simultaneously writable and executable, and neither
//! part offers any mechanism to subdivide it or mark a region non-executable -- so there is no
//! W^X property to enforce or lose there, whatever the PMP is doing on-die.  This matters because
//! the NCG's executable pool lives in exactly that memory on the tiers that use PSRAM: an
//! unqualified "the PMP enforces W^X" is true of the SRAM path and false of the memory the
//! generated code actually runs in, and a reader who takes the general reading concludes this
//! system has a memory-protection property it does not have.  Say which memory, every time.
//!
//! CONDITIONED ON LL_C5_PMP_RWX, AND THAT IS LOAD-BEARING.  Without the flag the PMP still
//! enforces W^X ON INTERNAL SRAM, so this pool would be allocated, would pass any range check, would be USED, and
//! the first call into it would fault -- turning a graceful fall-back-to-bytecode into a crash.
//! That is exactly the failure the LL_NCG_DIRAM_POOL comment above warns about for a chip whose
//! Phase 0 has not been run, and the same reasoning applies here in reverse: the flag IS the
//! evidence that Phase 0 passed on this build.
//!
//! NO D/IRAM ALIAS, DELIBERATELY.  The Xtensa pool keeps two pointers because instruction and data
//! reach the same bytes through different windows.  A C-series part has SOC_MMU_DI_VADDR_SHARED
//! -- one address space -- so the write pointer and the exec pointer are the same value, and
//! translating would be wrong rather than merely redundant.
//! B382/B389, P173 sec.12.3 option (c): THE ON-DIE TIER NO LONGER REQUIRES DISABLING W^X
//! ON INTERNAL SRAM.
//! It used to be gated on LL_C5_PMP_RWX alone, which empties esp_cpu_configure_region_protection()
//! and leaves ALL internal SRAM writable AND executable -- "Do not ship enabled", per that file's
//! own banner, and B367 removed it from the deliverable envs for exactly that reason.  The cost of
//! removing it was measured in B382: with no on-die tier every NCG function executes from PSRAM
//! over quad-SPI and `gc-ctrl-worst` went 6 us -> 273 us, a 45x latency regression that a
//! throughput benchmark cannot see (allocation rate differed by 0.4%).
//!
//! LL_C5_NCG_ARENA is the W^X-PRESERVING route to the same tier: w3_c5_pmp_arena.c owns the PMP
//! layout and carves ONE naturally-aligned RWX region for generated code, leaving the IDRAM split
//! intact everywhere else.  So either flag enables the on-die pool, and they are mutually
//! exclusive by #error in that file -- both replace the same symbol.
#ifndef LL_NCG_RISCV_POOL
  #if LL_RISCV32 && ((defined(LL_C5_PMP_RWX) && LL_C5_PMP_RWX) || \
                     (defined(LL_C5_NCG_ARENA) && LL_C5_NCG_ARENA))
    #define LL_NCG_RISCV_POOL 1
  #else
    #define LL_NCG_RISCV_POOL 0
  #endif
#endif

//! B367, AND IT STILL APPLIES TO LL_NCG_PSRAM_EXEC BELOW: the PSRAM exec tier is DELIBERATELY NOT
//! gated on LL_C5_PMP_RWX.  It used to live inside `#if LL_NCG_RISCV_POOL`, which requires that
//! flag, so a build that KEPT W^X got no native code generation at all -- making a customer C5 a
//! choice between NCG and memory protection that the hardware never required.
//! From the C5's own cpu_region_protect.c: with CONFIG_SPIRAM_PRE_CONFIGURE_MEMORY_PROTECTION unset
//! (it is), the MSPI window takes `PMP_ENTRY_SET(6, NAPOT(IROM), RWX)`, commented "Add the W
//! attribute in the case of PSRAM".  That entry is INDEPENDENT of CONFIG_ESP_SYSTEM_PMP_IDRAM_SPLIT,
//! which governs INTERNAL SRAM only -- so PSRAM executability was never blocked by the split, and
//! clearing the split was never what made it work.  (B408 records the flip side: that same entry is
//! why NO PSRAM can be made non-executable on this part.)
//!
//! THE DIVISION OF LABOUR:
//!   LL_NCG_RISCV_POOL  (internal 32 KB, hot)  -- NEEDS the flag.  Without it the PMP still enforces
//!       W^X on internal SRAM, so that pool would allocate, pass every range check, be USED, and
//!       fault on the first call into it.  Keep it flag-gated.
//!   LL_NCG_PSRAM_EXEC  (on demand, unbounded) -- needs only a part with PSRAM.
//! A build WITHOUT the flag therefore keeps W^X on internal SRAM, loses the fast tier, and still
//! generates native code into PSRAM.  Running out of fast memory costs SPEED, not the whole tier.

//! LL_NCG_PSRAM_EXEC -- CAN GENERATED CODE RUN FROM PSRAM ON THIS TARGET?
//!
//! This replaced a POOL (LL_NCG_XMMU_POOL / LL_NCG_PSRAM_POOL, both with a 1 MB cap) on 2026-09-14.
//! The pool mapped a fixed arena with esp_mmu_map() and bump-allocated from it, and every part of
//! that turned out to be unnecessary -- P173 sec.13.11 has the full argument; the short form:
//!
//!   * ALL PSRAM IS ALREADY EXECUTABLE ON BOTH ARCHITECTURES, and neither the pool nor esp_mmu_map
//!     made it so.  Measured on three boards.  See B408: there is no mechanism on either part to
//!     make any PSRAM non-executable, so this is a property of the silicon, not a grant.
//!   * THE FRAGMENTATION ARGUMENT INVERTS AT THIS SIZE.  "Reserve early or not at all" is real and
//!     measured -- in INTERNAL DRAM (P173 sec.11.6f: ~10 KB free mid-sweep, a 2,180-byte request
//!     refused).  That is why LL_NCG_EXEC_POOL_BYTES below still reserves.  PSRAM has 1.6-15 MB
//!     free, and the POOL is the fragile allocation there: it wants ONE CONTIGUOUS 192 KB-1 MB
//!     block, while a compiled procedure wants 200 B-2 KB.  Fragmentation kills large contiguous
//!     requests and spares small ones, so the reservation defended only against a failure it
//!     created.
//!   * A BUMP ARENA CAN NEVER RECLAIM.  On-demand allocation can heap_caps_free() a procedure that
//!     is discarded; that is why both pool caps existed at all, and why B389 called the pool a
//!     permanent claim on system memory.
//!
//! DO NOT REINTRODUCE A CAP HERE.  A cap on an on-demand allocator would only stop native code
//! being generated while memory remained -- the exact failure an "overflow tier" exists to prevent.
#ifndef LL_NCG_PSRAM_EXEC
  #if defined(BOARD_HAS_PSRAM) && (LL_ESP32S3 || LL_RISCV32)
    #define LL_NCG_PSRAM_EXEC 1
  #else
    #define LL_NCG_PSRAM_EXEC 0
  #endif
#endif

//! LL_NCG_PSRAM_ALIAS -- does this target need the DBUS->IBUS address transform, or is the data
//! pointer directly executable?
//!
//!   Xtensa S3: TRANSFORM.  Data and instructions reach PSRAM through different windows
//!              (0x3C…… and 0x42……) onto the same MMU entry, so the exec pointer is
//!              `w - SOC_DRAM0_CACHE_ADDRESS_LOW + SOC_IRAM0_CACHE_ADDRESS_LOW`.  This is the same
//!              shape as LL_NCG_DIRAM_POOL's D/IRAM alias for internal memory, one window further
//!              out.  Verified on esp32-s3-devkitc-1 (2 MB quad) and esp32s3-n32r16-00 (16 MB
//!              octal), at linear offsets 0x2686b0 and 0x392524 -- different memory types, different
//!              regions of the window, both `P173-ALIAS result=42`.
//!   RISC-V C5: NONE.  SOC_MMU_DI_VADDR_SHARED -- one address space, so the write pointer IS the
//!              exec pointer and a transform would be wrong rather than redundant.
//!
//! THE CLASSIC ESP32 (LX6) IS DELIBERATELY EXCLUDED FROM LL_NCG_PSRAM_EXEC ABOVE, and this is the
//! reason: its D/IRAM window is address-INVERTED (SOC_DIRAM_INVERTED), which already cost this
//! codebase one HANG-not-a-crash when a sequential memcpy through the DRAM alias laid an
//! instruction stream out backwards -- see the note in NcgBuffer::alloc_exec.  Its external window
//! has not been tested and the IDF refuses esp_mmu_map for PSRAM there entirely
//! (`#if !SOC_SPIRAM_SUPPORTED || CONFIG_IDF_TARGET_ESP32`).  It keeps the internal pool only.
//! Do not widen the guard without running the probe's alias arm on a 4WD or WROVER first.
#ifndef LL_NCG_PSRAM_ALIAS
  #if LL_NCG_PSRAM_EXEC && LL_ESP32S3 && !LL_RISCV32
    #define LL_NCG_PSRAM_ALIAS 1
  #else
    #define LL_NCG_PSRAM_ALIAS 0
  #endif
#endif

//! LL_WIFI_RESERVE_BYTES -- what the radio stack costs, held from installer time until WiFi.begin().
//!
//! MEASURED, not guessed: 48,752 bytes on esp32-s3-eye, attributed to a SINGLE FORM by the
//! form-level heap note -- `[heap] FORM WiFi.scm :: when  INT 113160 -> 64408 (-48752)` -- and it
//! takes the largest contiguous block from 69,620 to 31,732 at the same instant.
//!
//! WHY A CONSTANT AND NOT A MEASUREMENT AT RUNTIME: the reservation must be made BEFORE the radio
//! runs, so there is nothing to measure yet.  That makes this a number that WILL drift as the IDF's
//! WiFi stack changes, and drift silently, which is the defect this whole proposal exists to fight.
//! The mitigation is that it is best-effort in BOTH directions -- an under-reserve leaves the radio
//! to allocate the remainder as it does today, an over-reserve is handed back at WiFi.begin() -- so
//! being wrong costs ordering quality, never correctness.  Re-measure it with the form note when
//! the IDF moves; the note is threshold-gated and prints only when something crosses 2 KB.
//!
//! 48 KB, not 48,752: a reservation is a hole, and a round hole is easier to reason about than a
//! number that looks measured to the byte on a board it was not measured on.
#ifndef LL_WIFI_RESERVE_BYTES
  #define LL_WIFI_RESERVE_BYTES  (48UL * 1024)
#endif

#ifndef LL_NCG_EXEC_POOL_BYTES
  #if LL_NCG_RISCV_POOL
    //! ESP32-C5: 32 KB, taken at init where ~90 KB contiguous is available (measured on c5-01:
    //! `[heap] after cell+ncg pools INT free=106624 largest=90100`).  PROVISIONAL -- unlike the
    //! S3's 32 KB, this one has not yet been pushed to the point of filling,
    //! so treat it as a starting value and shrink it if internal DRAM proves tighter in a full
    //! sweep.  It is 32 KB and not more because internal DRAM is the scarce resource on this part
    //! (AI_RULES: nine peripheral drivers already cost 38 KB of it).  NOTE, corrected 2026-09-13:
    //! an earlier version of this comment ended "while 7.8 MB of PSRAM sits unused and cannot help
    //! -- executable memory must be internal."  That is FALSE on this part and it is the premise
    //! B367 was filed on; PSRAM is executable here (see LL_NCG_PSRAM_POOL above).  The 32 KB is a
    //! SPEED choice -- on-die SRAM versus quad-SPI at 80 MHz -- not a correctness one.
    #define LL_NCG_EXEC_POOL_BYTES  (32UL * 1024)
  #elif LL_ESP32S3
    #define LL_NCG_EXEC_POOL_BYTES  (32UL * 1024)
  #elif LL_ESP32
    //! THE CLASSIC ESP32 (LX6) GETS 32 KB TOO, AND IT IS THE ONLY FAST EXEC MEMORY IT WILL EVER
    //! HAVE.  Corrected 2026-09-14: the C5 comment above read "unlike the S3's 32 KB and the ESP32's
    //! 12 KB" -- a number this file has never defined.  A record disagreeing with the code fifteen
    //! lines below it, in the same file.
    //!
    //! SHRINKING THIS MEANS SOMETHING DIFFERENT HERE THAN ON THE OTHER PARTS, and that is the
    //! reason for this comment.  On the S3 and the C5, memory taken back from the pool converts FAST
    //! native code into SLOWER native code, because PSRAM catches the overflow.  On this chip there
    //! is no overflow: it converts native code into INTERPRETED code.  So B389's "give the 32 KB
    //! back" argument does not transfer -- same constant, different trade.
    //!
    //! WHY THERE IS NO OVERFLOW TIER, settled 2026-09-14 and not worth re-deriving:
    //! `SOC_SPIRAM_XIP_SUPPORTED` is defined for the S3 and NOT for this part -- Espressif's own
    //! capability macro.  The cause is routing: SOC_EXTRAM_DATA_LOW is 0x3F800000, south of
    //! 0x40000000 and therefore on the data bus, while instruction fetch needs >= 0x40000000.
    //! Measured on the 4WD: cache_sram_mmu_set() answers rc=5 for an instruction-window vaddr, and
    //! unmasking the IRAM1 cache bus at runtime to try again HUNG THE BOARD.  The only reported
    //! workaround is a hardware modification.  P173 sec.13.16.
    #define LL_NCG_EXEC_POOL_BYTES  (32UL * 1024)
  #else
    #define LL_NCG_EXEC_POOL_BYTES  (32UL * 1024)
  #endif
#endif
//! Hard cap on the GC rootstack (entries).  Each non-tail recursion level pushes ~5 roots, so this
//! sets the rootstack-bound recursion depth.  Since the markstack now grows on demand (
//! GC_MarkStack::push), the rootstack is no longer coupled to a fixed 65536 markstack and can be sized
//! so the non-expandable **C stack** (LL_EVAL_STACK_BUDGET) is the binding limit: a POSIX 8 MB stack
//! reaches ~40 k depth (~215 k roots) before the C-stack guard fires, so 262144.  On the ESP32 the
//! C stack caps depth long before 65536 roots, so the cap there is irrelevant -- keep it small.
//! THE ESP32 DEPTH IS 165, NOT THE ~600 THIS COMMENT USED TO CLAIM (measured 2026-09-11 on
//! esp32s3-n8r2-00: `(define (d n) (set! m n) (+ 1 (d (+ n 1))))` trips the guard at n=165).  The
//! ~600 was computed against a 96 KB loopTask stack; B95 HALVED THAT TO 48 KB and lowered
//! LL_EVAL_STACK_BUDGET to 40 KB to match, and nobody re-derived the depth -- so the number stayed
//! ~3.6x too optimistic for months, here and in CLAUDE.md.  Depth is per-form, not a constant: it
//! is budget / bytes-of-C-frame-per-eval-level, and a fatter Scheme frame reaches the wall sooner.
//! If you change the loopTask stack or the budget again, RE-MEASURE and update this line.
//! Each entry is a Sexpr_t (8 B) -> POSIX 2 MB; the markstack mirrors it transiently during a mark.
#ifndef LL_ROOTSTACK_MAX
  #if LL_WASM
  //! Sized from LL_EVAL_STACK_BUDGET above (3 MB, not the POSIX 6 MB), same ~5 roots per level.
  #define LL_ROOTSTACK_MAX  131072
  #elif LL_POSIX
  #define LL_ROOTSTACK_MAX  262144
  #else
  #define LL_ROOTSTACK_MAX  65536
  #endif
#endif
//! Physical slack allocated above LL_ROOTSTACK_MAX so the overflow error path (which itself
//! allocates a T_ERROR and pushes a few roots) has real buffer instead of writing out of bounds.
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
#ifndef LL_WASM32
#define LL_WASM32                         0
#endif

//! ===========================================================================
//! THE "DEMO PROFILE" SWITCHES -- factored here ONCE because the Windows (MinGW) and WebAssembly
//! (WebAssembly) need byte-for-byte the same exclusion set, and two proposals each carrying
//! their own copy of the list is how the two drift apart.
//!
//!   LL_NETWORK  0 -> no BSD/WiFi sockets at all (TCP client/server ports, LLIP over TCP).
//!   LL_TERMIOS  0 -> no raw terminal mode; line-at-a-time stdio only.
//!   LL_NCG      0 -> no native code generator; the AST and bytecode tiers are the runtime.
//!
//! Each DEFAULTS to what the platform historically had, so no existing target changes; a port
//! that cannot provide one sets it to 0 in its build_flags and every guard follows.
//!
//! WHY THESE ARE SEPARATE FROM LL_POSIX: LL_POSIX has quietly meant three unrelated things --
//! "has open/read/write", "has sockets", and "has termios".  wasm32-wasi is the first target to
//! have the first without the other two, so the single flag stopped being able to express the
//! platform.  A guard that means "has a socket" must now SAY so.
//! ===========================================================================
#ifndef LL_NETWORK
  #if LL_WASM
  #define LL_NETWORK  0	//!< browsers have no raw TCP (WebSocket only); WASI sockets are incomplete
  #else
  #define LL_NETWORK  ((LL_WIFI) || (LL_POSIX))
  #endif
#endif
//! Sockets that specifically come from the BSD/POSIX implementation (the
//! posix_fd paths), as opposed to the Arduino WiFi ones.
#define LL_POSIX_NET  ((LL_POSIX) && (LL_NETWORK))

#ifndef LL_TERMIOS
  #if LL_WASM
  #define LL_TERMIOS  0	//!< wasi-libc has no termios.h at all -- not a stub, the header is absent
  #else
  #define LL_TERMIOS  (LL_POSIX)
  #endif
#endif

//! LL_NCG -- is a native code generator COMPILED IN at all.
//! WASM IS A BUILD TARGET, NOT AN NCG BACKEND, and that is a design decision, not a gap to fill
//! later: wasm is a stack machine with structured control flow and no
//! self-modifying code, the host engine already JITs it, and emitting wasm from our
//! register-machine backends would be a JIT feeding a JIT.  If you are here because you want to
//! "add a wasm NCG backend", read that section first.
#ifndef LL_NCG
  #if LL_WASM
  #define LL_NCG  0
  #else
  #define LL_NCG  1
  #endif
#endif

//! LL_AUTOCOMPILE -- what the RUNTIME compiles for itself at startup, in main.cpp:
//!   0  leave every procedure as an AST (T_PROC), compile nothing
//!   1  run (compile-environment!)       -- AST -> bytecode
//!   2  also run (ncg-compile-environment!) -- bytecode -> native
//!
//! DEFAULT 2 WHERE THERE IS A BACKEND.  Until now this was set ONLY by the linux_x86_64_bc and
//! linux_x86_64_ncg diagnostic envs, so every shipping build booted fully interpreted and the
//! bytecode and native paths -- the whole point of the runtime -- ran only when a test asked for
//! them.  The startup census added alongside this reports the result, so the mode a board is
//! actually in is visible at boot rather than inferred.
//!
//! wasm gets 1, not 2: LL_NCG is 0 there (the host engine already JITs; see the note above), so
//! asking for a native pass would be asking a backend that does not exist.
//!
//! READ THIS BEFORE SHIPPING IT ON AN MCU.  On ESP32 the native code pool is 32 KB and
//! ncg-compile-environment! is DESIGNED to consume it down to a floor -- ncg_exec_budget_low()
//! stops at pool_free < 4096, and the last compile overshoots (measured: 1608 free of 32768,
//! [B389]).  Doing that at BOOT means every procedure the user defines afterwards, and every test
//! that compiles one, starts against a pool that is already spent.  On the host this is free --
//! the pool is megabytes -- so a green host build says nothing about it.  [B389] is the open
//! measurement of what that costs; do not read a passing linux run as clearance for a board.
//! DEFAULT 1 -- COMPILE EVERYTHING TO BYTECODE, NOTHING TO NATIVE.  Not a compromise; it follows
//! from where the two things live.  BYTECODE IS ORDINARY HEAP.  NATIVE CODE IS THE 32 KB EXEC
//! POOL.  Compiling every procedure to bytecode costs nothing scarce.  Compiling them to native
//! spends a small fixed shared resource that is never reclaimed -- so native must be rationed, and
//! rationing by "whatever the environment hash-walk reaches first" is not rationing.
//!
//! MEASURED on esp32s3-n8r2-00, 2026-09-14, with the blanket LL_AUTOCOMPILE=2 this replaces:
//!
//!     auto-compile: 230 procedures compiled
//!     ncg_compile_env() exec budget spent -- stopping (pool free 2896 of 32768)
//!     ncg-compile: 18 procedures compiled
//!     execution modes: AST 2  BC 212  NCG 18  (232 procedures)
//!
//! 18 of 230 reached native -- 8% -- for 91% of the pool.  The 18 were whichever the walk reached
//! first: WS2812.setAll, WS2812.setLedColorData, Buzzer.click, Sonar.start, diffie-hellman-keygen,
//! define-library, csv-opt, cddadr ... device drivers and rare library calls.  The pool bought
//! nothing and was then unavailable to code that mattered -- including the benchmark harness, which
//! must get ~14 procedures native to measure the NCG path at all ([B343] is what a perf row looks
//! like when it silently does not).
//!
//! SO: 1 here, with SELECTIVE native compilation layered on top -- a prioritised, per-application
//! list ([P205]).  That needs no new C++: `procedure->bytecode` puts a procedure in bytecode,
//! `ncg-compile-transitive!` takes it native, and bench-runner has driven both from an explicit
//! list for months.  What is missing is only where the list lives and who supplies it per target.
//!
//! wasm gets 1 and never 2: LL_NCG is 0 there (the host engine already JITs).  The linux_x86_64_bc
//! (=1) and linux_x86_64_ncg (=2) diagnostic envs set it explicitly and are unaffected; on a host
//! the pool is megabytes, so a blanket native pass is genuinely free there.
#ifndef LL_AUTOCOMPILE
  #define LL_AUTOCOMPILE  1
#endif


//! LL_XTENSA / LL_RISCV32 -- NAME THE ISA, NOT THE CHIP.
//!
//! An NCG backend is selected by INSTRUCTION SET, and nothing in this tree previously said
//! so.  `LL_XTENSA` was referenced by the backend guard and DEFINED NOWHERE -- grep the
//! whole tree and it appears only inside `#if LL_XTENSA || LL_ESP32` -- so the Xtensa backend was
//! in practice selected by **LL_ESP32 alone**.
//!
//! THE CONSEQUENCE, and it is the reason this block exists rather than a comment: every Espressif
//! part newer than the ESP32-S3 is RISC-V (C2, C3, C5, C6, C61, H2, P4).  Such a target MUST set
//! -DLL_ESP32=1 -- it needs heap_caps, the Arduino core, and the ESP32 branch of the platform
//! layer -- and the moment it does, it compiles the XTENSA CODE GENERATOR into a RISC-V binary.
//! That is not a build error; it emits Xtensa opcodes into a buffer and jumps to them.
//!
//! This is the identical defect the LL_NCG_DIRAM_POOL note above documents -- keying a capability
//! off a chip model means the only way to enable it elsewhere is to CLAIM TO BE that chip -- and
//! the LX6 boards already lost NCG entirely to that mistake once.
//!
//! Both default to 0, and the existing Xtensa envs now pass -DLL_XTENSA=1 EXPLICITLY, so current
//! behaviour is preserved by statement rather than by omission.  A target that sets neither gets
//! `ncg_make_backend()` returning nullptr (the complement guard) and therefore runs the bytecode
//! interpreter -- a SUPPORTED state, but since P200 R1 ONLY WHEN IT IS DECLARED: that complement
//! guard now `#error`s if LL_NCG is on and no ISA above matched, because LL_NCG DEFAULTS TO 1
//! (see its definition just above) and "no backend" was therefore reachable by OMISSION -- a new
//! ISA with no flag built clean and ran bytecode while its benchmarks still said NCG (B343).
//! Declare the absence with -DLL_NCG=0 in the env's build_flags, as wasm32_wasi, wasm32_browser
//! and windows_x86_64 do.  If you add an ISA here, add it to that complement guard too, or you
//! get a duplicate symbol instead of a missing one.
#ifndef LL_XTENSA
#define LL_XTENSA        0                //!<Tensilica Xtensa LX6/LX7 (ESP32, ESP32-S2/S3).
#endif
#ifndef LL_RISCV32
#define LL_RISCV32       0                //!<32-bit RISC-V (RV32IMC): ESP32-C/H/P series, and others.
#endif


//! Backend selection.  See the note at the flag definitions above: LL_ESP_ARDUINO is Espressif's core,
//! LL_ARDUINO is ours -- one underscore apart, opposite meanings.
#if LL_ESP_ARDUINO
#include "Arduino.h"
#endif

//! LLArduino: LambLisp's own implementation of the Arduino API.  Not a stub and not a
//! fallback -- it is the ONLY backend on POSIX, WASM and Windows, and it is what the entire host
//! test suite exercises.  Anything added here is API SURFACE WE OWE ON EVERY TARGET.
#if LL_ARDUINO
#include <string.h>

unsigned long millis();
unsigned long micros();
/*! B485: `delay_ms` IS THE NON-PORTABLE SPELLING, DESPITE LOOKING LIKE THE PORTABLE ONE.
    It is declared HERE and only here -- inside `#if LL_ARDUINO`, LambLisp's own backend, which is
    what POSIX, WASM and Windows use.  A real ESP32 builds LL_ESP_ARDUINO (Espressif's core) instead and
    has no such name.  So a call to delay_ms() from code SHARED between host and MCU compiles
    cleanly on the host and breaks every firmware target -- which is exactly what 72eba89 did to the
    whole fleet for an hour, from inside `#if LL_WIFI || LL_POSIX_NET`, a guard true on both.

    USE `delay()` IN SHARED CODE.  It exists on both backends: Arduino.h provides it under
    LL_ESP_ARDUINO, and the forwarder just below provides it under LL_ARDUINO.  The portable-looking
    name is the trap and the plain one is the safe choice -- the reverse of the usual instinct.

    A host-only build CANNOT catch this.  `w3 make one esp32s3-n8r2` catches it in ~22 seconds, and
    nothing in the pipeline compiles a firmware target on commit. */
void delay_ms(unsigned long ms);

static void delay(unsigned long ms) { delay_ms(ms); }

//! LLArduino GPIO surface, implemented by a BACKEND -- the null backend simulates it in
//! memory; a libgpiod backend drives real pins on a Pi or Jetson.  These are the eight functions
//! ll_xmop3_CommonIO.cpp actually calls; without them `commonio` cannot compile off-Arduino, which
//! is why 26 Scheme procedures were ESP32-only and untestable without a board.
//! Arduino spells the constants as macros, so match that rather than inventing an enum.
#ifndef HIGH
#define HIGH          1
#define LOW           0
#endif
#ifndef INPUT
#define INPUT         0x0
#define OUTPUT        0x1
#define INPUT_PULLUP  0x2
#endif

void pinMode(int pin, int mode);
void digitalWrite(int pin, int val);
int  digitalRead(int pin);
void analogWrite(int pin, int val);
int  analogRead(int pin);
void tone(int pin, unsigned int freq);
void tone(int pin, unsigned int freq, unsigned long dur);
void noTone(int pin);
void delayMicroseconds(unsigned long us);

//! Backend inspection -- lets a test assert on state the Arduino API cannot report (mode, duty,
//! tone) and name which backend answered.  See ll_llarduino_null.cpp.
int         ll_llarduino_pin_mode(int pin);
int         ll_llarduino_pin_duty(int pin);
int         ll_llarduino_pin_tone(int pin);
int         ll_llarduino_npins();
const char *ll_llarduino_backend();

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

//! MOVED HERE, and it must stay below this point: Print uses String (typedef at
//! `typedef LL_String String` above) and CHECKPRINTF_pos2 (defined just above).  Declared any
//! earlier in this header and the compiler reports "String does not name a type" -- which is a
//! header-ordering error, not a missing class.

//! GUARDED, AND IT MUST BE.  On ESP32 the VENDOR Arduino core defines its own Print and Stream
//! (cores/esp32/Print.h, Stream.h) via Arduino.h, so declaring these unconditionally is a
//! "redefinition of class Print" build failure on every ESP32 target.  It compiled clean on the
//! hosts because there is no Arduino core there to collide with -- which is exactly why the
//! mistake was invisible until an ESP32 build ran.  When this block was moved down here to sit
//! below the String typedef it left the LL_ARDUINO guard that ends further up; it now carries its
//! own.  LLArduino PROVIDES these where the vendor core is absent, and defers to it where present.
#if LL_ARDUINO
//! LL_ARDUINO Print / Stream / Serial.  NOT STUBS, and they need not be: Print and Stream are
//! pure character I/O, and LambStdio ALREADY implements exactly that on POSIX (stdin/stdout in
//! non-canonical mode).  So this is an Arduino-SHAPED FACADE over working I/O, in the same class as
//! millis() -- genuinely implemented, not simulated.  It is what lets sketch-style code
//! (`Serial.println("hi")`) run on a host with no board, and on WebAssembly and Windows,
//! where Espressif's core cannot go at all.
//!
//! FIDELITY IS THE RISK HERE, not capability.  Arduino's Print has behaviours worth matching
//! DELIBERATELY rather than by accident, and each is a place a host test could pass while the
//! device disagrees: println() terminates CRLF ("\r\n") not "\n"; write() returns a BYTE COUNT;
//! print(double, digits) defaults to 2 decimal places; print(int, base) supports BIN/OCT/DEC/HEX.
//! Those are exactly what success criterion 3 exists to check -- the same suite run against
//! the vendor core and against LLArduino must agree.
class Print {
public:
  virtual ~Print() {}
  virtual size_t write(uint8_t c) = 0;
  virtual size_t write(const uint8_t *buf, size_t n);
  size_t write(const char *s);
  size_t print(char c);
  size_t print(const char *s);
  size_t print(const String &s);
  size_t print(int n, int base = 10);
  size_t print(long n, int base = 10);
  size_t print(unsigned long n, int base = 10);
  size_t print(double v, int digits = 2);
  size_t println();                                  //!< CRLF, as Arduino does -- not "\n"
  size_t println(char c);
  size_t println(const char *s);
  size_t println(const String &s);
  size_t println(int n, int base = 10);
  size_t println(long n, int base = 10);
  size_t println(unsigned long n, int base = 10);
  size_t println(double v, int digits = 2);
  size_t printf(const char *fmt, ...) CHECKPRINTF_pos2;   //!< HardwareSerial::printf, used by LL itself
};

class Stream : public Print {
public:
  virtual int available() = 0;
  virtual int read()      = 0;
  virtual int peek()      = 0;
  virtual void flush()    {}
};

//! Serial over LambStdio.  peek() is implemented HERE because LambStdioClass has no peek: one byte
//! of pushback, which is all Stream promises.
class LLArduinoSerial : public Stream {
  int  _peeked;                                      //!< -1 = empty
public:
  LLArduinoSerial() : _peeked(-1) {}
  void begin(unsigned long baud = 115200);
  void end();
  int  available() override;
  int  availableForWrite();
  int  read() override;
  int  peek() override;
  void flush() override;
  size_t write(uint8_t c) override;
  using Print::write;
};

extern LLArduinoSerial Serial;


#endif // LL_ARDUINO -- Print/Stream/Serial

//! Render THROUGH whichever Print is compiled in -- LLArduino's or the vendor core's -- so Scheme
//! can assert what a device would actually emit and the SAME suite can be pointed at both.
//! Declared outside the guard above deliberately: see the note in ll_llarduino_print.cpp.
#if LL_ARDUINO || LL_ESP_ARDUINO
const char *ll_llarduino_fmt_int(long v, int base);
const char *ll_llarduino_fmt_real(double v, int digits);
const char *ll_llarduino_eol();
#endif

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
//! B410: CONSOLE RX RING SIZE.  The ESP32 Arduino default is 256 bytes, and a REPL line longer than
//! the driver can buffer WHILE THE LOOP IS BUSY is lost mid-line -- the board echoes what arrived,
//! the expression is left unbalanced, and the reader waits forever for a closing paren that was
//! dropped by the UART.  Nothing reports it, so a healthy board looks dead.  Measured on
//! esp32s3-n8r2-00: 453 bytes evaluated, 513 did not, and the cliff moved with how busy the control
//! loop was -- which is the signature of a ring overrun rather than a fixed parser limit.
//!
//! COSTS INTERNAL DRAM, which is the scarcest thing on these parts (B389 dies with 324 bytes left,
//! B396 starves WiFi).  2048 is chosen as the smallest size that clears every probe this project
//! actually sends by a wide margin, for +1792 bytes over the default -- NOT the largest that fits.
//! Raising it is spending from an overdrawn account; measure before you do.
//! CONSOLE BUFFERS -- THESE CANNOT GO IN PSRAM, AND THE SIZE IS A DIRECT INTERNAL-DRAM COST.
//!
//! Do not "move them to PSRAM" by raising the size past CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL (4096).
//! That threshold governs capability-less malloc(); the UART driver does not use one.
//! `esp_driver_uart/src/uart.c` allocates BOTH rings with an explicit capability:
//!
//!     #define UART_MALLOC_CAPS  (MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)
//!     uart_obj->rx_ring_buf = xRingbufferCreateWithCaps(rx_buffer_size, ..., UART_MALLOC_CAPS);
//!     uart_obj->tx_ring_buf = xRingbufferCreateWithCaps(tx_buffer_size, ..., UART_MALLOC_CAPS);
//!
//! So every byte of these buffers is internal DRAM at ANY size, and raising the number spends from
//! the account WiFi.begin() draws on.  Measured on the WROVER, same binary, one variable: a 2048
//! ring boot-looped the board with the bench overlay staged (7 aborts, 7 reboots) while 256 booted
//! clean, and the internal free difference was ~1992 bytes -- which is itself the proof they are
//! internal, since a PSRAM-backed ring would have shown no difference at all.
//!
//! B410 (a long REPL line silently dropped) is therefore NOT fixable by enlarging this.  The fix is
//! to drain promptly into a buffer WE allocate in PSRAM -- see P208; the driver ring then only has
//! to cover drain latency rather than a whole ~1300-byte LLIP frame.  Until that exists, the ring
//! stays at the framework default and the OVERFLOW IS REPORTED instead of being silent, which costs
//! nothing and is the half of B410's fix that was actually worth having.
#ifndef LL_STDIO_RX_BUFSIZE
#define LL_STDIO_RX_BUFSIZE 0            //!< 0 = leave the framework default; see above
#endif

const unsigned long toString_MAX_LENGTH = 8192;		//!<Global limit on Lamb-generated strings.
//! How much of an offending form an error message may quote back.  Well under
//! toString_MAX_LENGTH so the surrounding message text cannot push the total over it.
const unsigned long LL_ERRFORM_MAX = 400;
//! How many bindings of an ALIST environment frame a printed environment may expand before
//! it collapses to `#frame(N+)`.  An svec frame has always printed compactly; an alist frame did
//! not, and each of its values may be a closure that re-captures the same environment -- so
//! expanding one expands the program.  Measured on a chibi r7rs-tests run: single calls asking for
//! 13.7 MB, 14.8 MB and 31.8 MB of environment text, inside DIAGNOSTICS.  Chosen generously so
//! ordinary frames print in full and only unreadable ones are bounded.
const unsigned long LL_ENVFRAME_MAX = 32;
//! How many ELEMENTS of a list the printer may emit before it elides with " ...".
//!
//! THIS IS A LENGTH CAP AND MUST NOT BE THE DEPTH CAP.  The cdr spine is walked as a LOOP, so a
//! proper list costs no recursion and no print depth -- but the loop used `max_depth` as its
//! element budget, and `max_depth` defaults to 10 (LambLisp.h).  So an ELEVEN-element flat list
//! printed as `(12 11 10 9 8 7 6 5 4 3 ...)` and the runtime reported it as "datum deeper than the
//! print limit", which it was not: it was eleven items long.  Reported from the demo 2026-09-16 as
//! loop-stats being truncated, and it silently shortened every `Output:` line and every `~a` in a
//! log message.  Depth measures NESTING; this measures LENGTH; conflating them makes a list of
//! atoms indistinguishable from a structure nested past the stack backstop.
//!
//! IT IS ALSO THE CYCLE BACKSTOP, but only for callers that pass no DatumLabels table: with labels,
//! a cyclic or shared tail is detected exactly and printed as `#N#`.  Environments do NOT rely on
//! this -- they contain themselves by construction and have their own cap above.  Chosen large
//! enough that real data prints in full; a message that long is then bounded by
//! toString_MAX_LENGTH anyway.
const unsigned long LL_PRINT_LIST_MAX = 4096;
String toString(const char *fmt, ...) CHECKPRINTF;	//!<Produce a new string from the format and arguments, respecting the global limit on string length.
//!@}


#define ME(_me_) NOTUSED const char me[] = _me_			/*!<Declare an identifier "const char me[]" without causing "unused variable" warnings and/or code clutter to suppress them. */
#define isdef(sym) (#sym[0])					//!<Determine (cheaply) at runtime if a preprocessor symbol is defined.

void global_printf(const char *fmt, ...);		//!<This function enforces the limit on generated strings.

/*! Start the console spill reservoir.  Call once, LATE in boot.

  A FREE FUNCTION FOR THE SAME REASON global_printf IS ONE: the terminal is a VM internal, and
  `ll_vm_*` is never shipped to a customer.  `src/main.cpp` IS shipped -- it is the entry point a
  customer edits -- and it called `ll_term.spill_begin()` directly, which dragged `ll_vm_term.h`
  into a customer build that does not have it.  The package therefore could not compile at all
  [B472]; the first `pio run` in QUICKSTART died on the missing header.

  WHY main.cpp CALLS THIS AT ALL, rather than the VM doing it for itself: the ORDERING is the
  point, and it belongs to whoever owns boot.  The reservoir must be claimed AFTER setup.scm has
  loaded and after WiFi's radio buffers and LittleFS's DMA have taken their internal DRAM -- doing
  it earlier boot-looped the WROVER on a 2048-byte console ring [B411, B410/P208].  The reservoir
  is PSRAM, so it costs no internal DRAM; a board without PSRAM degrades to the driver ring.
*/
void global_spill_begin();

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

/*! @name Payload allocator -- bulk VM payloads belong in PSRAM, not internal DRAM.
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

//! ONE definition, not three per-platform ones, and spelled in the <stdint.h> idiom
//! so it states its ACTUAL requirement instead of satisfying it by accident.
//!
//! Word_t HOLDS POINTERS -- `rplacd((Word_t) val)`, the whole Cell payload -- so the requirement is
//! "wide enough for a pointer", which is exactly what uintptr_t means.  It was previously declared
//! per-platform as `unsigned long` (LL_AMD64, LL_ARM64) and `unsigned` (LL_ESP32).  Both were
//! CORRECT BY ACCIDENT rather than by construction: LP64 Linux and ILP32 Xtensa happen to make
//! those the same size as a pointer.  Windows x64 is LLP64 -- `long` is 32 bits while pointers are
//! 64 -- so the LL_AMD64 spelling TRUNCATES EVERY POINTER there, silently, at compile time, with
//! the first symptom being a GC walking garbage.  uintptr_t is 4 bytes on the ESP32 and 8 on every
//! 64-bit host, so one line is right on all of them and a fourth platform cannot reintroduce the
//! bug by copying the wrong branch.
//!
//! THE STATIC ASSERT IS THE POINT, not decoration.  Nothing else in the tree checks this property;
//! it is the only mechanism that catches a width regression at build time rather than in a
//! debugger.  Do not remove it, and do not replace uintptr_t with a fixed width (uint64_t would
//! waste half of every cell on the ESP32; uint32_t would truncate on a host).
//!
//! Related, and the reason the idiom matters beyond Windows: LL_int32 is int32_t, and the ESP-IDF 5
//! xtensa toolchain changed int32_t from `int` to `long` -- which silently made every
//! ascii.dec(someInt) call ambiguous (see the dec(int) forwarder below).  A type that NAMES its
//! width does not move under a toolchain upgrade; a type spelled `long` does.
typedef uintptr_t Word_t;	//!<A generic computer word, used only for setting and retrieval -- WIDE ENOUGH FOR A POINTER.  Not an *unsigned int* used for arithmetic.
typedef void *Ptr_t;		//!<Generic pointer in C++
static_assert(sizeof(Word_t) >= sizeof(void *),
              "Word_t must hold a pointer -- see the P174 note above; LLP64 (Windows x64) breaks "
              "the old `unsigned long` spelling because long is 32 bits there and pointers are 64.");

typedef int32_t  LL_int32;	//!<LambLisp 32-bit exact integer.

//! @name UTF-8 codepoint helpers
//! R7RS indexes strings by CHARACTER, not by byte.  LambLisp stores strings as NUL-terminated
//! UTF-8, so every index operation has to walk the encoding.  These are the one shared
//! implementation -- encoders were previously duplicated across several modules
//! which is how the write path came to encode real UTF-8 while the measure
//! path still counted bytes (`(string-length (list->string (list (integer->char 945))))`
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

//! CHARACTER count of a UTF-8 buffer of KNOWN BYTE LENGTH.  B317: once a string may contain a NUL,
//! ll_u8_strlen() above is the wrong tool -- it stops at the first 0 byte and would report a short
//! count for a perfectly good string.  Counting to an explicit byte length is the only form that
//! stays correct, so this is what the stored character length is computed with.
//! A truncated final sequence (a lead byte whose continuations run past nbytes) still counts as one
//! character and the loop still terminates: seqlen never returns 0.
inline LL_int32 ll_u8_strlen_n(const char *s, LL_int32 nbytes)
{
  LL_int32 n = 0;
  for (LL_int32 i = 0; i < nbytes; n++) i += ll_u8_seqlen((unsigned char) s[i]);
  return n;
}

//! Byte pointer to character index k within a buffer of KNOWN BYTE LENGTH; 0 if k is past the end.
//! The NUL-terminated ll_u8_index() below cannot be used on a string that may contain a NUL.
inline const char *ll_u8_index_n(const char *s, LL_int32 nbytes, LL_int32 k)
{
  LL_int32 i = 0;
  for (LL_int32 c = 0; c < k; c++) {
    if (i >= nbytes) return 0;
    i += ll_u8_seqlen((unsigned char) s[i]);
  }
  return (i <= nbytes) ? (s + i) : 0;
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
    if (n == INT32_MIN) return dec((LL_int64) n);   //!< -INT32_MIN overflows int32; int64 path prints it in full
    char *ptr = dec(-n);
    *--ptr = '-';
    return ptr;
  }

  //! dec(int) -- EXISTS ONLY WHERE int32_t IS NOT int, AND THAT VARIES BY TOOLCHAIN.
  //! The xtensa toolchain shipped with ESP-IDF 5 typedefs int32_t as `long`; the one with IDF 4.4
  //! used `int`.  With int32_t == long the overload set below is {unsigned, long, long long,
  //! float} and a plain `int` argument converts to the first three at IDENTICAL rank, so every
  //! ascii.dec(someInt) in the tree stops compiling at once with
  //!     error: call of overloaded 'dec(int&)' is ambiguous
  //! -- which points at the CALL rather than at the typedef that moved, and looks like the call
  //! site is wrong when nothing about it changed.  Under IDF 4.4 int32_t == int made dec(LL_int32)
  //! an exact match, so the ambiguity simply could not arise and the calls were always fine.
  //! Adding this forwarder fixes every call site at once instead of casting at each one.
  //! THE enable_if IS LOAD-BEARING, NOT DECORATION: on hosts where int32_t IS int (x86-64 Linux,
  //! the IDF 4.4 toolchain) this would be a redeclaration of dec(LL_int32) and would not compile,
  //! so it must vanish there rather than be #ifdef'd on a chip or an IDF version -- the condition
  //! is a property of the TYPEDEF, and only the compiler knows it.
  template <typename T>
  typename std::enable_if<std::is_same<T, int>::value && !std::is_same<LL_int32, int>::value,
                          char *>::type
  dec(T n) { return dec((LL_int32) n); }

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
  /*! @brief Free space in the pool cell BLOCKS are actually allocated from.
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

  //! B410/P208: register a callback the TRANSPORT invokes when input arrives, so the console can be
  //! drained by something other than the reader.  This belongs on the SHIM, not at the call site:
  //! LL_Term talks to LambStdioClass and nothing else, and `onReceive` is a HardwareSerial method
  //! that the shim does not inherit -- calling it through LambStdio compiles nowhere.
  //! Returns true if the transport supports it.  POSIX returns false and the caller keeps its
  //! existing reader-driven path, which is correct there: stdin is already buffered by libc.
  bool set_input_callback(void (*cb)());
  
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
  //! The LIVE SET the GC last measured, persisted across reboots so the heap can come back
  //! already sized for the workload.  NOT a block size -- the initial block is derived from it
  //! (round up to an extension_block_size multiple, then double).  0 = nothing persisted yet.
  //! Deliberately a separate key from cell_block_size: the old code wrote a multi-block TOTAL into
  //! cell_block_size, which means "size of the initial single block", and the units mismatch
  //! bricked boards.  Keeping the quantities in distinct fields makes that error unrepresentable.
  LL_int32 gc_total_marked      = 0;
  LL_int32 ncg_frame_pool_size  = 16;        //!< NcgFrames pre-allocated into the free-list pool at startup.
  //! Hard cap on ONE FORMATTED LOG/ERROR MESSAGE (`va_list_expand()`), beyond which the text is
  //! TRUNCATED rather than an error raised -- see the B175 note at that function for why this one
  //! buffer must truncate instead of throwing.  Separate from `toString_MAX_LENGTH` (which caps a
  //! printed DATUM) so a site that wants longer diagnostics does not also loosen the reader's cap.
  //! CLAMPED ON LOAD to [1024, 65536]; see `ll_va_list_max` for why the ceiling is not advisory.
  LL_int32 va_list_max          = (LL_int32) toString_MAX_LENGTH;
  //! B441: BOOT-ATTEMPT SENTINEL.  A persisted setting that makes the VM unbootable is
  //! self-perpetuating: the value is read before anything can judge it, the boot dies, and the next
  //! boot reads the same value.  `boot_pending` is written 1 just before a risky persisted value is
  //! USED and rewritten 0 once the VM is up.  Finding it still 1 at load means the previous boot
  //! did not survive what it read, so the risky value is discarded rather than retried forever.
  //! 0 = last boot completed.  1 = a boot was attempted with persisted values and did not finish.
  LL_int32 boot_pending         = 0;
  void load();               //!< Reads LAMB_SETTINGS_PATH_RAW via fopen; silent if missing.
};

//! B441: rewrite the settings file from `ll_pre_settings`, with `boot_pending` as given.
//! One writer, so a key added to the struct cannot be dropped by a caller that did not know of it.
void ll_pre_settings_write(LL_int32 boot_pending);
//! B441: call once the VM is up; clears the sentinel so the next boot trusts what is stored.
void ll_settings_boot_ok(void);

//! THE LIVE COPY OF WHAT `load()` READ.  Two consumers need it long after the local
//! `LambPreSettings pre` in `Lamb::setup()` has gone out of scope: `va_list_expand()`, which is a
//! free function reachable before any object exists, and the GC's rewrite of the settings file,
//! which must PRESERVE the keys it does not own (see B417).  Written once by `load()`; treat as
//! read-only afterwards.
extern LambPreSettings ll_pre_settings;

//! The cap `va_list_expand()` actually enforces, published by `load()` from `va_list_max`.
//! A SEPARATE GLOBAL, not a read through `ll_pre_settings`, because this is consulted on the
//! logging path before `load()` has run at all -- it must have a valid value from static init.
//! CEILING IS NOT ADVISORY: `autobuf_t::upsize()` RAISES a Scheme error past its own `_max_`
//! (65536, B175), and raising from inside the formatter means throwing while building the error
//! message that the throw will need to format.  Clamping on load keeps that unrepresentable.
extern LL_int32 ll_va_list_max;

//! @name C++ *try* and *catch* are used to process code faults detected by the LambLisp VM.
//! To cleanly unwind after an error is detected, each *catch* has uniform behavior, which is captured in this macro.
//!@{
#define ll_try try

//! LOG ONCE PER ERROR, NOT ONCE PER FRAME.
//! This macro is on every unwinding frame, so a deep error printed one line PER eval FRAME: a
//! recursion-depth trip at ~40k deep emitted ~20,000 identical lines, which buries the actual error
//! and, on a serial console, takes longer to drain than the computation took to fail.  It is not
//! specific to deep recursion -- any error raised there did this -- but the guard made it
//! routine, because tripping the guard is precisely the deep case.
//! The SAME T_ERROR object propagates up the whole unwind, so frame 2..n are recognisable by
//! pointer: log the first, then one "suppressing" line, then stay quiet.  A genuinely NEW error
//! resets the counter and prints normally, so nothing is lost except the repeats.
//! Pointer-compared as void*, deliberately: this must not resurrect a cell or touch GC state while
//! an exception is in flight.  mk_syserror reuses a singleton, so two DISTINCT errors can share a
//! pointer -- but only when separated by a completed unwind, and the count resets on the next
//! distinct object, so the worst case is one suppressed duplicate line, never a lost first report.
extern const void *ll_catch_last_err;   //!< most recently logged error object (compared, never dereferenced)
extern int         ll_catch_repeats;    //!< frames seen for that same object during this unwind
#define LL_CATCH_REPEAT_LIMIT 4

#define ll_catch(__code_before_rethrow__)				\
  catch (Sexpr_t __err__) {						\
    if (__err__->type() != Cell::T_ERROR)				\
      throw NIL->mk_error("ll_catch() BUG in %s bad type %s", me, __err__->dump().c_str()); \
    									\
    if ((const void *) __err__ != ll_catch_last_err) {			\
      ll_catch_last_err = (const void *) __err__;			\
      ll_catch_repeats  = 0;						\
    }									\
    if (++ll_catch_repeats <= LL_CATCH_REPEAT_LIMIT)			\
      global_printf("\r[%d] %s ll_catch(): %s\n", millis(), me, __err__->error_get_chars()); \
    else if (ll_catch_repeats == LL_CATCH_REPEAT_LIMIT + 1)		\
      global_printf("\r[%d] %s ll_catch(): ... same error still unwinding; further frames suppressed\n", millis(), me); \
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
