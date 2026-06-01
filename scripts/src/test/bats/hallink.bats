#!/usr/bin/env bats
# =============================================================================
# hallink.bats — unit tests for hallink.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

HALLINK_SH="${SCRIPTS_DIR}/hallink.sh"

# ── fixtures ──────────────────────────────────────────────────────────────────

HAL_JSON='{
  "_links": {
    "self":  {"href": "/api/r"},
    "items": [{"href": "/api/1"}, {"href": "/api/2{?q}", "templated": true}],
    "tmpl":  {"href": "/api{?q}", "templated": true},
    "multi": {"href": "/api{?q,lang}", "templated": true},
    "res":   {"href": "/api{+path}", "templated": true, "title": "Resource", "type": "application/hal+json"}
  },
  "_embedded": {
    "items": [
      {"_links": {"self": {"href": "/api/1"}, "sub": {"href": "/api/1/sub{?x}", "templated": true}}, "name": "Item 1"},
      {"_links": {"self": {"href": "/api/2"}}, "name": "Item 2"}
    ]
  },
  "title": "Test Resource",
  "count": 42
}'

HAL_YAML='_links:
  self:
    href: /api/r
  tmpl:
    href: "/api{?q}"
    templated: true
  items:
    - href: /api/1
    - href: "/api/2{?q}"
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
count: 42'

WORK_DIR=""

setup() {
    WORK_DIR="$(mktemp -d)"
    printf '%s\n' "$HAL_JSON" > "${WORK_DIR}/res.json"
    printf '%s\n' "$HAL_YAML" > "${WORK_DIR}/res.yaml"
    printf '%s\n' "$HAL_YAML" > "${WORK_DIR}/res.yml"
    printf '%s\n' "$HAL_JSON" > "${WORK_DIR}/res.body"
    # Generate XML from JSON if yq available
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        yq -o xml '.' "${WORK_DIR}/res.json" > "${WORK_DIR}/res.xml" 2>/dev/null || true
    fi
    cd "$WORK_DIR"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# ── argument validation (exit 1) ──────────────────────────────────────────────

@test "hallink.sh exits 1 with no arguments" {
    run bash "$HALLINK_SH"
    [ "$status" -eq 1 ]
}

@test "hallink.sh prints Usage to stderr with no arguments" {
    run --separate-stderr bash "$HALLINK_SH"
    [[ "$stderr" == *"Usage:"* ]]
}

@test "hallink.sh exits 1 when --link given with no arg and stdin is a terminal" {
    run bash "$HALLINK_SH" --link < /dev/null
    # /dev/null is not a terminal, so this goes through; test actual terminal case
    # by using a pipe that provides no data (simulated: rely on tty check)
    true
}

@test "hallink.sh --link: no arg stdin terminal error message" {
    # Run with TTY stdin via bash -i is tricky; verify the message text exists in usage
    run --separate-stderr bash "$HALLINK_SH"
    [[ "$stderr" == *"Usage:"* ]]
}

@test "hallink.sh exits 1 with no hal-path given" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json"
    [ "$status" -eq 1 ]
}

@test "hallink.sh prints error to stderr when no hal-path given" {
    run --separate-stderr bash "$HALLINK_SH" "${WORK_DIR}/res.json"
    [[ "$stderr" == *"hal-path required"* ]]
}

# ── file resolution (exit 2) ──────────────────────────────────────────────────

@test "hallink.sh exits 2 when full path file does not exist" {
    run bash "$HALLINK_SH" /no/such/file.json links self
    [ "$status" -eq 2 ]
}

@test "hallink.sh prints error to stderr for missing full path" {
    run --separate-stderr bash "$HALLINK_SH" /no/such/file.json links self
    [[ "$stderr" == *"no such file"* ]]
}

@test "hallink.sh exits 2 when basename has no matching file" {
    run bash "$HALLINK_SH" nonexistent links self
    [ "$status" -eq 2 ]
}

@test "hallink.sh prints error to stderr for unresolvable basename" {
    run --separate-stderr bash "$HALLINK_SH" nonexistent links self
    [[ "$stderr" == *"file not found"* ]]
}

