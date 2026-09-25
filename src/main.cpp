// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include <new>            //!< [B520] std::bad_alloc
#include "LambLisp.h"
#include "ll_exec_cap.h"   //!< B360: LL_HAVE_EXEC_CAP / ll_exec_heap_free()
#include "ll_fastram.h"
#include <exception>   //!< B349: name what escapes, instead of a mute abort() on an MCU
#include <cstdlib>
#if LL_ESP32 || LL_ESP32S3
#  include "esp_task_wdt.h"
#  include "esp_idf_version.h"
#  include "soc/timer_group_struct.h"
#  include "soc/timer_group_reg.h"
#endif

/*! @name These are the non-VM operators that are local to this application.

  To add new Lisp-compatible C++ operators, follow this recipe:

  1. Create your C++ function, having the "mop3" signature, as this:
  ```
  Sexpr_t my_function(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);

  ```
  In this example *my_function()* will receive a Lamb virtual machine, a symbolic expression *sexpr* of type *Sexpr_t* to be evaluated,
  and an environment in which to execute (which is also of type *Sexpr_t*).
  All the LambLisp native operators share this signature, so there is no "foreign function interface" as in other Lisps.
  All the functions with the *mop3* signature are native and will run at full C++ speed.

  **Warning:* To preserve the tail-recursion feature, *mop3* operators should not call other *mop3* operators.
  Recursive calls (direct or indirect) to the LambLisp S-expression partial evaluator will cause stack overflow.
  If you encounter a situation in which this seems desirable, you should instead factor out the common part
  and have the 2 *mop* operators call the common part separately.
 */

//!@{
Sexpr_t CommonIO_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t ESP32_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t PCA9685_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t WS2812_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t WiFi_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t Wire_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t Sonar_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t SPI_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t OneWire_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t LCD1602_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t Panel_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);   // P231: display panel, board-independent
Sexpr_t Lvgl_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);    // P231: LVGL, bound to the panel abstraction
Sexpr_t EyeCam_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
Sexpr_t ota_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);   // OTA loader<->VM NVS handshake
#if LL_CUDA
Sexpr_t Cuda_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
#endif
#if LL_HIP
Sexpr_t Hip_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
#endif
//!@}

Sexpr_t install_local_native_operators(Lamb &lamb)
{
  ME("::install_local_native_operators()");

  /*! @name The LambLisp virtual machine operates by executing Lisp language native functions written in C++.
    
    This provides high performance at runtime, and scalability at compile/link time.
    The LambLisp virtual machine operations are referred to generically as *mops* or *mop3* (because they all take 3 parameters).
    In the Lamb VM code the C++ type name for a LambLisp-compatible function is *Mop3st_t* ("mop3 star type", with the st standing in for an asterisk).
    The type Mop3st_t is a pointer to a LambLisp-compatible native function.

    Installers for native procedures are themselves Mop3st types, but so far they do not return any useful value.
    It should be possible to reinstall these native operators at runtime, a feature of doubtful utility.
    In Lisp the function signature for an installer is ```(installer env-target)```.
    The C++ signature for *Mop3st_t* is ```Sexpr_t installer(Lamb &lamb, Sexpr_t list_containing_1_element_env_target, Sexpr_t env_execution);```

    Dictionaries are first-class objects in LambLisp.
    Dictionaries are hierarchical, implemented as a list of frames, each of which may be an alist or a vector of alists (used as a hash table).
    It is possible to add a new dictionary child frame on top of an existing parent dictionary.
    When a dictionary is searched, the topmost child is checked first, and the first matching key/value pair is returned.

    The LambLisp execution environment is a dictionary.  Dictionary keys may be any type, but when used as environments dictionary keys are all symbols.
    the LambLisp object system is based on dictionaries, which directly support the concept of *object inheritance*.
    Object keys are also symbols.
  */
    
  /*!These are the installers for additional language primitives (written in C++) required for this particular application.
    They do not require any header file; for each additional group of functions there is an installer that places the functions into the runtime environment.
    The installer is a global function, not a member of any class.
    All the installers have a same signature, of the *Mop3st_t* type.
   */
  const Lamb::Mop3st_t func[] = {
    CommonIO_install_mop3,
#if LL_CUDA
    Cuda_install_mop3,
#endif
#if LL_HIP
    Hip_install_mop3,
#endif
    ESP32_install_mop3,
    WiFi_install_mop3,
    Wire_install_mop3,
    Sonar_install_mop3,
    SPI_install_mop3,
    OneWire_install_mop3,
    PCA9685_install_mop3,
    WS2812_install_mop3,
    LCD1602_install_mop3,
    Panel_install_mop3,
    Lvgl_install_mop3,
    EyeCam_install_mop3,
    ota_install_mop3,
  };
  const int Nfuncs = sizeof(func)/sizeof(func[0]);

  Sexpr_t env_exec      = lamb.r5_interaction_environment();
  Sexpr_t env_target_sx = lamb.cons(env_exec, NIL, env_exec);	//put env into a list for the Mop3st calling protocol

  lamb.gc_root_push(env_target_sx);
  for (int i=0; i<Nfuncs; i++)
    Sexpr_t ignore = func[i](lamb, env_target_sx, env_exec);
  lamb.gc_root_pop();
  
  return OBJ_UNDEF;
}

