#!/usr/bin/env bash
# =============================================================================
# HALDiSh post-install setup script
#
# Executed automatically by the self-inflatable archive after extraction.
# May also be run manually:   bash <prefix>/setup.sh [--prefix <dir>]
# =============================================================================
set -euo pipefail

HAL_PREFIX="${1:-${HOME}/.local/lib/haldish}"

_info()  { printf '\033[1;34m[HALDiSh]\033[0m %s\n' "$*"; }
_ok()    { printf '\033[1;32m[HALDiSh]\033[0m %s\n' "$*"; }
_warn()  { printf '\033[1;33m[HALDiSh]\033[0m %s\n' "$*" >&2; }

# ── bash version check ────────────────────────────────────────────────────────
_info "Checking bash version…"
bash_major="${BASH_VERSINFO[0]:-0}"
if (( bash_major < 4 )); then
    _warn "bash 4+ is required (found ${BASH_VERSION}). Some features may not work."
else
    _ok  "bash ${BASH_VERSION} — OK"
fi

# ── verify key files are present ─────────────────────────────────────────────
_info "Verifying installation in: ${HAL_PREFIX}"
missing=0
for f in hal_utils.sh; do
    if [[ -f "${HAL_PREFIX}/${f}" ]]; then
        _ok  "Found ${f}"
    else
        _warn "Missing ${f}"
        (( missing++ )) || true
    fi
done

(( missing > 0 )) && { _warn "Installation incomplete — ${missing} file(s) missing."; exit 1; }

# ── shell profile hint ────────────────────────────────────────────────────────
_ok  "Installation complete."
printf '\n'
_info "To use the library, add this to your shell profile (~/.bashrc / ~/.zshrc):"
printf '\n'
printf '  export HAL_LIB_DIR="%s"\n' "${HAL_PREFIX}"
printf '  source "%s/hal_utils.sh"\n' "${HAL_PREFIX}"
printf '\n'
