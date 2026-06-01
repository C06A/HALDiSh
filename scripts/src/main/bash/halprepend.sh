#!/usr/bin/env bash
# halprepend.sh — HAL_LINK_PLUGIN: prepend HAL_PREPEND_BASE to a link's href
#
# Usage (as a HAL_LINK_PLUGIN):
#   HAL_PREPEND_BASE=https://api.example.com \
#     HAL_LINK_PLUGIN=halprepend.sh \
#     hallink.sh resource.json links self
#
# Reads link JSON from stdin, prepends HAL_PREPEND_BASE to .href, writes JSON
# to stdout.  HAL_PREPEND_BASE unset or empty: passes link through unchanged.
# Positional args ([resource-file] [path…]) are accepted and ignored.
#
# Exit codes:
#   0  success
#   4  required tool not available (jq or yq)
set -euo pipefail

_link=$(cat)

if [[ -z "${HAL_PREPEND_BASE:-}" ]]; then
    printf '%s' "$_link"
    exit 0
fi

if command -v jq >/dev/null 2>&1 && printf '{}' | jq '.' >/dev/null 2>&1; then
    printf '%s' "$_link" | jq -c --arg b "$HAL_PREPEND_BASE" '.href = ($b + .href)'
elif command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
    printf '%s' "$_link" \
        | HALPREPEND_BASE="$HAL_PREPEND_BASE" yq -o json -I0 '.href = env(HALPREPEND_BASE) + .href'
else
    printf 'halprepend: jq or yq required\n' >&2; exit 4
fi
