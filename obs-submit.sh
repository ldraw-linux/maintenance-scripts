#!/bin/bash -x

SCRIPTS=`(cd ${BASH_SOURCE%/*}; pwd )`

D=`mktemp -d` || exit 1
mkdir $D/prep
export OUTPUT_DIR=$D/prep
$SCRIPTS/prepare-src.sh "$@" || exit

. .obs_config
COMMIT=`git log -1 --format="%h"`

cd $D
osc co $OBS_PROJECT/$OBS_PACKAGE
cd $OBS_PROJECT/$OBS_PACKAGE
osc rm *
cp $OUTPUT_DIR/* .
osc add *
osc commit -m "git commit: $COMMIT"

rm -rf $D
