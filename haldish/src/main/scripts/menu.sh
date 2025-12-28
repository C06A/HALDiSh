#!/usr/bin/env bash

# This script prints to the STDERR up to 36 options
# and accepts a single character from the terminal
# (0...9 and a...z) as user's selection.
# Then it prints the selected option (value) to the STDOUT.
#
# The script accepts the prompt and up to 36 options' values
# from the command line arguments.
#
# If command line contains only 1 argument, the script uses it as a prompt
# and reads options from STDIN (1 option per line).
#
# If there are no arguments at all, the script uses the first line
# from the STDIN as a prompt and the rest -- as options in the menu.
#

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }

# Get selector string for a 1-based index
selector_for() {
  local idx=$1
  if (( idx >= 1 && idx <= 9 )); then
    printf '%d' "$idx"
  elif (( idx >= 10 && idx <= 35 )); then
    local offset=$(( idx - 10 ))
    printf \\$(printf '%03o' $(( 97 + offset )))  # 97='a'
  else
    return 1
  fi
}

normalize_choice() {
  local s
  echo >&2
  s=$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr 'A-Z' 'a-z')
  printf '%s' "$s"
}

prompt_text=""
declare -a options=()

if (( $# >= 1 )); then
  prompt_text=$1; shift
  if (( $# >= 1 )); then
    options=("$@")
  else
    while IFS= read -r line; do options+=("$line"); done
  fi
else
  if ! IFS= read -r prompt_text; then
    err "Error: expected prompt on stdin but got nothing."; exit 1
  fi
  while IFS= read -r line; do options+=("$line"); done
fi

prompt_text=${prompt_text%$'\r'}
for i in "${!options[@]}"; do options[$i]=${options[$i]%$'\r'}; done

opt_count=${#options[@]}
(( opt_count > 0 )) || { err "Error: no menu options provided."; exit 1; }
(( opt_count <= 35 )) || { err "Error: too many options ($opt_count). Max is 35."; exit 1; }

declare -A sel_to_index=()
for (( i=1; i<=opt_count; i++ )); do
  sel=$(selector_for "$i") || { err "Internal error building selector for index $i."; exit 1; }
  sel_to_index["$sel"]=$i
  err "(${sel}) ${options[$((i-1))]}"
done

last_sel=$(selector_for "$opt_count")
range_display="[1-${last_sel}]"

# >>> fixed: print prompt to stderr WITHOUT newline, so input appears right after ':'
printf '%s' "${prompt_text} ${range_display}: " >&2

choice=""
if ! IFS= read -rn 1 choice </dev/tty; then
  printf '\n' >&2
  err "Error: could not read user input from terminal."; exit 2
fi
choice=$(normalize_choice "$choice")

while [[ -z "${sel_to_index[$choice]:-}" ]]; do
  err "Invalid choice: '$choice'. Please enter a selector in ${range_display}."
  # >>> fixed re-prompt too
  printf '%s' "${prompt_text} ${range_display}: " >&2
  if ! IFS= read -rn 1 choice </dev/tty; then
    printf '\n' >&2
    err "Error: could not read user input from terminal."; exit 2
  fi
  choice=$(normalize_choice "$choice")
done

idx=${sel_to_index[$choice]}
selected_option=${options[$((idx-1))]}

# Selected option text to stderr; selector only to stdout
# printf '%s\n' "selected_option: ${selected_option}" >&2
printf '%s\n' "${selected_option}"
