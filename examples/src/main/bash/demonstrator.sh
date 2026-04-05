#!/usr/bin/env bash
# =============================================================================
# demonstrator.sh — HALDiSh example launcher
#
# Locates the library installed by `./gradlew :examples:installHaldish`,
# sets up the environment, and lets the user choose an example to run.
#
# Usage:
#   bash examples/src/main/bash/demonstrator.sh   (from the repository root)
#   bash demonstrator.sh                          (from the examples/src/main/bash/ directory)
# =============================================================================
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "${_SELF_DIR}/../../../.." && pwd)"

# Ignore any inherited HAL_LIB_DIR — demonstrator always uses its own install.
unset HAL_LIB_DIR
_LIB_DIR="${_SELF_DIR}/../../../build/haldish"
_EXAMPLES_DIR="${_SELF_DIR}"

# ── auto-install ───────────────────────────────────────────────────────────────

if [[ ! -f "${_LIB_DIR}/env.sh" ]]; then
    printf 'demonstrator.sh: HALDiSh library not found — running installHaldish…\n'
    if [[ ! -f "${_ROOT_DIR}/gradlew" ]]; then
        printf 'demonstrator.sh: gradlew not found at: %s\n' "$_ROOT_DIR" >&2
        exit 1
    fi
    "${_ROOT_DIR}/gradlew" --project-dir "$_ROOT_DIR" :examples:installHaldish || {
        printf 'demonstrator.sh: installHaldish failed.\n' >&2
        exit 1
    }
fi

# ── environment setup ─────────────────────────────────────────────────────────

export HAL_LIB_DIR="$_LIB_DIR"
source "${_LIB_DIR}/env.sh"

# ── example selection ─────────────────────────────────────────────────────────

# Collect example scripts (excluding this script itself), using their basename
# (without .sh) as menu labels
declare -a _scripts=() _labels=()
while IFS= read -r -d '' f; do
    [[ "$(basename "$f")" == "demonstrator.sh" ]] && continue
    _scripts+=("$f")
    _labels+=("$(basename "$f" .sh)")
done < <(find "$_EXAMPLES_DIR" -maxdepth 1 -name '*.sh' -print0 | sort -z)

if [[ ${#_scripts[@]} -eq 0 ]]; then
    hal::log::error "No example scripts found in: ${_EXAMPLES_DIR}"
    exit 1
fi

_labels+=("quit")

# ── run loop ───────────────────────────────────────────────────────────────────

while true; do
    chosen=$(printf '%s\n' "${_labels[@]}" | menu.sh "Choose an example")

    [[ "$chosen" == "quit" ]] && { hal::log::ok "Bye!"; exit 0; }

    # Resolve chosen label back to script path
    _script=''
    for i in "${!_labels[@]}"; do
        if [[ "${_labels[$i]}" == "$chosen" ]]; then
            _script="${_scripts[$i]}"
            break
        fi
    done

    hal::log::info "Running: ${chosen}"
    printf '\n'
    bash "$_script"
    printf '\n'
done
