// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#ifndef LL_LAMB_H
#define LL_LAMB_H

#include "ll_platform_generic.h"

/*! @file
  This file is the header file required to use LambLisp.

  The LambLisp abstract machine is built on a solution stack of several parts:
  -  Part 0 is in the generic platform header file, containing definitions for foundational element of the underlying system.
  -  Part 1 contains definitions for general-purpose low-level data types and utility functions.
  -  Part 2 defines the Cell structure and its accessors.
  -  Part 3 defines the LambLisp Virtual Machine.
*/

//! @name Scheme partially defines *ports*, but LambLisp tries to keep them abstracted as far as possible, traceable back to the RxRS specifications.
//!@{
class LL_Port;			//!<This is a placeholder for the underlying C++ port defined elsewhere,  Here we only need pointers to instances of it.
typedef LL_Port Port_t;		//!<An alias for the underlying port implementation, conforming to the LambLisp VM shared type nomenclature.
typedef Port_t *Portst_t;	//!<A pointer to the shared type representing a *port* as described in the RxRS specifications.
//!@}

//!Facility to automatically delete C++ objects from Lisp.
typedef void CPPDeleter(void *cpp_obj);
typedef CPPDeleter *CPPDeleterPtr;

class Cell;		//forward
typedef Cell *Sexpr_t;	//!<A symbolic expression is a pointer to a cell.

class DatumLabels;	//!<forward: external per-cell color/label table for cyclic/shared write; defined in ll_vm_cell.cpp.
//! R7RS write modes: which datum labels the writer emits (SRFI-38 / R7RS 6.13.3).
enum class WriteMode { Simple, Cyclic, Shared };	//!<Simple=no labels; Cyclic=label cycle nodes (write/display); Shared=label all nodes seen >=2 (write-shared).
//! render `obj` to a String with datum labels per `mode` (runs pass1 scan + pass2 emit).  Defined in ll_vm_cell.cpp.
String ll_datum_to_string(Sexpr_t obj, Bool_t do_write, WriteMode mode);

/*! @name These singletons exist outside the general cell population.
  Lisp implementations are notoriously variable on the type and details of NIL.  In some, NIL is a *well-known symbol*, whose type is *list* and
  whose *car* and *cdr* are also NIL (pointing to itself).

  In *Scheme*, there is no symbol NIL but the empty parenthesis are used as in ().  The empty list is its own type, which is is a list, and an atom, but not a pair.
  In LambLisp, the singleton Cell NIL is allocated statically with the appropriate initializers to fill the role.
  
  Several other statically allocated symbols are also defined in this group.  They are available at compile time.
*/
//!@{
extern Sexpr_t NIL;		//!<The empty list.
extern Sexpr_t HASHT;		//!<The canonical *true* value.
extern Sexpr_t HASHF;		//!<The canonical *false* value.
extern Sexpr_t OBJ_EOF;		//!<A single EOF object is used to indicate end-of-file on all ports.
extern Sexpr_t OBJ_UNDEF;	//!<A single UNDEF object, used to initialize a Cell having no immediate default value, and as the UNBOUND-VARIABLE marker. It is **NOT** the RxRS unspecified value -- that is `OBJ_VOID` (B192). This comment used to say it was, and `mop3_cond` believed it: an unmatched `cond` returned OBJ_UNDEF and so was indistinguishable from a failed lookup, muddying `dict_ref` diagnosis. If you are reaching for a value meaning "no result", you want OBJ_VOID.
extern Sexpr_t OBJ_VOID;	//!<**THE** RxRS unspecified value, and the only one (B190/B192). Every form that returns nothing yields THIS, on BOTH the AST and the bytecode paths, and they must never disagree: an empty body, a no-else `if` whose test failed, `when`/`unless` on the untaken branch, a `cond` with no matching clause. It is truthy, is not null, and prints as nothing. NIL and HASHF are both WRONG here and both were used before B192 -- they are legitimate Scheme values that flow on silently, and HASHF is the worse of the two because it is Scheme's only false value, so an unspecified result acted as a NO and `(if (if #f #f) 'a 'b)` picked `'b`. The old note here ("a silent version of OBJ_UNDEF ... use with care because it will hide errors") predates B190/B192 and warned against exactly the use this value now has everywhere; it is gone rather than softened. Emitted in bytecode as a LOAD_CONST, not an opcode, because BC_* and NCG_* must stay numbered in lockstep.
extern Sexpr_t OBJ_NOSLOT;	//!<B196: the T_SVEC_IMM "this slot does not exist" marker, and NOTHING ELSE.
				//!<A T_SVEC_IMM stores NO length -- it INFERS 0/1/2 by comparing each slot to this
				//!<marker, which is BY DESIGN: set-car!/set-cdr! on one is meant to change its length.
				//!<The design only works while the marker is a value NOTHING can return.  It used to be
				//!<OBJ_VOID, which is the RxRS unspecified value, so `(vector-set! v 0 (if #f #f))`
				//!<SILENTLY SHRANK a 2-vector to 1 (and left the marker visible as element 0).  OBJ_UNDEF
				//!<is no better: array-set!/array-fill!/bvec-rand and ~10 more mop3s `return OBJ_UNDEF`
				//!<as their unspecified result.  A null (0) slot is worse still -- GC_MarkStack::push()
				//!<does p->gc_state() with no null guard, so the marker would fault.  Hence a dedicated
				//!<REAL cell: every traversal (mark, integrity_check, dump) stays safe, and no procedure
				//!<can ever produce it.  NEVER bind it, return it, or expose it to Scheme.
extern Sexpr_t OBJ_SYSERROR;	//!<A single instance of T_ERROR, statically allocated with a fixed size buffer (also statically allocated) for use by Cell-level errors
//!@}

static const LL_int32 SINT_CACHE_MIN  = -2048;                               //!<Smallest cached integer.
static const LL_int32 SINT_CACHE_MAX  =  4096;                               //!<Largest cached integer.
static const LL_int32 SINT_CACHE_SIZE =  SINT_CACHE_MAX - SINT_CACHE_MIN + 1; //!<Number of cached cells (6145).
extern Cell *sint_cache_cells;                                             //!<Base of the cache array; index = value - SINT_CACHE_MIN.

/*! @class Cell
  The Cell class is the foundational class for the LambLisp Virtual Machine.

  Nearly all the Cell methods are *inline* for performance.
  A Cell has only getters and setters; there are no other side effects.
  Cell fields are changed only through explicit requests, and not as the result of any other mutations.
  This means that Cells do not participate in garbage collection, which is managed from outside the Cell class.
  Indeed, there is no concept within the Cell that there might be a plurality of them; only the behavior of a single Cell is defined.

  A Cell may be one of several types.  Historically, the number of types varied with the variant of Lisp.
  In LambLisp, there are Cell types that correspond directly to the types described in the *Scheme RxRS* specifications (integers, procedures etc),
  and there are additional types that implement underlying behavior to support the higher-level language (thunks, dictionaries).

  For example, LambLisp supports several types of *strings* internally, depending on whether the character are stored on the heap,
  in externally-provided memory, or immediately within the cell (for fast operations on short strings).  Each of these *string* types
  is compatible with the string type in the *Scheme RxRS* specifications.  Likewise, bytevectors have external and immediate variants.
  
  LambLisp also supports specialized *pair* types, such as the LambLisp *dictionary*.
  These act as *Lisp* pairs for purposes of allocation and garbage collection, but their specialized operators are executed by the underlying LambLisp virtual machine and therefore operate at C++ speed.

  The Cell type enumeration is purposefully ordered in such a way as to allow efficient integer comparisons instead of a C switch in most cases,
  enhancing runtime performance as well as garbage collection.

  | Cell enumeration characteristics:                                              |
  |--------------------------------------------------------------------------------|
  | Cells requiring submarking                                                     |
  | Cells requiring finalizing                                                     |
  | Simple atoms: immediate cell types like bool char int real etc                 |
  | External (non-GC) objects and pointers to native C++ code                      |
  | Cells that point to C++-allocated objects, paired with optional GC finalizers. |
  | "well-known singleton atoms" such as NIL, undefined, and void types.           |
  | Pair - the Cell type that responds to the Lisp *pair?* predicate.              |
  | Other pairs - specialized pair types                                           |

  With this ordering of Cell types, the solution to many common cases during expression evaluation can be obtained with an inequality,
  rather than a C++ *switch* statement.
  This provides a significant performance boost, because the most common cases are checked first, and the total number of cases is reduced.
  
  | Cell optimized type tests                                                                                                          |
  |-------------------------------------------------------------------------------------------------------------------------------|
  | (Types <  "simple atoms") need specialized GC marking and heap reclamation.                                                   |
  | (Types <= "cells requiring finalizing") need specialized GC heap reclamation.                                                 |
  | (Types >= T_NIL) are lists.                                                                                                   |
  | (Types >  T_NIL) are pairs (but not only *Lisp* pairs, extended pairs too).                                                   |
  | (Types != T_PAIR) are atoms, including numbers, strings, vectors, and singletons such as NIL.                                 |
  | (Types >  T_PAIR) are extended pairs, used for specialized lists known to LambVM, but receiving regular *pair* GC processing. |

  There are cases where the ordering does not help so much.  For example the LambLisp type system allows for several types of strings.
  Because the type system is ordered according to GC requirements, these are not adjacent in the enumeration and less amenable to inequality tests.
  For these cases, there is a cell feature matrix available to be queried by type and feature.
  This allows the determination to be made with an array lookup, which is faster than several sequential tests or a C *switch*,
  putting a permanent cap on the cost of a type check.  It also allows other details such as `is-immediate?` to be implemented inexpensively.

  The garbage collector states are ordered for similar reasons.  See the garbage collector chapter for details on the Cell life cycle.
*/
class Cell {
public:
  /*! \name Static Cell constructors, used only for "well-known" atomic cells (nil, true, false etc).
    
    In general, it is best not to do anything complex at static construction time.  There is no guarantee that dependencies will be ready.
    In particular, use of the terminal may cause the system to crash.
    Most applications should leave any construction activities to more purposeful code at runtime, using only cells obtained through *cons*.
  */
  ///@{
  Cell() {}
  
  Cell(Word_t typ, Word_t  w1, Word_t  w2)	{ type(typ);  rplaca(w1);  rplacd(w2); }
  Cell(Word_t typ, Sexpr_t w1, Sexpr_t w2)	{ type(typ);  rplaca((Word_t) w1);  rplacd((Word_t) w2); }
  ///@}

  /*! \name Cell type enumeration

| Note the following properties of this enumeration:                                                                             |
|--------------------------------------------------------------------------------------------------------------------------------|
| NIL is a singleton, in the middle of the enumeration.                                                                          |
| Types <= NIL are atoms.                                                                                                        |
| Types >= NIL are lists.                                                                                                        |
| Types >  NIL are pairs.                                                                                                        |
| Types <= T_PORT_HEAP are heap-allocated objects, requiring specialized finalizing but not specialized marking.                 |
| Types <= T_ANY_HEAP_SVEC are heap allocated vectors requiring specialized marking in addition to finalizing.                   |
| For Scheme purposes, there is one `pair` type, but there are several other specialized `pair` types that facilitate execution. |
| These additional `pair` types are *atoms*, but list operations such as `car`, `cdr`, and `append` can operate on them.         |

  */
  //!@{
  enum {
    //Complex atoms first
    T_SVEC_HEAP=0,	//!<(LL_int32 Sexpr_t[])	A vector of Sexprs is a (len Sexpr_t*) pair.
    T_SVEC2N_HEAP,	//!<(LL_int32 Sexpr_t[]) 	Same as vector, but length must be a power of 2; useful for hash tables.
    
    T_ANY_HEAP_SVEC = T_SVEC2N_HEAP,	//!<Any types less than or equal to this are heap-stored vectors of S-expressions.  They need specialized marking at GC time.
    
    T_SYM_HEAP,		//!<(LL_int32 Charst_t)	Symbol is a (hash char*) pair.
    T_BVEC_HEAP,	//!<(LL_int32 Bytest_t)	Bytevector is a (len byte*) pair.
    T_BIGNUM,		//!<(LL_int32 Bytest_t) Arbitrary-precision integer; same layout as T_BVEC_HEAP: car=byte-length, cdr=ptr to payload [sign_nlimbs int32][limb0 LL_int32]...
    T_STR_HEAP,		//!<(reserved Charst_t)	The reserved field may be used in future to store the string length (not possible with immediate strings, so some details to be worked).
    T_CPP_HEAP,		//!<(ptr-to-cpp-deleter ptr-to-cpp-object)   Deleter is a function ```void f(void *cpp_obj)``` of the appropriate type T of the C++ object, and performs ```delete (T *) cpp_obj;```

    T_PORT_HEAP,	//!<(reserved  Ptr_t)	car is unused, cdr is ptr to underlying C++ port instance
    T_NEEDS_FINALIZING = T_PORT_HEAP,	//!<Any types less than or equal to this have data stored in the heap, and need specialized finalizing at GC time.
    
    T_BVEC_EXT,		//!<(LL_int32 Bytest_t)	Same as T_BYTEVEC but externally allocated; the byte array is not freed at GC time.
    T_STR_EXT,		//!<(reserved Charst_t)	Same as T_STR but externally allocated; the character array is not freed at GC time.

    T_BVEC_IMM,		//!<Special format: type and flag bytes as usual, byte 2 is vector length, remaining bytes are vector elements.
    T_STR_IMM,		//!<Special format: type and flag bytes as usual, remaining bytes are 0-terminated string embedded in the cell.
    T_GENSYM,		//!<Runtime symbol generation with no heap operations.

    //Simple atoms next
    T_BOOL,		//!<(Bool_t reserved)   Boolean atom
    T_CHAR,		//!<(Char_t reserved)   Character atom
    T_INT32,		//!<(LL_int32 reserved)  Exact 32-bit integer; value in car via memcpy(4).
    T_INT64,		//!<(LL_int64 wide)      Exact 64-bit integer; 8-byte value at &car (spans car+cdr on ESP32).  GC-safe: type < T_NIL.
    T_FLOAT32,		//!<(LL_float32 reserved)    Inexact 32-bit LL_float32; value in car via memcpy(4).
    T_FLOAT64,		//!<(LL_float64 wide)       Inexact 64-bit LL_float32; 8-byte value at &car (spans car+cdr on ESP32).  GC-safe: type < T_NIL.
    T_COMPLEX,		//!<(LL_float32 LL_float32) Complex number atom; car=real part (LL_float32), cdr=imaginary part (LL_float32).  GC atom: car/cdr not traversed as pointers.
    T_RATIONAL,		//!<(LL_int32 LL_int32) Exact rational atom; car=numerator, cdr=denominator (always >= 2, always GCD-reduced).  GC atom.
    //Interface atoms to C++ functions.  No garbage collection finalization required.
    T_MOP3_PROC,	//!<(reserved *Mop3st_t)	pointer to native function - args are evaluated before calling
    T_MOP3_NPROC,	//!<(reserved *Mop3st_t)	pointer to native macro processor - args are not evaluated before calling

    //T_VOID and T_UNDEF are singletons
    T_VOID,		//!<(don't care) VOID has its own type and a singleton instance OBJ_VOID
    T_UNDEF,		//!<(ERROR ERROR) UNDEF has its own type and a singleton instance OBJ_UNDEF

    /*!
      - The NIL singleton is both a list and an atom, but not a pair.
      - Types <= T_NIL are atoms, types >= T_NIL are lists, types > T_NIL are pairs, but only T_PAIR responds to the Scheme *pair?* predicate.
    */
    T_NIL,		//!<(ERROR ERROR) NIL has its own type and a singleton instance.

    /*!
      - Pair types.  Types > NIL and types >= T_PAIR are pairs, but only T_PAIR responds to Scheme (pair?).
      - All pair types can be garbage collected without type-specific GC marking or finalizing.
    */
    T_PAIR,		//!<(Sexpr_t Sexpr_t) Normal untyped cons cell.  All C++ types < T_PAIR are atoms.
    T_SVEC_IMM,		//!<(Sexpr_t Sexpr_t) Vector of 0, 1 or 2 elements.
    T_PROC,		//!<(Sexpr_t Sexpr_t) Procedure pair; car is lambda (formals + body containing free variables), cdr is environment.
    T_NPROC,		//!<(Sexpr_t Sexpr_t) Non-evaluating procedure pair; car is nlambda (formals + body containing free variables), cdr is environment.
    T_MACRO,		//!<(Sexpr_t Sexpr_t) Macro; car is transformer (proc of 1 arg) and cdr is env.
    T_DICT,		//!<(Sexpr_t Sexpr_t) Dictionary pair; car is local frame, cdr is list of parent frames, used for environments & object instances.
    T_THUNK_SEXPR,	//!<(Sexpr_t Sexpr_t) S-expression thunk pair; car is sexpr, cdr is environment with all variable bindings.
    T_THUNK_BODY,	//!<(Sexpr_t Sexpr_t) Code body thunk pair; car is body (i.e., list of sexprs), cdr is environment with all variable bindings.
    T_ERROR,		//!<(Sexpr_t Sexpr_t) An error cell; car is a T_STRING, cdr is a pointer to *irritants*.
    T_VALUES,		//!<(Sexpr_t Sexpr_t) Multiple return values; car is first value, cdr is list of remaining values.
    T_BYTECODE,		//!<(Sexpr_t Sexpr_t) Compiled bytecode procedure; car is T_SVEC_HEAP[bvec,arity,maxloc,maxstk,const...], cdr is closure env.
    T_BYTECODE_N,	//!<(Sexpr_t Sexpr_t) Compiled bytecode nlambda (non-evaluating); same layout as T_BYTECODE, but caller does NOT evaluate arguments.
    T_IDENT,		//!<(Sexpr_t Sexpr_t) Explicit-renaming identifier (syntactic closure over ONE id): car=symbol, cdr=definition-env. Pair-region type (GC-traversed as a pair). Made by `rename`; free refs resolve in cdr (referential transparency), bound occurrences alpha-rename via gensym. No wraps/marks/substs.

