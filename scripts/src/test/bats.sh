#!/usr/bin/env bash
# bats.sh — run one or more BATS test files by name
#
# Usage:
#   bats.sh <file> [file...]
#
# File names may be given with or without the .bats extension.
# Relative names are resolved from the bats/ sub-directory next to this script.
#
# Sets SCRIPTS_DIR and prepends it to PATH so that the scripts under test can
# invoke their siblings (menu.sh, uritemplate.sh, …) by simple name.

set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCRIPTS_DIR="$(cd "${_SELF_DIR}/../main/bash" && pwd)"
_BATS_EXE="${_SELF_DIR}/../../build/bats/bin/bats"
_BATS_DIR="${_SELF_DIR}/bats"

if [[ $# -eq 0 ]]; then
    printf 'Usage: %s <test-file> [test-file...]\n' "$(basename "$0")" >&2
    exit 1
fi

if [[ ! -x "$_BATS_EXE" ]]; then
    printf 'error: bats not found at %s\n' "$_BATS_EXE" >&2
    printf '       run: ./gradlew :scripts:installBats\n' >&2
    exit 1
fi

_files=()
for _arg in "$@"; do
    _f="$_arg"
    [[ "$_f" != *.bats ]] && _f="${_f}.bats"
    [[ "$_f" != /* ]]     && _f="${_BATS_DIR}/${_f}"
    if [[ ! -f "$_f" ]]; then
        printf 'error: not found: %s\n' "$_f" >&2
        exit 1
    fi
    _files+=("$_f")
done

export SCRIPTS_DIR="$_SCRIPTS_DIR"
export PATH="${_SCRIPTS_DIR}:${PATH}"

exec "$_BATS_EXE" "${_files[@]}"
