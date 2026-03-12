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
for f in hal_utils.sh env.sh validate.sh; do
    if [[ -f "${HAL_PREFIX}/${f}" ]]; then
        _ok  "Found ${f}"
    else
        _warn "Missing ${f}"
        (( missing++ )) || true
    fi
done

# httpreq.sh may already have been renamed to .httpreq.sh on a prior setup run
if [[ -f "${HAL_PREFIX}/httpreq.sh" || -f "${HAL_PREFIX}/.httpreq.sh" ]]; then
    _ok  "Found httpreq.sh"
else
    _warn "Missing httpreq.sh"
    (( missing++ )) || true
fi

(( missing > 0 )) && { _warn "Installation incomplete — ${missing} file(s) missing."; exit 1; }

# ── hide implementation and create method hardlinks ───────────────────────────
# Rename httpreq.sh → .httpreq.sh so method names (GET, POST, …) are the
# only public entry points.  Uses hardlinks so each name shares content with
# the hidden file; validate.sh checksums all of them independently.
if [[ -f "${HAL_PREFIX}/httpreq.sh" ]]; then
    _info "Renaming httpreq.sh → .httpreq.sh…"
    mv "${HAL_PREFIX}/httpreq.sh" "${HAL_PREFIX}/.httpreq.sh"
fi
_info "Creating method hardlinks…"
for _m in GET POST PUT PATCH OPTIONS DELETE; do
    ln -f "${HAL_PREFIX}/.httpreq.sh" "${HAL_PREFIX}/${_m}"
    _ok  "  ${_m} → .httpreq.sh"
done

# ── integrity manifest ────────────────────────────────────────────────────────
_info "Generating integrity manifest…"
manifest="${HAL_PREFIX}/.hal_manifest"
(
    cd "${HAL_PREFIX}"
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
) > "${manifest}"
_ok "Manifest written ($(wc -l < "${manifest}" | tr -d ' ') files checksummed)."

# ── usage hint ───────────────────────────────────────────────────────────────
_ok  "Installation complete."
printf '\n'
_info "To use the library, source the activation script from your script or session:"
printf '\n'
printf '  source "%s/env.sh"\n' "${HAL_PREFIX}"
printf '\n'
