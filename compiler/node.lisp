;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;;    Structures for the first intermediate representation in the compiler,
;;; IR1.
;;;
;;; Written by Rob MacLachlan
;;;
(in-package 'c)

;;; Defvars for these variables appear later.
(proclaim '(special *current-cookie* *default-cookie* *current-path*
		    *current-cleanup* *current-lambda* *current-component*
		    *fenv* *venv* *benv* *tenv*))


;;; The front-end data structure (IR1) is composed of nodes and continuations.
;;; The general idea is that continuations contain top-down information and
;;; nodes contain bottom-up, derived information.  A continuation represents a
;;; place in the code, while a node represents code that does something.
;;;
;;; This representation is more of a flow-graph than an augmented syntax tree.
;;; The evaluation order is explicitly represented in the linkage by
;;; continuations, rather than being implicit in the nodes which receive the
;;; the results of evaluation.  This allows us to decouple the flow of results
;;; from the flow of control.  A continuation represents both, but the
;;; continuation can represent the case of a discarded result by having no
;;; DEST. 

(defstruct (continuation (:print-function %print-continuation)
			 (:constructor make-continuation (&optional dest)))
  ;;
  ;; An indication of the way that this continuation is currently used:
  ;;
  ;; :Unused
  ;;        A continuation for which all control-related slots have the default
  ;;        values.  A continuation is unused during IR1 conversion until it is
  ;;        assigned a block, and may be also be temporarily unused during
  ;;        later manipulations of IR1.  In a consistent state there should
  ;;        never be any mention of :Unused continuations.  Next can have a
  ;;        non-null value if the next node has already been determined.
  ;;
  ;; :Deleted
  ;;        A continuation that has been deleted from IR1.  Any pointers into
  ;;        IR1 are cleared.  There are two conditions under which a deleted
  ;;        continuation may appear in code:
  ;;         -- The Cont of the Last node in a block may be a deleted
  ;;            continuation when the original receiver of the continuation's
  ;;            value was deleted.  Note that Dest in a deleted continuation is
  ;;            null, so it is easy to know not to attempt delivering any
  ;;            values to the continuation.
  ;;         -- Unreachable code that hasn't been deleted yet may receive
  ;;            deleted continuations.  All such code will be in blocks that
  ;;            have DELETE-P set.  All unreachable code is deleted by control
  ;;            optimization, so the backend doesn't have to worry about this.
  ;;
  ;; :Block-Start
  ;;        The continuation that is the Start of Block.  This is the only kind
  ;;        of continuation that can have more than one use.  The Block's
  ;;        Start-Uses is a list of all the uses.
  ;;
  ;; :Deleted-Block-Start
  ;;        Like :Block-Start, but Block has been deleted.  A block starting
  ;;        continuation is made into a deleted block start when the block is
  ;;        deleted, but the continuation still may have value semantics.
  ;;        Since there isn't any code left, next is null.
  ;;
  ;; :Inside-Block
  ;;        A continuation that is the Cont of some node in Block.
  ;;
  (kind :unused :type (member :unused :deleted :inside-block :block-start
			      :deleted-block-start))
  ;;
  ;; The node which receives this value, if any.  In a deleted continuation,
  ;; this is null even though the node that receives this continuation may not
  ;; yet be deleted.
  (dest nil :type (or node null))
  ;;
  ;; If this is a Node, then it is the node which is to be evaluated next.
  ;; This is always null in :Deleted and :Unused continuations, and will be
  ;; null in a :Inside-Block continuation when this is the CONT of the LAST.
  (next nil :type (or node null))
  ;;
  ;; An assertion on the type of this continuation's value.
  (asserted-type *wild-type* :type ctype)
  ;;
  ;; Cached type of this contiuation's value.  If NIL, then this must be
  ;; recomputed: see Continuation-Derived-Type.
  (%derived-type nil :type (or ctype null))
  ;;
  ;; Node where this continuation is used, if unique.  This is always null in
  ;; :Deleted and :Unused continuations, and is never null in :Inside-Block
  ;; continuations.  In a :Block-Start contiuation, the Block's Start-Uses
  ;; indicate whether NIL means no uses or more than one use.
  (use nil :type (or node null))
  ;;
  ;; Basic block this continuation is in.  This is null only in :Deleted and
  ;; :Unused continuations.  Note that blocks that are unreachable but still in
  ;; the DFO may receive deleted continuations, so it isn't o.k. to assume that
  ;; any random continuation that you pick up out of its Dest node has a Block.
  (block nil :type (or cblock null))
  ;;
  ;; Set to true when something about this continuation's value has changed.
  ;; See Reoptimize-Continuation.  This provides a way for IR1 optimize to
  ;; determine which operands to a node have changed.  If the optimizer for
  ;; this node type doesn't care, it can elect not to clear this flag.
  (reoptimize t :type boolean)
  ;;
  ;; An indication of what we have proven about how this contination's type
  ;; assertion is satisfied:
  ;; 
  ;; NIL
  ;;    No type check is necessary (proven type is a subtype of the assertion.)
  ;;
  ;; T
  ;;    A type check is needed.
  ;;
  ;; :DELETED
  ;;    Don't do a type check, but believe (intersect) the assertion.  A T
  ;;    check can be changed to :DELETED if we somehow prove the check is
  ;;    unnecessary, or if we eliminate it through a policy decision.
  ;;
  ;; :NO-CHECK
  ;;    Type check generation sets the slot to this if a check is called for,
  ;;    but it believes it has proven that the check won't be done for
  ;;    policy reasons or because a safe implementation will be used.  In the
  ;;    latter case, LTN must ensure that a safe implementation *is* be used.
  ;;
  ;; :ERROR
  ;;    There is a compile-time type error in some use of this continuation.  A
  ;;    type check should still be generated, but be careful.
  ;;
  ;; This is computed lazily by CONTINUATION-DERIVED-TYPE, so use
  ;; CONTINUATION-TYPE-CHECK instead of the %'ed slot accessor.
  ;;
  (%type-check t :type (member t nil :deleted :no-check :error))
  ;;
  ;; Something or other that the back end annotates this continuation with.
  (info nil))

