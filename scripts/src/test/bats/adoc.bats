#!/usr/bin/env bats
# =============================================================================
# adoc.bats — unit tests for adoc.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

ADOC_SH="${SCRIPTS_DIR}/adoc.sh"

setup() {
    WORK_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# Helper: run adoc.sh from WORK_DIR
_adoc() {
    run bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' $(printf '%q ' "$@")"
}

# ── argument validation ───────────────────────────────────────────────────────

@test "adoc: exits 0 with no output when no arguments and stdin is empty" {
    run bash "$ADOC_SH" < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── tag format ────────────────────────────────────────────────────────────────

@test "adoc: output contains opening tag comment" {
    printf 'hello' > "${WORK_DIR}/foo.txt"
    _adoc foo
    [[ "$output" == *'// tag::foo.txt[]'* ]]
}

@test "adoc: output contains closing tag comment" {
    printf 'hello' > "${WORK_DIR}/foo.txt"
    _adoc foo
    [[ "$output" == *'// end::foo.txt[]'* ]]
}

@test "adoc: tag name includes the file extension" {
    printf 'content' > "${WORK_DIR}/base.status"
    _adoc base
    [[ "$output" == *'// tag::base.status[]'* ]]
}

@test "adoc: file content appears between tag and end markers" {
    printf 'mycontent' > "${WORK_DIR}/foo.body"
    _adoc foo
    [[ "$output" == *'// tag::foo.body[]'*'mycontent'*'// end::foo.body[]'* ]]
}

# ── multiple files per base ───────────────────────────────────────────────────

@test "adoc: emits a tagged region for each file in the group" {
    printf '200'     > "${WORK_DIR}/req.status"
    printf 'ok'      > "${WORK_DIR}/req.body"
    _adoc req
    [[ "$output" == *'// tag::req.status[]'* ]]
    [[ "$output" == *'// tag::req.body[]'* ]]
}

@test "adoc: httpreq five-file group all appear in output" {
    printf 'curl -X GET x' > "${WORK_DIR}/r.curl"
    printf '200'            > "${WORK_DIR}/r.status"
    printf 'X-Foo: bar'    > "${WORK_DIR}/r.headers"
    printf 'tok=abc'        > "${WORK_DIR}/r.cookies"
    printf '{"a":1}'        > "${WORK_DIR}/r.body"
    _adoc r
    [[ "$output" == *'// tag::r.curl[]'*    ]]
    [[ "$output" == *'// tag::r.status[]'*  ]]
    [[ "$output" == *'// tag::r.headers[]'* ]]
    [[ "$output" == *'// tag::r.cookies[]'* ]]
    [[ "$output" == *'// tag::r.body[]'*    ]]
}

# ── multiple base names ───────────────────────────────────────────────────────

@test "adoc: processes multiple base names from arguments" {
    printf 'a' > "${WORK_DIR}/foo.txt"
    printf 'b' > "${WORK_DIR}/bar.txt"
    _adoc foo bar
    [[ "$output" == *'// tag::foo.txt[]'* ]]
    [[ "$output" == *'// tag::bar.txt[]'* ]]
}

@test "adoc: reads multiple base names from stdin" {
    printf 'a' > "${WORK_DIR}/foo.txt"
    printf 'b' > "${WORK_DIR}/bar.txt"
    run bash -c "cd '${WORK_DIR}' && printf 'foo\nbar\n' | bash '${ADOC_SH}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'// tag::foo.txt[]'* ]]
    [[ "$output" == *'// tag::bar.txt[]'* ]]
}

@test "adoc: stdin mode skips blank lines" {
    printf 'x' > "${WORK_DIR}/foo.txt"
    run bash -c "cd '${WORK_DIR}' && printf '\nfoo\n\n' | bash '${ADOC_SH}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'// tag::foo.txt[]'* ]]
}

# ── no matching files ─────────────────────────────────────────────────────────

@test "adoc: exits 0 when base name matches no files" {
    _adoc nonexistent
    [ "$status" -eq 0 ]
}

@test "adoc: produces no output when base name matches no files" {
    _adoc nonexistent
    [ -z "$output" ]
}

# ── -a append mode ────────────────────────────────────────────────────────────

@test "adoc: -a requires a filename argument" {
    run bash "$ADOC_SH" -a
    [ "$status" -eq 1 ]
    [[ "$output" == *"-a requires"* ]]
}

@test "adoc: -a appends AsciiDoc content to the specified file" {
    printf 'hello' > "${WORK_DIR}/foo.txt"
    local out="${WORK_DIR}/out.adoc"
    run bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' -a '${out}' foo"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    grep -q 'tag::foo.txt' "$out"
}

@test "adoc: -a prints the base name to stdout" {
    printf 'hello' > "${WORK_DIR}/foo.txt"
    local out="${WORK_DIR}/out.adoc"
    run --separate-stderr bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' -a '${out}' foo"
    [ "$status" -eq 0 ]
    [ "$output" = "foo" ]
}

@test "adoc: -a stdout contains no AsciiDoc markup" {
    printf 'hello' > "${WORK_DIR}/foo.txt"
    local out="${WORK_DIR}/out.adoc"
    run bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' -a '${out}' foo"
    [ "$status" -eq 0 ]
    ! [[ "$output" == *"tag::"* ]]
}

@test "adoc: -a with multiple bases prints each name on its own stdout line" {
    printf 'a' > "${WORK_DIR}/foo.txt"
    printf 'b' > "${WORK_DIR}/bar.txt"
    local out="${WORK_DIR}/out.adoc"
    run --separate-stderr bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' -a '${out}' foo bar"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "foo" ]
    [ "${lines[1]}" = "bar" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "adoc: -a appends to an existing file without truncating" {
    printf 'a' > "${WORK_DIR}/foo.txt"
    local out="${WORK_DIR}/out.adoc"
    printf 'existing content\n' > "$out"
    run bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' -a '${out}' foo"
    [ "$status" -eq 0 ]
    grep -q 'existing content' "$out"
    grep -q 'tag::foo.txt' "$out"
}

@test "adoc: -a creates the output file when it does not exist" {
    printf 'a' > "${WORK_DIR}/foo.txt"
    local out="${WORK_DIR}/newfile.adoc"
    [ ! -f "$out" ]
    run bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' -a '${out}' foo"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
}

@test "adoc: -a stdin mode appends content and prints base name to stdout" {
    printf 'a' > "${WORK_DIR}/foo.txt"
    local out="${WORK_DIR}/out.adoc"
    run --separate-stderr bash -c "cd '${WORK_DIR}' && echo 'foo' | bash '${ADOC_SH}' -a '${out}'"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    grep -q 'tag::foo.txt' "$out"
    [ "$output" = "foo" ]
}

# ── content fidelity ──────────────────────────────────────────────────────────

@test "adoc: preserves multi-line file content" {
    printf 'line1\nline2\nline3' > "${WORK_DIR}/foo.body"
    _adoc foo
    [[ "$output" == *'line1'* ]]
    [[ "$output" == *'line2'* ]]
    [[ "$output" == *'line3'* ]]
}

@test "adoc: handles empty file without error" {
    touch "${WORK_DIR}/foo.body"
    _adoc foo
    [ "$status" -eq 0 ]
    [[ "$output" == *'// tag::foo.body[]'* ]]
    [[ "$output" == *'// end::foo.body[]'* ]]
}

# ── extension filter ──────────────────────────────────────────────────────────

@test "adoc: filter after -- emits only the listed extensions" {
    printf 'B' > "${WORK_DIR}/req.body"
    printf 'H' > "${WORK_DIR}/req.headers"
    printf 'C' > "${WORK_DIR}/req.curl"
    _adoc req -- body headers
    [ "$status" -eq 0 ]
    [[ "$output" == *'// tag::req.body[]'* ]]
    [[ "$output" == *'// tag::req.headers[]'* ]]
    ! [[ "$output" == *'req.curl'* ]]
}

@test "adoc: a leading dot on an extension is optional" {
    printf 'B' > "${WORK_DIR}/req.body"
    printf 'H' > "${WORK_DIR}/req.headers"
    _adoc req -- .body .headers
    [ "$status" -eq 0 ]
    [[ "$output" == *'// tag::req.body[]'* ]]
    [[ "$output" == *'// tag::req.headers[]'* ]]
}

@test "adoc: no -- documents every extension (unchanged)" {
    printf 'B' > "${WORK_DIR}/req.body"
    printf 'C' > "${WORK_DIR}/req.curl"
    _adoc req
    [[ "$output" == *'req.body'* ]]
    [[ "$output" == *'req.curl'* ]]
}

@test "adoc: a bare -- with no extensions documents everything" {
    printf 'B' > "${WORK_DIR}/req.body"
    printf 'C' > "${WORK_DIR}/req.curl"
    _adoc req --
    [ "$status" -eq 0 ]
    [[ "$output" == *'req.body'* ]]
    [[ "$output" == *'req.curl'* ]]
}

@test "adoc: warns per base for a requested extension with no file, exit 0" {
    printf 'B' > "${WORK_DIR}/req.body"
    run --separate-stderr bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' req -- body xml"
    [ "$status" -eq 0 ]
    [[ "$output" == *'// tag::req.body[]'* ]]
    [[ "$stderr" == *'req has no .xml'* ]]
}

@test "adoc: a base missing one of several listed extensions still warns only for it" {
    printf 'B1' > "${WORK_DIR}/req1.body"
    printf 'H1' > "${WORK_DIR}/req1.headers"
    printf 'B2' > "${WORK_DIR}/req2.body"
    run --separate-stderr bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' req1 req2 -- body headers"
    [ "$status" -eq 0 ]
    [[ "$output" == *'// tag::req1.body[]'* ]]
    [[ "$output" == *'// tag::req1.headers[]'* ]]
    [[ "$output" == *'// tag::req2.body[]'* ]]
    [[ "$stderr" == *'req2 has no .headers'* ]]
    ! [[ "$stderr" == *'req1 has no'* ]]
}

@test "adoc: base names from stdin combine with a -- filter" {
    printf 'B' > "${WORK_DIR}/req.body"
    printf 'C' > "${WORK_DIR}/req.curl"
    run bash -c "cd '${WORK_DIR}' && printf 'req\n' | bash '${ADOC_SH}' -- curl"
    [ "$status" -eq 0 ]
    [[ "$output" == *'// tag::req.curl[]'* ]]
    ! [[ "$output" == *'req.body'* ]]
}

@test "adoc: filter warnings go to stderr, not into the -a output file" {
    printf 'B' > "${WORK_DIR}/req.body"
    local out="${WORK_DIR}/out.adoc"
    run --separate-stderr bash -c "cd '${WORK_DIR}' && bash '${ADOC_SH}' -a '${out}' req -- body xml"
    [ "$status" -eq 0 ]
    grep -q 'tag::req.body' "$out"
    ! grep -q 'has no .xml' "$out"
    [[ "$stderr" == *'req has no .xml'* ]]
}
