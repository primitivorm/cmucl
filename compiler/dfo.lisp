;;; -*- Package: C; Log: C.Log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC). 
;;; **********************************************************************
;;;
;;;     This file contains the code that finds the initial components and DFO,
;;; and recomputes the DFO if it is invalidated.
;;;
;;; Written by Rob MacLachlan
;;;
(in-package 'c)


;;; Find-DFO  --  Interface
;;;
;;;    Find the DFO for a component, deleting any unreached blocks and merging
;;; any other components we reach.  We repeatedly iterate over the entry
;;; points, since new ones may show up during the walk.
;;;
(proclaim '(function find-dfo (component) void))
(defun find-dfo (component)
  (clear-flags component)
  (let ((head (component-head component)))
    (do ()
	((dolist (ep (block-succ head) t)
	   (unless (block-flag ep)
	     (find-dfo-aux ep head component)
	     (return nil))))))

  (let ((num 0))
    (declare (fixnum num))
    (do-blocks-backwards (block component :both)
      (if (block-flag block)
	  (setf (block-number block) (incf num))
	  (delete-block block))))
  (setf (component-reanalyze component) nil))


;;; Join-Components  --  Internal
;;;
;;;    Move all the code and entry points from Old to New.  The code in Old is
;;; inserted at the head of New.
;;;
(proclaim '(function join-components (component component) void))
(defun join-components (new old)
  (let ((old-head (component-head old))
	(old-tail (component-tail old))
	(head (component-head new))
	(tail (component-tail new)))
    
    (do-blocks (block old)
      (setf (block-flag block) nil)
      (setf (block-component block) new))
    
    (let ((old-next (block-next old-head))
	  (old-last (block-prev old-tail))
	  (next (block-next head)))
      (unless (eq old-next old-tail)
	(setf (block-next head) old-next)
	(setf (block-prev old-next) head)
	
	(setf (block-prev next) old-last)
	(setf (block-next old-last) next))
      
      (setf (block-next old-head) old-tail)
      (setf (block-prev old-tail) old-head))

    (setf (component-lambdas new)
	  (nconc (component-lambdas old) (component-lambdas new)))
    (setf (component-lambdas old) ())
    (setf (component-new-functions new)
	  (nconc (component-new-functions old) (component-new-functions new)))
    (setf (component-new-functions old) ())

    (dolist (xp (block-pred old-tail))
      (unlink-blocks xp old-tail)
      (link-blocks xp tail))
    (dolist (ep (block-succ old-head))
      (unlink-blocks old-head ep)
      (link-blocks head ep))))


;;; Find-DFO-Aux  --  Internal
;;;
;;;    Do a depth-first walk from Block, inserting ourself in the DFO after
;;; Head.  If we somehow find ourselves in another component, then we join that
;;; component to our component.
;;;
(proclaim '(function find-dfo-aux (cblock cblock component) void))
(defun find-dfo-aux (block head component)
  (unless (eq (block-component block) component)
    (join-components component (block-component block)))
	
  (unless (block-flag block)
    (setf (block-flag block) t)
    (dolist (succ (block-succ block))
      (find-dfo-aux succ head component))

    (remove-from-dfo block)
    (add-to-dfo block head)))


;;; Walk-Home-Call-Graph  --  Internal
;;;
;;;   This function ensures that all the blocks in a given environment will be
;;; in the same component, even when they might not seem reachable from the
;;; environment entry.  Consider the case of code that is only reachable from a
;;; non-local exit.
;;;
;;;    This function is called on each block by Find-Initial-DFO-Aux before it
;;; walks the successors.  It looks at the home lambda's bind block to see if
;;; that block is in some other component:
;;; -- If the block is in the initial component, then do DFO-Walk-Call-Graph on
;;;    the home function to move it into component.
;;; -- If the block is in some other component, join Component into it and
;;;    return that component.
;;;
;;; This ensures that all the blocks in a given environment will be in the same
;;; component, even when they might not seem reachable from the environment
;;; entry.  Consider the case of code that is only reachable from a non-local
;;; exit.
;;;
(defun walk-home-call-graph (block component)
  (declare (type cblock block) (type component component))
  (let* ((home (lambda-home (block-lambda block)))
	 (bind-block (node-block (lambda-bind home)))
	 (home-component (block-component bind-block)))
    (cond ((eq (component-kind home-component) :initial)
	   (dfo-walk-call-graph home component))
	  ((eq home-component component)
	   component)
	  (t
	   (join-components home-component component)
	   home-component))))


;;; Find-Initial-DFO-Aux  --  Internal
;;;
;;;    Somewhat similar to Find-DFO-Aux, except that it merges the current
;;; component with any strange component, rather than the other way around.
;;; This is more efficient in the common case where the current component
;;; doesn't have much stuff in it.
;;;
;;;    We return the current component as a result, allowing the caller to
;;; detect when the old current component has been merged with another.
;;;
;;;    We walk blocks in initial components as though they were already in the
;;; current component, moving them to the current component in the process.
;;; The blocks are inserted at the head of the current component.
;;;
(defun find-initial-dfo-aux (block component)
  (declare (type cblock block) (type component component))
  (let ((this (block-component block)))
    (cond
     ((not (or (eq this component)
	       (eq (component-kind this) :initial)))
      (join-components this component)
      this)
     ((block-flag block) component)
     (t
      (setf (block-flag block) t)
      (let ((current (walk-home-call-graph block component)))
	(dolist (succ (block-succ block))
	  (setq current (find-initial-dfo-aux succ current)))
	
	(remove-from-dfo block)
	(add-to-dfo block (component-head current))
	current)))))


;;; Find-Reference-Functions  --  Internal
;;;
;;;    Return a list of all the home lambdas that reference Fun (may contain
;;; duplications).  References to XEP lambdas in top-level lambdas are excluded
;;; to keep run-time definitions from being joined to load-time code.  We mark
;;; any such top-level references as :notinline to prevent the (unlikely)
;;; possiblity that they might later be converted.  This preserves the
;;; invariant that local calls are always intra-component without joining in
;;; all top-level code.
;;;
(defun find-reference-functions (fun)
  (collect ((res))
    (dolist (ref (leaf-refs fun))
      (let ((home (lambda-home (block-lambda (node-block ref)))))
	(if (and (eq (functional-kind home) :top-level)
		 (eq (functional-kind fun) :external))
	    (setf (ref-inlinep ref) :notinline)
	    (res home))))
    (res)))


;;; DFO-Walk-Call-Graph  --  Internal
;;;
;;;    Move the code for Fun and all functions called by it into Component.
;;;
;;;    If the function is in an initial component, then we move its head and
;;; tail to Component and add it to Component's lambdas.  We then do a
;;; Find-DFO-Aux starting at the head of Fun.  If this flow-graph walk
;;; encounters another component (which can only happen due to a non-local
;;; exit), then we move code into that component instead.  We then recurse on
;;; all functions called from Fun, moving code into whichever component the
;;; preceding call returned.
;;;
;;;    If the function is an XEP, then we also walk all functions that contain
;;; references to the XEP.  This is done so that environment analysis doesn't
;;; need to cross component boundries.  This also ensures that conversion of a
;;; full call to a local call won't result in a need to join components, since
;;; the components will already be one.
;;;
;;;    If Fun is in the initial component, but the Block-Flag is set in the
;;; bind block, then we just return Component, since we must have already
;;; reached this function in the current walk (or the component would have been
;;; changed).  If Fun is already in Component, then we just return that
;;; component.
;;;
(defun dfo-walk-call-graph (fun component)
  (declare (type clambda fun) (type component component))
  (let* ((bind-block (node-block (lambda-bind fun)))
	 (this (block-component bind-block))
	 (return (lambda-return fun)))
    (cond
     ((eq this component) component)
     ((not (eq (component-kind this) :initial))
      (join-components this component)
      this)
     ((block-flag bind-block)
      component)
     (t
      (push fun (component-lambdas component))
      (link-blocks (component-head component) bind-block)
      (unlink-blocks (component-head this) bind-block)
      (when return
	(let ((return-block (node-block return)))
	  (link-blocks return-block (component-tail component))
	  (unlink-blocks return-block (component-tail this))))
      (let ((calls (if (eq (functional-kind fun) :external)
		       (append (find-reference-functions fun)
			       (lambda-calls fun))
		       (lambda-calls fun))))
	(do ((res (find-initial-dfo-aux bind-block component)
		  (dfo-walk-call-graph (first funs) res))
	     (funs calls (rest funs)))
	    ((null funs) res)
	  (declare (type component res))))))))
	    

;;; Find-Initial-DFO  --  Interface
;;;
;;;    Given a list of top-level lambdas, return a list of components
;;; representing the actual component division.  We assign the DFO for each
;;; component, and delete any unreachable blocks.  We assume that the Flags
;;; have already been cleared.
;;;
;;;     We iterate over the lambdas in each initial component, trying to put
;;; each function in its own component, but joining it to an existing component
;;; if we find that there are references between them.
;;;
;;;    When we are done, we assign DFNs and delete any components that are
;;; empty due to having been merged with another component.  Since all
;;; functions are walked, moving all reachable code to another component, all
;;; blocks remaining in the initial component may be deleted.  The only code
;;; left will be in deleted functions or not reachable from the entry to the
;;; function.
;;;
;;;   We also find components that contain a :Top-Level lambda and no :External
;;; lambdas, marking them as :Top-Level.  Top-Level components are returned at
;;; the end of the list so that we compile all real functions before we start
;;; compiling any Top-Level references to them.  This allows DEFUN, etc., to
;;; reference functions not in their component (which is normally forbidden).
;;;
(defun find-initial-dfo (lambdas)
  (declare (list lambdas))
  (collect ((components))
    (let ((new (make-empty-component)))
      (dolist (tll lambdas)
	(let ((component (block-component (node-block (lambda-bind tll)))))
	  (dolist (fun (component-lambdas component))
	    (assert (member (functional-kind fun)
			    '(:optional :external :top-level nil :escape
					:cleanup)))
	    (let ((res (dfo-walk-call-graph fun new)))
	      (when (eq res new)
		(components new)
		(setq new (make-empty-component)))))
      
	  (do-blocks (block component)
	    (delete-block block)))))
    
    (collect ((real)
	      (top))
      (dolist (com (components))
	(let ((num 0))
	  (declare (fixnum num))
	  (do-blocks-backwards (block com :both)
	    (setf (block-number block) (incf num)))
	  (unless (= num 2)
	    (setf (component-name com) (find-component-name com))
	    (let ((funs (component-lambdas com)))
	      (cond ((find :top-level funs :key #'functional-kind)
		     (unless (find :external funs :key #'functional-kind)
		       (setf (component-kind com) :top-level)
		       (setf (component-name com) "Top-Level Form"))
		     (top com))
		    (t
		     (real com)))))))
      (nconc (real) (top)))))
