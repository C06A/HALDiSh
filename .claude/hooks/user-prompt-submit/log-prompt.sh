#!/usr/bin/env bash
# Appends every user prompt to .claude/session-log.md

set -euo pipefail

LOG=".claude/session-log.md"
input=$(cat)

prompt=$(printf '%s' "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt',''))" 2>/dev/null || true)

[[ -z "$prompt" ]] && exit 0

date_str=$(date '+%Y-%m-%d %H:%M')

# Determine next prompt number
last_num=$(grep -oP '(?<=### Prompt )\d+' "$LOG" 2>/dev/null | sort -n | tail -1 || true)
next_num=$(( ${last_num:-0} + 1 ))

cat >> "$LOG" <<EOF

---

### Prompt ${next_num}  _(${date_str})_

> ${prompt}
EOF
