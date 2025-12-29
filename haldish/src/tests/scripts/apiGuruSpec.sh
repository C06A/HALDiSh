#!/usr/bin/env bash

. $(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)/specSetup.sh
setup apiGuru

[ $(ls -l ./* 2>/dev/null| wc -l) -le 0 ] || rm ./*

VALIDATOR=$(dirname $(command -v validator.sh))

API_GURU_PROVIDERS="https://api.apis.guru/v2/providers.json"
API_GURU_TEMPLATE="https://api.apis.guru/v2{/endpoint}.json"

# tag::sampleApiGuru.sh[]
#!/usr/bin/env bash

# tag::sourcingValidator[]
. $VALIDATOR/validator.sh >/dev/null
# end::sourcingValidator[]

# Send the GET request to the $API_GURU_PROVIDERS URL,
# rename all created files to have "providers" base name,
# combine all thous files as tagged ranges in the $ASCII_DOC_FILE
GET "$API_GURU_PROVIDERS" 2>/dev/null \
    | rename.sh "providers" 2>/dev/null \
    | adoc.sh 2>/dev/null >"$ASCII_DOC_FILE"

# Extract the name of the first API from the list
API_NAME=$(jq -r .data[1] "providers.body" )

# Take the URI template from the environment variable $API_GURU_TEMPLATE,
# insert the $API_NAME value as an endpoint expression,
# send GET request to resulted URL,
# rename all created files to have base name from the $API_NAME,
# and finally append them into $ASCII_DOC_FILE file
echo "$API_GURU_TEMPLATE" \
    | uritengin.sh endpoint="$API_NAME" \
    | GET -- 2>/dev/null \
    | rename.sh "$API_NAME" 2>/dev/null \
    | adoc.sh 2>/dev/null >>"$ASCII_DOC_FILE"

# Extract URL to get the Logo image
LOGO_FILE=$(jq -r ".apis.\"$API_NAME\".info.\"x-logo\".url" "$API_NAME.body" )

# Delete created files as they are not needed any more
rm "$API_NAME."*

# Send request to the Logo URL and rename resulting files
GET "$LOGO_FILE" 2>/dev/null \
    | rename.sh "${API_NAME}_logo" >/dev/null 2>&1

# Because this service doesn't support HAL, the type of the Logo image
# can be deducted from the extension of the URL.
# The HAL resource link contains the "type" field,
# which can be used to deduct the type of the downloaded body.
LOGO_EXT="${LOGO_FILE##*.}"

# Rename Logo file to have the proper extension
mv "${API_NAME}_logo.body" "$API_NAME.$LOGO_EXT"

# Remove unneeded files
rm "${API_NAME}_logo."*
# end::sampleApiGuru.sh[]
