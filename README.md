<!-- AUTO-GENERATED FILE — DO NOT EDIT.
-- Edit README.asciidoc and let CI regenerate this file.
-->


A Bash library and toolkit for HTTP requests, HAL document navigation,
and shell scripting utilities. Everything ships as a single
self-inflatable `.run` archive that requires nothing beyond Bash 4 and
standard UNIX tools.

# Getting the archive

## From GitHub Releases

Download the latest `.run` archive from the [Releases
page](https://github.com/C06A/HALDiSh/releases):

``` bash
curl -LO https://github.com/C06A/HALDiSh/releases/latest/download/HALDiSh-<version>.run
```

## From Maven Central

The archive is also published to Maven Central. You can download it
manually with curl:

``` bash
curl -LO "https://repo1.maven.org/maven2/com/helpchoice/haldish/<version>/haldish-<version>.run"
```

Or resolve it through a Gradle or Maven build (see [Using HALDiSh as a
dependency](#_using_haldish_as_a_dependency)).

# Installation

The `.run` file is a self-inflatable archive. Run it directly with Bash:

``` bash
bash HALDiSh-<version>.run
```

By default the library is extracted to `~/.local/lib/haldish`. Pass a
custom prefix with `--prefix`:

``` bash
bash HALDiSh-<version>.run --prefix /opt/haldish
```

The installer:

1.  Extracts all scripts to the prefix directory.

2.  Checks that Bash 4 or later is available.

3.  Creates the HTTP method entry-points (`GET`, `POST`, `PUT`, `PATCH`,
    `OPTIONS`, `DELETE`).

4.  Generates an integrity manifest used to detect post-install
    modifications.

# Activation

Source `env.sh` at the start of any shell session or script that uses
the library. This loads all utility functions and adds the library
directory to `PATH`:

``` bash
source ~/.local/lib/haldish/env.sh
```

After sourcing:

- All `hal::*` functions are available in the current shell.

- The library directory is prepended to `PATH`, so scripts such as
  `menu.sh`, `hal.sh`, and the HTTP method entry-points can be invoked
  by name.

- The `HAL_LIB_DIR` environment variable is exported and points to the
  installation directory. Scripts that need to locate the library at
  runtime can read this variable.

If validation fails (e.g. a file has been modified since installation),
`env.sh` returns 1 without loading anything.

# Library functions — `hal_utils.sh`

After activation all functions are available in the current shell. They
follow the `hal::<namespace>::<name>` naming convention.

## String utilities — `hal::str::*`

| Function                                  | Description                                        | Example                                  |
|-------------------------------------------|----------------------------------------------------|------------------------------------------|
| `hal::str::trim <string>`                 | Remove leading and trailing whitespace.            | `hal::str::trim " hello "` → `hello`     |
| `hal::str::upper <string>`                | Convert to uppercase.                              | `hal::str::upper "Hello"` → `HELLO`      |
| `hal::str::lower <string>`                | Convert to lowercase.                              | `hal::str::lower "HELLO"` → `hello`      |
| `hal::str::length <string>`               | Print the number of characters.                    | `hal::str::length "abc"` → `3`           |
| `hal::str::contains <haystack> <needle>`  | Return 0 if haystack contains needle, 1 otherwise. | `hal::str::contains "foobar" "oba"` → 0  |
| `hal::str::starts_with <string> <prefix>` | Return 0 if string starts with prefix.             | `hal::str::starts_with "hello" "he"` → 0 |
| `hal::str::ends_with <string> <suffix>`   | Return 0 if string ends with suffix.               | `hal::str::ends_with "hello" "lo"` → 0   |
| `hal::str::repeat <string> <n>`           | Print string repeated n times.                     | `hal::str::repeat "ab" 3` → `ababab`     |

## Array utilities — `hal::arr::*`

| Function                                    | Description                                        | Example                                       |
|---------------------------------------------|----------------------------------------------------|-----------------------------------------------|
| `hal::arr::contains <needle> "${array[@]}"` | Return 0 if needle is an element of the array.     | `hal::arr::contains "b" "a" "b" "c"` → 0      |
| `hal::arr::join <sep> "${array[@]}"`        | Join array elements with sep and print the result. | `hal::arr::join ", " "a" "b" "c"` → `a, b, c` |

## Filesystem utilities — `hal::fs::*`

| Function                          | Description                                        |
|-----------------------------------|----------------------------------------------------|
| `hal::fs::exists <path>`          | Return 0 if path exists (file or directory).       |
| `hal::fs::is_file <path>`         | Return 0 if path is a regular file.                |
| `hal::fs::is_dir <path>`          | Return 0 if path is a directory.                   |
| `hal::fs::mkdir_p <path>`         | Create directory and all parents; idempotent.      |
| `hal::fs::extension <path>`       | Print the file extension without the leading dot.  |
| `hal::fs::basename_no_ext <path>` | Print the filename without directory or extension. |

## Logging — `hal::log::*`

All logging functions write to stderr. Color output is disabled
automatically when stderr is not connected to a terminal.

Output can be filtered by level via the `HAL_LOG_LEVEL` environment
variable. The default level is `info`, which shows `info`, `ok`, `warn`,
and `error` messages while suppressing `debug` and `trace`.

| Function                              | Level                                                                                             | Description                                                                                   |
|---------------------------------------|---------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| `hal::log::trace <message>`           | `trace` (5)                                                                                       | Print a dim `[TRC ]` line. Most verbose; useful for step-by-step tracing.                     |
| `hal::log::debug <message>`           | `debug` (4)                                                                                       | Print a magenta `[DBG ]` line.                                                                |
| `hal::log::info <message>`            | `info` (3)                                                                                        | Print a cyan `[INFO]` line.                                                                   |
| `hal::log::ok <message>`              | Print a green `[ OK ]` line. Shares the `info` threshold — both are shown or suppressed together. |                                                                                               |
| `hal::log::warn <message>`            | `warn` (2)                                                                                        | Print a yellow `[WARN]` line.                                                                 |
| `hal::log::error <message>`           | `error` (1)                                                                                       | Print a red `[ERR ]` line.                                                                    |
| `hal::log::die <message> [exit-code]` | always                                                                                            | Print an error and exit. Default exit code is 1. Always prints regardless of `HAL_LOG_LEVEL`. |

### Controlling the log level

Pass the desired level as an argument to `hal::log::init`, or set
`HAL_LOG_LEVEL` and call `hal::log::init` with no argument — the
function falls back to the environment variable when none is supplied.
All messages at or above the configured level are printed. Level names
are case-insensitive.

| Value              | Numeric | Messages shown                                |
|--------------------|---------|-----------------------------------------------|
| `off`              | 0       | None (complete silence)                       |
| `0`                |         |                                               |
| `error`            | 1       | `error`, `die`                                |
| `err`              |         |                                               |
| `1`                |         |                                               |
| `warn`             | 2       | `warn`, `error`, `die`                        |
| `warning`          |         |                                               |
| `2`                |         |                                               |
| `info` *(default)* | 3       | `info`, `ok`, `warn`, `error`, `die`          |
| `ok`               |         |                                               |
| `3`                |         |                                               |
| `debug`            | 4       | `debug`, `info`, `ok`, `warn`, `error`, `die` |
| `4`                |         |                                               |
| `trace`            | 5       | All messages                                  |
| `5`                |         |                                               |

``` bash
# Pass level as an argument
hal::log::init warn
hal::log::debug "not printed"
hal::log::warn  "printed"

# Or rely on the environment variable
export HAL_LOG_LEVEL=warn
source ~/.local/lib/haldish/env.sh

# Change level mid-script — argument takes precedence over HAL_LOG_LEVEL
HAL_LOG_LEVEL=warn
hal::log::init debug
hal::log::debug "Starting verbose section"   # printed (debug overrides warn)
```

# HTTP client

After activation, the HTTP method entry-points (`GET`, `POST`, `PUT`,
`PATCH`, `OPTIONS`, `DELETE`) are on `PATH` and can be called directly.
They are all entry-points into `httpreq.sh`.

## Basic usage

``` bash
GET  'https://jsonplaceholder.typicode.com/posts/1'
POST 'https://jsonplaceholder.typicode.com/posts' -u 'title=Hello' -u 'userId=1'
```

The URL can also be piped via stdin using the `--` sentinel:

``` bash
echo 'https://jsonplaceholder.typicode.com/posts/1' | GET
printf 'https://jsonplaceholder.typicode.com/posts\n' | POST -- -u 'title=Hello'
```

## Output files

Each invocation writes a group of files named
`<domain>_<timestamp-ms>.*`:

| Extension  | Content                                                     |
|------------|-------------------------------------------------------------|
| `.curl`    | Shell-quoted `curl` command that replays the exact request. |
| `.status`  | HTTP status code (e.g. `200`).                              |
| `.headers` | Response headers, one `Name: Value` pair per line.          |
| `.cookies` | Response cookies, one `name=value` pair per line.           |
| `.body`    | Raw response body.                                          |

The base name (e.g. `jsonplaceholder.typicode.com_1711234567890`) is
printed to stdout, making it easy to pipe into the file-management
utilities.

## Request body options

| Flag        | Description                                                             |
|-------------|-------------------------------------------------------------------------|
| `-a [text]` | Plain-text body (`--data`). Omit text to read from stdin.               |
| `-u [text]` | URL-encoded body (`--data-urlencode`). Omit text to read from stdin.    |
| `-f [file]` | Multipart file upload (`--form`). Repeatable. Omit file to read stdin.  |
| `-b [file]` | Binary body from file (`--data-binary @file`). Omit file to read stdin. |
| `-r [file]` | Raw upload (`--upload-file`). Omit file to read stdin.                  |

## Request headers and cookies

Set request headers in the `HTTP_IN_HEADERS` environment variable (one
`Name: Value` per line) or point `HTTP_IN_HEADERS_FILE` at a file with
the same format. Cookies work the same way via `HTTP_IN_COOKIES` /
`HTTP_IN_COOKIES_FILE` (one `name=value` per line):

``` bash
export HTTP_IN_HEADERS="Authorization: Bearer $TOKEN
Accept: application/json"

GET 'https://jsonplaceholder.typicode.com/users/1'
```

## Including response headers in the replay

Pass `-i` before the body flags to record `-i` in the saved `.curl` file
so the replay shows response headers too:

``` bash
GET 'https://jsonplaceholder.typicode.com/posts/1' -i
```

## Pipeline example

``` bash
source ~/.local/lib/haldish/env.sh

base=$(GET 'https://jsonplaceholder.typicode.com/posts')
echo "Status: $(cat "${base}.status")"
hal.sh "${base}.body" properties id
```

# URI templates — `uritemplate.sh`

Expands [RFC 6570](https://www.rfc-editor.org/rfc/rfc6570) URI
templates.

## Usage

``` bash
uritemplate.sh <template> [var_binding...]
uritemplate.sh -           [var_binding...]   # template from stdin
echo '<template>' | uritemplate.sh [var_binding...]
```

Variable bindings use the following syntax:

| Syntax            | Type                                                               |
|-------------------|--------------------------------------------------------------------|
| `name=value`      | String variable. Repeat with the same name to build a list.        |
| `name[]=value`    | List append. Preferred syntax when providing list values directly. |
| `name[key]=value` | Map entry.                                                         |

## Examples

``` bash
uritemplate.sh 'https://example.com/users/{id}' 'id=42'
# → https://example.com/users/42

# List via repeated plain key
uritemplate.sh '{/segments*}' 'segments=a' 'segments=b' 'segments=c'
# → /a/b/c

# List via [] append syntax
uritemplate.sh '{?tags*}' 'tags[]=red' 'tags[]=green' 'tags[]=blue'
# → ?tags=red&tags=green&tags=blue

uritemplate.sh '{?q,lang}' 'q=hello world' 'lang=en'
# → ?q=hello%20world&lang=en

uritemplate.sh 'https://example.com{+path}' 'path=/foo/bar'
# → https://example.com/foo/bar
```

## Operator reference

| Operator | Behaviour                                           |
|----------|-----------------------------------------------------|
| (none)   | Comma-separated values; characters percent-encoded. |
| `+`      | Reserved passthrough; comma-separated.              |
| `#`      | Fragment prefix (`#`); reserved passthrough.        |
| `.`      | Dot-prefixed, dot-separated.                        |
| `/`      | Slash-prefixed, slash-separated.                    |
| `;`      | Semicolon-prefixed, named pairs.                    |
| `?`      | Query string (`?key=value&…`).                      |
| `&`      | Query continuation (`&key=value&…`).                |

Add `*` after a variable name to explode lists and maps into separate
components. Add `:N` to truncate a string variable to N characters.

# HAL document navigator — `hal.sh`

Navigate and extract values from
[HAL](https://stateless.co/hal_specification.html) documents in JSON,
YAML, or XML format.

Requires `yq` (mikefarah/yq v4) for YAML and XML, or `jq` for JSON.

## Interactive mode

``` bash
hal.sh <file>
```

Opens a menu-driven navigator. At each level you can choose links,
embedded resources, or properties to descend into. Selecting **print**
outputs the current node. Selecting **quit** or **exit** prints the
current jpath expression to stdout.

## Non-interactive mode

``` bash
hal.sh <file> links      [rel [N] [field]]
hal.sh <file> embeddeds  [rel [N] [args...]]
hal.sh <file> properties [key [args...]]
```

| Sub-command  | Description                                                                                                                  |
|--------------|------------------------------------------------------------------------------------------------------------------------------|
| `links`      | Extract from `_links`. Optionally filter by relation name, array index N, and a specific link field (e.g. `href`).           |
| `embeddeds`  | Extract from `_embedded`. Optionally filter by relation name and index, then traverse further into the nested resource.      |
| `properties` | Extract top-level properties (those outside `_links` and `_embedded`). Optionally specify a key and further traversal steps. |

## Examples

``` bash
# All link relations in a HAL document
hal.sh response.body links

# href of the first "order" link
hal.sh response.body links order 0 href

# Second embedded "items" resource
hal.sh response.body embeddeds items 1

# Value of the "total" property
hal.sh response.body properties total
```

# Interactive menu — `menu.sh`

A keyboard-driven single-selection menu for use in scripts or
interactively.

## Usage

``` bash
menu.sh <prompt> <option> <option>...   # all on the command line
menu.sh <prompt>                        # prompt as arg, options from stdin
menu.sh                                 # first stdin line = prompt, rest = options
```

The chosen option text is written to stdout; the menu display goes to
stderr. Invocations from scripts typically capture stdout:

``` bash
choice=$(menu.sh "Choose an environment:" staging production)
echo "Selected: $choice"
```

Selection is a single keypress (`1`–`9`, then `a`–`z`). When there are
more than 36 options the menu paginates (30 per page); press `<` / `>`
to move between pages.

# AsciiDoc integration — `adoc.sh`

Wraps files sharing a base name in AsciiDoc `tag::`/`end::` regions so
they can be included directly in documentation. Works naturally with the
output groups produced by the HTTP client scripts.

## Usage

``` bash
adoc.sh <base>...
printf "base1\nbase2\n" | adoc.sh
```

## Example

Given the files `jsonplaceholder.typicode.com_1711234567890.curl`,
`jsonplaceholder.typicode.com_1711234567890.status`, and
`jsonplaceholder.typicode.com_1711234567890.body`:

``` bash
adoc.sh jsonplaceholder.typicode.com_1711234567890
```

Output:

``` asciidoc
// tag::jsonplaceholder.typicode.com_1711234567890.curl[]
curl 'https://jsonplaceholder.typicode.com/posts/1' ...
// end::jsonplaceholder.typicode.com_1711234567890.curl[]
// tag::jsonplaceholder.typicode.com_1711234567890.status[]
200
// end::jsonplaceholder.typicode.com_1711234567890.status[]
// tag::jsonplaceholder.typicode.com_1711234567890.body[]
{"userId":1,"id":1,"title":"...","body":"..."}
// end::jsonplaceholder.typicode.com_1711234567890.body[]
```

## Saving to a file and including regions

Redirect the output to a `.adoc` file alongside your documentation
source:

``` bash
adoc.sh jsonplaceholder.typicode.com_1711234567890 >> examples/responses.adoc
```

Each tagged region can then be pulled into any AsciiDoc document with
the `include::` directive and a `tag=` attribute whose value is the file
name (including extension) used as the region label:

``` asciidoc
The following request was captured with HALDiSh:

[source,bash]
----
include::responses.adoc[tag=jsonplaceholder.typicode.com_1711234567890.curl]
----

The server responded with HTTP `\include::responses.adoc[tag=jsonplaceholder.typicode.com_1711234567890.status]`:

[source,json]
----
include::responses.adoc[tag=jsonplaceholder.typicode.com_1711234567890.body]
----
```

Because the tag label is the full file name (base + extension), a single
`.adoc` file can hold regions from many captured responses and you
reference only the ones you need.

# File management

## `rename.sh` — rename a request group

Renames all files that share a base name, preserving their extensions.

``` bash
rename.sh <new-name> <old-name>
rename.sh <new-name>               # old-name from stdin
```

``` bash
# Rename the captured response to something meaningful
base=$(GET 'https://jsonplaceholder.typicode.com/posts/1')
rename.sh get-post-1 "$base"
# get-post-1.curl  get-post-1.status  get-post-1.body  …
```

Pipeable — prints the new base name to stdout:

``` bash
GET 'https://jsonplaceholder.typicode.com/posts/1' | rename.sh get-post-1 | adoc.sh
```

## `cleanup.sh` — delete a request group

Deletes all files matching `<base-name>.*`, optionally keeping specific
extensions.

``` bash
cleanup.sh <base-name> [keep-ext...]
cleanup.sh -- [keep-ext...]           # base-name from stdin
```

``` bash
# Delete everything
cleanup.sh jsonplaceholder.typicode.com_1711234567890

# Keep only status and body
cleanup.sh jsonplaceholder.typicode.com_1711234567890 status body

# Pipeline: capture, process, then clean up
base=$(GET 'https://jsonplaceholder.typicode.com/posts')
hal.sh "${base}.body" properties total
cleanup.sh "$base"
```

Prints the base name to stdout for further piping.

# Examples module

The repository contains a runnable examples module under `examples/`. It
demonstrates every major feature of the library against real public APIs
and requires no configuration beyond having the archive installed.

## Running the examples

From the repository root, launch the interactive demonstrator:

``` bash
bash examples/src/main/bash/demonstrator.sh
```

The demonstrator automatically installs the HALDiSh archive into
`examples/build/haldish/` the first time it runs (via
`./gradlew :examples:installHaldish`), then presents a menu of available
example scripts. After each example finishes, control returns to the
menu so you can try another without restarting.

You can also run any example directly if the archive is already
installed and `HAL_LIB_DIR` is set:

``` bash
source ~/.local/lib/haldish/env.sh
bash examples/src/main/bash/demo_httpreq.sh
```

## Available examples

| Script                   | What it demonstrates                                                                                                                                                     |
|--------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `demo_strings.sh`        | `hal::str::*` functions: trim, case conversion, contains, starts_with, ends_with, repeat, length.                                                                        |
| `demo_arrays.sh`         | `hal::arr::*` functions: contains, join.                                                                                                                                 |
| `demo_filesystem.sh`     | `hal::fs::*` functions: existence checks, extension extraction, path manipulation.                                                                                       |
| `demo_menu.sh`           | All three invocation styles of `menu.sh` (arguments, piped options, full stdin) and how to branch on the selected value.                                                 |
| `demo_httpreq.sh`        | HTTP client against [JSONPlaceholder](https://jsonplaceholder.typicode.com): GET, POST, PUT, DELETE, custom headers, response file inspection, and curl replay commands. |
| `demo_periodic_table.sh` | Combined `menu.sh` and HTTP client demo: browse a public periodic-table API interactively.                                                                               |

## Syntax-checking examples

The `examples` module Gradle task `check` runs `bash -n` on every
example script to verify they parse correctly:

``` bash
./gradlew :examples:check
```

# Using HALDiSh as a dependency

## Gradle

Add a dedicated configuration for the `.run` artifact and register an
install task. The installed library is then available to any shell task
that sources `env.sh`.

``` kotlin
// build.gradle.kts

repositories {
    mavenCentral()
}

val haldish: Configuration by configurations.creating

dependencies {
    haldish("com.helpchoice.haldish:haldish:<version>@run")
}

val installHaldish by tasks.registering {
    inputs.files(haldish)
    val installDir = layout.buildDirectory.dir("haldish")
    outputs.dir(installDir)

    doLast {
        val dir = installDir.get().asFile
        dir.mkdirs()
        exec {
            commandLine("bash", haldish.singleFile.absolutePath,
                        "--prefix", dir.absolutePath)
        }
    }
}
```

After the task runs, the library is at `build/haldish/`. Activate it
from your shell scripts or Gradle `commandLine` blocks:

``` bash
source build/haldish/env.sh
GET 'https://api.example.com/resource'
```

## Maven

Maven cannot execute a `.run` file automatically, but you can download
the artifact and install it as a build step. Declare the dependency with
type `run` and use the `maven-dependency-plugin` to copy it, then invoke
the installer with the `exec-maven-plugin`:

``` xml
<dependencies>
  <dependency>
    <groupId>com.helpchoice.haldish</groupId>
    <artifactId>haldish</artifactId>
    <version>${haldish.version}</version>
    <type>run</type>
  </dependency>
</dependencies>

<build>
  <plugins>
    <plugin>
      <groupId>org.apache.maven.plugins</groupId>
      <artifactId>maven-dependency-plugin</artifactId>
      <executions>
        <execution>
          <id>copy-haldish</id>
          <phase>generate-resources</phase>
          <goals><goal>copy-dependencies</goal></goals>
          <configuration>
            <includeGroupIds>com.helpchoice.haldish</includeGroupIds>
            <outputDirectory>
              ${project.build.directory}/haldish-archive
            </outputDirectory>
          </configuration>
        </execution>
      </executions>
    </plugin>
    <plugin>
      <groupId>org.codehaus.mojo</groupId>
      <artifactId>exec-maven-plugin</artifactId>
      <executions>
        <execution>
          <id>install-haldish</id>
          <phase>generate-resources</phase>
          <goals><goal>exec</goal></goals>
          <configuration>
            <executable>bash</executable>
            <arguments>
              <argument>
                ${project.build.directory}/haldish-archive/haldish-${haldish.version}.run
              </argument>
              <argument>--prefix</argument>
              <argument>${project.build.directory}/haldish</argument>
            </arguments>
          </configuration>
        </execution>
      </executions>
    </plugin>
  </plugins>
</build>
```

## Direct download

If you prefer not to use a dependency manager, download the archive
manually and install it at a known location:

``` bash
curl -LO "https://repo1.maven.org/maven2/com/helpchoice/haldish/<version>/haldish-<version>.run"
bash haldish-<version>.run --prefix ~/mylibs/haldish
source ~/mylibs/haldish/env.sh
```

# Unit tests

The `scripts` module ships with a comprehensive BATS test suite that
covers all public functions and scripts.

## Test framework

Tests use [bats-core](https://github.com/bats-core/bats-core) 1.10.0,
which is downloaded automatically into `scripts/build/bats/` the first
time the test task runs. No global installation is required.

## Running the tests

``` bash
# Run the full test suite (downloads bats-core if needed)
./gradlew :scripts:test

# Install bats-core without running tests
./gradlew :scripts:installBats

# Run a single test file manually (requires bats on PATH)
bats scripts/src/test/bats/hal_str.bats
```

Test results are written in TAP format to `scripts/build/test-results/`.

## Test coverage

| Test file          | Coverage                                                                                                                                                                                             |
|--------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `hal_str.bats`     | `hal::str::*` — trim, upper, lower, length, contains, starts_with, ends_with, repeat.                                                                                                                |
| `hal_arr.bats`     | `hal::arr::*` — contains, join.                                                                                                                                                                      |
| `hal_fs.bats`      | `hal::fs::*` — exists, is_file, is_dir, mkdir_p, extension, basename_no_ext.                                                                                                                         |
| `hal_log.bats`     | `hal::log::*` — all levels (trace through error, die), level filtering via `HAL_LOG_LEVEL` (numeric and named values, case-insensitive, unknown defaults to info), `hal::log::init` dynamic re-read. |
| `httpreq.bats`     | HTTP client — method derivation, URL from arg/stdin, request headers and cookies, all body flags, output file creation and content.                                                                  |
| `uritemplate.bats` | RFC 6570 — all operators, prefix and explode modifiers, string/list/map variable types, percent-encoding, stdin template mode.                                                                       |
| `menu.bats`        | `menu.sh` — all invocation modes, selection keys, pagination, invalid input retry, TTY simulation.                                                                                                   |
| `hal.bats`         | `hal.sh` — format detection, non-interactive link/embedded/property extraction, interactive navigation.                                                                                              |
| `adoc.bats`        | `adoc.sh` — file grouping, AsciiDoc region wrapping, stdin mode.                                                                                                                                     |
| `rename.bats`      | `rename.sh` — base name handling, extension preservation, stdin mode.                                                                                                                                |
| `cleanup.bats`     | `cleanup.sh` — deletion with and without keep-extension list, stdin mode.                                                                                                                            |
| `env.bats`         | `env.sh` — sourcing guard, PATH setup, `HAL_LIB_DIR` export, integrity validation, duplicate-PATH prevention.                                                                                        |
| `setup.bats`       | `setup.sh` — Bash version check, file verification, method hardlink creation, manifest generation.                                                                                                   |
| `validate.bats`    | `validate.sh` — manifest presence, SHA-256 verification, method link checks.                                                                                                                         |

# Building from source

Requires Java 21 and the Gradle wrapper included in the repository.

| Task                         | Command                              |
|------------------------------|--------------------------------------|
| Run unit tests               | `./gradlew :scripts:test`            |
| Build the `.run` archive     | `./gradlew :scripts:assembleDist`    |
| Syntax-check example scripts | `./gradlew :examples:check`          |
| Full build (tests + archive) | `./gradlew build`                    |
| Install bats-core locally    | `./gradlew :scripts:installBats`     |
| Install HALDiSh for examples | `./gradlew :examples:installHaldish` |

The archive is produced at `scripts/build/dist/HALDiSh-<version>.run`.