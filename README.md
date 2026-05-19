# cldk-skillset

A collection of agent skills for working with [CodeLLM-DevKit (CLDK)](https://github.com/codellm-devkit) for *extending* and *maintaining* CLDK. This repo gathers reusable agent skills that help developers extend and expand CLDK itself (e.g., adding support for a new language, wiring up SDKs, adding new analyses, etc.).

## Planned Skills

### `cldk-language-pack`

This is an end-to-end skill that adds first-class support for a new language to CLDK as a "pack" that helps you bundle the backend analyzer and both SDKs. It scaffolds and wires up:
  - the **backend analyzer**: `codeanalyzer-<lang>` — modeled on [`../codeanalyzer-java`](../codeanalyzer-java) and [`../codeanalyzer-python`](../codeanalyzer-python)
  - the **Python SDK** bindings/APIs
  - the **TypeScript SDK** bindings/APIs

Each skill lives in its own directory with a `SKILL.md` describing when and how to invoke it and all the helpers/references to help build this out.

### `codeanalyzer-extension-builder`

Some applications in certain languages use features or idioms that a generic `codeanalyzer-<lang>` cannot capture out of the box. For example, service entrypoint detection in Python: while `codeanalyzer-python` understands Flask, FastAPI, and Django entrypoints, authors often write their own wrappers around these frameworks. To handle cases like this, `codeanalyzer` ships with an **extension mechanism** that lets you enrich the analysis without forking the analyzer. This skill walks you through building such an extension.

#### Extension Ecosystem

Extensions are first-class, discoverable, and packageable units that hook into pre-defined injection points in the backend. Concretely:

- **Self-contained packages.** Each extension is a directory (or installable package) containing the extension code, a manifest, and any supporting assets.
- **Directory-based discovery.** Extensions are auto-discovered from installed packages declaring a `codeanalyzer` manifest entry
- **Manifest-driven registration.** A small manifest (e.g., `extension.toml` / `package.json` block) declares the extension name, target language(s), version, entrypoint, and the **contribution points** it implements.
- **Contribution points (hooks).** Extensions opt into specific stages of the analysis pipeline rather than monkey-patching the analyzer. Examples include:
  - `entrypoint_detector` — declare additional functions/decorators/classes that should be treated as service entrypoints
  - `symbol_resolver` — teach the analyzer about custom DI containers, factories, or wrappers
  - `call_graph_enricher` — add synthetic edges (e.g., for dynamic dispatch via custom routers)
  - `taint_source_sink_pack` — contribute taint sources/sinks/sanitizers for a framework or in-house library
  - `metadata_annotator` — attach extra metadata (auth requirements, rate limits, etc.) to discovered symbols
- **Lifecycle hooks.** `before_analysis` / `after_analysis` (and per-pass variants) let extensions prepare state or post-process results.
- **Read-mostly enrichment.** Extensions enrich the analysis output through well-typed return values; they do not mutate analyzer internals, keeping behavior auditable and composable.
- **Shareable.** Extensions can be distributed as git repos or published packages, and pinned per-project for reproducibility.

#### What this skill does

Given a target language and a description of the idiom/framework to support, the skill:
1. Scaffolds the extension directory and manifest for the right `codeanalyzer-<lang>`.
2. Generates stub implementations for the relevant contribution points (e.g., an `entrypoint_detector` for a custom Flask wrapper).
3. Wires up discovery so the extension loads automatically in project-local or user-global locations.
4. Produces a minimal test/fixture project that exercises the new contribution points.
5. Documents the extension in a `README.md` and `SKILL.md`-style usage note so it is easy to share.
