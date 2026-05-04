#!/usr/bin/env bats
# =============================================================================
# httpreq.bats — unit tests for httpreq.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

HTTPREQ_SH="${SCRIPTS_DIR}/httpreq.sh"

# ── test infrastructure ───────────────────────────────────────────────────────

setup() {
    WORK_DIR="$(mktemp -d)"
    MOCK_DIR="$(mktemp -d)"
    MOCK_ARGS_FILE="${MOCK_DIR}/curl_args"
    export MOCK_ARGS_FILE

    # Default mock curl: writes null-delimited args, fakes a 200 response with
    # one Set-Cookie header and two regular headers.
    cat > "${MOCK_DIR}/curl" << 'MOCK'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${MOCK_ARGS_FILE}"
args=("$@")
hfile=''
bfile=''
i=0
while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
        -D) hfile="${args[$((i+1))]}"; i=$(( i+2 )) ;;
        -o) bfile="${args[$((i+1))]}"; i=$(( i+2 )) ;;
        *)  i=$(( i+1 )) ;;
    esac
done
if [[ -n "$hfile" ]]; then
    printf 'HTTP/1.1 200 OK\r\n'                          > "$hfile"
    printf 'Content-Type: application/json\r\n'          >> "$hfile"
    printf 'Set-Cookie: session=abc123; Path=/; HttpOnly\r\n' >> "$hfile"
    printf 'X-Request-Id: test-42\r\n'                   >> "$hfile"
    printf '\r\n'                                        >> "$hfile"
fi
[[ -n "$bfile" ]] && printf '{"ok":true}' > "$bfile"
printf '200'
MOCK
    chmod +x "${MOCK_DIR}/curl"
    export PATH="${MOCK_DIR}:${PATH}"

    # Create method-named symlinks for basename tests
    ln -s "$HTTPREQ_SH" "${WORK_DIR}/GET"
    ln -s "$HTTPREQ_SH" "${WORK_DIR}/POST"
    ln -s "$HTTPREQ_SH" "${WORK_DIR}/PUT"
}

teardown() {
    rm -rf "$WORK_DIR" "$MOCK_DIR"
}

# Run a request from WORK_DIR. $1 = method name (symlink), rest = args to script.
# Output files land in WORK_DIR; stdout is the base name.
_run_req() {
    local method="$1"; shift
    run bash -c "cd '$WORK_DIR' && '${WORK_DIR}/${method}' $(printf '%q ' "$@")"
}

# Read the mock curl args (null-delimited) into global array _curl_args.
_read_curl_args() {
    mapfile -d '' _curl_args < "$MOCK_ARGS_FILE"
}

# Return 0 if $1 appears anywhere in the mock curl args.
_curl_has() {
    _read_curl_args
    local a
    for a in "${_curl_args[@]}"; do [[ "$a" == "$1" ]] && return 0; done
    return 1
}

# Return 0 if the sequence $1 $2 appears consecutively in the mock curl args.
_curl_has_seq() {
    _read_curl_args
    local i
    for (( i=0; i < ${#_curl_args[@]}-1; i++ )); do
        [[ "${_curl_args[$i]}" == "$1" && "${_curl_args[$((i+1))]}" == "$2" ]] && return 0
    done
    return 1
}

# ── method detection ──────────────────────────────────────────────────────────

@test "httpreq: GET method derived from symlink named GET" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq -X GET
}

@test "httpreq: POST method derived from symlink named POST" {
    _run_req POST 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq -X POST
}

@test "httpreq: PUT method derived from symlink named PUT" {
    _run_req PUT 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq -X PUT
}

# ── URL handling ──────────────────────────────────────────────────────────────

@test "httpreq: URL from first argument is forwarded to curl" {
    _run_req GET 'https://api.example.com/v1/items'
    [ "$status" -eq 0 ]
    _curl_has 'https://api.example.com/v1/items'
}

@test "httpreq: URL read from stdin when first arg is --" {
    run bash -c "cd '$WORK_DIR' && echo 'https://api.example.com/from-stdin' | '${WORK_DIR}/GET' --"
    [ "$status" -eq 0 ]
    _curl_has 'https://api.example.com/from-stdin'
}

@test "httpreq: URL read from stdin when no arguments given" {
    run bash -c "cd '$WORK_DIR' && echo 'https://api.example.com/no-args' | '${WORK_DIR}/GET'"
    [ "$status" -eq 0 ]
    _curl_has 'https://api.example.com/no-args'
}

@test "httpreq: body flags after -- are applied to the request" {
    run bash -c "cd '$WORK_DIR' && echo 'https://example.com/' | '${WORK_DIR}/POST' -- -a 'key=val'"
    [ "$status" -eq 0 ]
    _curl_has_seq --data 'key=val'
}

# ── output files existence ────────────────────────────────────────────────────

@test "httpreq: .curl file is created after request" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/${output}.curl" ]
}

@test "httpreq: .status file is created after request" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/${output}.status" ]
}

