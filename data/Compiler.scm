;;; Copyright 2026 by Frobenius Norm LLC 2026-05-16
;;; Free for non-commercial use. Commercial use requires a license.
#|
The compiler is based on nlambda and macro expansion.

Recall that arguments to a lambda function are evaluated, and the results of the evaluation are the values to which the function is applied.
Arguments to an nlambda function are *not* evaluated; the body of the nlambda receives the arguments just as they are in the source code.

The nlambda feature forms the basis for syntax evaluation in LambLisp.  It is possible to implement the entirety of Scheme syntax (except syntax-rules macros)
using nlambda functions to implement the syntactic primitives.

In the interpreted mode, all source code symbols are retained, and their values looked up at run time.  This allows symbols to be reassigned new values at runtime.
Some might argue that it is not a useful feature to be able to replace, say, the *if* operator.  But this arrangement has some elegant features.

First, it can be used for overloading an operator to handle new argument types.
To do this, define the new type and its type predicate, and then define a function that checks the type and either operates on the new type, or applies the old operator to the object
Redefine the symbol in the environment, and now you have a more capable operator.
For example, this technique could be used to add support for complex numbers, or rational numbers, to an implementation that has only integers and floats.

Another important result is using the rebinding feature in the compilation chain.  LambLisp is implemented at a very high level.
The operations defined in the Scheme R5RS specification are coded directly in C++.
From that viewpoint, the system is nearly completely compiled already.

In interpreted mode, the symbols are looked up in the environment and their values (which are functions) are called.
LambLisp supports a fundamental T_MACRO type, which does the following:
At run-time, during eval, when a macro is encountered the macro body is applied to the arguments, and then the result of that application is further evaluated (tail-recursively).
Notably, at run-time macros may be expanded repeatedly, which may be desirable or may simply use additional time.

At read time, the result of macro evaluation is executed, and then that result is substituted into the program.
The result is that the symbol is compiled away, and replaced with the address of the associated function, which is then called directly at runtime.
This eliminates the lookup at run time, but also does not allow for further changes to the operations.
Also, when errors occur, the debug information is more difficult to interpret.
|#

(syslog "Loading Compiler\n")

;;; If sym is a symbol whose value in env is a procedure or nlambda,
;;; wrap it in a macro cell so the reader expands it at read time, eliminating
;;; the run-time symbol lookup.
;;; cons-fn must be the raw T_MOP3_PROC for cons, captured before any wrapping,
;;; so the macro body never looks up the symbol 'cons' at expansion time (B25).
(define (compile-symbol sym env cons-fn)
  (when (symbol? sym)
    (let ((proc (dict-ref env sym)))
      (when (or (procedure? proc) (nprocedure? proc))
        (dict-rebind! env sym (macro args (cons-fn proc args)))))))

;;; Compile a list of symbols in env.
(define (compile list-of-symbols env cons-fn)
  (unless (null? list-of-symbols)
    (compile-symbol (car list-of-symbols) env cons-fn)
    (compile (cdr list-of-symbols) env cons-fn)))

;;; Traverse env and compile every symbol whose value is a procedure or nlambda.
;;; Uses dict-keys to collect all keys across all frames of the environment dict,
;;; then iterates with for-each to avoid recursion-depth growth on large environments.
;;; cons-fn is captured before the loop so that after 'cons' itself is wrapped,
;;; macro bodies still hold the raw T_MOP3_PROC value and never recurse (B25 fix).
(define (compile-environment env)
  (let ((keys    (dict-keys env))
        (cons-fn (dict-ref env 'cons)))
    (syslog "Compiler: compiling ~a symbols\n" (length keys))
    (for-each (lambda (sym) (compile-symbol sym env cons-fn)) keys)
    (syslog "Compiler: done\n")))

(syslog "Compiler loaded\n")

