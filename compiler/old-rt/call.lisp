;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;;    This file contains the VM definition of function call for the RT.
;;;
;;; Written by Rob MacLachlan
;;;
(in-package 'c)


;;;; Interfaces to IR2 conversion:

;;; Standard-Argument-Location  --  Interface
;;;
;;;    Return a wired TN describing the N'th full call argument passing
;;; location.
;;;
(defun standard-argument-location (n)
  (declare (type unsigned-byte n))
  (if (< n register-arg-count)
      (make-wired-tn *any-primitive-type* register-arg-scn
		     (elt register-arg-offsets n))
      (make-wired-tn *any-primitive-type* stack-arg-scn n)))


;;; Make-Return-PC-Passing-Location  --  Interface
;;;
;;;    Make a passing location TN for a local call return PC.  If standard is
;;; true, then use the standard (full call) location, otherwise use any legal
;;; location.  Even in the non-standard case, this may be restricted by a
;;; desire to use a subroutine call instruction.
;;;
(defun make-return-pc-passing-location (standard)
  (if standard
      (make-wired-tn *any-primitive-type* register-arg-scn return-pc-offset)  
      (make-restricted-tn *any-primitive-type* (list register-arg-scn))))


;;; Make-Old-Cont-Passing-Location  --  Interface
;;;
;;;    Similar to Make-Return-PC-Passing-Location, but makes a location to pass
;;; Old-Cont in.  This is (obviously) wired in the standard convention, but is
;;; totally unrestricted in non-standard conventions, since we can always fetch
;;; it off of the stack using the arg pointer.
;;;
(defun make-old-cont-passing-location (standard)
  (if standard
      (make-wired-tn *any-primitive-type* register-arg-scn old-cont-offset)
      (make-normal-tn *any-primitive-type*)))


;;; Make-Old-Cont-Save-Location, Make-Return-PC-Save-Location  --  Interface
;;;
;;;    Make the TNs used to hold Old-Cont and Return-PC within the current
;;; function.  We treat these specially so that the debugger can find them at a
;;; known location.
;;;
(defun make-old-cont-save-location (env)
  (make-wired-environment-tn *any-primitive-type*
			     stack-arg-scn old-cont-save-offset
			     env))
;;;
(defun make-return-pc-save-location (env)
  (make-wired-environment-tn *any-primitive-type*
			     stack-arg-scn return-pc-save-offset
			     env))


;;; Make-Argument-Pointer-Location  --  Interface
;;;
;;;    Similar to Make-Return-PC-Passing-Location, but makes a location to pass
;;; an argument pointer in.  Even when non-standard locations are allowed, this
;;; must be restricted to a register, since the argument pointer is used to
;;; fetch stack arguments.
;;;
(defun make-argument-pointer-location (standard)
  (if standard
      (make-wired-tn *any-primitive-type* register-arg-scn
		     argument-pointer-offset)
      (make-restricted-tn *any-primitive-type* (list register-arg-scn))))


;;; Make-Argument-Count-Location  --  Interface
;;;
;;;    Make a TN for the standard argument count passing location.  We only
;;; need to make the standard location, since a count is never passed when we
;;; are using non-standard conventions.
;;;
(defun make-argument-count-location ()
  (make-wired-tn *any-primitive-type* register-arg-scn argument-count-offset))


;;; Select-Component-Format  --  Interface
;;;
;;;    This function is called by the Entry-Analyze phase, allowing
;;; VM-dependent initialization of the IR2-Component structure.  We push
;;; placeholder entries in the Constants to leave room for the component name,
;;; code vector and debug info.
;;;
(defun select-component-format (component)
  (declare (type component component))
  (dotimes (i 3)
    (vector-push-extend nil
			(ir2-component-constants (component-info component))))
  (undefined-value))


;;;; Argument/value passing, frame hackery:

;;; Fetch the argument Arg using the argument pointer Argp, yeilding the value
;;; Val.  This operation is used at function entry to move the arguments from
;;; their passing locations to the appropriate variable.
;;;
(define-vop (move-argument)
  (:args (arg :scs (any-reg descriptor-reg)  :load nil  :target val)
	 (argp :scs (descriptor-reg)))
  (:results (val :scs (any-reg descriptor-reg)))
  (:generator 0
    (sc-case arg
      (stack
       (loadw val argp (tn-offset arg)))
      ((any-reg descriptor-reg)
       (unless (location= arg val)
	 (inst lr val arg))))))


;;; Similar to Move-Argument, but is used to store known values into the frame
;;; being returned into.  In this case, it is Loc that is potentially on the
;;; stack in a different frame.
;;;
(define-vop (move-value)
  (:args (value :scs (any-reg descriptor-reg)
		:target loc)
	 (old-cont :scs (descriptor-reg)))
  (:results (loc :scs (any-reg descriptor-reg)  :load nil))
  (:generator 0
    (sc-case loc
      (stack
       (storew value old-cont (tn-offset loc)))
      ((any-reg descriptor-reg)
       (unless (location= loc value)
	 (inst lr loc value))))))


;;; Used for setting up the Old-Cont in local call.
;;;
(define-vop (current-cont)
  (:results (val :scs (any-reg descriptor-reg)))
  (:generator 1
    (inst lr val cont-tn)))


;;; Default-Unknown-Values  --  Internal
;;;
;;;    Emit code needed at the return-point from an unknown-values call for a
;;; fixed number of values.  Values is the head of the TN-Ref list for the
;;; locations that the values are to be received into.  Nvals is the number of
;;; values that are to be received (should equal the length of Values).  Node
;;; is the node to use for source context in emitted code.
;;;
;;;    Move-Temp and Nil-Temp are Descriptor-Reg TNs used as temporaries.
;;;
;;;    This code exploits the fact that in the unknown-values convention, a
;;; single value return returns at the return PC + 4, whereas a return of other
;;; than one value returns directly at the return PC.
;;;
;;;    If 0 or 1 values are expected, then we just emit an instruction to reset
;;; the SP (which will only be executed when other than 1 value is returned.)
;;;
;;; In the general case, we have to do three things:
;;;  -- Default unsupplied register values.  This need only be done when a
;;;     single value is returned, since register values are defaulted by the
;;;     called in the non-single case.
;;;  -- Default unsupplied stack values.  This needs to be done whenever there
;;;     are stack values.
;;;  -- Reset SP.  This must be done whenever other than 1 value is returned,
;;;     regardless of the number of values desired.
;;;
;;; The general-case code looks like this:
#|
	br regs-defaulted		; Skip if MVs
	cau a1 0 nil-16			; Default register values
	...
	loadi nargs 1			; Force defaulting of stack values
	lr args sp			; Set up args for SP resetting

regs-defaulted
	cau nil-temp 0 nil-16		; Cache nil

	cmpi nargs 3			; If 4'th value unsupplied...
	blex default-value-4		;    jump to default code
	loadw move-temp args-tn 3	; Move value to correct location.
	store-stack-tn val4-tn move-temp

	cmpi nargs 4			; Check 5'th value, etc.
	blex default-value-5
	loadw move-temp args-tn 4
	store-stack-tn val5-tn move-temp

	...

defaulting-done
	lr sp args			; Reset SP.
<end of code>

<elsewhere>
default-value-4 
	store-stack-tn val4-tn nil-temp ; Nil out 4'th value.

default-value-5
	store-stack-tn val5-tn nil-temp ; Nil out 5'th value.

	...

	br defaulting-done
|#
;;;
(defun default-unknown-values (node values nvals move-temp nil-temp)
  (declare (type node node) (type (or tn-ref null) values)
	   (type unsigned-byte nvals) (type tn move-temp nil-temp))
  (assemble node
    (if (<= nvals 1)
	(inst ai sp-tn args-tn 0)
	(let ((regs-defaulted (gen-label))
	      (defaulting-done (gen-label)))
	  (inst bnb :pz regs-defaulted)

	  (do ((i 1 (1+ i))
	       (val (tn-ref-across values) (tn-ref-across val)))
	      ((= i (min nvals register-arg-count)))
	    (inst cau (tn-ref-tn val) zero-tn clc::nil-16))
	  (when (> nvals register-arg-count)
	    (loadi nargs-tn 1)
	    (inst lr args-tn sp-tn))

	  (emit-label regs-defaulted)

	  (when (> nvals register-arg-count)
	    (inst cau nil-temp zero-tn clc::nil-16)

	    (collect ((defaults))
	      (do ((i register-arg-count (1+ i))
		   (val (do ((i 0 (1+ i))
			     (val values (tn-ref-across val)))
			    ((= i register-arg-count) val))
			(tn-ref-across val)))
		  ((null val))
		
		(let ((default-lab (gen-label))
		      (tn (tn-ref-tn val)))
		  (defaults (cons default-lab tn))
		  (cmpi nargs-tn i)
		  (inst bnbx :gt default-lab)
		  (loadw move-temp args-tn i)
		  (store-stack-tn tn move-temp)))

	      (emit-label defaulting-done)
	      (inst lr sp-tn args-tn)

	      (unassemble
	       (assemble-elsewhere node
		 (dolist (def (defaults))
		   (emit-label (car def))
		   (store-stack-tn (cdr def) nil-temp))
		 (inst bnb :pz defaulting-done))))))))
  (undefined-value))


;;;; Unknown values receiving:

;;; Receive-Unknown-Values  --  Internal
;;;
;;;    Emit code needed at the return point for an unknown-values call for an
;;; arbitrary number of values.
;;;
;;;    We do the single and non-single cases with no shared code: there doesn't
;;; seem to be any potential overlap, and receiving a single value is more
;;; important efficiency-wise.
;;;
;;;    When there is a single value, we just push it on the stack, returning
;;; the old SP and 1.
;;;
;;;    When there is a variable number of values, we move all of the argument
;;; registers onto the stack, and return Args and Nargs.
;;;
;;;    Args and Nargs are TNs wired to the named locations.  We must
;;; explicitly allocate these TNs, since their lifetimes overlap with the
;;; results Start and Count (also, it's nice to be able to target them).
;;;
(defun receive-unknown-values (node args nargs start count)
  (declare (type node node) (type tn args nargs start count))
  (assemble node
    (let ((variable-values (gen-label))
	  (done (gen-label)))
      (inst bnb :pz variable-values)

      (inst inc sp-tn 4)
      (storew (first register-argument-tns) sp-tn -1)
      (inst cal start sp-tn -4)
      (loadi count 1)

      (emit-label done)

      (unassemble
	(assemble-elsewhere node
	  (emit-label variable-values)
	  (do ((arg register-argument-tns (rest arg))
	       (i 0 (1+ i)))
	      ((null arg))
	    (storew (first arg) args i))
	  (unless (location= start args)
	    (inst lr start args))
	  (unless (location= count nargs)
	    (inst lr count nargs))
	  (inst bnb :pz done)))))
  (undefined-value))


;;; VOP that can be inherited by unknown values receivers.  The main thing this
;;; handles is allocation of the result temporaries.
;;;
(define-vop (unknown-values-receiver)
  (:results
   (start :scs (descriptor-reg))
   (count :scs (descriptor-reg)))
  (:node-var node)
  (:temporary (:sc descriptor-reg
	       :offset argument-pointer-offset
	       :from :eval  :to (:result 0))
	      values-start)
  (:temporary (:sc any-reg
	       :offset argument-count-offset
	       :from :eval  :to (:result 1))
	      nvals))


;;;; Tail-recursive local call:

;;; We just do the control transfer.  The other stuff is done with explicit
;;; move VOPs.
;;;
(define-vop (tail-call-local)
  (:args
   (args :more t))
  (:info start)
  (:ignore args)
  (:generator 5
    (when start
      (inst bnb :pz start))))


;;;; Local call with unknown values convention return:

;;; Non-TR local call for a fixed number of values passed according to the
;;; unknown values convention.
;;;
;;; Args are the argument passing locations, which are specified only to
;;; terminate their lifetimes in the caller.
;;;
;;; Values are the return value locations (wired to the standard passing
;;; locations).
;;;
;;; Save is the save info, which we can ignore since saving has been done.
;;; Return-PC is the TN that the return PC should be passed in.
;;; Target is a continuation pointing to the start of the called function.
;;; Nvals is the number of values received.
;;;
(define-vop (call-local)
  (:args (args :more t))
  (:results (values :more t))
  (:save-p t)
  (:info save return-pc target nvals)
  (:ignore args save)
  (:node-var node)
  (:temporary (:scs (descriptor-reg)) move-temp nil-temp)
  (:temporary (:sc stack
	       :offset env-save-offset)
	      env-save)
  (:generator 5
    (store-stack-tn env-save env-tn)
    (inst lr cont-tn sp-tn)
    (inst balix return-pc target)
    (inst cal sp-tn sp-tn (current-frame-size))
    (unassemble
      (default-unknown-values node values nvals move-temp nil-temp))
    (load-stack-tn env-tn env-save)))


;;; Non-TR local call for a variable number of return values passed according
;;; to the unknown values convention.  The results are the start of the values
;;; glob and the number of values received.
;;;
(define-vop (multiple-call-local unknown-values-receiver)
  (:args (args :more t))
  (:save-p t)
  (:info save return-pc target)
  (:ignore args save)
  (:temporary (:sc stack
	       :offset env-save-offset)
	      env-save)
  (:generator 20
    (store-stack-tn env-save env-tn)
    (inst lr cont-tn sp-tn)
    (inst balix return-pc target)
    (inst cal sp-tn sp-tn (current-frame-size))
    (unassemble
      (receive-unknown-values node values-start nvals start count))
    (load-stack-tn env-tn env-save)))


;;;; Local call with known values return:

;;; Non-TR local call with known return locations.  Known-value return works
;;; just like argument passing in local call.
;;;
(define-vop (known-call-local)
  (:args
   (args :more t))
  (:results
   (res :more t))
  (:save-p t)
  (:info save return-pc target)
  (:ignore args res save)
  (:generator 5
    (inst lr cont-tn sp-tn)
    (inst balix return-pc target)
    (inst cal sp-tn sp-tn (current-frame-size))))


;;; Return from known values call.  We receive the return locations as
;;; arguments to terminate their lifetimes in the returning function.  We
;;; restore CONT and SP and jump to the Return-PC.
;;;
(define-vop (known-return)
  (:args
   (old-cont :scs (descriptor-reg))
   (return-pc :scs (descriptor-reg))
   (locs :more t))
  (:ignore locs)
  (:generator 6
    (inst lr sp-tn cont-tn)
    (inst bnbrx :pz return-pc)
    (inst lr cont-tn old-cont)))


;;;; Full call:
;;;
;;;    There is something of a cross-product effect with full calls.  Different
;;; versions are used depending on whether we know the number of arguments or
;;; the name of the called function, and whether we want fixed values, unknown
;;; values, or a tail call.

;;; In full call, the arguments are passed by placing them in TNs wired to the
;;; beginning of the current frame (as done by Standard-Argument-Location).  A
;;; pointer to these arguments is then passed as the argument pointer.


;;; Define-Full-Call  --  Internal
;;;
;;;    This macro helps in the definition of full call VOPs by avoiding code
;;; replication in defining the cross-product VOPs.
;;;
;;; Name is the name of the VOP to define.
;;; 
;;; Named is true if the first argument is a symbol whose global function
;;; definition is to be called.
;;;
;;; Return is either :Fixed, :Unknown or :Tail:
;;; -- If :Fixed, then the call is for a fixed number of values, returned in
;;;    the standard passing locations (passed as result operands).
;;; -- If :Unknown, then the result values are pushed on the stack, and the
;;;    result values are specified by the Start and Count as in the
;;;    unknown-values continuation representation.
;;; -- If :Tail, then do a tail-recursive call.  No values are returned.
;;;    The Old-Cont and Return-PC are passed as the second and third arguments.
;;;
;;; Variable is true if there are a variable number of arguments passed on the
;;; stack, with the last argument pointing to the beginning of the arguments.
;;; If Variable is false, the arguments are set up in the standard passing
;;; locations and are passed as the remaining arguments.  Variable cannot be
;;; specified with :Tail return.  TR variable argument call is implemented
;;; separately.
;;;
(defmacro define-full-call (name named return variable)
  (assert (not (and variable (eq return :tail))))
  `(define-vop (,name
		,@(when (eq return :unknown)
		    '(unknown-values-receiver)))
     (:args
      ,(if named
	   '(name :scs (descriptor-reg)
		  :target name-pass)
	   '(arg-fun :scs (descriptor-reg)
		     :target function))
      
      ,@(when (eq return :tail)
	  '((old-cont :scs (descriptor-reg)
		      :target old-cont-pass)
	    (return-pc :scs (descriptor-reg)
		       :target return-pc-pass)))
      
      ,(if variable
	   '(args :scs (descriptor-reg)
		  :target args-pass)
	   '(args :more t)))

     ,@(when (eq return :fixed)
	 '((:results (values :more t))))
   
     ,@(unless (eq return :tail)
	 '((:save-p t)
	   (:node-var node)
	   (:temporary (:sc stack
			:offset env-save-offset)
		       env-save)))

     (:info ,@(unless (eq return :tail) '(save))
	    ,@(unless variable '(nargs))
	    ,@(when (eq return :fixed) '(nvals)))

     (:ignore
      ,@(unless (eq return :tail) '(save))
      ,@(unless variable '(args)))

     (:temporary (:sc descriptor-reg
		  :offset old-cont-offset
		  :from (:argument ,(if (eq return :tail) 1 0))
		  :to :eval)
		 old-cont-pass)

     (:temporary (:sc descriptor-reg
		  :offset return-pc-offset
		  :from (:argument ,(if (eq return :tail) 2 0))
		  :to :eval)
		 return-pc-pass)

     ,@(when named 
	 '((:temporary (:sc descriptor-reg
			:offset call-name-offset
			:from (:argument 0)
			:to :eval)
		       name-pass)))

     (:temporary (:scs (descriptor-reg)
		       :from (:argument 0)
		       :to :eval)
		 function)

     (:temporary (:sc descriptor-reg
		  :offset argument-pointer-offset
		  :from (:argument ,(if variable 1 0))
		  :to :eval)
		 args-pass)

     (:temporary (:sc descriptor-reg
		  :offset argument-count-offset
		  :to :eval)
		 nargs-pass)

     ,@(when variable
	 '((:temporary (:sc descriptor-reg
			:offset (first register-arg-offsets)
			:to :eval)
		       a0)
	   (:temporary (:sc descriptor-reg
			:offset (second register-arg-offsets)
			:to :eval)
		       a1)
	   (:temporary (:sc descriptor-reg
			:offset (third register-arg-offsets)
			:to :eval)
		       a2)))

     ,@(when (eq return :fixed)
	 '((:temporary (:scs (descriptor-reg)
			:from :eval)
		       move-temp nil-temp)))

     (:temporary (:scs (descriptor-reg)
		  :to :eval)
		 code offset)

     (:generator ,(+ (if named 5 0)
		     (if variable 19 1)
		     (if (eq return :tail) 0 10)
		     15
		     (if (eq return :unknown) 25 0))
       
       ,@(if named
	     `((unless (location= name name-pass)
		 (inst lr name-pass name))
	       (loadw function name-pass (/ clc::symbol-definition 4)))
	     `((unless (location= arg-fun function)
		 (inst lr function arg-fun))))
       
       ,@(if variable
	     `((unless (location= args args-pass)
		 (inst lr args-pass args))
	       (inst lr nargs-pass sp-tn)
	       (inst s nargs-pass args-pass)
	       (inst sari nargs-pass 2)
	       (loadw a0 args-pass 0)
	       (loadw a1 args-pass 1)
	       (loadw a2 args-pass 2))
	     `((loadi nargs-pass nargs)
	       (inst lr args-pass cont-tn)))
       
       (load-slot code function system:%function-code-slot)
       (load-slot offset function system:%function-offset-slot)
       (inst cas code code offset)
       
       ,@(if (eq return :tail)
	     '((unless (location= old-cont old-cont-pass)
		 (inst lr old-cont-pass old-cont))
	       (unless (location= return-pc return-pc-pass)
		 (inst lr return-pc-pass return-pc))
	       (inst bnbrx :pz code)
	       (inst lr env-tn function))
	     '((store-stack-tn env-save env-tn)
	       (inst lr old-cont-pass cont-tn)
	       (inst lr cont-tn sp-tn)
	       (inst balrx return-pc-pass code)
	       (inst lr env-tn function)
	       (no-op)))
       
       ,@(ecase return
	   (:fixed
	    '((unassemble
	       (default-unknown-values node values nvals move-temp nil-temp))))
	   (:unknown
	    '((unassemble
	       (receive-unknown-values node values-start nvals start count))))
	   (:tail))
       
       ,@(unless (eq return :tail)
	   '((load-stack-tn env-tn env-save))))))


(define-full-call call nil :fixed nil)
(define-full-call call-named t :fixed nil)
(define-full-call multiple-call nil :unknown nil)
(define-full-call multiple-call-named t :unknown nil)
(define-full-call tail-call nil :tail nil)
(define-full-call tail-call-named t :tail nil)

(define-full-call call-variable nil :fixed t)
(define-full-call multiple-call-variable nil :unknown t)


;;; Defined separately, since needs a MISCOP call that BLT's the arguments
;;; down.
;;;
;;; This miscop uses a non-standard calling convention so that the argument
;;; registers are free for loading of stack arguments.  Old-Cont, Args and the
;;; function are passed in the registers that they will ultimately go in:
;;; OLD-CONT, ARGS and ENV.  The Return-PC is passed in A3 rather than PC
;;; because the BALA trashes PC.  We use BALA even though the miscop never
;;; returns, since there isn't any BA.
;;;
;;; [### We could easily code inline the special case of nargs <= 3.]
;;;
(define-vop (tail-call-variable)
  (:args
   (function :scs (descriptor-reg))
   (old-cont :scs (descriptor-reg)
	     :target old-cont-pass)
   (return-pc :scs (descriptor-reg)
	      :target a3)
   (args :scs (descriptor-reg)
	 :target args-pass))
  (:temporary (:sc descriptor-reg
	       :offset old-cont-offset
	       :from (:argument 1))
	      old-cont-pass)
  (:temporary (:sc descriptor-reg
	       :offset a3-offset
	       :from (:argument 2))
	      a3)
  (:temporary (:sc descriptor-reg
	       :offset argument-pointer-offset
	       :from (:argument 3))
	      args-pass)
  (:generator 75
    (inst lr env-tn function)
    (unless (location= old-cont old-cont-pass)
      (inst lr old-cont-pass old-cont))
    (unless (location= return-pc a3)
      (inst lr a3 return-pc))
    (unless (location= args args-pass)
      (inst lr args-pass args))
    (inst miscop 'clc::tail-call-variable)))


;;;; Unknown values return:


;;; Do unknown-values return of a fixed number of values.  The Values are
;;; required to be set up in the standard passing locations.  Nvals is the
;;; number of values returned.
;;;
;;; If returning a single value, then deallocate the current frame, restore
;;; CONT and jump to the single-value entry at Return-PC + 4.
;;;
;;; If returning other than one value, then load the number of values returned,
;;; NIL out unsupplied values registers, restore CONT and return at Return-PC.
;;; When there are stack values, we must initialize the argument pointer to
;;; point to the beginning of the values block (which is the beginning of the
;;; current frame.)
;;;
(define-vop (return)
  (:args
   (old-cont :scs (descriptor-reg any-reg))
   (return-pc :scs (descriptor-reg) :target pc-save)
   (values :more t))
  (:ignore values)
  (:info nvals)
  (:temporary (:scs (descriptor-reg) :from (:argument 0)) pc-save)
  (:temporary (:sc descriptor-reg
	       :offset (first register-arg-offsets)
	       :from (:eval 0)
	       :to (:eval 1))
	      a0)
  (:temporary (:sc descriptor-reg
	       :offset (second register-arg-offsets)
	       :from (:eval 0)
	       :to (:eval 1))
	      a1)
  (:temporary (:sc descriptor-reg
	       :offset (third register-arg-offsets)
	       :from (:eval 0)
	       :to (:eval 1))
	      a2)
  (:temporary (:sc descriptor-reg
	       :offset argument-count-offset)
	      nvals-loc)
  (:temporary (:sc descriptor-reg
	       :offset argument-pointer-offset)
	      vals-loc)
  (:generator 6
    (cond ((= nvals 1)
	   (inst lr sp-tn cont-tn)
	   (inst inc return-pc 4)
	   (inst bnbrx :pz return-pc)
	   (inst lr cont-tn old-cont))
	  (t
	   (loadi nvals-loc nvals)
	   (inst lr vals-loc cont-tn)
	   (inst cal sp-tn vals-loc (* nvals 4))
	   (inst lr cont-tn old-cont)

	   (unless (location= pc-save return-pc)
	     (inst lr pc-save return-pc))

	   (when (< nvals 3)
	     (inst cau a2 zero-tn clc::nil-16)
	     (when (< nvals 2)
	       (inst lr a1 a2))
	     (when (< nvals 1)
	       (inst lr a0 a2)))

	   (inst bnbr :pz pc-save)))))


;;; Do unknown-values return of an arbitrary number of values (passed on the
;;; stack.)  We check for the common case of a single return value, and do that
;;; inline using the normal single value return convention.  Otherwise, we
;;; branch off to code that calls a miscop.
;;;
;;; The Return-Multiple miscop uses a non-standard calling convention.  For one
;;; thing, it doesn't return.  We only use BALA because there isn't a BA
;;; instruction.   Also, we don't use A0..A2 for argument passing, since the
;;; miscop will want to load these with values off of the stack.  Instead, we
;;; pass Old-Cont, Start and Count in the normal locations for these values.
;;; Return-PC is passed in A3 since PC is trashed by the BALA. 
;;;
(define-vop (return-multiple)
  (:args
   (old-cont :scs (descriptor-reg) :target old-cont-pass)
   (return-pc :scs (descriptor-reg)
	      :target a3)
   (start :scs (descriptor-reg)
	  :target vals-loc)
   (count :scs (descriptor-reg)
	  :target nvals-loc))
  (:temporary (:sc descriptor-reg
	       :offset old-cont-offset
	       :from (:argument 0))
	      old-cont-pass)
  (:temporary (:sc descriptor-reg
	       :offset a3-offset
	       :from (:argument 1))
	      a3)
  (:temporary (:sc descriptor-reg
	       :offset argument-pointer-offset
	       :from (:argument 2))
	      vals-loc)
  (:temporary (:sc descriptor-reg
	       :offset argument-count-offset
	       :from (:argument 3))
	      nvals-loc)
  (:temporary (:sc descriptor-reg
	       :offset (first register-arg-offsets))
	      a0)
  (:node-var node)
  (:generator 13
    (let ((non-single (gen-label)))
      (cmpi count 1)
      (inst bnbx :eq non-single)
      (loadw a0 start)
      (inst lr sp-tn cont-tn)
      (inst inc return-pc 4)
      (inst bnbrx :pz return-pc)
      (inst lr cont-tn old-cont)

      (unassemble
	(assemble-elsewhere node
	  (emit-label non-single)
	  (unless (location= old-cont-pass old-cont)
	    (inst lr old-cont-pass old-cont))
	  (unless (location= a3 return-pc)
	    (inst lr a3 return-pc))
	  (unless (location= vals-loc start)
	    (inst lr vals-loc start))
	  (unless (location= nvals-loc count)
	    (inst lr nvals-loc count))
	  (inst miscop 'clc::return-multiple))))))


;;;; XEP hackery:


(define-vop (allocate-frame)
  (:generator 1
    (inst cal sp-tn cont-tn (current-frame-size))))

;;; Fetch the constant pool from the function entry structure.
;;;
(define-vop (setup-environment)
  (:generator 5
    (load-slot env-tn env-tn system:%function-entry-constants-slot)))

;;; Return the current Env as our result, then indirect throught the closure
;;; and the closure-entry to find the constant pool
;;;
(define-vop (setup-closure-environment)
  (:results (closure :scs (descriptor-reg)))
  (:generator 11
    (inst lr closure env-tn)
    (load-slot env-tn env-tn system:%function-name-slot)
    (load-slot env-tn env-tn system:%function-entry-constants-slot)))


;;; Copy a more arg from the argument area to the end of the current frame.
;;; Fixed is the number of non-more arguments.  This definition and the
;;; associated miscop assume that all the arguments and stuff are in their
;;; passing registers, and that all other non-dedicated registers are free.
;;;
;;; We sleazily save the return PC in NAME so that we can do a miscop call.
;;;
(define-vop (copy-more-arg)
  (:temporary (:sc descriptor-reg :offset a3-offset) a3)
  (:temporary (:sc descriptor-reg :offset call-name-offset) name)
  (:info fixed)
  (:generator 20
    (loadi a3 fixed)
    (inst lr name pc-tn)
    (inst miscop 'clc::copy-more-arg)
    (inst lr pc-tn name)))


;;; More args are stored consequtively on the stack, starting immediately at
;;; the context pointer.
;;;
(define-vop (more-arg word-index-ref)
  (:variant 0)
  (:translate %more-arg))


;;; Turn more arg (context, count) into a list.  Context and count are passed
;;; in ARGS and NARGS.
;;;
(define-vop (listify-rest-args zero-arg-miscop)
  (:args (context :target args :scs (any-reg descriptor-reg))
	 (count :target nargs :scs (any-reg descriptor-reg)))
  (:temporary (:sc any-reg
	       :offset argument-pointer-offset
	       :from (:argument 0)
	       :to :eval)
	      args)
  (:temporary (:sc any-reg
	       :offset argument-count-offset
	       :from (:argument 1)
	       :to :eval)
	      nargs)
  (:variant-vars)
  (:translate %listify-rest-args)
  (:generator 50
    (unless (location= context args)
      (inst lr args context))
    (unless (location= count nargs)
      (inst lr nargs count))
    (inst miscop 'clc::listify-rest-args)
    (unless (location= a0 r)
      (inst lr r a0))))


;;; Return the location and size of the more arg glob created by Copy-More-Arg.
;;; Supplied is the total number of arguments supplied (originally passed in
;;; NARGS.)  Fixed is the number of non-rest arguments.
;;;
;;; We must duplicate some of the work done by Copy-More-Arg, since at that
;;; time the environment is in a pretty brain-damaged state, preventing this
;;; info from being returned as values.  What we do is compute
;;; supplied - fixed, and return a pointer that many words below the current
;;; stack top.
;;;
(define-vop (more-arg-context)
  (:args
   (supplied :scs (any-reg descriptor-reg)))
  (:info fixed)
  (:results
   (context :scs (descriptor-reg))
   (count :scs (any-reg descriptor-reg)))
  (:temporary (:scs (any-reg) :type fixnum) byte-size)
  (:generator 5
    (inst ai count supplied (- fixed))
    (inst lr byte-size count)
    (inst sli byte-size 2)
    (inst lr context sp-tn)
    (inst s context byte-size)))


;;; Signal wrong argument count error if Nargs isn't = to Count.
;;;
(define-vop (verify-argument-count)
  (:args
   (nargs :scs (any-reg descriptor-reg)))
  (:info count)
  (:node-var node)
  (:generator 3
    (let ((err-lab (generate-error-code
		    node clc::error-wrong-number-args nargs)))
      (cmpi nargs count)
      (inst bnb :eq err-lab))))


;;; Signal an argument count error.
;;;
(define-vop (argument-count-error)
  (:args (nargs :scs (any-reg descriptor-reg)))
  (:generator 0
    (error-call clc::error-wrong-number-args nargs)))
