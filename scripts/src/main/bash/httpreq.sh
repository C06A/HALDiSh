#!/usr/bin/env bash
# =============================================================================
# httpreq.sh — HTTP request dispatcher
#
# Invoke via method-named symlinks (uppercase, no extension):
#   ln -s httpreq.sh GET
#   ln -s httpreq.sh POST
#   ln -s httpreq.sh PUT
#   ln -s httpreq.sh DELETE
#   ...
#
# Usage (flags may appear in ANY order):
#   GET  <url> [flags...]
#   POST <url> [flags...]
#   POST --    [flags...]                  # URL read from first stdin line
#   POST                                   # URL read from first stdin line (no flags)
#   GET  --link <json> [flags...]          # HAL link object: href→URL, type→Accept
#   GET  --link @<file> [flags...]         # HAL link from file
#   GET  --link [flags...]                 # HAL link read from stdin
#   GET  <url> -s <basename> [flags...]    # write output files under <basename>
#
# Exactly one URL source may be given (a bare <url>, --, or --link); supplying
# more than one is an error.  The flags -s and -i may each appear at most once.
# The body is supplied in one of three mutually exclusive modes: single
# (-a/-b/-r, at most one), urlencoded (-u), or multipart (-f/-F); mixing modes
# is an error.  Within a mode, -u may repeat to build a multi-field body (curl
# joins the fields with '&'), and -f/-F may repeat and combine.
#
# Environment:
#   HTTP_IN_HEADERS       newline-separated "Name: Value" header lines
#   HTTP_IN_HEADERS_FILE  path to a file with the same format
#   HTTP_IN_COOKIES       newline-separated "name=value" cookie lines
#   HTTP_IN_COOKIES_FILE  path to a file with the same format
#
# Body flags (appear after the URL, in any combination):
#   -i             include -i in saved .curl replay command (shows response headers)
#   -a [text]      plain text body  (--data); omit text to read from stdin
#   -u [text]      URL-encode body  (--data-urlencode); omit to read from stdin;
#                  repeatable (curl joins the fields with '&')
#   -f [name=]file multipart file upload (--form name=@file); name defaults to
#                  the file's basename; omit file entirely for raw stdin body
#   -F name=value  multipart text field (--form name=value); repeatable
#   -b [filename]  binary body from file (--data-binary @file); omit for stdin
#   -r [filename]  raw upload (--upload-file); omit filename for stdin
#
# Stdout: base name of the output files (domain_timestampms, or the -s value)
#
# Output files written in the current directory (named <base>.*, where <base>
# is the -s argument when given, else domain_timestampms):
#   <base>.curl    shell-quoted curl command (for replay)
#   <base>.status  HTTP status code (single line)
#   <base>.headers response headers, "Name: Value" per line
#                  (excludes status line and Set-Cookie; matches HTTP_IN_HEADERS_FILE format)
#   <base>.cookies response cookies, "name=value" per line
#                  (extracted from Set-Cookie headers; matches HTTP_IN_COOKIES_FILE format)
#   <base>.body    raw response body
# =============================================================================
set -euo pipefail

. hal_utils.sh

# ── private global state ──────────────────────────────────────────────────────
declare    _HAL_HTTP_METHOD=''
declare    _HAL_HTTP_URL=''
declare -a _HAL_HTTP_CURL_ARGS=()
declare    _HAL_HTTP_BASE=''        # domain_timestampms (or the -s override)
declare    _HAL_HTTP_BASE_OVERRIDE='' # explicit base name from -s, if any
declare    _HAL_HTTP_TMPDIR=''
declare -a _HAL_HTTP_REPLAY_ARGS=() # curl args for .curl file (no capture flags)

# ── private helpers ───────────────────────────────────────────────────────────

# _hal_http_derive_method
# Sets _HAL_HTTP_METHOD to the basename of $0 (the invocation name).
_hal_http_derive_method() {
    _HAL_HTTP_METHOD="$(basename "$0")"
}

