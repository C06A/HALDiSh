#!/usr/bin/env bash
# =============================================================================
# nahal.sh — Interactive HAL API browser
#
# Usage:
#   nahal.sh <URL>
#   nahal.sh <link-text>              # HAL link object as JSON, XML, or YAML text
#   nahal.sh <resource-file> [path…]  # HAL resource file + navigation path to a link
#
# Interactively navigate a HAL API starting from a URL, a HAL link object
# file, or a link extracted from a HAL resource file.  Each HTTP response is
# classified by Content-Type:
#   application/hal+{json,xml,yaml}, application/json, application/xml, application/yaml
#                 → navigate as HAL resource
#   text/*        → print content or re-parse as HAL
#   other         → open with system default application
#
# All requests are logged to <session-dir>/session.sh as a replayable shell
# script of curl, yq/jq, and uritemplate.sh commands.
#
# Requires: curl, and yq (mikefarah/yq v4) or jq (JSON only)
# =============================================================================
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATH="${_SCRIPT_DIR}:${PATH}"
source "${_SCRIPT_DIR}/env.sh" 2>/dev/null || \
    source "${_SCRIPT_DIR}/hal_utils.sh" 2>/dev/null || true

# ── constants ─────────────────────────────────────────────────────────────────

readonly _BROW_HAL_ACCEPT='application/hal+json, application/hal+xml;q=0.9, application/hal+yaml;q=0.8, application/json;q=0.7, application/xml;q=0.6, application/yaml;q=0.5'

# ── session state ─────────────────────────────────────────────────────────────

_BROW_TOOL=''        # yq or jq
_BROW_OUTDIR=''      # directory for HTTP response files
_BROW_LOG=''         # path to session log script
_BROW_STEP=0         # request counter
_BROW_LAST_BASE=''   # base name of last response file set

# ── tool initialization ───────────────────────────────────────────────────────

_brow_init_tool() {
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        _BROW_TOOL=yq
    elif command -v jq >/dev/null 2>&1; then
        _BROW_TOOL=jq
    else
        printf 'nahal: yq or jq is required\n' >&2
        exit 1
    fi
}

# ── query helpers (mirrors hal.sh) ────────────────────────────────────────────

# _brow_q <json> <filter>  → compact JSON
_brow_q() {
    if [[ "$_BROW_TOOL" == yq ]]; then
        printf '%s' "$1" | yq -o json -I0 "$2"
    else
        printf '%s' "$1" | jq -c "$2"
    fi
}

# _brow_qr <json> <filter>  → raw scalar
_brow_qr() {
    if [[ "$_BROW_TOOL" == yq ]]; then
        printf '%s' "$1" | yq -o json -r "$2"
    else
        printf '%s' "$1" | jq -r "$2"
    fi
}

# _brow_qk <json> <key>  → object value by key
_brow_qk() {
    if [[ "$_BROW_TOOL" == yq ]]; then
        printf '%s' "$1" | HAL_K="$2" yq -o json -I0 '.[env(HAL_K)]'
    else
        printf '%s' "$1" | jq -c --arg k "$2" '.[$k]'
    fi
}

# _brow_qkr <json> <key>  → raw scalar by key
_brow_qkr() {
    if [[ "$_BROW_TOOL" == yq ]]; then
        printf '%s' "$1" | HAL_K="$2" yq -o json -r '.[env(HAL_K)]'
    else
        printf '%s' "$1" | jq -r --arg k "$2" '.[$k]'
    fi
}

# _brow_qi <json> <N>  → array element by index
_brow_qi() {
    _brow_q "$1" ".[$2]"
}

# _brow_detect_format <text>  → json | xml | yaml
_brow_detect_format() {
    local text="$1"
    # JSON: jq is the definitive validator
    if command -v jq >/dev/null 2>&1 && printf '%s' "$text" | jq '.' >/dev/null 2>&1; then
        printf 'json'; return
    fi
    if [[ "$_BROW_TOOL" == yq ]]; then
        # XML: force the XML parser; JSON (caught above) is not valid XML
        if printf '%s' "$text" | yq -p xml '.' >/dev/null 2>&1; then
            printf 'xml'; return
        fi
        # YAML: confirm yq can actually parse it before committing
        if printf '%s' "$text" | yq '.' >/dev/null 2>&1; then
            printf 'yaml'; return
        fi
        printf 'nahal: cannot determine format — content is not valid JSON, XML, or YAML\n' >&2
        return 1
    fi
    # Only jq available and it already failed → cannot handle non-JSON content
    printf 'nahal: yq is required to parse non-JSON content\n' >&2
    return 1
}