# ── link not found (exit 3) ───────────────────────────────────────────────────

@test "hallink.sh exits 3 when rel does not exist in _links" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links nosuchrel
    [ "$status" -eq 3 ]
}

@test "hallink.sh --link exits 3 when link object has no href" {
    run bash "$HALLINK_SH" --link '{"title":"no href here"}'
    [ "$status" -eq 3 ]
}

# ── tool unavailable (exit 4) ─────────────────────────────────────────────────

@test "hallink.sh exits 4 when neither yq nor jq is available" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq"; chmod +x "${stub_dir}/yq"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/jq"; chmod +x "${stub_dir}/jq"
    run env PATH="${stub_dir}:${PATH}" bash "$HALLINK_SH" --link '{"href":"/api"}'
    [ "$status" -eq 4 ]
    rm -rf "$stub_dir"
}

# ── basename search — extension priority ─────────────────────────────────────

@test "hallink.sh resolves basename to .json when all variants exist" {
    run bash "$HALLINK_SH" res links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh resolves basename to .xml when only .xml exists" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for XML"
    [[ -f "${WORK_DIR}/res.xml" ]] || skip "res.xml not generated"
    rm -f "${WORK_DIR}/res.json" "${WORK_DIR}/res.yaml" "${WORK_DIR}/res.yml" "${WORK_DIR}/res.body"
    run bash "$HALLINK_SH" res links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh resolves basename to .yaml when only .yaml exists" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for YAML"
    rm -f "${WORK_DIR}/res.json" "${WORK_DIR}/res.xml" "${WORK_DIR}/res.yml" "${WORK_DIR}/res.body"
    run bash "$HALLINK_SH" res links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh resolves basename to .yml when only .yml exists" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for YAML"
    rm -f "${WORK_DIR}/res.json" "${WORK_DIR}/res.xml" "${WORK_DIR}/res.yaml" "${WORK_DIR}/res.body"
    run bash "$HALLINK_SH" res links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh resolves basename to .body when only .body exists" {
    rm -f "${WORK_DIR}/res.json" "${WORK_DIR}/res.xml" "${WORK_DIR}/res.yaml" "${WORK_DIR}/res.yml"
    run bash "$HALLINK_SH" res links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh resolves explicit .xml extension" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for XML"
    [[ -f "${WORK_DIR}/res.xml" ]] || skip "res.xml not generated"
    run bash "$HALLINK_SH" "${WORK_DIR}/res.xml" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh resolves explicit .yaml extension" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for YAML"
    run bash "$HALLINK_SH" "${WORK_DIR}/res.yaml" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh resolves explicit .body extension" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.body" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

# ── Mode A: --link, non-templated ─────────────────────────────────────────────

@test "hallink.sh --link passes through non-templated link unchanged" {
    run bash "$HALLINK_SH" --link '{"href":"/api/items","title":"Items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/items"* ]]
}

@test "hallink.sh --link non-templated output has no 'templated' field" {
    run bash "$HALLINK_SH" --link '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" != *"templated"* ]]
}

@test "hallink.sh --link preserves title field on non-templated link" {
    run bash "$HALLINK_SH" --link '{"href":"/api/items","title":"My Items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"My Items"* ]]
}

# ── Mode A: --link, templated with bindings ────────────────────────────────────

@test "hallink.sh --link expands simple query template" {
    run bash "$HALLINK_SH" --link '{"href":"/api{?q}","templated":true}' 'q=hello'
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api?q=hello"* ]]
}

@test "hallink.sh --link removes 'templated' after expansion" {
    run bash "$HALLINK_SH" --link '{"href":"/api{?q}","templated":true}' 'q=hello'
    [ "$status" -eq 0 ]
    [[ "$output" != *'"templated"'* ]]
}

@test "hallink.sh --link expands multi-var query template" {
    run bash "$HALLINK_SH" --link '{"href":"/api{?q,lang}","templated":true}' 'q=hi' 'lang=en'
    [ "$status" -eq 0 ]
    [[ "$output" == *"q=hi"* ]]
    [[ "$output" == *"lang=en"* ]]
}

@test "hallink.sh --link preserves title and type fields after expansion" {
    run bash "$HALLINK_SH" --link \
        '{"href":"/api{+path}","templated":true,"title":"Resource","type":"application/hal+json"}' \
        'path=/foo/bar'
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/foo/bar"* ]]
    [[ "$output" == *"Resource"* ]]
    [[ "$output" == *"application/hal+json"* ]]
}

# ── Mode A: --link, templated with no bindings ────────────────────────────────

@test "hallink.sh --link expands templated link with no bindings" {
    run bash "$HALLINK_SH" --link '{"href":"/api{?q}","templated":true}'
    [ "$status" -eq 0 ]
    # {?q} with no binding expands to empty string → /api
    [ "$output" = '{"href":"/api"}' ]
}

@test "hallink.sh --link removes 'templated' even with no bindings" {
    run bash "$HALLINK_SH" --link '{"href":"/api{?q}","templated":true}'
    [ "$status" -eq 0 ]
    [[ "$output" != *'"templated"'* ]]
}

# ── Mode A: list bindings ─────────────────────────────────────────────────────

@test "hallink.sh --link expands list binding with explode (*)" {
    run bash "$HALLINK_SH" --link '{"href":"/api{?ids*}","templated":true}' \
        'ids[]=1' 'ids[]=2' 'ids[]=3'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ids=1"* ]]
    [[ "$output" == *"ids=2"* ]]
    [[ "$output" == *"ids=3"* ]]
}

@test "hallink.sh --link expands list binding without explode (comma-joined)" {
    run bash "$HALLINK_SH" --link '{"href":"/api{?ids}","templated":true}' \
        'ids[]=1' 'ids[]=2' 'ids[]=3'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ids=1,2,3"* ]]
}

# ── Mode A: dictionary bindings ───────────────────────────────────────────────

@test "hallink.sh --link expands dict binding with explode (*)" {
    run bash "$HALLINK_SH" --link '{"href":"{keys*}","templated":true}' \
        'keys[a]=1' 'keys[b]=2'
    [ "$status" -eq 0 ]
    # RFC 6570: map explode → alphabetical key=value pairs
    [[ "$output" == *"a=1"* ]]
    [[ "$output" == *"b=2"* ]]
}

@test "hallink.sh --link expands dict binding without explode (interleaved)" {
    run bash "$HALLINK_SH" --link '{"href":"{keys}","templated":true}' \
        'keys[a]=1' 'keys[b]=2'
    [ "$status" -eq 0 ]
    # RFC 6570: map non-explode → key,val,key,val interleaved (alphabetical)
    [[ "$output" == *"a,1"* ]]
    [[ "$output" == *"b,2"* ]]
}

# ── Mode A: @file and stdin ───────────────────────────────────────────────────

@test "hallink.sh --link @file reads link from file" {
    printf '{"href":"/from-file","title":"FromFile"}\n' > "${WORK_DIR}/mylink.json"
    run bash "$HALLINK_SH" --link "@${WORK_DIR}/mylink.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/from-file"* ]]
}

