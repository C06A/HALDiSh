#!/usr/bin/env bash
# test_uritengin.sh — unit-style tests for uritengin.sh (Bash 3.x compatible)

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup uritengin

pass=0
fail=0
tests=0

# Simple colors (works on most terminals; safe fallback)
RED="$(printf '\033[31m')"
GRN="$(printf '\033[32m')"
YEL="$(printf '\033[33m')"
RST="$(printf '\033[0m')"

# Run one test: template, expected, then args...
run_test() {
  tests=$((tests+1))
  local name="$1"; shift
  local template="$1"; shift
  local expected="$1"; shift

  # Invoke script: template via stdin; args are the remaining "$@"
  local got
  got="$(printf '%s' "$template" | uritengin.sh "$@")" || got="(exit $?)"

  if [ "$got" = "$expected" ]; then
    pass=$((pass+1))
    printf "%sPASS%s %-24s => %s\n" "$GRN" "$RST" "[$name]" "$template ==> $got"
  else
    fail=$((fail+1))
    printf "%sFAIL%s %-24s\n  tmpl: %s\n  args: %s\n  got : %s\n  want: %s\n" \
      "$RED" "$RST" "[$name]" "$template" "$*" "$got" "$expected"
  fi
}

###############################################################################
# TESTS
###############################################################################

# 1. Simple substitution
run_test "simple-subst" \
  "http://x/{var}" \
  "http://x/abc" \
  var=abc

# 2. Encoding in simple {var}
run_test "encoding-simple" \
  "/{a}" \
  "/a%2Fb%3Fc%23d%20e" \
  "a=a/b?c#d e"

# 3. Reserved expansion {+var} leaves reserved chars as-is (no encoding here)
run_test "reserved-plus" \
  "{+a}" \
  "a/b?c#d e" \
  "a=a/b?c#d e"

# 4. Fragment {#var} leaves chars as-is per this implementation
run_test "fragment" \
  "http://x{#frag}" \
  "http://x#A&B" \
  frag="A&B"

# 5. Label expansion {.var}
run_test "label" \
  "http://sub{.d}.com" \
  "http://sub.x.y.com" \
  d="x.y"

# 6. Path segments explode array {/p*}
run_test "path-array-explode" \
  "/files{/p*}" \
  "/files/a/b%20c" \
  "p=a|b c"

# 7. Path segments array no explode {/p}
run_test "path-array-no-explode" \
  "/files{/p}" \
  "/files/a,b" \
  "p=a|b"

# 8. Path dict explode {/params*}
run_test "path-dict-explode" \
  "/base{/params*}" \
  "/base/k1=v1/k2=v%202" \
  "params=k1:v1|k2:v 2"

# 9. Path dict no explode {/params}
run_test "path-dict-no-explode" \
  "/base{/params}" \
  "/base/k1,v1,k2,v%202" \
  "params=k1:v1|k2:v 2"

# 10. Path-style ; simple
run_test "matrix-simple" \
  "/p{;lang}" \
  "/p;lang=en" \
  lang=en

# 11. Path-style ; array explode
run_test "matrix-array-explode" \
  "/p{;opt*}" \
  "/p;opt=a;opt=b" \
  "opt=a|b"

# 12. Path-style ; array no explode
run_test "matrix-array-no-explode" \
  "/p{;opt}" \
  "/p;opt=a,b" \
  "opt=a|b"

# 13. Path-style ; dict explode (note k2 without value)
run_test "matrix-dict-explode" \
  "/p{;params*}" \
  "/p;k1=v1;k2" \
  "params=k1:v1|k2:"

# 14. Path-style ; dict no explode
run_test "matrix-dict-no-explode" \
  "/p{;params}" \
  "/p;params=k1,v1,k2," \
  "params=k1:v1|k2:"

# 15. Query {?} simple with encoding
run_test "query-simple" \
  "/search{?q}" \
  "/search?q=go%20lang" \
  "q=go lang"

# 16. Query arrays explode {?colors*}
run_test "query-array-explode" \
  "{?colors*}" \
  "?colors=red&colors=gr%20een" \
  "colors=red|gr een"

# 17. Query arrays no explode {?colors}
run_test "query-array-no-explode" \
  "{?colors}" \
  "?colors=red,gr%20een" \
  "colors=red|gr een"

# 18. Query dict explode {?p*}
run_test "query-dict-explode" \
  "{?p*}" \
  "?a=1&b=2" \
  "p=a:1|b:2"

# 19. Query dict no explode {?p}
run_test "query-dict-no-explode" \
  "{?p}" \
  "?p=a,1,b,2" \
  "p=a:1|b:2"

# 20. Query continuation {&var}
run_test "query-cont" \
  "/x?a=1{&b}" \
  "/x?a=1&b=2" \
  b=2

# 21. Query continuation with missing var (placeholder removed)
run_test "query-cont-missing" \
  "/x?a=1{&c}" \
  "/x?a=1" \
  "b=2"

# 22. Multiple variables in one expression for labels
run_test "multi-vars-label" \
  "{.d,sub}" \
  ".a.b" \
  d=a sub=b

# 23. Missing variable deletes entire placeholder (including operator)
run_test "missing-var-removal" \
  "/x{?none}" \
  "/x"

# 24. Explode on scalar is effectively same as non-explode
run_test "scalar-explode-query" \
  "{?x*}" \
  "?x=v" \
  x=v

# 25. {+var} with dict explode (non-encoding here)
run_test "reserved-dict-explode" \
  "{+p*}" \
  "a:/,b:~" \
  "p=a:/|b:~"

# 26. Fragment with multiple vars (comma-joined)
run_test "fragment-multi" \
  "{#a,b}" \
  "#foo,bar baz" \
  a=foo "b=bar baz"

###############################################################################
# SUMMARY
###############################################################################
printf "\n"
if [ "$fail" -eq 0 ]; then
  printf "%sAll %d tests passed.%s\n" "$GRN" "$tests" "$RST"
  exit 0
else
  printf "%s%d passed, %d failed (total %d).%s\n" "$YEL" "$pass" "$fail" "$tests" "$RST"
  exit 1
fi
