#!/usr/bin/env bats
# =============================================================================
# hal_basename.bats — unit tests for hal_basename.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

HAL_BASENAME_SH="${SCRIPTS_DIR}/hal_basename.sh"

setup() {
    WORK_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# Helper: run hal_basename.sh from WORK_DIR
_halbase() {
    run bash -c "cd '${WORK_DIR}' && bash '${HAL_BASENAME_SH}' $(printf '%q ' "$@")"
}

# ── argument validation ───────────────────────────────────────────────────────

@test "hal_basename: exits 1 with no arguments" {
    run bash "$HAL_BASENAME_SH"
    [ "$status" -eq 1 ]
}

@test "hal_basename: prints usage to stderr with no arguments" {
    run --separate-stderr bash "$HAL_BASENAME_SH"
    [[ "$stderr" == *"Usage"* ]]
}

@test "hal_basename: exits 1 when first arg is not -p" {
    _halbase notp foo
    [ "$status" -eq 1 ]
}

@test "hal_basename: exits 1 when -p has no prefix argument" {
    _halbase -p
    [ "$status" -eq 1 ]
}

# ── numbering ─────────────────────────────────────────────────────────────────

@test "hal_basename: first name for a prefix is <prefix>1" {
    _halbase -p resp
    [ "$status" -eq 0 ]
    [ "$output" = "resp1" ]
}

@test "hal_basename: returns one past the largest existing <prefix>N" {
    touch "${WORK_DIR}/resp1.body" "${WORK_DIR}/resp2.body" "${WORK_DIR}/resp3.headers"
    _halbase -p resp
    [ "$status" -eq 0 ]
    [ "$output" = "resp4" ]
}

@test "hal_basename: ignores non-numeric suffixes after the prefix" {
    touch "${WORK_DIR}/respX.body" "${WORK_DIR}/resp.body"
    _halbase -p resp
    [ "$status" -eq 0 ]
    [ "$output" = "resp1" ]
}

@test "hal_basename: numeric suffix is compared as a number not a string" {
    touch "${WORK_DIR}/resp9.body" "${WORK_DIR}/resp10.body"
    _halbase -p resp
    [ "$status" -eq 0 ]
    [ "$output" = "resp11" ]
}

@test "hal_basename: empty prefix yields bare numbers" {
    touch "${WORK_DIR}/1.body" "${WORK_DIR}/2.body"
    _halbase -p ''
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "hal_basename: only files with a literal prefix match are counted" {
    touch "${WORK_DIR}/other5.body"
    _halbase -p resp
    [ "$status" -eq 0 ]
    [ "$output" = "resp1" ]
}
