#!/usr/bin/env bash
# =============================================================================
# nahal.sh — Interactive HAL API browser
#
# Usage:
#   nahal.sh [-p <prefix>] <URL>
#   nahal.sh [-p <prefix>] <link-text>              # HAL link object (JSON/XML/YAML)
#   nahal.sh [-p <prefix>] <resource-file> [path…]  # link extracted from a file
#
# -p <prefix> sets the base-name prefix for the response files (prompted when
# omitted; an empty value is accepted).  Files are named <prefix><N>, numbered
# from one past the largest existing <prefix><N> in the session directory.
#
# Interactively navigate a live HAL API starting from a URL, a HAL link object,
# or a link extracted from a HAL resource file.  Each HTTP response is
# classified by Content-Type:
#   application/hal+{json,xml,yaml}, application/json, application/xml, application/yaml
#                 → navigate as a HAL resource (or an array of resources)
#   text/*        → print content or re-parse as HAL
#   other         → open with the system default application
#
# The resource menu offers links, embeddeds, properties, and — when the resource
# has curies used by a prefixed relation — docs (opens the documentation page in
# a browser).  Following a link prompts for an HTTP method (standard verbs, HEAD,
# or a custom RFC 7230 token) and, for body methods, a request body; methods that
# are not installed commands are dispatched via an on-demand ./<METHOD> link.
#
# Each request's response files are named <prefix><N> and the session is logged to
# <session-dir>/session.sh — a re-runnable script whose steps number a base into an
# array element, then build the response files under it:
#   _b[N]=$(hal_basename.sh -p "$_prefix")
#   hallink.sh -s "${_b[N]}" "${_b[M]}.body" <path> \
#    | <METHOD> --link \
#    | rename.sh "${_b[N]}"
# where $_prefix is set once near the top of the script.  session.sh keeps only the
# recorded per-session values (_prefix, the plugin list/env) and the steps; the
# session-independent replay machinery (argument parsing, the HALDiSh-environment
# bootstrap, _ensure_method, the plugin checks) lives in a companion
# <session-dir>/session_prelude.sh that session.sh sources at the top.
# Replaying it requires the HALDiSh environment on PATH (source env.sh).
#
# Link plugins (HAL_LINK_PLUGIN): a colon-separated list of scripts that each
# link object is piped through before it is followed — including a resolved CURIE
# documentation link before its page is opened.  Each plugin reads the
# current link JSON on stdin, receives the resource file and HAL path as args,
# and must print the updated link JSON (with .href) to stdout (see
# _hal_run_plugins in hal_utils.sh).  The plugin list in effect at session
# creation is recorded in session.sh, which on replay diffs it against the list
# present then: OK = in both, INFO = new at replay, WARN = missing at replay.
#
# Requires: curl, and yq (mikefarah/yq v4) or jq (JSON only)
# =============================================================================
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PATH="${_SCRIPT_DIR}:${PATH}"
source "${_SCRIPT_DIR}/env.sh" 2>/dev/null || \
    source "${_SCRIPT_DIR}/hal_utils.sh" 2>/dev/null || true

# ── constants ─────────────────────────────────────────────────────────────────

readonly _BROW_HAL_ACCEPT='application/hal+json, application/hal+xml;q=0.9, application/hal+yaml;q=0.8, application/json;q=0.7, application/xml;q=0.6, application/yaml;q=0.5'

# Prefix for menu items that are navigation/UI controls (back, quit, print, …)
# rather than data from the HAL resource.  menu.sh renders these in a distinct
# color and strips the marker from the value it returns.
readonly _BROW_NAV=$'\001'

# ── session state ─────────────────────────────────────────────────────────────

_BROW_TOOL=''            # yq or jq
_BROW_OUTDIR=''          # directory for HTTP response files
_BROW_LOG=''             # path to session log script
_BROW_STEP=0             # request counter
_BROW_LAST_BASE=''       # base name of last response file set
declare -a _BROW_STEP_BASE=()  # step number → its response base name (for back-nav)
_BROW_LAST_BINDINGS=()   # uritemplate var=value bindings from the last expansion
_BROW_LAST_URL=''        # expanded URL from the last _brow_expand_vars call
_BROW_REQ_HALLINK=()     # hallink.sh args for the next link request (live)
_BROW_REQ_BODY=()        # method body flags for the next link request (live)
_BROW_REQ_CT=''          # Content-Type to set for the next link request (live)
_BROW_PREFIX=''          # user-provided base-name prefix for response files (-p)
_BROW_PREFIX_SET=0       # 1 when -p was supplied, so the prompt is skipped
_BROW_SHOW_CURIES=false  # links menu: true = full prefixed rels, false = local names (-c / NAHAL_CURIES)

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

# _brow_qtype <json>  → normalized type: array | object | string | number | boolean | null
# yq returns YAML type tags (!!seq, !!map, …); this normalises them to jq names.
_brow_qtype() {
    local t
    t=$(_brow_qr "$1" 'type')
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

# _brow_raw <json>  → the resource as held (compact JSON, no pretty-printing)
_brow_raw() {
    printf '%s\n' "$1"
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

# _brow_is_json <text>  → exit 0 if text is JSON
_brow_is_json() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$1" | jq '.' >/dev/null 2>&1
    else
        local s="${1#"${1%%[![:space:]]*}"}"   # left-trim whitespace
        [[ "$s" == '{'* || "$s" == '['* ]]
    fi
}

# _brow_infer_content_type <body-flag...>  → Content-Type, or empty
# Maps the chosen body flag to a request Content-Type for the replay.  Multipart
# (-f/-F) yields nothing so curl can set its own boundary; -i is not a body.
_brow_infer_content_type() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u) printf 'application/x-www-form-urlencoded'; return ;;
            -a) shift || true
                if [[ $# -gt 0 ]] && _brow_is_json "$1"; then
                    printf 'application/json'
                else
                    printf 'text/plain'
                fi
                return ;;
            -b|-r) printf 'application/octet-stream'; return ;;
            -f|-F) return ;;
            *)     shift ;;
        esac
    done
}

# _brow_hdr_value <header-lines>  → quoted HTTP_IN_HEADERS assignment value
# Layers the given (newline-separated) header lines over any inherited value so
# the user's preset HTTP_IN_HEADERS survives.
_brow_hdr_value() {
    # shellcheck disable=SC2016 — the ${...} text is literal for the replay.
    printf '"%s${HTTP_IN_HEADERS:+\n$HTTP_IN_HEADERS}"' "$1"
}

