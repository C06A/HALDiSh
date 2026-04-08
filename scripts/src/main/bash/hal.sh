#!/usr/bin/env bash
# hal.sh — navigate and extract from HAL JSON/YAML/XML documents
#
# Usage:
#   hal.sh <file>                                  interactive
#   hal.sh <file> links [rel [N] [field]]          non-interactive
#   hal.sh <file> embeddeds [rel [N] [args...]]    non-interactive
#   hal.sh <file> properties [key [args...]]       non-interactive
#
# Requires: yq (mikefarah/yq v4), or jq for JSON files
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATH="${_SCRIPT_DIR}:${PATH}"
source "${_SCRIPT_DIR}/env.sh" 2>/dev/null || true

_HAL_TOOL=""
_HAL_FORMAT=""

# _detect_format — probe file content with available parsers; no extension or
# filename heuristics.  Sets _HAL_FORMAT to: json | xml | yaml | unknown.
_detect_format() {
    # jq '.' is the definitive JSON validator: parses the whole document.
    if command -v jq >/dev/null 2>&1 && jq '.' "$_hal_file" >/dev/null 2>&1; then
        _HAL_FORMAT=json; return
    fi
    # Only trust yq format probes if yq is actually functional.
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        # Force the XML parser; JSON is not valid XML so this correctly excludes it.
        if yq -p xml '.' "$_hal_file" >/dev/null 2>&1; then
            _HAL_FORMAT=xml; return
        fi
        # XML probe failed → YAML (yq parses JSON-as-YAML too, but jq caught that above).
        _HAL_FORMAT=yaml; return
    fi
    # No functional tool available — find the first non-whitespace token in the file
    # and match it against unambiguous multi-character format signatures.
    local _sig
    _sig=$(grep -m1 '[^[:space:]]' "$_hal_file" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-5)
    case "$_sig" in
        '<?xml'|'<'*)  _HAL_FORMAT=xml  ;;
        '{'*|'['*)     _HAL_FORMAT=json ;;  # jq unavailable; file looks like JSON
        *)             _HAL_FORMAT=yaml ;;
    esac
}

_init_tool() {
    _detect_format
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        _HAL_TOOL=yq
    elif [[ "$_HAL_FORMAT" == json ]] && command -v jq >/dev/null 2>&1; then
        _HAL_TOOL=jq
    else
        if [[ "$_HAL_FORMAT" == xml || "$_HAL_FORMAT" == yaml ]]; then
            printf 'hal: %s file requires yq\n' "$_HAL_FORMAT" >&2
        else
            printf 'hal: yq required (or jq for JSON files)\n' >&2
        fi
        exit 1
    fi
}

# _q <json> <filter>  → compact/JSON output
_q() {
    local json="$1" filter="$2"
    if [[ "$_HAL_TOOL" == yq ]]; then
        printf '%s' "$json" | yq -o json -I0 "$filter"
    else
        printf '%s' "$json" | jq -c "$filter"
    fi
}

# _qr <json> <filter>  → raw scalar output (no quotes)
_qr() {
    local json="$1" filter="$2"
    if [[ "$_HAL_TOOL" == yq ]]; then
        printf '%s' "$json" | yq -o json -r "$filter"
    else
        printf '%s' "$json" | jq -r "$filter"
    fi
}

# _qk <json> <key>  → get object value by key variable
_qk() {
    local json="$1" key="$2"
    if [[ "$_HAL_TOOL" == yq ]]; then
        printf '%s' "$json" | HAL_K="$key" yq -o json -I0 '.[env(HAL_K)]'
    else
        printf '%s' "$json" | jq -c --arg k "$key" '.[$k]'
    fi
}

# _qkr <json> <key>  → raw scalar by key variable
_qkr() {
    local json="$1" key="$2"
    if [[ "$_HAL_TOOL" == yq ]]; then
        printf '%s' "$json" | HAL_K="$key" yq -o json -r '.[env(HAL_K)]'
    else
        printf '%s' "$json" | jq -r --arg k "$key" '.[$k]'
    fi
}

