;;; utf8-tests.scm -- UTF-8 and Unicode conformance tests (R7RS 6.6, 6.7, 6.9).
;;; Copyright 2026 by Frobenius Norm LLC 2026-05-26 00:00:00
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; Source is ASCII-only.  Non-ASCII characters are constructed via:
;;;   #\xNNNN     character literal with hex codepoint (reader: B12 fixed)
;;;   "\xNNNN;"   string literal hex escape, stored as UTF-8 bytes in string
;;;   (integer->char N)  construct char from codepoint at runtime
;;;
;;; Expected failures on LambLisp (B27 -- strings are byte-indexed):
;;;   string-length, string-ref, string, list->string, string->list
;;;   for strings containing multi-byte UTF-8 characters.
;;;   char-alphabetic?, char-upper-case?, char-lower-case?, char-numeric?,
;;;   char-upcase, char-downcase beyond ASCII / Latin-1 supplement.
;;;   digit-value for non-ASCII decimal digits.
;;;
;;; Run standalone:  (load "ll_tests/utf8-tests.scm" 0)
;;; Run via suite:   loaded by run-all.scm

;;; ---------------------------------------------------------------------------
;;; Test framework (self-contained; works on LambLisp and Chez Scheme)
;;; ---------------------------------------------------------------------------