    Ntypes	//!<Number of LambLisp virtual machine types
  };
  //!@}
  
  //! \name Cell flags, including gc states for multi-pass incremental gc, tail marker, and spares.
  ///@{
  static const int F_GC01 = 0x01;	//!<gc flag
  static const int F_GC02 = 0x02;	//!<gc flag
  static const int F_GC04 = 0x04;	//!<gc flag
  static const int F_TAIL = 0x08;	//!<trampoline tail marker
  static const int F_CAR_WT0 = 0x10;	//!<T_PAIR car word-type bit 0 (see WordType enum; bits[5:4] = car word-type)
  static const int F_CAR_WT1 = 0x20;	//!<T_PAIR car word-type bit 1 (Wt_float32 has bit 1 set, bit 0 clear)
  static const int F_CDR_WT0 = 0x40;	//!<T_PAIR cdr word-type bit 0 (bits[7:6] = cdr word-type)
  static const int F_CDR_WT1 = 0x80;	//!<T_PAIR cdr word-type bit 1 (Wt_float32 has bit 1 set, bit 0 clear)
  static const int GC_STATE_MASK  = F_GC01 | F_GC02 | F_GC04;	//!<Mask for obtaining garbage collection state bits from Cell flag byte.
  enum WordType { Wt_ptr=0, Wt_int32=1, Wt_float32=2, Wt_reserved=3 };  //!<word-type encoding for car/cdr fields of T_PAIR cells.
  ///@}
  
  /*! \name Low-level cell field manipulation.

    Note that the type field occupies all of byte 0, although not all bits are required.
    This speeds up the very common type-checking operation, because no mask is required to extract the type bits.
    
    The flags are in byte 1, and a mask operation is required to access the individual flag fields.
  */
  //!@{
#define _type_		(_contents._byte[0])
#define _flags_		(_contents._byte[1])
#define _car_		(_contents._word[1])
#define _cdr_		(_contents._word[2])
#define _car_addr_	(&(_car_))
#define _int_ptr_	((LL_int32 *) _car_addr_)
#define _real_ptr_	((LL_float32 *) _car_addr_)
#define _byte2_ptr_	(&(_contents._byte[2]))

  void  zero()			{ _contents._word[0] = _contents._word[1] = _contents._word[2] = 0; }	//!<Set all cell bits to zero.
  LL_int32 type(void)		{ return _type_; }	//!<Return the type of the cell as a small integer.
  void  type(LL_int32 t)		{ _type_  = t; }	//!<Set the type of this cell.

  LL_int32 flags(void)		{ return _flags_; }	//!<Return the entire set of cell flags.
  void  flags_set(LL_int32 f)	{ _flags_ |= f; }	//!<Set the selected flags.
  void  flags_clr(LL_int32 f)	{ _flags_ &= ~f; }	//!<Clear the selected flags.

  void  rplaca(Word_t p)	{ _car_ = p; }		//!<Replace the cell car field.  Called rplaca for historical reasons, and to distinguish it from set-car!, which must respect the GC flags.
  void  rplacd(Word_t p)	{ _cdr_ = p; }		//!<Replace the cell cdr field.  Called rplacd for historical reasons, and to distinguish it from set-cdr!, which must respect the GC flags.
  //!@}

  /*! \name Cell type testing

    The cell type enumeration has been designed to group together cell types according to their most common operations.
    
    The main groups are those needing special sweep and finalizing during garbage collection, those that are treated as pairs, and simple atoms.
    There is a subgroup of those needing special sweep, that also need specialised marking during the garbage collection mark phase.

    There are some types that have optimized subtypes (such as **immediate** types), and they differ in their processing at GC time.
    Type-testing functions below have `is_any_x()` predicates that group all subtypes together (e.g., `is_any_str_atom()` returns **true** for any type of string (heap, immediate, external).
    There are also functions further down that will return the contents of complex cells, and throw an error if called with incorrect type.
    Therefore it is often not necessary to use the predicates before accessing the atom internals with `any_x_get_info()`.

    Note also: it is sometimes faster to check the types directly, rather than check the cell feature table.
    Preliminary testing indicates more than 2 type tests should use the table instead.
  */
  //!@{

  typedef struct {
    LL_int32 typ;
    bool is_any_pair, is_any_svec, is_any_svec2n, is_any_str, is_any_sym, is_any_bvec;
    const char *type_name;
  } CellFeatures;
  
  static const CellFeatures features[Ntypes];

  void init_static_data();
  
  Bool_t is_atom(void)			{ return _type_ <= T_NIL; }				//!<Return true if the cell is an atom.
  Bool_t is_pair(void)			{ return _type_ == T_PAIR; }				//!<Return true if the cell is a cons pair.
  Bool_t is_ident(void)			{ return _type_ == T_IDENT; }				//!<Return true if the cell is an ER renamed identifier (T_IDENT).

  //Note sometimes faster to check the features, other times faster to check the type directly.  For 3 checks the feature table wins, but for 2 it is not always obvious.
  Bool_t is_any_pair(void)		{ return _type_ > T_NIL; }						//!<Return true if the cell is any pair type.
  Bool_t is_any_svec_atom()		{ return features[_type_].is_any_svec; }				//!<Return true if the cell is any kind of Sexpr_t vector.
  Bool_t is_any_svec2n_atom()		{ return (_type_ == T_SVEC2N_HEAP) || (_type_ == T_SVEC_IMM); }		//!<Return true if the cell is Sexpr_t vector of size 2^n.
  Bool_t is_any_str_atom(void)		{ return features[_type_].is_any_str; }					//!<Return true if the cell is any kind of string.
  Bool_t is_any_sym_atom(void)		{ return (_type_ == T_SYM_HEAP) || (_type_ == T_GENSYM); }		//!<Return true if the cell is any kind of symbol
  Bool_t is_any_bvec_atom(void)		{ return features[_type_].is_any_bvec; }				//!<Return true if the cell is any kind of bytevector.
  Bool_t is_any_int(void)		{ return _type_ == T_INT32 || _type_ == T_INT64 || _type_ == T_BIGNUM; }  //!<Return true if the cell is any exact integer type (T_INT32, T_INT64, or T_BIGNUM).
  Bool_t is_bignum(void)		{ return _type_ == T_BIGNUM; }                                            //!<Return true if the cell is T_BIGNUM.
  Bool_t is_any_real(void)		{ return _type_ == T_FLOAT32 || _type_ == T_FLOAT64; }			//!<Return true if the cell is any inexact real type (T_FLOAT32 or T_FLOAT64).

  //! @name word-type accessors — meaningful for T_PAIR cells only.
  //!@{
  int car_word_type()  const  { return (_flags_ >> 4) & 3; }					//!<Car word-type: 0=ptr 1=int32 2=float32 3=reserved.
  int cdr_word_type()  const  { return (_flags_ >> 6) & 3; }					//!<Cdr word-type: 0=ptr 1=int32 2=float32 3=reserved.
  bool car_is_ptr()     const  { return car_word_type() == Wt_ptr; }				//!<True when car word holds a Cell pointer.
  bool cdr_is_ptr()     const  { return cdr_word_type() == Wt_ptr; }				//!<True when cdr word holds a Cell pointer.
  bool car_is_embedded() const  { return (_flags_ & (F_CAR_WT0 | F_CAR_WT1)) != 0; }		//!<True when car holds an embedded int32 or float32 (single bitwise op).
  bool cdr_is_embedded() const  { return (_flags_ & (F_CDR_WT0 | F_CDR_WT1)) != 0; }		//!<True when cdr holds an embedded int32 or float32 (single bitwise op).
  bool is_any_embedded() const  { return (_flags_ & 0xF0) != 0; }				//!<True when car or cdr holds an embedded value; single bitwise op on flags byte.
  LL_int32    car_int32()   const  { return (LL_int32)    _car_; }				//!<Car word as signed int32 (valid when car_word_type()==Wt_int32).
  LL_float32  car_float32() const  { return *(LL_float32*) &_car_; }				//!<Car word as float32 (valid when car_word_type()==Wt_float32).
  LL_int32    cdr_int32()   const  { return (LL_int32)    _cdr_; }				//!<Cdr word as signed int32 (valid when cdr_word_type()==Wt_int32).
  LL_float32  cdr_float32() const  { return *(LL_float32*) &_cdr_; }				//!<Cdr word as float32 (valid when cdr_word_type()==Wt_float32).
  //!@}

  //!@}

  /*! @name Flag testing & setting for garbage collection and tail recursion.

    The garbage collection algorithm is based on the *tricolor abstraction* described in *Dijkstra  1978*.
    The original set of 3 colors was enlarged to 4 with *Kung and Song 1977*, with their correctness proof of the incremental GC algorithm.
    In LambLisp, is is useful to have a fifth state, and to think of the state or color as a stage in the Cell life cycle.
    When GC is in progress, Cells may advance in their life cycle, but may also be moved back to an earlier gc state as the result of an assignment.
    This enumeration allows some tests to be combined in an inequality rather than a sequence of equality tests or a C `switch`.

    *LambLisp* uses a **trampoline technique** to implement tail recursion.
    The **tail** of a series of expressions is the last one evaluated; this is the expression that will return the value of the series.

    In the *trampoline*, instead of evaluating the last expression in the series and returning the value (as in C/C++),
    the expression is returned unevaluated, with the **tail flag** set.
    The evaluator checks every result to see if it is a *tail* that needs additional evaluation, or is a final result to be returned.

    This removes the need for an additional stack frame during recursion.
   */
  //!@{
  enum { gcst_idle, gcst_issued, gcst_stacked, gcst_marked, gcst_free, Ngcstates };
  
  LL_int32   gc_state(void)	{ return _flags_ & GC_STATE_MASK; }							//!<Return the garbage collection stat eof this cell.
  Sexpr_t gc_state(LL_int32 st)	{ _flags_ =  (_flags_ & ~GC_STATE_MASK) | (st & GC_STATE_MASK);  return this; }		//!<Set the garbage collection state of this cell, and return the cell.
  LL_int32   tail_state(void)	{ return _flags_ & F_TAIL; }								//!<Return the taill state of this cell.
  Sexpr_t tail_state_set(void)	{ _flags_ |=  F_TAIL;  return this; }							//!<Set the tail state flag on this cell, and return the cell.
  Sexpr_t tail_state_clr(void)	{ _flags_ &= ~F_TAIL;  return this; }							//!<Clear the tail state flag on this cell, and return the cell.

  static const int F_BC_VARIADIC = 0x01;         //!< byte 2 bit 0: final locals slot holds rest-arg list (T_BYTECODE only).
  bool bytecode_is_variadic() const               { return (_contents._byte[2] & F_BC_VARIADIC) != 0; }  //!< Ph9: true if T_BYTECODE with rest-arg.
  void bytecode_set_variadic()                    { _contents._byte[2] |= F_BC_VARIADIC; }               //!< Ph9: mark T_BYTECODE as variadic.
  //!@}
  
  //! @name Cell value extractors, dependent on Cell type.
  //!@{
  Ptr_t  get_car_addr()		{ return _car_addr_; }			//!<Return the address of the cell car.
  Word_t get_car(void)		{ return _car_; }			//!<Return the value of the cell car.
  Word_t get_cdr(void)		{ return _cdr_; }			//!<Return the value of the cell cdr.

  Bool_t  as_Bool_t()     { return (Bool_t) _car_; }						//!<Return the value of this cell as a boolean.
  Char_t  as_Char_t()     { return (Char_t) _car_; }						//!<Return the value of this cell as a character.
  ll_codepoint_t as_codepoint() { return (ll_codepoint_t) _car_; }  //!< Return full Unicode codepoint stored in T_CHAR cell.
  LL_int32   as_int32()   const { return (LL_int32)    _car_; }				//!<T_INT32 cell value.
  LL_int64   as_int64()   const { return *(LL_int64*)   &_car_; }			//!<T_INT64 cell value; spans car+cdr on ESP32.
  LL_float32 as_float32() const { return *(LL_float32*) &_car_; }			//!<T_FLOAT32 cell value.
  LL_float64 as_float64() const { return *(LL_float64*) &_car_; }			//!<T_FLOAT64 cell value; spans car+cdr on ESP32.

  Ptr_t     as_Ptr_t()		{ return (Ptr_t)     _cdr_; }		//!<Return the value of this cell as a generic pointer (i.e., void*).
  Charst_t  as_Charst_t()	{ return (Charst_t)  as_Ptr_t(); }	//!<Return the value of this cell as a pointer to a zero-terminated character array.
  Bytest_t  as_Bytest_t()	{ return (Bytest_t)  as_Ptr_t(); }	//!<Return the value of this cell as a pointer to an array of bytes.
  CharVec_t as_CharVec_t()	{ return (CharVec_t) as_Ptr_t(); }	//!<Return the value of this cell as a pointer to a zero-terminated character array.
  ByteVec_t as_ByteVec_t()	{ return (ByteVec_t) as_Ptr_t(); }	//!<Return the value of this cell as a pointer to an array of bytes.
  Portst_t  as_Portst_t()	{ return (Portst_t)  as_Ptr_t(); }	//!<Return the value of this cell as a pointer to an instance of the system underlying "port" implementation.
  
  //!@}

  /*! @name Cell hash value

    Hashing is used extensively throughout *LambLisp*.  Each Cell has a hash value, calculated as follows:
    - If the Cell is a symbol, the Cell's hash value is the hash value of the symbol.
    - Otherwise, the address of the Cell is hashed, and that is the result.
    
  */
  //!@{
  LL_int32 hash_sexpr(void);	//!<For symbols, the hash of its characters; for numbers,  the hash of the number; otherwise the hash of the S-expression itself (i.e., the address of a cell).
  LL_int32 hash_contents(void);	//!<For symbols, the hash of its characters; for numbers, strings, vectors, and bytevectors, the hash of the contents; otherwise the hash of the S-expression itself.
  LL_int32 hash(void)	{ return (type() == T_SYM_HEAP) ? prechecked_sym_heap_get_hash() : hash_sexpr(); }	//!<Return the hash value of this cell.
  //!@}
  
  //! @name Cell setters converting the C types into S-expressions.
  //!@{
  Sexpr_t set(LL_int32 typ, Word_t w1, Word_t w2)	{ _type_ = typ;  _car_ = w1;  _cdr_ = w2;  return this; }			//!<This is the lowest-level generic "set" function.
  Sexpr_t set(LL_int32 typ, LL_int32 a,   Sexpr_t b)	{ _type_ = typ;  _car_ = (Word_t) a;  _cdr_ = (Word_t) b;  return this; }	//!<Convenience: car is a raw (sign-extended) int32.  ATOMS only -- never a pair type (a pair car must be a full pointer; see the Word_t/Sexpr_t overload below, added for B182).
  Sexpr_t set(LL_int32 typ, Word_t a, Sexpr_t b)	{ _type_ = typ;  _car_ = a;           _cdr_ = (Word_t) b;  return this; }	//!<B182: a (Word_t,Sexpr_t) call formerly resolved to the (LL_int32,Sexpr_t) overload and SIGN-TRUNCATED the car (e.g. expand()'s `set(T_PAIR,(Word_t)NIL,free_list_head)` stored (LL_int32)NIL).  This full-width overload wins that resolution.
  Sexpr_t set(LL_int32 typ, Sexpr_t a, Sexpr_t b)	{ _type_ = typ;  _car_ = (Word_t) a;  _cdr_ = (Word_t) b;  return this; }	//!<This is a convenience function for common cases.
  