# _brow_to_json <text> <format>  → JSON string
_brow_to_json() {
    local text="$1" fmt="$2"
    case "$fmt" in
        json) printf '%s' "$text" ;;
        xml)  printf '%s' "$text" | yq -p xml -o json '.' ;;
        yaml) printf '%s' "$text" | yq -o json '.' ;;
    esac
}

# _brow_pretty <json>  → pretty-printed JSON to stdout
_brow_pretty() {
    if [[ "$_BROW_TOOL" == yq ]]; then
        printf '%s' "$1" | yq -o json -I2 '.'
    else
        printf '%s' "$1" | jq '.'
    fi
}

# ── content-type classification ───────────────────────────────────────────────

# _brow_classify_ct <content-type>  → hal | text | binary
_brow_classify_ct() {
    local ct="${1,,}"   # lowercase
    ct="${ct%%;*}"      # strip charset/parameters
    ct="${ct// /}"      # strip spaces
    case "$ct" in
        application/hal+json|application/hal+xml|application/hal+yaml|\
        application/json|application/xml|application/yaml)
            printf 'hal' ;;
        text/*)
            printf 'text' ;;
        *)
            printf 'binary' ;;
    esac
}

# ── session log ───────────────────────────────────────────────────────────────

_brow_log() {
    printf '%s\n' "$*" >> "$_BROW_LOG"
}

_brow_log_blank() {
    printf '\n' >> "$_BROW_LOG"
}

_brow_log_comment() {
    printf '\n# %s\n' "$*" >> "$_BROW_LOG"
}

# _brow_log_curl_file
# Appends the .curl replay file written by httpreq.sh for the last request
# to the session log.  Called by _brow_do_request after each successful request.
_brow_log_curl_file() {
    local curl_file="${_BROW_OUTDIR}/${_BROW_LAST_BASE}.curl"
    if [[ -f "$curl_file" ]]; then
        cat "$curl_file" >> "$_BROW_LOG"
        _brow_log_blank
    fi
}

# ── method symlinks ───────────────────────────────────────────────────────────

_brow_setup_methods() {
    command -v GET >/dev/null 2>&1 && return
    printf 'nahal: HTTP method commands (GET, POST, …) not found in PATH.\n' >&2
    printf 'nahal: Install the HALDiSh archive first: bash HALDiSh-<version>.run\n' >&2
    exit 1
}

# ── HTTP request ──────────────────────────────────────────────────────────────

# _brow_do_request <method> <url> <accept> [body-flags...]
# Sets _BROW_LAST_BASE.  Returns 1 on curl failure.
_brow_do_request() {
    local method="$1" url="$2" accept="$3"
    shift 3
    _BROW_STEP=$(( _BROW_STEP + 1 ))
    hal::log::info "Step ${_BROW_STEP}: ${method} ${url}"

    local base='' rc=0
    set +e
    HTTP_IN_HEADERS="Accept: ${accept}" \
        base=$(cd "$_BROW_OUTDIR" && "$method" "$url" "$@" 2>/dev/null)
    rc=$?
    set -e

    if [[ -z "$base" ]]; then
        hal::log::error "Request failed (curl exit ${rc})"
        return 1
    fi

    local status
    status=$(cat "${_BROW_OUTDIR}/${base}.status" 2>/dev/null || printf '???')
    hal::log::info "  HTTP ${status} — ${base}.{status,headers,body}"
    _BROW_LAST_BASE="$base"
    _brow_log_curl_file
}

# _brow_get_ct <headers-file>  → Content-Type value
_brow_get_ct() {
    grep -i '^content-type:' "$1" 2>/dev/null \
        | head -1 | cut -d: -f2- \
        | sed 's/^[[:space:]]*//' | tr -d '\r' \
        || printf ''
}

# ── TTY input ─────────────────────────────────────────────────────────────────

# _brow_prompt <prompt> <varname> [default]
_brow_prompt() {
    local _prompt="$1" _var="$2" _default="${3:-}"
    if [[ -n "$_default" ]]; then
        printf '%s [%s]: ' "$_prompt" "$_default" >&2
    else
        printf '%s: ' "$_prompt" >&2
    fi
    local _val
    IFS= read -r _val < /dev/tty
    _val="${_val:-$_default}"
    printf -v "$_var" '%s' "$_val"
}