(define ll-esc (string (integer->char #x1b)))
(define chez-scheme?
  (guard (exn (#t #t))
    (eval 'syslog)
    #f))

(define (%u8t-fmt color fmt . args)
  (when color (display color))
  (let loop ((chars (string->list fmt)) (args args))
    (cond
      ((null? chars) (values))
      ((and (char=? (car chars) #\~)
            (pair? (cdr chars))
            (char=? (cadr chars) #\a))
       (display (if (null? args) "?" (car args)))
       (loop (cddr chars) (if (null? args) '() (cdr args))))
      (else
       (display (string (car chars)))
       (loop (cdr chars) args))))
  (when color (display (string-append ll-esc "[0m"))))

(define (u8-news fmt . args) (apply %u8t-fmt (string-append ll-esc "[32m") fmt args))
(define (u8-warn fmt . args) (apply %u8t-fmt (string-append ll-esc "[33m") fmt args))

(define *pass* 0)
(define *fail* 0)

(define (check name expected actual)
  (if (equal? expected actual)
    (begin (set! *pass* (+ *pass* 1)) (u8-news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1)) (u8-warn "FAIL ~a  expected=~a  got=~a\n" name expected actual))))

(define (check-true name val)
  (if val
    (begin (set! *pass* (+ *pass* 1)) (u8-news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1)) (u8-warn "FAIL ~a  expected=#t  got=~a\n" name val))))

(define (check-false name val)
  (if (not val)
    (begin (set! *pass* (+ *pass* 1)) (u8-news "PASS ~a\n" name))
    (begin (set! *fail* (+ *fail* 1)) (u8-warn "FAIL ~a  expected=#f  got=~a\n" name val))))

(define (check-error name thunk32)
  (let ((r (guard (e (#t 'caught)) (thunk32) 'no-error)))
    (if (eq? r 'caught)
      (begin (set! *pass* (+ *pass* 1)) (u8-news "PASS ~a\n" name))
      (begin (set! *fail* (+ *fail* 1)) (u8-warn "FAIL ~a  expected error, got none\n" name)))))

;;; ---------------------------------------------------------------------------
;;; 1. Character literal notation: #\xNNNN hex codepoints  (B12 fixed)
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 1. #\\xNNNN character literal notation ---\n")

(check "charlit/ascii-a"    97      (char->integer #\x61))       ; U+0061 = 'a'
(check "charlit/ascii-0"    48      (char->integer #\x30))       ; U+0030 = '0'
(check "charlit/latin1-e"   #x00E9  (char->integer #\xE9))       ; U+00E9 = e with acute
(check "charlit/latin1-cap" #x00C0  (char->integer #\xC0))       ; U+00C0 = A with grave
(check "charlit/greek-lam"  #x03BB  (char->integer #\x03BB))     ; U+03BB = Greek small lambda
(check "charlit/greek-cap"  #x039B  (char->integer #\x039B))     ; U+039B = Greek capital Lambda
(check "charlit/hiragana"   #x3042  (char->integer #\x3042))     ; U+3042 = Hiragana A (a)
(check "charlit/emoji"      #x1F600 (char->integer #\x1F600))    ; U+1F600 = grinning face

;;; ---------------------------------------------------------------------------
;;; 2. String literal \xNNNN; hex escapes (stored as UTF-8 bytes in string)
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 2. String literal \\xNNNN; hex escape sequences ---\n")

;;; ASCII round-trip: byte value equals codepoint value, so both directions work.
(check-true "str-esc/ascii-eq"  (string=? "abc" "\x61;\x62;\x63;"))
(check "str-esc/ascii-len"   3  (string-length "\x61;\x62;\x63;"))

;;; Greek lambda U+03BB encodes to UTF-8 bytes #xCE #xBB.
;;; string->utf8 copies the stored bytes back as-is -- PASS.
(check "str-esc/greek-u8"
       (bytevector #xCE #xBB)
       (string->utf8 "\x03BB;"))

;;; string-length counts bytes, not characters (B27) -- FAIL on LambLisp.
(check "str-esc/greek-len"   1  (string-length "\x03BB;"))

;;; Four-byte emoji U+1F600: UTF-8 = #xF0 #x9F #x98 #x80.
(check "str-esc/emoji-u8"
       (bytevector #xF0 #x9F #x98 #x80)
       (string->utf8 "\x1F600;"))

;;; ---------------------------------------------------------------------------
;;; 3. char->integer / integer->char
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 3. char->integer / integer->char ---\n")

;;; char->integer returns the full Unicode codepoint.
(check "c->i/ascii"        97      (char->integer #\a))
(check "c->i/latin1"       #x00E9  (char->integer (integer->char #x00E9)))
(check "c->i/greek-lo"     #x03BB  (char->integer (integer->char #x03BB)))
(check "c->i/greek-up"     #x039B  (char->integer (integer->char #x039B)))
(check "c->i/hiragana"     #x3042  (char->integer (integer->char #x3042)))
(check "c->i/emoji"        #x1F600 (char->integer (integer->char #x1F600)))
(check "c->i/max"          #x10FFFF (char->integer (integer->char #x10FFFF)))

;;; integer->char must reject surrogate range U+D800-U+DFFF and > U+10FFFF.
(check-error "i->c/surrogate-lo"  (lambda () (integer->char #xD800)))
(check-error "i->c/surrogate-mid" (lambda () (integer->char #xDC00)))
(check-error "i->c/surrogate-hi"  (lambda () (integer->char #xDFFF)))
(check-error "i->c/out-of-range"  (lambda () (integer->char #x110000)))

;;; ---------------------------------------------------------------------------
;;; 4. Char ordering -- codepoint order (R7RS 6.6)
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 4. Char ordering by Unicode codepoint ---\n")

(check-true  "char<?/bmp"    (char<? #\a (integer->char #x03BB)))    ; 'a'(97) < lambda(955)
(check-true  "char>?/bmp"    (char>? (integer->char #x03BB) #\a))
(check-true  "char=?/nonascii" (char=? (integer->char #x03BB) (integer->char #x03BB)))
(check-false "char=?/differ"   (char=? (integer->char #x03BB) (integer->char #x03BC)))  ; lambda != mu
(check-true  "char<?/bmp-smp"  (char<? (integer->char #x03BB) (integer->char #x1F600))) ; BMP < SMP

;;; ---------------------------------------------------------------------------
;;; 5. Char predicates (R7RS 6.6)
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 5a. char-alphabetic? ---\n")

;;; ASCII: always correct.
(check-true  "alpha?/a"       (char-alphabetic? #\a))
(check-true  "alpha?/Z"       (char-alphabetic? #\Z))
(check-false "alpha?/0"       (char-alphabetic? #\0))
(check-false "alpha?/space"   (char-alphabetic? #\space))

;;; Latin-1 supplement (U+00C0-U+00FF): LambLisp handles this range.
(check-true  "alpha?/e-acute" (char-alphabetic? (integer->char #x00E9)))   ; e with acute
(check-true  "alpha?/A-grave" (char-alphabetic? (integer->char #x00C0)))   ; A with grave

;;; Greek -- R7RS requires #t; LambLisp returns #f (B27).
(check-true  "alpha?/greek-lo" (char-alphabetic? (integer->char #x03BB)))  ; lambda
(check-true  "alpha?/greek-up" (char-alphabetic? (integer->char #x039B)))  ; Lambda

;;; Hiragana -- R7RS requires #t; LambLisp returns #f (B27).
(check-true  "alpha?/hiragana" (char-alphabetic? (integer->char #x3042)))  ; a

(u8-news "\n--- 5b. char-upper-case? / char-lower-case? ---\n")

;;; ASCII: correct.
(check-true  "upper?/A"       (char-upper-case? #\A))
(check-false "upper?/a"       (char-upper-case? #\a))
(check-true  "lower?/a"       (char-lower-case? #\a))
(check-false "lower?/A"       (char-lower-case? #\A))

;;; Latin-1 uppercase: LambLisp returns #f (ASCII-only check, B27).
(check-true  "upper?/A-grave" (char-upper-case? (integer->char #x00C0)))   ; A with grave
(check-true  "lower?/e-acute" (char-lower-case? (integer->char #x00E9)))   ; e with acute

(u8-news "\n--- 5c. char-whitespace? ---\n")

(check-true  "ws?/space"    (char-whitespace? #\space))
(check-true  "ws?/newline"  (char-whitespace? #\newline))
(check-true  "ws?/tab"      (char-whitespace? #\tab))
(check-false "ws?/a"        (char-whitespace? #\a))
;;; Non-breaking space U+00A0 and line/paragraph separators: LambLisp handles these.
(check-true  "ws?/nbsp"     (char-whitespace? (integer->char #x00A0)))
(check-true  "ws?/linesep"  (char-whitespace? (integer->char #x2028)))
(check-true  "ws?/parasep"  (char-whitespace? (integer->char #x2029)))

(u8-news "\n--- 5d. char-numeric? ---\n")

(check-true  "numeric?/0"    (char-numeric? #\0))
(check-true  "numeric?/9"    (char-numeric? #\9))
(check-false "numeric?/a"    (char-numeric? #\a))
;;; Arabic-Indic digit U+0664. char-numeric? shares digit-value's Nd table (7c6b094), so the
;;; two agree; R7RS defines digit-value as #f for a non-digit, so a char with a digit VALUE is
;;; numeric. The old note here pointed at B27, which was FIXED 2026-08-29 -- char-numeric? was
;;; left behind when B27's residual went to B162 (char-alphabetic?/char-case only).
(check-true  "numeric?/arab" (char-numeric? (integer->char #x0664)))

(u8-news "\n--- 5e. digit-value ---\n")

(check "dv/0"       0  (digit-value #\0))
(check "dv/5"       5  (digit-value #\5))
(check "dv/9"       9  (digit-value #\9))
(check "dv/a"      #f  (digit-value #\a))
;;; Arabic-Indic U+0660-U+0669: R7RS requires correct digit values; LambLisp returns #f (B27).
(check "dv/arab-0"  0  (digit-value (integer->char #x0660)))   ; Arabic-Indic digit 0
(check "dv/arab-4"  4  (digit-value (integer->char #x0664)))   ; Arabic-Indic digit 4
;;; Devanagari U+0966-U+096F: likewise (B27).
(check "dv/deva-0"  0  (digit-value (integer->char #x0966)))   ; Devanagari digit 0

(u8-news "\n--- 5f. char-upcase / char-downcase ---\n")

;;; ASCII: correct.
(check "upcase/a"    #\A  (char-upcase #\a))
(check "downcase/A"  #\a  (char-downcase #\A))

;;; Latin-1 supplement: LambLisp handles U+00C0-U+00DE <-> U+00E0-U+00FE.
(check "upcase/e-acute"   (integer->char #x00C9) (char-upcase  (integer->char #x00E9)))  ; e->E acute
(check "downcase/E-acute" (integer->char #x00E9) (char-downcase (integer->char #x00C9))) ; E->e acute
(check "upcase/a-grave"   (integer->char #x00C0) (char-upcase  (integer->char #x00E0)))  ; a->A grave

;;; Greek: R7RS requires lambda->Lambda; LambLisp returns identity (B27).
(check "upcase/greek-lo"   (integer->char #x039B) (char-upcase  (integer->char #x03BB))) ; lambda->Lambda
(check "downcase/greek-up" (integer->char #x03BB) (char-downcase (integer->char #x039B))) ; Lambda->lambda

;;; ---------------------------------------------------------------------------
;;; 6. string-length for Unicode strings (R7RS 6.7)
;;; string-length counts characters, not bytes (B27 on LambLisp).
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 6. string-length ---\n")

;;; ASCII: always correct (1 char = 1 byte).
(check "strlen/ascii"    5  (string-length "hello"))
(check "strlen/empty"    0  (string-length ""))

;;; Greek lambda U+03BB = 2 UTF-8 bytes; R7RS requires length 1 (B27).
(check "strlen/greek"    1  (string-length "\x03BB;"))

;;; Emoji U+1F600 = 4 UTF-8 bytes; R7RS requires length 1 (B27).
(check "strlen/emoji"    1  (string-length "\x1F600;"))

;;; Mixed: "a" + lambda + "b" = 3 characters, 4 bytes (B27).
(check "strlen/mixed"    3  (string-length "\x61;\x03BB;\x62;"))

;;; ---------------------------------------------------------------------------
;;; 7. string-ref for Unicode strings (R7RS 6.7)
;;; string-ref is character-indexed, not byte-indexed (B27 on LambLisp).
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 7. string-ref ---\n")

;;; ASCII: always correct.
(check "strref/ascii-0"   #\h  (string-ref "hello" 0))
(check "strref/ascii-4"   #\o  (string-ref "hello" 4))

;;; Greek: index 0 should yield the lambda character, not the first UTF-8 byte (B27).
(check "strref/greek-0"   (integer->char #x03BB)  (string-ref "\x03BB;" 0))

;;; Mixed "a" + lambda + "b": index 1 = lambda, index 2 = 'b' (B27).
(check "strref/mixed-1"   (integer->char #x03BB)  (string-ref "\x61;\x03BB;\x62;" 1))
(check "strref/mixed-2"   #\b                     (string-ref "\x61;\x03BB;\x62;" 2))

;;; ---------------------------------------------------------------------------
;;; 8. string / list->string / string->list with non-ASCII chars (R7RS 6.7)
;;; (string char ...) must encode chars as UTF-8 (B27 on LambLisp).
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 8. string / list->string / string->list ---\n")

;;; ASCII: always correct.
(check "string/ascii"    "hi"  (string #\h #\i))
(check "l->s/ascii"      "hi"  (list->string (list #\h #\i)))
(check "s->l/ascii"      (list #\h #\i) (string->list "hi"))

;;; (string (integer->char #x03BB)) must produce a 1-char string encoded as UTF-8.
;;; Verified via string->utf8: should be #u8(#xCE #xBB).
;;; LambLisp truncates to byte #xBB, returning #u8(#xBB) (B27).
(check-true "string/greek-utf8"
  (equal? (bytevector #xCE #xBB)
          (string->utf8 (string (integer->char #x03BB)))))

;;; (list->string (list (integer->char #x03BB))): list->string encodes UTF-8 correctly -- PASS.
(check-true "l->s/greek-utf8"
  (equal? (bytevector #xCE #xBB)
          (string->utf8 (list->string (list (integer->char #x03BB))))))

;;; (string->list "\x03BB;") must yield a 1-element list containing lambda.
;;; LambLisp splits on bytes, yielding (#\xCE #\xBB) (B27).
(check "s->l/greek"
  (list (integer->char #x03BB))
  (string->list "\x03BB;"))

;;; (string->list "\x03BB;" 0 1) must yield (lambda): 1 char, not byte slice (B27).
(check "s->l/greek-slice"
  (list (integer->char #x03BB))
  (string->list "\x03BB;" 0 1))

;;; ---------------------------------------------------------------------------
;;; 9. string->utf8 / utf8->string (R7RS 6.9)
;;; ---------------------------------------------------------------------------

(u8-news "\n--- 9. string->utf8 / utf8->string ---\n")

;;; ASCII: both directions correct.
(check "s->u8/ascii"   (bytevector 104 101 108 108 111) (string->utf8 "hello"))
(check "u8->s/ascii"   "hello"  (utf8->string (bytevector 104 101 108 108 111)))
(check "u8->s/slice"   "el"     (utf8->string (bytevector 104 101 108 108 111) 1 3))

;;; Strings created by "\xNNNN;" escapes store raw UTF-8 bytes.
;;; string->utf8 copies those bytes back, so this round-trip PASSES.
(check "s->u8/greek"   (bytevector #xCE #xBB)           (string->utf8 "\x03BB;"))
(check "s->u8/emoji"   (bytevector #xF0 #x9F #x98 #x80) (string->utf8 "\x1F600;"))

;;; utf8->string then string->utf8 must be a round-trip (PASS -- both work on raw bytes).
(check-true "u8->s/roundtrip-greek"
  (equal? (bytevector #xCE #xBB)
          (string->utf8 (utf8->string (bytevector #xCE #xBB)))))

;;; R7RS: (string-length (utf8->string bv)) must equal character count, not byte count.
;;; For #u8(#xCE #xBB): 2 bytes, 1 character. LambLisp returns 2 (B27).
(check "u8->s/strlen-greek"  1  (string-length (utf8->string (bytevector #xCE #xBB))))

;;; R7RS: (string-ref (utf8->string bv) 0) must be the decoded character.
;;; For #u8(#xCE #xBB): should be lambda U+03BB. LambLisp returns #\xCE (B27).
(check "u8->s/ref-greek"
  (integer->char #x03BB)
  (string-ref (utf8->string (bytevector #xCE #xBB)) 0))

;;; ---------------------------------------------------------------------------
;;; Summary
;;; ---------------------------------------------------------------------------

(u8-news "\n=== UTF-8 / Unicode TEST SUMMARY: ~a passed, ~a failed ===\n" *pass* *fail*)
(if (= *fail* 0)
  (u8-news "ALL TESTS PASSED\n")
  (u8-warn "~a TESTS FAILED (see B27 in proposal_bug_registry_P88.md)\n" *fail*))

(define utf8-pass *pass*)
(define utf8-fail *fail*)

; end of utf8-tests.scm
