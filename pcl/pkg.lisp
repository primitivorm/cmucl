;;;-*-Mode:LISP; Package:(PCL (LISP WALKER)); Base:10; Syntax:Common-lisp -*-
;;;
;;; *************************************************************************
;;; Copyright (c) 1985, 1986, 1987, 1988, 1989, 1990 Xerox Corporation.
;;; All rights reserved.
;;;
;;; Use and copying of this software and preparation of derivative works
;;; based upon this software are permitted.  Any distribution of this
;;; software or derivative works must comply with all applicable United
;;; States export control laws.
;;; 
;;; This software is made available AS IS, and Xerox Corporation makes no
;;; warranty about the software, its performance or its conformity to any
;;; specification.
;;; 
;;; Any person obtaining a copy of this software is requested to send their
;;; name and post office or electronic mail address to:
;;;   CommonLoops Coordinator
;;;   Xerox PARC
;;;   3333 Coyote Hill Rd.
;;;   Palo Alto, CA 94304
;;; (or send Arpanet mail to CommonLoops-Coordinator.pa@Xerox.arpa)
;;;
;;; Suggestions, comments and requests for improvements are also welcome.
;;; *************************************************************************
;;;

(ext:file-comment
  "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/pcl/pkg.lisp,v 1.10.2.3 2002/03/23 18:51:20 pw Exp $")
;;;
;;; CMUCL 18a: Jan-1998 -- Changing to DEFPACKAGE.

(defpackage "WALKER" (:use :common-lisp)
  (:export "DEFINE-WALKER-TEMPLATE"
	   "WALK-FORM"
	   "WALK-FORM-EXPAND-MACROS-P"
	   "NESTED-WALK-FORM"
	   "VARIABLE-LEXICAL-P"
	   "VARIABLE-SPECIAL-P"
	   "VARIABLE-GLOBALLY-SPECIAL-P"
	   "*VARIABLE-DECLARATIONS*"
	   "VARIABLE-DECLARATION"
	   "MACROEXPAND-ALL"))

(defpackage "ITERATE" (:use :common-lisp :walker)
  (:export "ITERATE" "ITERATE*" "GATHERING" "GATHER" "WITH-GATHERING"
	   "INTERVAL" "ELEMENTS" "LIST-ELEMENTS" "LIST-TAILS"
	   "PLIST-ELEMENTS" "EACHTIME" "WHILE" "UNTIL"
	   "COLLECTING" "JOINING" "MAXIMIZING" "MINIMIZING" "SUMMING"
	   "*ITERATE-WARNINGS*"))

