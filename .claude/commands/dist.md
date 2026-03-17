---
name: dist
description: Build the self-inflatable shell archive (.run file)
---

# Dist

Build the self-inflatable shell archive (`.run` file) from the scripts module.

```bash
./gradlew :scripts:assembleDist
```

The archive will be written to `scripts/build/dist/HALDiSh-<version>.run`.

Install it locally with:

```bash
bash scripts/build/dist/HALDiSh-*.run --prefix ~/.local/lib/haldish
```
