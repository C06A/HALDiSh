#!/usr/bin/env bash
# =============================================================================
# demo_strings.sh — demonstrates hal::str::* helpers from hal_utils.sh
#
# Run after installing the archive:
#   bash HALDiSh-0.1.0.run --prefix ~/mylibs
#   bash demo_strings.sh
# =============================================================================
set -euo pipefail

# ── load the library ──────────────────────────────────────────────────────────
LIB_DIR="${HAL_LIB_DIR:-${HOME}/.local/lib/haldish}"
source "${LIB_DIR}/hal_utils.sh"

hal::log::info "=== hal::str demos ==="

# ── trim ──────────────────────────────────────────────────────────────────────
raw="   hello, world!   "
trimmed=$(hal::str::trim "$raw")
hal::log::ok "trim: '${raw}' → '${trimmed}'"

# ── case conversion ───────────────────────────────────────────────────────────
hal::log::ok "upper: $(hal::str::upper 'make me shout')"
hal::log::ok "lower: $(hal::str::lower 'QUIET DOWN PLEASE')"

# ── predicates ────────────────────────────────────────────────────────────────
sentence="The quick brown fox"

if hal::str::contains "$sentence" "brown"; then
    hal::log::ok "contains 'brown': yes"
fi

if hal::str::starts_with "$sentence" "The"; then
    hal::log::ok "starts_with 'The': yes"
fi

if hal::str::ends_with "$sentence" "fox"; then
    hal::log::ok "ends_with 'fox': yes"
fi

if ! hal::str::contains "$sentence" "cat"; then
    hal::log::warn "does not contain 'cat'"
fi

# ── repeat ────────────────────────────────────────────────────────────────────
hal::log::ok "repeat '-' x40: $(hal::str::repeat '-' 40)"

# ── length ────────────────────────────────────────────────────────────────────
word="banana"
hal::log::ok "length of '${word}': $(hal::str::length "$word")"