(defun %print-continuation (s stream d)
  (declare (ignore d))
  (format stream "#<Continuation c~D>" (cont-num s)))


(defstruct node
  ;;
  ;; The bottom-up derived type for this node.  This does not take into
  ;; consideration output type assertions on this node (actually on its CONT).
  (derived-type *wild-type* :type ctype)
  ;;
  ;; True if this node needs to be optimized.  This is set to true whenever
  ;; something changes about the value of a continuation whose DEST is this
  ;; node.
  (reoptimize t :type boolean)
  ;;
  ;; The continuation which receives the value of this node.  This also
  ;; indicates what we do controlwise after evaluating this node.  This may be
  ;; null during IR1 conversion.
  (cont nil :type (or continuation null))
  ;; 
  ;; The continuation that this node is the next of.  This is null during
  ;; IR1 conversion when we haven't linked the node in yet or in nodes that
  ;; have been deleted from the IR1 by UNLINK-NODE.
  (prev nil :type (or continuation null))
  ;;
  ;; The Cookie holds various rarely-changed information about how a node
  ;; should be compiled.  Currently it only holds the values of the Optimize
  ;; settings.  Values for things which have not been specified locally are
  ;; null.  The real value is then found in the Default-Cookie.  The
  ;; Default-Cookie must also be kept in the node since it changes when
  ;; we run into a Proclaim duing IR1 conversion.
  (cookie *current-cookie* :type cookie :read-only t)
  (default-cookie *default-cookie* :type cookie :read-only t)
  ;;
  ;; Source code for this node.  This is used to provide context in messages to
  ;; the user, since it may be hard to reconstruct the source from the internal
  ;; representation.
  (source nil :type t :read-only t)
  ;;
  ;; A representation of the location in the original source of the form
  ;; responsible for generating this node.  The first element in this list is
  ;; the "form number", which is the ordinal number of this form in a
  ;; depth-first, left-to-right walk of the truly top-level form in which this
  ;; appears.
  ;;
  ;; Following is a list of integers describing the path taken through the
  ;; source to get to this point:
  ;;     (k l m ...) => (nth k (nth l (nth m ...)))
  ;; 
  ;; This path is through the original top-level form compiled, and in general
  ;; has nothing to do with the Source slot.  This path is our best guess for
  ;; where the code came from, and may be not be very helpful in the case of
  ;; code resulting from macroexpansion.  The last element in the list is the
  ;; top-level form number, which is the ordinal number (in this call to the
  ;; compiler) of the truly top-level form containing the orignal source
  (source-path *current-path* :type list :read-only t)
  ;;
  ;; If this node is in a tail-recursive position, then this is set to the
  ;; corresponding Tail-Set.  This is first computed at the end of IR1 (after
  ;; cleanup code has been emitted).  If the back-end breaks tail-recursion for
  ;; some reason, then it can null out this slot.
  (tail-p nil :type (or tail-set null)))