# ── URI template expansion ────────────────────────────────────────────────────

# _brow_expand_vars <template> <rel>  → expanded URL on stdout
# Prompts for template variable values, expands via uritemplate.sh, and logs
# ONLY the "$(uritemplate.sh ...)" call.  The caller is responsible for
# logging the _template= assignment before calling this function.
_brow_expand_vars() {
    local tmpl="$1" rel="$2"
    hal::log::info "Templated link '${rel}': ${tmpl}"

    # Extract variable names from template expressions
    local tmp="$tmpl" vars=()
    local _tpl_re='\{[+#./;?&]?([^}]+)\}'
    while [[ "$tmp" =~ $_tpl_re ]]; do
        local expr="${BASH_REMATCH[1]#[+#./;?&]}"
        local IFS=','
        local vs
        for vs in $expr; do
            vs="${vs%%:*}"; vs="${vs%%\**}"
            vars+=("$vs")
        done
        tmp="${tmp#*\}}"
    done

    # _tpl_bindings: ordered array of uritemplate.sh binding strings
    #   string:  "name=value"
    #   list:    "name=v1" "name=v2" …
    #   map:     "name[key1]=v1" "name[key2]=v2" …
    local -a _tpl_bindings=()

    # _tpl_summary <varname>  → human-readable current state for the top menu
    _tpl_summary() {
        local _v="$1" _strs=() _keys=() _b
        for _b in ${_tpl_bindings[@]+"${_tpl_bindings[@]}"}; do
            if [[ "$_b" == "${_v}["*"]="* ]]; then
                _keys+=("${_b#"${_v}["}")   # "key]=val"
            elif [[ "$_b" == "${_v}="* ]]; then
                _strs+=("${_b#"${_v}="}")
            fi
        done
        if [[ ${#_strs[@]} -eq 1 && ${#_keys[@]} -eq 0 ]]; then
            printf '%s = %s' "$_v" "${_strs[0]}"
        elif [[ ${#_strs[@]} -gt 1 ]]; then
            printf '%s = [%s]' "$_v" "$(IFS=','; printf '%s' "${_strs[*]}")"
        elif [[ ${#_keys[@]} -gt 0 ]]; then
            local _pairs=()
            for _b in "${_keys[@]}"; do
                _pairs+=("${_b%%\]=*}=${_b#*\]=}")
            done
            printf '%s = {%s}' "$_v" "$(IFS=','; printf '%s' "${_pairs[*]}")"
        else
            printf '%s (unset)' "$_v"
        fi
    }

    # _tpl_clear <varname>  → remove all bindings for the variable
    _tpl_clear() {
        local _v="$1" _keep=() _b
        for _b in ${_tpl_bindings[@]+"${_tpl_bindings[@]}"}; do
            [[ "$_b" == "${_v}="* || "$_b" == "${_v}["* ]] || _keep+=("$_b")
        done
        _tpl_bindings=(${_keep[@]+"${_keep[@]}"})
    }

    # Top-level variable selection loop
    while true; do
        local opts=("Continue") v
        for v in "${vars[@]}"; do
            opts+=("$(_tpl_summary "$v")")
        done

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "URI template: ${tmpl}")
        [[ "$chosen" == "Continue" ]] && break

        # Recover variable name from chosen label (up to first space or '=')
        local vname="${chosen%% *}"; vname="${vname%%=*}"; vname="${vname%%(unset)}"
        vname="${vname%% }"

        # Sub-menu for this variable
        local action
        action=$(printf '%s\n' \
            "Set single value" \
            "Add list item" \
            "Add map entry (key=value)" \
            "Clear" \
            "Back" \
            | menu.sh "${vname}")

        local inp
        case "$action" in
            "Set single value")
                _brow_prompt "Value for '${vname}'" inp ""
                if [[ -n "$inp" ]]; then
                    _tpl_clear "$vname"
                    _tpl_bindings+=("${vname}=${inp}")
                fi
                ;;
            "Add list item")
                _brow_prompt "List item for '${vname}'" inp ""
                [[ -n "$inp" ]] && _tpl_bindings+=("${vname}=${inp}")
                ;;
            "Add map entry (key=value)")
                local mkey mval
                _brow_prompt "Key for '${vname}'" mkey ""
                if [[ -n "$mkey" ]]; then
                    _brow_prompt "Value for '${vname}[${mkey}]'" mval ""
                    [[ -n "$mval" ]] && _tpl_bindings+=("${vname}[${mkey}]=${mval}")
                fi
                ;;
            "Clear")
                _tpl_clear "$vname"
                ;;
            "Back") ;;
        esac
    done

    # Collect ordered bindings for uritemplate.sh and the log
    local bindings=() log_bindings=()
    local b
    for b in ${_tpl_bindings[@]+"${_tpl_bindings[@]}"}; do
        bindings+=("$b")
        log_bindings+=("$(printf '%q' "$b")")
    done

    local expanded
    expanded=$(bash "${_SCRIPT_DIR}/uritemplate.sh" "$tmpl" \
               ${bindings[@]+"${bindings[@]}"})

    # Log only the uritemplate expansion line (caller wrote _template=...)
    printf '_link=$(bash uritemplate.sh "$_template"' >> "$_BROW_LOG"
    local lb
    for lb in ${log_bindings[@]+"${log_bindings[@]}"}; do
        printf ' %s' "$lb" >> "$_BROW_LOG"
    done
    printf ')\n' >> "$_BROW_LOG"

    printf '%s' "$expanded"
}

# ── method + body prompt ──────────────────────────────────────────────────────

# Sets _BROW_REQ_METHOD and _BROW_REQ_BODY_ARGS
_BROW_REQ_METHOD=''
_BROW_REQ_BODY_ARGS=()

_brow_prompt_method_body() {
    local default_method="${1:-GET}"
    local method
    _brow_prompt "HTTP method" method "$default_method"
    _BROW_REQ_METHOD="${method^^}"
    _BROW_REQ_BODY_ARGS=()

    case "$_BROW_REQ_METHOD" in
        POST|PUT|PATCH)
            local body_choice
            body_choice=$(printf '%s\n' \
                "No body" \
                "Inline text (-a): plain text or JSON typed inline" \
                "Text file (-a): plain text or JSON read from file" \
                "URL-encoded (-u): application/x-www-form-urlencoded string" \
                "Multipart files (-f): --form basename=@file (repeatable)" \
                "Binary file (-b): --data-binary @file" \
                "Raw upload (-r): --upload-file (streaming, no encoding)" \
                | menu.sh "Request body")
            local bfile
            case "$body_choice" in
                "Inline text"*)
                    local body
                    _brow_prompt "Body text" body ""
                    [[ -n "$body" ]] && _BROW_REQ_BODY_ARGS=(-a "$body")
                    ;;
                "Text file"*)
                    _brow_prompt "File path" bfile ""
                    if [[ -f "$bfile" ]]; then
                        _BROW_REQ_BODY_ARGS=(-a "$(cat "$bfile")")
                    else
                        hal::log::warn "File not found: ${bfile}"
                    fi
                    ;;
                "URL-encoded"*)
                    local body
                    _brow_prompt "URL-encoded body" body ""
                    [[ -n "$body" ]] && _BROW_REQ_BODY_ARGS=(-u "$body")
                    ;;
                "Multipart files"*)
                    while true; do
                        _brow_prompt "File path (empty to finish)" bfile ""
                        [[ -z "$bfile" ]] && break
                        if [[ -f "$bfile" ]]; then
                            _BROW_REQ_BODY_ARGS+=(-f "$bfile")
                        else
                            hal::log::warn "File not found: ${bfile}"
                        fi
                    done
                    ;;
                "Binary file"*)
                    _brow_prompt "File path" bfile ""
                    if [[ -f "$bfile" ]]; then
                        _BROW_REQ_BODY_ARGS=(-b "$bfile")
                    else
                        hal::log::warn "File not found: ${bfile}"
                    fi
                    ;;
                "Raw upload"*)
                    _brow_prompt "File path" bfile ""
                    if [[ -f "$bfile" ]]; then
                        _BROW_REQ_BODY_ARGS=(-r "$bfile")
                    else
                        hal::log::warn "File not found: ${bfile}"
                    fi
                    ;;
            esac
            ;;
    esac
}

