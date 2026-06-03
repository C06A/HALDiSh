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
base="resp"
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/hal+json\r\n\r\n' > "${base}.headers"
printf '200' > "${base}.status"
printf '%s' '{ "_links": { "self": { "href": "/api/r" } }, "title": "Mock" }' > "${base}.body"
printf 'curl -X GET\n' > "${base}.curl"
printf '%s' "$base"
MOCK
    chmod +x "${STUB_DIR}/GET"
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

_type_key() { printf '%s' "$@" >&9; }

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

# ── interactive session smoke tests ───────────────────────────────────────────

@test "interactive: GET a HAL resource then quit" {
    # Resource menu (top-level): links(1) properties(2) print resource(3) quit(4)
    _type_key '4'
    run --separate-stderr bash -c 'cd "$2" && bash "$1" http://example.com/api' \
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
    run --separate-stderr bash -c 'cd "$2" && bash "$1" http://example.com/api' \
        _ "$NAHAL_SH" "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"/api/r"* ]]
}
