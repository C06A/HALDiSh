#!/usr/bin/env bats
# =============================================================================
# menu.bats — unit tests for menu.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

MENU_SH="${SCRIPTS_DIR}/menu.sh"

setup() {
    # A regular temp file pre-filled with simulated keystrokes works because
    # each `read` in menu.sh consumes one line in order.
    TEST_TTY="$(mktemp)"
    export _MENU_TTY="$TEST_TTY"
}

teardown() {
    rm -f "$TEST_TTY"
}

# Write simulated keystrokes as a raw byte stream (no newlines).
# read -n1 consumes exactly one byte per call, so separators are not needed.
_type() {
    printf '%s' "$@" > "$TEST_TTY"
}

# Build an array of N options: "Option 1" … "Option N"
# Compatible with bash 3.2 (no nameref).
_make_options() {
    local n=$1 arr_name=$2 i
    eval "${arr_name}=()"
    for (( i = 1; i <= n; i++ )); do
        eval "${arr_name}+=(\"Option $i\")"
    done
}

# ── no options → error ────────────────────────────────────────────────────────

@test "menu.sh exits 1 when no options are provided" {
    run --separate-stderr bash "$MENU_SH" "Pick one"
    [ "$status" -eq 1 ]
}

@test "menu.sh prints error to stderr when no options are provided" {
    run --separate-stderr bash "$MENU_SH" "Pick one"
    [[ "$stderr" == *"no menu options provided"* ]]
}

# ── argument modes ────────────────────────────────────────────────────────────

@test "menu.sh accepts prompt and options as arguments" {
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Choose" "Alpha" "Beta" "Gamma"
    [ "$status" -eq 0 ]
    [ "$output" = "Alpha" ]
}

@test "menu.sh reads options from stdin when given one argument" {
    _type '2'
    run --separate-stderr bash "$MENU_SH" "Choose" <<< $'Alpha\nBeta\nGamma'
    [ "$status" -eq 0 ]
    [ "$output" = "Beta" ]
}

@test "menu.sh reads prompt and options from stdin when given no arguments" {
    _type '3'
    run --separate-stderr bash "$MENU_SH" <<< $'Choose\nAlpha\nBeta\nGamma'
    [ "$status" -eq 0 ]
    [ "$output" = "Gamma" ]
}

@test "menu.sh skips blank lines when reading options from stdin" {
    _type '2'
    run --separate-stderr bash "$MENU_SH" "Choose" <<< $'Alpha\n\nBeta\n\nGamma'
    [ "$status" -eq 0 ]
    [ "$output" = "Beta" ]
}

# ── stdout / stderr routing ───────────────────────────────────────────────────

@test "menu.sh prints the chosen option text to stdout" {
    _type '2'
    run --separate-stderr bash "$MENU_SH" "Pick" "Apple" "Banana" "Cherry"
    [ "$output" = "Banana" ]
}

@test "menu.sh echoes the chosen option to stderr" {
    _type '2'
    run --separate-stderr bash "$MENU_SH" "Pick" "Apple" "Banana" "Cherry"
    [[ "$stderr" == *"Banana"* ]]
}

@test "menu.sh prints nothing extra to stdout" {
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "Apple" "Banana"
    [ "$output" = "Apple" ]
}

# ── option rows on stderr ─────────────────────────────────────────────────────

@test "menu.sh prints all option rows to stderr" {
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "Apple" "Banana" "Cherry"
    [[ "$stderr" == *"(1) Apple"* ]]
    [[ "$stderr" == *"(2) Banana"* ]]
    [[ "$stderr" == *"(3) Cherry"* ]]
}

@test "menu.sh assigns selector 'a' to the tenth option" {
    _make_options 10 opts
    _type 'a'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "Option 10" ]
    [[ "$stderr" == *"(a) Option 10"* ]]
}

# ── prompt format ─────────────────────────────────────────────────────────────

@test "menu.sh includes prompt text in stderr output" {
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Select a fruit" "Apple" "Banana"
    [[ "$stderr" == *"Select a fruit"* ]]
}

@test "menu.sh shows single selector in brackets for one option" {
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "Only"
    [[ "$stderr" == *"[1]"* ]]
}

@test "menu.sh shows selector range in brackets for multiple options" {
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "A" "B" "C"
    [[ "$stderr" == *"[1-3]"* ]]
}

@test "menu.sh prompt ends with a colon" {
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "A" "B"
    [[ "$stderr" == *":"* ]]
}

# ── selectors ─────────────────────────────────────────────────────────────────

@test "menu.sh selector '1' picks the first option" {
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "First" "Second" "Third"
    [ "$output" = "First" ]
}

@test "menu.sh selector '9' picks the ninth option" {
    _make_options 9 opts
    _type '9'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [ "$output" = "Option 9" ]
}

@test "menu.sh selector 'z' picks the 35th option" {
    _make_options 35 opts
    _type 'z'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [ "$output" = "Option 35" ]
}

# ── invalid input and retry ───────────────────────────────────────────────────

@test "menu.sh reports invalid selector on stderr" {
    _type 'X' '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "Alpha" "Beta"
    [[ "$stderr" == *"Invalid selection"* ]]
}

@test "menu.sh retries after invalid selector" {
    _type 'X' '2'
    run --separate-stderr bash "$MENU_SH" "Pick" "Alpha" "Beta"
    [ "$status" -eq 0 ]
    [ "$output" = "Beta" ]
}

# ── pagination threshold ──────────────────────────────────────────────────────

@test "menu.sh does not paginate with exactly 36 options" {
    _make_options 36 opts
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [[ "$stderr" != *"(>) Next"* ]]
}

@test "menu.sh paginates when options exceed 36" {
    _make_options 37 opts
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [[ "$stderr" == *"(>) Next"* ]]
}

# ── pagination display ────────────────────────────────────────────────────────

@test "menu.sh shows 30 options on the first page" {
    _make_options 37 opts
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [[ "$stderr" == *"(1) Option 1"* ]]
    [[ "$stderr" == *"Option 30"* ]]
    [[ "$stderr" != *"Option 31"* ]]
}

@test "menu.sh does not show Previous on the first page" {
    _make_options 37 opts
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [[ "$stderr" != *"(<) Previous"* ]]
}

@test "menu.sh includes next-page hint in prompt range on first page" {
    _make_options 37 opts
    _type '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [[ "$stderr" == *",>"* ]]
}

# ── pagination navigation ─────────────────────────────────────────────────────

@test "menu.sh navigates to next page with '>'" {
    _make_options 37 opts
    _type '>' '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "Option 31" ]
}

@test "menu.sh shows Previous on page 2" {
    _make_options 37 opts
    _type '>' '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [[ "$stderr" == *"(<) Previous"* ]]
}

@test "menu.sh navigates back to previous page with '<'" {
    _make_options 37 opts
    # Go forward, then back, then select option 1 (= Option 1 on page 1)
    _type '>' '<' '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "Option 1" ]
}

@test "menu.sh prompt omits next hint on the last page" {
    _make_options 37 opts
    _type '>' '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    # stderr accumulates from all pages; page-1 prompt contains ",>" once.
    # Strip everything up to and including the first ",>" — the remainder
    # (page-2 output) must not contain a second ",>".
    local after_first="${stderr#*,>}"
    [[ "$after_first" != *",>"* ]]
}

@test "menu.sh selector range resets to '1' on each page" {
    _make_options 37 opts
    _type '>' '1'
    run --separate-stderr bash "$MENU_SH" "Pick" "${opts[@]}"
    [[ "$stderr" == *"[1-"* ]]
}