# ── accept header for a link ─────────────────────────────────────────────────

_brow_accept_for_link() {
    local link_json="$1"
    local ltype
    ltype=$(_brow_qkr "$link_json" 'type' 2>/dev/null || printf '')
    if [[ -n "$ltype" && "$ltype" != "null" ]]; then
        printf '%s' "$ltype"
    else
        printf '%s' "$_BROW_HAL_ACCEPT"
    fi
}

# ── link following ────────────────────────────────────────────────────────────

# _brow_follow_link <link_json> <rel>
# Sends request, handles response.  Returns 0 if navigated into new HAL
# resource (recursive call completed), 1 if non-HAL (stay on current resource).
_brow_follow_link() {
    local link_json="$1" rel="$2"

    local href templated accept url
    href=$(_brow_qkr "$link_json" '.href')
    templated=$(_brow_qr  "$link_json" '.templated // false')
    accept=$(_brow_accept_for_link "$link_json")

    _brow_log_comment "Step ${_BROW_STEP}: follow link '${rel}'"

    # Log _template= or _link= assignment, then expand if templated
    if [[ "$templated" == "true" ]]; then
        # Write _template= assignment: from jq/yq extraction or literal fallback
        if [[ -n "$_BROW_LAST_BASE" ]]; then
            printf '_template=$(%s -r %s %s)\n' \
                "$_BROW_TOOL" \
                "$(printf '%q' "._links.${rel}.href")" \
                "$(printf '%q' "${_BROW_LAST_BASE}.body")" >> "$_BROW_LOG"
        else
            printf '_template=%s\n' "$(printf '%q' "$href")" >> "$_BROW_LOG"
        fi
        url=$(_brow_expand_vars "$href" "$rel")
    else
        if [[ -n "$_BROW_LAST_BASE" ]]; then
            printf '_link=$(%s -r %s %s)\n' \
                "$_BROW_TOOL" \
                "$(printf '%q' "._links.${rel}.href")" \
                "$(printf '%q' "${_BROW_LAST_BASE}.body")" >> "$_BROW_LOG"
        else
            printf '_link=%s\n' "$(printf '%q' "$href")" >> "$_BROW_LOG"
        fi
        url="$href"
    fi

    # Prompt for method + body
    _brow_prompt_method_body "GET"
    local method="$_BROW_REQ_METHOD"
    local body_args=()
    [[ ${#_BROW_REQ_BODY_ARGS[@]} -gt 0 ]] && body_args=("${_BROW_REQ_BODY_ARGS[@]}")

    # Make the request
    if ! _brow_do_request "$method" "$url" "$accept" ${body_args[@]+"${body_args[@]}"}; then
        hal::log::warn "Request failed — staying on current resource"
        return 1
    fi

    local status ct cls
    status=$(cat "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.status" 2>/dev/null || printf '0')
    ct=$(_brow_get_ct "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.headers")
    cls=$(_brow_classify_ct "$ct")

    if [[ "$status" -ge 400 ]] 2>/dev/null; then
        hal::log::warn "HTTP ${status}"
    fi

    case "$cls" in
        hal)
            _brow_navigate_response "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.body" "$url" "0"
            return 0
            ;;
        text)
            _brow_handle_text "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.body" "$ct" "$url"
            return 1
            ;;
        binary)
            _brow_handle_binary "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.body" "$ct" "$url"
            return 1
            ;;
    esac
}

