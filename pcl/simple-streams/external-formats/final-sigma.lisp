;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Package: STREAM -*-
;;;
;;; **********************************************************************
;;; This code was written by Paul Foley and has been placed in the public
;;; domain.
;;;
(ext:file-comment "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/pcl/simple-streams/external-formats/final-sigma.lisp,v 1.1.2.1 2009/04/28 16:52:17 rtoy Exp $")

;; This is a composing format that attempts to detect sigma in
;; word-final position and change it from "~" to "~".

(define-composing-external-format :final-sigma (:size 1)
  (input (state input unput tmp1 tmp2 tmp3 tmp4)
    `(multiple-value-bind (,tmp1 ,tmp2) ,input
       (when (= ,tmp1 #x03C3)
	 (multiple-value-bind (,tmp3 ,tmp4) ,input
	   (when (or (not ,tmp3) (< ,tmp3 #x0370))
	     (setq ,tmp1 #x03C2))
	   (when ,tmp3
	     (,unput ,tmp4))))
       (values ,tmp1 ,tmp2)))
  (output (code state output)
    `(,output ,code)))
