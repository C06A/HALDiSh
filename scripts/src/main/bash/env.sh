#!/usr/bin/env bash
# =============================================================================
# env.sh — HALDiSh environment activation
#
# Source this file from any script or shell session to load the library:
#
#   source /path/to/haldish/env.sh
#
# After sourcing, all hal::* functions are available and HAL_LIB_DIR is set.
# =============================================================================

# Resolve the directory containing this file, regardless of where it is sourced
# from or how the containing script was invoked.
_hal_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export HAL_LIB_DIR="${_hal_env_dir}"

# shellcheck source=hal_utils.sh
source "${HAL_LIB_DIR}/hal_utils.sh"

unset _hal_env_dir
