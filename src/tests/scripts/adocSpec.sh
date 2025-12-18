#!/bin/bash

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup adoc

pass=0
fail=0
tests=0

# Simple colors (works on most terminals; safe fallback)
RED="$(printf '\033[31m')"
GRN="$(printf '\033[32m')"
YEL="$(printf '\033[33m')"
RST="$(printf '\033[0m')"

cat >test.first <<EOF
This is a first section
EOF

cat >test.second <<EOF
which followed
by the second
EOF

cat >test.third <<EOF
and
finishes
with
the
third
EOF

cat >another.1 <<EOF
This is another first section
EOF

cat >another.2 <<EOF
which followed
by the another second
EOF

cat >another.3 <<EOF
and
finishes
with
the
another
third
EOF

cat >to.skip <<EOF
This file will be not included
EOF


adoc.sh test another 2>/dev/null | tee output.adoc >/dev/null

tags=$(grep "tag::" output.adoc | wc -l )

ends=$(grep "end::" output.adoc | wc -l )

if [ $tags -eq 6 ] && [ $ends -eq 6 ]
then
  printf "%sPASS%s %-24s\n" "$GRN" "$RST" "ASCIIdoc combined file created successfuly"
  exit 0
else
  grep "tag::" output.adoc
  grep "end::" output.adoc
  printf "%sFAIL%s %-24s\n" "$RED" "$RST" "Fail to create proper ASCIIdoc file"
  exit 1
fi
