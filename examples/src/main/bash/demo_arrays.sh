#!/usr/bin/env bash
# =============================================================================
# demo_arrays.sh — demonstrates hal::arr::* helpers from hal_utils.sh
# =============================================================================
set -euo pipefail

LIB_DIR="${HAL_LIB_DIR:-${HOME}/.local/lib/haldish}"
source "${LIB_DIR}/hal_utils.sh"

hal::log::info "=== hal::arr demos ==="

# ── contains ──────────────────────────────────────────────────────────────────
fruits=("apple" "banana" "cherry" "date")

hal::log::info "Array: ${fruits[*]}"

for item in "banana" "grape"; do
    if hal::arr::contains "$item" "${fruits[@]}"; then
        hal::log::ok  "'${item}' is in the array"
    else
        hal::log::warn "'${item}' is NOT in the array"
    fi
done

# ── join ──────────────────────────────────────────────────────────────────────
joined=$(hal::arr::join " | " "${fruits[@]}")
hal::log::ok "join with ' | ': ${joined}"

csv=$(hal::arr::join "," "${fruits[@]}")
hal::log::ok "join as CSV: ${csv}"

# ── practical: build a PATH-style variable ────────────────────────────────────
dirs=("/usr/bin" "/usr/local/bin" "${HOME}/.local/bin")
custom_path=$(hal::arr::join ":" "${dirs[@]}")
hal::log::ok "custom PATH: ${custom_path}"
