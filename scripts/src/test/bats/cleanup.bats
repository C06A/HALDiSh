#!/usr/bin/env bats
# =============================================================================
# cleanup.bats — unit tests for cleanup.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

CLEANUP_SH="${SCRIPTS_DIR}/cleanup.sh"

setup() {
    WORK_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# Helper: run cleanup.sh from WORK_DIR
_cleanup() {
    run bash -c "cd '${WORK_DIR}' && bash '${CLEANUP_SH}' $(printf '%q ' "$@")"
}

# ── argument validation ───────────────────────────────────────────────────────

@test "cleanup: exits 1 with no arguments" {
    run bash "$CLEANUP_SH"
    [ "$status" -eq 1 ]
}

@test "cleanup: prints usage to stderr with no arguments" {
    run --separate-stderr bash "$CLEANUP_SH"
    [[ "$stderr" == *"Usage"* ]]
}

# ── stdout ────────────────────────────────────────────────────────────────────

@test "cleanup: prints base name to stdout" {
    touch "${WORK_DIR}/foo.tmp"
    _cleanup foo
    [ "$output" = "foo" ]
}

@test "cleanup: stdout is only the base name when files are kept" {
    touch "${WORK_DIR}/foo.sh" "${WORK_DIR}/foo.tmp"
    _cleanup foo sh
    [ "$output" = "foo" ]
}

@test "cleanup: prints base name even when no files exist" {
    _cleanup nonexistent
    [ "$status" -eq 0 ]
    [ "$output" = "nonexistent" ]
}

# ── delete all (no keep list) ─────────────────────────────────────────────────

@test "cleanup: deletes all matching files when no keep-extensions given" {
    touch "${WORK_DIR}/foo.sh" "${WORK_DIR}/foo.txt" "${WORK_DIR}/foo.log"
    _cleanup foo
    [ ! -f "${WORK_DIR}/foo.sh" ]
    [ ! -f "${WORK_DIR}/foo.txt" ]
    [ ! -f "${WORK_DIR}/foo.log" ]
}

@test "cleanup: exits 0 when no matching files and no keep list" {
    _cleanup nonexistent
    [ "$status" -eq 0 ]
}

# ── keep list ─────────────────────────────────────────────────────────────────

@test "cleanup: keeps file whose extension is in the keep list" {
    touch "${WORK_DIR}/foo.sh" "${WORK_DIR}/foo.tmp"
    _cleanup foo sh
    [ -f "${WORK_DIR}/foo.sh" ]
}

@test "cleanup: deletes file whose extension is not in the keep list" {
    touch "${WORK_DIR}/foo.sh" "${WORK_DIR}/foo.tmp"
    _cleanup foo sh
    [ ! -f "${WORK_DIR}/foo.tmp" ]
}

@test "cleanup: keeps multiple extensions" {
    touch "${WORK_DIR}/foo.sh" "${WORK_DIR}/foo.bats" "${WORK_DIR}/foo.md" "${WORK_DIR}/foo.tmp"
    _cleanup foo sh bats md
    [ -f "${WORK_DIR}/foo.sh" ]
    [ -f "${WORK_DIR}/foo.bats" ]
    [ -f "${WORK_DIR}/foo.md" ]
}

@test "cleanup: deletes files not in a multi-extension keep list" {
    touch "${WORK_DIR}/foo.sh" "${WORK_DIR}/foo.bats" "${WORK_DIR}/foo.tmp" "${WORK_DIR}/foo.log"
    _cleanup foo sh bats
    [ ! -f "${WORK_DIR}/foo.tmp" ]
    [ ! -f "${WORK_DIR}/foo.log" ]
}

@test "cleanup: keep list extension not present is silently ignored" {
    touch "${WORK_DIR}/foo.sh"
    _cleanup foo sh txt
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/foo.sh" ]
}

# ── does not affect unrelated files ──────────────────────────────────────────

@test "cleanup: does not delete files with a different base name" {
    touch "${WORK_DIR}/foo.tmp" "${WORK_DIR}/bar.tmp"
    _cleanup foo
    [ -f "${WORK_DIR}/bar.tmp" ]
}

@test "cleanup: does not delete files whose name only starts with base name" {
    touch "${WORK_DIR}/foo.tmp" "${WORK_DIR}/foobar.tmp"
    _cleanup foo
    [ -f "${WORK_DIR}/foobar.tmp" ]
}

# ── stdin mode (-- sentinel) ──────────────────────────────────────────────────

@test "cleanup: reads base name from stdin when first arg is --" {
    touch "${WORK_DIR}/foo.tmp"
    run bash -c "cd '${WORK_DIR}' && echo foo | bash '${CLEANUP_SH}' --"
    [ "$status" -eq 0 ]
    [ ! -f "${WORK_DIR}/foo.tmp" ]
}

@test "cleanup: stdin mode prints base name to stdout" {
    touch "${WORK_DIR}/foo.tmp"
    run bash -c "cd '${WORK_DIR}' && echo foo | bash '${CLEANUP_SH}' --"
    [ "$output" = "foo" ]
}

@test "cleanup: stdin mode respects keep-extensions after --" {
    touch "${WORK_DIR}/alpha.sh" "${WORK_DIR}/alpha.tmp"
    run bash -c "cd '${WORK_DIR}' && echo alpha | bash '${CLEANUP_SH}' -- sh"
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/alpha.sh" ]
    [ ! -f "${WORK_DIR}/alpha.tmp" ]
}

@test "cleanup: stdin mode deletes all when no keep-extensions given" {
    touch "${WORK_DIR}/alpha.sh" "${WORK_DIR}/alpha.tmp"
    run bash -c "cd '${WORK_DIR}' && echo alpha | bash '${CLEANUP_SH}' --"
    [ ! -f "${WORK_DIR}/alpha.sh" ]
    [ ! -f "${WORK_DIR}/alpha.tmp" ]
}

@test "cleanup: stdin mode stdout is only the base name" {
    run bash -c "cd '${WORK_DIR}' && echo mybase | bash '${CLEANUP_SH}' --"
    [ "$output" = "mybase" ]
}
