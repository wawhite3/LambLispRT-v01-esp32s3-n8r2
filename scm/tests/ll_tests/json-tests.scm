;;; json-tests.scm -- unit tests for json-read and json-write
;;; Copyright 2026 by Frobenius Norm LLC 2026-06-01
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Usage: echo '(load "ll_tests/json-tests.scm" 0)' | ./program

(define json-pass 0)
(define json-fail 0)

(define (json-check name expected actual)
  (if (equal? expected actual)
      (begin (display "PASS ") (display name) (newline)
             (set! json-pass (+ json-pass 1)))
      (begin (display "FAIL ") (display name)
             (display " expected=") (display expected)
             (display " got=") (display actual) (newline)
             (set! json-fail (+ json-fail 1)))))

;;; json-read tests
(json-check "read-object"     '(("a" . 1) ("b" . #t))  (json-read "{\"a\":1,\"b\":true}"))
(json-check "read-array"      '(1 2 3)                  (json-read "[1,2,3]"))
(json-check "read-null"       'null                     (json-read "null"))
(json-check "read-true"       #t                        (json-read "true"))
(json-check "read-false"      #f                        (json-read "false"))
(json-check "read-string"     "hello"                   (json-read "\"hello\""))
(json-check "read-int32"      42                        (json-read "42"))
(json-check "read-neg-int"    -7                        (json-read "-7"))
(json-check "read-float"      1.5                       (json-read "1.5"))
(json-check "read-empty-obj"  '()                       (json-read "{}"))
(json-check "read-empty-arr"  '()                       (json-read "[]"))
(json-check "read-nested"     '(("x" . (1 2)))          (json-read "{\"x\":[1,2]}"))
(json-check "read-escape"     "a\"b"                    (json-read "\"a\\\"b\""))
(json-check "read-whitespace" '(("k" . 1))              (json-read "{ \"k\" : 1 }"))

;;; json-write tests
(json-check "write-true"      "true"                    (json-write #t))
(json-check "write-false"     "false"                   (json-write #f))
(json-check "write-null"      "null"                    (json-write 'null))
(json-check "write-int"       "42"                      (json-write 42))
(json-check "write-string"    "\"hello\""               (json-write "hello"))
(json-check "write-array"     "[1,2,3]"                 (json-write '(1 2 3)))
(json-check "write-object"    "{\"x\":42}"              (json-write '(("x" . 42))))
(json-check "write-empty-arr" "[]"                      (json-write '()))

;;; json-read — numeric types
(json-check "read-int64"      2147483648                (json-read "2147483648"))
(json-check "read-neg-int64"  -2147483649               (json-read "-2147483649"))

;;; json-read — string escapes
(json-check "read-escape-tab"     "a\tb"               (json-read "\"a\\tb\""))
(json-check "read-escape-newline" "a\nb"               (json-read "\"a\\nb\""))
(json-check "read-unicode"        "A"                  (json-read "\"\\u0041\""))

;;; json-write — floats
(json-check "write-float32"   "1.5"                    (json-write 1.5))

;;; json-write — symbol keys in alist
(json-check "write-sym-key"   "{\"x\":1}"              (json-write (list (cons 'x 1))))

;;; json-write — nested
(json-check "write-nested"    "{\"a\":[1,2]}"          (json-write '(("a" . (1 2)))))

;;; json-write — string escaping
(json-check "write-str-tab"   "\"a\\tb\""              (json-write "a\tb"))
(json-check "write-str-quote" "\"a\\\"b\""             (json-write "a\"b"))

;;; json-write — large integer
(json-check "write-int64"     "2147483648"             (json-write 2147483648))

;;; error cases
(define (json-throws? thunk14)
  (let ((threw #f))
    (guard (e (#t (set! threw #t)))
      (thunk14))
    threw))

(json-check "read-error-truncated"  #t (json-throws? (lambda () (json-read "{"))))
(json-check "read-error-bare-str"   #t (json-throws? (lambda () (json-read "\"unterminated"))))
(json-check "write-error-proc"      #t (json-throws? (lambda () (json-write car))))

;;; round-trip tests
(json-check "roundtrip-obj"     '(("a" . 1))            (json-read (json-write '(("a" . 1)))))
(json-check "roundtrip-arr"     '(1 2 3)                (json-read (json-write '(1 2 3))))
(json-check "roundtrip-nested"  '(("x" . (1 2 3)))      (json-read (json-write '(("x" . (1 2 3))))))
(json-check "roundtrip-int64"   2147483648              (json-read (json-write 2147483648)))
(json-check "roundtrip-string"  "a\tb"                  (json-read (json-write "a\tb")))

(display "Total: ") (display json-pass) (display " pass, ")
(display json-fail) (display " fail") (newline)
(display "--- json done ---") (newline)

