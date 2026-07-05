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
        cmd="hallink.sh -s \"\${_b[3]}\" \"\${_b[2]}.body\" links self
./HEAD --link"
        _brow_log_step "Accept:x" "./HEAD" "$cmd" "follow"
        cat "$2"
    ' _ "$NAHAL_SH" "${WORK_DIR}/log"
    [[ "$output" == *"_ensure_method HEAD"* ]]
    [[ "$output" == *'HTTP_IN_HEADERS="Accept:x'* ]]
    [[ "$output" == *'./HEAD --link'* ]]                            # method carries no -s
    [[ "$output" == *'_b[3]=$(hal_basename.sh -p "$_prefix")'* ]]   # base numbered into _b[N]
    [[ "$output" == *'${_b[2]}.body'* ]]
    [[ "$output" == *'rename.sh "${_b[3]}"'* ]]                     # trailing rename onto _b[N]
    [[ "$output" != *"(HTTP_IN_HEADERS"* ]]
    # Layout: _b[N] numbered on its own line, then the pipeline one stage per line,
    # "\"-continued, the header prefixed onto the method, rename as the last stage.
    [[ "$output" == *$'_b[3]=$(hal_basename.sh -p "$_prefix")\n'* ]]
    [[ "$output" == *$'\nhallink.sh -s "${_b[3]}" "${_b[2]}.body" links self \\\n'* ]]
    [[ "$output" == *$'\n   ./HEAD --link \\\n'* ]]
    [[ "$output" == *$'\n | rename.sh "${_b[3]}"'* ]]   # rename is the final stage
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

# ── deprecation ───────────────────────────────────────────────────────────────

@test "_brow_open_deprecation: opens the link's deprecation URL" {
    export OPEN_LOG="${WORK_DIR}/opened"
    _src '_brow_open_deprecation "$1" self 0' '{"href":"/api/r","deprecation":"https://ex.com/why"}'
    [ "$status" -eq 0 ]
    run cat "${OPEN_LOG}"
    [ "$output" = "https://ex.com/why" ]
}

@test "_brow_open_deprecation: warns and opens nothing when the link is not deprecated" {
    export OPEN_LOG="${WORK_DIR}/opened"
    _src '_brow_open_deprecation "$1" self 0' '{"href":"/api/r"}'
    [ "$status" -eq 0 ]
    [ ! -e "${OPEN_LOG}" ]
}

@test "_brow_open_deprecation: runs the deprecation URL through HAL_LINK_PLUGIN" {
    # Same filter a followed href gets: a plugin that prepends "PLUGIN:" to .href.
    local plug="${WORK_DIR}/depplug.sh"
    cat > "$plug" <<'PLUG'
#!/usr/bin/env bash
sed 's#"href":"#"href":"PLUGIN:#'
PLUG
    chmod +x "$plug"
    export HAL_LINK_PLUGIN="$plug"
    export OPEN_LOG="${WORK_DIR}/opened"
    _src '_brow_open_deprecation "$1" self 0' '{"href":"/api/r","deprecation":"https://ex.com/why"}'
    [ "$status" -eq 0 ]
    run cat "${OPEN_LOG}"
    [ "$output" = "PLUGIN:https://ex.com/why" ]
}

# ── interactive session smoke tests ───────────────────────────────────────────

@test "interactive: GET a HAL resource then quit" {
    # Resource menu (top-level): links(1) properties(2) print resource(3) print resource (raw)(4) quit(5)
    _type_key '5'
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"example.com"* ]]
    # A session directory + replay log are created next to the run.
    [ -n "$(ls -d "${WORK_DIR}"/nahal_* 2>/dev/null)" ]
}

@test "interactive: print resource (raw) dumps the resource unformatted" {
    # Resource menu (top-level): links(1) properties(2) print resource(3) print resource (raw)(4) quit(5)
    _type_key '4'   # print resource (raw)
    _type_key '5'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    # Raw output is the resource as held — the unmodified single-line body, not reflowed.
    [[ "$output" == *'{ "_links": { "self": { "href": "/api/r" } }, "title": "Mock" }'* ]]
}

