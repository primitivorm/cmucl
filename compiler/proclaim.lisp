;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;;    This file contains load-time support for declaration processing.  It is
;;; split off from the compiler so that the compiler doesn'thave to be in the
;;; cold load.
;;;
;;; Written by Rob MacLachlan
;;;
(in-package 'c)

;;; The Cookie holds information about the compilation environment for a node.
;;; See the Node definition for a description of how it is used.
;;;
(defstruct cookie
  (speed nil :type (or (rational 0 3) null))
  (space nil :type (or (rational 0 3) null))
  (safety nil :type (or (rational 0 3) null))
  (cspeed nil :type (or (rational 0 3) null))
  (brevity nil :type (or (rational 0 3) null))
  (debug nil :type (or (rational 0 3) null)))


;;; The *default-cookie* represents the current global compiler policy
;;; information.  Whenever the policy is changed, we copy the structure so that
;;; old uses will still get the old values.
;;;
(proclaim '(type cookie *default-cookie*))
(defvar *default-cookie* (make-cookie :safety 1 :speed 1 :space 1 :cspeed 1
				      :brevity 1 :debug 1))


;;; Check-Function-Name  --  Interface
;;;
;;;    Check that Name is a valid function name, returning the name if OK, and
;;; doing an error if not.  In addition to checking for basic well-formedness,
;;; we also check that symbol names are not NIL or the name of a special form.
;;;
(defun check-function-name (name)
  (typecase name
    (list
     (unless (and (consp name) (consp (cdr name))
		  (null (cddr name)) (eq (car name) 'setf)
		  (symbolp (cadr name)))
       (compiler-error "Illegal function name: ~S." name))
     name)
    (symbol
     (when (eq (info function kind name) :special-form)
       (compiler-error "Special form is an illegal function name: ~S." name))
     name)
    (t
     (compiler-error "Illegal function name: ~S." name))))


;;; Define-Function-Name  --  Interface
;;;
;;;    Check the legality of a function name that is being introduced.  If it
;;; names a macro, then give a warning and blast the macro information.
;;;
(proclaim '(function define-function-name (t) void))
(defun define-function-name (name)
  (check-function-name name)
  (ecase (info function kind name)
    (:function)
    (:special-from
     (compiler-error "~S names a special form, so cannot be a function." name))
    (:macro
     (compiler-warning "~S previously defined as a macro." name)
     (setf (info function kind name) :function)
     (setf (info function where-from name) :assumed)
     (clear-info function macro-function name))
    ((nil)
     (setf (info function kind name) :function)))
  name)


;;; Process-Optimize-Declaration  --  Interface
;;;
;;;    Return a new cookie containing the policy information represented by the
;;; optimize declaration Spec.  Any parameters not specified are defaulted from
;;; Cookie.
;;;
(proclaim '(function process-optimize-declaration (list cookie) cookie))
(defun process-optimize-declaration (spec cookie)
  (let ((res (copy-cookie cookie)))
    (dolist (quality (cdr spec))
      (let ((quality (if (atom quality) (list quality 3) quality)))
	(if (and (consp (cdr quality)) (null (cddr quality))
		 (rationalp (second quality)) (<= 0 (second quality) 3))
	    (let ((value (second quality)))
	      (case (first quality)
		(speed (setf (cookie-speed res) value))
		(space (setf (cookie-space res) value))
		(safety (setf (cookie-safety res) value))
		(compilation-speed (setf (cookie-cspeed res) value))
		(brevity (setf (cookie-brevity res) value))
		(debug-info (setf (cookie-debug res) value))
		(t
		 (compiler-warning "Unknown optimization quality ~S in ~S."
				   (car quality) spec))))
	    (compiler-warning
	     "Malformed optimization quality specifier ~S in ~S."
	     quality spec))))
    res))

  
;;; %Proclaim  --  Interface
;;;
;;;    This function is the guts of proclaim, since it does the global
;;; environment updating.
;;;
;;; ### At least for now, ignore type proclamations when compiled under the new
;;; compiler.  This allows us to delay putting the type system into the cold
;;; load.
;;;
(defun %proclaim (form)
  (unless (consp form)
    (error "Malformed PROCLAIM spec: ~S." form))
  
  (let ((kind (first form))
	(args (rest form)))
    (case kind
      (special
       (dolist (name args)
	 (unless (symbolp name)
	   (error "Variable name is not a symbol: ~S." name))
	 (clear-info variable constant-value name)
	 (setf (info variable kind name) :special)))
      (type
       #-new-compiler
       (let ((type (specifier-type (first args))))
	 (dolist (name (rest args))
	 (unless (symbolp name)
	   (error "Variable name is not a symbol: ~S." name))
	   (setf (info variable type name) type)
	   (setf (info variable where-from name) :declared))))
      (ftype
       #-new-compiler
       (let ((type (specifier-type (first args))))
	 (unless (function-type-p type)
	   (error "Declared functional type is not a function type: ~S."
		  (first args)))
	 (dolist (name (rest args))
	   (define-function-name name)
	   (setf (info function type name) type)
	   (setf (info function where-from name) :declared))))
      (function
       #-new-compiler
       (%proclaim `(ftype (function . ,(rest args)) ,(first args))))
      (optimize
       (setq *default-cookie* (process-optimize-declaration form *default-cookie*)))
      ((inline notinline maybe-inline)
       (dolist (name args)
	 (define-function-name name)
	 (setf (info function inlinep name)
	       (case kind
		 (inline :inline)
		 (notinline :notinline)
		 (maybe-inline :maybe-inline)))))
      (declaration
       (dolist (decl args)
	 (unless (symbolp decl)
	   (error "Declaration to be RECOGNIZED is not a symbol: ~S." decl))
	 (setf (info declaration recognized decl) t)))
      (t
       (if (member kind type-specifier-symbols)
	   (%proclaim `(type . ,form))
	   (error "Unrecognized proclamation: ~S." form)))))
  (undefined-value))
;;;
(setf (symbol-function 'proclaim) #'%proclaim)


;;; %%Compiler-Defstruct  --  Interface
;;;
;;;    This function updates the global compiler information to represent the
;;; definition of the the structure described by Info.
;;;
(defun %%compiler-defstruct (info)
  (declare (type defstruct-description info))

  (let ((name (dd-name info)))
    (dolist (inc (dd-includes info))
      (pushnew name (dd-included-by (info type structure-info inc))))

    (let ((old (info type structure-info name)))
      (when old
	(setf (dd-included-by info) (dd-included-by old))))

    (setf (info type kind name) :structure)
    (setf (info type structure-info name) info))

  (dolist (inc (dd-includes info))
    (pushnew (dd-name info)
	     (dd-included-by (info type structure-info inc))))

  (dolist (slot (dd-slots info))
    (let ((fun (dsd-accessor slot)))
      (define-function-name fun)
      (setf (info function accessor-for fun) info)
      ;;
      ;; ### Bootstrap hack...
      ;; This blows away any inverse that has been loaded into the bootstrap
      ;; environment.  Probably this should be more general (expanders, etc.),
      ;; and also perhaps done on other functions.
      (when (info setf inverse fun)
	(setf (info setf inverse fun) nil))
      
      (unless (dsd-read-only slot)
	(setf (info function accessor-for `(setf ,fun)) info))))
  (undefined-value))

(setf (symbol-function '%compiler-defstruct) #'%%compiler-defstruct)


;;;; Dummy definitions of COMPILER-ERROR, etc.
;;;
;;;    Until the compiler is properly loaded, we make the compiler error
;;; functions synonyms for the obvious standard error function.
;;;

(defun compiler-error (string &rest args)
  (apply #'error string args))

(defun compiler-warning (string &rest args)
  (apply #'warn string args))

(defun compiler-note (string &rest args)
  (apply #'warn string args))

(defun compiler-error-message (string &rest args)
  (apply #'warn string args))


;;; Alien=>Lisp-Transform  --  Internal
;;;
;;;    This is the transform for alien-operators and other alien-valued
;;; things which may be evaluated normally to yield an alien-value structure.
;;;
(defun alien=>lisp-transform (form)
  (multiple-value-bind (binds stuff res)
		       (analyze-alien-expression nil form)
    `(let* ,(reverse binds)
       ,(ignore-unreferenced-vars binds)
       ,@(nreverse stuff)
       ,(if (ct-a-val-alien res)
	    (ct-a-val-alien res)
	    `(lisp::make-alien-value
	      ,(ct-a-val-sap res)
	      ,(ct-a-val-offset res)
	      ,(ct-a-val-size res)
	      ',(ct-a-val-type res))))))
