#!/usr/bin/env bash
# grapher.sh — Build a navigation graph from HAL session files
#
# Usage:
#   grapher.sh [--format dot|mermaid|plantuml|ascii|json|svg] [--orientation lr|tb] [DIR]
#
# Scans DIR (default: .) for files with extensions .url .curl .body .json .xml
# .yaml .yml, groups them by shared basename, and emits a graph showing which
# resource's links led to which requests.
#
# Edge origin: when a request carries the sidecars written by `hallink.sh -s`
# (<base>.source naming the resource the link came from, <base>.halpath the
# path traversed, <base>.bindings the template bindings), the edge is built
# directly and trusted as recorded.  When those sidecars are absent the origin
# is *guessed* by matching the target URL against the hrefs of earlier bodies;
# if more than one href in the chosen body matches, the guess is ambiguous and
# the edge label is flagged "(guessed: N matches)".
#
# Visualization:
#   dot:       graphviz (brew install graphviz, then `dot -Tpng -o graph.png`)
#   mermaid:   https://mermaid.ai/live
#   plantuml:  http://www.plantuml.com/plantuml/uml/ (paste into the URL path)
#   ascii:     any text editor or terminal
#   json:      any text editor or jq/yq for manipulation
#   svg:       self-contained <svg> document (no external tools); open in a browser
#
# Requires: jq (JSON), yq (XML/YAML), hal.sh (self-link extraction)
set -euo pipefail

. hal_utils.sh

# ── globals ───────────────────────────────────────────────────────────────────

declare -a _GR_NODE_IDS=()
declare -A _GR_NODE_URL=()
declare -A _GR_NODE_CURL=()
declare -a _GR_EDGE_FROM=()
declare -a _GR_EDGE_TO=()
declare -a _GR_EDGE_LABEL=()
declare -a _GR_EDGE_GUESS=()   # '' = recorded/unique, 'ambiguous' = >1 href matched

_GR_FORMAT='dot'
_GR_ORIENT='lr'
_GR_DIR='.'

_GR_HAS_JQ=0
_GR_HAS_YQ=0

# Set by _template_matches; also cleared by _urls_match for non-template hits
_TMPL_BINDINGS=''

# Set by _template_to_regex
_TMPL_REGEX=''
declare -a _TMPL_VARNAMES=()
declare -a _TMPL_OPS=()

# ── argument parsing ──────────────────────────────────────────────────────────

_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f)
                shift
                _GR_FORMAT=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
                ;;
            --format=*)
                _GR_FORMAT=$(printf '%s' "${1#--format=}" | tr '[:upper:]' '[:lower:]')
                ;;
            --orientation|-o)
                shift
                _GR_ORIENT=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
                ;;
            --orientation=*)
                _GR_ORIENT=$(printf '%s' "${1#--orientation=}" | tr '[:upper:]' '[:lower:]')
                ;;
            -*)
                hal::log::die "grapher: unknown option: $1"
                ;;
            *)
                _GR_DIR="$1"
                ;;
        esac
        shift
    done

    case "$_GR_FORMAT" in
        dot|mermaid|plantuml|ascii|json|svg) ;;
        *) hal::log::die "grapher: unknown format '$_GR_FORMAT'. Use: dot mermaid plantuml ascii json svg" ;;
    esac
    case "$_GR_ORIENT" in
        lr|tb) ;;
        *) hal::log::die "grapher: unknown orientation '$_GR_ORIENT'. Use: lr tb" ;;
    esac
    [[ -d "$_GR_DIR" ]] || hal::log::die "grapher: directory not found: $_GR_DIR"
}

# ── tool detection ────────────────────────────────────────────────────────────

_check_tools() {
    command -v jq >/dev/null 2>&1 && _GR_HAS_JQ=1 || true
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        _GR_HAS_YQ=1
    fi
    (( _GR_HAS_JQ || _GR_HAS_YQ )) || hal::log::die "grapher: requires jq or yq"
    (( _GR_HAS_JQ )) || hal::log::die "grapher: jq is required for href extraction"
}

# ── file creation time ────────────────────────────────────────────────────────

_get_ctime() {
    local f="$1"
    local t
    # macOS: stat -f %B (birth time); Linux: stat --format=%W (birth, 0 if unsupported)
    if t=$(stat -f %B "$f" 2>/dev/null); then
        printf '%s' "$t"
    elif t=$(stat --format=%W "$f" 2>/dev/null) && [[ "$t" != '0' ]]; then
        printf '%s' "$t"
    else
        # Fall back to mtime
        stat -f %m "$f" 2>/dev/null || stat --format=%Y "$f" 2>/dev/null || printf '0'
    fi
}

# ── format detection & JSON conversion ───────────────────────────────────────

_detect_format() {
    local f="$1"
    if (( _GR_HAS_JQ )) && jq '.' "$f" >/dev/null 2>&1; then
        printf 'json'; return
    fi
    if (( _GR_HAS_YQ )); then
        if yq -p xml '.' "$f" >/dev/null 2>&1; then printf 'xml'; return; fi
        printf 'yaml'; return
    fi
    local sig
    sig=$(grep -m1 '[^[:space:]]' "$f" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-5)
    case "$sig" in
        '<?xml'|'<'*) printf 'xml' ;;
        '{'*|'['*)    printf 'json' ;;
        *)            printf 'yaml' ;;
    esac
}

# Outputs file content as JSON on stdout; returns 1 if impossible
_to_json_content() {
    local f="$1"
    local fmt
    fmt=$(_detect_format "$f")
    case "$fmt" in
        json) cat "$f" ;;
        yaml|xml)
            if (( _GR_HAS_YQ )); then
                yq -o json '.' "$f" 2>/dev/null
            else
                hal::log::warn "grapher: yq required for $fmt file: $f"
                return 1
            fi
            ;;
    esac
}

# ── shell word tokenizer ──────────────────────────────────────────────────────

# Prints one shell token per line, honouring single/double quotes and backslash.
_tokenize_shell() {
    local input="$1"
    local token=''
    local i=0 n=${#input}
    local char
    local in_single=0 in_double=0

    while (( i < n )); do
        char="${input:$i:1}"
        if (( in_single )); then
            if [[ "$char" == "'" ]]; then in_single=0
            else token+="$char"; fi
        elif (( in_double )); then
            if [[ "$char" == '"' ]]; then
                in_double=0
            elif [[ "$char" == '\\' ]]; then
                (( i += 1 )) || true
                char="${input:$i:1}"
                case "$char" in
                    '"'|'\\'|'$'|'`'|'!') token+="$char" ;;
                    n) token+=$'\n' ;;
                    t) token+=$'\t' ;;
                    *) token+="\\$char" ;;
                esac
            else
                token+="$char"
            fi
        elif [[ "$char" == "'" ]]; then
            in_single=1
        elif [[ "$char" == '"' ]]; then
            in_double=1
        elif [[ "$char" == '\\' ]]; then
            (( i += 1 )) || true
            char="${input:$i:1}"
            [[ "$char" != $'\n' ]] && token+="$char"
        elif [[ "$char" == ' ' || "$char" == $'\t' || "$char" == $'\n' ]]; then
            [[ -n "$token" ]] && { printf '%s\n' "$token"; token=''; }
        else
            token+="$char"
        fi
        (( i += 1 )) || true
    done
    [[ -n "$token" ]] && printf '%s\n' "$token"
}

