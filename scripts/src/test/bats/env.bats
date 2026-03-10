#!/usr/bin/env bats
# =============================================================================
# env.bats — unit tests for env.sh
# =============================================================================

load 'test_helper'

# Each test gets a clean install dir with a valid manifest already in place.
setup() {
    TEST_DIR="$(mktemp -d)"
    cp "${SCRIPTS_DIR}"/*.sh "${TEST_DIR}/"
    bash "${TEST_DIR}/setup.sh" "${TEST_DIR}" >/dev/null 2>&1
}

teardown() {
    unset HAL_LIB_DIR
    rm -rf "${TEST_DIR}"
}

# ── successful activation ─────────────────────────────────────────────────────

@test "env.sh sets HAL_LIB_DIR to the install directory" {
    source "${TEST_DIR}/env.sh"
    [ "${HAL_LIB_DIR}" = "${TEST_DIR}" ]
}

@test "env.sh makes hal::str::* functions available" {
    source "${TEST_DIR}/env.sh"
    run hal::str::upper "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "HELLO" ]
}

@test "env.sh makes hal::arr::* functions available" {
    source "${TEST_DIR}/env.sh"
    arr=(a b c)
    run hal::arr::join "," "${arr[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "a,b,c" ]
}

@test "env.sh makes hal::fs::* functions available" {
    source "${TEST_DIR}/env.sh"
    run hal::fs::extension "archive.tar.gz"
    [ "$status" -eq 0 ]
    [ "$output" = "gz" ]
}

@test "env.sh cleans up its internal _hal_env_dir variable" {
    source "${TEST_DIR}/env.sh"
    [ -z "${_hal_env_dir+x}" ]
}

@test "env.sh adds the install directory to PATH" {
    source "${TEST_DIR}/env.sh"
    [[ ":${PATH}:" == *":${TEST_DIR}:"* ]]
}

@test "env.sh does not duplicate PATH entry when sourced twice" {
    source "${TEST_DIR}/env.sh"
    source "${TEST_DIR}/env.sh"
    count=$(tr ':' '\n' <<< "$PATH" | grep -cxF "${TEST_DIR}")
    [ "$count" -eq 1 ]
}

@test "env.sh allows scripts to be called by name after sourcing" {
    source "${TEST_DIR}/env.sh"
    run which menu.sh
    [ "$status" -eq 0 ]
}

# ── integrity gate ────────────────────────────────────────────────────────────

@test "env.sh returns 1 when a file has been modified" {
    echo "# tampered" >> "${TEST_DIR}/hal_utils.sh"
    run bash -c "source '${TEST_DIR}/env.sh'"
    [ "$status" -eq 1 ]
}

@test "env.sh does not set HAL_LIB_DIR when validation fails" {
    echo "# tampered" >> "${TEST_DIR}/hal_utils.sh"
    unset HAL_LIB_DIR
    # Source in a subshell; the parent HAL_LIB_DIR must stay unset
    bash -c "source '${TEST_DIR}/env.sh'; [ -z \"\${HAL_LIB_DIR+x}\" ]"
}

@test "env.sh returns 1 when manifest is missing" {
    rm "${TEST_DIR}/.hal_manifest"
    run bash -c "source '${TEST_DIR}/env.sh'"
    [ "$status" -eq 1 ]
}
