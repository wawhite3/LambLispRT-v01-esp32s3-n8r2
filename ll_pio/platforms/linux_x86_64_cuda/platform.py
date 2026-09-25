# Linux x86_64 with CUDA platform for PlatformIO.
# Builds natively on x86_64 Linux using gcc/g++ for .cpp and nvcc for .cu files.
# Requires: nvcc in PATH and libcudart installed.
#   sudo apt install nvidia-cuda-toolkit  (or libcudart-dev)
#
# Copyright 2026 by FrobeniusNorm LLC 2026-04-15 00:00:00

from platformio.public import PlatformBase


class Linux_x86_64_cudaPlatform(PlatformBase):

    def configure_default_packages(self, variables, targets):
        # Use system compiler -- no managed toolchain packages.
        return super().configure_default_packages(variables, targets)
