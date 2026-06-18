#!/usr/bin/env bats
# =============================================================================
# nahal.bats — unit tests for nahal.sh
#
# nahal.sh launches an interactive HTTP session at the bottom of the file, so
# it carries a `BASH_SOURCE == $0` guard: sourcing the file defines every helper
# without running `main`.  These tests source it (via `_src`) to exercise the
# pure helpers in isolation, and also drive a few end-to-end sessions with a
# mock `GET` command plus a FIFO-backed menu TTY.
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

NAHAL_SH="${SCRIPTS_DIR}/nahal.sh"

# ── fixtures ──────────────────────────────────────────────────────────────────

LINK_JSON='{"_links":{"self":{"href":"/api/r"},"items":[{"href":"/a"},{"href":"/b"}]},"title":"T","count":3}'

setup() {
    WORK_DIR="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"

    # Mock HTTP method command.  Its presence satisfies the `command -v GET`
    # check in _brow_setup_methods; when actually invoked (smoke tests) it
    # writes an httpreq-style file family into the cwd — which nahal.sh has
    # cd'd into the session output directory — and echoes the base name.
    cat > "${STUB_DIR}/GET" <<'MOCK'
#!/usr/bin/env bash
# Drain stdin in --link mode (like real httpreq.sh) so a `hallink | GET --link`
# pipe doesn't break with SIGPIPE.
case " $* " in *" --link "*) cat >/dev/null 2>&1 || true ;; esac
# Honor -s <base> exactly like the real httpreq.sh: the caller (nahal.sh / the
# replay) numbers the base via hal_basename.sh and passes it here, so the output
# files land under the predictable name with no rename.
base="resp"
_prev=""
for _a in "$@"; do
    [[ "$_prev" == "-s" ]] && { base="$_a"; break; }
    _prev="$_a"
done
ct="${MOCK_CT:-application/hal+json}"
printf 'HTTP/1.1 200 OK\r\nContent-Type: %s\r\n\r\n' "$ct" > "${base}.headers"
printf '200' > "${base}.status"
body="${MOCK_BODY:-}"
[[ -z "$body" ]] && body='{ "_links": { "self": { "href": "/api/r" } }, "title": "Mock" }'
printf '%s' "$body" > "${base}.body"
printf 'curl -X GET\n' > "${base}.curl"
printf '%s\n' "$base"      # real httpreq.sh prints the base with a trailing newline
MOCK
    chmod +x "${STUB_DIR}/GET"
    # A POST command with identical behavior, for testing non-GET dispatch.
    cp "${STUB_DIR}/GET" "${STUB_DIR}/POST"

    # Stub the browser opener so "docs" tests capture the URL instead of
    # launching a real browser.  Records to $OPEN_LOG when set.
    cat > "${STUB_DIR}/open" <<'OPENMOCK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${OPEN_LOG:-/dev/null}"
OPENMOCK
    chmod +x "${STUB_DIR}/open"

    export PATH="${STUB_DIR}:${PATH}"

    # FIFO-backed menu TTY so sequential menu.sh subprocesses can each read a
    # keystroke.  fd 9 holds the write end open (see hal.bats / menu.bats).
    TEST_TTY="${WORK_DIR}/menu_tty"
    mkfifo "$TEST_TTY"
    exec 9<>"$TEST_TTY"
    export _MENU_TTY="$TEST_TTY"
}

teardown() {
    exec 9>&- 2>/dev/null || true
    rm -rf "$WORK_DIR" "$STUB_DIR"
}

_type_key()  { printf '%s'   "$@" >&9; }   # menu.sh keystrokes (no newline)
_type_line() { printf '%s\n' "$@" >&9; }   # _brow_prompt line input (newline)

# _src '<bash using nahal helpers>' [args...]
# Sources nahal.sh (guard skips main), initialises the JSON tool, then evals the
# snippet with the extra args available as $1, $2, …  Runs in a subshell so the
# script's `set -euo pipefail` never leaks into the test process.
_src() {
    local code="$1"; shift
    run bash -c '
        source "$1" >/dev/null 2>&1 || true
        _brow_init_tool
        _code="$2"; shift 2
        eval "$_code"
    ' _ "$NAHAL_SH" "$code" "$@"
}

# ── content-type classification ───────────────────────────────────────────────

@test "_brow_classify_ct: hal+json is hal" {
    _src '_brow_classify_ct "application/hal+json"'
    [ "$output" = "hal" ]
}

@test "_brow_classify_ct: strips charset parameter" {
    _src '_brow_classify_ct "application/hal+json; charset=utf-8"'
    [ "$output" = "hal" ]
}

@test "_brow_classify_ct: case-insensitive" {
    _src '_brow_classify_ct "APPLICATION/HAL+JSON"'
    [ "$output" = "hal" ]
}

@test "_brow_classify_ct: hal+xml and hal+yaml are hal" {
    _src '_brow_classify_ct "application/hal+xml"'
    [ "$output" = "hal" ]
    _src '_brow_classify_ct "application/hal+yaml"'
    [ "$output" = "hal" ]
}

@test "_brow_classify_ct: plain application/json and xml and yaml are hal" {
    _src '_brow_classify_ct "application/json"'
    [ "$output" = "hal" ]
    _src '_brow_classify_ct "application/xml"'
    [ "$output" = "hal" ]
    _src '_brow_classify_ct "application/yaml"'
    [ "$output" = "hal" ]
}

@test "_brow_classify_ct: text/* is text" {
    _src '_brow_classify_ct "text/plain"'
    [ "$output" = "text" ]
    _src '_brow_classify_ct "text/html; charset=utf-8"'
    [ "$output" = "text" ]
}

@test "_brow_classify_ct: unknown and empty are binary" {
    _src '_brow_classify_ct "image/png"'
    [ "$output" = "binary" ]
    _src '_brow_classify_ct "application/octet-stream"'
    [ "$output" = "binary" ]
    _src '_brow_classify_ct ""'
    [ "$output" = "binary" ]
}

