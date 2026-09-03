;;; csv-tests.scm — tests for the P140 CSV library (features/csv.scm).
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-11
(define csv-pass 0)
(define csv-fail 0)
(define (csv-check name expected actual)
  (if (equal? expected actual)
      (begin (set! csv-pass (+ csv-pass 1)) (display "PASS ") (display name) (newline))
      (begin (set! csv-fail (+ csv-fail 1))
             (display "FAIL ") (display name) (display " exp=") (write expected)
             (display " got=") (write actual) (newline))))

;; 1. simple rows
(csv-check "simple" '(("a" "b" "c") ("1" "2" "3")) (csv-string->rows "a,b,c\n1,2,3\n"))
;; 2. empty fields
(csv-check "empty-mid"   '(("a" "" "c")) (csv-string->rows "a,,c\n"))
(csv-check "empty-edges" '(("" "a" "")) (csv-string->rows ",a,\n"))
;; 3. quoted field with embedded delimiter
(csv-check "quoted-comma" '(("a" "x,y" "c")) (csv-string->rows "a,\"x,y\",c\n"))
;; 4. quoted field with embedded newline (LF and CRLF)
(csv-check "quoted-lf"   '(("a" "x\ny" "c"))   (csv-string->rows "a,\"x\ny\",c\n"))
(csv-check "quoted-crlf" '(("a" "x\r\ny" "c")) (csv-string->rows "a,\"x\r\ny\",c\n"))
;; 5. escaped quote "" inside a quoted field
(csv-check "escaped-quote" '(("a" "he \"x\"" "c")) (csv-string->rows "a,\"he \"\"x\"\"\",c\n"))
;; 6. mixed quoted/unquoted
(csv-check "mixed" '(("plain" "with,comma" "42")) (csv-string->rows "plain,\"with,comma\",42\n"))
;; 7. line-end variants + trailing / no-trailing newline
(csv-check "crlf-rows"      '(("a" "b") ("c" "d")) (csv-string->rows "a,b\r\nc,d\r\n"))
(csv-check "bare-cr-rows"   '(("a" "b") ("c" "d")) (csv-string->rows "a,b\rc,d\r"))
(csv-check "no-trailing-nl" '(("a" "b"))           (csv-string->rows "a,b"))
;; 8. blank lines skipped
(csv-check "blank-skip" '(("a" "b") ("c" "d")) (csv-string->rows "a,b\n\nc,d\n"))
;; 9. (BOM auto-stripping deferred — string-port multi-byte read bug; see registry)
;; 10. custom delimiter
(csv-check "semicolon" '(("a" "b" "c")) (csv-string->rows "a;b;c\n" (list (cons 'delimiter (integer->char 59)))))
(csv-check "tab"       '(("a" "b"))     (csv-string->rows "a\tb\n"  (list (cons 'delimiter (integer->char 9)))))
;; 11. trim (unquoted only)
(csv-check "trim"        '(("a" "b"))   (csv-string->rows " a , b \n"   (list (cons 'trim #t))))
(csv-check "trim-quoted" '((" a " "b")) (csv-string->rows "\" a \",b\n" (list (cons 'trim #t))))
;; 12. csv-read->dicts + dict-ref
(define csv-d1 (csv-string->dicts "name,age\nAda,36\nBob,40\n"))
(csv-check "dict-count" 2     (length csv-d1))
(csv-check "dict-name"  "Ada" (dict-ref (car csv-d1) "name"))
(csv-check "dict-age"   "40"  (dict-ref (cadr csv-d1) "age"))
;; 13. coerce numeric columns
(define csv-d2 (csv-string->dicts "x,y\n1,2\n" (list (cons 'coerce (lambda (col v) (string->number v))))))
(csv-check "coerce" 2 (dict-ref (car csv-d2) "y"))
;; 14. ragged rows
(csv-check "ragged-short" "" (dict-ref (car (csv-string->dicts "a,b,c\n1,2\n")) "c"))
(csv-check "ragged-long"  "1" (dict-ref (car (csv-string->dicts "a,b\n1,2,3\n")) "a"))
;; 15. writer quoting rule
(csv-check "write-plain"  "a,b\r\n"          (rows->csv-string '(("a" "b"))))
(csv-check "write-comma"  "\"a,b\"\r\n"      (rows->csv-string '(("a,b"))))
(csv-check "write-quote"  "\"he \"\"x\"\"\"\r\n" (rows->csv-string '(("he \"x\""))))
(csv-check "write-nl-opt" "a,b\n"            (rows->csv-string '(("a" "b")) (list (cons 'newline "\n"))))
;; 16. quote-all
(csv-check "quote-all" "\"a\",\"b\"\r\n" (rows->csv-string '(("a" "b")) (list (cons 'quote-all #t))))
;; 17. round-trip identity  (rows == parse(write(rows)))
(define csv-corpus '(("a" "b,c" "d\ne") ("x" "he \"hi\"" "") ("" "1" "2")))
(csv-check "round-trip" csv-corpus (csv-string->rows (rows->csv-string csv-corpus)))
;; 18. empty input + parse-line + dicts write round-trip
(csv-check "empty-input" '()               (csv-string->rows ""))
(csv-check "parse-line"  '("a" "b,c" "d")   (csv-parse-line "a,\"b,c\",d"))
(csv-check "dicts-write-rt" "36"
           (dict-ref (car (csv-string->dicts (dicts->csv-string csv-d1))) "age"))

(display "Total: ")(display csv-pass)(display " pass, ")(display csv-fail)(display " fail")(newline)
