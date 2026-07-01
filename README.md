# cldk-skillset

A Claude Code **plugin** bundling agent skills for *extending* and *maintaining*
[CodeLLM-DevKit (CLDK)](https://github.com/codellm-devkit) — adding a new language, wiring it into
the SDKs, and keeping the analyzer/SDK contract in lockstep.

The plugin is defined by [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) and published
through [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json). Each skill lives
under `skills/<name>/` with a `SKILL.md` describing when and how to invoke it, plus `references/`
holding the detailed specs the skill reads on demand.

## Skills

Adding a language to CLDK spans **two surfaces**, so the work is split into two focused skills you
run back to back — build and ship the analyzer, then bind it into the SDK(s).

### [`codeanalyzer-backend`](skills/codeanalyzer-backend/)

Build the **backend analyzer** `codeanalyzer-<lang>`: parse a new language and emit the canonical
`analysis.json` (symbol table + resolver-based call graph), then package and release it as a thin
`codeanalyzer-<lang>` PyPI distribution (+ GitHub Release binaries + a Homebrew formula). The
defining move is a guided, informed decision about the analyzer's backend tooling (parser,
resolver, enrichment, packaging), then scaffolding a **modular** analyzer to a validated level-1
analysis. Also covers the optional **Neo4j projection** (`--emit neo4j`) — a Cypher snapshot / live
Bolt push of the same IR — and all analyzer-side testing gates and definitions of done.

Anchored on [`../codeanalyzer-java`](../codeanalyzer-java),
[`../codeanalyzer-python`](../codeanalyzer-python), and
[`../codeanalyzer-typescript`](../codeanalyzer-typescript).

### [`cldk-sdk-frontend`](skills/cldk-sdk-frontend/)

Wire an existing `codeanalyzer-<lang>` into a CLDK **frontend SDK** so the language is reachable
through the user-facing API — `CLDK.<lang>(project_path=..., backend=...)` in the Python SDK today
(with the legacy `CLDK(language="<lang>").analysis(...)` kept as a compat shim), and the TypeScript
SDK the same way. The SDK selects along two axes — **language** (a `CLDK.<lang>()` factory method)
and **backend** (a config object: the local `codeanalyzer` backend, or an optional read-only
**Neo4j** backend that reconstructs the same model from a graph) — both behind a per-language
`<Lang>AnalysisBackend` ABC. The skill guides an interactive design of the facade's query surface,
then encodes it into each SDK with models that validate against the analyzer's `analysis.json`.

Anchored on [`../python-sdk`](../python-sdk).

## Using it

Install the plugin from the marketplace, then invoke a skill by name (or just describe the task —
"add Go support to CLDK", "wire the analyzer into python-sdk") and Claude Code will trigger the
matching skill. Precondition for `cldk-sdk-frontend`: a working, schema-conformant
`codeanalyzer-<lang>` produced by `codeanalyzer-backend` already exists.
