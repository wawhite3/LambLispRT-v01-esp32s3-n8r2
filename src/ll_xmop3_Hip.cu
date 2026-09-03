/* Stubs for GCC aarch64 built-in vector types not recognised by nvcc's device parser.
   These macros let glibc's bits/math-vector.h compile when cross-compiling for aarch64.
   Guards prevent redefinition when g++ defines them natively as built-ins.
   The resulting typedefs (__f32x4_t, __sv_f32_t etc.) are never used by our CUDA kernels. */
#ifdef __NVCC__
#  ifndef __Float32x4_t
#    define __Float32x4_t LL_float32
#  endif
#  ifndef __Float64x2_t
#    define __Float64x2_t LL_float64
#  endif
#  ifndef __SVFloat32_t
#    define __SVFloat32_t LL_float32
#  endif
#  ifndef __SVFloat64_t
#    define __SVFloat64_t LL_float64
#  endif
#  ifndef __SVBool_t
#    define __SVBool_t    unsigned char
#  endif
#endif

#include "LambLisp.h"

#if LL_HIP
#include "hip/hip_runtime.h"
//! @defgroup xmop3_hip HIP / ROCm GPU
//! @ingroup xmop3
//! @brief LambLisp HIP / ROCm GPU builtins.
//! @{

//kernel examples are based on the book by Jamie Flux.

__global__ void cudakernel_vectorAdd(const LL_float32 *A, const LL_float32 *B, LL_float32 *C, int n)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) C[i] = A[i] + B[i];
}

__global__ void kernel1(LL_float32 *data, int n)
{
  int i = blockDim.x * blockIdx.x + threadIdx.x;
  if (i < n) data[i] *= 2.0;
}

hipError_t launch_kernel1(int nblocks, int thrPerBlk, int shared, hipStream_t stream,
			   LL_float32 *data, int n
			   )
{
  kernel1<<<nblocks, thrPerBlk, shared, stream>>>(data, n);
  return hipGetLastError();
}

__global__ void kernel2(LL_float32 *data, int n)
{
  int i = blockDim.x * blockIdx.x + threadIdx.x;
  if (i < n) data[i] += 1.0;
}

/*!
  Extract a raw buffer pointer from either a T_CPP_HEAP device/pinned pointer or a
  bytevector.  Returns the pointer; sets nbytes to the buffer size in bytes, or -1
  if the size is not known (device / pinned pointers have no Scheme-level size).
*/
static void *cuda_buf_ptr(Sexpr_t sx, LL_int32 &nbytes)
{
  if (sx->type() == Cell::T_CPP_HEAP) {
    nbytes = -1;   //!< size unknown for device/pinned pointers
    return sx->mustbe_cppobj_t()->prechecked_cppobj_get_ptr();
  }
  ByteVec_t bytes;
  sx->any_bvec_get_info(nbytes, bytes);
  return (void *) bytes;
}

void cudaDevicePtrDestroyer(Ptr_t p) { hipFree(p); }    //!< GC destructor for device memory
void cudaHostPtrDestroyer(Ptr_t p)   { hipHostFree(p); } //!< GC destructor for pinned host memory

#endif  // LL_CUDA

//! CPU-side vector add: C[i] = A[i] + B[i] for i in [0,n).
//! Args: (A B C n) -- A, B, C are realvectors; n is element count.
//! Available with or without CUDA; used in three-way correctness tests.
Sexpr_t mop3_cpp_vector_add(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cpp_vector_add()");
  ll_try {
    LL_int32 nA, nB, nC;
    ByteVec_t bA, bB, bC;
    lamb.car(sexpr)->any_bvec_get_info(nA, bA);
    lamb.cadr(sexpr)->any_bvec_get_info(nB, bB);
    lamb.caddr(sexpr)->any_bvec_get_info(nC, bC);
    LL_int32 n = lamb.cadddr(sexpr)->mustbe_int32();
    LL_int32 needed = n * (LL_int32) sizeof(LL_float32);
    if ((nA < needed) || (nB < needed) || (nC < needed))
      throw NIL->mk_error("%s buffer too small for %s elements\n", me, ascii.dec(n));
    LL_float32 *A = (LL_float32 *) bA;
    LL_float32 *B = (LL_float32 *) bB;
    LL_float32 *C = (LL_float32 *) bC;
    for (LL_int32 i = 0; i < n; i++) C[i] = A[i] + B[i];
    return OBJ_UNDEF;
  }
  ll_catch();
}

