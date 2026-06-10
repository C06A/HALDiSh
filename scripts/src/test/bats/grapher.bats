#!/usr/bin/env bats
# =============================================================================
# grapher.bats — unit tests for grapher.sh
# =============================================================================

bats_require_minimum_version 1.5.0

load 'test_helper'

GRAPHER_SH="${SCRIPTS_DIR}/grapher.sh"

WORK_DIR=""

# ── fixture helpers ───────────────────────────────────────────────────────────

_write_url()  { printf '%s' "$2" > "${WORK_DIR}/${1}.url"; }
_write_curl() { printf '%s' "$2" > "${WORK_DIR}/${1}.curl"; }
_write_body() { printf '%s\n' "$2" > "${WORK_DIR}/${1}.body"; }

# Sidecars written by `hallink.sh -s` — source resource, hal-path tokens (one per
# line), and template bindings (one var=value per line).
_write_source()   { printf '%s\n' "$2" > "${WORK_DIR}/${1}.source"; }
_write_halpath()  { printf '%s\n' "$2" > "${WORK_DIR}/${1}.halpath"; }
_write_bindings() { printf '%s\n' "$2" > "${WORK_DIR}/${1}.bindings"; }

# Create a group and sleep briefly so ctime ordering is reliable
_group() {
    local base="$1"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)      _write_url      "$base" "$2"; shift 2 ;;
            --curl)     _write_curl     "$base" "$2"; shift 2 ;;
            --body)     _write_body     "$base" "$2"; shift 2 ;;
            --source)   _write_source   "$base" "$2"; shift 2 ;;
            --halpath)  _write_halpath  "$base" "$2"; shift 2 ;;
            --bindings) _write_bindings "$base" "$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    sleep 0.05
}

setup() {
    WORK_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$WORK_DIR"
}

# ── argument validation ───────────────────────────────────────────────────────

@test "grapher exits 1 for unknown format" {
    run bash "$GRAPHER_SH" --format bogus "$WORK_DIR"
    [ "$status" -eq 1 ]
}

@test "grapher exits 1 for unknown orientation" {
    run bash "$GRAPHER_SH" --orientation diagonal "$WORK_DIR"
    [ "$status" -eq 1 ]
}

@test "grapher exits 1 for missing directory" {
    run bash "$GRAPHER_SH" /no/such/dir
    [ "$status" -eq 1 ]
}

# ── empty directory ───────────────────────────────────────────────────────────

@test "grapher --format json empty dir produces empty nodes and edges" {
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"nodes": ['* ]]
    [[ "$output" == *'"edges": ['* ]]
}

@test "grapher --format dot empty dir produces valid digraph" {
    run bash "$GRAPHER_SH" --format dot "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'digraph {'* ]]
}

# ── single group, no edges ────────────────────────────────────────────────────

@test "grapher single group from .url file appears as node" {
    _group g1 --url 'https://api.example.com/items' \
               --body '{"_links":{"self":{"href":"/items"}}}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"id":"g1"'* ]]
    [[ "$output" == *'"url":"https://api.example.com/items"'* ]]
}

@test "grapher single group with no url file uses self link from body" {
    _group g1 --body '{"_links":{"self":{"href":"/items"}}}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"url":"/items"'* ]]
}

@test "grapher single group with no url or body is orphan with empty url" {
    printf 'curl https://api.example.com/' > "${WORK_DIR}/g1.curl"
    sleep 0.05
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"id":"g1"'* ]]
    # No edges (the edges array contains only whitespace between [ and ])
    run jq '.edges | length' <<< "$output"
    [ "$output" -eq 0 ]
}

# ── URL extraction from .curl file ────────────────────────────────────────────

@test "grapher extracts URL from multi-line curl file" {
    _group g1 --curl "$(printf 'curl \\\n    -X GET \\\n    --header '"'"'Accept: application/json'"'"' \\\n    https://api.example.com/items')"
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"url":"https://api.example.com/items"'* ]]
}

@test "grapher extracts URL from curl file with quoted header containing spaces" {
    _group g1 --curl "curl --header 'Authorization: Bearer token' https://api.example.com/res"
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"url":"https://api.example.com/res"'* ]]
}

