;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;; $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/assembly/mips/assem-rtns.lisp,v 1.19 1990/09/18 00:35:43 wlott Exp $
;;;
;;;
(in-package "C")



;;;; Non-local exit noise.


(define-assembly-routine (unwind
			  ((:translate %continue-unwind)
			   (:policy :fast-safe))
			  (:arg block (any-reg descriptor-reg) a0-offset)
			  (:arg start (any-reg descriptor-reg) old-fp-offset)
			  (:arg count (any-reg descriptor-reg) nargs-offset)
			  (:temp lip interior-reg lip-offset)
			  (:temp lra descriptor-reg lra-offset)
			  (:temp cur-uwp any-reg nl0-offset)
			  (:temp next-uwp any-reg nl1-offset)
			  (:temp target-uwp any-reg nl2-offset))
  (declare (ignore start count))

  (let ((error (generate-error-code nil invalid-unwind-error)))
    (inst beq block zero-tn error))
  
  (load-symbol-value cur-uwp lisp::*current-unwind-protect-block*)
  (loadw target-uwp block vm:unwind-block-current-uwp-slot)
  (inst bne cur-uwp target-uwp do-uwp)
  (inst nop)
      
  (move cur-uwp block)

  do-exit
      
  (loadw fp-tn cur-uwp vm:unwind-block-current-cont-slot)
  (loadw code-tn cur-uwp vm:unwind-block-current-code-slot)
  (loadw lra cur-uwp vm:unwind-block-entry-pc-slot)
  (lisp-return lra lip :frob-code nil)

  do-uwp

  (loadw next-uwp cur-uwp vm:unwind-block-current-uwp-slot)
  (inst b do-exit)
  (store-symbol-value next-uwp lisp::*current-unwind-protect-block*))



(define-assembly-routine (throw
			  ()
			  (:arg target descriptor-reg a0-offset)
			  (:arg start any-reg old-fp-offset)
			  (:arg count any-reg nargs-offset)
			  (:temp catch any-reg a1-offset)
			  (:temp tag descriptor-reg a2-offset)
			  (:temp ndescr non-descriptor-reg nl0-offset))
  
  (load-symbol-value catch lisp::*current-catch-block*)
  
  loop
  
  (let ((error (generate-error-code nil unseen-throw-tag-error target)))
    (inst beq catch zero-tn error)
    (inst nop))
  
  (loadw tag catch vm:catch-block-tag-slot)
  (inst beq tag target exit)
  (inst nop)
  (loadw catch catch vm:catch-block-previous-catch-slot)
  (inst b loop)
  (inst nop)
  
  exit
  
  (move target catch)
  (inst li ndescr (make-fixup 'unwind :assembly-routine))
  (inst j ndescr)
  (inst nop))