# ── format detection / conversion ─────────────────────────────────────────────

@test "_brow_detect_format: identifies JSON" {
    _src '_brow_detect_format "$1"' '{"a":1}'
    [ "$status" -eq 0 ]
    [ "$output" = "json" ]
}

@test "_brow_detect_format: fails on content that is neither JSON, XML, nor YAML" {
    # jq-only environments report YAML/XML unsupported; either way it is non-zero.
    _src '_brow_detect_format "$1"' ':::not: valid: [ }'
    [ "$status" -ne 0 ]
}

@test "_brow_to_json: passes JSON through unchanged" {
    _src '_brow_to_json "$1" json' '{"a":1}'
    [ "$status" -eq 0 ]
    [ "$output" = '{"a":1}' ]
}

@test "_brow_detect_format: identifies YAML (yq)" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    _src '_brow_detect_format "$1"' 'title: hello'
    [ "$status" -eq 0 ]
    [ "$output" = "yaml" ]
}

@test "_brow_detect_format: identifies XML (yq)" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    _src '_brow_detect_format "$1"' '<r><a>1</a></r>'
    [ "$status" -eq 0 ]
    [ "$output" = "xml" ]
}

@test "_brow_to_json: converts YAML to JSON (yq)" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    _src '_brow_to_json "$1" yaml' 'a: 1'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"a"'* ]]
    [[ "$output" == *'1'* ]]
}

@test "_brow_to_json: converts XML to JSON (yq)" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    _src '_brow_to_json "$1" xml' '<r><a>1</a></r>'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"a"'* ]]
}

# ── type normalization ────────────────────────────────────────────────────────

@test "_brow_qtype: object" {
    _src '_brow_qtype "$1"' '{}'
    [ "$output" = "object" ]
}

@test "_brow_qtype: array" {
    _src '_brow_qtype "$1"' '[]'
    [ "$output" = "array" ]
}

@test "_brow_qtype: string number boolean null" {
    _src '_brow_qtype "$1"' '"hi"'
    [ "$output" = "string" ]
    _src '_brow_qtype "$1"' '42'
    [ "$output" = "number" ]
    _src '_brow_qtype "$1"' 'true'
    [ "$output" = "boolean" ]
    _src '_brow_qtype "$1"' 'null'
    [ "$output" = "null" ]
}

# ── query helpers ─────────────────────────────────────────────────────────────

@test "_brow_qr: extracts raw scalar" {
    _src '_brow_qr "$1" .title' "$LINK_JSON"
    [ "$output" = "T" ]
    _src '_brow_qr "$1" .count' "$LINK_JSON"
    [ "$output" = "3" ]
}

@test "_brow_q: extracts compact JSON" {
    _src '_brow_q "$1" .title' "$LINK_JSON"
    [ "$output" = '"T"' ]
}

@test "_brow_qk: extracts object value by key" {
    _src '_brow_qk "$1" title' "$LINK_JSON"
    [ "$output" = '"T"' ]
}

@test "_brow_qkr: extracts raw scalar by key" {
    _src '_brow_qkr "$1" title' "$LINK_JSON"
    [ "$output" = "T" ]
}

@test "_brow_qi: extracts array element by index" {
    _src '_brow_qi "$1" 0' '[{"href":"/a"},{"href":"/b"}]'
    [ "$output" = '{"href":"/a"}' ]
    _src '_brow_qi "$1" 1' '[{"href":"/a"},{"href":"/b"}]'
    [ "$output" = '{"href":"/b"}' ]
}

# ── rel filter ────────────────────────────────────────────────────────────────

@test "_brow_rel_filter: bracket-quotes a simple rel" {
    _src '_brow_rel_filter "$1"' 'self'
    [ "$output" = '._links["self"].href' ]
}

@test "_brow_rel_filter: handles a CURIE rel containing a colon" {
    _src '_brow_rel_filter "$1"' 'ex:items'
    [ "$output" = '._links["ex:items"].href' ]
}

@test "_brow_rel_filter: escapes embedded double quotes" {
    _src '_brow_rel_filter "$1"' 'a"b'
    [ "$output" = '._links["a\"b"].href' ]
}

# ── accept header for a link ─────────────────────────────────────────────────

@test "_brow_accept_for_link: uses the link's type field when present" {
    _src '_brow_accept_for_link "$1"' '{"href":"/x","type":"application/json"}'
    [ "$output" = "application/json" ]
}

@test "_brow_accept_for_link: falls back to the default HAL accept header" {
    _src '_brow_accept_for_link "$1"' '{"href":"/x"}'
    [[ "$output" == *"application/hal+json"* ]]
}

# ── content-type extraction from headers ──────────────────────────────────────

@test "_brow_get_ct: extracts content-type, case-insensitive, trimmed, CR-stripped" {
    printf 'HTTP/1.1 200 OK\r\ncontent-type:  text/html; charset=utf-8\r\n\r\n' \
        > "${WORK_DIR}/h"
    _src '_brow_get_ct "$1"' "${WORK_DIR}/h"
    [ "$output" = "text/html; charset=utf-8" ]
}

@test "_brow_get_ct: returns empty when header absent" {
    printf 'HTTP/1.1 200 OK\r\nX-Other: 1\r\n\r\n' > "${WORK_DIR}/h"
    _src '_brow_get_ct "$1"' "${WORK_DIR}/h"
    [ -z "$output" ]
}

# ── tool selection ────────────────────────────────────────────────────────────

@test "_brow_init_tool: selects yq when available" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bash -c 'source "$1" >/dev/null 2>&1 || true; _brow_init_tool; printf "%s" "$_BROW_TOOL"' \
        _ "$NAHAL_SH"
    [ "$output" = "yq" ]
}

@test "_brow_init_tool: falls back to jq when yq is broken" {
    local stub; stub="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub}/yq"; chmod +x "${stub}/yq"
    run env PATH="${stub}:${PATH}" bash -c \
        'source "$1" >/dev/null 2>&1 || true; _brow_init_tool; printf "%s" "$_BROW_TOOL"' \
        _ "$NAHAL_SH"
    [ "$status" -eq 0 ]
    [ "$output" = "jq" ]
    rm -rf "$stub"
}

