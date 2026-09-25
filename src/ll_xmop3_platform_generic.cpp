// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"
#if defined(__GLIBC__)
#include <malloc.h>   //!< mallinfo2 for Platform.sysmem-inuse
#endif

#include "ll_platform_generic.h"
#include <cstdlib>			// getenv / _exit (R7RS process-context)
#if LL_POSIX || LL_AMD64 || LL_ARM64
#include <cstdio>			// popen / pclose for (system-capture)
//! NOT ON WINDOWS.  MinGW has no <sys/wait.h> and no WIFEXITED: `_pclose` returns the child's
//! EXIT CODE directly, not a wait status, so the decode below is not merely unavailable there --
//! it would be wrong.  LL_WINDOWS implies LL_POSIX and subtracts (see ll_platform_generic.h), and
//! this is one of the subtractions, spelled the way that file prescribes.
#if !LL_WINDOWS
#include <sys/wait.h>			// WIFEXITED / WEXITSTATUS -- pclose returns a WAIT STATUS,
					// not an exit code: 0x100 for `exit 1`.  Decode it or every
					// nonzero status reads as a wrong number.
#endif  //!< !LL_WINDOWS -- no <sys/wait.h> there
#endif

#if LL_POSIX || LL_AMD64 || LL_ARM64
extern char **environ;			//!< POSIX environment, for (get-environment-variables)
extern int          g_ll_argc;		//!< argv captured in main.cpp, for (command-line)
extern const char **g_ll_argv;
#endif
//! @defgroup xmop3_platform Platform (generic)
//! @ingroup xmop3
//! @brief LambLisp Platform (generic) builtins.
//! @{

LambPlatform lambPlatform;

//! Return bytes of free heap memory on the platform.
Sexpr_t Platform_mop3_free_heap(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return lamb.mk_integer(lambPlatform.free_heap(), env_exec); }

//! [B520] THE POOL CELL BLOCKS AND PAYLOADS SHARE.  `Platform.free-heap` is `esp_get_free_heap_size()`
//! -- the AGGREGATE of internal DRAM and PSRAM -- which cannot see the pool that actually runs out.
//! `cell_pool_free()` reports the pool cell blocks are allocated from, and `ll_platform_generic.h`
//! already names the failure this exposes: the cell heap grows until PSRAM is full and "starves the
//! PAYLOADS (strings, bignum digits, vectors, bytecode) that share that pool".
//!
//! EXPOSED BECAUSE THE COLLAPSE IS UNINSTRUMENTED.  In the B520 runs, 951 KB disappears between the
//! last reading and the first `alloc_exec` failure, with ZERO samples in between -- every diagnostic
//! that fires is downstream of the event.  A Scheme-visible reading lets `bench-timed/run` bracket
//! the loss to one benchmark and one phase, which is the one thing none of the existing
//! instrumentation can do.
Sexpr_t Platform_mop3_cell_pool_free(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return lamb.mk_integer(lambPlatform.cell_pool_free(), env_exec); }
Sexpr_t Platform_mop3_free_internal(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return lamb.mk_integer(lambPlatform.free_internal(), env_exec); }
Sexpr_t Platform_mop3_free_dma(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return lamb.mk_integer(lambPlatform.free_dma(), env_exec); }
//! Return bytes of free stack space on the platform.
Sexpr_t Platform_mop3_free_stack(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return lamb.mk_integer(lambPlatform.free_stack(), env_exec); }
//! Return microseconds since boot as an integer.
Sexpr_t Platform_mop3_micros(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return lamb.mk_integer(micros(), env_exec);  }
//! Return milliseconds since boot as an integer.
//! LLArduino introspection.  These exist so the layer's Arduino-fidelity guarantees are
//! ASSERTED rather than asserted-in-a-comment: (llarduino-fmt-int 255 16) must be "ff" with no 0x
//! prefix, (llarduino-fmt-real 1.5 2) must be "1.50" not "1.5", and (llarduino-eol) must be "\r\n"
//! -- all rendered through the real Print, so a divergence from a device shows up as a test failure.
Sexpr_t Platform_mop3_llarduino_backend(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
#if LL_ARDUINO
  return lamb.mk_string(ll_llarduino_backend(), env_exec);
#else
  return lamb.mk_string("arduino-core", env_exec);      //!< the vendor core is answering, not us
#endif
}

