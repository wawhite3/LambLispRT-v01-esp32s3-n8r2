;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "Loading Terminal settings\n")

(define esc-char     (integer->char #x1b))
(define fg_black     (format "~a~a" esc-char "[30m"))
(define fg_blue      (format "~a~a" esc-char "[94m"))
(define fg_green     (format "~a~a" esc-char "[92m"))
(define fg_cyan      (format "~a~a" esc-char "[96m"))
(define fg_red	     (format "~a~a" esc-char "[91m"))
(define fg_magenta   (format "~a~a" esc-char "[95m"))
(define fg_brown     (format "~a~a" esc-char "[93m"))
(define fg_white     (format "~a~a" esc-char "[97m"))
(define fg_grey      (format "~a~a" esc-char "[90m"))
(define fg_ltBlue    (format "~a~a" esc-char "[34m"))
(define fg_ltGreen   (format "~a~a" esc-char "[32m"))
(define fg_ltCyan    (format "~a~a" esc-char "[36m"))
(define fg_ltRed     (format "~a~a" esc-char "[31m"))
(define fg_ltMagenta (format "~a~a" esc-char "[35m"))
(define fg_yellow    (format "~a~a" esc-char "[93m"))
(define fg_ltWhite   (format "~a~a" esc-char "[37m"))

(define (news    . args) (syslog "~a~a~a" fg_green (apply format args) fg_white))
(define (warn    . args) (syslog "~a~a~a" fg_yellow (apply format args) fg_white))
(define (term    . args) (syslog "~a~a~a" fg_cyan (apply format args) fg_white))
(define (info    . args) (syslog "~a~a~a" fg_white (apply format args) fg_white))
(define (blue    . args) (syslog "~a~a~a" fg_ltBlue (apply format args) fg_white))
(define (magenta . args) (syslog "~a~a~a" fg_ltMagenta (apply format args) fg_white))
(define (errmsg  . args) (syslog "~a~a~a" fg_red (apply format args) fg_white))

(define banner
  (let* (
	 (b0 '(
	      "\n"
	      "8                          8 \n"
	      "8     eeeee eeeeeee eeeee  8     e  eeeee eeeee \n"
	      "8e    8   8 8  8  8 8   8  8e    8  8   ' 8   8 \n"
	      "88    8eee8 8e 8  8 8eee8e 88    8e 8eeee 8eee8 \n"
	      "88    88  8 88 8  8 88   8 88    88    88 88 \n"
	      "88eee 88  8 88 8  8 88eee8 88eee 88 8ee88 88 \n"
	      "\n"
	      ))
	 (b1 '(
	      "\n"
	      ":                          : \n"
	      ":     ..... ....... .....  :     .  ..... ..... \n"
	      ":.    :   : :  :  : :   :  :.    :  :   ' :   : \n"
	      "::    :...: :. :  : :...:. ::    :. :.... :...: \n"
	      "::    ::  : :: :  : ::   : ::    ::    :: :: \n"
	      "::... ::  : :: :  : ::...: ::... :: :..:: :: \n"
	      "\n"
	      ))
	 (b b0)
	 )
    ;; f is self-recursive -> letrec (strict R7RS let* does not scope a binding in its own init)
    (letrec ((f (lambda (l) (if (null? l)
			    #f
			    (begin
			      (news (car l))
			      (f (cdr l))
			      )
			    )
		    )))
      (info "LambLisp is Copyright 2023-2025 Frobenius Norm LLC\n")
      (lambda () (f b))
      )
    )
  )

(banner)
(set! banner #f)	;purge the banner to reclaim space

(news "Good news in green\n")
(info "Info in white\n")
(warn "Warnings in yellow\n")
(errmsg "Errors in red\n")

(define (print-alist alist)
  (letrec ((print1 (lambda (p) (info "  (~a . ~a)\n" (car p) (cdr p))))
	   (printrest (lambda (l)
			(unless (null? l)
			  (print1 (car l))
			  (printrest (cdr l))
			  )
			)
		      )
	   )
    (info "(\n")
    (printrest alist)
    info ")\n")
  )
