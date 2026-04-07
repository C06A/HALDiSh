#!/usr/bin/env bats
# =============================================================================
# hal.bats — unit tests for hal.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

HAL_SH="${SCRIPTS_DIR}/hal.sh"

# ── fixture ───────────────────────────────────────────────────────────────────

HAL_JSON='{
  "_links": {
    "self":  { "href": "/api/r" },
    "items": [{ "href": "/api/1" }, { "href": "/api/2", "templated": true }],
    "tmpl":  { "href": "/api{?q}", "templated": true }
  },
  "_embedded": {
    "items": [
      { "_links": { "self": { "href": "/api/1" } }, "name": "Item 1" },
      { "_links": { "self": { "href": "/api/2" } }, "name": "Item 2" }
    ]
  },
  "title": "Test Resource",
  "count": 42,
  "meta":  { "created": "2025-01-01", "active": true },
  "tags":  ["alpha", "beta"]
}'

ARRAY_JSON='[
  { "_links": { "self": { "href": "/api/0" } }, "name": "Zero" },
  { "_links": { "self": { "href": "/api/1" } }, "name": "One" }
]'

WORK_DIR=""

setup() {
    WORK_DIR="$(mktemp -d)"
    printf '%s\n' "$HAL_JSON"   > "${WORK_DIR}/resource.json"
    printf '%s\n' "$ARRAY_JSON" > "${WORK_DIR}/array.json"

    # Use a FIFO for _MENU_TTY so sequential reads work across multiple menu.sh
    # subprocess invocations.  fd 9 keeps the write end open so subprocesses
    # can open the read end without blocking.
    TEST_TTY="${WORK_DIR}/menu_tty"
    mkfifo "$TEST_TTY"
    exec 9<>"$TEST_TTY"
    export _MENU_TTY="$TEST_TTY"
}

teardown() {
    exec 9>&- 2>/dev/null || true
    rm -rf "$WORK_DIR"
}

# Write simulated keystrokes / lines for interactive tests.
# menu.sh uses read -n1 (no newline); _read_index uses read -r (newline-terminated).
_type_key()  { printf '%s'   "$@" >&9; }
_type_line() { printf '%s\n' "$@" >&9; }

# ── argument validation ───────────────────────────────────────────────────────

@test "hal.sh exits 1 with no arguments" {
    run bash "$HAL_SH"
    [ "$status" -eq 1 ]
}

@test "hal.sh prints usage to stderr with no arguments" {
    run --separate-stderr bash "$HAL_SH"
    [[ "$stderr" == *"Usage:"* ]]
}

@test "hal.sh exits 1 when file does not exist" {
    run bash "$HAL_SH" /no/such/file.json links
    [ "$status" -eq 1 ]
}

@test "hal.sh prints error to stderr when file does not exist" {
    run --separate-stderr bash "$HAL_SH" /no/such/file.json links
    [[ "$stderr" == *"no such file"* ]]
}

# ── tool selection ────────────────────────────────────────────────────────────

@test "hal.sh fails when neither yq nor jq is available" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    # stubs that always exit 1 so both functional checks fail
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq"; chmod +x "${stub_dir}/yq"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/jq"; chmod +x "${stub_dir}/jq"
    run env PATH="${stub_dir}:${PATH}" bash "$HAL_SH" "${WORK_DIR}/resource.json" links
    [ "$status" -eq 1 ]
    rm -rf "$stub_dir"
}

@test "hal.sh falls back to jq for JSON file when yq absent" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    # broken yq stub (found but fails), real jq → should fall back to jq
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq"; chmod +x "${stub_dir}/yq"
    run env PATH="${stub_dir}:${PATH}" bash "$HAL_SH" "${WORK_DIR}/resource.json" links
    [ "$status" -eq 0 ]
    [[ "$output" == *"self"* ]]
    rm -rf "$stub_dir"
}

@test "hal.sh rejects YAML file when only jq is available" {
    local stub_dir yaml_file
    stub_dir="$(mktemp -d)"
    yaml_file="${WORK_DIR}/resource.yaml"
    printf '_links:\n  self:\n    href: /api/r\ntitle: Test\n' > "$yaml_file"
    # broken yq stub → jq is real but cannot parse YAML → should exit 1
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq"; chmod +x "${stub_dir}/yq"
    run --separate-stderr env PATH="${stub_dir}:${PATH}" bash "$HAL_SH" "$yaml_file" properties
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"yaml"* ]]
    rm -rf "$stub_dir"
}

# ── non-interactive: links ────────────────────────────────────────────────────

@test "hal.sh links lists all link rels" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links
    [ "$status" -eq 0 ]
    [[ "$output" == *"self"*  ]]
    [[ "$output" == *"items"* ]]
    [[ "$output" == *"tmpl"*  ]]
}

@test "hal.sh links self prints self link JSON" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"href"*  ]]
    [[ "$output" == *"/api/r"* ]]
}

@test "hal.sh links self href prints href value" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links self href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/r" ]
}

@test "hal.sh links items 0 href prints first array link href" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links items 0 href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/1" ]
}

@test "hal.sh links items 1 href prints second array link href" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links items 1 href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/2" ]
}

# ── non-interactive: embeddeds ────────────────────────────────────────────────

@test "hal.sh embeddeds lists all embedded rels" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" embeddeds
    [ "$status" -eq 0 ]
    [[ "$output" == *"items"* ]]
}

@test "hal.sh embeddeds items 0 links self href navigates into embedded" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" embeddeds items 0 links self href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/1" ]
}