Sexpr_t Platform_mop3_llarduino_fmt_int(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
#if LL_ARDUINO || LL_ESP_ARDUINO
  LL_int32 v    = lamb.car(sexpr)->coerce_int32();
  LL_int32 base = (lamb.cdr(sexpr) == NIL) ? 10 : lamb.cadr(sexpr)->coerce_int32();
  return lamb.mk_string(ll_llarduino_fmt_int((long) v, (int) base), env_exec);
#else
  (void) sexpr;  return HASHF;
#endif
}

Sexpr_t Platform_mop3_llarduino_fmt_real(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
#if LL_ARDUINO || LL_ESP_ARDUINO
  double   v      = lamb.car(sexpr)->coerce_float64();
  LL_int32 digits = (lamb.cdr(sexpr) == NIL) ? 2 : lamb.cadr(sexpr)->coerce_int32();
  return lamb.mk_string(ll_llarduino_fmt_real(v, (int) digits), env_exec);
#else
  (void) sexpr;  return HASHF;
#endif
}

Sexpr_t Platform_mop3_llarduino_eol(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
#if LL_ARDUINO || LL_ESP_ARDUINO
  return lamb.mk_string(ll_llarduino_eol(), env_exec);
#else
  return HASHF;
#endif
}

Sexpr_t Platform_mop3_millis(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ return lamb.mk_integer(millis(), env_exec);  }
//! Return elapsed milliseconds since the start of the current Arduino loop() call.
Sexpr_t Platform_mop3_loop_elapsed_ms(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return lamb.mk_integer(lambPlatform.loop_elapsed_ms(), env_exec);  }
//! Return elapsed microseconds since the start of the current Arduino loop() call.
Sexpr_t Platform_mop3_loop_elapsed_us(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ return lamb.mk_integer(lambPlatform.loop_elapsed_us(), env_exec);  }
//! Reboot the platform (embedded) or do nothing (POSIX).
Sexpr_t Platform_mop3_lamb_reboot(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ lambPlatform.reboot(); return OBJ_UNDEF; }

//! Flush stdio and exit (POSIX) or reboot (embedded).
Sexpr_t Platform_mop3_exit(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  lambPlatform.end();                    //!< release platform resources
#if LL_POSIX || LL_AMD64 || LL_ARM64
  fflush(nullptr);  _exit(0);            //!< Linux: flush stdio then exit
#else
  lambPlatform.reboot();                 //!< embedded: reboot after cleanup
#endif
  return OBJ_UNDEF;                      //!< unreachable
}

//! Delay for the given number of milliseconds using platform delay().
Sexpr_t Platform_mop3_delay_ms(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ delay((unsigned long) lamb.car(sexpr)->mustbe_int32());  return OBJ_UNDEF; }
//! Run the GC idle task for up to the given number of microseconds.
Sexpr_t Platform_mop3_gc_idle_task(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)		{ lamb.gc_idle_task_us(lamb.car(sexpr)->mustbe_int32(), env_exec);  return OBJ_UNDEF; }
//! Run one complete GC cycle (mark + sweep); use before benchmarks to reset GC phase.
Sexpr_t Platform_mop3_gc_collect(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)          { lamb.gc_collect(env_exec);  return OBJ_UNDEF; }