@test "_brow_init_tool: exits 1 when neither yq nor jq is available" {
    local stub; stub="$(mktemp -d)"
    # Broken yq stub; PATH excludes real jq (/usr/local/bin) so it is absent.
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub}/yq"; chmod +x "${stub}/yq"
    run env PATH="${stub}:/usr/bin:/bin" bash -c \
        'source "$1" >/dev/null 2>&1 || true; _brow_init_tool' _ "$NAHAL_SH"
    [ "$status" -eq 1 ]
    rm -rf "$stub"
}

# ── method-command requirement ────────────────────────────────────────────────

@test "_brow_setup_methods: exits 1 when HTTP method commands are missing" {
    run --separate-stderr env PATH="/usr/bin:/bin" bash -c \
        'source "$1" >/dev/null 2>&1 || true; _brow_setup_methods' _ "$NAHAL_SH"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"method"* ]]
}

# ── argument resolution / usage ───────────────────────────────────────────────

@test "nahal.sh exits 1 with no arguments" {
    run bash "$NAHAL_SH"
    [ "$status" -eq 1 ]
}

@test "nahal.sh prints usage to stderr with no arguments" {
    run --separate-stderr bash "$NAHAL_SH"
    [[ "$stderr" == *"Usage:"* ]]
}

@test "nahal.sh exits 1 for link text without an href" {
    run --separate-stderr bash "$NAHAL_SH" '{"foo":"bar"}'
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"href"* ]]
}

@test "nahal.sh exits 1 when the resource file does not exist" {
    run --separate-stderr bash "$NAHAL_SH" /no/such/file.json links self
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not a file"* ]]
}

# ── method token validation ───────────────────────────────────────────────────

@test "_brow_valid_method: accepts standard and extension verbs" {
    _src '_brow_valid_method GET && _brow_valid_method POST && _brow_valid_method PROPFIND'
    [ "$status" -eq 0 ]
}

@test "_brow_valid_method: accepts the full RFC 7230 token charset" {
    local tok='a1!#$%&'"'"'*+-.^_`|~'
    _src '_brow_valid_method "$1"' "$tok"
    [ "$status" -eq 0 ]
}

@test "_brow_valid_method: rejects empty input" {
    _src '_brow_valid_method ""'
    [ "$status" -ne 0 ]
}

@test "_brow_valid_method: rejects spaces and slashes" {
    _src '_brow_valid_method "$1"' "bad method"
    [ "$status" -ne 0 ]
    _src '_brow_valid_method "$1"' "a/b"
    [ "$status" -ne 0 ]
}

# ── runtime-local method links ─────────────────────────────────────────────────

@test "_brow_link_method: hardlinks ./<METHOD> to .httpreq.sh" {
    mkdir -p "${WORK_DIR}/lib" "${WORK_DIR}/out"
    printf 'x' > "${WORK_DIR}/lib/.httpreq.sh"
    _src '_SCRIPT_DIR="$1"; _BROW_OUTDIR="$2"; _brow_link_method HEAD' \
        "${WORK_DIR}/lib" "${WORK_DIR}/out"
    [ "$status" -eq 0 ]
    [ "${WORK_DIR}/out/HEAD" -ef "${WORK_DIR}/lib/.httpreq.sh" ]
}

@test "_brow_link_method: falls back to a symlink when a hardlink is not possible" {
    mkdir -p "${WORK_DIR}/out"
    # Missing source makes `ln -f` fail, exercising the symlink fallback.
    _src '_SCRIPT_DIR="$1"; _BROW_OUTDIR="$2"; _brow_link_method PROPFIND' \
        "${WORK_DIR}/nonexistent" "${WORK_DIR}/out"
    [ "$status" -eq 0 ]
    [ -L "${WORK_DIR}/out/PROPFIND" ]
}

@test "_brow_link_method: is a no-op when the link already exists" {
    mkdir -p "${WORK_DIR}/lib" "${WORK_DIR}/out"
    printf 'x' > "${WORK_DIR}/lib/.httpreq.sh"
    printf 'existing' > "${WORK_DIR}/out/HEAD"
    _src '_SCRIPT_DIR="$1"; _BROW_OUTDIR="$2"; _brow_link_method HEAD' \
        "${WORK_DIR}/lib" "${WORK_DIR}/out"
    [ "$status" -eq 0 ]
    run cat "${WORK_DIR}/out/HEAD"
    [ "$output" = "existing" ]
}

# ── dropped file:// path normalization ────────────────────────────────────────

@test "_brow_normalize_path: strips a file:// scheme" {
    _src '_brow_normalize_path "$1"' 'file:///Users/me/x.json'
    [ "$output" = "/Users/me/x.json" ]
}

@test "_brow_normalize_path: percent-decodes encoded characters" {
    _src '_brow_normalize_path "$1"' 'file:///Users/me/My%20File.txt'
    [ "$output" = "/Users/me/My File.txt" ]
    _src '_brow_normalize_path "$1"' 'file:///a%25b%2Fc'
    [ "$output" = "/a%b/c" ]
}

@test "_brow_normalize_path: handles the single-slash file: form" {
    _src '_brow_normalize_path "$1"' 'file:/Users/x'
    [ "$output" = "/Users/x" ]
}

@test "_brow_normalize_path: leaves a plain typed path unchanged (even with %)" {
    _src '_brow_normalize_path "$1"' '/plain/path/with%20literal'
    [ "$output" = "/plain/path/with%20literal" ]
}

@test "_brow_normalize_path: empty input stays empty" {
    _src '_brow_normalize_path ""'
    [ -z "$output" ]
}

# ── method invocation resolution ──────────────────────────────────────────────

