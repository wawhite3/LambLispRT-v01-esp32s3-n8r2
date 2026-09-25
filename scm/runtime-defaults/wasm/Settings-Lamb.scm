;;; Copyright 2026 by Frobenius Norm LLC 2026-09-16
;;;
;;; Settings-Lamb.scm for the BROWSER demo (wasm32_browser) -- pre-heap GC config, read by the C++
;;; pre-reader before the heap exists.  Staged over the shared runtime-defaults/Settings-Lamb.scm
;;; by scm/targets/wasm32_browser.manifest; every other target keeps the shared 8K default.
;;;
;;; WHY THE BROWSER NEEDS ITS OWN (B437).  The shared default is 8,192 cells -- about 115 KB, an
;;; MCU-sized pool.  A browser tab has gigabytes, and on that pool merely LOADING the staged .scm
;;; library outran the collector and printed
;;;     LambMemoryManager::gc_urgent() INCREMENTAL GC FELL BEHIND (synchronous catch-up)
;;; on the customer-facing demo page.  That message is an UNBOUNDED pause -- the one thing the
;;; real-time claim forbids -- and it is on the TERM channel so `quiet` cannot hide it.
;;;
;;; A SHIPPED FILE IS THE MECHANISM, NOT A COMPILE-TIME DEFAULT.  An #if LL_EMSCRIPTEN default in
;;; LambPreSettings was written first and reverted: whatever this file says WINS over the compiled
;;; default, so with a Settings-Lamb.scm in the image the compile-time value is unreachable code.
;;; One mechanism, and it is this one.
;;;
;;; WHY THE BROWSER CANNOT LEARN THIS FOR ITSELF, unlike every board.  The GC rewrites Settings on
;;; a heap expansion, and a board reads it back on the next boot and comes back correctly sized.
;;; The demo's /data is MEMFS, rebuilt from the preloaded image on every page load, so that write
;;; is discarded and the browser ALWAYS cold-starts.  It can never converge; it has to be told.
;;;
;;; DELIBERATELY NO gc_total_marked.  Shipping the measured live set (12,271 cells on 2026-09-16)
;;; would size the heap perfectly and go stale silently as the library grows -- a hand-maintained
;;; copy of a figure the GC measures for itself.  A pool generous enough not to need the
;;; measurement does not rot.  64K cells is ~900 KB and ~5x the demo's settled live set.

((cell_block_size . 65536)
 (extension_block_size . 16384)
 (va_list_max . 8192))
