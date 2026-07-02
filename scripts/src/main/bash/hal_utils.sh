#!/usr/bin/env bash
# =============================================================================
# hal_utils.sh — HALDiSh utility function library
#
# Source this file to load all utility namespaces:
#   source /path/to/hal_utils.sh
#
# Namespaces
#   hal::str::*   — string helpers
#   hal::arr::*   — array helpers
#   hal::fs::*    — filesystem helpers
#   hal::log::*   — colourised logging
# =============================================================================
set -euo pipefail

# Prevent double-sourcing
[[ -n "${_HAL_UTILS_LOADED:-}" ]] && return 0
readonly _HAL_UTILS_LOADED=1

# ── hal::str ──────────────────────────────────────────────────────────────────

# hal::str::trim <string>
# Prints the string with leading and trailing whitespace removed.
hal::str::trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"   # strip leading
    s="${s%"${s##*[![:space:]]}"}"   # strip trailing
    printf '%s' "$s"
}

# hal::str::upper <string>
# Prints the string converted to upper-case.
hal::str::upper() {
    printf '%s' "$*" | tr '[:lower:]' '[:upper:]'
}

# hal::str::lower <string>
# Prints the string converted to lower-case.
hal::str::lower() {
    printf '%s' "$*" | tr '[:upper:]' '[:lower:]'
}

# hal::str::contains <haystack> <needle>
# Returns 0 if haystack contains needle, 1 otherwise.
hal::str::contains() {
    [[ "$1" == *"$2"* ]]
}

# hal::str::starts_with <string> <prefix>
# Returns 0 if string starts with prefix, 1 otherwise.
hal::str::starts_with() {
    [[ "$1" == "$2"* ]]
}

# hal::str::ends_with <string> <suffix>
# Returns 0 if string ends with suffix, 1 otherwise.
hal::str::ends_with() {
    [[ "$1" == *"$2" ]]
}

# hal::str::repeat <string> <count>
# Prints string repeated count times (no separator).
hal::str::repeat() {
    local s="$1" n="$2" i
    for (( i = 0; i < n; i++ )); do printf '%s' "$s"; done
    printf '\n'
}

# hal::str::length <string>
# Prints the character length of string.
hal::str::length() {
    printf '%d' "${#1}"
}

# ── hal::arr ──────────────────────────────────────────────────────────────────

# hal::arr::contains <value> <array_elements...>
# Returns 0 if value is present among the remaining arguments.
# Usage:  hal::arr::contains "needle" "${array[@]}"
hal::arr::contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# hal::arr::join <separator> <array_elements...>
# Prints all elements joined by separator.
# Usage:  hal::arr::join ", " "${array[@]}"
hal::arr::join() {
    local sep="$1"; shift
    local first=1
    local item
    for item in "$@"; do
        [[ $first -eq 1 ]] && first=0 || printf '%s' "$sep"
        printf '%s' "$item"
    done
    printf '\n'
}

# ── hal::fs ───────────────────────────────────────────────────────────────────

# hal::fs::exists <path>
# Returns 0 if path exists (file or directory), 1 otherwise.
hal::fs::exists() {
    [[ -e "$1" ]]
}

# hal::fs::is_file <path>
# Returns 0 if path is a regular file, 1 otherwise.
hal::fs::is_file() {
    [[ -f "$1" ]]
}

# hal::fs::is_dir <path>
# Returns 0 if path is a directory, 1 otherwise.
hal::fs::is_dir() {
    [[ -d "$1" ]]
}

# hal::fs::mkdir_p <path>
# Creates directory and all parents; idempotent.
hal::fs::mkdir_p() {
    mkdir -p "$1"
}

# hal::fs::extension <filename>
# Prints the file extension (without the dot), or empty string if none.
hal::fs::extension() {
    local base="${1##*/}"
    [[ "$base" == *.* ]] && printf '%s' "${base##*.}" || printf ''
}

# hal::fs::basename_no_ext <filename>
# Prints the filename without directory or extension.
hal::fs::basename_no_ext() {
    local base="${1##*/}"
    printf '%s' "${base%.*}"
}

# ── hal::log ──────────────────────────────────────────────────────────────────

# Colour codes (disabled automatically when not writing to a terminal)
if [[ -t 2 ]]; then
    _HAL_RED='\033[0;31m'
    _HAL_YEL='\033[0;33m'
    _HAL_GRN='\033[0;32m'
    _HAL_CYN='\033[0;36m'
    _HAL_MAG='\033[0;35m'
    _HAL_DIM='\033[2m'
    _HAL_RST='\033[0m'
else
    _HAL_RED='' _HAL_YEL='' _HAL_GRN='' _HAL_CYN='' _HAL_MAG='' _HAL_DIM='' _HAL_RST=''
fi

# Numeric level thresholds (higher number = more verbose)
_HAL_LVL_OFF=0
_HAL_LVL_ERROR=1
_HAL_LVL_WARN=2
_HAL_LVL_INFO=3
_HAL_LVL_DEBUG=4
_HAL_LVL_TRACE=5