@test "httpreq: .headers file is created after request" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/${output}.headers" ]
}

@test "httpreq: .cookies file is created after request" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/${output}.cookies" ]
}

@test "httpreq: .body file is created after request" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/${output}.body" ]
}

# ── output file contents ──────────────────────────────────────────────────────

@test "httpreq: .code file contains HTTP code from curl" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [ "$(cat "${WORK_DIR}/${output}.code")" = '200' ]
}

@test "httpreq: .body file contains response body" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [ "$(cat "${WORK_DIR}/${output}.body")" = '{"ok":true}' ]
}

# ── .headers file format ──────────────────────────────────────────────────────

@test "httpreq: .headers file excludes the HTTP status line" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    ! grep -q '^HTTP/' "${WORK_DIR}/${output}.headers"
}

@test "httpreq: .headers file excludes Set-Cookie lines" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    ! grep -qi '^Set-Cookie' "${WORK_DIR}/${output}.headers"
}

@test "httpreq: .headers file contains other response headers in Name: Value format" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    grep -q 'X-Request-Id: test-42' "${WORK_DIR}/${output}.headers"
}

# ── .cookies file parsing ─────────────────────────────────────────────────────

@test "httpreq: .cookies file contains name=value from Set-Cookie header" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    grep -q 'session=abc123' "${WORK_DIR}/${output}.cookies"
}

@test "httpreq: .cookies file strips cookie attributes (Path, HttpOnly, etc.)" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    # Must contain name=value and must NOT contain the attributes
    ! grep -q 'Path=' "${WORK_DIR}/${output}.cookies"
    ! grep -q 'HttpOnly' "${WORK_DIR}/${output}.cookies"
}

@test "httpreq: multiple Set-Cookie headers produce multiple lines in .cookies" {
    # Override mock to emit two Set-Cookie headers
    cat > "${MOCK_DIR}/curl" << 'MOCK'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${MOCK_ARGS_FILE}"
args=("$@"); hfile=''; bfile=''; i=0
while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
        -D) hfile="${args[$((i+1))]}"; i=$(( i+2 )) ;;
        -o) bfile="${args[$((i+1))]}"; i=$(( i+2 )) ;;
        *)  i=$(( i+1 )) ;;
    esac
done
if [[ -n "$hfile" ]]; then
    printf 'HTTP/1.1 200 OK\r\n'                           > "$hfile"
    printf 'Set-Cookie: session=abc; Path=/\r\n'          >> "$hfile"
    printf 'Set-Cookie: lang=en; Path=/\r\n'              >> "$hfile"
    printf '\r\n'                                         >> "$hfile"
fi
[[ -n "$bfile" ]] && : > "$bfile"
printf '200'
MOCK
    chmod +x "${MOCK_DIR}/curl"
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [ "$(wc -l < "${WORK_DIR}/${output}.cookies")" -eq 2 ]
    grep -q 'session=abc' "${WORK_DIR}/${output}.cookies"
    grep -q 'lang=en'     "${WORK_DIR}/${output}.cookies"
}

# ── output file naming ────────────────────────────────────────────────────────

@test "httpreq: stdout prints the base name (domain_timestamp)" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[^_]+_[0-9]+$ ]]
}

@test "httpreq: output file prefix is the domain from the URL" {
    _run_req GET 'https://api.example.com/v1/users?page=1'
    [ "$status" -eq 0 ]
    [[ "$output" == api.example.com_* ]]
}