  Sexpr_t set(Bool_t b)				{ return set(T_BOOL, (Word_t) b, (Word_t) 0); }				//!<Set cell as boolean
  Sexpr_t set(Char_t c)				{ return set(T_CHAR, (Word_t) c, (Word_t) 0); }				//!<Set cell as character
  Sexpr_t set(LL_int32 i)			{ _type_ = T_INT32;   _car_ = _cdr_ = 0; memcpy(&_car_, &i, 4); return this; }	//!<Set cell as T_INT32
  Sexpr_t set(LL_int64 v)			{ _type_ = T_INT64;   _car_ = _cdr_ = 0; memcpy(&_car_, &v, 8); return this; }	//!<Set cell as T_INT64 (8 bytes at &car; spans cdr on ESP32)
  Sexpr_t set(LL_float32 r)			{ _type_ = T_FLOAT32; _car_ = _cdr_ = 0; memcpy(&_car_, &r, 4); return this; }	//!<Set cell as T_FLOAT32
  Sexpr_t set(LL_float64 d)			{ _type_ = T_FLOAT64; _car_ = _cdr_ = 0; memcpy(&_car_, &d, 8); return this; }	//!<Set cell as T_FLOAT64 (8 bytes at &car; spans cdr on ESP32)
  Sexpr_t set(LL_float32 r, LL_float32 i)	{ _type_ = T_COMPLEX; memcpy(&_car_, &r, 4); memcpy(&_cdr_, &i, 4); return this; }	//!<Set cell as T_COMPLEX (single precision)
  LL_float32   cpx_real() const			{ return *(LL_float32*) &_car_; }						//!<Real part of a T_COMPLEX cell.
  LL_float32   cpx_imag() const			{ return *(LL_float32*) &_cdr_; }						//!<Imaginary part of a T_COMPLEX cell.
  // ── T_RATIONAL: P70 per-slot P23 word-type components ────────────────────────────────────────
  // car=numerator, cdr=denominator; each slot is either an EMBEDDED int32 (Wt_int32, common small
  // case, no allocation, not GC-scanned) or a Wt_ptr to a boxed exact integer (T_INT32/T_INT64/
  // T_BIGNUM).  A component that overflows int32 boxes to T_INT64 then T_BIGNUM (int widening ladder)
  // -- no float64 fallback, so rationals stay exact.  as_numerator/as_denominator read a component as
  // int64 (valid unless it is a boxed T_BIGNUM -- guard with rat_is_big() first).
  Sexpr_t set(LL_int32 num, LL_int32 den) {
    _type_ = T_RATIONAL; _car_ = _cdr_ = 0; memcpy(&_car_, &num, 4); memcpy(&_cdr_, &den, 4);
    _flags_ = (_flags_ & 0x0F) | F_CAR_WT0 | F_CDR_WT0;   //!< both slots Wt_int32 (preserve gc_state/F_TAIL)
    return this;
  }
  void rat_set_car_i32(LL_int32 v) { _car_ = 0; memcpy(&_car_, &v, 4); _flags_ = (_flags_ & ~(F_CAR_WT0|F_CAR_WT1)) | F_CAR_WT0; }  //!< embedded int32 numerator (Wt_int32)
  void rat_set_car_ptr(Sexpr_t p)  { _car_ = (Word_t) p;              _flags_ =  _flags_ & ~(F_CAR_WT0|F_CAR_WT1);              }  //!< boxed-int numerator ptr (Wt_ptr)
  void rat_set_cdr_i32(LL_int32 v) { _cdr_ = 0; memcpy(&_cdr_, &v, 4); _flags_ = (_flags_ & ~(F_CDR_WT0|F_CDR_WT1)) | F_CDR_WT0; }  //!< embedded int32 denominator (Wt_int32)
  void rat_set_cdr_ptr(Sexpr_t p)  { _cdr_ = (Word_t) p;              _flags_ =  _flags_ & ~(F_CDR_WT0|F_CDR_WT1);              }  //!< boxed-int denominator ptr (Wt_ptr)
  LL_int64 int_as_i64() const { return _type_ == T_INT64 ? as_int64() : (LL_int64) as_int32(); }   //!< value of a boxed T_INT32/T_INT64 (NOT T_BIGNUM)
  Sexpr_t rat_car_ptr() const { return (Sexpr_t) _car_; }   //!< boxed numerator cell   (valid when car_word_type()==Wt_ptr)
  Sexpr_t rat_cdr_ptr() const { return (Sexpr_t) _cdr_; }   //!< boxed denominator cell (valid when cdr_word_type()==Wt_ptr)
  bool rat_car_big() const { return car_word_type() == Wt_ptr && ((Cell*) _car_)->type() == T_BIGNUM; }
  bool rat_cdr_big() const { return cdr_word_type() == Wt_ptr && ((Cell*) _cdr_)->type() == T_BIGNUM; }
  bool rat_is_big()   const { return _type_ == T_RATIONAL && (rat_car_big() || rat_cdr_big()); }   //!< a component is a T_BIGNUM
  bool exact_is_big() const { return _type_ == T_BIGNUM || rat_is_big(); }                          //!< does not fit the int64 fast path
  LL_int64 as_numerator() const   { return car_word_type() == Wt_int32 ? (LL_int64) car_int32() : ((const Cell*) _car_)->int_as_i64(); }  //!<Numerator as int64 (guard rat_is_big()).
  LL_int64 as_denominator() const { return cdr_word_type() == Wt_int32 ? (LL_int64) cdr_int32() : ((const Cell*) _cdr_)->int_as_i64(); }  //!<Denominator as int64 (guard rat_is_big()).
  //! Sign (-1/0/+1) of any exact number; for a rational, the numerator's sign (denominator is positive).
  int exact_sign() {
    switch (_type_) {
      case T_INT32:  { LL_int32 v = as_int32(); return v > 0 ? 1 : v < 0 ? -1 : 0; }
      case T_INT64:  { LL_int64 v = as_int64(); return v > 0 ? 1 : v < 0 ? -1 : 0; }
      case T_BIGNUM: { const int32_t *pay = (const int32_t *) as_ByteVec_t(); int n = pay[0] & 0x7fffffff; return n == 0 ? 0 : (((uint32_t) pay[0]) >> 31 ? -1 : 1); }
      case T_RATIONAL:
        if (car_word_type() == Wt_int32) { LL_int32 v = car_int32(); return v > 0 ? 1 : v < 0 ? -1 : 0; }
        return ((Cell*) _car_)->exact_sign();
      default: return 0;
    }
  }
  Sexpr_t set(Port_t &p)			{ return set(T_PORT_HEAP, (Word_t) 0, (Word_t) &p); }	//!<Set cell as port
  //Sexpr_t set(Sexpr_t a, Sexpr_t b)		{ return set(T_PAIR, a, b); }				//!<Set cell as pair
  
  Sexpr_t set(LL_int32 typ, LL_int32 a, Charst_t b)	{ return set(typ, (Word_t) a, (Word_t) b); }	//!<Set cell as a immutable string
  Sexpr_t set(LL_int32 typ, LL_int32 a, Bytest_t b)	{ return set(typ, (Word_t) a, (Word_t) b); }	//!<Set cell as a immutable bytevector
  Sexpr_t set(LL_int32 typ, LL_int32 a, CharVec_t b)	{ return set(typ, (Word_t) a, (Word_t) b); }	//!<Set cell as a mutable string 
  Sexpr_t set(LL_int32 typ, LL_int32 a, ByteVec_t b)	{ return set(typ, (Word_t) a, (Word_t) b); }	//!<Set cell as a mutable bytevector
  //!@}
  
  Sexpr_t mk_error(const char *fmt, ...) CHECKPRINTF_pos2;			//!<Fills and returns the single Cell-level T_ERROR object.
  Sexpr_t mk_error(Sexpr_t irritants, const char *fmt, ...) CHECKPRINTF_pos3;	//!<Fills and returns the single Cell-level T_ERROR object.
  
  /*! @name Accessors for use when the type is known.
    
    If the cell type is already known, then these accessors can be used to efficiently access the cell contents.
  */
  //!@{
  Sexpr_t   prechecked_anypair_get_car()		{ return (Sexpr_t) get_car(); }
  Sexpr_t   prechecked_anypair_get_cdr()		{ return (Sexpr_t) get_cdr(); }
  
  LL_int32     prechecked_sym_heap_get_hash()				{ return as_int32(); }
  Charst_t  prechecked_sym_heap_get_chars()				{ return (Charst_t) as_Ptr_t(); }
  void      prechecked_sym_heap_get_info(LL_int32 &hsh, Charst_t &chars)	{ hsh = as_int32();  chars = (Charst_t) as_Ptr_t(); }

  CharVec_t prechecked_str_heap_get_chars()				{ return as_CharVec_t(); }		//!<Return a pointer to the character array in the heap.
  CharVec_t prechecked_str_ext_get_chars()				{ return as_CharVec_t(); }		//!<Return a pointer to the character array located outside the heap.
  CharVec_t prechecked_str_imm_get_chars()				{ return (CharVec_t) _byte2_ptr_; }	//!<Return a pointer to the character array embedded in this cell.

  void      prechecked_bvec_imm_set_length(LL_int32 l)			{ _contents._byte[2] = l; }
  
  Charst_t  prechecked_gensym_get_chars()				{ return str().c_str(); }
  void      prechecked_gensym_get_info(LL_int32 &hsh, Charst_t &chars)	{ hsh = as_int32();  chars = prechecked_gensym_get_chars(); }
  
  Sexpr_t   prechecked_error_get_irritants()				{ return (Sexpr_t) get_cdr(); }
  Sexpr_t   prechecked_error_get_str()					{ return (Sexpr_t) get_car(); }
  Charst_t  prechecked_error_get_chars()				{ return prechecked_error_get_str()->any_str_get_chars(); }
  //! @}

  /*! @name Accessors for use when the cell type is unverified.
    The **any** and **mustbe** accessors will perform type checking and throw an error if an improper access is attempted.
    The **coerce** operators will perform C coercion on its operand if possible, otherwise throw an error.
  */
#define THROW_BAD_TYPE { throw mk_error("%s Bad type %s", me, dump().c_str()); }
  //!@{
  Bool_t  mustbe_Bool_t()	{ ME("Cell::mustbe_Bool_t()");     if (type() == T_BOOL)    return as_Bool_t();    THROW_BAD_TYPE; }	//!<Return the value of this cell as a boolean.
  Char_t  mustbe_Char_t()	{ ME("Cell::mustbe_Char_t()");     if (type() == T_CHAR)    return as_Char_t();    THROW_BAD_TYPE; }	//!<Return the value of this cell as a character.
  ll_codepoint_t mustbe_codepoint() { ME("Cell::mustbe_codepoint()"); if (type() == T_CHAR) return as_codepoint(); THROW_BAD_TYPE; }  //!< Return full codepoint; throw if not T_CHAR.
  LL_int32 mustbe_int32()	{ ME("Cell::mustbe_int32()");    if (type() == T_INT32)   return as_int32();  THROW_BAD_TYPE; }	//!<Return the value of this T_INT32 cell as int32.
  LL_float32  mustbe_float32()	{ ME("Cell::mustbe_float32()");     if (type() == T_FLOAT32)  return as_float32();   THROW_BAD_TYPE; }	//!<Return the value of this T_FLOAT32 cell as a real.

  Sexpr_t mustbe_any_str_t()	{ ME("Cell::mustbe_any_str_t()"); if (is_any_str_atom()) return this;        THROW_BAD_TYPE; }		//!<Return this cell if it is a string.
  Sexpr_t mustbe_cppobj_t()	{ ME("Cell::mustbe_cppobj_t()");  if (type() == T_CPP_HEAP) return this;     THROW_BAD_TYPE; }		//!<Return this cell if it is a CPP object.

  CPPDeleterPtr prechecked_cppobj_get_deleter()		{ return (CPPDeleterPtr) _car_; }	//!<Return the function to be called at garbage collection time to recycle the C++ object.
  Ptr_t prechecked_cppobj_get_ptr()			{ return as_Ptr_t(); }			//!<Return a pointer to a C++ object obtained earlier.

  CPPDeleterPtr any_cppobj_get_deleter()		{ return mustbe_cppobj_t()->prechecked_cppobj_get_deleter(); }
  Ptr_t any_cppobj_get_ptr()				{ return mustbe_cppobj_t()->prechecked_cppobj_get_ptr(); }
  void any_cppobj_get_info(CPPDeleterPtr &d, Ptr_t &p)	{ Sexpr_t o = mustbe_cppobj_t();  d = o->prechecked_cppobj_get_deleter();  p = o->prechecked_cppobj_get_ptr(); }

  LL_float32 coerce_float32()	//!<Coerce any numeric cell to float32 (lossy for INT64/FLOAT64).
  {
    ME("Cell::coerce_float32()");
    LL_int32 typ = type();
    if (typ == T_FLOAT32)   return as_float32();
    else if (typ == T_INT32)    return (LL_float32) as_int32();
    else if (typ == T_INT64)    return (LL_float32) as_int64();
    else if (typ == T_FLOAT64)  return (LL_float32) as_float64();
    else if (typ == T_RATIONAL) {   //!< P70: a component may be a boxed bignum -> coerce it via the boxed cell
      LL_float64 n = (car_word_type() == Wt_int32) ? (LL_float64) car_int32() : ((Cell*) _car_)->coerce_float64();
      LL_float64 d = (cdr_word_type() == Wt_int32) ? (LL_float64) cdr_int32() : ((Cell*) _cdr_)->coerce_float64();
      return (LL_float32) (n / d);
    }
    else if (typ == T_BIGNUM)   return (LL_float32) coerce_float64();
    else if (typ == T_CHAR)     return (LL_float32) as_codepoint();
    THROW_BAD_TYPE;
  }

  LL_float64 coerce_float64()	//!<Coerce any numeric cell to LL_float64 (lossless for all except RATIONAL/BIGNUM).
  {
    ME("Cell::coerce_float64()");
    LL_int32 typ = type();
    if (typ == T_FLOAT64)   return as_float64();
    else if (typ == T_FLOAT32)  return (LL_float64) as_float32();
    else if (typ == T_INT32)    return (LL_float64) as_int32();
    else if (typ == T_INT64)    return (LL_float64) as_int64();
    else if (typ == T_RATIONAL) {   //!< P70: a component may be a boxed bignum -> coerce it via the boxed cell
      LL_float64 n = (car_word_type() == Wt_int32) ? (LL_float64) car_int32() : ((Cell*) _car_)->coerce_float64();
      LL_float64 d = (cdr_word_type() == Wt_int32) ? (LL_float64) cdr_int32() : ((Cell*) _cdr_)->coerce_float64();
      return n / d;
    }
    else if (typ == T_BIGNUM) {
      // limb-by-limb: payload = [int32 sign_nlimbs][LL_int32 limb0 ... limbN-1], little-endian.
      const int32_t *pay   = (const int32_t *) as_ByteVec_t();
      int            n     = (int)(pay[0] & 0x7fffffff);
      int            neg   = (int)((uint32_t) pay[0] >> 31);
      const LL_int32 *limbs = (const LL_int32 *)(pay + 1);
      LL_float64 r = 0.0;
      for (int i = n - 1; i >= 0; i--)
        r = r * 4294967296.0 + (LL_float64)(uint32_t) limbs[i];
      return neg ? -r : r;
    }
    THROW_BAD_TYPE;
  }

  LL_int32 coerce_int32()		//!<Coerce any numeric cell to int32 (truncates LL_float32/int64).
  {
    ME("Cell::coerce_int32()");
    LL_int32 typ = type();
    if (typ == T_INT32)   return as_int32();
    else if (typ == T_INT64)   return (LL_int32) as_int64();
    else if (typ == T_FLOAT32) return (LL_int32) as_float32();
    else if (typ == T_FLOAT64) return (LL_int32) as_float64();
    else if (typ == T_RATIONAL) return (LL_int32) ((LL_float32) as_numerator() / (LL_float32) as_denominator());
    else if (typ == T_CHAR)    return (LL_int32) as_codepoint();
    THROW_BAD_TYPE;
  }

  LL_int64 coerce_int64()		//!<Coerce any numeric cell to int64 (truncates float).
  {
    ME("Cell::coerce_int64()");
    LL_int32 typ = type();
    if (typ == T_INT64)   return as_int64();
    else if (typ == T_INT32)   return (LL_int64) as_int32();
    else if (typ == T_FLOAT32) return (LL_int64) as_float32();
    else if (typ == T_FLOAT64) return (LL_int64) as_float64();
    else if (typ == T_RATIONAL) return (LL_int64) ((LL_float64) as_numerator() / (LL_float64) as_denominator());
    THROW_BAD_TYPE;
  }

