#!/usr/bin/env bash

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup rename

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
  echo success -- rename.sh
else
  echo failure -- rename.sh
  exit 252
fi
