#!/usr/bin/env bats
# =============================================================================
# validate.bats — unit tests for validate.sh
# =============================================================================

load 'test_helper'

# Populate a temp install dir via setup.sh to get the full post-install state:
# .httpreq.sh, method hardlinks, and a correct manifest.
setup() {
    TEST_DIR="$(mktemp -d)"
    cp "${SCRIPTS_DIR}"/*.sh "${TEST_DIR}/"
    bash "${TEST_DIR}/setup.sh" "${TEST_DIR}" >/dev/null 2>&1
}

teardown() {
    rm -rf "${TEST_DIR}"
}

# Helper: (re)generate the manifest the same way setup.sh does.
# Includes both *.sh files and the method-named hardlinks.
_make_manifest() {
    (
        cd "${TEST_DIR}"
        _files=()
        while IFS= read -r f; do _files+=("$f"); done < <(find . -name "*.sh" | sort)
        for _m in GET POST PUT PATCH OPTIONS DELETE; do
            [[ -f "./${_m}" ]] && _files+=("./${_m}")
        done
        if command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "${_files[@]}"
        else
            sha256sum "${_files[@]}"
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

# ── method hardlinks ──────────────────────────────────────────────────────────

@test "validate.sh exits 1 when a method hardlink is missing" {
    rm "${TEST_DIR}/GET"
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 1 ]
}

@test "validate.sh names the missing method in its output" {
    rm "${TEST_DIR}/POST"
    run bash "${TEST_DIR}/validate.sh"
    [[ "$output" =~ "POST" ]]
}

# ── re-run after regenerating manifest ───────────────────────────────────────

@test "validate.sh passes after manifest is regenerated for modified file" {
    echo "# new line" >> "${TEST_DIR}/hal_utils.sh"
    _make_manifest
    run bash "${TEST_DIR}/validate.sh"
    [ "$status" -eq 0 ]
}
