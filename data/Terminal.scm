;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
(syslog "Loading Terminal settings\n")

;;; ANSI ESCAPES ARE A FEATURE -- ON WHEREVER THE TERMINAL OBEYS THEM, OFF WHERE IT DOES NOT.
;;;
;;; `(ansi?)` is the one predicate, decided in C++ at startup before the first byte is printed:
;;; an explicit LL_COLOR=0/1, else the no-color.org NO_COLOR convention, else the console's own
;;; answer.  On Windows the console is genuinely ASKED (SetConsoleMode with
;;; ENABLE_VIRTUAL_TERMINAL_PROCESSING), so a modern console gets full colour; Wine's console
;;; refuses to be asked and gets none.  Nothing here tests the PLATFORM, because the platform is
;;; not what varies -- one Windows binary can meet all three answers.
;;;
;;; WHY THE TEST IS AT RUN TIME AND NOT A BUILD-TIME EDIT: this file ships to every target in every
;;; customer package.  There is one copy and no per-target variant to change.
;;;
;;; WHAT A WRONG ANSWER LOOKS LIKE, in both directions: too eager and a terminal that cannot obey
;;; them shows `[97m` as text, which is the bug this fixes and is visible ONLY to an eye on a
;;; console -- a piped run strips nothing and looks identical either way.  Too shy and a perfectly
;;; good terminal loses its colours, which is cosmetic and immediately obvious.  Check by looking.
(define esc-char (integer->char #x1b))

;;; Recompute the 16 colour strings from the CURRENT `(ansi?)`.  Called once at load, and again by
;;; hand after `(ansi! ...)` -- the C++ `fg_*` are repointed the instant `ansi!` runs, but these
;;; Scheme bindings hold whatever they were computed from, so the two agree only if this is re-run.
;;; Stated plainly rather than hidden: the ordinary case is LL_COLOR set before startup, where load
;;; time IS the only time and no refresh is needed.
(define (terminal-colors!)
  (let ((fg (lambda (code) (if (ansi?) (format "~a~a" esc-char code) ""))))
    (set! fg_black     (fg "[30m"))
    (set! fg_blue      (fg "[94m"))
    (set! fg_green     (fg "[92m"))
    (set! fg_cyan      (fg "[96m"))
    (set! fg_red       (fg "[91m"))
    (set! fg_magenta   (fg "[95m"))
    (set! fg_brown     (fg "[93m"))
    (set! fg_white     (fg "[97m"))
    (set! fg_grey      (fg "[90m"))
    (set! fg_ltBlue    (fg "[34m"))
    (set! fg_ltGreen   (fg "[32m"))
    (set! fg_ltCyan    (fg "[36m"))
    (set! fg_ltRed     (fg "[31m"))
    (set! fg_ltMagenta (fg "[35m"))
    (set! fg_yellow    (fg "[93m"))
    (set! fg_ltWhite   (fg "[37m"))
    (ansi?)))

;;; Defined before the first `terminal-colors!` call so `set!` has bindings to assign.
(define fg_black     "")
(define fg_blue      "")
(define fg_green     "")
(define fg_cyan      "")
(define fg_red	     "")
(define fg_magenta   "")
(define fg_brown     "")
(define fg_white     "")
(define fg_grey      "")
(define fg_ltBlue    "")
(define fg_ltGreen   "")
(define fg_ltCyan    "")
(define fg_ltRed     "")
(define fg_ltMagenta "")
(define fg_yellow    "")
(define fg_ltWhite   "")

(terminal-colors!)

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