/*!
  Allocate Lamb virtual machines dynamically, not statically.
  The constructors may depend on serial port availability or other operating system facility that is not available at static construction time.
*/
Lamb *lamb = 0;

//! B349: THE MCU ENTRY POINTS CATCH ONLY Sexpr_t, AND THAT IS WHY AN MCU FAULT IS MUTE.
//!
//! POSIX main() (bottom of this file) has caught `Sexpr_t` AND `...` since B182 (2026-08-30), and
//! prints "LambLisp fatal: uncaught C++ exception".  The ESP32 path never got the second half:
//! setup() had no handler at all and loop() had only `ll_catch_terminal`, which is
//! `catch (Sexpr_t)`.  So a std::bad_alloc / std::length_error out of any ordinary allocation --
//! `new uint8_t[newcap]` in NcgBuffer::ensure, `new NcgXtensa()`, `new NcgCode{}`, a
//! std::vector growth in the NCG backend -- unwound past EVERY handler in the VM to
//! std::terminate, and the board printed nothing but
//!     abort() was called at PC 0x... / Backtrace: ... / Rebooting...
//! WHAT THAT COSTS is not the crash, it is the DIAGNOSIS: decoding that backtrace needs the exact
//! firmware.elf, which is a build artifact that is usually already overwritten.  B220 was revised
//! three times, with two published retractions, against a symptom whose transcript literally read
//! `abort() was called` -- because nothing named the exception and no harness kept the transcript.
//! So: NAME IT, THEN GO DOWN.  Do not "recover" and continue -- an escape this deep leaves the GC
//! root stack unbalanced; a reboot is the honest outcome, an EXPLAINED reboot is the useful one.
static void ll_setup_body();

