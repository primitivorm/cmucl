;;;; -*- Mode: Lisp ; Package: User -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;;
(ext:file-comment
  "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/motif/lisp/initial.lisp,v 1.3.2.2 2002/03/23 18:51:11 pw Exp $")
;;;
;;; **********************************************************************
;;;
;;; Written by Michael Garland
;;;
;;; This file is the initial startup code for the Motif Toolkit
;;;

(in-package  "USER")



(require :clx)

;;;; Set up Lisp for the loading of the Motif toolkit

(defpackage "TOOLKIT-INTERNALS"
  (:nicknames "XTI")
  (:use "COMMON-LISP" "EXTENSIONS" "ALIEN" "C-CALL")
  (:export "*MOTIF-CONNECTION*" "*X-DISPLAY*" "MOTIF-CONNECTION"
	   "MAKE-MOTIF-CONNECTION" "MOTIF-CONNECTION-FD"
	   "MOTIF-CONNECTION-DISPLAY-NAME" "MOTIF-CONNECTION-DISPLAY"
	   "MOTIF-CONNECTION-SERIAL" "MOTIF-CONNECTION-WIDGET-TABLE"
	   "MOTIF-CONNECTION-FUNCTION-TABLE"
	   "MOTIF-CONNECTION-CALLBACK-TABLE" "MOTIF-CONNECTION-CLOSE-HOOK"
	   "MOTIF-CONNECTION-PROTOCOL-TABLE" "MOTIF-CONNECTION-TERMINATED"
	   "MOTIF-CONNECTION-EVENT-TABLE" "TOOLKIT-ERROR"
	   "TOOLKIT-CERROR" "TOOLKIT-EOF-ERROR" "CONNECT-TO-HOST"
	   "WAIT-FOR-INPUT" "WAIT-FOR-INPUT-OR-TIMEOUT" "WIDGET"
	   "MAKE-WIDGET" "WIDGET-ID" "WIDGET-TYPE" "WIDGET-PARENT"
	   "WIDGET-CHILDREN" "WIDGET-CALLBACKS" "WIDGET-PROTOCOLS"
	   "WIDGET-EVENTS" "WIDGET-USER-DATA" "MOTIF-OBJECT" "FONT-LIST"
	   "XMSTRING" "TRANSLATIONS" "ACCELERATORS" "SYMBOL-RESOURCE"
	   "SYMBOL-CLASS" "SYMBOL-ATOM" "WIDGET-ADD-CHILD" "CREATE-MESSAGE"
	   "DESTROY-MESSAGE" "TRANSMIT-MESSAGE" "RECEIVE-MESSAGE"
	   "CREATE-NEXT-MESSAGE" "PREPARE-REQUEST" "*TYPE-TABLE*"
	   "*ENUM-TABLE*" "TOOLKIT-READ-VALUE" "TOOLKIT-WRITE-VALUE"
	   "TOOLKIT-EVENT" "EVENT-HANDLE" "EVENT-SERIAL" "EVENT-SEND-EVENT"
	   "EVENT-WINDOW" "EVENT-TYPE" "BUTTON-EVENT-ROOT"
	   "BUTTON-EVENT-SUBWINDOW" "BUTTON-EVENT-TIME" "BUTTON-EVENT-X"
	   "BUTTON-EVENT-Y" "BUTTON-EVENT-X-ROOT" "BUTTON-EVENT-Y-ROOT"
	   "BUTTON-EVENT-STATE" "BUTTON-EVENT-SAME-SCREEN"
	   "BUTTON-EVENT-BUTTON" "KEY-EVENT-ROOT" "KEY-EVENT-SUBWINDOW"
	   "KEY-EVENT-TIME" "KEY-EVENT-X" "KEY-EVENT-Y" "KEY-EVENT-X-ROOT"
	   "KEY-EVENT-Y-ROOT" "KEY-EVENT-STATE" "KEY-EVENT-KEYCODE"
	   "KEY-EVENT-SAME-SCREEN" "MOTION-EVENT-ROOT"
	   "MOTION-EVENT-SUBWINDOW" "MOTION-EVENT-TIME" "MOTION-EVENT-X"
	   "MOTION-EVENT-Y" "MOTION-EVENT-X-ROOT" "MOTION-EVENT-Y-ROOT"
	   "MOTION-EVENT-STATE" "MOTION-EVENT-IS-HINT"
	   "MOTION-EVENT-SAME-SCREEN" "CROSSING-EVENT-ROOT"
	   "CROSSING-EVENT-SUBWINDOW" "CROSSING-EVENT-TIME"
	   "CROSSING-EVENT-X" "CROSSING-EVENT-Y" "CROSSING-EVENT-X-ROOT"
	   "CROSSING-EVENT-Y-ROOT" "CROSSING-EVENT-MODE"
	   "CROSSING-EVENT-DETAIL" "CROSSING-EVENT-FOCUS"
	   "CROSSING-EVENT-SAME-SCREEN" "CROSSING-EVENT-STATE"
	   "FOCUS-CHANGE-EVENT-MODE" "FOCUS-CHANGE-EVENT-DETAIL"
	   "EXPOSE-EVENT-X" "EXPOSE-EVENT-Y" "EXPOSE-EVENT-WIDTH"
	   "EXPOSE-EVENT-HEIGHT" "EXPOSE-EVENT-COUNT"
	   "GRAPHICS-EXPOSE-EVENT-X" "GRAPHICS-EXPOSE-EVENT-DRAWABLE"
	   "GRAPHICS-EXPOSE-EVENT-Y" "GRAPHICS-EXPOSE-EVENT-WIDTH"
	   "GRAPHICS-EXPOSE-EVENT-HEIGHT" "GRAPHICS-EXPOSE-EVENT-COUNT"
	   "GRAPHICS-EXPOSE-EVENT-MAJOR-CODE"
	   "GRAPHICS-EXPOSE-EVENT-MINOR-CODE" "NO-EXPOSE-EVENT-MINOR-CODE"
	   "NO-EXPOSE-EVENT-DRAWABLE" "NO-EXPOSE-EVENT-MAJOR-CODE"
	   "VISIBILITY-EVENT-STATE" "CREATE-WINDOW-EVENT-PARENT"
	   "CREATE-WINDOW-EVENT-WINDOW" "CREATE-WINDOW-EVENT-X"
	   "CREATE-WINDOW-EVENT-Y" "CREATE-WINDOW-EVENT-WIDTH"
	   "CREATE-WINDOW-EVENT-HEIGHT"
	   "CREATE-WINDOW-EVENT-OVERRIDE-REDIRECT"
	   "DESTROY-WINDOW-EVENT-EVENT" "DESTROY-WINDOW-EVENT-WINDOW"
	   "UNMAP-EVENT-EVENT" "UNMAP-EVENT-WINDOW"
	   "UNMAP-EVENT-FROM-CONFIGURE" "MAP-REQUEST-EVENT-PARENT"
	   "MAP-REQUEST-EVENT-WINDOW" "REPARENT-EVENT-EVENT"
	   "REPARENT-EVENT-PARENT" "REPARENT-EVENT-X" "REPARENT-EVENT-Y"
	   "REPARENT-EVENT-OVERRIDE-REDIRECT" "CONFIGURE-EVENT-EVENT"
	   "CONFIGURE-EVENT-WINDOW" "CONFIGURE-EVENT-X" "CONFIGURE-EVENT-Y"
	   "CONFIGURE-EVENT-WIDTH" "CONFIGURE-EVENT-HEIGHT"
	   "CONFIGURE-EVENT-BORDER-WIDTH" "CONFIGURE-EVENT-ABOVE"
	   "CONFIGURE-EVENT-OVERRIDE-REDIRECT" "GRAVITY-EVENT-EVENT"
	   "GRAVITY-EVENT-WINDOW" "GRAVITY-EVENT-X" "GRAVITY-EVENT-Y"
	   "RESIZE-REQUEST-EVENT-WIDTH" "RESIZE-REQUEST-EVENT-HEIGHT"
	   "CONFIGURE-REQUEST-EVENT-PARENT"
	   "CONFIGURE-REQUEST-EVENT-WINDOW" "CONFIGURE-REQUEST-EVENT-X"
	   "CONFIGURE-REQUEST-EVENT-Y" "CONFIGURE-REQUEST-EVENT-WIDTH"
	   "CONFIGURE-REQUEST-EVENT-HEIGHT" "CONFIGURE-REQUEST-EVENT-ABOVE"
	   "CONFIGURE-REQUEST-EVENT-BORDER-WIDTH"
	   "CONFIGURE-REQUEST-EVENT-DETAIL"
	   "CONFIGURE-REQUEST-EVENT-VALUE-MASK" "CIRCULATE-EVENT-EVENT"
	   "CIRCULATE-EVENT-WINDOW" "CIRCULATE-EVENT-PLACE"
	   "CIRCULATE-REQUEST-EVENT-EVENT" "CIRCULATE-REQUEST-EVENT-WINDOW"
	   "CIRCULATE-REQUEST-EVENT-PLACE" "PROPERTY-EVENT-ATOM"
	   "PROPERTY-EVENT-TIME" "PROPERTY-EVENT-STATE"
	   "SELECTION-CLEAR-EVENT-SELECTION" "SELECTION-CLEAR-EVENT-TIME"
	   "SELECTION-REQUEST-EVENT-OWNER"
	   "SELECTION-REQUEST-EVENT-REQUESTOR"
	   "SELECTION-REQUEST-EVENT-SELECTION"
	   "SELECTION-REQUEST-EVENT-TARGET"
	   "SELECTION-REQUEST-EVENT-PROPERTY"
	   "SELECTION-REQUEST-EVENT-TIME" "SELECTION-EVENT-REQUESTOR"
	   "SELECTION-EVENT-SELECTION" "SELECTION-EVENT-TARGET"
	   "SELECTION-EVENT-PROPERTY" "SELECTION-EVENT-TIME"
	   "COLORMAP-EVENT-COLORMAP" "COLORMAP-EVENT-NEW"
	   "COLORMAP-EVENT-STATE" "MAPPING-EVENT-REQUEST"
	   "MAPPING-EVENT-FIRST-KEYCODE" "MAPPING-EVENT-COUNT"))

