#!/usr/bin/env bash
# halprepend.sh — prepend a base string to a HAL link object's href
#
# Usage:
#   halprepend.sh <base> --link [<json|xml|yaml>|@<file>]
#   halprepend.sh <base> --link                            (link from stdin)
#   halprepend.sh <base> <file-or-basename> <hal-path>
#
# hal-path: links <rel> [N]
#           embeddeds <rel> [N] links <rel2> [N2]
#
# The href field of the link object is replaced with <base> + <href>.
# All other fields (title, type, templated, …) are preserved unchanged.
# Output format matches input format (JSON → JSON, YAML → YAML, XML → XML).
#
# Exit codes:
#   0  success
#   1  usage / argument error
#   2  file not found
#   3  link not found or invalid (no href)
#   4  required tool not available
#
# Requires: yq (mikefarah/yq v4), or jq for JSON
set -euo pipefail

. hal_utils.sh

_HALPREPEND_TOOL=""
_HALPREPEND_FMT="json"

_halprepend_usage() {
    local name; name="$(basename "$0")"
    printf 'Usage: %s <base> --link [<json>|@<file>]\n' "$name" >&2
    printf '       %s <base> --link                    (link from stdin)\n' "$name" >&2
    printf '       %s <base> <file> <hal-path>\n' "$name" >&2
    printf '\nhal-path: links <rel> [N]\n' >&2
    printf '          embeddeds <rel> [N] links <rel2> [N2]\n' >&2
}

# _halprepend_resolve_file <spec>
# Resolves a file specifier to an existing path. Searches CWD for basenames
# (no path separator) in order: exact, .json, .xml, .yaml, .yml, .body.
# Prints the resolved path to stdout. Exits 2 if not found.
_halprepend_resolve_file() {
    local spec="$1"
    if [[ "$spec" == */* ]]; then
        [[ -f "$spec" ]] || { printf 'halprepend: no such file: %s\n' "$spec" >&2; exit 2; }
        printf '%s' "$spec"; return
    fi
    local ext
    for ext in '' .json .xml .yaml .yml .body; do
        [[ -f "${spec}${ext}" ]] && { printf '%s' "${spec}${ext}"; return; }
    done
    printf 'halprepend: file not found: %s (tried .json .xml .yaml .yml .body)\n' "$spec" >&2
    exit 2
}

# _halprepend_init_tool — sets _HALPREPEND_TOOL. Exits 4 if neither yq nor jq available.
_halprepend_init_tool() {
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        _HALPREPEND_TOOL=yq
    elif command -v jq >/dev/null 2>&1 && printf '{}' | jq '.' >/dev/null 2>&1; then
        _HALPREPEND_TOOL=jq
    else
        printf 'halprepend: yq or jq required\n' >&2; exit 4
    fi
}

# _halprepend_detect_file <path> — sets _HALPREPEND_FMT to json | xml | yaml.
_halprepend_detect_file() {
    local f="$1"
    if command -v jq >/dev/null 2>&1 && jq '.' "$f" >/dev/null 2>&1; then
        _HALPREPEND_FMT=json; return
    fi
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        if yq -p xml '.' "$f" >/dev/null 2>&1; then
            _HALPREPEND_FMT=xml; return
        fi
        _HALPREPEND_FMT=yaml; return
    fi
    local sig
    sig=$(grep -m1 '[^[:space:]]' "$f" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-5)
    case "$sig" in
        '<?xml'|'<'*) _HALPREPEND_FMT=xml  ;;
        '{'*|'['*)    _HALPREPEND_FMT=json ;;
        *)            _HALPREPEND_FMT=yaml ;;
    esac
}

# _halprepend_detect_str <content> — sets _HALPREPEND_FMT to json | xml | yaml.
_halprepend_detect_str() {
    local content="$1"
    if printf '%s' "$content" | jq '.' >/dev/null 2>&1; then
        _HALPREPEND_FMT=json; return
    fi
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        if printf '%s' "$content" | yq -p xml '.' >/dev/null 2>&1; then
            _HALPREPEND_FMT=xml; return
        fi
        _HALPREPEND_FMT=yaml; return
    fi
    local sig
    sig=$(printf '%s' "$content" | grep -m1 '[^[:space:]]' | sed 's/^[[:space:]]*//' | cut -c1-5)
    case "$sig" in
        '<?xml'|'<'*) _HALPREPEND_FMT=xml  ;;
        '{'*|'['*)    _HALPREPEND_FMT=json ;;
        *)            _HALPREPEND_FMT=yaml ;;
    esac
}

