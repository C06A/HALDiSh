#!/usr/bin/env bash
# =============================================================================
# rename.sh — rename a group of files that share a base name across extensions
#
# Usage:
#   rename.sh <new-name> <old-name>
#   rename.sh <new-name>              # old-name read from stdin
#
# Finds all files matching <old-name>.* in the current directory and renames
# them to <new-name>.<same-ext>.
#
# Stdout: new base name (on success)
# =============================================================================
set -euo pipefail

_usage() {
    printf 'Usage: %s <new-name> [old-name]\n' "$(basename "$0")" >&2
    printf '       echo old-name | %s <new-name>\n' "$(basename "$0")" >&2
}

if [[ $# -lt 1 ]]; then
    _usage; exit 1
fi

. hal_utils.sh

new_name="$1"

if [[ $# -ge 2 ]]; then
    old_name="$2"
elif [[ ! -t 0 ]]; then
    IFS= read -r old_name
else
    _usage; exit 1
fi

hal::log::debug "rename \"${old_name}.*\" files into \"${new_name}.*\""

shopt -s nullglob
files=( "${old_name}".* )

if [[ ${#files[@]} -eq 0 ]]; then
    hal::log::warn 'rename: no files found matching: %s.*\n' "$old_name"
    exit 1
fi

for f in "${files[@]}"; do
    ext="${f#"${old_name}".}"
    mv -- "$f" "${new_name}.${ext}"
done

printf '%s\n' "$new_name"