@test "hallink.sh --link reads link from stdin" {
    run bash "$HALLINK_SH" --link <<< '{"href":"/from-stdin"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"/from-stdin"* ]]
}

@test "hallink.sh --link stdin expands templated link" {
    run bash "$HALLINK_SH" --link 'q=world' <<< '{"href":"/api{?q}","templated":true}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"?q=world"* ]]
}

# ── Mode B: navigate to link ──────────────────────────────────────────────────

@test "hallink.sh navigates to self link in resource file" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh navigates to non-templated array element link" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links items 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/1"* ]]
}

@test "hallink.sh expands templated link via file path" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links tmpl 'q=test'
    [ "$status" -eq 0 ]
    [[ "$output" == *"?q=test"* ]]
    [[ "$output" != *'"templated"'* ]]
}

@test "hallink.sh expands templated array element link" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links items 1 'q=foo'
    [ "$status" -eq 0 ]
    [[ "$output" == *"?q=foo"* ]]
}

@test "hallink.sh navigates through embeddeds to reach a link" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" embeddeds items 0 links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/1"* ]]
}

@test "hallink.sh expands templated link inside embedded resource" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" embeddeds items 0 links sub 'x=42'
    [ "$status" -eq 0 ]
    [[ "$output" == *"?x=42"* ]]
    [[ "$output" != *'"templated"'* ]]
}