# _halprepend_to_json <content> — prints link object as compact JSON.
_halprepend_to_json() {
    local content="$1"
    case "$_HALPREPEND_FMT" in
        json) printf '%s' "$content" ;;
        xml)
            [[ "$_HALPREPEND_TOOL" == yq ]] \
                || { printf 'halprepend: XML input requires yq\n' >&2; exit 4; }
            printf '%s' "$content" | yq -p xml -o json -I0 '.'
            ;;
        yaml)
            [[ "$_HALPREPEND_TOOL" == yq ]] \
                || { printf 'halprepend: YAML input requires yq\n' >&2; exit 4; }
            printf '%s' "$content" | yq -o json -I0 '.'
            ;;
    esac
}

# _halprepend_get_field <json> <field> — prints raw string value or empty string.
_halprepend_get_field() {
    local json="$1" field="$2"
    if [[ "$_HALPREPEND_TOOL" == yq ]]; then
        printf '%s' "$json" | yq -r ".${field} // \"\""
    else
        printf '%s' "$json" | jq -r ".${field} // \"\""
    fi
}

# _halprepend_emit <link_json> — outputs the link in _HALPREPEND_FMT format.
_halprepend_emit() {
    local json="$1"
    case "$_HALPREPEND_FMT" in
        yaml)
            [[ "$_HALPREPEND_TOOL" == yq ]] \
                || { printf 'halprepend: YAML output requires yq\n' >&2; exit 4; }
            printf '%s' "$json" | yq -o yaml -I2 '.'
            ;;
        xml)
            [[ "$_HALPREPEND_TOOL" == yq ]] \
                || { printf 'halprepend: XML output requires yq\n' >&2; exit 4; }
            printf '%s' "$json" | yq -o xml '.'
            ;;
        *)
            printf '%s\n' "$json"
            ;;
    esac
}

# ── main ──────────────────────────────────────────────────────────────────────

[[ $# -lt 2 ]] && { _halprepend_usage; exit 1; }

_base="$1"; shift

_mode=""
_link_src=""
_file=""
_path=()

if [[ "$1" == "--link" ]]; then
    _mode=link
    shift
    if [[ $# -gt 0 && "$1" != -* ]]; then
        _link_src="$1"; shift
    fi
    # If _link_src is empty and stdin is a terminal, error now rather than hanging
    if [[ -z "$_link_src" && -t 0 ]]; then
        printf 'halprepend: --link: no link argument and stdin is a terminal\n' >&2
        exit 1
    fi
else
    _mode=file
    _file="$1"; shift
    _path=("$@")
fi

_halprepend_init_tool

# ── Mode A: --link ─────────────────────────────────────────────────────────────

if [[ "$_mode" == link ]]; then
    _raw=""
    if [[ -n "$_link_src" ]]; then
        if [[ "$_link_src" == @* ]]; then
            _src_file="${_link_src#@}"
            _raw=$(<"$_src_file")
            _halprepend_detect_file "$_src_file"
        else
            _raw="$_link_src"
            _halprepend_detect_str "$_raw"
        fi
    else
        _raw=$(cat)
        _halprepend_detect_str "$_raw"
    fi
    _link_obj=$(_halprepend_to_json "$_raw")

# ── Mode B: file + path ─────────────────────────────────────────────────────────

else
    _file=$(_halprepend_resolve_file "$_file")
    _halprepend_detect_file "$_file"

    if [[ ${#_path[@]} -eq 0 ]]; then
        printf 'halprepend: hal-path required (e.g. links self)\n' >&2; exit 1
    fi

    _hal_err=$(mktemp)
    _link_obj=""
    if ! _link_obj=$(hal.sh "$_file" "${_path[@]}" 2>"$_hal_err"); then
        cat "$_hal_err" >&2
        rm -f "$_hal_err"
        exit 3
    fi
    rm -f "$_hal_err"

    if [[ "$_link_obj" == "null" || -z "$_link_obj" ]]; then
        printf 'halprepend: link not found: %s\n' "${_path[*]}" >&2; exit 3
    fi
fi

# ── Prepend base to href ────────────────────────────────────────────────────────

_href=$(_halprepend_get_field "$_link_obj" "href")
[[ -n "$_href" && "$_href" != "null" ]] \
    || { printf 'halprepend: link object has no href\n' >&2; exit 3; }

_new_href="${_base}${_href}"

if [[ "$_HALPREPEND_TOOL" == yq ]]; then
    _link_obj=$(printf '%s' "$_link_obj" \
        | HALPREPEND_HREF="$_new_href" yq -o json -I0 '.href = env(HALPREPEND_HREF)')
else
    _link_obj=$(printf '%s' "$_link_obj" \
        | jq -c --arg h "$_new_href" '.href = $h')
fi

_halprepend_emit "$_link_obj"
