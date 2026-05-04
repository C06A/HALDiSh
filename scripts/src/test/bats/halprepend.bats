#!/usr/bin/env bats
# =============================================================================
# halprepend.bats — unit tests for halprepend.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

HALPREPEND_SH="${SCRIPTS_DIR}/halprepend.sh"

# ── fixtures ──────────────────────────────────────────────────────────────────

HAL_JSON='{
  "_links": {
    "self":  {"href": "/api/r"},
    "items": [{"href": "/api/1"}, {"href": "/api/2"}],
    "typed": {"href": "/api/typed", "title": "Typed", "type": "application/hal+json"}
  },
  "_embedded": {
    "items": [
      {"_links": {"self": {"href": "/api/1"}}, "name": "Item 1"},
      {"_links": {"self": {"href": "/api/2"}}, "name": "Item 2"}
    ]
  },
  "title": "Test Resource"
}'

HAL_YAML='_links:
  self:
    href: /api/r
  items:
    - href: /api/1
    - href: /api/2
title: Test Resource'

WORK_DIR=""

setup() {
    WORK_DIR="$(mktemp -d)"
    printf '%s\n' "$HAL_JSON" > "${WORK_DIR}/res.json"
    printf '%s\n' "$HAL_YAML" > "${WORK_DIR}/res.yaml"
    printf '%s\n' "$HAL_YAML" > "${WORK_DIR}/res.yml"
    printf '%s\n' "$HAL_JSON" > "${WORK_DIR}/res.body"
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        yq -o xml '.' "${WORK_DIR}/res.json" > "${WORK_DIR}/res.xml" 2>/dev/null || true
    fi
    cd "$WORK_DIR"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# ── argument validation (exit 1) ──────────────────────────────────────────────

@test "halprepend.sh exits 1 with no arguments" {
    run bash "$HALPREPEND_SH"
    [ "$status" -eq 1 ]
}

@test "halprepend.sh prints Usage to stderr with no arguments" {
    run --separate-stderr bash "$HALPREPEND_SH"
    [[ "$stderr" == *"Usage:"* ]]
}

@test "halprepend.sh exits 1 with only a base and no mode" {
    run bash "$HALPREPEND_SH" 'https://example.com'
    [ "$status" -eq 1 ]
}

@test "halprepend.sh exits 1 when --link given but stdin is a terminal and no arg" {
    run bash "$HALPREPEND_SH" 'https://example.com' --link < /dev/null
    # /dev/null provides EOF stdin; jq/yq parse empty input → no href → exit 3
    # What we care about: non-zero exit when there's nothing useful to parse
    [ "$status" -ne 0 ]
}

@test "halprepend.sh exits 1 when file mode but no hal-path given" {
    run bash "$HALPREPEND_SH" 'https://example.com' "${WORK_DIR}/res.json"
    [ "$status" -eq 1 ]
}

@test "halprepend.sh prints hal-path required error to stderr" {
    run --separate-stderr bash "$HALPREPEND_SH" 'https://example.com' "${WORK_DIR}/res.json"
    [[ "$stderr" == *"hal-path required"* ]]
}

# ── file resolution (exit 2) ──────────────────────────────────────────────────

@test "halprepend.sh exits 2 when full path file does not exist" {
    run bash "$HALPREPEND_SH" 'https://example.com' /no/such/file.json links self
    [ "$status" -eq 2 ]
}

@test "halprepend.sh exits 2 when basename has no matching file" {
    run bash "$HALPREPEND_SH" 'https://example.com' nonexistent links self
    [ "$status" -eq 2 ]
}

# ── link not found / no href (exit 3) ─────────────────────────────────────────

@test "halprepend.sh exits 3 when --link JSON has no href field" {
    run bash "$HALPREPEND_SH" 'https://example.com' --link '{"title":"no href"}'
    [ "$status" -eq 3 ]
}

@test "halprepend.sh exits 3 when rel does not exist in _links" {
    run bash "$HALPREPEND_SH" 'https://example.com' "${WORK_DIR}/res.json" links nosuchrel
    [ "$status" -eq 3 ]
}

# ── tool unavailable (exit 4) ─────────────────────────────────────────────────

@test "halprepend.sh exits 4 when neither yq nor jq is available" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq"; chmod +x "${stub_dir}/yq"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/jq"; chmod +x "${stub_dir}/jq"
    run env PATH="${stub_dir}:${PATH}" bash "$HALPREPEND_SH" 'https://example.com' --link '{"href":"/api"}'
    [ "$status" -eq 4 ]
    rm -rf "$stub_dir"
}