//! Return a bytevector of n cryptographically random bytes.
Sexpr_t Platform_mop3_random_bytevector(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_random_bytevector()");
  LL_int32 n = lamb.car(sexpr)->mustbe_int32();
  if (n < 0) throw NIL->mk_error("%s negative size %d\n", me, (int) n);
  Sexpr_t bv = lamb.mk_bytevector(n, env_exec);
  LL_int32 nelems;
  ByteVec_t elems;
  bv->any_bvec_get_info(nelems, elems);
  lambPlatform.rand(elems, nelems);
  return bv;
}

//! Return a cryptographically random integer.
Sexpr_t Platform_mop3_random_integer(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)	{ LL_int32 r = 0;  lambPlatform.rand((byte *) &r, sizeof(r));  return lamb.mk_integer(r, env_exec); }
//! Return a cryptographically random float32 in [0, 1).
Sexpr_t Platform_mop3_random_real(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  unsigned long long iran = 0;
  lambPlatform.rand((byte *) &iran, sizeof(iran));
  return lamb.mk_float32((LL_float32) (iran * 0x1p-64), env_exec);		//!< [0, 2^64-1] * 2^-64 → [0,1) exact
}

// ── P6 LambSettings runtime mop3s ───────────────────────────────────────────

//! Return the number of cells in the first (fixed) memory block.
Sexpr_t Platform_mop3_cell_block_size(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.mem_cell_block_size(), env_exec); }

//! Return the current number of allocated memory blocks.
Sexpr_t Platform_mop3_n_cell_blocks(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.mem_n_cell_blocks(), env_exec); }

//! THE CELL POOL, computed ONCE in the VM.  Callers used to reconstruct it as
//!   nblocks * cell_block_size
//! which is right only if every block is the same size.  With a 65,536-cell base block and
//! 8,192-cell expansions that overstated the pool by 7.2x (4,194,304 reported against a true
//! 581,632), and every occupancy figure derived from it was wrong by the same factor.
//! total_cells() is baseBlockSize + NexpansionBlocks * expansionBlockSize -- ask the VM, do not
//! re-derive it.
Sexpr_t Platform_mop3_total_cells(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.mem_total_cells(), env_exec); }

//! Return the current number of free cells in the GC heap.
Sexpr_t Platform_mop3_nfree(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.mem_nfree(), env_exec); }

//! Return the maximum number of GC blocks allowed before the memory_cap_reached warning fires.
Sexpr_t Platform_mop3_max_cell_blocks(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.mem_max_cell_blocks(), env_exec); }

//! Set the maximum number of GC blocks before memory_cap_reached warning fires.
Sexpr_t Platform_mop3_set_max_cell_blocks(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ lamb.mem_set_max_cell_blocks(lamb.car(sexpr)->mustbe_int32());  return OBJ_UNDEF; }

Sexpr_t Platform_mop3_extension_block_size(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.mem_extension_block_size(), env_exec); }

//! Set the number of cells in each future extension memory block.
Sexpr_t Platform_mop3_set_extension_block_size(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ lamb.mem_set_extension_block_size(lamb.car(sexpr)->mustbe_int32());  return OBJ_UNDEF; }

//! Expand the heap to at least n blocks; allocates extension blocks as needed.
Sexpr_t Platform_mop3_expand_to_n_blocks(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ lamb.mem_expand_to_n_blocks(lamb.car(sexpr)->mustbe_int32(), env_exec);  return OBJ_UNDEF; }

