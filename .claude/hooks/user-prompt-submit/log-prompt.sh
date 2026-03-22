#!/usr/bin/env bash
# Appends every user prompt (with tool-call table header) to .claude/session-log.md

set -euo pipefail

LOG=".claude/session-log.md"
input=$(cat)

prompt=$(printf '%s' "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('prompt', ''))
" 2>/dev/null || true)

[[ -z "$prompt" ]] && exit 0

date_str=$(date '+%Y-%m-%d %H:%M')

# Extract the prompt number: match digits immediately after "### Prompt "
# and before the first non-digit (space/underscore/end), so timestamps in
# the same line are never picked up.
last_num=$(sed -n 's/^### Prompt \([0-9][0-9]*\)[^0-9].*/\1/p' "$LOG" 2>/dev/null \
    | sort -n | tail -1 || true)
next_num=$(( ${last_num:-0} + 1 ))

cat >> "$LOG" <<EOF

---

### Prompt ${next_num}  _(${date_str})_

> ${prompt}

**Tool calls & permissions**

| Tool | Action | Decision |
|---|---|---|
EOF
