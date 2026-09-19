# P174: SCons builder for the windows_x86_64 platform (MinGW-w64 cross-build from Linux).
#
# Copyright 2026 by Frobenius Norm LLC 2026-09-05 00:00:00

import shutil
import sys

from SCons.Script import AlwaysBuild, Default, DefaultEnvironment

env = DefaultEnvironment()

CROSS_PREFIX = "x86_64-w64-mingw32-"

if shutil.which(CROSS_PREFIX + "g++") is None:
    sys.stderr.write(
        "\n[windows_x86_64] FATAL: MinGW-w64 not found and this env needs it.\n"
        "  sudo apt install mingw-w64\n"
        "  (and 'sudo apt install wine64' to run the result here)\n\n")
    env.Exit(1)

# ---------------------------------------------------------------------------
# WHY -posix AND NOT THE DEFAULT -win32 THREAD MODEL.
#
# Debian/Ubuntu ship MinGW-w64 in two flavours selected by update-alternatives: the win32 model
# has NO <mutex>, <thread> or <condition_variable> in libstdc++, and several headers this codebase
# includes transitively pull those in.  The failure is a wall of "'mutex' is not a member of
# 'std'" from inside libstdc++, which reads as a broken standard library rather than as a
# toolchain-flavour choice.  Name the -posix binaries explicitly so the build does not depend on
# whatever update-alternatives happens to point at on this machine.
# ---------------------------------------------------------------------------
_posix = CROSS_PREFIX + "g++-posix"
_HAVE_POSIX_FLAVOUR = shutil.which(_posix) is not None
_CXX = _posix if _HAVE_POSIX_FLAVOUR else CROSS_PREFIX + "g++"
_CC = (CROSS_PREFIX + "gcc-posix") if _HAVE_POSIX_FLAVOUR else (CROSS_PREFIX + "gcc")

env.Replace(
    _BINPREFIX   = CROSS_PREFIX,
    AR           = "${_BINPREFIX}ar",
    AS           = "${_BINPREFIX}as",
    CC           = _CC,
    CXX          = _CXX,
    LINK         = _CXX,
    GDB          = "${_BINPREFIX}gdb",
    OBJCOPY      = "${_BINPREFIX}objcopy",
    RANLIB       = "${_BINPREFIX}ranlib",
    SIZETOOL     = "${_BINPREFIX}size",
    SIZEPRINTCMD = "$SIZETOOL $SOURCES",
    #! P174 names the deliverable "a native Windows LambLisp.exe", and a customer double-clicks
    #! whatever the file is called -- so do not ship PlatformIO's default `program.exe`.  The
    #! wasm32 browser builder sets PROGNAME for the same reason.
    PROGNAME     = "LambLisp",
    PROGSUFFIX   = ".exe",
)

env.Append(
    CXXFLAGS  = ["-std=gnu++17"],
    LINKFLAGS = [
        # STATIC, AND THAT IS THE WHOLE POINT OF THE PHASE.  P174 exists so a prospect can try the
        # language from ONE download -- no Docker Desktop licence, no WSL2, no install.  A
        # dynamically linked MinGW build needs libstdc++-6.dll, libgcc_s_seh-1.dll and
        # libwinpthread-1.dll beside it, and the failure when they are missing is a Windows dialog
        # naming a DLL, which is precisely the "go and install something first" experience this
        # target is meant to remove.
        "-static",
        "-static-libgcc",
        "-static-libstdc++",
        # 8 MB stack, matching what LL_EVAL_STACK_BUDGET assumes for a host build.  Windows takes
        # its stack size from the PE HEADER, not from a runtime rlimit, and the default is 1 MB --
        # so without this the interpreter's recursion guard (sized for 8 MB) is useless: the
        # process dies on a real stack overflow long before the guard raises its catchable error.
        "-Wl,--stack,8388608",
    ],
)

#
# Target: Build executable program
#

target_bin = env.BuildProgram()

#
# Target: Print binary size
#

target_size = env.Alias(
    "size", target_bin,
    env.VerboseAction("$SIZEPRINTCMD", "Calculating size $SOURCE"),
)
AlwaysBuild(target_size)

Default([target_bin])
