// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
/* nvcc_aarch64_compat.h -- stubs for GCC aarch64 built-in types unknown to nvcc.
   Pre-included via -include when cross-compiling CUDA for aarch64 with nvcc.
   math-vector.h (glibc) declares these unconditionally when __GNUC__ >= 10. */

#ifndef NVCC_AARCH64_COMPAT_H
#define NVCC_AARCH64_COMPAT_H

typedef float  __Float32x4_t __attribute__((__vector_size__(16)));
typedef double __Float64x2_t __attribute__((__vector_size__(16)));

typedef float  __SVFloat32_t;
typedef double __SVFloat64_t;
typedef unsigned char __SVBool_t;

#endif /* NVCC_AARCH64_COMPAT_H */
