---
name: codeanalyzer-backend
description: >-
  Build or migrate the BACKEND language analyzer for CodeLLM-DevKit (CLDK): a `codeanalyzer-<lang>`
  that parses a programming language and emits the **canonical schema v2** — one additive
  node-tree-plus-typed-edges (a CPG) — in BOTH `analysis.json` and Neo4j, then packages and
  releases it. Use this whenever a CLDK maintainer wants to "add a language", "build a
  codeanalyzer for <X>", "migrate <X>'s analyzer to the new schema", "emit CFG/PDG/SDG/dataflow
  for <X>", or "support <X> in CLDK" at the analyzer level — even if they don't say "skill". Two
  entry paths: a NEW language (scaffold the analyzer from scratch) or an EXISTING analyzer (a
  major release that adapts it to emit schema v2). The core move is designing/confirming the
  canonical schema for the language, then building it up **level by level** (L1 symbol table → L2
  call graph → L3 intraprocedural dataflow → L4 interprocedural SDG), each an additive layer,
  shipped via tag-triggered release automation with a CLAUDE.md agent guide. This skill stops at
  the analyzer; wiring it into a CLDK SDK is the companion **cldk-sdk-frontend** skill. Do NOT use
  this for adding a contribution point to an existing analyzer (codeanalyzer-extension-builder),
  or for merely *using* CLDK to analyze code.
---

# CLDK analyzer backend

Build (new language) or migrate (existing analyzer) a `codeanalyzer-<lang>` that emits the
**canonical schema v2** (`references/canonical-schema.md` — read it first, it is the keystone).
The schema is **one additive structure** — a tree of code nodes with typed edge overlays, a CPG —
emitted in **two projections**: `analysis.json` and a Neo4j graph. Both are first-class
deliverables. This skill owns that analyzer and its distribution; wiring it into a CLDK **frontend
SDK** is the separate **cldk-sdk-frontend** skill, which consumes this skill's output.

The organizing principle is the schema's own:

> **Codeanalyzer is an additive analysis paradigm: each analysis level is the same tree grown one
> layer deeper, plus one edge family over the new layer.**

So you don't "build an analyzer" and then bolt on features — you **grow one structure, level by
level**, and each level is independently shippable.

## Two paths

Decide which up front (`AskUserQuestion` if unclear); the rest of the workflow branches lightly on
it:

- **(A) New language.** No analyzer exists. Choose the backend tooling, scaffold a modular
  analyzer, and build the schema up level by level. Most of this file.
- **(B) Existing analyzer → schema v2.** A `codeanalyzer-<lang>` exists on the **old** schema
  (flat `symbol_table` + rich or identity edges). This is a **major release**: keep the
  analyzer's parsing/resolution guts, and adapt its *emission* to schema v2 (both JSON and Neo4j),
  level by level. Follow `references/schema-migration.md`; the level structure below still governs
  the order you migrate in.

Either way the target is identical: an analyzer whose output validates against
`canonical-schema.md` at its implemented `max_level`, in both projections.

## Before you start: orient

- Confirm the **target language** and locate the CLDK reference repos (read-only; prefer a local
  sibling checkout, else clone into `/tmp` from `github.com/codellm-devkit/<repo>`):
  `codeanalyzer-java` (WALA — already ships L3/L4 via its slicer, the worked example of the full
  ladder), `codeanalyzer-python`, `codeanalyzer-typescript`, and `python-sdk` (the SDK your output
  must validate against). For an existing-analyzer migration, its own repo is the primary anchor.
