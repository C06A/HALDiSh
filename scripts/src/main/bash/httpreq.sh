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
# Usage:
#   GET  <url> [body-flags...]
#   POST <url> [body-flags...]
#   POST --    [body-flags...]              # URL read from first stdin line
#   POST                                   # URL read from first stdin line (no body flags)
#   GET  --link <json> [body-flags...]     # HAL link object: href→URL, type→Accept
#   GET  --link @<file> [body-flags...]    # HAL link from file
#   GET  --link [body-flags...]            # HAL link read from stdin
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
#   -u [text]      URL-encode body  (--data-urlencode); omit to read from stdin
#   -f [name=]file multipart file upload (--form name=@file); name defaults to
#                  the file's basename; omit file entirely for raw stdin body
#   -F name=value  multipart text field (--form name=value); repeatable
#   -b [filename]  binary body from file (--data-binary @file); omit for stdin
#   -r [filename]  raw upload (--upload-file); omit filename for stdin
#
# Stdout: base name of the output files (domain_timestampms)
#
# Output files written in the current directory:
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
declare    _HAL_HTTP_BASE=''        # domain_timestampms
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

# _hal_http_parse_body_args [arg...]
# Processes body-element flags from the positional arguments.
# Each flag consumes the next positional arg as its parameter unless the next
# arg is itself a flag (-a/-u/-f/-b/-r), in which case stdin is used.
_hal_http_parse_body_args() {
    local flag param fname
    while [[ $# -gt 0 ]]; do
        flag="$1"; shift
        case "$flag" in
            -i)
                _HAL_HTTP_REPLAY_ARGS+=(-i)
                ;;
            -a|-u|-f|-F|-b|-r)
                param=''
                if [[ $# -gt 0 ]] && ! [[ "$1" =~ ^-[aufFbri]$ ]]; then
                    param="$1"; shift
                fi
                case "$flag" in
                    -a)
                        if [[ -n "$param" ]]; then
                            _HAL_HTTP_CURL_ARGS+=(--data "$param")
                            _HAL_HTTP_REPLAY_ARGS+=(--data "$param")
                        else
                            param="$(cat)"
                            _HAL_HTTP_CURL_ARGS+=(--data "$param")
                            _HAL_HTTP_REPLAY_ARGS+=(--data "$param")
                        fi
                        ;;
                    -u)
                        if [[ -n "$param" ]]; then
                            _HAL_HTTP_CURL_ARGS+=(--data-urlencode "$param")
                            _HAL_HTTP_REPLAY_ARGS+=(--data-urlencode "$param")
                        else
                            param="$(cat)"
                            _HAL_HTTP_CURL_ARGS+=(--data-urlencode "$param")
                            _HAL_HTTP_REPLAY_ARGS+=(--data-urlencode "$param")
                        fi
                        ;;
                    -f)
                        if [[ -n "$param" ]]; then
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
                        _HAL_HTTP_CURL_ARGS+=(--form "$param")
                        _HAL_HTTP_REPLAY_ARGS+=(--form "$param")
                        ;;
                    -b)
                        if [[ -n "$param" ]]; then
                            _HAL_HTTP_CURL_ARGS+=(--data-binary "@${param}")
                            _HAL_HTTP_REPLAY_ARGS+=(--data-binary "@${param}")
                        else
                            _HAL_HTTP_CURL_ARGS+=(--data-binary @-)
                            _HAL_HTTP_REPLAY_ARGS+=(--data-binary @-)
                        fi
                        ;;
                    -r)
                        if [[ -n "$param" ]]; then
                            _HAL_HTTP_CURL_ARGS+=(--upload-file "$param")
                            _HAL_HTTP_REPLAY_ARGS+=(--upload-file "$param")
                        else
                            _HAL_HTTP_CURL_ARGS+=(--upload-file -)
                            _HAL_HTTP_REPLAY_ARGS+=(--upload-file -)
                        fi
                        ;;
                esac
                ;;
            *)
                hal::log::warn "httpreq.sh: unknown body flag: $flag"
                ;;
        esac
    done
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
    printf '\nFlags:\n'                                                                    >&2
    printf '  -i             add -i to saved .curl replay (show response headers)\n' >&2
    printf '  -a [text]      --data (ASCII text; omit to read stdin)\n'        >&2
    printf '  -u [text]      --data-urlencode (omit to read stdin)\n'          >&2
    printf '  -f [name=]file --form name=@file (name defaults to basename; omit file for raw stdin)\n' >&2
    printf '  -F name=value  --form name=value (multipart text field; repeatable)\n' >&2
    printf '  -b [filename]  --data-binary @file (omit for stdin)\n'           >&2
    printf '  -r [filename]  --upload-file (omit for stdin)\n'                 >&2
}

# ── entry point ───────────────────────────────────────────────────────────────

_hal_http_derive_method

if [[ $# -eq 0 ]]; then
    # No arguments: URL must come from stdin; error if stdin is a terminal
    if [[ -t 0 ]]; then
        _hal_http_usage
        exit 1
    fi
    IFS= read -r _hal_http_url_tmp
    _hal_http_parse_url "$_hal_http_url_tmp"
    set --   # clear positional params so body loop is a no-op
elif [[ "$1" == '--' ]]; then
    # Explicit stdin sentinel: read URL from stdin, body flags follow '--'
    shift
    IFS= read -r _hal_http_url_tmp
    _hal_http_parse_url "$_hal_http_url_tmp"
    # $@ now holds the body flags
elif [[ "$1" == '--link' ]]; then
    shift
    _hal_link_json=''
    if [[ $# -gt 0 && "$1" != -* ]]; then
        # Next arg is the link value (inline JSON or @file reference)
        _hal_link_json="$1"; shift
        [[ "$_hal_link_json" == @* ]] && _hal_link_json=$(<"${_hal_link_json#@}")
    else
        # No link value (or next arg is a body flag): read link JSON from stdin
        if [[ -t 0 ]]; then
            printf '%s: --link: no link argument and stdin is a terminal\n' \
                "$(basename "$0")" >&2
            exit 1
        fi
        _hal_link_json=$(cat)
    fi
    _hal_http_expand_link "$_hal_link_json"
    # $@ now holds body flags
else
    # Normal: first arg is URL, rest are body flags
    _hal_http_parse_url "$1"
    shift
fi

_hal_http_add_headers
_hal_http_add_cookies
_hal_http_build_base_args
_hal_http_parse_body_args "$@"
_hal_http_run
