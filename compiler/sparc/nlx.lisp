;;; -*- Package: SPARC -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;; $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/compiler/sparc/nlx.lisp,v 1.2 1990/12/01 16:33:49 wlott Exp $
;;;
;;;    This file contains the definitions of VOPs used for non-local exit
;;; (throw, lexical exit, etc.)
;;;
;;; Written by Rob MacLachlan
;;;
(in-package "SPARC")

;;; MAKE-NLX-SP-TN  --  Interface
;;;
;;;    Make an environment-live stack TN for saving the SP for NLX entry.
;;;
(def-vm-support-routine make-nlx-sp-tn (env)
  (environment-live-tn
   (make-representation-tn *fixnum-primitive-type* immediate-arg-scn)
   env))



;;; Save and restore dynamic environment.
;;;
;;;    These VOPs are used in the reentered function to restore the appropriate
;;; dynamic environment.  Currently we only save the Current-Catch and binding
;;; stack pointer.  We don't need to save/restore the current unwind-protect,
;;; since unwind-protects are implicitly processed during unwinding.  If there
;;; were any additional stacks, then this would be the place to restore the top
;;; pointers.


;;; Make-Dynamic-State-TNs  --  Interface
;;;
;;;    Return a list of TNs that can be used to snapshot the dynamic state for
;;; use with the Save/Restore-Dynamic-Environment VOPs.
;;;
(def-vm-support-routine make-dynamic-state-tns ()
  (make-n-tns 5 *any-primitive-type*))

(define-vop (save-dynamic-state)
  (:results (catch :scs (descriptor-reg))
	    (special :scs (descriptor-reg))
	    (nfp :scs (descriptor-reg))
	    (nsp :scs (descriptor-reg))
	    (eval :scs (descriptor-reg)))
  (:vop-var vop)
  (:generator 13
    (load-symbol-value catch lisp::*current-catch-block*)
    (move special bsp-tn)
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
	(move nfp cur-nfp)))
    (move nsp nsp-tn)
    (load-symbol-value eval lisp::*eval-stack-top*)))

(define-vop (restore-dynamic-state)
  (:args (catch :scs (descriptor-reg))
	 (special :scs (descriptor-reg))
	 (nfp :scs (descriptor-reg))
	 (nsp :scs (descriptor-reg))
	 (eval :scs (descriptor-reg)))
  (:temporary (:scs (descriptor-reg)) symbol value)
  (:vop-var vop)
  (:generator 10
    (let ((done (gen-label))
	  (skip (gen-label))
	  (loop (gen-label)))

      (store-symbol-value catch lisp::*current-catch-block*)
      (store-symbol-value eval lisp::*eval-stack-top*)
      (let ((cur-nfp (current-nfp-tn vop)))
	(when cur-nfp
	  (move cur-nfp nfp)))
      (move nsp-tn nsp)
      
      (inst cmp special bsp-tn)
      (inst b :eq done)
      (inst nop)

      (emit-label loop)
      (loadw symbol bsp-tn (- binding-symbol-slot binding-size))
      (inst cmp symbol)
      (inst b :eq skip)
      (loadw value bsp-tn (- binding-value-slot binding-size))
      (storew value symbol vm:symbol-value-slot vm:other-pointer-type)
      (storew zero-tn bsp-tn (- binding-symbol-slot binding-size))
      (emit-label skip)
      (inst add bsp-tn bsp-tn (* -2 vm:word-bytes))
      (inst cmp bsp-tn special)
      (inst b :ne loop)
      (inst nop)

      (emit-label done))))

(define-vop (current-stack-pointer)
  (:results (res :scs (any-reg descriptor-reg)))
  (:generator 1
    (move res csp-tn)))

(define-vop (current-binding-pointer)
  (:results (res :scs (any-reg descriptor-reg)))
  (:generator 1
    (move res bsp-tn)))



;;;; Unwind block hackery:

;;; Compute the address of the catch block from its TN, then store into the
;;; block the current Fp, Env, Unwind-Protect, and the entry PC.
;;;
(define-vop (make-unwind-block)
  (:args (tn))
  (:info entry-label)
  (:results (block :scs (any-reg)))
  (:temporary (:scs (descriptor-reg)) temp)
  (:temporary (:scs (non-descriptor-reg)) ndescr)
  (:generator 22
    (inst add block cfp-tn (* (tn-offset tn) vm:word-bytes))
    (load-symbol-value temp lisp::*current-unwind-protect-block*)
    (storew temp block vm:unwind-block-current-uwp-slot)
    (storew cfp-tn block vm:unwind-block-current-cont-slot)
    (storew code-tn block vm:unwind-block-current-code-slot)
    (inst compute-lra-from-code temp code-tn entry-label ndescr)
    (storew temp block vm:catch-block-entry-pc-slot)))


;;; Like Make-Unwind-Block, except that we also store in the specified tag, and
;;; link the block into the Current-Catch list.
;;;
(define-vop (make-catch-block)
  (:args (tn)
	 (tag :scs (descriptor-reg)))
  (:info entry-label)
  (:results (block :scs (any-reg)))
  (:temporary (:scs (descriptor-reg)) temp)
  (:temporary (:scs (descriptor-reg) :target block :to (:result 0)) result)
  (:temporary (:scs (non-descriptor-reg)) ndescr)
  (:generator 44
    (inst add result cfp-tn (* (tn-offset tn) vm:word-bytes))
    (load-symbol-value temp lisp::*current-unwind-protect-block*)
    (storew temp result vm:catch-block-current-uwp-slot)
    (storew cfp-tn result vm:catch-block-current-cont-slot)
    (storew code-tn result vm:catch-block-current-code-slot)
    (inst compute-lra-from-code temp code-tn entry-label ndescr)
    (storew temp result vm:catch-block-entry-pc-slot)

    (storew tag result vm:catch-block-tag-slot)
    (load-symbol-value temp lisp::*current-catch-block*)
    (storew temp result vm:catch-block-previous-catch-slot)
    (store-symbol-value result lisp::*current-catch-block*)

    (move block result)))


