#!/usr/bin/env bats
# =============================================================================
# halcurie.bats — unit tests for halcurie.sh (CURIE-expanding link plugin)
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

HALCURIE_SH="${SCRIPTS_DIR}/halcurie.sh"

# ── fixtures ──────────────────────────────────────────────────────────────────
#
# Resource tree:
#   root              _links.CURIE = [{name:doc, …/docs/}, {name:item, …/items/}]
#   └─ orders[0]      _links.CURIE = {name:ord, …/orders/}   (single object)
#      └─ items[0]    (no CURIE — forces a walk up to orders, then root)
#
# A CURIE definition href is a plain URL (no "{rel}" template); link hrefs that
# reference a prefix use the SafeCURIE form "[<prefix>:<reference>]".

HAL_JSON='{
  "_links": {
    "CURIE": [
      {"name": "doc",  "href": "https://api.example.com/docs/"},
      {"name": "item", "href": "https://api.example.com/items/"}
    ],
    "self": {"href": "/api"}
  },
  "_embedded": {
    "orders": [
      {
        "_links": {
          "CURIE":   {"name": "ord", "href": "https://api.example.com/orders/"},
          "self":    {"href": "/api/orders/1"},
          "product": {"href": "[ord:widget]"}
        },
        "_embedded": {
          "items": [
            {
              "_links": {
                "self":  {"href": "/api/items/1"},
                "guide": {"href": "[doc:start]"}
              }
            }
          ]
        }
      }
    ]
  }
}'

WORK_DIR=""

setup() {
    WORK_DIR="$(mktemp -d)"
    printf '%s\n' "$HAL_JSON" > "${WORK_DIR}/res.json"
    cd "$WORK_DIR"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# ── single-object CURIE in the link's own resource ────────────────────────────

@test "expands prefix from a single-object CURIE in the same resource" {
    run bash -c \
        'printf "%s" "{\"href\":\"[ord:widget]\"}" | halcurie.sh res.json embeddeds orders 0 links product'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"https://api.example.com/orders/widget"'* ]]
}

# ── array CURIE at the root ───────────────────────────────────────────────────

@test "expands prefix from a CURIE array at the root" {
    run bash -c \
        'printf "%s" "{\"href\":\"[doc:start]\",\"type\":\"text/html\"}" | halcurie.sh res.json links home'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"https://api.example.com/docs/start"'* ]]
}

@test "selects the matching name out of a multi-entry CURIE array" {
    run bash -c \
        'printf "%s" "{\"href\":\"[item:42]\"}" | halcurie.sh res.json links thing'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"https://api.example.com/items/42"'* ]]
}

# ── walk up the embedded stack ────────────────────────────────────────────────

@test "walks up to an ancestor that defines the prefix" {
    # items[0] has no CURIE; "doc" is only defined at the root.
    run bash -c \
        'printf "%s" "{\"href\":\"[doc:start]\"}" | halcurie.sh res.json embeddeds orders 0 embeddeds items 0 links guide'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"https://api.example.com/docs/start"'* ]]
}

# ── pass-through (unchanged) cases, all exit 0 ────────────────────────────────

@test "leaves a real URL scheme unchanged" {
    run bash -c \
        'printf "%s" "{\"href\":\"http://host/path\"}" | halcurie.sh res.json links self'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"http://host/path"'* ]]
}

@test "leaves an unknown SafeCURIE prefix unchanged" {
    run bash -c \
        'printf "%s" "{\"href\":\"[zzz:thing]\"}" | halcurie.sh res.json embeddeds orders 0 links product'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"[zzz:thing]"'* ]]
}

@test "leaves a bare (unbracketed) CURIE unchanged — only SafeCURIEs expand" {
    run bash -c \
        'printf "%s" "{\"href\":\"ord:widget\"}" | halcurie.sh res.json embeddeds orders 0 links product'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"ord:widget"'* ]]
}

@test "leaves a href without a prefix unchanged" {
    run bash -c \
        'printf "%s" "{\"href\":\"/relative/path\"}" | halcurie.sh res.json links self'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"/relative/path"'* ]]
}

@test "passes a link with no href through unchanged" {
    run bash -c \
        'printf "%s" "{\"name\":\"x\"}" | halcurie.sh res.json links self'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"name":"x"'* ]]
}

@test "passes through unchanged when no resource file is given" {
    run bash -c 'printf "%s" "{\"href\":\"doc:start\"}" | halcurie.sh'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"doc:start"'* ]]
}

# ── preserves sibling fields on expansion ─────────────────────────────────────

@test "preserves other link fields when expanding" {
    run bash -c \
        'printf "%s" "{\"href\":\"[ord:widget]\",\"type\":\"application/json\",\"title\":\"W\"}" | halcurie.sh res.json embeddeds orders 0 links product'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"type":"application/json"'* ]]
    [[ "$output" == *'"title":"W"'* ]]
    [[ "$output" == *'"href":"https://api.example.com/orders/widget"'* ]]
}

# ── error: invalid JSON on stdin (exit 5) ─────────────────────────────────────

@test "exits 5 on invalid link JSON" {
    run bash -c 'printf "%s" "not json {" | halcurie.sh res.json links self'
    [ "$status" -eq 5 ]
}

# ── error: no tool available (exit 4) ─────────────────────────────────────────

@test "exits 4 when neither yq nor jq is available" {
    local stub_dir="${WORK_DIR}/stubs"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\nexit 1\n' > "${stub_dir}/yq"
    printf '#!/bin/sh\nexit 1\n' > "${stub_dir}/jq"
    chmod +x "${stub_dir}/yq" "${stub_dir}/jq"
    run env PATH="${stub_dir}:${PATH}" bash -c \
        'printf "%s" "{\"href\":\"doc:start\"}" | halcurie.sh res.json links home'
    [ "$status" -eq 4 ]
}

# ── jq-only path ──────────────────────────────────────────────────────────────

@test "works with jq when yq is unavailable" {
    local stub_dir="${WORK_DIR}/stubs"
    mkdir -p "$stub_dir"
    printf '#!/bin/sh\nexit 1\n' > "${stub_dir}/yq"
    chmod +x "${stub_dir}/yq"
    run env PATH="${stub_dir}:${PATH}" bash -c \
        'printf "%s" "{\"href\":\"[ord:widget]\"}" | halcurie.sh res.json embeddeds orders 0 links product'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"href":"https://api.example.com/orders/widget"'* ]]
}

# ── -config: env-recreation snippet (plugin contract) ────────────────────────

@test "halcurie.sh -config prints nothing and exits 0 (needs no environment)" {
    run bash "$HALCURIE_SH" -config
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "halcurie.sh -config does not read stdin" {
    # A link on stdin must be ignored: -config exits before reading it.
    run bash "$HALCURIE_SH" -config <<< '{"href":"[ord:widget]"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
