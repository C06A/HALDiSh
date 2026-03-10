#!/usr/bin/env bash
# =============================================================================
# demo_filesystem.sh — demonstrates hal::fs::* helpers from hal_utils.sh
# =============================================================================
set -euo pipefail

LIB_DIR="${HAL_LIB_DIR:-${HOME}/.local/lib/haldish}"
source "${LIB_DIR}/hal_utils.sh"

hal::log::info "=== hal::fs demos ==="

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── mkdir_p ───────────────────────────────────────────────────────────────────
hal::fs::mkdir_p "${WORK_DIR}/a/b/c"
hal::log::ok "mkdir_p created nested dirs: ${WORK_DIR}/a/b/c"

# ── is_dir / is_file / exists ─────────────────────────────────────────────────
if hal::fs::is_dir "${WORK_DIR}/a/b/c"; then
    hal::log::ok "is_dir: ${WORK_DIR}/a/b/c → true"
fi

touch "${WORK_DIR}/hello.txt"
if hal::fs::is_file "${WORK_DIR}/hello.txt"; then
    hal::log::ok "is_file: hello.txt → true"
fi

if ! hal::fs::exists "${WORK_DIR}/ghost"; then
    hal::log::warn "exists: ghost → false (expected)"
fi

# ── extension / basename_no_ext ───────────────────────────────────────────────
files=("report.pdf" "archive.tar.gz" "Makefile" "deploy.sh")
hal::log::info "File name analysis:"
for f in "${files[@]}"; do
    ext=$(hal::fs::extension "$f")
    base=$(hal::fs::basename_no_ext "$f")
    printf '  %-20s  base=%-15s  ext=%s\n' "$f" "$base" "${ext:-<none>}"
done

hal::log::ok "Done."