;;; The CBlock structure represents a basic block.  We include SSet-Element so
;;; that we can have sets of blocks.  Initially the SSet-Element-Number is
;;; null, but we number in reverse DFO before we do any set operations.
;;;
(defstruct (cblock (:print-function %print-block)
		   (:include sset-element)
		   (:constructor make-block (start))
		   (:constructor make-block-key)
		   (:conc-name block-)
		   (:predicate block-p)
		   (:copier copy-block))
  ;;
  ;; A list of all the blocks that are predecessors/successors of this block.
  ;; In well-formed IR1, most blocks will have one or two successors.  The only
  ;; exceptions are component head blocks and block with DELETE-P set.
  (pred nil :type list)
  (succ nil :type list)
  ;;
  ;; The continuation which heads this block (either a :Block-Start or
  ;; :Deleted-Block-Start.)  Null when we haven't made the start continuation
  ;; yet.
  (start nil :type (or continuation null))
  ;;
  ;; A list of all the nodes that have Start as their Cont.
  (start-uses nil :type list)
  ;;
  ;; The last node in this block.  This is null when we are in the process of
  ;; building a block.
  (last nil :type (or node null))
  ;;
  ;; The Lambda that this code is syntactically within, for environment
  ;; analysis.  This may be null during IR1 conversion.  This is also null in
  ;; the dummy head and tail blocks for a component.
  (lambda *current-lambda* :type (or clambda null))
  ;;
  ;; The cleanups in effect at the beginning and after the end of this block.
  ;; If there is no cleanup in effect within the enclosing lambda, then the
  ;; value is the enclosing lambda.  The Lambda-Cleanup must be examined to
  ;; determine whether later let-substitution has added an enclosing dynamic
  ;; binding in the same environment.  Cleanup generation uses this information
  ;; to determine if code needs to be emitted to undo dynamic bindings.
  ;; Null in the dummy component head and tail.
  (start-cleanup *current-cleanup* :type (or cleanup clambda null))
  (end-cleanup *current-cleanup* :type (or cleanup clambda null))
  ;;
  ;; The forward and backward links in the depth-first ordering of the blocks.
  ;; These slots are null at beginning/end.
  (next nil :type (or null cblock))
  (prev nil :type (or null cblock))
  ;;
  ;; Flags that are used to indicate that various IR1 optimization phases
  ;; should be done on code in this block:
  ;; -- REOPTIMIZE is set when something interesting happens the uses of a
  ;;    continuation whose Dest is in this block.  This indicates that the
  ;;    value-driven (forward) IR1 optimizations should be done on this block.
  ;; -- FLUSH-P is set when code in this block becomes potentially flushable,
  ;;    usually due to a continuation's DEST becoming null.
  ;; -- TYPE-CHECK is true when the type check phase should be run on this
  ;;    block.  IR1 optimize can introduce new blocks after type check has
  ;;    already run.  We need to check these blocks, but there is no point in
  ;;    checking blocks we have already checked.
  ;; -- DELETE-P is true when this block is used to indicate that this block
  ;;    has been determined to be unreachable and should be deleted.  IR1
  ;;    phases should not attempt to  examine or modify blocks with DELETE-P
  ;;    set, since they may:
  ;;     - be in the process of being deleted, or
  ;;     - have no successors, or
  ;;     - receive :DELETED continuations.
  ;; -- TYPE-ASSERTED, TEST-MODIFIED
  ;;    These flags are used to indicate that something in this block might be
  ;;    of interest to constraint propagation.  TYPE-ASSERTED is set when a
  ;;    continuation type assertion is strengthened.  TEST-MODIFIED is set
  ;;    whenever the test for the ending IF has changed (may be true when there 
  ;;    is no IF.)
  ;;
  (reoptimize t :type boolean)
  (flush-p t :type boolean)
  (type-check t :type boolean)
  (delete-p nil :type boolean)
  (type-asserted t :type boolean)
  (test-modified t :type boolean)
  ;;
  ;; Some sets used by constraint propagation.
  (kill nil)
  (gen nil)
  (in nil)
  (out nil)
  ;;
  ;; The component this block is in.  Null temporarily during IR1 conversion
  ;; and in deleted blocks.
  (component *current-component* :type (or component null))
  ;;
  ;; A flag used by various graph-walking code to determine whether this block
  ;; has been processed already or what.  We make this initially NIL so that
  ;; Find-Initial-DFO doesn't have to scan the entire initial component just to
  ;; clear the flags.
  (flag nil)
  ;;
  ;; Some kind of info used by the back end.
  (info nil))

(defun %print-block (s stream d)
  (declare (ignore d))
  (format stream "#<Block ~X, Start = c~D>" (system:%primitive make-fixnum s)
	  (cont-num (block-start s))))


;;; The Component structure provides a handle on a connected piece of the flow
;;; graph.  Most of the passes in the compiler operate on components rather
;;; than on the entire flow graph.
;;;
(defstruct (component (:print-function %print-component))
  ;;
  ;; The kind of component:
  ;; 
  ;; NIL
  ;;     An ordinary component, containing arbitrary code.
  ;;
  ;; :Top-Level
  ;;     A component containing only load-time code.
  ;;
  ;; :Initial
  ;;     The result of initial IR1 conversion, on which component analysis has
  ;;     not been done.
  ;;
  (kind nil :type (member nil :top-level :initial))
  ;;
  ;; The blocks that are the dummy head and tail of the DFO.  Entry/exit points
  ;; have these blocks as their predecessors/successors.  Null temporarily.
  ;; The start and return from each non-deleted function is linked to the
  ;; component head and tail.  Until environment analysis links NLX entry stubs
  ;; to the component head, every successor of the head is a function start
  ;; (i.e. begins with a Bind node.)
  (head nil :type (or null cblock))
  (tail nil :type (or null cblock))
  ;;
  ;; A list of the CLambda structures for all functions in this component.
  ;; Optional-Dispatches are represented only by their XEP and other associated
  ;; lambdas.  This doesn't contain any deleted or let lambdas.
  (lambdas () :type list)
  ;;
  ;; A list of Functional structures for functions that are newly converted,
  ;; and haven't been local-call analyzed yet.  Unanalyzed functions aren't in
  ;; the Lambdas list.  Functions are moved into the Lambdas as they are
  ;; analysed.
  (new-functions () :type list)
  ;;
  ;; If true, then there is stuff in this component that could benefit from
  ;; further IR1 optimization.
  (reoptimize t :type boolean)
  ;;
  ;; If true, then the control flow in this component was messed up by IR1
  ;; optimizations.  The DFO should be recomputed.
  (reanalyze nil :type boolean)
  ;;
  ;; String that is some sort of name for the code in this component.
  (name "<unknown>" :type simple-string)
  ;;
  ;; Some kind of info used by the back end.
  (info nil))


(defprinter component
  name
  (reanalyze :test reanalyze))
  