@test "interactive: navigate into links, show details, back, then quit" {
    _type_key '1'   # links
    _type_key '2'   # self           (links menu: back(1) self(2))
    _type_key '2'   # show details   (action: follow(1) details(2) back(3)) — loops
    _type_key '3'   # back           → back to links list
    _type_key '1'   # back           → back to resource
    _type_key '5'   # quit           (resource: links(1) properties(2) print(3) raw(4) quit(5))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"/api/r"* ]]
}

@test "interactive: GET an array of HAL resources, enter one element, then quit" {
    export MOCK_BODY='[{"_links":{"self":{"href":"/api/a"}},"n":1},{"_links":{"self":{"href":"/api/b"}},"n":2}]'
    _type_key '1'   # element 1   (array menu: 1:/api/a(1) 2:/api/b(2) print(3) raw(4) quit(5))
    _type_key '6'   # quit        (element resource: links(1) properties(2) print(3) raw(4) back(5) quit(6))
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
    _type_key '1'   # links               (root: links(1) print(2) raw(3) quit(4))
    _type_key '3'   # toB                 (links: back(1) self(2) toB(3) toX(4))
    _type_key '1'   # follow              (action: follow(1) details(2) back(3))
    _type_key '1'   # GET                 (method: GET(1) …)
    _type_key '4'   # back                (B resource: links(1) print(2) raw(3) back(4) quit(5))
    _type_key '4'   # toX                 (root links again: back(1) self(2) toB(3) toX(4))
    _type_key '1'   # follow
    _type_key '1'   # GET
    _type_key '5'   # quit                (followed resource: links(1) print(2) raw(3) back(4) quit(5))
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
    _type_key '1'   # links                 (top: links(1) properties(2) print(3) raw(4) quit(5))
    _type_key '2'   # items                 (links: back(1) items(2))
    _type_key '3'   # element 1 → /b        (choose link: back(1) 0:/a(2) 1:/b(3))
    _type_key '1'   # follow (send request) (action: follow(1) details(2) back(3))
    _type_key '1'   # GET                   (HTTP method menu: GET(1) …)
    _type_key '6'   # quit                  (followed resource: links(1) properties(2) print(3) raw(4) back(5) quit(6))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"Choose link"* ]]      # the array element picker appeared
    local s; s=$(ls -d "${WORK_DIR}"/nahal_*/session.sh | head -1)
    grep -qF 'hallink.sh -s "${_b[2]}" "${_b[1]}.body" links items 1' "$s"   # indexed hal-path
    grep -qF '# follow links items 1' "$s"                     # comment carries the index
    ! grep -qF 'links items 0' "$s"                            # the other element not followed
}

@test "interactive: docs option appears for a CURIE resource and opens the doc URL" {
    # Single curie rel so the docs-menu selection is deterministic regardless of
    # whether jq (sorted) or yq (document order) lists the keys.
    export MOCK_BODY='{"_links":{"self":{"href":"/api/r"},"curies":[{"name":"ex","href":"https://ex.com/docs/{rel}","templated":true}],"ex:widget":{"href":"/w"}},"title":"t"}'
    export OPEN_LOG="${WORK_DIR}/opened"
    # Resource menu: links(1) properties(2) docs(3) print(4) raw(5) quit(6)
    _type_key '3'   # docs
    _type_key '2'   # ex:widget   (docs menu: back(1) ex:widget(2))
    _type_key '1'   # back
    _type_key '6'   # quit
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
    _type_key '6'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    run cat "${OPEN_LOG}"
    [ "$output" = "PLUGIN:https://ex.com/docs/widget" ]
}