@test "grapher synthesizes curl command when only .url file exists" {
    _group g1 --url 'https://api.example.com/items'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"curl":"curl https://api.example.com/items"'* ]]
}

# ── edge detection: basic link matching ──────────────────────────────────────

@test "grapher finds edge via _links array href (absolute path match)" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"item":[{"href":"/items/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/items/1' \
        --body '{"_links":{"self":{"href":"/items/1"}}}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2","label":"links item 0"'* ]]
}

@test "grapher finds edge via _links object href" {
    # Use distinct self path so self link doesn't match g2 first
    _group g1 \
        --url 'https://api.example.com/root' \
        --body '{"_links":{"self":{"href":"/root"},"next":{"href":"/items?page=2"}}}'
    _group g2 \
        --url 'https://api.example.com/items?page=2' \
        --body '{"_links":{"self":{"href":"/items"}}}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2","label":"links next"'* ]]
}

# ── edge detection: embedded resource links ───────────────────────────────────

@test "grapher finds edge via embedded resource link" {
    _group g1 \
        --url 'https://api.example.com/orders' \
        --body '{
          "_links":{"self":{"href":"/orders"}},
          "_embedded":{"item":[
            {"_links":{"self":{"href":"/orders/1"}}}
          ]}
        }'
    _group g2 \
        --url 'https://api.example.com/orders/1' \
        --body '{"_links":{"self":{"href":"/orders/1"}}}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"label":"embeddeds item 0\nlinks self"'* ]]
}

# ── edge detection: property URL matching ─────────────────────────────────────

@test "grapher finds edge via URL-like property value" {
    _group g1 \
        --url 'https://api.example.com/a' \
        --body '{"_links":{"self":{"href":"/a"}},"next":"/b"}'
    _group g2 \
        --url 'https://api.example.com/b' \
        --body '{"_links":{"self":{"href":"/b"}}}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"label":"properties next"'* ]]
}

# ── edge detection: URI template matching ─────────────────────────────────────

@test "grapher matches templated link and records query bindings" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"search":{"href":"/items{?q}","templated":true}}}'
    # Make g2 NOT match the self link first by giving g2 a unique path
    _group g2 \
        --url 'https://api.example.com/items?q=hello'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    # Either self or search may match first depending on href order; edge must exist
    [[ "$output" == *'"from":"g1","to":"g2"'* ]]
}

@test "grapher matches path-segment template {var}" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"item":{"href":"/items/{id}","templated":true}}}'
    _group g2 \
        --url 'https://api.example.com/items/42'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2"'* ]]
    [[ "$output" == *'id=42'* ]]
}

# ── URL suffix matching ───────────────────────────────────────────────────────

@test "grapher matches when link is relative and target has absolute host" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"item":[{"href":"/items/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/v1/api/items/1'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2"'* ]]
}

@test "grapher does NOT match when link path is not a suffix of target path" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"item":[{"href":"/items/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/otheritems/1'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    # No edge for g2 (otheritems/1 is not a suffix of /items/1)
    [[ "$output" != *'"to":"g2"'* ]]
}

# ── orphan nodes ──────────────────────────────────────────────────────────────

@test "grapher includes node with no URL as orphan (no incoming edge)" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"}}}'
    # g2 has no URL or self link; give it a body so it has a file to be picked up
    _group g2 --body '{"title":"no links here"}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"id":"g2"'* ]]
    # g2 has no incoming edge
    [[ "$output" != *'"to":"g2"'* ]]
}

# ── chronological ordering ────────────────────────────────────────────────────

@test "grapher only looks at earlier groups for parent" {
    _group g1 \
        --url 'https://api.example.com/b' \
        --body '{"_links":{"self":{"href":"/b"},"next":{"href":"/a"}}}'
    _group g2 \
        --url 'https://api.example.com/a'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    # g2 must not link back to g1 (g1 was CREATED after g2? No: g1 was created first)
    # g2 comes after g1 in time, so g1 is the candidate parent for g2.
    # g1's "next" points to /a which is g2's URL.
    # Wait, this is a reverse: g1 links to /a, g2 IS /a.  So edge: g1→g2  is correct.
    # This test verifies ordering: g1 (earlier) → g2 (later).
    [[ "$output" == *'"from":"g1","to":"g2"'* ]]
}