# ── non-HAL response handlers ─────────────────────────────────────────────────

_brow_handle_text() {
    local body_file="$1" ct="$2" url="$3"
    hal::log::info "Text response (${ct})"

    local choice
    choice=$(printf '%s\n' \
        "Print content" \
        "Parse as HAL resource" \
        "Continue from previous resource" \
        | menu.sh "Text response")

    case "$choice" in
        "Print content")
            cat "$body_file"
            ;;
        "Parse as HAL resource")
            local body fmt json
            body=$(cat "$body_file")
            fmt=$(_brow_detect_format "$body")
            json=$(_brow_to_json "$body" "$fmt")
            _brow_navigate_resource "$json" "$url" "0"
            ;;
    esac
}

_brow_handle_binary() {
    local body_file="$1" ct="$2" url="$3"
    hal::log::info "Binary response (${ct}) — saved: ${body_file}"

    local choice
    choice=$(printf '%s\n' \
        "Open with system application" \
        "Continue from previous resource" \
        | menu.sh "Binary response")

    if [[ "$choice" == "Open with system application" ]]; then
        if command -v open >/dev/null 2>&1; then
            open "$body_file"
        elif command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$body_file"
        else
            hal::log::warn "No system opener found.  File: ${body_file}"
        fi
    fi
}