#if LL_HIP

//! Launch kernel1 (element *= 2) on a device buffer; args: (stream data [n]).
Sexpr_t mop3_cudaLaunch_kernel1(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaLaunch_kernel1()");
  ll_try {
    Sexpr_t stream = lamb.car(sexpr);   sexpr = lamb.cdr(sexpr);
    hipStream_t cudaStream;
    if ((stream->type() == Cell::T_INT32) && (stream->as_int32() == 0)) cudaStream = 0;
    else {
      hipStream_t *cs = (hipStream_t *) stream->mustbe_cppobj_t()->prechecked_cppobj_get_ptr();
      cudaStream = *cs;
    }

    LL_int32 nbytes;
    LL_float32 *elems = (LL_float32 *) cuda_buf_ptr(lamb.car(sexpr), nbytes);
    LL_int32 n = (nbytes >= 0) ? nbytes / (LL_int32) sizeof(LL_float32) : lamb.cadr(sexpr)->mustbe_int32();

    const LL_int32 threadsPerBlock = 256;
    LL_int32 nblocks = (n + threadsPerBlock - 1) / threadsPerBlock;

    hipError_t err = launch_kernel1(nblocks, threadsPerBlock, 0, cudaStream, elems, n);
    if (err != hipSuccess) throw NIL->mk_error("%s cuda error %d\n", me, err);
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! GPU vector add C[i] = A[i]+B[i]; args: (A B C n) as device/pinned pointers or bytevectors.
Sexpr_t mop3_cudakernel_vectorAdd(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudakernel_vectorAdd()");
  ll_try {
    LL_int32 nA, nB, nC;
    LL_float32 *eA = (LL_float32 *) cuda_buf_ptr(lamb.car(sexpr),    nA);
    LL_float32 *eB = (LL_float32 *) cuda_buf_ptr(lamb.cadr(sexpr),   nB);
    LL_float32 *eC = (LL_float32 *) cuda_buf_ptr(lamb.caddr(sexpr),  nC);
    LL_int32 n    = lamb.cadddr(sexpr)->mustbe_int32();

    if ((nA >= 0 && nA < n) || (nB >= 0 && nB < n) || (nC >= 0 && nC < n))
      throw NIL->mk_error("%s Index out of range %s\n", me, ascii.dec(n));

    const LL_int32 threadsPerBlock = 256;
    LL_int32 nblocks = (n + threadsPerBlock - 1) / threadsPerBlock;

    cudakernel_vectorAdd<<<nblocks, threadsPerBlock>>>(eA, eB, eC, n);
    hipError_t err = hipGetLastError();
    if (err != hipSuccess) throw NIL->mk_error("%s cuda error %d\n", me, err);
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! Allocate n bytes of device memory; returns a T_CPP_HEAP object with hipFree destructor.
Sexpr_t mop3_cudaMalloc(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaMalloc()");
  ll_try {
    LL_int32 n = lamb.car(sexpr)->mustbe_int32();
    void *devicePtr = 0;
    hipError_t err = hipMalloc(&devicePtr, n);
    if (err != hipSuccess) throw NIL->mk_error("%s error %d\n", me, err);
    CPPDeleterPtr deleter = &cudaDevicePtrDestroyer;
    return lamb.tcons(Cell::T_CPP_HEAP, (Word_t) deleter, (Word_t) devicePtr, env_exec);
  }
  ll_catch();
}

//! Allocate n bytes of page-locked host memory; returns a T_CPP_HEAP object with hipHostFree destructor.
Sexpr_t mop3_cudaMallocHost(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaMallocHost()");
  ll_try {
    LL_int32 n = lamb.car(sexpr)->mustbe_int32();
    void *hostPtr = 0;
    hipError_t err = hipHostMalloc(&hostPtr, n);
    if (err != hipSuccess) throw NIL->mk_error("%s error %d\n", me, err);
    CPPDeleterPtr deleter = &cudaHostPtrDestroyer;
    return lamb.tcons(Cell::T_CPP_HEAP, (Word_t) deleter, (Word_t) hostPtr, env_exec);
  }
  ll_catch();
}

//! Free one or more device memory objects returned by hipMalloc.
Sexpr_t mop3_cudaFree(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaFree()");
  ll_try {
    while (sexpr != NIL) {
      Sexpr_t bv      = lamb.car(sexpr);
      void *devPtr    = bv->mustbe_cppobj_t()->prechecked_cppobj_get_ptr();
      hipError_t err = hipFree(devPtr);
      if (err != hipSuccess) throw NIL->mk_error("%s error %d\n", me, err);
      sexpr = lamb.cdr(sexpr);
    }
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! Combines hipMemcpy() and hipMemcpyAsync().  If the stream argument is provided then the asynchronous copy will be used.
//! count is in bytes.  dst and src may be device pointers (hipMalloc), pinned host pointers (hipHostMalloc), or bytevectors.
Sexpr_t mop3_cudaMemcpy(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaMemcpy()");
  ll_try {
    // mk_symbol allocates; protect each symbol before creating the next.
    Sexpr_t sym_h2d = lamb.mk_symbol("hipMemcpyHostToDevice",   env_exec);
    Sexpr_t sym_d2h = NIL, sym_d2d = NIL;
    mop3_gc_protect(sym_h2d, {
        sym_d2h = lamb.mk_symbol("hipMemcpyDeviceToHost", env_exec);
    });
    mop3_gc_protect2(sym_h2d, sym_d2h, {
        sym_d2d = lamb.mk_symbol("hipMemcpyDeviceToDevice", env_exec);
    });

    LL_int32 dlen, slen;
    void *dst = cuda_buf_ptr(lamb.car(sexpr),  dlen);
    void *src = cuda_buf_ptr(lamb.cadr(sexpr), slen);
    sexpr = lamb.cddr(sexpr);

    LL_int32 count = lamb.car(sexpr)->mustbe_int32();
    if ((dlen >= 0 && dlen < count) || (slen >= 0 && slen < count))
      throw NIL->mk_error("%s Bad count %s\n", me, ascii.dec(count));
    sexpr = lamb.cdr(sexpr);

    Sexpr_t dir = lamb.car(sexpr);
    hipMemcpyKind idir;
    if      (dir == sym_h2d) idir = hipMemcpyHostToDevice;
    else if (dir == sym_d2h) idir = hipMemcpyDeviceToHost;
    else if (dir == sym_d2d) idir = hipMemcpyDeviceToDevice;
    else throw NIL->mk_error("%s unrecognized direction symbol\n", me);
    sexpr = lamb.cdr(sexpr);

    hipStream_t *cppstream = 0;
    if (sexpr != NIL) {
      Sexpr_t item = lamb.car(sexpr);
      if (item != NIL) cppstream = (hipStream_t *) item->mustbe_cppobj_t()->prechecked_cppobj_get_ptr();
    }

    hipError_t err = cppstream
      ? hipMemcpyAsync(dst, src, count, idir, *cppstream)
      : hipMemcpy(dst, src, count, idir);
    if (err != hipSuccess) throw NIL->mk_error("%s error %d\n", me, err);

    return OBJ_UNDEF;
  }
  ll_catch();
}

//! Fill count bytes of device memory with a byte value: (hipMemset ptr val count).
Sexpr_t mop3_cudaMemset(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaMemset()");
  ll_try {
    LL_int32 nbytes;
    void *devPtr = cuda_buf_ptr(lamb.car(sexpr), nbytes);
    LL_int32 val    = lamb.cadr(sexpr)->mustbe_int32();
    LL_int32 count  = lamb.caddr(sexpr)->mustbe_int32();
    hipError_t err = hipMemset(devPtr, val, count);
    if (err != hipSuccess) throw NIL->mk_error("%s error %d\n", me, err);
    return OBJ_UNDEF;
  }
  ll_catch();
}

void cudaStreamDestroyer(Ptr_t p) { hipStream_t *s = (hipStream_t *) p;  hipStreamDestroy(*s);  delete s; }

//! Create a CUDA stream; returns a T_CPP_HEAP object with hipStreamDestroy destructor.
Sexpr_t mop3_cudaStreamCreate(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaStreamCreate()");
  ll_try {
    hipStream_t *s = new hipStream_t;
    hipError_t err = hipStreamCreate(s);
    if (err != hipSuccess) { delete s;  throw NIL->mk_error("%s error %d\n", me, err); }
    CPPDeleterPtr deleter = &cudaStreamDestroyer;
    return lamb.tcons(Cell::T_CPP_HEAP, (Word_t) deleter, (Word_t) s, env_exec);
  }
  ll_catch();
}

//! Block until all operations in the given CUDA stream have completed.
Sexpr_t mop3_cudaStreamSynchronize(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaStreamSynchronize()");
  ll_try {
    hipStream_t *s = (hipStream_t *) lamb.car(sexpr)->mustbe_cppobj_t()->prechecked_cppobj_get_ptr();
    hipError_t err = hipStreamSynchronize(*s);
    if (err != hipSuccess) throw NIL->mk_error("%s error %d\n", me, err);
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! Block until all CUDA work on the current device has completed.
Sexpr_t mop3_cudaDeviceSynchronize(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaDeviceSynchronize()");
  ll_try {
    hipError_t err = hipDeviceSynchronize();
    if (err != hipSuccess) throw NIL->mk_error("%s error %d\n", me, err);
    return OBJ_UNDEF;
  }
  ll_catch();
}

//! Return the number of CUDA-capable devices available on the host.
Sexpr_t mop3_cudaGetDeviceCount(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaGetDeviceCount()");
  ll_try {
    int n = 0;
    hipError_t err = hipGetDeviceCount(&n);
    // No ROCm-capable GPU (or no amdgpu driver) -> report 0 devices, matching CUDA's
    // cudaGetDeviceCount convention, instead of throwing.  Real errors still throw.
    if (err == hipErrorNoDevice || err == hipErrorInvalidDevice) return lamb.mk_integer(0, env_exec);
    if (err != hipSuccess) throw NIL->mk_error("%s hip returned %d\n", me, err);
    return lamb.mk_integer(n, env_exec);
  }
  ll_catch();
}

//! Return an association list of device properties for the given device index (default 0).
Sexpr_t mop3_cudaGetDeviceProp(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("mop3_cudaGetDeviceProp()");
  ll_try {
    LL_int32 dev = 0;
    if (sexpr != NIL) dev = lamb.car(sexpr)->mustbe_int32();

    hipDeviceProp_t prop;
    hipError_t err = hipGetDeviceProperties(&prop, dev);
    if (err != hipSuccess) throw NIL->mk_error("%s cuda returned %d\n", me, err);

    Sexpr_t alist = NIL;

    Sexpr_t sym = NIL;
    mop3_gc_protect(alist, {
        sym = lamb.mk_symbol("name", env_exec);
    });
    Sexpr_t vec = NIL, pair = NIL;
    mop3_gc_protect2(alist, sym, {
        vec  = lamb.mk_string(sizeof(prop.name), prop.name, env_exec);
        pair = lamb.cons(sym, vec, env_exec);
        alist = lamb.cons(pair, alist, env_exec);
    });
    mop3_gc_protect(alist, {
        sym = lamb.mk_symbol("uuid", env_exec);
    });
    mop3_gc_protect2(alist, sym, {
        vec  = lamb.mk_bytevector(sizeof(prop.uuid), (Bytest_t) &prop.uuid, env_exec);
        pair = lamb.cons(sym, vec, env_exec);
        alist = lamb.cons(pair, alist, env_exec);
    });

#define mk_int_field(__name) {                                       \
      Sexpr_t _sym = NIL;                                            \
      mop3_gc_protect(alist, {                                        \
          _sym = lamb.mk_symbol(#__name, env_exec);                  \
      });                                                             \
      mop3_gc_protect2(alist, _sym, {                                 \
          Sexpr_t _ival = lamb.mk_integer(prop.__name, env_exec);    \
          Sexpr_t _pair = lamb.cons(_sym, _ival, env_exec);          \
          alist = lamb.cons(_pair, alist, env_exec);                  \
      });                                                             \
    }                                                                 \
    //

#define mk_int2_field(__name) {                                                              \
      Sexpr_t _sym = NIL;                                                                    \
      mop3_gc_protect(alist, {                                                               \
          _sym = lamb.mk_symbol(#__name, env_exec);                                          \
      });                                                                                     \
      mop3_gc_protect2(alist, _sym, {                                                        \
          Sexpr_t _vec  = lamb.mk_bytevector(2 * sizeof(int), (Bytest_t) prop.__name, env_exec); \
          Sexpr_t _pair = lamb.cons(_sym, _vec, env_exec);                                   \
          alist = lamb.cons(_pair, alist, env_exec);                                          \
      });                                                                                     \
    }                                                                                         \
    //

#define mk_int3_field(__name) {                                                              \
      Sexpr_t _sym = NIL;                                                                    \
      mop3_gc_protect(alist, {                                                               \
          _sym = lamb.mk_symbol(#__name, env_exec);                                          \
      });                                                                                     \
      mop3_gc_protect2(alist, _sym, {                                                        \
          Sexpr_t _vec  = lamb.mk_bytevector(3 * sizeof(int), (Bytest_t) prop.__name, env_exec); \
          Sexpr_t _pair = lamb.cons(_sym, _vec, env_exec);                                   \
          alist = lamb.cons(_pair, alist, env_exec);                                          \
      });                                                                                     \
    }                                                                                         \
    //

    mk_int_field(totalGlobalMem);
    mk_int_field(sharedMemPerBlock);
    mk_int_field(regsPerBlock);
    mk_int_field(warpSize);
    mk_int_field(memPitch);
    mk_int_field(maxThreadsPerBlock);
    mk_int3_field(maxThreadsDim);
    mk_int3_field(maxGridSize);

#if CUDART_VERSION < 13000
    mk_int_field(clockRate);
#endif
    mk_int_field(totalConstMem);
    mk_int_field(major);
    mk_int_field(minor);
    mk_int_field(textureAlignment);
    mk_int_field(texturePitchAlignment);
#if CUDART_VERSION < 13000
    mk_int_field(deviceOverlap);
#endif
    mk_int_field(multiProcessorCount);
#if CUDART_VERSION < 13000
    mk_int_field(kernelExecTimeoutEnabled);
#endif
    mk_int_field(integrated);
    mk_int_field(canMapHostMemory);
#if CUDART_VERSION < 13000
    mk_int_field(computeMode);
#endif
    mk_int_field(maxTexture1D);
    mk_int_field(maxTexture1DMipmap);
#if CUDART_VERSION < 13000
    mk_int_field(maxTexture1DLinear);
#endif
    mk_int2_field(maxTexture2D);
    mk_int2_field(maxTexture2DMipmap);
    mk_int3_field(maxTexture2DLinear);
    mk_int2_field(maxTexture2DGather);
    mk_int3_field(maxTexture3D);
    mk_int3_field(maxTexture3DAlt);

    mk_int_field(maxTextureCubemap);
    mk_int2_field(maxTexture1DLayered);
    mk_int3_field(maxTexture2DLayered);
    mk_int2_field(maxTextureCubemapLayered);
    mk_int_field(maxSurface1D);
    mk_int2_field(maxSurface2D);
    mk_int3_field(maxSurface3D);
    mk_int2_field(maxSurface1DLayered);
    mk_int3_field(maxSurface2DLayered);

    mk_int_field(maxSurfaceCubemap);
    mk_int2_field(maxSurfaceCubemapLayered);

    mk_int_field(surfaceAlignment);
    mk_int_field(concurrentKernels);
    mk_int_field(ECCEnabled);
    mk_int_field(pciBusID);
    mk_int_field(pciDeviceID);
    mk_int_field(pciDomainID);
    mk_int_field(tccDriver);
    mk_int_field(asyncEngineCount);
    mk_int_field(unifiedAddressing);
#if CUDART_VERSION < 13000
    mk_int_field(memoryClockRate);
#endif
    mk_int_field(memoryBusWidth);
    mk_int_field(l2CacheSize);
    mk_int_field(persistingL2CacheMaxSize);
    mk_int_field(maxThreadsPerMultiProcessor);
    mk_int_field(streamPrioritiesSupported);
    mk_int_field(globalL1CacheSupported);
    mk_int_field(localL1CacheSupported);
    mk_int_field(sharedMemPerMultiprocessor);
    mk_int_field(regsPerMultiprocessor);
    mk_int_field(managedMemory);
    mk_int_field(isMultiGpuBoard);
    mk_int_field(multiGpuBoardGroupID);
#if CUDART_VERSION < 13000
    mk_int_field(singleToDoublePrecisionPerfRatio);
#endif
    mk_int_field(pageableMemoryAccess);
    mk_int_field(concurrentManagedAccess);
    mk_int_field(computePreemptionSupported);
    mk_int_field(canUseHostPointerForRegisteredMem);
    mk_int_field(cooperativeLaunch);
#if CUDART_VERSION < 13000
    mk_int_field(cooperativeMultiDeviceLaunch);
#endif
    mk_int_field(pageableMemoryAccessUsesHostPageTables);
    mk_int_field(directManagedMemAccessFromHost);
    mk_int_field(accessPolicyMaxWindowSize);

#undef mk_int_field
#undef mk_int2_field
#undef mk_int3_field

    return alist;
  }
  ll_catch();
}

#endif

//! @brief Installer: bind the HIP/ROCm GPU builtins into `env_target` (AMD-GPU counterpart of the CUDA bindings); host builds register safe no-ops.
Sexpr_t Hip_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
#if LL_HIP
  ME("::Hip_install_mop3()");
  ll_try {

    // NOTE: the Scheme-visible names are the SAME cuda* API as the CUDA build --
    // HIP is only the C++ backend, so Cuda.scm and all GPU Scheme code work unchanged.
    // (hipify-perl had rewritten these string literals to hip*, which unbound the
    // documented cuda* API and made Cuda.scm report "CUDA not available".)
    static const struct { Lamb::Mop3st_t func;  const char *name; } std_procs[] = {
      { mop3_cudaGetDeviceCount,      "cudaGetDeviceCount"      },
      { mop3_cudaGetDeviceProp,       "cudaGetDeviceProperties" },

      { mop3_cudaMalloc,              "cudaMalloc"              },
      { mop3_cudaMallocHost,          "cudaMallocHost"          },
      { mop3_cudaFree,                "cudaFree"                },
      { mop3_cudaMemset,              "cudaMemset"              },
      { mop3_cudaMemcpy,              "cudaMemcpy"              },
      { mop3_cudaStreamCreate,        "cudaStreamCreate"        },
      { mop3_cudaStreamSynchronize,   "cudaStreamSynchronize"   },
      { mop3_cudaDeviceSynchronize,   "cudaDeviceSynchronize"   },
      { mop3_cudakernel_vectorAdd,    "cudakernel-vectorAdd"    },
      { mop3_cudaLaunch_kernel1,      "cudaLaunch-kernel1"      },

      { Hip_install_mop3,            "Hip-install-mop3"       }
    };

    const int Nstd_procs = sizeof(std_procs)/sizeof(std_procs[0]);

    lamb.log("%s defining %d Mops\n", me, Nstd_procs);
    Sexpr_t env_target = lamb.car(sexpr);
    for (int i=0; i<Nstd_procs; i++) {
      Sexpr_t proc = lamb.mk_Mop3_procst_t(std_procs[i].func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(std_procs[i].name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }

    return OBJ_UNDEF;
  }
  ll_catch();
#else
  return OBJ_UNDEF;
#endif
}
//! @}