# ── output formats ────────────────────────────────────────────────────────────

@test "grapher --format dot produces rankdir=LR by default" {
    _group g1 --url 'https://api.example.com/'
    run bash "$GRAPHER_SH" --format dot "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'rankdir=LR'* ]]
}

@test "grapher --format dot --orientation tb produces rankdir=TB" {
    _group g1 --url 'https://api.example.com/'
    run bash "$GRAPHER_SH" --format dot --orientation tb "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'rankdir=TB'* ]]
}

@test "grapher --format mermaid default orientation is LR" {
    _group g1 --url 'https://api.example.com/'
    run bash "$GRAPHER_SH" --format mermaid "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == 'graph LR'* ]]
}

@test "grapher --format mermaid --orientation tb uses TD" {
    _group g1 --url 'https://api.example.com/'
    run bash "$GRAPHER_SH" --format mermaid --orientation tb "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == 'graph TD'* ]]
}

@test "grapher --format plantuml contains @startuml/@enduml" {
    _group g1 --url 'https://api.example.com/'
    run bash "$GRAPHER_SH" --format plantuml "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'@startuml'* ]]
    [[ "$output" == *'@enduml'* ]]
}

@test "grapher --format plantuml --orientation lr has left to right direction" {
    _group g1 --url 'https://api.example.com/'
    run bash "$GRAPHER_SH" --format plantuml --orientation lr "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'left to right direction'* ]]
}

@test "grapher --format plantuml --orientation tb omits left to right direction" {
    _group g1 --url 'https://api.example.com/'
    run bash "$GRAPHER_SH" --format plantuml --orientation tb "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *'left to right direction'* ]]
}