;;; Just set the current unwind-protect to TN's address.  This instantiates an
;;; unwind block as an unwind-protect.
;;;
(define-vop (set-unwind-protect)
  (:args (tn))
  (:temporary (:scs (descriptor-reg)) new-uwp)
  (:generator 7
    (inst add new-uwp cfp-tn (* (tn-offset tn) vm:word-bytes))
    (store-symbol-value new-uwp lisp::*current-unwind-protect-block*)))


(define-vop (unlink-catch-block)
  (:temporary (:scs (any-reg)) block)
  (:policy :fast-safe)
  (:translate %catch-breakup)
  (:generator 17
    (load-symbol-value block lisp::*current-catch-block*)
    (loadw block block vm:catch-block-previous-catch-slot)
    (store-symbol-value block lisp::*current-catch-block*)))

(define-vop (unlink-unwind-protect)
  (:temporary (:scs (any-reg)) block)
  (:policy :fast-safe)
  (:translate %unwind-protect-breakup)
  (:generator 17
    (load-symbol-value block lisp::*current-unwind-protect-block*)
    (loadw block block vm:unwind-block-current-uwp-slot)
    (store-symbol-value block lisp::*current-unwind-protect-block*)))


;;;; NLX entry VOPs:


(define-vop (nlx-entry)
  (:args (sp) ; Note: we can't list an sc-restriction, 'cause any load vops
	      ; would be inserted before the LRA.
	 (start)
	 (count))
  (:results (values :more t))
  (:temporary (:scs (descriptor-reg)) move-temp)
  (:info label nvals)
  (:save-p :force-to-stack)
  (:generator 30
    (emit-return-pc label)
    (cond ((zerop nvals))
	  ((= nvals 1)
	   (let ((no-values (gen-label)))
	     (inst cmp count)
	     (inst b :eq no-values)
	     (move (tn-ref-tn values) null-tn)
	     (loadw (tn-ref-tn values) start)
	     (emit-label no-values)))
	  (t
	   (collect ((defaults))
	     (inst subcc count (fixnum 1))
	     (do ((i 0 (1+ i))
		  (tn-ref values (tn-ref-across tn-ref)))
		 ((null tn-ref))
	       (let ((default-lab (gen-label))
		     (tn (tn-ref-tn tn-ref)))
		 (defaults (cons default-lab tn))
		 
		 (inst b :lt default-lab)
		 (inst subcc count (fixnum 1))
		 (sc-case tn
			  ((descriptor-reg any-reg)
			   (loadw tn start i))
			  (control-stack
			   (loadw move-temp start i)
			   (store-stack-tn tn move-temp)))))
	     
	     (let ((defaulting-done (gen-label)))
	       
	       (emit-label defaulting-done)
	       
	       (assemble (*elsewhere*)
		 (dolist (def (defaults))
		   (emit-label (car def))
		   (let ((tn (cdr def)))
		     (sc-case tn
			      ((descriptor-reg any-reg)
			       (move tn null-tn))
			      (control-stack
			       (store-stack-tn tn null-tn)))))
		 (inst b defaulting-done)
		 (inst nop))))))
    (load-stack-tn csp-tn sp)))


(define-vop (nlx-entry-multiple)
  (:args (top :target dst) (start :target src) (count :target num))
  ;; Again, no SC restrictions for the args, 'cause the loading would
  ;; happen before the entry label.
  (:info label)
  (:temporary (:scs (any-reg) :from (:argument 0)) dst)
  (:temporary (:scs (any-reg) :from (:argument 1)) src)
  (:temporary (:scs (any-reg) :from (:argument 2)) num)
  (:temporary (:scs (descriptor-reg)) temp)
  (:results (new-start) (new-count))
  (:save-p :force-to-stack)
  (:generator 30
    (emit-return-pc label)
    (let ((loop (gen-label))
	  (done (gen-label)))

      ;; Copy args.
      (load-stack-tn dst top)
      (move src start)
      (move num count)

      ;; Establish results.
      (sc-case new-start
	(any-reg (move new-start dst))
	(control-stack (store-stack-tn new-start dst)))
      (inst cmp num)
      (inst b :eq done)
      (sc-case new-count
	(any-reg (inst move new-count num))
	(control-stack (store-stack-tn new-count num)))

      ;; Copy stuff on stack.
      (emit-label loop)
      (loadw temp src)
      (inst add src src vm:word-bytes)
      (storew temp dst)
      (inst subcc num (fixnum 1))
      (inst b :ge loop)
      (inst add dst dst vm:word-bytes)

      (emit-label done)
      (inst move csp-tn dst))))


;;; This VOP is just to force the TNs used in the cleanup onto the stack.
;;;
(define-vop (uwp-entry)
  (:info label)
  (:save-p :force-to-stack)
  (:results (block) (start) (count))
  (:ignore block start count)
  (:generator 0
    (emit-return-pc label)))