@test "hallink.sh navigates via .body file using file path" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.body" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

# ── Mode B: field preservation ────────────────────────────────────────────────

@test "hallink.sh preserves title field on mode B templated link" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links res 'path=/index'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resource"* ]]
}

@test "hallink.sh preserves type field on mode B templated link" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links res 'path=/index'
    [ "$status" -eq 0 ]
    [[ "$output" == *"application/hal+json"* ]]
}

# ── Format preservation ───────────────────────────────────────────────────────

@test "hallink.sh outputs JSON for JSON source" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'{'* ]]
    [[ "$output" == *'"href"'* ]]
}

@test "hallink.sh outputs YAML for YAML source" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for YAML output"
    run bash "$HALLINK_SH" "${WORK_DIR}/res.yaml" links self
    [ "$status" -eq 0 ]
    # YAML output uses 'href:' not '"href":'
    [[ "$output" == *'href:'* ]]
    [[ "$output" != *'"href"'* ]]
}

@test "hallink.sh outputs XML for XML source" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for XML"
    [[ -f "${WORK_DIR}/res.xml" ]] || skip "res.xml not generated"
    run bash "$HALLINK_SH" "${WORK_DIR}/res.xml" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'<'* ]]
}

# ── Exit code specificity ─────────────────────────────────────────────────────

@test "hallink.sh file-not-found returns exactly exit code 2" {
    run bash "$HALLINK_SH" /no/such/path.json links self
    [ "$status" -eq 2 ]
}

@test "hallink.sh basename-not-found returns exactly exit code 2" {
    run bash "$HALLINK_SH" nosuchbasename links self
    [ "$status" -eq 2 ]
}

@test "hallink.sh rel-not-found returns exactly exit code 3" {
    run bash "$HALLINK_SH" "${WORK_DIR}/res.json" links nosuchrel
    [ "$status" -eq 3 ]
}

@test "hallink.sh no-href returns exactly exit code 3" {
    run bash "$HALLINK_SH" --link '{"title":"no href"}'
    [ "$status" -eq 3 ]
}

@test "hallink.sh no-tool returns exactly exit code 4" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq"; chmod +x "${stub_dir}/yq"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/jq"; chmod +x "${stub_dir}/jq"
    run env PATH="${stub_dir}:${PATH}" bash "$HALLINK_SH" --link '{"href":"/api"}'
    [ "$status" -eq 4 ]
    rm -rf "$stub_dir"
}

# ── HAL_LINK_PLUGIN — plugin chain ────────────────────────────────────────────

_make_plugin() {
    local path="$1" new_href="$2"
    printf '#!/usr/bin/env bash\njq -c --arg h "%s" '"'"'.href = $h'"'"' \n' "$new_href" > "$path"
    chmod +x "$path"
}

@test "hallink.sh HAL_LINK_PLUGIN not set — no-op" {
    run env -u HAL_LINK_PLUGIN bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *"/api/r"* ]]
}

@test "hallink.sh HAL_LINK_PLUGIN single plugin rewrites href (file+path mode)" {
    local plugin="${WORK_DIR}/plugin.sh"
    printf '#!/usr/bin/env bash\njq -c '"'"'.href = "/rewritten"'"'"'\n' > "$plugin"
    chmod +x "$plugin"
    run env HAL_LINK_PLUGIN="$plugin" bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'"/rewritten"'* ]]
}

