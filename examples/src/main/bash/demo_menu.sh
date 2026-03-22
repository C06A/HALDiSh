#!/usr/bin/env bash
# =============================================================================
# demo_menu.sh — demonstrates the three invocation styles of menu.sh
#
# Run after installing the archive:
#   bash HALDiSh-0.1.0.run --prefix ~/mylibs
#   bash demo_menu.sh
# =============================================================================
set -euo pipefail

# ── load the library (also adds the install dir to PATH) ─────────────────────
LIB_DIR="${HAL_LIB_DIR:-${HOME}/.local/lib/haldish}"
source "${LIB_DIR}/env.sh"

# After sourcing env.sh, menu.sh is on PATH and can be called by name.

# ── style 1: prompt + options as arguments ───────────────────────────────────
hal::log::info "Style 1 — all arguments"
hal::log::info "  menu.sh <prompt> <option>..."

color=$(menu.sh "Pick a color" Red Green Blue Yellow)
hal::log::ok "You chose: ${color}"

echo

# ── style 2: prompt as argument, options from stdin ──────────────────────────
hal::log::info "Style 2 — prompt as argument, options piped via stdin"
hal::log::info "  printf '...' | menu.sh <prompt>"

method=$(printf 'GET\nPOST\nPUT\nPATCH\nDELETE\n' \
    | menu.sh "Select HTTP method")
hal::log::ok "You chose: ${method}"

echo

# ── style 3: prompt and options entirely from stdin ──────────────────────────
hal::log::info "Style 3 — prompt and options both from stdin (no arguments)"
hal::log::info "  printf '<prompt>\\n<opt1>\\n...' | menu.sh"

target_env=$(printf 'Target environment:\ndevelopment\nstaging\nproduction\n' \
    | menu.sh)
hal::log::ok "You chose: ${target_env}"

echo

# ── capturing the result for branching ───────────────────────────────────────
hal::log::info "Practical use — branch on the selected option"

action=$(menu.sh "What would you like to do?" \
    "Show disk usage" \
    "List running processes" \
    "Print current directory")

case "$action" in
    "Show disk usage")         df -h ;;
    "List running processes")  ps aux | head -10 ;;
    "Print current directory") pwd ;;
esac