@test "httpreq: output file prefix excludes scheme, path, and port" {
    _run_req GET 'https://host.example.com:8443/some/path'
    [ "$status" -eq 0 ]
    [[ "$output" == host.example.com_* ]]
}

# ── .curl file content ────────────────────────────────────────────────────────

@test "httpreq: .curl file starts with 'curl'" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    [[ "$(head -1 "${WORK_DIR}/${output}.curl")" == curl\ * ]]
}

@test "httpreq: .curl file contains the request URL" {
    _run_req GET 'https://example.com/path'
    [ "$status" -eq 0 ]
    grep -qF 'https://example.com/path' "${WORK_DIR}/${output}.curl"
}

@test "httpreq: .curl file contains -i flag when -i is passed" {
    _run_req GET 'https://example.com/' -i
    [ "$status" -eq 0 ]
    grep -qw '\-i' "${WORK_DIR}/${output}.curl"
}

@test "httpreq: .curl file does not contain -i flag when -i is not passed" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    ! grep -qw '\-i' "${WORK_DIR}/${output}.curl"
}

@test "httpreq: .curl file does not contain -D flag" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    ! grep -qw '\-D' "${WORK_DIR}/${output}.curl"
}

@test "httpreq: .curl file does not contain -o flag" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    ! grep -qw '\-o' "${WORK_DIR}/${output}.curl"
}

@test "httpreq: .curl file does not contain --write-out flag" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    ! grep -q '\-\-write-out' "${WORK_DIR}/${output}.curl"
}

@test "httpreq: .curl file does not contain --silent flag" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    ! grep -q '\-\-silent' "${WORK_DIR}/${output}.curl"
}

# ── .curl file multi-line format ──────────────────────────────────────────────

@test "httpreq: .curl file spans multiple lines (at least 3 for a simple GET)" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    local curl_file="${WORK_DIR}/${output}.curl"
    local line_count
    line_count=$(wc -l < "$curl_file")
    [ "$line_count" -ge 3 ]
}

@test "httpreq: .curl file first line is 'curl \\'" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    local first_line
    first_line=$(head -1 "${WORK_DIR}/${output}.curl")
    [ "$first_line" = 'curl \' ]
}

@test "httpreq: .curl file continuation lines are indented with exactly 4 spaces" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    local curl_file="${WORK_DIR}/${output}.curl"
    # Every line after the first must start with 4 spaces (flag/value or URL lines).
    # grep -v returns 1 when no lines match (all pass), so use || true to avoid
    # a false failure under set -euo pipefail.
    local bad
    bad=$(tail -n +2 "$curl_file" | grep -v '^    ' || true)
    [ -z "$bad" ]
}

@test "httpreq: .curl file flag+value pair appears on same indented line" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    # -X and GET must appear together on one continuation line
    grep -qE '^    -X GET( \\)?$' "${WORK_DIR}/${output}.curl"
}

@test "httpreq: .curl file URL appears on its own continuation line" {
    _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    grep -qF '    https://example.com/' "${WORK_DIR}/${output}.curl"
    # URL line must be on its own (not combined with a flag)
    ! grep -qE '^\s+-[A-Za-z].*https://' "${WORK_DIR}/${output}.curl"
}

@test "httpreq: .curl file with --header spans across multiple lines" {
    HTTP_IN_HEADERS='Authorization: Bearer token123' \
        _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    local line_count
    line_count=$(wc -l < "${WORK_DIR}/${output}.curl")
    [ "$line_count" -ge 4 ]
    grep -qE '^    --header ' "${WORK_DIR}/${output}.curl"
}

# ── HTTP_IN_HEADERS env var ───────────────────────────────────────────────────

@test "httpreq: HTTP_IN_HEADERS single header becomes --header curl arg" {
    HTTP_IN_HEADERS='Authorization: Bearer token123' \
        _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq --header 'Authorization: Bearer token123'
}

@test "httpreq: HTTP_IN_HEADERS multiple headers each become separate --header args" {
    HTTP_IN_HEADERS=$'Accept: application/json\nX-Api-Version: 2' \
        _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq --header 'Accept: application/json'
    _curl_has_seq --header 'X-Api-Version: 2'
}