@test "_brow_invoke_name: standard verbs are invoked bare" {
    _src 'printf "%s,%s" "$(_brow_invoke_name GET)" "$(_brow_invoke_name DELETE)"'
    [ "$output" = "GET,DELETE" ]
}

@test "_brow_invoke_name: a same-named system command does not hijack HEAD" {
    local stub; stub="$(mktemp -d)"
    printf '#!/bin/sh\n' > "${stub}/HEAD"; chmod +x "${stub}/HEAD"
    run env PATH="${stub}:${PATH}" bash -c \
        'source "$1" >/dev/null 2>&1 || true; _brow_invoke_name HEAD' _ "$NAHAL_SH"
    [ "$output" = "./HEAD" ]
    rm -rf "$stub"
}

@test "_brow_invoke_name: custom verbs dispatch via a local link" {
    _src '_brow_invoke_name PROPFIND'
    [ "$output" = "./PROPFIND" ]
}

@test "_brow_invoke_name: a command in the install dir is invoked bare" {
    local d; d="$(mktemp -d)"; d="$(cd "$d" && pwd)"   # resolve symlinks (macOS /var)
    printf '#!/bin/sh\n' > "${d}/PURGE"; chmod +x "${d}/PURGE"
    run env PATH="${d}:${PATH}" bash -c \
        'source "$1" >/dev/null 2>&1 || true; _SCRIPT_DIR="$2"; _brow_invoke_name PURGE' \
        _ "$NAHAL_SH" "$d"
    [ "$output" = "PURGE" ]
    rm -rf "$d"
}

# ── request headers (replay) ──────────────────────────────────────────────────

@test "_brow_req_headers: no header for a GET on a typed link" {
    _src '_brow_req_headers "{\"href\":\"/x\",\"type\":\"application/hal+json\"}"'
    [ -z "$output" ]
}

@test "_brow_req_headers: no header for a GET on an untyped link (Accept comes from the link)" {
    _src '_brow_req_headers "{\"href\":\"/x\"}"'
    [ -z "$output" ]
}

@test "_brow_req_headers: a JSON body yields Content-Type only, never Accept" {
    _src '_brow_req_headers "{\"href\":\"/x\"}" -a "{\"k\":1}"'
    [[ "$output" == *"Content-Type:application/json"* ]]
    [[ "$output" != *"Accept:"* ]]
}

@test "_brow_req_headers: a urlencoded body yields the form Content-Type, never Accept" {
    _src '_brow_req_headers "{\"href\":\"/x\"}" -u "a=1"'
    [[ "$output" == *"Content-Type:application/x-www-form-urlencoded"* ]]
    [[ "$output" != *"Accept:"* ]]
}

@test "_brow_log_step: custom method, inline header, array capture, hal_basename naming" {
    run bash -c '
        source "$1" >/dev/null 2>&1 || true
        _BROW_LOG="$2"; _BROW_STEP=3; _BROW_PREFIX=req
        : > "$2"
        cmd="hallink.sh -s \"\$_s\" \"\${_b[2]}.body\" links self
./HEAD -s \"\$_s\" --link"
        _brow_log_step "Accept:x" "./HEAD" "$cmd" "follow"
        cat "$2"
    ' _ "$NAHAL_SH" "${WORK_DIR}/log"
    [[ "$output" == *"_ensure_method HEAD"* ]]
    [[ "$output" == *'HTTP_IN_HEADERS="Accept:x'* ]]
    [[ "$output" == *'./HEAD -s "$_s" --link'* ]]
    [[ "$output" == *'_s=$(hal_basename.sh -p "$_prefix")'* ]]   # base numbered once
    [[ "$output" == *'${_b[2]}.body'* ]]
    [[ "$output" != *'rename.sh'* ]]                 # no rename — -s names the files
    [[ "$output" != *"(HTTP_IN_HEADERS"* ]]
    # Multi-line layout: "$(" opens its own line, ")" closes its own line, and
    # the piped/continued stages are indented.
    [[ "$output" == *$'_b[3]=$(\n'* ]]
    [[ "$output" == *$'\n)'* ]]
    [[ "$output" == *$'  _s=$(hal_basename.sh -p "$_prefix")\n'* ]]
    [[ "$output" == *$'\n  hallink.sh -s "$_s" "${_b[2]}.body" links self \\\n'* ]]
    [[ "$output" == *$'\n  ./HEAD -s "$_s" --link\n'* ]]
}

# ── documentation (CURIE) ─────────────────────────────────────────────────────

CURI_RES='{"_links":{"self":{"href":"/r"},"curies":[{"name":"ex","href":"https://ex.com/docs/{rel}","templated":true}],"ex:widget":{"href":"/w"},"ex:item":{"href":"/i"}},"title":"t"}'

@test "_brow_curi_rels: lists rels using a defined curie prefix" {
    _src '_brow_curi_rels "$1"' "$CURI_RES"
    [[ "$output" == *"ex:widget"* ]]
    [[ "$output" == *"ex:item"* ]]
}

@test "_brow_curi_rels: empty when curies present but no prefixed rel uses them" {
    _src '_brow_curi_rels "$1"' '{"_links":{"self":{"href":"/r"},"curies":[{"name":"ex","href":"x/{rel}"}]}}'
    [ -z "$output" ]
}

@test "_brow_curi_rels: empty when there are no curies" {
    _src '_brow_curi_rels "$1"' '{"_links":{"self":{"href":"/r"}}}'
    [ -z "$output" ]
}

@test "_brow_resolve_curi_url: expands the curie template for a rel" {
    _src 'links=$(_brow_qk "$1" _links); _brow_resolve_curi_url "$links" ex:widget' "$CURI_RES"
    [ "$output" = "https://ex.com/docs/widget" ]
}

@test "_brow_curi_link: returns the curie link with href expanded and templated false" {
    _src 'links=$(_brow_qk "$1" _links); _brow_curi_link "$links" ex:widget' "$CURI_RES"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"https://ex.com/docs/widget"'* ]]   # template expanded
    [[ "$output" == *'"name":"ex"'* ]]                           # curie object preserved
    [[ "$output" == *'"templated":false'* ]]                     # no longer templated
}

