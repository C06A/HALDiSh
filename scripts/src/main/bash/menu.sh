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

# An option whose text starts with this byte is a navigation/meta item (back,
# quit, …) rather than data from the resource being browsed.  The marker is
# stripped before display and before the chosen value is returned; the label is
# rendered in a distinct color so it stands out from content options.
readonly _MENU_META_MARK=$'\001'
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    readonly _MENU_META_COLOR=$'\033[36m'   # cyan
    readonly _MENU_META_RESET=$'\033[0m'
else
    readonly _MENU_META_COLOR=''
    readonly _MENU_META_RESET=''
fi

# _menu_render_row <selector> <option-text>
# Prints one menu row to stderr, coloring it if it is a meta item.
_menu_render_row() {
    local sel="$1" opt="$2"
    if [[ "${opt:0:1}" == "$_MENU_META_MARK" ]]; then
        # ">>> " prefix marks meta items independently of color, for terminals
        # without color support or users who can't distinguish the cyan.
        printf '(%s) %s>>> %s%s\n' "$sel" "$_MENU_META_COLOR" "${opt:1}" "$_MENU_META_RESET" >&2
    else
        printf '(%s) %s\n' "$sel" "$opt" >&2
    fi
}

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

# Blank line separates the menu from whatever preceded it (prior log, response
# body, previous menu echo) so the option list is visually distinct.
printf '\n' >&2

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
        _menu_render_row "$_sel" "${_menu_options[$_i]}"
    done

    # Pagination controls are navigation, so color them like meta items.
    if [[ $_menu_has_prev -eq 1 ]]; then _menu_render_row '<' "${_MENU_META_MARK}Previous"; fi
    if [[ $_menu_has_next -eq 1 ]]; then _menu_render_row '>' "${_MENU_META_MARK}Next";     fi

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
        _menu_chosen_opt="${_menu_options[$_menu_matched]}"
        if [[ "${_menu_chosen_opt:0:1}" == "$_MENU_META_MARK" ]]; then
            _menu_chosen_opt="${_menu_chosen_opt:1}"             # drop meta marker
            printf '%s>>> %s%s\n' "$_MENU_META_COLOR" "$_menu_chosen_opt" "$_MENU_META_RESET" >&2
        else
            printf '%s\n' "$_menu_chosen_opt" >&2               # chosen option → stderr
        fi
        printf '%s\n' "$_menu_chosen_opt"                        # chosen option → stdout
        exit 0
    fi

    printf 'Invalid selection: "%s" — please try again.\n' "$_menu_choice" >&2
done
