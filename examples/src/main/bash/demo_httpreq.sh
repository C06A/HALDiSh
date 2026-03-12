#!/usr/bin/env bash
# =============================================================================
# demo_httpreq.sh — browse JSONPlaceholder via httpreq.sh
#
# JSONPlaceholder (https://jsonplaceholder.typicode.com) is a free, public,
# no-key-required REST API for prototyping and testing HTTP clients.
#
# Demonstrates:
#   • GET  — fetch a single resource or a filtered list
#   • POST — create a new resource with URL-encoded body fields
#   • PUT  — replace an existing resource
#   • DELETE — remove a resource
#   • HTTP_IN_HEADERS — inject custom request headers
#   • Output files — inspect .curl, .status, .headers, .cookies, .body
#
# Run after installing the archive:
#   bash HALDiSh-0.1.0.run --prefix ~/mylibs
#   bash demo_httpreq.sh
# =============================================================================
set -euo pipefail

# ── load the library ──────────────────────────────────────────────────────────
LIB_DIR="${HAL_LIB_DIR:-${HOME}/.local/lib/haldish}"
source "${LIB_DIR}/env.sh"

# ── set up method symlinks and output directory ───────────────────────────────
# Method-named symlinks (GET, POST, PUT, DELETE) live in examples/build/demo/bin.
# All output files for the session accumulate in examples/build/demo/out
# and are kept after the script exits (inspect them after the session).
_demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/build/demo"
_demo_out="${_demo_root}/http"
mkdir -p "$_demo_out"

# All requests carry Accept: application/json
export HTTP_IN_HEADERS='Accept: application/json'

_BASE='https://jsonplaceholder.typicode.com'

# ── helpers ───────────────────────────────────────────────────────────────────

# _req <METHOD> [httpreq-args...]
# Runs the method-named script from the output directory.
# Returns the base name printed to stdout by httpreq.sh.
_req() {
    local method="$1"; shift
    (cd "$_demo_out" && "$method" "$@")
}

# _show <base>
# Prints a formatted response summary.
_show() {
    local base="${_demo_out}/$1"
    local status
    status="$(cat "${base}.status")"
    printf '\n'
    printf '  HTTP status : %s\n' "$status"
    printf '  Body:\n\n'
    sed 's/^/    /' "${base}.body"
    printf '\n'
    hal::log::info "Files saved: ${1}.{curl,status,headers,cookies,body}"
    printf '\n'
}

# _show_curl <base>
# Prints the saved curl command (useful for replay).
_show_curl() {
    local curl_file="${_demo_out}/${1}.curl"
    [[ -f "$curl_file" ]] || { hal::log::warn "No .curl file found."; return; }
    printf '\n  Replay command:\n\n'
    sed 's/^/    /' "$curl_file"
    printf '\n'
}

# ── main loop ─────────────────────────────────────────────────────────────────

hal::log::info "JSONPlaceholder demo — output files accumulate in: ${_demo_out}"
printf '\n'

while true; do

    choice=$(menu.sh "Choose a request to make" \
        "GET  /posts?_limit=5            list 5 posts" \
        "GET  /posts/1                   fetch post #1" \
        "GET  /comments?postId=1         comments on post #1" \
        "POST /posts                     create a post (-u body flags)" \
        "PUT  /posts/1                   replace post #1" \
        "DELETE /posts/1                 delete post #1" \
        "GET  /posts/1 + custom header   add X-Client header" \
        "Inspect last .curl file" \
        "Exit")

    echo

    [[ "$choice" == "Exit" ]] && break

    case "$choice" in

        "GET  /posts?_limit=5            list 5 posts")
            hal::log::info "GET ${_BASE}/posts?_limit=5"
            base=$(_req GET "${_BASE}/posts?_limit=5")
            _show "$base"
            ;;

        "GET  /posts/1                   fetch post #1")
            hal::log::info "GET ${_BASE}/posts/1"
            base=$(_req GET "${_BASE}/posts/1")
            _show "$base"
            ;;

        "GET  /comments?postId=1         comments on post #1")
            hal::log::info "GET ${_BASE}/comments?postId=1"
            base=$(_req GET "${_BASE}/comments?postId=1")
            _show "$base"
            ;;

        "POST /posts                     create a post (-u body flags)")
            hal::log::info "POST ${_BASE}/posts  (body via -u URL-encoded fields)"
            base=$(_req POST "${_BASE}/posts" \
                -u 'title=Hello from HALDiSh' \
                -u 'body=Created via httpreq.sh' \
                -u 'userId=42')
            _show "$base"
            ;;

        "PUT  /posts/1                   replace post #1")
            hal::log::info "PUT ${_BASE}/posts/1"
            base=$(_req PUT "${_BASE}/posts/1" \
                -u 'id=1' \
                -u 'title=Updated by HALDiSh' \
                -u 'body=This post was replaced via httpreq.sh' \
                -u 'userId=1')
            _show "$base"
            ;;

        "DELETE /posts/1                 delete post #1")
            hal::log::info "DELETE ${_BASE}/posts/1"
            base=$(_req DELETE "${_BASE}/posts/1")
            _show "$base"
            ;;

        "GET  /posts/1 + custom header   add X-Client header")
            hal::log::info "GET ${_BASE}/posts/1  (with X-Client: HALDiSh)"
            HTTP_IN_HEADERS=$'Accept: application/json\nX-Client: HALDiSh' \
                base=$(_req GET "${_BASE}/posts/1")
            _show "$base"
            hal::log::info "Request headers sent:"
            grep 'X-Client\|Accept' "${_demo_out}/${base}.curl" || true
            printf '\n'
            ;;

        "Inspect last .curl file")
            last=$(ls -t "${_demo_out}"/*.curl 2>/dev/null | head -1 || true)
            if [[ -z "$last" ]]; then
                hal::log::warn "No requests made yet."
                printf '\n'
            else
                base="$(basename "$last" .curl)"
                _show_curl "$base"
            fi
            ;;

    esac

    IFS= read -r -s -n1 -p "  Press any key to continue..." < /dev/tty
    echo
    echo

done

hal::log::ok "Goodbye!  Output files kept in: ${_demo_out}"
