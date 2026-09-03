// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"
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

void setup()
{
  unsigned long t_start = millis();
  ME("::setup()");

#if LL_ESP32 || LL_ESP32S3
  // Disable watchdogs so long Scheme evaluations (benchmarks, compilation)
  // don't trigger TG0WDT (TWDT) or TG1WDT (IWDT) system resets.
  esp_task_wdt_deinit();                          // disable TWDT (TG0WDT)
#if LL_ESP32S3
  TIMERG1.wdtwprotect.val = TIMG_WDT_WKEY_V;   // unlock TG1WDT write-protect
  TIMERG1.wdtconfig0.wdt_en = 0;               // disable TG1WDT (IWDT)
  TIMERG1.wdtwprotect.val = 0;                  // re-lock
#else  // LL_ESP32 (original, wdt_ prefix registers)
  TIMERG1.wdt_wprotect = TIMG_WDT_WKEY_V;      // unlock TG1WDT write-protect
  TIMERG1.wdt_config0.en = 0;                  // disable TG1WDT (IWDT)
  TIMERG1.wdt_wprotect = 0;                    // re-lock
#endif
#endif

  LambStdio.begin();
  global_printf("[%lu] %s LambLisp starting, 1st light @%lu ms\n", millis(), me, t_start);
#if LL_ESP32
  global_printf("[%lu] %s free EXEC/IRAM heap: %u bytes\n", millis(), me,
                (unsigned) heap_caps_get_free_size(MALLOC_CAP_EXEC));
#endif
  void ll_heap_note(const char *tag);   // B95 boot-phase internal-DRAM tracer
  ll_heap_note("boot: before new Lamb");
  lamb = new Lamb;	//avoid static allocation due to possible lack of terminal at static construct time
  lamb->setup();
  
  lamb->log("%s Installing local native operators\n", me);
  install_local_native_operators(*lamb);

  ll_heap_note("before setup.scm load");
  lamb->log("%s Loading setup.scm\n", me);
  Sexpr_t ignored = lamb->load("setup.scm", lamb->r5_interaction_environment(), 0);
  ll_heap_note("after setup.scm load");

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

}

void loop()
{
  ME("::loop()");
  ll_try {
    lamb->loop();
  }

  ll_catch_terminal
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
    long sz = 0, res = 0;
    FILE *f = fopen("/proc/self/statm", "r");
    if (f) { if (fscanf(f, "%ld %ld", &sz, &res) != 2) res = 0; fclose(f); }
    return res * (sysconf(_SC_PAGESIZE) / 1024);
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