# _hal_http_parse_url <url>
# Extracts the domain from the URL and sets _HAL_HTTP_URL and _HAL_HTTP_BASE.
# _HAL_HTTP_BASE = domain_timestampms (current directory prefix for output files).
_hal_http_parse_url() {
    local url="$1"
    local domain
    domain="${url#*://}"      # strip scheme (e.g. https://)
    domain="${domain%%/*}"    # strip path
    domain="${domain%%\?*}"   # strip query string
    domain="${domain%%#*}"    # strip fragment
    domain="${domain##*@}"    # strip userinfo (user:pass@)
    domain="${domain%%:*}"    # strip port number
    domain="${domain:-hal}"   # fallback for relative hrefs (no scheme/host)
    local ts_ms
    ts_ms=$(( $(date +%s) * 1000 ))
    _HAL_HTTP_URL="$url"
    _HAL_HTTP_BASE="${domain}_${ts_ms}"
}

# _hal_http_add_headers
# Appends --header args to both _HAL_HTTP_CURL_ARGS and _HAL_HTTP_REPLAY_ARGS
# from HTTP_IN_HEADERS (env) and HTTP_IN_HEADERS_FILE (file path).
_hal_http_add_headers() {
    local line
    if [[ -n "${HTTP_IN_HEADERS:-}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _HAL_HTTP_CURL_ARGS+=(--header "$line")
            _HAL_HTTP_REPLAY_ARGS+=(--header "$line")
        done <<< "$HTTP_IN_HEADERS"
    fi
    if [[ -n "${HTTP_IN_HEADERS_FILE:-}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _HAL_HTTP_CURL_ARGS+=(--header "$line")
            _HAL_HTTP_REPLAY_ARGS+=(--header "$line")
        done < "$HTTP_IN_HEADERS_FILE"
    fi
}

# _hal_http_add_cookies
# Collects cookies from HTTP_IN_COOKIES (env) and HTTP_IN_COOKIES_FILE (file).
# Format: one "name=value" line per cookie. All cookies are joined as a single
# --cookie "n1=v1; n2=v2" argument.
_hal_http_add_cookies() {
    local line
    local -a cookie_parts=()
    if [[ -n "${HTTP_IN_COOKIES:-}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            cookie_parts+=("$line")
        done <<< "$HTTP_IN_COOKIES"
    fi
    if [[ -n "${HTTP_IN_COOKIES_FILE:-}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            cookie_parts+=("$line")
        done < "$HTTP_IN_COOKIES_FILE"
    fi
    if [[ "${#cookie_parts[@]}" -gt 0 ]]; then
        # Join with '; ' manually — IFS only uses its first character in ${arr[*]}
        local joined='' sep=''
        for line in "${cookie_parts[@]}"; do
            joined="${joined}${sep}${line}"
            sep='; '
        done
        _HAL_HTTP_CURL_ARGS+=(--cookie "$joined")
        _HAL_HTTP_REPLAY_ARGS+=(--cookie "$joined")
    fi
}

# _hal_http_expand_link <json>
# Parses a HAL link JSON object. Sets _HAL_HTTP_URL (via _hal_http_parse_url)
# from the href field and prepends "Accept: <type>" to HTTP_IN_HEADERS when
# the link carries a type field.
_hal_http_expand_link() {
    local json="$1"
    local href type
    if command -v jq >/dev/null 2>&1; then
        href=$(jq -r '.href // ""' <<< "$json" 2>/dev/null)
        type=$(jq -r '.type // ""' <<< "$json" 2>/dev/null)
    elif command -v yq >/dev/null 2>&1; then
        href=$(yq -r '.href // ""' <<< "$json" 2>/dev/null)
        type=$(yq -r '.type // ""' <<< "$json" 2>/dev/null)
    else
        hal::log::die '--link requires jq or yq'
    fi
    [[ -n "$href" ]] || hal::log::die '--link: link object has no href field'
    if [[ -n "$type" && "$type" != 'null' ]]; then
        HTTP_IN_HEADERS="Accept:${type}${HTTP_IN_HEADERS:+$'\n'${HTTP_IN_HEADERS}}"
    fi
    _hal_http_parse_url "$href"
}

# _hal_http_build_base_args
# Populates _HAL_HTTP_CURL_ARGS with the full execution flags (-X, capture
# flags, URL) and _HAL_HTTP_REPLAY_ARGS with the user-facing replay flags
# (-X, -i, URL) — without -D/-o/--write-out/--silent.
_hal_http_build_base_args() {
    _HAL_HTTP_TMPDIR="$(mktemp -d)"
    _HAL_HTTP_CURL_ARGS+=(
        -X "$_HAL_HTTP_METHOD"
        -D "${_HAL_HTTP_TMPDIR}/headers"
        -o "${_HAL_HTTP_TMPDIR}/body"
        --write-out '%{http_code}'
        --silent
        "$_HAL_HTTP_URL"
    )
    _HAL_HTTP_REPLAY_ARGS+=(
        -X "$_HAL_HTTP_METHOD"
        "$_HAL_HTTP_URL"
    )
}

# _hal_http_is_flag <arg>
# True when <arg> is one of the recognized flag tokens.  Used to decide whether
# the argument following a body flag is that flag's parameter or the next flag
# (in which case the body flag falls back to reading its data from stdin).
_hal_http_is_flag() {
    case "$1" in
        -i|-a|-u|-f|-F|-b|-r|-s|--|--link) return 0 ;;
        *) return 1 ;;
    esac
}

# _hal_http_add_body <flag> <param> <had_param>
# Translates a single body flag (with its already-consumed parameter, if any)
# into curl execution + replay args.  <had_param> is 1 when a parameter was
# present on the command line, 0 when the flag should read from stdin instead.
_hal_http_add_body() {
    local flag="$1" param="$2" had="$3" fname
    case "$flag" in
        -a)
            [[ "$had" -eq 1 ]] || param="$(cat)"
            _HAL_HTTP_CURL_ARGS+=(--data "$param")
            _HAL_HTTP_REPLAY_ARGS+=(--data "$param")
            ;;
        -u)
            [[ "$had" -eq 1 ]] || param="$(cat)"
            _HAL_HTTP_CURL_ARGS+=(--data-urlencode "$param")
            _HAL_HTTP_REPLAY_ARGS+=(--data-urlencode "$param")
            ;;
        -f)
            if [[ "$had" -eq 1 ]]; then
                # name=path explicit, or fall back to basename
                if [[ "$param" == *=* ]]; then
                    fname="${param%%=*}"
                    param="${param#*=}"
                else
                    fname="$(basename "$param")"
                fi
                _HAL_HTTP_CURL_ARGS+=(--form "${fname}=@${param}")
                _HAL_HTTP_REPLAY_ARGS+=(--form "${fname}=@${param}")
            else
                # No filename: upload stdin as raw body (not multipart)
                _HAL_HTTP_CURL_ARGS+=(--data-binary @-)
                _HAL_HTTP_REPLAY_ARGS+=(--data-binary @-)
            fi
            ;;
        -F)
            [[ "$had" -eq 1 ]] || hal::log::die '-F requires a name=value argument'
            _HAL_HTTP_CURL_ARGS+=(--form "$param")
            _HAL_HTTP_REPLAY_ARGS+=(--form "$param")
            ;;
        -b)
            if [[ "$had" -eq 1 ]]; then
                _HAL_HTTP_CURL_ARGS+=(--data-binary "@${param}")
                _HAL_HTTP_REPLAY_ARGS+=(--data-binary "@${param}")
            else
                _HAL_HTTP_CURL_ARGS+=(--data-binary @-)
                _HAL_HTTP_REPLAY_ARGS+=(--data-binary @-)
            fi
            ;;
        -r)
            if [[ "$had" -eq 1 ]]; then
                _HAL_HTTP_CURL_ARGS+=(--upload-file "$param")
                _HAL_HTTP_REPLAY_ARGS+=(--upload-file "$param")
            else
                _HAL_HTTP_CURL_ARGS+=(--upload-file -)
                _HAL_HTTP_REPLAY_ARGS+=(--upload-file -)
            fi
            ;;
    esac
}