;;; The Cleanup structure represents some dynamic binding action.  Blocks are
;;; annotated with the current cleanup so that dynamic bindings can be removed
;;; when control is transferred out of the binding environment.  We arrange for
;;; changes in dynamic bindings to happen at block boundaries, so that cleanup
;;; code may easily be inserted.  The "mess-up" action is explictly represented
;;; by a funny function call or Entry node.
;;;
;;; We guarantee that cleanups only need to be done at block boundries by
;;; requiring that the exit continuations initially head their blocks, and then
;;; by not merging blocks when there is a cleanup change.
;;;
(defstruct (cleanup (:print-function %print-cleanup))
  ;;
  ;; The kind of thing that has to be cleaned up.  :Entry marks the dynamic
  ;; extent of a lexical exit (TAGBODY or BLOCK).
  (kind nil :type (member :special-bind :catch :unwind-protect :entry))
  ;;
  ;; The first messed-up continuation.  This is Use'd by the node that is the
  ;; mess-up.  Null only temporarily.  This could be deleted if the mess-up was
  ;; deleted.
  (start nil :type (or continuation null))
  ;;
  ;; The syntactically enclosing cleanup.  If there is no enclosing cleanup in
  ;; our lambda, then this is the lambda.  A :Catch or :Unwind-Protect cleanup
  ;; is always enclosed by the :Entry cleanup for the escape block.
  (enclosing *current-cleanup* :type (or cleanup clambda))
  ;;
  ;; A list of all the NLX-Info structures whose NLX-Info-Cleanup is this
  ;; cleanup.  This is filled in by environment analysis.
  (nlx-info nil :type list))

(defprinter cleanup
  kind
  (start :prin1 (continuation-use start))
  (nlx-info :test nlx-info))


;;; The Environment structure represents the result of Environment analysis.
;;;
(defstruct (environment (:print-function %print-environment))
  ;;
  ;; The function that allocates this environment.
  (function nil :type clambda)
  ;;
  ;; A list of all the Lambdas that allocate variables in this environment.
  (lambdas nil :type list)
  ;;
  ;; A list of all the lambda-vars and NLX-Infos needed from enclosing
  ;; environments by code in this environment.
  (closure nil :type list)
  ;;
  ;; A list of NLX-Info structures describing all the non-local exits into this
  ;; environment.
  (nlx-info nil :type list)
  ;;
  ;; Some kind of info used by the back end.
  (info nil))

(defprinter environment
  function
  (closure :test closure)
  (nlx-info :test nlx-info))


;;; The Tail-Set structure is used to accmumlate information about
;;; tail-recursive local calls.  The "tail set" is effectively the transitive
;;; closure of the "is called tail-recursively by" relation.
;;;
;;; All functions in the same tail set share the same Tail-Set structure.
;;; Initially each function has its own Tail-Set, but converting a TR local
;;; call joins the tail sets of the called function and the calling function.
;;; When computing the tail set, we consider a call to be TR when it delivers
;;; its value to a return node; there may be an implicit MV-Prog1, and the
;;; use of the result continuation might even turn out to be a non-local exit.
;;;
;;; This is the most useful interpretation for type inference.  Anyway, local
;;; call analysis happens too early to determine which calls are truly TR.
;;;
(defstruct (tail-set
	    (:print-function %print-tail-set))
  ;;
  ;; A list of all the lambdas in this tail set.
  (functions nil :type list)
  ;;
  ;; Our current best guess of the type returned by these functions.  This is
  ;; the union across all the functions of the return node's Result-Type.
  ;; excluding local calls.
  (type *wild-type* :type ctype)
  ;;
  ;; Some info used by the back end.
  (info nil))

(defprinter tail-set
  functions
  type
  (info :test info))


;;; The NLX-Info structure is used to collect various information about
;;; non-local exits.  This is effectively an annotation on the Continuation,
;;; although it is accessed by searching in the Environment-Nlx-Info.
;;;
(defstruct (nlx-info (:print-function %print-nlx-info))
  ;;
  ;; The cleanup associated with this exit.  In a catch or unwind-protect, this
  ;; is the :Catch or :Unwind-Protect cleanup, and not the cleanup for the
  ;; escape block.  The Cleanup-Kind of this thus provides a good indication of
  ;; what kind of exit is being done.
  (cleanup nil :type cleanup)
  ;;
  ;; The continuation exited to (the CONT of the EXIT nodes.)  This is
  ;; primarily an indication of where this exit delivers its values to (if
  ;; any), but it is also used as a sort of name to allow us to find the
  ;; NLX-Info that corresponds to a given exit.  For this purpose, the Entry
  ;; must also be used to disambiguate, since exits to different places may
  ;; deliver their result to the same continuation.
  (continuation nil :type continuation)
  ;;
  ;; The entry stub inserted by environment analysis.  This is a block
  ;; containing a call to the %NLX-Entry funny function that has the original
  ;; exit destination as its successor.  Null only temporarily.
  (target nil :type (or cblock null))
  ;;
  ;; Some kind of info used by the back end.
  info)

(defprinter nlx-info
  continuation
  target
  info)


;;; Leaves:
;;;
;;;    Variables, constants and functions are all represented by Leaf
;;; structures.  A reference to a Leaf is indicated by a Ref node.  This allows
;;; us to easily substitute one for the other without actually hacking the flow
;;; graph.

(defstruct leaf
  ;;
  ;; Some name for this leaf.  The exact significance of the name depends on
  ;; what kind of leaf it is.  In a Lambda-Var or Global-Var, this is the
  ;; symbol name of the variable.  In a functional that is from a DEFUN, this
  ;; is the defined name.  In other functionals, this is a descriptive string.
  (name nil :type t)
  ;;
  ;; The type which values of this leaf must have.
  (type *universal-type* :type ctype)
  ;;
  ;; Where the Type information came from:
  ;;  :declared, from a declaration.
  ;;  :assumed, from uses of the object.
  ;;  :defined, from examination of the definition.
  (where-from :assumed :type (member :declared :assumed :defined))
  ;;
  ;; List of the Ref nodes for this leaf.
  (refs () :type list)
  ;;
  ;; True if there was ever a Ref or Set node for this leaf.  This may be true
  ;; when Refs and Sets are null, since code can be deleted.
  (ever-used nil :type boolean)
  ;;
  ;; Some kind of info used by the back end.
  (info nil))


