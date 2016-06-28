#!/bin/bash


function field_var_name() {
	local varname=${1//-/_}
	echo ${varname^^}
}

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
			echo "DEBUG: LINE=$value" >&2
			while IFS= read -r line ; do
				if [ "${line:0:1}" != " " ] ; then
					IN_EOF=0
					break
				fi
				echo "DEBUG: LINE=$line" >&2
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
			field="NAME"
			mode="package"
		fi
		eval "${PREFIX}_${fieldvar}=\"${value}\""
		ALL_FIELDS="${ALL_FIELDS} ${PREFIX}_${fieldvar}"
	done <./debian/control
	for f in $ALL_FIELDS ; do
		eval "echo \"DEBUG: ${f}=\$$f\"" >&2
	done
}

function parse_changelog() {
	true
}

declare -a DSC_OUTPUT_FIELDS=(
"Maintainer"
"Architecture"
"Binary"
"Build-Conflicts-Arch"
"Build-Conflicts"
"Build-Conflicts-Indep"
"Build-Depends-Arch"
"Build-Depends"
"Build-Depends-Indep"
"Enhances"
"Files"
"Package-List"
"Provides"
"Size"
"Status"
"Testsuite"
"Uploaders"
"Vcs-Browser"
"Vcs-Arch"
"Vcs-Bzr"
"Vcs-Cvs"
"Vcs-Darcs"
"Vcs-Git"
"Vcs-Hg"
"Vcs-Mtn"
"Vcs-Svn"
"Vendor"
"Vendor-Url"
"Version"
)

function output_dsc() {
	for field in "${DSC_OUTPUT_FIELDS[@]}" ; do
		fieldvar=$(field_var_name $field)
		eval "f=\${FIELD_${fieldvar}}"
		[ -n "$f" ] && eval echo \"${field}: \${FIELD_${fieldvar}}\"
	done
}

function debian_generate_dsc() {
	parse_control_file
	parse_changelog

	output_dsc
}

debian_generate_dsc
