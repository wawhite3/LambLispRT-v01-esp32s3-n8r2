;;; Copyright 2026 by Frobenius Norm LLC 2026-08-09 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;; =======================================================================
;;; Tests for the P139 unified typed numeric array surface (array-*).
;;; Each test prints PASS or FAIL with the expected and actual values.
;;; =======================================================================

(define pass-count 0)
(define fail-count 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass-count (+ pass-count 1)) (printf "PASS ~a\n" name))
      (begin (set! fail-count (+ fail-count 1)) (printf "FAIL ~a expected=~a got=~a\n" name expected actual))))

(define (check-error name thunk01)
  (guard (e (#t (set! pass-count (+ pass-count 1)) (printf "PASS ~a (raised)\n" name)))
    (thunk01)
    (set! fail-count (+ fail-count 1))
    (printf "FAIL ~a (no error raised)\n" name)))

;;; -----------------------------------------------------------------------
;;; 1-D vectors: make-<T>-vector  (strictly rank-1)
;;; -----------------------------------------------------------------------
(printf "--- make-<T>-vector (1-D) ---\n")

(define iv (make-int32-vector 4))
(check "int32 vector rank"   1 (array-rank iv))
(check "int32 vector length" 4 (array-length iv))
(check "int32 vector size"   4 (array-size iv))
(check "int32 vector type"   array-type-int32 (array-type iv))
(check "int32? array"        #t (array? iv))

(define fv (make-float32-vector 3 1.5))
(check "float32 fill ref0" 1.5 (array-ref fv 0))
(check "float32 fill ref2" 1.5 (array-ref fv 2))
(check "float32 fill sum"  4.5 (array-sum fv))
(array-set! fv 1 9.0)
(check "float32 set/ref"   9.0 (array-ref fv 1))

(check-error "make-int32-vector rejects a shape list"
  (lambda () (make-int32-vector (list 2 3))))

;;; -----------------------------------------------------------------------
;;; N-D arrays: make-<T>-array  (list-shape and spread forms)
;;; -----------------------------------------------------------------------
(printf "--- make-<T>-array (N-D) ---\n")

(define m (make-float32-array (list 2 3)))
(check "array rank"  2 (array-rank m))
(check "array dim0"  2 (array-dim m 0))
(check "array dim1"  3 (array-dim m 1))
(check "array size"  6 (array-size m))
(check "array shape" '(2 3) (array-shape m))

(define ms (make-int32-array 2 3))     ;; spread-dims form
(check "spread-dims shape" '(2 3) (array-shape ms))

;; fill m[i][j] = i*10 + j
(let iloop ((i 0))
  (when (< i 2)
    (let jloop ((j 0))
      (when (< j 3)
        (array-set! m i j (+ (* i 10) j))
        (jloop (+ j 1))))
    (iloop (+ i 1))))
(check "array-ref 2-D (1,2)" 12.0 (array-ref m 1 2))
(check "array-sum 2-D" 36.0 (array-sum m))   ;; 0+1+2+10+11+12 = 36

;;; -----------------------------------------------------------------------
;;; reshape / transpose / slice / copy
;;; -----------------------------------------------------------------------
(printf "--- reshape / transpose / slice / copy ---\n")

(define t (array-transpose m))            ;; 3x2
(check "transpose shape" '(3 2) (array-shape t))
(check "transpose (2,1)=m(1,2)" 12.0 (array-ref t 2 1))
(check "transpose (0,1)=m(1,0)" 10.0 (array-ref t 0 1))

(define r (array-reshape m (list 3 2)))   ;; row-major data preserved
(check "reshape shape" '(3 2) (array-shape r))
(check "reshape (0,0)" 0.0  (array-ref r 0 0))
(check "reshape (2,1)" 12.0 (array-ref r 2 1))   ;; last element

(check-error "reshape size mismatch raises"
  (lambda () (array-reshape m (list 2 2))))

(define sl (array-slice m 0 1 2))         ;; rows [1,2) -> shape (1 3)
(check "slice shape" '(1 3) (array-shape sl))
(check "slice (0,2)" 12.0 (array-ref sl 0 2))

(define c (array-copy m))
(check "copy shape" '(2 3) (array-shape c))
(check "copy (1,1)" 11.0 (array-ref c 1 1))
(array-set! c 1 1 99.0)
(check "copy is independent" 11.0 (array-ref m 1 1))

;;; -----------------------------------------------------------------------
;;; native-int and real aliases
;;; -----------------------------------------------------------------------
(printf "--- make-int-vector / make-real-vector ---\n")

(define nv (make-int-vector 3 7))
(check "int-vector is int64 (64-bit host)" array-type-int64 (array-type nv))
(check "int-vector sum" 21 (array-sum nv))

(define rv (make-real-vector 3 2.0))
(check "real-vector is float32" array-type-float32 (array-type rv))
(check "real-vector sum" 6.0 (array-sum rv))

;; native-int N-D
(define na (make-int-array 2 2))
(check "int-array rank" 2 (array-rank na))

;;; -----------------------------------------------------------------------
;;; array-dot
;;; -----------------------------------------------------------------------
(printf "--- array-dot ---\n")

(define a (make-float32-vector 3))
(define b (make-float32-vector 3))
(array-set! a 0 1.0) (array-set! a 1 2.0) (array-set! a 2 3.0)
(array-set! b 0 4.0) (array-set! b 1 5.0) (array-set! b 2 6.0)
(check "array-dot float32" 32.0 (array-dot a b))   ;; 4+10+18

(define ia (make-int32-vector 3 2))
(define ib (make-int32-vector 3 3))
(check "array-dot int32" 18 (array-dot ia ib))     ;; 2*3 * 3

;;; -----------------------------------------------------------------------
;;; N-D array math: matmul! / scale! / add! / mul! / copy! / contiguous?
;;; -----------------------------------------------------------------------
(printf "--- array math (matmul!/scale!/add!/mul!/copy!) ---\n")

;; helper: set a 2-D array row-major from a flat list
(define (fill2! arr rows cols vals)
  (let loop ((i 0) (vs vals))
    (when (< i rows)
      (let jloop ((j 0) (vs vs))
        (if (< j cols)
            (begin (array-set! arr i j (car vs)) (jloop (+ j 1) (cdr vs)))
            (loop (+ i 1) vs))))))

;; A = [[1 2 3][4 5 6]] (2x3), B = [[7 8][9 10][11 12]] (3x2)
;; A*B = [[58 64][139 154]]
(define Af (make-float32-array (list 2 3)))
(define Bf (make-float32-array (list 3 2)))
(define Cf (make-float32-array (list 2 2)))
(fill2! Af 2 3 '(1.0 2.0 3.0 4.0 5.0 6.0))
(fill2! Bf 3 2 '(7.0 8.0 9.0 10.0 11.0 12.0))
(array-matmul! Cf Af Bf)
(check "matmul float32 (0,0)" 58.0  (array-ref Cf 0 0))
(check "matmul float32 (0,1)" 64.0  (array-ref Cf 0 1))
(check "matmul float32 (1,0)" 139.0 (array-ref Cf 1 0))
(check "matmul float32 (1,1)" 154.0 (array-ref Cf 1 1))

(define Ai (make-int32-array (list 2 3)))
(define Bi (make-int32-array (list 3 2)))
(define Ci (make-int32-array (list 2 2)))
(fill2! Ai 2 3 '(1 2 3 4 5 6))
(fill2! Bi 3 2 '(7 8 9 10 11 12))
(array-matmul! Ci Ai Bi)
(check "matmul int32 (0,0)" 58  (array-ref Ci 0 0))
(check "matmul int32 (1,1)" 154 (array-ref Ci 1 1))

(check-error "matmul inner-dim mismatch raises"
  (lambda () (array-matmul! (make-float32-array (list 2 2)) Af Af)))

;; scale!
(define sc (make-float32-vector 3 2.0))
(array-scale! sc 2.5)
(check "scale! result" 5.0 (array-ref sc 0))
(check "scale! sum" 15.0 (array-sum sc))

;; add!
(define pa (make-float32-vector 3 1.0))
(define pb (make-float32-vector 3 4.0))
(array-add! pa pb)
(check "add! result" 5.0 (array-ref pa 0))

;; mul!
(define ma (make-int32-vector 3 3))
(define mb (make-int32-vector 3 4))
(array-mul! ma mb)
(check "mul! result" 12 (array-ref ma 0))

(check-error "add! shape mismatch raises"
  (lambda () (array-add! (make-float32-vector 3) (make-float32-vector 4))))

;; copy! (in place, distinct from allocating array-copy)
(define cd (make-float32-vector 3 0.0))
(define cs (make-float32-vector 3 7.0))
(array-copy! cd cs)
(check "copy! result" 7.0 (array-ref cd 0))
(array-set! cs 0 99.0)
(check "copy! is a snapshot" 7.0 (array-ref cd 0))

;; contiguous?
(check "contiguous? always #t" #t (array-contiguous? (make-float32-array (list 2 3))))

;;; -----------------------------------------------------------------------
(printf "Total: ~a pass, ~a fail\n" pass-count fail-count)
