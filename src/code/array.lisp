;;; -*- Log: code.log; Package: Lisp -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;;
(ext:file-comment
  "$Header: src/code/array.lisp $")
;;;
;;; **********************************************************************
;;;
;;; Functions to implement arrays for CMU Common Lisp.
;;; Written by Skef Wholey.
;;; Worked over for the MIPS port by William Lott.
;;;
(in-package "LISP")

(intl:textdomain "cmucl")

(export '(array-rank-limit array-dimension-limit array-total-size-limit
	  make-array vector aref array-element-type array-rank
	  array-dimension array-dimensions array-in-bounds-p
	  array-row-major-index array-total-size svref bit sbit
	  bit-and bit-ior bit-xor bit-eqv bit-nand bit-nor bit-andc1 bit-andc2
	  bit-orc1 bit-orc2 bit-not array-has-fill-pointer-p
	  fill-pointer vector-push vector-push-extend vector-pop adjust-array
          adjustable-array-p row-major-aref array-displacement))

(in-package "KERNEL")
(export '(%with-array-data))
(in-package "LISP")

(declaim (inline fill-pointer array-has-fill-pointer-p adjustable-array-p
		 array-displacement))

(defconstant array-rank-limit 65529
  "The exclusive upper bound on the rank of an array.")

(defconstant array-dimension-limit most-positive-fixnum
  "The exclusive upper bound any given dimension of an array.")

(defconstant array-total-size-limit most-positive-fixnum
  "The exclusive upper bound on the total number of elements in an array.")



;;;; Random accessor functions.

;;; These functions are needed by the interpreter, 'cause the compiler inlines
;;; them.

(macrolet ((frob (name)
	     `(progn
		(defun ,name (array)
		  (,name array))
		(defun (setf ,name) (value array)
		  (setf (,name array) value)))))
  (frob %array-fill-pointer)
  (frob %array-fill-pointer-p)
  (frob %array-available-elements)
  (frob %array-data-vector)
  (frob %array-displacement)
  (frob %array-displaced-p))

(defun %array-rank (array)
  (%array-rank array))

(defun %array-dimension (array axis)
  (%array-dimension array axis))

(defun %set-array-dimension (array axis value)
  (%set-array-dimension array axis value))

(defun %check-bound (array bound index)
  (declare (type index bound)
	   (fixnum index))
  (%check-bound array bound index))

;;; %WITH-ARRAY-DATA  --  Interface
;;;
;;;    The guts of the WITH-ARRAY-DATA macro (in sysmacs).  Note that this
;;; function is only called if we have an array header or an error, so it
;;; doesn't have to be too tense.
;;;
(defun %with-array-data (array start end)
  (declare (array array) (type index start) (type (or index null) end)
	   (values (simple-array * (*)) index index index))
  (let* ((size (array-total-size array))
	 (end (cond (end
		     (unless (<= end size)
		       (error (intl:gettext "End ~D is greater than total size ~D.")
			      end size))
		     end)
		    (t size))))
    (when (> start end)
      (error (intl:gettext "Start ~D is greater than end ~D.") start end))
    (do ((data array (%array-data-vector data))
	 (cumulative-offset 0
			    (+ cumulative-offset
			       (%array-displacement data))))
	((not (array-header-p data))
	 (values data
		 (+ cumulative-offset start)
		 (+ cumulative-offset end)
		 cumulative-offset))
      (declare (type index cumulative-offset)))))


;;;; MAKE-ARRAY

(eval-when (:compile-toplevel :execute)

(defmacro pick-type (type &rest specs)
  `(cond ,@(mapcar #'(lambda (spec)
		       `(,(if (eq (car spec) t)
			      t
			      `(subtypep ,type ',(car spec)))
			 ,@(cdr spec)))
		   specs)))

); eval-when


(defun %vector-type-code (type)
  (pick-type type
    (base-char (values #.vm:simple-string-type #.vm:char-bits))
    (bit (values #.vm:simple-bit-vector-type 1))
    ((unsigned-byte 2) (values #.vm:simple-array-unsigned-byte-2-type 2))
    ((unsigned-byte 4) (values #.vm:simple-array-unsigned-byte-4-type 4))
    ((unsigned-byte 8) (values #.vm:simple-array-unsigned-byte-8-type 8))
    ((unsigned-byte 16) (values #.vm:simple-array-unsigned-byte-16-type 16))
    ((unsigned-byte 32) (values #.vm:simple-array-unsigned-byte-32-type 32))
    ((signed-byte 8) (values #.vm:simple-array-signed-byte-8-type 8))
    ((signed-byte 16) (values #.vm:simple-array-signed-byte-16-type 16))
    ((signed-byte 30) (values #.vm:simple-array-signed-byte-30-type 32))
    ((signed-byte 32) (values #.vm:simple-array-signed-byte-32-type 32))
    (single-float (values #.vm:simple-array-single-float-type 32))
    (double-float (values #.vm:simple-array-double-float-type 64))
    #+long-float
    (long-float
     (values #.vm:simple-array-long-float-type #+x86 96 #+sparc 128))
    #+double-double
    (double-double-float
     (values #.vm::simple-array-double-double-float-type 128))
    ((complex single-float)
     (values #.vm:simple-array-complex-single-float-type 64))
    ((complex double-float)
     (values #.vm:simple-array-complex-double-float-type 128))
    #+long-float
    ((complex long-float)
     (values #.vm:simple-array-complex-long-float-type #+x86 192 #+sparc 256))
    #+double-double
    ((complex double-double-float)
     (values #.vm::simple-array-complex-double-double-float-type 256))
    (t (values #.vm:simple-vector-type #.vm:word-bits))))

(defun %complex-vector-type-code (type)
  (pick-type type
    (base-char #.vm:complex-string-type)
    (bit #.vm:complex-bit-vector-type)
    (t #.vm:complex-vector-type)))

(defvar *static-vectors* nil
  "List of weak-pointers to static vectors.  Needed for GCing static vectors")

(defun make-static-vector (length element-type)
  (multiple-value-bind (type bits)
      (lisp::%vector-type-code element-type)
    ;; What types of static arrays do we really want to allow?
    ;; Whatever we choose, we definitely cannot allow arrays with the
    ;; following element types: T, (signed-byte 30)
    (unless (member type
		    '(#.vm:simple-string-type
		      #.vm:simple-array-unsigned-byte-8-type
		      #.vm:simple-array-unsigned-byte-16-type
		      #.vm:simple-array-unsigned-byte-32-type
		      #.vm:simple-array-signed-byte-8-type
		      #.vm:simple-array-signed-byte-16-type
		      #.vm:simple-array-signed-byte-32-type
		      #.vm:simple-array-single-float-type
		      #.vm:simple-array-double-float-type
		      #.vm:simple-array-complex-single-float-type
		      #.vm:simple-array-complex-double-float-type))
      (error (intl:gettext "Cannot make a static array of element type ~S") element-type))
    ;; Malloc space for the vector.  We need enough space for the data
    ;; itself, and then 2 words for the vector header (header word and
    ;; length).  Use calloc to make sure the area is initialized to
    ;; zeros, like normal Lisp arrays are.
    (let* ((data-bytes (ceiling (* length bits) 8))
	   (total-bytes (+ data-bytes (* 2 vm:word-bytes))))
      (sys:without-gcing
       (let ((pointer (alien:alien-funcall (alien:extern-alien "calloc"
							       (function sys::system-area-pointer
									 unix::size-t
									 unix::size-t))
					   total-bytes
					   1)))
	 ;; Malloc should return double-word (8 byte) alignment.
	 (assert (zerop (logand 7 (sys:sap-int pointer))))
	 (when (zerop (sys:sap-int pointer))
	   (error (intl:gettext "Failed to allocate space for static array of length ~S of type ~S")
		  length element-type))

	 ;; Fill in the vector header word and length word.  Set the data
	 ;; portion of the header word (normally 0) to 1 so we know this
	 ;; is a static vector.
	 (setf (sys:sap-ref-32 pointer 0) (+ type (ash 1 vm:type-bits)))
	 (setf (sys:sap-ref-32 pointer vm:word-bytes) (ash length 2))
	 ;; Convert the sap to a lisp object and initialize the array
	 (let ((vector
		(kernel:make-lisp-obj (+ vm:other-pointer-type (sys:sap-int pointer)))))
	   (push (make-weak-pointer vector) *static-vectors*)
	   vector))))))

(defun make-array (dimensions &key
			      (element-type t)
			      (initial-element nil initial-element-p)
			      (initial-contents nil initial-contents-p)
                              adjustable fill-pointer
			      displaced-to displaced-index-offset
		              allocation)
  "Creates an array of the specified Dimensions and properties.  See the
  manual for details.

  :Element-type
      The type of objects that the array can hold 
  :Initial-element
      Each element of the array is initialized to this value, if supplied.
      If not supplied, 0 of the appropriate type is used.
  :Initial-contents
      The contents of the array are initialized to this.
  :Adjustable
      If non-Nil, make an expressly adjustable array.
  :Fill-pointer
      For one-dimensional array, set the fill-pointer to the given value.
      If T, use the actual length of the array.
  :Displaced-to
      Create an array that is displaced to the target array specified
      by :displaced-to.
  :Displaced-index-offset
      Index offset to the displaced array.  That is, index 0 of this array is
      actually index displaced-index-offset of the target displaced array. 
  :Allocation
      How to allocate the array.  If :MALLOC, a static, nonmovable array is
      created.  This array is created by calling malloc."
  (declare (type (member nil :malloc) allocation))
  (let* ((dimensions (if (listp dimensions) dimensions (list dimensions)))
	 (array-rank (length (the list dimensions)))
	 (static-array-p (eq allocation :malloc))
	 (simple (and (null fill-pointer)
		      (not adjustable)
		      (null displaced-to))))
    (declare (fixnum array-rank))
    (when (and displaced-index-offset (null displaced-to))
      (error (intl:gettext "Can't specify :displaced-index-offset without :displaced-to")))
    (when (and adjustable static-array-p)
      (error (intl:gettext "Cannot make an adjustable static array")))
    (when (and displaced-to static-array-p)
      (error (intl:gettext "Cannot make a displaced array static")))
    (if (and simple (= array-rank 1))
	;; It's a (simple-array * (*))
	(multiple-value-bind (type bits)
			     (%vector-type-code element-type)
	  (declare (type (unsigned-byte 8) type)
		   (type (integer 1 256) bits))
	  (let* ((length (car dimensions))
		 (array (if static-array-p
			    (make-static-vector length element-type)
			    (allocate-vector
			     type
			     length
			     (ceiling (* (if (= type vm:simple-string-type)
					     (1+ length)
					     length)
					 bits)
				      vm:word-bits)))))
	    (declare (type index length))
	    (when initial-element-p
	      (fill array initial-element))
	    (when initial-contents-p
	      (when initial-element-p
		(error (intl:gettext "Cannot specify both :initial-element and ~
		:initial-contents")))
	      (unless (= length (length initial-contents))
		(error (intl:gettext "~D elements in the initial-contents, but the ~
		vector length is ~D.")
		       (length initial-contents)
		       length))
	      (replace array initial-contents))
	    array))
	;; It's either a complex array or a multidimensional array.
	(let* ((total-size (reduce #'* dimensions))
	       (data (or displaced-to
			 (data-vector-from-inits
			  dimensions total-size element-type
			  initial-contents initial-contents-p
                          initial-element initial-element-p
			  static-array-p)))
	       (array (make-array-header
		       (cond ((= array-rank 1)
			      (%complex-vector-type-code element-type))
			     (simple vm:simple-array-type)
			     (t vm:complex-array-type))
		       array-rank)))
	  (cond (fill-pointer
		 (unless (= array-rank 1)
		   (error (intl:gettext "Only vectors can have fill pointers.")))
		 (let ((length (car dimensions)))
		   (declare (fixnum length))
		   (setf (%array-fill-pointer array)
		     (cond ((eq fill-pointer t)
			    length)
			   (t
			    (unless (and (fixnump fill-pointer)
					 (>= fill-pointer 0)
					 (<= fill-pointer length))
				    (error (intl:gettext "Invalid fill-pointer ~D")
					   fill-pointer))
			    fill-pointer))))
		 (setf (%array-fill-pointer-p array) t))
		(t
		 (setf (%array-fill-pointer array) total-size)
		 (setf (%array-fill-pointer-p array) nil)))
	  (setf (%array-available-elements array) total-size)
	  (setf (%array-data-vector array) data)
	  (cond (displaced-to
		 (when (or initial-element-p initial-contents-p)
		   (error (intl:gettext "Neither :initial-element nor :initial-contents ~
		   can be specified along with :displaced-to")))
		 ;; The CLHS entry for MAKE-ARRAY says that if the
		 ;; actual array element types are not type equivalent
		 ;; (subtypes of each other), the consequences are
		 ;; undefined.  Let's signal an error here.
		 (unless (and (subtypep (upgraded-array-element-type element-type)
					(array-element-type displaced-to))
			      (subtypep (array-element-type displaced-to)
					(upgraded-array-element-type element-type)))
		   (error (intl:gettext "One can't displace an array of type ~S into ~
                           another of type ~S.")
			  element-type (array-element-type displaced-to)))
		 (let ((offset (or displaced-index-offset 0)))
		   (when (> (+ offset total-size)
			    (array-total-size displaced-to))
		     (error (intl:gettext "~S doesn't have enough elements.") displaced-to))
		   (setf (%array-displacement array) offset)
		   (setf (%array-displaced-p array) t)))
		(t
		 (setf (%array-displaced-p array) nil)))
	  (let ((axis 0))
	    (dolist (dim dimensions)
	      (setf (%array-dimension array axis) dim)
	      (incf axis)))
	  array))))

(defvar *debug-static-array-p* nil
  "If non-NIL, print some debugging information when GC'ing static arrays")

(defun static-array-p (array)
  (with-array-data ((v array) (start) (end))
    (declare (ignore start end))
    (and (typep v '(kernel:simple-unboxed-array (*)))
	 (let ((header (sys:sap-ref-32 (sys:vector-sap v)
				       (- (* 2 vm:word-bytes)))))
	   (logbitp vm:type-bits header)))))

(defun free-static-vector (vector)
  (sys:without-gcing
   (let ((addr (logandc1 vm:lowtag-mask (kernel:get-lisp-obj-address vector))))
     (when *debug-static-array-p*
       (format t (intl:gettext "~&Freeing foreign vector at #x~X~%") addr))
     (alien:alien-funcall
      (alien:extern-alien "free"
			  (function c-call:void
				    sys:system-area-pointer))
      (sys:int-sap addr)))))

(defun finalize-static-vectors ()
  ;; Run down the list of weak-pointers to static vectors.  Look at
  ;; the static vector and see if vector is marked.  If so, clear the
  ;; mark, and do nothing.  If the mark is not set, then the vector is
  ;; free, so free it, and remove this weak-pointer from the list.
  ;; The mark bit the MSB of the header word.  Look at scavenge in
  ;; gencgc.c.
  (when *static-vectors*
    (when *debug-static-array-p*
      (let ((*print-array* nil))
	(format t (intl:gettext "Finalizing static vectors ~S~%") *static-vectors*)))
    (setf *static-vectors*
	  (delete-if
	   #'(lambda (wp)
	       (let ((vector (weak-pointer-value wp)))
		 (when vector
		   (let* ((sap (sys:vector-sap vector))
			  (header (sys:sap-ref-32 sap (* -2 vm:word-bytes))))
		     (when *debug-static-array-p*
		       (format t (intl:gettext "static vector ~A.  header = ~X~%")
			       vector header))
		     (cond ((logbitp 31 header)
			    ;; Clear mark
			    (setf (sys:sap-ref-32 sap (* -2 vm:word-bytes))
				  (logand header #x7fffffff))
			    (when *debug-static-array-p*
			      (let ((*print-array* nil))
				(format t (intl:gettext "  static vector ~A in use~%") vector)))
			    nil)
			   (t
			    ;; Mark was clear so free the vector
			    (when *debug-static-array-p*
			      (let ((*print-array* nil))
				(format t (intl:gettext "  Free static vector ~A~%") vector)))
			    (sys:without-interrupts
			      (setf (weak-pointer-value wp) nil)
			      (free-static-vector vector))
			    t))))))
	   *static-vectors*))))

;; Clean up any unreferenced static vectors after GC has run.
(pushnew 'finalize-static-vectors *after-gc-hooks*)


;;; DATA-VECTOR-FROM-INITS returns a simple vector that has the specified array
;;; characteristics.  Dimensions is only used to pass to FILL-DATA-VECTOR
;;; for error checking on the structure of initial-contents.
;;;
(defun data-vector-from-inits (dimensions total-size element-type
			       initial-contents initial-contents-p
			       initial-element initial-element-p
			       &optional static-array-p)
  (when (and initial-contents-p initial-element-p)
    (error (intl:gettext "Cannot supply both :initial-contents and :initial-element to
            either make-array or adjust-array.")))
  (let ((data (if static-array-p
		  (make-static-vector total-size element-type)
		  (if initial-element-p
		      (make-array total-size
				  :element-type element-type
				  :initial-element initial-element)
		      (make-array total-size
				  :element-type element-type)))))
    (cond (initial-element-p
	   (unless (and (simple-vector-p data) static-array-p)
	     (unless (typep initial-element element-type)
	       (error (intl:gettext "~S cannot be used to initialize an array of type ~S.")
		      initial-element element-type))
	     (fill (the vector data) initial-element)))
	  (initial-contents-p
	   (fill-data-vector data dimensions initial-contents)))
    data))


(defun fill-data-vector (vector dimensions initial-contents)
  (let ((index 0))
    (labels ((frob (axis dims contents)
	       (cond ((null dims)
		      (setf (aref vector index) contents)
		      (incf index))
		     (t
		      (unless (typep contents 'sequence)
			(error (intl:ngettext "Malformed :initial-contents.  ~S is not a ~
			                       sequence, but ~D more layer needed."
					      "Malformed :initial-contents.  ~S is not a ~
			                       sequence, but ~D more layers needed."
					      (- (length dimensions) axis))
			       contents))
		      (unless (= (length contents) (car dims))
			(error (intl:gettext "Malformed :initial-contents.  Dimension of ~
			        axis ~D is ~D, but ~S is ~D long.")
			       axis (car dims) contents (length contents)))
		      (if (listp contents)
			  (dolist (content contents)
			    (frob (1+ axis) (cdr dims) content))
			  (dotimes (i (length contents))
			    (frob (1+ axis) (cdr dims) (aref contents i))))))))
      (frob 0 dimensions initial-contents))))


(defun vector (&rest objects)
  "Constructs a simple-vector from the given objects."
  (coerce (the list objects) 'simple-vector))



;;;; Accessor/Setter functions.

(defun data-vector-ref (array index)
  (with-array-data ((vector array) (index index) (end))
    (declare (ignore end) (optimize (safety 3)))
    (macrolet ((dispatch (&rest stuff)
		 `(etypecase vector
		    ,@(mapcar #'(lambda (type)
				  (let ((atype `(simple-array ,type (*))))
				    `(,atype
				      (data-vector-ref (the ,atype vector)
						       index))))
			      stuff))))
      (dispatch
       t
       bit
       character
       (unsigned-byte 2)
       (unsigned-byte 4)
       (unsigned-byte 8)
       (unsigned-byte 16)
       (unsigned-byte 32)
       (signed-byte 8)
       (signed-byte 16)
       (signed-byte 30)
       (signed-byte 32)
       single-float
       double-float
       #+long-float long-float
       #+double-double double-double-float
       (complex single-float)
       (complex double-float)
       #+long-float (complex long-float)
       #+double-double (complex double-double-float)))))

(defun data-vector-set (array index new-value)
  (with-array-data ((vector array) (index index) (end))
    (declare (ignore end) (optimize (safety 3)))
    (macrolet ((dispatch (&rest stuff)
		 `(etypecase vector
		    ,@(mapcar #'(lambda (type)
				  (let ((atype `(simple-array ,type (*))))
				    `(,atype
				      (data-vector-set (the ,atype vector)
						       index
						       (the ,type new-value))
				      new-value)))
			      stuff))))
      (dispatch
       t
       bit
       character
       (unsigned-byte 2)
       (unsigned-byte 4)
       (unsigned-byte 8)
       (unsigned-byte 16)
       (unsigned-byte 32)
       (signed-byte 8)
       (signed-byte 16)
       (signed-byte 30)
       (signed-byte 32)
       single-float
       double-float
       #+long-float long-float
       #+double-double double-double-float
       (complex single-float)
       (complex double-float)
       #+long-float (complex long-float)
       #+double-double (complex double-double-float)))))



(defun %array-row-major-index (array subscripts
				     &optional (invalid-index-error-p t))
  (declare (array array)
	   (list subscripts))
  (let ((rank (array-rank array)))
    (unless (= rank (length subscripts))
      (simple-program-error (intl:gettext "Wrong number of subscripts, ~D, for array of rank ~D")
	     (length subscripts) rank))
    (if (array-header-p array)
	(do ((subs (nreverse subscripts) (cdr subs))
	     (axis (1- (array-rank array)) (1- axis))
	     (chunk-size 1)
	     (result 0))
	    ((null subs) result)
	  (declare (list subs) (fixnum axis chunk-size result))
	  (let ((index (car subs))
		(dim (%array-dimension array axis)))
	    (declare (fixnum index dim))
	    (unless (< -1 index dim)
	      (if invalid-index-error-p
		  (error (intl:gettext "Invalid index ~D~[~;~:; on axis ~:*~D~] in ~S")
			 index axis array)
		  (return-from %array-row-major-index nil)))
	    (incf result (* chunk-size index))
	    (setf chunk-size (* chunk-size dim))))
	(let ((index (first subscripts)))
	  (unless (< -1 index (length (the (simple-array * (*)) array)))
	    (if invalid-index-error-p
		(error (intl:gettext "Invalid index ~D in ~S") index array)
		(return-from %array-row-major-index nil)))
	  index))))

(defun array-in-bounds-p (array &rest subscripts)
  "Returns T if the Subscipts are in bounds for the Array, Nil otherwise."
  (if (%array-row-major-index array subscripts nil)
      t))

(defun array-row-major-index (array &rest subscripts)
  (%array-row-major-index array subscripts))

(defun aref (array &rest subscripts)
  "Returns the element of the Array specified by the Subscripts."
  (row-major-aref array (%array-row-major-index array subscripts)))

(defun %aset (array &rest stuff)
  (let ((subscripts (butlast stuff))
	(new-value (car (last stuff))))
    (setf (row-major-aref array (%array-row-major-index array subscripts))
	  new-value)))

(declaim (inline (setf aref)))
(defun (setf aref) (new-value array &rest subscripts)
  (declare (type array array))
  (setf (row-major-aref array (%array-row-major-index array subscripts))
	new-value))

(defun row-major-aref (array index)
  "Returns the element of array corressponding to the row-major index.  This is
   SETF'able."
  (declare (optimize (safety 1)))
  (row-major-aref array index))


(defun %set-row-major-aref (array index new-value)
  (declare (optimize (safety 1)))
  (setf (row-major-aref array index) new-value))

(defun svref (simple-vector index)
  "Returns the Index'th element of the given Simple-Vector."
  (declare (optimize (safety 1)))
  (aref simple-vector index))

(defun %svset (simple-vector index new)
  (declare (optimize (safety 1)))
  (setf (aref simple-vector index) new))


(defun bit (bit-array &rest subscripts)
  "Returns the bit from the Bit-Array at the specified Subscripts."
  (declare (type (array bit) bit-array) (optimize (safety 1)))
  (row-major-aref bit-array (%array-row-major-index bit-array subscripts)))


(defun %bitset (bit-array &rest stuff)
  (declare (type (array bit) bit-array) (optimize (safety 1)))
  (let ((subscripts (butlast stuff))
	(new-value (car (last stuff))))
    (setf (row-major-aref bit-array
			  (%array-row-major-index bit-array subscripts))
	  new-value)))

(declaim (inline (setf bit)))
(defun (setf bit) (new-value bit-array &rest subscripts)
  (declare (type (array bit) bit-array) (optimize (safety 1)))
  (setf (row-major-aref bit-array
			(%array-row-major-index bit-array subscripts))
	new-value))

(defun sbit (simple-bit-array &rest subscripts)
  "Returns the bit from the Simple-Bit-Array at the specified Subscripts."
  (declare (type (simple-array bit) simple-bit-array) (optimize (safety 1)))
  (row-major-aref simple-bit-array
		  (%array-row-major-index simple-bit-array subscripts)))

(defun %sbitset (simple-bit-array &rest stuff)
  (declare (type (simple-array bit) simple-bit-array) (optimize (safety 1)))
  (let ((subscripts (butlast stuff))
	(new-value (car (last stuff))))
    (setf (row-major-aref simple-bit-array
			  (%array-row-major-index simple-bit-array subscripts))
	  new-value)))
 
(declaim (inline (setf sbit)))
(defun (setf sbit) (new-value bit-array &rest subscripts)
  (declare (type (simple-array bit) bit-array) (optimize (safety 1)))
  (setf (row-major-aref bit-array
			(%array-row-major-index bit-array subscripts))
	new-value))


;;;; Random array properties.

(defun array-element-type (array)
  "Returns the type of the elements of the array"
  (let ((type (get-type array)))
    (macrolet ((pick-element-type (&rest stuff)
		 `(cond ,@(mapcar #'(lambda (stuff)
				      (cons
				       (let ((item (car stuff)))
					 (cond ((eq item t)
						t)
					       ((listp item)
						(cons 'or
						      (mapcar #'(lambda (x)
								  `(= type ,x))
							      item)))
					       (t
						`(= type ,item))))
				       (cdr stuff)))
						   stuff))))
      (pick-element-type
       ((vm:simple-string-type vm:complex-string-type) 'base-char)
       ((vm:simple-bit-vector-type vm:complex-bit-vector-type) 'bit)
       (vm:simple-vector-type t)
       (vm:simple-array-unsigned-byte-2-type '(unsigned-byte 2))
       (vm:simple-array-unsigned-byte-4-type '(unsigned-byte 4))
       (vm:simple-array-unsigned-byte-8-type '(unsigned-byte 8))
       (vm:simple-array-unsigned-byte-16-type '(unsigned-byte 16))
       (vm:simple-array-unsigned-byte-32-type '(unsigned-byte 32))
       (vm:simple-array-signed-byte-8-type '(signed-byte 8))
       (vm:simple-array-signed-byte-16-type '(signed-byte 16))
       (vm:simple-array-signed-byte-30-type '(signed-byte 30))
       (vm:simple-array-signed-byte-32-type '(signed-byte 32))
       (vm:simple-array-single-float-type 'single-float)
       (vm:simple-array-double-float-type 'double-float)
       #+long-float
       (vm:simple-array-long-float-type 'long-float)
       #+double-double
       (vm::simple-array-double-double-float-type 'double-double-float)
       (vm:simple-array-complex-single-float-type '(complex single-float))
       (vm:simple-array-complex-double-float-type '(complex double-float))
       #+long-float
       (vm:simple-array-complex-long-float-type '(complex long-float))
       #+double-double
       (vm::simple-array-complex-double-double-float-type '(complex double-double-float))
       ((vm:simple-array-type vm:complex-vector-type vm:complex-array-type)
	(with-array-data ((array array) (start) (end))
	  (declare (ignore start end))
	  (array-element-type array)))
       (t
        (error 'type-error :datum array :expected-type 'array))))))


(defun array-rank (array)
  "Returns the number of dimensions of the Array."
  (if (array-header-p array)
      (%array-rank array)
      1))

(defun array-dimension (array axis-number)
  "Returns length of dimension Axis-Number of the Array."
  (declare (array array) (type index axis-number))
  (cond ((not (array-header-p array))
	 (unless (= axis-number 0)
	   (simple-program-error (intl:gettext "Vector axis is not zero: ~S") axis-number))
	 (length (the (simple-array * (*)) array)))
	((>= axis-number (%array-rank array))
	 (simple-program-error (intl:ngettext "~D is too big; ~S only has ~D dimension"
					      "~D is too big; ~S only has ~D dimensions"
					      (%array-rank array))
			       axis-number array))
	(t
	 (%array-dimension array axis-number))))

(defun array-dimensions (array)
  "Returns a list whose elements are the dimensions of the array"
  (declare (array array))
  (if (array-header-p array)
      (do ((results nil (cons (array-dimension array index) results))
	   (index (1- (array-rank array)) (1- index)))
	  ((minusp index) results))
      (list (array-dimension array 0))))

(defun array-total-size (array)
  "Returns the total number of elements in the Array."
  (declare (array array))
  (if (array-header-p array)
      (%array-available-elements array)
      (length (the vector array))))

(defun array-displacement (array)
  "Returns values of :displaced-to and :displaced-index-offset options to
   make-array, or the defaults nil and 0 if not a displaced array."
  (declare (array array))
  (if (and (array-header-p array) (%array-displaced-p array))
      (values (%array-data-vector array)
            (truly-the fixnum (%array-displacement array)))
      (values nil 0)))

(defun adjustable-array-p (array)
  "Returns T if (adjust-array array...) would return an array identical
   to the argument, this happens for complex arrays."
  (declare (array array))
  (not (typep array 'simple-array)))


;;;; Fill pointer frobbing stuff.

(defun array-has-fill-pointer-p (array)
  "Returns T if the given Array has a fill pointer, or Nil otherwise."
  (declare (array array))
  (and (array-header-p array) (%array-fill-pointer-p array)))

(defun fill-pointer (vector)
  "Returns the Fill-Pointer of the given Vector."
  (declare (vector vector))
  (if (and (array-header-p vector) (%array-fill-pointer-p vector))
      (%array-fill-pointer vector)
      (error 'simple-type-error
	     :datum vector
	     :expected-type '(and vector (satisfies array-has-fill-pointer-p))
	     :format-control
	     (intl:gettext "~S is not an array with a fill-pointer.")
	     :format-arguments (list vector))))

(defun %set-fill-pointer (vector new)
  (declare (vector vector) (fixnum new))
  (if (and (array-header-p vector) (%array-fill-pointer-p vector))
      (if (> new (%array-available-elements vector))
	(simple-program-error
         (intl:gettext "New fill pointer, ~S, is larger than the length of the vector.")
         new)
	(setf (%array-fill-pointer vector) new))
      (error 'simple-type-error
	     :datum vector
	     :expected-type '(and vector (satisfies array-has-fill-pointer-p))
	     :format-control (intl:gettext "~S is not an array with a fill-pointer.")
	     :format-arguments (list vector))))

(defun vector-push (new-el array)
  "Attempts to set the element of Array designated by the fill pointer
   to New-El and increment fill pointer by one.  If the fill pointer is
   too large, Nil is returned, otherwise the index of the pushed element is 
   returned."
  (declare (vector array))
  (let ((fill-pointer (fill-pointer array)))
    (declare (fixnum fill-pointer))
    (cond ((= fill-pointer (%array-available-elements array))
	   nil)
	  (t
	   (setf (aref array fill-pointer) new-el)
	   (setf (%array-fill-pointer array) (1+ fill-pointer))
	   fill-pointer))))

(defun vector-push-extend (new-el array &optional
				  (extension (if (zerop (length array))
						 1
						 (length array))))
  "Like Vector-Push except that if the fill pointer gets too large, the
   Array is extended rather than Nil being returned."
  (declare (vector array) (fixnum extension))
  (let ((fill-pointer (fill-pointer array)))
    (declare (fixnum fill-pointer))
    (when (= fill-pointer (%array-available-elements array))
      (setf array (adjust-array array (+ fill-pointer extension))))
    (setf (aref array fill-pointer) new-el)
    (setf (%array-fill-pointer array) (1+ fill-pointer))
    fill-pointer))

(defun vector-pop (array)
  "Attempts to decrease the fill-pointer by 1 and return the element
   pointer to by the new fill pointer.  If the original value of the fill
   pointer is 0, an error occurs."
  (declare (vector array))
  (let ((fill-pointer (fill-pointer array)))
    (declare (fixnum fill-pointer))
    (if (zerop fill-pointer)
	(simple-program-error (intl:gettext "Nothing left to pop."))
	(aref array
	      (setf (%array-fill-pointer array)
		    (1- fill-pointer))))))


;;;; Adjust-array

(defun adjust-array (array dimensions &key
			   (element-type (array-element-type array))
			   (initial-element nil initial-element-p)
			   (initial-contents nil initial-contents-p)
                           fill-pointer
			   displaced-to displaced-index-offset)
  "Adjusts the Array's dimensions to the given Dimensions and stuff."
  (let ((dimensions (if (listp dimensions) dimensions (list dimensions))))
    (cond ((/= (the fixnum (length (the list dimensions)))
	       (the fixnum (array-rank array)))
	   (simple-program-error (intl:gettext "Number of dimensions not equal to rank of array.")))
	  ((not (subtypep element-type (array-element-type array)))
	   (simple-program-error (intl:gettext "New element type, ~S, is incompatible with old.")
				 element-type))
	  ((static-array-p array)
	   (simple-program-error (intl:gettext "Static arrays are not adjustable."))))
    (let ((array-rank (length (the list dimensions))))
      (declare (fixnum array-rank))
      (when (and fill-pointer (> array-rank 1))
	(simple-program-error (intl:gettext "Multidimensional arrays can't have fill pointers.")))
      (cond (initial-contents-p
	     ;; Array former contents replaced by initial-contents.
	     (if (or initial-element-p displaced-to)
		 (simple-program-error (intl:gettext "Initial contents may not be specified with ~
		 the :initial-element or :displaced-to option.")))
	     (let* ((array-size (apply #'* dimensions))
		    (array-data (data-vector-from-inits
				 dimensions array-size element-type
				 initial-contents initial-contents-p
                                 initial-element initial-element-p)))
	       (if (adjustable-array-p array)
		   (set-array-header array array-data array-size
				 (get-new-fill-pointer array array-size
						       fill-pointer)
				 0 dimensions nil)
		   (if (array-header-p array)
		       ;; Simple multidimensional or single dimensional array.
		       (make-array dimensions
				   :element-type element-type
				   :initial-contents initial-contents)
		       array-data))))
	    (displaced-to
	     ;; No initial-contents supplied is already established.
	     (when initial-element
	       (simple-program-error (intl:gettext "The :initial-element option may not be specified ~
	       with :displaced-to.")))
	     (unless (subtypep element-type (array-element-type displaced-to))
	       (simple-program-error (intl:gettext "One can't displace an array of type ~S into another of ~
	               type ~S.")
		      element-type (array-element-type displaced-to)))
	     (let ((displacement (or displaced-index-offset 0))
		   (array-size (apply #'* dimensions)))
	       (declare (fixnum displacement array-size))
	       (if (< (the fixnum (array-total-size displaced-to))
		      (the fixnum (+ displacement array-size)))
		   (simple-program-error (intl:gettext "The :displaced-to array is too small.")))
	       (if (adjustable-array-p array)
		   ;; None of the original contents appear in adjusted array.
		   (set-array-header array displaced-to array-size
				     (get-new-fill-pointer array array-size
							   fill-pointer)
				     displacement dimensions t)
		   ;; Simple multidimensional or single dimensional array.
		   (make-array dimensions
			       :element-type element-type
			       :displaced-to displaced-to
			       :displaced-index-offset
			       displaced-index-offset))))
	    ((= array-rank 1)
	     (let ((old-length (array-total-size array))
		   (new-length (car dimensions))
		   new-data)
	       (declare (fixnum old-length new-length))
	       (with-array-data ((old-data array) (old-start)
				 (old-end old-length))
		 (cond
		   ((and (adjustable-array-p array)
			 (not (%array-displaced-p array))
			 (<= new-length old-length))
		    ;; Shrink underlying vector in-place.  We don't do this
		    ;; for non-adjustable arrays, since that might confuse
		    ;; user expectations about adjust-array consing a fresh
		    ;; array in that case.
		    (setf new-data (shrink-vector old-data new-length)))
		   (t
		    (setf new-data
			  (data-vector-from-inits
			   dimensions new-length element-type
			   initial-contents initial-contents-p
			   initial-element initial-element-p))
		    (replace new-data old-data
			     :start2 old-start :end2 old-end)))
		 (if (adjustable-array-p array)
		     (set-array-header array new-data new-length
				       (get-new-fill-pointer array new-length
							     fill-pointer)
				       0 dimensions nil)
		     new-data))))
	    (t
	     (let ((old-length (%array-available-elements array))
		   (new-length (apply #'* dimensions)))
               (declare (fixnum old-length new-length))
               (cond ((null dimensions)
                      array)
                     (t
                      (with-array-data ((old-data array) (old-start)
                                        (old-end old-length))
                        (declare (ignore old-end))
                        (let ((new-data (if (or (%array-displaced-p array)
                                                (> new-length old-length))
                                            (data-vector-from-inits
                                             dimensions new-length
                                             element-type () nil
                                             initial-element initial-element-p)
                                            old-data)))
                          (if (or (zerop old-length) (zerop new-length))
                              (when initial-element-p (fill new-data initial-element))
                              (zap-array-data old-data (array-dimensions array)
                                              old-start
                                              new-data dimensions new-length
                                              element-type initial-element
                                              initial-element-p))
                          (if (adjustable-array-p array)
                              (set-array-header array new-data new-length
                                                new-length 0 dimensions nil)
                              (let ((new-array
                                     (make-array-header vm:simple-array-type array-rank)))
                                (set-array-header new-array new-data new-length
                                                  new-length 0 dimensions nil)))))))))))))

(defun get-new-fill-pointer (old-array new-array-size fill-pointer)
  (cond ((not fill-pointer)
	 (when (array-has-fill-pointer-p old-array)
	   (when (> (%array-fill-pointer old-array) new-array-size)
	     (simple-program-error
                    (intl:gettext "Cannot adjust-array an array (~S) to a size (~S) that is ~
	            smaller than it's fill pointer (~S).")
		    old-array new-array-size (fill-pointer old-array)))
	   (%array-fill-pointer old-array)))
	((not (array-has-fill-pointer-p old-array))
	 (simple-program-error
          (intl:gettext "Cannot supply a non-NIL value (~S) for :fill-pointer ~
	   in adjust-array unless the array (~S) was originally ~
 	   created with a fill pointer.")
          fill-pointer
          old-array))
	((numberp fill-pointer)
	 (when (> fill-pointer new-array-size)
	   (simple-program-error
            (intl:gettext "Cannot supply a value for :fill-pointer (~S) that is larger ~
	     than the new length of the vector (~S).")
            fill-pointer new-array-size))
	 fill-pointer)
	((eq fill-pointer t)
	 new-array-size)
	(t
	 (simple-program-error (intl:gettext "Bogus value for :fill-pointer in adjust-array: ~S")
                               fill-pointer))))

(defun shrink-vector (vector new-size)
  "Destructively alters the Vector, changing its length to New-Size, which
   must be less than or equal to its current size."
  (declare (vector vector))
  (unless (array-header-p vector)
    (macrolet ((frob (name &rest things)
		 `(etypecase ,name
		    ,@(mapcar #'(lambda (thing)
				  `(,(car thing)
				    (fill (truly-the ,(car thing) ,name)
					  ,(cadr thing)
					  :start new-size)))
			      things))))
      (frob vector
	(simple-vector 0)
	(simple-base-string (code-char 0))
	(simple-bit-vector 0)
	((simple-array (unsigned-byte 2) (*)) 0)
	((simple-array (unsigned-byte 4) (*)) 0)
	((simple-array (unsigned-byte 8) (*)) 0)
	((simple-array (unsigned-byte 16) (*)) 0)
	((simple-array (unsigned-byte 32) (*)) 0)
	((simple-array (signed-byte 8) (*)) 0)
	((simple-array (signed-byte 16) (*)) 0)
	((simple-array (signed-byte 30) (*)) 0)
	((simple-array (signed-byte 32) (*)) 0)
	((simple-array single-float (*)) (coerce 0 'single-float))
	((simple-array double-float (*)) (coerce 0 'double-float))
	#+long-float
	((simple-array long-float (*)) (coerce 0 'long-float))
	#+double-double
	((simple-array double-double-float (*))
	 (coerce 0 'double-double-float))
	((simple-array (complex single-float) (*))
	 (coerce 0 '(complex single-float)))
	((simple-array (complex double-float) (*))
	 (coerce 0 '(complex double-float)))
	#+long-float
	((simple-array (complex long-float) (*))
	 (coerce 0 '(complex long-float)))
	#+double-double
	((simple-array (complex double-double-float) (*))
	 (coerce 0 '(complex double-double-float))))))
  ;; Only arrays have fill-pointers, but vectors have their length parameter
  ;; in the same place.
  (setf (%array-fill-pointer vector) new-size)
  vector)

(defun set-array-header (array data length fill-pointer displacement dimensions
			 &optional displacedp)
  "Fills in array header with provided information.  Returns array."
  (setf (%array-data-vector array) data)
  (setf (%array-available-elements array) length)
  (cond (fill-pointer
	 (setf (%array-fill-pointer array) fill-pointer)
	 (setf (%array-fill-pointer-p array) t))
	(t
	 (setf (%array-fill-pointer array) length)
	 (setf (%array-fill-pointer-p array) nil)))
  (setf (%array-displacement array) displacement)
  (if (listp dimensions)
      (dotimes (axis (array-rank array))
	(declare (type index axis))
	(setf (%array-dimension array axis) (pop dimensions)))
      (setf (%array-dimension array 0) dimensions))
  (setf (%array-displaced-p array) displacedp)
  array)



;;;; ZAP-ARRAY-DATA for ADJUST-ARRAY.

;;; Make a temporary to be used when old-data and new-data are EQ.
;;;
(defvar *zap-array-data-temp* (make-array 1000 :initial-element t))

(defun zap-array-data-temp (length element-type initial-element
			    initial-element-p)
  (declare (fixnum length))
  (when (> length (the fixnum (length *zap-array-data-temp*)))
    (setf *zap-array-data-temp*
	  (make-array length :initial-element t)))
  (when initial-element-p
    (unless (typep initial-element element-type)
      (simple-program-error (intl:gettext "~S cannot be used to initialize an array of type ~S.")
	     initial-element element-type))
    (fill (the simple-vector *zap-array-data-temp*) initial-element
	  :end length))
  *zap-array-data-temp*)


;;; ZAP-ARRAY-DATA  --  Internal.
;;;
;;; This does the grinding work for ADJUST-ARRAY.  It zaps the data from the
;;; Old-Data in an arrangement specified by the Old-Dims to the New-Data in an
;;; arrangement specified by the New-Dims.  Offset is a displaced offset to be
;;; added to computed indexes of Old-Data.  New-Length, Element-Type,
;;; Initial-Element, and Initial-Element-P are used when Old-Data and New-Data
;;; are EQ; in this case, a temporary must be used and filled appropriately.
;;; When Old-Data and New-Data are not EQ, New-Data has already been filled
;;; with any specified initial-element.
;;;
(defun zap-array-data (old-data old-dims offset new-data new-dims new-length
		       element-type initial-element initial-element-p)
  (declare (list old-dims new-dims))
  (setq old-dims (nreverse old-dims))
  (setq new-dims (reverse new-dims))
  (if (eq old-data new-data)
      (let ((temp (zap-array-data-temp new-length element-type
				       initial-element initial-element-p)))
	(zap-array-data-aux old-data old-dims offset temp new-dims)
	(dotimes (i new-length) (setf (aref new-data i) (aref temp i))))
      (zap-array-data-aux old-data old-dims offset new-data new-dims)))
      
(defun zap-array-data-aux (old-data old-dims offset new-data new-dims)
  (declare (fixnum offset))
  (let ((limits (mapcar #'(lambda (x y)
			    (declare (fixnum x y))
			    (1- (the fixnum (min x y))))
			old-dims new-dims)))
    (macrolet ((bump-index-list (index limits)
		 `(do ((subscripts ,index (cdr subscripts))
		       (limits ,limits (cdr limits)))
		      ((null subscripts) nil)
		    (cond ((< (the fixnum (car subscripts))
			      (the fixnum (car limits)))
			   (rplaca subscripts
				   (1+ (the fixnum (car subscripts))))
			   (return ,index))
			  (t (rplaca subscripts 0))))))
      (do ((index (make-list (length old-dims) :initial-element 0)
		  (bump-index-list index limits)))
	  ((null index))
	(setf (aref new-data (row-major-index-from-dims index new-dims))
	      (aref old-data
		    (+ (the fixnum (row-major-index-from-dims index old-dims))
		       offset)))))))

;;; ROW-MAJOR-INDEX-FROM-DIMS  --  Internal.
;;;
;;; This figures out the row-major-order index of an array reference from a
;;; list of subscripts and a list of dimensions.  This is for internal calls
;;; only, and the subscripts and dim-list variables are assumed to be reversed
;;; from what the user supplied.
;;;
(defun row-major-index-from-dims (rev-subscripts rev-dim-list)
  (do ((rev-subscripts rev-subscripts (cdr rev-subscripts))
       (rev-dim-list rev-dim-list (cdr rev-dim-list))
       (chunk-size 1)
       (result 0))
      ((null rev-dim-list) result)
    (declare (fixnum chunk-size result))
    (setq result (+ result
		    (the fixnum (* (the fixnum (car rev-subscripts))
				   chunk-size))))
    (setq chunk-size (* chunk-size (the fixnum (car rev-dim-list))))))



;;;; Some bit stuff.
 
(defun bit-array-same-dimensions-p (array1 array2)
  (declare (type (array bit) array1 array2))
  (and (= (array-rank array1)
	  (array-rank array2))
       (dotimes (index (array-rank array1) t)
	 (when (/= (array-dimension array1 index)
		   (array-dimension array2 index))
	   (return nil)))))

(defun pick-result-array (result-bit-array bit-array-1)
  (case result-bit-array
    ((t) bit-array-1)
    ((nil) (make-array (array-dimensions bit-array-1)
		       :element-type 'bit
		       :initial-element 0))
    (t
     (unless (bit-array-same-dimensions-p bit-array-1
					  result-bit-array)
       (simple-program-error (intl:gettext "~S and ~S do not have the same dimensions.")
	      bit-array-1 result-bit-array))
     result-bit-array)))

(defmacro def-bit-array-op (name function)
  (let ((docstring (format nil
			   "Perform a bit-wise ~A on the elements of BIT-ARRAY-1 and ~
			    BIT-ARRAY-2,~%  putting the results in RESULT-BIT-ARRAY.  ~
			    If RESULT-BIT-ARRAY is T,~%  BIT-ARRAY-1 is used.  If ~
			    RESULT-BIT-ARRAY is NIL or omitted, a new array is~%  created.  ~
			    All the arrays must have the same rank and dimensions."
			   (symbol-name function))))
    (intl::note-translatable intl::*default-domain* docstring)
    `(defun ,name (bit-array-1 bit-array-2 &optional result-bit-array)
       ,docstring
       (declare (type (array bit) bit-array-1 bit-array-2)
		(type (or (array bit) (member t nil)) result-bit-array))
       (unless (bit-array-same-dimensions-p bit-array-1 bit-array-2)
	 (simple-program-error (intl:gettext "~S and ~S do not have the same dimensions.")
			       bit-array-1 bit-array-2))
       (let ((result-bit-array (pick-result-array result-bit-array bit-array-1)))
	 (if (and (simple-bit-vector-p bit-array-1)
		  (simple-bit-vector-p bit-array-2)
		  (simple-bit-vector-p result-bit-array))
	     (locally (declare (optimize (speed 3) (safety 0)))
	       (,name bit-array-1 bit-array-2 result-bit-array))
	     (with-array-data ((data1 bit-array-1) (start1) (end1))
	       (declare (ignore end1))
	       (with-array-data ((data2 bit-array-2) (start2) (end2))
		 (declare (ignore end2))
		 (with-array-data ((data3 result-bit-array) (start3) (end3))
		   (do ((index-1 start1 (1+ index-1))
			(index-2 start2 (1+ index-2))
			(index-3 start3 (1+ index-3)))
		       ((>= index-3 end3) result-bit-array)
		     (declare (type index index-1 index-2 index-3))
		     (setf (sbit data3 index-3)
			   (logand (,function (sbit data1 index-1)
					      (sbit data2 index-2))
				   1)))))))))))

(def-bit-array-op bit-and logand)
(def-bit-array-op bit-ior logior)
(def-bit-array-op bit-xor logxor)
(def-bit-array-op bit-eqv logeqv)
(def-bit-array-op bit-nand lognand)
(def-bit-array-op bit-nor lognor)
(def-bit-array-op bit-andc1 logandc1)
(def-bit-array-op bit-andc2 logandc2)
(def-bit-array-op bit-orc1 logorc1)
(def-bit-array-op bit-orc2 logorc2)

(defun bit-not (bit-array &optional result-bit-array)
  "Performs a bit-wise logical NOT on the elements of BIT-ARRAY,
  putting the results in RESULT-BIT-ARRAY.  If RESULT-BIT-ARRAY is T,
  BIT-ARRAY is used.  If RESULT-BIT-ARRAY is NIL or omitted, a new array is
  created.  Both arrays must have the same rank and dimensions."
  (declare (type (array bit) bit-array)
	   (type (or (array bit) (member t nil)) result-bit-array))
  (let ((result-bit-array (pick-result-array result-bit-array bit-array)))
    (if (and (simple-bit-vector-p bit-array)
	     (simple-bit-vector-p result-bit-array))
	(locally (declare (optimize (speed 3) (safety 0)))
	  (bit-not bit-array result-bit-array))
	(with-array-data ((src bit-array) (src-start) (src-end))
	  (declare (ignore src-end))
	  (with-array-data ((dst result-bit-array) (dst-start) (dst-end))
	    (do ((src-index src-start (1+ src-index))
		 (dst-index dst-start (1+ dst-index)))
		((>= dst-index dst-end) result-bit-array)
	      (declare (type index src-index dst-index))
	      (setf (sbit dst dst-index)
		    (logxor (sbit src src-index) 1))))))))
