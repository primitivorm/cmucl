;;; -*- Package: RT -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public
;;; domain.  If you want to use this code or any part of CMU Common
;;; Lisp, please contact Scott Fahlman (Scott.Fahlman@CS.CMU.EDU)
;;; **********************************************************************
;;;
;;; $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/assembly/rt/alloc.lisp,v 1.4 1991/10/22 16:50:28 wlott Exp $
;;;
;;; Stuff to handle allocating simple objects.
;;;
;;; Written by William Lott.
;;; Converted to the IBM RT by Bill Chiles.
;;;

(in-package "RT")


(define-for-each-primitive-object (obj)
  (let* ((options (primitive-object-options obj))
	 (alloc-trans (getf options :alloc-trans))
	 (alloc-vop (getf options :alloc-vop alloc-trans))
	 (header (primitive-object-header obj))
	 (lowtag (primitive-object-lowtag obj))
	 (size (primitive-object-size obj))
	 (variable-length (primitive-object-variable-length obj))
	 (need-unbound-marker nil))
    (collect ((args) (init-forms))
      (when (and alloc-vop variable-length)
	(args 'extra-words))
      (dolist (slot (primitive-object-slots obj))
	(let* ((name (slot-name slot))
	       (offset (slot-offset slot)))
	  (ecase (getf (slot-options slot) :init :zero)
	    (:zero)
	    (:null
	     (init-forms `(storew null-tn result ,offset ,lowtag)))
	    (:unbound
	     (setf need-unbound-marker t)
	     (init-forms `(storew temp result ,offset ,lowtag)))
	    (:arg
	     (args name)
	     (init-forms `(storew ,name result ,offset ,lowtag))))))
      (when (and (null alloc-vop) (args))
	(error "Slots ~S want to be initialized, but there is no alloc vop ~
	defined for ~S."
	       (args) (primitive-object-name obj)))
      (when alloc-vop
	`(define-assembly-routine
	     (,alloc-vop
	      (:cost 35)
	      ,@(when alloc-trans
		  `((:translate ,alloc-trans)))
	      (:policy :fast-safe))
	     (,@(let ((arg-offsets (cdr register-arg-offsets)))
		  (mapcar #'(lambda (name)
			      (unless arg-offsets
				(error "Too many args in ~S" alloc-vop))
			      `(:arg ,name (descriptor-reg any-reg)
				     ,(pop arg-offsets)))
			  (args)))
		(:temp alloc non-descriptor-reg nl0-offset)
		,@(when (or need-unbound-marker header variable-length)
		    '((:temp temp non-descriptor-reg ocfp-offset)))
		(:res result descriptor-reg a0-offset))
	   (pseudo-atomic (temp)
	     (load-symbol-value alloc *allocation-pointer*)
	     (inst cal result alloc ,lowtag)
	     ,@(cond ((and header variable-length)
		      `((inst cal temp extra-words (fixnum (1- ,size)))
			(inst cas alloc temp alloc)
			(inst sl temp (- type-bits word-shift))
			(inst oil temp ,header)
			(storew temp result 0 ,lowtag)
			(inst cal alloc alloc (+ (fixnum 1) lowtag-mask))
			(inst li temp (lognot lowtag-mask))
			(inst n alloc temp)))
		     (variable-length
		      (error ":REST-P T with no header in ~S?"
			     (primitive-object-name obj)))
		     (header
		      `((inst cal alloc alloc (pad-data-block ,size))
			(inst li temp
			      ,(logior (ash (1- size) type-bits)
				       (symbol-value header)))
			(storew temp result 0 ,lowtag)))
		     (t
		      `((inst cal alloc alloc (pad-data-block ,size)))))
	     ,@(when need-unbound-marker
		 `((inst li temp unbound-marker-type)))
	     ,@(init-forms)
	     (store-symbol-value alloc *allocation-pointer*))
	   (load-symbol-value temp *internal-gc-trigger*)
	   (inst tlt temp alloc))))))