# _qtype <json>  → normalized type: array | object | string | number | boolean | null
# yq returns YAML type tags (!!seq, !!map, …); this normalises them to jq names.
_qtype() {
    local t
    t=$(_qr "$1" 'type')
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

# _qi <json> <N>  → get array element by integer index
_qi() {
    local json="$1" idx="$2"
    _q "$json" ".[$idx]"
}

_usage() {
    printf 'Usage: %s <file> [links|embeddeds|properties [...]]\n' "$(basename "$0")" >&2
}

# ── non-interactive traversal ─────────────────────────────────────────────────

# _traverse_link <link_json> [field]
_traverse_link() {
    local link="$1"; shift
    if [[ $# -gt 0 ]]; then
        local field="$1"
        shift
        link=$(_qkr "$link" "$field")
        if [[ $# -gt 0 ]]; then
            field="$1"
            shift
            link=$(_qkr "$link" "$field")
        fi
    fi

    printf '%s\n' "$link"
}

# _traverse_value <val_json> [args...]
_traverse_value() {
    local val="$1"; shift
    if [[ $# -eq 0 ]]; then
        local vtype
        vtype=$(_qtype "$val")
        if [[ "$vtype" == "string" ]]; then
            _qr "$val" '.'
        else
            printf '%s\n' "$val"
        fi
        return
    fi
    local arg="$1"; shift
    local vtype
    vtype=$(_qtype "$val")
    if [[ "$vtype" == "array" ]]; then
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            local elem
            elem=$(_qi "$val" "$arg")
            _traverse_value "$elem" "$@"
        else
            printf 'hal: expected array index, got: %s\n' "$arg" >&2; exit 1
        fi
    elif [[ "$vtype" == "object" ]]; then
        local sub
        sub=$(_qk "$val" "$arg")
        _traverse_value "$sub" "$@"
    else
        printf 'hal: cannot traverse into %s\n' "$vtype" >&2; exit 1
    fi
}

# _traverse <json> [args...]
_traverse() {
    local json="$1"; shift

    if [[ $# -eq 0 ]]; then
        printf '%s\n' "$json"
        return
    fi

    local cmd="$1"; shift
    local jtype
    jtype=$(_qtype "$json")

    # Top-level array: first arg must be an index
    if [[ "$jtype" == "array" && "$cmd" =~ ^[0-9]+$ ]]; then
        local elem
        elem=$(_qi "$json" "$cmd")
        _traverse "$elem" "$@"
        return
    fi

    case "$cmd" in
        links)
            local links
            links=$(_qk "$json" "_links")
            if [[ $# -eq 0 ]]; then
                _qr "$links" 'keys[]'
                return
            fi
            local rel="$1"; shift
            local link
            link=$(_qk "$links" "$rel")
            local ltype
            ltype=$(_qtype "$link")
            if [[ "$ltype" == "array" ]]; then
                if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                    local idx="$1"; shift
                    link=$(_qi "$link" "$idx")
                fi
            fi
            _traverse_link "$link" "$@"
            ;;
        embeddeds)
            local embedded
            embedded=$(_qk "$json" "_embedded")
            if [[ $# -eq 0 ]]; then
                _qr "$embedded" 'keys[]'
                return
            fi
            local rel="$1"; shift
            local item
            item=$(_qk "$embedded" "$rel")
            local itype
            itype=$(_qtype "$item")
            if [[ "$itype" == "array" ]]; then
                if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                    local idx="$1"; shift
                    item=$(_qi "$item" "$idx")
                fi
            fi
            _traverse "$item" "$@"
            ;;
        properties)
            local props
            props=$(_q "$json" 'del(._links,._embedded)')
            if [[ $# -eq 0 ]]; then
                _qr "$props" 'keys[]'
                return
            fi
            local key="$1"; shift
            local val
            val=$(_qk "$props" "$key")
            _traverse_value "$val" "$@"
            ;;
        *)
            printf 'hal: unknown command: %s\n' "$cmd" >&2; exit 1
            ;;
    esac
}

# ── interactive helpers ───────────────────────────────────────────────────────

_show_path() {
    printf '\n[ %s ]\n' "$1" >&2
}

# _to_jpath <nav-path>  → jq/yq filter expression
# nav-path is "<file> [segment ...]" where segments are HAL navigation words.
# Conversion rules:
#   links      → ._links
#   embeddeds  → ._embedded
#   properties → (skip — property keys live at root level)
#   <number>   → [N]
#   <key>      → .key
_to_jpath() {
    local path_str="$1"
    # Strip the leading filename token (everything up to the first space).
    [[ "$path_str" != *' '* ]] && { printf '.'; return; }
    local rest="${path_str#* }"
    local jpath="" seg
    for seg in $rest; do
        case "$seg" in
            links)      jpath="${jpath}._links"    ;;
            embeddeds)  jpath="${jpath}._embedded" ;;
            properties) ;;
            *)
                if [[ "$seg" =~ ^[0-9]+$ ]]; then
                    jpath="${jpath}[${seg}]"
                else
                    jpath="${jpath}.${seg}"
                fi
                ;;
        esac
    done
    printf '%s' "${jpath:-.}"
}

# _read_index <count>  → prints chosen index, 'r', or 'q'
_read_index() {
    local count="$1"
    local max=$(( count - 1 ))
    local input
    while true; do
        printf 'Index [0-%d] (r=return, q=quit): ' "$max" >&2
        IFS= read -r input <&3
        if [[ "$input" == "r" || "$input" == "q" ]]; then
            printf '%s' "$input"
            return
        fi
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 0 && input <= max )); then
            printf '%s' "$input"
            return
        fi
        printf 'Invalid: "%s"\n' "$input" >&2
    done
}

# _interactive_value <val_json> <path> <is_top>
_interactive_value() {
    local val="$1" path="$2" is_top="$3"
    local vtype
    vtype=$(_qtype "$val")

    if [[ "$vtype" == "array" ]]; then
        local count
        count=$(_qr "$val" 'length')
        while true; do
            _show_path "$path"
            local idx
            idx=$(_read_index "$count")
            [[ "$idx" == "q" ]] && { _to_jpath "$path"; printf '\n'; exit 0; }
            [[ "$idx" == "r" ]] && return 0
            local elem
            elem=$(_qi "$val" "$idx")
            _interactive_value "$elem" "$path $idx" "$is_top"
        done
    elif [[ "$vtype" == "object" ]]; then
        local keys
        keys=$(_qr "$val" 'keys[]')
        while true; do
            _show_path "$path"
            local opts=()
            while IFS= read -r k; do opts+=("$k"); done <<< "$keys"
            opts+=("print" "return")
            [[ "$is_top" == "1" ]] && opts+=("quit")
            local chosen
            chosen=$(printf '%s\n' "${opts[@]}" | bash menu.sh "Value")
            case "$chosen" in
                print)  printf '%s\n' "$val"; ;;
                return) return 0 ;;
                quit)   _to_jpath "$path"; printf '\n'; exit 0 ;;
                *)
                    local sub
                    sub=$(_qk "$val" "$chosen")
                    _interactive_value "$sub" "$path $chosen" "$is_top"
                    ;;
            esac
        done
    else
        # primitive
        _qr "$val" '.'
    fi
}

# _interactive_link_detail <link_json> <path> <is_top>
_interactive_link_detail() {
    local link="$1" path="$2" is_top="$3"
    local fields
    fields=$(_qr "$link" 'keys[]')
    while true; do
        _show_path "$path"
        local opts=()
        while IFS= read -r f; do opts+=("$f"); done <<< "$fields"
        opts+=("print" "return" "quit")
        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | bash menu.sh "Link field")
        case "$chosen" in
            print)  printf '%s\n' "$link" ;;
            return) return 0 ;;
            quit)   _to_jpath "$path"; printf '\n'; exit 0 ;;
            *)
                local ftype fval
                fval=$(_qk "$link" "$chosen")
                ftype=$(_qtype "$fval")
                if [[ "$ftype" == "string" || "$ftype" == "number" || "$ftype" == "boolean" ]]; then
                    _qkr "$link" "$chosen"
                else
                    _interactive_value "$fval" "$path $chosen" "$is_top"
                fi
                ;;
        esac
    done
}