#if LL_ESP32C5
//! [B340] GUARD ON `LL_ESP32C5`, THE `-D` FROM platformio.ini -- NOT on CONFIG_IDF_TARGET_ESP32C5.
//! The first cut of this used the CONFIG_ macros and SILENTLY COMPILED TO NOTHING: `nm` found no
//! `ll_b340_rearm_psram_barrier` in the ELF and the boot log printed no B340 line at all, which is
//! indistinguishable from the code not being there.  Those macros live in `sdkconfig.h`, which this
//! translation unit does not reliably see; `LL_ESP32C5` is on the compiler command line and cannot
//! go missing.  The headers below are included explicitly for the same reason.
#  include "sdkconfig.h"
#  include "esp_heap_caps.h"
//! [B340] RE-ARM THE PSRAM MSPI MEMORY BARRIER, WHICH THE IDF TRIED TO ARM BEFORE PSRAM EXISTED.
//!
//! WHAT GOES WRONG.  `esp_psram_init()` registers PSRAM with the heap at esp_psram.c:129 and arms
//! the barrier at :140 -- but only the FIRST is inside
//! `#if CONFIG_SPIRAM_BOOT_INIT && (CONFIG_SPIRAM_USE_CAPS_ALLOC || CONFIG_SPIRAM_USE_MALLOC)`.
//! The Arduino prebuilt libs we link against define CONFIG_SPIRAM=1 and CONFIG_SPIRAM_USE_MALLOC=1
//! but do NOT define CONFIG_SPIRAM_BOOT_INIT AT ALL, so that guard is 0, the heap-add is compiled
//! out, and `esp_psram_mspi_mb_init()` runs anyway -- asking for 32 bytes of MALLOC_CAP_SPIRAM from
//! a heap that has no SPIRAM region yet.  Hence the one early boot line:
//!     E (1349) MSPI Timing: Failed to allocate dummy cacheline for PSRAM memory barrier!
//! PSRAM is full LATER because ARDUINO registers it at system-init priority 99
//! (esp32-hal-misc.c:299 -> psramInit -> psramAddToHeap), long after cpu_start.c:646.
//!
//! WHY CALLING IT AGAIN WORKS.  `esp_psram_mspi_mb_init()` is not static and simply redoes the same
//! calloc into its own file-static pointer.  By the time `setup()` runs, Arduino has registered
//! PSRAM, so the identical request now succeeds.  Nothing about the allocation was ever unusual --
//! it is 32 bytes, 32-byte aligned; there was simply no SPIRAM to take it from.
//!
//! THE BARRIER IS NOT COSMETIC: `esp_psram_mspi_mb()` is a DMA/PSRAM ordering barrier
//! (esp_dma_utils.c:138, uhci.c:123/153) and is a silent NO-OP while unarmed, for the whole run.
//! It is an erratum workaround for C5 silicon BELOW v1.02; our bench parts are v1.02 (ECO3) so it
//! is inert HERE, but the shipped image declares support down to v1.00 where it is load-bearing.
//!
//! WE PROBE BEFORE RE-ARMING BECAUSE THE IDF CANNOT REPORT ITS OWN FAILURE: `esp_psram_mspi_mb_init()`
//! logs and then `return ESP_OK;` regardless, so its result says nothing.  The probe performs the
//! IDENTICAL allocation and reports it, which is the only way this line can be seen to have worked.
extern "C" esp_err_t esp_psram_mspi_mb_init(void);

static void ll_b340_rearm_psram_barrier()
{
  const size_t line = CONFIG_CACHE_L1_CACHE_LINE_SIZE;
  void *probe = heap_caps_calloc(1, line, MALLOC_CAP_SPIRAM | MALLOC_CAP_CACHE_ALIGNED);
  unsigned long psfree = (unsigned long) heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
  if (probe) {
    heap_caps_free(probe);
    esp_psram_mspi_mb_init();                 //!< same call the IDF made; now it has memory
    global_printf("\r[%lu] [B340] PSRAM MSPI barrier re-armed (%lu B probe ok, PSRAM free=%lu)\n",
                  millis(), (unsigned long) line, psfree);
  }
  else {
    //! Still failing HERE would mean PSRAM is not in the heap even at setup() -- a different fault
    //! from B340, and worth saying so rather than reporting a re-arm that did not happen.
    global_printf("\r[%lu] [B340] PSRAM MSPI barrier NOT re-armed: %lu B SPIRAM probe FAILED "
                  "at setup() (PSRAM free=%lu) -- PSRAM is not in the heap here either\n",
                  millis(), (unsigned long) line, psfree);
  }
}
#endif
void setup()
{
#if LL_POSIX
  ll_setup_body();          //!< POSIX: main()'s own try/catch already covers this (B182)
#else
  try {
    ll_setup_body();
  }
  catch (Sexpr_t err) {
    global_printf("\r[%lu] ::setup() FATAL uncaught LambLisp error object -- aborting\n", millis());
    if (err) { try { global_printf("  %s\n", err->str().c_str()); } catch (...) {} }
    abort();
  }
  catch (std::exception &e) {
    global_printf("\r[%lu] ::setup() FATAL uncaught C++ exception: %s -- aborting\n", millis(), e.what());
    abort();
  }
  catch (...) {
    global_printf("\r[%lu] ::setup() FATAL uncaught C++ exception of unknown type -- aborting\n", millis());
    abort();
  }
#endif
}