@test "hal.sh embeddeds items 1 links self href navigates into second embedded" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" embeddeds items 1 links self href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/2" ]
}

# ── non-interactive: properties ───────────────────────────────────────────────

@test "hal.sh properties lists all property keys excluding _links and _embedded" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties
    [ "$status" -eq 0 ]
    [[ "$output" == *"title"* ]]
    [[ "$output" == *"count"* ]]
    [[ "$output" == *"meta"*  ]]
    [[ "$output" == *"tags"*  ]]
    [[ "$output" != *"_links"*    ]]
    [[ "$output" != *"_embedded"* ]]
}

@test "hal.sh properties title prints string value" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties title
    [ "$status" -eq 0 ]
    [ "$output" = "Test Resource" ]
}

@test "hal.sh properties count prints number value" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties count
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "hal.sh properties meta created navigates nested dict property" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties meta created
    [ "$status" -eq 0 ]
    [ "$output" = "2025-01-01" ]
}

@test "hal.sh properties tags 0 navigates array property by index" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties tags 0
    [ "$status" -eq 0 ]
    [ "$output" = "alpha" ]
}

@test "hal.sh properties tags 1 navigates second array element" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties tags 1
    [ "$status" -eq 0 ]
    [ "$output" = "beta" ]
}

# ── non-interactive: top-level array ─────────────────────────────────────────

@test "hal.sh top-level array index 0 then properties name" {
    run bash "$HAL_SH" "${WORK_DIR}/array.json" 0 properties name
    [ "$status" -eq 0 ]
    [ "$output" = "Zero" ]
}

@test "hal.sh top-level array index 1 then links self href" {
    run bash "$HAL_SH" "${WORK_DIR}/array.json" 1 links self href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/1" ]
}

# ── interactive smoke tests ───────────────────────────────────────────────────

@test "interactive: print resource then exit outputs JSON" {
    # menu choices: 'print' then 'exit'
    # Resource menu has: links, embeddeds, properties, print, exit
    # With 5 options: 1=links 2=embeddeds 3=properties 4=print 5=exit
    # We want 'print' first, then 'exit'
    _type_key '4'   # print
    _type_key '5'   # exit
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"_links"* ]]
    [[ "$output" == *"title"*  ]]
}

@test "interactive: navigate links then self then quit outputs jpath" {
    # Resource menu (5 opts: 1=links 2=embeddeds 3=properties 4=print 5=exit)
    _type_key '1'
    # Links list menu: yq sorts rels alphabetically: items(1) self(2) tmpl{T}(3) return(4)
    _type_key '2'   # self
    # Link detail menu for self {href}: 1=href 2=print 3=return 4=quit
    _type_key '4'   # quit → prints path, exits
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"links"* ]]
    [[ "$output" == *"self"*  ]]
}

@test "interactive: navigate to properties then quit outputs jpath" {
    # Resource menu (5 opts: 1=links 2=embeddeds 3=properties 4=print 5=exit)
    _type_key '3'   # properties
    # Properties menu: yq sorts keys alphabetically: count(1) meta(2) tags(3) title(4) return(5) quit(6)
    _type_key '6'   # quit → prints jpath, exits
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    # "properties" navigates to the root object; jpath is "."
    [ "$output" = "." ]
}

@test "interactive: top-level array prompts for index" {
    # index prompt: pick 0, then resource menu → print (4 opts: links properties print exit) = '3'
    _type_line '0'
    _type_key  '3'   # print
    _type_key  '4'   # exit
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/array.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Zero"* ]]
}

# ── yq-specific: key-by-variable lookup (env(HAL_K)) ─────────────────────────
# These tests skip when yq is absent. When yq is installed hal.sh uses it and
# _qk/_qkr must pass HAL_K on the yq side of the pipe, not the printf side.

HAL_YAML='_links:
  self:
    href: /api/r
  items:
    - href: /api/1
    - href: /api/2
      templated: true
  tmpl:
    href: "/api{?q}"
    templated: true
_embedded:
  items:
    - _links:
        self:
          href: /api/1
      name: Item 1
    - _links:
        self:
          href: /api/2
      name: Item 2
title: Test Resource
count: 42
meta:
  created: "2025-01-01"
  active: true
tags:
  - alpha
  - beta'

@test "yq: links self href returns scalar value" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links self href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/r" ]
}

@test "yq: links items 0 href returns first array link href" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links items 0 href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/1" ]
}

@test "yq: links items 1 href returns second array link href" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links items 1 href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/2" ]
}

@test "yq: embeddeds items 0 links self href navigates embedded" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" embeddeds items 0 links self href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/1" ]
}

@test "yq: properties title returns string value" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties title
    [ "$status" -eq 0 ]
    [ "$output" = "Test Resource" ]
}

@test "yq: parses YAML file and returns link href" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    printf '%s\n' "$HAL_YAML" > "${WORK_DIR}/resource.yaml"
    run bash "$HAL_SH" "${WORK_DIR}/resource.yaml" links self href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/r" ]
}

@test "yq: YAML file links items 0 href returns first array link href" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    printf '%s\n' "$HAL_YAML" > "${WORK_DIR}/resource.yaml"
    run bash "$HAL_SH" "${WORK_DIR}/resource.yaml" links items 0 href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/1" ]
}

@test "yq: YAML file properties title returns string value" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    printf '%s\n' "$HAL_YAML" > "${WORK_DIR}/resource.yaml"
    run bash "$HAL_SH" "${WORK_DIR}/resource.yaml" properties title
    [ "$status" -eq 0 ]
    [ "$output" = "Test Resource" ]
}
