#!/usr/bin/env bash

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup thecolorapi

[ $(ls -1 | wc -l) -eq 0 ] || rm ./*

cd $(dirname $0); SCRIPT_DIR=$(pwd); cd - >/dev/null
VALIDATOR=$(dirname $(command -v validator.sh))

ASCII_DOC_FILE="thecolorapi.adoc"

check() {
  name=$1
  count=$2

  [ $(ls -1 "$name".* | wc -l) -eq $count ] || echo failure -- thecolorapi
}

COLOR_TEMPLATE="https://www.thecolorapi.com/id{?rgb,hex,hsl,hsv,cmyk,format,w,named}"
SCHEME_TEMPLATE="https://www.thecolorapi.com/scheme{?rgb,hex,hsl,hsv,cmyk,format,mode,count}"

NAME=thecolorapi_madison
EXIT_CODE=0
echo "$COLOR_TEMPLATE" | uritengin.sh rgb="10|50|90" type=id \
  | GET -- | rename.sh "$NAME" 2>/dev/null >/dev/null
[ -z "$(check "$NAME" 6)" ] || exit $((EXIT_CODE+1))

grep "nel: " "$NAME.headers" | dd bs=1 skip=5 2>/dev/null | jq -r . >"$NAME.nel"
[ -z "$(check "$NAME" 7)" ] || exit $((EXIT_CODE+2))

grep "report-to: " "$NAME.headers" | dd bs=1 skip=11 2>/dev/null | jq -r . >"$NAME.report_to"
[ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+3))

jq -r .endpoints[0].url "$NAME.report_to" | OPTIONS -- | rename.sh "${NAME}_report_to" 2>/dev/null >/dev/null

adoc.sh "$NAME" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+4))

NAMESVG="${NAME}_svg"
GET $(jq -r .image.named "$NAME.body") | rename.sh "$NAMESVG" 2>/dev/null >/dev/null
[ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+5))
adoc.sh "$NAMESVG" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+6))

cp "$NAMESVG.body" "$NAMESVG.svg"
[ $? -eq 0 ] || exit $((EXIT_CODE+7))
open "$NAMESVG.svg" &
[ $? -eq 0 ] || exit $((EXIT_CODE+8))



NAME=thecolorapi_tory_blue
EXIT_CODE=10
echo "$COLOR_TEMPLATE" | uritengin.sh hex="105090" type=id \
  | GET -- | rename.sh "$NAME" 2>/dev/null >/dev/null
[ -z "$(check "$NAME" 6)" ] || exit $((EXIT_CODE+1))

grep "nel: " "$NAME.headers" | dd bs=1 skip=5 2>/dev/null | jq -r . >"$NAME.nel"
[ -z "$(check "$NAME" 7)" ] || exit $((EXIT_CODE+2))

grep "report-to: " "$NAME.headers" | dd bs=1 skip=11 2>/dev/null | jq -r . >"$NAME.report_to"
[ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+3))

jq -r .endpoints[0].url "$NAME.report_to" | OPTIONS -- | rename.sh "${NAME}_report_to" 2>/dev/null >/dev/null

adoc.sh "$NAME" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+4))

NAMESVG="${NAME}_svg"
GET $(jq -r .image.named "$NAME.body") | rename.sh "$NAMESVG" 2>/dev/null >/dev/null
[ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+5))
adoc.sh "$NAMESVG" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+6))

cp "$NAMESVG.body" "$NAMESVG.svg"
[ $? -eq 0 ] || exit $((EXIT_CODE+7))
open "$NAMESVG.svg" &
[ $? -eq 0 ] || exit $((EXIT_CODE+8))



NAME=thecolorapi_pot_pourri
EXIT_CODE=20
echo "$COLOR_TEMPLATE" | uritengin.sh hsl="10|50%|90%" type=id \
  | GET -- | rename.sh "$NAME" 2>/dev/null >/dev/null
[ -z "$(check "$NAME" 6)" ] || exit $((EXIT_CODE+1))

grep "nel: " "$NAME.headers" | dd bs=1 skip=5 2>/dev/null | jq -r . >"$NAME.nel"
[ -z "$(check "$NAME" 7)" ] || exit $((EXIT_CODE+2))

grep "report-to: " "$NAME.headers" | dd bs=1 skip=11 2>/dev/null | jq -r . >"$NAME.report_to"
[ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+3))

jq -r .endpoints[0].url "$NAME.report_to" | OPTIONS -- | rename.sh "${NAME}_report_to" 2>/dev/null >/dev/null

adoc.sh "$NAME" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+4))

NAMESVG="${NAME}_svg"
GET $(jq -r .image.named "$NAME.body" ) | rename.sh "$NAMESVG" 2>/dev/null >/dev/null
[ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+5))
adoc.sh "$NAMESVG" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+6))

cp "$NAMESVG.body" "$NAMESVG.svg"
[ $? -eq 0 ] || exit $((EXIT_CODE+7))
open "$NAMESVG.svg" &
[ $? -eq 0 ] || exit $((EXIT_CODE+8))



NAME=thecolorapi_apricot
EXIT_CODE=30
echo "$COLOR_TEMPLATE" | uritengin.sh hsv="10|50|90" type=id \
  | GET -- | rename.sh "$NAME" 2>/dev/null >/dev/null
[ -z "$(check "$NAME" 6)" ] || exit $((EXIT_CODE+1))

grep "nel: " "$NAME.headers" | dd bs=1 skip=5 2>/dev/null | jq -r . >"$NAME.nel"
[ -z "$(check "$NAME" 7)" ] || exit $((EXIT_CODE+2))

grep "report-to: " "$NAME.headers" | dd bs=1 skip=11 2>/dev/null | jq -r . >"$NAME.report_to"
[ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+3))

jq -r .endpoints[0].url "$NAME.report_to" | OPTIONS -- | rename.sh "${NAME}_report_to" 2>/dev/null >/dev/null

adoc.sh "$NAME" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+4))

NAMESVG="${NAME}_svg"
GET $(jq -r .image.named "$NAME.body" ) | rename.sh "$NAMESVG" 2>/dev/null >/dev/null
[ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+5))
adoc.sh "$NAMESVG" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+6))

cp "$NAMESVG.body" "$NAMESVG.svg"
[ $? -eq 0 ] || exit $((EXIT_CODE+7))
open "$NAMESVG.svg" &
[ $? -eq 0 ] || exit $((EXIT_CODE+8))



NAME=thecolorapi_fuzzy_wuzzy
EXIT_CODE=40
echo "$COLOR_TEMPLATE" | uritengin.sh cmyk="100|90|50|10" type=id \
  | GET -- | rename.sh "$NAME" 2>/dev/null >/dev/null
[ -z "$(check "$NAME" 6)" ] || exit $((EXIT_CODE+1))

grep "nel: " "$NAME.headers" | dd bs=1 skip=5 2>/dev/null | jq -r . >"$NAME.nel"
[ -z "$(check "$NAME" 7)" ] || exit $((EXIT_CODE+2))

grep "report-to: " "$NAME.headers" | dd bs=1 skip=11 2>/dev/null | jq -r . >"$NAME.report_to"
[ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+3))

jq -r .endpoints[0].url "$NAME.report_to" | OPTIONS -- | rename.sh "${NAME}_report_to" 2>/dev/null >/dev/null

adoc.sh "$NAME" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAME" 8)" ] || exit $((EXIT_CODE+4))

NAMESVG="${NAME}_svg"
GET $(jq -r .image.named "$NAME.body" ) | rename.sh "$NAMESVG" 2>/dev/null >/dev/null
[ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+5))
adoc.sh "$NAMESVG" 2>/dev/null >"$ASCII_DOC_FILE"
[ -z "$(check "thecolorapi" 1)" ] && [ -z "$(check "$NAMESVG" 6)" ] || exit $((EXIT_CODE+6))

cp "$NAMESVG.body" "$NAMESVG.svg"
[ $? -eq 0 ] || exit $((EXIT_CODE+7))
open "$NAMESVG.svg" &
[ $? -eq 0 ] || exit $((EXIT_CODE+8))



NAME=thecolorapi_svg
EXIT_CODE=50
echo "$COLOR_TEMPLATE" | uritengin.sh rgb="90|50|10" type=id format=svg \
  | GET -- | rename.sh "$NAME" 2>/dev/null >/dev/null
[ -z "$(check "$NAME" 6)" ] || exit $((EXIT_CODE+1))

cp "$NAME.body" "$NAME.svg"
[ $? -eq 0 ] || exit $((EXIT_CODE+7))
open "$NAME.svg" &
[ $? -eq 0 ] || exit $((EXIT_CODE+8))


NAME=thecolorapi_html
open $(echo "$COLOR_TEMPLATE" | uritengin.sh rgb="10|50|90" type=id format=html)



NAME=thecolorapi_schema_svg
EXIT_CODE=60
echo "$SCHEME_TEMPLATE" | uritengin.sh hex="#0A325A" mode=quad format=svg \
  | GET -- | rename.sh "$NAME" 2>/dev/null >/dev/null
[ -z "$(check "$NAME" 6)" ] || exit $((EXIT_CODE+1))

cp "$NAME.body" "$NAME.svg"
[ $? -eq 0 ] || exit $((EXIT_CODE+7))
open "$NAME.svg" &
[ $? -eq 0 ] || exit $((EXIT_CODE+8))


NAME=thecolorapi_schema
open $(echo "$SCHEME_TEMPLATE" | uritengin.sh hex="#0A325A" mode=quad count=10 format=html)



cd - >/dev/null