static void ll_setup_body()
{
  unsigned long t_start = millis();
  ME("::setup()");

#if LL_ESP32 || LL_ESP32S3
  // Disable watchdogs so long Scheme evaluations (benchmarks, compilation)
  // don't trigger TG0WDT (TWDT) or TG1WDT (IWDT) system resets.
  esp_task_wdt_deinit();                          // disable TWDT (TG0WDT)
  //! THE SPLIT HERE IS BY IDF VERSION AS WELL AS BY SoC.  Under IDF 4.4 the two SoCs spelled these
  //! TIMERG1 fields differently: the S3 used wdtwprotect / wdtconfig0.wdt_en, while the classic
  //! ESP32 (LX6) used the underscore forms wdt_wprotect / wdt_config0.en -- hence the original
  //! `#if LL_ESP32S3` split.  IDF 5 REGENERATED the classic ESP32's soc/timer_group_struct.h from
  //! the same template as the newer parts, so the LX6 now uses the S3 spelling too and the
  //! SoC-only split is wrong there.  Verified in the IDF 5.5 header: timg_dev_t carries
  //! `wdtconfig0` and `wdtwprotect`, and the enable bit is `wdt_en` at bitpos 31, identical to the
  //! S3.  The symptom of getting this wrong is LX6-only and looks like a typo, because GCC helpfully
  //! suggests the very name you wanted:
  //!     error: 'timg_dev_t' has no member named 'wdt_wprotect'; did you mean 'wdtwprotect'?
  //! -- so it reads as a misspelling rather than as a header that was regenerated under you.
#if LL_ESP32S3 || ESP_IDF_VERSION_MAJOR >= 5
  TIMERG1.wdtwprotect.val = TIMG_WDT_WKEY_V;   // unlock TG1WDT write-protect
  TIMERG1.wdtconfig0.wdt_en = 0;               // disable TG1WDT (IWDT)
  TIMERG1.wdtwprotect.val = 0;                  // re-lock
#else  // LX6 on IDF 4.x only (original, wdt_ prefix registers)
  TIMERG1.wdt_wprotect = TIMG_WDT_WKEY_V;      // unlock TG1WDT write-protect
  TIMERG1.wdt_config0.en = 0;                  // disable TG1WDT (IWDT)
  TIMERG1.wdt_wprotect = 0;                    // re-lock
#endif
#endif

  LambStdio.begin();
  global_printf("[%lu] %s LambLisp starting, 1st light @%lu ms\n", millis(), me, t_start);

#if LL_ESP32C5
  //! [B340] AFTER `LambStdio.begin()`, NOT BEFORE IT.  The first placement was immediately after
  //! `ME()` at the top of this function -- 29 lines ahead of first light -- so the re-arm RAN and
  //! its report went nowhere, and the boot log looked exactly as if the code were not compiled in.
  //! Cost a flash-and-bootlog cycle to find, on top of a build spent chasing a `#if` that was
  //! fine.  The re-arm itself is position-independent: it only needs Arduino's priority-99
  //! `psramInit()` to have run, which it has long before `setup()` is entered.  So put it where it
  //! can be SEEN.
  ll_b340_rearm_psram_barrier();
#endif
#if LL_ESP32
  //! B360: ll_exec_heap_free(), not heap_caps_get_free_size(MALLOC_CAP_EXEC) -- under ESP-IDF 6 with
  //! CONFIG_ESP_SYSTEM_MEMPROT the macro is UNDEFINED and this boot banner, which has nothing to do
  //! with native code generation, would fail the build of the whole firmware.  It reports 0 there,
  //! which is the truth: no capability, no executable heap.
  global_printf("[%lu] %s free EXEC/IRAM heap: %u bytes\n", millis(), me,
                ll_exec_heap_free());
#endif
  void ll_heap_note(const char *tag);   // B95 boot-phase internal-DRAM tracer
  ll_heap_note("boot: before new Lamb");
  lamb = new Lamb;	//avoid static allocation due to possible lack of terminal at static construct time
  lamb->setup();
  
  lamb->log("%s Installing local native operators\n", me);
  install_local_native_operators(*lamb);

  //! P211 PHASE ORDER: the system's one-shot claims have now been made (drivers installed, radio
  //! reservation taken), so LambLisp sizes its own discretionary pool from what ACTUALLY remains.
  //! This is the "system first, LambLisp from the remainder" rule the proposal argues for, and it
  //! is the one ordering LambLisp fully controls.
  { void ll_ncg_exec_pool_claim_late(); ll_ncg_exec_pool_claim_late(); }
  ll_heap_note("before setup.scm load");
  lamb->log("%s Loading setup.scm\n", me);
  Sexpr_t ignored = lamb->load("setup.scm", lamb->r5_interaction_environment(), 0);
  ll_heap_note("after setup.scm load");
  //! P211: anything still reserved was never claimed -- give it back.  This is what makes the
  //! installer-time reservation "first IF it is used, otherwise not" rather than a tax every
  //! board pays.  Two boards in this fleet boot ONLY because they do not start a radio (B411).
  ll_fastram_release_unclaimed();

  //! B410/P208: allocate the console spill reservoir HERE, not at LambStdio.begin().  This is the
  //! ordering the proposal argues for -- system services (WiFi's radio buffers, LittleFS DMA) have
  //! finished claiming internal DRAM by now, so LambLisp takes its discretionary memory from what
  //! actually remains.  Doing it earlier is what made a 2048-byte console ring boot-loop the WROVER
  //! (B411): the claim landed before WiFi.begin() could make its own.
  //! The reservoir itself is PSRAM, so this costs no internal DRAM at all; the point of the late
  //! placement is that a board WITHOUT PSRAM degrades to the driver ring rather than competing.
  global_spill_begin();

  //! B441: THE VM IS UP -- clear the boot-attempt sentinel.  Placed AFTER setup.scm has loaded and
  //! after the memory-hungry startup claims, because that is the span a bad persisted value kills:
  //! a gcpause run's `gc_total_marked` sizes the heap at 2x and `setup()` throws std::bad_alloc
  //! before reaching here.  Clearing it earlier would declare success while the dangerous part was
  //! still ahead, which is the failure this sentinel exists to catch.
  ll_settings_boot_ok();

#if LL_AUTOCOMPILE >= 1
  // Auto-compile all T_PROC/T_NPROC bindings in the interaction environment.
  {
    extern Sexpr_t mop3_compile_environment(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
    Sexpr_t env = lamb->r5_interaction_environment();
    Sexpr_t arg = lamb->cons(env, NIL, env);
    lamb->gc_root_push(arg);
    Sexpr_t n = mop3_compile_environment(*lamb, arg, env);
    lamb->gc_root_pop();
    lamb->log("%s auto-compile: %s procedures compiled\n", me, n->str().c_str());
  }
#endif
#if LL_AUTOCOMPILE >= 2
  // NCG-compile all T_BYTECODE bindings to native code.
  {
    extern Sexpr_t mop3_ncg_compile_env(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
    Sexpr_t env = lamb->r5_interaction_environment();
    Sexpr_t arg = lamb->cons(env, NIL, env);
    lamb->gc_root_push(arg);
    Sexpr_t n = mop3_ncg_compile_env(*lamb, arg, env);
    lamb->gc_root_pop();
    lamb->log("%s ncg-compile: %s procedures compiled\n", me, n->str().c_str());
  }
#endif

  // Execution-mode census.  Reports how many bindings are AST (interpreted), BC (bytecode) and NCG
  // (native) once the startup compile phase has finished.
  //
  // DELIBERATELY OUTSIDE BOTH #if BLOCKS, not tucked in after compile-environment!.  Two reasons.
  // LL_AUTOCOMPILE is set only by the linux_x86_64_bc and linux_x86_64_ncg diagnostic envs, so on
  // every shipping build both blocks compile away -- and "all AST" is exactly the fact worth
  // printing, not one to hide behind a flag nobody ships.  And when LL_AUTOCOMPILE is 2 the NCG
  // pass runs AFTER the bytecode pass, so a census placed between them would report NCG 0 on every
  // boot and read as "native code is not working" when it simply had not run yet.
  {
    extern void ll_env_exec_census(Lamb &lamb, Sexpr_t dict, int &n_ast, int &n_bc, int &n_ncg);
    int n_ast = 0, n_bc = 0, n_ncg = 0;
    ll_env_exec_census(*lamb, lamb->r5_interaction_environment(), n_ast, n_bc, n_ncg);
    lamb->log("%s execution modes: AST %d  BC %d  NCG %d  (%d procedures)\n",
              me, n_ast, n_bc, n_ncg, n_ast + n_bc + n_ncg);
  }

}

void loop()
{
  ME("::loop()");
#if LL_POSIX
  ll_try {
    lamb->loop();
  }

  ll_catch_terminal
#else
  //! B349: see the note above setup().  `ll_catch_terminal` is `catch (Sexpr_t)` and nothing else,
  //! so on an MCU every other exception type reached std::terminate and the board rebooted mute.
  try {
    lamb->loop();
  }
  catch (Sexpr_t __err__) {
    if (__err__ && __err__->type() == Cell::T_ERROR)
      global_printf("\r[%lu] %s ll_catch_terminal: %s\n", millis(), me, __err__->error_get_chars());
    else
      global_printf("\r[%lu] %s ll_catch_terminal: non-error type\n", millis(), me);
    ll_debug_catcher;
  }
  //! [B520] OUT OF MEMORY IS NOT A REASON TO REBOOT THE BOARD.  `std::bad_alloc` used to fall into
  //! the generic `std::exception` arm below and `abort()`, so a program that merely asked for more
  //! memory than the part has took the whole device down -- 62 times in one measured run, turning a
  //! ~1,190 s benchmark sweep into ~14,200 s and an INCOMPLETE cell.
  //!
  //! IT IS A CONDITION, NOT A CORRUPTION.  The allocation failed; nothing was written, nothing is
  //! inconsistent.  The runtime claims ~1.2 MB of a 2 MB part before user code runs, so exhausting
  //! the remainder is arithmetic a program can legitimately hit -- and a program that hits it should
  //! be able to be TOLD, not silently restarted underneath its author.
  //!
  //! SO: report and RETURN.  `loop()` is re-entered by the Arduino main loop, so returning ends this
  //! iteration and keeps the REPL, the session and the serial link alive -- which is the difference
  //! between a test that reports "out of memory" and one that reports nothing because the board
  //! rebooted mid-sentence.  We do NOT abort and we do NOT pretend it succeeded.
  //!
  //! WHAT THIS IS NOT: it is not the full fix.  A Scheme program still cannot `guard` an OOM,
  //! because by the time the exception reaches here the Scheme stack is already unwound.  Making it
  //! catchable means converting `bad_alloc` to a LambLisp error AT THE ALLOCATION SITE; that is a
  //! change to every allocator path and wants its own decision.  This is the half that stops the
  //! reboot, which is the half that was destroying measurements.
  catch (std::bad_alloc &) {
    global_printf("\r[%lu] %s OUT OF MEMORY (std::bad_alloc) -- allocation refused, continuing.\n"
                  "  This is a memory BUDGET limit, not corruption [B520].  The board is NOT being\n"
                  "  reset; the failed operation is abandoned and the REPL continues.\n", millis(), me);
    ll_debug_catcher;
  }
  catch (std::exception &e) {
    global_printf("\r[%lu] %s FATAL uncaught C++ exception: %s -- aborting\n", millis(), me, e.what());
    abort();
  }
  catch (...) {
    global_printf("\r[%lu] %s FATAL uncaught C++ exception of unknown type -- aborting\n", millis(), me);
    abort();
  }
#endif
}

#if !LL_POSIX
size_t getArduinoLoopTaskStackSize(void) { return 49152; }  //!< 48 KB loopTask stack (halved from 96 KB, B95: frees ~48 KB internal DRAM for LittleFS DMA reads).  Eval guard LL_EVAL_STACK_BUDGET lowered to match.
#endif

#if LL_POSIX

// R7RS (scheme process-context) command-line: capture argv so (command-line) can return it.
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#include <malloc.h>

int          g_ll_argc = 0;
const char **g_ll_argv = nullptr;

/*! @brief `--teardown-test N` -- construct and destroy N Lamb instances, reporting RSS each time.

  Exercises ~Lamb(), which until 2026-08-24 did not exist: nothing in the tree ever tore an
  instance down, so every allocation the VM makes had an untested release path.  A flat RSS across
  cycles means the teardown returns what setup took; a rising one names the leak's size per cycle.

  SEQUENTIAL ONLY.  `sint_cache_cells` is a global, so two LIVE instances would share it and the
  first teardown would free it under the survivor.  This loop destroys each instance before
  building the next.
*/
static int ll_teardown_test(int cycles)
{
  //! RSS cannot separate a real leak from allocator retention, so report mallinfo's in-use bytes
  //! alongside it: uordblks rising per cycle is a genuine leak, RSS alone rising is not.
  auto inuse_kb = []() -> long {
#if defined(__GLIBC__)
    struct mallinfo2 mi = mallinfo2();
    return (long) (mi.uordblks / 1024);
#else
    return -1;
#endif
  };
  auto rss_kb = []() -> long {
#if LL_WINDOWS
    //! P174: -1 == "this host cannot tell us", the SAME convention inuse_kb() above already uses
    //! for a non-glibc libc, and reported as such rather than as a plausible 0.  Windows has
    //! neither /proc/self/statm nor sysconf(); its answer is GetProcessMemoryInfo() from psapi,
    //! which is not written because --teardown-test is a LEAK-HUNTING DIAGNOSTIC for the hosts we
    //! develop on, and P174 Phase 1 is a language demo.  Add it to ll_platform_Windows.cpp if a
    //! leak ever needs chasing on Windows specifically; until then a missing number is honest and
    //! a wrong one is not.
    return -1;
#else
    long sz = 0, res = 0;
    FILE *f = fopen("/proc/self/statm", "r");
    if (f) { if (fscanf(f, "%ld %ld", &sz, &res) != 2) res = 0; fclose(f); }
    return res * (sysconf(_SC_PAGESIZE) / 1024);
#endif
  };
  printf("teardown-test: %d cycles\n", cycles);
  long base = 0;
  for (int i = 1; i <= cycles; i++) {
    lamb = new Lamb;
    lamb->setup();
    delete lamb;
    lamb = nullptr;
    long r = rss_kb();
    if (i == 1) base = r;
    long u = inuse_kb();
    static long ubase = 0; if (i == 1) ubase = u;
    printf("  cycle %2d  rss=%ld kB (%+ld)  malloc-inuse=%ld kB (%+ld)\n",
           i, r, r - base, u, u - ubase);
    fflush(stdout);
  }
  return 0;
}

int main(int argc, const char **v)
{
  g_ll_argc = argc;
  g_ll_argv = v;
  if (argc >= 2 && strcmp(v[1], "--teardown-test") == 0)
    return ll_teardown_test(argc >= 3 ? atoi(v[2]) : 5);
  // B182: never let a thrown LambLisp error object escape main -> std::terminate -> SIGABRT.  A
  // startup file-error (mk_input_file_port's %file-error) or an OOM syserror under memory pressure
  // used to abort the whole process with no diagnostic; report it and exit cleanly instead.
  try {
    setup();
    while (true) loop();
  }
  catch (Sexpr_t err) {
    fprintf(stderr, "\nLambLisp fatal: uncaught error object\n");
    if (err) { try { String s = err->str(); fprintf(stderr, "  %s\n", s.c_str()); } catch (...) {} }
    return 1;
  }
  catch (...) {
    fprintf(stderr, "\nLambLisp fatal: uncaught C++ exception\n");
    return 1;
  }
}
#endif
