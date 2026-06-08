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
    "items": [{ "href": "/api/1", "name": "first" }, { "href": "/api/2", "name": "second", "templated": true }],
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
  "tags":  ["alpha", "beta"],
  "rows":  [{ "id": 1, "label": "Row A" }, { "id": 2, "label": "Row B" }]
}'

CURI_JSON='{
  "_links": {
    "self": { "href": "/api/r" },
    "curies": [
      { "name": "ex", "href": "https://example.com/docs/{rel}", "templated": true }
    ],
    "ex:items": { "href": "/api/items", "title": "Items" },
    "ex:widget": { "href": "/api/widgets/{id}", "templated": true, "title": "Widget" }
  },
  "title": "CURI Resource"
}'

MULTI_CURI_JSON='{
  "_links": {
    "self": { "href": "/api/r" },
    "curies": [
      { "name": "ex",    "href": "https://example.com/docs/{rel}",  "templated": true },
      { "name": "other", "href": "https://other.example.com/{rel}", "templated": true }
    ],
    "ex:items":    { "href": "/api/items" },
    "other:items": { "href": "/api/v2/items" }
  },
  "title": "Multi-CURI Resource"
}'

ARRAY_JSON='[
  { "_links": { "self": { "href": "/api/0" } }, "name": "Zero" },
  { "_links": { "self": { "href": "/api/1" } }, "name": "One" }
]'

WORK_DIR=""

setup() {
    WORK_DIR="$(mktemp -d)"
    printf '%s\n' "$HAL_JSON"        > "${WORK_DIR}/resource.json"
    printf '%s\n' "$ARRAY_JSON"      > "${WORK_DIR}/array.json"
    printf '%s\n' "$CURI_JSON"       > "${WORK_DIR}/curi.json"
    printf '%s\n' "$MULTI_CURI_JSON" > "${WORK_DIR}/multi_curi.json"

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

@test "hal.sh links items first href selects array link by name" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links items first href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/1" ]
}

@test "hal.sh links items second href selects second array link by name" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links items second href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/2" ]
}

@test "hal.sh links items second prints the named link JSON" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links items second
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/2"* ]]
    [[ "$output" == *"second"* ]]
}

@test "hal.sh links items <unknown-name> exits 1 with error" {
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json" links items nope href
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"no link named: nope"* ]]
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

@test "hal.sh embeddeds items name=<v> selects embedded by field (value with space)" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" embeddeds items "name=Item 2" links self href
    [ "$status" -eq 0 ]
    [ "$output" = "/api/2" ]
}

@test "hal.sh embeddeds items <unmatched-field> exits 1 with error" {
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json" embeddeds items name=nope links self href
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"no embedded where name=nope"* ]]
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

@test "hal.sh properties rows label=<v> selects object array element by field" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties rows "label=Row B" id
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "hal.sh properties rows id=2 selects element by a numeric field" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" properties rows id=2 label
    [ "$status" -eq 0 ]
    [ "$output" = "Row B" ]
}

@test "hal.sh properties rows <unmatched-field> exits 1 with error" {
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json" properties rows id=99 label
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"no element where id=99"* ]]
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
    # Properties menu keys sorted: count(1) meta(2) rows(3) tags(4) title(5) return(6) quit(7)
    _type_key '7'   # quit → prints jpath, exits
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

@test "interactive: link array picks element by name" {
    _type_key '1'   # links
    # Link rel menu (keys sorted): items(1) self(2) tmpl {T}(3) return(4)
    _type_key '1'   # items (array link)
    # Name picker: "0: first"(1) "1: second"(2) return(3) quit(4)
    _type_key '2'   # second
    # Link detail (fields sorted): href(1) name(2) templated(3) print(4) return(5) quit(6)
    _type_key '4'   # print
    _type_key '6'   # quit
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/2"* ]]
    [[ "$output" == *"second"* ]]
}

@test "interactive: embedded array selects by field then value" {
    _type_key '2'   # embeddeds
    # Embedded rel menu: items(1) return(2)
    _type_key '1'   # items (array)
    # Select-by menu: name(1) index(2) return(3) quit(4)
    _type_key '1'   # name
    # Value menu "name": "0: Item 1"(1) "1: Item 2"(2) return(3) quit(4)
    _type_key '2'   # Item 2
    # Embedded resource menu: links(1) properties(2) print(3) return(4) quit(5)
    _type_key '3'   # print
    _type_key '5'   # quit
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Item 2"* ]]
    [[ "$output" == *"/api/2"* ]]
}

