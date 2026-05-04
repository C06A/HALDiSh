#!/usr/bin/env bats
# =============================================================================
# haldoclink.bats — unit tests for haldoclink.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

HALDOCLINK_SH="${SCRIPTS_DIR}/haldoclink.sh"

# ── fixtures ──────────────────────────────────────────────────────────────────
#
# Resource tree:
#   root            _links.curies = [{name:doc, href:https://example.com/docs/{rel}}]
#                   _links.doc:orders
#   └─ orders[0]    _links.curies = [{name:ns, href:https://ns.example.com/{rel}}]
#                   _links.ns:detail
#                   _links.doc:item      (prefix "doc" only defined at root)
#      └─ items[0]  (no curies)
#                   _links.doc:part      (prefix "doc" only defined at root)

HAL_JSON='{
  "_links": {
    "curies": [
      {"name": "doc", "href": "https://example.com/docs/{rel}", "templated": true}
    ],
    "self":       {"href": "/api"},
    "doc:orders": {"href": "/api/orders"}
  },
  "_embedded": {
    "orders": [
      {
        "_links": {
          "curies": [
            {"name": "ns", "href": "https://ns.example.com/{rel}", "templated": true}
          ],
          "self":      {"href": "/api/orders/1"},
          "ns:detail": {"href": "/api/orders/1/detail"},
          "doc:item":  {"href": "/api/orders/1"}
        },
        "_embedded": {
          "items": [
            {
              "_links": {
                "self":     {"href": "/api/items/1"},
                "doc:part": {"href": "/api/parts/1"}
              }
            }
          ]
        }
      }
    ]
  }
}'

HAL_YAML='_links:
  curies:
    - name: doc
      href: "https://example.com/docs/{rel}"
      templated: true
  self:
    href: /api
  doc:orders:
    href: /api/orders'

WORK_DIR=""

setup() {
    WORK_DIR="$(mktemp -d)"
    printf '%s\n' "$HAL_JSON"  > "${WORK_DIR}/res.json"
    printf '%s\n' "$HAL_YAML"  > "${WORK_DIR}/res.yaml"
    printf '%s\n' "$HAL_YAML"  > "${WORK_DIR}/res.yml"
    printf '%s\n' "$HAL_JSON"  > "${WORK_DIR}/res.body"
    if command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        yq -o xml '.' "${WORK_DIR}/res.json" > "${WORK_DIR}/res.xml" 2>/dev/null || true
    fi
    cd "$WORK_DIR"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# ── argument validation (exit 1) ──────────────────────────────────────────────

@test "haldoclink.sh exits 1 with no arguments" {
    run bash "$HALDOCLINK_SH"
    [ "$status" -eq 1 ]
}

@test "haldoclink.sh prints Usage to stderr with no arguments" {
    run --separate-stderr bash "$HALDOCLINK_SH"
    [[ "$stderr" == *"Usage:"* ]]
}

@test "haldoclink.sh exits 1 when only file is given" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json"
    [ "$status" -eq 1 ]
}

@test "haldoclink.sh exits 1 for unknown path segment" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" bogus doc:orders
    [ "$status" -eq 1 ]
}

@test "haldoclink.sh prints error for unknown segment" {
    run --separate-stderr bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" bogus doc:orders
    [[ "$stderr" == *"unexpected path segment"* ]]
}

@test "haldoclink.sh exits 1 when links has no following rel" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links
    [ "$status" -eq 1 ]
}

@test "haldoclink.sh exits 1 when embeddeds has no following rel" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" embeddeds
    [ "$status" -eq 1 ]
}

@test "haldoclink.sh exits 1 for extra segment after links rel" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links doc:orders extra
    [ "$status" -eq 1 ]
}

@test "haldoclink.sh prints error for extra segment after links" {
    run --separate-stderr bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links doc:orders extra
    [[ "$stderr" == *"unexpected segment after links"* ]]
}

# ── file resolution (exit 2) ──────────────────────────────────────────────────

@test "haldoclink.sh exits 2 when full path file does not exist" {
    run bash "$HALDOCLINK_SH" /no/such/file.json links doc:orders
    [ "$status" -eq 2 ]
}

@test "haldoclink.sh prints error to stderr for missing full path" {
    run --separate-stderr bash "$HALDOCLINK_SH" /no/such/file.json links doc:orders
    [[ "$stderr" == *"no such file"* ]]
}

