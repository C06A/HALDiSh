#!/usr/bin/env bash
# =============================================================================
# uritemplate.sh — RFC 6570 URI Template expansion
#
# Usage:
#   uritemplate.sh <template> [var_binding...]
#
# Variable binding syntax:
#   name=value        → string variable; repeat the flag to build a list
#   name[]=value      → list append (preferred for lists)
#   name[field]=value → map entry
#
# Prints the expanded URI to stdout.
# Undefined variables are silently omitted from the expansion.
# Requires bash 4.0+ (associative arrays).
#
# Examples:
#   uritemplate.sh 'http://example.com/{path}' 'path=index'
#   uritemplate.sh '{/list*}' 'list=a' 'list=b' 'list=c'
#   uritemplate.sh '{?q,lang}' 'q=hello world' 'lang=en'
# =============================================================================
set -euo pipefail

# ── Variable store ────────────────────────────────────────────────────────────
# _HAL_URI_VARS stores all variable values:
#   key        → string value
#   key[N]     → list element at index N
#   key[field] → map entry for named field
declare -A _HAL_URI_VARS=()
# _HAL_URI_TYPES records the type of each variable name
declare -A _HAL_URI_TYPES=()
# _HAL_URI_LIST_CNT tracks the next list index per variable name (O(1) append)
declare -A _HAL_URI_LIST_CNT=()
# _HAL_URI_PARTS accumulates expanded items within a single expression
declare -a _HAL_URI_PARTS=()

# ── Operator metadata tables ──────────────────────────────────────────────────
# Bash does not allow empty string as an associative array key, so the default
# operator (no operator character) is stored under the key '0'.
# _hal_uri_expand_expression normalises op='' to op_key='0' before lookups.

# Prefix prepended to the whole expression result when any part was produced
declare -A _HAL_URI_OP_PREFIX=()
_HAL_URI_OP_PREFIX['0']='' ; _HAL_URI_OP_PREFIX['+']=''
_HAL_URI_OP_PREFIX['#']='#'; _HAL_URI_OP_PREFIX['.']='.'
_HAL_URI_OP_PREFIX['/']='/'; _HAL_URI_OP_PREFIX[';']=';'
_HAL_URI_OP_PREFIX['?']='?' ; _HAL_URI_OP_PREFIX['&']='&'

# Item separator between expanded variable values within one expression
declare -A _HAL_URI_OP_SEP=()
_HAL_URI_OP_SEP['0']=','  ; _HAL_URI_OP_SEP['+']=','
_HAL_URI_OP_SEP['#']=','  ; _HAL_URI_OP_SEP['.']='.'
_HAL_URI_OP_SEP['/']='/'  ; _HAL_URI_OP_SEP[';']=';'
_HAL_URI_OP_SEP['?']='&'  ; _HAL_URI_OP_SEP['&']='&'

# Whether reserved characters pass through unencoded (+ and # operators only)
declare -A _HAL_URI_OP_ALLOW_R=()
_HAL_URI_OP_ALLOW_R['0']=0; _HAL_URI_OP_ALLOW_R['+']=1
_HAL_URI_OP_ALLOW_R['#']=1; _HAL_URI_OP_ALLOW_R['.']=0
_HAL_URI_OP_ALLOW_R['/']=0; _HAL_URI_OP_ALLOW_R[';']=0
_HAL_URI_OP_ALLOW_R['?']=0; _HAL_URI_OP_ALLOW_R['&']=0

# Whether the operator produces named (key=value) pairs
declare -A _HAL_URI_OP_NAMED=()
_HAL_URI_OP_NAMED['0']=0; _HAL_URI_OP_NAMED['+']=0
_HAL_URI_OP_NAMED['#']=0; _HAL_URI_OP_NAMED['.']=0
_HAL_URI_OP_NAMED['/']=0; _HAL_URI_OP_NAMED[';']=1
_HAL_URI_OP_NAMED['?']=1; _HAL_URI_OP_NAMED['&']=1

# String appended after the key when the value is empty (named operators only)
#   ''  → ; operator: emit just the key name, no equals sign
#   '=' → ? and & operators: emit key= with an empty value
declare -A _HAL_URI_OP_IFEMP=()
_HAL_URI_OP_IFEMP['0']='' ; _HAL_URI_OP_IFEMP['+']=''
_HAL_URI_OP_IFEMP['#']='' ; _HAL_URI_OP_IFEMP['.']=''
_HAL_URI_OP_IFEMP['/']='' ; _HAL_URI_OP_IFEMP[';']=''
_HAL_URI_OP_IFEMP['?']='='; _HAL_URI_OP_IFEMP['&']='='

