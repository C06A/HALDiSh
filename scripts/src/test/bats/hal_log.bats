#!/usr/bin/env bats
# =============================================================================
# hal_log.bats — unit tests for hal::log::* functions
# =============================================================================

load 'test_helper'

setup() {
    load_lib hal_utils.sh
    # Ensure a clean default level for each test (INFO = 3)
    HAL_LOG_LEVEL=info
    hal::log::init
}

# ── label format ──────────────────────────────────────────────────────────────

@test "hal::log::trace output contains [TRC ] label" {
    HAL_LOG_LEVEL=trace; hal::log::init
    run hal::log::trace "msg"
    [[ "$output" == *"[TRC ]"* ]]
}

@test "hal::log::debug output contains [DBG ] label" {
    HAL_LOG_LEVEL=debug; hal::log::init
    run hal::log::debug "msg"
    [[ "$output" == *"[DBG ]"* ]]
}

@test "hal::log::info output contains [INFO] label" {
    run hal::log::info "msg"
    [[ "$output" == *"[INFO]"* ]]
}

@test "hal::log::ok output contains [ OK ] label" {
    run hal::log::ok "msg"
    [[ "$output" == *"[ OK ]"* ]]
}

@test "hal::log::warn output contains [WARN] label" {
    run hal::log::warn "msg"
    [[ "$output" == *"[WARN]"* ]]
}

@test "hal::log::error output contains [ERR ] label" {
    run hal::log::error "msg"
    [[ "$output" == *"[ERR ]"* ]]
}

# ── message text ──────────────────────────────────────────────────────────────

@test "hal::log::info includes the message text" {
    run hal::log::info "hello world"
    [[ "$output" == *"hello world"* ]]
}

@test "hal::log::warn includes the message text" {
    run hal::log::warn "something wrong"
    [[ "$output" == *"something wrong"* ]]
}

@test "hal::log::error includes the message text" {
    run hal::log::error "fatal issue"
    [[ "$output" == *"fatal issue"* ]]
}

# ── default level: info (3) ───────────────────────────────────────────────────

@test "trace is suppressed at default level" {
    run hal::log::trace "msg"
    [ -z "$output" ]
}

@test "debug is suppressed at default level" {
    run hal::log::debug "msg"
    [ -z "$output" ]
}

@test "info is shown at default level" {
    run hal::log::info "msg"
    [ -n "$output" ]
}

@test "ok is shown at default level" {
    run hal::log::ok "msg"
    [ -n "$output" ]
}

@test "warn is shown at default level" {
    run hal::log::warn "msg"
    [ -n "$output" ]
}

@test "error is shown at default level" {
    run hal::log::error "msg"
    [ -n "$output" ]
}

# ── level: off (0) ────────────────────────────────────────────────────────────

@test "error is suppressed at off level" {
    HAL_LOG_LEVEL=off; hal::log::init
    run hal::log::error "msg"
    [ -z "$output" ]
}

@test "warn is suppressed at off level" {
    HAL_LOG_LEVEL=off; hal::log::init
    run hal::log::warn "msg"
    [ -z "$output" ]
}

@test "info is suppressed at off level" {
    HAL_LOG_LEVEL=off; hal::log::init
    run hal::log::info "msg"
    [ -z "$output" ]
}

# ── level: error (1) ─────────────────────────────────────────────────────────

@test "error is shown at error level" {
    HAL_LOG_LEVEL=error; hal::log::init
    run hal::log::error "msg"
    [ -n "$output" ]
}

@test "warn is suppressed at error level" {
    HAL_LOG_LEVEL=error; hal::log::init
    run hal::log::warn "msg"
    [ -z "$output" ]
}

@test "info is suppressed at error level" {
    HAL_LOG_LEVEL=error; hal::log::init
    run hal::log::info "msg"
    [ -z "$output" ]
}

# ── level: warn (2) ──────────────────────────────────────────────────────────

@test "warn is shown at warn level" {
    HAL_LOG_LEVEL=warn; hal::log::init
    run hal::log::warn "msg"
    [ -n "$output" ]
}

@test "error is shown at warn level" {
    HAL_LOG_LEVEL=warn; hal::log::init
    run hal::log::error "msg"
    [ -n "$output" ]
}

@test "info is suppressed at warn level" {
    HAL_LOG_LEVEL=warn; hal::log::init
    run hal::log::info "msg"
    [ -z "$output" ]
}

@test "ok is suppressed at warn level" {
    HAL_LOG_LEVEL=warn; hal::log::init
    run hal::log::ok "msg"
    [ -z "$output" ]
}

# ── level: debug (4) ─────────────────────────────────────────────────────────

@test "debug is shown at debug level" {
    HAL_LOG_LEVEL=debug; hal::log::init
    run hal::log::debug "msg"
    [ -n "$output" ]
}

@test "info is shown at debug level" {
    HAL_LOG_LEVEL=debug; hal::log::init
    run hal::log::info "msg"
    [ -n "$output" ]
}

@test "trace is suppressed at debug level" {
    HAL_LOG_LEVEL=debug; hal::log::init
    run hal::log::trace "msg"
    [ -z "$output" ]
}

# ── level: trace (5) ─────────────────────────────────────────────────────────

@test "trace is shown at trace level" {
    HAL_LOG_LEVEL=trace; hal::log::init
    run hal::log::trace "msg"
    [ -n "$output" ]
}

