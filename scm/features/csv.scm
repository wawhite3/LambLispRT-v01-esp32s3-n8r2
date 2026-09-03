;;; csv.scm — RFC 4180 CSV reader/writer for LambLisp (P140).
;;; Copyright 2026 by Frobenius Norm LLC 2026-08-11
;;; Free for non-commercial use. Commercial use requires a license.
;;;
;;; One core reader (csv-read, a char-by-char state machine over a port); everything
;;; else is a thin wrapper.  Quoted fields may contain the delimiter, embedded newlines,
;;; and "" -escaped quotes.  Values are strings unless an opts 'coerce is supplied.
(syslog "Loading CSV\n")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; options ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; opts is an alist; keys: delimiter quote trim coerce columns quote-all newline
(define (csv-opt opts key default)
  (let ((p (assq key opts)))
    (if (pair? p) (cdr p) default)))

(define (csv-ws? c) (or (char=? c #\space) (char=? c #\tab)))

(define (csv-trim s)
  (let* ((n (string-length s))
         (a (let loop ((i 0)) (if (and (< i n) (csv-ws? (string-ref s i))) (loop (+ i 1)) i)))
         (b (let loop ((j n)) (if (and (> j a) (csv-ws? (string-ref s (- j 1)))) (loop (- j 1)) j))))
    (if (<= b a) "" (substring s a b))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; core reader ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; A record separator is LF, CRLF, or a bare CR.  On CR, consume a following LF.
(define (csv-eol? c port)
  (cond ((char=? c #\newline) #t)
        ((char=? c #\return)
         (let ((nx (peek-char port)))
           (if (and (not (eof-object? nx)) (char=? nx #\newline)) (read-char port) #f))
         #t)
        (else #f)))

;;; UTF-8 BOM decodes to codepoint U+FEFF; drop it if it leads the stream.
(define (csv-strip-bom! port)
  (let ((c (peek-char port)))
    (if (and (not (eof-object? c)) (= (char->integer c) #xFEFF)) (read-char port) #f)))

;;; csv-read : port [opts] -> list of records (each a list of field strings)
(define (csv-read port . opt)
  (let* ((o     (if (pair? opt) (car opt) '()))
         (delim (csv-opt o 'delimiter #\,))
         (quo   (csv-opt o 'quote     (integer->char 34)))
         (trim? (csv-opt o 'trim      #f)))
    ;; NOTE: leading-BOM auto-stripping is deferred — `read-char` misbehaves after a
    ;; multi-byte UTF-8 char read via `open-input-string` (see the bug registry).
    (let loop ((st 'start) (fld '()) (row '()) (seen #f) (rows '()))
      ;; field-str/emit-row take q = was-this-field-quoted?  trim applies to unquoted only.
      (define (field-str q) (let ((s (list->string (reverse fld)))) (if (and trim? (not q)) (csv-trim s) s)))
      (define (emit-row q)  (reverse (cons (field-str q) row)))
      (let ((c (read-char port)))
        (cond
          ;; end of input
          ((eof-object? c)
           (reverse (if (and (not seen) (null? row)) rows
                        (cons (emit-row (or (eq? st 'quoted) (eq? st 'quote-seen))) rows))))
          ;; inside a quoted field
          ((eq? st 'quoted)
           (if (char=? c quo)
               (loop 'quote-seen fld row #t rows)
               (loop 'quoted (cons c fld) row #t rows)))
          ;; just saw a quote while quoted
          ((eq? st 'quote-seen)
           (cond ((char=? c quo)   (loop 'quoted (cons c fld) row #t rows))            ; "" -> "
                 ((char=? c delim) (loop 'start '() (cons (field-str #t) row) #f rows)); field end (quoted)
                 ((csv-eol? c port)(loop 'start '() '() #f (cons (emit-row #t) rows))) ; record end (quoted)
                 (else             (loop 'quoted (cons c fld) row #t rows))))          ; lenient
          ;; start-of-field or unquoted
          (else
           (cond ((and (eq? st 'start) (char=? c quo)) (loop 'quoted fld row #t rows))
                 ((char=? c delim) (loop 'start '() (cons (field-str #f) row) #f rows))
                 ((csv-eol? c port)
                  (if (and (not seen) (null? row))
                      (loop 'start '() '() #f rows)                                    ; blank line skipped
                      (loop 'start '() '() #f (cons (emit-row #f) rows))))
                 (else (loop 'unquoted (cons c fld) row #t rows)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; dict / string / file readers ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; zip a header list and a value list into a dict, reconciling arity (short -> "", long -> drop)
(define (csv-row->dict header vals rowno coerce)
  (let loop ((h header) (v vals) (ks '()) (xs '()))
    (cond ((null? h)
           (if (not (null? v)) (syslog "csv: row ~a has extra fields (dropped)\n" rowno))
           (2list->dict (list (reverse ks) (reverse xs))))
          (else
           (let* ((col (car h))
                  (raw (if (null? v) "" (car v)))
                  (val (coerce col raw)))
             (loop (cdr h) (if (null? v) '() (cdr v)) (cons col ks) (cons val xs)))))))

;;; csv-read->dicts : port [opts] -> list of dicts (header row keys the rest)
(define (csv-read->dicts port . opt)
  (let* ((o      (if (pair? opt) (car opt) '()))
         (coerce (csv-opt o 'coerce (lambda (col v) v)))
         (rows   (apply csv-read port opt)))
    (if (null? rows) '()
        (let ((header (car rows)))
          (let loop ((rs (cdr rows)) (n 1) (acc '()))
            (if (null? rs) (reverse acc)
                (loop (cdr rs) (+ n 1)
                      (cons (csv-row->dict header (car rs) n coerce) acc))))))))

(define (csv-string->rows str . opt)  (apply csv-read (open-input-string str) opt))
(define (csv-string->dicts str . opt) (apply csv-read->dicts (open-input-string str) opt))
(define (read-csv path . opt)         (call-with-input-file path (lambda (p) (apply csv-read p opt))))
(define (read-csv->dicts path . opt)  (call-with-input-file path (lambda (p) (apply csv-read->dicts p opt))))

;;; csv-parse-line : one record string -> list of fields (no embedded-newline handling)
(define (csv-parse-line str . opt)
  (let ((rows (apply csv-string->rows str opt)))
    (if (null? rows) '() (car rows))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; writer ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(define (csv-cell->string v) (if (string? v) v (csv->display-string v)))
(define (csv->display-string v)
  (cond ((string? v) v) ((number? v) (number->string v)) ((eq? v #t) "true") ((eq? v #f) "false")
        ((symbol? v) (symbol->string v)) (else (error "csv: cannot render non-scalar cell" v))))

(define (csv-field-needs-quote? s delim quo)
  (let ((n (string-length s)))
    (let loop ((i 0))
      (if (>= i n) #f
          (let ((c (string-ref s i)))
            (if (or (char=? c delim) (char=? c quo) (char=? c #\newline) (char=? c #\return))
                #t (loop (+ i 1))))))))

;;; double every quote char in s
(define (csv-escape-quotes s quo)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '()))
      (if (>= i n) (list->string (reverse acc))
          (let ((c (string-ref s i)))
            (loop (+ i 1) (if (char=? c quo) (cons c (cons c acc)) (cons c acc))))))))

(define (csv-render-field v delim quo quote-all)
  (let ((s (csv-cell->string v)))
    (if (or quote-all (csv-field-needs-quote? s delim quo))
        (string-append (string quo) (csv-escape-quotes s quo) (string quo))
        s)))

(define (csv-render-row row delim quo quote-all)
  (if (null? row) ""
      (let loop ((r (cdr row)) (acc (csv-render-field (car row) delim quo quote-all)))
        (if (null? r) acc
            (loop (cdr r) (string-append acc (string delim)
                                         (csv-render-field (car r) delim quo quote-all)))))))

(define (rows->csv-string rows . opt)
  (let* ((o    (if (pair? opt) (car opt) '()))
         (delim (csv-opt o 'delimiter #\,)) (quo (csv-opt o 'quote (integer->char 34)))
         (qall (csv-opt o 'quote-all #f))   (nl  (csv-opt o 'newline "\r\n")))
    (let loop ((rs rows) (acc ""))
      (if (null? rs) acc
          (loop (cdr rs) (string-append acc (csv-render-row (car rs) delim quo qall) nl))))))

(define (csv-write port rows . opt)
  (write-string (apply rows->csv-string rows opt) port))

;;; dicts -> csv: header from opts 'columns or the first dict's key order
(define (dicts->csv-string dicts . opt)
  (if (null? dicts) ""
      (let* ((o    (if (pair? opt) (car opt) '()))
             (cols (or (csv-opt o 'columns #f) (car (dict->2list (car dicts)))))
             (rows (cons cols
                         (map (lambda (d) (map (lambda (k) (dict-ref d k)) cols)) dicts))))
        (apply rows->csv-string rows opt))))

(define (csv-write-dicts port dicts . opt)
  (write-string (apply dicts->csv-string dicts opt) port))
