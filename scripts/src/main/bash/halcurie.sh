#!/usr/bin/env bash
# halcurie.sh — HAL_LINK_PLUGIN that expands a CURIE-prefixed link href.
#
# Used as a link plugin (set HAL_LINK_PLUGIN=halcurie.sh, alone or colon-joined
# with others).  Follows the project plugin contract:
#   stdin  — the link object JSON
#   args   — <root-resource-file> <hal-path-to-the-link…>
#   stdout — the link object JSON with .href expanded (unchanged when it is not a
#            resolvable CURIE)
#
# With '-config' as the first argument, prints the shell snippet that recreates
# this plugin's environment and exits 0 without reading stdin.  halcurie needs no
# environment, so it emits nothing.
#
# Only a SafeCURIE href is expanded — a CURIE wrapped in square brackets,
# "[<prefix>:<reference>]" with an NCName <prefix> (e.g. "[doc:orders]").  The
# brackets are the W3C SafeCURIE marker that disambiguates a CURIE from a URI that
# merely shares the "<prefix>:…" shape (e.g. "http://host/…"), so a bare,
# unbracketed href is always left unchanged.  The prefix is resolved against the
# FIRST link in a "_links.CURIE" collection whose "name" equals the prefix,
# searched from the resource holding the link upward through the embedded stack to
# the root.  The CURIE link's href is a plain URL (no "{rel}" template); expansion
# replaces the whole "[<prefix>:<reference>]" with that URL followed by the
# reference (the brackets are dropped).
#
# The upward search is done by re-querying the root file with hal.sh, altering
# the path rather than loading sub-resources into memory: the trailing
# "links <rel> …" is replaced with "links CURIE <prefix> href" (an array of
# definitions), falling back to a single CURIE object whose "name" is asserted to
# equal the prefix; each miss drops the last "embeddeds …" segment to step up to
# the parent resource.
#
# Exit codes:
#   0  success (href expanded, or intentionally left unchanged)
#   4  required tool (yq or jq) not available
#   5  link object on stdin is not valid JSON
#
# Requires: yq (mikefarah/yq v4), or jq for JSON; hal.sh on PATH
set -euo pipefail

_HC_TOOL=""

# _hc_init_tool — sets _HC_TOOL to yq or jq, preferring yq; exits 4 if neither.
_hc_init_tool() {
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        _HC_TOOL=yq
    elif command -v jq >/dev/null 2>&1 && printf '{}' | jq '.' >/dev/null 2>&1; then
        _HC_TOOL=jq
    else
        printf 'halcurie: yq or jq required\n' >&2; exit 4
    fi
}

# _hc_get_href <link_json> — prints the .href value (empty string when absent).
_hc_get_href() {
    if [[ "$_HC_TOOL" == yq ]]; then
        printf '%s' "$1" | yq -o json -r '.href // ""'
    else
        printf '%s' "$1" | jq -r '.href // ""'
    fi
}

# _hc_set_href <link_json> <new_href> — prints the link with .href replaced.
_hc_set_href() {
    if [[ "$_HC_TOOL" == yq ]]; then
        printf '%s' "$1" | HC_H="$2" yq -o json -I0 '.href = env(HC_H)'
    else
        printf '%s' "$1" | jq -c --arg h "$2" '.href = $h'
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────

# Plugin-contract '-config' hook: this plugin needs no environment, so it emits
# nothing and exits without reading stdin.  (nahal.sh records each plugin's
# `-config` output so a session replay can recreate the environment.)
if [[ "${1:-}" == -config ]]; then
    exit 0
fi

_link_json=$(cat)

# No resource file to search → nothing to resolve against; pass through.
if [[ -z "${1:-}" ]]; then
    printf '%s' "$_link_json"; exit 0
fi
_file="$1"; shift
_segs=("$@")

_hc_init_tool

if ! _href=$(_hc_get_href "$_link_json"); then
    printf 'halcurie: invalid link JSON on stdin\n' >&2; exit 5
fi

# Not a SafeCURIE href ("[<prefix>:<reference>]") → pass through unchanged.  A bare
# "<prefix>:<reference>" is ambiguous with a URI and is intentionally left as-is.
if [[ -z "$_href" || "$_href" == null || "$_href" != \[*:*\] ]]; then
    printf '%s' "$_link_json"; exit 0
fi
_curie="${_href#\[}"; _curie="${_curie%\]}"   # strip the SafeCURIE brackets
_prefix="${_curie%%:*}"
_reference="${_curie#*:}"
if [[ ! "$_prefix" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; then
    printf '%s' "$_link_json"; exit 0
fi

# Container path = the hal-path with its trailing "links <rel> …" (or "docs …")
# removed, leaving the embedded-stack address of the resource holding the link.
_boundary=-1
for (( _i = ${#_segs[@]} - 1; _i >= 0; _i-- )); do
    if [[ "${_segs[$_i]}" == links || "${_segs[$_i]}" == docs ]]; then
        _boundary=$_i; break
    fi
done
if (( _boundary >= 0 )); then
    _container=("${_segs[@]:0:_boundary}")
else
    _container=("${_segs[@]+"${_segs[@]}"}")
fi

# Walk the embedded stack from the link's resource up to the root, asking hal.sh
# for the "_links.CURIE" definition whose name matches the prefix, then its href.
# A "CURIE" collection may be an array of definitions or a single object:
#   array  — `links CURIE <prefix> href` selects by hal.sh's bare-name match
#   object — bare-name match does not apply, so assert `links CURIE name` equals
#            the prefix, then take `links CURIE href`
_curie_href=""
while :; do
    _cpath=("${_container[@]+"${_container[@]}"}" links CURIE)
    # CURIE array: pick the entry whose "name" is the prefix.
    if _out=$(hal.sh "$_file" "${_cpath[@]}" "${_prefix}" href 2>/dev/null) \
        && [[ -n "$_out" && "$_out" != null ]]; then
        _curie_href="$_out"; break
    fi
    # Single CURIE object: verify its "name" before taking its href.
    if _nm=$(hal.sh "$_file" "${_cpath[@]}" name 2>/dev/null) \
        && [[ "$_nm" == "$_prefix" ]] \
        && _out=$(hal.sh "$_file" "${_cpath[@]}" href 2>/dev/null) \
        && [[ -n "$_out" && "$_out" != null ]]; then
        _curie_href="$_out"; break
    fi
    # Step up: drop the last "embeddeds …" segment.  None left ⇒ we were at root.
    _up=-1
    for (( _i = ${#_container[@]} - 1; _i >= 0; _i-- )); do
        if [[ "${_container[$_i]}" == embeddeds ]]; then _up=$_i; break; fi
    done
    (( _up < 0 )) && break
    _container=("${_container[@]:0:_up}")
done

if [[ -n "$_curie_href" ]]; then
    _hc_set_href "$_link_json" "${_curie_href}${_reference}"
else
    printf '%s' "$_link_json"
fi