# ── Private helpers ───────────────────────────────────────────────────────────

# _hal_uri_encode <string> <allow_reserved>
# Percent-encodes a string per RFC 6570 rules.
#   allow_reserved=1 → reserved chars (:/?#[]@!$&'()*+,;=) also pass through
#   allow_reserved=0 → only unreserved chars (ALPHA DIGIT -._~) pass through
# Outputs the encoded string to stdout.
_hal_uri_encode() {
    local str="$1"
    local allow_reserved="${2:-0}"
    local result='' char hex piece i j

    for (( i = 0; i < ${#str}; i++ )); do
        char="${str:$i:1}"

        # Unreserved chars always pass through (ALPHA DIGIT - . _ ~)
        case "$char" in
            [A-Za-z0-9\-._~])
                result+="$char"
                continue ;;
        esac

        # Reserved chars pass through only when allow_reserved=1
        if [[ "$allow_reserved" == '1' ]]; then
            case "$char" in
                ':'|'/'|'?'|'#'|'['|']'|'@'|'!'|'$'|'&'|"'"|'('|')'|'*'|'+'|','|';'|'=')
                    result+="$char"
                    continue ;;
            esac
        fi

        # Percent-encode: get byte representation via od (handles ASCII + UTF-8)
        hex=$(printf '%s' "$char" | od -An -tx1 | tr -d ' \n')
        for (( j = 0; j < ${#hex}; j += 2 )); do
            piece="${hex:$j:2}"
            result+="%${piece^^}"
        done
    done

    printf '%s' "$result"
}

# _hal_uri_parse_bindings [binding...]
# Parses key=value and key[field]=val bindings into the
# _HAL_URI_VARS, _HAL_URI_TYPES, and _HAL_URI_LIST_CNT global arrays.
# Repeating the same plain key builds a list: first occurrence is stored as a
# string; on the second occurrence the string is promoted to a list and each
# subsequent occurrence appends another element.
_hal_uri_parse_bindings() {
    local binding key value base field idx

    for binding in "$@"; do
        # Split on the first '=' only
        key="${binding%%=*}"
        value="${binding#*=}"

        if [[ "$key" == *'['*']' ]]; then
            # Map entry or list-append: key[field]=value or key[]=value
            base="${key%%\[*}"
            field="${key#*\[}"
            field="${field%]}"

            if [[ -z "$field" ]]; then
                # key[]=value → list append
                idx="${_HAL_URI_LIST_CNT[$base]:-0}"
                _HAL_URI_VARS["${base}[${idx}]"]="$value"
                _HAL_URI_LIST_CNT["$base"]=$(( idx + 1 ))
                _HAL_URI_TYPES["$base"]='list'
            else
                # key[field]=value → map entry
                _HAL_URI_VARS["${base}[${field}]"]="$value"
                _HAL_URI_TYPES["$base"]='map'
            fi

        else
            # Plain name: first occurrence → string; repeated → list
            if [[ "${_HAL_URI_TYPES[$key]:-}" == 'string' ]]; then
                # Promote: move the existing string value to index 0
                _HAL_URI_VARS["${key}[0]"]="${_HAL_URI_VARS[$key]}"
                unset "_HAL_URI_VARS[$key]"
                _HAL_URI_LIST_CNT["$key"]=1
                _HAL_URI_TYPES["$key"]='list'
            fi

            if [[ "${_HAL_URI_TYPES[$key]:-}" == 'list' ]]; then
                idx="${_HAL_URI_LIST_CNT[$key]:-0}"
                _HAL_URI_VARS["${key}[${idx}]"]="$value"
                _HAL_URI_LIST_CNT["$key"]=$(( idx + 1 ))
            else
                # First occurrence
                _HAL_URI_VARS["$key"]="$value"
                _HAL_URI_TYPES["$key"]='string'
            fi
        fi
    done
}

# _hal_uri_expand_list <varname> <op> <explode> <allow_r> <named> <ifemp> <sep>
# Appends expanded list items to _HAL_URI_PARTS.
_hal_uri_expand_list() {
    local varname="$1" op="$2" explode="$3" allow_r="$4"
    local named="$5" ifemp="$6" sep="$7"
    local idx=0 elem encoded joined
    local -a list_vals=() encoded_elems=()

    # Collect list elements in insertion order
    while [[ -n "${_HAL_URI_VARS["${varname}[${idx}]"]+x}" ]]; do
        list_vals+=("${_HAL_URI_VARS["${varname}[${idx}]"]}")
        (( idx++ ))
    done

    [[ "${#list_vals[@]}" -eq 0 ]] && return 0

    if [[ "$explode" == '1' ]]; then
        # Each element is a separate entry (joined by sep in the caller)
        for elem in "${list_vals[@]}"; do
            encoded=$(_hal_uri_encode "$elem" "$allow_r")
            if [[ "$named" == '1' ]]; then
                [[ -n "$encoded" ]] && _HAL_URI_PARTS+=("${varname}=${encoded}") \
                                    || _HAL_URI_PARTS+=("${varname}${ifemp}")
            else
                _HAL_URI_PARTS+=("$encoded")
            fi
        done
    else
        # Non-explode: join all elements with comma → single entry
        for elem in "${list_vals[@]}"; do
            encoded_elems+=("$(_hal_uri_encode "$elem" "$allow_r")")
        done
        joined=$(
            local IFS=','
            printf '%s' "${encoded_elems[*]}"
        )
        if [[ "$named" == '1' ]]; then
            _HAL_URI_PARTS+=("${varname}=${joined}")
        else
            _HAL_URI_PARTS+=("$joined")
        fi
    fi
}

# _hal_uri_expand_map <varname> <op> <explode> <allow_r> <named> <ifemp> <sep>
# Appends expanded map items to _HAL_URI_PARTS.
_hal_uri_expand_map() {
    local varname="$1" op="$2" explode="$3" allow_r="$4"
    local named="$5" ifemp="$6" sep="$7"
    local vprefix="${varname}["
    local plen=$(( ${#vprefix} ))
    local k field enc_key enc_val joined
    local -a fields=() sorted_fields=() kv_pairs=()

    # Enumerate map keys stored as "varname[field]"
    for k in "${!_HAL_URI_VARS[@]}"; do
        [[ "$k" == "${vprefix}"* && "$k" == *']' ]] || continue
        field="${k:$plen}"
        field="${field%]}"
        fields+=("$field")
    done

    [[ "${#fields[@]}" -eq 0 ]] && return 0

    # Sort fields for deterministic output
    local IFS=$'\n'
    # shellcheck disable=SC2207
    sorted_fields=($(printf '%s\n' "${fields[@]}" | sort))
    unset IFS

    if [[ "$explode" == '1' ]]; then
        # Each key=value pair is a separate entry
        for field in "${sorted_fields[@]}"; do
            enc_key=$(_hal_uri_encode "$field" "$allow_r")
            enc_val=$(_hal_uri_encode "${_HAL_URI_VARS["${vprefix}${field}]"]}" "$allow_r")
            _HAL_URI_PARTS+=("${enc_key}=${enc_val}")
        done
    else
        # Non-explode: key,value,key,value,... → single entry
        for field in "${sorted_fields[@]}"; do
            kv_pairs+=("$(_hal_uri_encode "$field" "$allow_r")")
            kv_pairs+=("$(_hal_uri_encode "${_HAL_URI_VARS["${vprefix}${field}]"]}" "$allow_r")")
        done
        joined=$(
            local IFS=','
            printf '%s' "${kv_pairs[*]}"
        )
        if [[ "$named" == '1' ]]; then
            _HAL_URI_PARTS+=("${varname}=${joined}")
        else
            _HAL_URI_PARTS+=("$joined")
        fi
    fi
}

# _hal_uri_expand_expression <expression>
# Expands a single {expression} (without the surrounding braces).
# Prints the expanded string to stdout.
_hal_uri_expand_expression() {
    local expr="$1"
    local op='' varlist="$expr"

    # Detect operator: one of + # . / ; ? &
    case "${expr:0:1}" in
        '+'|'#'|'.'|'/'|';'|'?'|'&')
            op="${expr:0:1}"
            varlist="${expr:1}"
            ;;
    esac

    # Normalise the default operator (empty string) to its table key '0'
    local op_key="${op:-0}"
    local prefix="${_HAL_URI_OP_PREFIX[$op_key]}"
    local sep="${_HAL_URI_OP_SEP[$op_key]}"
    local allow_r="${_HAL_URI_OP_ALLOW_R[$op_key]}"
    local named="${_HAL_URI_OP_NAMED[$op_key]}"
    local ifemp="${_HAL_URI_OP_IFEMP[$op_key]}"

    # Split varlist on commas
    local -a varspecs=()
    local old_IFS="$IFS"
    IFS=',' read -r -a varspecs <<< "$varlist"
    IFS="$old_IFS"

    _HAL_URI_PARTS=()

    local varspec varname vtype explode prefix_len val encoded
    for varspec in "${varspecs[@]}"; do
        varname="$varspec"
        explode=0
        prefix_len=-1

        # Detect explode modifier (*)
        if [[ "$varname" == *'*' ]]; then
            varname="${varname%\*}"
            explode=1
        # Detect prefix modifier (:N)
        elif [[ "$varname" == *':'* ]]; then
            prefix_len="${varname##*:}"
            varname="${varname%%:*}"
        fi

        vtype="${_HAL_URI_TYPES[$varname]:-}"

        # Skip undefined variables
        if [[ -z "$vtype" && -z "${_HAL_URI_VARS[$varname]+x}" ]]; then
            continue
        fi

        case "${vtype:-string}" in
            string)
                val="${_HAL_URI_VARS[$varname]:-}"
                # Apply prefix modifier
                if [[ "$prefix_len" -ge 0 ]] 2>/dev/null; then
                    val="${val:0:$prefix_len}"
                fi
                encoded=$(_hal_uri_encode "$val" "$allow_r")
                if [[ "$named" == '1' ]]; then
                    [[ -n "$encoded" ]] && _HAL_URI_PARTS+=("${varname}=${encoded}") \
                                        || _HAL_URI_PARTS+=("${varname}${ifemp}")
                else
                    _HAL_URI_PARTS+=("$encoded")
                fi
                ;;

            list)
                _hal_uri_expand_list \
                    "$varname" "$op" "$explode" "$allow_r" "$named" "$ifemp" "$sep"
                ;;

            map)
                _hal_uri_expand_map \
                    "$varname" "$op" "$explode" "$allow_r" "$named" "$ifemp" "$sep"
                ;;
        esac
    done

    # Join parts with separator and prepend prefix
    if [[ "${#_HAL_URI_PARTS[@]}" -gt 0 ]]; then
        local joined
        joined=$(
            local IFS="$sep"
            printf '%s' "${_HAL_URI_PARTS[*]}"
        )
        printf '%s%s' "$prefix" "$joined"
    fi
    # Undefined/empty → print nothing
}

# _hal_uri_process_template <template>
# Scans the template for {expression} blocks, expands them, and prints the
# resulting URI to stdout.
_hal_uri_process_template() {
    local remaining="$1"
    local result='' before expr

    while [[ "$remaining" == *'{'* ]]; do
        # Capture everything before the first '{'
        before="${remaining%%\{*}"
        result+="$before"
        remaining="${remaining#*\{}"

        if [[ "$remaining" != *'}'* ]]; then
            # Malformed template: no closing '}' — treat remainder as literal
            result+="{${remaining}"
            remaining=''
            break
        fi

        # Extract expression up to the first '}'
        expr="${remaining%%\}*}"
        remaining="${remaining#*\}}"

        result+="$(_hal_uri_expand_expression "$expr")"
    done

    # Trailing literal text after the last '}'
    result+="$remaining"
    printf '%s\n' "$result"
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Usage:
#   uritemplate.sh <template> [var_binding...]   — template as first argument
#   uritemplate.sh - [var_binding...]            — template read from stdin
#   echo '<template>' | uritemplate.sh [var_binding...]  — template from stdin
#
# When reading from stdin, only the first line is used as the template.
# Variable bindings are always supplied as positional arguments.

if [[ $# -eq 0 ]]; then
    # No args: read first line of stdin as template; no bindings
    IFS= read -r _hal_template || true
    _hal_uri_process_template "$_hal_template"
elif [[ "$1" == '-' ]]; then
    # Explicit stdin sentinel: read template from stdin, bindings from remaining args
    IFS= read -r _hal_template || true
    _hal_uri_parse_bindings "${@:2}"
    _hal_uri_process_template "$_hal_template"
else
    # Normal: template as first arg, bindings from remaining args
    _hal_uri_parse_bindings "${@:2}"
    _hal_uri_process_template "$1"
fi
