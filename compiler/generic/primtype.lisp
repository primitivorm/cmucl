;;; -*- Package: VM -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of CMU Common Lisp, please contact
;;; Scott Fahlman or slisp-group@cs.cmu.edu.
;;;
(ext:file-comment
  "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/compiler/generic/primtype.lisp,v 1.11 1993/03/13 20:22:52 ram Exp $")
;;;
;;; **********************************************************************
;;;
;;; This file contains the machine independent aspects of the object
;;; representation and primitive types.
;;;
;;; Written by William Lott.
;;;
(in-package "VM")


;;;; Primitive Type Definitions

;;; *Anything*
;;; 
(def-primitive-type t (descriptor-reg))
(defvar *any-primitive-type* (primitive-type-or-lose 't))
(setf (backend-any-primitive-type *target-backend*) *any-primitive-type*)

;;; Primitive integer types that fit in registers.
;;;
(def-primitive-type positive-fixnum (any-reg signed-reg unsigned-reg)
  :type (unsigned-byte 29))
(def-primitive-type unsigned-byte-31 (signed-reg unsigned-reg descriptor-reg)
  :type (unsigned-byte 31))
(def-primitive-type unsigned-byte-32 (unsigned-reg descriptor-reg)
  :type (unsigned-byte 32))
(def-primitive-type fixnum (any-reg signed-reg)
  :type (signed-byte 30))
(def-primitive-type signed-byte-32 (signed-reg descriptor-reg)
  :type (signed-byte 32))

(defvar *fixnum-primitive-type* (primitive-type-or-lose 'fixnum))

(def-primitive-type-alias tagged-num (:or positive-fixnum fixnum))
(def-primitive-type-alias unsigned-num (:or unsigned-byte-32
					    unsigned-byte-31
					    positive-fixnum))
(def-primitive-type-alias signed-num (:or signed-byte-32
					  fixnum
					  unsigned-byte-31
					  positive-fixnum))

;;; Other primitive immediate types.
(def-primitive-type base-char (base-char-reg any-reg))

;;; Primitive pointer types.
;;; 
(def-primitive-type function (descriptor-reg))
(def-primitive-type list (descriptor-reg))
(def-primitive-type instance (descriptor-reg))

(def-primitive-type funcallable-instance (descriptor-reg))

;;; Primitive other-pointer number types.
;;; 
(def-primitive-type bignum (descriptor-reg))
(def-primitive-type ratio (descriptor-reg))
(def-primitive-type complex (descriptor-reg))
(def-primitive-type single-float (single-reg descriptor-reg))
(def-primitive-type double-float (double-reg descriptor-reg))

;;; Primitive other-pointer array types.
;;; 
(def-primitive-type simple-string (descriptor-reg) :type simple-base-string)
(def-primitive-type simple-bit-vector (descriptor-reg))
(def-primitive-type simple-vector (descriptor-reg))
(def-primitive-type simple-array-unsigned-byte-2 (descriptor-reg)
  :type (simple-array (unsigned-byte 2) (*)))
(def-primitive-type simple-array-unsigned-byte-4 (descriptor-reg)
  :type (simple-array (unsigned-byte 4) (*)))
(def-primitive-type simple-array-unsigned-byte-8 (descriptor-reg)
  :type (simple-array (unsigned-byte 8) (*)))
(def-primitive-type simple-array-unsigned-byte-16 (descriptor-reg)
  :type (simple-array (unsigned-byte 16) (*)))
(def-primitive-type simple-array-unsigned-byte-32 (descriptor-reg)
  :type (simple-array (unsigned-byte 32) (*)))
(def-primitive-type simple-array-single-float (descriptor-reg)
  :type (simple-array single-float (*)))
(def-primitive-type simple-array-double-float (descriptor-reg)
  :type (simple-array double-float (*)))

;;; Note: The complex array types are not inclueded, 'cause it is pointless to
;;; restrict VOPs to them.

;;; Other primitive other-pointer types.
;;; 
(def-primitive-type system-area-pointer (sap-reg descriptor-reg))
(def-primitive-type weak-pointer (descriptor-reg))

;;; Random primitive types that don't exist at the LISP level.
;;; 
(def-primitive-type catch-block (catch-block) :type nil)



;;;; Primitive-type-of and friends.

;;; Primitive-Type-Of  --  Interface
;;;
;;;    Return the most restrictive primitive type that contains Object.
;;;
(def-vm-support-routine primitive-type-of (object)
  (let ((type (ctype-of object)))
    (cond ((not (member-type-p type)) (primitive-type type))
	  ((equal (member-type-members type) '(nil))
	   (primitive-type-or-lose 'list *backend*))
	  (t
	   *any-primitive-type*))))

;;; 
(defvar *simple-array-primitive-types*
  '((base-char . simple-string)
    (string-char . simple-string)
    (bit . simple-bit-vector)
    ((unsigned-byte 2) . simple-array-unsigned-byte-2)
    ((unsigned-byte 4) . simple-array-unsigned-byte-4)
    ((unsigned-byte 8) . simple-array-unsigned-byte-8)
    ((unsigned-byte 16) . simple-array-unsigned-byte-16)
    ((unsigned-byte 32) . simple-array-unsigned-byte-32)
    (single-float . simple-array-single-float)
    (double-float . simple-array-double-float)
    (t . simple-vector))
  "An a-list for mapping simple array element types to their
  corresponding primitive types.")


;;; Return the primitive type corresponding to a type descriptor
;;; structure. The second value is true when the primitive type is
;;; exactly equivalent to the argument Lisp type.
;;;
;;; In a bootstrapping situation, we should be careful to use the
;;; correct values for the system parameters.
;;;
;;; We need an aux function because we need to use both def-vm-support-routine
;;; and defun-cached.
;;; 
(def-vm-support-routine primitive-type (type)
  (primitive-type-aux type))
;;;
(defun-cached (primitive-type-aux
	       :hash-function (lambda (x)
				(logand (cache-hash-eq x) #x1FF))
	       :hash-bits 9
	       :values 2
	       :default (values nil :empty))
	      ((type eq))
  (declare (type ctype type))
  (macrolet ((any () '(values *any-primitive-type* nil))
	     (exactly (type)
	       `(values (primitive-type-or-lose ',type *backend*) t))
	     (part-of (type)
	       `(values (primitive-type-or-lose ',type *backend*) nil)))
    (etypecase type
      (numeric-type
       (let ((lo (numeric-type-low type))
	     (hi (numeric-type-high type)))
	 (case (numeric-type-complexp type)
	   (:real
	    (case (numeric-type-class type)
	      (integer
	       (cond ((and hi lo)
		      (dolist (spec
			       '((positive-fixnum 0 #.(1- (ash 1 29)))
				 (unsigned-byte-31 0 #.(1- (ash 1 31)))
				 (unsigned-byte-32 0 #.(1- (ash 1 32)))
				 (fixnum #.(ash -1 29) #.(1- (ash 1 29)))
				 (signed-byte-32 #.(ash -1 31)
						 #.(1- (ash 1 31))))
			       (if (or (< hi (ash -1 29))
				       (> lo (1- (ash 1 29))))
				   (part-of bignum)
				   (any)))
			(let ((type (car spec))
			      (min (cadr spec))
			      (max (caddr spec)))
			  (when (<= min lo hi max)
			    (return (values (primitive-type-or-lose type
								    *backend*)
					    (and (= lo min) (= hi max))))))))
		     ((or (and hi (< hi most-negative-fixnum))
			  (and lo (> lo most-positive-fixnum)))
		      (part-of bignum))
		     (t
		      (any))))
	      (float
	       (let ((exact (and (null lo) (null hi))))
		 (case (numeric-type-format type)
		   ((short-float single-float)
		    (values (primitive-type-or-lose 'single-float *backend*)
			    exact))
		   ((double-float long-float)
		    (values (primitive-type-or-lose 'double-float *backend*)
			    exact))
		   (t
		    (any)))))
	      (t
	       (any))))
	   (:complex
	    (part-of complex))
	   (t
	    (any)))))
      (array-type
       (if (array-type-complexp type)
	   (any)
	   (let* ((dims (array-type-dimensions type))
		  (etype (array-type-specialized-element-type type))
		  (type-spec (type-specifier etype))
		  (ptype (cdr (assoc type-spec *simple-array-primitive-types*
				     :test #'equal))))
	     (if (and (consp dims) (null (rest dims)) ptype)
		 (values (primitive-type-or-lose ptype *backend*)
			 (eq (first dims) '*))
		 (any)))))
      (union-type
       (if (type= type (specifier-type 'list))
	   (exactly list)
	   (let ((types (union-type-types type)))
	     (multiple-value-bind (res exact)
				  (primitive-type (first types))
	       (dolist (type (rest types) (values res exact))
		 (multiple-value-bind (ptype ptype-exact)
				      (primitive-type type)
		   (unless ptype-exact (setq exact nil))
		   (unless (eq ptype res)
		     (return (any)))))))))
      (member-type
       (let* ((members (member-type-members type))
	      (res (primitive-type-of (first members))))
	 (dolist (mem (rest members) (values res nil))
	   (unless (eq (primitive-type-of mem) res)
	     (return (values *any-primitive-type* nil))))))
      (named-type
       (ecase (named-type-name type)
	 ((t *) (values *any-primitive-type* t))
	 ((nil) (values *any-primitive-type* nil))))
      (built-in-class
       (case (class-name type)
	 ((complex function instance funcallable-instance system-area-pointer
		   weak-pointer)
	  (values (primitive-type-or-lose (class-name type) *backend*) t))
	 (base-char
	  (exactly base-char))
	 (cons
	  (part-of list))
	 (t
	  (any))))
      (function-type
       (exactly function))
      (class
       (if (csubtypep type (specifier-type 'function))
	   (part-of function)
	   (part-of instance)))
      (ctype
       (any)))))

