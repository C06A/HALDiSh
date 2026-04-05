#!/usr/bin/env bats
# =============================================================================
# prettyprint.bats — unit tests for prettyprint.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

PP_SH="${SCRIPTS_DIR}/prettyprint.sh"

setup() {
    WORK_DIR="$(mktemp -d)"
    MOCK_DIR="$(mktemp -d)"

    # Mock jq: validates any stdin as JSON for 'empty'; passes through for '.'
    cat > "${MOCK_DIR}/jq" << 'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "empty" ]]; then cat > /dev/null; exit 0; fi
cat
MOCK
    chmod +x "${MOCK_DIR}/jq"
    export PATH="${MOCK_DIR}:${PATH}"
}

teardown() {
    rm -rf "$WORK_DIR" "$MOCK_DIR"
}

# Run prettyprint from WORK_DIR with positional args.
_run_pp() {
    run bash -c "cd '$WORK_DIR' && bash '$PP_SH' $(printf '%q ' "$@")"
}

# ── error cases ───────────────────────────────────────────────────────────────

@test "prettyprint: exits 1 when body file not found" {
    _run_pp 'nosuchfile'
    [ "$status" -eq 1 ]
}

@test "prettyprint: prints error message when body file not found" {
    _run_pp 'nosuchfile'
    [[ "$output" == *"not found"* ]]
}

@test "prettyprint: exits 1 when -e has no argument" {
    _run_pp -e
    [ "$status" -eq 1 ]
}

@test "prettyprint: prints error message when -e has no argument" {
    _run_pp -e
    [[ "$output" == *"-e requires"* ]]
}

# ── stdout purity (for piping) ────────────────────────────────────────────────
# All tests in this section suppress stderr with 2>/dev/null so that $output
# contains only what prettyprint.sh wrote to stdout — no log messages.

@test "prettyprint: stdout is exactly the base name, nothing else" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    run bash -c "cd '$WORK_DIR' && bash '$PP_SH' req 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "req" ]
}

@test "prettyprint: stdout has no log messages" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    run bash -c "cd '$WORK_DIR' && bash '$PP_SH' req 2>/dev/null"
    [ "$status" -eq 0 ]
    ! [[ "$output" == *"[INFO]"* || "$output" == *"[WARN]"* || "$output" == *"[ERR ]"* ]]
}

@test "prettyprint: stdout has one line per base name, in argument order" {
    printf '{"a":1}' > "${WORK_DIR}/first.body"
    printf '{"b":2}' > "${WORK_DIR}/second.body"
    run bash -c "cd '$WORK_DIR' && bash '$PP_SH' first second 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "first" ]
    [ "${lines[1]}" = "second" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "prettyprint: stdout base name can be piped to cleanup.sh" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    # prettyprint (move mode) → req.json; pipe base name to cleanup, keeping json
    run bash -c "cd '$WORK_DIR' \
        && bash '$PP_SH' -m req 2>/dev/null \
        | bash '${SCRIPTS_DIR}/cleanup.sh' -- json 2>/dev/null"
    [ "$status" -eq 0 ]
    # cleanup.sh read 'req' from stdin and kept only .json
    [ -f "${WORK_DIR}/req.json" ]
    # cleanup printed the base name to its own stdout
    [ "$output" = "req" ]
}

@test "prettyprint: move mode stdout base name pipes correctly — source removed, output kept" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    run bash -c "cd '$WORK_DIR' && bash '$PP_SH' -m req 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "req" ]
    [ ! -f "${WORK_DIR}/req.body" ]
    [ -f "${WORK_DIR}/req.json" ]
}

@test "prettyprint: stdin mode stdout base name is pipeable" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    # Pipe prettyprint stdout directly into read to simulate downstream script
    local received
    received=$(cd "$WORK_DIR" && echo 'req' | bash "$PP_SH" 2>/dev/null)
    [ "$received" = "req" ]
}

# ── copy mode ─────────────────────────────────────────────────────────────────

@test "prettyprint: copy mode is the default — source file is kept" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.body" ]
}

@test "prettyprint: -c flag keeps source file" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    _run_pp -c 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.body" ]
}

@test "prettyprint: copy mode creates output file alongside source" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.body" ]
    [ -f "${WORK_DIR}/req.json" ]
}

# ── move mode ─────────────────────────────────────────────────────────────────

@test "prettyprint: -m flag removes source file" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    _run_pp -m 'req'
    [ "$status" -eq 0 ]
    [ ! -f "${WORK_DIR}/req.body" ]
}

@test "prettyprint: -m flag creates output file with detected extension" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    _run_pp -m 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.json" ]
}

# ── custom source extension (-e) ──────────────────────────────────────────────

@test "prettyprint: -e changes the source extension" {
    printf '{"k":1}' > "${WORK_DIR}/req.raw"
    _run_pp -e raw 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.json" ]
}

@test "prettyprint: -e accepts extension with leading dot" {
    printf '{"k":1}' > "${WORK_DIR}/req.raw"
    _run_pp -e .raw 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.json" ]
}

# ── type detection: JSON ──────────────────────────────────────────────────────

@test "prettyprint: JSON object body produces .json output file" {
    printf '{"key":"value","num":42}' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.json" ]
}

@test "prettyprint: JSON array body produces .json output file" {
    printf '[1,2,3]' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.json" ]
}

@test "prettyprint: JSON output file contains source content" {
    printf '{"key":"value"}' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    grep -q 'key' "${WORK_DIR}/req.json"
}

# ── type detection: XML ───────────────────────────────────────────────────────

@test "prettyprint: XML body produces .xml output file" {
    printf '<?xml version="1.0"?><root><child/></root>' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.xml" ]
}

