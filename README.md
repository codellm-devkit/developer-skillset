# cldk-devtools

> Formerly cldk-forge. Now being remodeled into a mode ladder — see [the epic](https://github.com/codellm-devkit/cldk-forge/issues/13) for progress.

The forge where [CodeLLM-DevKit (CLDK)](https://github.com/codellm-devkit) gets built: a
[Claude Code](https://claude.com/claude-code) **plugin** of agent skills for extending CLDK —
build a new language's backend analyzer, wire it into the SDKs, and grow it through the
analysis levels: symbol table, call graph, and native dataflow.

## Install

```
/plugin marketplace add codellm-devkit/cldk-devtools
/plugin install cldk-devtools@codellm-devkit
```

Then just describe the task — *"add Rust support to CLDK"*, *"build a codeanalyzer for Kotlin"*,
*"wire the Go analyzer into python-sdk"*, *"add dataflow analysis to codeanalyzer-go"* — and the
matching skill triggers.

## Skills

### [`codeanalyzer-backend`](skills/codeanalyzer-backend/)

Build and release the **backend analyzer** `codeanalyzer-<lang>` for a new language: a guided
decision on the backend tooling (parser, resolver, packaging), then a **modular** analyzer
scaffolded and verified stage by stage, shipped as a thin PyPI wheel + GitHub Release binaries +
Homebrew formula via tag-triggered releases.

The analysis levels it owns:

| Level | What | Cost |
| --- | --- | --- |
| 1 | Symbol table + resolver-based call graph → canonical `analysis.json` | Cheap, always built |
| 2 | Framework-based call-graph enrichment (Joern/WALA/SVF) | Heavy, flag-gated |
| 3 | **Native dataflow**: CFG/DFG/PDG/SDG built from the language's own AST, with slicing and taint as queries | Heavy, in-process, flag-gated |

Also covered: the optional **Neo4j projection** (`--emit neo4j` — Cypher snapshot or live Bolt
push, with the CPG as the level-3 overlay), deterministic parallelism (`-j`), testing gates and
fixture design, and the analyzer README + `CLAUDE.md` agent guide as standing deliverables.

Key references: [`backend-recipe.md`](skills/codeanalyzer-backend/references/backend-recipe.md),
[`tooling-menu.md`](skills/codeanalyzer-backend/references/tooling-menu.md),
[`canonical-schema.md`](skills/codeanalyzer-backend/references/canonical-schema.md),
[`dataflow-graphs.md`](skills/codeanalyzer-backend/references/dataflow-graphs.md) (+ its
construction / substrate-menu / issue-template companions),
[`neo4j-projection.md`](skills/codeanalyzer-backend/references/neo4j-projection.md),
[`packaging-and-release.md`](skills/codeanalyzer-backend/references/packaging-and-release.md).

### [`cldk-sdk-frontend`](skills/cldk-sdk-frontend/)

Wire an existing analyzer into a CLDK **frontend SDK** — today the
[Python SDK](https://github.com/codellm-devkit/python-sdk): the `CLDK.<lang>()` factory method, a
per-language backend ABC with a local `codeanalyzer` backend and an optional read-only **Neo4j**
backend, Pydantic models that validate against the analyzer's `analysis.json`, and mocked + E2E +
backend-contract tests. The facade's query surface is designed interactively (every divergence
decided with you), then encoded per SDK.

## Typical flow

1. **`codeanalyzer-backend`** → a working, released `codeanalyzer-<lang>` (level 1, optionally
   level 2) with a validated schema contract.
2. **`cldk-sdk-frontend`** → the language reachable via `CLDK.<lang>(project_path=...)`.
3. When ready for dataflow: instantiate
   [`dataflow-issue-template.md`](skills/codeanalyzer-backend/references/dataflow-issue-template.md)
   as the level-3 epic on the analyzer repo (worked example:
   [codeanalyzer-go#3](https://github.com/codellm-devkit/codeanalyzer-go/issues/3)) and build it
   stage by stage.

## Layout

```
.claude-plugin/          # plugin + marketplace manifests
skills/
  codeanalyzer-backend/  # SKILL.md + references/ (the specs the skill reads on demand)
  cldk-sdk-frontend/     # SKILL.md + references/
```

Reference analyzers this skillset anchors on:
[`codeanalyzer-java`](https://github.com/codellm-devkit/codeanalyzer-java),
[`codeanalyzer-python`](https://github.com/codellm-devkit/codeanalyzer-python),
[`codeanalyzer-typescript`](https://github.com/codellm-devkit/codeanalyzer-typescript).
