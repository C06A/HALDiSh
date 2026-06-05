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

# Install git hooks (run once after cloning)
./gradlew installGitHooks
```

BATS is auto-installed to `scripts/build/bats/` on first `test` run. For manual runs `SCRIPTS_DIR` must be set and the scripts directory must be on `PATH` (both are handled by Gradle automatically).

## Architecture

All scripts live in `scripts/src/main/bash/`. Tests live in `scripts/src/test/bats/`, one `.bats` file per script. The self-inflatable archive bundles every `*.sh` file; `setup.sh` runs post-extract.

### Script roles

| Script | Role |
|---|---|
| `hal_utils.sh` | Sourced library: `hal::str::*`, `hal::arr::*`, `hal::fs::*`, `hal::log::*`. Has a double-source guard (`_HAL_UTILS_LOADED`). |
| `env.sh` | Activation script — `source env.sh` to load the library and add the directory to `PATH`. Calls `validate.sh` first. |
| `hal.sh` | Navigate HAL JSON/YAML/XML documents: interactive or `hal.sh <file> links|embeddeds|properties|docs [path…]`. |
| `hallink.sh` | Resolve a HAL link object's `href`, expanding URI templates. Two modes: `--link <obj>` or `<file> <hal-path>`. |
| `haldoclink.sh` | Emit a documentation link `{"href":"<doc_url>","type":"text/html"}` for a CURIE-prefixed relation. Searches `_links.curies` from the deepest embedded resource up to the root. `<file> <hal-path>` only. |
| `halprepend.sh` | Prepend a base string to a HAL link object's `href`. Two modes: `--link <obj>` or `<file> <hal-path>`. Format-preserving (JSON/YAML/XML). |
| `httpreq.sh` | HTTP dispatcher. Invoked via method-named hardlinks (`GET`, `POST`, …) that all point to `.httpreq.sh`. Outputs a family of files: `<base>.body`, `<base>.headers`, `<base>.code`, `<base>.curl`, etc. |
| `uritemplate.sh` | RFC 6570 URI template expansion. Called as a subprocess by `hal.sh` and `hallink.sh`. |
| `nahal.sh` | Interactive HAL API browser. Fetches with the method commands, classifies responses by Content-Type, and navigates links/embeddeds/properties/docs — and arrays of resources — via `hal.sh`. Follows links with any HTTP method (HEAD/custom verbs via an on-demand `./<METHOD>` link). Renames each response via `rename.sh -p <prefix>` (user prefix from `-p` or a prompt) and logs a re-runnable `session.sh` whose steps capture each base into a `_b[]` array — `_b[N]=$(hallink.sh "${_b[M]}.body" … \| <METHOD> --link \| rename.sh -p <prefix>)` — with the header as a command-prefix on the method (no grouping subshells). Records the `HAL_LINK_PLUGIN` list at session creation and emits a `_check_plugins` that diffs it against the replay-time list (OK = in both, INFO = new, WARN = missing). |
| `menu.sh` | Single-keypress interactive selector. Reads from fd 3 (`_MENU_TTY` env var overrides). |
| `prettyprint.sh` | Detects content type of `<base>.body` and reformats it as JSON/YAML/XML. |
| `adoc.sh` | Wraps file groups into AsciiDoc tagged regions for inclusion in docs. |
| `rename.sh` | Renames a group of files sharing a base name across all extensions. `-p <prefix>` mode auto-numbers the new base as `<prefix><N>` (one past the largest existing `<prefix><N>.*`). |
| `validate.sh` | Integrity checker: verifies SHA-256 hashes against `.hal_manifest`. Called by `env.sh`. |
| `setup.sh` | Post-install: renames `httpreq.sh` → `.httpreq.sh`, creates method hardlinks, generates `.hal_manifest`. |

### Key design patterns

**Tool selection** — every script that queries JSON/XML/YAML uses the same two-step pattern: prefer `yq` (mikefarah/yq v4, handles all three formats), fall back to `jq` for JSON-only. The functional check `printf '{}' | yq '.'` is always included alongside `command -v yq` to guard against broken stubs. Format detection reads file content (never file extensions).

**HAL path convention** — non-interactive traversal uses space-separated segments: `links <rel> [N]`, `embeddeds <rel> [N]`, `properties <key>`. Segments without `=` are path components; segments containing `=` are URI template variable bindings.

**Exit codes** — `hallink.sh` uses distinct codes: 1 usage, 2 file not found, 3 link not found/no href, 4 tool unavailable. `hal.sh` and most other scripts exit 1 for all errors.

**httpreq.sh method dispatch** — `setup.sh` creates hardlinks `GET`, `POST`, `PUT`, `PATCH`, `OPTIONS`, `DELETE` → `.httpreq.sh`. The script detects its method via `basename "$0"`. The `--link` flag accepts inline JSON, `@file`, or stdin.

**Format-preserving output** — scripts that accept JSON/XML/YAML input detect the source format and emit output in the same format (via `yq -o yaml`, `yq -o xml`, or compact JSON).

**`hal_utils.sh` sourcing** — scripts that need logging or utility functions source `hal_utils.sh` via `. hal_utils.sh` (PATH lookup, not a relative path). In tests, `SCRIPTS_DIR` is on `PATH` so this resolves correctly.

### Tests

Each `.bats` file begins with:
```bash
bats_require_minimum_version 1.5.0
load 'test_helper'
```

`test_helper.bash` sets `SCRIPTS_DIR` and exposes `load_lib`. All fixture files are created under a `WORK_DIR=$(mktemp -d)` in `setup()` and removed in `teardown()`. Use `run --separate-stderr` when asserting on both stdout and stderr independently. Tool-absence tests inject broken stubs by prepending a stub directory to `PATH` — stubs must fail both `command -v` + functional verification (`printf '{}' | tool '.'`).

### README

`README.asciidoc` is the source of truth. `README.md` is generated from it by `pandoc` and must never be edited directly. The pre-commit hook enforces this and auto-regenerates `README.md` when `README.asciidoc` is staged.