# _hal_http_write_url_file
# Writes the URL to <base>.url.
_hal_http_write_url_file() {
  local out="${_HAL_HTTP_BASE}.url"
  printf '%s' "$_HAL_HTTP_URL" >> "$out"
}

# _hal_http_write_curl_file
# Writes a human-friendly, multi-line replay command to <base>.curl.
# Each flag+value pair occupies its own continuation line (4-space indent).
# If a flag+value pair would exceed 130 characters, the value is placed on
# the next line with an 8-space indent.  Standalone tokens (e.g. -i, URL)
# are never split.
_hal_http_write_curl_file() {
    local -a quoted=()
    local arg
    for arg in "${_HAL_HTTP_REPLAY_ARGS[@]}"; do
        quoted+=("$(printf '%q' "$arg")")
    done

    local out="${_HAL_HTTP_BASE}.curl"
    local n=${#quoted[@]}
    local i=0 token val line

    printf 'curl' > "$out"

    while [[ $i -lt $n ]]; do
        token="${quoted[$i]}"
        case "$token" in
            --header|--cookie|-X|--data|--data-urlencode|\
            --form|--data-binary|--upload-file)
                # Flag that always takes exactly one value argument
                val="${quoted[$((i + 1))]}"
                line="    ${token} ${val}"
                if [[ ${#line} -gt 130 ]]; then
                    # Value too long: place it on the next line, indented further
                    printf ' \\\n    %s \\\n        %s' "$token" "$val" >> "$out"
                else
                    # $line already carries the 4-space indent; no extra spaces needed
                    printf ' \\\n%s' "$line" >> "$out"
                fi
                i=$((i + 2))
                ;;
            *)
                # Standalone token: single flag (-i) or URL
                printf ' \\\n    %s' "$token" >> "$out"
                i=$((i + 1))
                ;;
        esac
    done
    printf '\n' >> "$out"
}

# _hal_http_process_headers <header_file>
# Reads curl's raw response header dump (-D output, CRLF-terminated).
# Writes <base>.headers (Name: Value lines, no status line, no Set-Cookie) and
# <base>.cookies (name=value lines extracted from Set-Cookie headers).
_hal_http_process_headers() {
    local header_file="$1"
    local headers_out="${_HAL_HTTP_BASE}.headers"
    local cookies_out="${_HAL_HTTP_BASE}.cookies"
    : > "$headers_out"
    : > "$cookies_out"
    [[ ! -f "$header_file" ]] && return
    local line value cookie_val
    while IFS= read -r line; do
        # Strip trailing CR (HTTP headers use CRLF line endings)
        line="${line%$'\r'}"
        # Skip blank lines (header/body separator)
        [[ -z "$line" ]] && continue
        # Skip HTTP status line (e.g. "HTTP/1.1 200 OK")
        [[ "$line" == HTTP/* ]] && continue
        # Extract Set-Cookie: strip attributes, keep only name=value
        if [[ "${line,,}" == 'set-cookie:'* ]]; then
            value="${line#*: }"
            cookie_val="${value%%;*}"
            # Trim trailing whitespace
            cookie_val="${cookie_val%"${cookie_val##*[![:space:]]}"}"
            printf '%s\n' "$cookie_val" >> "$cookies_out"
            continue
        fi
        printf '%s\n' "$line" >> "$headers_out"
    done < "$header_file"
}

# List of HTTP status codes at https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml
declare -A status_codes
status_codes['000']='No request could be sent'
status_codes['200']='OK'
status_codes['201']='CREATED'
status_codes['202']='ACCEPTED'
status_codes['204']='NO CONTENT'
status_codes['206']='PARTIAL CONTENT'
status_codes['302']='FOUND'
status_codes['400']='BAD REQUEST'
status_codes['401']='UNAUTHORIZED'
status_codes['403']='FORBIDDEN'
status_codes['404']='NOT FOUNT'
status_codes['406']='NOT ACCEPTABLE'
status_codes['409']='CONFLICT'
status_codes['422']='UNPROCESSABLE CONTENT'
status_codes['500']='INTERNAL SERVE ERROR'
status_codes['502']='BAD GATEWAY'
status_codes['503']='SERVICE UNAVAILABLE'
status_codes['504']='GATEWAY TIMEOUT'

# _hal_http_run
# Writes the .curl file, executes curl, captures the HTTP status code, copies
# response body, processes headers/cookies into output files, and prints the
# base name to stdout. Preserves curl's exit code.
_hal_http_run() {
    _hal_http_write_url_file
    _hal_http_write_curl_file

    local status_code='' curl_exit=0
    # Temporarily disable errexit: curl may return non-zero (4xx/5xx) which is
    # not an error for us — we still want to capture and save the response.
    set +e
    status_code="$(curl "${_HAL_HTTP_CURL_ARGS[@]}")"
    curl_exit=$?
    set -e
    hal::log::debug "status code: $status_code"
    printf '%s\n' "$status_code"                                   >"${_HAL_HTTP_BASE}.code"
    printf '%s\n' "$status_code (${status_codes["$status_code"]:-'unknown'})" >"${_HAL_HTTP_BASE}.status"
    cp "${_HAL_HTTP_TMPDIR}/body" "${_HAL_HTTP_BASE}.body" 2>/dev/null \
        || touch "${_HAL_HTTP_BASE}.body"
    _hal_http_process_headers "${_HAL_HTTP_TMPDIR}/headers"
    rm -rf "$_HAL_HTTP_TMPDIR"
    # Print the base name to stdout so callers can locate the output files
    printf '%s\n' "$_HAL_HTTP_BASE"
    return $curl_exit
}

_hal_http_usage() {
    local name
    name="$(basename "$0")"
    printf 'Usage: %s <url> [flags...]\n'                                     "$name" >&2
    printf '       %s -- [flags...]             (URL from stdin)\n'             "$name" >&2
    printf '       %s --link <json> [flags...]  (HAL link: href→URL, type→Accept)\n' "$name" >&2
    printf '       %s --link @<file> [flags...]  (HAL link from file)\n'        "$name" >&2
    printf '       %s --link [flags...]          (HAL link from stdin)\n'       "$name" >&2
    printf '\nFlags (any order):\n'                                                        >&2
    printf '  -s <basename>  write output files under <basename> (else domain_timestamp)\n' >&2
    printf '  -i             add -i to saved .curl replay (show response headers)\n' >&2
    printf '  -a [text]      --data (ASCII text; omit to read stdin)\n'        >&2
    printf '  -u [text]      --data-urlencode (omit to read stdin; repeatable)\n' >&2
    printf '  -f [name=]file --form name=@file (name defaults to basename; omit file for raw stdin)\n' >&2
    printf '  -F name=value  --form name=value (multipart text field; repeatable)\n' >&2
    printf '  -b [filename]  --data-binary @file (omit for stdin)\n'           >&2
    printf '  -r [filename]  --upload-file (omit for stdin)\n'                 >&2
    printf '\nBody modes (mutually exclusive): -a/-b/-r single, -u urlencoded, -f/-F multipart.\n' >&2
}

# ── entry point ───────────────────────────────────────────────────────────────

_hal_http_derive_method

# Single left-to-right pass: every argument is read in turn and classified.
# Flags may appear in any order.  At most one URL source (a bare URL, --, or
# --link) and at most one each of -s and -i are allowed.  Body flags and their
# consumed parameters are recorded in parallel arrays and replayed after the
# URL is resolved, so any stdin read for the URL happens before a body's.
_url_source=''            # '' | url | stdin | link
_url_value=''             # the URL (url) or link spec (link)
_link_from_stdin=0
_seen_s=0
_seen_i=0
_seen_single=''           # the chosen -a/-u/-b/-r flag, if any
_seen_multipart=0         # 1 once any -f/-F is seen
declare -a _BF_FLAG=() _BF_PARAM=() _BF_HAD=()

# _hal_http_set_url_source <kind> — record the URL source, rejecting a second one.
_hal_http_set_url_source() {
    [[ -z "$_url_source" ]] || hal::log::die \
        'only one URL source allowed (a URL, --, or --link)'
    _url_source="$1"
}

while [[ $# -gt 0 ]]; do
    _arg="$1"; shift
    case "$_arg" in
        -s)
            [[ "$_seen_s" -eq 0 ]] || hal::log::die '-s specified more than once'
            _seen_s=1
            [[ $# -gt 0 ]] || hal::log::die '-s requires a basename argument'
            _HAL_HTTP_BASE_OVERRIDE="$1"; shift
            ;;
        -i)
            [[ "$_seen_i" -eq 0 ]] || hal::log::die '-i specified more than once'
            _seen_i=1
            ;;
        --)
            _hal_http_set_url_source stdin
            ;;
        --link)
            _hal_http_set_url_source link
            if [[ $# -gt 0 ]] && ! _hal_http_is_flag "$1"; then
                _url_value="$1"; shift
            else
                _link_from_stdin=1
            fi
            ;;
        -u)
            # -u (--data-urlencode) may repeat; curl concatenates the fields
            # into one body, joined with '&'.  Still conflicts with the other
            # single-body flags and with multipart -f/-F.
            [[ -z "$_seen_single" || "$_seen_single" == -u ]] || hal::log::die \
                "conflicting body flag $_arg (already using $_seen_single)"
            [[ "$_seen_multipart" -eq 0 ]] || hal::log::die \
                "body flag $_arg conflicts with multipart -f/-F"
            _seen_single="$_arg"
            _BF_FLAG+=("$_arg")
            if [[ $# -gt 0 ]] && ! _hal_http_is_flag "$1"; then
                _BF_PARAM+=("$1"); _BF_HAD+=(1); shift
            else
                _BF_PARAM+=(''); _BF_HAD+=(0)
            fi
            ;;
        -a|-b|-r)
            [[ -z "$_seen_single" ]] || hal::log::die \
                "conflicting body flag $_arg (already using $_seen_single)"
            [[ "$_seen_multipart" -eq 0 ]] || hal::log::die \
                "body flag $_arg conflicts with multipart -f/-F"
            _seen_single="$_arg"
            _BF_FLAG+=("$_arg")
            if [[ $# -gt 0 ]] && ! _hal_http_is_flag "$1"; then
                _BF_PARAM+=("$1"); _BF_HAD+=(1); shift
            else
                _BF_PARAM+=(''); _BF_HAD+=(0)
            fi
            ;;
        -f|-F)
            [[ -z "$_seen_single" ]] || hal::log::die \
                "multipart $_arg conflicts with body flag $_seen_single"
            _seen_multipart=1
            _BF_FLAG+=("$_arg")
            if [[ $# -gt 0 ]] && ! _hal_http_is_flag "$1"; then
                _BF_PARAM+=("$1"); _BF_HAD+=(1); shift
            else
                _BF_PARAM+=(''); _BF_HAD+=(0)
            fi
            ;;
        -*)
            hal::log::die "unknown flag: $_arg"
            ;;
        *)
            _hal_http_set_url_source url
            _url_value="$_arg"
            ;;
    esac
done

# Resolve the URL source (reading stdin where needed) before any body stdin read.
case "$_url_source" in
    url)
        _hal_http_parse_url "$_url_value"
        ;;
    link)
        if [[ "$_link_from_stdin" -eq 1 ]]; then
            if [[ -t 0 ]]; then
                printf '%s: --link: no link argument and stdin is a terminal\n' \
                    "$(basename "$0")" >&2
                exit 1
            fi
            _hal_link_json=$(cat)
        else
            _hal_link_json="$_url_value"
            [[ "$_hal_link_json" == @* ]] && _hal_link_json=$(<"${_hal_link_json#@}")
        fi
        _hal_http_expand_link "$_hal_link_json"
        ;;
    stdin|'')
        # Explicit -- or no URL source at all: read the URL from the first
        # stdin line; a terminal stdin with nothing to read is a usage error.
        if [[ -t 0 ]]; then
            _hal_http_usage
            exit 1
        fi
        IFS= read -r _hal_http_url_tmp
        _hal_http_parse_url "$_hal_http_url_tmp"
        ;;
esac

# Apply an explicit -s base name over the URL-derived default.
[[ -n "$_HAL_HTTP_BASE_OVERRIDE" ]] && _HAL_HTTP_BASE="$_HAL_HTTP_BASE_OVERRIDE"

_hal_http_add_headers
_hal_http_add_cookies
_hal_http_build_base_args
[[ "$_seen_i" -eq 1 ]] && _HAL_HTTP_REPLAY_ARGS+=(-i)
for (( _k = 0; _k < ${#_BF_FLAG[@]}; _k++ )); do
    _hal_http_add_body "${_BF_FLAG[$_k]}" "${_BF_PARAM[$_k]}" "${_BF_HAD[$_k]}"
done
_hal_http_run