@test "haldoclink.sh exits 2 when basename has no matching file" {
    run bash "$HALDOCLINK_SH" nonexistent links doc:orders
    [ "$status" -eq 2 ]
}

@test "haldoclink.sh prints error to stderr for unresolvable basename" {
    run --separate-stderr bash "$HALDOCLINK_SH" nonexistent links doc:orders
    [[ "$stderr" == *"file not found"* ]]
}

# ── CURIE not found (exit 3) ──────────────────────────────────────────────────

@test "haldoclink.sh exits 3 when CURIE prefix is not defined anywhere in stack" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links unk:orders
    [ "$status" -eq 3 ]
}

@test "haldoclink.sh prints error when CURIE prefix not found" {
    run --separate-stderr bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links unk:orders
    [[ "$stderr" == *"no CURIE found"* ]]
}

@test "haldoclink.sh exits 3 when unprefixed rel has no matching CURIE key" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links nosuchrel
    [ "$status" -eq 3 ]
}

@test "haldoclink.sh prints error when unprefixed rel has no matching key" {
    run --separate-stderr bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links nosuchrel
    [[ "$stderr" == *"no CURIE-prefixed rel"* ]]
}

@test "haldoclink.sh exits 3 when embedded rel does not exist" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" embeddeds nosuch 0 links doc:orders
    [ "$status" -eq 3 ]
}

# ── tool unavailable (exit 4) ─────────────────────────────────────────────────

@test "haldoclink.sh exits 4 when neither yq nor jq is available" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq";  chmod +x "${stub_dir}/yq"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/jq";  chmod +x "${stub_dir}/jq"
    run env PATH="${stub_dir}:${PATH}" bash "$HALDOCLINK_SH" \
        "${WORK_DIR}/res.json" links doc:orders
    [ "$status" -eq 4 ]
    rm -rf "$stub_dir"
}

# ── root CURIE — explicit prefix ──────────────────────────────────────────────

@test "haldoclink.sh resolves doc:orders from root CURIE" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/orders"* ]]
}

@test "haldoclink.sh output contains type text/html for root CURIE" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"text/html"* ]]
}

@test "haldoclink.sh output is a JSON object for root CURIE" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == '{'* ]]
    [[ "$output" == *'"href"'* ]]
    [[ "$output" == *'"type"'* ]]
}

# ── root CURIE — no prefix (suffix search) ────────────────────────────────────

@test "haldoclink.sh resolves unprefixed 'orders' to doc:orders at root" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/orders"* ]]
}

@test "haldoclink.sh unprefixed rel produces type text/html" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"text/html"* ]]
}

# ── embedded CURIE — explicit prefix ─────────────────────────────────────────

@test "haldoclink.sh resolves ns:detail using CURIE defined in embedded resource" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" embeddeds orders 0 links ns:detail
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://ns.example.com/detail"* ]]
}

@test "haldoclink.sh embedded CURIE output contains type text/html" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" embeddeds orders 0 links ns:detail
    [ "$status" -eq 0 ]
    [[ "$output" == *"text/html"* ]]
}

# ── embedded CURIE — no prefix (suffix search) ────────────────────────────────

@test "haldoclink.sh resolves unprefixed 'detail' to ns:detail in embedded resource" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" embeddeds orders 0 links detail
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://ns.example.com/detail"* ]]
}

# ── upward CURIE search — explicit prefix ─────────────────────────────────────

@test "haldoclink.sh finds doc CURIE at root when embedded has only ns CURIE" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" embeddeds orders 0 links doc:item
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/item"* ]]
}

@test "haldoclink.sh upward-search output contains type text/html" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" embeddeds orders 0 links doc:item
    [ "$status" -eq 0 ]
    [[ "$output" == *"text/html"* ]]
}

# ── upward CURIE search — no prefix ───────────────────────────────────────────

@test "haldoclink.sh resolves unprefixed 'item' to doc:item, CURIE found at root" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" embeddeds orders 0 links item
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/item"* ]]
}

# ── deep upward CURIE search (two levels up) ──────────────────────────────────

@test "haldoclink.sh resolves doc:part from items[0], CURIE found at root" {
    run bash "$HALDOCLINK_SH" \
        "${WORK_DIR}/res.json" embeddeds orders 0 embeddeds items 0 links doc:part
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/part"* ]]
}