  //! Exact numeric rank: 0=T_INT32  1=T_INT64  2=T_RATIONAL  3=T_BIGNUM  -1=not exact.
  int exact_rank() const { switch (_type_) { case T_INT32: return 0; case T_INT64: return 1; case T_RATIONAL: return 2; case T_BIGNUM: return 3; default: return -1; } }
  //! Inexact numeric rank: 0=T_FLOAT32  1=T_FLOAT64  2=T_COMPLEX  -1=not inexact.
  int inexact_rank() const { switch (_type_) { case T_FLOAT32: return 0; case T_FLOAT64: return 1; case T_COMPLEX: return 2; default: return -1; } }
  bool is_exact()   const { return exact_rank() >= 0; }    //!< True for T_INT32, T_INT64, T_RATIONAL, T_BIGNUM.
  bool is_inexact() const { return inexact_rank() >= 0; }  //!< True for T_FLOAT32, T_FLOAT64, T_COMPLEX.
  bool is_complex() const { return _type_ == T_COMPLEX; }  //!< True iff T_COMPLEX.
  //! Legacy scalar rank: 0=int  1=float  2=rational  3=complex  -1=non-numeric.
  int num_rank() const {
    switch (_type_) {
    case T_INT32: case T_INT64: case T_BIGNUM: return 0;
    case T_FLOAT32: case T_FLOAT64:            return 1;
    case T_RATIONAL:                           return 2;
    case T_COMPLEX:                            return 3;
    default:                                   return -1;
    }
  }
  LL_int64 numerator64()   const { if (_type_ == T_RATIONAL) return (LL_int64) as_numerator(); if (_type_ == T_INT64) return as_int64(); return (LL_int64) as_int32(); }  //!< Numerator of any exact number as LL_int64.
  LL_int64 denominator64() const { return _type_ == T_RATIONAL ? (LL_int64) as_denominator() : (LL_int64) 1; }  //!< Denominator of any exact number as LL_int64 (1 for integer types).
  LL_float64 coerce_cpx_real() { return _type_ == T_COMPLEX ? (LL_float64) cpx_real() : coerce_float64(); }  //!< Real part: T_COMPLEX → cpx_real; others → coerce_float64.
  LL_float64 coerce_cpx_imag() { return _type_ == T_COMPLEX ? (LL_float64) cpx_imag() : 0.0; }               //!< Imaginary part: T_COMPLEX → cpx_imag; others → 0.

  Sexpr_t   error_get_str()		{ ME("Cell::error_get_str()");        if (_type_ == T_ERROR) return prechecked_error_get_str(); THROW_BAD_TYPE; }
  Sexpr_t   error_get_irritants()	{ ME("Cell::error_get_irritants()");  if (_type_ == T_ERROR) return prechecked_error_get_irritants(); THROW_BAD_TYPE; }
  Charst_t  error_get_chars()		{ ME("Cell::error_get_chars()");      if (_type_ == T_ERROR) return prechecked_error_get_chars(); THROW_BAD_TYPE; }
  //! any_error_get_*: like error_get_* but the T_ERROR typecheck is folded in and a non-error yields
  //! a benign sentinel (NIL) instead of throwing -- lets a predicate write o->any_error_get_irritants()
  //! without a separate type() guard (less source, no missed-check bug).
  Sexpr_t   any_error_get_str()		{ return (_type_ == T_ERROR) ? prechecked_error_get_str()       : NIL; }
  Sexpr_t   any_error_get_irritants()	{ return (_type_ == T_ERROR) ? prechecked_error_get_irritants() : NIL; }

  LL_int32 any_sym_get_hash()		{ ME("any_sym_get_hash()");	      if (is_any_sym_atom()) return as_int32(); THROW_BAD_TYPE; }
  
  Charst_t any_sym_get_chars() {
    ME("Cell::any_sym_get_chars()");
    if (_type_ == T_SYM_HEAP) return prechecked_sym_heap_get_chars();
    else if (_type_ == T_GENSYM) return prechecked_gensym_get_chars();
    else THROW_BAD_TYPE;
  }
  
  void any_sym_get_info(LL_int32 &hsh, Charst_t &chars) {
    ME("Cell::any_sym_get_info()");
    if (_type_ == T_SYM_HEAP) prechecked_sym_heap_get_info(hsh, chars);
    else if (_type_ == T_GENSYM) prechecked_gensym_get_info(hsh, chars);
    else THROW_BAD_TYPE;
  }
  
  //!@}

  /*! @name Operations on strings

    LambLisp supports several subtypes of **strings**.  At the time of writing, there are heap-allocated strings (read-write),
    strings whose characters outside of LambLisp's managed memory, (aka external or EXT strings),
    and short **immediate** strings that are contained completely within a single cell.
    Additional subtypes (such as load-on-demand strings) may be added in future.
  
    There are functions of the form any_xxx() that can be used with any subtype, and there are type-specific functions of the form
    any_xxx_yyy() for use where the type is already known, with yyy being a code hint.
  */
  //!@{
  
  //!If the cell is any kind of string, return a pointer to the zero-terminated character array.
  CharVec_t any_str_get_chars() {
    ME("Cell::anystring_get_chars()");
    if (_type_ == T_STR_IMM) return prechecked_str_imm_get_chars();
    else if (_type_ == T_STR_HEAP) return prechecked_str_heap_get_chars();
    else if (_type_ == T_STR_EXT) return prechecked_str_ext_get_chars();
    else THROW_BAD_TYPE;
  }

  LL_int32 any_str_get_length()				{ return strlen(any_str_get_chars()); }
  void any_str_get_info(LL_int32 &len, CharVec_t &chars)	{ len = strlen(chars = any_str_get_chars()); }
  //!@}

  /*! \name Operations on vectors and sub-types of vectors

    Within the LambLisp virtual machine, a *Lisp vector* is referred to as *svec*.  This is an array of S-expressions having a fixed dimension.
    There are also *bytevectors*; these are an array of bytes, also of fixed dimension.
    
    As with *strings*, there are several subtypes of S-expression vectors.
    There is a heap-allocated vector, which may be of any size.
    There is a second type of heap-allocated vector, that is always sized to be a power of 2.  These are provided to support efficient hash tables.
    There are immediate vectors, which may be of 0, 1, or 2 elements.
    The 2-element immediate vector can also be used as a hash table.
    This can reduce search time by half without requiring any heap allocation, at the cost of 1 extra cell allocation.

    Bytevectors are also diverse, having heap, external, and immediate variants.
    Heap bytevectors are allocated, obviously, on the system heap, and the heap space is freed when the bytevector is garbage-collected.

    External bytevectors operate on bytes provided externally to LambLisp's memory manager.
    This space may have been dynamically allocated from outside LambLisp, or may be located in read-only memory.
    When a C++ object os injected into *LambLisp*, it can optionally be provided with a garbage collector callback;
    in that case the external object can be automatically garbage collected when no it's longer used in the *Lisp* program.

    Immediate bytevectors are contained within a LambLisp Cell.  The maximum size is limited by the word size of the underlying platform.
    
    Within the *LambLisp* virtual machine, there are generic functions of the form any_xvec_xxx() that can operate on any xvec (svec or bvec) subtype,
    as well as type-specific functions of the form xvec_yyy_xxx(), where yyy is a code hint for the cell storage type (heap, immediate, ROM).
  */
  
  //!@{
  void any_svec_get_info(LL_int32 &Nelems, Sexpr_t *&elems) {
    ME("Cell::any_svec_get_info()");
    LL_int32 typ = _type_;
    if (typ <= T_SVEC2N_HEAP) {
      Nelems = as_int32();
      elems  = (Sexpr_t *) as_Ptr_t();
    }
    else if (typ == T_SVEC_IMM) {	//could be 0, 1 or 2 elems
      Nelems = 2;	//assume
      if (prechecked_anypair_get_cdr() == OBJ_NOSLOT) Nelems--;	//!<B196: NOT OBJ_VOID -- that is a real value
      if (prechecked_anypair_get_car() == OBJ_NOSLOT) Nelems--;
      elems  = (Sexpr_t *) _car_addr_;
    }
    else THROW_BAD_TYPE;
  }

  Sexpr_t *any_svec_get_elems()
  {
    ME("Cell::any_svec_get_elems()");
    Sexpr_t *res = 0;
    LL_int32 typ    = _type_;

    if (typ <= T_SVEC2N_HEAP) res = (Sexpr_t *) as_Ptr_t();
    else if (typ == T_SVEC_IMM) res  = (Sexpr_t *) _car_addr_;
    else THROW_BAD_TYPE;

    return res;
  }
  
  LL_int32 any_bvec_get_length()
  {
    ME("Cell::any_bvec_get_length()");
    LL_int32 Nelems = -1;
    if (_type_ == T_BVEC_IMM) {
      ByteVec_t b = (ByteVec_t) _byte2_ptr_;
      Nelems = b[0];
    }
    else if ((_type_ == T_BVEC_HEAP) || (_type_ == T_BVEC_EXT) || (_type_ == T_BIGNUM)) Nelems = as_int32();
    else THROW_BAD_TYPE;

    return Nelems;
  }
  
  ByteVec_t any_bvec_get_elems()
  {
    ME("Cell::any_bvec_get_elems()");
    ByteVec_t res = 0;
    if (_type_ == T_BVEC_IMM) {
      ByteVec_t b = (ByteVec_t) _byte2_ptr_;
      res = (ByteVec_t) &(b[1]);
    }
    else if ((_type_ == T_BVEC_HEAP) || (_type_ == T_BVEC_EXT) || (_type_ == T_BIGNUM)) res  = as_ByteVec_t();
    else THROW_BAD_TYPE;
    return res;
  }

  void any_bvec_get_info(LL_int32 &Nelems, ByteVec_t &elems)
  {
    ME("Cell::any_bvec_get_info()");
    if (_type_ == T_BVEC_IMM) {
      ByteVec_t b = (ByteVec_t) _byte2_ptr_;
      Nelems      = b[0];
      elems       = (ByteVec_t) &(b[1]);
    }
    else if ((_type_ == T_BVEC_HEAP) || (_type_ == T_BVEC_EXT) || (_type_ == T_BIGNUM)) {
      Nelems = as_int32();
      elems  = as_ByteVec_t();
    }
    else THROW_BAD_TYPE;
  }

  LL_int32  bvec_elem_type(void) const { return _contents._byte[3]; }			//!<Typed-vector element type tag stored in Cell byte 3 (valid for all bvec subtypes).
  void      bvec_set_elem_type(LL_int32 t) { _contents._byte[3] = (Byte_t)t; }		//!<Set the typed-vector element type tag in Cell byte 3.
  //!@}
    
#undef THROW_BAD_TYPE
#undef _type_
#undef _flags_
#undef _car_
#undef _cdr_
#undef _car_addr_
#undef _int_ptr_
#undef _real_ptr_
#undef _byte2_ptr_
    
  /*! @name Cell conversions to printable representation
    
    These functions convert a Cell (or parts of a Cell) to a printable representation of the S-expression contents of the Cell.
    Because environments are often included in the descendants of the Cell being printed, the depth of environment recursiveness is limited.
  */
  //!@{
  String   cell_name(void);		//!<A convenience feature to produce a string name for cells which are "well known" like NIL.  Otherwise the name is the hex representation of the cell address.

  Charst_t type_name(LL_int32 typ);	//!<Return a pointer to the C string corresponding to the cell type.
  Charst_t type_name(void) { return type_name(this->type()); }
  Charst_t gcstate_name(void);		//!<Return a pointer to a C string corresponding to the given GC state.

  String dump();			//!<Return a printable representation of the Cell internals.

  // P138: the recursive core takes an external DatumLabels table (nullptr => Simple/legacy tree print).
  String str(Sexpr_t sx, Bool_t as_write_or_display, DatumLabels *lbl, LL_int32 max_depth);
  // Legacy 4-arg form kept for source compat: env_depth is now ignored (environments print via labels + max_depth backstop).
  String str(Sexpr_t sx, Bool_t as_write_or_display, LL_int32 env_depth, LL_int32 max_depth)	{ (void) env_depth; return str(sx, as_write_or_display, (DatumLabels *) 0, max_depth); }
  String str(Bool_t as_write_or_display, LL_int32 env_depth, LL_int32 max_depth)	{ (void) env_depth; return str(this, as_write_or_display, (DatumLabels *) 0, max_depth); }
  String str(Bool_t as_write_or_display, LL_int32 env_depth)			{ (void) env_depth; return str(this, as_write_or_display, (DatumLabels *) 0, 10); }
  String str(Bool_t as_write_or_display)					{ return str(this, as_write_or_display, (DatumLabels *) 0, 10); }
  String str(LL_int32 env_depth) 							{ (void) env_depth; return str(this, true, (DatumLabels *) 0, 10); }
  String str(void)								{ return str(this, true, (DatumLabels *) 0, 10); }
  //!@}
  
private:
  union {
    Byte_t _byte[3 * sizeof(Word_t)];
    Word_t _word[3];
  } _contents;

};

static_assert(sizeof(Cell) == 3*sizeof(Word_t), "Cell size != 3*Word_t size\n");
static_assert(sizeof(Cell) == 3*sizeof(Ptr_t),  "Cell size != 3*Ptr_t size\n");

//! @name The LambLisp VM can accept S-expression generated externally, evaluate them, and produce the result as an S-expression.
//!@{
extern Sexpr_t LAMB_INPUT;	//!<If the variable is non-NIL, LambLisp will evaluate it and put the results in LAMB_OUTPUT;
extern Sexpr_t LAMB_OUTPUT;	//!<The result of evaluating LAMB_INPUT is placed here.
//!@}

class LambMemoryManager;
struct NcgFrame;       //!< Forward decl; defined in ll_vm_ncg.h

/*! Exception-escape context set up by ncg_eval/ncg_eval_argv so that C++ shims
 *  called FROM JIT code can longjmp rather than throw through the JIT frame.
 *  JIT frames have no DWARF unwind info; uncaught C++ exceptions propagating
 *  through them call std::terminate().  The longjmp skips the JIT frame entirely
 *  and returns control to the setjmp site in ncg_eval, which then re-throws.
 */
struct NcgErrJmp {
  jmp_buf  jmpbuf;    //!< longjmp target; set by ncg_eval before calling fn(lamb,fp)
  Sexpr_t  error;     //!< exception value stored by ncg_err_longjmp before longjmp
  LL_int32 gc_depth;  //!< gc_root_depth() saved before fn(); restored in setjmp handler
};

/*! \class Lamb
  
  The Lamb class represents a single Lisp virtual machine.
  To closely match the Arduino-style of loop-based control, LambLisp provides begin(), loop(), and end().

  To initialize the LambLisp VM, begin() should be called once before any other call.  Generally LambLisp loop() will be called one time for every main loop(), but it is not necessary.
  If end() is called, all LambLisp resources are freed; Lamb::setup() can be called again to restart that LambLisp VM.

  The LambLisp VM functions are grouped this way:
  - Logging functions
  - Build and version informational functions.
  - Cell constructors, getters & setters
  - Base data structures for the interpreter: alist, hash tables, and environments, along with their getters & setters.
  - Printers
  - Partial evaluation and application
  - Port access from *Lisp*
  - Vector, list, and dictionary utilities, used internally and also available in *Lisp*.
  - GC interface functions to protect critical sections.
  - Bindings
  - Makers
*/

//! LL_CALL_MOP3 -- invoke a mop3 C function DIRECTLY (bypassing apply_proc_partial) while still
//! honoring the mop3 GC contract, INLINED at the call site with zero call overhead.  That contract
//! (documented at the mop3 GC rule and in ll_vm_mop3_er.cpp / _syntax_rules.cpp / _quasiquote.cpp):
//! a mop3 body assumes its argument LIST and env are ALREADY ROOTED for the whole call and protects
//! only its own locally-built temps.  `apply_proc_partial` provides that with ll_gc_protect3(proc,
//! args, env); a caller that reaches the mop3 WITHOUT apply must reproduce it or the collector sweeps
//! the freshly-consed arg spine mid-call and the mop3 reads a freed cell -- B43 (a trivial builtin
//! like abs/append throwing "not a number"/bad-type).  A comment cannot enforce the contract; this
//! macro does -- route EVERY direct mop3 call through it (bytecode-VM fast path, eval fast path, NCG
//! call shims, argv fast-path fallbacks) so no site can silently omit the rooting again (exactly how
//! B43 recurred: the fix landed at some sites and was missed at others).
//! Exception-safe by the same mechanism as before: apply_proc_partial/eval/the NCG shims restore
//! gc_root depth on throw, so the two pushes are reclaimed even if `func` throws before the pop.
//! Statement-expression (gnu++17) yielding the mop3 result as an rvalue; args/env/lambref are each
//! evaluated EXACTLY ONCE (bound to locals), so a side-effecting arg expression -- e.g.
//! argv_to_list(...) -- is safe.  `lambref` is a Lamb& (pass `*lamb` at pointer call sites).
#define LL_CALL_MOP3(lambref, func, args, env) __extension__({ \
    Lamb   &_llcm_l = (lambref);                               \
    Sexpr_t _llcm_a = (args);                                  \
    Sexpr_t _llcm_e = (env);                                   \
    _llcm_l.gc_root_push(_llcm_a);                             \
    _llcm_l.gc_root_push(_llcm_e);                             \
    Sexpr_t _llcm_r = (func)(_llcm_l, _llcm_a, _llcm_e);       \
    _llcm_l.gc_root_pop(2);                                    \
    _llcm_r; })

class Lamb {
public:

  Lamb();
  
