#!/usr/bin/env bash
# =============================================================================
# demo_link_plugin.sh — start a nahal.sh session with a link-prefixing plugin
#
# Takes a start URL, reports whether any HAL link plugins are already configured
# (HAL_LINK_PLUGIN), and — when none are — configures halprepend.sh to prefix
# every followed link's href with the provided URL.  This lets an API whose
# responses carry relative hrefs (e.g. "/users/1") be navigated as if they were
# absolute.  Then it launches the interactive browser on that URL.
#
# A plugin already present in HAL_LINK_PLUGIN is reported and left untouched.
#
# Usage:
#   bash demo_link_plugin.sh <url>
#
# Run after installing the archive:
#   bash HALDiSh-<version>.run --prefix ~/.local/lib/haldish
#   bash demo_link_plugin.sh https://api.example.com
# =============================================================================
set -euo pipefail

# ── load the library ──────────────────────────────────────────────────────────
# env.sh prepends the library directory to PATH, so nahal.sh, halprepend.sh and
# the hal::log::* helpers are all available by name afterwards.  The library is
# resolved relative to this script — the haldish install lives in build/haldish,
# three levels up from src/main/bash.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../../../build/haldish" && pwd)"
source "${LIB_DIR}/env.sh"

# ── arguments ─────────────────────────────────────────────────────────────────
if [[ $# -ne 1 || -z "$1" ]]; then
    printf 'Usage: %s <url>\n' "$(basename "$0")" >&2
    exit 1
fi
URL="$1"

# ── check for configured link plugins, and report ────────────────────────────
if [[ -n "${HAL_LINK_PLUGIN:-}" ]]; then
    hal::log::info "Link plugins already configured (HAL_LINK_PLUGIN): ${HAL_LINK_PLUGIN}"
else
    # Configure halprepend.sh to prepend the provided URL to every link href.
    export HAL_LINK_PLUGIN='halprepend.sh'
    export HAL_PREPEND_BASE="$URL"
    # Report the resulting plugin configuration before continuing.
    hal::log::info "No link plugins were configured. Starting with: HAL_LINK_PLUGIN=${HAL_LINK_PLUGIN}  HAL_PREPEND_BASE=${HAL_PREPEND_BASE}"
fi

# ── start the interactive browser ─────────────────────────────────────────────
exec nahal.sh "$URL"
