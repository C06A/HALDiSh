#!/usr/bin/env bash
# hallink.sh — resolve a HAL link object's href, expanding URI templates
#
# Usage:
#   hallink.sh --link [<json|xml|yaml>|@<file>] [var=value ...]
#   hallink.sh --link                            [var=value ...]   (link from stdin)
#   hallink.sh <file-or-basename> <hal-path> [var=value ...]
#
# hal-path: links <rel> [N]
#           embeddeds <rel> [N] links <rel2> [N2]
#
# Var bindings are distinguished from path segments by the presence of '=':
#   name=value   plain string
#   name[]=value list append
#   name[k]=v    map entry
#
# Exit codes:
#   0  success
#   1  usage / argument error
#   2  file not found
#   3  link not found or invalid (no href)
#   4  required tool not available
#
# Requires: yq (mikefarah/yq v4), or jq for JSON; uritemplate.sh on PATH
set -euo pipefail

. hal_utils.sh

_HALLINK_TOOL=""
_HALLINK_FMT="json"

_hallink_usage() {
    local name; name="$(basename "$0")"
    printf 'Usage: %s --link [<json>|@<file>] [var=val ...]\n' "$name" >&2
    printf '       %s --link [var=val ...]              (link from stdin)\n' "$name" >&2
    printf '       %s <file> <hal-path> [var=val ...]\n' "$name" >&2
    printf '\nhal-path: links <rel> [N]\n' >&2
    printf '          embeddeds <rel> [N] links <rel2> [N2]\n' >&2
}

# _hallink_resolve_file <spec>
# Resolves a file specifier to an existing path. Searches CWD for basenames
# (no path separator) in order: exact, .json, .xml, .yaml, .yml, .body.
# Prints the resolved path to stdout. Exits 2 if not found.
_hallink_resolve_file() {
    local spec="$1"
    if [[ "$spec" == */* ]]; then
        [[ -f "$spec" ]] || { printf 'hallink: no such file: %s\n' "$spec" >&2; exit 2; }
        printf '%s' "$spec"; return
    fi
    local ext
    for ext in '' .json .xml .yaml .yml .body; do
        [[ -f "${spec}${ext}" ]] && { printf '%s' "${spec}${ext}"; return; }
    done
    printf 'hallink: file not found: %s (tried .json .xml .yaml .yml .body)\n' "$spec" >&2
    exit 2
}

# _hallink_init_tool — sets _HALLINK_TOOL. Exits 4 if neither yq nor jq available.
_hallink_init_tool() {
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        _HALLINK_TOOL=yq
    elif command -v jq >/dev/null 2>&1 && printf '{}' | jq '.' >/dev/null 2>&1; then
        _HALLINK_TOOL=jq
    else
        printf 'hallink: yq or jq required\n' >&2; exit 4
    fi
}

# _hallink_detect_file <path> — sets _HALLINK_FMT to json | xml | yaml.
_hallink_detect_file() {
    local f="$1"
    if command -v jq >/dev/null 2>&1 && jq '.' "$f" >/dev/null 2>&1; then
        _HALLINK_FMT=json; return
    fi
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        if yq -p xml '.' "$f" >/dev/null 2>&1; then
            _HALLINK_FMT=xml; return
        fi
        _HALLINK_FMT=yaml; return
    fi
    local sig
    sig=$(grep -m1 '[^[:space:]]' "$f" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-5)
    case "$sig" in
        '<?xml'|'<'*) _HALLINK_FMT=xml  ;;
        '{'*|'['*)    _HALLINK_FMT=json ;;
        *)            _HALLINK_FMT=yaml ;;
    esac
}

# _hallink_detect_str <content> — sets _HALLINK_FMT to json | xml | yaml.
_hallink_detect_str() {
    local content="$1"
    if printf '%s' "$content" | jq '.' >/dev/null 2>&1; then
        _HALLINK_FMT=json; return
    fi
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        if printf '%s' "$content" | yq -p xml '.' >/dev/null 2>&1; then
            _HALLINK_FMT=xml; return
        fi
        _HALLINK_FMT=yaml; return
    fi
    local sig
    sig=$(printf '%s' "$content" | grep -m1 '[^[:space:]]' | sed 's/^[[:space:]]*//' | cut -c1-5)
    case "$sig" in
        '<?xml'|'<'*) _HALLINK_FMT=xml  ;;
        '{'*|'['*)    _HALLINK_FMT=json ;;
        *)            _HALLINK_FMT=yaml ;;
    esac
}

# _hallink_to_json <content> — prints link object as compact JSON.
_hallink_to_json() {
    local content="$1"
    case "$_HALLINK_FMT" in
        json) printf '%s' "$content" ;;
        xml)
            [[ "$_HALLINK_TOOL" == yq ]] \
                || { printf 'hallink: XML input requires yq\n' >&2; exit 4; }
            printf '%s' "$content" | yq -p xml -o json -I0 '.'
            ;;
        yaml)
            [[ "$_HALLINK_TOOL" == yq ]] \
                || { printf 'hallink: YAML input requires yq\n' >&2; exit 4; }
            printf '%s' "$content" | yq -o json -I0 '.'
            ;;
    esac
}

