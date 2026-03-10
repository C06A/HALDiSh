#!/usr/bin/env bats
# =============================================================================
# hal_arr.bats — unit tests for hal::arr::* functions
# =============================================================================

load 'test_helper'

setup() {
    load_lib hal_utils.sh
}

# ── hal::arr::contains ────────────────────────────────────────────────────────

@test "hal::arr::contains finds existing element" {
    local arr=("apple" "banana" "cherry")
    hal::arr::contains "banana" "${arr[@]}"
}

@test "hal::arr::contains returns 1 for missing element" {
    local arr=("apple" "banana" "cherry")
    ! hal::arr::contains "grape" "${arr[@]}"
}

@test "hal::arr::contains works with single-element array" {
    hal::arr::contains "only" "only"
}

@test "hal::arr::contains returns 1 for empty array" {
    ! hal::arr::contains "x"
}

@test "hal::arr::contains does not do partial matches" {
    local arr=("foobar")
    ! hal::arr::contains "foo" "${arr[@]}"
}

# ── hal::arr::join ────────────────────────────────────────────────────────────

@test "hal::arr::join joins with separator" {
    run hal::arr::join ", " "a" "b" "c"
    [ "$status" -eq 0 ]
    [ "$output" = "a, b, c" ]
}

@test "hal::arr::join with single element has no separator" {
    run hal::arr::join "-" "only"
    [ "$status" -eq 0 ]
    [ "$output" = "only" ]
}

@test "hal::arr::join with empty separator concatenates" {
    run hal::arr::join "" "x" "y" "z"
    [ "$status" -eq 0 ]
    [ "$output" = "xyz" ]
}