# ── HAL navigation ────────────────────────────────────────────────────────────

# _brow_navigate_response <body-file> <url> <is_top>
# Loads body file, detects format, converts to JSON, calls _brow_navigate_resource.
_brow_navigate_response() {
    local body_file="$1" url="$2" is_top="$3"
    local body fmt json
    body=$(cat "$body_file")
    fmt=$(_brow_detect_format "$body")
    json=$(_brow_to_json "$body" "$fmt")
    _brow_navigate_resource "$json" "$url" "$is_top"
}

# _brow_navigate_resource <json> <url> <is_top>
# Interactive navigation.  Returns 0 on "back", exits on "quit".
_brow_navigate_resource() {
    local json="$1" url="$2" is_top="$3"

    local has_links has_embedded has_props
    has_links=$(_brow_qr    "$json" 'has("_links")')
    has_embedded=$(_brow_qr "$json" 'has("_embedded")')
    has_props=$(_brow_qr    "$json" 'del(._links,._embedded) | length > 0')

    while true; do
        printf '\n[ %s ]\n' "$url" >&2

        local opts=()
        [[ "$has_links"    == "true" ]] && opts+=("links")
        [[ "$has_embedded" == "true" ]] && opts+=("embedded")
        [[ "$has_props"    == "true" ]] && opts+=("properties")
        opts+=("print resource")
        if [[ "$is_top" == "1" ]]; then
            opts+=("quit")
        else
            opts+=("back")
            opts+=("quit")
        fi

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Resource")

        case "$chosen" in
            links)           _brow_nav_links      "$json" "$url" ;;
            embedded)        _brow_nav_embedded   "$json" ;;
            properties)      _brow_nav_properties "$json" ;;
            "print resource") _brow_pretty "$json" ;;
            back)            return 0 ;;
            quit)            exit 0 ;;
        esac
    done
}

# _brow_nav_links <json> <url>
_brow_nav_links() {
    local json="$1" url="$2"
    local links rels
    links=$(_brow_qk "$json" "_links")
    rels=$(_brow_qr  "$links" 'keys[]')

    while true; do
        local opts=("back")
        while IFS= read -r rel; do
            local lobj ltype templated suffix=''
            lobj=$(_brow_qk "$links" "$rel")
            ltype=$(_brow_qr "$lobj" 'type')
            if [[ "$ltype" == "array" ]]; then
                templated=$(_brow_qr "$lobj" '.[0].templated // false')
            else
                templated=$(_brow_qr "$lobj" '.templated // false')
            fi
            [[ "$templated" == "true" ]] && suffix=" {T}"
            opts+=("${rel}${suffix}")
        done <<< "$rels"

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Links")
        [[ "$chosen" == "back" ]] && return 0

        local rel="${chosen% \{T\}}"
        local lobj ltype
        lobj=$(_brow_qk "$links" "$rel")
        ltype=$(_brow_qr "$lobj" 'type')

        # If link is an array, let user pick which one
        local link_obj
        if [[ "$ltype" == "array" ]]; then
            local count i idx_opts=("back")
            count=$(_brow_qr "$lobj" 'length')
            for (( i = 0; i < count; i++ )); do
                local lhref lname entry
                entry=$(_brow_qi "$lobj" "$i")
                lhref=$(_brow_qkr "$entry" 'href')
                lname=$(_brow_qr  "$entry" '.name // empty')
                if [[ -n "$lname" ]]; then
                    idx_opts+=("${i}: ${lname} (${lhref})")
                else
                    idx_opts+=("${i}: ${lhref}")
                fi
            done
            local idx_choice
            idx_choice=$(printf '%s\n' "${idx_opts[@]}" | menu.sh "Choose link [${rel}]")
            [[ "$idx_choice" == "back" ]] && continue
            local idx="${idx_choice%%:*}"
            link_obj=$(_brow_qi "$lobj" "$idx")
        else
            link_obj="$lobj"
        fi

        # Show href and offer action
        local href
        href=$(_brow_qkr "$link_obj" 'href')
        printf '\n  %s → %s\n' "$rel" "$href" >&2

        local action
        action=$(printf '%s\n' \
            "follow (send request)" \
            "show link details" \
            "back" \
            | menu.sh "Action")

        case "$action" in
            "follow (send request)") _brow_follow_link "$link_obj" "$rel" ;;
            "show link details")     _brow_pretty "$link_obj" ;;
            back)                    continue ;;
        esac
    done
}

