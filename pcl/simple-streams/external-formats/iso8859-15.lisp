;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Package: STREAM -*-
;;;
;;; **********************************************************************
;;; This code was written by Paul Foley and has been placed in the public
;;; domain.
;;;
(ext:file-comment "$Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/pcl/simple-streams/external-formats/iso8859-15.lisp,v 1.1.2.1 2008/07/02 01:22:10 rtoy Exp $")

(defconstant +iso-8859-15+
  (make-array 96 :element-type '(unsigned-byte 16)
     :initial-contents #(160 161 162 163 8364 165 352 167 353 169 170 171 172
                         173 174 175 176 177 178 179 381 181 182 183 382 185
                         186 187 338 339 376 191 192 193 194 195 196 197 198
                         199 200 201 202 203 204 205 206 207 208 209 210 211
                         212 213 214 215 216 217 218 219 220 221 222 223 224
                         225 226 227 228 229 230 231 232 233 234 235 236 237
                         238 239 240 241 242 243 244 245 246 247 248 249 250
                         251 252 253 254 255)))

(define-external-format :iso8859-15 (:iso8859-2)
  ((table +iso-8859-15+)))