@test "_brow_curi_link: returns non-zero when no curie defines the prefix" {
    _src 'links=$(_brow_qk "$1" _links); _brow_curi_link "$links" zz:widget' "$CURI_RES"
    [ "$status" -ne 0 ]
}

# ── interactive session smoke tests ───────────────────────────────────────────

@test "interactive: GET a HAL resource then quit" {
    # Resource menu (top-level): links(1) properties(2) print resource(3) quit(4)
    _type_key '4'
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"example.com"* ]]
    # A session directory + replay log are created next to the run.
    [ -n "$(ls -d "${WORK_DIR}"/nahal_* 2>/dev/null)" ]
}

@test "interactive: navigate into links, show details, back, then quit" {
    _type_key '1'   # links
    _type_key '2'   # self           (links menu: back(1) self(2))
    _type_key '2'   # show details   (action: follow(1) details(2) back(3)) — loops
    _type_key '3'   # back           → back to links list
    _type_key '1'   # back           → back to resource
    _type_key '4'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"/api/r"* ]]
}

@test "interactive: GET an array of HAL resources, enter one element, then quit" {
    export MOCK_BODY='[{"_links":{"self":{"href":"/api/a"}},"n":1},{"_links":{"self":{"href":"/api/b"}},"n":2}]'
    _type_key '1'   # element 1   (array menu: 1:/api/a(1) 2:/api/b(2) print(3) quit(4))
    _type_key '5'   # quit        (element resource: links(1) properties(2) print(3) back(4) quit(5))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"array of 2"* ]]
    [[ "$stderr" == *"/api/a"* ]]
}

@test "interactive: a link followed after 'back' is resolved from the resource navigated back to" {
    # Regression: after navigating root → B and pressing 'back' to root, following
    # a *root* link (toX) must extract it from root's body — not the deepest
    # fetched body (B), which the global last-base used to point at.  A URL-routing
    # mock returns a different body per requested path so the source body matters.
    cat > "${STUB_DIR}/GET" <<'ROUTER'
#!/usr/bin/env bash
base="resp"; _prev=""; url=""; is_link=0
for _a in "$@"; do
    [[ "$_prev" == "-s" ]] && base="$_a"
    [[ "$_a" == "--link" ]] && is_link=1
    [[ "$_a" != -* && "$_prev" != "-s" && -z "$url" ]] && url="$_a"
    _prev="$_a"
done
# In --link mode the link object arrives on stdin; its href is the request URL.
if (( is_link )); then
    _link=$(cat)
    url=$(printf '%s' "$_link" | jq -r '.href // empty' 2>/dev/null)
fi
case "$url" in
    */B)  body='{"_links":{"self":{"href":"/B"}}}' ;;                       # B: no toX
    */X)  body='{"_links":{"self":{"href":"/X"}}}' ;;                       # the goal
    *)    body='{"_links":{"self":{"href":"/A"},"toB":{"href":"/B"},"toX":{"href":"/X"}}}' ;;
esac
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/hal+json\r\n\r\n' > "${base}.headers"
printf '200' > "${base}.status"
printf '%s' "$body" > "${base}.body"
printf 'curl -X GET\n' > "${base}.curl"
printf '%s\n' "$base"
ROUTER
    chmod +x "${STUB_DIR}/GET"

    # rels sort identically under jq (alphabetical) and yq (document order):
    # self, toB, toX.
    _type_key '1'   # links               (root: links(1) print(2) quit(3))
    _type_key '3'   # toB                 (links: back(1) self(2) toB(3) toX(4))
    _type_key '1'   # follow              (action: follow(1) details(2) back(3))
    _type_key '1'   # GET                 (method: GET(1) …)
    _type_key '3'   # back                (B resource: links(1) print(2) back(3) quit(4))
    _type_key '4'   # toX                 (root links again: back(1) self(2) toB(3) toX(4))
    _type_key '1'   # follow
    _type_key '1'   # GET
    _type_key '4'   # quit                (followed resource: links(1) print(2) back(3) quit(4))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p req http://example.com/A' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]

    local dir; dir=$(ls -d "${WORK_DIR}"/nahal_* | head -1)
    # Three successful fetches: A (req1), B (req2), X (req3).
    [ -f "${dir}/req3.body" ]
    # The third fetch reached /X — proving the toX follow read root's body, not B's.
    grep -qF '/X' "${dir}/req3.body"
    # The toX request's recorded source sidecar is root's body (req1), not B's (req2).
    grep -qF 'req1.body' "${dir}/req3.source"
}

@test "interactive: follow an element of an array-valued link rel, logging the index" {
    # _links.items is an array of two links; only that one rel so menu positions
    # are the same under jq (sorted keys) and yq (document order).
    export MOCK_BODY='{"_links":{"items":[{"href":"/a"},{"href":"/b"}]},"title":"t"}'
    _type_key '1'   # links                 (top: links(1) properties(2) print(3) quit(4))
    _type_key '2'   # items                 (links: back(1) items(2))
    _type_key '3'   # element 1 → /b        (choose link: back(1) 0:/a(2) 1:/b(3))
    _type_key '1'   # follow (send request) (action: follow(1) details(2) back(3))
    _type_key '1'   # GET                   (HTTP method menu: GET(1) …)
    _type_key '5'   # quit                  (followed resource: links(1) properties(2) print(3) back(4) quit(5))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Choose link"* ]]      # the array element picker appeared
    local s; s=$(ls -d "${WORK_DIR}"/nahal_*/session.sh | head -1)
    grep -qF 'hallink.sh -s "$_s" "${_b[1]}.body" links items 1' "$s"   # indexed hal-path
    grep -qF '# follow links items 1' "$s"                     # comment carries the index
    ! grep -qF 'links items 0' "$s"                            # the other element not followed
}