@test "prettyprint: XML output file contains source content" {
    printf '<?xml version="1.0"?><root><child/></root>' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    grep -q 'root' "${WORK_DIR}/req.xml"
}

# ── type detection: HTML ──────────────────────────────────────────────────────

@test "prettyprint: HTML body produces .html output file" {
    printf '<!DOCTYPE html><html><body>hello</body></html>' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.html" ]
}

@test "prettyprint: HTML body with lowercase html tag produces .html output file" {
    printf '<html><head></head><body>test</body></html>' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.html" ]
}

# ── type detection: YAML ──────────────────────────────────────────────────────

@test "prettyprint: YAML key-value body produces .yaml output file" {
    printf 'name: Alice\nage: 30\n' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.yaml" ]
}

@test "prettyprint: YAML document marker produces .yaml output file" {
    printf -- '---\nkey: value\nother: data\n' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.yaml" ]
}

# ── type detection: CSV ───────────────────────────────────────────────────────

@test "prettyprint: CSV body produces .csv output file" {
    printf 'a,b,c\n1,2,3\n4,5,6\n' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.csv" ]
}

@test "prettyprint: CSV output file preserves all rows" {
    printf 'a,b,c\n1,2,3\n4,5,6\n' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    grep -q '1,2,3' "${WORK_DIR}/req.csv"
    grep -q '4,5,6' "${WORK_DIR}/req.csv"
}

# ── type detection: plain text ────────────────────────────────────────────────

@test "prettyprint: plain text body produces .txt output file" {
    printf 'hello world\nno special format here\n' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.txt" ]
}

@test "prettyprint: plain text output preserves all lines" {
    printf 'line one\nline two\n' > "${WORK_DIR}/req.body"
    _run_pp 'req'
    [ "$status" -eq 0 ]
    grep -q 'line one' "${WORK_DIR}/req.txt"
    grep -q 'line two' "${WORK_DIR}/req.txt"
}

# ── multiple base names ───────────────────────────────────────────────────────

@test "prettyprint: processes all base names provided as arguments" {
    printf '{"a":1}' > "${WORK_DIR}/first.body"
    printf '{"b":2}' > "${WORK_DIR}/second.body"
    _run_pp 'first' 'second'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/first.json" ]
    [ -f "${WORK_DIR}/second.json" ]
}

@test "prettyprint: exits non-zero when one of multiple base names is missing" {
    printf '{"a":1}' > "${WORK_DIR}/first.body"
    # second.body intentionally absent
    _run_pp 'first' 'missing'
    [ "$status" -ne 0 ]
}

# ── stdin mode ────────────────────────────────────────────────────────────────

@test "prettyprint: reads base names from stdin when no args given" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    run bash -c "cd '$WORK_DIR' && echo 'req' | bash '$PP_SH'"
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.json" ]
}

@test "prettyprint: stdin mode skips blank lines" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    run bash -c "cd '$WORK_DIR' && printf 'req\n\n' | bash '$PP_SH'"
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.json" ]
}

@test "prettyprint: stdin mode prints base name to stdout" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    run bash -c "cd '$WORK_DIR' && echo 'req' | bash '$PP_SH' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "req" ]
}

@test "prettyprint: stdin mode processes multiple base names" {
    printf '{"a":1}' > "${WORK_DIR}/first.body"
    printf '{"b":2}' > "${WORK_DIR}/second.body"
    run bash -c "cd '$WORK_DIR' && printf 'first\nsecond\n' | bash '$PP_SH'"
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/first.json" ]
    [ -f "${WORK_DIR}/second.json" ]
}

# ── positional options ────────────────────────────────────────────────────────

@test "prettyprint: -m affects only base names after the flag" {
    printf '{"a":1}' > "${WORK_DIR}/kept.body"
    printf '{"b":2}' > "${WORK_DIR}/removed.body"
    _run_pp 'kept' -m 'removed'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/kept.body" ]      # processed before -m → kept
    [ ! -f "${WORK_DIR}/removed.body" ] # processed after -m → removed
}

@test "prettyprint: -c after -m reverts to copy mode" {
    printf '{"a":1}' > "${WORK_DIR}/first.body"
    printf '{"b":2}' > "${WORK_DIR}/second.body"
    _run_pp -m 'first' -c 'second'
    [ "$status" -eq 0 ]
    [ ! -f "${WORK_DIR}/first.body" ]  # -m was active
    [ -f "${WORK_DIR}/second.body" ]   # -c restored copy mode
}

@test "prettyprint: -e affects only base names after the flag" {
    printf '{"a":1}' > "${WORK_DIR}/first.body"
    printf '{"b":2}' > "${WORK_DIR}/second.raw"
    _run_pp 'first' -e raw 'second'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/first.json" ]   # used default 'body' extension
    [ -f "${WORK_DIR}/second.json" ]  # used 'raw' extension
}

@test "prettyprint: unknown option emits warning but continues processing" {
    printf '{"k":1}' > "${WORK_DIR}/req.body"
    _run_pp -z 'req'
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown option"* ]]
    [ -f "${WORK_DIR}/req.json" ]
}

# ── in-place processing ───────────────────────────────────────────────────────

@test "prettyprint: in-place when source ext matches detected ext" {
    printf '{"key":"value"}' > "${WORK_DIR}/req.json"
    _run_pp -e json 'req'
    [ "$status" -eq 0 ]
    [ -f "${WORK_DIR}/req.json" ]
    grep -q 'key' "${WORK_DIR}/req.json"
}

@test "prettyprint: in-place move mode preserves file (src == dst)" {
    printf '{"key":"value"}' > "${WORK_DIR}/req.json"
    _run_pp -m -e json 'req'
    [ "$status" -eq 0 ]
    # src and dst are the same file; it must not be removed
    [ -f "${WORK_DIR}/req.json" ]
}