  /*!This is a pointer to a C++ native function that interacts directly with the S-expression in the given environment.
    Every LambLisp native function shares this signature.
    New external functions that conform to this signature can be used from within LambLisp and will run at full speed.
   */
  typedef Sexpr_t (*Mop3st_t)(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec);
  typedef Sexpr_t (*Mop3st_argv_t)(Lamb &lamb, Sexpr_t *argv, int nargs, Sexpr_t env_exec); //!< direct-argv calling convention; argv[0..nargs-1] are already-evaluated args.
  //!< GC CONTRACT for argv variants: the caller (apply_fast1/2_argv, ncg) passes a C-array `argv` that
  //!< is NOT on the root stack, so a variant MUST read every argv[i] it needs into a local BEFORE its
  //!< first allocation (arg cells are otherwise unrooted and can be swept mid-call -- B43).  To build a
  //!< Scheme list from argv, use argv_to_list(), which roots all elements for the build.

  //! @name Arduino-compatible loop-based control interface.
  //!@{
  Sexpr_t setup(void);	//!<Run once after base platform has started.  In particular, *Serial* should be initialized before calling setup().
  Sexpr_t loop(void);	//!<Run often to maintain control.  The main responsibility of C++ Lamb::loop() is to call the LambLisp function of the same name (loop).
  void end(void);	//!<Reset roots and force a full collection.  NOTE: despite the name this
			//!<does NOT release anything -- the pool, the blocks and the payloads all stay.
			//!<Use the destructor for real teardown.
  ~Lamb();		//!<Real teardown: finalize every cell, free the blocks and the memory
			//!<manager.  Pairs with `new Lamb` + setup().  Written 2026-08-24; before
			//!<that the class had no destructor at all and nothing ever tore an
			//!<instance down, so the leaks below had never been exercised.
  //!@}

  //! @name A few foundational functions for embedded debugging.
  //!@{
  void log(const char *fmt, ...) CHECKPRINTF_pos2;	//!<C-level printf feature with a limit on the length of strings produced.  Takes care of log prompt.
  void printf(const char *fmt, ...) CHECKPRINTF_pos2;	//!<C-level printf feature with a limit on the length of strings produced.
  bool debug(void);					//!<Return the state of the Lamb internal debug flag.
  void debug(bool onoff);				//!<Set the state of the Lamb debug flag.
  //!@}

  //! @name Information about the current build.
  //!@{
  bool build_isDebug();			//!<Return true if this build is not checked in.  This is unrelated to the runtime `debug` flag.
  unsigned long build_version();	//!<Return the build version as a long integer (implemented as a UTC time stamp).
  unsigned long build_UTC();		//!<Return the UTC time of this build.
  unsigned long build_pushUTC();	//!<Return the UTC time this repo was last pushed.
  const char *build_buildRelease();	//!<Return a pointer to a character array containing the release description.
  const char *build_buildDate();	//!<Return a pointer to a character array containing the build date.
  const char *build_pushDate();		//!<Return a pointer to a character array containing the date this repo was last pushed.
  //@}

  /*! \name Cell constructors
    
    Garbage collection may happen at any time during the execution of the Cell constructors.
    The cell constructors that accept S-expression arguments will protect those arguments from GC during the operation, using the gc root push/pop functions.
  */
  //!@{
  void expand();							//!<Add another block of cells to the population.
  Sexpr_t tcons(LL_int32 typ, Word_t a,  Word_t  b, Sexpr_t env_exec);	//!<Generic cell constructor with no GC protection for its arguments.
  Sexpr_t tcons(LL_int32 typ, Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);	//!<Constructor for any pair type; protects both S-expression arguments.

  Sexpr_t cons(Sexpr_t a,  Sexpr_t b, Sexpr_t env_exec)	{ return tcons(Cell::T_PAIR, a, b, env_exec); }	//!<Cell constructor for normal pairs.

  void  gc_root_push(Sexpr_t p);	//!<Preserve the cell given from GC, until popped.
  void  gc_root_pop(LL_int32 n=1);		//!<Release the preserved cells for normal GC processing.
  LL_int32 gc_root_depth();		//!<Return current rootstack depth (save before a try block).
  void  gc_root_setdepth(LL_int32 n);	//!<Restore rootstack to saved depth, discarding entries above n (call in catch to drop orphaned roots without disturbing the caller's entries).
  void  gc_idle_task_us(LL_int32 us, Sexpr_t env_exec);  //!<Run GC for up to us microseconds of spare time; bank extra quanta as credit to skip during later allocations.
  void  gc_collect(Sexpr_t env_exec);                    //!<Run one complete GC cycle (mark + sweep); leaves heap in idle phase with all unreachable cells freed.
  LL_int32 gc_Qm() const;               //!< return current mark quantum size.
  void gc_pass_n(LL_int32 nsteps);      //!< run nsteps mark steps; no-op if not in marking phase.

  // ── P6 LambSettings accessors (delegate to LambMemoryManager) ────────────
  LL_int32 mem_cell_block_size();
  LL_int32 mem_n_cell_blocks();
  LL_int32 mem_total_cells();
  LL_int32 mem_ngc();
  LL_int32 mem_markstack_grows();
  LL_int32 mem_urgent_calls();
  LL_int32 mem_urgent_max_us();
  void     mem_diag_quiet(Bool_t q);
  LL_int32 mem_startmark_max_us();
  LL_int32 mem_startmark_nroots();
  LL_int32 mem_extraroots_max_us();
  LL_int32 mem_extraroots_pushes();
  LL_int32 mem_nfree();
  LL_int32 mem_extension_block_size();
  void     mem_set_extension_block_size(LL_int32 sz);
  void     mem_expand_to_n_blocks(LL_int32 n, Sexpr_t env_exec);
  LL_int32 mem_max_cell_blocks();
  void     mem_set_max_cell_blocks(LL_int32 n);
  LL_int32 mem_gc_budget_ns();
  LL_int32 mem_dbg_urgent_max_us();
  LL_int32 mem_dbg_urgent_calls();
  unsigned long mem_dbg_t_gc_total_us();   //!< monotonic total us in gc_pass -- measured GC load
  LL_int32 mem_dbg_amax();
  LL_int32 mem_dbg_live_marked();
  unsigned long mem_dbg_n_idle();
  unsigned long mem_dbg_n_work();
  LL_int32 mem_dbg_t_mark_ns();
  LL_int32 mem_dbg_t_sweep_ns();
  LL_int32 mem_dbg_mark_q();
  LL_int32 mem_dbg_sweep_q();
  LL_int32 mem_dbg_yuasa_M();
  LL_int32 mem_dbg_yuasa_N();
  void     mem_set_gc_budget_ns(LL_int32 ns);
  LL_int32 mem_gcload_target_pct();
  void     mem_set_gcload_target_pct(LL_int32 pct);
  LL_int32 verbosity()              { return _verbosity; }
  void     set_verbosity(LL_int32 v){ _verbosity = v; }

  //! Quiet REPL mode: suppress the per-char redisplay prompt reprint and the "Input:" echo.
  //! NOT platform-specific despite its old home -- the terminal reaches the platform only through
  //! LambStdio (LL_Term::get_input_serial/get_output_serial both return it), and the flag's readers
  //! are the REPL echo in ll_vm_lamb.cpp and the (quiet)/(verbose) procs.  Declared HERE, defined in
  //! ll_vm_term.cpp beside the ll_term singleton that stores it: a shipped ll_xmop3_*.cpp must be
  //! able to set it WITHOUT including a stripped ll_vm_* header, which is what made every customer
  //! package unbuildable from source (2026-08-26).
  void     set_repl_quiet(bool q);
  bool     repl_quiet(void) const;
  LL_int32 ncg_frame_pool_n()      { return ncg_frame_pool_count; }  //!< Frames currently in the free-list pool.
  void     ncg_frame_pool_init(LL_int32 n);  //!< Allocate n frames and push them onto the pool free list.
  //!@}
  
  //! @name A subset of the car/cdr accessors for list cells.  This is the subset used within LambLisp.
  //!@{
  Sexpr_t car(Sexpr_t l);					//!<Return the first element (*car*) of a pair cell; throws if `l` is not a pair type.
  Sexpr_t cdr(Sexpr_t l);					//!<Return the second element (*cdr*) of a pair cell; throws if `l` is not a pair type.
  Sexpr_t prechecked_anypair_get_car(Sexpr_t c);		//!<Car of a known pair; handles embedded int32/float32; no type check.
  Sexpr_t prechecked_anypair_get_cdr(Sexpr_t c);		//!<Cdr of a known pair; handles embedded int32/float32; no type check.
  Sexpr_t caar(Sexpr_t l)	{ return car(car(l)); }		//!<Composition: `car(car(l))`.
  Sexpr_t cadr(Sexpr_t l)	{ return car(cdr(l)); }		//!<Composition: `car(cdr(l))`; returns the second element of a list.
  Sexpr_t cdar(Sexpr_t l)	{ return cdr(car(l)); }		//!<Composition: `cdr(car(l))`.
  Sexpr_t cddr(Sexpr_t l)	{ return cdr(cdr(l)); }		//!<Composition: `cdr(cdr(l))`.
  Sexpr_t caddr(Sexpr_t l)	{ return car(cddr(l)); }	//!<Composition: `car(cdr(cdr(l)))`; returns the third element of a list.
  Sexpr_t cdddr(Sexpr_t l)	{ return cdr(cddr(l)); }	//!<Composition: `cdr(cdr(cdr(l)))`.
  Sexpr_t cadddr(Sexpr_t l)	{ return car(cdddr(l)); }	//!<Composition: `car(cdr(cdr(cdr(l))))`; returns the fourth element of a list.
  Sexpr_t cddddr(Sexpr_t l)	{ return cdr(cdddr(l)); }	//!<Composition: `cdr(cdr(cdr(cdr(l))))`.
  //!@}
  
  //! @name The "bang" functions are the "mutators" of GC literature.
  //!@{
  void set_car_bang(Sexpr_t c, Sexpr_t val);			//!<Replace the car field in the cell with *val*.  GC flags will be maintained as required.
  void set_cdr_bang(Sexpr_t c, Sexpr_t val);			//!<Replace the cdr field in the cell with *val*.  GC flags will be maintained as required.
  void vector_set_bang(Sexpr_t vec, LL_int32 k, Sexpr_t val);	//!<Replace the specified vector element with *val*.  GC flags will be maintained as required.
  Sexpr_t reverse_bang(Sexpr_t l);				//!<Reverse the list in-place and return the new list head (the former list tail).
  Sexpr_t bulk_alloc_pairs(LL_int32 n, Sexpr_t env_exec);	//!<Grab n free T_PAIR cells atomically; mark gcst_issued during mark/sweep; return NIL-terminated chain.
  //!@}
  
  //! @name Equivalence tests and sequential search
  //!@{
  Sexpr_t eq_q(Sexpr_t obj1, Sexpr_t obj2);	//!<Return true if 2 cells are the same cell, or are atoms with the same value.
  Sexpr_t eqv_q(Sexpr_t obj1, Sexpr_t obj2);	//!<Return true if 1 cells are the same cell, or are atoms with the same value.
  Sexpr_t equal_q(Sexpr_t obj1, Sexpr_t obj2);	//!<Returns true when obj1 and obj2 are eqv?, and also all their descendants.
  Sexpr_t assq(Sexpr_t obj, Sexpr_t alist);	//!<Search an association list for a matching key, and return the `(key . value)` pair, or **false** if not found.
  //!@}

  /*!
    \name Interned symbols

    There are just a few operations on symbols:
    - Remember a new symbol.
    - Check if symbol has already been seen.
    - Compare 2 symbols for equality.
    - At evaluation time, lookup the symbol in the *current environment*.

    For best performance, symbols in LambLisp are *interned*.
    This means a single copy of the symbol's characters are stored in a data structure containing the set of all *interned symbols*.
    Once interned, symbols can be tested for equality by address rather than character-by-character.
    
    Traditionally, the data structure was called *oblist* if an association list was used, or called *obarray* if an array was used.
    Arrays allow for a hash table implementation, which greatly reduces search time, and can be further optimized if the array size is a power of 2 (2^n).

    LambLisp uses the term *oblist* for the interned symbol table, implemented using a 2^n hash table.
    Symbol hashes are computed only once and are stored with the symbol, speeding runtime lookups.
  */
  
  //!@{
  Sexpr_t oblist_query(Sexpr_t oblist, const char *identifier, Bool_t force, Sexpr_t env_exec);	//!<Look up `identifier` in `oblist`. If `force` is true, intern the symbol (creating it if absent) and return it. If `force` is false, return the existing symbol or `HASHF` if not found.
  Sexpr_t oblist_test(Sexpr_t oblist, const char *identifier, Sexpr_t env_exec)		{ return oblist_query(oblist, identifier, false, env_exec); }	//!<Return the interned symbol for `identifier`, or `HASHF` if not present.
  Sexpr_t oblist_intern(Sexpr_t oblist, const char *identifier, Sexpr_t env_exec)	{ return oblist_query(oblist, identifier, true, env_exec); }	//!<Return the interned symbol for `identifier`, creating it if necessary.
  Sexpr_t oblist_analyze(Sexpr_t oblist, LL_int32 verbosity, Sexpr_t env_exec);		//!<Report statistics on the oblist hash table (load factor, chain lengths, etc.) at the given `verbosity` level. Returns NIL.
  //!@}

  /*! \name Hierarchical Dictionary type
    
    LambLisp's high-performance hierarchical dictionary implementation is used internally to represent the runtime environment.
    Dictionaries are also directly usable in the Lisp applications, and the dictionary data type is the basis for the LambLisp Object System (LOBS).
  */
  //!@{
  Sexpr_t dict_new(LL_int32 framesize, Sexpr_t env_exec)				{ return dict_add_empty_frame(NIL, framesize, env_exec); }	//!<Return a new empty dictionary with the given top frame size.
  Sexpr_t dict_new(Sexpr_t env_exec)						{ return dict_add_empty_frame(NIL, 0, env_exec); }		//!<Return a new empty dictionary with alist top frame.

  /*! Prepend a new empty frame to `dict` and return the extended dictionary.
    Frame storage is chosen by `framesize`: < 4 = alist; 4--7 = 2-slot hash table; >= 8 = heap-allocated hash table of `framesize` slots.
  */
  Sexpr_t dict_add_empty_frame(Sexpr_t dict, LL_int32 framesize, Sexpr_t env_exec);
  Sexpr_t dict_add_empty_frame(Sexpr_t dict, Sexpr_t env_exec)			{ return dict_add_empty_frame(dict, 0, env_exec); }	//!<Returns a new dictionary with an empty alist top frame and `dict` as parent.
  
  Sexpr_t dict_add_keyval_frame(Sexpr_t dict, Sexpr_t keys, Sexpr_t vals, Sexpr_t env_exec);						//!<Returns a new dictionary with a new top frame containing the keys bound to the values.
  Sexpr_t dict_add_keyval_frame_argv(Sexpr_t dict, Sexpr_t keys, Sexpr_t *argv, int nargs, Sexpr_t env_exec);	//!< same as dict_add_keyval_frame but values come from argv[] instead of a cons list.
  Sexpr_t dict_add_vector_frame(Sexpr_t parent, Sexpr_t names, Sexpr_t *vals, int ncaps, Sexpr_t env);          //!< compact kv-vec frame (T_SVEC_IMM for ncaps==1); alist fallback for ncaps>1.
  Sexpr_t dict_add_alist_frame(Sexpr_t dict, Sexpr_t alist, Sexpr_t env_exec)	{ return mk_dict(alist, dict, env_exec); }		//!<Returns a new dictionary with the alist bindings added in a new frame on top of the base dictionary.
  Sexpr_t dict_append_bang(Sexpr_t d1, Sexpr_t d2, Sexpr_t env_exec);			//!<Append d2 as a parwent dictionary of d1.
  void    dict_bind_bang(Sexpr_t dict, Sexpr_t key, Sexpr_t value, Sexpr_t env_exec);       //!<Modify the target dictionary; `value` is re-assigned to `key` wherever first found in chain, else created in the top frame.
  void    dict_bind_local_bang(Sexpr_t dict, Sexpr_t key, Sexpr_t value, Sexpr_t env_exec); //!<Modify only the top frame of dict; update `key` if found there, else create it there. Never walks parent frames. Use for define/define-syntax per R7RS 5.3.2.
  void    dict_rebind_bang(Sexpr_t dict, Sexpr_t key, Sexpr_t value, Sexpr_t env_exec);     //!<Modify the target dictionary; `value` is assigned to `key` wherever first found in env, else error if not found.
  void    dict_bind_alist_bang(Sexpr_t dict, Sexpr_t alist, Sexpr_t env_exec);		//!<Modify the target dictionary; binding keys in the alist to their corresponding values.
  void    dict_rebind_alist_bang(Sexpr_t dict, Sexpr_t alist, Sexpr_t env_exec);	//!<Modify the target dictionary; rebinding keys in the alist to their corresponding values.

  Sexpr_t dict_ref_q(Sexpr_t dict, Sexpr_t key);				//!<Returns (key value) pair, or **false** if key is unbound.
  Sexpr_t dict_ref(Sexpr_t dict, Sexpr_t key);					//!<Returns the value associated with the key in the given dictionary; throws error if key is unbound.

