#!/usr/bin/env bash
# haldoclink.sh — emit a documentation link for a HAL link relation
#
# Usage:
#   haldoclink.sh <file-or-basename> <hal-path>
#
# hal-path: links <rel>
#           embeddeds <rel> [N] links <rel2>
#
# <rel> may be a full CURIE-prefixed relation (e.g. doc:orders) or just a
# local name (e.g. orders).  Without a prefix the script searches the
# containing resource's _links for a key whose suffix matches.
#
# CURIE lookup walks from the deepest embedded resource up to the root,
# using the first ancestor whose _links.curies defines the required prefix.
#
# Output: {"href":"<doc_url>","type":"text/html"}
# Output format matches input format (JSON → JSON, YAML → YAML, XML → XML).
#
# Exit codes:
#   0  success
#   1  usage / argument error
#   2  file not found
#   3  rel not found, or no CURIE for its prefix anywhere in the resource stack
#   4  required tool not available
#
# Requires: yq (mikefarah/yq v4), or jq for JSON; uritemplate.sh on PATH
set -euo pipefail

. hal_utils.sh

_HALDOCLINK_TOOL=""
_HALDOCLINK_FMT="json"
_HALDOCLINK_REL=""
_HALDOCLINK_STACK=()

_haldoclink_usage() {
    local name; name="$(basename "$0")"
    printf 'Usage: %s <file> <hal-path>\n' "$name" >&2
    printf '\nhal-path: links <rel>\n' >&2
    printf '          embeddeds <rel> [N] links <rel2>\n' >&2
}

