#!/bin/bash
# A wrapper for prepare-src.sh that 
# submits the prepatred package sources to the openSUSE Build Service
# it requires a .obs_config, containing these variables:
# OBS_PROJECT - name of your OBS project
# OBS_PACKAGE - name of the package inside your OBS project



# prepare-src.sh is called from the same directory as this script
SCRIPTS=`(cd ${BASH_SOURCE%/*}; pwd )`

D=`mktemp -d` || exit 1
mkdir $D/prep
export OUTPUT_DIR=$D/prep

# prepare the sources
$SCRIPTS/prepare-src.sh "$@" || exit

. .obs_config
COMMIT=`git log -1 --format="%h"`

# check out the OBS package, COMPLETELY REPLACE it with
# the newly generated sources and resubmit

cd $D
osc co $OBS_PROJECT/$OBS_PACKAGE
cd $OBS_PROJECT/$OBS_PACKAGE
rm *
cp $OUTPUT_DIR/* .
osc addremove
osc commit -m "git commit: $COMMIT"

#clean up
rm -rf $D
