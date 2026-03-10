#!/usr/bin/env bash
# =============================================================================
# validate.sh — HALDiSh installation integrity check
#
# Verifies that no files in the installation directory have been modified
# since setup.sh generated the manifest.
#
# Usage (standalone):  bash <prefix>/validate.sh
# Called by env.sh automatically before loading the library.
#
# Exit codes:  0 — all files intact
#              1 — one or more files modified or manifest missing
# =============================================================================
set -euo pipefail

_HAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HAL_MANIFEST="${_HAL_DIR}/.hal_manifest"

_err() { printf '\033[1;31m[HALDiSh]\033[0m %s\n' "$*" >&2; }
_ok()  { printf '\033[1;32m[HALDiSh]\033[0m %s\n' "$*"; }

# ── manifest presence ─────────────────────────────────────────────────────────
if [[ ! -f "${_HAL_MANIFEST}" ]]; then
    _err "Integrity manifest not found: ${_HAL_MANIFEST}"
    _err "Re-run setup.sh to regenerate it."
    exit 1
fi

# ── portable SHA-256 ──────────────────────────────────────────────────────────
_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

# ── verify every entry in the manifest ───────────────────────────────────────
fail=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    expected="${line%% *}"
    relpath="${line##*  }"   # shasum uses two spaces before path
    fullpath="${_HAL_DIR}/${relpath#./}"

    if [[ ! -f "${fullpath}" ]]; then
        _err "MISSING: ${relpath}"
        (( fail++ )) || true
        continue
    fi

    actual="$(_sha256 "${fullpath}")"
    if [[ "${actual}" != "${expected}" ]]; then
        _err "MODIFIED: ${relpath}"
        (( fail++ )) || true
    fi
done < "${_HAL_MANIFEST}"

# ── result ────────────────────────────────────────────────────────────────────
if (( fail > 0 )); then
    _err "${fail} file(s) failed integrity check. Aborting."
    exit 1
fi

_ok "Integrity check passed."