;;; The Constant structure is used to represent known constant values.  If Name
;;; is not null, then it is the name of the named constant which this leaf
;;; corresponds to, otherwise this is an anonymous constant.
;;;
(defstruct (constant (:include leaf)
		     (:print-function %print-constant))
  ;;
  ;; The value of the constant.
  (value nil :type t))

(defprinter constant
  (name :test name)
  value)

  
;;; The Basic-Var structure represents information common to all variables
;;; which don't correspond to known local functions.
;;;
(defstruct (basic-var (:include leaf))
  ;;
  ;; Lists of the set nodes for this variable.
  (sets () :type list))


;;; The Global-Var structure represents a value hung off of the symbol Name.
;;; We use a :Constant Var when we know that the thing is a constant, but don't
;;; know what the value is at compile time.
;;;
(defstruct (global-var (:include basic-var)
		       (:print-function %print-global-var))
  ;;
  ;; Kind of variable described.
  (kind nil :type (member :special :global-function :constant :global)))

(defprinter global-var
  name
  (type :test (not (eq type *universal-type*)))
  (where-from :test (not (eq where-from :assumed)))
  kind)


;;; The Slot-Accessor structure represents defstruct slot accessors.  It is a
;;; subtype of Global-Var to make it look more like a normal function.
;;;
(defstruct (slot-accessor (:include global-var
				    (where-from :defined)
				    (kind :global-function))
			  (:print-function %print-slot-accessor))
  ;;
  ;; The description of the structure that this is an accessor for.
  (for nil :type defstruct-description)
  ;;
  ;; The slot description of the slot.
  (slot nil :type defstruct-slot-description))

(defprinter slot-accessor
  name
  for
  slot)



;;;; Function stuff:


