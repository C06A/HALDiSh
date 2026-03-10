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

# Determine next prompt number — use python3 + grep -E for macOS compatibility
last_num=$(grep -E '^### Prompt [0-9]+' "$LOG" 2>/dev/null \
    | grep -Eo '[0-9]+' \
    | sort -n \
    | tail -1 || true)
next_num=$(( ${last_num:-0} + 1 ))

cat >> "$LOG" <<EOF

---

### Prompt ${next_num}  _(${date_str})_

> ${prompt}

**Tool calls & permissions**

| Tool | Action | Decision |
|---|---|---|
EOF