  //!Note that keys and values are guaranteed to return in the corresponding order in dict_keys and dict_values, duplicate keys may occur.
  Sexpr_t dict_keys(Sexpr_t dict, Sexpr_t env_exec);				//!<Return a list of all the keys in this dictionary.  If the dictionary has parents, keys may appear multiple times.
  Sexpr_t dict_values(Sexpr_t dict, Sexpr_t env_exec);				//!<Return a list of all the values in this dictionary.  If the dictionary has parents, values may appear multiple times for each key.
  
  Sexpr_t dict_to_alist(Sexpr_t dict, Sexpr_t env_exec);	//!<Convert the dictionary to an alist, retaining only the top-level `(key . value)` pairs.
  Sexpr_t dict_to_2list(Sexpr_t dict, Sexpr_t env_exec);	//!<Convert the dictionary to a list of 2-element lists, retaining only the top-level `(key value)` sublists.
  Sexpr_t alist_to_dict(Sexpr_t alist, Sexpr_t env_exec);	//!<Convert an alist into a dictionary.  The resulting dictionary has no parent.
  Sexpr_t twolist_to_dict(Sexpr_t twolist, Sexpr_t env_exec);	//!<Convert a list of 2-element lists into a dictionary.  The resulting dictionary has no parent.

  Sexpr_t dict_analyze(Sexpr_t dict, LL_int32 verbosity = 0);	//!<Internal integrity check.
  Sexpr_t integrity_check(Sexpr_t env_exec, LL_int32 verbosity = 1);	//!<GC heap integrity check; callable from mop3.
  //!@}

  //! \name Reading and writing
  //!@{
  Sexpr_t read(LL_Port &src, Sexpr_t env_exec)	{ return read_sexpr(src, env_exec, false); }	//!<Read one S-expression from `src`; returns `OBJ_EOF` at end of input.

  Sexpr_t write_or_display(Sexpr_t sexpr, Bool_t do_write, WriteMode mode = WriteMode::Cyclic);	//!<Write `sexpr` to the current output port. `do_write` true => *write* semantics (strings quoted, chars as `#\\x`); false => *display* (strings/chars as-is). `mode` selects datum-label emission: Cyclic labels nodes on a cycle (default, terminates on cycles), Shared labels all shared nodes, Simple emits no labels. Returns `OBJ_VOID`.
  Sexpr_t write_simple(Sexpr_t sexpr);				//!<Write `sexpr` using *write* semantics without following shared structure. Returns `OBJ_VOID`.

  /*! Format a string from a template and a list of S-expression arguments.
    Format specifiers: `~a` / `~A` inserts the next argument using *display* formatting;
    `~n` or `~%` inserts a newline; `~~` inserts a literal `~`.
    Backslash escapes `\\n` (newline) and `\\\\` (literal backslash) are also recognized.
    Throws if the argument count does not match the format string.
  */
  String  sprintf(Charst_t fmt, Sexpr_t args, Sexpr_t env_exec);

  Sexpr_t printf(Sexpr_t args, LL_Port &outp);	//!<Format and write to `outp`; `args` is `(fmt-string val ...)`. See `sprintf()` for format specifier syntax. Returns `OBJ_VOID`.
  Sexpr_t printf(Sexpr_t args);			//!<Format and write to the current output port; `args` is `(fmt-string val ...)`. See `sprintf()` for format specifier syntax. Returns `OBJ_VOID`.
  //!@}
  
  //! \name Evaluation and function application
  //!@{
  Sexpr_t eval(Sexpr_t sexpr, Sexpr_t env_exec);			//!<Evaluate the S-expression in the environment provided.
  Sexpr_t eval_list(Sexpr_t args, Sexpr_t env_exec);				//!<Evaluate the list of S-expressions in the environment provided, and return a lkist of results.
  Sexpr_t apply_proc_partial(Sexpr_t proc, Sexpr_t sexpr, Sexpr_t env_exec);	//!<Evaluate the function arguments and then apply the function to them.  The result may be a tail requiring further evaluation.
  Sexpr_t map_proc(Sexpr_t proc, Sexpr_t lists, Sexpr_t env_exec);		//!<Apply the procecure to the lists per R5RS.
  //!@}

  //! \name Querying underlying system features defined by Scheme.
  //!@{
  Sexpr_t r5_base_environment()		{ return _r5_base_environment; }
  Sexpr_t r5_interaction_environment()	{ return _r5_interaction_environment; }
  Sexpr_t lamb_oblist()			{ return _lamb_oblist; }
  
  //!< B149: the current in/out/error ports are ordinary global bindings in the base env (which is
  //!< permanently rooted), so the ports are traced like any other binding -- NOT special GC roots.
  //!< These read/write the cached binding cell's cdr (the port value) for O(1) access.
  Sexpr_t current_input_port()		{ return (_r5_cur_in_cell  != NIL) ? (Sexpr_t) _r5_cur_in_cell->get_cdr()  : NIL; }
  Sexpr_t current_output_port()		{ return (_r5_cur_out_cell != NIL) ? (Sexpr_t) _r5_cur_out_cell->get_cdr() : NIL; }
  Sexpr_t current_error_port()		{ return (_r5_cur_err_cell != NIL) ? (Sexpr_t) _r5_cur_err_cell->get_cdr() : NIL; }
  void set_current_input_port(Sexpr_t p)  { if (_r5_cur_in_cell  != NIL) set_cdr_bang(_r5_cur_in_cell,  p); }  //!< for with-input-from-file
  void set_current_output_port(Sexpr_t p) { if (_r5_cur_out_cell != NIL) set_cdr_bang(_r5_cur_out_cell, p); }  //!< for with-output-to-file
  void set_current_error_port(Sexpr_t p)  { if (_r5_cur_err_cell != NIL) set_cdr_bang(_r5_cur_err_cell, p); }

  bool reader_fold_case()		{ return _reader_fold_case; }
  void reader_fold_case_set(bool v)	{ _reader_fold_case = v; }
  //!@}
  
  Sexpr_t load(Charst_t name, Sexpr_t env_exec, LL_int32 verbosity = 0);		//!<Load and evaluate S-expressions from the named file.
  
  //! \name Useful list processing used internally by the LambLisp virtual machine.
  //!@{
  Sexpr_t append(Sexpr_t sexpr, Sexpr_t env_exec);		//!<Concatenate a list of lists per R5RS `append`; the last element may be a non-list, producing an improper list. Returns the concatenated result.
  Sexpr_t append2(Sexpr_t lis, Sexpr_t obj, Sexpr_t env_exec);	//!<Destructively attach *obj* to the end of *lis*, which must be a proper list.
  Sexpr_t list_copy(Sexpr_t sexpr, Sexpr_t env_exec);		//!<Return a shallow copy of the list: new pair cells with the same elements in the same order.
  /*! Traverse `sexpr` using Floyd's cycle-detection algorithm and return a structural description:
    - proper list of length N → integer N
    - improper list (non-NIL terminator) after N pairs → `(improper . N)`
    - circular structure → `#f`
  */
  Sexpr_t list_analyze(Sexpr_t sexpr, Sexpr_t env_exec);
  Sexpr_t list_to_vector(Sexpr_t l, Sexpr_t env_exec);		//!<Convert a proper list to a heap-allocated S-expression vector (`T_SVEC_HEAP`); list order is preserved.
  Sexpr_t vector_to_list(Sexpr_t v, Sexpr_t env_exec);		//!<Convert an S-expression vector to a proper list; element order is preserved.
  Sexpr_t vector_copy(Sexpr_t from, Sexpr_t env_exec);		//!<Return a shallow copy of the S-expression vector `from`.
  //!@}

  /*! \name Sparse vectors
    The sparse vector representation is a sorted association list, in which the car of each pair is the vector index and the cdr is the vector value at that index.
  */
  //!@{
  Sexpr_t vector_to_sparsevec(Sexpr_t vec, Sexpr_t skip, Sexpr_t env_exec);		//!<Convert `vec` to a sorted `(index . value)` alist, omitting elements equal to `skip`.
  Sexpr_t sparsevec_to_vector(Sexpr_t alist, Sexpr_t fill, Sexpr_t env_exec);		//!<Reconstruct a dense vector from a sparse `(index . value)` alist; positions not present in the alist are initialized to `fill`.
  //!@}

  /*! \name Makers for error types
    
    These functions will sprintf a message into a buffer, and return an error object containing the message.
    They differ in that one (mk_error) creates a new error object, and the other (mk_syserror) avoids use of the memory manager by reusing the system error singleton.
  */
  //!@{
  Sexpr_t mk_error(Sexpr_t env_exec, Sexpr_t irritants, const char *fmt, ...) CHECKPRINTF_pos4;	//!<Fill a new error object with the information given, and return it.
  Sexpr_t mk_error(Sexpr_t env_exec, const char *fmt, ...) CHECKPRINTF_pos3;			//!<Fill a new error object with the information given, and return it.  The *irritants* field is left NIL.
  Sexpr_t mk_syserror(const char *fmt, ...) CHECKPRINTF_pos2;					//!<Fill the system error object with the info given, and return it.
  Sexpr_t tag_error(Sexpr_t err, const char *kind);						//!<Tag a fresh T_ERROR with a kind marker in its irritants (e.g. "%file-error"/"%read-error") so file-error?/read-error? can classify it.  Returns err.
  Sexpr_t mk_syserror(Sexpr_t irritants, const char *fmt, ...) CHECKPRINTF_pos3;		//!<Fill the system error object with the info given, and return it.
  //!@}
  
  /*! @name Makers for simple compact types with embedded values, without external storage or dependencies

    These types all have their values embedded in the Cell.
    Note that other types may also hold immediate values, but are "less simple" because they are C++ subtypes that are variations on the *Lisp*-declared types.
  */
  //!@{
  //! Perf: these makers allocate a blank cell then embed the value with ->set(), so the tcons a/b
  //! args are throwaways -- pass (Word_t)0,(Word_t)0 to hit the NON-pushing Word_t tcons overload.
  //! Do NOT change back to `NIL, NIL`: that selects the Sexpr_t overload, whose ll_gc_protect2(a,b)
  //! pushes NIL twice on EVERY mk_int32/float32/... (i.e. every materializing car/cdr) for nothing.
  Sexpr_t gensym(Sexpr_t env_exec);		//!<Produce a new unique symbol.
  Sexpr_t mk_bool(Bool_t b, Sexpr_t env_exec)				{ return b? HASHT : HASHF; }												//!<Return `HASHT` or `HASHF`.
  Sexpr_t mk_character(ll_codepoint_t cp, Sexpr_t env_exec) { return tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec)->set(Cell::T_CHAR, (Word_t)cp, (Word_t)0); }  //!< Allocate a new `T_CHAR` cell holding Unicode codepoint `cp`.
  //! mk_integer: T_INT32 if fits, else T_INT64.  Returns cached cell for [-2048..4096].
  //!
  //! THE DOUBLE WRITE BELOW LOOKS LIKE WASTE.  REMOVING IT DID NOT PAY -- THREE VARIANTS MEASURED.
  //! `tcons(T_PAIR,0,0,env)` initialises the cell as an empty pair and `->set(v)` immediately
  //! overwrites it.  Tried 2026-09-01 with an `alloc_cell()` returning a zeroed UNTYPED cell so the
  //! caller writes it once.  All three were CORRECT (rxrs 443/0, extend 629/0, conform 1337/0, and
  //! numeric spot-checks across int32/int64/float/complex/bignum).  S3 devkit, fib-iter(45) AST,
  //! 3 s window, fresh boot; baseline 17,784 / 17,924 / 17,994 us:
  //!   1. shared allocator, out-of-line   18,384      (+3.4%)
  //!   2. shared allocator, in-class      18,139-18,209 (+2.3%)
  //!   3. DUPLICATED pop, tcons_unguarded BYTE-IDENTICAL   18,135-18,348 (+1.5-2.4%)
  //! Variant 3 is the control: it cannot have touched the cons path, and it lost the same amount.
  //! So the "sharing grew a hot function" story I first wrote is WRONG.  What is left is that the
  //! effect sits at or below the level at which code LAYOUT alone moves this benchmark on this
  //! device -- adding a function perturbs placement, and the baseline itself spans 1.2%.
  //! CONCLUSION: no demonstrable benefit; do not re-attempt without a profile that can separate
  //! layout from mechanism, and measure cons-heavy work on the DEVICE, not on x86.
  Sexpr_t mk_integer(LL_int64 i, Sexpr_t env_exec) {
    if (i >= SINT_CACHE_MIN && i <= SINT_CACHE_MAX) return sint_cache_cells + (LL_int32)(i - SINT_CACHE_MIN);
    if (i >= INT32_MIN && i <= INT32_MAX) return tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec)->set((LL_int32) i);
    return tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec)->set(i);
  }
  Sexpr_t mk_int32(LL_int32 i, Sexpr_t env_exec) {										//!<T_INT32 cell; returns cached cell for small values.
    if (i >= SINT_CACHE_MIN && i <= SINT_CACHE_MAX) return sint_cache_cells + (i - SINT_CACHE_MIN);
    return tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec)->set(i);
  }
  Sexpr_t mk_int64(LL_int64 i, Sexpr_t env_exec)			{ return tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec)->set(i); }					//!<T_INT64 cell (always allocates).
  Sexpr_t mk_float32(LL_float32 r, Sexpr_t env_exec)				{ return tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec)->set(r); }					//!<T_FLOAT32 cell.
  Sexpr_t mk_float64(LL_float64 d, Sexpr_t env_exec)			{ return tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec)->set(d); }					//!<T_FLOAT64 cell.
  Sexpr_t mk_complex(LL_float32 r, LL_float32 i, Sexpr_t env_exec)		{ return tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec)->set(r, i); }					//!<T_COMPLEX cell.
  //! Store an int64 exact value into a rational slot: embedded int32 if it fits, else a boxed T_INT64.
  void rat_store_i64(Sexpr_t c, bool is_num, LL_int64 v, Sexpr_t env_exec) {
    if (v >= (LL_int64) INT32_MIN && v <= (LL_int64) INT32_MAX) {
      if (is_num) c->rat_set_car_i32((LL_int32) v); else c->rat_set_cdr_i32((LL_int32) v);
    } else {
      Sexpr_t b = mk_int64(v, env_exec);                       //!< boxed (issued -> survives; stored immediately)
      if (is_num) c->rat_set_car_ptr(b); else c->rat_set_cdr_ptr(b);
    }
  }
  //! Canonical rational from int64 components: GCD-reduces, normalises sign, returns an integer when
  //! den==1, else a T_RATIONAL whose components box to T_INT64 when they overflow int32 (P70 -- no
  //! float64 fallback, so exactness is preserved).  When LL_RATIONAL=0, always returns inexact float64.
  Sexpr_t mk_rational(LL_int64 num, LL_int64 den, Sexpr_t env_exec) {
    if (den == 0) throw mk_syserror("rational: division by zero");
#if LL_RATIONAL
    if (den < 0) { num = -num; den = -den; }
    LL_int64 a = num < 0 ? -num : num, b = den;
    while (b) { LL_int64 r = a % b; a = b; b = r; }
    if (a > 0) { num /= a; den /= a; }
    if (den == 1) return mk_integer(num, env_exec);
    Sexpr_t c = tcons(Cell::T_PAIR, (Word_t) 0, (Word_t) 0, env_exec);
    c->set((LL_int32) 0, (LL_int32) 1);                        //!< establish T_RATIONAL + Wt_int32 flags
    rat_store_i64(c, true,  num, env_exec);
    rat_store_i64(c, false, den, env_exec);
    return c;
#else
    return mk_float64((LL_float64) num / (LL_float64) den, env_exec);
#endif
  }
#if LL_RATIONAL && LL_BIGNUM
  //! P70/B11 big-rational support (defined in ll_vm_mop3_rational.cpp).  Components may be bignums.
  Sexpr_t mk_rational_big(Sexpr_t num, Sexpr_t den, Sexpr_t env_exec);   //!< reduce+narrow+store exact-integer components
  Sexpr_t rat_num_cell(Sexpr_t x, Sexpr_t env_exec);                     //!< numerator of a rational/integer as a boxed integer cell
  Sexpr_t rat_den_cell(Sexpr_t x, Sexpr_t env_exec);                     //!< denominator (1 for integers) as a boxed integer cell
  void    rat_store_cell(Sexpr_t c, bool is_num, Sexpr_t val);           //!< store a narrowed integer cell into a rational slot
  Sexpr_t rat_big_add2(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);
  Sexpr_t rat_big_sub2(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);
  Sexpr_t rat_big_mul2(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);
  Sexpr_t rat_big_div2(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);
  int     rat_big_cmp2(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);         //!< sign of a-b
  Sexpr_t rat_big_floorlike(Sexpr_t x, int mode, Sexpr_t env_exec);     //!< 0=floor 1=ceiling 2=truncate 3=round(half-even) -> integer
#endif

  Sexpr_t mk_number(Charst_t str, Sexpr_t env_exec);		//!<Parse `str` as a number; returns `T_INT`, `T_REAL`, `T_RATIONAL`, or `T_COMPLEX` as appropriate, or `OBJ_UNDEF` if `str` is not a valid numeric literal.

  Sexpr_t mk_sharp_const(Charst_t name, Sexpr_t env_exec);	//!<Parse a `#`-prefixed constant name (e.g., `"t"`, `"f"`, `"true"`, `"false"`) and return the corresponding singleton; returns `OBJ_UNDEF` if unrecognized.

