#|! @file Cuda-bench.scm
  Benchmark: float32 array add on LambLisp CPU vs CUDA GPU.

  Copyright 2026 by Frobenius Norm LLC 2026-04-15 18:00:07
;;; Free for non-commercial use. Commercial use requires a license.

  Runs the same element-wise A[i]+B[i]=C[i] computation three ways:
    1. Pure LambLisp Scheme loop (on-board)
    2. CUDA GPU -- full round-trip: H2D + kernel + D2H (off-board total)
    3. CUDA GPU -- kernel only, no memcpy (off-board compute only)

  Reports timing for each, speedup ratios, and verifies that on-board
  and off-board results agree exactly (float32 add is deterministic).

  Run: (load "Cuda-bench.scm" 1)
|#

(define sizeof-Real_t 4)   ; float32 on all platforms

;;;; ---- helpers -------------------------------------------------------

(define (bench-report label us)
  (syslog "  ~a~a us\n" label us))

;;;; ---- run one size --------------------------------------------------

(define (cuda-bench n)
  (let* ((nbytes  (* n sizeof-Real_t))
         (A       (make-float32-vector n 1.5))
         (B       (make-float32-vector n 2.5))
         (C-cpu   (make-float32-vector n 0.0))
         (C-gpu   (make-float32-vector n 0.0)))

    (syslog "\n=== n = ~a  (~a KB) ===\n" n (/ (* n sizeof-Real_t) 1024))

    ;; --- 1. On-board: LambLisp Scheme loop ---
    (let* ((t0 (micros)))
      (let loop ((i 0))
        (when (<i i n)
          (array-set! C-cpu i (+ (array-ref A i) (array-ref B i)))
          (loop (+i i 1))))
      (bench-report "LambLisp CPU:          " (- (micros) t0)))

    ;; --- 2. Off-board: CUDA full round-trip ---
    (let* ((dA (cudaMalloc nbytes))
           (dB (cudaMalloc nbytes))
           (dC (cudaMalloc nbytes)))

      ;; full round-trip timing
      (let* ((t0 (micros)))
        (cudaMemcpy dA (array-data A) nbytes 'cudaMemcpyHostToDevice)
        (cudaMemcpy dB (array-data B) nbytes 'cudaMemcpyHostToDevice)
        (cudakernel-vectorAdd dA dB dC n)
        (cudaDeviceSynchronize)
        (cudaMemcpy (array-data C-gpu) dC nbytes 'cudaMemcpyDeviceToHost)
        (bench-report "CUDA H2D+kernel+D2H:   " (- (micros) t0)))

      ;; kernel-only timing (data already on device)
      (cudaMemcpy dA (array-data A) nbytes 'cudaMemcpyHostToDevice)
      (cudaMemcpy dB (array-data B) nbytes 'cudaMemcpyHostToDevice)
      (cudaDeviceSynchronize)
      (let* ((t0 (micros)))
        (cudakernel-vectorAdd dA dB dC n)
        (cudaDeviceSynchronize)
        (bench-report "CUDA kernel only:      " (- (micros) t0)))

      (cudaFree dA) (cudaFree dB) (cudaFree dC))

    ;; --- verify on-board vs off-board results agree ---
    (let loop ((i 0) (errors 0))
      (if (>=i i n)
          (syslog "  Verification errors:  ~a\n" errors)
          (loop (+i i 1)
                (if (= (array-ref C-cpu i) (array-ref C-gpu i))
                    errors
                    (+i errors 1)))))))

;;;; ---- sweep sizes ---------------------------------------------------

(syslog "Cuda-bench: float32 array add on LambLisp CPU vs CUDA GPU\n")

(cuda-bench 1024)
(cuda-bench 4096)
(cuda-bench 16384)
(cuda-bench 65536)
(cuda-bench 262144)

(syslog "\nDone.\n")