@test "interactive: docs option is absent when no rel uses a curie prefix" {
    export MOCK_BODY='{"_links":{"self":{"href":"/api/r"},"curies":[{"name":"ex","href":"https://ex.com/docs/{rel}"}]},"title":"t"}'
    _type_key '3'   # links(1) properties(2) print(3) raw(4) quit(5) — no docs; 3 = print
    _type_key '5'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"docs"* ]]
}

@test "interactive: a deprecated link offers 'open deprecation docs' and opens the URL" {
    # Single non-self link so the links-menu position is deterministic across
    # jq (sorted) and yq (document order).
    export MOCK_BODY='{"_links":{"old":{"href":"/old","deprecation":"https://ex.com/dep"}},"title":"t"}'
    export OPEN_LOG="${WORK_DIR}/opened"
    # Resource menu: links(1) properties(2) print(3) raw(4) quit(5)
    _type_key '1'   # links
    _type_key '2'   # old   (links menu: back(1) old(2))
    _type_key '3'   # open deprecation docs (action: follow(1) details(2) open deprecation docs(3) back(4))
    _type_key '4'   # back  (action) → links list
    _type_key '1'   # back  (links) → resource
    _type_key '5'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"deprecated: https://ex.com/dep"* ]]
    run cat "${OPEN_LOG}"
    [ "$output" = "https://ex.com/dep" ]
}

@test "interactive: a non-deprecated link does not offer 'open deprecation docs'" {
    # Default MOCK_BODY's self link carries no deprecation; the action menu is
    # follow(1) details(2) back(3) — selecting 3 returns to the links list.
    _type_key '1'   # links
    _type_key '2'   # self  (links menu: back(1) self(2))
    _type_key '3'   # back  (action: follow(1) details(2) back(3)) → links list
    _type_key '1'   # back  (links) → resource
    _type_key '5'   # quit
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"deprecation docs"* ]]
}

# ── links menu: curies display mode (-c / NAHAL_CURIES) ───────────────────────

# Resource with two curie prefixes (c1, c2): order is defined under both, report
# only under c1.  Resource menu: links(1) properties(2) docs(3) print(4) raw(5) quit(6).
CURIE_LINKS_BODY='{"_links":{"self":{"href":"/api/r"},"curies":[{"name":"c1","href":"https://d/{rel}","templated":true},{"name":"c2","href":"https://d2/{rel}","templated":true}],"c1:order":{"href":"/o1"},"c2:order":{"href":"/o2"},"c1:report":{"href":"/rp"}},"title":"t"}'