@test "interactive: docs option appears for a CURIE resource and opens the doc URL" {
    # Single curie rel so the docs-menu selection is deterministic regardless of
    # whether jq (sorted) or yq (document order) lists the keys.
    export MOCK_BODY='{"_links":{"self":{"href":"/api/r"},"curies":[{"name":"ex","href":"https://ex.com/docs/{rel}","templated":true}],"ex:widget":{"href":"/w"}},"title":"t"}'
    export OPEN_LOG="${WORK_DIR}/opened"
    # Resource menu: links(1) properties(2) docs(3) print(4) quit(5)
    _type_key '3'   # docs
    _type_key '2'   # ex:widget   (docs menu: back(1) ex:widget(2))
    _type_key '1'   # back
    _type_key '5'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"docs"* ]]
    run cat "${OPEN_LOG}"
    [ "$output" = "https://ex.com/docs/widget" ]
}

@test "interactive: docs link is passed through HAL_LINK_PLUGIN before opening" {
    # A plugin that prepends "PLUGIN:" to the link's href; proves the resolved
    # curie doc link is run through HAL_LINK_PLUGIN before the browser is opened.
    local plug="${WORK_DIR}/docplug.sh"
    cat > "$plug" <<'PLUG'
#!/usr/bin/env bash
sed 's#"href":"#"href":"PLUGIN:#'
PLUG
    chmod +x "$plug"
    export HAL_LINK_PLUGIN="$plug"
    export MOCK_BODY='{"_links":{"self":{"href":"/api/r"},"curies":[{"name":"ex","href":"https://ex.com/docs/{rel}","templated":true}],"ex:widget":{"href":"/w"}},"title":"t"}'
    export OPEN_LOG="${WORK_DIR}/opened"
    _type_key '3'   # docs
    _type_key '2'   # ex:widget
    _type_key '1'   # back
    _type_key '5'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    run cat "${OPEN_LOG}"
    [ "$output" = "PLUGIN:https://ex.com/docs/widget" ]
}

@test "interactive: docs option is absent when no rel uses a curie prefix" {
    export MOCK_BODY='{"_links":{"self":{"href":"/api/r"},"curies":[{"name":"ex","href":"https://ex.com/docs/{rel}"}]},"title":"t"}'
    _type_key '3'   # links(1) properties(2) print(3) quit(4) — no docs; 3 = print
    _type_key '4'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"docs"* ]]
}

# ── links menu: curies display mode (-c / NAHAL_CURIES) ───────────────────────

# Resource with two curie prefixes (c1, c2): order is defined under both, report
# only under c1.  Resource menu: links(1) properties(2) docs(3) print(4) quit(5).
CURIE_LINKS_BODY='{"_links":{"self":{"href":"/api/r"},"curies":[{"name":"c1","href":"https://d/{rel}","templated":true},{"name":"c2","href":"https://d2/{rel}","templated":true}],"c1:order":{"href":"/o1"},"c2:order":{"href":"/o2"},"c1:report":{"href":"/rp"}},"title":"t"}'

@test "links menu (default/without curies): shows local names, groups duplicates, hides curies" {
    export MOCK_BODY="$CURIE_LINKS_BODY"
    _type_key '1'   # links
    _type_key '1'   # back
    _type_key '5'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"order (c1, c2)"* ]]   # duplicate local name → grouped
    [[ "$stderr" == *"report"* ]]           # single-match shown by local name
    [[ "$stderr" != *"c1:order"* ]]         # full prefixed rels not shown
    [[ "$stderr" != *"c1:report"* ]]
}

@test "links menu (-c on): shows full CURIE-prefixed rels" {
    export MOCK_BODY="$CURIE_LINKS_BODY"
    _type_key '1'   # links
    _type_key '1'   # back
    _type_key '5'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -c on -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"c1:order"* ]]
    [[ "$stderr" == *"c2:order"* ]]
    [[ "$stderr" == *"c1:report"* ]]
    [[ "$stderr" != *"order (c1, c2)"* ]]
}

@test "links menu: -c overrides NAHAL_CURIES" {
    export MOCK_BODY="$CURIE_LINKS_BODY"
    _type_key '1'; _type_key '1'; _type_key '5'
    run --separate-stderr bash -c 'cd "$2" && NAHAL_CURIES=off bash "$1" -c on -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"c1:order"* ]]         # -c on wins over NAHAL_CURIES=off
}

@test "links menu (without curies): ambiguous local name disambiguates and logs the real rel" {
    # Single ambiguous group so the menu positions are the same under jq and yq.
    export MOCK_BODY='{"_links":{"curies":[{"name":"c1","href":"https://d/{rel}","templated":true},{"name":"c2","href":"https://d2/{rel}","templated":true}],"c1:item":{"href":"/i1"},"c2:item":{"href":"/i2"}},"title":"t"}'
    _type_key '1'   # links            → links menu: back(1) item (c1, c2)(2)
    _type_key '2'   # item (ambiguous) → disambiguation: back(1) c1:item(2) c2:item(3)
    _type_key '2'   # c1:item
    _type_key '1'   # follow (send request)
    _type_key '1'   # GET (HTTP method menu)
    _type_key '6'   # quit (followed resource has docs: links(1) props(2) docs(3) print(4) back(5) quit(6))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    local s; s=$(ls -d "${WORK_DIR}"/nahal_*/session.sh | head -1)
    grep -qF 'links c1:item' "$s"           # the real prefixed rel is followed/logged
    grep -qF '# follow links c1:item' "$s"
    ! grep -qF 'links item' "$s"            # never the bare local name
}

@test "links menu (without curies): single-match prefixed rel follows directly" {
    export MOCK_BODY='{"_links":{"curies":[{"name":"c1","href":"https://d/{rel}","templated":true}],"c1:only":{"href":"/o"}},"title":"t"}'
    _type_key '1'   # links   → back(1) only(2)
    _type_key '2'   # only    → single match, no disambiguation → action menu
    _type_key '1'   # follow
    _type_key '1'   # GET (HTTP method menu)
    _type_key '6'   # quit (followed resource has docs: links(1) props(2) docs(3) print(4) back(5) quit(6))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    local s; s=$(ls -d "${WORK_DIR}"/nahal_*/session.sh | head -1)
    grep -qF 'links c1:only' "$s"
    ! grep -qF 'links only' "$s"
}

