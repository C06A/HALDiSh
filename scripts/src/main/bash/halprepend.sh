#!/usr/bin/env bash
# halprepend.sh — HAL_LINK_PLUGIN: prepend HAL_PREPEND_BASE to a link's href
#
# Usage (as a HAL_LINK_PLUGIN):
#   HAL_PREPEND_BASE=https://api.example.com \
#     HAL_LINK_PLUGIN=halprepend.sh \
#     hallink.sh resource.json links self
#
# Reads link JSON from stdin, prepends HAL_PREPEND_BASE to .href, writes JSON
# to stdout.  Only a *relative* href is rewritten — an href that already carries
# a protocol (scheme:) or a domain (protocol-relative //host) is left unchanged.
# HAL_PREPEND_BASE unset or empty: passes link through unchanged.
# Positional args ([resource-file] [path…]) are accepted and ignored.
#
# With '-config' as the first argument, prints a shell snippet that recreates
# this plugin's environment from the current value (an `export HAL_PREPEND_BASE`
# line when set, nothing when unset) and exits 0 without reading stdin.  This is
# the plugin-contract hook nahal.sh records so a session replay can restore the
# environment.
#
# Exit codes:
#   0  success
#   4  required tool not available (jq or yq)
set -euo pipefail

if [[ "${1:-}" == -config ]]; then
    [[ -n "${HAL_PREPEND_BASE:-}" ]] && printf 'export HAL_PREPEND_BASE=%q\n' "$HAL_PREPEND_BASE"
    exit 0
fi

_link=$(cat)

if [[ -z "${HAL_PREPEND_BASE:-}" ]]; then
    printf '%s' "$_link"
    exit 0
fi

# An absolute href already carries a protocol (scheme:) or a domain
# (protocol-relative //host); prepend the base only to a relative href.
_abs_re='^([a-zA-Z][a-zA-Z0-9+.-]*:|//)'

if command -v jq >/dev/null 2>&1 && printf '{}' | jq '.' >/dev/null 2>&1; then
    printf '%s' "$_link" | jq -c --arg b "$HAL_PREPEND_BASE" --arg re "$_abs_re" \
        '.href = (if (.href | test($re)) then .href else ($b + .href) end)'
elif command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
    printf '%s' "$_link" \
        | HALPREPEND_BASE="$HAL_PREPEND_BASE" HALPREPEND_ABS_RE="$_abs_re" \
          yq -o json -I0 '.href = (.href | (select(test(env(HALPREPEND_ABS_RE))) // (env(HALPREPEND_BASE) + .)))'
else
    printf 'halprepend: jq or yq required\n' >&2; exit 4
fi
