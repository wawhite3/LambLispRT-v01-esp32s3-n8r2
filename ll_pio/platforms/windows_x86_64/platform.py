# P174: Windows x86_64 PlatformIO platform, cross-built from Linux with MinGW-w64.
#
# NO MANAGED TOOLCHAIN PACKAGE, for the same reason the wasm32 platform has none: PlatformIO has
# no registry package for MinGW-w64, and vendoring a cross-toolchain into this repo is not on.
# The toolchain is found on the machine and check_toolchain() says exactly what to install --
# because the alternative failure ("x86_64-w64-mingw32-g++: command not found" from deep inside
# SCons) names neither the package nor the platform that wanted it.
#
# Copyright 2026 by Frobenius Norm LLC 2026-09-05 00:00:00

import shutil
import sys

from platformio.public import PlatformBase


class Windows_x86_64Platform(PlatformBase):

    CROSS_PREFIX = "x86_64-w64-mingw32-"

    #! NOT native even when the host is x86_64.  is_native() means "the host can RUN what this
    #! platform builds", and a Linux box cannot run a PE binary; saying otherwise makes PlatformIO
    #! offer to execute the .exe directly.  Running it here goes through wine -- see
    #! `w3 make windows_run`.
    def is_native(self):
        return False

    def is_embedded(self):
        return False

    def configure_default_packages(self, variables, targets):
        # No managed packages: the cross-toolchain is found on the host (apt: mingw-w64).
        return super().configure_default_packages(variables, targets)

    def check_toolchain(self):
        """Warn at configuration time if the cross-toolchain is absent, and say how to get it."""
        cxx = self.CROSS_PREFIX + "g++"
        if shutil.which(cxx) is None:
            sys.stderr.write(
                "\n[windows_x86_64] MinGW-w64 NOT FOUND ('%s' is not on PATH).\n"
                "  Install it with:  sudo apt install mingw-w64\n"
                "  To RUN the result on this machine as well:  sudo apt install wine64\n\n"
                % cxx
            )