- **Read the keystone first**, then the rest:
  - `references/canonical-schema.md` — **the v2 model.** The tree, the id grammar, the additive
    levels, the two projections. Everything else serves this.
  - `references/schema-reference.md` — the per-kind field/edge appendix.
  - `references/schema-design-loop.md` — **the method** for confirming the language's schema node
    by node (which kinds/fields it adds), anchored on the keystone + Java/Python.
  - `references/schema-migration.md` — path (B): old schema → v2, field-by-field, as a major
    release.
  - `references/analyzer-architecture.md` — the **modular package skeleton** (delegating `core`,
    per-phase subpackages, pluggable pass layer). Producing a *modular* analyzer is a success
    criterion, not a nicety.
  - `references/tooling-menu.md` — the L1/L2 backend-tooling decision (parser, resolver).
  - `references/dataflow-substrate-menu.md` — the L3/L4 substrate decision (CFG source, def-use,
    points-to oracle). The points-to slot is the L4 gate.
  - `references/dataflow-graphs.md` + `references/dataflow-construction.md` — the L3/L4 contract
    and construction method (CFG → dominance → def-use → PDG → summaries → SDG).
  - `references/cli-contract.md` — the CLI flags (`-a 1|2|3|4`, `--emit`, `--graphs`).
  - `references/neo4j-projection.md` — the co-primary graph projection (always full-depth).
  - `references/project-materialization.md`, `references/testing-and-validation.md`,
    `references/packaging-and-release.md` — build/deps, gates, distribution.

## Workflow — grow the tree, level by level

Work in order. Design the schema, scaffold the modular skeleton, materialize dependencies, then
**build the structure one level at a time**, each additive and gated. Every level emits **both**
projections (JSON + Neo4j). Levels 1–2 are the floor (always built); levels 3–4 are the dataflow
tier (opt-in, added when asked and when the substrate is chosen).

### Orient & choose the backend tooling
Walk the user through `references/tooling-menu.md` (runtime, structural parser, resolver,
build/dep materialization, packaging) and — **if L3/L4 are in scope** —
`references/dataflow-substrate-menu.md` (CFG source, def-use source, points-to oracle). Pre-fill a
recommendation per slot and confirm (`AskUserQuestion` for load-bearing ones). Ask the **target
depth** (`max_level`): L1–2 (symbol table + call graph, the default floor), L3 (intraprocedural
dataflow), or L4 (interprocedural SDG + taint). Record the locked decisions under an **Architecture
& Tooling** heading in the analyzer's `README.md`, and keep schema decisions in `.claude/
SCHEMA_DECISIONS.md`. **Then verify the toolchain is installed** (parser, resolver, the points-to
oracle if L4, plus the packaging/release toolchain) — if anything required is missing, stop and
give exact install commands, and wait. An analyzer you can't run is one you can't validate.

### Schema design (confirm the language's shape against the keystone)
The schema is already designed — it's `canonical-schema.md`. Here you **confirm the
language-specific expansion**: which type kinds, callable kinds, body-node kinds, CFG-edge kinds,
and typed fields this language adds to the shared spine (`references/schema-design-loop.md`). Run
it node by node, anchoring on the keystone and on how Java/Python model the same concept, and
**bring every genuine divergence to the user** (`AskUserQuestion`) — *"the spine has `type` with a
`kind`; Go needs `struct` + a receiver on methods; model receiver as X?"*. Record each answer in
`.claude/SCHEMA_DECISIONS.md`. Output: the confirmed per-language kind/field set, still the same
tree. (Path B: this is where you map old fields → v2 kinds; see `schema-migration.md`.)

### Scaffold the modular skeleton (seams first)
Lay out the analyzer as a **modular package** mirroring `codeanalyzer-python`
(`references/analyzer-architecture.md`): a thin CLI; a `core` **orchestrator that only delegates**;
`syntactic_analysis/` (the tree builder), `semantic_analysis/` (call graph + the dataflow passes,
framework backend isolated in its own subpackage), a `neo4j/` projection subpackage, and the
pluggable `analysis/` pass layer + `frameworks/` finder layer. Create the boxes empty-but-wired.
Retrofitting modularity into a monolith is the failure this prevents (`codeanalyzer-ts`'s original
flat build is the anti-example).

### Project materialization (build & dependency resolution)
Before parsing, materialize the target project's dependencies so the resolver can populate types
(`references/project-materialization.md`) — Java downloads deps for the classpath, Python builds a
venv for Jedi, Go runs `go mod download` for `go/packages`. Cache under `cache_dir`, degrade
gracefully to partial types on failure, honor `--no-build`/`--eager`.

### L1 — build the tree (symbol table)
Grow the containment tree to **callable depth**: `application → symbol_table{module} →
types{}/functions{} → callables{}`, each node with its `can://` id, `kind`, `span` (with byte
offsets), and the module's `source` stored once (`references/symbol-table-construction.md`).
Populate the language-native kinds/fields confirmed in schema design. This is the floor;
everything hangs off it. **Emit both projections** (JSON tree + Neo4j nodes/`HAS_*` edges).
**Gate:** output validates against the SDK `Application` model; `symbol_table` keys are relative
paths (no absolute, no `..`); `get_method_body` slices `module.source` correctly; re-run reuses
cache. (`references/testing-and-validation.md` § symbol-table gate.)

