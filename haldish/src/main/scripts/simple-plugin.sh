#!/usr/bin/env bash

# simple-plugin.sh can be used as a starting point for other pligins
# to be used with nahal.sh to manually discover HAL-base API
# of the deployed and running server
#
# Contract:
#   STDIN  : basename of previous response files
#   $1     : yq path to selected HAL link
#   $2..N  : key=value pairs for URI Template expansion of the templated link
#
# The different parts of the previous response already saved in the files with
# the same base name and follow extensions:
#   <base-name>.code    : HTTP response code
#   <base-name>.body    : the body of the HTTP response (usually HAL resource)
#   <base-name>.headers : the headers of the HTTP response
#   <base-name>.cookies : the cookies extracted and removed from the headers
#   <base-name>.url     : the URL, the request was sent to
#
# Output:
#   Final URL (printed to stdout)
#

set -euo pipefail

YQ_CMD="yq"

# --- read inputs -------------------------------------------------------------

BASENAME="$(cat | tr -d '\n')"
LINK_PATH="${1:-}"
shift || true

KV_PAIRS=("$@")

[[ -n "$BASENAME" ]] || { echo "simple-plugin: empty basename" >&2; exit 1; }
[[ -n "$LINK_PATH" ]] || { echo "simple-plugin: missing link path" >&2; exit 1; }

# --- locate payload ----------------------------------------------------------

PAYLOAD=""
for f in \
  "${BASENAME}.body" \
  "${BASENAME}.json" \
  "${BASENAME}.payload" \
  "${BASENAME}.response" \
  "${BASENAME}"
do
  if [[ -f "$f" ]]; then
    PAYLOAD="$f"
    break
  fi
done

[[ -n "$PAYLOAD" ]] || {
  echo "simple-plugin: cannot locate payload for basename: $BASENAME" >&2
  exit 1
}

# --- extract href and templated flag ------------------------------------------

HREF="$("$YQ_CMD" -r "${LINK_PATH}.href // \"\"" "$PAYLOAD")"
TEMPLATED="$("$YQ_CMD" -r "${LINK_PATH}.templated // false" "$PAYLOAD")"

[[ -n "$HREF" ]] || {
  echo "simple-plugin: link has no href at path: $LINK_PATH" >&2
  exit 1
}

# --- expand URI template if needed -------------------------------------------

URL="$HREF"

if [[ "$TEMPLATED" == "true" ]]; then
  # uritengin.sh interface example:
  #   uritengin.sh "<template>" key=value key=value ...
  URL="$(echo "$HREF" | uritengin.sh "${KV_PAIRS[@]}")"
fi

# --- output ------------------------------------------------------------------

printf '%s\n' "$URL"