;;; We default the Where-From and Type slots to :Defined and Function.  We
;;; don't normally manipulate function types for defined functions, but if
;;; someone wants to know, an approximation is there.
;;;
(defstruct (functional (:include leaf
			 (:where-from :defined)
			 (:type (specifier-type 'function))))
  ;;
  ;; Some information about how this function is used.  These values are
  ;; meaningful:
  ;;
  ;;    Nil
  ;;        An ordinary function, callable using local call.
  ;;
  ;;    :Let
  ;;        A lambda that is used in only one local call, and has in effect
  ;;        been substituted directly inline.  The return node is deleted, and
  ;;        the result is computed with the actual result continuation for the
  ;;        call.
  ;;
  ;;    :MV-Let
  ;;        Similar to :Let, but the call is an MV-Call.
  ;;
  ;;    :Optional
  ;;        A lambda that is an entry-point for an optional-dispatch.  Similar
  ;;        to NIL, but requires greater caution, since local call analysis may
  ;;        create new references to this function.  Also, the function cannot
  ;;        be deleted even if it has *no* references.  The Optional-Dispatch
  ;;        is in the LAMDBA-OPTIONAL-DISPATCH.
  ;;
  ;;    :External
  ;;        An external entry point lambda.  The function it is an entry for is
  ;;        in the Entry-Function.
  ;;
  ;;    :Top-Level
  ;;        A top-level lambda, holding a compiled top-level form.  Compiled
  ;;        very much like NIL, but provides an indication of top-level
  ;;        context.  A top-level lambda should have *no* references.  Its
  ;;        Entry-Function is a self-pointer.
  ;;
  ;;    :Escape
  ;;    :Cleanup
  ;;        Special functions used internally by Catch and Unwind-Protect.
  ;;        These are pretty much like a normal function (NIL), but are treated
  ;;        specially by local call analysis and stuff.  Neither kind should
  ;;        ever be given an XEP even though they appear as args to funny
  ;;        functions.  An :Escape function is never actually called, and thus
  ;;        doesn't need to have code generated for it.
  ;;
  ;;    :Deleted
  ;;        This function has been found to be uncallable, and has been
  ;;        marked for deletion.
  ;;
  (kind nil :type (member nil :optional :deleted :external :top-level :escape
			  :cleanup :let :mv-let))
  ;;
  ;; In a normal function, this is the external entry point (XEP) lambda for
  ;; this function, if any.  Each function that is used other than in a local
  ;; call has an XEP, and all of the non-local-call references are replaced
  ;; with references to the XEP.
  ;;
  ;; In an XEP lambda (indicated by the :External kind), this is the function
  ;; that the XEP is an entry-point for.  The body contains local calls to all
  ;; the actual entry points in the function.  In a :Top-Level lambda (which is
  ;; its own XEP) this is a self-pointer.
  ;;
  ;; With all other kinds, this is null.
  (entry-function nil :type (or functional null))
  ;;
  ;; If we have a lambda that can be used as in inline expansion for this
  ;; function, then this is it.  If there is no source-level lambda
  ;; corresponding to this function then this is Null.
  (inline-expansion nil :type list)
  ;;
  ;; The original function or macro lambda list, or :UNSPECIFIED if this is a
  ;; compiler created function.
  (arg-documentation nil :type (or list (member :unspecified)))
  ;;
  ;; The environment values that we use if we reconvert the Inline-Expansion.
  (fenv *fenv*)
  (venv *venv*)
  (benv *benv*)
  (tenv *tenv*))


;;; The Lambda only deals with required lexical arguments.  Special, optional,
;;; keyword and rest arguments are handled by transforming into simpler stuff.
;;;
(defstruct (clambda (:include functional)
		    (:print-function %print-lambda)
		    (:conc-name lambda-)
		    (:predicate lambda-p)
		    (:constructor make-lambda)
		    (:copier copy-lambda))
  ;;
  ;; List of lambda-var descriptors for args.
  (vars nil :type list)
  ;;
  ;; If this function was ever a :OPTIONAL function (an entry-point for an
  ;; optional-dispatch), then this is that optional-dispatch.  The optional
  ;; dispatch will be :DELETED if this function is no longer :OPTIONAL.
  (optional-dispatch nil :type (or optional-dispatch null))
  ;;
  ;; The Bind node for this Lambda.  This node marks the beginning of the
  ;; lambda, and serves to explicitly represent the lambda binding semantics
  ;; within the flow graph representation.
  (bind nil :type bind)
  ;;
  ;; The Return node for this Lambda, or NIL if it has been deleted.  This
  ;; marks the end of the lambda, receiving the result of the body.  In a let,
  ;; the return node is deleted, and the body delivers the value to the actual
  ;; continuation.  The return may also be deleted if it is unreachable.
  (return nil :type (or creturn null))
  ;;
  ;; If this is a let, then the Lambda whose Lets list we are in, otherwise
  ;; this is a self-pointer.
  (home nil :type (or clambda null))
  ;;
  ;; A list of all the all the lambdas that have been let-substituted in this
  ;; lambda.  This is only non-null in lambdas that aren't lets.
  (lets () :type list)
  ;;
  ;; A list of all the Entry nodes in this function and its lets.  Null an a
  ;; let.
  (entries () :type list)
  ;;
  ;; If true, then this is the innermost cleanup that dynamically encloses the
  ;; call to this function.  If false, then there is no such cleanup.  This is
  ;; never true if the lambda isn't a let, since in other cases the function
  ;; will have its own environment, and the non-local exit mechanism will deal
  ;; with cleanups.
  (cleanup nil :type (or cleanup null))
  ;;
  ;; A list of all the functions directly called from this function (or one of
  ;; its lets) using a non-let local call.
  (calls () :type list)
  ;;
  ;; The Tail-Set that this lambda is in.  Null when Return is null.
  (tail-set nil :type (or tail-set null))
  ;;
  ;; The structure which represents the environment that this Function's
  ;; variables are allocated in.  This is filled in by environment analysis.
  ;; In a let, this is EQ to our home's environment.
  (environment nil :type (or environment null)))


(defprinter lambda
  name
  (type :test (not (eq type *universal-type*)))
  (where-from :test (not (eq where-from :assumed)))
  (vars :prin1 (mapcar #'leaf-name vars)))


;;; The Optional-Dispatch leaf is used to represent hairy lambdas.  If is a
;;; Functional, like Lambda.  Each legal number of arguments has a function
;;; which is called when that number of arguments is passed.  The function is
;;; called with all the arguments actually passed.  If additional arguments are
;;; legal, then the LEXPR style More-Entry handles them.  The value returned by
;;; the function is the value which results from calling the Optional-Dispatch.
;;;
;;; The theory is that each entry-point function calls the next entry
;;; point tail-recursively, passing all the arguments passed in and the default
;;; for the argument the entry point is for.  The last entry point calls the
;;; real body of the function.  In the presence of supplied-p args and other
;;; hair, things are more complicated.  In general, there is a distinct
;;; internal function that takes the supplied-p args as parameters.  The
;;; preceding entry point calls this function with NIL filled in for the
;;; supplied-p args, while the current entry point calls it with T in the
;;; supplied-p positions.
;;;
;;; Note that it is easy to turn a call with a known number of arguments into a
;;; direct call to the appropriate entry-point function, so functions that are
;;; compiled together can avoid doing the dispatch.
;;;
(defstruct (optional-dispatch (:include functional)
			      (:print-function %print-optional-dispatch))
  ;;
  ;; The original parsed argument list, for anyone who cares.
  (arglist nil :type list)
  ;;
  ;; True if &allow-other-keys was supplied.
  (allowp nil :type boolean)
  ;;
  ;; True if &key was specified.  (Doesn't necessarily mean that there are any
  ;; keyword arguments...)
  (keyp nil :type boolean)
  ;;
  ;; The number of required arguments.  This is the smallest legal number of
  ;; arguments.
  (min-args 0 :type unsigned-byte)
  ;;
  ;; The total number of required and optional arguments.  Args at positions >=
  ;; to this are rest, key or illegal args.
  (max-args 0 :type unsigned-byte)
  ;;
  ;; List of the Lambdas which are the entry points for non-rest, non-key
  ;; calls.  The entry for Min-Args is first, Min-Args+1 second, ... Max-Args
  ;; last.  The last entry-point always calls the main entry; in simple cases
  ;; it may be the main entry.
  (entry-points nil :type list)
  ;;
  ;; An entry point which takes Max-Args fixed arguments followed by an
  ;; argument context pointer and an argument count.  This entry point deals
  ;; with listifying rest args and parsing keywords.  This is null when extra
  ;; arguments aren't legal.  
  (more-entry nil :type (or clambda null))
  ;;
  ;; The main entry-point into the function, which takes all arguments
  ;; including keywords as fixed arguments.  The format of the arguments must
  ;; be determined by examining the arglist.  This may be used by callers that
  ;; supply at least Max-Args arguments and know what they are doing.
  (main-entry nil :type (or clambda null)))


(defprinter optional-dispatch
  name
  (type :test (not (eq type *universal-type*)))
  (where-from :test (not (eq where-from :assumed)))
  arglist
  min-args
  max-args
  (entry-points :test entry-points)
  (more-entry :test more-entry)
  main-entry)


;;; The Arg-Info structure allows us to tack various information onto
;;; Lambda-Vars during IR1 conversion.  If we use one of these things, then the
;;; var will have to be massaged a bit before it is simple and lexical.
;;;
(defstruct (arg-info (:print-function %print-arg-info))
  ;;
  ;; True if this arg is to be specially bound.
  (specialp nil :type boolean)
  ;;
  ;; The kind of argument being described.  Required args only have arg
  ;; info structures if they are special.
  (kind nil :type (member :required :optional :keyword :rest))
  ;;
  ;; If true, the Var for supplied-p variable of a keyword or optional arg.
  ;; This is true for keywords with non-constant defaults even when there is no
  ;; user-specified supplied-p var.
  (supplied-p nil :type (or lambda-var null))
  ;;
  ;; The default for a keyword or optional, represented as the original
  ;; Lisp code.  This is set to NIL in keyword arguments that are defaulted
  ;; using the supplied-p arg.
  (default nil :type t)
  ;;
  ;; The actual keyword for a keyword argument.
  (keyword nil :type (or keyword null)))

(defprinter arg-info
  (specialp :test specialp)
  kind
  (supplied-p :test supplied-p)
  (default :test default)
  (keyword :test keyword))


;;; The Lambda-Var structure represents a lexical lambda variable.  This
;;; structure is also used during IR1 conversion to describe lambda arguments
;;; which may ultimately turn out not to be simple and lexical.
;;;
;;; Lambda-Vars with no Refs are considered to be deleted; environment analysis
;;; isn't done on these variables, so the back end must check for and ignore
;;; unreferenced variables.  Note that a deleted lambda-var may have sets; in
;;; this case the back end is still responsible for propagating the Set-Value
;;; to the set's Cont.
;;;
(defstruct (lambda-var (:include basic-var)
		       (:print-function %print-lambda-var))
  ;;
  ;; True if this variable has been declared Ignore.
  (ignorep nil :type boolean)
  ;;
  ;; The Lambda that this var belongs to.  This may be null when we are
  ;; building a lambda during IR1 conversion.
  (home nil :type (or null clambda))
  ;;
  ;; This is set by environment analysis if it chooses an indirect (value cell)
  ;; representation for this variable because it is both set and closed over.
  (indirect nil :type boolean)
  ;;
  ;; The following two slots are only meaningful during IR1 conversion of hairy
  ;; lambda vars:
  ;;
  ;; The Arg-Info structure which holds information obtained from &keyword
  ;; parsing.
  (arg-info nil :type (or arg-info null))
  ;;
  ;; If true, the Global-Var structure for the special variable which is to be
  ;; bound to the value of this argument.
  (specvar nil :type (or global-var null))
  ;;
  ;; Set of the CONSTRAINTs on this variable.  Used by constraint
  ;; propagation.  This is left null by the lambda pre-pass if it determine
  ;; that this is a set closure variable, and is thus not a good subject for
  ;; flow analysis.
  (constraints nil :type (or sset null)))

(defprinter lambda-var
  name
  (type :test (not (eq type *universal-type*)))
  (where-from :test (not (eq where-from :assumed)))
  (ignorep :test ignorep)
  (arg-info :test arg-info)
  (specvar :test specvar))


;;;; Basic node types:

;;; A Ref represents a reference to a leaf.  Ref-Reoptimize is initially (and
;;; forever) NIL, since Refs don't receive any values and don't have any IR1
;;; optimizer.
;;;
(defstruct (ref (:include node (:reoptimize nil))
		(:constructor make-ref (derived-type source leaf inlinep))
		(:print-function %print-ref))
  ;;
  ;; The leaf referenced.
  (leaf nil :type leaf)
  ;;
  ;; For a function variable, indicates the legality of coding inline.  Nil,
  ;; means that there is no relevent declaration so we can do whatever we want.
  (inlinep nil :type inlinep))

(defprinter ref
  leaf
  (inlinep :test inlinep))


;;; Naturally, the IF node always appears at the end of a block.  Node-Cont is
;;; a dummy continuation, and is there only to keep people happy.
;;;
(defstruct (cif (:include node)
		(:print-function %print-if)
		(:conc-name if-)
		(:predicate if-p)
		(:constructor make-if)
		(:copier copy-if))
  ;;
  ;; Continuation for the predicate.
  (test nil :type continuation)
  ;;
  ;; The blocks that we execute next in true and false case, respectively (may
  ;; be the same.)
  (consequent nil :type cblock)
  (alternative nil :type cblock))

(defprinter if
  (test :prin1 (continuation-use test))
  consequent
  alternative)


(defstruct (cset (:include node
			   (:derived-type *universal-type*))
		 (:print-function %print-set)
		 (:conc-name set-)
		 (:predicate set-p)
		 (:constructor make-set)
		 (:copier copy-set))
  ;;
  ;; Descriptor for the variable set.
  (var nil :type basic-var)
  ;;
  ;; Continuation for the value form.
  (value nil :type continuation))

(defprinter set
  var
  (value :prin1 (continuation-use value)))


;;; The Basic-Combination structure is used to represent both normal and
;;; multiple value combinations.  In a local function call, this node appears
;;; at the end of its block and the body of the called function appears as the
;;; successor.  The NODE-CONT remains the continuation which receives the
;;; value of the call.
;;;
(defstruct (basic-combination (:include node))
  ;;
  ;; Continuation for the function.
  (fun nil :type continuation)
  ;;
  ;; List of continuations for the args.  In a local call, an argument
  ;; continuation may be replaced with NIL to indicate that the corresponding
  ;; variable is unreferenced, and thus no argument value need be passed.
  (args nil :type list)
  ;;
  ;; The kind of function call being made.  :Full is a standard call, with the
  ;; function being determined at run time.  :Local is used when we are calling
  ;; a function known at compile time.  The IR1 for the called function is
  ;; spliced into the flow graph for the caller.  Calls to known global
  ;; functions are represented by storing the Function-Info for the function in
  ;; this slot.
  (kind :full :type (or (member :full :local) function-info))
  ;;
  ;; Some kind of information attached to this node by the back end.
  (info nil))


;;; The Combination node represents all normal function calls, including
;;; FUNCALL.  This is distinct from Basic-Combination so that an MV-Combination
;;; isn't Combination-P.
;;;
(defstruct (combination (:include basic-combination)
			(:constructor make-combination (source fun))
			(:print-function %print-combination)))

(defprinter combination
  (fun :prin1 (continuation-use fun))
  (args :prin1 (mapcar #'(lambda (x)
			   (if x
			       (continuation-use x)
			       "<deleted>"))
		       args)))


;;; An MV-Combination is to Multiple-Value-Call as a Combination is to Funcall.
;;; This is used to implement all the multiple-value receiving forms.
;;;
(defstruct (mv-combination (:include basic-combination)
			   (:constructor make-mv-combination (source fun))
			   (:print-function %print-mv-combination)))

(defprinter mv-combination
  (fun :prin1 (continuation-use fun))
  (args :prin1 (mapcar #'continuation-use args)))


;;; The Bind node marks the beginning of a lambda body and represents the
;;; creation and initialization of the variables.
;;;
(defstruct (bind (:include node)
		 (:print-function %print-bind))
  ;;
  ;; The lambda we are binding variables for.  Null when we are creating the
  ;; Lambda during IR1 translation.
  (lambda nil :type (or clambda null)))

(defprinter bind
  lambda)


;;; The Return node marks the end of a lambda body.  It collects the return
;;; values and represents the control transfer on return.  This is also where
;;; we stick information used for Tail-Set type inference.
;;;
(defstruct (creturn (:include node)
		    (:print-function %print-return)
		    (:conc-name return-)
		    (:predicate return-p)
		    (:constructor make-return)
		    (:copier copy-return))
  ;;
  ;; The lambda we are returing from.  Null temporarily during ir1tran.
  (lambda nil :type (or clambda null))
  ;;
  ;; The continuation which yields the value of the lambda.
  (result nil :type continuation)
  ;;
  ;; The union of the node-derived-type of all uses of the result other than by
  ;; a local call, intersected with the result's asserted-type.  If there are
  ;; no non-call uses, this is *empty-type*.
  (result-type *wild-type* :type ctype))


(defprinter return
  lambda
  result-type)


;;;; Non-local exit support:
;;;
;;;    In IR1, we insert special nodes to mark potentially non-local lexical
;;; exits.


;;; The Entry node serves to mark the start of the dynamic extent of a lexical
;;; exit.  It is the mess-up node for the corresponding :Entry cleanup.
;;;
(defstruct (entry (:include node)
		  (:print-function %print-entry))
  ;;
  ;; All of the continuations for potential non-local exits to this point.
  (exits nil :type list))

(defprinter entry
  exits)


;;; The Exit node marks the place at which exit code would be emitted, if
;;; necessary.  This is interposed between the uses of the exit continuation
;;; and the exit continuation's DEST.  Instead of using the returned value
;;; being delivered directly to the exit continuation, it is delivered to our
;;; Value continuation.  The original exit continuation is the exit node's
;;; CONT.
;;;
(defstruct (exit (:include node)
		 (:print-function %print-exit))
  ;;
  ;; The Entry node that this is an exit for.  If null, this is a degenerate
  ;; exit.  A degenerate exit is used to "fill" an empty block (which isn't
  ;; allowed in IR1.)  In a degenerate exit, Value is always also null.
  (entry nil :type (or entry null))
  ;;
  ;; The continuation yeilding the value we are to exit with.  If NIL, then no
  ;; value is desired (as in GO).
  (value nil :type (or continuation null)))

(defprinter exit
  (entry :test entry)
  (value :test value))


;;;; Miscellaneous IR1 structures:

(defstruct (unknown-function
	    (:print-function
	     (lambda (s stream d)
	       (declare (ignore d))
	       (format stream "#<Unknown-Function ~S>"
		       (unknown-function-name s)))))
  ;;
  ;; The name of the unknown function called.
  (name nil :type (or symbol list))
  ;;
  ;; The number of times this function was called.
  (count 0 :type unsigned-byte)
  ;;
  ;; A list of COMPILER-ERROR-CONTEXT structures describing places where this
  ;; function was called.  Note that we only record the first
  ;; *UNKNOWN-FUNCTION-WARNING-LIMIT* calls.
  (warnings () :type list))