### L2 — call graph
Add the **`call_graph`** edge list at the application scope: resolve each call into a
`callable → callable` edge with `prov` and `weight`, using the Tier-1 resolver
(`references/dataflow-graphs.md` § levels). Backfill the `callee` refinement slot on call nodes
(`null → id`) — the one sanctioned mutation. Call edges are **immutable once written** (never
re-anchored to a statement at L3). Framework enrichment (Joern/WALA) merges *into this same list*
with added provenance — it's the orthogonal precision axis, not a level. **Gate:** every edge
endpoint is a real callable id (no dangling); output still validates.

### L3 — intraprocedural dataflow (optional; the first dataflow level)
Grow the tree **below the callable**: populate each callable's `body` with statement nodes, and
add the intra-callable edge lists `cfg`, `cdg`, `ddg` (**syntactic** — name-equality, no points-to
oracle needed). Build stage by stage per `references/dataflow-construction.md` (CFG → dominance →
def-use → PDG). AST-only and **per-callable parallel** (`-j`). This is a complete, shippable
capability (`-a 3`). **Gate:** the intraprocedural backward-slice on the fixture equals the
hand-computed node set, exactly.

### L4 — interprocedural dataflow (optional; needs the points-to oracle)
Add the **synthetic parameter vertices** (`formal_in/out`, `actual_in/out`) to `body`, the
cross-function `param_in`/`param_out` edge lists, the intra-caller `summary` edges, and the
**semantic** (alias-aware) `ddg` edges (`prov:["points-to"]`) — the whole-program SDG. Needs the
points-to oracle from the substrate menu + the summary fixpoint (stages 5–8 of
`dataflow-construction.md`). `-a 4`. **Gate:** no dangling SDG endpoints; a known source→sink taint
flow is found and its sanitized variant reported sanitized.

### Neo4j projection (co-primary, always full-depth)
The Neo4j graph is not an afterthought — it's the **second required projection**
(`references/neo4j-projection.md`). Build it as the modular `neo4j/` subpackage (pure
`project() → GraphRows → cypher/bolt writers` + a declarative schema catalog). Containment renders
as typed `HAS_*`/`DECLARES` edges; every overlay edge renders as a typed relationship; nodes carry
their `can://` id. `--emit neo4j` always runs at **maximum implemented depth** — analysis levels
gate the JSON path only; combining `-a`/`--graphs` with `--emit neo4j` is an explicit error. Keep
the graph schema versioned and in lockstep with the JSON schema (same kinds → labels).

### CLI, caching/incremental, packaging & release
Add the CLI family (`references/cli-contract.md`): `-a 1|2|3|4`, `--emit json|neo4j|schema`,
`--graphs`, `-j/--jobs`, `--eager`, `-c/--cache-dir`. **Validate all flag values** (unimplemented
→ non-zero error, never silent fallback). Cache by hash/mtime with vendored/test trees skipped.
**For packaging, be opinionated and follow `references/packaging-and-release.md`:** a
self-contained binary per platform, shipped as a thin `codeanalyzer-<lang>` PyPI wheel (+ GitHub
Release binaries + a `codellm-devkit/homebrew-tap` formula), cut by a tag-triggered `release.yml`.
The SDKs depend on the published package; they never build the binary. For an existing analyzer
migrating to v2, this is a **major version bump** — the schema change is breaking.

### Write the analyzer README (last build step)
Grow the `README.md` (which already holds the Architecture & Tooling decisions) into a complete,
user-facing README modeled on `codeanalyzer-python`'s: logo + one-liner; prerequisites (read the
minimum toolchain version from the build manifest, not what's installed); building/packaging/
releasing; usage + real `--help`; **the analysis levels** (what L1–L4 emit today, flagged
implemented-vs-stubbed by `max_level`); the schema contract (point at `canonical-schema.md`); and
SDK integration (bound by **cldk-sdk-frontend**). Write only what actually runs.