@test "httpreq: HTTP_IN_HEADERS blank lines are ignored" {
    HTTP_IN_HEADERS=$'Accept: text/plain\n\nX-Custom: val' \
        _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    # Exactly 2 --header args, not 3
    _read_curl_args
    local count=0 a
    for a in "${_curl_args[@]}"; do [[ "$a" == '--header' ]] && count=$(( count + 1 )); done
    [ "$count" -eq 2 ]
}

# ── HTTP_IN_HEADERS_FILE ──────────────────────────────────────────────────────

@test "httpreq: HTTP_IN_HEADERS_FILE headers are added to request" {
    printf 'X-From-File: yes\nX-Version: 3\n' > "${WORK_DIR}/hdrs.txt"
    HTTP_IN_HEADERS_FILE="${WORK_DIR}/hdrs.txt" \
        _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq --header 'X-From-File: yes'
    _curl_has_seq --header 'X-Version: 3'
}

# ── HTTP_IN_COOKIES env var ───────────────────────────────────────────────────

@test "httpreq: HTTP_IN_COOKIES single cookie becomes --cookie curl arg" {
    HTTP_IN_COOKIES='token=abc123' \
        _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq --cookie 'token=abc123'
}

@test "httpreq: HTTP_IN_COOKIES multiple cookies are joined with semicolon" {
    HTTP_IN_COOKIES=$'token=abc\nlang=en' \
        _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq --cookie 'token=abc; lang=en'
}

# ── HTTP_IN_COOKIES_FILE ──────────────────────────────────────────────────────

@test "httpreq: HTTP_IN_COOKIES_FILE cookies are combined with env cookies" {
    printf 'from_file=1\n' > "${WORK_DIR}/cookies.txt"
    HTTP_IN_COOKIES='from_env=2' \
    HTTP_IN_COOKIES_FILE="${WORK_DIR}/cookies.txt" \
        _run_req GET 'https://example.com/'
    [ "$status" -eq 0 ]
    _curl_has_seq --cookie 'from_env=2; from_file=1'
}

# ── body flag: -a ─────────────────────────────────────────────────────────────

@test "httpreq: -a with text adds --data to curl args" {
    _run_req POST 'https://example.com/' -a 'hello=world'
    [ "$status" -eq 0 ]
    _curl_has_seq --data 'hello=world'
}

@test "httpreq: -a without param reads data from stdin" {
    run bash -c "cd '$WORK_DIR' && echo 'stdin-body' | '${WORK_DIR}/POST' 'https://example.com/' -a"
    [ "$status" -eq 0 ]
    _curl_has_seq --data 'stdin-body'
}

# ── body flag: -u ─────────────────────────────────────────────────────────────

@test "httpreq: -u with text adds --data-urlencode to curl args" {
    _run_req POST 'https://example.com/' -u 'q=hello world'
    [ "$status" -eq 0 ]
    _curl_has_seq --data-urlencode 'q=hello world'
}

@test "httpreq: -u without param reads text from stdin" {
    run bash -c "cd '$WORK_DIR' && echo 'my query' | '${WORK_DIR}/POST' 'https://example.com/' -u"
    [ "$status" -eq 0 ]
    _curl_has_seq --data-urlencode 'my query'
}

# ── body flag: -f ─────────────────────────────────────────────────────────────

@test "httpreq: -f with filename adds --form basename=@file to curl args" {
    printf 'data\n' > "${WORK_DIR}/upload.txt"
    _run_req POST 'https://example.com/' -f "${WORK_DIR}/upload.txt"
    [ "$status" -eq 0 ]
    _curl_has_seq --form "upload.txt=@${WORK_DIR}/upload.txt"
}