(defpackage "PCL" (:use :common-lisp :walker :iterate)
  (:shadow "DESTRUCTURING-BIND")
  (:shadow "FIND-CLASS" "CLASS-NAME" "CLASS-OF"
	   "CLASS" "BUILT-IN-CLASS" "STRUCTURE-CLASS"
	   "STANDARD-CLASS")
  (:shadow "DOTIMES")
  (:import-from :kernel "FUNCALLABLE-INSTANCE-P")
  (:shadow "DOCUMENTATION")


;;;						
;;; These come from the index pages of 88-002R.
;;;
;;;
  
  (:export "ADD-METHOD"
	   "BUILT-IN-CLASS"
	   "CALL-METHOD"
	   "CALL-NEXT-METHOD"
	   "CHANGE-CLASS"
	   "CLASS-NAME"
	   "CLASS-OF"
	   "COMPUTE-APPLICABLE-METHODS"
	   "DEFCLASS"
	   "DEFGENERIC"
	   "DEFINE-METHOD-COMBINATION"
	   "DEFMETHOD"
	   "DESCRIBE-OBJECT"
	   "ENSURE-GENERIC-FUNCTION"
	   "FIND-CLASS"
	   "FIND-METHOD"
	   "FUNCTION-KEYWORDS"
	   "GENERIC-FLET"
	   "GENERIC-LABELS"
	   "INITIALIZE-INSTANCE"
	   "INVALID-METHOD-ERROR"
	   "MAKE-INSTANCE"
	   "MAKE-INSTANCES-OBSOLETE"
	   "METHOD-COMBINATION-ERROR"
	   "METHOD-QUALIFIERS"
	   "NEXT-METHOD-P"
	   "NO-APPLICABLE-METHOD"
	   "NO-NEXT-METHOD"
	   "PRINT-OBJECT"
	   "REINITIALIZE-INSTANCE"
	   "REMOVE-METHOD"
	   "SHARED-INITIALIZE"
	   "SLOT-BOUNDP"
	   "SLOT-EXISTS-P"
	   "SLOT-MAKUNBOUND"
	   "SLOT-MISSING"
	   "SLOT-UNBOUND"
	   "SLOT-VALUE"
	   "STANDARD"
	   "STANDARD-GENERIC-FUNCTION"
	   "STANDARD-METHOD"
	   "STANDARD-OBJECT"
	   "UPDATE-INSTANCE-FOR-DIFFERENT-CLASS"
	   "UPDATE-INSTANCE-FOR-REDEFINED-CLASS"
	   "WITH-ACCESSORS"
	   "WITH-ADDED-METHODS"
	   "WITH-SLOTS"
	   )
  
  (:export "STANDARD-INSTANCE"
	   "FUNCALLABLE-STANDARD-INSTANCE"
	   "GENERIC-FUNCTION"
	   "STANDARD-GENERIC-FUNCTION"
	   "METHOD"
	   "STANDARD-METHOD"
	   "STANDARD-ACCESSOR-METHOD"
	   "STANDARD-READER-METHOD"
	   "STANDARD-WRITER-METHOD"
	   "METHOD-COMBINATION"
	   "SLOT-DEFINITION"
	   "DIRECT-SLOT-DEFINITION"
	   "EFFECTIVE-SLOT-DEFINITION"
	   "STANDARD-SLOT-DEFINITION"
	   "STANDARD-DIRECT-SLOT-DEFINITION"
	   "STANDARD-EFFECTIVE-SLOT-DEFINITION"
	   "SPECIALIZER"
	   "EQL-SPECIALIZER"
	   "FORWARD-REFERENCED-CLASS"
	   "FUNCALLABLE-STANDARD-CLASS"
	   "FUNCALLABLE-STANDARD-OBJECT")

  ;;*chapter-6-exports*
  (:export "ADD-DEPENDENT"
	   "ADD-DIRECT-METHOD"
	   "ADD-DIRECT-SUBCLASS"
	   "ADD-METHOD"
	   "ALLOCATE-INSTANCE"
	   "CLASS-DEFAULT-INITARGS"
	   "CLASS-DIRECT-DEFAULT-INITARGS"
	   "CLASS-DIRECT-SLOTS"
	   "CLASS-DIRECT-SUBCLASSES"
	   "CLASS-DIRECT-SUPERCLASSES"
	   "CLASS-FINALIZED-P"
	   "CLASS-PRECEDENCE-LIST"
	   "CLASS-PROTOTYPE"
	   "CLASS-SLOTS"
	   "COMPUTE-APPLICABLE-METHODS"
	   "COMPUTE-APPLICABLE-METHODS-USING-CLASSES"
	   "COMPUTE-CLASS-PRECEDENCE-LIST"
	   "COMPUTE-DISCRIMINATING-FUNCTION"
	   "COMPUTE-EFFECTIVE-METHOD"
	   "COMPUTE-EFFECTIVE-SLOT-DEFINITION"
	   "COMPUTE-SLOTS"
	   "DIRECT-SLOT-DEFINITION-CLASS"
	   "EFFECTIVE-SLOT-DEFINITION-CLASS"
	   "ENSURE-CLASS"
	   "ENSURE-CLASS-USING-CLASS"
	   "ENSURE-GENERIC-FUNCTION"
	   "ENSURE-GENERIC-FUNCTION-USING-CLASS"
	   "EQL-SPECIALIZER-INSTANCE"
	   "EXTRACT-LAMBDA-LIST"
	   "EXTRACT-SPECIALIZER-NAMES"
	   "FINALIZE-INHERITANCE"
	   "FIND-METHOD-COMBINATION"
	   "FUNCALLABLE-STANDARD-INSTANCE-ACCESS"
	   "GENERIC-FUNCTION-ARGUMENT-PRECEDENCE-ORDER"
	   "GENERIC-FUNCTION-DECLARATIONS"
	   "GENERIC-FUNCTION-LAMBDA-LIST"
	   "GENERIC-FUNCTION-METHOD-CLASS"
	   "GENERIC-FUNCTION-METHOD-COMBINATION"
	   "GENERIC-FUNCTION-METHODS"
	   "GENERIC-FUNCTION-NAME"
	   "INTERN-EQL-SPECIALIZER"
	   "MAKE-INSTANCE"
	   "MAKE-METHOD-LAMBDA"
	   "MAP-DEPENDENTS"
	   "METHOD-FUNCTION"
	   "METHOD-GENERIC-FUNCTION"
	   "METHOD-LAMBDA-LIST"
	   "METHOD-SPECIALIZERS"
	   "METHOD-QUALIFIERS"
	   "ACCESSOR-METHOD-SLOT-DEFINITION"
	   "READER-METHOD-CLASS"
	   "REMOVE-DEPENDENT"
	   "REMOVE-DIRECT-METHOD"
	   "REMOVE-DIRECT-SUBCLASS"
	   "REMOVE-METHOD"
	   "SET-FUNCALLABLE-INSTANCE-FUNCTION"
	   "SLOT-BOUNDP-USING-CLASS"
	   "SLOT-DEFINITION-ALLOCATION"
	   "SLOT-DEFINITION-INITARGS"
	   "SLOT-DEFINITION-INITFORM"
	   "SLOT-DEFINITION-INITFUNCTION"
	   "SLOT-DEFINITION-LOCATION"
	   "SLOT-DEFINITION-NAME"
	   "SLOT-DEFINITION-READERS"
	   "SLOT-DEFINITION-WRITERS"
	   "SLOT-DEFINITION-TYPE"
	   "SLOT-MAKUNBOUND-USING-CLASS"
	   "SLOT-VALUE-USING-CLASS"
	   "SPECIALIZER-DIRECT-GENERIC-FUNCTION"
	   "SPECIALIZER-DIRECT-METHODS"
	   "STANDARD-INSTANCE-ACCESS"
	   "UPDATE-DEPENDENT"
	   "VALIDATE-SUPERCLASS"
	   "WRITER-METHOD-CLASS"
          ))