### Write the agent guide (CLAUDE.md + AGENTS.md symlink) — a default artifact
Every analyzer repo ships a root **`CLAUDE.md`, with `AGENTS.md` as a relative symlink** to it, so
Claude Code and the generic-agent convention read one source of truth. **Mirror
`codeanalyzer-typescript/CLAUDE.md`** as the template, and it must **describe the schema v2 model
in detail** (for maintainability): the additive paradigm, the node tree + edge overlays, the
`can://` ids, the level structure, and the two projections — so a future agent understands *what
this analyzer emits and why* without re-deriving it. Cover: what the repo is + chosen tooling; the
modular architecture and its invariants; how to build/test/run + the validation fixture; the schema
contract (link `canonical-schema.md` + `.claude/SCHEMA_DECISIONS.md`); packaging/release + version
lockstep; and repo rules (never add AI-authorship trailers). Watch the **global-gitignore trap** —
many setups exclude `AGENTS.md`, so un-ignore it in the repo's local `.gitignore` (`!AGENTS.md`)
and verify `git ls-files AGENTS.md` (or `git add -f`). Fold any existing `CLAUDE.md` in rather than
discarding it.

### Summarize & hand off to the frontend skill
Report: the two-path choice, the schema decisions (`SCHEMA_DECISIONS.md`), which `max_level` runs
today and what each level emits (on the fixture, both projections), the distribution artifacts
(PyPI package + version, Release binaries, brew formula, `release.yml`), the `README.md` and the
`CLAUDE.md`/`AGENTS.md` guide, and the diff summary. Confirm the **modularity** checks from
`analyzer-architecture.md` and the **schema gates** from `testing-and-validation.md` actually hold.
**Hand-off to cldk-sdk-frontend:** the SDK binding is a *separate* major release (`§ c`) — it
revises the Pydantic models to the v2 schema while keeping the same public API. Hand over a sample
`analysis.json` (each level), the schema contract + `SCHEMA_DECISIONS.md`, the CLI `--help`, and
the published package name + version to pin.

> **Never fake verification.** Every level's gate must actually run. If a required tool is found
> missing mid-build, stop and instruct the user to install it and wait. Full criteria, fixture
> design, and definitions of done: `references/testing-and-validation.md`.

## Guardrails
- **The schema is the success criterion.** An analyzer that runs but emits non-v2 JSON has failed
  the real job — the SDK can't load it, and the Neo4j graph won't match. Validate output against
  the SDK `Application` model at every level, in both projections. Mirror the schema
  **comprehensively** (`schema-reference.md`); a thin schema that "looks right" but drops fields is
  a silent failure.
- **Additive, never rewriting.** Each level only *adds* nodes/edges (plus the one `callee`
  refinement). `L1 ⊆ L2 ⊆ L3 ⊆ L4` is a CI-checkable superset gate. If a "higher" level would
  rewrite a lower level's fact, the model is wrong — fix the model.
- **Hold the parity line.** The shared vocabulary (node kinds, edge lists, `can://` grammar) is
  identical across analyzers; language extras are **additive** and recorded in `SCHEMA_DECISIONS.md`.
  This is what lets the SDK model the schema once and the Neo4j schema be one contract.
- **Modularity is a success criterion.** Mirror `codeanalyzer-python`'s structure — delegating
  `core`, a builder split by node kind, the framework backend and the `neo4j/` projection isolated
  in their own subpackages, a real pluggable pass layer. `codeanalyzer-ts`'s original monolith is
  the anti-example.
- **Two projections, always.** JSON and Neo4j are co-primary. Neo4j is always full-depth; levels
  gate the JSON path only.
- **No invented tooling.** If a recommended parser/resolver/oracle doesn't exist for the language,
  say so and fall back per the menu's reasoning, rather than inventing a package name.
- **Scope discipline.** This skill builds the *analyzer* and its distribution. Wiring it into the
  Python/TS/… SDKs is **cldk-sdk-frontend**; enriching an existing analyzer with a contribution
  point is `codeanalyzer-extension-builder`.
