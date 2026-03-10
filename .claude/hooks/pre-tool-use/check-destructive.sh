#!/usr/bin/env bash
# pre-tool-use hook: warn before running destructive Gradle tasks (clean, etc.)
# Claude Code passes the tool input as JSON on stdin.

input=$(cat)
command=$(echo "$input" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4)

case "$command" in
    *"clean"*)
        echo "WARN: About to run a clean task — build outputs will be deleted." >&2
        ;;
esac

exit 0
