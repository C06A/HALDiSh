#!/usr/bin/env bash
# cleanup.sh
#
# Deletes files matching given base names.
# If -k extensions are provided, those extensions are kept.
# If no -k is provided, everything matching the base name is removed.
#
# Base names may be passed as arguments or via STDIN (one per line).
# Prints each handled base name to STDOUT.

set -u -o pipefail
shopt -s nullglob

usage() {
  cat <<'USAGE' >&2
Usage:
  cleanup.sh [-k EXT[,EXT...]] [-k EXT ...] [--] [BASENAME ...]
  cleanup.sh [-k EXT[,EXT...]] < basenames.txt

Options:
  -k EXT[,EXT...]   Extension(s) to keep (optional, repeatable).
  -n               Dry-run (show what would be deleted).
  -v               Verbose output to STDERR.
  -h               Show this help.

Notes:
  - BASENAME matches files "BASENAME" and "BASENAME.*" in current directory.
  - If no -k is provided, ALL matching files are removed.
  - Extensions are case-sensitive.
USAGE
}

dry_run=0
verbose=0
declare -A KEEP=()

add_keep() {
  local ext
  IFS=',' read -r -a parts <<<"$1"
  for ext in "${parts[@]}"; do
    [[ -n "$ext" ]] && KEEP["$ext"]=1
  done
}

basenames=()

# Parse arguments
while (($#)); do
  case "$1" in
    -k)
      shift || { usage; exit 2; }
      add_keep "$1"
      ;;
    -k*)
      add_keep "${1#-k}"
      ;;
    -n)
      dry_run=1
      ;;
    -v)
      verbose=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      basenames+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      basenames+=("$1")
      ;;
  esac
  shift || true
done

# Read basenames from STDIN if none provided
if ((${#basenames[@]} == 0)); then
  if [ -t 0 ]; then
    echo "Error: no base names provided." >&2
    usage
    exit 2
  fi
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && basenames+=("$line")
  done
fi

process_base() {
  local base="$1"
  local f ext

  for f in "$base" "$base".*; do
    [[ -f "$f" ]] || continue

    if [[ "$f" == "$base" ]]; then
      ext=""
    else
      ext="${f##*.}"
    fi

    # Keep only if -k was provided AND extension matches
    if ((${#KEEP[@]} > 0)) && [[ -n "$ext" && -n "${KEEP[$ext]+x}" ]]; then
      ((verbose)) && echo "KEEP:    $f" >&2
      continue
    fi

    if ((dry_run)); then
      echo "DELETE:  $f" >&2
    else
      rm -f -- "$f"
      ((verbose)) && echo "DELETED: $f" >&2
    fi
  done

  # Emit handled base name
  printf '%s\n' "$base"
}

for b in "${basenames[@]}"; do
  process_base "$b"
done