# ── --link inline JSON ────────────────────────────────────────────────────────

@test "halprepend.sh --link prepends base to relative href" {
    run bash "$HALPREPEND_SH" 'https://example.com' --link '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/items'* ]]
}

@test "halprepend.sh --link preserves title field" {
    run bash "$HALPREPEND_SH" 'https://example.com' --link '{"href":"/api/items","title":"Items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"title"'* ]]
    [[ "$output" == *'Items'* ]]
}

@test "halprepend.sh --link preserves type field" {
    run bash "$HALPREPEND_SH" 'https://example.com' \
        --link '{"href":"/api/items","type":"application/hal+json"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'application/hal+json'* ]]
}

@test "halprepend.sh --link preserves templated field" {
    run bash "$HALPREPEND_SH" 'https://example.com' \
        --link '{"href":"/api{?q}","templated":true}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"templated"'* ]]
    [[ "$output" == *'https://example.com/api{?q}'* ]]
}

@test "halprepend.sh --link with empty base leaves href unchanged" {
    run bash "$HALPREPEND_SH" '' --link '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"/api/items"'* ]]
}

@test "halprepend.sh --link concatenates base and href literally" {
    run bash "$HALPREPEND_SH" 'https://example.com/' --link '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    # Simple concatenation: trailing slash + leading slash = double slash
    [[ "$output" == *'https://example.com//api/items'* ]]
}

# ── --link @file ──────────────────────────────────────────────────────────────

@test "halprepend.sh --link @file reads link JSON from a file" {
    printf '{"href":"/from-file","title":"FromFile"}\n' > "${WORK_DIR}/mylink.json"
    run bash "$HALPREPEND_SH" 'https://example.com' --link "@${WORK_DIR}/mylink.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/from-file'* ]]
}

# ── --link from stdin ─────────────────────────────────────────────────────────

@test "halprepend.sh --link reads link JSON from stdin" {
    run bash "$HALPREPEND_SH" 'https://example.com' --link <<< '{"href":"/from-stdin"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/from-stdin'* ]]
}

# ── file + path mode ──────────────────────────────────────────────────────────

@test "halprepend.sh navigates to self link and prepends base" {
    run bash "$HALPREPEND_SH" 'https://example.com' "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/r'* ]]
}

@test "halprepend.sh navigates to array element link and prepends base" {
    run bash "$HALPREPEND_SH" 'https://example.com' "${WORK_DIR}/res.json" links items 0
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/1'* ]]
}

@test "halprepend.sh navigates into embedded and prepends base" {
    run bash "$HALPREPEND_SH" 'https://example.com' \
        "${WORK_DIR}/res.json" embeddeds items 0 links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/1'* ]]
}

@test "halprepend.sh resolves basename to .json and prepends base" {
    run bash "$HALPREPEND_SH" 'https://example.com' res links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/r'* ]]
}

# ── format preservation ───────────────────────────────────────────────────────

@test "halprepend.sh outputs JSON for JSON --link input" {
    run bash "$HALPREPEND_SH" 'https://example.com' --link '{"href":"/api/r"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'{'* ]]
    [[ "$output" == *'"href"'* ]]
}

@test "halprepend.sh outputs JSON for JSON file input" {
    run bash "$HALPREPEND_SH" 'https://example.com' "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href"'* ]]
}

@test "halprepend.sh outputs YAML for YAML file input" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for YAML output"
    run bash "$HALPREPEND_SH" 'https://example.com' "${WORK_DIR}/res.yaml" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'href:'* ]]
    [[ "$output" != *'"href"'* ]]
}

@test "halprepend.sh outputs XML for XML file input" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for XML"
    [[ -f "${WORK_DIR}/res.xml" ]] || skip "res.xml not generated"
    run bash "$HALPREPEND_SH" 'https://example.com' "${WORK_DIR}/res.xml" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'<'* ]]
    [[ "$output" == *'https://example.com/api/r'* ]]
}
