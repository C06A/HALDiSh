---
name: readme
description: Generate README.asciidoc by exploring the project and writing a comprehensive user-facing reference document covering installation, activation, and usage of every public script or tool
---

# Generate README.asciidoc

Explore the project thoroughly, then write a complete `README.asciidoc` at the repository root.

**Research phase** — before writing, read enough of the codebase to answer:
- What does this project do and who is it for?
- How is it distributed and installed?
- What must a user do to activate or initialise it after installation?
- What are the public-facing scripts and library functions a user or calling script would use?
- What are the usage signatures, arguments, environment variables, stdin/stdout behaviour, and exit codes of each?
- Are there any notable integration patterns (piping, sourcing, composing tools together)?

**Document structure** — produce sections in a logical order for a new user reading top to bottom:
1. One-paragraph introduction.
2. How to obtain the distributed artifact.
3. Installation steps.
4. Activation / first-time setup.
5. One section per major public component (library namespaces, standalone scripts, sourced helpers, etc.) with usage syntax, option/flag tables, examples, and integration notes.
6. Build-from-source instructions.

**Formatting rules:**
- Standard AsciiDoc header attributes: `:toc: left`, `:toclevels: 3`, `:sectnums:`, `:icons: font`.
- Use `[cols=...,options="header"]` AsciiDoc tables for all reference material (flags, functions, operators, environment variables, etc.).
- When a listing block must contain inner `----` delimiters, use `------` (six dashes) for the outer block so inner delimiters are treated as literal content.
- Do not include internal implementation details (integrity checks, private helpers, generated files, internal environment variables, etc.).

Write the result directly to `README.asciidoc` — do not print it to the conversation.
