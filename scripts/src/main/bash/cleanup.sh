#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — delete files by base name, keeping listed extensions
#
# Usage:
#   cleanup.sh <base-name> [keep-ext...]
#   cleanup.sh -- [keep-ext...]          # base-name read from stdin
#
# Deletes every <base-name>.* file in the current directory whose extension is
# NOT in the keep list. With no keep-extensions, all matching files are deleted.
#
# Stdout: base name
# =============================================================================
set -euo pipefail

_usage() {
    printf 'Usage: %s <base-name> [keep-ext...]\n' "$(basename "$0")" >&2
    printf '       %s -- [keep-ext...]   (base-name from stdin)\n' "$(basename "$0")" >&2
}

if [[ $# -lt 1 ]]; then
    _usage; exit 1
fi

if [[ "$1" == '--' ]]; then
    if [[ -t 0 ]]; then _usage; exit 1; fi
    IFS= read -r base_name
    shift
else
    base_name="$1"
    shift
fi

declare -A _keep=()
for ext in "$@"; do
    _keep["$ext"]=1
done

shopt -s nullglob
files=( "${base_name}".* )

for f in "${files[@]}"; do
    ext="${f#"${base_name}".}"
    if [[ -z "${_keep["$ext"]+_}" ]]; then
        rm -- "$f"
    fi
done

printf '%s\n' "$base_name"
