#!/usr/bin/env bats
# =============================================================================
# validate.bats — unit tests for validate.sh
# =============================================================================

load 'test_helper'

# Populate a temp install dir with all scripts and a freshly-generated manifest.
setup() {
    TEST_DIR="$(mktemp -d)"
    cp "${SCRIPTS_DIR}"/*.sh "${TEST_DIR}/"
    _make_manifest
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# Helper: (re)generate the manifest the same way setup.sh does.
_make_manifest() {
    (
        cd "${TEST_DIR}"
        if command -v shasum >/dev/null 2>&1; then
            find . -name "*.sh" | sort | xargs shasum -a 256
        else
            find . -name "*.sh" | sort | xargs sha256sum
        fi
    ) > "${TEST_DIR}/.hal_manifest"
}

# ── manifest presence ─────────────────────────────────────────────────────────

@test "validate.sh passes with an intact installation" {
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 0 ]
}

@test "validate.sh exits 1 when manifest is missing" {
    rm "${TEST_DIR}/.hal_manifest"
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 1 ]
}

@test "validate.sh reports manifest path when missing" {
    rm "${TEST_DIR}/.hal_manifest"
    run bash "${TEST_DIR}/validate.sh"
    [[ "$output" =~ ".hal_manifest" ]]
}

# ── modified file ─────────────────────────────────────────────────────────────

@test "validate.sh exits 1 when a file is modified" {
    echo "# tampered" >> "${TEST_DIR}/hal_utils.sh"
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 1 ]
}

@test "validate.sh names the modified file in its output" {
    echo "# tampered" >> "${TEST_DIR}/hal_utils.sh"
    run bash "${TEST_DIR}/validate.sh"
    [[ "$output" =~ "hal_utils.sh" ]]
}

@test "validate.sh counts multiple modified files correctly" {
    echo "# tampered" >> "${TEST_DIR}/hal_utils.sh"
    echo "# tampered" >> "${TEST_DIR}/env.sh"
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "2 file(s)" ]]
}

# ── missing file ──────────────────────────────────────────────────────────────

@test "validate.sh exits 1 when a tracked file is deleted" {
    rm "${TEST_DIR}/hal_utils.sh"
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 1 ]
}

@test "validate.sh names the missing file in its output" {
    rm "${TEST_DIR}/hal_utils.sh"
    run bash "${TEST_DIR}/validate.sh"
    [[ "$output" =~ "hal_utils.sh" ]]
}

# ── re-run after regenerating manifest ───────────────────────────────────────

@test "validate.sh passes after manifest is regenerated for modified file" {
    echo "# new line" >> "${TEST_DIR}/hal_utils.sh"
    _make_manifest
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 0 ]
}
