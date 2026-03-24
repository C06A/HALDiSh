#!/usr/bin/env bash
# =============================================================================
# env.sh — HALDiSh environment activation
#
# Source this file from any script or shell session to load the library:
#
#   source /path/to/haldish/env.sh
#
# After sourcing successfully, all hal::* functions are available and
# the library directory is prepended to PATH.
# =============================================================================

# ── guard: must be sourced ────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    printf 'env.sh: must be sourced, not executed directly.\n' >&2
    printf '  source %s\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi

# Resolve the directory containing this file, regardless of where it is sourced
# from or how the containing script was invoked.
_hal_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ── integrity check (runs as subprocess so it can use exit freely) ────────────
if ! bash "${_hal_env_dir}/validate.sh"; then
    unset _hal_env_dir
    return 1
fi

# shellcheck source=hal_utils.sh
source "${_hal_env_dir}/hal_utils.sh"

# Prepend the library directory to PATH so all scripts can be invoked by name.
# Avoid duplicating the entry if already present.
case ":${PATH}:" in
    *":${_hal_env_dir}:"*) ;;
    *) export PATH="${_hal_env_dir}:${PATH}" ;;
esac

unset _hal_env_dir
