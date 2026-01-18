#!/usr/bin/env bash

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup cleanup

set +e

pass=0
fail=0
tests=0

# Simple colors (works on most terminals; safe fallback)
RED="$(printf '\033[31m')"
GRN="$(printf '\033[32m')"
YEL="$(printf '\033[33m')"
RST="$(printf '\033[0m')"

check() {
  expected=$#

  count=$(find . -maxdepth 1 -type f -ls | wc -l)
  [ "$count" -eq "$expected" ] || { echo "Found $count files"; return 255; }

  for file in "$@"
  do
    [ -f "$file" ] || { ls -l $file; echo; echo "file $file is missing"; return 1; }
  done
  return 0
}

report() {
  result=$1
  passMsg=$2
  failMsg=$3

  tests=$((tests+1))

#  echo "result: $result"
#  echo "pass ($pass): $passMsg"
#  echo "fail ($fail): $failMsg"

  if [ "$result" -eq 0 ]
  then
    pass=$((pass+1))
    printf "%sPASS%s %-24s\n" "$GRN" "$RST" "$passMsg"
  else
    fail=$((fail+1))
    printf "%sFAIL%s %-24s\n" "$RED" "$RST" "$failMsg"
  fi

  echo "The first test file" >test.first
  echo -e "The second\ntest file" >test.second
  echo -e "The\nthird\ntest\nfile\n." >test.third
  cp test.first first.test
  cp test.second second.test
  cp test.third third.test
}

[ $(find . -type f -name "*" -ls | wc -l) -eq 0 ] || rm * # cleanup empty folder
stdout=$(echo test | cleanup.sh 2>/dev/null)
[ "$stdout" == "test" ] && { check; }
report $? \
  "successfully do nothing if files not exist" \
  "failure -- response: \"$stdout\". Some files are found"

stdout=$(echo test | cleanup.sh 2>/dev/null)
[ "$stdout" == "test" ] && { check first.test second.test third.test; }
report $? \
  "successfully deleted all files without exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't delete all file: \n$(find . -name "test.*")")"

stdout=$(echo test | cleanup.sh -k first 2>/dev/null)
[ "$stdout" == "test" ] && { check first.test second.test third.test test.first; }
report $? \
  "successfuly deleted all files without a 'first' exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep a single file: \n$(find . -name "test.*")")"

stdout=$(echo test | cleanup.sh -k second,third 2>/dev/null)
[ "$stdout" == "test" ] && { check first.test second.test third.test test.second test.third; }
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

stdout=$(echo test | cleanup.sh -k first -k third 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test test.first test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

rm * # cleanup empty folder
stdout=$(cleanup.sh test 2>/dev/null)
[ "$stdout" == "test" ] && (check)
report $? "successfully do nothing if files not exist" "failure -- response: \"$stdout\". Some files are found"

stdout=$(cleanup.sh test 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test)
report $? \
  "successfully deleted all files without exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't delete all file: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh test -k first 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test test.first)
report $? \
  "successfuly deleted all files without a 'first' exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep a single file: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh -k first test 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test test.first)
report $? \
  "successfuly deleted all files without a 'first' exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep a single file: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh test -k second,third 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test test.second test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh -k second,third test 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test test.second test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh test -k first -k third 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test test.first test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh -k first test -k third 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test test.first test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh -k first -k third test 2>/dev/null)
[ "$stdout" == "test" ] && (check first.test second.test third.test test.first test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

rm * # cleanup empty folder
stdout=$(echo -e "test\nfirst" | cleanup.sh 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nfirst")" ] && (check)
report $? \
  "successfully do nothing if files not exist" \
  "failure -- response: \"$stdout\". Some files are found"

stdout=$(echo -e "test\nfirst" | cleanup.sh 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nfirst")" ] && (check second.test third.test)
report $? \
  "successfully deleted all files without exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't delete all file: \n$(find . -name "test.*")")"

stdout=$(echo -e "test\nsecond" | cleanup.sh -k first 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nsecond")" ] && (check first.test third.test test.first)
report $? \
  "successfuly deleted all files without a 'first' exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep a single file: \n$(find . -name "test.*")")"

stdout=$(echo -e "test\nthird" | cleanup.sh -k second,third 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nthird")" ] && (check first.test second.test test.second test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

stdout=$(echo -e "test\nfirst" | cleanup.sh -k first -k third 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nfirst")" ] && (check second.test third.test test.first test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

rm * # cleanup empty folder
stdout=$(cleanup.sh test first 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nfirst")" ] && (check)
report $? \
  "successfully do nothing if files not exist" \
  "failure -- response: \"$stdout\". Some files are found"

stdout=$(cleanup.sh test first 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nfirst")" ] && (check second.test third.test)
report $? \
  "successfully deleted all files without exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't delete all file: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh test second -k first 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nsecond")" ] && (check first.test third.test test.first)
report $? \
  "successfuly deleted all files without a 'first' exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep a single file: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh test second -k first third 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nsecond\nthird")" ] && (check first.test test.first)
report $? \
  "successfuly deleted all files without a 'first' exclusion" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep a single file: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh -k first test -k third first 2>/dev/null)
[ "$stdout" == "$(echo -e "test\nfirst")" ] && (check second.test third.test test.first test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"

stdout=$(cleanup.sh missing -k first test -k third first 2>/dev/null)
[ "$stdout" == "$(echo -e "missing\ntest\nfirst")" ] && (check second.test third.test test.first test.third)
report $? \
  "successfuly deleted all files without 'second' and 'third' exclusions and missing base name" \
  "$(echo -e "failure -- response: \"$stdout\". doesn't keep files with comma-separated extensions: \n$(find . -name "test.*")")"


###############################################################################
# SUMMARY
###############################################################################
printf "\n"
if [ "$fail" -eq 0 ]; then
  printf "%sAll %d tests passed.%s\n" "$GRN" "$tests" "$RST"
  exit 0
else
  printf "%s%d passed, %d failed (total %d).%s\n" "$YEL" "$pass" "$fail" "$tests" "$RST"
  exit "$fail"
fi
