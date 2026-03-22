#!/usr/bin/env bash
# =============================================================================
# adoc.sh — emit AsciiDoc tagged regions from grouped files
#
# Usage:
#   adoc.sh <base>...
#   printf "base1\nbase2\n" | adoc.sh
#
# For each base name, finds all files matching <base>.* in the current
# directory and wraps their content in AsciiDoc tagged regions:
#
#   // tag::<filename-with-ext>[]
#   <raw file content>
#   // end::<filename-with-ext>[]
#
# Designed to work with httpreq.sh output groups (.curl, .status, .headers,
# .cookies, .body), but accepts any file groups.
#
# Stdout: AsciiDoc tagged regions for all matching files
# =============================================================================
set -euo pipefail

_usage() {
    printf 'Usage: %s <base>...\n' "$(basename "$0")" >&2
    printf '       printf "base1\\nbase2\\n" | %s\n' "$(basename "$0")" >&2
}

declare -a _bases=()

if [[ $# -gt 0 ]]; then
    _bases=( "$@" )
elif [[ ! -t 0 ]]; then
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _bases+=( "$_line" )
    done
else
    _usage; exit 1
fi

shopt -s nullglob

for base in "${_bases[@]}"; do
    files=( "${base}".* )
    for f in "${files[@]}"; do
        printf '// tag::%s[]\n' "$f"
        cat -- "$f"
        printf '// end::%s[]\n' "$f"
    done
done