# ── curl URL extraction ───────────────────────────────────────────────────────

# Options whose next token is their value (combined --opt=val handled separately)
_CURL_VALUE_FLAGS=' -X --request -H --header -d --data --data-ascii --data-binary
 --data-raw --data-urlencode -u --user -U --proxy-user -A --user-agent -b --cookie
 -c --cookie-jar -o --output -F --form -m --max-time --connect-timeout -e --referer
 -x --proxy --resolve --retry --retry-delay --retry-max-time --limit-rate -w
 --write-out -T --upload-file --unix-socket --abstract-unix-socket --cacert --cert
 -E --key --pass --capath --ciphers --curves --tls-max --interface --dns-interface
 --dns-servers --noproxy --keepalive-time -P --ftp-port --ftp-account --socks4
 --socks4a --socks5 --socks5-hostname --proxy-header --proxy-cacert --proxy-cert
 --proxy-key --proxy-pass --proxy-ciphers --engine --random-file --pinnedpubkey
 --service-name --login-options --oauth2-bearer --aws-sigv4 --alt-svc --hsts
 --doh-url --connect-to --proto --proto-redir --proto-default -Q --quote --netrc-file
 --etag-save --etag-compare --delegation --krb --max-redirs -r --range -K --config
 --limit-rate --parallel-max --max-filesize -Y --speed-limit -y --speed-time
 -z --time-cond -y --retry-max-time '

_curl_flag_takes_value() {
    local flag="${1%%=*}"  # strip =value suffix
    [[ " $_CURL_VALUE_FLAGS " == *" ${flag} "* ]]
}

