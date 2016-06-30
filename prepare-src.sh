#!/bin/bash
ROOT=`pwd`
PKG=`basename "$ROOT"`
UPSTREAM=upstream
MASTER=master
PACKAGING=packaging

SCRIPTS=`(cd ${BASH_SOURCE%/*}; pwd )`

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

# ignore stdout of pushd/popd
function pushd()
{
	builtin pushd "$@" >/dev/null || die "pushd failed: $@"
}

function popd()
{
	builtin popd "$@" >/dev/null || die "popd failed: $@"
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
# and verify that we're on a tagged commit

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
RELEASE_VERSION=${VERSION##*.}

echo "Using $VERSION as version string."	


#
# Create the directory of package sources
# If OUTPUT_DIR is not set, it will be created under the sources directory
#
D=`mktemp -d`
SRCDIR="$D/$PKG"
PATCHES_MASTER=$D/patches-master
OUTPUT_DIR=${OUTPUT_DIR:-${SRCDIR}/output}

mkdir "$SRCDIR" || die "Cannot create a temporary directory $SRCDIR"
mkdir "$PATCHES_MASTER" || die "Cannot create a temporary directory $PATCHES_MASTER"
mkdir -p "$OUTPUT_DIR"

# create upstream tarball
git archive --prefix=${PKG}-${UPSTREAM_VERSION}/ $UPSTREAM | gzip -n > "${OUTPUT_DIR}/${PKG}_${UPSTREAM_VERSION}.orig.tar.gz"

# create patch series between upstream and master
git format-patch -o $PATCHES_MASTER $UPSTREAM..$MASTER

# copy distro-specific files 
git archive $PACKAGING -- rpm deb | tar -x -C $SRCDIR

# this may fail if the directories don't exist and that's OK
git archive $PACKAGING -- patches-distro series-distro 2>/dev/null | tar -x -C $SRCDIR 


#
# Generate packages
#

################### rpm #############

function rpm_generate_changes_file() {
	# TODO: we need to ensure proper ordering of the git log;
	# this condenses each commit to a single line, sorts using sort,
	# and then splits the lines again. This is probably wrong! FIXME!
	# we also want to properly describe merge commits!

	git log --date-order --first-parent --pretty=format:\
'%at;-------------------------------------------------------------------|n|'\
'%ad - %ce|n||n|- %s|n|  %h|n|'\
	start..$MASTER | sort -nr -t \; -k 1 | sed 's/^[0-9]*;//;s/|n|/\n/g'
}


function gen_rpm() {
	SRC=$1
	OUTPUT="$2"
	DISTNAME=$3

	pushd $SRC

	# generate spec.patch_declare and spec.patch_apply temporary files
	n=0
	for i in patches/*; do
		[[ -e $i ]] || continue
		f=${i##*/}
		n=$((n+1))
		echo "Patch$n: $f" >> spec.patch_declare
		echo "%patch$n -p1" >> spec.patch_apply
		[[ -e "$OUTPUT/$f" ]] || cp $i "$OUTPUT"
	done

	# generate the spec file, filling in marked fields from the template
	sed -e 's/__UPSTREAM_VERSION__/'$UPSTREAM_VERSION'/
	        s/__RELEASE_VERSION__/'$RELEASE_VERSION'/
		/__PATCHES_DECLARE__/ {
			r spec.patch_declare
			d
			};
		/__PATCHES_APPLY__/ {
			r spec.patch_apply
			d
			}' $PKG.spec >"$OUTPUT/${PKG}${DISTNAME:+-}${DISTNAME}.spec"
	rm spec.patch_declare spec.patch_apply

	{	
		# needs to be run in the git directory
		pushd $ROOT 
		rpm_generate_changes_file 
		popd 
	} >"$OUTPUT/${PKG}${DISTNAME:+-}${DISTNAME}.changes"

	popd
}

################### deb #############

function deb_generate_changes_file() {
	# TODO: we need to ensure proper ordering of the git log;
	# this condenses each commit to a single line, sorts using sort,
	# and then splits the lines again. This is probably wrong! FIXME!
	# we also want to properly describe merge commits!

	git log --date-order --first-parent --pretty=format:\
"%at;"\
"$PKG ($DEBIAN_VERSION) unstable; urgency=low|n||n|"\
"  * %s (%h)|n||n|"\
" -- %cn <%ce>  %aD"\
	start..$MASTER | sort -nr -t \; -k 1 | sed 's/^[0-9]*;//;s/|n|/\n/g'
}

# reimplement associative arrays to support bash < 4.0
function field_var_name() {
	local varname=${1//-/_}
	echo ${varname^^}
}

# parses the control file and saves the information in bash variables
function parse_control_file() {
	PREFIX=FIELD
	PKG_NUM=0
	PKG_MAX=$PKG_NUM
	mode="general"
	ALL_FIELDS=""
	IFS_ORIG="$IFS"
	while read field value ; do
		[ -z "$field" ] && continue
		field=${field/:/}
		fieldvar=$(field_var_name $field)
		if [ "$mode" = "package" -a "$field" = "Description" ] ; then
			IN_EOF=1
			eval "${PREFIX}_${fieldvar}=\"\$value\""
			while IFS= read -r line ; do
				if [ "${line:0:1}" != " " ] ; then
					IN_EOF=0
					break
				fi
				eval "${PREFIX}_${fieldvar}=\"\${${PREFIX}_${fieldvar}}
\${line}\""
			done
			ALL_FIELDS="${ALL_FIELDS} ${PREFIX}_${fieldvar}"
			if [ "${IN_EOF}" = 1 ] ; then
				break
			else
				read field value <<<"$line"
				[ -z "$field" ] && continue
				field=${field/:/}
				fieldvar=$(field_var_name $field)
			fi
		fi
		if [ "$field" = "Package" ] ; then
			PKG_NUM=$(( PKG_NUM + 1 ))
			PKG_MAX=$PKG_NUM
			PREFIX="PACKAGE_${PKG_NUM}"
			fieldvar="NAME"
			mode="package"
		fi
		eval "${PREFIX}_${fieldvar}=\"${value}\""
		ALL_FIELDS="${ALL_FIELDS} ${PREFIX}_${fieldvar}"
	done < control
}


# fields we want to be put in the dsc, stored in bsah variables by the above
# parse_... functions
declare -a DSC_OUTPUT_FIELDS=(
"Source"
"Binary"
"Maintainer"
"Architecture"
"Build-Depends"
"Files"
"Vcs-Git"
)

function output_dsc() {
	echo "Format: $(< source/format)"

	echo "Architecture: any all"
	echo "Version: $VERSION_DISTNAME"

	for field in "${DSC_OUTPUT_FIELDS[@]}" ; do
		fieldvar=$(field_var_name $field)
		eval "f=\${FIELD_${fieldvar}}"
		[ -n "$f" ] && eval echo \"${field}: \${FIELD_${fieldvar}}\"
	done

	echo -n "Binary: "
	for ((i=1; i<=$PKG_MAX; ++i)); do
		eval "f=\${PACKAGE_${i}_NAME}"
		echo -n $f
		if [[ $i == $PKG_MAX ]]; then
			echo ""
		else
			echo -n ", "
		fi
	done

	echo "Package-List:"
	for ((i=1; i<=$PKG_MAX; ++i)); do
		eval "f=\${PACKAGE_${i}_NAME}"
		echo " $f deb misc optional arch=all"
	done


	pushd "$OUTPUT"
	echo "Files:" >> $DSC
	for i in ${PKG}_${UPSTREAM_VERSION}.orig.tar.gz ${PKG}_${VERSION_DISTNAME}.debian.tar.gz; do
		MD5=`md5sum $i`
		MD5=${MD5%% *}
		SIZE=`stat -c%s $i`
		echo " $MD5 $SIZE $i"
	done >> $DSC
	popd

	
}

function deb_generate_dsc() {
	parse_control_file
	output_dsc
}


function gen_deb() {
	SRC=$1
	OUTPUT="$2"
	DISTNAME=$3

	# distribution-version specific files have the distribution version
	# appended to the package version using +
	DISTNAME_ALPHANUM=${DISTNAME//[._-]/}
	DEBIAN_VERSION=${UPSTREAM_VERSION}-${RELEASE_VERSION}
	VERSION_DISTNAME=${DEBIAN_VERSION}${DISTNAME_ALPHANUM:++}${DISTNAME_ALPHANUM}
	pushd $SRC
	echo "9" > compat

	mkdir -p source
	echo "3.0 (quilt)" > source/format

	pushd patches
	ls -1 |grep -v "^series$" > series
	popd
	{	
		pushd $ROOT
		# needs to be run in the git directory
		deb_generate_changes_file 
		popd
	} > changelog

	tar -czf "$OUTPUT/${PKG}_${VERSION_DISTNAME}.debian.tar.gz" --transform='s%^\.%debian%' .
	
	DSC="$OUTPUT/${PKG}${DISTNAME:+-}${DISTNAME}.dsc"

	deb_generate_dsc > $DSC
	popd
}
pushd $SRCDIR

# the packaging branch of each package needs to have a directory for
# each supported package format

DISTRO_TEMPLATES="rpm deb"
for template in $DISTRO_TEMPLATES ; do
	# generic package source for this package format
	cp -a $PATCHES_MASTER ${template}/patches
	gen_$template $template "${OUTPUT_DIR}" ""
	[[ -d series-distro/${template} ]] || continue

	# distribution-version specific patches
	for dist_full in series-distro/${template}/* ; do
		[[ -e "$dist_full" ]] || continue
		dist=${dist_full##*/}

		# copy the generic package source generated above and apply
		# the distribution-version specific patches
		cp -a ${template} ${dist}
		pushd ${dist}
		while read patch; do
			[[ -f ../patches-distro/$patch ]] || continue
			patch -p1 < ../patches-distro/$patch
		done <../series-distro/$template/${dist}
		popd
		#generate the distribution-version specific package source
		gen_$template ${dist} "${OUTPUT_DIR}" ${dist}
	done
done
popd #SRCDIR

echo -e "Sources of the package are stored at\n $OUTPUT_DIR" >&2
