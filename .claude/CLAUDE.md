# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run all tests
./gradlew :scripts:test

# Run a single test file (from repo root)
SCRIPTS_DIR="$(pwd)/scripts/src/main/bash" \
  PATH="$(pwd)/scripts/src/main/bash:$PATH" \
  scripts/build/bats/bin/bats scripts/src/test/bats/hallink.bats

# Build the self-inflatable .run archive
./gradlew :scripts:assembleDist          # output: scripts/build/dist/HALDiSh-<version>.run

# Full build (assemble + test)
./gradlew :scripts:build
```

BATS is auto-installed to `scripts/build/bats/` on first `test` run.
For manual runs `SCRIPTS_DIR` must be set and the scripts directory must be on `PATH` (both are handled by Gradle automatically).

## Architecture

All scripts live in `scripts/src/main/bash/`. Tests live in `scripts/src/test/bats/`, one `.bats` file per script.
The self-inflatable archive bundles every `*.sh` file; `setup.sh` runs post-extract.

### Script roles

| Script | Role |
|---|---|
| `hal_utils.sh` | Sourced library: `hal::str::*`, `hal::arr::*`, `hal::fs::*`, `hal::log::*`. Has a double-source guard (`_HAL_UTILS_LOADED`). |
| `env.sh` | Activation script — `source env.sh` to load the library and add the directory to `PATH`. Calls `validate.sh` first. |
| `hal.sh` | Navigate HAL JSON/YAML/XML documents: interactive or `hal.sh <file> links\|embeddeds\|properties\|docs [path…]`. Array selection in a path: a numeric segment is an index; for `links` a bare segment matches the element's `name`; for `embeddeds`/`properties` a `field=value` segment selects the element whose field (rendered raw, so numbers/strings both match by literal text) equals the value — unmatched selectors exit 1. Interactively, link arrays are picked from a `name`-labelled menu; embedded-resource and property arrays first prompt for a field to select by (or index), then list elements by that field's value; scalar arrays are picked by index. hal.sh does not accept template var bindings (a hallink.sh concept). |
| `hallink.sh` | Resolve a HAL link object's `href`, expanding URI templates. Two modes: `--link <obj>` or `<file> <hal-path>`. Template var bindings follow a literal `--` separator and each must contain `=`; everything before `--` is the path (or, with `--link`, the link source), and without `--` there are no bindings. This keeps a path's `field=value` array selector (resolved by hal.sh) distinct from a template binding. A binding after `--` lacking `=`, or a stray arg before `--` in `--link` mode, is a usage error (exit 1). An optional `-s <base>` (anywhere before `--`) writes sidecar files recording how the link was located — `<base>.source` (the `<file>` arg, or an `@file` with `@` stripped; omitted for an inline/stdin `--link`), `<base>.halpath` (path segments, one per line; empty in `--link` mode), `<base>.bindings` (the `var=value` bindings, one per line) — sharing the base name so a later rename moves them with the response files. |
| `haldoclink.sh` | Emit a documentation link `{"href":"<doc_url>","type":"text/html"}` for a CURIE-prefixed relation. Searches `_links.curies` from the deepest embedded resource up to the root. `<file> <hal-path>` only. |
| `halprepend.sh` | Prepend a base string to a HAL link object's `href`. Two modes: `--link <obj>` or `<file> <hal-path>`. Format-preserving (JSON/YAML/XML). |
| `httpreq.sh` | HTTP dispatcher. Invoked via method-named hardlinks (`GET`, `POST`, …) that all point to `.httpreq.sh`. Outputs a family of files: `<base>.body`, `<base>.headers`, `<base>.code`, `<base>.curl`, etc. Arguments are parsed in a single pass and may appear in **any order**: exactly one URL source (a bare `<url>`, `--` for a stdin URL, or `--link`); `-s <base>` (at most once) names the output base — else `<domain>_<timestampms>` is generated and may be piped to `rename.sh` for a predictable name; `-i` (at most once); the body-content flags `-a/-u/-b/-r` are mutually exclusive and conflict with the multipart `-f/-F` (which repeat and combine). Violations exit non-zero. |
| `uritemplate.sh` | RFC 6570 URI template expansion. Called as a subprocess by `hal.sh` and `hallink.sh`. |
| `nahal.sh` | Interactive HAL API browser. Fetches with the method commands, classifies responses by Content-Type, and navigates links/embeddeds/properties/docs — and arrays of resources — via `hal.sh`. Follows links with any HTTP method (HEAD/custom verbs via an on-demand `./<METHOD>` link). Each step numbers its response base once via `hal_basename.sh -p <prefix>` into `$_s` and passes `-s "$_s"` to both `hallink.sh` and the method (no `rename.sh`); the link-following pipeline `hallink.sh -s "$_s" <src>.body <path> [-- binds] | <METHOD> -s "$_s" --link` is identical live and in the replay, and `hallink.sh -s` also writes the `<base>.source/.halpath/.bindings` sidecars. The bare-URL start is named with `-s` but writes no sidecar. Logs a re-runnable `session.sh` whose steps capture each base into a `_b[]` array as a multi-line `_b[N]=$( … )` opening with `_s=$(hal_basename.sh -p "$_prefix")` — then one stage per indented line, `\`-continued (a leading `\|` after a bare newline is a Bash syntax error), with the `HTTP_IN_HEADERS=…` header a command-prefix on the method stage (no grouping subshells). `HTTP_IN_HEADERS` is emitted only for headers the link cannot supply — `httpreq.sh --link` derives `Accept` from the link's `type`, so the sole `Accept` written is on the initial bare-URL `GET`, plus `Content-Type` for body requests. The prefix is set once into `$_prefix` in the header; at replay it can be overridden by `session.sh -p <prefix>` (wins) or an exported `HAL_FILE_PREFIX` (set-but-empty honored), else the baked value — bad args print usage and exit 2. The replay opens with a bootstrap that self-activates the HALDiSh environment (uses it if on `PATH`, else sources `env.sh` from `$HAL_LIB_DIR` or `~/.local/lib/haldish`, else prints install instructions and exits). Every followed link — and a resolved CURIE doc link before its page is opened — is run through `HAL_LINK_PLUGIN` (the doc link is the curie object with its `{rel}` href expanded). Records the `HAL_LINK_PLUGIN` list at session creation and emits a `_check_plugins` that diffs it against the replay-time list (OK = in both, INFO = new, WARN = missing). |
| `menu.sh` | Single-keypress interactive selector. Reads from fd 3 (`_MENU_TTY` env var overrides). |
| `prettyprint.sh` | Detects content type of `<base>.body` and reformats it as JSON/YAML/XML. |
| `adoc.sh` | Wraps file groups into AsciiDoc tagged regions for inclusion in docs. `[<base>...] [-- <ext>...]`: an extension list after `--` documents only those extensions (leading dot optional; no `--` = all); a requested extension with no `<base>.<ext>` file warns per base but exits 0. |
| `grapher.sh` | Build a navigation graph from HAL session files. Scans a directory for grouped response files (`req1.body`, `req2.body`, …) and emits a graph showing which resource's links led to which requests. Output formats: dot, mermaid, plantuml, ascii, svg (native SVG rendering, no external tools), json. Orientations: lr (left-to-right, default), tb (top-to-bottom). Edge origin: when a request carries sidecars written by `hallink.sh -s` (`.source`, `.halpath`, `.bindings`), the origin is recorded and trusted; otherwise the origin is guessed by matching the target URL against earlier bodies' hrefs — ambiguous guesses (>1 match) are flagged in the label. |
| `hal_basename.sh` | Single source of truth for the `<prefix><N>` naming scheme: `hal_basename.sh -p <prefix>` prints `<prefix><N>` (one past the largest existing `<prefix><N>.*` in the CWD; empty prefix → bare numbers). Called by `rename.sh -p` and by `nahal.sh`. |
| `rename.sh` | Renames a group of files sharing a base name across all extensions. `-p <prefix>` mode auto-numbers the new base by delegating to `hal_basename.sh -p <prefix>`. |
| `validate.sh` | Integrity checker: verifies SHA-256 hashes against `.hal_manifest`. Called by `env.sh`. |
| `setup.sh` | Post-install: renames `httpreq.sh` → `.httpreq.sh`, creates method hardlinks, generates `.hal_manifest`. |

### Key design patterns

**Tool selection** — every script that queries JSON/XML/YAML uses the same two-step pattern: prefer `yq` (mikefarah/yq v4,
handles all three formats), fall back to `jq` for JSON-only. The functional check `printf '{}' | yq '.'` is always
included alongside `command -v yq` to guard against broken stubs. Format detection reads file content (never file extensions).

**HAL path convention** — non-interactive traversal uses space-separated segments: `links <rel> [N|name]`, `embeddeds <rel> [N|field=value]`, `properties <key> [N|field=value]`.
A numeric segment is an array index; for `links` a bare segment matches the element's `name`; for `embeddeds`/`properties` a `field=value` segment selects the matching array element. Template variable bindings are **not** part of the hal-path — they are a hallink.sh concept and live after a literal `--` separator (everything before `--` is the path, every arg after it must contain `=`). This is what lets a `field=value` selector in the path coexist with a `var=value` template binding without ambiguity.

**Exit codes** — `hallink.sh` uses distinct codes: 1 usage, 2 file not found, 3 link not found/no href, 4 tool unavailable.
`hal.sh` and most other scripts exit 1 for all errors.

**httpreq.sh method dispatch** — `setup.sh` creates hardlinks `GET`, `POST`, `PUT`, `PATCH`, `OPTIONS`, `DELETE` → `.httpreq.sh`.
The script detects its method via `basename "$0"`. The `--link` flag accepts inline JSON, `@file`, or stdin.

**Format-preserving output** — scripts that accept JSON/XML/YAML input detect the source format and emit output in the same format
(via `yq -o yaml`, `yq -o xml`, or compact JSON).

**`hal_utils.sh` sourcing** — scripts that need logging or utility functions source `hal_utils.sh` via `. hal_utils.sh`
(PATH lookup, not a relative path). In tests, `SCRIPTS_DIR` is on `PATH` so this resolves correctly.

### Tests

Each `.bats` file begins with:
```bash
bats_require_minimum_version 1.5.0
load 'test_helper'
```

`test_helper.bash` sets `SCRIPTS_DIR` and exposes `load_lib`. All fixture files are created under a `WORK_DIR=$(mktemp -d)`
in `setup()` and removed in `teardown()`. Use `run --separate-stderr` when asserting on both stdout and stderr independently.
Tool-absence tests inject broken stubs by prepending a stub directory to `PATH` — stubs must fail both `command -v` + functional verification
(`printf '{}' | tool '.'`).

### README

`README.asciidoc` is the source of truth.