@test "haldoclink.sh resolves unprefixed 'part' from items[0], CURIE found at root" {
    run bash "$HALDOCLINK_SH" \
        "${WORK_DIR}/res.json" embeddeds orders 0 embeddeds items 0 links part
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/part"* ]]
}

@test "haldoclink.sh deep upward search output contains type text/html" {
    run bash "$HALDOCLINK_SH" \
        "${WORK_DIR}/res.json" embeddeds orders 0 embeddeds items 0 links doc:part
    [ "$status" -eq 0 ]
    [[ "$output" == *"text/html"* ]]
}

# ── basename resolution ───────────────────────────────────────────────────────

@test "haldoclink.sh resolves basename to .json when multiple variants exist" {
    run bash "$HALDOCLINK_SH" res links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/orders"* ]]
}

@test "haldoclink.sh resolves basename to .yaml when only .yaml exists" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for YAML"
    rm -f "${WORK_DIR}/res.json" "${WORK_DIR}/res.xml" \
          "${WORK_DIR}/res.yml"  "${WORK_DIR}/res.body"
    run bash "$HALDOCLINK_SH" res links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/orders"* ]]
}

@test "haldoclink.sh resolves basename to .yml when only .yml exists" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for YAML"
    rm -f "${WORK_DIR}/res.json" "${WORK_DIR}/res.xml" \
          "${WORK_DIR}/res.yaml" "${WORK_DIR}/res.body"
    run bash "$HALDOCLINK_SH" res links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/orders"* ]]
}

@test "haldoclink.sh resolves basename to .body when only .body exists" {
    rm -f "${WORK_DIR}/res.json" "${WORK_DIR}/res.xml" \
          "${WORK_DIR}/res.yaml" "${WORK_DIR}/res.yml"
    run bash "$HALDOCLINK_SH" res links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/orders"* ]]
}

@test "haldoclink.sh resolves basename to .xml when only .xml exists" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for XML"
    [[ -f "${WORK_DIR}/res.xml" ]] || skip "res.xml not generated"
    rm -f "${WORK_DIR}/res.json" "${WORK_DIR}/res.yaml" \
          "${WORK_DIR}/res.yml"  "${WORK_DIR}/res.body"
    run bash "$HALDOCLINK_SH" res links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://example.com/docs/orders"* ]]
}

# ── output format preservation ────────────────────────────────────────────────

@test "haldoclink.sh outputs JSON for JSON source" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == '{'* ]]
    [[ "$output" == *'"href"'* ]]
    [[ "$output" == *'"type"'* ]]
}

@test "haldoclink.sh outputs YAML for YAML source" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for YAML output"
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.yaml" links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *'href:'* ]]
    [[ "$output" != *'"href"'* ]]
    [[ "$output" == *'type:'* ]]
}

@test "haldoclink.sh outputs XML for XML source" {
    command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1 \
        || skip "yq required for XML"
    [[ -f "${WORK_DIR}/res.xml" ]] || skip "res.xml not generated"
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.xml" links doc:orders
    [ "$status" -eq 0 ]
    [[ "$output" == *'<'* ]]
    [[ "$output" == *'https://example.com/docs/orders'* ]]
}

# ── exit code specificity ─────────────────────────────────────────────────────

@test "haldoclink.sh file-not-found returns exactly exit code 2" {
    run bash "$HALDOCLINK_SH" /no/such/path.json links doc:orders
    [ "$status" -eq 2 ]
}

@test "haldoclink.sh basename-not-found returns exactly exit code 2" {
    run bash "$HALDOCLINK_SH" nosuchbasename links doc:orders
    [ "$status" -eq 2 ]
}

@test "haldoclink.sh unknown-curie-prefix returns exactly exit code 3" {
    run bash "$HALDOCLINK_SH" "${WORK_DIR}/res.json" links unknown:orders
    [ "$status" -eq 3 ]
}

@test "haldoclink.sh no-tool returns exactly exit code 4" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq"; chmod +x "${stub_dir}/yq"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/jq"; chmod +x "${stub_dir}/jq"
    run env PATH="${stub_dir}:${PATH}" bash "$HALDOCLINK_SH" \
        "${WORK_DIR}/res.json" links doc:orders
    [ "$status" -eq 4 ]
    rm -rf "$stub_dir"
}
