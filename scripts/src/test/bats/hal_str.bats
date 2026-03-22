#!/usr/bin/env bats
# =============================================================================
# hal_str.bats — unit tests for hal::str::* functions
# =============================================================================

load 'test_helper'

setup() {
    load_lib hal_utils.sh
}

# ── hal::str::trim ────────────────────────────────────────────────────────────

@test "hal::str::trim removes leading spaces" {
    run hal::str::trim "   hello"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "hal::str::trim removes trailing spaces" {
    run hal::str::trim "hello   "
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "hal::str::trim removes surrounding whitespace" {
    run hal::str::trim "  hello world  "
    [ "$status" -eq 0 ]
    [ "$output" = "hello world" ]
}

@test "hal::str::trim leaves non-padded string unchanged" {
    run hal::str::trim "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "hal::str::trim handles empty string" {
    run hal::str::trim ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ── hal::str::upper ───────────────────────────────────────────────────────────

@test "hal::str::upper converts to upper-case" {
    run hal::str::upper "hello world"
    [ "$status" -eq 0 ]
    [ "$output" = "HELLO WORLD" ]
}

@test "hal::str::upper is idempotent on already-upper string" {
    run hal::str::upper "HELLO"
    [ "$status" -eq 0 ]
    [ "$output" = "HELLO" ]
}

# ── hal::str::lower ───────────────────────────────────────────────────────────

@test "hal::str::lower converts to lower-case" {
    run hal::str::lower "HELLO WORLD"
    [ "$status" -eq 0 ]
    [ "$output" = "hello world" ]
}

@test "hal::str::lower is idempotent on already-lower string" {
    run hal::str::lower "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

# ── hal::str::contains ────────────────────────────────────────────────────────

@test "hal::str::contains returns 0 when needle present" {
    hal::str::contains "foobar" "oob"
}

@test "hal::str::contains returns 1 when needle absent" {
    ! hal::str::contains "foobar" "xyz"
}

@test "hal::str::contains works with exact match" {
    hal::str::contains "hello" "hello"
}

@test "hal::str::contains works with empty needle" {
    hal::str::contains "anything" ""
}

# ── hal::str::starts_with ─────────────────────────────────────────────────────

@test "hal::str::starts_with returns 0 when prefix matches" {
    hal::str::starts_with "foobar" "foo"
}

@test "hal::str::starts_with returns 1 when prefix absent" {
    ! hal::str::starts_with "foobar" "bar"
}

@test "hal::str::starts_with works with full string as prefix" {
    hal::str::starts_with "hello" "hello"
}

# ── hal::str::ends_with ───────────────────────────────────────────────────────

@test "hal::str::ends_with returns 0 when suffix matches" {
    hal::str::ends_with "foobar" "bar"
}

@test "hal::str::ends_with returns 1 when suffix absent" {
    ! hal::str::ends_with "foobar" "foo"
}

# ── hal::str::repeat ──────────────────────────────────────────────────────────

@test "hal::str::repeat repeats string n times" {
    run hal::str::repeat "ab" 3
    [ "$status" -eq 0 ]
    [ "$output" = "ababab" ]
}

@test "hal::str::repeat with count 1 returns original string" {
    run hal::str::repeat "x" 1
    [ "$status" -eq 0 ]
    [ "$output" = "x" ]
}

@test "hal::str::repeat with count 0 returns empty string" {
    run hal::str::repeat "x" 0
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ── hal::str::length ──────────────────────────────────────────────────────────

@test "hal::str::length returns correct length" {
    run hal::str::length "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
}

@test "hal::str::length returns 0 for empty string" {
    run hal::str::length ""
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}