(defpackage "SLOT-ACCESSOR-NAME" (:use)(:nicknames "S-A-N"))

(in-package :pcl)
(defvar *slot-accessor-name-package*
  (find-package :slot-accessor-name))

;;; These symbol names came from "The Art of the Metaobject Protocol".
;;;

(defpackage "CLOS-MOP"
  (:use :pcl :common-lisp)
  (:nicknames "MOP")

  (:shadowing-import-from :pcl
    "FIND-CLASS" "CLASS-NAME" "BUILT-IN-CLASS" "CLASS-OF")
  (:export
    "FIND-CLASS" "CLASS-NAME" "BUILT-IN-CLASS" "CLASS-OF")

  (:export ;; Names taken from "The Art of the Metaobject Protocol"
   "ADD-DEPENDENT"
   "ADD-DIRECT-METHOD"
   "ADD-DIRECT-SUBCLASS"
   "ADD-METHOD"
   "ALLOCATE-INSTANCE"
   "CLASS-DEFAULT-INITARGS"
   "CLASS-DIRECT-DEFAULT-INITARGS"
   "CLASS-DIRECT-SLOTS"
   "CLASS-DIRECT-SUBCLASSES"
   "CLASS-DIRECT-SUPERCLASSES"
   "CLASS-FINALIZED-P"
   "CLASS-NAME"
   "CLASS-PRECEDENCE-LIST"
   "CLASS-PROTOTYPE"
   "CLASS-SLOTS"
   "COMPUTE-APPLICABLE-METHODS"
   "COMPUTE-APPLICABLE-METHODS-USING-CLASSES"
   "COMPUTE-CLASS-PRECEDENCE-LIST"
   "COMPUTE-DEFAULT-INITARGS"
   "COMPUTE-DISCRIMINATING-FUNCTION"
   "COMPUTE-EFFECTIVE-METHOD"
   "COMPUTE-EFFECTIVE-SLOT-DEFINITION"
   "COMPUTE-SLOTS"
   "DIRECT-SLOT-DEFINITION-CLASS"
   "EFFECTIVE-SLOT-DEFINITION-CLASS"
   "ENSURE-CLASS"
   "ENSURE-CLASS-USING-CLASS"
   "ENSURE-GENERIC-FUNCTION"
   "ENSURE-GENERIC-FUNCTION-USING-CLASS"
   "EQL-SPECIALIZER-OBJECT"
   "EXTRACT-LAMBDA-LIST"
   "EXTRACT-SPECIALIZER-NAMES"
   "FINALIZE-INHERITANCE"
   "FIND-METHOD-COMBINATION"
   "FUNCALLABLE-STANDARD-INSTANCE-ACCESS"
   "GENERIC-FUNCTION-ARGUMENT-PRECEDENCE-ORDER"
   "GENERIC-FUNCTION-DECLARATIONS"
   "GENERIC-FUNCTION-LAMBDA-LIST"
   "GENERIC-FUNCTION-METHOD-CLASS"
   "GENERIC-FUNCTION-METHOD-COMBINATION"
   "GENERIC-FUNCTION-METHODS"
   "GENERIC-FUNCTION-NAME"
   "INTERN-EQL-SPECIALIZER"
   "MAKE-INSTANCE"
   "MAKE-METHOD-LAMBDA"
   "MAP-DEPENDENTS"
   "METHOD-FUNCTION"
   "METHOD-GENERIC-FUNCTION"
   "METHOD-LAMBDA-LIST"
   "METHOD-SPECIALIZERS"
   "METHOD-QUALIFIERS"
   "ACCESSOR-METHOD-SLOT-DEFINITION"

   "SLOT-DEFINITION-ALLOCATION"
   "SLOT-DEFINITION-INITARGS"
   "SLOT-DEFINITION-INITFORM"
   "SLOT-DEFINITION-INITFUNCTION"
   "SLOT-DEFINITION-NAME"
   "SLOT-DEFINITION-TYPE"
   "SLOT-DEFINITION-READERS"
   "SLOT-DEFINITION-WRITERS"
   "SLOT-DEFINITION-LOCATION"

   "READER-METHOD-CLASS"
   "REMOVE-DEPENDENT"
   "REMOVE-DIRECT-METHOD"
   "REMOVE-DIRECT-SUBCLASS"
   "REMOVE-METHOD"
   "SET-FUNCALLABLE-INSTANCE-FUNCTION"
   "SLOT-BOUNDP-USING-CLASS"
   "SLOT-MAKUNBOUND-USING-CLASS"
   "SLOT-VALUE-USING-CLASS"
   "SPECIALIZER-DIRECT-GENERIC-FUNCTIONS"
   "SPECIALIZER-DIRECT-METHODS"
   "STANDARD-INSTANCE-ACCESS"
   "UPDATE-DEPENDENT"
   "VALIDATE-SUPERCLASS"
   "WRITER-METHOD-CLASS"
   ))