# _interactive_links <json> <path> <is_top>
_interactive_links() {
    local json="$1" path="$2" is_top="$3"
    local links
    links=$(_qk "$json" "_links")
    local rels
    rels=$(_qr "$links" 'keys[]')
    while true; do
        _show_path "$path links"
        local opts=()
        while IFS= read -r rel; do
            local lobj ltype templated suffix
            lobj=$(_qk "$links" "$rel")
            ltype=$(_qtype "$lobj")
            if [[ "$ltype" == "array" ]]; then
                templated=$(_qr "$lobj" '.[0].templated // false')
            else
                templated=$(_qr "$lobj" '.templated // false')
            fi
            suffix=""
            [[ "$templated" == "true" ]] && suffix=" {T}"
            opts+=("${rel}${suffix}")
        done <<< "$rels"
        opts+=("return")
        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | bash menu.sh "Link rel")
        [[ "$chosen" == "return" ]] && return 0
        # strip suffix
        local rel="${chosen% \{T\}}"
        local lobj ltype
        lobj=$(_qk "$links" "$rel")
        ltype=$(_qtype "$lobj")
        if [[ "$ltype" == "array" ]]; then
            local count
            count=$(_qr "$lobj" 'length')
            _show_path "$path links $rel"
            local idx
            idx=$(_read_index "$count")
            [[ "$idx" == "q" ]] && { _to_jpath "$path links $rel"; printf '\n'; exit 0; }
            [[ "$idx" == "r" ]] && continue
            lobj=$(_qi "$lobj" "$idx")
            _interactive_link_detail "$lobj" "$path links $rel $idx" "$is_top"
        else
            _interactive_link_detail "$lobj" "$path links $rel" "$is_top"
        fi
    done
}

