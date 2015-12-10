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

#
# Check options 
#

if [[ -z $1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] ; then
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
PATCHES_MASTER=$D/patches_master
mkdir "$SRCDIR" || die "Cannot create a temporary directory $SRCDIR"
mkdir "$PATCHES_MASTER" || die "Cannot create a temporary directory $PATCHES_MASTER"

# create upstream tarball
git archive --prefix=${PKG}-${UPSTREAM_VER}/ $UPSTREAM | gzip > $SRCDIR/${PKG}_${UPSTREAM_VER}.orig.tar.gz

# create patch series between upstream and master
git format-patch -o $PATCHES_MASTER $UPSTREAM..$MASTER

# copy distro-specific files 
git archive $PACKAGING -- patches-distro series-distro suse debian | tar -x -C $SRCDIR


#
# Generate packages
#

function gen_template_suse() {
	SRC=$1
	OUTPUT=$2

	SPEC=$SRC/$PKG.spec
	CHANGEFILE=$PKG.changes
	#generate spec.patch_declare and spec.patch_apply temporary files
	n = 0;
	for i in $PATCHDIR/*; do
		f=`filename $i`
		n=$((n+1))
		echo "Patch$n: $f" >> $SRCDIR/spec.patch_declare
		echo "%patch$n -p1" >> $SRCDIR/spec.patch_apply
	done

	sed -e 's/__VERSION__/$VER/;/__PATCHES_DECLARE__/ {' -e "'r $SRCDIR/spec.patch_declare" -e 'd' -e '};/__PATCHES_APPLY__/ {' -e "r $SRCDIR/spec.patch_declare" -e 'd' -e '}'; suse/$SPEC >$SRCDIR/$SPEC
	suse_generate_changes_file >$SRCDIR/$CHANGEFILE
}

pushd $SRCDIR
mkdir output

for template_full in series-distro/* ; do
	template=${template_full##*/}
	gen_$template $template output
	for dist_full in series-distro/${template}/* ; do
		dist=${dist_full##*/}
		cp -a ${template} ${dist}
		pushd ${dist}
		while read patch; do
			patch < ../patches-distro/$patch
		done <../series-distro/${dist}
		popd
		gen_$template ${dist} output
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
	git log --date-order --pretty=format:'%at;-------------------------------------------------------------------|n|%ad - %ce|n||n|- %s|n|  %h|n|' start..HEAD | sort -nr -t \; -k 1 | sed 's/^[0-9]*;//;s/|n|/\n/g'
	suse_shorten_history
}

