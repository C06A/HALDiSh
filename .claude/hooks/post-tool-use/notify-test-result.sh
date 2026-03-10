#!/usr/bin/env bash
# post-tool-use hook: surface a short summary when a test task finishes.
# Claude Code passes tool result JSON on stdin.

input=$(cat)

# Only act on Bash tool results that look like a test run
if echo "$input" | grep -q '"tool_name":"Bash"'; then
    if echo "$input" | grep -qE '"output":.*gradlew.*test'; then
        if echo "$input" | grep -q '"exit_code":0'; then
            echo "✓ Tests passed." >&2
        else
            echo "✗ Tests failed — check output above." >&2
        fi
    fi
fi

exit 0