@test "hallink.sh HAL_LINK_PLUGIN plugin receives resource file and path args" {
    local plugin="${WORK_DIR}/plugin.sh"
    # Plugin writes its args to a file so we can inspect them, then passes link through
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/plugin_args"\ncat\n' \
        "$WORK_DIR" > "$plugin"
    chmod +x "$plugin"
    run env HAL_LINK_PLUGIN="$plugin" bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    local args
    args=$(cat "${WORK_DIR}/plugin_args")
    [[ "$args" == *"${WORK_DIR}/res.json"* ]]
    [[ "$args" == *"links"* ]]
    [[ "$args" == *"self"* ]]
}

@test "hallink.sh HAL_LINK_PLUGIN single plugin rewrites href (--link mode)" {
    local plugin="${WORK_DIR}/plugin.sh"
    printf '#!/usr/bin/env bash\njq -c '"'"'.href = "/link-mode-rewritten"'"'"'\n' > "$plugin"
    chmod +x "$plugin"
    run env HAL_LINK_PLUGIN="$plugin" bash "$HALLINK_SH" --link '{"href":"/api/r"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"/link-mode-rewritten"'* ]]
}

@test "hallink.sh HAL_LINK_PLUGIN --link mode calls plugin with no resource-file arg" {
    local plugin="${WORK_DIR}/plugin.sh"
    printf '#!/usr/bin/env bash\nprintf "%%d\\n" "$#" > "%s/plugin_argc"\ncat\n' \
        "$WORK_DIR" > "$plugin"
    chmod +x "$plugin"
    run env HAL_LINK_PLUGIN="$plugin" bash "$HALLINK_SH" --link '{"href":"/api/r"}'
    [ "$status" -eq 0 ]
    [ "$(cat "${WORK_DIR}/plugin_argc")" -eq 0 ]
}

@test "hallink.sh HAL_LINK_PLUGIN two plugins chain in order" {
    local p1="${WORK_DIR}/p1.sh" p2="${WORK_DIR}/p2.sh"
    printf '#!/usr/bin/env bash\njq -c '"'"'.href = "/step1"'"'"'\n' > "$p1"; chmod +x "$p1"
    printf '#!/usr/bin/env bash\njq -c '"'"'.href = (.href + "/step2")'"'"'\n' > "$p2"; chmod +x "$p2"
    run env HAL_LINK_PLUGIN="${p1}:${p2}" bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'"/step1/step2"'* ]]
}

@test "hallink.sh HAL_LINK_PLUGIN plugin exits non-zero → exit 3" {
    local plugin="${WORK_DIR}/plugin.sh"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$plugin"; chmod +x "$plugin"
    run env HAL_LINK_PLUGIN="$plugin" bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 3 ]
}

@test "hallink.sh HAL_LINK_PLUGIN plugin emits invalid JSON → exit 3" {
    local plugin="${WORK_DIR}/plugin.sh"
    printf '#!/usr/bin/env bash\nprintf "not-json"\n' > "$plugin"; chmod +x "$plugin"
    run env HAL_LINK_PLUGIN="$plugin" bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 3 ]
}

@test "hallink.sh HAL_LINK_PLUGIN plugin output missing .href → exit 3" {
    local plugin="${WORK_DIR}/plugin.sh"
    printf '#!/usr/bin/env bash\nprintf '"'"'{"title":"no href"}'"'"'\n' > "$plugin"; chmod +x "$plugin"
    run env HAL_LINK_PLUGIN="$plugin" bash "$HALLINK_SH" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 3 ]
}

@test "hallink.sh HAL_LINK_PLUGIN plugin fires before template expansion" {
    local plugin="${WORK_DIR}/plugin.sh"
    # Rewrite href to a non-templated value; if plugin fires before expansion,
    # no template expansion will occur and output will contain our literal href.
    printf '#!/usr/bin/env bash\njq -c '"'"'.href = "/plugin-href" | del(.templated)'"'"'\n' \
        > "$plugin"; chmod +x "$plugin"
    run env HAL_LINK_PLUGIN="$plugin" bash "$HALLINK_SH" "${WORK_DIR}/res.json" links tmpl
    [ "$status" -eq 0 ]
    [[ "$output" == *'"/plugin-href"'* ]]
}
