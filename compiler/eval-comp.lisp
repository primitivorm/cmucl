;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;; This file represents the current state of on-going development on compiler
;;; hooks for an interpreter that takes the compiler's IR1 of a program.
;;;
;;; Written by Bill Chiles.
;;;

(in-package "C")

(proclaim '(special *constants* *free-variables* *compile-component*
		    *code-vector* *next-location* *result-fixups*
		    *free-functions* *source-paths* *failed-optimizations*
		    *seen-blocks* *seen-functions* *list-conflicts-table*
		    *continuation-number* *continuation-numbers*
		    *number-continuations* *tn-id* *tn-ids* *id-tns*
		    *label-ids* *label-id* *id-labels* *sb-list*
		    *unknown-functions* *compiler-error-count*
		    *compiler-warning-count* *compiler-note-count*
		    *compiler-error-output* *compiler-error-bailout*
		    *compiler-trace-output*
		    *last-source-context* *last-original-source*
		    *last-source-form* *last-format-string* *last-format-args*
		    *last-message-count* *check-consistency*
		    *all-components* *converting-for-interpreter*
		    *source-info* *block-compile* *current-path*
		    *current-component* *fenv*))

(export '(compile-for-eval lambda-eval-info-frame-size
	  lambda-eval-info-args-passed lambda-eval-info-entries
	  entry-node-info-st-top entry-node-info-nlx-tag))

;;; EVAL will pick off some special forms; for example, global variable
;;; references, c::package-frobbers, etc.  I note this because the compilation
;;; stuff EVAL's these forms instead of compiling code for them.
;;;



