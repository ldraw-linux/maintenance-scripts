#!/bin/bash -x
ROOT=`pwd`
PKG=`basename "$ROOT"`
UPSTREAM=upstream
MASTER=master
PACKAGING=packaging

#
# a block of functions
# look for "main" to skip it
#
function die() {
	echo "ERROR: $1" >&2
	exit 1
}

function warn() {
	echo "WARNING: $1" >&2
}

#
# main
#

#
# Check we're being run from the project root
#

if ! [[ -d "$ROOT/.git" ]]; then
	die "Run this script from the project root"
fi

#TODO: check we're in the packaging branch?
#TODO: check that upstream/master/packaging branches exist
#TODO: check master has been merged into the packaging branch

#
# Check options 
#

if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] ; then
	echo "Usage: $0 [force]" >&2
	exit 1
fi

FORCE=false
[[ "$1" == "force" ]] && FORCE=true

# check for uncommitted changes

if git status --porcelain -- "$ROOT"|grep -q M; then
	warn "Uncommited changes:"
	git status --short >&2
	if git status --porcelain -- "$ROOT" |grep -q M && ! $FORCE; then
		die "Please commit your changes to git first. To override, run: $0 force"
	fi
fi

# get the commit the user wants to make a package from
# and that we're on a tagged commit

HASH=`git log -1 --pretty="format:%H"`
TAG=`git tag --points-at HEAD`
if [[ -z $TAG ]]; then 
	warn "Not on a tagged commit."
	TAG=`git describe --abbrev=0`
	[[ -z $TAG ]] && exit 1

	if ! $FORCE; then
		die "To use the most recent tag ($TAG) as the version string, run: $0 force"
	fi
fi
#TODO: check VERSION format
VERSION=$TAG
UPSTREAM_VERSION=${VERSION%.*}

echo "Using $VERSION as version string."	


#
# Create the directory of package sources
#
D=`mktemp -d`
SRCDIR="$D/$PKG"
PATCHES_MASTER=$D/patches-master
mkdir "$SRCDIR" || die "Cannot create a temporary directory $SRCDIR"
mkdir "$PATCHES_MASTER" || die "Cannot create a temporary directory $PATCHES_MASTER"
mkdir "$SRCDIR/output"

# create upstream tarball
git archive --prefix=${PKG}-${UPSTREAM_VERSION}/ $UPSTREAM | gzip > $SRCDIR/output/${PKG}_${UPSTREAM_VERSION}.orig.tar.gz

# create patch series between upstream and master
git format-patch -o $PATCHES_MASTER $UPSTREAM..$MASTER

# copy distro-specific files 
git archive $PACKAGING -- suse debian | tar -x -C $SRCDIR

# this may fail if the directories don't exist and that's OK
git archive $PACKAGING -- patches-distro series-distro 2>/dev/null | tar -x -C $SRCDIR 


#
# Generate packages
#

# This function expects an annotated tag 'start' containing two lines in the messsage:
#   Upstream version of the project at that time
#   URL of upstream
function suse_shorten_history() {
	git cat-file -p start | {
		while true ; do
			read line
			if [ -z "$line" ] ; then
				break
			fi
		done
		read version
		read URL
		git log -1 --pretty=format:"-------------------------------------------------------------------%n%ad - %ce%n%n- ${version}%n  ${URL}%n" start ;
	}
}

function suse_generate_changes_file() {
	git log --date-order --pretty=format:'%at;-------------------------------------------------------------------|n|%ad - %ce|n||n|- %s|n|  %h|n|' start..$PACKAGING | sort -nr -t \; -k 1 | sed 's/^[0-9]*;//;s/|n|/\n/g'
	suse_shorten_history
}


function gen_suse() {
	SRC=$1
	OUTPUT=$2
	DISTNAME=$3

	pushd $SRC

	#generate spec.patch_declare and spec.patch_apply temporary files
	n=0
	for i in patches/*; do
		[[ -e $i ]] || continue
		f=${i##*/}
		n=$((n+1))
		echo "Patch$n: $f" >> spec.patch_declare
		echo "%patch$n -p1" >> spec.patch_apply
		[[ -e $OUTPUT/$f ]] || cp $i $OUTPUT
	done

	sed -e 's/__VERSION__/'$VERSION'/
	        /__PATCHES_DECLARE__/ {
			r spec.patch_declare
			d
			};
		/__PATCHES_APPLY__/ {
			r spec.patch_apply
			d
			}' $PKG.spec >$OUTPUT/${PKG}${DISTNAME:+-}${DISTNAME}.spec

	{	
		# needs to be run in the git directory
		pushd $ROOT
		suse_generate_changes_file 
		popd
	} >$OUTPUT/${PKG}${DISTNAME:+-}${DISTNAME}.changes

	popd
}

pushd $SRCDIR


DISTRO_TEMPLATES="suse debian"
for template in $DISTRO_TEMPLATES ; do
	cp -a $PATCHES_MASTER ${template}/patches
	gen_$template $template ${SRCDIR}/output ""
	[[ -d series-distro/${template} ]] || continue
	for dist_full in series-distro/${template}/* ; do
		[[ -e "$dist_full" ]] || continue
		dist=${dist_full##*/}
		cp -a ${template} ${dist}
		pushd ${dist}
		while read patch; do
			patch < ../patches-distro/$patch
		done <../series-distro/${dist}
		popd
		gen_$template ${dist} ${SRCDIR}/output ${dist}
	done
done
popd #SRCDIR

#generate Debian packaging files
mkdir $SRCDIR/debian



if $LOCAL ; then
	echo "Sources of the package are stored at $SRCDIR" >&2
	exit 0
fi

#
# OSC part
#

pushd $D
if ! osc co "$PRJ" "$PKG"; then
	popd
	rm -rf $D
	die "Cannot check the project out from BS."
fi

PRJD="$D/$PRJ/$PKG"

if ! cd $PRJD; then 
	popd
	rm -rf $D
	die "Cannot get into the package directory."
fi

rm -rf ./*
cp $SRCDIR/* .

if $BUILD; then
	osc build
	echo "Keeping build source directory: $D"
else
	osc addremove
	osc commit -m "git commit: $TAG($HASH)"
	popd
	rm -rf $D
fi