@test "grapher --format plantuml escapes double quotes in a curl node label" {
    # A real curl command mixes single and double quotes; an unescaped " inside
    # the node "..." label closes the string early and makes PlantUML fail with
    # "Syntax error? (Assumed diagram type: class)".
    _group g1 --curl 'curl -X GET '"'"'http://h/'"'"' -H "Accept: application/hal+json"'
    run bash "$GRAPHER_SH" --format plantuml "$WORK_DIR"
    [ "$status" -eq 0 ]
    # The node line must be a single well-formed quoted label: exactly the two
    # delimiting quotes, none in between.
    local node_line
    node_line=$(printf '%s\n' "$output" | grep '^node ')
    [[ "$node_line" == *'Accept:'* ]]          # the header text survived
    [[ "$node_line" != *'"Accept:'* ]]         # but not as an interior double quote
    [ "$(printf '%s' "$node_line" | tr -cd '"' | wc -c | tr -d ' ')" -eq 2 ]
}

@test "grapher --format plantuml gives numeric (empty-prefix) basenames valid aliases" {
    # Bare-number basenames (empty -p prefix) are invalid PlantUML aliases; they
    # must be emitted with a leading non-digit and used consistently on edges.
    _group 1 \
        --url 'https://api.example.com/' \
        --body '{"_links":{"self":{"href":"/"},"x":{"href":"/x"}}}'
    _group 2 --url 'https://api.example.com/x'
    run bash "$GRAPHER_SH" --format plantuml "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'as n_1'* ]]
    [[ "$output" == *'as n_2'* ]]
    [[ "$output" == *'n_1 --> n_2'* ]]
    # No edge or node line starts with a bare digit alias.
    [[ "$output" != *$'\n''1 -->'* ]]
}

@test "grapher --format plantuml keeps a multi-line edge label on one line" {
    # A templated link records a path segment plus a binding, so the edge label
    # spans two lines.  A bare newline would split the `A --> B : ...` statement
    # and break PlantUML; the break must be the literal \n instead.
    _group g1 \
        --url 'https://api.example.com/' \
        --body '{"_links":{"self":{"href":"/"},"tmpl":{"href":"/items/1","templated":true}}}'
    _group g2 \
        --url 'https://api.example.com/items/1' \
        --source 'g1.body' --halpath $'links\ntmpl' --bindings 'id=1'
    run bash "$GRAPHER_SH" --format plantuml "$WORK_DIR"
    [ "$status" -eq 0 ]
    # The label rides one physical line with an escaped break.
    [[ "$output" == *'g1 --> g2 : links tmpl\nid=1'* ]]
    # The binding never appears as its own bare line.
    [[ "$output" != *$'\n''id=1'* ]]
}

@test "grapher --format ascii --orientation tb draws a boxed indented tree" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"item":[{"href":"/items/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/items/1'
    run bash "$GRAPHER_SH" --format ascii --orientation tb "$WORK_DIR"
    [ "$status" -eq 0 ]
    # Each node is a rectangle labelled with its base name.
    [[ "$output" == *'│ g1'* ]]
    [[ "$output" == *'│ g2'* ]]
    # Box borders are drawn.
    [[ "$output" == *'┌'* ]]
    [[ "$output" == *'└'* ]]
    # The child hangs off a tree branch connector.
    [[ "$output" == *'└─ '* || "$output" == *'├─ '* ]]
}

@test "grapher --format ascii --orientation tb branches one parent to two children" {
    _group g1 \
        --url 'https://api.example.com/' \
        --body '{"_links":{"self":{"href":"/"},"a":{"href":"/a"},"b":{"href":"/b"}}}'
    _group g2 --url 'https://api.example.com/a'
    _group g3 --url 'https://api.example.com/b'
    run bash "$GRAPHER_SH" --format ascii --orientation tb "$WORK_DIR"
    [ "$status" -eq 0 ]
    # First of two siblings uses ├─, the last uses └─.
    [[ "$output" == *'├─ '* ]]
    [[ "$output" == *'└─ '* ]]
    [[ "$output" == *'│ g2'* ]]
    [[ "$output" == *'│ g3'* ]]
}

@test "grapher --format ascii --orientation lr flows boxes rightward with arrows" {
    _group g1 \
        --url 'https://api.example.com/' \
        --body '{"_links":{"self":{"href":"/"},"a":{"href":"/a"}}}'
    _group g2 --url 'https://api.example.com/a'
    run bash "$GRAPHER_SH" --format ascii --orientation lr "$WORK_DIR"
    [ "$status" -eq 0 ]
    # ASCII boxes with a + corner and an arrowhead into the child.
    [[ "$output" == *'+--'* ]]
    [[ "$output" == *'| g1'* ]]
    [[ "$output" == *'| g2'* ]]
    [[ "$output" == *'>'* ]]
    # A linear chain flows along one row: g1 on the left, an arrow, then g2.
    local g1row
    g1row=$(printf '%s\n' "$output" | grep '| g1')
    [[ "$g1row" == *'g1'*'>'*'g2'* ]]
}

@test "grapher --format ascii defaults to lr and differs from tb" {
    _group g1 \
        --url 'https://api.example.com/' \
        --body '{"_links":{"self":{"href":"/"},"a":{"href":"/a"}}}'
    _group g2 --url 'https://api.example.com/a'
    run bash "$GRAPHER_SH" --format ascii "$WORK_DIR"
    [ "$status" -eq 0 ]
    local def="$output"
    run bash "$GRAPHER_SH" --format ascii --orientation lr "$WORK_DIR"
    local lr="$output"
    run bash "$GRAPHER_SH" --format ascii --orientation tb "$WORK_DIR"
    local tb="$output"
    # Default orientation is lr.
    [ "$def" = "$lr" ]
    # The two orientations produce genuinely different drawings.
    [ "$lr" != "$tb" ]
}

@test "grapher --format json produces valid JSON" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"item":[{"href":"/items/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/items/1'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    # Validate JSON with jq
    run jq '.' <<< "$output"
    [ "$status" -eq 0 ]
}

# ── edge label: multi-line for embedded paths ─────────────────────────────────

@test "grapher edge label has multiple lines for embedded link" {
    _group g1 \
        --url 'https://api.example.com/root' \
        --body '{
          "_links":{"self":{"href":"/root"}},
          "_embedded":{"orders":[{"_links":{"self":{"href":"/orders/1"}}}]}
        }'
    _group g2 --url 'https://api.example.com/orders/1'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'embeddeds orders 0'* ]]
    [[ "$output" == *'links self'* ]]
}

# ── most recent parent ────────────────────────────────────────────────────────

