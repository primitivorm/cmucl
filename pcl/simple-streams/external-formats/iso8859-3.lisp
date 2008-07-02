;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Package: STREAM -*-
;;;
;;; **********************************************************************
;;; This code was written by Paul Foley and has been placed in the public
;;; domain.
;;;
(ext:file-comment "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/pcl/simple-streams/external-formats/iso8859-3.lisp,v 1.1.2.1 2008/07/02 01:22:10 rtoy Exp $")

(defconstant +iso-8859-3+
  (make-array 96 :element-type '(unsigned-byte 16)
     :initial-contents #(160 294 728 163 164 65534 292 167 168 304 350 286 308
                         173 65534 379 176 295 178 179 180 181 293 183 184 305
                         351 287 309 189 65534 380 192 193 194 65534 196 266
                         264 199 200 201 202 203 204 205 206 207 65534 209 210
                         211 212 288 214 215 284 217 218 219 220 364 348 223
                         224 225 226 65534 228 267 265 231 232 233 234 235 236
                         237 238 239 65534 241 242 243 244 289 246 247 285 249
                         250 251 252 365 349 729)))

(define-external-format :iso8859-3 (:iso8859-2)
  ((table +iso-8859-3+)))
