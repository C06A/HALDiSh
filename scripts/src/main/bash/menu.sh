#!/usr/bin/env bash
# menu.sh — interactive selector menu
#
# Usage:
#   menu.sh <prompt> <option> <option>...   prompt + options as arguments (≥3 args)
#   menu.sh <prompt>                        prompt as arg, options from stdin
#   menu.sh                                 first stdin line = prompt, rest = options
#
# Stdout : text of the chosen option
# Stderr : menu display and chosen option text

readonly _MENU_SELECTORS='123456789abcdefghijklmnopqrstuvwxyz'
readonly _MENU_MAX_PER_PAGE=30
readonly _MENU_PAGINATE_THRESHOLD=36

# ── parse arguments / stdin ──────────────────────────────────────────────────

_menu_read_options_from_stdin() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && _menu_options+=("$line")
    done
}

_menu_prompt=''
_menu_options=()

if [[ $# -eq 0 ]]; then
    IFS= read -r _menu_prompt
    _menu_read_options_from_stdin
elif [[ $# -eq 1 ]]; then
    _menu_prompt="$1"
    _menu_read_options_from_stdin
else
    _menu_prompt="$1"; shift
    _menu_options=("$@")
fi

_menu_total=${#_menu_options[@]}
if [[ $_menu_total -eq 0 ]]; then
    printf 'menu.sh: no menu options provided\n' >&2
    exit 1
fi

# ── interactive display loop ─────────────────────────────────────────────────

_menu_page=0
_menu_paginate=0
if (( _menu_total > _MENU_PAGINATE_THRESHOLD )); then
    _menu_paginate=1
fi

# Open the input source once so sequential reads advance through the stream.
# (_MENU_TTY overrides /dev/tty in tests.)
exec 3< "${_MENU_TTY:-/dev/tty}"

while true; do
    # Determine visible slice
    if [[ $_menu_paginate -eq 1 ]]; then
        _menu_start=$(( _menu_page * _MENU_MAX_PER_PAGE ))
        _menu_end=$(( _menu_start + _MENU_MAX_PER_PAGE ))
        if (( _menu_end > _menu_total )); then _menu_end=$_menu_total; fi
    else
        _menu_start=0
        _menu_end=$_menu_total
    fi

    _menu_count=$(( _menu_end - _menu_start ))
    _menu_has_prev=0
    _menu_has_next=0
    if (( _menu_page > 0 ));           then _menu_has_prev=1; fi
    if (( _menu_end < _menu_total ));  then _menu_has_next=1; fi

    # Print option rows
    for (( _i = _menu_start; _i < _menu_end; _i++ )); do
        _sel="${_MENU_SELECTORS:$(( _i - _menu_start )):1}"
        printf '(%s) %s\n' "$_sel" "${_menu_options[$_i]}" >&2
    done

    if [[ $_menu_has_prev -eq 1 ]]; then printf '(<) Previous\n' >&2; fi
    if [[ $_menu_has_next -eq 1 ]]; then printf '(>) Next\n'     >&2; fi

    # Build selector range for the prompt suffix  [first-last]
    _menu_first="${_MENU_SELECTORS:0:1}"
    _menu_last="${_MENU_SELECTORS:$(( _menu_count - 1 )):1}"
    if [[ "$_menu_first" == "$_menu_last" ]]; then
        _menu_range="$_menu_first"
    else
        _menu_range="${_menu_first}-${_menu_last}"
    fi

    _menu_nav=''
    if [[ $_menu_has_prev -eq 1 ]]; then _menu_nav="${_menu_nav},<"; fi
    if [[ $_menu_has_next -eq 1 ]]; then _menu_nav="${_menu_nav},>"; fi

    printf '%s [%s%s]: ' "$_menu_prompt" "$_menu_range" "$_menu_nav" >&2

    # Read a single keypress from fd 3 (no Enter required).
    # -s suppresses terminal echo; we echo the char manually so the user sees it.
    IFS= read -r -s -n1 _menu_choice <&3
    printf '%s\n' "$_menu_choice" >&2

    # ── navigation ───────────────────────────────────────────────────────────
    if [[ "$_menu_choice" == '<' && $_menu_has_prev -eq 1 ]]; then
        _menu_page=$(( _menu_page - 1 ))
        continue
    fi
    if [[ "$_menu_choice" == '>' && $_menu_has_next -eq 1 ]]; then
        _menu_page=$(( _menu_page + 1 ))
        continue
    fi

    # ── validate selector ────────────────────────────────────────────────────
    _menu_matched=-1
    for (( _j = 0; _j < _menu_count; _j++ )); do
        if [[ "${_MENU_SELECTORS:$_j:1}" == "$_menu_choice" ]]; then
            _menu_matched=$(( _menu_start + _j ))
            break
        fi
    done

    if (( _menu_matched >= 0 )); then
        printf '%s\n' "${_menu_options[$_menu_matched]}" >&2  # chosen option → stderr
        printf '%s\n' "${_menu_options[$_menu_matched]}"       # chosen option → stdout
        exit 0
    fi

    printf 'Invalid selection: "%s" — please try again.\n' "$_menu_choice" >&2
done