@test "debug is shown at trace level" {
    HAL_LOG_LEVEL=trace; hal::log::init
    run hal::log::debug "msg"
    [ -n "$output" ]
}

@test "info is shown at trace level" {
    HAL_LOG_LEVEL=trace; hal::log::init
    run hal::log::info "msg"
    [ -n "$output" ]
}

# ── numeric aliases ───────────────────────────────────────────────────────────

@test "HAL_LOG_LEVEL=0 silences all output" {
    HAL_LOG_LEVEL=0; hal::log::init
    run hal::log::error "msg"
    [ -z "$output" ]
}

@test "HAL_LOG_LEVEL=1 shows error and suppresses warn" {
    HAL_LOG_LEVEL=1; hal::log::init
    run hal::log::error "msg"
    [ -n "$output" ]
    run hal::log::warn "msg"
    [ -z "$output" ]
}

@test "HAL_LOG_LEVEL=2 shows warn and suppresses info" {
    HAL_LOG_LEVEL=2; hal::log::init
    run hal::log::warn "msg"
    [ -n "$output" ]
    run hal::log::info "msg"
    [ -z "$output" ]
}

@test "HAL_LOG_LEVEL=3 shows info and suppresses debug" {
    HAL_LOG_LEVEL=3; hal::log::init
    run hal::log::info "msg"
    [ -n "$output" ]
    run hal::log::debug "msg"
    [ -z "$output" ]
}

@test "HAL_LOG_LEVEL=4 shows debug and suppresses trace" {
    HAL_LOG_LEVEL=4; hal::log::init
    run hal::log::debug "msg"
    [ -n "$output" ]
    run hal::log::trace "msg"
    [ -z "$output" ]
}

@test "HAL_LOG_LEVEL=5 shows trace" {
    HAL_LOG_LEVEL=5; hal::log::init
    run hal::log::trace "msg"
    [ -n "$output" ]
}

# ── case-insensitive level names ──────────────────────────────────────────────

@test "HAL_LOG_LEVEL=ERROR (uppercase) behaves as error level" {
    HAL_LOG_LEVEL=ERROR; hal::log::init
    run hal::log::error "msg"
    [ -n "$output" ]
    run hal::log::warn "msg"
    [ -z "$output" ]
}

@test "HAL_LOG_LEVEL=WARN (uppercase) behaves as warn level" {
    HAL_LOG_LEVEL=WARN; hal::log::init
    run hal::log::warn "msg"
    [ -n "$output" ]
    run hal::log::info "msg"
    [ -z "$output" ]
}

@test "HAL_LOG_LEVEL=INFO (uppercase) behaves as info level" {
    HAL_LOG_LEVEL=INFO; hal::log::init
    run hal::log::info "msg"
    [ -n "$output" ]
    run hal::log::debug "msg"
    [ -z "$output" ]
}

# ── prefix aliases (warning, err) ─────────────────────────────────────────────

@test "HAL_LOG_LEVEL=warning is accepted as warn" {
    HAL_LOG_LEVEL=warning; hal::log::init
    run hal::log::warn "msg"
    [ -n "$output" ]
    run hal::log::info "msg"
    [ -z "$output" ]
}

@test "HAL_LOG_LEVEL=err is accepted as error" {
    HAL_LOG_LEVEL=err; hal::log::init
    run hal::log::error "msg"
    [ -n "$output" ]
    run hal::log::warn "msg"
    [ -z "$output" ]
}

# ── unknown level defaults to info ────────────────────────────────────────────

@test "unknown HAL_LOG_LEVEL defaults to info" {
    HAL_LOG_LEVEL=bogus; hal::log::init
    run hal::log::info "msg"
    [ -n "$output" ]
    run hal::log::debug "msg"
    [ -z "$output" ]
}

# ── hal::log::die ─────────────────────────────────────────────────────────────

@test "hal::log::die exits with status 1 by default" {
    run hal::log::die "fatal"
    [ "$status" -eq 1 ]
}

@test "hal::log::die exits with custom status code" {
    run hal::log::die "fatal" 42
    [ "$status" -eq 42 ]
}

@test "hal::log::die includes the message in output" {
    run hal::log::die "something bad happened"
    [[ "$output" == *"something bad happened"* ]]
}

@test "hal::log::die always prints even at off level" {
    HAL_LOG_LEVEL=off; hal::log::init
    run hal::log::die "fatal"
    [ -n "$output" ]
}

# ── hal::log::init ────────────────────────────────────────────────────────────

@test "hal::log::init picks up a changed HAL_LOG_LEVEL" {
    HAL_LOG_LEVEL=error; hal::log::init
    run hal::log::info "should be hidden"
    [ -z "$output" ]

    HAL_LOG_LEVEL=info; hal::log::init
    run hal::log::info "should be visible"
    [ -n "$output" ]
}

@test "hal::log::init accepts level as argument" {
    hal::log::init error
    run hal::log::info "should be hidden"
    [ -z "$output" ]
    run hal::log::error "should be visible"
    [ -n "$output" ]
}

@test "hal::log::init argument takes precedence over HAL_LOG_LEVEL" {
    HAL_LOG_LEVEL=trace; hal::log::init error
    run hal::log::debug "should be hidden"
    [ -z "$output" ]
}

@test "hal::log::init falls back to HAL_LOG_LEVEL when no argument given" {
    HAL_LOG_LEVEL=error; hal::log::init
    run hal::log::warn "should be hidden"
    [ -z "$output" ]
}
