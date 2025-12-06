#!/usr/bin/env bash

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup apiGuru

[ $(ls -l ./* 2>/dev/null| wc -l) -le 0 ] || rm ./*

VALIDATOR=$(dirname $(command -v validator.sh))

ASCII_DOC_FILE=apiGuru.adoc

getProvider() {
    local API_NAME=$(jq -r ".data[$1]" "$PREV_NAME.body" )
    local OPEN=$2

    echo "$API_GURU_TEMPLATE" | uritengin.sh endpoint="$API_NAME" \
        | GET -- 2>/dev/null | rename.sh "$API_NAME" 2>/dev/null \
        | adoc.sh 2>/dev/null >>"$ASCII_DOC_FILE"

    local PROVIDER=$(jq -r ".apis|keys|.[0]" "$API_NAME.body")

    local LOGO_FILE=$(jq -r ".apis.\"$PROVIDER\".info.\"x-logo\".url" "$API_NAME.body" )
    echo "$LOGO_FILE" \
        | GET -- 2>/dev/null | rename.sh "${API_NAME}_logo" >/dev/null 2>&1

    local LOGO_EXT="${LOGO_FILE##*.}"

    jq -r ".apis.\"$PROVIDER\".swaggerUrl" "$API_NAME.body" \
        | GET -- 2>/dev/null | rename.sh "${API_NAME}_swagger" >/dev/null 2>&1

    rm "$API_NAME."*
    mv "${API_NAME}_logo.body" "$API_NAME.$LOGO_EXT"
    mv "${API_NAME}_swagger.body" "$API_NAME.swagger"

    echo -n ">>>> ${API_NAME}: "; jq -r .info.description "${API_NAME}.swagger" | head -1

    rm "${API_NAME}_logo."* "${API_NAME}_swagger."*

    [ -z "$OPEN" ] || open "$API_NAME.$LOGO_EXT"
}

# tag::sampleApiGuru.sh[]
#!/usr/bin/env bash

. $VALIDATOR/validator.sh >/dev/null

PREV_NAME=providers
API_GURU_PROVIDERS=$(jq -r "._links.\"$PREV_NAME\".href" $RESOURCES_DIR/apiGuru.hal )
API_GURU_TEMPLATE=$(jq -r "._links.endpoint.href" $RESOURCES_DIR/apiGuru.hal )

GET "$API_GURU_PROVIDERS" 2>/dev/null | rename.sh "$PREV_NAME" 2>/dev/null \
  | adoc.sh 2>/dev/null >"$ASCII_DOC_FILE"

API_NAME=$(jq -r .data[1] "$PREV_NAME.body" )

echo "$API_GURU_TEMPLATE" | uritengin.sh endpoint="$API_NAME" \
    | GET -- 2>/dev/null | rename.sh "$API_NAME" 2>/dev/null \
    | adoc.sh 2>/dev/null >>"$ASCII_DOC_FILE"

LOGO_FILE=$(jq -r ".apis.\"$API_NAME\".info.\"x-logo\".url" "$API_NAME.body" )

echo "$LOGO_FILE" \
    | GET -- 2>/dev/null | rename.sh "${API_NAME}_logo" >/dev/null 2>&1

LOGO_EXT="${LOGO_FILE##*.}"

jq -r ".apis.\"$API_NAME\".swaggerUrl" "$API_NAME.body" \
    | GET -- 2>/dev/null | rename.sh "${API_NAME}_swagger" >/dev/null 2>&1

rm "$API_NAME."*
mv "${API_NAME}_logo.body" "$API_NAME.$LOGO_EXT"
mv "${API_NAME}_swagger.body" "$API_NAME.swagger"

echo -n ">>>> ${API_NAME}: "; jq -r .info.description "${API_NAME}.swagger"

rm "${API_NAME}_logo."* "${API_NAME}_swagger."*
# end::sampleApiGuru.sh[]

COUNTER=$(jq ".data | length" "$PREV_NAME.body")
for (( i=2; i<COUNTER; i++ ))
do
  getProvider $i ""
done
