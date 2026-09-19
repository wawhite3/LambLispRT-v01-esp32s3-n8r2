# P175: SCons builder for the wasm32 platform.
#
# Two hosts, one platform, selected by the board's build.wasm_host:
#   "wasi"    -> $WASI_SDK/bin/clang++ --target=wasm32-wasip1   -> a bare .wasm CLI module
#   "browser" -> em++                                            -> LambLisp.js + LambLisp.wasm
#
# Copyright 2026 by Frobenius Norm LLC 2026-09-04 00:00:00

import os
import sys

from SCons.Script import AlwaysBuild, Default, DefaultEnvironment

env   = DefaultEnvironment()
board = env.BoardConfig()
host  = board.get("build.wasm_host", "wasi")

# ---------------------------------------------------------------------------
# THE STACK SIZE IS A CONTRACT WITH ll_platform_generic.h.
#
# wasm has no guard page.  The shadow stack is a slice of linear memory whose size is fixed HERE,
# at link time, and running off the end does NOT fault -- by default the stack grows DOWN into the
# static data segment, so the first symptom of an overrun is silently corrupted globals somewhere
# else entirely.  Two things keep that from happening, and they must agree:
#   1. LL_EVAL_STACK_BUDGET (ll_platform_generic.h, LL_WASM arm) = 3 MB -- the interpreter's own
#      recursion guard, which raises a catchable "recursion too deep" BEFORE the stack runs out;
#   2. -Wl,--stack-first, which moves the stack BELOW the data segment so an overrun runs off the
#      bottom of linear memory and TRAPS instead of quietly overwriting globals.
# Change WASM_STACK_BYTES and you must change LL_EVAL_STACK_BUDGET with it, keeping ~1 MB of head.
# ---------------------------------------------------------------------------
WASM_STACK_BYTES  = 4 * 1024 * 1024
WASM_INITIAL_MEM  = 64 * 1024 * 1024     #!< linear memory at instantiation; grows on demand
WASM_MAX_MEM      = 1024 * 1024 * 1024   #!< hard ceiling, so a runaway allocation fails instead of OOM-ing the tab


def _find_wasi_sdk():
    import glob
    cands = [c for c in (os.environ.get("WASI_SDK_PATH", ""), "/opt/wasi-sdk", "/usr/lib/wasi-sdk") if c]
    cands += sorted(glob.glob(os.path.expanduser("~/wasi-sdk-*")), reverse=True)
    cands += sorted(glob.glob("/opt/wasi-sdk-*"), reverse=True)
    for c in cands:
        if os.path.isfile(os.path.join(c, "bin", "clang++")):
            return c
    return ""


if host == "wasi":
    sdk = _find_wasi_sdk()
    if not sdk:
        sys.stderr.write(
            "\n[wasm32] FATAL: wasi-sdk not found and this env needs it.\n"
            "  curl -L -o /tmp/wasi-sdk.tar.gz https://github.com/WebAssembly/wasi-sdk/"
            "releases/download/wasi-sdk-34/wasi-sdk-34.0-x86_64-linux.tar.gz\n"
            "  tar xzf /tmp/wasi-sdk.tar.gz -C $HOME\n"
            "  (or set WASI_SDK_PATH)\n\n")
        env.Exit(1)
    bindir  = os.path.join(sdk, "bin")
    sysroot = os.path.join(sdk, "share", "wasi-sysroot")

    env.Replace(
        AR       = os.path.join(bindir, "llvm-ar"),
        AS       = os.path.join(bindir, "clang"),
        CC       = os.path.join(bindir, "clang"),
        CXX      = os.path.join(bindir, "clang++"),
        LINK     = os.path.join(bindir, "clang++"),
        RANLIB   = os.path.join(bindir, "llvm-ranlib"),
        OBJCOPY  = os.path.join(bindir, "llvm-objcopy"),
        SIZETOOL = os.path.join(bindir, "llvm-size"),
        SIZEPRINTCMD = "$SIZETOOL $SOURCES",
        PROGSUFFIX = ".wasm",
    )

    common = [
        "--target=wasm32-wasip1",
        "--sysroot=%s" % sysroot,
        # -fwasm-exceptions is NOT optional here.  ll_try/ll_catch are plain C++ try/catch
        # (ll_platform_generic.h) and the VM raises every Scheme error as a thrown Sexpr_t, so a
        # build with the default -fno-exceptions does not "run without error handling" -- it
        # refuses to compile the first ll_catch.  The legacy JS-based -fexceptions is slower and
        # larger and needs Emscripten, which is not what this env is.
        "-fwasm-exceptions",
        # setjmp/longjmp: used by the NCG error-escape path (ll_vm_ncg_core.cpp) and by the B227
        # `guard` landing pad in ll_vm_ai_rxrs.cpp, which is compiled even with LL_NCG=0.  Wasm
        # SjLj is implemented on top of wasm EH, hence -lsetjmp at link.  WITHOUT this flag clang
        # does not warn -- it fails at the LINKER with "undefined symbol: setjmp".
        "-mllvm", "-wasm-enable-sjlj",
        # EMIT THE *STANDARDISED* EXCEPTION OPCODES (exnref), NOT THE LEGACY ONES.
        # clang still defaults to the legacy `try`/`catch` encoding, and a module built that way
        # loads fine in node/V8 and is REFUSED by wasmtime with:
        #     Error: failed to compile: wasm[0]::function[58]::Lamb::car(Cell*)
        #       1: Invalid input WebAssembly code at offset 7139:
        #          legacy_exceptions feature required for try instruction
        # -- an error that names a random C++ function and a byte offset, and says nothing about
        # the compiler flag that caused it.  Measured 2026-09-04 with wasi-sdk 34 / clang 23 and
        # wasmtime 48.0.1.  The exnref encoding runs under BOTH, so it is the one to emit.
        "-mllvm", "-wasm-use-legacy-eh=false",
    ]
    env.Append(
        ASFLAGS   = common,
        CCFLAGS   = common,
        CXXFLAGS  = ["-std=gnu++17"],
        LINKFLAGS = common + [
            "-lsetjmp",       #!< wasi-libc's wasm-EH-based setjmp/longjmp
            "-lunwind",       #!< _Unwind_* + __wasm_lpad_context, needed by -fwasm-exceptions
            "-Wl,-z,stack-size=%d" % WASM_STACK_BYTES,
            "-Wl,--stack-first",              #!< see the stack contract note above
            "-Wl,--initial-memory=%d" % WASM_INITIAL_MEM,
            "-Wl,--max-memory=%d" % WASM_MAX_MEM,
        ],
    )

