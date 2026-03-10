#!/usr/bin/env bats
# =============================================================================
# setup.bats — unit tests for setup.sh
# =============================================================================

load 'test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cp "${SCRIPTS_DIR}"/*.sh "${TEST_DIR}/"
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# ── exit status ───────────────────────────────────────────────────────────────

@test "setup.sh exits 0 when all files are present" {
    run bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    [ "$status" -eq 0 ]
}

@test "setup.sh exits 1 when hal_utils.sh is missing" {
    rm "${TEST_DIR}/hal_utils.sh"
    run bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    [ "$status" -eq 1 ]
}

@test "setup.sh exits 1 when env.sh is missing" {
    rm "${TEST_DIR}/env.sh"
    run bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    [ "$status" -eq 1 ]
}

@test "setup.sh exits 1 when validate.sh is missing" {
    rm "${TEST_DIR}/validate.sh"
    run bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    [ "$status" -eq 1 ]
}

# ── manifest generation ───────────────────────────────────────────────────────

@test "setup.sh creates .hal_manifest" {
    bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    [ -f "${TEST_DIR}/.hal_manifest" ]
}

@test "setup.sh manifest is non-empty" {
    bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    [ -s "${TEST_DIR}/.hal_manifest" ]
}

@test "setup.sh manifest contains an entry for every .sh file" {
    bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    while IFS= read -r f; do
        fname="$(basename "$f")"
        grep -q "$fname" "${TEST_DIR}/.hal_manifest"
    done < <(find "${TEST_DIR}" -name "*.sh")
}

@test "setup.sh manifest passes subsequent validate.sh check" {
    bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 0 ]
}

@test "setup.sh does not create manifest when files are missing" {
    rm "${TEST_DIR}/validate.sh"
    run bash "${TEST_DIR}/setup.sh" "${TEST_DIR}"
    [ ! -f "${TEST_DIR}/.hal_manifest" ]
}