# _brow_nav_embedded <json>
_brow_nav_embedded() {
    local json="$1"
    local embedded rels
    embedded=$(_brow_qk "$json" "_embedded")
    rels=$(_brow_qr "$embedded" 'keys[]')

    while true; do
        local opts=("back")
        while IFS= read -r rel; do opts+=("$rel"); done <<< "$rels"

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Embedded")
        [[ "$chosen" == "back" ]] && return 0

        local item itype
        item=$(_brow_qk "$embedded" "$chosen")
        itype=$(_brow_qr "$item" 'type')

        if [[ "$itype" == "array" ]]; then
            local count idx
            count=$(_brow_qr "$item" 'length')
            while true; do
                printf 'Index [1-%d] (0 to cancel): ' "$count" >&2
                IFS= read -r idx < /dev/tty
                [[ "$idx" == "0" ]] && break 2
                if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= count )); then
                    break
                fi
                printf 'Invalid: enter a number between 1 and %d, or 0 to cancel.\n' "$count" >&2
            done
            local elem
            elem=$(_brow_qi "$item" "$(( idx - 1 ))")
            _brow_navigate_resource "$elem" "(embedded ${chosen}[${idx_choice}])" "0"
        else
            _brow_navigate_resource "$item" "(embedded ${chosen})" "0"
        fi
    done
}

# _brow_nav_value <json-value> <label>
# Recursively navigate any JSON value.
#   scalar → print and return
#   object → menu of sub-keys (plus "print" and "back"), recurse on chosen key
#   array  → prompt for 1-based index (0 to go back), recurse on chosen element
_brow_nav_value() {
    local val="$1" label="$2"
    local vtype
    vtype=$(_brow_qr "$val" 'type')

    case "$vtype" in
        string|number|boolean|null)
            printf '%s\n' "$(_brow_qr "$val" '.')"
            ;;
        object)
            local keys
            keys=$(_brow_qr "$val" 'keys[]')
            while true; do
                local opts=("print" "back")
                while IFS= read -r k; do opts+=("$k"); done <<< "$keys"
                local chosen
                chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "${label}")
                case "$chosen" in
                    print) _brow_pretty "$val" ;;
                    back)  return 0 ;;
                    *)
                        local sub
                        sub=$(_brow_qk "$val" "$chosen")
                        _brow_nav_value "$sub" "${label}.${chosen}"
                        ;;
                esac
            done
            ;;
        array)
            local count idx
            count=$(_brow_qr "$val" 'length')
            while true; do
                printf 'Index [1-%d] (0 to go back): ' "$count" >&2
                IFS= read -r idx < /dev/tty
                [[ "$idx" == "0" ]] && return 0
                if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= count )); then
                    local elem
                    elem=$(_brow_qi "$val" "$(( idx - 1 ))")
                    _brow_nav_value "$elem" "${label}[${idx}]"
                else
                    printf 'Invalid: enter a number between 1 and %d, or 0 to go back.\n' \
                        "$count" >&2
                fi
            done
            ;;
    esac
}

# _brow_nav_properties <json>
_brow_nav_properties() {
    local json="$1"
    local props keys
    props=$(_brow_q "$json" 'del(._links,._embedded)')
    keys=$(_brow_qr "$props" 'keys[]')

    while true; do
        local opts=("back")
        while IFS= read -r k; do opts+=("$k"); done <<< "$keys"

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Properties")
        [[ "$chosen" == "back" ]] && return 0

        local val
        val=$(_brow_qk "$props" "$chosen")
        _brow_nav_value "$val" "$chosen"
    done
}

# ── argument resolution ───────────────────────────────────────────────────────

_brow_usage() {
    local name
    name="$(basename "$0")"
    printf 'Usage:\n' >&2
    printf '  %s <URL>\n' "$name" >&2
    printf '  %s <link-text>              # HAL link object as JSON, XML, or YAML text\n' "$name" >&2
    printf '  %s <resource-file> [path…]  # HAL resource file + navigation path to a link\n' "$name" >&2
    printf '\nPath examples: links self    |  links items 0\n' >&2
}

_BROW_START_URL=''
_BROW_START_LINK_JSON=''

