#!/usr/bin/env bash
# =============================================================================
# hal_basename.sh — generate the next auto-numbered base name for a prefix
#
# Usage:
#   hal_basename.sh -p <prefix>
#
# Prints <prefix><N>, where N is one more than the largest integer among
# existing <prefix>N.* files in the current directory (1 when none exist), so
# repeated runs keep appending without collisions.  An empty prefix yields bare
# numbers (1, 2, …).  Matching is literal on the prefix and only a purely-numeric
# suffix counts, so unrelated files are ignored.
#
# This is the single source of truth for the <prefix><N> naming scheme: rename.sh
# (-p mode) and nahal.sh both call it so the numbering can never drift apart.
#
# Stdout: the new base name.
# =============================================================================
set -euo pipefail

. hal_utils.sh

_usage() {
    printf 'Usage: %s -p <prefix>\n' "$(basename "$0")" >&2
}

if [[ $# -lt 2 || "$1" != "-p" ]]; then
    _usage; exit 1
fi

prefix="$2"

# Next number = (largest N among existing <prefix>N.* files) + 1.
max=0
shopt -s nullglob
for f in *; do
    [[ "$f" == "${prefix}"* ]] || continue
    rest="${f#"$prefix"}"
    num="${rest%%.*}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    (( 10#$num > max )) && max=$(( 10#$num ))
done

printf '%s\n' "${prefix}$(( max + 1 ))"
