# Linux aarch64 PlatformIO platform.
# Builds natively on aarch64 Linux hosts.
# Cross-compiles from x86_64 Linux or macOS hosts using the
# aarch64-linux-gnu-* toolchain (apt: gcc-aarch64-linux-gnu).
#
# Copyright 2026 by FrobeniusNorm LLC 2026-04-08 00:00:00

import subprocess
import sys

from platformio.public import PlatformBase


def _host_is_aarch64():
    """Return True when the build host is already aarch64."""
    try:
        out = subprocess.check_output(["uname", "-m"], text=True).strip()
        return out == "aarch64"
    except Exception:
        return False


class Linux_aarch64Platform(PlatformBase):

    CROSS_PREFIX = "aarch64-linux-gnu-"

    def is_native(self):
        return _host_is_aarch64()

    def configure_default_packages(self, variables, targets):
        # No managed toolchain packages: rely on the system cross-compiler.
        # Users must install it themselves (apt install gcc-aarch64-linux-gnu).
        return super().configure_default_packages(variables, targets)

    def check_toolchain(self):
        """Warn at configuration time if the cross-toolchain is absent."""
        if self.is_native():
            return
        import shutil
        cc = self.CROSS_PREFIX + "gcc"
        if shutil.which(cc) is None:
            sys.stderr.write(
                "\n[linux_aarch64] WARNING: cross-compiler '%s' not found.\n"
                "  Install it with:  sudo apt install gcc-aarch64-linux-gnu\n\n"
                % cc
            )