@test "links menu: an invalid -c value errors with usage and exits 2" {
    run bash -c 'cd "$2" && bash "$1" -c bogus http://example.com/api' _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid -c value"* ]]
}

@test "links menu: an invalid NAHAL_CURIES value errors and exits 2" {
    run bash -c 'cd "$2" && NAHAL_CURIES=bogus bash "$1" http://example.com/api' _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid NAHAL_CURIES"* ]]
}

# ── session.sh replay generation ──────────────────────────────────────────────

# Drive a fixed session (GET root → follow self → quit) and echo the session dir.
# Keys: links(1) self(2) follow(1) GET(1) quit(5)
_run_self_follow_session() {
    _type_key '1'; _type_key '2'; _type_key '1'; _type_key '1'; _type_key '5'
    run bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    SESSION_DIR=$(ls -d "${WORK_DIR}"/nahal_* | head -1)
}

@test "session.sh: replay captures into _b[] and names files via hal_basename.sh -s" {
    _run_self_follow_session
    local s="${SESSION_DIR}/session.sh"
    [ -f "$s" ]
    grep -qF '_ensure_method()' "$s"            # custom-method helper in header
    grep -qF '_b=()' "$s"                        # response-base array initialised
    grep -qF '_b[1]=$(' "$s"                     # initial captured as _b[1]
    grep -qF 'HTTP_IN_HEADERS="Accept:' "$s"     # Accept set on the initial bare-URL GET
    # Accept is set once, only on the initial bare-URL GET; the --link follow
    # gets its Accept from the link via httpreq.sh, so no HTTP_IN_HEADERS there.
    [ "$(grep -c 'HTTP_IN_HEADERS=' "$s")" -eq 1 ]
    grep -qF '_prefix=step_' "$s"                # prefix set once in the header
    grep -qF '_s=$(hal_basename.sh -p "$_prefix")' "$s"  # base numbered per step
    grep -qF '# follow links self' "$s"          # step comment carries the full path
    grep -qF 'hallink.sh -s "$_s" "${_b[1]}.body" links self' "$s"  # follow reads _b[1]
    grep -qF 'GET -s "$_s" --link' "$s"          # method consumes the link under the base
    grep -qF '_b[2]=$(' "$s"                     # follow captured as _b[2]
    # Old forms must be gone: no rename, no grouping subshell, no dead _link=.
    ! grep -qF 'rename.sh' "$s"
    ! grep -q '^(HTTP_IN_HEADERS' "$s"
    ! grep -qF '_link=$(' "$s"
}

@test "session.sh: replay re-runs and recreates the predictable step files" {
    _run_self_follow_session
    run bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [ -f "${SESSION_DIR}/step_1.body" ]
    [ -f "${SESSION_DIR}/step_2.body" ]
}

# ── session.sh prefix override (-p / HAL_FILE_PREFIX) ─────────────────────────
# _run_self_follow_session bakes the prefix "step_" into the session.

@test "session.sh: -p overrides the baked prefix" {
    _run_self_follow_session
    run bash "${SESSION_DIR}/session.sh" -p over_
    [ "$status" -eq 0 ]
    [ -f "${SESSION_DIR}/over_1.body" ]
    [ -f "${SESSION_DIR}/over_2.body" ]
}

@test "session.sh: HAL_FILE_PREFIX overrides the baked prefix" {
    _run_self_follow_session
    run env HAL_FILE_PREFIX=envp_ bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [ -f "${SESSION_DIR}/envp_1.body" ]
    [ -f "${SESSION_DIR}/envp_2.body" ]
}

@test "session.sh: -p beats HAL_FILE_PREFIX" {
    _run_self_follow_session
    run env HAL_FILE_PREFIX=envp_ bash "${SESSION_DIR}/session.sh" -p cli_
    [ "$status" -eq 0 ]
    [ -f "${SESSION_DIR}/cli_1.body" ]
    [ ! -f "${SESSION_DIR}/envp_1.body" ]
}

@test "session.sh: no override keeps the baked prefix" {
    _run_self_follow_session
    run bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [ -f "${SESSION_DIR}/step_1.body" ]
}

@test "session.sh: an empty -p override yields an unprefixed base" {
    _run_self_follow_session
    run bash "${SESSION_DIR}/session.sh" -p ''
    [ "$status" -eq 0 ]
    [ -f "${SESSION_DIR}/1.body" ]
    [ -f "${SESSION_DIR}/2.body" ]
}

@test "session.sh: a set-but-empty HAL_FILE_PREFIX yields an unprefixed base" {
    _run_self_follow_session
    run env HAL_FILE_PREFIX='' bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [ -f "${SESSION_DIR}/1.body" ]
}

@test "session.sh: an unknown option errors with usage and exits 2" {
    _run_self_follow_session
    run bash "${SESSION_DIR}/session.sh" -x
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: session.sh [-p <prefix>]"* ]]
}

@test "session.sh: a stray positional errors with usage and exits 2" {
    _run_self_follow_session
    run bash "${SESSION_DIR}/session.sh" extra
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}

@test "session.sh: header contains the HALDiSh bootstrap" {
    _run_self_follow_session
    local s="${SESSION_DIR}/session.sh"
    grep -qF 'HALDiSh bootstrap' "$s"
    grep -qF 'command -v hallink.sh' "$s"
    grep -qF '.local/lib/haldish/env.sh' "$s"           # default install location
    grep -qF 'HALDiSh toolkit not found' "$s"           # install instructions
}

