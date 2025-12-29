#!/usr/bin/env bash

# This script sends the HTTP request to the provided URL.
# It uses the name of the script as an HTTP Method,
# sets headers and cookies from environment variables or files,
# and, if provided, the body of the request from STDIN.
# The parts of the request and respond are saved to separate files
# for the future use.
# The base name of the created files is combined from the domain name
# of the URL and current timestamp to make it unique.
#
# The first argument is the URL to send request to.
# If the first argument is '--', the script reads URL from STDIN.
#
# The rest of the command line arguments (optional) are the files,
# to be sent as a body. If the value is '--' the content of STDIN
# will be sent as a body. If command contains more than 1 file,
# all their contents will be sent as multi-part body.
# If no files provided by the command, the request will contain no body.
#
# The script saves parts of the request and response in separate files
# with relevant extensions.
#
# The script uses follow environment variables, if set:
# -- HTTP_IN_HEADERS may contain HTTP headers, to send with request. Each header occupies separate line.
# -- HTTP_IN_HEADERS_FILE may contain the file path/name, where each line contains a separate header.
# -- HTTP_IN_COOKIES may contain HTTP cookies, to send with request. Each cookie occupies separate line.
# -- HTTP_IN_COOKIES_FILE may contain the file path/name, where each line contains a separate cookie.
#

# Determine HTTP method from script name
SCRIPT_NAME=$(basename "$0" .sh)
HTTP_METHOD=$(echo "$SCRIPT_NAME" | tr '[:lower:]' '[:upper:]')

# Get timestamp (milliseconds since epoch)
TIMESTAMP=$(date +%s%3N)

# Get URL from first argument
URL="$1"
if [ -z "$URL" ]
then
    echo "Error: URL is required as first argument" >&2
    exit 1
elif [ "$URL" = "--" ]
then
    IFS= read -r URL
fi

# Extract domain from URL
DOMAIN=$(echo "$URL" | sed -E 's|^https?://||' | sed -E 's|#.*$||' | sed -E 's|\?.*$||' | sed -E 's|/.*$||' | sed -E 's|:.*$||')

# Base filename
BASE_NAME="${DOMAIN}_${TIMESTAMP}"

# File paths
URL_FILE="${BASE_NAME}.url"
CURL_CMD_FILE="${BASE_NAME}.curl"
HTTP_CODE_FILE="${BASE_NAME}.code"
RESPONSE_HEADERS_FILE="${BASE_NAME}.headers"
RESPONSE_COOKIES_FILE="${BASE_NAME}.cookies"
RESPONSE_BODY_FILE="${BASE_NAME}.body"

# Temporary files
TEMP_HEADERS=$(mktemp)
TEMP_RESPONSE=$(mktemp)

# Cleanup on exit
trap "rm -f $TEMP_HEADERS $TEMP_RESPONSE" EXIT

# Save the URL
echo -e $URL >"$URL_FILE"

# Build curl command
CURL_CMD="curl -X $HTTP_METHOD"

# Add URL
CURL_CMD="$CURL_CMD \"$URL\""

# Add headers from HTTP_IN_HEADERS environment variable
if [ -n "$HTTP_IN_HEADERS" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && CURL_CMD="$CURL_CMD -H \"$line\""
    done <<< "$HTTP_IN_HEADERS"
fi

# Add headers from HTTP_IN_HEADERS_FILE
if [ -n "$HTTP_IN_HEADERS_FILE" ] && [ -f "$HTTP_IN_HEADERS_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && CURL_CMD="$CURL_CMD -H \"$line\""
    done < "$HTTP_IN_HEADERS_FILE"
fi

# Add cookies from HTTP_IN_COOKIES environment variable
if [ -n "$HTTP_IN_COOKIES" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && CURL_CMD="$CURL_CMD -b \"$line\""
    done <<< "$HTTP_IN_COOKIES"
fi

# Add cookies from HTTP_IN_COOKIES_FILE
if [ -n "$HTTP_IN_COOKIES_FILE" ] && [ -f "$HTTP_IN_COOKIES_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && CURL_CMD="$CURL_CMD -b \"$line\""
    done < "$HTTP_IN_COOKIES_FILE"
fi

# Handle body/files
shift # Remove URL from arguments

if [ "$1" == "--" ]; then
    # No files specified, use STDIN as body
    CURL_CMD="$CURL_CMD --data-binary @-"
else
    # Multiple files specified, send as multipart
    for file in "$@"; do
        if [ -f "$file" ]; then
            CURL_CMD="$CURL_CMD -F \"file=@$file\""
        else
            echo "Warning: File not found: $file" >&2
        fi
    done
fi

# Save curl command to file
echo "$CURL_CMD" > "$CURL_CMD_FILE"

# Add options to capture response details
CURL_CMD="$CURL_CMD -D \"$TEMP_HEADERS\" -o \"$TEMP_RESPONSE\" -w \"%{http_code}\" -s"

# Execute curl command
HTTP_CODE=$(eval "$CURL_CMD")

# Save HTTP code
echo "$HTTP_CODE" > "$HTTP_CODE_FILE"

# Process response headers
if [ -f "$TEMP_HEADERS" ]; then
    # Skip HTTP status line and extract headers
    sed '1d' "$TEMP_HEADERS" | grep -v '^$' > "$RESPONSE_HEADERS_FILE"
fi

# Extract cookies from response headers
if [ -f "$TEMP_HEADERS" ]; then
    grep -i '^Set-Cookie:' "$TEMP_HEADERS" | sed 's/^Set-Cookie: //i' | sed 's/;.*$//' > "$RESPONSE_COOKIES_FILE"
fi

# Save response body
if [ -f "$TEMP_RESPONSE" ]; then
    cp "$TEMP_RESPONSE" "$RESPONSE_BODY_FILE"
fi

# Output base filename (without extension) to STDOUT
echo "$BASE_NAME"

exit 0
