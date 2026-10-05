# P175: WebAssembly PlatformIO platform (wasm32-wasip1 and wasm32-emscripten).
#
# NO MANAGED TOOLCHAIN PACKAGE.  PlatformIO has no registry package for wasi-sdk or emsdk, and
# vendoring a 100 MB SDK into this repo is not on.  The toolchain is found on the machine, and
# check_toolchain() below says exactly what to install when it is not there -- because the
# alternative failure ("clang: command not found" from deep inside SCons) tells you nothing.
#
# Copyright 2026 by Frobenius Norm LLC 2026-09-04 00:00:00

import os
import sys
import glob
import shutil

from platformio.public import PlatformBase


#: Search order for the wasi-sdk root.  $WASI_SDK_PATH wins so a machine can pin a version.
WASI_SDK_CANDIDATES = [
    os.environ.get("WASI_SDK_PATH", ""),
    "/opt/wasi-sdk",
    "/usr/lib/wasi-sdk",
]


def find_wasi_sdk():
    """Return the wasi-sdk root, or "" if none is installed."""
    cands = [c for c in WASI_SDK_CANDIDATES if c]
    #! Newest-first, so a machine with several unpacked SDKs uses the latest.  sort() on the
    #! directory name is a STRING sort: wasi-sdk-9 would beat wasi-sdk-34.  That is deliberate --
    #! there is no wasi-sdk-9 tarball for linux and inventing a version parser to handle a release
    #! that does not exist is the wrong trade.  Set $WASI_SDK_PATH if the choice ever matters.
    cands += sorted(glob.glob(os.path.expanduser("~/wasi-sdk-*")), reverse=True)
    cands += sorted(glob.glob("/opt/wasi-sdk-*"), reverse=True)
    for c in cands:
        if os.path.isfile(os.path.join(c, "bin", "clang++")):
            return c
    return ""


class Wasm32Platform(PlatformBase):

    def is_embedded(self):
        return False

    def configure_default_packages(self, variables, targets):
        # No managed packages: the SDK is found on the host (see find_wasi_sdk / emcc on PATH).
        return super().configure_default_packages(variables, targets)

    def check_toolchain(self):
        """Warn at configuration time if the toolchain is absent, and say how to get it."""
        if not find_wasi_sdk():
            sys.stderr.write(
                "\n[wasm32] wasi-sdk NOT FOUND.  Install it with:\n"
                "  curl -L -o /tmp/wasi-sdk.tar.gz \\\n"
                "    https://github.com/WebAssembly/wasi-sdk/releases/download/"
                "wasi-sdk-34/wasi-sdk-34.0-x86_64-linux.tar.gz\n"
                "  tar xzf /tmp/wasi-sdk.tar.gz -C $HOME\n"
                "  (or set WASI_SDK_PATH to an existing install)\n\n"
            )
        if shutil.which("emcc") is None:
            sys.stderr.write(
                "\n[wasm32] emcc NOT FOUND (only needed for the wasm32_browser env).  Install:\n"
                "  git clone https://github.com/emscripten-core/emsdk ~/emsdk\n"
                "  ~/emsdk/emsdk install latest && ~/emsdk/emsdk activate latest\n"
                "  source ~/emsdk/emsdk_env.sh\n\n"
            )
