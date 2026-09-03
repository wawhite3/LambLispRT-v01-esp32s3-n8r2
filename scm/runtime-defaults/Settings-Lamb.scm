; Settings-Lamb.scm -- pre-heap GC config (read by the C++ pre-reader before the heap exists).
; Shipped as a runtime default so it ALWAYS exists on the FS (no "failed to open" at boot);
; the GC may rewrite it. Reboot required to apply cell_block_size. 8192 = default block 1 (8K).
((cell_block_size . 8192))