# _interactive_embeddeds <json> <path> <is_top>
_interactive_embeddeds() {
    local json="$1" path="$2" is_top="$3"
    local embedded
    embedded=$(_qk "$json" "_embedded")
    local rels
    rels=$(_qr "$embedded" 'keys[]')
    while true; do
        _show_path "$path embeddeds"
        local opts=()
        while IFS= read -r rel; do opts+=("$rel"); done <<< "$rels"
        opts+=("return")
        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | bash menu.sh "Embedded rel")
        [[ "$chosen" == "return" ]] && return 0
        local item itype
        item=$(_qk "$embedded" "$chosen")
        itype=$(_qtype "$item")
        if [[ "$itype" == "array" ]]; then
            local count
            count=$(_qr "$item" 'length')
            _show_path "$path embeddeds $chosen"
            local idx
            idx=$(_read_index "$count")
            [[ "$idx" == "q" ]] && { _to_jpath "$path embeddeds $chosen"; printf '\n'; exit 0; }
            [[ "$idx" == "r" ]] && continue
            item=$(_qi "$item" "$idx")
            _interactive_resource "$item" "$path embeddeds $chosen $idx" "0"
        else
            _interactive_resource "$item" "$path embeddeds $chosen" "0"
        fi
    done
}

# _interactive_properties <json> <path> <is_top>
_interactive_properties() {
    local json="$1" path="$2" is_top="$3"
    local props
    props=$(_q "$json" 'del(._links,._embedded)')
    local keys
    keys=$(_qr "$props" 'keys[]')
    while true; do
        _show_path "$path properties"
        local opts=()
        while IFS= read -r k; do opts+=("$k"); done <<< "$keys"
        opts+=("return" "quit")
        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | bash menu.sh "Property")
        [[ "$chosen" == "return" ]] && return 0
        [[ "$chosen" == "quit"   ]] && { _to_jpath "$path properties"; printf '\n'; exit 0; }
        local val vtype
        val=$(_qk "$props" "$chosen")
        vtype=$(_qtype "$val")
        if [[ "$vtype" == "string" || "$vtype" == "number" || "$vtype" == "boolean" ]]; then
            _qkr "$props" "$chosen"
        else
            _interactive_value "$val" "$path properties $chosen" "$is_top"
        fi
    done
}

# _interactive_resource <json> <path> <is_top>
_interactive_resource() {
    local json="$1" path="$2" is_top="$3"
    local has_links has_embedded has_props
    has_links=$(_qr "$json" 'has("_links")')
    has_embedded=$(_qr "$json" 'has("_embedded")')
    has_props=$(_qr "$json" 'del(._links,._embedded) | length > 0')

    while true; do
        _show_path "$path"
        local opts=()
        [[ "$has_links"    == "true" ]] && opts+=("links")
        [[ "$has_embedded" == "true" ]] && opts+=("embeddeds")
        [[ "$has_props"    == "true" ]] && opts+=("properties")
        opts+=("print")
        if [[ "$is_top" == "1" ]]; then
            opts+=("exit")
        else
            opts+=("return" "quit")
        fi
        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | bash menu.sh "Resource")
        case "$chosen" in
            links)      _interactive_links      "$json" "$path" "$is_top" ;;
            embeddeds)  _interactive_embeddeds  "$json" "$path" "$is_top" ;;
            properties) _interactive_properties "$json" "$path" "$is_top" ;;
            print)      printf '%s\n' "$json" ;;
            exit)       exit 0 ;;
            return)     return 0 ;;
            quit)       _to_jpath "$path"; printf '\n'; exit 0 ;;
        esac
    done
}

# ── main ──────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { _usage; exit 1; }
_hal_file="$1"; shift
[[ ! -f "$_hal_file" ]] && { printf 'hal: no such file: %s\n' "$_hal_file" >&2; exit 1; }

_init_tool
if [[ "$_HAL_TOOL" == yq ]]; then
    _hal_json=$(yq -o json '.' "$_hal_file")
else
    _hal_json=$(cat "$_hal_file")
fi

if [[ $# -eq 0 ]]; then
    exec 3< "${_MENU_TTY:-/dev/tty}"
    _jtype=$(_qtype "$_hal_json")
    if [[ "$_jtype" == "array" ]]; then
        count=$(_qr "$_hal_json" 'length')
        while true; do
            _show_path "$_hal_file"
            idx=$(_read_index "$count")
            [[ "$idx" == "q" ]] && exit 0
            [[ "$idx" == "r" ]] && exit 0
            elem=$(_qi "$_hal_json" "$idx")
            _interactive_resource "$elem" "$_hal_file $idx" "1"
        done
    else
        _interactive_resource "$_hal_json" "$_hal_file" "1"
    fi
else
    _traverse "$_hal_json" "$@"
fi
