;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Package: STREAM -*-
;;;
;;; **********************************************************************
;;; This code was written by Paul Foley and has been placed in the public
;;; domain.
;;;
(ext:file-comment "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/pcl/simple-streams/external-formats/iso8859-8.lisp,v 1.1.2.1 2008/07/02 01:22:10 rtoy Exp $")

(defconstant +iso-8859-8+
  (make-array 96 :element-type '(unsigned-byte 16)
     :initial-contents #(160 65534 162 163 164 165 166 167 168 169 215 171 172
                         173 174 175 176 177 178 179 180 181 182 183 184 185
                         247 187 188 189 190 65534 65534 65534 65534 65534
                         65534 65534 65534 65534 65534 65534 65534 65534 65534
                         65534 65534 65534 65534 65534 65534 65534 65534 65534
                         65534 65534 65534 65534 65534 65534 65534 65534 65534
                         8215 1488 1489 1490 1491 1492 1493 1494 1495 1496 1497
                         1498 1499 1500 1501 1502 1503 1504 1505 1506 1507 1508
                         1509 1510 1511 1512 1513 1514 65534 65534 8206 8207
                         65534)))

(define-external-format :iso8859-8 (:iso8859-2)
  ((table +iso-8859-8+)))
