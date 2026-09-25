;;; array.scm -- Unified typed numeric array library (P139)
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-09 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; An array is a pair (shape-bvec . data-bvec).  A *vector* is the rank-1 case.
;;; This surface unifies the four older systems (tvec, intvector, realvector,
;;; ndarray) onto one representation -- see P139.
;;;
;;; C++ mop3 primitives (ll_vm_mop3_extra.cpp):
;;;   make-{int32,int64,float32,float64}-vector   (1-D)
;;;   make-{int,real}-vector                       (native int / float32, 1-D)
;;;   make-{int32,int64,float32,float64}-array     (N-D)
;;;   make-{int,real}-array                        (native int / float32, N-D)
;;;   array-ref  array-set!  array-type  array-rank  array-dim
;;;   array-fill!  array-sum  array-randomize01!  array-randomize11!  array-dot
;;;
;;; NOTE (B93): keep every top-level form SHALLOW.  The reader recurses once per paren
;;; nesting level, so a single deeply-nested form can overflow the ESP32 loopTask stack
;;; while it is being READ.  The dispatch/index helpers below are factored flat so no
;;; form nests more than ~6 deep -- do not re-inline them into transpose/slice.
;;;
;;; PERFORMANCE NOTE: the layout is row-major (C order), so the LAST index varies fastest in
;;; memory.  Hot loops should iterate the last index INNERMOST for cache locality (e.g. the
;;; C++ array-matmul! CPU path uses i-k-j ordering so its inner loop streams contiguous rows).

;;; Element-type tags -- DERIVED from the runtime, never hardcoded.  The tag is the
;;; Cell::Type enum value returned by array-type; hardcoding it silently mis-dispatches
;;; when the enum drifts (B94).  Deriving from a throwaway array makes it self-correcting.
(define array-type-int32   (array-type (make-int32-vector   1)))
(define array-type-int64   (array-type (make-int64-vector   1)))
(define array-type-float32 (array-type (make-float32-vector 1)))
(define array-type-float64 (array-type (make-float64-vector 1)))

(define (array-valid-type? tag)
  (or (= tag array-type-int32)
      (= tag array-type-int64)
      (= tag array-type-float32)
      (= tag array-type-float64)))

;;; Structural predicate
(define (array? a)
  (and (pair? a)
       (bytevector? (car a))
       (bytevector? (cdr a))
       (array-valid-type? (array-type a))))

(define (array-shape-bvec a) (car a))  ;;;!< raw shape bytevector (elem-type tag + dims); internal
(define (array-data       a) (cdr a))  ;;;!< raw data bytevector

;;; array-size -- product of all dimensions (exact integer, may exceed INT32)
(define (array-size a)
  (let loop ((k 0) (acc 1))
    (if (= k (array-rank a))
        acc
        (loop (+ k 1) (* acc (array-dim a k))))))

;;; array-shape -- dimensions as a Scheme list
(define (array-shape a)
  (let ((r (array-rank a)))
    (let loop ((k 0) (acc (list)))
      (if (= k r) (reverse acc)
          (loop (+ k 1) (cons (array-dim a k) acc))))))

;;; array-length -- length of a rank-1 array
(define (array-length a) (array-dim a 0))

;;; --- element-type dispatch + index helpers (flat, so transpose/slice stay shallow -- B93) ---

;; Allocate a fresh array of element type `tag` with `dims` (an integer or a list).
(define (array-alloc tag dims)
  (cond ((= tag array-type-int32)   (make-int32-array   dims))
        ((= tag array-type-int64)   (make-int64-array   dims))
        ((= tag array-type-float32) (make-float32-array dims))
        ((= tag array-type-float64) (make-float64-array dims))
        (else (error "array: unknown element type" tag))))

;; Read the element of `a` at multi-dim index list `idx`.
(define (array-ref-list a idx) (apply array-ref (cons a idx)))

;; Write `val` into `a` at multi-dim index list `idx`.
(define (array-set-list! a idx val) (apply array-set! (cons a (append idx (list val)))))

;; Decode a linear offset into a multi-dim index list, mixed-radix over `ndim` axes.
;; `dim-extent` returns the extent of axis k (lets slice override the sliced axis).
(define (array-linear->index lin ndim dim-extent)
  (let decode ((lin lin) (k (- ndim 1)) (acc (list)))
    (if (< k 0)
        acc
        (let ((d (dim-extent k)))
          (decode (quotient lin d) (- k 1) (cons (remainder lin d) acc))))))

;;; array-copy -- fresh contiguous copy with identical shape and data
(define (array-copy a)
  (cons (bytevector-copy (array-shape-bvec a))
        (bytevector-copy (array-data       a))))

;;; array-reshape -- new shape over the same data (always copies data)
;;; new-dims may be an integer (1-D) or a list of integers.
(define (array-reshape a new-dims)
  (let* ((old-size (array-size a))
         (new-a    (if (integer? new-dims)
                       (array-alloc (array-type a) (list new-dims))   ; keep source element type
                       (array-alloc (array-type a) new-dims)))
         (new-size (array-size new-a)))
    (if (not (= old-size new-size))
        (error "array-reshape: size mismatch" old-size new-size)
        (cons (array-shape-bvec new-a)
              (bytevector-copy (array-data a))))))

;;; array-transpose -- contiguous copy with reversed shape (for 2-D, the matrix transpose)
(define (array-transpose a)
  (let* ((ndim    (array-rank a))
         (dims    (let loop ((k 0) (acc (list)))
                    (if (= k ndim) (reverse acc)
                        (loop (+ k 1) (cons (array-dim a k) acc)))))
         (new-a   (array-alloc (array-type a) (reverse dims)))
         (size    (array-size a))
         (extent  (lambda (k) (array-dim a k))))
    (let copy-loop ((src-linear 0))
      (if (= src-linear size)
          new-a
          (let ((src-idx (array-linear->index src-linear ndim extent)))
            (array-set-list! new-a (reverse src-idx) (array-ref-list a src-idx))
            (copy-loop (+ src-linear 1)))))))

;;; array-slice -- contiguous copy of sub-array along dimension dim, indices [start, end)
(define (array-slice a dim start end)
  (let* ((ndim     (array-rank a))
         (extent   (- end start))
         (axis     (lambda (k) (if (= k dim) extent (array-dim a k))))
         (new-dims (let loop ((k 0) (acc (list)))
                     (if (= k ndim) (reverse acc)
                         (loop (+ k 1) (cons (axis k) acc)))))
         (new-a    (array-alloc (array-type a) new-dims))
         (new-size (array-size new-a)))
    (let copy-loop ((dst-linear 0))
      (if (= dst-linear new-size)
          new-a
          (let* ((dst-idx (array-linear->index dst-linear ndim axis))
                 (src-idx (array-slice-src-index dst-idx dim start)))
            (array-set-list! new-a dst-idx (array-ref-list a src-idx))
            (copy-loop (+ dst-linear 1)))))))

;; Map a slice destination index back to the source index (offset the sliced axis by `start`).
(define (array-slice-src-index dst-idx dim start)
  (let loop ((k 0) (di dst-idx) (acc (list)))
    (if (null? di)
        (reverse acc)
        (loop (+ k 1) (cdr di)
              (cons (if (= k dim) (+ (car di) start) (car di)) acc)))))
