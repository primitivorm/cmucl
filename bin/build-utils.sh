#!/bin/sh

if [ "$1" = "" ]
then
	echo "Usage: $0 target-directory"
	exit 1
fi

if [ ! -d "$1" ]
then
	echo "$1 isn't a directory"
	exit 2
fi

TARGET="`echo $1 | sed 's:/*$::'`"
shift

# Compile up the asdf and defsystem modules
$TARGET/lisp/lisp -noinit -nositeinit -batch "$@" << EOF || exit 3
(in-package :cl-user)
(setf (ext:search-list "target:")
      '("$TARGET/" "src/"))
(setf (ext:search-list "modules:")
      '("target:contrib/"))

(compile-file "modules:asdf/asdf")
(compile-file "modules:defsystem/defsystem")
EOF

$TARGET/lisp/lisp \
	-noinit -nositeinit -batch "$@" <<EOF || exit 3
(in-package :cl-user)

(setf lisp::*enable-package-locked-errors* nil)
(setf (ext:search-list "target:")
      '("$TARGET/" "src/"))

(setf *default-pathname-defaults* (ext:default-directory))
(intl:install)
(intl::translation-enable)
(load "target:setenv")

(pushnew :no-clx *features*)
(pushnew :no-clm *features*)
(pushnew :no-hemlock *features*)

(compile-file "target:tools/setup" :load t)
(setq *gc-verbose* nil *interactive* nil)
(load "target:tools/clxcom")
(load "target:clx/clx-library")
(load "target:tools/clmcom")
(load "target:tools/hemcom")

EOF

# Find GNU make:

if [ "$MAKE" = "" ]
then    
    MAKE="`which gmake`"

    # Some versions of which set an error code if it fails.  Others
    # say "no foo in <path>".  In either of these cases, just assume
    # make is GNU make.

    if [ $? -ne 0 ]; then
	MAKE="make"
    fi
    if echo "X$MAKE" | grep '^Xno' > /dev/null; then
	MAKE="make"
    fi
fi

export MAKE

${MAKE} -C $TARGET/motif/server clean && ${MAKE} -C $TARGET/motif/server
