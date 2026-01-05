#!/bin/bash

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup get

set +e

pass=0
fail=0
tests=0

# Simple colors (works on most terminals; safe fallback)
RED="$(printf '\033[31m')"
GRN="$(printf '\033[32m')"
YEL="$(printf '\033[33m')"
RST="$(printf '\033[0m')"

get() {
  local url=$1
  local name=$2

  GET "$url" | eval rename.sh "$name" 2>/dev/null
}

report() {
  result=$1
  passMsg=$2
  failMsg=$3

  tests=$((tests+1))

#  echo "result: $result"
#  echo "pass ($pass): $passMsg"
#  echo "fail ($fail): $failMsg"

  if [ $result -eq 0 ]
  then
    pass=$((pass+1))
    printf "%sPASS%s %-24s\n" "$GRN" "$RST" "$passMsg"
  else
    fail=$((fail+1))
    printf "%sFAIL%s %-24s\n" "$RED" "$RST" "$failMsg"
  fi
}

get "$RESOURCES_DIR/start.hal" "start" >/dev/null
[ $(cat start.body | wc -l) -gt 0 ]
report $? 'get start resource' 'get start resource got nothing'


get $(eval echo $(jq -r "._links.empty.href" start.body)) "start_empty" >/dev/null
[ -z "$(cat start_empty.body)" ]
report $? 'empty file downloaded from start resource' 'empty file downloaded from start resource is not empty'


get $(eval echo $(jq -r "._links.null.href" start.body)) "start_null" >/dev/null
[ "$(cat start_null.body)" == "null" ]
report $? 'null file downloaded from start resource' 'null file downloaded from start resource contain null value'

get $(eval echo $(jq -r "._links.false.href" start.body)) "start_false" >/dev/null
[ "$(cat start_false.body)" == "false" ]
report $? 'false file downloaded from start resource' 'false file downloaded from start resource contain invalid value'


get $(eval echo $(jq -r "._links.true.href" start.body)) "start_true" >/dev/null
[ "$(cat start_true.body)" == "true" ]
report $? 'true file downloaded from start resource' 'true file downloaded from start resource contain invalid value'


get $(eval echo $(jq -r "._links.number.href" start.body)) "start_number" >/dev/null
[ "$(cat start_number.body)" == "42" ]
report $? 'number file downloaded from start resource' 'number file downloaded from start resource contain invalid value'


get $(eval echo $(jq -r "._links.string.href" start.body)) "start_string" >/dev/null
[ "$(cat start_string.body)" == "\"Single string HAL resource\"" ]
report $? 'string file downloaded from start resource' 'string file contain invalid value'


get $(eval echo $(jq -r "._links.simple.href" start.body)) "simple" >/dev/null
[ $(cat simple.body | wc -l) -gt 0 ]
report $? 'get simple resource downloaded from start resource' 'get simple resource downloaded from start resource got nothing'

get $(eval echo $(jq -r "._embedded.simple._links.self.href" start.body)) "simple_embedded" >/dev/null
[ $(diff simple.body simple_embedded.body | wc -l) -eq 0 ]
report $? 'simple resource get via link or embedded' 'simple resource get via link or embedded do not match'


get $(eval echo $(jq -r "._links.object.href" start.body)) "object" >/dev/null
[ $(cat object.body | wc -l) -gt 0 ]
report $? 'get object resource' 'get object resource got nothing'

get $(eval echo $(jq -r "._embedded.object._links.self.href" start.body)) "object_embedded" >/dev/null
[ $(diff object.body object_embedded.body | wc -l) -eq 0 ]
report $? 'object resource get via link or embedded' 'object resource get via link or embedded do not match'


get $(eval echo $(jq -r "._links.array.href" start.body)) "array" >/dev/null
[ $(cat array.body | wc -l) -gt 0 ]
report $? 'get array resource' 'get array resource got nothing'

get $(eval echo $(jq -r "._embedded.array._links.self.href" start.body)) "array_embedded" >/dev/null
[ $(diff array.body array_embedded.body | wc -l) -eq 0 ]
report $? 'array resource get via link or embedded' 'array resource get via link or embedded do not match'