//! (Platform.gc-diag) -> (pass-max-us urgent-max-us urgent-calls).  Reported through the
//! RESULT of a mop3 so the bench can `display` it -- warn() output never survives the embedded
//! path (W3_REPL_QUIET at the source, plus serial_run.py dropping any line naming LambMemory or
//! gc_pass), so a warn-based probe silently reports nothing and looks like a clean result.
//! (Platform.sysmem-inuse) -> bytes currently held by the SYSTEM allocator, or -1.
//!
//! THE CELL POOL CANNOT ANSWER THE FINALIZATION QUESTION, which is why this exists.  A vector,
//! bytevector or heap string keeps its ELEMENTS in a malloc'd block and only its handle in a
//! cell -- measured: a `(make-vector 5000)` moved the free-cell count by FIVE.  So a
//! backing block that is never freed when its cell is collected is a real leak that every
//! cell-based counter reports as clean.  This reads the allocator directly.
//!
//! -1 means "this build cannot tell", NOT "zero leaked": mallinfo2 is glibc-only, so wasm, MinGW
//! and the ESP32 return -1 and a caller must treat that as UNKNOWN and skip, never as a pass.
Sexpr_t Platform_mop3_sysmem_inuse(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_sysmem_inuse()");
  (void) sexpr;
  ll_try {
#if defined(__GLIBC__)
    struct mallinfo2 mi = mallinfo2();
    return lamb.mk_integer((LL_int64) mi.uordblks, env_exec);
#else
    return lamb.mk_integer((LL_int64) -1, env_exec);
#endif
  }
  ll_catch();
}


//! Return the GC time budget per loop iteration in nanoseconds.
Sexpr_t Platform_mop3_gc_budget_ns(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.mem_gc_budget_ns(), env_exec); }

//! Set the GC time budget per loop iteration in nanoseconds.
Sexpr_t Platform_mop3_set_gc_budget_ns(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ lamb.mem_set_gc_budget_ns(lamb.car(sexpr)->mustbe_int32());  return OBJ_UNDEF; }

//! Return the target GC load as a percentage of loop time.
Sexpr_t Platform_mop3_gcload_target_pct(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.mem_gcload_target_pct(), env_exec); }

//! Set the target GC load percentage (0--100).
Sexpr_t Platform_mop3_set_gcload_target_pct(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ lamb.mem_set_gcload_target_pct(lamb.car(sexpr)->mustbe_int32());  return OBJ_UNDEF; }

//! Return the current verbosity level (0 = silent, higher = more logging).
Sexpr_t Platform_mop3_verbosity(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ return lamb.mk_integer(lamb.verbosity(), env_exec); }

//! Set the verbosity level.
Sexpr_t Platform_mop3_set_verbosity(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ lamb.set_verbosity(lamb.car(sexpr)->mustbe_int32());  return OBJ_UNDEF; }