;;; COMPILE-FOR-EVAL -- Public.
;;;
;;; This translates form into the compiler's IR1 and performs environment
;;; analysis.  It is sort of a combination of NCOMPILE-FILE, SUB-COMPILE-FILE,
;;; COMPILE-TOP-LEVEL, and COMPILE-COMPONENT.
;;;
(defun compile-for-eval (form quietly)
  (with-ir1-namespace
    (let* ((*block-compile* nil)
	   (*fenv* ())
	   ;;
	   (*compiler-error-output*
	    (if quietly
		(make-broadcast-stream)
		*error-output*))
	   (*compiler-trace-output* nil)
	   (*compiler-error-bailout*
	    #'(lambda () (error "Fatal error, aborting evaluation.")))
	   ;;
	   (*last-source-context* nil)
	   (*last-original-source* nil)
	   (*last-source-form* nil)
	   (*last-format-string* nil)
	   (*last-format-args* nil)
	   (*last-message-count* 0)
	   ;;
	   (*unknown-functions* nil)
	   (*compiler-error-count* 0)
	   (*compiler-warning-count* 0)
	   (*compiler-note-count* 0)
	   (*source-info* (make-lisp-source-info form)))
      (clear-stuff)
      ;;
      ;; This LET comes from COMPILE-TOP-LEVEL.
      ;; The noted DOLIST is a splice from a call that COMPILE-TOP-LEVEL makes.
      (let* ((*converting-for-interpreter* t)
	     (lambdas (list (ir1-top-level form '(0) t))))
	(declare (list lambdas))
	(dolist (lambda lambdas)
	  (let* ((component
		  (block-component (node-block (lambda-bind lambda))))
		 (*all-components* (list component)))
	    (local-call-analyze component)))
	(let* ((components (find-initial-dfo lambdas))
	       (*all-components* components))
	  (when *check-consistency*
	    (maybe-mumble "[Check]~%")
	    (check-ir1-consistency components))
	  ;;
	  ;; This DOLIST body comes from the beginning of COMPILE-COMPONENT.
	  (dolist (component components)
	    (let ((*compile-component* component))
	      (maybe-mumble "Env ")
	      (environment-analyze component))
	    (annotate-component-for-eval component))
	  (when *check-consistency*
	    (maybe-mumble "[Check]~%")
	    (check-ir1-consistency components)))
	(ir1-finalize)
	(car lambdas)))))


;;;; Annotating IR1 for interpretation.

(defstruct (lambda-eval-info (:print-function print-lambda-eval-info)
			     (:constructor make-lambda-eval-info
					   (frame-size args-passed entries)))
  frame-size		;Number of stack locations needed to hold locals.
  args-passed		;Number of referenced arguments passed to lambda.
  entries)		;A-list mapping entry nodes to stack locations.

(defun print-lambda-eval-info (obj str n)
  (declare (ignore n obj))
  (format str "#<Lambda-eval-info>"))

(defstruct (entry-node-info (:print-function print-entry-node-info)
			    (:constructor make-entry-node-info
					  (st-top nlx-tag)))
  st-top	;Stack top when we encounter the entry node.
  nlx-tag)	;Tag to which to throw to get back entry node's context.

(defun print-entry-node-info (obj str n)
  (declare (ignore n obj))
  (format str "#<Entry-node-info>"))


;;; Some compiler funny functions have definitions, so the interpreter can
;;; call them.  These require special action to coordinate the interpreter,
;;; system call stack, and the environment.  The annotation prepass marks the
;;; references to these as :unused, so the interpreter doesn't try to fetch
;;; function's through these undefined symbols.
;;;
(defconstant undefined-funny-funs
  '(%special-bind %special-unbind %more-arg-context %unknown-values %catch
    %unwind-protect %catch-breakup %unwind-protect-breakup %lexical-exit-breakup
    %continue-unwind %nlx-entry))


;;; ANNOTATE-COMPONENT-FOR-EVAL -- Internal.
;;;
;;; This annotates continuations, lambda-vars, and lambdas.  For each
;;; continuation, we cache how its destination uses its value.  This only buys
;;; efficiency when the code executes more than once, but the overhead of this
;;; part of the prepass for code executed only once should be negligible.
;;;
;;; As a special case to aid interpreting local function calls, we sometimes
;;; note the continuation as :unused.  This occurs when there is a local call,
;;; and there is no actual function object to call; we mark the continuation as
;;; :unused since there is nothing to push on the interpreter's stack.
;;; Normally we would see a reference to a function that we would push on the
;;; stack to later pop and apply to the arguments on the stack.  To determine
;;; when we have a local call with no real function object, we look at the node
;;; to see if it is a reference with a destination that is a :local combination
;;; whose function is the reference node's continuation.
;;;
;;; After checking for virtual local calls, we check for funny functions the
;;; compiler refers to for calling to note certain operations.  These functions
;;; are undefined, and if the interpreter tried to reference the function cells
;;; of these symbols, it would get an error.  We mark the continuations
;;; delivering the values of these references as :unused, so the reference
;;; never takes place.
;;;
;;; For each lambda-var, including a lambda's vars and its let's vars, we note
;;; the stack offset used to access and store that variable.  Then we note the
;;; lambda with the total number of variables, so we know how big its stack
;;; frame is.  Also in the lambda's info is the number of its arguments that it
;;; actually references; the interpreter never pushes or pops an unreferenced
;;; argument, so we can't just use LENGTH on LAMBDA-VARS to know how many args
;;; the caller passed.
;;;
;;; For each entry node in a lambda, we associate in the lambda-eval-info the
;;; entry node with a stack offset.  Evaluation code stores the frame pointer
;;; in this slot upon processing the entry node to aid stack cleanup and
;;; correct frame manipulation when processing exit nodes.
;;;
(defun annotate-component-for-eval (component)
  (do-blocks (b component)
    (do-nodes (node cont b)
      (let* ((dest (continuation-dest cont))
	     (refp (typep node 'ref))
	     (leaf (if refp (ref-leaf node))))
	(setf (continuation-info cont)
	      (cond ((and refp dest (typep dest 'combination)
			  (eq (combination-kind dest) :local)
			  (eq (combination-fun dest) cont))
		     :unused)
		    ((and leaf (typep leaf 'global-var)
			  (eq (global-var-kind leaf) :global-function)
			  (member (c::global-var-name leaf) undefined-funny-funs
				  :test #'eq))
		     :unused)
		    (t
		     (typecase dest
		       ;; Change locations in eval.lisp that think :return could
		       ;; occur.
		       ((or mv-combination creturn exit) :multiple)
		       (null :unused)
		       (t :single))))))))
  (dolist (lambda (component-lambdas component))
    (let ((locals-count 0)
	  (args-passed-count 0))
      (dolist (var (lambda-vars lambda))
	(setf (leaf-info var) locals-count)
	(incf locals-count)
	(when (leaf-refs var) (incf args-passed-count)))
      (dolist (let (lambda-lets lambda))
	(dolist (var (lambda-vars let))
	  (setf (leaf-info var) locals-count)
	  (incf locals-count)))
      (let ((entries nil))
	(dolist (e (lambda-entries lambda))
	  (ecase (process-entry-node-p e)
	    (:blow-it-off)
	    (:local-lexical-exit
	     (push (cons e (make-entry-node-info locals-count nil))
		   entries)
	     (incf locals-count))
	    (:non-local-lexical-exit
	     (push (cons e
			 (make-entry-node-info locals-count (incf locals-count)))
		   entries)
	     (incf locals-count))))
	(setf (lambda-info lambda)
	      (make-lambda-eval-info locals-count args-passed-count
				     entries))))))

;;; PROCESS-ENTRY-NODE-P -- Internal.
;;; 
(defun process-entry-node-p (entry)
  (dolist (nlx (environment-nlx-info (node-environment entry))
	       :local-lexical-exit)
    (let ((cleanup (nlx-info-cleanup nlx)))
      (ecase (cleanup-kind cleanup)
	(:entry
	 (when (eq (continuation-use (cleanup-start cleanup))
		   entry)
	   (return :non-local-lexical-exit)))
	((:catch :unwind-protect)
	 (when (eq (continuation-use (cleanup-start (cleanup-enclosing cleanup)))
		   entry)
	   (return :blow-it-off)))))))


;;; Sometime consider annotations to exclude processign of exit nodes when
;;; we want to do a tail-p thing.
;;;


;;;; Defining funny functions for interpreter.

#|
%listify-rest-args %more-arg %verify-argument-count %argument-count-error
%odd-keyword-arguments-error %unknown-keyword-argument-error
|#

(defun %verify-argument-count (supplied-args defined-args)
  (unless (= supplied-args defined-args)
    (error "Wrong argument count, wanted ~D and got ~D."
	   defined-args supplied-args)))

(defun %throw (tag &rest args)
  (throw tag (values-list args)))

(defun %more-arg (args index)
  (nth index args))

(defun %listify-rest-args (ptr count)
  (declare (ignore count))
  ptr)

(defun %argument-count-error (args-passed-count)
  (error "Wrong number of arguments passed -- ~S." args-passed-count))

(defun %odd-keyword-arguments-error ()
  (error "Function called with odd number of keyword arguments."))

(defun %unknown-keyword-argument-error (keyword)
  (error "Unknown keyword argument -- ~S." keyword))