# _hallink_get_field <json> <field> — prints raw string value or empty string.
_hallink_get_field() {
    local json="$1" field="$2"
    if [[ "$_HALLINK_TOOL" == yq ]]; then
        printf '%s' "$json" | yq -r ".${field} // \"\""
    else
        printf '%s' "$json" | jq -r ".${field} // \"\""
    fi
}

# _hallink_emit <link_json> — outputs the link in _HALLINK_FMT format.
_hallink_emit() {
    local json="$1"
    case "$_HALLINK_FMT" in
        yaml)
            [[ "$_HALLINK_TOOL" == yq ]] \
                || { printf 'hallink: YAML output requires yq\n' >&2; exit 4; }
            printf '%s' "$json" | yq -o yaml -I2 '.'
            ;;
        xml)
            [[ "$_HALLINK_TOOL" == yq ]] \
                || { printf 'hallink: XML output requires yq\n' >&2; exit 4; }
            printf '%s' "$json" | yq -o xml '.'
            ;;
        *)
            printf '%s\n' "$json"
            ;;
    esac
}

# ── main ──────────────────────────────────────────────────────────────────────

[[ $# -eq 0 ]] && { _hallink_usage; exit 1; }

_mode=""
_link_src=""
_file=""
_path=()
_bindings=()

if [[ "$1" == "--link" ]]; then
    _mode=link
    shift
    # Consume next arg as link source only if it looks like a link:
    # starts with { [ < @ (JSON/XML/file-ref), or is plain text without '='
    # (bare YAML). An arg containing '=' is a var binding, not a link.
    if [[ $# -gt 0 && "$1" != -* ]]; then
        case "$1" in
            '{'*|'['*|'<'*|@*) _link_src="$1"; shift ;;
            *=*) : ;;   # var binding — don't consume
            *) _link_src="$1"; shift ;;
        esac
    fi
    _bindings=("$@")
else
    _mode=file
    _file="$1"; shift
    for _arg in "$@"; do
        [[ "$_arg" == *=* ]] && _bindings+=("$_arg") || _path+=("$_arg")
    done
fi

_hallink_init_tool

# ── Mode A: --link ─────────────────────────────────────────────────────────────

if [[ "$_mode" == link ]]; then
    _raw=""
    if [[ -n "$_link_src" ]]; then
        if [[ "$_link_src" == @* ]]; then
            _src_file="${_link_src#@}"
            _raw=$(<"$_src_file")
            _hallink_detect_file "$_src_file"
        else
            _raw="$_link_src"
            _hallink_detect_str "$_raw"
        fi
    else
        if [[ -t 0 ]]; then
            printf 'hallink: --link: no link argument and stdin is a terminal\n' >&2; exit 1
        fi
        _raw=$(cat)
        _hallink_detect_str "$_raw"
    fi
    _link_obj=$(_hallink_to_json "$_raw")
    _link_obj=$(_hal_run_plugins "$_link_obj") || exit 3

# ── Mode B: file + path ─────────────────────────────────────────────────────────

else
    _file=$(_hallink_resolve_file "$_file")
    _hallink_detect_file "$_file"

    if [[ ${#_path[@]} -eq 0 ]]; then
        printf 'hallink: hal-path required (e.g. links self)\n' >&2; exit 1
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
        printf 'hallink: link not found: %s\n' "${_path[*]}" >&2; exit 3
    fi
    _link_obj=$(_hal_run_plugins "$_link_obj" "$_file" "${_path[@]}") || exit 3
fi

# ── Expand href ────────────────────────────────────────────────────────────────

_href=$(_hallink_get_field "$_link_obj" "href")
[[ -n "$_href" && "$_href" != "null" ]] \
    || { printf 'hallink: link object has no href\n' >&2; exit 3; }

_templated=$(_hallink_get_field "$_link_obj" "templated")
_was_templated=false

if [[ "$_templated" == true ]]; then
    command -v uritemplate.sh >/dev/null 2>&1 \
        || { printf 'hallink: uritemplate.sh not found on PATH\n' >&2; exit 4; }
    _href=$(uritemplate.sh "$_href" ${_bindings[@]+"${_bindings[@]}"})
    _was_templated=true
fi

# ── Update link object ─────────────────────────────────────────────────────────

if [[ "$_was_templated" == true ]]; then
    if [[ "$_HALLINK_TOOL" == yq ]]; then
        _link_obj=$(printf '%s' "$_link_obj" \
            | HALLINK_HREF="$_href" yq -o json -I0 '.href = env(HALLINK_HREF) | del(.templated)')
    else
        _link_obj=$(printf '%s' "$_link_obj" \
            | jq -c --arg h "$_href" '.href = $h | del(.templated)')
    fi
else
    if [[ "$_HALLINK_TOOL" == yq ]]; then
        _link_obj=$(printf '%s' "$_link_obj" \
            | HALLINK_HREF="$_href" yq -o json -I0 '.href = env(HALLINK_HREF)')
    else
        _link_obj=$(printf '%s' "$_link_obj" \
            | jq -c --arg h "$_href" '.href = $h')
    fi
fi

_hallink_emit "$_link_obj"
