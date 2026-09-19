// Copyright 2026 by Frobenius Norm LLC 2026-09-04 00:00:00
// Free for non-commercial use. Commercial use requires a license.
/*! @file ll_wasm_browser.cpp
  P175 Phase 2 -- the browser entry points.

  A browser page cannot call main() and let it sit in `while (true) loop();`: that would peg the
  tab's only thread and never return to the event loop, so nothing would ever be drawn and no
  keystroke would ever be delivered.  The env therefore links with -sINVOKE_RUN=0 (main is never
  called) and JavaScript drives the VM one step at a time through the three functions below.

  These are the ONLY wasm-specific entry points in the tree.  Everything they call --
  ::setup(), ::loop(), LL_Term -- is the same code every other target runs; see
  LL_Term::push_line() for why the input path is inverted rather than made asynchronous.
*/
#if LL_EMSCRIPTEN

#include <emscripten.h>
#include <cstdio>          //!< B442: fflush() on the entry-point boundary
#include <unistd.h>        //!< B442: fsync() -- the flush that actually reaches Module.print
#include "LambLisp.h"
#include "ll_vm_term.h"

//! Defined in main.cpp.  Declared rather than #included because main.cpp has no header.
void setup();
void loop();

extern "C" {

/*! Boot the VM: construct Lamb, install the native operators, load setup.scm.

  CALL THIS EXACTLY ONCE, and expect it to take a moment: it loads the whole staged `.scm` library
  from the preloaded MEMFS image.  It is a straight call to ::setup(), so a failure reports itself
  through the ordinary log path rather than through a return code -- the page should show the
  terminal output, not a status number.
*/
EMSCRIPTEN_KEEPALIVE void ll_wasm_boot(void)
{
  setup();
  //! QUIET BY DEFAULT IN THE BROWSER, and only in the browser.
  //!
  //! This page is a CUSTOMER-FACING DEMO, and the VM's diagnostics are written for us, not for a
  //! visitor: `LambMemoryManager::gc_pass() (Ngc 9) (Amax 11017) (Yuasa_MN 41 11094)` and a
  //! `Lamb::loop() Input:` echo of every line.  On a real workload that is hundreds of lines --
  //! measured 2026-09-06 in headless Chrome: one `(churn 40000 ...)` produced 336 gc_pass lines
  //! and 22 expand() reports.  Three consequences, all of which read as a broken product:
  //!   * the visitor's own answer is pushed out of the viewport by log lines;
  //!   * the flood LOOKS like the runtime struggling, when the same expression on linux_x86_64
  //!     produces MORE expansions (27 vs 22) and is simply how this allocation pattern paces;
  //!   * it advertises internals a customer has no use for.
  //!
  //! `(verbose)` turns it back on from the REPL, so nothing is hidden from anyone who wants it --
  //! the page's footer says so.
  //!
  //! NOT DONE FOR wasm32_wasi: that build is what `w3 test conform LL wasm` drives, and the
  //! harness PARSES this output.  Silencing it there would break the tier, so this lives in the
  //! Emscripten-only entry point rather than in setup().
  ll_term.quiet_echo = true;   // P203: the browser wants both
  ll_term.quiet_logs = true;
}

/*! B442: push any PARTIAL line out to Module.print.

  MUST BE CALLED AT THE END OF EVERY ENTRY POINT THAT RUNS THE VM, and the symptom if it is not is
  that the demo looks dead: `(display (+ 1 2))` computes 3, writes it, and prints NOTHING.

  Emscripten line-buffers stdout into Module.print -- a `\n` delivers the line, a partial line
  waits.  Every other target flushes the partial line from `LL_Term::redisplay()`, but all of that
  function's call sites are inside the character-at-a-time line EDITOR, and the browser never
  reaches it: input is PUSHED from JS, so the LL_EMSCRIPTEN arm returns at the top of
  `monitor_commandline()`.  The browser therefore has NO flush on the eval path at all, and
  `display` emits no trailing newline.

  IT LOOKS LIKE A QUIET-MODE BUG AND IS NOT.  With logs on, every `Lamb::loop() Output:` line ends
  in `\n` and INCIDENTALLY flushed whatever `display` had left pending, so the demo appeared to
  work; `ll_wasm_boot()` setting quiet_echo/quiet_logs above merely removed the accident.  Turning
  quiet back off would hide this again and leave it for the next caller who displays without a
  newline.

  NOT `LL_Term::flush()`, despite the name -- that is an INPUT flush (it resets commandLine, cursor
  and esc_st, and flushes the input serial).
*/
static void ll_wasm_flush(void)
{
  //! TWO FLUSHES, AND THE SECOND IS THE ONE THAT WORKS.  `fflush` alone does NOT fix this -- it
  //! was tried first and changed nothing.  It moves bytes out of the libc FILE buffer into
  //! Emscripten's TTY device, and the device is where the line assembly happens:
  //!
  //!     put_char(tty, val) { if (val === null || val === 10) { out(...); tty.output = []; }
  //!                          else tty.output.push(val); }
  //!
  //! i.e. `Module.print` is called ONLY on a newline.  A partial line sits in `tty.output` no
  //! matter how hard libc is flushed.  The same object provides the escape hatch --
  //!
  //!     fsync(tty) { if (tty.output?.length > 0) { out(...); tty.output = []; } }
  //!
  //! -- reachable from C because `TTY.stream_ops.fsync` forwards straight to it.  So `fsync(1)` on
  //! the fd, not `fflush` on the FILE, is what delivers a partial line to the page.  Keep the
  //! fflush: it is what moves the bytes into the device in the first place.
  fflush(stdout);
  fflush(stderr);
  fsync(STDOUT_FILENO);
  fsync(STDERR_FILENO);
}

/*! Evaluate one line of REPL input.

  `line` is UTF-8, WITHOUT a trailing newline; JS is responsible for line editing, because the
  browser terminal (xterm.js) already does it far better than a raw-mode line editor could.
  Output arrives on stdout/stderr, which Emscripten routes to Module.print / Module.printErr.
*/
EMSCRIPTEN_KEEPALIVE void ll_wasm_eval(const char *line)
{
  ll_term.push_line(line ? line : "");
  loop();
  ll_wasm_flush();
}

/*! Run one idle iteration of the VM with NO input.

  The page should call this on an interval (or from requestAnimationFrame).  It is not
  decoration: Lamb::loop() is where the Scheme-level `(loop)` procedure runs, where the deferred
  GC status line is emitted, and where the incremental collector gets its idle quantum.  A page
  that only ever calls ll_wasm_eval() does all its collection inside the user's keystrokes.
*/
EMSCRIPTEN_KEEPALIVE void ll_wasm_tick(void)
{
  loop();
  ll_wasm_flush();
}

}  // extern "C"

#endif // LL_EMSCRIPTEN