# Extracts the URL from a curl command string (multi-line ok)
_extract_url_from_curl() {
    local cmd="$1"

    # Join continuation lines (trailing backslash)
    local joined=''
    local line
    while IFS= read -r line; do
        if [[ "${line: -1}" == '\' ]]; then
            joined+="${line:0:$(( ${#line} - 1 ))} "
        else
            joined+="$line "
        fi
    done <<< "$cmd"

    local -a candidates=()
    local skip_next=0
    local token

    while IFS= read -r token; do
        if (( skip_next )); then skip_next=0; continue; fi
        [[ "$token" == 'curl' ]] && continue
        [[ "$token" == '-i' ]] && continue
        # --option=value: consume entirely, no skip of next token
        if [[ "$token" == --*=* || "$token" == -*=* ]]; then continue; fi
        # Flag token
        if [[ "$token" == -* ]]; then
            _curl_flag_takes_value "$token" && skip_next=1
            continue
        fi
        candidates+=("$token")
    done < <(_tokenize_shell "$joined")

    [[ ${#candidates[@]} -eq 0 ]] && return 1

    # Prefer token that looks like a URL
    local c
    for c in "${candidates[@]}"; do
        if [[ "$c" =~ ^[a-zA-Z][a-zA-Z0-9+.\-]*:// || "$c" == /* ]]; then
            printf '%s' "$c"; return 0
        fi
    done
    printf '%s' "${candidates[-1]}"
}

# ── body file lookup ──────────────────────────────────────────────────────────

_find_body_file() {
    local dir="$1" base="$2"
    local ext
    for ext in body json xml yaml yml; do
        local f="${dir}/${base}.${ext}"
        [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# ── URL extraction for a group ────────────────────────────────────────────────

_extract_url_for_group() {
    local dir="$1" base="$2"
    local url

    # 1. .url file
    local url_file="${dir}/${base}.url"
    if [[ -f "$url_file" ]]; then
        url=$(hal::str::trim "$(< "$url_file")")
        [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
    fi

    # 2. .curl file
    local curl_file="${dir}/${base}.curl"
    if [[ -f "$curl_file" ]]; then
        url=$(_extract_url_from_curl "$(< "$curl_file")") && [[ -n "$url" ]] && {
            printf '%s' "$url"; return 0
        } || true
    fi

    # 3. _links.self.href from body file
    local body_file
    body_file=$(_find_body_file "$dir" "$base") || return 0
    url=$(hal.sh "$body_file" links self href 2>/dev/null) || true
    [[ -n "$url" && "$url" != 'null' ]] && printf '%s' "$url"
    return 0
}

_extract_curl_for_group() {
    local dir="$1" base="$2"
    local curl_file="${dir}/${base}.curl"
    if [[ -f "$curl_file" ]]; then
        cat "$curl_file"; return 0
    fi
    local url="${_GR_NODE_URL[$base]:-}"
    if [[ -n "$url" ]]; then
        printf 'curl %s' "$url"
    else
        printf 'curl (unknown)'
    fi
}

# ── URL component parsing ─────────────────────────────────────────────────────

_URL_SCHEME='' _URL_HOST='' _URL_PORT='' _URL_PATH='' _URL_QUERY=''

_parse_url_components() {
    _URL_SCHEME='' _URL_HOST='' _URL_PORT='' _URL_PATH='' _URL_QUERY=''
    local url="$1"

    # Scheme
    if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.\-]*)://(.*)$ ]]; then
        _URL_SCHEME="${BASH_REMATCH[1],,}"
        url="${BASH_REMATCH[2]}"
        # Authority
        if [[ "$url" =~ ^([^/?#]*)(.*)$ ]]; then
            local auth="${BASH_REMATCH[1]}"
            url="${BASH_REMATCH[2]}"
            if [[ "$auth" =~ ^(.*):([0-9]+)$ ]]; then
                _URL_HOST="${BASH_REMATCH[1],,}"
                _URL_PORT="${BASH_REMATCH[2]}"
            else
                _URL_HOST="${auth,,}"
            fi
        fi
    fi

    # Query
    if [[ "$url" =~ ^([^?#]*)(\?([^#]*))?(#.*)?$ ]]; then
        _URL_PATH="${BASH_REMATCH[1]}"
        _URL_QUERY="${BASH_REMATCH[3]}"
    else
        _URL_PATH="$url"
    fi

    # Strip trailing slash unless sole /
    [[ "$_URL_PATH" != '/' ]] && _URL_PATH="${_URL_PATH%/}"
}

# Returns 0 if link_path matches the end of target_path (segment-boundary aware)
_path_suffix_match() {
    local l="${1%/}" t="${2%/}"
    local l_bare="${l#/}" t_bare="${t#/}"
    [[ "$t_bare" == "$l_bare" ]] && return 0
    [[ -z "$l_bare" ]] && return 0
    [[ "$t_bare" == *"/$l_bare" ]] && return 0
    return 1
}

# ── URI template → ERE regex ──────────────────────────────────────────────────

_template_to_regex() {
    _TMPL_REGEX=''
    _TMPL_VARNAMES=()
    _TMPL_OPS=()

    local tmpl="$1"
    local i=0 n=${#tmpl}

    while (( i < n )); do
        local char="${tmpl:$i:1}"
        if [[ "$char" == '{' ]]; then
            # Find closing brace
            local end=$(( i + 1 ))
            while (( end < n )) && [[ "${tmpl:$end:1}" != '}' ]]; do
                (( end += 1 )) || true
            done
            local expr="${tmpl:$(( i + 1 )):$(( end - i - 1 ))}"
            (( i = end + 1 )) || true

            # Operator and variable list
            local op='' vars_str="$expr"
            if [[ "$expr" =~ ^([+#./;?&])(.+)$ ]]; then
                op="${BASH_REMATCH[1]}"
                vars_str="${BASH_REMATCH[2]}"
            fi

            _TMPL_OPS+=("$op")
            _TMPL_VARNAMES+=("$vars_str")  # comma-separated var names

            # Regex fragment: one capture group per expression.
            # Values may contain separator chars (list/dict expansion).
            case "$op" in
                '')   _TMPL_REGEX+='([^/?#]*)' ;;   # simple: no / ? #
                '+')  _TMPL_REGEX+='([^?#]*)' ;;     # reserved: no ? #
                '#')  _TMPL_REGEX+='(#[^#]*)?' ;;    # fragment (optional)
                '.')  _TMPL_REGEX+='(\.[^/?#]*)?' ;;  # dot-label (optional)
                '/')  _TMPL_REGEX+='(/[^?#]*)?' ;;   # path segment (optional)
                ';')  _TMPL_REGEX+='(;[^/?#]*)?' ;;  # semicolon param (optional)
                '?')  _TMPL_REGEX+='\?([^#]*)' ;;    # query string
                '&')  _TMPL_REGEX+='(&[^#]*)' ;;     # query continuation
            esac
        else
            # Literal character — escape ERE metacharacters
            case "$char" in
                '.'|'*'|'+'|'?'|'('|')'|'['|']'|'{'|'}'|'|'|'^'|'$'|'\\')
                    _TMPL_REGEX+="\\${char}" ;;
                *) _TMPL_REGEX+="$char" ;;
            esac
            (( i += 1 )) || true
        fi
    done
}

# Sets _TMPL_BINDINGS (newline-separated var=value lines) and returns 0 on match
_template_matches() {
    local tmpl="$1" target="$2"
    _TMPL_BINDINGS=''
    _template_to_regex "$tmpl"

    # Anchor: template regex must match a suffix of the target URL
    local full_regex
    printf -v full_regex '.*%s$' "$_TMPL_REGEX"

    if [[ "$target" =~ $full_regex ]]; then
        local i
        for (( i = 0; i < ${#_TMPL_VARNAMES[@]}; i++ )); do
            local vname="${_TMPL_VARNAMES[$i]}"
            local op="${_TMPL_OPS[$i]}"
            local val="${BASH_REMATCH[$((i+1))]:-}"
            [[ -z "$val" ]] && continue
            case "$op" in
                '?'|'&')
                    # Parse key=val&key2=val2 pairs
                    local pair
                    local pairs_str="${val#[?&]}"  # strip leading ? or &
                    while IFS= read -r pair; do
                        [[ -n "$pair" ]] && _TMPL_BINDINGS+="${pair}"$'\n'
                    done < <(printf '%s\n' "$pairs_str" | tr '&' '\n')
                    ;;
                *) _TMPL_BINDINGS+="${vname}=${val}"$'\n' ;;
            esac
        done
        return 0
    fi
    return 1
}

# ── URL matching ──────────────────────────────────────────────────────────────

# Returns 0 if link_href matches target_url; sets _TMPL_BINDINGS for templates
_urls_match() {
    local link_href="$1" target_url="$2"
    _TMPL_BINDINGS=''

    # Templated link
    if [[ "$link_href" == *'{'* ]]; then
        _template_matches "$link_href" "$target_url"
        return $?
    fi

    _parse_url_components "$link_href"
    local l_scheme="$_URL_SCHEME" l_host="$_URL_HOST" l_port="$_URL_PORT" l_path="$_URL_PATH"

    _parse_url_components "$target_url"
    local t_scheme="$_URL_SCHEME" t_host="$_URL_HOST" t_port="$_URL_PORT" t_path="$_URL_PATH"

    # Scheme: if present in link, must match
    [[ -n "$l_scheme" && -n "$t_scheme" && "$l_scheme" != "$t_scheme" ]] && return 1
    # Host: if present in link, must match
    [[ -n "$l_host" && -n "$t_host" && "$l_host" != "$t_host" ]] && return 1
    # Port: if present in link, must match
    [[ -n "$l_port" && -n "$t_port" && "$l_port" != "$t_port" ]] && return 1
    # Path: link path must match end of target path
    [[ -n "$l_path" ]] && { _path_suffix_match "$l_path" "$t_path" || return 1; }
    return 0
}

# ── HAL path extraction from body ─────────────────────────────────────────────

# Prints one compact JSON object {"path":"...","value":"..."} per line
_extract_hrefs() {
    local json_content="$1"
    # URL-like: starts with a scheme+authority, or an absolute path, no whitespace/braces
    local url_pat='^(https?://[^ {}]+|[a-zA-Z][a-zA-Z0-9+.\-]*://[^ {}]+|/[^ {}]+)$'
    jq -c --arg url_pat "$url_pat" '
      def is_url: type == "string" and test($url_pat) and length > 1;
      def collect(pfx):
        if type == "object" then
          (if has("_links") then
            ._links | to_entries[] |
            select(.key != "curies") |
            . as {key: $rel, value: $lnk} |
            if ($lnk | type) == "array" then
              $lnk | to_entries[] |
              select((.value | type) == "object" and (.value | has("href"))) |
              . as {key: $idx, value: $lo} |
              {path: (pfx + ["_links", $rel, $idx, "href"] | @json),
               value: $lo.href}
            elif ($lnk | type) == "object" and ($lnk | has("href")) then
              {path: (pfx + ["_links", $rel, "href"] | @json), value: $lnk.href}
            else empty end
          else empty end),
          (to_entries[] |
            select(.key | startswith("_") | not) |
            select(.value | is_url) |
            {path: (pfx + [.key] | @json), value: .value}
          ),
          (if has("_embedded") then
            ._embedded | to_entries[] |
            . as {key: $rel, value: $items} |
            if ($items | type) == "array" then
              $items | to_entries[] |
              . as {key: $idx, value: $item} |
              $item | collect(pfx + ["_embedded", $rel, $idx])
            elif ($items | type) == "object" then
              $items | collect(pfx + ["_embedded", $rel])
            else empty end
          else empty end)
        else empty end;
      collect([])
    ' <<< "$json_content"
}

# ── jq path → HAL path label ──────────────────────────────────────────────────

# Converts a jq path JSON array string to a multi-line HAL path label.
# e.g. '["_embedded","orders",0,"_links","item","href"]'
#   → "embeddeds orders 0\nlinks item"
_jqpath_to_hal_path() {
    local path_json="$1"
    local -a segs
    mapfile -t segs < <(jq -r '.[]' <<< "$path_json" 2>/dev/null)

    local result='' i=0 n=${#segs[@]} seg

    while (( i < n )); do
        seg="${segs[$i]}"
        (( i += 1 )) || true

        case "$seg" in
            _links)
                local rel='' idx_part=''
                if (( i < n )); then rel="${segs[$i]}"; (( i += 1 )) || true; fi
                if (( i < n )) && [[ "${segs[$i]}" =~ ^[0-9]+$ ]]; then
                    idx_part=" ${segs[$i]}"; (( i += 1 )) || true
                fi
                # skip trailing "href"
                if (( i < n )) && [[ "${segs[$i]}" == 'href' ]]; then
                    (( i += 1 )) || true
                fi
                result+="${result:+$'\n'}links ${rel}${idx_part}"
                ;;
            _embedded)
                local rel='' idx_part=''
                if (( i < n )); then rel="${segs[$i]}"; (( i += 1 )) || true; fi
                if (( i < n )) && [[ "${segs[$i]}" =~ ^[0-9]+$ ]]; then
                    idx_part=" ${segs[$i]}"; (( i += 1 )) || true
                fi
                result+="${result:+$'\n'}embeddeds ${rel}${idx_part}"
                ;;
            *)
                result+="${result:+$'\n'}properties ${seg}"
                ;;
        esac
    done
    printf '%s' "$result"
}

# ── sidecar (hallink.sh -s) origin records ────────────────────────────────────

# Strip directory and the final extension from a name (req1.body → req1).
_basename_no_ext() {
    local s="${1##*/}"
    printf '%s' "${s%.*}"
}

# Group the flat hal-path tokens stored in <base>.halpath (one per line) into the
# labelled form the graph uses: "links <rel> [sel]" / "embeddeds <rel> [sel]" /
# "properties <key> [sel]" / "docs <rel>", one group per line — matching the
# layout produced by _jqpath_to_hal_path for guessed edges.
_halpath_tokens_to_label() {
    local -a toks=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && toks+=("$line")
    done <<< "$1"

    local result='' i=0 n=${#toks[@]} t
    while (( i < n )); do
        t="${toks[$i]}"; (( i += 1 )) || true
        case "$t" in
            links|embeddeds|properties|docs)
                local kw="$t" rel='' sel=''
                if (( i < n )); then rel="${toks[$i]}"; (( i += 1 )) || true; fi
                # An optional selector follows the rel unless the next token starts
                # a new segment.
                if (( i < n )); then
                    case "${toks[$i]}" in
                        links|embeddeds|properties|docs) ;;
                        *) sel=" ${toks[$i]}"; (( i += 1 )) || true ;;
                    esac
                fi
                result+="${result:+$'\n'}${kw} ${rel}${sel}"
                ;;
            *)
                result+="${result:+$'\n'}${t}"
                ;;
        esac
    done
    printf '%s' "$result"
}

# Build an edge label from the <base>.halpath and <base>.bindings sidecars: the
# grouped hal-path followed by each var=value binding on its own line (the same
# shape the guessing path produces).
_sidecar_label() {
    local dir="$1" base="$2"
    local label=''

    local hp="${dir}/${base}.halpath"
    [[ -f "$hp" ]] && label=$(_halpath_tokens_to_label "$(< "$hp")")

    local bf="${dir}/${base}.bindings"
    if [[ -f "$bf" ]]; then
        local b
        while IFS= read -r b; do
            [[ -n "$b" ]] && label+="${label:+$'\n'}${b}"
        done < "$bf"
    fi
    printf '%s' "$label"
}

# ── graph building ────────────────────────────────────────────────────────────

_build_graph() {
    local dir="$_GR_DIR"

    # Collect files and group by basename
    declare -A _grp_seen=()
    declare -A _grp_ctime=()

    local f base ext ct
    while IFS= read -r f; do
        base="${f##*/}"
        base="${base%.*}"
        ct=$(_get_ctime "$f")
        if [[ -z "${_grp_seen[$base]:-}" ]]; then
            _grp_seen["$base"]=1
            _grp_ctime["$base"]=$ct
        elif (( ct < _grp_ctime[$base] )); then
            _grp_ctime["$base"]=$ct
        fi
    done < <(find "$dir" -maxdepth 1 \( \
        -name '*.url' -o -name '*.curl' -o -name '*.body' \
        -o -name '*.json' -o -name '*.xml' \
        -o -name '*.yaml' -o -name '*.yml' \
    \) -type f)

    # Sort basenames by creation time
    local -a sorted=()
    mapfile -t sorted < <(
        for b in "${!_grp_ctime[@]}"; do
            printf '%s\t%s\n' "${_grp_ctime[$b]}" "$b"
        done | sort -n -k1,1 | cut -f2
    )

    # Populate node arrays
    local b
    for b in "${sorted[@]}"; do
        _GR_NODE_IDS+=("$b")
        local url
        url=$(_extract_url_for_group "$dir" "$b")
        _GR_NODE_URL["$b"]="${url}"
        local curl_cmd
        curl_cmd=$(_extract_curl_for_group "$dir" "$b")
        _GR_NODE_CURL["$b"]="${curl_cmd}"
    done

    # Build edges
    local i j
    for (( i = 1; i < ${#_GR_NODE_IDS[@]}; i++ )); do
        local target_base="${_GR_NODE_IDS[$i]}"

        # 1. Recorded origin: a <base>.source sidecar names the resource the link
        #    was extracted from.  Trust it as-is (no re-validation).
        local source_file="${dir}/${target_base}.source"
        if [[ -f "$source_file" ]]; then
            local src
            src=$(hal::str::trim "$(< "$source_file")")
            if [[ -n "$src" ]]; then
                _GR_EDGE_FROM+=("$(_basename_no_ext "$src")")
                _GR_EDGE_TO+=("$target_base")
                _GR_EDGE_LABEL+=("$(_sidecar_label "$dir" "$target_base")")
                _GR_EDGE_GUESS+=('')
                continue
            fi
        fi

        # 2. Guessed origin: match the target URL against earlier bodies' hrefs.
        local target_url="${_GR_NODE_URL[$target_base]}"
        [[ -z "$target_url" ]] && continue

        for (( j = i - 1; j >= 0; j-- )); do
            local cand_base="${_GR_NODE_IDS[$j]}"
            local body_file
            body_file=$(_find_body_file "$dir" "$cand_base") || continue

            local json_content
            json_content=$(_to_json_content "$body_file") || continue

            # Count every href in this body that resolves to the target URL; the
            # first match builds the edge, but >1 means the origin is ambiguous.
            local match_count=0 first_path='' first_bindings=''
            while IFS= read -r href_rec; do
                [[ -z "$href_rec" ]] && continue
                local href_path href_value
                href_path=$(jq -r '.path' <<< "$href_rec")
                href_value=$(jq -r '.value' <<< "$href_rec")

                if _urls_match "$href_value" "$target_url"; then
                    (( match_count += 1 )) || true
                    if (( match_count == 1 )); then
                        first_path="$href_path"
                        first_bindings="${_TMPL_BINDINGS%$'\n'}"
                    fi
                fi
            done < <(_extract_hrefs "$json_content")

            if (( match_count >= 1 )); then
                local hal_path
                hal_path=$(_jqpath_to_hal_path "$first_path")
                [[ -n "$first_bindings" ]] && hal_path+=$'\n'"$first_bindings"
                local guess=''
                if (( match_count > 1 )); then
                    guess='ambiguous'
                    hal_path+=$'\n'"(guessed: ${match_count} matches)"
                fi
                _GR_EDGE_FROM+=("$cand_base")
                _GR_EDGE_TO+=("$target_base")
                _GR_EDGE_LABEL+=("$hal_path")
                _GR_EDGE_GUESS+=("$guess")
                break
            fi
        done
    done
    return 0
}

# ── output helpers ────────────────────────────────────────────────────────────

# Escape for DOT quoted string: backslash, quote; newlines → \n literal
_esc_dot() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Escape for Mermaid label: replace newlines with <br>, escape "
_esc_mermaid() {
    local s="$1"
    s="${s//\"/&quot;}"
    s="${s//$'\n'/<br>}"
    printf '%s' "$s"
}

# Escape for a PlantUML double-quoted label.  PlantUML has no in-string escape
# for a literal double quote, so collapse any " to ' (keeps a curl command, which
# mixes both quote styles, readable).  Every line break becomes the literal \n
# PlantUML renders as an in-label break: first a curl continuation (backslash +
# newline) so its trailing backslash is absorbed, then any remaining bare newline
# (multi-line edge labels) — leaving a real newline would split the statement.
_esc_plantuml() {
    local s="$1"
    s="${s//\"/\'}"
    s="${s//$'\\\n'/\\n}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Escape text for an SVG/XML text node or attribute value.
_esc_xml() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# Emit a valid Mermaid node ID (letters, digits, underscore, hyphen)
_mermaid_id() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_'
}

# Emit a valid PlantUML alias: letters, digits, underscore only, and never
# starting with a digit (a bare-number basename from an empty prefix would
# otherwise be an invalid alias).  Used consistently for node decls and edges.
_plantuml_id() {
    local id
    id=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_' '_')
    [[ "$id" =~ ^[A-Za-z_] ]] || id="n_${id}"
    printf '%s' "$id"
}

# ── output formats ────────────────────────────────────────────────────────────

_output_dot() {
    local rankdir='LR'
    [[ "$_GR_ORIENT" == 'tb' ]] && rankdir='TB'
    printf 'digraph {\n'
    printf '  rankdir=%s;\n' "$rankdir"
    printf '  node [shape=box fontname="monospace"];\n'

    local b
    for b in "${_GR_NODE_IDS[@]}"; do
        printf '  "%s" [label="%s"];\n' \
            "$(_esc_dot "$b")" "$(_esc_dot "${_GR_NODE_CURL[$b]:-}")"
    done

    local i
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        printf '  "%s" -> "%s" [label="%s"];\n' \
            "$(_esc_dot "${_GR_EDGE_FROM[$i]}")" \
            "$(_esc_dot "${_GR_EDGE_TO[$i]}")" \
            "$(_esc_dot "${_GR_EDGE_LABEL[$i]}")"
    done
    printf '}\n'
}

_output_mermaid() {
    local direction='LR'
    [[ "$_GR_ORIENT" == 'tb' ]] && direction='TD'
    printf 'graph %s\n' "$direction"

    local b
    for b in "${_GR_NODE_IDS[@]}"; do
        printf '  %s["%s"]\n' \
            "$(_mermaid_id "$b")" "$(_esc_mermaid "${_GR_NODE_CURL[$b]:-}")"
    done

    local i
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        printf '  %s -->|"%s"| %s\n' \
            "$(_mermaid_id "${_GR_EDGE_FROM[$i]}")" \
            "$(_esc_mermaid "${_GR_EDGE_LABEL[$i]}")" \
            "$(_mermaid_id "${_GR_EDGE_TO[$i]}")"
    done
}

_output_plantuml() {
    printf '@startuml\n'
    [[ "$_GR_ORIENT" == 'lr' ]] && printf 'left to right direction\n'

    local b
    for b in "${_GR_NODE_IDS[@]}"; do
        printf 'node "%s" as %s\n' \
            "$(_esc_plantuml "${_GR_NODE_CURL[$b]:-}")" "$(_plantuml_id "$b")"
    done

    local i
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        local label
        label=$(_esc_plantuml "${_GR_EDGE_LABEL[$i]}")
        if [[ -n "$label" ]]; then
            printf '%s --> %s : %s\n' \
                "$(_plantuml_id "${_GR_EDGE_FROM[$i]}")" \
                "$(_plantuml_id "${_GR_EDGE_TO[$i]}")" \
                "$label"
        else
            printf '%s --> %s\n' \
                "$(_plantuml_id "${_GR_EDGE_FROM[$i]}")" \
                "$(_plantuml_id "${_GR_EDGE_TO[$i]}")"
        fi
    done
    printf '@enduml\n'
}

# Repeat a (possibly multi-byte) string N times.
_ascii_repeat() {
    local c="$1" n="$2" out=''
    while (( n-- > 0 )); do out+="$c"; done
    printf '%s' "$out"
}

# Fit a string into W columns: truncate with a trailing … if it is too long.
# (Node text is ASCII URLs/ids, so character count equals column count.)
_ascii_fit() {
    local s="$1" w="$2"
    if   (( w <= 0 ));      then return 0
    elif (( ${#s} > w ));   then printf '%s…' "${s:0:w-1}"
    else                         printf '%s' "$s"; fi
}

# Draw a two-line rectangle for one node (id on top, "METHOD url" below) and
# echo its lines with no prefix; the caller indents them.
_ascii_box() {
    local id="$1" sub="$2" maxw=72
    local w=${#id}
    (( ${#sub} > w )) && w=${#sub}
    (( w > maxw )) && w=$maxw
    id=$(_ascii_fit "$id" "$w")
    sub=$(_ascii_fit "$sub" "$w")
    local bar; bar=$(_ascii_repeat '─' $(( w + 2 )))
    printf '┌%s┐\n'   "$bar"
    printf '│ %-*s │\n' "$w" "$id"
    printf '│ %-*s │\n' "$w" "$sub"
    printf '└%s┘\n'   "$bar"
}

# The box's second line: the request method (parsed from the .curl) and URL.
_ascii_node_sub() {
    local node="$1" method='GET' url="${_GR_NODE_URL[$node]:-}"
    local curl="${_GR_NODE_CURL[$node]:-}"
    [[ "$curl" =~ -X[[:space:]]+([A-Za-z]+) ]] && method="${BASH_REMATCH[1]}"
    [[ -z "$url" ]] && url='(no url)'
    printf '%s %s' "$method" "$url"
}

# Collect a node's outgoing edges (in edge order) into _CKIDS/_CLABS.  Labels can
# contain embedded newlines, so edges are read straight from the parallel arrays
# rather than packed into a single delimited string.
_ascii_children() {
    local node="$1" i
    _CKIDS=(); _CLABS=()
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        if [[ "${_GR_EDGE_FROM[$i]}" == "$node" ]]; then
            _CKIDS+=("${_GR_EDGE_TO[$i]}")
            _CLABS+=("${_GR_EDGE_LABEL[$i]}")
        fi
    done
}

# ── ascii: top-to-bottom (boxed indented tree) ────────────────────────────────

# Render a node's box at the given prefix, then each child below it, hung off a
# ├─/└─ branch carrying the edge label.  A node already drawn elsewhere is shown
# as a one-line back-reference so shared targets / cycles don't recurse forever.
_ascii_render() {
    local node="$1" prefix="$2"

    if [[ -n "${_ascii_seen[$node]:-}" ]]; then
        printf '%s· %s (shown above)\n' "$prefix" "$node"
        return 0
    fi
    _ascii_seen[$node]=1

    local line
    while IFS= read -r line; do
        printf '%s%s\n' "$prefix" "$line"
    done < <(_ascii_box "$node" "$(_ascii_node_sub "$node")")

    _ascii_children "$node"
    local kids=() labs=()
    (( ${#_CKIDS[@]} )) && kids=("${_CKIDS[@]}")
    (( ${#_CLABS[@]} )) && labs=("${_CLABS[@]}")

    local n=${#kids[@]} i
    # A short drop links the box's bottom edge to its branches.
    (( n > 0 )) && printf '%s│\n' "$prefix"
    for (( i = 0; i < n; i++ )); do
        local branch contpref
        if (( i == n - 1 )); then branch='└─ '; contpref="${prefix}   "
        else                      branch='├─ '; contpref="${prefix}│  "; fi

        # First label line rides the branch; continuation lines align under it.
        local label="${labs[$i]}"
        local first="${label%%$'\n'*}" rest="${label#*$'\n'}"
        printf '%s%s%s\n' "$prefix" "$branch" "$first"
        if [[ "$rest" != "$label" ]]; then
            local ll
            while IFS= read -r ll; do
                [[ -n "$ll" ]] && printf '%s%s\n' "$contpref" "$ll"
            done <<< "$rest"
        fi

        _ascii_render "${kids[$i]}" "$contpref"
    done
    return 0
}

_ascii_tb() {
    declare -A _ascii_seen=()

    # A root is any node with no incoming edge; render those first, in node order.
    declare -A _indeg=()
    local i
    for (( i = 0; i < ${#_GR_EDGE_TO[@]}; i++ )); do _indeg["${_GR_EDGE_TO[$i]}"]=1; done

    local b first=1
    for b in "${_GR_NODE_IDS[@]}"; do
        [[ -n "${_indeg[$b]:-}" ]] && continue
        (( first )) || printf '\n'; first=0
        _ascii_render "$b" ''
    done

    # Anything not reached above (e.g. only inside a cycle) still gets drawn.
    for b in "${_GR_NODE_IDS[@]}"; do
        [[ -n "${_ascii_seen[$b]:-}" ]] && continue
        (( first )) || printf '\n'; first=0
        _ascii_render "$b" ''
    done
    return 0
}

# ── ascii: left-to-right (boxes on a character canvas) ─────────────────────────
#
# The canvas _CV is a sparse grid of single ASCII glyphs keyed "row,col"; pure
# ASCII keeps one glyph == one column == one byte, so painting works regardless
# of locale.  Columns hold successive link depths; a tidy-tree pass stacks each
# node's children vertically and the parent is centred against them.

_cv_set() {
    _CV["$1,$2"]="$3"
    (( $1 > _CV_MAXY )) && _CV_MAXY=$1
    (( $2 > _CV_MAXX )) && _CV_MAXX=$2
    return 0
}
_cv_text() {
    local y="$1" x="$2" s="$3" i n=${#3}
    for (( i = 0; i < n; i++ )); do _cv_set "$y" $(( x + i )) "${s:i:1}"; done
    return 0
}
_cv_hline() { local y="$1" x; for (( x = $2; x <= $3; x++ )); do _cv_set "$y" "$x" '-'; done; return 0; }
_cv_vline() { local x="$1" y; for (( y = $2; y <= $3; y++ )); do _cv_set "$y" "$x" '|'; done; return 0; }

_cv_box() {
    local node="$1" x="$2" y="$3" w="${_W[$node]}"
    local id sub bar
    id=$(_ascii_fit "$node" "$w")
    sub=$(_ascii_fit "$(_ascii_node_sub "$node")" "$w")
    bar="+$(_ascii_repeat '-' $(( w + 2 )))+"
    _cv_text "$y"        "$x" "$bar"
    _cv_text $(( y + 1 )) "$x" "$(printf '| %-*s |' "$w" "$id")"
    _cv_text $(( y + 2 )) "$x" "$(printf '| %-*s |' "$w" "$sub")"
    _cv_text $(( y + 3 )) "$x" "$bar"
    return 0
}

# Assign each node a top row: leaves take the next free band, internal nodes are
# centred on their first and last child.  Depends on _BOXH/_VGAP/_COFF globals.
_lr_layout() {
    local node="$1"
    [[ -n "${_TOP[$node]:-}" ]] && return 0       # shared node already placed

    _ascii_children "$node"
    local kids=()
    (( ${#_CKIDS[@]} )) && kids=("${_CKIDS[@]}")
    local n=${#kids[@]}

    if (( n == 0 )); then
        _TOP[$node]=$_LR_ROW
        _LR_ROW=$(( _LR_ROW + _BOXH + _VGAP ))
        return 0
    fi

    local c
    for c in "${kids[@]}"; do _lr_layout "$c"; done

    local cf=$(( _TOP[${kids[0]}] + _COFF )) cl=$(( _TOP[${kids[n-1]}] + _COFF ))
    local center=$(( (cf + cl) / 2 ))
    _TOP[$node]=$(( center - _COFF ))
    (( _TOP[$node] < 0 )) && _TOP[$node]=0
    return 0
}

# Compute the left-to-right tidy-tree geometry in character cells.  The caller
# declares the maps _W/_OW/_DEPTH/_TOP/_COLW/_COLX/_GAP and the _BOXH/_VGAP/_COFF
# /_LR_ROW scalars; this fills them and sets _LR_MAXD to the deepest column.
# Shared by the ascii LR canvas and the native SVG renderer.
_lr_compute_layout() {
    local node i

    # Box widths and a first guess at depth (0 = root).  A caller may pre-set
    # _W/_OW (the SVG renderer sizes boxes to the curl command); leave those.
    for node in "${_GR_NODE_IDS[@]}"; do
        _DEPTH[$node]=0
        [[ -n "${_W[$node]:-}" ]] && continue
        local sub; sub=$(_ascii_node_sub "$node")
        local w=${#node}
        (( ${#sub} > w )) && w=${#sub}
        (( w > 72 )) && w=72
        _W[$node]=$w; _OW[$node]=$(( w + 4 ))
    done

    # Edges always run earlier→later, so one ordered pass fixes every depth as the
    # longest path from a root.
    for node in "${_GR_NODE_IDS[@]}"; do
        _ascii_children "$node"
        local c
        for c in ${_CKIDS[@]+"${_CKIDS[@]}"}; do
            local nd=$(( _DEPTH[$node] + 1 ))
            (( nd > ${_DEPTH[$c]:-0} )) && _DEPTH[$c]=$nd
        done
    done

    local maxd=0
    for node in "${_GR_NODE_IDS[@]}"; do (( _DEPTH[$node] > maxd )) && maxd=${_DEPTH[$node]}; done

    # Per-column box width and per-column connector gap (wide enough for its
    # widest edge label, drawn on the connector line).
    for node in "${_GR_NODE_IDS[@]}"; do
        local d=${_DEPTH[$node]}
        (( ${_OW[$node]} > ${_COLW[$d]:-0} )) && _COLW[$d]=${_OW[$node]}
    done
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        local d=${_DEPTH[${_GR_EDGE_FROM[$i]}]}
        local lbl="${_GR_EDGE_LABEL[$i]//$'\n'/ }"
        local need=$(( ${#lbl} + 6 ))
        (( need > ${_GAP[$d]:-8} )) && _GAP[$d]=$need
    done
    local d
    for (( d = 0; d <= maxd; d++ )); do : "${_COLW[$d]:=0}" "${_GAP[$d]:=8}"; done
    _COLX[0]=0
    for (( d = 1; d <= maxd; d++ )); do
        _COLX[$d]=$(( ${_COLX[$((d-1))]} + ${_COLW[$((d-1))]} + ${_GAP[$((d-1))]} ))
    done

    # Vertical placement: lay out each root's subtree, then any unreached node.
    declare -A _indeg=()
    for (( i = 0; i < ${#_GR_EDGE_TO[@]}; i++ )); do _indeg["${_GR_EDGE_TO[$i]}"]=1; done
    for node in "${_GR_NODE_IDS[@]}"; do
        [[ -n "${_indeg[$node]:-}" ]] && continue
        _lr_layout "$node"
    done
    for node in "${_GR_NODE_IDS[@]}"; do
        [[ -n "${_TOP[$node]:-}" ]] && continue
        _lr_layout "$node"
    done

    _LR_MAXD=$maxd
    return 0
}

_ascii_lr() {
    declare -A _CV=(); local _CV_MAXX=0 _CV_MAXY=0
    declare -A _W=() _OW=() _DEPTH=() _TOP=() _COLW=() _COLX=() _GAP=()
    local _BOXH=4 _VGAP=2 _COFF=1 _LR_ROW=0 _LR_MAXD=0
    local node i

    _lr_compute_layout

    # Paint boxes.
    for node in "${_GR_NODE_IDS[@]}"; do
        _cv_box "$node" "${_COLX[${_DEPTH[$node]}]}" "${_TOP[$node]}"
    done

    # Paint connectors: a stub off the parent's right edge to a vertical bus, then
    # one labelled arrow per child into its left edge.
    for node in "${_GR_NODE_IDS[@]}"; do
        _ascii_children "$node"
        local kids=() labs=()
        (( ${#_CKIDS[@]} )) && kids=("${_CKIDS[@]}")
        (( ${#_CLABS[@]} )) && labs=("${_CLABS[@]}")
        local n=${#kids[@]}
        (( n == 0 )) && continue

        local pd=${_DEPTH[$node]}
        local px2=$(( _COLX[$pd] + _OW[$node] - 1 ))
        local pay=$(( _TOP[$node] + _COFF ))
        local jx=$(( px2 + 2 ))

        local miny=$pay maxy=$pay k c cay
        for (( k = 0; k < n; k++ )); do
            cay=$(( _TOP[${kids[$k]}] + _COFF ))
            (( cay < miny )) && miny=$cay
            (( cay > maxy )) && maxy=$cay
        done
        _cv_hline "$pay" $(( px2 + 1 )) "$jx"
        _cv_vline "$jx" "$miny" "$maxy"
        _cv_set "$pay" "$jx" '+'

        for (( k = 0; k < n; k++ )); do
            c=${kids[$k]}
            local cd=${_DEPTH[$c]} cx=${_COLX[${_DEPTH[$c]}]}
            cay=$(( _TOP[$c] + _COFF ))
            _cv_hline "$cay" $(( jx + 1 )) $(( cx - 1 ))
            _cv_set "$cay" $(( cx - 1 )) '>'
            _cv_set "$cay" "$jx" '+'
            local lbl="${labs[$k]//$'\n'/ }"
            lbl=$(_ascii_fit "$lbl" $(( cx - jx - 3 )))
            [[ -n "$lbl" ]] && _cv_text "$cay" $(( jx + 2 )) "$lbl"
        done
    done

    # Emit the canvas, trimming each line's trailing blanks.
    local y x line cell
    for (( y = 0; y <= _CV_MAXY; y++ )); do
        line=''
        for (( x = 0; x <= _CV_MAXX; x++ )); do cell="${_CV[$y,$x]:- }"; line+="$cell"; done
        printf '%s\n' "${line%"${line##*[![:space:]]}"}"
    done
    return 0
}

_output_ascii() {
    if [[ "$_GR_ORIENT" == 'tb' ]]; then _ascii_tb; else _ascii_lr; fi
}

# Render a self-contained SVG directly from the tidy-tree geometry — no external
# renderer.  Character-cell layout (shared with the ascii LR canvas) is scaled to
# pixels: CW per column, RY per band row.  Orientation lr flows depth along x and
# stacks siblings along y; tb transposes (depth → y, siblings → x).
_output_svg() {
    declare -A _W=() _OW=() _DEPTH=() _TOP=() _COLW=() _COLX=() _GAP=()
    local _VGAP=2 _COFF=1 _LR_ROW=0 _LR_MAXD=0 node i

    # Box content is the full curl command, matching the dot/mermaid/plantuml
    # formats (one text line per curl line).  Pre-size each box to its widest
    # curl line so _lr_compute_layout keeps it; a uniform height (the tallest
    # curl plus a padding row top and bottom) preserves the tidy tree's equal-
    # row spacing.
    local maxlines=1
    for node in "${_GR_NODE_IDS[@]}"; do
        local cl="${_GR_NODE_CURL[$node]:-}" line w=0 nlines=0
        while IFS= read -r line; do
            nlines=$(( nlines + 1 ))
            (( ${#line} > w )) && w=${#line}
        done <<< "$cl"
        (( nlines == 0 )) && nlines=1
        (( w > 72 )) && w=72
        (( w < 1 )) && w=1
        _W[$node]=$w; _OW[$node]=$(( w + 4 ))
        (( nlines > maxlines )) && maxlines=$nlines
    done
    local _BOXH=$(( maxlines + 2 ))

    _lr_compute_layout

    local CW=8 RY=12 tb=0
    [[ "$_GR_ORIENT" == 'tb' ]] && tb=1

    # For tb the sibling axis is horizontal, so its pitch must clear the widest
    # box; derive a uniform band unit (in chars) from the maximum box width.
    local maxow=0
    for node in "${_GR_NODE_IDS[@]}"; do (( _OW[$node] > maxow )) && maxow=${_OW[$node]}; done
    local pitch=$(( _BOXH + _VGAP )) bandunit=$(( maxow + 4 ))

    # Pixel rectangle per node, and the overall canvas extent.
    declare -A _BX=() _BY=() _BW=() _BH=()
    local maxx=0 maxy=0
    for node in "${_GR_NODE_IDS[@]}"; do
        local d=${_DEPTH[$node]} x y
        if (( tb )); then
            x=$(( _TOP[$node] * bandunit * CW / pitch ))
            y=$(( d * pitch * RY ))
        else
            x=$(( _COLX[$d] * CW ))
            y=$(( _TOP[$node] * RY ))
        fi
        local w=$(( _OW[$node] * CW )) h=$(( _BOXH * RY ))
        _BX[$node]=$x; _BY[$node]=$y; _BW[$node]=$w; _BH[$node]=$h
        (( x + w > maxx )) && maxx=$(( x + w ))
        (( y + h > maxy )) && maxy=$(( y + h ))
    done

    local pad=20
    local cw=$(( maxx + pad )) ch=$(( maxy + pad ))
    (( cw < 40 )) && cw=40
    (( ch < 40 )) && ch=40

    printf '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="monospace" font-size="12">\n' \
        "$cw" "$ch" "$cw" "$ch"
    printf '  <defs><marker id="arrow" markerWidth="10" markerHeight="8" refX="8" refY="3" orient="auto" markerUnits="strokeWidth">'
    printf '<path d="M0,0 L8,3 L0,6 Z" fill="#333"/></marker></defs>\n'
    printf '  <rect width="100%%" height="100%%" fill="white"/>\n'

    # Edges first so the boxes paint over their endpoints.
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        local f="${_GR_EDGE_FROM[$i]}" t="${_GR_EDGE_TO[$i]}"
        [[ -z "${_BX[$f]:-}" || -z "${_BX[$t]:-}" ]] && continue
        local ox oy ix iy lx ly path
        if (( tb )); then
            ox=$(( _BX[$f] + _BW[$f]/2 )); oy=$(( _BY[$f] + _BH[$f] ))
            ix=$(( _BX[$t] + _BW[$t]/2 )); iy=${_BY[$t]}
            local my=$(( (oy + iy)/2 ))
            path="M $ox $oy V $my H $ix V $iy"
            # Anchor on the bus turn above the target: unique x per sibling.
            lx=$ix; ly=$my
        else
            ox=$(( _BX[$f] + _BW[$f] )); oy=$(( _BY[$f] + _BH[$f]/2 ))
            ix=${_BX[$t]};              iy=$(( _BY[$t] + _BH[$t]/2 ))
            local mx=$(( (ox + ix)/2 ))
            path="M $ox $oy H $mx V $iy H $ix"
            # Anchor on the segment entering the target: unique y per sibling.
            lx=$(( (mx + ix)/2 )); ly=$iy
        fi
        local stroke='#333'
        [[ "${_GR_EDGE_GUESS[$i]:-}" == 'ambiguous' ]] && stroke='#c33'
        printf '  <path d="%s" fill="none" stroke="%s" marker-end="url(#arrow)"/>\n' "$path" "$stroke"

        # Edge label: a center-anchored block set just above the anchor line,
        # over a white halo so it reads clearly and stays tied to its edge.
        # One <text> per non-empty line, stacked upward from the line.
        local lbl="${_GR_EDGE_LABEL[$i]}" line
        local -a _ll=(); local _lmax=0
        if [[ -n "$lbl" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                _ll+=("$line"); (( ${#line} > _lmax )) && _lmax=${#line}
            done <<< "$lbl"
        fi
        local n=${#_ll[@]}
        if (( n )); then
            local charw=6 lh=11 gap=4 j
            local bw=$(( _lmax * charw + 6 ))
            local firsty=$(( ly - gap - (n - 1) * lh ))
            printf '  <rect x="%d" y="%d" width="%d" height="%d" fill="white" fill-opacity="0.9"/>\n' \
                "$(( lx - bw / 2 ))" "$(( firsty - 9 ))" "$bw" "$(( n * lh + 2 ))"
            local ty=$firsty
            for (( j = 0; j < n; j++ )); do
                printf '  <text x="%d" y="%d" font-size="10" fill="#555" text-anchor="middle">%s</text>\n' \
                    "$lx" "$ty" "$(_esc_xml "${_ll[$j]}")"
                ty=$(( ty + lh ))
            done
        fi
    done

    # Boxes: the curl command, one <text> per line, each fitted to the box width.
    for node in "${_GR_NODE_IDS[@]}"; do
        local x=${_BX[$node]} y=${_BY[$node]} w=${_BW[$node]} h=${_BH[$node]}
        printf '  <rect x="%d" y="%d" width="%d" height="%d" rx="4" fill="#f5f5f5" stroke="#333"/>\n' \
            "$x" "$y" "$w" "$h"
        local cl="${_GR_NODE_CURL[$node]:-}" line j=0
        while IFS= read -r line; do
            printf '  <text x="%d" y="%d" font-size="10" fill="#333">%s</text>\n' \
                "$(( x + 6 ))" "$(( y + 14 + j * RY ))" \
                "$(_esc_xml "$(_ascii_fit "$line" "${_W[$node]}")")"
            j=$(( j + 1 ))
        done <<< "$cl"
    done

    printf '</svg>\n'
    return 0
}

_output_json() {
    printf '{\n  "nodes": [\n'
    local first=1 b
    for b in "${_GR_NODE_IDS[@]}"; do
        (( first )) || printf ',\n'
        first=0
        printf '    {"id":%s,"url":%s,"curl":%s}' \
            "$(printf '%s' "$b" | jq -Rs .)" \
            "$(printf '%s' "${_GR_NODE_URL[$b]:-}" | jq -Rs .)" \
            "$(printf '%s' "${_GR_NODE_CURL[$b]:-}" | jq -Rs .)"
    done
    printf '\n  ],\n  "edges": [\n'
    first=1
    local i
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        (( first )) || printf ',\n'
        first=0
        local guessed='false'
        [[ "${_GR_EDGE_GUESS[$i]:-}" == 'ambiguous' ]] && guessed='true'
        printf '    {"from":%s,"to":%s,"label":%s,"guessed":%s}' \
            "$(printf '%s' "${_GR_EDGE_FROM[$i]}" | jq -Rs .)" \
            "$(printf '%s' "${_GR_EDGE_TO[$i]}" | jq -Rs .)" \
            "$(printf '%s' "${_GR_EDGE_LABEL[$i]}" | jq -Rs .)" \
            "$guessed"
    done
    printf '\n  ]\n}\n'
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    _parse_args "$@"
    _check_tools
    _build_graph

    case "$_GR_FORMAT" in
        dot)      _output_dot ;;
        mermaid)  _output_mermaid ;;
        plantuml) _output_plantuml ;;
        ascii)    _output_ascii ;;
        json)     _output_json ;;
        svg)      _output_svg ;;
    esac
}

main "$@"