get $(eval echo $(jq -r ".[7]._links.self.href" array.body)) "array_object" >/dev/null
[ $(diff object.body array_object.body | wc -l) -eq 0 ]
report $? 'object resource get via link in the array resource' 'object resource get via link in the array resource do not match one gotten directly'

get $(eval echo $(jq -r '.[7]._links.simple[] | select(.name == "empty") | .href' array.body)) "array_link_empty" >/dev/null
[ $(diff start_empty.body array_link_empty.body | wc -l) -eq 0 ]
report $? 'empty resource get via link in the array resource' 'empty resource get via link in the array resource do not match one gotten directly'


get $(eval echo $(jq -r '.[7]._links.simple[] | select(.name == "null") | .href' array.body)) "array_link_null" >/dev/null
[ $(diff start_null.body array_link_null.body | wc -l) -eq 0 ]
report $? 'null resource get via link in the array resource' 'null resource get via link in the array resource do not match one gotten directly'


get $(eval echo $(jq -r '.[7]._links.simple[] | select(.name == "false") | .href' array.body)) "array_link_false" >/dev/null
[ $(diff start_false.body array_link_false.body | wc -l) -eq 0 ]
report $? 'false resource get via link in the array resource' 'false resource get via link in the array resource do not match one gotten directly'


get $(eval echo $(jq -r '.[7]._links.simple[] | select(.name == "true") | .href' array.body)) "array_link_true" >/dev/null
[ $(diff start_true.body array_link_true.body | wc -l) -eq 0 ]
report $? 'true resource get via link in the array resource' 'true resource get via link in the array resource do not match one gotten directly'


get $(eval echo $(jq -r '.[7]._links.simple[] | select(.name == "number") | .href' array.body)) "array_link_number" >/dev/null
[ $(diff start_number.body array_link_number.body | wc -l) -eq 0 ]
report $? 'number resource get via link in the array resource' 'number resource get via link in the array resource do not match one gotten directly'


get $(eval echo $(jq -r '.[7]._links.simple[] | select(.name == "string") | .href' array.body)) "array_link_string" >/dev/null
[ $(diff start_string.body array_link_string.body | wc -l) -eq 0 ]
report $? 'string resource get via link in the array resource' 'string resource get via link in the array resource do not match one gotten directly'


get $(eval echo $(jq -r '.[7]._links.start.href' array.body)) "array_link_start" >/dev/null
[ $(diff start.body array_link_start.body | wc -l) -eq 0 ]
report $? 'start resource get via link in the array resource' 'start resource get via link in the array resource do not match one gotten directly'


get $(eval echo $(jq -r '.[7]._links.object.href' array.body)) "array_link_object" >/dev/null
[ $(diff object.body array_link_object.body | wc -l) -eq 0 ]
report $? 'object resource get via link in the array resource' 'object resource get via link in the array resource do not match one gotten directly'


get $(eval echo $(jq -r '.[7]._links.array.href' array.body)) "array_link_array" >/dev/null
[ $(diff array.body array_link_array.body | wc -l) -eq 0 ]
report $? 'array resource get via link in the array resource' 'array resource get via link in the array resource do not match one gotten directly'


get "https://one.one.one.one/cdn-cgi/trace" "one-trace" >/dev/null
[ $(ls -l one-trace.* | wc -l) -eq 6 ] \
&& [ "$(cat one-trace.code)" == '200' ] \
&& [ "$(cat one-trace.url)" == 'https://one.one.one.one/cdn-cgi/trace' ] \
&& [ "$(cat one-trace.curl)" == 'curl -k -X GET "https://one.one.one.one/cdn-cgi/trace"' ] \
&& [ $(cat one-trace.headers | wc -l) -eq 10 ] \
&& [ $(cat one-trace.cookies | wc -l) -eq 0 ] \
&& [ $(cat one-trace.body | wc -l) -eq 16 ]
report $? 'receive proper trace' 'there is a problem in the received trace. Check files one-trace.*'


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