elif host == "browser":
    # ---------------------------------------------------------------------------
    # FINDING EMSCRIPTEN WITHOUT `source emsdk_env.sh`.
    #
    # emsdk's normal usage is to source a script that mutates PATH and EM_CONFIG in YOUR shell.
    # That does not survive into a PlatformIO/SCons subprocess launched from `./w3`, and the
    # failure it produces is "emcc: command not found" from inside SCons -- which names neither
    # emsdk nor the missing environment.  So find the toolchain the way the wasi-sdk arm does,
    # and set EM_CONFIG explicitly: emcc looks for $EM_CONFIG, then ~/.emscripten, and `emsdk
    # activate` writes NEITHER of those -- it writes ~/emsdk/.emscripten.
    # ---------------------------------------------------------------------------
    emroot = os.environ.get("EMSDK", "") or os.path.expanduser("~/emsdk")
    embin  = os.path.join(emroot, "upstream", "emscripten")
    if os.path.isfile(os.path.join(embin, "em++")):
        env.PrependENVPath("PATH", embin)
        emnode = sorted(glob_node for glob_node in
                        __import__("glob").glob(os.path.join(emroot, "node", "*", "bin")))
        if emnode:
            env.PrependENVPath("PATH", emnode[-1])
        emcfg = os.path.join(emroot, ".emscripten")
        if os.path.isfile(emcfg) and not os.environ.get("EM_CONFIG"):
            env["ENV"]["EM_CONFIG"] = emcfg
    elif __import__("shutil").which("em++") is None:
        sys.stderr.write(
            "\n[wasm32] FATAL: em++ not found and this env needs it.\n"
            "  git clone https://github.com/emscripten-core/emsdk ~/emsdk\n"
            "  ~/emsdk/emsdk install latest && ~/emsdk/emsdk activate latest\n"
            "  (or set $EMSDK to an existing install)\n\n")
        env.Exit(1)

    #
    # PROGSUFFIX IS ".js", NOT ".wasm" OR ".html", AND THAT CHOICE IS LOAD-BEARING: em++ decides
    # what to emit from the OUTPUT EXTENSION.  ".wasm" gets you a bare module with no JS glue and
    # nothing to load it; ".html" gets you Emscripten's own shell page, which would silently
    # replace ours.  ".js" emits LambLisp.js + LambLisp.wasm, which is what w3_pio/wasm_shell/
    # index.html loads.
    staged = board.get("build.wasm_preload", "")
    env.Replace(
        AR       = "emar",
        AS       = "emcc",
        CC       = "emcc",
        CXX      = "em++",
        LINK     = "em++",
        RANLIB   = "emranlib",
        # llvm-size lives in emsdk's upstream/bin, which is NOT the directory em++ lives in and is
        # NOT added to PATH above.  PlatformIO runs `checkprogsize` after every link, so a missing
        # SIZETOOL turns a SUCCESSFUL link into a FAILED build -- artifacts on disk, exit code 1.
        SIZETOOL = (os.path.join(emroot, "upstream", "bin", "llvm-size")
                    if os.path.isfile(os.path.join(emroot, "upstream", "bin", "llvm-size"))
                    else "llvm-size"),
        SIZEPRINTCMD = "$SIZETOOL $SOURCES",
        PROGNAME = "LambLisp",
        PROGSUFFIX = ".js",
    )
    env.Append(
        CCFLAGS   = ["-fwasm-exceptions"],
        CXXFLAGS  = ["-std=gnu++17"],
        LINKFLAGS = [
            "-fwasm-exceptions",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sINITIAL_MEMORY=%d" % WASM_INITIAL_MEM,
            "-sMAXIMUM_MEMORY=%d" % WASM_MAX_MEM,
            "-sSTACK_SIZE=%d" % WASM_STACK_BYTES,
            "-sEXIT_RUNTIME=1",
            "-sFORCE_FILESYSTEM=1",
            "-sMODULARIZE=1",
            "-sEXPORT_NAME=createLambLisp",
            # ccall/cwrap are what the page uses to hand ll_wasm_eval() a JS string; FS and IDBFS
            # are P175 Phase 3, the IndexedDB-backed /persist mount.  The C entry points themselves
            # are exported by EMSCRIPTEN_KEEPALIVE in src/ll_wasm_browser.cpp, not from here.
            "-sEXPORTED_RUNTIME_METHODS=['FS','callMain','ccall','cwrap','UTF8ToString','stringToUTF8','lengthBytesUTF8']",
            # P175 Phase 3 -- the IndexedDB backing for /persist.  This ONE flag is the whole
            # requirement: it links the IDBFS library, after which the page reaches it as
            # FS.filesystems.IDBFS through the already-exported FS.
            #
            # DO NOT ALSO ADD 'IDBFS' TO EXPORTED_RUNTIME_METHODS ABOVE.  It looks like the
            # obvious companion change and it is not: with 'IDBFS' in that list the module builds
            # and LOADS cleanly, and then ll_wasm_boot() NEVER RETURNS.  There is no error, no
            # exception and no output -- wasm_browser_check.cjs simply hangs until its timeout,
            # which reads as a VM or a Scheme-library problem and sends you looking in entirely
            # the wrong place.  Measured 2026-09-05 by bisecting the two halves of this change:
            # -lidbfs.js alone passes all four cases; adding the export hangs; FS.filesystems.IDBFS
            # is a live object either way, so the export buys nothing and costs the boot.
            "-lidbfs.js",
            # INVOKE_RUN=0: main() is NEVER called in the browser.  main()'s body is
            # `while (true) loop();`, which on a single-threaded page would peg the tab and never
            # return to the event loop -- no paint, no keystroke, no way out.  JS calls
            # ll_wasm_boot() / ll_wasm_eval() / ll_wasm_tick() instead; see ll_wasm_browser.cpp.
            "-sINVOKE_RUN=0",
        ],
    )
    if staged:
        # --preload-file <hostdir>@/data : the staged runtime FS lands at /data in MEMFS, which is
        # exactly where ll_vm_file.cpp's posix_resolve() looks ("data/<name>" relative to cwd "/").
        # So (load "setup.scm") works unchanged against the same manifest every other target gets.
        env.Append(LINKFLAGS=["--preload-file", "%s@/data" % staged])