# _brow_log_step <header-lines> <invoke> <request-cmd> <label>
# Appends one replay step: a custom-method link when <invoke> is ./<NAME>, then
# the response capture.  The base name is numbered once into _b[N] by
# hal_basename.sh (prefix from the $_prefix variable set in the session header);
# hallink.sh writes its sidecars straight under that base via -s "${_b[N]}", the
# method writes its response under its own auto-generated base, and a trailing
# rename.sh "${_b[N]}" moves that group onto _b[N] — so the files land under the
# predictable name, identical to a live run:
#   _b[<N>]=$(hal_basename.sh -p "$_prefix")
#   hallink.sh -s "${_b[N]}" "${_b[M]}.body" <path> \
#    | HTTP_IN_HEADERS="…" \
#      <method> --link \
#    | rename.sh "${_b[N]}"
# The header (when any) is emitted as a line-continued assignment prefixed onto the
# method stage — the last stage in <request-cmd> — because a standalone assignment
# is not exported to the piped command.  <request-cmd> holds the request stages
# newline-separated, the method carrying no -s (rename supplies the name), e.g.
# 'hallink.sh -s "${_b[2]}" "${_b[1]}.body" links x'$'\n''GET --link'.
_brow_log_step() {
    local hdr="$1" invoke="$2" cmd="$3" label="$4"

    printf '\n' >> "$_BROW_LOG"   # blank line separates each request
    [[ -n "$label" ]] && printf '# %s\n' "$label" >> "$_BROW_LOG"
    [[ "$invoke" == ./* ]] && printf '_ensure_method %s\n' "${invoke#./}" >> "$_BROW_LOG"

    local -a segs=()
    local line
    while IFS= read -r line; do segs+=("$line"); done <<< "$cmd"
    # The method stage (which carries the header) is the last request stage; the
    # rename stage is appended after it.
    local _method_idx=$(( ${#segs[@]} - 1 ))

    # Number the base once into _b[N], then run the pipeline as its own statement:
    # one stage per line, "\"-continued, the method carrying any header as a
    # command-prefix, and a trailing rename onto _b[N].
    local i pipe
    printf '_b[%s]=$(hal_basename.sh -p "$_prefix")\n' "$_BROW_STEP" >> "$_BROW_LOG"
    for (( i = 0; i < ${#segs[@]}; i++ )); do
        (( i == 0 )) && pipe='' || pipe=' | '
        if (( i == _method_idx )) && [[ -n "$hdr" ]]; then
            printf '%sHTTP_IN_HEADERS=%s \\\n' "$pipe" "$(_brow_hdr_value "$hdr")" >> "$_BROW_LOG"
            pipe='   '   # the method continues the assignment line; indent, no pipe
        fi
        printf '%s%s \\\n' "$pipe" "${segs[i]}" >> "$_BROW_LOG"
    done
    printf ' | rename.sh "${_b[%s]}"\n' "$_BROW_STEP" >> "$_BROW_LOG"
}

# ── method symlinks ───────────────────────────────────────────────────────────

_brow_setup_methods() {
    command -v GET >/dev/null 2>&1 && return
    printf 'nahal: HTTP method commands (GET, POST, …) not found in PATH.\n' >&2
    printf 'nahal: Install the HALDiSh archive first: bash HALDiSh-<version>.run\n' >&2
    exit 1
}

# _brow_link_method <METHOD>
# Makes the dispatcher invokable as ./<METHOD> from the session directory, for
# methods that have no installed command on PATH (HEAD, custom verbs).  Creates
# a hardlink to .httpreq.sh; falls back to a symlink when a hardlink is not
# possible (e.g. the session directory is on a different filesystem than the
# install directory).  No-op if the link already exists.
_brow_link_method() {
    local m="$1"
    local dst="${_BROW_OUTDIR}/${m}"
    [[ -e "$dst" ]] && return 0
    local src="${_SCRIPT_DIR}/.httpreq.sh"
    ln -f "$src" "$dst" 2>/dev/null || ln -sf "$src" "$dst"
}

# _brow_invoke_name <METHOD>  → how the method is invoked: bare name or ./<METHOD>.
# A method is invoked bare only when it is a standard installed verb, or resolves
# to a command inside the HALDiSh install dir.  Anything else (HEAD, custom verbs)
# is dispatched via a session-local ./<METHOD> link so a same-named system command
# (e.g. /usr/bin/HEAD from libwww-perl) cannot hijack it.  Used for both the live
# call and the replay log, so they always agree.
_brow_invoke_name() {
    local m="$1" v p
    for v in GET POST PUT PATCH OPTIONS DELETE; do
        [[ "$m" == "$v" ]] && { printf '%s' "$m"; return; }
    done
    p=$(command -v "$m" 2>/dev/null) || p=''
    if [[ -n "$p" && "$(cd "$(dirname "$p")" 2>/dev/null && pwd)" == "$_SCRIPT_DIR" ]]; then
        printf '%s' "$m"
    else
        printf './%s' "$m"
    fi
}

# ── HTTP request ──────────────────────────────────────────────────────────────

# _brow_do_request <method> <url> <accept> [body-flags...]
# Bare-URL request (the session start).  Sets _BROW_LAST_BASE.  Returns 1 on
# failure.  Names the response files up front with hal_basename.sh -s, exactly as
# the generated session.sh replay does, so the live directory matches (no rename).
_brow_do_request() {
    local method="$1" url="$2" accept="$3"
    shift 3
    _BROW_STEP=$(( _BROW_STEP + 1 ))
    hal::log::info "Step ${_BROW_STEP}: ${method} ${url}"

    # Resolve how to invoke the method.  Installed methods (GET, POST, …) are on
    # PATH and called bare; anything else (HEAD, custom verbs) is dispatched via
    # a session-local ./<METHOD> link created on demand.
    local invoke
    invoke=$(_brow_invoke_name "$method")
    [[ "$invoke" == ./* ]] && _brow_link_method "$method"

    # Number the base once, then send.  Accept is a command-prefix on the method
    # (a standalone assignment is not exported).
    local base='' rc=0
    set +e
    base=$(cd "$_BROW_OUTDIR" || exit 1
        _s=$(hal_basename.sh -p "$_BROW_PREFIX") || exit 1
        HTTP_IN_HEADERS="Accept:${accept}" "$invoke" -s "$_s" "$url" "$@" 2>/dev/null)
    rc=$?
    set -e

    if [[ -z "$base" ]]; then
        hal::log::error "Request failed (exit ${rc})"
        return 1
    fi

    local status
    status=$(cat "${_BROW_OUTDIR}/${base}.status" 2>/dev/null || printf '???')
    hal::log::info "  HTTP ${status} — ${base}.{status,headers,body}"
    _BROW_LAST_BASE="$base"
    _BROW_STEP_BASE[$_BROW_STEP]="$base"
}

# _brow_do_link_request <method> <display>
# Link request, unified with the replay pipeline: number the base, resolve and
# record the link with hallink.sh -s (which writes the .source/.halpath/.bindings
# sidecars), and send it with the method reading the link via --link.  Inputs are
# the globals _BROW_REQ_HALLINK (hallink args), _BROW_REQ_BODY (method body flags)
# and _BROW_REQ_CT (Content-Type, or empty).  Sets _BROW_LAST_BASE; returns 1 on
# failure.
_brow_do_link_request() {
    local method="$1" display="$2"
    _BROW_STEP=$(( _BROW_STEP + 1 ))
    hal::log::info "Step ${_BROW_STEP}: ${method} ${display}"

    local invoke
    invoke=$(_brow_invoke_name "$method")
    [[ "$invoke" == ./* ]] && _brow_link_method "$method"

    local base='' rc=0
    set +e
    base=$(cd "$_BROW_OUTDIR" || exit 1
        _s=$(hal_basename.sh -p "$_BROW_PREFIX") || exit 1
        if [[ -n "$_BROW_REQ_CT" ]]; then
            hallink.sh -s "$_s" "${_BROW_REQ_HALLINK[@]}" 2>/dev/null \
                | HTTP_IN_HEADERS="Content-Type:${_BROW_REQ_CT}" \
                  "$invoke" -s "$_s" --link ${_BROW_REQ_BODY[@]+"${_BROW_REQ_BODY[@]}"} 2>/dev/null
        else
            hallink.sh -s "$_s" "${_BROW_REQ_HALLINK[@]}" 2>/dev/null \
                | "$invoke" -s "$_s" --link ${_BROW_REQ_BODY[@]+"${_BROW_REQ_BODY[@]}"} 2>/dev/null
        fi)
    rc=$?
    set -e

    if [[ -z "$base" ]]; then
        hal::log::error "Request failed (exit ${rc})"
        return 1
    fi

    local status
    status=$(cat "${_BROW_OUTDIR}/${base}.status" 2>/dev/null || printf '???')
    hal::log::info "  HTTP ${status} — ${base}.{status,headers,body}"
    _BROW_LAST_BASE="$base"
    _BROW_STEP_BASE[$_BROW_STEP]="$base"
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
# Reads a line from the controlling terminal.  _BROW_TTY overrides /dev/tty (for
# tests), mirroring menu.sh's _MENU_TTY.
_brow_prompt() {
    local _prompt="$1" _var="$2" _default="${3:-}"
    if [[ -n "$_default" ]]; then
        printf '%s [%s]: ' "$_prompt" "$_default" >&2
    else
        printf '%s: ' "$_prompt" >&2
    fi
    local _val
    IFS= read -r _val < "${_BROW_TTY:-/dev/tty}"
    _val="${_val:-$_default}"
    printf -v "$_var" '%s' "$_val"
}

# _brow_normalize_path <input>  → filesystem path on stdout
# Dragging a file from the macOS Finder (and some other apps) into a terminal
# pastes a percent-encoded file:// URI rather than a plain path.  When the input
# carries a file: scheme, strip it and percent-decode; otherwise return the
# input unchanged (so typed paths — which may legitimately contain '%' — are
# never altered).
_brow_normalize_path() {
    local p="$1"
    case "$p" in
        file://*) p="${p#file://}" ;;   # file:///path  → /path
        file:*)   p="${p#file:}"   ;;   # file:/path    → /path
        *)        printf '%s' "$p"; return ;;
    esac
    # Percent-decode: turn %XX into \xXX and let printf interpret the escapes.
    # Backslashes are pre-escaped so a literal '\' in the URI survives intact.
    p="${p//\\/\\\\}"
    printf '%b' "${p//%/\\x}"
}

# _brow_prompt_file <prompt> <varname>
# Prompt for a filesystem path, normalizing a pasted file:// URI (see
# _brow_normalize_path).  An empty entry yields an empty value.
_brow_prompt_file() {
    local _fp_prompt="$1" _fp_var="$2" _fp_raw
    _brow_prompt "$_fp_prompt" _fp_raw ""
    printf -v "$_fp_var" '%s' "$(_brow_normalize_path "$_fp_raw")"
}

# ── URI template expansion ────────────────────────────────────────────────────

# _brow_expand_vars <template> <rel>
# Prompts for template variable values and expands the template via
# uritemplate.sh.  Sets _BROW_LAST_URL (the expanded URL) and _BROW_LAST_BINDINGS
# (the chosen var=value bindings, for the replay).  Must be called directly — not
# in a command substitution — or those globals would be lost to the subshell.
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
        local opts=("${_BROW_NAV}Continue") v
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
            "${_BROW_NAV}Back" \
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

    # Collect ordered bindings for uritemplate.sh.  Expose them to the session
    # logger (as uritemplate/hallink "var=value" args) so the replay can re-expand
    # the same template; the logger quotes them.
    local bindings=()
    local b
    for b in ${_tpl_bindings[@]+"${_tpl_bindings[@]}"}; do
        bindings+=("$b")
    done
    _BROW_LAST_BINDINGS=(${bindings[@]+"${bindings[@]}"})

    _BROW_LAST_URL=$(bash "${_SCRIPT_DIR}/uritemplate.sh" "$tmpl" \
               ${bindings[@]+"${bindings[@]}"})
}

# ── method + body prompt ──────────────────────────────────────────────────────

# Standard methods offered in the selection menu.  GET..DELETE are installed as
# hardlinks on PATH by setup.sh; HEAD has no install hardlink and is dispatched
# via a runtime-local link, exactly like a typed custom method.
readonly _BROW_METHODS=(GET POST PUT PATCH OPTIONS DELETE HEAD)

# _brow_valid_method <token>
# True when the token is a non-empty RFC 7230 method token: ALPHA / DIGIT /
# "!" "#" "$" "%" "&" "'" "*" "+" "-" "." "^" "_" "`" "|" "~".
_brow_valid_method() {
    local _re='^[A-Za-z0-9!#$%&'\''*+.^_`|~-]+$'
    [[ "$1" =~ $_re ]]
}

# Sets _BROW_REQ_METHOD and _BROW_REQ_BODY_ARGS
_BROW_REQ_METHOD=''
_BROW_REQ_BODY_ARGS=()

_brow_prompt_method_body() {
    local default_method="${1:-GET}"
    _BROW_REQ_METHOD=''
    _BROW_REQ_BODY_ARGS=()

    # Select a method from the standard set, or type one by hand.  The prompt
    # shows the default (reset to GET on every follow).
    local choice
    choice=$(printf '%s\n' "${_BROW_METHODS[@]}" "${_BROW_NAV}Other (type a method)" \
        | menu.sh "HTTP method [${default_method}]")

    if [[ "$choice" == "Other (type a method)" ]]; then
        # Free-text entry: uppercase immediately; empty cancels back to the
        # default method; invalid tokens re-prompt in a loop.
        local entry
        while true; do
            _brow_prompt "HTTP method" entry ""
            entry="${entry^^}"
            [[ -z "$entry" ]] && { _BROW_REQ_METHOD="${default_method^^}"; break; }
            if _brow_valid_method "$entry"; then
                _BROW_REQ_METHOD="$entry"
                break
            fi
            hal::log::warn "Invalid method: must be an RFC 7230 token (letters, digits, ! # \$ % & ' * + - . ^ _ \` | ~)"
        done
    else
        _BROW_REQ_METHOD="${choice^^}"
    fi

    # A request body is meaningful for every method except GET/HEAD/OPTIONS.
    case "$_BROW_REQ_METHOD" in
        GET|HEAD|OPTIONS) ;;
        *)
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
                    _brow_prompt_file "File path" bfile
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
                        _brow_prompt_file "File path (empty to finish)" bfile
                        [[ -z "$bfile" ]] && break
                        if [[ -f "$bfile" ]]; then
                            _BROW_REQ_BODY_ARGS+=(-f "$bfile")
                        else
                            hal::log::warn "File not found: ${bfile}"
                        fi
                    done
                    ;;
                "Binary file"*)
                    _brow_prompt_file "File path" bfile
                    if [[ -f "$bfile" ]]; then
                        _BROW_REQ_BODY_ARGS=(-b "$bfile")
                    else
                        hal::log::warn "File not found: ${bfile}"
                    fi
                    ;;
                "Raw upload"*)
                    _brow_prompt_file "File path" bfile
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

# _brow_rel_filter <rel>  → jq/yq filter for a link's href: ._links["<rel>"].href
# Bracket-quote syntax is valid in both jq and mikefarah yq and safely handles
# CURIE prefixes (rels containing ':') and any other non-identifier characters.
_brow_rel_filter() {
    local rel="$1"
    rel="${rel//\\/\\\\}"   # escape backslashes
    rel="${rel//\"/\\\"}"   # escape double quotes
    printf '._links[%s].href' "\"${rel}\""
}

# _brow_qargs <arg...>  → space-joined, shell-quoted argument string
_brow_qargs() {
    local out='' a
    for a in "$@"; do out+="${out:+ }$(printf '%q' "$a")"; done
    printf '%s' "$out"
}

# _brow_req_headers [link_json] <body-flag...>  → non-Accept header lines for the
# replay.  Accept is NOT emitted here: when a request is sent via `--link`,
# httpreq.sh derives Accept from the link's `type`, so repeating it in
# HTTP_IN_HEADERS would be redundant.  Only headers the link cannot supply are
# emitted — currently a Content-Type for body requests.  The leading link_json
# argument is accepted for call-site symmetry but no longer inspected.  Lines are
# newline-separated, as httpreq.sh expects in HTTP_IN_HEADERS.
_brow_req_headers() {
    shift || true   # discard the (now unused) link_json argument
    local ct hdr=''
    ct=$(_brow_infer_content_type "$@")
    [[ -n "$ct" ]] && hdr="Content-Type:${ct}"
    printf '%s' "$hdr"
}

# _brow_follow_link <link_json> <rel> <src_base> [link_idx]
# Sends request, handles response, and logs a replayable step that re-extracts
# the link from <src_base>.body at the current navigation path.  Returns 0 if it
# navigated into a new HAL resource, 1 if non-HAL (stay on current resource).
_brow_follow_link() {
    local link_json="$1" rel="$2" src_base="$3" link_idx="${4:-}"

    local href templated accept url
    accept=$(_brow_accept_for_link "$link_json")

    # The resource the link is being followed *from* is the one currently being
    # viewed — identified by its step number (src_base), not the global
    # _BROW_LAST_BASE (which tracks the most recent fetch and is stale after the
    # user navigates back).  Resolve it to that resource's response base name.
    local _src_base_name="${_BROW_STEP_BASE[$src_base]:-$_BROW_LAST_BASE}"

    if [[ -n "${HAL_LINK_PLUGIN:-}" ]]; then
        local _resource_file=''
        [[ -n "$_src_base_name" ]] && _resource_file="${_BROW_OUTDIR}/${_src_base_name}.body"
        link_json=$(_hal_run_plugins "$link_json" \
            ${_resource_file:+"$_resource_file"} \
            "${_BROW_NAV_PATH[@]+"${_BROW_NAV_PATH[@]}"}" \
            "links" "$rel") \
            || { hal::log::error "plugin failed — aborting navigation"; return 1; }
    fi

    href=$(_brow_qkr "$link_json" 'href')
    templated=$(_brow_qr  "$link_json" '.templated // false')

    # Resolve the live URL (interactive template expansion when templated).
    # _BROW_LAST_BINDINGS captures the chosen var=value bindings for the replay.
    _BROW_LAST_BINDINGS=()
    if [[ "$templated" == "true" ]]; then
        # Called directly (not in $()) so _BROW_LAST_URL/_BROW_LAST_BINDINGS persist.
        _brow_expand_vars "$href" "$rel"
        url="$_BROW_LAST_URL"
    else
        url="$href"
    fi

    # Prompt for method + body
    _brow_prompt_method_body "GET"
    local method="$_BROW_REQ_METHOD"
    local body_args=()
    [[ ${#_BROW_REQ_BODY_ARGS[@]} -gt 0 ]] && body_args=("${_BROW_REQ_BODY_ARGS[@]}")

    # The hal-path from the source resource (the current nav path) down to this
    # link — used for both the live request and the replay log.
    local -a halpath=(${_BROW_NAV_PATH[@]+"${_BROW_NAV_PATH[@]}"} links "$rel")
    [[ -n "$link_idx" ]] && halpath+=("$link_idx")

    # Make the request, mirroring the replay exactly: hallink.sh -s resolves the
    # link from the source body at this path (writing the .source/.halpath/
    # .bindings sidecars) and the method sends it via --link.  The source body is
    # the resource being viewed (src_base), not the last-fetched one.
    _BROW_REQ_HALLINK=("${_src_base_name}.body" "${halpath[@]}")
    [[ ${#_BROW_LAST_BINDINGS[@]} -gt 0 ]] && \
        _BROW_REQ_HALLINK+=(-- "${_BROW_LAST_BINDINGS[@]}")
    _BROW_REQ_BODY=(${body_args[@]+"${body_args[@]}"})
    _BROW_REQ_CT=$(_brow_infer_content_type ${body_args[@]+"${body_args[@]}"})
    if ! _brow_do_link_request "$method" "${method} ${url}"; then
        hal::log::warn "Request failed — staying on current resource"
        return 1
    fi

    # Log the replay step: hallink re-extracts (and re-expands) this link from the
    # source resource's body at the current navigation path; the method sends it
    # via --link, and a trailing rename moves the response onto _b[N].  hallink
    # writes its sidecars straight under _b[N] via -s "${_b[N]}"; reference the
    # source resource's captured base for the body: hallink.sh "${_b[<M>]}.body".
    local src_cmd="hallink.sh -s \"\${_b[${_BROW_STEP}]}\" \"\${_b[${src_base}]}.body\" $(_brow_qargs "${halpath[@]}")"
    # Template var bindings follow a literal '--' separator (hallink.sh requires it).
    [[ ${#_BROW_LAST_BINDINGS[@]} -gt 0 ]] && \
        src_cmd+=" -- $(_brow_qargs "${_BROW_LAST_BINDINGS[@]}")"
    local invoke
    invoke=$(_brow_invoke_name "$method")
    local req_cmd="${src_cmd}"$'\n'"${invoke} --link"
    [[ ${#body_args[@]} -gt 0 ]] && req_cmd+=" $(_brow_qargs "${body_args[@]}")"
    # Label the step with the whole HAL path to the link (including any embeddeds
    # segments traversed to reach it) plus the var=value bindings used to expand
    # the template, e.g. "follow embeddeds orders 0 links search term=hat".
    local _label="follow ${halpath[*]}"
    [[ ${#_BROW_LAST_BINDINGS[@]} -gt 0 ]] && _label+=" ${_BROW_LAST_BINDINGS[*]}"
    _brow_log_step "$(_brow_req_headers "$link_json" ${body_args[@]+"${body_args[@]}"})" \
        "$invoke" "$req_cmd" "$_label"

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
        "${_BROW_NAV}Continue from previous resource" \
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
            _brow_navigate_resource "$json" "$url" "0" "${_BROW_STEP}"
            ;;
    esac
}

_brow_handle_binary() {
    local body_file="$1" ct="$2" url="$3"
    hal::log::info "Binary response (${ct}) — saved: ${body_file}"

    local choice
    choice=$(printf '%s\n' \
        "Open with system application" \
        "${_BROW_NAV}Continue from previous resource" \
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
_BROW_NAV_PATH=()

_brow_navigate_response() {
    local body_file="$1" url="$2" is_top="$3"
    # The replay step index this response is captured as (_b[<src_base>]).
    local src_base="${_BROW_STEP}"
    # Reset the navigation path for this freshly fetched resource, but restore
    # the caller's path on return so a nested fetch doesn't clobber the parent's.
    local _saved_path=("${_BROW_NAV_PATH[@]+"${_BROW_NAV_PATH[@]}"}")
    _BROW_NAV_PATH=()
    local body fmt json
    body=$(cat "$body_file")
    fmt=$(_brow_detect_format "$body")
    json=$(_brow_to_json "$body" "$fmt")
    _brow_navigate_resource "$json" "$url" "$is_top" "$src_base"
    _BROW_NAV_PATH=("${_saved_path[@]+"${_saved_path[@]}"}")
}

# _brow_navigate_resource <json> <url> <is_top> <src_base>
# Interactive navigation.  Returns 0 on "back", exits on "quit".
# <src_base> is the logical step name of the body this resource was loaded from.
_brow_navigate_resource() {
    local json="$1" url="$2" is_top="$3" src_base="$4"

    # A HAL document may be a single resource (object) or an array of resources
    # (e.g. a collection returned as a bare JSON/XML/YAML array).  Object key
    # probes like has("_links") error on an array, so dispatch by type first.
    local rtype
    rtype=$(_brow_qtype "$json")
    case "$rtype" in
        array)  _brow_navigate_array "$json" "$url" "$is_top" "$src_base"; return ;;
        object) ;;
        *)      # scalar — nothing to navigate into; just show it
                _brow_pretty "$json"; return ;;
    esac

    local has_links has_embedded has_props has_docs
    has_links=$(_brow_qr    "$json" 'has("_links")')
    has_embedded=$(_brow_qr "$json" 'has("_embedded")')
    has_props=$(_brow_qr    "$json" 'del(._links,._embedded) | length > 0')
    # Offer docs only when the resource has a curies array AND at least one rel
    # actually uses a defined CURIE prefix.
    has_docs="false"
    [[ "$has_links" == "true" && -n "$(_brow_curi_rels "$json")" ]] && has_docs="true"

    # The response base this resource was loaded from (empty for a resource that
    # was parsed from a file/text start rather than fetched into a numbered base).
    local _base="${_BROW_STEP_BASE[$src_base]:-}"

    while true; do
        if [[ -n "$_base" ]]; then
            printf '\n[ URL: %s | basename: %s ]\n' "$url" "$_base" >&2
        else
            printf '\n[ URL: %s ]\n' "$url" >&2
        fi

        local opts=()
        [[ "$has_links"    == "true" ]] && opts+=("links")
        [[ "$has_embedded" == "true" ]] && opts+=("embedded")
        [[ "$has_props"    == "true" ]] && opts+=("properties")
        [[ "$has_docs"     == "true" ]] && opts+=("docs")
        opts+=("${_BROW_NAV}print resource")
        opts+=("${_BROW_NAV}print resource (raw)")
        if [[ "$is_top" == "1" ]]; then
            opts+=("${_BROW_NAV}quit")
        else
            opts+=("${_BROW_NAV}back")
            opts+=("${_BROW_NAV}quit")
        fi

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Resource")

        case "$chosen" in
            links)           _brow_nav_links      "$json" "$url" "$src_base" ;;
            embedded)        _brow_nav_embedded   "$json" "$src_base" ;;
            properties)      _brow_nav_properties "$json" ;;
            docs)            _brow_nav_docs       "$json" "$src_base" ;;
            "print resource") _brow_pretty "$json" ;;
            "print resource (raw)") _brow_raw "$json" ;;
            back)            return 0 ;;
            quit)            exit 0 ;;
        esac
    done
}

# _brow_navigate_array <json> <url> <is_top>
# Navigate an array of HAL resources: list the elements (showing each one's
# self href when present), then recurse into the chosen element as a resource.
# Returns 0 on "back", exits on "quit".
_brow_navigate_array() {
    local json="$1" url="$2" is_top="$3" src_base="$4"
    local count
    count=$(_brow_qr "$json" 'length')
    local _base="${_BROW_STEP_BASE[$src_base]:-}"

    while true; do
        if [[ -n "$_base" ]]; then
            printf '\n[ URL: %s | basename: %s ] (array of %s)\n' "$url" "$_base" "$count" >&2
        else
            printf '\n[ URL: %s ] (array of %s)\n' "$url" "$count" >&2
        fi

        local opts=() i
        for (( i = 0; i < count; i++ )); do
            local entry href
            entry=$(_brow_qi "$json" "$i")
            href=$(_brow_qr "$entry" '._links.self.href // .href // empty')
            if [[ -n "$href" ]]; then
                opts+=("$(( i + 1 )): ${href}")
            else
                opts+=("$(( i + 1 ))")
            fi
        done
        opts+=("${_BROW_NAV}print resource")
        opts+=("${_BROW_NAV}print resource (raw)")
        if [[ "$is_top" == "1" ]]; then
            opts+=("${_BROW_NAV}quit")
        else
            opts+=("${_BROW_NAV}back")
            opts+=("${_BROW_NAV}quit")
        fi

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Array")

        case "$chosen" in
            "print resource") _brow_pretty "$json" ;;
            "print resource (raw)") _brow_raw "$json" ;;
            back)             return 0 ;;
            quit)             exit 0 ;;
            *)
                local idx="${chosen%%:*}"
                local elem
                elem=$(_brow_qi "$json" "$(( idx - 1 ))")
                local _saved_path=("${_BROW_NAV_PATH[@]+"${_BROW_NAV_PATH[@]}"}")
                _BROW_NAV_PATH=("${_saved_path[@]+"${_saved_path[@]}"}" "$(( idx - 1 ))")
                _brow_navigate_resource "$elem" "${url} [${idx}]" "0" "$src_base"
                _BROW_NAV_PATH=("${_saved_path[@]+"${_saved_path[@]}"}")
                ;;
        esac
    done
}

# _brow_rel_templated_suffix <links_json> <rel>  → " {T}" when the link (or the
# first element of an array-valued link) is templated, else nothing.
_brow_rel_templated_suffix() {
    local links="$1" rel="$2" lobj ltype templated
    lobj=$(_brow_qk "$links" "$rel")
    ltype=$(_brow_qtype "$lobj")
    if [[ "$ltype" == "array" ]]; then
        templated=$(_brow_qr "$lobj" '.[0].templated // false')
    else
        templated=$(_brow_qr "$lobj" '.templated // false')
    fi
    [[ "$templated" == "true" ]] && printf ' {T}'
    return 0   # never fail the caller's command (it runs under set -e)
}

# _brow_nav_links <json> <url> <src_base>
# Lists the resource's followable link rels (never the reserved `curies` array).
# With _BROW_SHOW_CURIES=true each rel is shown verbatim (e.g. curie1:curied);
# otherwise rels are shown by local name (prefix stripped) and grouped, so several
# prefixed rels sharing a local name collapse into one entry that disambiguates on
# selection.  Either way the real `_links` key is what gets followed and logged.
_brow_nav_links() {
    local json="$1" url="$2" src_base="$3"
    local links
    links=$(_brow_qk "$json" "_links")

    # All followable rels (exclude the reserved CURIE definitions).
    local -a all_rels=()
    local r
    while IFS= read -r r; do
        [[ "$r" == "curies" ]] && continue
        all_rels+=("$r")
    done < <(_brow_qr "$links" 'keys[]')

    while true; do
        # Build parallel arrays: a menu label and the newline-joined real rels it
        # stands for.  Single-rel entries follow directly; multi-rel entries (only
        # possible in without-curies mode) disambiguate after selection.
        local -a entry_label=() entry_rels=()
        if [[ "$_BROW_SHOW_CURIES" == "true" ]]; then
            for r in "${all_rels[@]+"${all_rels[@]}"}"; do
                entry_label+=("${r}$(_brow_rel_templated_suffix "$links" "$r")")
                entry_rels+=("$r")
            done
        else
            # Curie names define which prefixes may be stripped; an absolute-URI
            # rel like "https://ex/rel" contains ':' but is not a curie and stays.
            local -a curi_names=()
            while IFS= read -r r; do
                [[ -n "$r" ]] && curi_names+=("$r")
            done < <(_brow_curi_names "$links")

            # Group real rels by local name, preserving first-appearance order.
            local -a g_local=() g_rels=()
            local local_name j found pfx cn
            for r in "${all_rels[@]+"${all_rels[@]}"}"; do
                local_name="$r"
                if [[ "$r" == *:* ]]; then
                    pfx="${r%%:*}"
                    for cn in "${curi_names[@]+"${curi_names[@]}"}"; do
                        [[ "$cn" == "$pfx" ]] && { local_name="${r#*:}"; break; }
                    done
                fi
                found=-1
                for j in "${!g_local[@]}"; do
                    [[ "${g_local[j]}" == "$local_name" ]] && { found=$j; break; }
                done
                if [[ $found -ge 0 ]]; then g_rels[found]+=$'\n'"$r"
                else g_local+=("$local_name"); g_rels+=("$r"); fi
            done
            for j in "${!g_local[@]}"; do
                local -a members=()
                while IFS= read -r r; do members+=("$r"); done <<< "${g_rels[j]}"
                if [[ ${#members[@]} -eq 1 ]]; then
                    entry_label+=("${g_local[j]}$(_brow_rel_templated_suffix "$links" "${members[0]}")")
                    entry_rels+=("${members[0]}")
                else
                    # Ambiguous: label notes the contributing prefixes ("-" for a
                    # prefix-less rel); the {T} marker is deferred to the submenu.
                    local prefixes='' m pfx
                    for m in "${members[@]}"; do
                        if [[ "$m" == *:* ]]; then pfx="${m%%:*}"; else pfx="-"; fi
                        prefixes+="${prefixes:+, }${pfx}"
                    done
                    entry_label+=("${g_local[j]} (${prefixes})")
                    entry_rels+=("${g_rels[j]}")
                fi
            done
        fi

        local opts=("${_BROW_NAV}back" "${entry_label[@]+"${entry_label[@]}"}")
        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Links")
        [[ "$chosen" == "back" ]] && return 0

        # Map the chosen label back to its real rel(s).
        local sel=-1 k
        for k in "${!entry_label[@]}"; do
            [[ "${entry_label[k]}" == "$chosen" ]] && { sel=$k; break; }
        done
        [[ $sel -lt 0 ]] && continue

        local -a sel_members=()
        while IFS= read -r r; do sel_members+=("$r"); done <<< "${entry_rels[sel]}"

        local rel
        if [[ ${#sel_members[@]} -gt 1 ]]; then
            local dis_opts=("${_BROW_NAV}back") m
            for m in "${sel_members[@]}"; do
                dis_opts+=("${m}$(_brow_rel_templated_suffix "$links" "$m")")
            done
            local dchoice
            dchoice=$(printf '%s\n' "${dis_opts[@]}" | menu.sh "Choose rel")
            [[ "$dchoice" == "back" ]] && continue
            rel="${dchoice% \{T\}}"
        else
            rel="${sel_members[0]}"
        fi

        local lobj ltype
        lobj=$(_brow_qk "$links" "$rel")
        ltype=$(_brow_qtype "$lobj")

        # If link is an array, let user pick which one.  link_idx feeds the
        # replay hal-path (links <rel> <idx>); empty for a single link object.
        local link_obj link_idx=''
        if [[ "$ltype" == "array" ]]; then
            local count i idx_opts=("${_BROW_NAV}back")
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
            link_idx="$idx"
        else
            link_obj="$lobj"
        fi

        # Show href, then loop on the action menu so "show link details" keeps
        # offering actions for the same link instead of dropping back to the list.
        # A deprecated link (one carrying a `deprecation` URL) also offers to open
        # that documentation page in the browser.
        local href depr
        href=$(_brow_qkr "$link_obj" 'href')
        depr=$(_brow_qr "$link_obj" '.deprecation // empty')
        while true; do
            printf '\n  %s → %s\n' "$rel" "$href" >&2
            [[ -n "$depr" ]] && printf '  (deprecated: %s)\n' "$depr" >&2

            local -a action_opts=("follow (send request)" "show link details")
            [[ -n "$depr" ]] && action_opts+=("open deprecation docs")
            action_opts+=("${_BROW_NAV}back")

            local action
            action=$(printf '%s\n' "${action_opts[@]}" | menu.sh "Action")

            case "$action" in
                # `|| true`: a non-HAL response makes _brow_follow_link return 1 as
                # a "stay on current resource" signal — not an error. Without this,
                # `set -e` would treat the failed case arm as fatal and exit.
                "follow (send request)") _brow_follow_link "$link_obj" "$rel" "$src_base" "$link_idx" || true; break ;;
                "show link details")     _brow_pretty "$link_obj" ;;
                "open deprecation docs") _brow_open_deprecation "$link_obj" "$rel" "$src_base" ;;
                back)                    break ;;
            esac
        done
    done
}

# _brow_nav_embedded <json> <src_base>
_brow_nav_embedded() {
    local json="$1" src_base="$2"
    local embedded rels
    embedded=$(_brow_qk "$json" "_embedded")
    rels=$(_brow_qr "$embedded" 'keys[]')

    while true; do
        local opts=("${_BROW_NAV}back")
        while IFS= read -r rel; do opts+=("$rel"); done <<< "$rels"

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Embedded")
        [[ "$chosen" == "back" ]] && return 0

        local item itype
        item=$(_brow_qk "$embedded" "$chosen")
        itype=$(_brow_qtype "$item")

        local _saved_path=("${_BROW_NAV_PATH[@]+"${_BROW_NAV_PATH[@]}"}")

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
            _BROW_NAV_PATH=("${_saved_path[@]+"${_saved_path[@]}"}" "embeddeds" "$chosen" "$(( idx - 1 ))")
            _brow_navigate_resource "$elem" "(embedded ${chosen}[${idx}])" "0" "$src_base"
        else
            _BROW_NAV_PATH=("${_saved_path[@]+"${_saved_path[@]}"}" "embeddeds" "$chosen")
            _brow_navigate_resource "$item" "(embedded ${chosen})" "0" "$src_base"
        fi
        _BROW_NAV_PATH=("${_saved_path[@]+"${_saved_path[@]}"}")
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
    vtype=$(_brow_qtype "$val")

    case "$vtype" in
        string|number|boolean|null)
            printf '%s\n' "$(_brow_qr "$val" '.')"
            ;;
        object)
            local keys
            keys=$(_brow_qr "$val" 'keys[]')
            while true; do
                local opts=("${_BROW_NAV}print" "${_BROW_NAV}back")
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
        local opts=("${_BROW_NAV}back")
        while IFS= read -r k; do opts+=("$k"); done <<< "$keys"

        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Properties")
        [[ "$chosen" == "back" ]] && return 0

        local val
        val=$(_brow_qk "$props" "$chosen")
        _brow_nav_value "$val" "$chosen"
    done
}

# ── documentation (CURIE) ─────────────────────────────────────────────────────

# _brow_curies_mode <value>  → 'true' (with curies) or 'false' (without) on stdout;
# returns 1 on an unrecognized value.  Accepts on/true and off/false (any case).
_brow_curies_mode() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        on|true)   printf 'true'  ;;
        off|false) printf 'false' ;;
        *)         return 1 ;;
    esac
}

# _brow_curi_names <links_json>  → the names defined in _links.curies, one per
# line (empty when there is no curies array).
_brow_curi_names() {
    local links="$1"
    [[ "$(_brow_qr "$links" 'has("curies")')" == "true" ]] || return 0
    local curies_json count i
    curies_json=$(_brow_qk "$links" "curies")
    count=$(_brow_qr "$curies_json" 'length')
    for (( i = 0; i < count; i++ )); do
        _brow_qkr "$(_brow_qi "$curies_json" "$i")" 'name'
    done
}

# _brow_curi_rels <json>  → CURIE-prefixed rels, one per line
# Lists each _links rel of the form "<prefix>:<name>" whose <prefix> is defined
# in the resource's _links.curies array.  Prints nothing when the resource has
# no curies array or no rel uses a defined prefix.
_brow_curi_rels() {
    local json="$1"
    local links
    links=$(_brow_qk "$json" "_links")
    [[ "$(_brow_qr "$links" 'has("curies")')" == "true" ]] || return 0

    local curies_json count i
    curies_json=$(_brow_qk "$links" "curies")
    count=$(_brow_qr "$curies_json" 'length')
    local -a names=()
    for (( i = 0; i < count; i++ )); do
        names+=("$(_brow_qkr "$(_brow_qi "$curies_json" "$i")" 'name')")
    done

    local rel prefix n
    while IFS= read -r rel; do
        [[ "$rel" == *:* ]] || continue
        prefix="${rel%%:*}"
        for n in "${names[@]}"; do
            [[ "$n" == "$prefix" ]] && { printf '%s\n' "$rel"; break; }
        done
    done < <(_brow_qr "$links" 'keys[]')
}

# _brow_curi_link <links_json> <rel>  → the matching curie link object with its
# href expanded to the documentation URL per HAL rules (the `{rel}` template is
# substituted with the rel's local name, and `templated` becomes false).  The
# rest of the curie object (e.g. `name`) is preserved, so the result is a proper
# link object that can be passed through HAL_LINK_PLUGIN.  Returns 1 when no
# curie defines the rel's prefix.
_brow_curi_link() {
    local links="$1" rel="$2"
    local prefix="${rel%%:*}" local_name="${rel#*:}"
    local curies_json count i obj name href url
    curies_json=$(_brow_qk "$links" "curies")
    count=$(_brow_qr "$curies_json" 'length')
    for (( i = 0; i < count; i++ )); do
        obj=$(_brow_qi "$curies_json" "$i")
        name=$(_brow_qkr "$obj" 'name')
        if [[ "$name" == "$prefix" ]]; then
            href=$(_brow_qkr "$obj" 'href')
            url=$(bash "${_SCRIPT_DIR}/uritemplate.sh" "$href" "rel=${local_name}")
            if [[ "$_BROW_TOOL" == yq ]]; then
                printf '%s' "$obj" | HAL_HREF="$url" yq -o json -I0 \
                    '.href = env(HAL_HREF) | .templated = false'
            else
                printf '%s' "$obj" | jq -c --arg h "$url" '.href = $h | .templated = false'
            fi
            return 0
        fi
    done
    return 1
}

# _brow_resolve_curi_url <links_json> <rel>  → documentation URL on stdout, i.e.
# the expanded href of the matching curie link.  Returns 1 when no curie matches.
_brow_resolve_curi_url() {
    local link
    link=$(_brow_curi_link "$1" "$2") || return 1
    _brow_qkr "$link" 'href'
}

# _brow_open_docs <url>  → opens the documentation page in the default browser
_brow_open_docs() {
    local url="$1"
    hal::log::info "Opening: ${url}"
    if command -v open >/dev/null 2>&1; then
        open "$url"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url"
    else
        hal::log::warn "No browser opener found (tried open, xdg-open).  URL: ${url}"
    fi
}

# _brow_open_deprecation <link_json> <rel> <src_base>
# Opens a deprecated link's `deprecation` URL (a documentation page explaining the
# deprecation) in the browser.  The URL is run through HAL_LINK_PLUGIN — the same
# filters a link's href gets when it is followed — by rewriting a copy of the link
# so its href is the deprecation URL, piping it through the plugin chain, then
# opening the resulting href.  No-op (warns) when the link carries no deprecation.
_brow_open_deprecation() {
    local link_json="$1" rel="$2" src_base="${3:-}"

    local depr
    depr=$(_brow_qr "$link_json" '.deprecation // empty')
    [[ -z "$depr" ]] && { hal::log::warn "link has no deprecation URL"; return 0; }

    # Carry the deprecation URL as the link's href so the plugin chain treats it
    # exactly like a followable href (prepend a base, expand a CURIE, …), keeping
    # the rest of the link object as context for the plugins.
    local depr_link
    if [[ "$_BROW_TOOL" == yq ]]; then
        depr_link=$(printf '%s' "$link_json" | HAL_HREF="$depr" yq -o json -I0 '.href = env(HAL_HREF)')
    else
        depr_link=$(printf '%s' "$link_json" | jq -c --arg h "$depr" '.href = $h')
    fi

    if [[ -n "${HAL_LINK_PLUGIN:-}" ]]; then
        # The resource the link belongs to (by step number), not the last fetch.
        local _src_base_name="${_BROW_STEP_BASE[$src_base]:-$_BROW_LAST_BASE}"
        local _resource_file=''
        [[ -n "$_src_base_name" ]] && _resource_file="${_BROW_OUTDIR}/${_src_base_name}.body"
        depr_link=$(_hal_run_plugins "$depr_link" \
            ${_resource_file:+"$_resource_file"} \
            "${_BROW_NAV_PATH[@]+"${_BROW_NAV_PATH[@]}"}" \
            "links" "$rel") \
            || { hal::log::error "plugin failed — not opening deprecation docs"; return 0; }
    fi

    local url
    url=$(_brow_qkr "$depr_link" 'href')
    _brow_open_docs "$url"
}

# _brow_nav_docs <json> <src_base>
# Menu of CURIE-prefixed rels; resolves the chosen rel's curie template to a
# documentation URL and opens it in the browser.
_brow_nav_docs() {
    local json="$1" src_base="${2:-}"
    local links
    links=$(_brow_qk "$json" "_links")

    # The resource these docs belong to (by step number), not the last fetch.
    local _src_base_name="${_BROW_STEP_BASE[$src_base]:-$_BROW_LAST_BASE}"

    local -a rels=()
    local r
    while IFS= read -r r; do [[ -n "$r" ]] && rels+=("$r"); done < <(_brow_curi_rels "$json")

    while true; do
        local opts=("${_BROW_NAV}back" "${rels[@]+"${rels[@]}"}")
        local chosen
        chosen=$(printf '%s\n' "${opts[@]}" | menu.sh "Docs")
        [[ "$chosen" == "back" ]] && return 0

        local doc_link doc_url
        if doc_link=$(_brow_curi_link "$links" "$chosen"); then
            # Run the resolved curie link through HAL_LINK_PLUGIN before opening,
            # exactly as link following does, so plugins can rewrite the doc href.
            if [[ -n "${HAL_LINK_PLUGIN:-}" ]]; then
                local _resource_file=''
                [[ -n "$_src_base_name" ]] && \
                    _resource_file="${_BROW_OUTDIR}/${_src_base_name}.body"
                doc_link=$(_hal_run_plugins "$doc_link" \
                    ${_resource_file:+"$_resource_file"} \
                    "${_BROW_NAV_PATH[@]+"${_BROW_NAV_PATH[@]}"}" \
                    "docs" "$chosen") \
                    || { hal::log::error "plugin failed — not opening docs"; continue; }
            fi
            doc_url=$(_brow_qkr "$doc_link" 'href')
            _brow_open_docs "$doc_url"
        else
            hal::log::warn "No CURI found for prefix: ${chosen%%:*}"
        fi
    done
}

# ── argument resolution ───────────────────────────────────────────────────────

_brow_usage() {
    local name
    name="$(basename "$0")"
    printf 'Usage:\n' >&2
    printf '  %s [-p <prefix>] [-c on|off] <URL>\n' "$name" >&2
    printf '  %s [-p <prefix>] [-c on|off] <link-text>              # HAL link object (JSON/XML/YAML)\n' "$name" >&2
    printf '  %s [-p <prefix>] [-c on|off] <resource-file> [path…]  # link extracted from a file\n' "$name" >&2
    printf '\n-p <prefix>: base-name prefix for response files (prompted if omitted; empty allowed)\n' >&2
    printf -- '-c on|off  : links menu shows full CURIE-prefixed rels (on/true) or local names\n' >&2
    printf '             (off/false, default); also via NAHAL_CURIES.  -c overrides the env var.\n' >&2
    printf 'Path examples: links self    |  links items 0\n' >&2
}

_BROW_START_URL=''
_BROW_START_LINK_JSON=''
_BROW_START_MODE=''      # url | link | file — how the session was started
_BROW_START_ARGS=()      # original CLI args, replayed verbatim in step 1

_brow_resolve_start() {
    local first="${1:-}"
    shift || true

    if [[ -z "$first" ]]; then _brow_usage; exit 1; fi

    # Case 1: URL
    if [[ "$first" == http://* || "$first" == https://* ]]; then
        _BROW_START_URL="$first"
        _BROW_START_MODE=url
        _BROW_START_ARGS=("$first")
        return
    fi

    if [[ $# -gt 0 ]]; then
        # Case 3: resource file + navigation path to a link
        _BROW_START_MODE=file
        _BROW_START_ARGS=("$first" "$@")
        [[ ! -f "$first" ]] && { printf 'nahal: not a file: %s\n' "$first" >&2; exit 1; }
        local link_raw link_fmt link_json
        link_raw=$(bash "${_SCRIPT_DIR}/hal.sh" "$first" "$@")
        if [[ -z "$link_raw" ]]; then
            printf 'nahal: could not extract link at path\n' >&2; exit 1
        fi
        link_fmt=$(_brow_detect_format "$link_raw")
        link_json=$(_brow_to_json "$link_raw" "$link_fmt")
        link_json=$(_hal_run_plugins "$link_json" "$first" "$@") \
            || { printf 'nahal: plugin failed on start link\n' >&2; exit 1; }
        _BROW_START_LINK_JSON="$link_json"
        _BROW_START_URL=$(_brow_qkr "$link_json" 'href')
        if [[ -z "$_BROW_START_URL" || "$_BROW_START_URL" == "null" ]]; then
            printf 'nahal: extracted path does not contain a link with .href\n' >&2; exit 1
        fi
    else
        # Case 2: link text (JSON, XML, or YAML) passed directly as argument
        _BROW_START_MODE=link
        _BROW_START_ARGS=("$first")
        local fmt json
        fmt=$(_brow_detect_format "$first")
        json=$(_brow_to_json "$first" "$fmt")
        _BROW_START_LINK_JSON="$json"
        _BROW_START_URL=$(_brow_qkr "$json" 'href')
        if [[ -z "$_BROW_START_URL" || "$_BROW_START_URL" == "null" ]]; then
            printf 'nahal: link has no .href field\n' >&2; exit 1
        fi
    fi
}

# _brow_emit_plugin_env
# Emits (to session.sh) the recorded plugin environment: the ordered plugin-name
# array and each plugin's `-config` snippet (%q-encoded).  A replay uses these to
# restore the env (plugin list unset) or diff against it (list set) — see
# _check_plugin_env in session_prelude.sh.  The entry-time "was the plugin list
# set" flag is captured by the prelude itself (before _restore_plugins runs).
_brow_emit_plugin_env() {
    local -a _plugins=()
    [[ -n "${HAL_LINK_PLUGIN:-}" ]] && IFS=: read -ra _plugins <<< "$HAL_LINK_PLUGIN"

    local _p
    printf '_plugin_cfg_names=('
    for _p in "${_plugins[@]+"${_plugins[@]}"}"; do
        [[ -z "$_p" ]] && continue
        printf ' %q' "$_p"
    done
    printf ' )\n'

    local _i=0 _cfg
    for _p in "${_plugins[@]+"${_plugins[@]}"}"; do
        [[ -z "$_p" ]] && continue
        _cfg=''
        command -v "$_p" >/dev/null 2>&1 && _cfg="$("$_p" -config 2>/dev/null || true)"
        printf '_plugin_cfg_%d=%q\n' "$_i" "$_cfg"
        _i=$((_i + 1))
    done
}

# ── main ──────────────────────────────────────────────────────────────────────
# Guard so the file can be sourced (e.g. by the test suite) to exercise the
# helper functions in isolation without launching an interactive session.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then

# Curies display mode: NAHAL_CURIES sets the default, -c overrides it (CLI wins).
if [[ -n "${NAHAL_CURIES:-}" ]]; then
    _BROW_SHOW_CURIES=$(_brow_curies_mode "$NAHAL_CURIES") || {
        printf 'nahal: invalid NAHAL_CURIES value: %s (use on|off|true|false)\n' \
            "$NAHAL_CURIES" >&2; exit 2; }
fi

# -p <prefix> sets the response-file base-name prefix (empty allowed); when
# omitted we prompt for it.  -c on|off toggles CURIE-prefixed rels in the links
# menu.  Options precede the URL / link / file arguments.
while getopts ":p:c:" _opt; do
    case "$_opt" in
        p) _BROW_PREFIX="$OPTARG"; _BROW_PREFIX_SET=1 ;;
        c) _BROW_SHOW_CURIES=$(_brow_curies_mode "$OPTARG") || {
               printf 'nahal: invalid -c value: %s (use on|off|true|false)\n' \
                   "$OPTARG" >&2; exit 2; } ;;
        *) _brow_usage; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ $# -lt 1 ]] && { _brow_usage; exit 1; }

_brow_init_tool
_brow_setup_methods
_brow_resolve_start "$@"

# Ask for the response-file prefix when -p was not given (empty is accepted).
[[ "$_BROW_PREFIX_SET" -eq 1 ]] || _brow_prompt "File prefix (empty for none)" _BROW_PREFIX ""

# Session directory (next to where the script is run)
_BROW_OUTDIR="$(pwd)/nahal_$(date +%Y%m%dT%H%M%S)"
mkdir -p "$_BROW_OUTDIR"
_BROW_LOG="${_BROW_OUTDIR}/session.sh"
_BROW_PRELUDE="${_BROW_OUTDIR}/session_prelude.sh"

# The replay is split in two so session.sh stays short and readable:
#   session_prelude.sh — the session-independent machinery (argument parsing, the
#                        HALDiSh environment bootstrap, the _ensure_method helper,
#                        and the plugin list/env restore-and-diff checks).
#   session.sh         — the human-readable header, the recorded per-session values
#                        (_prefix, _plugins_created, _plugin_cfg_*), a `source` of
#                        the prelude, then one block per request step.
# session.sh sets the recorded values BEFORE sourcing the prelude; the prelude
# consumes them.  The prelude's bootstrap activates the HALDiSh environment
# (GET/POST/…, hallink.sh, rename.sh, uritemplate.sh) or explains how to install
# it; _ensure_method recreates a custom-method link if the session dir was moved.

# ── session_prelude.sh — the static, session-independent replay machinery ─────
cat > "$_BROW_PRELUDE" <<'_NAHAL_PRELUDE'
#!/usr/bin/env bash
# HAL Browse session — replay preamble, sourced by session.sh.  Session-
# independent machinery: argument parsing, the HALDiSh environment bootstrap,
# the _ensure_method helper, and the plugin list/env restore-and-diff checks.
# session.sh sets the recorded per-session values (_prefix, _plugins_created,
# _plugin_cfg_*) before sourcing this file; the code below consumes them.

# ── arguments ─────────────────────────────────────────────────────────────────
# -p <prefix> overrides the response-file base-name prefix for this replay.
_cli_prefix_set=0 _cli_prefix=''
while getopts ':p:' _opt; do
    case "$_opt" in
        p) _cli_prefix=$OPTARG; _cli_prefix_set=1 ;;
        *) printf 'session.sh: usage: session.sh [-p <prefix>]\n' >&2; exit 2 ;;
    esac
done
shift $(( OPTIND - 1 ))
[ $# -gt 0 ] && { printf 'session.sh: usage: session.sh [-p <prefix>]\n' >&2; exit 2; }

# ── HALDiSh bootstrap ─────────────────────────────────────────────────────────
# Make the toolkit available: use it if already active, otherwise source env.sh
# from $HAL_LIB_DIR or the default install location.  If it cannot be found,
# explain how to install it (default location ~/.local/lib/haldish) and exit.
if ! command -v hallink.sh >/dev/null 2>&1; then
    for _hal_env in "${HAL_LIB_DIR:-}/env.sh" "${HOME}/.local/lib/haldish/env.sh"; do
        [ -f "$_hal_env" ] && { . "$_hal_env"; break; }
    done
fi
if ! command -v hallink.sh >/dev/null 2>&1; then
    cat >&2 <<'EOF'
HALDiSh toolkit not found — it is required to replay this session.

Install it (extracts to ~/.local/lib/haldish by default):

  curl -LO https://github.com/C06A/HALDiSh/releases/latest/download/HALDiSh-<version>.run
  bash HALDiSh-<version>.run

Pick the latest <version> from https://github.com/C06A/HALDiSh/releases

Then re-run this script, or activate the environment first:

  source ~/.local/lib/haldish/env.sh
EOF
    exit 1
fi
. hal_utils.sh   # ensure hal::log::* are loaded (no-op if already sourced)

_ensure_method() {
    command -v "$1" >/dev/null 2>&1 && return 0
    [ -e "./$1" ] && return 0
    local src; src="$(dirname "$(command -v GET)")/.httpreq.sh"
    ln -f "$src" "./$1" 2>/dev/null || ln -sf "$src" "./$1"
}

_b=()   # response base name captured per step

# Resolve the response-file prefix: session.sh set the recorded default in
# _prefix; an exported HAL_FILE_PREFIX overrides it (set-but-empty is honored);
# -p overrides both.
[ "${HAL_FILE_PREFIX+x}" = x ] && _prefix=$HAL_FILE_PREFIX
[ "$_cli_prefix_set" -eq 1 ]   && _prefix=$_cli_prefix

# Capture, before _restore_plugins can change it, whether the caller set the
# plugin list at replay entry — this gates the env restore in _check_plugin_env.
_hal_plugins_set_at_entry=0
[ -n "${HAL_LINK_PLUGIN+x}" ] && _hal_plugins_set_at_entry=1

# Plugin auto-restore: if HAL_LINK_PLUGIN is not set at all (not even to an empty
# value) and every plugin recorded at session creation is still available, restore
# the recorded list so the replay runs with the same plugins.  If the variable is
# set (even to empty) or any recorded plugin is missing, leave it untouched and
# fall through to the diff below (current behavior).
_restore_plugins() {
    [ -n "${HAL_LINK_PLUGIN+x}" ] && return 0   # already set (even empty): leave as-is
    [ -n "$_plugins_created" ]    || return 0   # nothing recorded to restore
    local -a _was=(); local _p
    IFS=: read -ra _was <<< "$_plugins_created"
    for _p in "${_was[@]+"${_was[@]}"}"; do
        [ -z "$_p" ] && continue
        command -v "$_p" >/dev/null 2>&1 || {
            hal::log::warn "not restoring HAL_LINK_PLUGIN: recorded plugin $_p is missing"
            return 0
        }
    done
    export HAL_LINK_PLUGIN="$_plugins_created"
    hal::log::info "restored HAL_LINK_PLUGIN from session: $_plugins_created"
}
_restore_plugins

# Plugin list check: compare HAL_LINK_PLUGIN at replay against the list recorded
# when this session was created.  OK = present in both, INFO = new at replay,
# WARN = recorded plugin missing at replay.
_check_plugins() {
    local -a _was=() _now=(); local _p
    [ -n "$_plugins_created" ]      && IFS=: read -ra _was <<< "$_plugins_created"
    [ -n "${HAL_LINK_PLUGIN:-}" ]   && IFS=: read -ra _now <<< "${HAL_LINK_PLUGIN:-}"
    for _p in "${_was[@]+"${_was[@]}"}"; do
        [ -z "$_p" ] && continue
        if printf '%s\n' "${_now[@]+"${_now[@]}"}" | grep -qxF -- "$_p"; then
            hal::log::ok   "plugin $_p"
        else
            hal::log::warn "plugin $_p missing at replay"
        fi
    done
    for _p in "${_now[@]+"${_now[@]}"}"; do
        [ -z "$_p" ] && continue
        printf '%s\n' "${_was[@]+"${_was[@]}"}" | grep -qxF -- "$_p" \
            || hal::log::info "plugin $_p new at replay"
    done
}
_check_plugins

# Plugin env check/restore: the recorded plugin-name array (_plugin_cfg_names)
# and per-plugin `-config` snippets (_plugin_cfg_<i>) were set by session.sh, and
# _hal_plugins_set_at_entry (above) captured whether the caller set HAL_LINK_PLUGIN
# before _restore_plugins ran.  When the plugin list was unset at replay entry
# the session owns the environment, so each recorded snippet is eval'd to restore
# it; when the list was set the caller drives the environment, so each plugin's
# current `-config` is only diffed against the recorded snippet and reported.
_check_plugin_env() {
    local _i _p _v _rec _now
    for _i in "${!_plugin_cfg_names[@]}"; do
        _p="${_plugin_cfg_names[$_i]}"
        _v="_plugin_cfg_${_i}"
        _rec="${!_v-}"
        if [ "${_hal_plugins_set_at_entry:-0}" -eq 0 ]; then
            [ -n "$_rec" ] && { eval "$_rec"; hal::log::info "restored env for plugin $_p"; }
            continue
        fi
        command -v "$_p" >/dev/null 2>&1 || continue
        _now="$("$_p" -config 2>/dev/null || true)"
        if [ "$_now" = "$_rec" ]; then
            hal::log::ok   "plugin $_p env matches"
        else
            hal::log::warn "plugin $_p env differs from recorded"
        fi
    done
}
_check_plugin_env
_NAHAL_PRELUDE
chmod +x "$_BROW_PRELUDE"

# ── session.sh — the header, the recorded per-session values, then the steps ──
{
    printf '#!/usr/bin/env bash\n'
    printf '# HAL Browse session — %s\n' "$(date)"
    printf '# Starting URL: %s\n' "$_BROW_START_URL"
    printf '# Run from:     %s\n' "$_BROW_OUTDIR"
    printf '# Replay machinery lives in session_prelude.sh (sourced below); this\n'
    printf '# file records the per-session values and the request steps, and\n'
    printf '# activates the HALDiSh environment via that prelude.\n'
    printf '# Override the response-file prefix: -p <prefix> (highest), else\n'
    printf '# $HAL_FILE_PREFIX, else the value recorded at session creation.\n'
    printf 'set -euo pipefail\n'
    printf 'cd "$(dirname "$0")"\n'
    printf '\n'
    printf '# ── recorded session values (consumed by session_prelude.sh) ──────────────────\n'
    printf '_prefix=%q   # prefix recorded at session creation (default)\n' "$_BROW_PREFIX"
    # Record the HAL_LINK_PLUGIN list as it stood at session creation, plus each
    # configured plugin's environment (via its `-config` output), so the prelude
    # can restore or diff the plugin list and env at replay.
    printf '_plugins_created=%q\n' "${HAL_LINK_PLUGIN:-}"
    _brow_emit_plugin_env
    printf '\n'
    printf '# Load the replay machinery: argument parsing, HALDiSh bootstrap,\n'
    printf '# _ensure_method, and the plugin list/env restore-and-diff checks.\n'
    printf 'source "$(dirname "$0")/session_prelude.sh"\n'
} > "$_BROW_LOG"
chmod +x "$_BROW_LOG"

hal::log::info "Session directory: ${_BROW_OUTDIR}"
hal::log::info "Session log:       ${_BROW_LOG}"

# Determine accept header and handle templated start link
accept="$_BROW_HAL_ACCEPT"
start_url="$_BROW_START_URL"
_BROW_LAST_BINDINGS=()

if [[ -n "$_BROW_START_LINK_JSON" ]]; then
    accept=$(_brow_accept_for_link "$_BROW_START_LINK_JSON")
    local_templated=$(_brow_qr "$_BROW_START_LINK_JSON" '.templated // false')
    if [[ "$local_templated" == "true" ]]; then
        _brow_expand_vars "$_BROW_START_URL" "start"
        start_url="$_BROW_LAST_URL"
    fi
fi

# Send the initial request
_brow_do_request "GET" "$start_url" "$accept"

# Log the initial step, reproducing the original nahal.sh invocation: a bare GET
# for a URL start, or hallink.sh (--link for a link/file start) piped to GET --link.
# hallink writes its sidecars under the base via -s "${_b[N]}"; the method writes
# under its own auto-generated base and the trailing rename (added by
# _brow_log_step) moves the group onto _b[N].
_brow_initial_cmd=""
_brow_initial_hdr=""
case "$_BROW_START_MODE" in
    url)
        _brow_initial_cmd="GET $(_brow_qargs "${_BROW_START_ARGS[@]}")"
        # Bare URL GET — there is no link for httpreq.sh to read Accept from, so
        # request a HAL response explicitly (this is the one place we set Accept).
        _brow_initial_hdr="Accept:${_BROW_HAL_ACCEPT}"
        ;;
    link)
        _brow_initial_cmd="hallink.sh -s \"\${_b[${_BROW_STEP}]}\" --link $(_brow_qargs "${_BROW_START_ARGS[@]}")"
        [[ ${#_BROW_LAST_BINDINGS[@]} -gt 0 ]] && \
            _brow_initial_cmd+=" -- $(_brow_qargs "${_BROW_LAST_BINDINGS[@]}")"
        _brow_initial_cmd+=$'\n'"GET --link"
        _brow_initial_hdr="$(_brow_req_headers "$_BROW_START_LINK_JSON")"
        ;;
    file)
        _brow_initial_cmd="hallink.sh -s \"\${_b[${_BROW_STEP}]}\" $(_brow_qargs "${_BROW_START_ARGS[@]}")"
        [[ ${#_BROW_LAST_BINDINGS[@]} -gt 0 ]] && \
            _brow_initial_cmd+=" -- $(_brow_qargs "${_BROW_LAST_BINDINGS[@]}")"
        _brow_initial_cmd+=$'\n'"GET --link"
        _brow_initial_hdr="$(_brow_req_headers "$_BROW_START_LINK_JSON")"
        ;;
esac
# Append any template bindings used to expand a templated start link.
_brow_initial_label="initial request"
[[ ${#_BROW_LAST_BINDINGS[@]} -gt 0 ]] && \
    _brow_initial_label+=" ${_BROW_LAST_BINDINGS[*]}"
_brow_log_step "$_brow_initial_hdr" "GET" "$_brow_initial_cmd" "$_brow_initial_label"

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

fi   # end main guard
