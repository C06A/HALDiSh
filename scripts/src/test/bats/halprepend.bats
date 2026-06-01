#!/usr/bin/env bats
# =============================================================================
# halprepend.bats — unit tests for halprepend.sh (HAL_LINK_PLUGIN: prepend href)
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

HALPREPEND_SH="${SCRIPTS_DIR}/halprepend.sh"

WORK_DIR=""

setup() {
    WORK_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# ── HAL_PREPEND_BASE unset / empty — pass-through ─────────────────────────────

@test "halprepend.sh passes link through when HAL_PREPEND_BASE is unset" {
    run env -u HAL_PREPEND_BASE bash "$HALPREPEND_SH" <<< '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"/api/items"'* ]]
}

@test "halprepend.sh passes link through when HAL_PREPEND_BASE is empty" {
    run env HAL_PREPEND_BASE='' bash "$HALPREPEND_SH" <<< '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"/api/items"'* ]]
}

@test "halprepend.sh pass-through preserves all link fields" {
    run env -u HAL_PREPEND_BASE bash "$HALPREPEND_SH" \
        <<< '{"href":"/api","title":"T","type":"application/hal+json"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"title"'* ]]
    [[ "$output" == *'"type"'* ]]
}

# ── HAL_PREPEND_BASE set — prepend ───────────────────────────────────────────

@test "halprepend.sh prepends base to href" {
    run env HAL_PREPEND_BASE='https://example.com' bash "$HALPREPEND_SH" \
        <<< '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/items'* ]]
}

@test "halprepend.sh concatenates base and href literally" {
    run env HAL_PREPEND_BASE='https://example.com/' bash "$HALPREPEND_SH" \
        <<< '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com//api/items'* ]]
}

@test "halprepend.sh preserves title field" {
    run env HAL_PREPEND_BASE='https://example.com' bash "$HALPREPEND_SH" \
        <<< '{"href":"/api/items","title":"Items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"title"'* ]]
    [[ "$output" == *'Items'* ]]
}

@test "halprepend.sh preserves type field" {
    run env HAL_PREPEND_BASE='https://example.com' bash "$HALPREPEND_SH" \
        <<< '{"href":"/api/items","type":"application/hal+json"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'application/hal+json'* ]]
}

@test "halprepend.sh preserves templated field" {
    run env HAL_PREPEND_BASE='https://example.com' bash "$HALPREPEND_SH" \
        <<< '{"href":"/api{?q}","templated":true}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"templated"'* ]]
    [[ "$output" == *'https://example.com/api{?q}'* ]]
}

@test "halprepend.sh output is JSON" {
    run env HAL_PREPEND_BASE='https://example.com' bash "$HALPREPEND_SH" \
        <<< '{"href":"/api"}'
    [ "$status" -eq 0 ]
    [[ "$output" == '{'* ]]
    [[ "$output" == *'"href"'* ]]
}

# ── positional args accepted and ignored ─────────────────────────────────────

@test "halprepend.sh accepts resource-file and path args (plugin contract)" {
    printf '{"_links":{"self":{"href":"/api/r"}}}\n' > "${WORK_DIR}/res.json"
    run env HAL_PREPEND_BASE='https://example.com' bash "$HALPREPEND_SH" \
        "${WORK_DIR}/res.json" links self <<< '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/items'* ]]
}

# ── tool unavailable (exit 4) ─────────────────────────────────────────────────

@test "halprepend.sh exits 4 when neither yq nor jq available and base is set" {
    local stub_dir
    stub_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/yq"; chmod +x "${stub_dir}/yq"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${stub_dir}/jq"; chmod +x "${stub_dir}/jq"
    run env PATH="${stub_dir}:${PATH}" HAL_PREPEND_BASE='https://example.com' \
        bash "$HALPREPEND_SH" <<< '{"href":"/api"}'
    [ "$status" -eq 4 ]
    rm -rf "$stub_dir"
}

# ── end-to-end: used as HAL_LINK_PLUGIN with hallink.sh ──────────────────────

@test "halprepend.sh as HAL_LINK_PLUGIN rewrites href via hallink.sh" {
    printf '{"_links":{"self":{"href":"/api/r"}}}\n' > "${WORK_DIR}/res.json"
    run env HAL_PREPEND_BASE='https://example.com' \
        HAL_LINK_PLUGIN="$HALPREPEND_SH" \
        bash "${SCRIPTS_DIR}/hallink.sh" "${WORK_DIR}/res.json" links self
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/r'* ]]
}

@test "halprepend.sh as HAL_LINK_PLUGIN works in --link mode" {
    run env HAL_PREPEND_BASE='https://example.com' \
        HAL_LINK_PLUGIN="$HALPREPEND_SH" \
        bash "${SCRIPTS_DIR}/hallink.sh" --link '{"href":"/api/items"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'https://example.com/api/items'* ]]
}