(defpackage "TOOLKIT"
  (:nicknames "XT")
  (:use "COMMON-LISP" "EXTENSIONS" "TOOLKIT-INTERNALS")
  (:export "ADD-CALLBACK" "REMOVE-CALLBACK" "REMOVE-ALL-CALLBACKS"
	   "ADD-PROTOCOL-CALLBACK" "REMOVE-PROTOCOL-CALLBACK"
	   "ADD-WM-PROTOCOL-CALLBACK" "REMOVE-WM-PROTOCOL-CALLBACK"
	   "WITH-CALLBACK-EVENT" "WITH-ACTION-EVENT" "ADD-EVENT-HANDLER"
	   "REMOVE-EVENT-HANDLER" "ANY-CALLBACK" "ANY-CALLBACK-REASON"
	   "ANY-CALLBACK-EVENT" "BUTTON-CALLBACK" "DRAWING-AREA-CALLBACK"
	   "BUTTON-CALLBACK-CLICK-COUNT" "DRAWING-AREA-CALLBACK-WINDOW"
	   "DRAWN-BUTTON-CALLBACK" "DRAWN-BUTTON-CALLBACK-WINDOW"
	   "DRAWN-BUTTON-CALLBACK-CLICK-COUNT" "SCROLL-BAR-CALLBACK"
	   "SCROLL-BAR-CALLBACK-VALUE" "SCROLL-BAR-CALLBACK-PIXEL"
	   "TOGGLE-BUTTON-CALLBACK" "TOGGLE-BUTTON-CALLBACK-SET"
	   "LIST-CALLBACK" "LIST-CALLBACK-ITEM"
	   "LIST-CALLBACK-ITEM-POSITION" "LIST-CALLBACK-SELECTED-ITEMS"
	   "LIST-CALLBACK-SELECTED-ITEM-POSITIONS"
	   "LIST-CALLBACK-SELECTION-TYPE" "SELECTION-CALLBACK"
	   "SELECTION-CALLBACK-VALUE" "FILE-SELECTION-CALLBACK"
	   "FILE-SELECTION-CALLBACK-VALUE" "FILE-SELECTION-CALLBACK-MASK"
	   "FILE-SELECTION-CALLBACK-DIR" "FILE-SELECTION-CALLBACK-PATTERN"
	   "SCALE-CALLBACK" "SCALE-CALLBACK-VALUE" "TEXT-CALLBACK"
	   "TEXT-CALLBACK-DOIT" "TEXT-CALLBACK-CURR-INSERT"
	   "TEXT-CALLBACK-NEW-INSERT" "TEXT-CALLBACK-START-POS"
	   "TEXT-CALLBACK-END-POS" "TEXT-CALLBACK-TEXT" "WITH-ACTION-EVENT"
	   "TEXT-CALLBACK-FORMAT" "*DEBUG-MODE*" "*DEFAULT-SERVER-HOST*"
	   "*CLM-BINARY-DIRECTORY*" "*CLM-BINARY-NAME*"
	   "*DEFAULT-DISPLAY*" "QUIT-APPLICATION" "WITH-MOTIF-CONNECTION"
	   "RUN-MOTIF-APPLICATION" "WITH-CLX-REQUESTS"
	   "BUILD-SIMPLE-FONT-LIST" "BUILD-FONT-LIST" "*MOTIF-CONNECTION*"
	   "*X-DISPLAY*" "WIDGET" "XMSTRING" "FONT-LIST" "SET-VALUES"
	   "GET-VALUES" "CREATE-MANAGED-WIDGET" "CREATE-WIDGET"
	   "CREATE-POPUP-SHELL" "CREATE-APPLICATION-SHELL" "DESTROY-WIDGET"
	   "*CONVENIENCE-AUTO-MANAGE*" "MANAGE-CHILDREN"
	   "UNMANAGE-CHILDREN" "WITH-RESOURCE-VALUES" "MENU-POSITION"
	   "CREATE-ARROW-BUTTON" "CREATE-ARROW-BUTTON-GADGET"
	   "CREATE-BULLETIN-BOARD" "CREATE-CASCADE-BUTTON"
	   "CREATE-CASCADE-BUTTON-GADGET" "CREATE-COMMAND"
	   "CREATE-DIALOG-SHELL" "CREATE-DRAWING-AREA"
	   "CREATE-DRAWN-BUTTON" "CREATE-FILE-SELECTION-BOX" "CREATE-FORM"
	   "CREATE-FRAME" "CREATE-LABEL" "CREATE-LABEL-GADGET"
	   "CREATE-LIST" "CREATE-MAIN-WINDOW" "CREATE-MENU-SHELL"
	   "CREATE-MESSAGE-BOX" "CREATE-PANED-WINDOW" "CREATE-PUSH-BUTTON"
	   "CREATE-PUSH-BUTTON-GADGET" "CREATE-ROW-COLUMN" "CREATE-SCALE"
	   "CREATE-SCROLL-BAR" "CREATE-SCROLLED-WINDOW"
	   "CREATE-SELECTION-BOX" "CREATE-SEPARATOR"
	   "CREATE-SEPARATOR-GADGET" "CREATE-TEXT" "CREATE-TEXT-FIELD"
	   "CREATE-TOGGLE-BUTTON"
	   "CREATE-TOGGLE-BUTTON-GADGET" "CREATE-MENU-BAR"
	   "CREATE-OPTION-MENU" "CREATE-RADIO-BOX" "CREATE-WARNING-DIALOG"
	   "CREATE-BULLETIN-BOARD-DIALOG" "CREATE-ERROR-DIALOG"
	   "CREATE-FILE-SELECTION-DIALOG" "CREATE-FORM-DIALOG"
	   "CREATE-INFORMATION-DIALOG" "CREATE-MESSAGE-DIALOG"
	   "CREATE-POPUP-MENU" "CREATE-PROMPT-DIALOG"
	   "CREATE-PULLDOWN-MENU" "CREATE-QUESTION-DIALOG"
	   "CREATE-SCROLLED-LIST" "CREATE-SCROLLED-TEXT"
	   "CREATE-SELECTION-DIALOG" "CREATE-WORKING-DIALOG"
	   "REALIZE-WIDGET" "UNREALIZE-WIDGET" "MAP-WIDGET" "UNMAP-WIDGET"
	   "SET-SENSITIVE" "POPUP" "POPDOWN" "MANAGE-CHILD"
	   "UNMANAGE-CHILD" "PARSE-TRANSLATION-TABLE"
	   "AUGMENT-TRANSLATIONS" "OVERRIDE-TRANSLATIONS"
	   "UNINSTALL-TRANSLATIONS" "PARSE-ACCELERATOR-TABLE"
	   "INSTALL-ACCELERATORS" "INSTALL-ALL-ACCELERATORS" "IS-MANAGED"
	   "POPUP-SPRING-LOADED" "IS-REALIZED" "WIDGET-WINDOW" "WIDGET-NAME"
	   "IS-SENSITIVE" "COMMAND-APPEND-VALUE" "COMMAND-ERROR"
	   "COMMAND-SET-VALUE" "SCALE-GET-VALUE" "SCALE-SET-VALUE"
	   "TOGGLE-BUTTON-GET-STATE" "TOGGLE-BUTTON-SET-STATE"
	   "LIST-ADD-ITEM" "LIST-ADD-ITEM-UNSELECTED" "LIST-DELETE-ITEM"
	   "LIST-DELETE-POS" "LIST-DESELECT-ALL-ITEMS" "LIST-DESELECT-ITEM"
	   "LIST-DESELECT-POS" "LIST-SELECT-ITEM" "LIST-SELECT-POS"
	   "LIST-SET-BOTTOM-ITEM" "LIST-SET-BOTTOM-POS"
	   "LIST-SET-HORIZ-POS" "LIST-SET-ITEM" "LIST-SET-POS"
	   "ADD-TAB-GROUP" "REMOVE-TAB-GROUP" "PROCESS-TRAVERSAL"
	   "FONT-LIST-ADD" "FONT-LIST-CREATE" "FONT-LIST-FREE"
	   "COMPOUND-STRING-BASELINE" "COMPOUND-STRING-BYTE-COMPARE"
	   "COMPOUND-STRING-COMPARE" "COMPOUND-STRING-CONCAT"
	   "COMPOUND-STRING-COPY" "COMPOUND-STRING-CREATE"
	   "COMPOUND-STRING-CREATE-LTOR" "COMPOUND-STRING-CREATE-SIMPLE"
	   "COMPOUND-STRING-CREATE-EMPTY" "COMPOUND-STRING-EXTENT"
	   "COMPOUND-STRING-FREE" "COMPOUND-STRING-HAS-SUBSTRING"
	   "COMPOUND-STRING-HEIGHT" "COMPOUND-STRING-LENGTH"
	   "COMPOUND-LINE-COUNT" "COMPOUND-STRING-NCONCAT"
	   "COMPOUND-STRING-NCOPY" "COMPOUND-STRING-SEPARATOR-CREATE"
	   "COMPOUND-STRING-WIDTH" "TEXT-CLEAR-SELECTION" "TEXT-COPY"
	   "TEXT-CUT" "TEXT-GET-BASELINE" "TEXT-GET-EDITABLE"
	   "TEXT-GET-INSERTION-POSITION" "TEXT-GET-LAST-POSITION"
	   "TEXT-GET-MAX-LENGTH" "TEXT-GET-SELECTION"
	   "TEXT-GET-SELECTION-POSITION" "TEXT-GET-STRING"
	   "TEXT-GET-TOP-CHARACTER" "TEXT-INSERT" "TEXT-PASTE"
	   "TEXT-POS-TO-XY" "TEXT-REMOVE" "TEXT-REPLACE" "TEXT-SCROLL"
	   "TEXT-SET-ADD-MODE" "TEXT-SET-EDITABLE" "TEXT-SET-HIGHLIGHT"
	   "TEXT-SET-INSERTION-POSITION" "TEXT-SET-MAX-LENGTH"
	   "TEXT-SET-SELECTION" "TEXT-SET-STRING" "TEXT-SET-TOP-CHARACTER"
	   "TEXT-SHOW-POSITION" "TEXT-XY-TO-POS" "MESSAGE-BOX-GET-CHILD"
	   "SELECTION-BOX-GET-CHILD" "FILE-SELECTION-BOX-GET-CHILD"
	   "COMMAND-GET-CHILD" "UPDATE-DISPLAY" "IS-MOTIF-WM-RUNNING"
	   "LIST-ADD-ITEMS" "LIST-DELETE-ALL-ITEMS" "LIST-DELETE-ITEMS"
	   "LIST-DELETE-ITEMS-POS" "LIST-ITEM-EXISTS" "LIST-ITEM-POS"
	   "LIST-REPLACE-ITEMS" "LIST-REPLACE-ITEMS-POS"
	   "LIST-SET-ADD-MODE" "TRANSLATE-COORDS" "SCROLL-BAR-GET-VALUES"
	   "SCROLL-BAR-SET-VALUES" "COMPOUND-STRING-GET-LTOR"
	   "TRACKING-LOCATE" "SCROLLED-WINDOW-SET-AREAS" "CREATE-FONT-CURSOR"
	   "LIST-GET-SELECTED-POS" "QUIT-APPLICATION-CALLBACK"
	   "DESTROY-CALLBACK" "MANAGE-CALLBACK" "UNMANAGE-CALLBACK"
	   "POPUP-CALLBACK" "POPDOWN-CALLBACK" "SET-ITEMS" "GET-ITEMS"
	   "WITH-CALLBACK-DEFERRED-ACTIONS" "NAME-TO-WIDGET"
           "IS-APPLICATION-SHELL" "IS-COMPOSITE" "IS-CONSTRAINT" "IS-OBJECT"
           "IS-OVERRIDE-SHELL" "IS-RECT-OBJ" "IS-SHELL" "IS-TOP-LEVEL-SHELL"
           "IS-TRANSIENT-SHELL" "IS-VENDOR-SHELL" "IS-W-M-SHELL"
           "XT-WIDGET-PARENT"))



;;;; These variables are built at compile time and used to build C header
;;;; files.  We retain the values at run-time just so that we can built the
;;;; interface files at any time.

(in-package "TOOLKIT")

(declaim (special *request-table* *class-table* next-type-tag))

