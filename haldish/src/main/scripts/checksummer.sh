#!/usr/bin/env sh
# Compute a single SHA-256 checksum from the concatenation of all files,
# excluding patterns. Portable to Linux/macOS with POSIX /bin/sh.

set -eu

usage() {
  cat <<'USAGE'
Usage: checksummer.sh [OPTIONS] [DIR]

Create the command to compute a single SHA-256 checksum over the concatenation of all regular files
under DIR (default: .), excluding any files that match exclude patterns.

Options:
  -e, --exclude PATTERN     Exclude files matching shell glob PATTERN
                            (matched against path relative to DIR)
  -E, --exclude-from FILE   Read exclude patterns (one per line) from FILE
  -h, --help                Show this help

Output:
  1) The SHA-256 checksum for all included files concatenated in sorted order.
  2) An explicit command you can run to reproduce it (no wildcards).

Notes:
  - Patterns are shell globs (* ? [ ]) matched against relative paths.
  - Symlinks are skipped. Binary files are fine.
  - Filenames with spaces are supported; filenames with newlines are not.
USAGE
}

DIR="."
EXCLUDE_PATTERNS=""

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -e|--exclude)
      [ $# -ge 2 ] || { echo "Missing argument for $1" >&2; exit 2; }
      EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS}
$2"
      shift 2 ;;
    -E|--exclude-from)
      [ $# -ge 2 ] || { echo "Missing argument for $1" >&2; exit 2; }
      [ -f "$2" ] || { echo "Exclude file not found: $2" >&2; exit 2; }
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          ''|'#'*) continue ;;
          *) EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS}
$line" ;;
        esac
      done < "$2"
      shift 2 ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2 ;;
    *)
      DIR="$1"
      shift ;;
  esac
done

# Normalize DIR
case "$DIR" in
  '') DIR='.' ;;
  */) DIR=${DIR%/} ;;
esac

[ -d "$DIR" ] || { echo "Not a directory: $DIR" >&2; exit 2; }

# Pick checksum tool and set a small parser function
HASH_TOOL=""
parse_hash() { awk '{print $1}'; }  # default parser for shasum/sha256sum
if command -v shasum >/dev/null 2>&1; then
  HASH_TOOL="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  HASH_TOOL="sha256sum"
elif command -v openssl >/dev/null 2>&1; then
  HASH_TOOL="openssl dgst -sha256"
  parse_hash() { awk '{print $2}'; }  # OpenSSL prints "SHA256(stdin)= <hash>"
else
  echo "No SHA-256 tool found. Install shasum, sha256sum, or openssl." >&2
  exit 127
fi

# Exclude matcher (POSIX-glob only; no **)
should_exclude() {
  _rel=$1
  oldIFS=$IFS
  IFS='
'
  for pat in $EXCLUDE_PATTERNS; do
    [ -n "$pat" ] || continue
    case "$_rel" in
      $pat) IFS=$oldIFS; return 0 ;;
    esac
  done
  IFS=$oldIFS
  return 1
}

# Build a sorted list of included files (newline-delimited; spaces safe)
LIST=$(mktemp)
SORTED=$(mktemp)
trap 'rm -f "$LIST" "$SORTED"' EXIT

# Collect files
find "$DIR" -type f | while IFS= read -r f; do
  # Skip symlinks (belt-and-suspenders)
  [ -L "$f" ] && continue
  case "$f" in
    "$DIR"/*) rel=${f#"$DIR"/} ;;
    "$DIR") rel="." ;;
    *) rel="$f" ;;
  esac
  if should_exclude "$rel"; then
    continue
  fi
  printf '%s\n' "$f" >> "$LIST"
done

# Deterministic order
LC_ALL=C sort "$LIST" > "$SORTED"

[ -s "$SORTED" ] || { echo "No files to hash after exclusions." >&2; exit 3; }

# Build explicit reproducible command string: cat 'f1' 'f 2' ... | HASH_TOOL
CMD_STR="cat"
while IFS= read -r f; do
  esc=$(printf "%s" "$f" | sed "s/'/'\\\\''/g")
  CMD_STR="$CMD_STR '$esc'"
done < "$SORTED"
CMD_STR="$CMD_STR | $HASH_TOOL"

# Output
printf '%s\n' "$CMD_STR"
CHECKSUM=$(eval $CMD_STR)
