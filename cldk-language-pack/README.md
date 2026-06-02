# cldk-language-pack — installation

An agent skill that scaffolds **first-class support for a new language in CodeLLM-DevKit
(CLDK)** end to end: a `codeanalyzer-<lang>` backend analyzer plus Python SDK bindings. It runs
a guided, opinionated workflow — choose backend tooling → design the schema (anchored on the
existing Java/Python/C analyzers, asking you at every divergence) → materialize deps → build the
symbol table + a cheap resolver-based call graph → wire the Python SDK on a branch.

This file is about **installing** the skill so Claude Code can use it. For what the skill does
and how it works, read `SKILL.md` and the `references/` directory.

## Prerequisites

- **Claude Code** (the skill is discovered from your skills directory).
- **git** — the skill clones the CLDK reference repos into `/tmp` if they aren't already on disk.
- When you actually *run* it for a target language, that language's **toolchain** must be
  installed (Node for ts-morph, the Go toolchain, rustc + rust-analyzer, clang/libclang, etc.).
  The skill probes for this up front and will stop and tell you exactly what to install if it's
  missing — it won't scaffold something it can't validate.

## Install

Pick one. The **symlink** method is best if you want skill edits to take effect without
reinstalling (recommended while iterating).

### A. Symlink into your user skills directory (recommended)

```bash
ln -s "$(pwd)/cldk-language-pack" ~/.claude/skills/cldk-language-pack
```

Run this from the repo root (the directory containing `cldk-language-pack/`). Edits to the
skill body and `references/` are picked up on the **next invocation**; edits to the
`description` in `SKILL.md` frontmatter (which controls triggering) require a **new session** to
reload.

### B. Copy into your user skills directory

```bash
cp -R cldk-language-pack ~/.claude/skills/cldk-language-pack
```

A static snapshot — re-copy after any change.

### C. Project-scoped (only this repo's sessions)

```bash
mkdir -p .claude/skills
ln -s "$(pwd)/cldk-language-pack" .claude/skills/cldk-language-pack
```

Use this to make the skill available only when working inside a particular project, rather than
globally.

## Verify

1. Start a **fresh** Claude Code session (the skill list loads at session start).
2. Run `/skills` and confirm **cldk-language-pack** appears.

## Use

Trigger it explicitly with `/cldk-language-pack`, or just describe the task — e.g.:

> Add first-class TypeScript support to CLDK — scaffold the codeanalyzer-ts backend and wire it
> into the Python SDK. I want to use ts-morph.

(Swap in Go, Rust, C++, etc.) The skill asks you the load-bearing decisions (backend tooling,
analysis depth, and every schema divergence) as it goes.

> **Heads up:** the skill edits the CLDK `python-sdk` on a new branch (`add-<lang>-support`) and
> may create a sibling `codeanalyzer-<lang>/` directory. If you'd rather it not touch a real
> checkout, point it at a throwaway clone.

## Uninstall

```bash
rm ~/.claude/skills/cldk-language-pack        # or .claude/skills/cldk-language-pack
```

Removes only the symlink/copy, not this source directory.
