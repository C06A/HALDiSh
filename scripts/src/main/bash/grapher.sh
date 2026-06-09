#!/usr/bin/env bash
# grapher.sh — Build a navigation graph from HAL session files
#
# Usage:
#   grapher.sh [--format dot|mermaid|plantuml|ascii|json] [--orientation lr|tb] [DIR]
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
        dot|mermaid|plantuml|ascii|json) ;;
        *) hal::log::die "grapher: unknown format '$_GR_FORMAT'. Use: dot mermaid plantuml ascii json" ;;
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

# Escape for PlantUML label: newlines → \n literal
_esc_plantuml() {
    local s="$1"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Emit a valid Mermaid node ID (letters, digits, underscore, hyphen)
_mermaid_id() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_'
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
        printf 'node "%s" as %s\n' "$(_esc_plantuml "${_GR_NODE_CURL[$b]:-}")" "$b"
    done

    local i
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        printf '%s --> %s : %s\n' \
            "${_GR_EDGE_FROM[$i]}" \
            "${_GR_EDGE_TO[$i]}" \
            "$(_esc_plantuml "${_GR_EDGE_LABEL[$i]}")"
    done
    printf '@enduml\n'
}

_output_ascii() {
    # Build incoming-edge index: target → "from|label"
    declare -A _incoming=()
    local i
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        local to="${_GR_EDGE_TO[$i]}"
        _incoming["$to"]+="${_GR_EDGE_FROM[$i]}|${_GR_EDGE_LABEL[$i]}"$'\n'
    done

    # Build outgoing-edge index: from → "label|to"
    declare -A _outgoing=()
    for (( i = 0; i < ${#_GR_EDGE_FROM[@]}; i++ )); do
        local from="${_GR_EDGE_FROM[$i]}"
        _outgoing["$from"]+="${_GR_EDGE_LABEL[$i]}|${_GR_EDGE_TO[$i]}"$'\n'
    done

    local b
    for b in "${_GR_NODE_IDS[@]}"; do
        printf '[%s]\n' "$b"
        printf '%s\n' "${_GR_NODE_CURL[$b]:-curl (unknown)}"

        # Incoming
        local entry
        while IFS=$'\n' read -r entry; do
            [[ -z "$entry" ]] && continue
            local from="${entry%%|*}"
            local label="${entry#*|}"
            # Multi-line label: indent continuation lines
            local first_line="${label%%$'\n'*}"
            local rest="${label#*$'\n'}"
            printf '  <-- %s via %s\n' "$from" "$first_line"
            if [[ "$rest" != "$label" ]]; then
                local ll
                while IFS= read -r ll; do
                    [[ -n "$ll" ]] && printf '       %s\n' "$ll"
                done <<< "$rest"
            fi
        done <<< "${_incoming[$b]:-}"

        # Outgoing
        while IFS=$'\n' read -r entry; do
            [[ -z "$entry" ]] && continue
            local label="${entry%%|*}"
            local to="${entry#*|}"
            local first_line="${label%%$'\n'*}"
            local rest="${label#*$'\n'}"
            printf '  --> %s via %s\n' "$to" "$first_line"
            if [[ "$rest" != "$label" ]]; then
                local ll
                while IFS= read -r ll; do
                    [[ -n "$ll" ]] && printf '       %s\n' "$ll"
                done <<< "$rest"
            fi
        done <<< "${_outgoing[$b]:-}"

        printf '\n'
    done
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
    esac
}

main "$@"
