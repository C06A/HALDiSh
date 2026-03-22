---
name: commit-note
description: Generate a commit message for currently staged changes
---

# Commit note

Generate a commit message for the currently staged files.

```bash
git diff --staged
```

Review the staged diff above and write a concise commit message following the style of recent commits:

```bash
git log --oneline -5
```

Output only the commit message text — no explanation, no code block wrapper.