@test "httpreq: -f form field name uses basename, not full path" {
    printf 'data\n' > "${WORK_DIR}/report.csv"
    _run_req POST 'https://example.com/' -f "${WORK_DIR}/report.csv"
    [ "$status" -eq 0 ]
    # --form value should start with the basename, not the full directory path
    _read_curl_args
    local i found=0
    for (( i=0; i < ${#_curl_args[@]}-1; i++ )); do
        if [[ "${_curl_args[$i]}" == '--form' && "${_curl_args[$((i+1))]}" == report.csv=@* ]]; then
            found=1; break
        fi
    done
    [ "$found" -eq 1 ]
}

@test "httpreq: multiple -f flags each add a separate --form part" {
    printf 'a\n' > "${WORK_DIR}/file1.txt"
    printf 'b\n' > "${WORK_DIR}/file2.txt"
    _run_req POST 'https://example.com/' \
        -f "${WORK_DIR}/file1.txt" \
        -f "${WORK_DIR}/file2.txt"
    [ "$status" -eq 0 ]
    _curl_has_seq --form "file1.txt=@${WORK_DIR}/file1.txt"
    _curl_has_seq --form "file2.txt=@${WORK_DIR}/file2.txt"
}

@test "httpreq: -f without param adds --data-binary @- (raw stdin, not multipart)" {
    run bash -c "cd '$WORK_DIR' && echo 'raw-body' | '${WORK_DIR}/POST' 'https://example.com/' -f"
    [ "$status" -eq 0 ]
    _curl_has_seq --data-binary @-
    ! _curl_has --form
}

@test "httpreq: -f with name=path uses the explicit name as form field name" {
    printf 'data\n' > "${WORK_DIR}/test.file"
    _run_req POST 'https://example.com/' -f "files=${WORK_DIR}/test.file"
    [ "$status" -eq 0 ]
    _curl_has_seq --form "files=@${WORK_DIR}/test.file"
}

@test "httpreq: -f with name=path does not use basename as field name" {
    printf 'data\n' > "${WORK_DIR}/test.file"
    _run_req POST 'https://example.com/' -f "files=${WORK_DIR}/test.file"
    [ "$status" -eq 0 ]
    ! _curl_has_seq --form "test.file=@${WORK_DIR}/test.file"
}

@test "httpreq: -f with name=path preserves path with equals sign in filename" {
    mkdir -p "${WORK_DIR}/sub"
    printf 'data\n' > "${WORK_DIR}/sub/a=b.txt"
    _run_req POST 'https://example.com/' -f "myfield=${WORK_DIR}/sub/a=b.txt"
    [ "$status" -eq 0 ]
    _curl_has_seq --form "myfield=@${WORK_DIR}/sub/a=b.txt"
}

# ── body flag: -F ─────────────────────────────────────────────────────────────

@test "httpreq: -F name=value adds --form text field to curl args" {
    _run_req POST 'https://example.com/' -F 'type=file'
    [ "$status" -eq 0 ]
    _curl_has_seq --form 'type=file'
}

@test "httpreq: multiple -F flags each add a separate --form text part" {
    _run_req POST 'https://example.com/' -F 'type=file' -F 'version=2'
    [ "$status" -eq 0 ]
    _curl_has_seq --form 'type=file'
    _curl_has_seq --form 'version=2'
}

@test "httpreq: -F and -f can be combined in the same request" {
    printf 'data\n' > "${WORK_DIR}/upload.txt"
    _run_req POST 'https://example.com/' -F 'type=document' -f "${WORK_DIR}/upload.txt"
    [ "$status" -eq 0 ]
    _curl_has_seq --form 'type=document'
    _curl_has_seq --form "upload.txt=@${WORK_DIR}/upload.txt"
}

@test "httpreq: -F with name=path and -f with name=path build the target curl command" {
    printf 'data\n' > "${WORK_DIR}/test.file"
    _run_req POST 'https://example.com/' -F 'type=file' -f "files=${WORK_DIR}/test.file"
    [ "$status" -eq 0 ]
    _curl_has_seq --form 'type=file'
    _curl_has_seq --form "files=@${WORK_DIR}/test.file"
}

@test "httpreq: -F value appears in .curl replay file" {
    _run_req POST 'https://example.com/' -F 'type=document'
    [ "$status" -eq 0 ]
    grep -qF 'type=document' "${WORK_DIR}/${output}.curl"
}

# ── body flag: -b ─────────────────────────────────────────────────────────────

@test "httpreq: -b with filename adds --data-binary @file to curl args" {
    printf '\x00\x01\x02' > "${WORK_DIR}/bin.dat"
    _run_req POST 'https://example.com/' -b "${WORK_DIR}/bin.dat"
    [ "$status" -eq 0 ]
    _curl_has_seq --data-binary "@${WORK_DIR}/bin.dat"
}

@test "httpreq: -b without param adds --data-binary @-" {
    run bash -c "cd '$WORK_DIR' && echo 'data' | '${WORK_DIR}/POST' 'https://example.com/' -b"
    [ "$status" -eq 0 ]
    _curl_has_seq --data-binary @-
}

# ── body flag: -r ─────────────────────────────────────────────────────────────

@test "httpreq: -r with filename adds --upload-file to curl args" {
    printf 'contents\n' > "${WORK_DIR}/payload.bin"
    _run_req PUT 'https://example.com/resource' -r "${WORK_DIR}/payload.bin"
    [ "$status" -eq 0 ]
    _curl_has_seq --upload-file "${WORK_DIR}/payload.bin"
}

@test "httpreq: -r without param adds --upload-file -" {
    run bash -c "cd '$WORK_DIR' && echo 'stream' | '${WORK_DIR}/PUT' 'https://example.com/' -r"
    [ "$status" -eq 0 ]
    _curl_has_seq --upload-file -
}

# ── --link flag ───────────────────────────────────────────────────────────────

@test "httpreq: --link inline JSON uses href as the request URL" {
    _run_req GET '--link' '{"href":"https://link.example.com/"}'
    [ "$status" -eq 0 ]
    _curl_has 'https://link.example.com/'
}

@test "httpreq: --link with type field adds Accept header to request" {
    _run_req GET '--link' '{"href":"https://example.com/","type":"application/hal+json"}'
    [ "$status" -eq 0 ]
    _curl_has_seq --header 'Accept: application/hal+json'
}

@test "httpreq: --link without type field does not inject Accept header" {
    _run_req GET '--link' '{"href":"https://example.com/"}'
    [ "$status" -eq 0 ]
    _read_curl_args
    local i found=0
    for (( i=0; i < ${#_curl_args[@]}-1; i++ )); do
        if [[ "${_curl_args[$i]}" == '--header' && "${_curl_args[$((i+1))]}" == "Accept:"* ]]; then
            found=1; break
        fi
    done
    [ "$found" -eq 0 ]
}

@test "httpreq: --link @file reads link JSON from a file" {
    printf '{"href":"https://file.example.com/"}' > "${WORK_DIR}/link.json"
    _run_req GET '--link' "@${WORK_DIR}/link.json"
    [ "$status" -eq 0 ]
    _curl_has 'https://file.example.com/'
}

@test "httpreq: --link reads link JSON from stdin when no argument given" {
    run bash -c "cd '$WORK_DIR' && printf '{\"href\":\"https://stdin.example.com/\"}' | '${WORK_DIR}/GET' --link"
    [ "$status" -eq 0 ]
    _curl_has 'https://stdin.example.com/'
}

@test "httpreq: --link passes body flags through to curl" {
    _run_req POST '--link' '{"href":"https://example.com/"}' -a 'key=val'
    [ "$status" -eq 0 ]
    _curl_has_seq --data 'key=val'
}

@test "httpreq: --link JSON object with no href field exits non-zero" {
    run bash -c "cd '$WORK_DIR' && '${WORK_DIR}/GET' --link '{\"title\":\"no href\"}'"
    [ "$status" -ne 0 ]
}

@test "httpreq: --link with no argument and empty stdin exits non-zero" {
    run bash -c "cd '$WORK_DIR' && '${WORK_DIR}/GET' --link < /dev/null"
    [ "$status" -ne 0 ]
}

@test "httpreq: --link relative href produces base name starting with 'hal_'" {
    _run_req GET '--link' '{"href":"/relative/path"}'
    [ "$status" -eq 0 ]
    [[ "$output" == hal_* ]]
}

@test "httpreq: --link type field appears as Accept header in .curl replay file" {
    _run_req GET '--link' '{"href":"https://example.com/","type":"application/hal+json"}'
    [ "$status" -eq 0 ]
    # .curl stores shell-quoted args; the space in the header value is backslash-escaped
    grep -qF 'Accept:\ application/hal+json' "${WORK_DIR}/${output}.curl"
}
