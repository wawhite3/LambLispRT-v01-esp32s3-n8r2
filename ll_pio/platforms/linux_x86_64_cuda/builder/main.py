# Builder for Linux x86_64 with CUDA.
# Uses gcc/g++ for all .c/.cpp files (via env.BuildProgram()).
# Uses nvcc for .cu files: compiles each to a .o and adds to the link.
#
# Copyright 2026 by FrobeniusNorm LLC 2026-04-15 00:00:00

import glob
import os
import subprocess

from SCons.Script import AlwaysBuild, Default, DefaultEnvironment

env = DefaultEnvironment()

env.Replace(
    _BINPREFIX  = "",
    AR          = "ar",
    AS          = "as",
    CC          = "gcc",
    CXX         = "g++",
    GDB         = "gdb",
    OBJCOPY     = "objcopy",
    RANLIB      = "ranlib",
    SIZETOOL    = "size",
    SIZEPRINTCMD = "$SIZETOOL $SOURCES",
)

# ---------------------------------------------------------------------------
# CUDA: compile every src/*.cu with nvcc, add resulting .o to the link.
# ---------------------------------------------------------------------------

NVCC         = os.environ.get("NVCC", "nvcc")
build_dir    = env.subst("$BUILD_DIR")
src_dir      = env.subst("$PROJECT_SRC_DIR")
cu_files     = glob.glob(os.path.join(src_dir, "*.cu"))

def _nvcc_action(target, source, env):
    """Compile a single .cu file to a .o with nvcc."""
    src_path = str(source[0])
    tgt_path = str(target[0])

    # Collect -I paths from the SCons env.
    includes = ["-I" + p for p in env.get("CPPPATH", [])]

    # Collect -D defines.  PlatformIO stores them as strings or (name, val) tuples.
    defines = []
    for d in env.get("CPPDEFINES", []):
        if isinstance(d, (list, tuple)):
            defines.append("-D{}={}".format(d[0], d[1]))
        else:
            defines.append("-D" + str(d))

    # Use nvcc with --compiler-options to forward flags to the host compiler.
    # -x cu  forces CUDA compilation even though the file already ends in .cu.
    cmd = (
        [NVCC, "-x", "cu", "-c", "-O3", "--std=c++17",
         "--compiler-options", "-fPIC"]
        + includes
        + defines
        + ["-o", tgt_path, src_path]
    )
    print(" ".join(cmd))
    return subprocess.call(cmd)

cu_objects = []
for cu in cu_files:
    basename = os.path.splitext(os.path.basename(cu))[0]
    obj      = os.path.join(build_dir, "src", basename + ".o")
    cu_obj   = env.Command(obj, cu, _nvcc_action)
    cu_objects.append(cu_obj)
    # Add compiled .o to the final link command.
    env.Append(LINKFLAGS=[obj])

# ---------------------------------------------------------------------------
# Standard program build (handles all .cpp / .c sources).
# ---------------------------------------------------------------------------

target_bin = env.BuildProgram()

if cu_objects:
    env.Depends(target_bin, cu_objects)

# ---------------------------------------------------------------------------
# Size target
# ---------------------------------------------------------------------------

target_size = env.Alias(
    "size", target_bin,
    env.VerboseAction("$SIZEPRINTCMD", "Calculating size $SOURCE"),
)
AlwaysBuild(target_size)

Default([target_bin])
