;;; -*- Log: hemlock.log; Package: Hemlock -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the Spice Lisp project at
;;; Carnegie-Mellon University, and has been placed in the public domain.
;;; Spice Lisp is currently incomplete and under active development.
;;; If you want to use this code or any part of Spice Lisp, please contact
;;; Scott Fahlman (FAHLMAN@CMUC).
;;; **********************************************************************
;;;
;;; This file contains code for connecting to eval servers and some command
;;; level stuff too.
;;;
;;; Written by William Lott.
;;;

(in-package "HEMLOCK")



;;;; Structures.

(defstruct (server-info (:print-function print-server-info))
  name			      ; String name of this server.
  wire			      ; Wire connected to this server.
  notes			      ; List of note objects for operations
			      ;  which have not yet completed.
  slave-info		      ; Ts-Info used in "Slave Lisp" buffer
			      ;  (formerly the "Lisp Listener" buffer).
  slave-buffer		      ; "Slave Lisp" buffer for slave's *terminal-io*.
  background-info	      ; Ts-Info structure of typescript we use in
			      ;  "background" buffer.
  background-buffer	      ; Buffer "background" typescript is in.
  (errors		      ; Array of errors while compiling
   (make-array 16
	       :adjustable t
	       :fill-pointer 0))
  error-index)		      ; Index of current error.
;;;
(defun print-server-info (obj stream n)
  (declare (ignore n))
  (format stream "#<Server-info for ~A>" (server-info-name obj)))


(defstruct (error-info (:print-function print-error-info))
  buffer		      ; Buffer this error is for.
  message		      ; Error Message
  line			      ; Pointer to message in log buffer.
  region)		      ; Region of faulty text
;;;
(defun print-error-info (obj stream n)
  (declare (ignore n))
  (format stream "#<Error: ~A>" (error-info-message obj)))


