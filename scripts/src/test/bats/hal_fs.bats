#!/usr/bin/env bats
# =============================================================================
# hal_fs.bats — unit tests for hal::fs::* functions
# =============================================================================

load 'test_helper'

setup() {
    load_lib hal_utils.sh
    # Isolated temp directory per test
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ── hal::fs::exists ───────────────────────────────────────────────────────────

@test "hal::fs::exists returns 0 for existing file" {
    touch "$TEST_TMP/file.txt"
    hal::fs::exists "$TEST_TMP/file.txt"
}

@test "hal::fs::exists returns 0 for existing directory" {
    hal::fs::exists "$TEST_TMP"
}

@test "hal::fs::exists returns 1 for nonexistent path" {
    ! hal::fs::exists "$TEST_TMP/no_such_file"
}

# ── hal::fs::is_file / is_dir ─────────────────────────────────────────────────

@test "hal::fs::is_file returns 0 for regular file" {
    touch "$TEST_TMP/regular"
    hal::fs::is_file "$TEST_TMP/regular"
}

@test "hal::fs::is_file returns 1 for directory" {
    ! hal::fs::is_file "$TEST_TMP"
}

@test "hal::fs::is_dir returns 0 for directory" {
    hal::fs::is_dir "$TEST_TMP"
}

@test "hal::fs::is_dir returns 1 for file" {
    touch "$TEST_TMP/f"
    ! hal::fs::is_dir "$TEST_TMP/f"
}

# ── hal::fs::mkdir_p ──────────────────────────────────────────────────────────

@test "hal::fs::mkdir_p creates nested directories" {
    hal::fs::mkdir_p "$TEST_TMP/a/b/c"
    [ -d "$TEST_TMP/a/b/c" ]
}

@test "hal::fs::mkdir_p is idempotent" {
    hal::fs::mkdir_p "$TEST_TMP/existing"
    hal::fs::mkdir_p "$TEST_TMP/existing"
    [ -d "$TEST_TMP/existing" ]
}

# ── hal::fs::extension ────────────────────────────────────────────────────────

@test "hal::fs::extension returns extension without dot" {
    run hal::fs::extension "archive.tar.gz"
    [ "$status" -eq 0 ]
    [ "$output" = "gz" ]
}

@test "hal::fs::extension returns extension for simple filename" {
    run hal::fs::extension "script.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "sh" ]
}

@test "hal::fs::extension returns empty string when no extension" {
    run hal::fs::extension "Makefile"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "hal::fs::extension ignores directory component" {
    run hal::fs::extension "/usr/local/bin/script.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "sh" ]
}

# ── hal::fs::basename_no_ext ──────────────────────────────────────────────────

@test "hal::fs::basename_no_ext strips extension" {
    run hal::fs::basename_no_ext "deploy.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "deploy" ]
}

@test "hal::fs::basename_no_ext strips path and extension" {
    run hal::fs::basename_no_ext "/opt/scripts/deploy.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "deploy" ]
}

@test "hal::fs::basename_no_ext returns full name when no extension" {
    run hal::fs::basename_no_ext "Makefile"
    [ "$status" -eq 0 ]
    [ "$output" = "Makefile" ]
}
