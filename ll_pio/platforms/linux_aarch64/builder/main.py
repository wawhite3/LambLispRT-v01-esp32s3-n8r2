# Builder for Linux aarch64.
# On an aarch64 host: uses the system compiler (no prefix).
# On any other host:  uses the aarch64-linux-gnu-* cross-toolchain.
#
# Required on x86_64 Debian/Ubuntu hosts:
#   sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu
#
# Copyright 2026 by FrobeniusNorm LLC 2026-04-08 00:00:00

import subprocess

from SCons.Script import AlwaysBuild, Default, DefaultEnvironment


def _host_is_aarch64():
    try:
        return subprocess.check_output(["uname", "-m"], text=True).strip() == "aarch64"
    except Exception:
        return False


CROSS_PREFIX = "" if _host_is_aarch64() else "aarch64-linux-gnu-"

env = DefaultEnvironment()

env.Replace(
    _BINPREFIX  = CROSS_PREFIX,
    AR          = "${_BINPREFIX}ar",
    AS          = "${_BINPREFIX}as",
    CC          = "${_BINPREFIX}gcc",
    CXX         = "${_BINPREFIX}g++",
    GDB         = "${_BINPREFIX}gdb",
    OBJCOPY     = "${_BINPREFIX}objcopy",
    RANLIB      = "${_BINPREFIX}ranlib",
    SIZETOOL    = "${_BINPREFIX}size",
    SIZEPRINTCMD = "$SIZETOOL $SOURCES",
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

#
# Default targets
#

Default([target_bin])
