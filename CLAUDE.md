# HALDiSh — project guide for Claude

## Project layout

```
scripts/   Distributable bash library + BATS unit tests
examples/  Demo scripts showing how to use the library
.claude/   Claude Code commands, hooks, and settings
```

## Build system

Gradle 8.5 with the Gradle wrapper (`./gradlew`).  Java 21 required.

## Common tasks

| Task                        | Command                           |
|-----------------------------|-----------------------------------|
| Run unit tests              | `./gradlew :scripts:test`         |
| Build distributable archive | `./gradlew :scripts:assembleDist` |
| Syntax-check examples       | `./gradlew :examples:check`       |
| Full build                  | `./gradlew build`                 |
| Install bats-core locally   | `./gradlew :scripts:installBats`  |

Slash commands `/build`, `/test`, `/dist` are available as shortcuts.

## Bash library

The main library is `scripts/src/main/bash/hal_utils.sh`.
Namespaces: `hal::str::*`, `hal::arr::*`, `hal::fs::*`, `hal::log::*`.

## Testing

Tests live in `scripts/src/test/bats/` and use [bats-core](https://github.com/bats-core/bats-core).
`installBats` downloads bats-core 1.10 into `scripts/build/bats/` on first run.

## Self-inflatable archive

`assembleDist` produces `scripts/build/dist/HALDiSh-<version>.run`.
The archive is a pure-bash self-extractor: header script + base64-encoded tar.gz.

## Conventions

- All bash functions use the `hal::<namespace>::<name>` naming convention.
- Every public function must have a corresponding BATS test.
- Example scripts must source `hal_utils.sh` via `HAL_LIB_DIR` env var.