else:
    sys.stderr.write("[wasm32] unknown build.wasm_host %r (expected 'wasi' or 'browser')\n" % host)
    env.Exit(1)


#
# Target: Build the module
#

target_bin = env.BuildProgram()

if host == "browser":
    # Copy the page shell next to LambLisp.js so $BUILD_DIR is a directory you can serve as-is.
    # It is COPIED rather than left in w3_pio/ because a half-assembled demo -- the .js here, the
    # .html three directories away -- is the kind of thing that gets published missing a file.
    import shutil as _shutil
    _shell = os.path.join(env.subst("$PROJECT_DIR"), "w3_pio", "wasm_shell")

    def _install_shell(target, source, env):
        if not os.path.isdir(_shell):
            sys.stderr.write("[wasm32] WARNING: no page shell at %s -- the .js has nothing to load it\n" % _shell)
            return
        out = env.subst("$BUILD_DIR")
        for fn in os.listdir(_shell):
            if fn.startswith("."):
                continue
            _shutil.copy2(os.path.join(_shell, fn), os.path.join(out, fn))
        print("[wasm32] page shell copied to %s -- serve that directory" % out)

    env.AddPostAction(target_bin, env.VerboseAction(_install_shell, "Installing page shell"))

#
# Target: Print size
#

target_size = env.Alias(
    "size", target_bin,
    env.VerboseAction("$SIZEPRINTCMD", "Calculating size $SOURCE"),
)
AlwaysBuild(target_size)

Default([target_bin])
