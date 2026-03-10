#!/usr/bin/env bash
# Appends one tool-call row to the current prompt section in .claude/session-log.md

set -euo pipefail

LOG=".claude/session-log.md"
input=$(cat)

tool_name=$(printf '%s' "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_name', ''))
" 2>/dev/null || true)

[[ -z "$tool_name" ]] && exit 0

# Build a human-readable action summary
summary=$(printf '%s' "$input" | python3 -c "
import sys, json
d    = json.load(sys.stdin)
name = d.get('tool_name', '')
inp  = d.get('tool_input', {})

if name == 'Bash':
    desc = inp.get('description', '')
    cmd  = inp.get('command', '').split('\n')[0][:80]
    out  = desc if desc else cmd
elif name == 'Read':
    out = inp.get('file_path', '')
elif name == 'Write':
    out = 'Create ' + inp.get('file_path', '')
elif name == 'Edit':
    out = 'Edit ' + inp.get('file_path', '')
elif name == 'Glob':
    out = inp.get('pattern', '')
elif name == 'Grep':
    pat = inp.get('pattern', '')
    out = 'Search \`' + pat + '\`'
elif name == 'Skill':
    out = 'Invoke /' + inp.get('skill', '')
elif name == 'Agent':
    out = inp.get('description', 'agent task')
else:
    out = str(inp)[:60]

print(out.replace('|', '/'))
" 2>/dev/null || true)

# Determine outcome from tool_response
decision=$(printf '%s' "$input" | python3 -c "
import sys, json
d    = json.load(sys.stdin)
resp = d.get('tool_response', {})
if isinstance(resp, dict):
    if resp.get('blocked'):
        print('**denied by user**')
    elif 'denied' in str(resp.get('error', '')).lower():
        print('**denied by user**')
    elif resp.get('isError') or resp.get('error'):
        print('error')
    else:
        print('auto-approved')
else:
    print('auto-approved')
" 2>/dev/null || true)

[[ -z "$decision" ]] && decision="auto-approved"

printf '| \`%s\` | %s | %s |\n' "$tool_name" "$summary" "$decision" >> "$LOG"