# hal::log::init
# (Re-)reads HAL_LOG_LEVEL and caches it as a number in _HAL_LOG_LEVEL.
# Called automatically at source time; call again after changing HAL_LOG_LEVEL.
#
# HAL_LOG_LEVEL accepts a name or number (case-insensitive):
#   off   | 0   — silence all output
#   error | 1   — errors only
#   warn  | 2   — warn and error
#   info  | 3   — info, ok, warn, error          (default)
#   debug | 4   — debug and above
#   trace | 5   — everything
hal::log::init() {
    local _level="${1:-${HAL_LOG_LEVEL:-info}}"
    _level=$(printf '%s' "$_level" | tr '[:upper:]' '[:lower:]')
    case "${_level}" in
        0|off)    _HAL_LOG_LEVEL=$_HAL_LVL_OFF   ;;
        1|err*)   _HAL_LOG_LEVEL=$_HAL_LVL_ERROR ;;
        2|warn*)  _HAL_LOG_LEVEL=$_HAL_LVL_WARN  ;;
        3|info)   _HAL_LOG_LEVEL=$_HAL_LVL_INFO  ;;
        4|debug)  _HAL_LOG_LEVEL=$_HAL_LVL_DEBUG ;;
        5|trace)  _HAL_LOG_LEVEL=$_HAL_LVL_TRACE ;;
        *)        _HAL_LOG_LEVEL=$_HAL_LVL_INFO  ;;
    esac
}
hal::log::init

hal::log::trace() { (( _HAL_LOG_LEVEL >= _HAL_LVL_TRACE )) || return 0
                    printf "${_HAL_DIM}[TRC ]${_HAL_RST}  %s\n" "$*" >&2; }
hal::log::debug() { (( _HAL_LOG_LEVEL >= _HAL_LVL_DEBUG )) || return 0
                    printf "${_HAL_MAG}[DBG ]${_HAL_RST}  %s\n" "$*" >&2; }
hal::log::info()  { (( _HAL_LOG_LEVEL >= _HAL_LVL_INFO  )) || return 0
                    printf "${_HAL_CYN}[INFO]${_HAL_RST}  %s\n" "$*" >&2; }
hal::log::ok()    { (( _HAL_LOG_LEVEL >= _HAL_LVL_INFO  )) || return 0
                    printf "${_HAL_GRN}[ OK ]${_HAL_RST}  %s\n" "$*" >&2; }
hal::log::warn()  { (( _HAL_LOG_LEVEL >= _HAL_LVL_WARN  )) || return 0
                    printf "${_HAL_YEL}[WARN]${_HAL_RST}  %s\n" "$*" >&2; }
hal::log::error() { (( _HAL_LOG_LEVEL >= _HAL_LVL_ERROR )) || return 0
                    printf "${_HAL_RED}[ERR ]${_HAL_RST}  %s\n" "$*" >&2; }

# hal::log::die <message> [exit_code]
# Logs an error and exits.  Default exit code is 1.
# Always prints regardless of HAL_LOG_LEVEL.
hal::log::die() {
    printf "${_HAL_RED}[ERR ]${_HAL_RST}  %s\n" "$1" >&2
    exit "${2:-1}"
}

# ── hal::plugin ───────────────────────────────────────────────────────────────

# _hal_run_plugins <link_json> [resource-file] [path…]
# Pipes link_json through each colon-separated script in HAL_LINK_PLUGIN in order.
# Each plugin: receives current link JSON on stdin, resource-file + path as args,
# must print updated link JSON (with .href) to stdout.
# No-op when HAL_LINK_PLUGIN is unset or empty.
# Prints error to stderr and returns 1 on plugin failure or invalid output.
_hal_run_plugins() {
    local _current="$1"; shift
    if [[ -z "${HAL_LINK_PLUGIN:-}" ]]; then
        printf '%s' "$_current"
        return 0
    fi
    local -a _plugins
    IFS=: read -ra _plugins <<< "$HAL_LINK_PLUGIN"
    local _p _out
    for _p in "${_plugins[@]}"; do
        [[ -z "$_p" ]] && continue
        if ! _out=$(printf '%s' "$_current" | "$_p" "$@"); then
            printf 'hal: plugin failed: %s\n' "$_p" >&2
            return 1
        fi
        _current="$_out"
    done
    local _href=''
    if command -v jq >/dev/null 2>&1; then
        _href=$(printf '%s' "$_current" | jq -r '.href // empty' 2>/dev/null) || true
    elif command -v yq >/dev/null 2>&1 && printf '{}' | yq '.' >/dev/null 2>&1; then
        _href=$(printf '%s' "$_current" | yq -r '.href // ""' 2>/dev/null) || true
    else
        printf 'hal: plugin validation requires jq or yq\n' >&2; return 1
    fi
    if [[ -z "$_href" || "$_href" == "null" ]]; then
        printf 'hal: plugin output missing .href\n' >&2; return 1
    fi
    printf '%s' "$_current"
}

# hal::plugin::config
# Prints the aggregate plugin-environment snippet for the plugins in
# HAL_LINK_PLUGIN.  Each plugin is queried with '-config' (the plugin contract:
# print shell that recreates its environment from the current values, no stdin
# read) and its output is framed by a marker line so a caller can record or diff
# the per-plugin blocks.  A plugin not on PATH is skipped (its absence is already
# surfaced by the session plugin-list check).  No-op when HAL_LINK_PLUGIN is
# unset or empty.
hal::plugin::config() {
    [[ -n "${HAL_LINK_PLUGIN:-}" ]] || return 0
    local -a _plugins
    IFS=: read -ra _plugins <<< "$HAL_LINK_PLUGIN"
    local _p
    for _p in "${_plugins[@]}"; do
        [[ -z "$_p" ]] && continue
        command -v "$_p" >/dev/null 2>&1 || continue
        printf '# --8<-- plugin: %s\n' "$_p"
        "$_p" -config
    done
}
