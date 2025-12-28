#!/usr/bin/env bash

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup rename

pass=0
fail=0
tests=0

# Simple colors (works on most terminals; safe fallback)
RED="$(printf '\033[31m')"
GRN="$(printf '\033[32m')"
YEL="$(printf '\033[33m')"
RST="$(printf '\033[0m')"

cat >test.first <<EOF
The first test file
EOF

cat >test.second <<EOF
The second
test file
EOF

cat >test.third <<EOF
The
 third
  test
   file
.
EOF

[ $(echo test | rename.sh renamed 2>/dev/null) = "renamed" ] || (echo failure -- doesn\'t rename; exit 250)

[ $(rename.sh alternative renamed 2>/dev/null) = "alternative" ] || (echo failure -- doesn\'t rename again; exit 251)

if [ $(ls -1 . | wc -l) -eq $(ls -1 alternative.* | wc -l) ]
then
  printf "%sPASS%s %-24s\n" "$GRN" "$RST" "Renamed files correctly"
  exit 0
else
  printf "%sFAIL%s %-24s\n" "$RED" "$RST" "Failed to rename files"
  exit 252
fi