@test "links menu (default/without curies): shows local names, groups duplicates, hides curies" {
    export MOCK_BODY="$CURIE_LINKS_BODY"
    _type_key '1'   # links
    _type_key '1'   # back
    _type_key '6'   # quit
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
    _type_key '6'   # quit
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
    _type_key '1'; _type_key '1'; _type_key '6'
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
    _type_key '7'   # quit (followed resource has docs: links(1) props(2) docs(3) print(4) raw(5) back(6) quit(7))
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
    _type_key '7'   # quit (followed resource has docs: links(1) props(2) docs(3) print(4) raw(5) back(6) quit(7))
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
# Keys: links(1) self(2) follow(1) GET(1) quit(6)
# (followed resource menu: links(1) properties(2) print(3) raw(4) back(5) quit(6))
_run_self_follow_session() {
    _type_key '1'; _type_key '2'; _type_key '1'; _type_key '1'; _type_key '6'
    run bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    SESSION_DIR=$(ls -d "${WORK_DIR}"/nahal_* | head -1)
}

@test "session.sh: replay numbers _b[] via hal_basename.sh and names files via rename.sh" {
    _run_self_follow_session
    local s="${SESSION_DIR}/session.sh"
    local p="${SESSION_DIR}/session_prelude.sh"
    [ -f "$s" ]
    [ -f "$p" ]                                  # companion prelude written
    grep -qF 'source "$(dirname "$0")/session_prelude.sh"' "$s"  # and sourced
    grep -qF '_ensure_method()' "$p"            # custom-method helper in the prelude
    grep -qF '_b=()' "$p"                        # response-base array initialised
    grep -qF '_b[1]=$(' "$s"                     # initial captured as _b[1]
    grep -qF 'HTTP_IN_HEADERS="Accept:' "$s"     # Accept set on the initial bare-URL GET
    # Accept is set once, only on the initial bare-URL GET; the --link follow
    # gets its Accept from the link via httpreq.sh, so no HTTP_IN_HEADERS there.
    [ "$(grep -c 'HTTP_IN_HEADERS=' "$s")" -eq 1 ]
    grep -qF '_prefix=step_' "$s"                # prefix set once in the header
    grep -qF '_b[2]=$(hal_basename.sh -p "$_prefix")' "$s"  # base numbered into _b[N] per step
    grep -qF '# follow links self' "$s"          # step comment carries the full path
    grep -qF 'hallink.sh -s "${_b[2]}" "${_b[1]}.body" links self' "$s"  # follow reads _b[1], writes _b[2]
    grep -qF 'GET --link' "$s"                    # method consumes the link (no -s — rename names it)
    grep -qF 'rename.sh "${_b[2]}"' "$s"          # trailing rename moves the group onto _b[2]
    grep -qF 'rename.sh "${_b[1]}"' "$s"          # the initial GET is renamed onto _b[1] too
    # The method no longer carries -s; rename supplies the predictable name.
    ! grep -qF 'GET -s "$_s"' "$s"
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

@test "session_prelude.sh contains the HALDiSh bootstrap" {
    _run_self_follow_session
    local p="${SESSION_DIR}/session_prelude.sh"
    grep -qF 'HALDiSh bootstrap' "$p"
    grep -qF 'command -v hallink.sh' "$p"
    grep -qF '.local/lib/haldish/env.sh' "$p"           # default install location
    grep -qF 'HALDiSh toolkit not found' "$p"           # install instructions
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
    local p="${SESSION_DIR}/session_prelude.sh"
    grep -qF '. hal_utils.sh' "$p"                 # library sourced for hal::log::*
    grep -qF '_check_plugins()' "$p"               # check function defined
    grep -qF "$pass" "$s"                          # creation-time list recorded
    grep -qE '^_check_plugins$' "$p"               # and invoked on replay
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

# ── plugin environment: -config recording, restore, and diff at replay ────────

# A pass-through plugin that also implements the `-config` contract: `-config`
# prints an `export NAHAL_TEST_ENV=<current value>` snippet (mirroring
# halprepend.sh), while the normal link path records the value of NAHAL_TEST_ENV
# in effect to marker.out (so a test can observe what the replay had set) and
# passes the link JSON through unchanged.
_make_config_plugin() {
    local p="${WORK_DIR}/$1"
    cat > "$p" <<PLUGIN
#!/usr/bin/env bash
if [ "\${1:-}" = -config ]; then
    [ -n "\${NAHAL_TEST_ENV:-}" ] && printf 'export NAHAL_TEST_ENV=%q\n' "\$NAHAL_TEST_ENV"
    exit 0
fi
printf '%s\n' "\${NAHAL_TEST_ENV-<unset>}" >> "${WORK_DIR}/marker.out"
cat
PLUGIN
    chmod +x "$p"
    printf '%s' "$p"
}

@test "session.sh: records each plugin's -config env and emits _check_plugin_env" {
    local cfg; cfg=$(_make_config_plugin cfg.sh)
    export HAL_LINK_PLUGIN="$cfg"
    export NAHAL_TEST_ENV='orig-value'
    _run_self_follow_session
    local s="${SESSION_DIR}/session.sh"
    local p="${SESSION_DIR}/session_prelude.sh"
    grep -qF '_plugin_cfg_names=('  "$s"           # ordered plugin-name array (recorded)
    grep -qF '_plugin_cfg_0='       "$s"           # per-plugin recorded snippet
    grep -qF 'NAHAL_TEST_ENV=orig-value' "$s"      # the recorded env value
    grep -qF '_hal_plugins_set_at_entry' "$p"      # entry-time list flag captured in prelude
    grep -qF '_check_plugin_env()'  "$p"           # env check defined in prelude
    grep -qE '^_check_plugin_env$'  "$p"           # and invoked on replay
}

@test "session.sh replay: restores plugin env when HAL_LINK_PLUGIN is unset" {
    local cfg; cfg=$(_make_config_plugin cfg.sh)
    export HAL_LINK_PLUGIN="$cfg"
    export NAHAL_TEST_ENV='restored-me'
    _run_self_follow_session
    rm -f "${WORK_DIR}/marker.out"                 # drop the creation-time record
    # Replay with both the list and the plugin's env entirely unset: the session
    # owns the environment, so the recorded snippet is eval'd back into place.
    run --separate-stderr env -u HAL_LINK_PLUGIN -u NAHAL_TEST_ENV \
        bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"restored env for plugin ${cfg}"* ]]
    # The self-follow step ran the plugin after the restore → it saw the value.
    [[ "$(cat "${WORK_DIR}/marker.out")" == *'restored-me'* ]]
}

@test "session.sh replay: env matches logs OK when the list is set and value agrees" {
    local cfg; cfg=$(_make_config_plugin cfg.sh)
    export HAL_LINK_PLUGIN="$cfg"
    export NAHAL_TEST_ENV='same-value'
    _run_self_follow_session
    run --separate-stderr env HAL_LINK_PLUGIN="$cfg" NAHAL_TEST_ENV='same-value' \
        bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plugin ${cfg} env matches"* ]]
}

@test "session.sh replay: env differs logs WARN and does not overwrite the caller's value" {
    local cfg; cfg=$(_make_config_plugin cfg.sh)
    export HAL_LINK_PLUGIN="$cfg"
    export NAHAL_TEST_ENV='recorded-value'
    _run_self_follow_session
    rm -f "${WORK_DIR}/marker.out"
    # Replay with the list set but a different env value: compare-only, no restore.
    run --separate-stderr env HAL_LINK_PLUGIN="$cfg" NAHAL_TEST_ENV='caller-value' \
        bash "${SESSION_DIR}/session.sh"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"plugin ${cfg} env differs from recorded"* ]]
    # The caller's value was left untouched (not overwritten by the recorded one).
    [[ "$(cat "${WORK_DIR}/marker.out")" == *'caller-value'* ]]
    [[ "$(cat "${WORK_DIR}/marker.out")" != *'recorded-value'* ]]
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
    _type_key  '6'        # quit (followed resource: links(1) properties(2) print(3) raw(4) back(5) quit(6))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p req http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    local s
    s=$(ls -d "${WORK_DIR}"/nahal_*/session.sh | head -1)
    grep -qF 'hallink.sh -s "${_b[2]}" "${_b[1]}.body" links search -- term=hello' "$s"  # binding after --
    grep -qF '# follow links search term=hello' "$s"   # path + binding in the comment
}

@test "interactive: follow a link, choose POST from the menu with no body" {
    _type_key '1'   # links
    _type_key '2'   # self     (links: back(1) self(2))
    _type_key '1'   # follow   (action: follow(1) details(2) back(3))
    _type_key '2'   # POST     (method: GET(1) POST(2) … HEAD(7) Other(8))
    _type_key '1'   # No body  (body: No body(1) …)
    _type_key '6'   # quit     (followed resource: links(1) properties(2) print(3) raw(4) back(5) quit(6))
    run --separate-stderr bash -c 'cd "$2" && bash "$1" -p step_ http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    # The follow request is dispatched and logged with the chosen method.
    [[ "$stderr" == *"POST"* ]]
}
