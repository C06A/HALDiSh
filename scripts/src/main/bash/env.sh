#!/usr/bin/env bash
# =============================================================================
# env.sh — HALDiSh environment activation
#
# Source this file from any script or shell session to load the library:
#
#   source /path/to/haldish/env.sh
#
# Validates installation integrity before setting any environment variables.
# Aborts with a non-zero return code if any file has been modified.
#
# After sourcing successfully, all hal::* functions are available and
# HAL_LIB_DIR is set.
# =============================================================================

# Resolve the directory containing this file, regardless of where it is sourced
# from or how the containing script was invoked.
_hal_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── integrity check (runs as subprocess so it can use exit freely) ────────────
if ! bash "${_hal_env_dir}/validate.sh"; then
    unset _hal_env_dir
    return 1
fi

export HAL_LIB_DIR="${_hal_env_dir}"

# shellcheck source=hal_utils.sh
source "${HAL_LIB_DIR}/hal_utils.sh"

# Add the library directory to PATH so scripts (e.g. menu.sh) can be invoked
# by name without a full path. Avoid duplicating the entry if already present.
case ":${PATH}:" in
    *":${HAL_LIB_DIR}:"*) ;;
    *) export PATH="${HAL_LIB_DIR}:${PATH}" ;;
esac

unset _hal_env_dir