# _haldoclink_resolve_file <spec>
_haldoclink_resolve_file() {
    local spec="$1"
    if [[ "$spec" == */* ]]; then
        [[ -f "$spec" ]] || { printf 'haldoclink: no such file: %s\n' "$spec" >&2; exit 2; }
        printf '%s' "$spec"; return
    fi
    local ext
    for ext in '' .json .xml .yaml .yml .body; do
        [[ -f "${spec}${ext}" ]] && { printf '%s' "${spec}${ext}"; return; }
    done
    printf 'haldoclink: file not found: %s (tried .json .xml .yaml .yml .body)\n' "$spec" >&2
    exit 2
}

# _haldoclink_init_tool — sets _HALDOCLINK_TOOL; exits 4 if neither available.
_haldoclink_init_tool() {
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        _HALDOCLINK_TOOL=yq
    elif command -v jq >/dev/null 2>&1 && printf '{}' | jq '.' >/dev/null 2>&1; then
        _HALDOCLINK_TOOL=jq
    else
        printf 'haldoclink: yq or jq required\n' >&2; exit 4
    fi
}

# _haldoclink_detect_file <path> — sets _HALDOCLINK_FMT to json | xml | yaml.
_haldoclink_detect_file() {
    local f="$1"
    if command -v jq >/dev/null 2>&1 && jq '.' "$f" >/dev/null 2>&1; then
        _HALDOCLINK_FMT=json; return
    fi
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        if yq -p xml '.' "$f" >/dev/null 2>&1; then
            _HALDOCLINK_FMT=xml; return
        fi
        _HALDOCLINK_FMT=yaml; return
    fi
    local sig
    sig=$(grep -m1 '[^[:space:]]' "$f" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-5)
    case "$sig" in
        '<?xml'|'<'*) _HALDOCLINK_FMT=xml  ;;
        '{'*|'['*)    _HALDOCLINK_FMT=json ;;
        *)            _HALDOCLINK_FMT=yaml ;;
    esac
}

# _haldoclink_emit <link_json> — prints the link in _HALDOCLINK_FMT format.
_haldoclink_emit() {
    local json="$1"
    case "$_HALDOCLINK_FMT" in
        yaml)
            [[ "$_HALDOCLINK_TOOL" == yq ]] \
                || { printf 'haldoclink: YAML output requires yq\n' >&2; exit 4; }
            printf '%s' "$json" | yq -o yaml -I2 '.'
            ;;
        xml)
            [[ "$_HALDOCLINK_TOOL" == yq ]] \
                || { printf 'haldoclink: XML output requires yq\n' >&2; exit 4; }
            printf '%s' "$json" | yq -o xml '.'
            ;;
        *)
            printf '%s\n' "$json"
            ;;
    esac
}

# ── query helpers ─────────────────────────────────────────────────────────────

_hdq() {
    local json="$1" filter="$2"
    if [[ "$_HALDOCLINK_TOOL" == yq ]]; then
        printf '%s' "$json" | yq -o json -I0 "$filter"
    else
        printf '%s' "$json" | jq -c "$filter"
    fi
}

_hdqr() {
    local json="$1" filter="$2"
    if [[ "$_HALDOCLINK_TOOL" == yq ]]; then
        printf '%s' "$json" | yq -o json -r "$filter"
    else
        printf '%s' "$json" | jq -r "$filter"
    fi
}

_hdqk() {
    local json="$1" key="$2"
    if [[ "$_HALDOCLINK_TOOL" == yq ]]; then
        printf '%s' "$json" | HDQK="$key" yq -o json -I0 '.[env(HDQK)]'
    else
        printf '%s' "$json" | jq -c --arg k "$key" '.[$k]'
    fi
}

_hdqkr() {
    local json="$1" key="$2"
    if [[ "$_HALDOCLINK_TOOL" == yq ]]; then
        printf '%s' "$json" | HDQK="$key" yq -o json -r '.[env(HDQK)]'
    else
        printf '%s' "$json" | jq -r --arg k "$key" '.[$k]'
    fi
}

_hdqi() {
    local json="$1" idx="$2"
    _hdq "$json" ".[$idx]"
}

_hdqtype() {
    local t
    t=$(_hdqr "$1" 'type')
    case "$t" in
        '!!seq')           printf 'array'   ;;
        '!!map')           printf 'object'  ;;
        '!!str')           printf 'string'  ;;
        '!!int'|'!!float') printf 'number'  ;;
        '!!bool')          printf 'boolean' ;;
        '!!null')          printf 'null'    ;;
        *)                 printf '%s' "$t" ;;
    esac
}

# ── CURIE helpers ─────────────────────────────────────────────────────────────

# _haldoclink_resolve_curi_url <links_json> <prefix> <local_name>
# Finds the CURIE for <prefix> in the given _links object and expands its href
# template with rel=<local_name>.  Prints the doc URL.  Returns 1 if not found.
_haldoclink_resolve_curi_url() {
    local links="$1" prefix="$2" local_name="$3"
    local curies_json curi_count i curi_obj curi_name curi_href
    curies_json=$(_hdqk "$links" "curies")
    [[ "$curies_json" == "null" || -z "$curies_json" ]] && return 1
    curi_count=$(_hdqr "$curies_json" 'length')
    for (( i = 0; i < curi_count; i++ )); do
        curi_obj=$(_hdqi "$curies_json" "$i")
        curi_name=$(_hdqkr "$curi_obj" "name")
        if [[ "$curi_name" == "$prefix" ]]; then
            curi_href=$(_hdqkr "$curi_obj" "href")
            uritemplate.sh "$curi_href" "rel=${local_name}"
            return 0
        fi
    done
    return 1
}

# _haldoclink_find_suffixed_rel <links_json> <local_name>
# Returns the first _links key of the form "<prefix>:<local_name>".
# Warns to stderr on ambiguity.  Returns 1 if none found.
_haldoclink_find_suffixed_rel() {
    local links="$1" local_name="$2"
    local -a matches=()
    local rel
    while IFS= read -r rel; do
        if [[ "$rel" == *:"$local_name" ]]; then
            matches+=("$rel")
        fi
    done < <(_hdqr "$links" 'keys[]')
    [[ "${#matches[@]}" -eq 0 ]] && return 1
    if [[ "${#matches[@]}" -gt 1 ]]; then
        printf 'haldoclink: warning: "%s" matches multiple CURIE prefixes (%s) — using %s\n' \
            "$local_name" "${matches[*]}" "${matches[0]}" >&2
    fi
    printf '%s\n' "${matches[0]}"
}

# _haldoclink_build_stack <root_json> [path_segments...]
# Fills _HALDOCLINK_STACK (resource objects root→deepest) and _HALDOCLINK_REL.
_haldoclink_build_stack() {
    local json="$1"; shift
    _HALDOCLINK_STACK=("$json")
    local current="$json"
    local -a segs=("$@")
    local n=${#segs[@]}
    local i=0

    while (( i < n )); do
        local seg="${segs[$i]}"
        case "$seg" in
            embeddeds)
                i=$(( i + 1 ))
                if (( i >= n )); then
                    printf 'haldoclink: embeddeds: rel name expected\n' >&2; exit 1
                fi
                local emb_rel="${segs[$i]}"
                i=$(( i + 1 ))
                local embedded
                embedded=$(_hdqk "$current" "_embedded")
                if [[ "$embedded" == "null" || -z "$embedded" ]]; then
                    printf 'haldoclink: no _embedded in resource\n' >&2; exit 3
                fi
                local item
                item=$(_hdqk "$embedded" "$emb_rel")
                if [[ "$item" == "null" || -z "$item" ]]; then
                    printf 'haldoclink: embedded rel not found: %s\n' "$emb_rel" >&2; exit 3
                fi
                local itype
                itype=$(_hdqtype "$item")
                if [[ "$itype" == "array" ]] && (( i < n )) && [[ "${segs[$i]}" =~ ^[0-9]+$ ]]; then
                    local idx="${segs[$i]}"
                    i=$(( i + 1 ))
                    item=$(_hdqi "$item" "$idx")
                fi
                current="$item"
                _HALDOCLINK_STACK+=("$current")
                ;;
            links)
                i=$(( i + 1 ))
                if (( i >= n )); then
                    printf 'haldoclink: links: rel name expected\n' >&2; exit 1
                fi
                local rel="${segs[$i]}"
                i=$(( i + 1 ))
                if (( i < n )); then
                    printf 'haldoclink: unexpected segment after links %s: %s\n' \
                        "$rel" "${segs[$i]}" >&2; exit 1
                fi
                if [[ "$rel" == *:* ]]; then
                    _HALDOCLINK_REL="$rel"
                else
                    local links_json
                    links_json=$(_hdqk "$current" "_links")
                    if [[ "$links_json" == "null" || -z "$links_json" ]]; then
                        printf 'haldoclink: no _links in resource\n' >&2; exit 3
                    fi
                    local full_rel
                    if ! full_rel=$(_haldoclink_find_suffixed_rel "$links_json" "$rel"); then
                        printf 'haldoclink: no CURIE-prefixed rel with local name: %s\n' \
                            "$rel" >&2; exit 3
                    fi
                    _HALDOCLINK_REL="$full_rel"
                fi
                ;;
            *)
                printf 'haldoclink: unexpected path segment: %s\n' "$seg" >&2; exit 1
                ;;
        esac
    done
}

# _haldoclink_search_curie
# Searches _HALDOCLINK_STACK in reverse for a CURIE matching _HALDOCLINK_REL's prefix.
# Prints the doc URL to stdout.  Exits 3 if not found.
_haldoclink_search_curie() {
    local prefix="${_HALDOCLINK_REL%%:*}"
    local local_name="${_HALDOCLINK_REL#*:}"
    local i
    for (( i = ${#_HALDOCLINK_STACK[@]} - 1; i >= 0; i-- )); do
        local resource="${_HALDOCLINK_STACK[$i]}"
        local links
        links=$(_hdqk "$resource" "_links")
        [[ "$links" == "null" || -z "$links" ]] && continue
        local has_curies
        has_curies=$(_hdqr "$links" 'has("curies")')
        [[ "$has_curies" != "true" ]] && continue
        local doc_url
        if doc_url=$(_haldoclink_resolve_curi_url "$links" "$prefix" "$local_name"); then
            printf '%s\n' "$doc_url"
            return 0
        fi
    done
    printf 'haldoclink: no CURIE found for prefix "%s" in any enclosing resource\n' \
        "$prefix" >&2
    exit 3
}

# ── main ──────────────────────────────────────────────────────────────────────

[[ $# -lt 2 ]] && { _haldoclink_usage; exit 1; }

_file="$1"; shift
_path=("$@")

_haldoclink_init_tool

command -v uritemplate.sh >/dev/null 2>&1 \
    || { printf 'haldoclink: uritemplate.sh not found on PATH\n' >&2; exit 4; }

_file=$(_haldoclink_resolve_file "$_file")
_haldoclink_detect_file "$_file"

if [[ "$_HALDOCLINK_TOOL" == yq ]]; then
    _root_json=$(yq -o json '.' "$_file")
else
    _root_json=$(cat "$_file")
fi

_haldoclink_build_stack "$_root_json" "${_path[@]}"

if [[ -z "$_HALDOCLINK_REL" ]]; then
    printf 'haldoclink: hal-path must end with: links <rel>\n' >&2; exit 1
fi

_doc_url=$(_haldoclink_search_curie)

if [[ "$_HALDOCLINK_TOOL" == yq ]]; then
    _link_json=$(printf '{"href":"","type":"text/html"}' \
        | HALDOCLINK_HREF="$_doc_url" yq -o json -I0 '.href = env(HALDOCLINK_HREF)')
else
    _link_json=$(jq -cn --arg h "$_doc_url" '{"href":$h,"type":"text/html"}')
fi

_haldoclink_emit "$_link_json"