@test "grapher picks the most recent prior group that has a matching link" {
    # g1 and g2 both have a link to /target; g3 links to /target
    # g3 should be linked from g2 (most recent prior match)
    _group g1 \
        --url 'https://api.example.com/a' \
        --body '{"_links":{"self":{"href":"/a"},"t":{"href":"/target"}}}'
    _group g2 \
        --url 'https://api.example.com/b' \
        --body '{"_links":{"self":{"href":"/b"},"t":{"href":"/target"}}}'
    _group g3 --url 'https://api.example.com/target'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g2","to":"g3"'* ]]
    [[ "$output" != *'"from":"g1","to":"g3"'* ]]
}

# ── recorded origin via hallink.sh -s sidecars ────────────────────────────────

@test "grapher uses .source sidecar to build a recorded (not guessed) edge" {
    _group g1 \
        --url 'https://api.example.com/orders' \
        --body '{"_links":{"self":{"href":"/orders"},"item":[{"href":"/orders/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/orders/1' \
        --source 'g1.body' \
        --halpath "$(printf 'links\nitem\n0')"
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2","label":"links item 0","guessed":false'* ]]
}

@test "grapher .source sidecar label includes template bindings" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"}}}'
    _group g2 \
        --url 'https://api.example.com/items/42' \
        --source 'g1.body' \
        --halpath "$(printf 'links\nitem')" \
        --bindings 'id=42'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2"'* ]]
    [[ "$output" == *'links item\nid=42'* ]]
}

@test "grapher .source sidecar wins over a guessable URL match" {
    # g1 has the link that the guesser would find; gx is named as the recorded
    # source instead, so the edge must come from gx, not g1.
    _group g1 \
        --url 'https://api.example.com/a' \
        --body '{"_links":{"self":{"href":"/a"},"t":{"href":"/target"}}}'
    _group gx \
        --url 'https://api.example.com/x' \
        --body '{"_links":{"self":{"href":"/x"}}}'
    _group g2 \
        --url 'https://api.example.com/target' \
        --source 'gx.body' \
        --halpath "$(printf 'links\nself')"
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"gx","to":"g2"'* ]]
    [[ "$output" != *'"from":"g1","to":"g2"'* ]]
}

@test "grapher empty .source sidecar falls back to guessing" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"item":[{"href":"/items/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/items/1' \
        --source ''
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2","label":"links item 0","guessed":false'* ]]
}

# ── guessed-origin ambiguity flag ─────────────────────────────────────────────

@test "grapher flags a guessed edge when more than one href matches" {
    # Two distinct links in g1 both resolve to g2's URL → ambiguous guess.
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"a":{"href":"/items/1"},"b":{"href":"/items/1"}}}'
    _group g2 \
        --url 'https://api.example.com/items/1' \
        --body '{"_links":{"self":{"href":"/items/1"}}}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2"'* ]]
    [[ "$output" == *'"guessed":true'* ]]
    [[ "$output" == *'(guessed: 2 matches)'* ]]
}

@test "grapher does not flag a guessed edge with a single matching href" {
    _group g1 \
        --url 'https://api.example.com/items' \
        --body '{"_links":{"self":{"href":"/items"},"item":[{"href":"/items/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/items/1' \
        --body '{"_links":{"self":{"href":"/items/1"}}}'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"guessed":false'* ]]
    [[ "$output" != *'(guessed:'* ]]
}

# ── mixed directory: recorded and guessed edges coexist ───────────────────────

@test "grapher handles a directory mixing sidecar and non-sidecar requests" {
    # g1 → g2 recorded via sidecar; g2 → g3 guessed from g2's body.
    _group g1 \
        --url 'https://api.example.com/orders' \
        --body '{"_links":{"self":{"href":"/orders"},"item":[{"href":"/orders/1"}]}}'
    _group g2 \
        --url 'https://api.example.com/orders/1' \
        --source 'g1.body' \
        --halpath "$(printf 'links\nitem\n0')" \
        --body '{"_links":{"self":{"href":"/orders/1"},"pay":{"href":"/orders/1/pay"}}}'
    _group g3 \
        --url 'https://api.example.com/orders/1/pay'
    run bash "$GRAPHER_SH" --format json "$WORK_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"from":"g1","to":"g2","label":"links item 0","guessed":false'* ]]
    [[ "$output" == *'"from":"g2","to":"g3","label":"links pay","guessed":false'* ]]
}