@test "session.sh: bootstrap prints install instructions and exits when HALDiSh is absent" {
    _run_self_follow_session
    # Replay with the toolkit off PATH, no HAL_LIB_DIR, and an empty HOME so the
    # default install location does not resolve either.
    run env -u HAL_LIB_DIR PATH="/usr/bin:/bin" HOME="${WORK_DIR}/nohome" \
        bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"HALDiSh toolkit not found"* ]]
    [[ "$output" == *".local/lib/haldish"* ]]
    [[ "$output" == *"releases"* ]]
}

# Passthrough HAL_LINK_PLUGIN: echoes the link JSON on stdin unchanged.  Returns
# its absolute path so it can be both invoked and string-matched in session.sh.
_make_pass_plugin() {
    local p="${WORK_DIR}/$1"
    printf '#!/usr/bin/env bash\ncat\n' > "$p"
    chmod +x "$p"
    printf '%s' "$p"
}

@test "session.sh: records the HAL_LINK_PLUGIN list and emits a replay check" {
    local pass; pass=$(_make_pass_plugin pass.sh)
    export HAL_LINK_PLUGIN="$pass"
    _run_self_follow_session
    local s="${SESSION_DIR}/session.sh"
    grep -qF '. hal_utils.sh' "$s"                 # library sourced for hal::log::*
    grep -qF '_check_plugins()' "$s"               # check function defined
    grep -qF "$pass" "$s"                          # creation-time list recorded
    grep -qE '^_check_plugins$' "$s"               # and invoked on replay
}

@test "session.sh replay: plugin diff logs OK / WARN / INFO" {
    local keep gone fresh
    keep=$(_make_pass_plugin keep.sh)
    gone=$(_make_pass_plugin gone.sh)
    fresh=$(_make_pass_plugin fresh.sh)
    export HAL_LINK_PLUGIN="${keep}:${gone}"       # list at session creation
    _run_self_follow_session
    # Replay with a different list: keep stays, gone drops, fresh appears.
    HAL_LINK_PLUGIN="${keep}:${fresh}" \
        run --separate-stderr bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plugin ${keep}"* ]]                  # OK   — in both
    [[ "$stderr" == *"${gone} missing at replay"* ]]       # WARN — dropped
    [[ "$stderr" == *"${fresh} new at replay"* ]]          # INFO — added
}

@test "session.sh replay: restores HAL_LINK_PLUGIN when unset and all plugins available" {
    local pass; pass=$(_make_pass_plugin pass.sh)
    export HAL_LINK_PLUGIN="$pass"                 # list at session creation
    _run_self_follow_session
    # Replay with HAL_LINK_PLUGIN entirely unset: it is restored, then the diff
    # sees the restored entry as present in both (OK), not new and not missing.
    run --separate-stderr env -u HAL_LINK_PLUGIN bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"restored HAL_LINK_PLUGIN from session"* ]]
    [[ "$stderr" == *"${pass}"* ]]
    [[ "$stderr" != *"new at replay"* ]]
    [[ "$stderr" != *"missing at replay"* ]]
}

@test "session.sh replay: does not restore HAL_LINK_PLUGIN when a recorded plugin is missing" {
    local gone; gone=$(_make_pass_plugin gone.sh)
    export HAL_LINK_PLUGIN="$gone"                 # list at session creation
    _run_self_follow_session
    rm -f "$gone"                                  # plugin no longer available
    run --separate-stderr env -u HAL_LINK_PLUGIN bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"not restoring HAL_LINK_PLUGIN"* ]]
    [[ "$stderr" == *"recorded plugin ${gone} is missing"* ]]
    [[ "$stderr" != *"restored HAL_LINK_PLUGIN from session"* ]]
}

@test "session.sh replay: does not restore when HAL_LINK_PLUGIN is set (even to empty)" {
    local pass; pass=$(_make_pass_plugin pass.sh)
    export HAL_LINK_PLUGIN="$pass"                 # list at session creation
    _run_self_follow_session
    # Explicitly set-but-empty at replay: the user's choice wins, no restore.
    HAL_LINK_PLUGIN="" run --separate-stderr bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"restored HAL_LINK_PLUGIN from session"* ]]
}

@test "live session: response files are renamed to predictable step names" {
    _run_self_follow_session
    [ -f "${SESSION_DIR}/step_1.body" ]
    [ -f "${SESSION_DIR}/step_2.body" ]
    # the auto-generated base name from the request is not left behind
    ! ls "${SESSION_DIR}"/resp.* >/dev/null 2>&1
}

@test "interactive: a templated follow records the binding values in session.sh" {
    # _brow_prompt reads its value from _BROW_TTY (the same FIFO as the menus).
    export _BROW_TTY="$TEST_TTY"
    export MOCK_BODY='{"_links":{"self":{"href":"/api/r"},"search":{"href":"/q{?term}","templated":true}},"title":"Mock"}'
    _type_key  '1'        # links
    _type_key  '2'        # search {T}   (links: back(1) search{T}(2) self(3))
    _type_key  '1'        # follow
    _type_key  '2'        # term         (template menu: Continue(1) term(2))
    _type_key  '1'        # Set single value
    _type_line 'hello'    # the value for term
    _type_key  '1'        # Continue
    _type_key  '1'        # GET
    _type_key  '5'        # quit (followed resource menu)
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p req http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    local s
    s=$(ls -d "${WORK_DIR}"/nahal_*/session.sh | head -1)
    grep -qF 'hallink.sh -s "$_s" "${_b[1]}.body" links search -- term=hello' "$s"  # binding after --
    grep -qF '# follow links search term=hello' "$s"   # path + binding in the comment
}

@test "interactive: follow a link, choose POST from the menu with no body" {
    _type_key '1'   # links
    _type_key '2'   # self     (links: back(1) self(2))
    _type_key '1'   # follow   (action: follow(1) details(2) back(3))
    _type_key '2'   # POST     (method: GET(1) POST(2) … HEAD(7) Other(8))
    _type_key '1'   # No body  (body: No body(1) …)
    _type_key '5'   # quit     (followed resource: links(1) properties(2) print(3) back(4) quit(5))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    # The follow request is dispatched and logged with the chosen method.
    [[ "$stderr" == *"POST"* ]]
}