#if LL_BIGNUM
  // P54.2 — T_BIGNUM methods
  Sexpr_t mk_bignum(int nlimbs, int sign, Sexpr_t env_exec);
  Sexpr_t bignum_normalize(Sexpr_t x, Sexpr_t env_exec);
  Sexpr_t bignum_add(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);
  Sexpr_t bignum_sub(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);
  Sexpr_t bignum_mul(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);
  Sexpr_t bignum_divmod(Sexpr_t a, Sexpr_t b, Sexpr_t *rem, Sexpr_t env_exec);
  Sexpr_t bignum_gcd(Sexpr_t a, Sexpr_t b, Sexpr_t env_exec);
  int     bignum_cmp(Sexpr_t a, Sexpr_t b);
  Sexpr_t bignum_shift(Sexpr_t a, int bits, Sexpr_t env_exec);               //!< magnitude shift (trunc toward 0)
  Sexpr_t bignum_ashift(Sexpr_t n, int bits, Sexpr_t env_exec);              //!< arithmetic shift: right floors (int semantics)
  Sexpr_t bignum_bitwise(Sexpr_t a, Sexpr_t b, char op, Sexpr_t env_exec);   //!< op: '&' '|' '^' (two's-complement)
  Sexpr_t bignum_modexp_sw(Sexpr_t base, Sexpr_t exp, Sexpr_t mod, Sexpr_t env_exec);
  Sexpr_t bignum_to_string(Sexpr_t x, int radix, Sexpr_t env_exec);
  Sexpr_t bignum_from_string(const char *s, int radix, Sexpr_t env_exec);
  Sexpr_t to_bignum(Sexpr_t x, Sexpr_t env_exec);
#endif
  //!@}

  /*! \name Makers for heap storage types

    In principle, these types require space from the system heap.  At GC time, they may also require specialized marking, and also specialized sweeping.

    As an optimization, *LambLisp* also implements **immediate** types.
    When the size required for the object is small, the internal bytes of the Cell can be used to hold the contents, avoiding heap operations.
    Using immediate types in this way has been common practice for integers and real numbers.  LambLisp makes some additional use of immediate types.
    Immediate types are a LambLisp internal optimization,  and they are all subtypes of the main *Lisp* type.

    The types that employ the *immediate* optimization are:
    - strings, providing up to 9 content bytes plus trailing 0 (32 bit word) or 22 content bytes (64 bit).
    - bytevectors a count plus up to 9 or 22 content bytes.
    - vectors of length 0, 1 or 2.

    There are also **EXTERNAL** versions of those data types.
    These data types can be used to access data that should not be garbage collected,
    such as data contained in the application image, or C++ objects provided by another application.

    A variant of the EXTERNAL types is also provided, so that objects created in C++ can be passed to LambLisp,
    along with an optional *deleter function*.
    In C++, the deleter is best implemented as a one-line C++ lambda function accepting 1 argument (a void* pointer to a C++ object).
    The deleter function casts the void* pointer to match the C++ object type, and applies the C++ *delete* or *delete[]* operators to free the object space and any dependent resources.

    By passing the C++ objects to LambLisp, they can be automatically garbage collected when LambLisp has finished with them.
  */
  //!@{
  Sexpr_t mk_string(Sexpr_t env_exec, const char *fmt, ...) CHECKPRINTF_pos3;
  /*! @brief Allocate a bulk PAYLOAD (string/bytevector/vector/bignum/bytecode body) with a DEFINED
      out-of-memory policy, mirroring what gc_urgent() does for cells.

      B129: ll_payload_alloc_bytes() falls back to malloc() when PSRAM is full, and malloc() returns
      NULL -- which every call site then wrote through (memset/memcpy on address 0), producing
      `Guru Meditation Error: StoreProhibited` and a BOOT LOOP that only a reflash cleared.  A
      real-time node must not die that way, and must not die silently.

      Policy, in order:
        1. try the allocation;
        2. on failure run the collector to completion -- payload memory is reclaimed by the SWEEP
           (finalize_one_cell frees the payloads of dead cells), so exhaustion is often transient --
           and retry ONCE;
        3. if it still fails, throw a normal LambLisp error.  It is catchable with `guard`, so an
           application can shed load, and the REPL survives to report it.
      Never returns NULL. */
  void *payload_alloc(size_t nbytes, const char *who, Sexpr_t env_exec);

  Sexpr_t mk_string(LL_int32 k, Charst_t src, Sexpr_t env_exec);
  Sexpr_t mk_string(String s, Sexpr_t env_exec)			{ return mk_string(s.length(), s.c_str(), env_exec); }
  
  Sexpr_t mk_symbol_or_number(Charst_t str, Sexpr_t env_exec);	//!<Try to parse `str` as a number; if that fails, intern it as a symbol. Used by the reader for unquoted tokens.
  Sexpr_t mk_symbol(Charst_t str, Sexpr_t env_exec)		{ return oblist_intern(_lamb_oblist, str, env_exec);  }	//!<Intern `str` in the oblist and return the symbol S-expression. Two calls with identical strings always return the same cell pointer.
  
  Sexpr_t mk_bytevector(LL_int32 k, Sexpr_t env_exec);			//!<Simplest heap allocation with no initialization.
  Sexpr_t mk_bytevector(LL_int32 k, Bytest_t src, Sexpr_t env_exec);	//!<Heap allocation with initialization.
  Sexpr_t mk_bytevector(LL_int32 k, LL_int32 fill, Sexpr_t env_exec);		//!<Heap allocation with initialization.

  //!Injection of externally allocated memory, which will not be freed at GC time.
  Sexpr_t mk_bytevector_ext(LL_int32 k, Bytest_t ext, Sexpr_t env_exec)	{ return tcons(Cell::T_BVEC_EXT, (Word_t) k, (Word_t) ext, env_exec); }  

  //!Note that integer vectors and real vectors are just bytevectors underneath.
  Sexpr_t mk_intvector(LL_int32 k, Sexpr_t env_exec);		//!<Allocates a bytevector from the heap to ensure proper alignment (no IMM type).
  Sexpr_t mk_realvector(LL_int32 k, Sexpr_t env_exec);		//!<Allocates a bytevector from the heap to ensure proper alignment (no IMM type).
  Sexpr_t mk_intvector(LL_int32 k, LL_int32 fill, Sexpr_t env_exec);
  Sexpr_t mk_realvector(LL_int32 k, LL_float32 fill, Sexpr_t env_exec);

  Sexpr_t mk_vector(LL_int32 len, Sexpr_t fill, Sexpr_t env_exec);		//!<Allocate a `T_SVEC_HEAP` vector of `len` elements, all initialized to `fill`.
  Sexpr_t mk_hashtbl(LL_int32 len, Sexpr_t fill, Sexpr_t env_exec);	//!<Allocate a `T_SVEC2N_HEAP` hash-table vector; actual size is rounded up to the next power of 2, minimum `len` slots, all initialized to `fill`.

  Sexpr_t mk_serial_port(Sexpr_t env_exec);					//!<Wrap the platform serial port (Arduino `Serial` or POSIX stdin/stdout) as a LambLisp port object.
  Sexpr_t mk_input_file_port(Charst_t name, Sexpr_t env_exec);			//!<Open the named filesystem file for reading; return a port. Throws if the file cannot be opened.
  Sexpr_t mk_output_file_port(Charst_t name, Sexpr_t env_exec);			//!<Open the named filesystem file for writing; return a port. Throws if the file cannot be opened.

  /*! @name Network port makers (TCP and TLS)

    These makers are available when `LL_WIFI` (ESP32 WiFi) or `LL_POSIX` (Linux/macOS) is defined.
    They are exposed in the Scheme interaction environment as `open-tcp-client-port`,
    `open-tcp-server-port`, `server-accept`, `open-tls-client-port`, and `open-tls-server-port`.

    All network ports are bidirectional `T_PORT_HEAP` objects and work with the standard R7RS I/O
    procedures (`read`, `write`, `read-char`, `write-string`, `close-port`, etc.).

    The LLIP (LambLisp Interaction Protocol) layer (`llip-server.scm` / `llip-client.scm`)
    is built entirely on top of these primitives.  It speaks a line-oriented S-expression protocol
    over plain TCP (development) or TLS (production).

    Wire protocol summary:
    - Server sends: `(hello "llip/1.0")` on connect.
    - Client sends: `(auth "token")`.  Server replies `(ok)` or closes.
    - Each request is one S-expression per line; response is `(ok ...)` or `(error "msg")`.
    - Supported ops: `ping`, `bye`, `ls`, `stat`, `read`, `write`, `append`,
      `delete`, `rename`, `load`, `eval`.
    - `(bye)` triggers a graceful close; EOF from the client also closes the session.

    @see `data/llip-server.scm` -- Scheme server (load on the target board).
    @see `data/llip-client.scm` -- Scheme client (load on the host or peer board).
    @see `ll_tests/llip-tests.scm` -- integration test suite.
  */
  //!@{
#if LL_WIFI || LL_POSIX
  Sexpr_t mk_tcp_client_port(Charst_t host, unsigned port, Sexpr_t env_exec);	//!<Open a TCP connection to `host:port`; return a bidirectional port. Scheme: `(open-tcp-client-port host port)`. Throws on connection failure.
  Sexpr_t mk_tcp_server_port(unsigned port, Sexpr_t env_exec);			//!<Create a TCP listener on `port`; return a server port. Scheme: `(open-tcp-server-port port)`. Use `server_accept_port()` to accept incoming connections.
  Sexpr_t server_accept_port(LL_Port *server, Sexpr_t env_exec);		//!<Accept one pending connection from `server`; returns a bidirectional client port, or `HASHF` (`#f`) if no connection is waiting (non-blocking). Scheme: `(server-accept server-port)`.
#endif
#if LL_WIFI
  Sexpr_t mk_tls_client_port(Charst_t host, unsigned port, Charst_t ca_cert_pem, Sexpr_t env_exec);	//!<Open a TLS client connection to `host:port`. Pass a PEM CA certificate string in `ca_cert_pem` to verify the server; pass `nullptr` to skip verification (insecure, development only). Scheme: `(open-tls-client-port host port)` or `(open-tls-client-port host port ca-cert-pem)`.
  Sexpr_t mk_tls_server_port(unsigned port, Charst_t cert_pem, Charst_t key_pem, Sexpr_t env_exec);	//!<Create a TLS server on `port` using PEM-encoded certificate `cert_pem` and private key `key_pem`. Scheme: `(open-tls-server-port port cert-pem key-pem)`.
#endif
  //!@}

  Sexpr_t mk_input_string_port(Charst_t inp, Sexpr_t env_exec);			//!<Wrap the C string `inp` as an input port; reading consumes characters left to right.
  Sexpr_t mk_output_string_port(Sexpr_t env_exec);				//!<Create an output port that accumulates written characters; retrieve the result with Scheme `get-output-string`.
  Sexpr_t mk_input_bytevector_port(ByteVec_t src, LL_int32 n, Sexpr_t env_exec);	//!<Wrap `n` bytes of `src` as a binary input port.
  Sexpr_t mk_output_bytevector_port(Sexpr_t env_exec);				//!<Create a binary output port that accumulates written bytes; retrieve the result with Scheme `get-output-bytevector`.
  //!@}

  //! \name Makers for interface to native procedures and C++ objects.
  //!@{
  Sexpr_t mk_Mop3_procst_t(Mop3st_t f, Sexpr_t env_exec)                            { return tcons(Cell::T_MOP3_PROC,  (Word_t) 0,   (Word_t) f, env_exec); } //!< _car_=0 (no argv variant)
  Sexpr_t mk_Mop3_procst_argv_t(Mop3st_t f, Mop3st_argv_t fa, Sexpr_t env_exec)   { return tcons(Cell::T_MOP3_PROC,  (Word_t) fa,  (Word_t) f, env_exec); } //!< _car_=argv fn, _cdr_=standard fn
  Sexpr_t mk_Mop3_nprocst_t(Mop3st_t f, Sexpr_t env_exec)                          { return tcons(Cell::T_MOP3_NPROC, (Word_t) 0,   (Word_t) f, env_exec); }
  Sexpr_t mk_cppobj(void *obj, CPPDeleterPtr deleter, Sexpr_t env_exec)	{ return tcons(Cell::T_CPP_HEAP,   (Word_t) deleter, (Word_t) obj, env_exec); }
  //!@}

  /*! \name Makers for pair types.

    These **pair** types all have the same structure for construction and garbage collection purposes, but are not *Scheme pair* types.
    *LambLisp*'s scalable type system presents opportunities for efficiency when implementing common operations on lists.
    These are executed by the *LambLisp* virtual machine at C++ speed, rather than at the slower speed of the *Lisp* evaluation loop.
    
    - procedures ... the evaluator must be able to identify these directly.
    - dictionaries ... often containing cycles when used as environments, so a depth limit is imposed when traversing.
    - thunks ... used in combination with the trampoline technique to implement tail recursion.
    
    Note that there is no need for mk_pair(), it is just cons().
  */
  //!@{
  Sexpr_t mk_macro(Sexpr_t nlam, Sexpr_t env_nlam, Sexpr_t env_exec)				{ return tcons(Cell::T_MACRO, nlam, env_nlam, env_exec); }			//!<Allocate a `T_MACRO` cell: `nlam` is the nlambda transformer, `env_nlam` is its definition environment. At expansion time the transformer receives the unevaluated argument list; its result is evaluated in the call-site environment.
  Sexpr_t mk_ident(Sexpr_t sym, Sexpr_t def_env, Sexpr_t env_exec)				{ return tcons(Cell::T_IDENT, sym, def_env, env_exec); }			//!<Allocate a `T_IDENT` cell (ER renamed identifier): `sym` is the original symbol, `def_env` its definition environment.  car=sym, cdr=def_env.
  Sexpr_t mk_procedure(Sexpr_t formals, Sexpr_t body, Sexpr_t env_proc, Sexpr_t env_exec)	{ return tcons(Cell::T_PROC, cons(formals, body, env_proc), env_proc, env_exec); }	//!<Allocate a `T_PROC` closure: `formals` is the parameter list, `body` is the list of body expressions, `env_proc` is the captured lexical environment.
  Sexpr_t mk_nprocedure(Sexpr_t formals, Sexpr_t body, Sexpr_t env_nproc, Sexpr_t env_exec)	{ return tcons(Cell::T_NPROC, cons(formals, body, env_nproc), env_nproc, env_exec); }	//!<As `mk_procedure()` but returns a `T_NPROC` cell; arguments are passed unevaluated at call time.
  Sexpr_t mk_thunk_sexpr(Sexpr_t sexpr, Sexpr_t env_thunk, Sexpr_t env_exec)	{ return tcons(Cell::T_THUNK_SEXPR, sexpr, env_thunk, env_exec); }	//!<Allocate a `T_THUNK_SEXPR` trampoline cell: `sexpr` will be evaluated in `env_thunk` on the next trampoline iteration.
  Sexpr_t mk_thunk_body(Sexpr_t body, Sexpr_t env_thunk, Sexpr_t env_exec)	{ return tcons(Cell::T_THUNK_BODY, body, env_thunk, env_exec); }	//!<Allocate a `T_THUNK_BODY` trampoline cell: `body` is a list of expressions evaluated in sequence in `env_thunk`; the last expression's value is the result.
  Sexpr_t mk_dict(Sexpr_t frame, Sexpr_t base, Sexpr_t env_exec)		{ return tcons(Cell::T_DICT, frame, base, env_exec); }
  Sexpr_t mk_dict(LL_int32 framesize, Sexpr_t env_exec);
  //!@}

  /*! \name Macro support

    These macro primitives behave as described in Steele's *Common Lisp*.
  */
  //!@{
  Sexpr_t macroexpand(Sexpr_t form, Sexpr_t env_exec);				//!<Fully expand all macros in `form`, applying transformers repeatedly until no further expansion is possible. Returns the fully expanded form.
  Sexpr_t macroexpand1(Sexpr_t form, Sexpr_t env_exec);				//!<Apply at most one macro expansion step to `form`. Returns the expansion if `form` is a macro call, otherwise returns `form` unchanged.

  Sexpr_t macroexpand(Sexpr_t proc, Sexpr_t args, Sexpr_t env_exec);		//!<Fully expand the macro `proc` applied to `args`.
  Sexpr_t macroexpand1(Sexpr_t proc, Sexpr_t args, Sexpr_t env_exec);		//!<Apply one expansion step of macro `proc` to `args`.
  //!@{

  //! \name Native Code Generator (NCG)
  //!@{
  NcgFrame   *ncg_frame_top        = nullptr;  //!< linked list of live frames; head threaded through frame->prev
  NcgFrame   *ncg_frame_pool_head  = nullptr;  //!< free-list head; recycled frames linked via frame->prev
  int          ncg_frame_pool_count = 0;        //!< frames currently available in the pool
  NcgErrJmp  *ncg_err_ctx          = nullptr;  //!< innermost escape context; set by ncg_eval before JIT call

  void    ncg_mark_frames();                                                           //!< Push all NCG live-frame values onto GC markstack; called from start_marking().
  Sexpr_t ncg_eval(Sexpr_t bc, Sexpr_t args, Sexpr_t env_exec);                       //!< Execute a T_BYTECODE cell that has been NCG-compiled.
  Sexpr_t ncg_eval_argv(Sexpr_t bc, Sexpr_t *argv, int nargs, Sexpr_t env_exec);      //!< Phase 6: direct NCG→NCG call; takes argv[] instead of list, skips apply_proc_partial.
  Sexpr_t ncg_compile(Sexpr_t bc, Sexpr_t env_exec, Sexpr_t captured_names = nullptr); //!< Compile a T_BYTECODE cell to native code; sets slot BC_SLOT_NCG_CODE in its cvec.
  void    ncg_disassemble(Sexpr_t bc, Sexpr_t env_exec);                              //!< Log basic info about an NCG-compiled proc.
  void    ncg_vector_set_ptr(Sexpr_t *data_ptr, LL_int32 k, Sexpr_t val);                //!< Write-barrier store for inlined NCG_STORE_LOCAL (Phase 1).
  // P38 helpers -- fast vector-ref/set with write barrier; called by ncg_vector_ref/set_fast shims.
  Sexpr_t ncg_vref_fast(Sexpr_t vec, Sexpr_t idx);   //!< fast vector-ref (T_SVEC + T_INT32 fast path).
  Sexpr_t ncg_vset_fast(Sexpr_t vec, Sexpr_t idx, Sexpr_t val);  //!< fast vector-set (write-barrier inline).
  // P40 helper -- fast cons from free list, no gc_pass.
  Sexpr_t ncg_cons_fast(Sexpr_t a, Sexpr_t d);  //!< fast cons; returns nullptr if Nfree<=yuasa_M or sweeping.
  Sexpr_t ncg_box_fast(LL_int64 v);             //!< fast integer box; nullptr if Nfree<=yuasa_M or sweeping.
  //!@}

  //! \name native-recursion guard (catch C-stack overflow before it SIGSEGVs)
  //! Both the interpreter (eval) and the compiled path (ncg_eval/ncg_eval_argv) recurse on the
  //! native C stack; unbounded/non-tail Scheme recursion overflows it into the OS guard page =
  //! an uncatchable SIGSEGV.  Stack grows down, so the outermost frame has the highest address;
  //! we track that high-water mark as the base and, once a recursive call has grown more than
  //! eval_stack_budget_ bytes below it, raise a normal (catchable) "recursion too deep" error.
  //! eval_recursion_check() is inlined into the hot recursion entry points; the throw lives in
  //! the cold out-of-line eval_recursion_overflow().
  //!@{
  const char *eval_stack_base_   = nullptr;                  //!< highest stack address seen at a recursion entry (== outermost frame)
  size_t      eval_stack_budget_ = LL_EVAL_STACK_BUDGET;     //!< trip threshold: bytes of C-stack growth below base; tunable at runtime
  LL_int32    eval_root_depth_max_ = LL_EVAL_ROOT_DEPTH_MAX; //!< trip threshold: rootstack depth (cap is 65536); tunable at runtime

  void eval_recursion_overflow(const char *where);          //!< cold path: throws the catchable "recursion too deep" error
  inline void eval_recursion_check(const char *where) {     //!< hot path: cheap C-stack + root-stack depth check at a recursion entry
    char _probe;
    const char *_sp = &_probe;
    if ((eval_stack_base_ == nullptr) || (_sp > eval_stack_base_)) eval_stack_base_ = _sp;  // track outermost (highest)
    if ((size_t) (eval_stack_base_ - _sp) > eval_stack_budget_) eval_recursion_overflow(where);  // C-stack guard page
    if (gc_root_depth() > eval_root_depth_max_) eval_recursion_overflow(where);                  // rootstack OOB write
  }
  //!@}

