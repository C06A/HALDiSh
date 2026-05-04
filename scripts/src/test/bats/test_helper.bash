#!/usr/bin/env bash
# =============================================================================
# test_helper.bash — shared setup loaded by every .bats test file
# =============================================================================

# SCRIPTS_DIR is injected by Gradle; fall back to a relative path for manual
# runs from the repo root.
SCRIPTS_DIR="$(cd "${SCRIPTS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../../main/bash}" && pwd)"

load_lib() {
    source "${SCRIPTS_DIR}/${1}"
}
