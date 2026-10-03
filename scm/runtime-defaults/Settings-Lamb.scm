; Settings-Lamb.scm -- pre-heap GC config (read by the C++ pre-reader before the heap exists).
; Shipped as a runtime default so it ALWAYS exists on the FS (no "failed to open" at boot);
; the GC may rewrite it. Reboot required to apply cell_block_size. 8192 = default block 1 (8K).
;
; THE GC REWRITES THIS FILE IN FULL (on the first heap expansion), preserving every key it finds.
; Before B417 it wrote gc_total_marked ALONE, truncating the rest away -- if you are reading an
; older board's file and a setting you made has vanished, that is why.
;
; va_list_max -- cap on ONE formatted log/error message; longer text is TRUNCATED, not an error.
;   Clamped on load to [1024, 65536].  The ceiling is autobuf_t's own limit, past which the
;   formatter would RAISE while formatting -- i.e. throw while building the message the throw
;   needs.  Raise this if diagnostics are being clipped; it costs one buffer, grown on demand.
((cell_block_size . 8192)
 (va_list_max . 8192))