(defvar *server-names* (make-string-table)
  "A string-table of the name of all Eval servers and their corresponding
   server-info structures.")

(defvar *abort-operations* nil
  "T iff we should ignore any operations sent to us.")

(defvar *inside-operation* nil
  "T iff we are currenly working on an operation. A catcher for the tag 
   abort-operation will be established whenever this is T.")

(defconstant *slave-connect-wait* 300)

;;; Used internally for communications.
;;;
(defvar *newly-created-slave* nil)
(defvar *compiler-wire* nil)
(defvar *compiler-error-stream* nil)
(defvar *compiler-note* nil)



;;;; Hemlock Variables

(defhvar "Current Eval Server"
  "The Server-Info object for the server currently used for evaluation and
   compilation."
  :value nil)

(defhvar "Current Compile Server"
  "The Server-Info object for the server currently used for compilation
   requests."
  :value nil)

(defhvar "Current Package"
  "This variable holds the name of the package currently used for Lisp
   evaluation and compilation.  If it is Nil, the value of *Package* is used
   instead."
  :value nil)

(defhvar "Slave Utility"
  "This is the pathname of the utility to fire up slave Lisps.  It defaults
   to /usr/misc/.lisp/bin/lisp."
  :value "/usr/misc/.lisp/bin/lisp")

(defhvar "Slave Utility Switches"
  "These are additional switches to pass to the Slave Utility.
   For example, (list \"-core\" <core-file-name>).  The -slave
   switch and the editor name are always supplied, and they should
   not be present in this variable."
  :value nil)

(defhvar "Ask About Old Servers"
  "When set (the default), Hemlock will prompt for an existing server's name
   in preference to prompting for a new slave's name and creating it."
  :value t)

(defhvar "Confirm Slave Creation"
  "When set (the default), Hemlock always confirms a slave's creation for
   whatever reason."
  :value t)



;;;; Slave destruction.

;;; WIRE-DIED -- Internal.
;;;
;;; The routine is called whenever a wire dies.  We roll through all the
;;; servers looking for any that use this wire and nuke them with server-died.
;;;
(defun wire-died (wire)
  (let ((servers nil))
    (do-strings (name info *server-names*)
      (declare (ignore name))
      (when (eq wire (server-info-wire info))
	(push info servers)))
    (dolist (server servers)
      (server-died server))))

;;; SERVER-DIED -- Internal.
;;;
;;; Clean up the server. Remove any references to it from variables, etc.
;;;
(defun server-died (server)
  (let ((name (server-info-name server)))
    (delete-string name *server-names*)
    (message "Server ~A just died." name))
  (when (server-info-wire server)
    (let ((fd (wire:wire-fd (server-info-wire server))))
      (system:invalidate-descriptor fd)
      (mach:unix-close fd))
    (setf (server-info-wire server) nil))
  (when (server-info-slave-info server)
    (ts-buffer-wire-died (server-info-slave-info server))
    (setf (server-info-slave-info server) nil))
  (when (server-info-background-info server)
    (ts-buffer-wire-died (server-info-background-info server))
    (setf (server-info-background-info server) nil))
  (clear-server-errors server)
  (when (eq server (variable-value 'current-eval-server :global))
    (setf (variable-value 'current-eval-server :global) nil))
  (when (eq server (variable-value 'current-compile-server :global))
    (setf (variable-value 'current-compile-server :global) nil))
  (dolist (buffer *buffer-list*)
    (dolist (var '(current-eval-server current-compile-server server-info))
      (when (and (hemlock-bound-p var :buffer buffer)
		 (eq (variable-value var :buffer buffer) server))
	(delete-variable var :buffer buffer)))))

;;; SERVER-CLEANUP -- Internal.
;;;
;;; This routine is called as a buffer delete hook.  It takes care of any
;;; per-buffer cleanup that is necessary.  It clears out all references to the
;;; buffer from server-info structures and that any errors that refer to this
;;; buffer are finalized.
;;;
(defun server-cleanup (buffer)
  (let ((info (if (hemlock-bound-p 'server-info :buffer buffer)
		  (variable-value 'server-info :buffer buffer))))
    (when info
      (when (eq buffer (server-info-slave-buffer info))
	(setf (server-info-slave-buffer info) nil)
	(setf (server-info-slave-info info) nil))
      (when (eq buffer (server-info-background-buffer info))
	(setf (server-info-background-buffer info) nil)
	(setf (server-info-background-info info) nil))))
  (do-strings (string server *server-names*)
    (declare (ignore string))
    (clear-server-errors server
			 #'(lambda (error)
			     (eq (error-info-buffer error) buffer)))))
;;;
(add-hook delete-buffer-hook 'server-cleanup)

;;; CLEAR-SERVER-ERRORS -- Public.
;;;
;;; Clears all known errors for the given server and resets it so more can
;;; accumulate.
;;;
(defun clear-server-errors (server &optional test-fn)
  "This clears compiler errors for server cleaning up any pointers for GC
   purposes and allowing more errors to register."
  (let ((array (server-info-errors server))
	(current nil))
    (dotimes (i (fill-pointer array))
      (let ((error (aref array i)))
	(when (or (null test-fn)
		  (funcall test-fn error))
	  (let ((region (error-info-region error)))
	    (when (regionp region)
	      (delete-mark (region-start region))
	      (delete-mark (region-end region))))
	  (setf (aref array i) nil))))
    (let ((index (server-info-error-index server)))
      (when index
	(setf current
	      (or (aref array index)
		  (find-if-not #'null array
			       :from-end t
			       :end current)))))
    (delete nil array)
    (setf (server-info-error-index server)
	  (position current array))))



;;;; Slave creation.

;;; INITIALIZE-SERVER-STUFF -- Internal.
;;;
;;; Reinitialize stuff when a core file is saved.
;;;
(defun initialize-server-stuff ()
  (clrstring *server-names*))


(defvar *editor-name* nil "Name of this editor.")
(defvar *accept-connections* nil
  "When set, allow slaves to connect to the editor.")

;;; GET-EDITOR-NAME -- Internal.
;;;
;;; Pick a name for the editor.  Names consist of machine-name:port-number.  If
;;; in ten tries we can't get an unused port, choak.  We don't save the result
;;; of WIRE:CREATE-REQUEST-SERVER because we don't think the editor needs to
;;; ever kill the request server, and we can always inhibit connection with
;;; "Accept Connections".
;;;
(defun get-editor-name ()
  (if *editor-name*
      *editor-name*
      (let ((random-state (make-random-state t)))
	(dotimes (tries 10 (error "Could not create an internet listener."))
	  (let ((port (+ 2000 (random 10000 random-state))))
	    (when (handler-case (wire:create-request-server
				 port
				 #'(lambda (wire addr)
				     (declare (ignore addr))
				     (values *accept-connections*
					     #'(lambda () (wire-died wire)))))
		    (error () nil))
	      (return (setf *editor-name*
			    (format nil "~A:~D" (machine-instance) port)))))))))


;;; MAKE-BUFFERS-FOR-TYPESCRIPT -- Internal.
;;;
;;; This function returns no values because it is called remotely for value by
;;; connecting slaves.  Though we know the system will propagate nil back to
;;; the slave, we indicate here that nil is meaningless.
;;;
(defun make-buffers-for-typescript (slave-name background-name)
  "Make the interactive and background buffers slave-name and background-name.
   If either is nil, then prompt the user."
  (multiple-value-bind (slave-name background-name)
		       (if (and slave-name background-name)
			   (values slave-name background-name)
			   (pick-slave-buffer-names))
    (let* ((slave-buffer (or (getstring slave-name *buffer-names*)
			     (make-buffer slave-name :modes '("Lisp"))))
	   (background-buffer (or (getstring background-name *buffer-names*)
				  (make-buffer background-name
					       :modes '("Lisp"))))
	   (server-info (make-server-info :name slave-name
					  :wire wire:*current-wire*
					  :slave-buffer slave-buffer
					  :background-buffer background-buffer))
	   (slave-info (typescriptify-buffer slave-buffer server-info
					     wire:*current-wire*))
	   (background-info (typescriptify-buffer background-buffer server-info
						  wire:*current-wire*)))
      (setf (server-info-slave-info server-info) slave-info)
      (setf (server-info-background-info server-info) background-info)
      (setf (getstring slave-name *server-names*) server-info)
      (unless (variable-value 'current-eval-server :global)
	(setf (variable-value 'current-eval-server :global) server-info))
      (wire:remote-value
       wire:*current-wire*
       (made-buffers-for-typescript (wire:make-remote-object slave-info)
				    (wire:make-remote-object background-info)))
      (setf *newly-created-slave* server-info)
      (values))))


;;; CREATE-SLAVE -- Public.
;;;
(defun create-slave (&optional name)
  "This creates a slave that tries to connect to the editor.  When the slave
   connects to the editor, this returns a slave-information structure.  Name is
   the name of the interactive buffer.  If name is nil, this generates a name.
   If name is supplied, and a buffer with that name already exists, this
   signals an error.  In case the slave never connects, this will eventually
   timeout and signal an editor-error."
  (when (and name (getstring name *buffer-names*))
    (editor-error "Buffer ~A is already in use." name))
  (multiple-value-bind (slave background)
		       (if name
			   (values name (format nil "Background ~A" name))
			   (pick-slave-buffer-names))
    (when (value confirm-slave-creation)
       (setf slave (prompt-for-string
		    :prompt "New slave name? "
		    :help "Enter the name to use for the newly created slave."
		    :default slave
		    :default-string slave))
       (setf background (format nil "Background ~A" slave))
       (when (getstring slave *buffer-names*)
	 (editor-error "Buffer ~A is already in use." slave))
       (when (getstring background *buffer-names*)
	 (editor-error "Buffer ~A is already in use." background)))
    (message "Spawning slave ... ")
    (let ((proc
	   (ext:run-program (namestring (truename (value slave-utility)))
			    `("-slave" ,(get-editor-name)
			      ,@(if slave (list "-slave-buffer" slave))
			      ,@(if background
				    (list "-background-buffer" background))
			      ,@(value slave-utility-switches))
			    :wait nil
			    :output "/dev/null"
			    :if-output-exists :append))
	  (*accept-connections* t)
	  (*newly-created-slave* nil))
      (unless proc
	(editor-error "Could not start slave."))
      (dotimes (i *slave-connect-wait*
		  (editor-error "Client Lisp is still unconnected.  ~
				 You must use \"Accept Slave Connections\" to ~
				 allow the slave to connect at this point."))
	(system:serve-event 1)
	(case (ext:process-status proc)
	  (:exited
	   (editor-error "The slave lisp exited before connecting."))
	  (:signaled
	   (editor-error "The slave lisp was kill before connecting.")))
	(when *newly-created-slave*
	  (message "DONE")
	  (return *newly-created-slave*))))))

;;; MAYBE-CREATE-SERVER -- Internal interface.
;;;
(defun maybe-create-server ()
  "If there is an existing server and \"Ask about Old Servers\" is set, then
   prompt for a server's name and return that server's info.  Otherwise,
   create a new server."
  (if (value ask-about-old-servers)
      (multiple-value-bind (first-server-name first-server-info)
			   (do-strings (name info *server-names*)
			     (return (values name info)))
	(if first-server-info
	    (multiple-value-bind
		(name info)
		(prompt-for-keyword (list *server-names*)
				    :prompt "Existing server name: "
				    :default first-server-name
				    :default-string first-server-name
				    :help
				    "Enter the name of an existing eval server."
				    :must-exist t)
	      (declare (ignore name))
	      (or info (create-slave)))
	    (create-slave)))
      (create-slave)))


(defvar *next-slave-index* 0
  "Number to use when creating the next slave.")

;;; PICK-SLAVE-BUFFER-NAMES -- Internal.
;;;
;;; Return two unused names to use for the slave and background buffers.
;;;
(defun pick-slave-buffer-names ()
  (loop
    (let ((slave (format nil "Slave ~D" (incf *next-slave-index*)))
	  (background (format nil "Background Slave ~D" *next-slave-index*)))
      (unless (or (getstring slave *buffer-names*)
		  (getstring background *buffer-names*))
	(return (values slave background))))))



;;;; Slave selection.

;;; GET-CURRENT-EVAL-SERVER -- Public.
;;;
(defun get-current-eval-server (&optional errorp)
  "Returns the server-info struct for the current eval server.  If there is
   none, and errorp is non-nil, then signal an editor error.  If there is no
   current server, and errorp is nil, then create one, prompting the user for
   confirmation.  Also, set the current server to be the newly created one."
  (let ((info (value current-eval-server)))
    (cond (info)
	  (errorp
	   (editor-error "No current eval server."))
	  (t
	   (setf (value current-eval-server) (maybe-create-server))))))

;;; GET-CURRENT-COMPILE-SERVER -- Public.
;;;
;;; If a current compile server is defined, return it, otherwise return the
;;; current eval server using get-current-eval-server.
;;;
(defun get-current-compile-server (&optional errorp)
  "Returns the server-info struct for the current compile server. If there is
   no current compile server, return the current eval server."
  (or (value current-compile-server)
      (get-current-eval-server errorp)))



;;;; Server Manipulation commands.

(defcommand "Select Slave" (p)
  "Switch to the current slave's buffer.  When given an argument, create a new
   slave."
  "Switch to the current slave's buffer.  When given an argument, create a new
   slave."
  (let* ((info (if p (create-slave) (get-current-eval-server)))
	 (slave (server-info-slave-buffer info)))
    (unless slave
      (editor-error "The current eval server doesn't have a slave buffer!"))
    (change-to-buffer slave)))

(defcommand "Select Background" (p)
  "Switch to the current slave's background buffer. When given an argument, use
   the current compile server instead of the current eval server."
  "Switch to the current slave's background buffer. When given an argument, use
   the current compile server instead of the current eval server."
  (let* ((info (if p
		 (get-current-compile-server t)
		 (get-current-eval-server t)))
	 (background (server-info-background-buffer info)))
    (unless background
      (editor-error "The current ~A server doesn't have a background buffer!"
		    (if p "compile" "eval")))
    (change-to-buffer background)))

(defcommand "Kill Slave" (p)
  "This aborts any operations in the slave, tells the slave to QUIT, and shuts
   down the connection to the specified eval server.  This makes no attempt to
   assure the eval server actually dies."
  "This aborts any operations in the slave, tells the slave to QUIT, and shuts
   down the connection to the specified eval server.  This makes no attempt to
   assure the eval server actually dies."
  (declare (ignore p))
  (let ((default (and (value current-eval-server)
		      (server-info-name (value current-eval-server)))))
    (multiple-value-bind
	(name info)
	(prompt-for-keyword
	 (list *server-names*)
	 :prompt "Kill Slave: "
	 :help "Enter the name of the eval server you wish to destroy."
	 :must-exist t
	 :default default
	 :default-string default)
      (declare (ignore name))
      (let ((wire (server-info-wire info)))
	(when wire
	  (ext:send-character-out-of-band (wire:wire-fd wire) #\N)
	  (wire:remote wire (ext:quit))
	  (wire:wire-force-output wire)))
      (server-died info))))

(defcommand "Kill Slave and Buffers" (p)
  "This is the same as \"Kill Slave\", but it also deletes the slaves
   interaction and background buffers."
  "This is the same as \"Kill Slave\", but it also deletes the slaves
   interaction and background buffers."
  (declare (ignore p))
  (let ((default (and (value current-eval-server)
		      (server-info-name (value current-eval-server)))))
    (multiple-value-bind
	(name info)
	(prompt-for-keyword
	 (list *server-names*)
	 :prompt "Kill Slave: "
	 :help "Enter the name of the eval server you wish to destroy."
	 :must-exist t
	 :default default
	 :default-string default)
      (declare (ignore name))
      (let ((wire (server-info-wire info)))
	(when wire
	  (ext:send-character-out-of-band (wire:wire-fd wire) #\N)
	  (wire:remote wire (ext:quit))
	  (wire:wire-force-output wire)))
      (let ((buffer (server-info-slave-buffer info)))
	(when buffer (delete-buffer-if-possible buffer)))
      (let ((buffer (server-info-background-buffer info)))
	(when buffer (delete-buffer-if-possible buffer)))
      (server-died info))))

(defcommand "Accept Slave Connections" (p)
  "This causes Hemlock to accept slave connections and displays the port of
   the editor's connections request server.  This is suitable for use with the
   Lisp's -slave switch.  Given an argument, this inhibits slave connections."
  "This causes Hemlock to accept slave connections and displays the port of
   the editor's connections request server.  This is suitable for use with the
   Lisp's -slave switch.  Given an argument, this inhibits slave connections."
  (let ((accept (not p)))
    (setf *accept-connections* accept)
    (message "~:[Inhibiting~;Accepting~] connections to ~S"
	     accept (get-editor-name))))



;;;; Slave initialization junk.

(defvar *original-beep-function* nil
  "Handle on original beep function.")

(defvar *original-gc-notify-before* nil
  "Handle on original before-GC notification function.")

(defvar *original-gc-notify-after* nil
  "Handle on original after-GC notification function.")

(defvar *original-terminal-io* nil
  "Handle on original *terminal-io* so we can restore it.")

(defvar *original-standard-input* nil
  "Handle on original *standard-input* so we can restore it.")

(defvar *original-standard-output* nil
  "Handle on original *standard-output* so we can restore it.")

(defvar *original-error-output* nil
  "Handle on original *error-output* so we can restore it.")

(defvar *original-debug-io* nil
  "Handle on original *debug-io* so we can restore it.")

(defvar *original-query-io* nil
  "Handle on original *query-io* so we can restore it.")

(defvar *original-trace-output* nil
  "Handle on original *trace-output* so we can restore it.")

(defvar *background-io* nil
  "Stream connected to the editor's background buffer in case we want to use it
  in the future.")

;;; CONNECT-STREAM -- internal
;;;
;;; Run in the slave to create a new stream and connect it to the supplied
;;; buffer.  Returns the stream.
;;; 
(defun connect-stream (remote-buffer)
  (let ((stream (make-ts-stream wire:*current-wire* remote-buffer)))
    (wire:remote wire:*current-wire*
      (ts-buffer-set-stream remote-buffer
			    (wire:make-remote-object stream)))
    stream))

;;; MADE-BUFFERS-FOR-TYPESCRIPT -- Internal Interface.
;;;
;;; Run in the slave by the editor with the two buffers' info structures,
;;; actually remote-objects in the slave.  Does any necessary stream hacking.
;;; Return nil to make sure no weird objects try to go back over the wire
;;; since the editor calls this in the slave for value.  The editor does this
;;; for synch'ing, not for values.
;;;
(defun made-buffers-for-typescript (slave-info background-info)
  (macrolet ((frob (symbol new-value)
	       `(setf ,(intern (concatenate 'simple-string
					    "*ORIGINAL-"
					    (subseq (string symbol) 1)))
		      ,symbol
		      ,symbol ,new-value)))
    (let ((wire wire:*current-wire*))
      (frob system:*beep-function*
	    #'(lambda (&optional stream)
		(declare (ignore stream))
		(wire:remote-value wire (beep))))
      (frob ext:*gc-notify-before*
	    #'(lambda (bytes-in-use)
		(wire:remote wire
		  (slave-gc-notify-before
		   slave-info
		   (format nil
			   "~%[GC threshold exceeded with ~:D bytes in use.  ~
			   Commencing GC.]~%"
			   bytes-in-use)))
		(wire:wire-force-output wire)))
      (frob ext:*gc-notify-after*
	    #'(lambda (bytes-retained bytes-freed new-trigger)
		(wire:remote wire
		  (slave-gc-notify-after
		   slave-info
		   (format nil
			   "[GC completed with ~:D bytes retained and ~:D ~
			   bytes freed.]~%[GC will next occur when at least ~
			   ~:D bytes are in use.]~%"
			   bytes-retained bytes-freed new-trigger)))
		(wire:wire-force-output wire))))
    (frob *terminal-io* (connect-stream slave-info))
    (frob *standard-input* (make-synonym-stream '*terminal-io*))
    (frob *standard-output* *standard-input*)
    (frob *error-output* *standard-input*)
    (frob *debug-io* *standard-input*)
    (frob *query-io* *standard-input*)
    (frob *trace-output* *standard-input*))
  (setf *background-io* (connect-stream background-info))
  nil)

;;; SLAVE-GC-NOTIFY-BEFORE and SLAVE-GC-NOTIFY-AFTER -- internal
;;;
;;; These two routines are run in the editor by the slave's gc notify routines.
;;; 
(defun slave-gc-notify-before (remote-ts message)
  (let ((ts (wire:remote-object-value remote-ts)))
    (ts-buffer-output-string ts message t)
    (message "~A is GC'ing." (buffer-name (ts-data-buffer ts)))
    (system:beep)))
(defun slave-gc-notify-after (remote-ts message)
  (let ((ts (wire:remote-object-value remote-ts)))
    (ts-buffer-output-string ts message t)
    (message "~A is done GC'ing." (buffer-name (ts-data-buffer ts)))
    (system:beep)))

;;; EDITOR-DIED -- internal
;;;
;;; Run in the slave when the editor goes belly up.
;;; 
(defun editor-died ()
  (macrolet ((frob (symbol)
	       (let ((orig (intern (concatenate 'simple-string
						"*ORIGINAL-"
						(subseq (string symbol) 1)))))
		 `(when ,orig
		    (setf ,symbol ,orig)))))
    (frob system:*beep-function*)
    (frob ext:*gc-notify-before*)
    (frob ext:*gc-notify-after*)
    (frob *terminal-io*)
    (frob *standard-input*)
    (frob *standard-output*)
    (frob *error-output*)
    (frob *debug-io*)
    (frob *query-io*)
    (frob *trace-output*))
  (setf *background-io* nil)
  (format t "~2&Connection to editor died.~%")
  (ext:quit))

;;; START-SLAVE -- internal
;;;
;;; Initiate the process by which a lisp becomes a slave.
;;; 
(defun start-slave (editor)
  (declare (simple-string editor))
  (let ((seperator (position #\: editor :test #'char=)))
    (unless seperator
      (error "Editor name ~S invalid. ~
              Must be of the form \"MachineName:PortNumber\"."
	     editor))
    (let ((machine (subseq editor 0 seperator))
	  (port (parse-integer editor :start (1+ seperator))))
      (format t "Connecting to ~A:~D~%" machine port)
      (connect-to-editor machine port))))

;;; CONNECT-TO-EDITOR -- internal
;;;
;;; Do the actual connect to the editor.
;;; 
(defun connect-to-editor (machine port
			  &optional
			  (slave (find-eval-server-switch "slave-buffer"))
			  (background (find-eval-server-switch
				       "background-buffer")))
  (let ((wire (wire:connect-to-remote-server machine port 'editor-died)))
    (ext:add-oob-handler (wire:wire-fd wire)
			  #\B
			  #'(lambda ()
			      (system:without-hemlock
			       (system:with-interrupts
				(break "Software Interrupt")))))
    (ext:add-oob-handler (wire:wire-fd wire)
			  #\T
			  #'(lambda ()
			      (when lisp::*in-top-level-catcher*
				(throw 'lisp::top-level-catcher nil))))
    (ext:add-oob-handler (wire:wire-fd wire)
			  #\A
			  #'abort)
    (ext:add-oob-handler (wire:wire-fd wire)
			  #\N
			  #'(lambda ()
			      (setf *abort-operations* t)
			      (when *inside-operation*
				(throw 'abort-operation
				       (if debug::*in-the-debugger*
					   :was-in-debugger)))))
    (wire:remote-value wire
      (make-buffers-for-typescript slave background))))


;;;; Eval server evaluation functions.

(defvar *eval-form-stream*
  (make-two-way-stream
   (lisp::make-stream
    :in #'(lambda (&rest junk)
	    (declare (ignore junk))
	    (error "You cannot read when handling an eval_form request.")))
   (make-broadcast-stream)))

;;; SERVER-EVAL-FORM -- Public.
;;;   Evaluates the given form (which is a string to be read from in the given
;;; package) and returns the results as a list.
;;;
(defun server-eval-form (package form)
  (declare (type (or string null) package) (simple-string form))
  (handler-bind
      ((error #'(lambda (condition)
		  (wire:remote wire:*current-wire*
			       (eval-form-error (format nil "~A~&" condition)))
		  (return-from server-eval-form nil))))
    (let ((*package* (if package
			 (lisp::package-or-lose package)
			 *package*))
	  (*terminal-io* *eval-form-stream*))
      (stringify-list (multiple-value-list (eval (read-from-string form)))))))


;;; DO-OPERATION -- Internal.
;;;   Checks to see if we are aborting operations. If not, do the operation
;;; wrapping it with operation-started and operation-completed calls. Also
;;; deals with setting up *terminal-io* and *package*.
;;;
(defmacro do-operation ((note package terminal-io) &body body)
  `(let ((aborted t)
	 (*terminal-io* (if ,terminal-io
			  (wire:remote-object-value ,terminal-io)
			  *terminal-io*))
	 (*package* (maybe-make-package ,package)))
     (unwind-protect
	 (unless *abort-operations*
	   (when (eq :was-in-debugger
		     (catch 'abort-operation
		       (let ((*inside-operation* t))
			 (wire:remote wire:*current-wire*
				      (operation-started ,note))
			 (wire:wire-force-output wire:*current-wire*)
			 ,@body
			 (setf aborted nil))))
	     (format t
		     "~&[Operation aborted.  ~
		      You are no longer in this instance of the debugger.]~%")))
       (wire:remote wire:*current-wire*
	 (operation-completed ,note aborted))
       (wire:wire-force-output wire:*current-wire*))))


;;; unique-thingie is a unique eof-value for READ'ing.  Its a parameter, so
;;; we can reload the file.
;;;
(defparameter unique-thingie (gensym)
  "Used as eof-value in reads to check for the end of a file.")

;;; SERVER-EVAL-TEXT -- Public.
;;;
;;;   Evaluate all the forms read from text in the given package, and send the
;;; results back.  The error handler bound does not handle any errors.  It
;;; simply notifies the client that an error occurred and then returns.
;;;
(defun server-eval-text (note package text terminal-io)
  (do-operation (note package terminal-io)
    (with-input-from-string (stream text)
      (let ((last-pos 0))
	(handler-bind
	    ((error
	      #'(lambda (condition)
		  (wire:remote wire:*current-wire*
			       (lisp-error note last-pos
					   (file-position stream)
					   (format nil "~A~&" condition))))))
	  (loop
	    (let ((form (read stream nil unique-thingie)))
	      (when (eq form unique-thingie)
		(return nil))
	      (let* ((values (stringify-list (multiple-value-list (eval form))))
		     (pos (file-position stream)))
		(wire:remote wire:*current-wire*
		  (eval-text-result note last-pos pos values))
		(setf last-pos pos)))))))))

(defun stringify-list (list)
  (mapcar #'prin1-to-string list))
#|
(defun stringify-list (list)
  (mapcar #'(lambda (thing)
	      (with-output-to-string (stream)
		(write thing
		       :stream stream :radix nil :base 10 :circle t
		       :pretty nil :level nil :length nil :case :upcase
		       :array t :gensym t)))
	  list))
|#


;;;; Eval server compilation stuff.

;;; DO-COMPILER-OPERATION -- Internal.
;;;
;;; Useful macro that does the operation with *compiler-note* and
;;; *compiler-wire* bound.
;;;
(defmacro do-compiler-operation ((note package terminal-io error) &body body)
  `(let ((*compiler-note* ,note)
	 (*compiler-error-stream* ,error)
	 (*compiler-wire* wire:*current-wire*)
	 #-new-compiler
	 (clc:*compiler-notification-function* #'compiler-note-in-editor))
     (do-operation (*compiler-note* ,package ,terminal-io)
		   (unwind-protect
		       (handler-bind ((error #'compiler-error-handler))
			 ,@body)
		     (when *compiler-error-stream*
		       (force-output *compiler-error-stream*))))))

;;; COMPILER-NOTIFICATION -- Internal.
;;;
;;; DO-COMPILER-OPERATION binds clc:*compiler-notification-function to this, so
;;; interesting observations in the compilation can be propagated back to the
;;; editor.  If there is a notification point defined, we send information
;;; about the position and kind of error.  The actual error text is written out
;;; using typescript operations.
;;;
;;; Start and End are the compiler's best guess at the file position where the
;;; error occurred.  Function is the symbolic name of the function in which the
;;; error occurred.  We PRIN1 this to a string because sending the symbol back
;;; to the editor could easily result in the editor trying to fetch a symbol
;;; off the wire into a non-existing package.  We expect packages to exist in
;;; the developing Lisp environment that are missing in the editor's Lisp.
;;;
#-new-compiler
(defun compiler-note-in-editor (severity function)
  (when *compiler-wire*
    (force-output *compiler-error-stream*)
    (multiple-value-bind (start end)
			 (clc:current-form-position)
      (wire:remote *compiler-wire*
	(compiler-error *compiler-note* start end
			(prin1-to-string function)
			severity)))
    (wire:wire-force-output *compiler-wire*)))

;;; COMPILER-ERROR-HANDLER -- Internal.
;;;
;;;    The error handler function for the compiler interfaces.
;;; DO-COMPILER-OPERATION binds this as an error handler while evaluating the
;;; compilation form.
;;;
(defun compiler-error-handler (condition)
  #-new-compiler
  (when *compiler-wire*
    (multiple-value-bind (start end)
			 (clc:current-form-position)
      (wire:remote *compiler-wire*
	(lisp-error *compiler-note* start end
		    (format nil "~A~&" condition))))))




;;; SERVER-COMPILE-TEXT -- Public.
;;;
;;;    Similar to server-eval-text, except that the stuff is compiled.
;;;
(defun server-compile-text (note package text defined-from
			    terminal-io error-output)
  (let ((error-output (if error-output
			(wire:remote-object-value error-output))))
    (do-compiler-operation (note package terminal-io error-output)
      (with-input-from-string (input-stream text)
	(terpri error-output)
	(c::compile-from-stream input-stream
				:error-stream error-output
				:defined-from-pathname defined-from)))))

;;; SERVER-COMPILE-FILE -- Public.
;;;
;;;    Compiles the file sending error info back to the editor.
;;;
(defun server-compile-file (note package input output error lap
			    load terminal background)
  (macrolet ((frob (x)
	       `(if (wire:remote-object-p ,x)
		  (wire:remote-object-value ,x)
		  ,x)))
    (let ((error-stream (frob background)))
      (do-compiler-operation (note package terminal error-stream)
	(compile-file (frob input)
		      :output-file (frob output)
		      :error-file (frob error)
		      :trace-file (frob lap)
		      :load load
		      :error-output error-stream)))))


;;;; Other random eval server stuff.

;;; MAYBE-MAKE-PACKAGE -- Internal.
;;;
;;; Returns a package for a name.  Creates it if it doesn't already exist.
;;;
(defun maybe-make-package (name)
  (cond ((null name) *package*)
	((find-package name))
	(t
	 (wire:remote-value (ts-stream-wire *terminal-io*)
	   (ts-buffer-output-string
	    (ts-stream-typescript *terminal-io*)
	    (format nil "~&Creating package ~A.~%" name)
	    t))
	 (make-package name))))

;;; SERVER-SET-PACKAGE -- Public.
;;;
;;;   Serves package setting requests.  It simply sets
;;; *package* to an already existing package or newly created one.
;;;
(defun server-set-package (package)
  (setf *package* (maybe-make-package package)))

;;; SERVER-ACCEPT-OPERATIONS -- Public.
;;;
;;;   Start accepting operations again.
;;;
(defun server-accept-operations ()
  (setf *abort-operations* nil))



;;;; Command line switches.

;;; FIND-EVAL-SERVER-SWITCH -- Internal.
;;;
;;; This is special to the switches supplied by CREATE-SLAVE and fetched by
;;; CONNECT-EDITOR-SERVER, so we can use STRING=.
;;;
(defun find-eval-server-switch (string)
  (let ((switch (find string ext:*command-line-switches*
		      :test #'string=
		      :key #'ext:cmd-switch-name)))
    (if switch
	(or (ext:cmd-switch-value switch)
	    (car (ext:cmd-switch-words switch))))))


(defun slave-switch-demon (switch)
  (let ((editor (ext:cmd-switch-arg switch)))
    (unless editor
      (error "Editor to connect to unspesified."))
    (start-slave editor)))
;;;
(defswitch "slave" 'slave-switch-demon)
(defswitch "slave-buffer")
(defswitch "background-buffer")


(defun edit-switch-demon (switch)
  (declare (ignore switch))
#|  (let ((arg (or (ext:cmd-switch-value switch)
		 (car (ext:cmd-switch-words switch)))))
    (when (stringp arg) (setq *editor-name* arg)))|#
  (let ((initp (not (ext:get-command-line-switch "noinit"))))
    (if (stringp (car ext:*command-line-words*))
	(ed (car ext:*command-line-words*) :init initp)
	(ed nil :init initp))))
;;;
(defswitch "edit" 'edit-switch-demon)