_brow_resolve_start() {
    local first="${1:-}"
    shift || true

    if [[ -z "$first" ]]; then _brow_usage; exit 1; fi

    # Case 1: URL
    if [[ "$first" == http://* || "$first" == https://* ]]; then
        _BROW_START_URL="$first"
        return
    fi

    if [[ $# -gt 0 ]]; then
        # Case 3: resource file + navigation path to a link
        [[ ! -f "$first" ]] && { printf 'nahal: not a file: %s\n' "$first" >&2; exit 1; }
        local link_raw link_fmt link_json
        link_raw=$(bash "${_SCRIPT_DIR}/hal.sh" "$first" "$@")
        if [[ -z "$link_raw" ]]; then
            printf 'nahal: could not extract link at path\n' >&2; exit 1
        fi
        link_fmt=$(_brow_detect_format "$link_raw")
        link_json=$(_brow_to_json "$link_raw" "$link_fmt")
        _BROW_START_LINK_JSON="$link_json"
        _BROW_START_URL=$(_brow_qkr "$link_json" '.href')
        if [[ -z "$_BROW_START_URL" || "$_BROW_START_URL" == "null" ]]; then
            printf 'nahal: extracted path does not contain a link with .href\n' >&2; exit 1
        fi
    else
        # Case 2: link text (JSON, XML, or YAML) passed directly as argument
        local fmt json
        fmt=$(_brow_detect_format "$first")
        json=$(_brow_to_json "$first" "$fmt")
        _BROW_START_LINK_JSON="$json"
        _BROW_START_URL=$(_brow_qkr "$json" '.href')
        if [[ -z "$_BROW_START_URL" || "$_BROW_START_URL" == "null" ]]; then
            printf 'nahal: link has no .href field\n' >&2; exit 1
        fi
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && { _brow_usage; exit 1; }

_brow_init_tool
_brow_setup_methods
_brow_resolve_start "$@"

# Session directory (next to where the script is run)
_BROW_OUTDIR="$(pwd)/nahal_$(date +%Y%m%dT%H%M%S)"
mkdir -p "$_BROW_OUTDIR"
_BROW_LOG="${_BROW_OUTDIR}/session.sh"

# Write session log header
{
    printf '#!/usr/bin/env bash\n'
    printf '# HAL Browse session — %s\n' "$(date)"
    printf '# Starting URL: %s\n' "$_BROW_START_URL"
    printf '# Run from:     %s\n' "$_BROW_OUTDIR"
    printf 'set -euo pipefail\n'
    printf 'cd "$(dirname "$0")"\n'
} > "$_BROW_LOG"
chmod +x "$_BROW_LOG"

hal::log::info "Session directory: ${_BROW_OUTDIR}"
hal::log::info "Session log:       ${_BROW_LOG}"

# Determine accept header and handle templated start link
accept="$_BROW_HAL_ACCEPT"
start_url="$_BROW_START_URL"

if [[ -n "$_BROW_START_LINK_JSON" ]]; then
    accept=$(_brow_accept_for_link "$_BROW_START_LINK_JSON")
    local_templated=$(_brow_qr "$_BROW_START_LINK_JSON" '.templated // false')
    if [[ "$local_templated" == "true" ]]; then
        _brow_log_comment "Expand starting URI template"
        printf '_template=%s\n' "$(printf '%q' "$_BROW_START_URL")" >> "$_BROW_LOG"
        start_url=$(_brow_expand_vars "$_BROW_START_URL" "start")
    fi
fi

# Log the initial request
_brow_log_comment "Initial GET"
printf '_link=%s\n' "$(printf '%q' "$start_url")" >> "$_BROW_LOG"

# Send the initial request
_brow_do_request "GET" "$start_url" "$accept"

# Classify and navigate the initial response
_brow_ct=$(_brow_get_ct "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.headers")
_brow_cls=$(_brow_classify_ct "$_brow_ct")

case "$_brow_cls" in
    hal)
        _brow_navigate_response \
            "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.body" "$start_url" "1"
        ;;
    text)
        _brow_handle_text \
            "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.body" "$_brow_ct" "$start_url"
        ;;
    binary)
        _brow_handle_binary \
            "${_BROW_OUTDIR}/${_BROW_LAST_BASE}.body" "$_brow_ct" "$start_url"
        ;;
esac

hal::log::ok "Session ended.  Log: ${_BROW_LOG}"