@test "interactive: embedded array can fall back to index" {
    _type_key '2'   # embeddeds
    _type_key '1'   # items (array)
    # Select-by menu: name(1) index(2) return(3) quit(4)
    _type_key '2'   # index
    # Index menu: 0(1) 1(2) return(3) quit(4)
    _type_key '1'   # element 0
    # Embedded resource menu: links(1) properties(2) print(3) return(4) quit(5)
    _type_key '3'   # print
    _type_key '5'   # quit
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Item 1"* ]]
    [[ "$output" == *"/api/1"* ]]
}

@test "interactive: object property array selects by field" {
    _type_key '3'   # properties
    # Properties menu: count(1) meta(2) rows(3) tags(4) title(5) return(6) quit(7)
    _type_key '3'   # rows (array of objects)
    # Select-by menu: id(1) label(2) index(3) return(4) quit(5)
    _type_key '2'   # label
    # Value menu "label": "0: Row A"(1) "1: Row B"(2) return(3) quit(4)
    _type_key '1'   # Row A
    # Element object menu: id(1) label(2) print(3) return(4) quit(5)
    _type_key '3'   # print
    _type_key '5'   # quit
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Row A"* ]]
}

@test "interactive: scalar property array selects by index" {
    _type_key '3'   # properties
    # Properties menu: count(1) meta(2) rows(3) tags(4) title(5) return(6) quit(7)
    _type_key '4'   # tags (array of scalars → index only)
    # Index menu (no fields): 0(1) 1(2) return(3) quit(4)
    _type_key '2'   # "beta"
    # back in the array loop; quit
    _type_key '4'   # quit
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"beta"* ]]
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

@test "yq: links items second href selects array link by name" {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" links items second href
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

# ── non-interactive: docs ─────────────────────────────────────────────────────

@test "hal.sh docs presents interactive menu of CURI-prefixed rels" {
    # menu: ex:items(1) ex:widget(2) return(3) — select return
    _type_key '3'
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/curi.json" docs
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"ex:items"*  ]]
    [[ "$stderr" == *"ex:widget"* ]]
    [[ "$stderr" != *"self"*      ]]
    [[ "$stderr" != *"curies"*    ]]
}

@test "hal.sh docs expands CURI template for a given rel" {
    run bash "$HAL_SH" "${WORK_DIR}/curi.json" docs ex:items
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.com/docs/items" ]
}

@test "hal.sh docs expands CURI template for a second rel" {
    run bash "$HAL_SH" "${WORK_DIR}/curi.json" docs ex:widget
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.com/docs/widget" ]
}

@test "hal.sh docs exits 1 when no curies defined" {
    run bash "$HAL_SH" "${WORK_DIR}/resource.json" docs
    [ "$status" -eq 1 ]
}

@test "hal.sh docs exits 1 when CURI prefix not found" {
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/curi.json" docs unknown:rel
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"unknown"* ]]
}

@test "hal.sh docs resolves bare rel name to CURI-prefixed rel" {
    run bash "$HAL_SH" "${WORK_DIR}/curi.json" docs items
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.com/docs/items" ]
}

@test "hal.sh docs bare rel exits 1 when no matching CURI rel" {
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/curi.json" docs unknown
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"unknown"* ]]
}

@test "hal.sh docs warns when bare rel matches multiple CURI prefixes" {
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/multi_curi.json" docs items
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning"* ]]
    [[ "$stderr" == *"items"*   ]]
}

@test "hal.sh docs uses first match when bare rel matches multiple CURI prefixes" {
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/multi_curi.json" docs items
    [ "$status" -eq 0 ]
    # ex comes before other alphabetically — first match wins
    [ "$output" = "https://example.com/docs/items" ]
}

# ── interactive: docs option appears for CURI resources ──────────────────────

@test "interactive: docs option appears when resource has curies" {
    # Resource menu for curi.json: links, docs, properties, print, exit
    # links(1) docs(2) properties(3) print(4) exit(5)
    # Select 'exit' directly
    _type_key '5'
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/curi.json"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"docs"* ]]
}

@test "interactive: docs not in menu when no curies" {
    # Resource menu for resource.json: links, embeddeds, properties, print, exit (no docs)
    _type_key '5'   # exit
    run --separate-stderr bash "$HAL_SH" "${WORK_DIR}/resource.json"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"docs"* ]]
}
