#!/usr/bin/env bash
# =============================================================================
# rename.sh — rename a group of files that share a base name across extensions
#
# Usage:
#   rename.sh <new-name> [old-name]      # old-name read from stdin if omitted
#   rename.sh -p <prefix> [old-name]     # new-name = <prefix><next number>
#
# In -p mode the new base name is computed by hal_basename.sh -p <prefix>: it is
# <prefix> followed by one more than the largest integer N among existing
# <prefix>N.* files in the current directory (1 when none exist), so repeated
# runs keep appending without collisions.  An empty prefix yields bare numbers
# (1.*, 2.*, …).
#
# Finds all files matching <old-name>.* in the current directory and renames
# them to <new-name>.<same-ext>.
#
# Stdout: new base name (on success)
# =============================================================================
set -euo pipefail

_usage() {
    printf 'Usage: %s <new-name> [old-name]\n' "$(basename "$0")" >&2
    printf '       %s -p <prefix> [old-name]\n' "$(basename "$0")" >&2
    printf '       echo old-name | %s <new-name>|-p <prefix>\n' "$(basename "$0")" >&2
}

if [[ $# -lt 1 ]]; then
    _usage; exit 1
fi

. hal_utils.sh

# Resolve the new base name (explicit, or auto-numbered from a prefix).
new_name=""
if [[ "$1" == "-p" ]]; then
    [[ $# -ge 2 ]] || { _usage; exit 1; }
    prefix="$2"
    shift 2
    # Delegate the <prefix><N> numbering to hal_basename.sh, the single source of
    # truth for that scheme (so this and nahal.sh can never disagree).
    new_name="$(hal_basename.sh -p "$prefix")"
else
    new_name="$1"
    shift
fi

# Resolve the old base name (positional argument or stdin).
if [[ $# -ge 1 ]]; then
    old_name="$1"
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