//! Quiet REPL: enable/disable line-mode quiet console (suppress async log() output and
//! the per-char redisplay() prompt-reprint).  The LLIP tunnel uses this -- (llt) sets it on,
//! (en) clears it -- so a tool's frames aren't garbled by the prompt-redraw flood.
Sexpr_t Platform_mop3_repl_quiet(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{ lamb.set_repl_quiet(lamb.car(sexpr) != HASHF);  return OBJ_UNDEF; }

//! (features) -- R7RS (scheme base): the list of feature identifiers this implementation provides
//! (kept consistent with cond-expand).
static Sexpr_t Platform_mop3_features(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_features()");
  Sexpr_t res = NIL;
  mop3_gc_protect(res, {
      res = lamb.cons(lamb.mk_symbol("ieee-float", env_exec), res, env_exec);
      res = lamb.cons(lamb.mk_symbol("r7rs",       env_exec), res, env_exec);
      res = lamb.cons(lamb.mk_symbol("lamblisp",   env_exec), res, env_exec);
  });
  return res;
}

//! (command-line) -- R7RS (scheme process-context): argv as a list of strings (empty on embedded).
static Sexpr_t Platform_mop3_command_line(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_command_line()");
  Sexpr_t res = NIL;
#if LL_POSIX || LL_AMD64 || LL_ARM64
  for (int i = g_ll_argc - 1; i >= 0; i--) {
    mop3_gc_protect(res, {                       // re-root accumulator across mk_string alloc
        Sexpr_t s = lamb.mk_string(env_exec, "%s", g_ll_argv[i]);
        res = lamb.cons(s, res, env_exec);
    });
  }
#endif
  return res;
}

//! (get-environment-variable name) -- R7RS: the value string, or #f if unset (always #f on embedded).
static Sexpr_t Platform_mop3_get_env_var(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_get_env_var()");
#if LL_POSIX || LL_AMD64 || LL_ARM64
  Sexpr_t name = lamb.car(sexpr);
  const char *v = getenv(name->any_str_get_chars());
  return v ? lamb.mk_string(env_exec, "%s", v) : HASHF;
#else
  return HASHF;
#endif
}

//! (get-environment-variables) -- R7RS: alist of (name . value) string pairs ('() on embedded).
static Sexpr_t Platform_mop3_get_env_vars(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_get_env_vars()");
  Sexpr_t res = NIL;
#if LL_POSIX || LL_AMD64 || LL_ARM64
  for (char **e = environ; e && *e; e++) {
    const char *eq = strchr(*e, '=');
    if (!eq) continue;
    mop3_gc_protect(res, {                       // re-root accumulator across the allocations below
        //!< `nm` is a C-STACK local and the next mk_string ALLOCATES, so a GC quantum
        //!< there can reclaim it -- and nothing would fault until the pair is read much later.
        Sexpr_t nm  = lamb.mk_string((LL_int32) (eq - *e), *e, env_exec);
        Sexpr_t pr  = OBJ_UNDEF;
        mop3_gc_protect(nm, {
            Sexpr_t val = lamb.mk_string(env_exec, "%s", eq + 1);
            pr = lamb.cons(nm, val, env_exec);          //!< cons roots both of its own arguments
        });
        res = lamb.cons(pr, res, env_exec);
    });
  }
#endif
  return res;
}

//! (exit [obj]) -- R7RS process-context: run cleanup then terminate.  obj: absent/#t -> success,
//! #f -> failure, integer -> that code.  On embedded there is no process to exit: reboot.
static Sexpr_t Platform_mop3_exit_r7(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_exit_r7()");
  int code = 0;
  if (sexpr != NIL) {
    Sexpr_t o = lamb.car(sexpr);
    if (o == HASHF) code = 1;
    else if (o->is_any_int()) code = (int) o->mustbe_int32();
  }
  lambPlatform.end();
#if LL_POSIX || LL_AMD64 || LL_ARM64
  fflush(nullptr);  _exit(code);
#else
  lambPlatform.reboot();
#endif
  return OBJ_UNDEF;                              //!< unreachable
}

//! (emergency-exit [obj]) -- R7RS: terminate WITHOUT running cleanup handlers.
static Sexpr_t Platform_mop3_emergency_exit(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_emergency_exit()");
  int code = 0;
  if (sexpr != NIL) {
    Sexpr_t o = lamb.car(sexpr);
    if (o == HASHF) code = 1;
    else if (o->is_any_int()) code = (int) o->mustbe_int32();
  }
#if LL_POSIX || LL_AMD64 || LL_ARM64
  _exit(code);                                   //!< no cleanup, no stdio flush
#else
  lambPlatform.reboot();
#endif
  return OBJ_UNDEF;                              //!< unreachable
}

//! HOST ONLY -- these two run an external program, which an MCU target has no way to do.
//! On every non-POSIX target they return #f rather than erroring, matching
//! (get-environment-variable): a script that probes for the capability gets a clean #f, and a
//! shipped MCU image carries no shell-execution surface at all.
//!
//! NOT R7RS.  R7RS-small's (scheme process-context) is exactly command-line,
//! get-environment-variable(s), exit and emergency-exit -- all already above.  There is no
//! standard `system`, so these follow the Guile/Chicken spelling rather than inventing one.
#if LL_POSIX || LL_AMD64 || LL_ARM64
//! Decode what pclose()/system() return: a WAIT STATUS.  Returns the exit code, or -1 if the
//! child was signalled or the launch failed.
static int ll_wait_status_to_code(int rc)
{
  int res = -1;
#if LL_WINDOWS
  //! _pclose gives the exit code itself; there is no status to decode and no macro to decode it.
  if (rc != -1) res = rc;
#else
  if (rc != -1 && WIFEXITED(rc)) res = WEXITSTATUS(rc);
#endif
  return res;
}
#endif

//! (system COMMAND) -> exit-status integer, or #f if the command could not be launched
//! (and on any non-POSIX target).  COMMAND runs under /bin/sh; stdout and stderr are
//! INHERITED, so output goes to the console rather than to the caller -- use
//! (system-capture) when the output is the point.
static Sexpr_t Platform_mop3_system(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_system()");
#if LL_POSIX || LL_AMD64 || LL_ARM64
  Sexpr_t cmd = lamb.car(sexpr)->mustbe_any_str_t();
  fflush(nullptr);                               //!< the child shares our stdout; flush first or
                                                 //!< our buffered text interleaves after its output
  int rc = ::system(cmd->any_str_get_chars());
  return (rc == -1) ? HASHF : lamb.mk_int32((LL_int32) ll_wait_status_to_code(rc), env_exec);
#else
  (void) sexpr; (void) env_exec;
  return HASHF;
#endif
}

//! (system-capture COMMAND) -> (exit-status . output-string), or #f if the command could not be
//! launched (and on any non-POSIX target).  COMMAND runs under /bin/sh and its STDOUT is
//! collected into the string; stderr is NOT captured -- append `2>&1` to COMMAND to fold it in.
//! The status is car and the output cdr, so a caller can check the status without re-running the
//! command, which is the whole reason this returns a pair rather than a bare string.
static Sexpr_t Platform_mop3_system_capture(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::Platform_mop3_system_capture()");
#if LL_POSIX || LL_AMD64 || LL_ARM64
  Sexpr_t cmd = lamb.car(sexpr)->mustbe_any_str_t();
  fflush(nullptr);
  FILE *fp = popen(cmd->any_str_get_chars(), "r");
  if (!fp) return HASHF;
  size_t cap = 4096, len = 0;
  char  *buf = (char *) malloc(cap);
  if (!buf) { pclose(fp); return HASHF; }
  for (;;) {
    if (len + 1024 > cap) {                      //!< grow BEFORE the read, never after
      char *nb = (char *) realloc(buf, cap * 2);
      if (!nb) { free(buf); pclose(fp); return HASHF; }
      buf = nb; cap *= 2;
    }
    size_t n = fread(buf + len, 1, 1024, fp);
    len += n;
    if (n < 1024) break;                         //!< EOF or error -- either way we are done
  }
  int code = ll_wait_status_to_code(pclose(fp));
  //! Build the string BEFORE the cons and root it: mk_string allocates, and so does cons, so an
  //! unrooted string here can be collected by the allocation that follows it.
  Sexpr_t res = NIL;
  Sexpr_t out = lamb.mk_string((LL_int32) len, (Charst_t) buf, env_exec);
  free(buf);
  mop3_gc_protect(out, {
      res = lamb.cons(lamb.mk_int32((LL_int32) code, env_exec), out, env_exec);
  });
  return res;
#else
  (void) sexpr; (void) env_exec;
  return HASHF;
#endif
}

Sexpr_t __lamb_platform_generic_install_mop3(Lamb &lamb, Sexpr_t list_containing_env_target, Sexpr_t env_exec)
{
  ME("::__lamb_platform_generic_install_mop3()");

  ll_try {
    Sexpr_t env_target = lamb.car(list_containing_env_target);
    lamb.log("%s installing Mops\n", me);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } std_procs[] = {
      { __lamb_platform_generic_install_mop3,     "Platform.install-mop3",         false },
      { Platform_mop3_micros,                     "micros",                        false },
      { Platform_mop3_millis,                     "millis",                        false },
      { Platform_mop3_llarduino_backend,          "llarduino-backend",             false },
      { Platform_mop3_llarduino_fmt_int,          "llarduino-fmt-int",             false },
      { Platform_mop3_llarduino_fmt_real,         "llarduino-fmt-real",            false },
      { Platform_mop3_llarduino_eol,              "llarduino-eol",                 false },
      { Platform_mop3_micros,                     "Platform.micros",               false },
      { Platform_mop3_millis,                     "Platform.millis",               false },
      { Platform_mop3_lamb_reboot,                "Platform.reboot",               false },
      { Platform_mop3_repl_quiet,                 "lamb-repl-quiet!",              false },
      { Platform_mop3_exit,                       "lamblisp-exit",                 false },
      { Platform_mop3_features,                   "features",                      false },
      { Platform_mop3_command_line,               "command-line",                  false },
      { Platform_mop3_get_env_var,                "get-environment-variable",      false },
      { Platform_mop3_get_env_vars,               "get-environment-variables",     false },
      { Platform_mop3_exit_r7,                    "exit",                          false },
      { Platform_mop3_emergency_exit,             "emergency-exit",                false },
      { Platform_mop3_system,                     "system",                        false },
      { Platform_mop3_system_capture,             "system-capture",                false },
      { Platform_mop3_random_bytevector,          "Platform.random-bytevector",    false },
      { Platform_mop3_random_integer,             "Platform.random-integer",       false },
      { Platform_mop3_random_real,                "Platform.random-real",          false },
      { Platform_mop3_loop_elapsed_us,            "Platform.loop-elapsed-us",      false },
      { Platform_mop3_loop_elapsed_ms,            "Platform.loop-elapsed-ms",      false },
      { Platform_mop3_free_heap,                  "Platform.free-heap",            false },
      { Platform_mop3_cell_pool_free,             "Platform.cell-pool-free",       false },
      { Platform_mop3_free_internal,              "Platform.free-internal",        false },
      { Platform_mop3_free_dma,                   "Platform.free-dma",             false },
      { Platform_mop3_free_stack,                 "Platform.free-stack",           false },
      { Platform_mop3_delay_ms,                   "delay-ms",                      false },
      { Platform_mop3_gc_idle_task,               "Platform.gc-idle-task!",        false },
      { Platform_mop3_gc_collect,                 "gc!",                           false },
      { Platform_mop3_cell_block_size,            "Platform.cell-block-size",      false },
      { Platform_mop3_n_cell_blocks,              "Platform.n-cell-blocks",        false },
      { Platform_mop3_total_cells,                "Platform.total-cells",          false },
      { Platform_mop3_nfree,                      "Platform.nfree",                false },
      { Platform_mop3_max_cell_blocks,             "Platform.max-cell-blocks",      false },
      { Platform_mop3_set_max_cell_blocks,        "Platform.max-cell-blocks!",     false },
      { Platform_mop3_extension_block_size,       "Platform.extension-block-size", false },
      { Platform_mop3_set_extension_block_size,   "Platform.extension-block-size!",false },
      { Platform_mop3_expand_to_n_blocks,         "Platform.expand-to-n-blocks!",  false },
      { Platform_mop3_sysmem_inuse,               "Platform.sysmem-inuse",         false },
      { Platform_mop3_gc_budget_ns,               "Platform.gc-budget-ns",         false },
      { Platform_mop3_set_gc_budget_ns,           "Platform.gc-budget-ns!",        false },
      { Platform_mop3_gcload_target_pct,          "Platform.gcload-target-pct",    false },
      { Platform_mop3_set_gcload_target_pct,      "Platform.gcload-target-pct!",   false },
      { Platform_mop3_verbosity,                  "Platform.verbosity",            false },
      { Platform_mop3_set_verbosity,              "Platform.verbosity!",           false },
    };
    const int Nstd_procs = sizeof(std_procs)/sizeof(std_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nstd_procs);
    for (int i = 0; i < Nstd_procs; i++) {
      const auto &p = std_procs[i];
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