#if LL_ESP32
  void diag_memory_report();   //!< B117: dump GC-buffer / cell-block placement (INTERNAL vs PSRAM) + sizes.
#endif

  /* put this comment after the last documented member to start new page in doxygen detailed section.
     \latexonly \newpage \endlatexonly
  */

private:

  LambMemoryManager *mem;

  bool _debug_in_progress;
  bool _reader_fold_case;    //!< when true, mk_symbol_or_number lowercases tokens (include-ci, #!fold-case)
  LL_int32 _verbosity;
  LL_float32 ema_loop_ms   = 4.0f;  //!< EMA of main-loop elapsed time (ms); seed matches former loop_target_ms constant
  int   ema_alpha_inv = 8;     //!< EMA smoothing: new-sample weight = 1/ema_alpha_inv
  
  //Symbols and bindings
  static const LL_int32 _lamb_oblist_size		= 2048;
  static const LL_int32 _r5_base_frame_size        = 1024;
  static const LL_int32 _r5_interaction_frame_size = 512;

  Sexpr_t _lamb_oblist;
  Sexpr_t _r5_base_environment;
  Sexpr_t _r5_interaction_environment;

  Sexpr_t _r5_cur_in_cell;    //!< B149: cached (%current-input-port . port) binding pair in the base env; port lives in the (permanently-rooted) env, traced normally -- no special GC root.
  Sexpr_t _r5_cur_out_cell;   //!< cached (%current-output-port . port) binding pair.
  Sexpr_t _r5_cur_err_cell;   //!< cached (%current-error-port . port) binding pair.
  
  //Reader
  const char *DELIMITERS = "()\";\f\t\v\n\r ";
  
  enum {
    TOK_EOF,
    TOK_LPAREN,
    TOK_RPAREN,
    TOK_DOT,
    TOK_ATOM,
    TOK_SQUOTE,
    TOK_DQUOTE,
    TOK_BQUOTE,
    TOK_COMMA,
    TOK_COMMA_AT,
    TOK_SHARP,
    TOK_SHARP_CONST,
    TOK_VECTOR,
    TOK_BVECTOR,   //!< #u8( bytevector literal
    TOK_DCOLON,
    Ntokens
  };

  void report();
  
  LL_int32 produce_token(LL_Port &src, Sexpr_t &env_exec);   //!< env_exec: #; must READ and discard a datum (B181)
  Sexpr_t consume_token(LL_int32 tok, LL_Port &src, Sexpr_t env_exec, bool quoted);

  //Tokens that the reader recognizes and converts directly to symbols.
  Sexpr_t sym_squote;		//single quote '
  Sexpr_t sym_qquote;		//backquote `
  Sexpr_t sym_unquote;		//comma ,
  Sexpr_t sym_uqsplice;		//comma-at ,@

  //Symbols inserted into the reader output to complete multi-step operations
  //e.g., a quoted vector '#(a b c) becomes (apply vector (quote (a b c)))
  Sexpr_t sym_apply;
  Sexpr_t sym_vector;

  //Magic reader tokens that turn into magic symbols.
  Sexpr_t sym_colon_hook;	//LL_float64 colon ::
  Sexpr_t sym_sharp_hook;	//sharp # (not constant or vector)

  Sexpr_t sym_ellipsis;		//three dot ellipsis ...
  Sexpr_t sym_fatarrow;		//aka "feed through" =>
  
  //Loop-based control
  Sexpr_t sym_loop;
  
  Sexpr_t vector_eqv_q(Sexpr_t obj1, Sexpr_t obj2);
  Sexpr_t hashtbl_eqv_q(Sexpr_t obj1, Sexpr_t obj2);
  Sexpr_t bytevector_eqv_q(Sexpr_t obj1, Sexpr_t obj2);
  
  //Bindings: Symbols, Variables and Environments
  Sexpr_t dump_frame(Sexpr_t frame);
  Sexpr_t dump_env_stack(Sexpr_t env_stack);

  //!The reader
  const char *token2name(LL_int32 tok);

  // P138: datum-label read state (`#N=<datum>` / `#N#`).  A placeholder cell is pre-registered
  // before its datum is read so an interior `#N#` resolves to the same (still-being-filled) cell,
  // reconstructing cycles.  Placeholders are kept as GC roots for the whole top-level read.
  // (Plain arrays, not autobuf_t: ll_vm_util.h is not visible this early in the header.)
  LL_int32 *rd_lab_ids;        //!<label id per registered datum label (grown in ll_vm_rdr.cpp)
  Sexpr_t  *rd_lab_cells;      //!<the (rooted) cell each label id resolves to
  LL_int32  rd_lab_cap;        //!<allocated capacity of the two arrays
  LL_int32  rd_lab_n;          //!<number of registered labels this top-level read
  LL_int32  rd_lab_depth;      //!<read_sexpr nesting depth (0 at a fresh top-level read)
  LL_int32  rd_lab_root_base;  //!<gc_root_depth() captured at the outermost read (for cleanup)
  void    rd_label_register(LL_int32 id, Sexpr_t cell);   //!<record id->cell (appends; latest wins)
  Sexpr_t rd_label_lookup(LL_int32 id);                   //!<most-recent cell for id, or 0 if none

  Sexpr_t read_sexpr(LL_Port &src, Sexpr_t &env_exec, bool quoted);
  Sexpr_t read_atom(LL_Port &src, Sexpr_t &env_exec);

  Sexpr_t read_any_quote(Sexpr_t symbol, LL_Port &src, Sexpr_t &env_exec);
  Sexpr_t read_squote(LL_Port &src, Sexpr_t env_exec)	{ return read_any_quote(sym_squote, src, env_exec); }
  Sexpr_t read_qquote(LL_Port &src, Sexpr_t env_exec)	{ return read_any_quote(sym_qquote, src, env_exec); }
  Sexpr_t read_unquote(LL_Port &src, Sexpr_t env_exec)	{ return read_any_quote(sym_unquote, src, env_exec); }
  Sexpr_t read_uqsplice(LL_Port &src, Sexpr_t env_exec)	{ return read_any_quote(sym_uqsplice, src, env_exec); }

  Sexpr_t read_sharp_const(LL_Port &src, Sexpr_t &env_exec);
  Sexpr_t read_sharp(LL_Port &src, Sexpr_t &env_exec);
  Sexpr_t read_vector(LL_Port &src, Sexpr_t &env_exec);
  Sexpr_t read_bvector(LL_Port &src, Sexpr_t &env_exec);
  Sexpr_t read_quotedvector(LL_Port &src, Sexpr_t &env_exec);
  Sexpr_t read_list(LL_Port &src, Sexpr_t &env_exec, bool quoted);
  Sexpr_t read_string(LL_Port &src, Sexpr_t &env_exec);  
  Sexpr_t read_bar_symbol(LL_Port &src, Sexpr_t &env_exec);   //!< R7RS |...| verbatim symbol

};

//! gc_protect idiom for the inline Lamb members below.  ll_gc_protect (ll_vm_mem.h) is
//! mem->rootpush-based and is NOT in scope here -- LambLisp.h is included before ll_vm_mem.h in
//! every TU -- so this Lamb-method variant gives the same scoped push/code/pop shape for car()/cdr().
//! Body must be multi-line if it contains a top-level comma (same preprocessor rule as ll_gc_protect).
//With error check, inlined for speed.
// B43/perf: car()/cdr() ALLOCATE (mk_int32/mk_float32) when materializing an embedded immediate
// (P70/P76 packed pair).  We do NOT root the source pair `c` across that alloc: c's value bits are
// extracted BEFORE mk_* runs (car/cdr never touch c afterward), and callers reach c through an
// already-rooted structure -- apply_proc_partial roots the mop3 arg list, and internal fresh
// aggregates are rooted at their build site per the mop3 accumulator rule.  An A/B test (self-push
// OFF, call-site roots ON) ran the conform hunt clean, confirming the self-push was defensive, not
// load-bearing -- and through apply it merely re-rooted `c`, already reachable from the rooted args.
// So it is dropped to keep the hot car/cdr path push-free.  A caller holding an UNROOTED fresh pair
// across a materializing car/cdr must root it at the call site, not rely on this accessor.
inline Sexpr_t Lamb::car(Sexpr_t c)	{
  ME("Lamb::car()");
  if (c->type() >= Cell::T_PAIR) {
    if (c->car_is_embedded()) {
      int wt = c->car_word_type();
      if (wt == Cell::Wt_int32)   return mk_int32(c->car_int32(), NIL);
      if (wt == Cell::Wt_float32) return mk_float32(c->car_float32(), NIL);
    }
    return c->prechecked_anypair_get_car();
  }
  embedded_debug_catcher();
  throw mk_syserror("%s Bad type %s", me, c->dump().c_str());
}

inline Sexpr_t Lamb::prechecked_anypair_get_car(Sexpr_t c)	{
  if (c->car_is_embedded()) {
    int wt = c->car_word_type();
    if (wt == Cell::Wt_int32)   return mk_int32(c->car_int32(), NIL);
    if (wt == Cell::Wt_float32) return mk_float32(c->car_float32(), NIL);
  }
  return c->prechecked_anypair_get_car();
}

inline Sexpr_t Lamb::prechecked_anypair_get_cdr(Sexpr_t c)	{
  if (c->cdr_is_embedded()) {
    int wt = c->cdr_word_type();
    if (wt == Cell::Wt_int32)   return mk_int32(c->cdr_int32(), NIL);
    if (wt == Cell::Wt_float32) return mk_float32(c->cdr_float32(), NIL);
  }
  return c->prechecked_anypair_get_cdr();
}

inline Sexpr_t Lamb::cdr(Sexpr_t c)	{
  ME("Lamb::cdr()");
  if (c->type() >= Cell::T_PAIR) {
    if (c->cdr_is_embedded()) {
      int wt = c->cdr_word_type();
      if (wt == Cell::Wt_int32)   return mk_int32(c->cdr_int32(), NIL);
      if (wt == Cell::Wt_float32) return mk_float32(c->cdr_float32(), NIL);
    }
    return c->prechecked_anypair_get_cdr();
  }
  embedded_debug_catcher();
  throw mk_syserror("%s Bad type %s", me, c->dump().c_str());
}


// ---------------------------------------------------------------------------
// mop3 authoring macros.  THESE LIVE HERE ON PURPOSE.
//
// They were in ll_vm_mop3.h until 2026-08-26.  Every shipped ll_xmop3_*.cpp includes that header
// for these macros and for nothing else (zero references to apply_fast or anything NCG) -- but
// packaging strips `ll_vm_*` from customer src/, so from the day the include was added (acc66ea,
// 2026-05-04) NO customer package could be rebuilt from source: twelve extension modules failed
// with "fatal error: ll_vm_mop3.h: No such file or directory".  It went unnoticed for four months
// because nobody builds a package the way a customer does.
//
// LambLisp.h already ships and every extension already includes it, so putting them here needs no
// new header and no new include.  Anything that is genuinely VM-internal stays in ll_vm_mop3.h.
// If you add a macro that a shipped ll_xmop3_*.cpp needs, it belongs HERE, not there.
// ---------------------------------------------------------------------------

/*! Push @p __thing__ onto the GC rootstack, execute @p __code__, then pop. */
#define mop3_gc_protect(__thing__, __code__) do {	\
    lamb.gc_root_push(__thing__);			\
    { __code__ };					\
    lamb.gc_root_pop();					\
  } while (0)						\
  //
//

/*! Push two values onto the GC rootstack, execute @p __code__, then pop both. */
#define mop3_gc_protect2(__thing1__, __thing2__, __code__) do {	\
    lamb.gc_root_push(__thing1__);				\
    lamb.gc_root_push(__thing2__);				\
    { __code__ };						\
    lamb.gc_root_pop(2);					\
  } while (0)							\
  //
//

/*! Push three values onto the GC rootstack, execute @p __code__, then pop all three. */
#define mop3_gc_protect3(__thing1__, __thing2__, __thing3__, __code__) do {	\
    lamb.gc_root_push(__thing1__);						\
    lamb.gc_root_push(__thing2__);						\
    lamb.gc_root_push(__thing3__);						\
    { __code__ };								\
    lamb.gc_root_pop(3);							\
  } while (0)									\
  //
//

//! mop3_try/mop3_catch: mop3-specific variants that save/restore GC root depth automatically.
//! Use these instead of ll_try/ll_catch in mop3 functions (which have 'lamb' in scope).
#define mop3_try							\
  LL_int32 __gc_depth__ = lamb.gc_root_depth();				\
  try									\
  //
//

#define mop3_catch(__code_before_rethrow__)						\
  catch (Sexpr_t __err__) {							\
    if (__err__->type() != Cell::T_ERROR)					\
      throw NIL->mk_error("mop3_catch() BUG in %s bad type %s", me, __err__->dump().c_str()); \
    lamb.gc_root_setdepth(__gc_depth__);					\
    global_printf("\r[%d] %s mop3_catch(): %s\n", millis(), me, __err__->error_get_chars()); \
    ll_debug_catcher;								\
    __code_before_rethrow__;							\
    throw __err__;								\
  }										\
  //
//

#endif
