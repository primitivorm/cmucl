;;; -*- Mode: Lisp; Package: Lisp; Log: code.log -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;; If you want to use this code or any part of CMU Common Lisp, please contact
;;; Scott Fahlman or slisp-group@cs.cmu.edu.
;;;
(ext:file-comment
  "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/code/sunos-os.lisp,v 1.5 1992/03/26 03:35:02 wlott Exp $")
;;;
;;; **********************************************************************
;;;
;;; OS interface functions for CMU CL under Mach.  From Miles Bader and David
;;; Axmark.
;;;
(in-package "SYSTEM")
(use-package "EXTENSIONS")
(export '(get-system-info get-page-size os-init))

(pushnew :sunos *features*)
(setq *software-type* "SunOS")

(defconstant foreign-segment-start #x00C00000) ; ### Not right???
(defconstant foreign-segment-size  #x00400000)

(defvar *software-version* nil "Version string for supporting software")
(defun software-version ()
  "Returns a string describing version of the supporting software."
  (unless *software-version*
    (setf *software-version*
	  (let ((version-line
		 (with-output-to-string (stream)
		   (run-program
		    "/bin/sh"
		    '("-c" "strings /vmunix|grep -i 'sunos release'")
		    :output stream
		    :pty nil
		    :error nil))))
	    (let* ((first-space (position #\Space version-line))
		   (second-space (position #\Space version-line
					   :start (1+ first-space)))
		   (third-space (position #\Space version-line
					  :start (1+ second-space))))
	      (subseq version-line (1+ second-space) third-space)))))
  *software-version*)


;;; OS-INIT -- interface.
;;;
;;; Other OS dependent initializations.
;;; 
(defun os-init ()
  ;; Decache version on save, because it might not be the same when we restart.
  (setq *software-version* nil))

;;; GET-SYSTEM-INFO  --  Interface
;;;
;;;    Return system time, user time and number of page faults.
;;;
(defun get-system-info ()
  (let (run-utime run-stime page-faults)
    (multiple-value-bind (err? utime stime maxrss ixrss idrss
                               isrss minflt majflt)
        (unix:unix-getrusage unix:rusage_self)
      (declare (ignore maxrss ixrss idrss isrss minflt))
      (cond ((null err?)
             (error "Unix system call getrusage failed: ~A."
                    (unix:get-unix-error-msg utime)))
            (T (values utime stime majflt))))))


;;; GET-PAGE-SIZE  --  Interface
;;;
;;;    Return the system page size.
;;;
(defun get-page-size ()
  (multiple-value-bind (val err)
		       (unix:unix-getpagesize)
    (unless val
      (error "Getpagesize failed: ~A" (unix:get-unix-error-msg err)))
    val))
