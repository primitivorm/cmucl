;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Package: STREAM -*-
;;;
;;; **********************************************************************
;;; This code was written by Paul Foley and has been placed in the public
;;; domain.
;;; 
(ext:file-comment
 "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/pcl/simple-streams/file.lisp,v 1.2 2003/06/07 17:56:28 toy Exp $")
;;;
;;; **********************************************************************
;;;
;;; Definition of File-Simple-Stream and relations

(in-package "STREAM")

(export '(file-simple-stream mapped-file-simple-stream probe-simple-stream))

(def-stream-class mapped-file-simple-stream (file-simple-stream
					     direct-simple-stream)
  ())

(def-stream-class probe-simple-stream (simple-stream)
  ())

(defun open-file-stream (stream options)
  (let ((filename (getf options :filename))
	(direction (getf options :direction :input))
	(if-exists (getf options :if-exists))
	(if-exists-given (not (getf options :if-exists t)))
	(if-does-not-exist (getf options :if-does-not-exist))
	(if-does-not-exist-given (not (getf options :if-does-not-exist t))))
    (with-stream-class (file-simple-stream stream)
      (ecase direction
	(:input (add-stream-instance-flags stream :input))
	(:output (add-stream-instance-flags stream :output))
	(:io (add-stream-instance-flags stream :input :output)))
      (cond ((and (sm input-handle stream) (sm output-handle stream)
		  (not (eql (sm input-handle stream)
			    (sm output-handle stream))))
	     (error "Input-Handle and Output-Handle can't be different."))
	    ((or (sm input-handle stream) (sm output-handle stream))
	     (add-stream-instance-flags stream :simple)
	     ;; get namestring, etc., from handle, if possible
	     ;;    (i.e., if it's a stream)
	     ;; set up buffers
	     stream)
	    (t
	     (multiple-value-bind (fd namestring original delete-original)
		 (cl::fd-open filename direction if-exists if-exists-given
			      if-does-not-exist if-does-not-exist-given)
	       (when fd
		 (add-stream-instance-flags stream :simple)
		 (setf (sm pathname stream) filename
		       (sm filename stream) namestring
		       (sm original stream) original
		       (sm delete-original stream) delete-original)
		 (when (any-stream-instance-flags stream :input)
		   (setf (sm input-handle stream) fd))
		 (when (any-stream-instance-flags stream :output)
		   (setf (sm output-handle stream) fd))
		 (ext:finalize stream
		   (lambda ()
		     (unix:unix-close fd)
		     (format *terminal-io* "~&;;; ** closed ~S (fd ~D)~%"
			     namestring fd)))
		 stream)))))))


(defmethod device-open ((stream file-simple-stream) options)
  (with-stream-class (file-simple-stream stream)
    (when (open-file-stream stream options)
      ;; Franz says:
      ;;  "The device-open method must be prepared to recognize resource
      ;;   and change-class situations. If no filename is specified in
      ;;   the options list, and if no input-handle or output-handle is
      ;;   given, then the input-handle and output-handle slots should
      ;;   be examined; if non-nil, that means the stream is still open,
      ;;   and thus the operation being requested of device-open is a
      ;;   change-class. Also, a device-open method need not allocate a
      ;;   buffer every time it is called, but may instead reuse a
      ;;   buffer it finds in a stream, if it does not become a security
      ;;   issue."
      (unless (sm buffer stream)
	(let ((length (device-buffer-length stream)))
	  ;; Buffer should be array of (unsigned-byte 8), in general
	  ;; use strings for now so it's easy to read the content...
	  (setf (sm buffer stream) (make-string length)
		(sm buffpos stream) 0
		(sm buffer-ptr stream) 0
		(sm buf-len stream) length)))
      (when (any-stream-instance-flags stream :output)
	(setf (sm control-out stream) *std-control-out-table*))
      (let ((efmt (getf options :external-format :default)))
	(compose-encapsulating-streams stream efmt)
	(install-single-channel-character-strategy stream efmt nil))
      stream)))

(defmethod device-close ((stream file-simple-stream) abort)
  (with-stream-class (file-simple-stream stream)
    (let ((fd (or (sm input-handle stream) (sm output-handle stream))))
      (cond (abort
	     ;; Remove any fd-handler
	     (when (any-stream-instance-flags stream :output)
	       (cl::revert-file (sm filename stream) (sm original stream))))
	    (t
	     (when (sm delete-original stream)
	       (cl::delete-original (sm filename stream)
				    (sm original stream)))))
      (unix:unix-close fd)
      ;; if buffer is a sap, put it back on cl::*available-buffers*
      (setf (sm buffer stream) nil)))
  t)

(defmethod device-file-position ((stream file-simple-stream))
  (with-stream-class (file-simple-stream stream)
    (values (unix:unix-lseek (or (sm input-handle stream)
				 (sm output-handle stream))
			     0
			     unix:l_incr))))

(defmethod (setf device-file-position) (value (stream file-simple-stream))
  (declare (type fixnum value))
  (with-stream-class (file-simple-stream stream)
    (values (unix:unix-lseek (or (sm input-handle stream)
				 (sm output-handle stream))
			     value
			     (if (minusp value) unix:l_xtnd unix:l_set)))))

(defmethod device-file-length ((stream file-simple-stream))
  (with-stream-class (file-simple-stream stream)
    (multiple-value-bind (okay dev ino mode nlink uid gid rdev size)
	(unix:unix-fstat (sm input-handle stream))
      (declare (ignore dev ino mode nlink uid gid rdev))
      (if okay size nil))))


(defmethod device-open ((stream mapped-file-simple-stream) options)
  (with-stream-class (mapped-file-simple-stream stream)
    (when (open-file-stream stream options)
      (let* ((input (any-stream-instance-flags stream :input))
	     (output (any-stream-instance-flags stream :output))
	     (prot (logior (if input unix:prot_read 0)
			   (if output unix:prot_write 0)))
	     (fd (or (sm input-handle stream) (sm output-handle stream))))
	(multiple-value-bind (okay dev ino mode nlink uid gid rdev size)
	    (unix:unix-fstat fd)
	  (declare (ignore ino mode nlink uid gid rdev))
	  (unless okay
	    (unix:unix-close fd)
	    (ext:cancel-finalization stream)
	    (error "Error fstating ~S: ~A" stream
		   (unix:get-unix-error-msg dev)))
	  (when (> size most-positive-fixnum)
	    ;; Or else BUF-LEN has to be a general integer, or
	    ;; maybe (unsigned-byte 32).  In any case, this means
	    ;; BUF-MAX and BUF-PTR have to be the same, which means
	    ;; number-consing every time BUF-PTR moves...
	    ;; Probably don't have the address space available to map
	    ;; bigger files, anyway.  Maybe DEVICE-EXTEND can adjust
	    ;; the mapped portion of the file?
	    (warn "Unable to memory-map entire file.")
	    (setf size most-positive-fixnum))
	  (let ((buffer
		 (unix:unix-mmap nil size prot unix:map_shared fd 0)))
	    (when (null buffer)
	      (unix:unix-close fd)
	      (ext:cancel-finalization stream)
	      (error "Unable to map file."))
	    (setf (sm buffer stream) buffer
		  (sm buffpos stream) 0
		  (sm buffer-ptr stream) size
		  (sm buf-len stream) size)
	    (install-single-channel-character-strategy
	     stream (getf options :external-format :default) 'mapped)
	    (ext:finalize stream
	      (lambda ()
		(unix:unix-munmap buffer size)
		(format *terminal-io* "~&;;; ** unmapped ~S" buffer))))))
      stream)))

(defmethod device-close ((stream mapped-file-simple-stream) abort)
  (with-stream-class (mapped-file-simple-stream stream)
    (when (sm buffer stream)
      (unix:unix-munmap (sm buffer stream) (sm buf-len stream))
      (setf (sm buffer stream) nil))
    (cond (abort
	   ;; remove any fd handler
	   ;; if it has an original name (is this possible for mapped files?)
	   ;;   revert the file
	   )
	  (t
	   ;; if there's an original name and delete-original is set (again,
	   ;;   is this even possible?), kill the original
	   ))
    (unix:unix-close (sm input-handle stream)))
  t)