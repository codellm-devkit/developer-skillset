---
name: codeanalyzer-backend
description: >-
  Build the BACKEND language analyzer for CodeLLM-DevKit (CLDK): a
  `codeanalyzer-<lang>` that parses a NEW programming language and emits the canonical
  `analysis.json` (symbol table + resolver-based call graph), then packages and releases it as a
  thin `codeanalyzer-<lang>` PyPI distribution. Use this whenever a CLDK maintainer wants to "add a
  language", "build a codeanalyzer for <X>", "write a CLDK backend/analyzer for <X>", or
  "support <X> in CLDK" at the analyzer level — even if they don't say the word "skill". The core
  move is a guided, informed decision about the analyzer's backend tooling (parser, resolver,
  enrichment, packaging) for the target language, then scaffolding a MODULAR analyzer to a working,
  validated level-1 analysis and shipping it via tag-triggered release automation. This skill stops
  at the analyzer; wiring the analyzer into a CLDK SDK (Python/TS/…) is the companion
  **cldk-sdk-frontend** skill. Do NOT use this for adding an extension/contribution point to an
  EXISTING analyzer (that's codeanalyzer-extension-builder), or for merely *using* CLDK to analyze
  code.
---

# CLDK analyzer backend

Build a new language's **backend analyzer** `codeanalyzer-<lang>`: it parses the language and emits
the canonical `analysis.json` (symbol table + call graph), then ships as a thin
`codeanalyzer-<lang>` PyPI distribution. This skill owns **one surface** — the analyzer and its
distribution. Wiring that analyzer into a CLDK **frontend SDK** (`CLDK(language="<lang>")
.analysis(...)` in the Python SDK, and later the TS/Rust/Go/Java SDKs) is the separate
**cldk-sdk-frontend** skill, which consumes this skill's output. Keep that boundary: here you
produce a validated, released analyzer + its `analysis.json` contract; the frontend skill binds it.

The skill's defining move is **not** picking a template — it's running a guided, informed decision
about *how to build the backend* for this specific language, then scaffolding from that decision. A
new language's analyzer must live in that language's own ecosystem to reach its best tooling, so the
tooling choices genuinely differ per language and the user owns them.

## Before you start: orient

- Confirm the **target language** and locate the CLDK reference repos — you anchor the schema
  and construction on the **already-implemented** analyzers. They normally sit as siblings:
  `codeanalyzer-java/`, `codeanalyzer-python/` (analyzer templates), `codeanalyzer-ts/` (a
  **cautionary** reference — see below), and `python-sdk/` (which also contains the **C** analyzer
  under `cldk/analysis/c/` — the procedural, non-class anchor — and is the model SDK Pydantic
  schema the analyzer's output must validate against). **If any of these is not present locally,
  clone it into `/tmp` and anchor on that copy** (read-only — never push to these):
  ```
  for r in codeanalyzer-java codeanalyzer-python codeanalyzer-ts python-sdk; do
    [ -d "/tmp/$r" ] || git clone --depth 1 https://github.com/codellm-devkit/$r.git "/tmp/$r"
  done
  ```
  Prefer a local sibling checkout if one exists (it may be ahead of `main`); fall back to the
  `/tmp` clone. Don't invent locations, and don't proceed to schema design without at least the
  Java and Python analyzers plus `python-sdk` available to read.
- Skim the analyzer references to ground yourself: **`codeanalyzer-python` is the model to
  replicate** — the modern, pluggable, cleanly-separated template (tree-sitter + Jedi);
  `codeanalyzer-java` is the heavyweight WALA one. Most new languages follow the *structure* of
  the Python one but in their own ecosystem. **`codeanalyzer-ts` is a cautionary reference: it
  runs and validates, but it was generated as a flat monolith** (a 968-line grab-bag of free
  functions, a `core` that inlines everything and hardcodes `entrypoints: {}`, and **no
  pluggable pass/registry/finder layer at all**). Read it to learn the anti-patterns to avoid —
  not the structure to copy. **Producing a modular package, not a working monolith, is a
  first-class success criterion of this skill** (see `references/analyzer-architecture.md`).
- Read these reference files now — they are the spec the scaffolding must satisfy:
  - `references/analyzer-architecture.md` — **the modular package skeleton the analyzer must
    have** (anchored on `codeanalyzer-python`, with `codeanalyzer-ts` as the anti-example).
    Read it before scaffolding: the seams are laid up front, not retrofitted.
  - `references/canonical-schema.md` — the `analysis.json` contract and its invariants. **Read first.**
  - `references/schema-reference.md` — the exhaustive, field-by-field schema derived from the
    SDK Pydantic models. This is what the analyzer must mirror **comprehensively** (every
    field, not a subset), and the basis for the validation success criterion.
  - `references/schema-design-loop.md` — **the method** for *Schema Design*: design the schema node by
    node by anchoring on Java + Python and **bringing every divergence to the user as a
    decision**.
  - `references/project-materialization.md` — *Project Materialization*: the build/dependency phase that must run
    **before parsing** (Java downloads deps for the SymbolSolver classpath; Python builds a
    venv for Jedi) so the resolver can populate types.
  - `references/symbol-table-construction.md` — *Symbol Table Construction*: how to walk files and populate the
    table, modeled on how Java (`SymbolTable.extractAll`) and Python (`core.py` rglob loop)
    actually do it.
  - `references/backend-recipe.md` — the 9-step methodology for building the analyzer.
  - `references/tooling-menu.md` — the per-language decision you'll walk the user through.
  - `references/cli-contract.md` — the CLI flags the analyzer must expose (the contract the
    frontend SDKs depend on; owned here).
  - `references/neo4j-projection.md` — the **optional second output surface**: projecting the
    same IR into a Neo4j graph via `--emit neo4j` (Cypher snapshot + live Bolt push). Every
    mature analyzer ships it; add it once level-1 JSON is solid.
  - `references/testing-and-validation.md` — **all analyzer-side verification criteria, fixture
    design rules, and definitions of done.** Read before writing any tests. (SDK-side testing
    is the frontend skill's `references/sdk-testing.md`.)
  - `references/packaging-and-release.md` — **the distribution layer**: cross-compile the binary,
    ship it as a thin `codeanalyzer-<lang>` PyPI package (+ raw binaries as GitHub Release assets +
    a `brew install codeanalyzer-<lang>` formula pushed to the shared `codellm-devkit/homebrew-tap`),
    and cut tag-triggered releases. Standing up `packaging/python/` + `packaging/homebrew/` +
    `release.yml` is a first-class deliverable.

## Workflow

Work the steps below in order, and **don't design the whole thing up front**. Design the schema,
**scaffold the modular package skeleton**, materialize the project's dependencies, construct the
symbol table file by file, then build the cheap resolver-based call graph. *Symbol Table Construction* + *Call Graph Construction* together
are **level 1 — the cheap, resolver-based analysis** (symbol table *and* call graph, both from
the same Tier-1 resolver). The heavy **level 2 — framework-based** analysis (WALA/CodeQL/Joern/
SVF) is optional and comes later. Each step models itself on what the mature reference analyzers
(Java + Python) do.

### Orient & choose the backend tooling
The developer's real first move: *what backend am I using?* Walk the user through the tooling
menu (`references/tooling-menu.md`). **Pre-fill a recommendation for each slot** (runtime,
structural parser, resolver, optional enrichment, build/dep materialization, packaging) and ask
for confirmation — don't silently choose, don't ask an open-ended "what do you want?". Use
`AskUserQuestion` for the load-bearing slots, especially *is the structural tool also the
resolver, or are they separate?* — that reshapes everything downstream. Note what the chosen
resolver needs materialized (Jedi→venv, TS checker→`tsconfig`+`node_modules`, `go/types`→`go mod
download`).

Also ask the **analysis depth** they want (`AskUserQuestion`):
- **Rapid — level 1 (default):** symbol table + the cheap resolver-based call graph. The
  framework backend is left stubbed.
- **Deep — level 2:** also stand up the framework-based backend (CodeQL/Joern/SVF/WALA),
  flipping the *Level 2: framework-based analysis* step from stubbed to implemented.

Default to **rapid (level 1)** — level 1 is always built (it's the floor; level 2 builds on it),
and deep is opt-in. Record the agreed choices — including the depth **and the packaging build
strategy** (single-host cross-compile vs native-runner matrix; `packaging-and-release.md`) — under
an **"Architecture & Tooling"** heading in the analyzer's own `codeanalyzer-<lang>/README.md`. This
is deliberately a public, top-level doc: it documents for human readers *which backend tooling
was chosen and why*, and it doubles as the guide any later session (you included, or the
**cldk-sdk-frontend** skill) reads to recover the locked decisions without re-litigating them.
Capture each load-bearing slot (runtime, structural parser, resolver, optional enrichment,
build/dep materialization, packaging, depth, extra node kinds) and a one-line rationale per
non-default choice. Keep the *Schema Design* `SCHEMA_DECISIONS.md` under the analyzer's `.claude/`
folder (create it if needed); only these tooling decisions are promoted into the README.

**Then check the toolchain is installed, before building anything.** The chosen tooling has hard
prerequisites (Node + the analyzer's deps for ts-morph; the Go toolchain for `go/types`; the
Rust toolchain + rust-analyzer; clang/libclang for C++; plus any framework backend like CodeQL/
Joern if *deep*) **and the packaging/release toolchain that cross-compiles and publishes the
`codeanalyzer-<lang>` package** (e.g. Bun for `bun build --compile --target=...`, GraalVM
`native-image` for JVM, the cross-compile target for Go/Rust; plus Python `build`/`wheel`/`twine`
+ `auditwheel` for the platform wheels — see `references/packaging-and-release.md`). Probe for
them (e.g. `node --version`, `go version`, `rustc --version`, `clang --version`, `bun --version`).
**If anything required is missing, stop and instruct the user to install it**
— give the exact install commands for their platform and what each is for — and **wait** until
they confirm it's available. Do **not** proceed to scaffold-and-leave-unverified: an analyzer you
can't run is an analyzer you can't validate against the schema, which is the whole success
criterion. Only continue once the toolchain is present.

### Schema Design (interactive, node by node)
Design the canonical schema once — it is the **contract** the analyzer's `analysis.json` emits, and
the contract the **cldk-sdk-frontend** skill later encodes as SDK models. Here you produce **two
things in lockstep: the analyzer-side types AND the contract** (`canonical-schema.md` /
`schema-reference.md`); the per-SDK `cldk/models/<lang>/` Pydantic models (and TS types) are built
later by the frontend skill against this same approved contract. Run the loop in
`references/schema-design-loop.md` per node (spine first: `Module` →
`Class` → `Callable` → `Callsite` → `CallEdge`, then language-native kinds):

1. **Anchor** — read the node in **Java** (`cldk/models/java/models.py`) and **Python**
   (`py_schema.py`) side by side. Catalog the shared spine and **every place they diverge**.
2. **Differentiate** — ask *"how is the `<lang>` language structurally different here?"*
   (language semantics, not domain) and note each genuinely new concept.
3. **Decide each open point WITH the user.** This is the rule: for every divergence and every
   new concept, **don't choose silently — ask** (`AskUserQuestion`). Present it as *"Java did X,
   Python did Y; for `<lang>`, concept Z, how do you want to model it?"* with explained options
   and a recommended default. (E.g. *Java annotations are flat strings, Python uses structured
   `PyDecorator`; for TS decorators that carry args, option 1: structured `TSDecorator`
   (recommended) …*.) Record each answer in `.claude/SCHEMA_DECISIONS.md`.
4. **Define** — encode the decisions into the analyzer-side type and update the contract;
   snake_case, optional-with-defaults, spine untouched, identity-only edges. (These same decisions
   drive the SDK models the frontend skill builds — `SCHEMA_DECISIONS.md` is its input.)

No files are walked yet. Output: a complete, user-approved schema contract + the analyzer types +
`SCHEMA_DECISIONS.md`.

### Scaffold the modular skeleton (seams first, before filling phases)
Before writing any analysis logic, lay out the analyzer as a **modular package that mirrors
`codeanalyzer-python`'s structure** — one subpackage per phase plus the pluggable pass layer —
following `references/analyzer-architecture.md`. Create the boxes empty-but-wired: a thin CLI
entry; a `core` **orchestrator that only delegates** (no inlined parsing, and never a hardcoded
`entrypoints: {}`); `syntactic_analysis/`, `semantic_analysis/` (with the framework backend in
its **own subpackage**, seams scaffolded even when stubbed); and the extensibility layer —
`analysis/` (the `AnalysisPass` base + a registry that discovers, topo-orders by
`requires`/`provides`, and runs a `run_pipeline`) and `frameworks/` (the entrypoint-finder base).
The built-in pass list and concrete finders may start empty, but **the seams and entry-point
discovery must exist now** — that is exactly the layer the generated TS analyzer was missing, and
where `codeanalyzer-extension-builder` later plugs in. Retrofitting modularity into a monolith is
the failure this step prevents.

### Project Materialization (build & dependency resolution)
Before parsing, materialize the target project's dependencies so the resolver can populate
types — this is a real phase with its own failure modes. Follow
`references/project-materialization.md`, modeled on Java
(`BuildProject.downloadLibraryDependencies` runs *before* the symbol table, for the
SymbolSolver classpath) and Python (`core.py` builds a **venv** + `pip install` and passes it
to the symbol-table builder, because Jedi needs it). For the new language: detect the manifest
(`tsconfig.json`+`package.json`, `go.mod`), run the ecosystem installer (`npm ci` →
`node_modules`; `go mod download`), **cache** it under `cache_dir`, **degrade gracefully** to
partial types on failure (never crash), and honor `--no-build`/`--eager`. Source-level
resolvers (TS checker, `go/types`, Jedi) need deps **present**, not a full compile; defer any
heavier compile to just before *Call Graph Construction* if your call-graph backend needs build artifacts.

### Symbol Table Construction (file by file)
Now populate the schema. Follow `references/symbol-table-construction.md`, which is built by
**studying how Java (`SymbolTable.extractAll` → `symbolTable.put(path, ...)`) and Python
(`core.py`'s `rglob` loop → `build_pymodule_from_file` → `symbol_table[file_key] = module`)
iterate over files** — then doing the same for the new language: discover source files (skip
vendored/test trees), compute stable relative `file_key`s, per-file cache-check then build the
`Module` (filling classes/functions/native kinds + **unresolved** call sites with
`callee_signature` null + cache metadata), and assemble `symbol_table: Dict[path, Module]`.
Support whole-project, `-t` target-files, and (optional) single-source modes. This stage
records call sites but doesn't resolve them into edges yet — the cheap resolution is the very
next stage (still level 1).

**Path predicate pitfall — apply filters to the relative path, never the absolute path.**
Every file-skip predicate (`IsVendored`, `IsTestFile`, and any custom equivalent) must be
evaluated against the path *relative to the project root* — not the absolute path. Absolute
paths carry segments from the analyzer's own directory layout (`testdata`, `vendor`, `.git`,
etc.) that falsely trigger the filter and silently empty the symbol table. Resolve the project
root to an absolute path at the top of the analysis entry point, then derive all relative keys
as `rel(projectRoot, absFilePath)`. Using the process's working directory as the base
(e.g. `rel(".", absPath)`) is a separate trap: it produces the right answer only when the
process happens to run from the project root, which is never the case in tests.

**Cross-file type/method attachment — check whether your language requires a two-pass build.**
In some languages a type and its method bodies can be spread across multiple files of the same
unit (Go packages, C# partial classes and extension methods, Kotlin extension functions, Ruby
open classes). A single-pass, file-by-file builder that resolves receiver types only within
the current file silently drops every method defined in a sibling file. Identify whether the
target language has this property before writing the builder. If it does, use a two-pass
approach: pass 1 collects all type declarations from every file and builds a
`(unit, typeName) → ownerFile` index; pass 2 attaches methods using that index. Retrofitting
this after the fact is costly — the fix lives in the core iteration loop.

**Symbol-table gate (verify):** Run the analyzer on the fixture and confirm the criteria in
`references/testing-and-validation.md § 2` (symbol-table gate). Don't proceed until this passes.

### Call Graph Construction (resolver-based, cheap — completes level 1)
This is **cheap and part of level 1**, not a heavy pass: the same Tier-1 resolver that typed the
symbol table (Jedi/tsc/rust-analyzer/clang) is already loaded, so resolving call sites into edges
is inexpensive. For each recorded call site: resolve the callee → **backfill `callee_signature`
in place** → emit an identity-only edge `source_sig → target_sig` with `provenance` = your
resolver. Handle constructors/`new`, receiver-type dispatch, and an explicit unresolved fallback
(record the site, skip the edge, never crash). Don't mutate the symbol table beyond filling
`callee_signature`.

**Its precision is a decision the references disagree on — so ask.** Don't frame the tiers as
"whole-program vs not" — once deps are materialized the resolver resolves across the
whole program too; the axis is the *engine* (`tooling-menu.md` § "Call-graph tiers"). Python's
cheap `jedi` call graph lives here at level 1 and **drops** unresolved sites; **Java is the
outlier** — it has no cheap resolver call graph, so its call graph *is* the heavy Tier-2 WALA
pass (`makeRTABuilder` → **RTA**), which for a new resolver-capable language belongs in the
*Level 2: framework-based analysis* step. For the chosen resolver, surface the dispatch choice
(declared-type only ≈ CHA, + instantiated subtypes ≈ RTA-style); heavier framework-based
precision (WALA/CodeQL/Joern/SVF) belongs to that level-2 step, not here.

**Verify:** confirm the criteria in `references/testing-and-validation.md § 2` (call-graph
gate) — every edge endpoint matches a real signature (no dangling nodes) and output still
validates. (`backend-recipe.md` step 6.)

### CLI, caching/incremental, packaging & release
Add the CLI family surface (`cli-contract.md`) with `analysis.json` as the only facade-visible
output. **Validate all flag values** — unrecognized or unimplemented values (e.g. `--format
msgpack` before msgpack is implemented) must return a non-zero exit with a clear message, never
silently fall back (`cli-contract.md § Flag validation requirements`).

**Caching has three independent layers — implement and test each explicitly:**

1. **Materialization cache** — memoizes the dependency-fetch step (`go mod download`, `npm ci`,
   venv build) by hashing the manifest (`go.sum`, `package-lock.json`, `requirements.txt`).
   Stored in `cache_dir`. Bypassed by `--eager`.
2. **Per-run output cache** (`analysis_cache.json`) — written to `cache_dir` after every
   successful `Analyze()` call. Always rewritten; gives the SDK something to read without
   re-invoking the binary. `--eager` rewrites it; non-eager runs still write it (it's not
   a skip guard at the binary level).
3. **SDK-level skip** — the Python facade reads the *output dir*'s `analysis.json`, validates
   it, and **skips invoking the binary entirely** if valid. This is where the real "don't
   re-run the binary" logic lives (frontend skill). The binary itself always runs fresh
   analysis when invoked.

The behavioral tests for caching are in `references/testing-and-validation.md § 2`.

**For packaging, be opinionated and follow `references/packaging-and-release.md`:
build a self-contained binary for every platform, then ship it as a thin
`codeanalyzer-<lang>` PyPI package** — one platform-tagged wheel per OS/arch, carrying the binary
and exposing `bin_path()` — **plus raw binaries as GitHub Release assets, plus a Homebrew formula
`Formula/codeanalyzer-<lang>.rb` pushed to the shared `codellm-devkit/homebrew-tap`** (so end users
get `brew install codeanalyzer-<lang>`), all cut by a **tag-triggered `release.yml`**. The brew
formula reuses the same Release-asset binaries (compiled case) or the same PyPI package (Python
case) — never a rebuild. The frontend SDKs *depend on* that published package; they never
bundle or build the binary. Build it by **single-host cross-compile where the toolchain allows** (TS
via `bun build --compile --target=<plat>`; Go via `GOOS`/`GOARCH`; Rust via target triples) **or a
native-runner build matrix where it doesn't** (JVM via GraalVM `native-image`, which can't
cross-compile; C++/clang with per-target sysroots). A Python analyzer is the same PyPI package but
its wheel carries code, imported in-process. **Release automation is standard practice, not optional:** stand up
`packaging/python/` (the `build_wheels.sh` + `pyproject.toml` + `bin_path()` package) and
`.github/workflows/release.yml`, tag releases `vX.Y.Z` with real notes modeled on
`codeanalyzer-python`'s GitHub Releases (Keep-a-Changelog *Added/Changed/Fixed* + auto-generated
*Detailed Changes*), publish to PyPI under `codeanalyzer-<lang>` (prefer OIDC Trusted Publishing),
and **record the published name + version** so the frontend skill can pin it. (`backend-recipe.md`
steps 3, 8, 9; full spec in `references/packaging-and-release.md`; rationale in `tooling-menu.md`
§ "Packaging".)

### (Optional) Neo4j graph projection — a second output surface
Once the level-1 `analysis.json` path is solid, add the **optional Neo4j projection** every
mature analyzer now ships (`references/neo4j-projection.md`). It is not an ingestion of the
JSON — it's an **alternative projection of the same in-memory IR**, selected by `--emit neo4j`,
producing either a self-contained `graph.cypher` snapshot or a live Bolt push, plus `--emit
schema` for the static `schema.neo4j.json` contract. Build it as a modular `neo4j/` subpackage
(`project` → `GraphRows` → `cypher`/`bolt` writers + a declarative `schema`), keep the driver an
**optional/lazy** dependency, and hold the graph schema in lockstep with the JSON schema (same
`SCHEMA_DECISIONS.md` node kinds → node labels; identity-only call edges → `CALLS`). The SDK's
Neo4j backend (frontend skill) reconstructs the canonical model from this graph, so the node
families and `--app-name` anchor must match. Leave it out only if the user explicitly scopes to
JSON-only; otherwise it's a standard deliverable of the CLI/packaging stage.

### (Optional) Level 2: framework-based analysis
Gated on the depth choice from *Orient & choose the backend tooling*. The heavy tier — a dedicated analysis engine
(CodeQL/Joern/SVF, or WALA-style; `backend-recipe.md` step 7) for points-to/dataflow edges the
cheap resolver can't reach. If the user picked **rapid (default)**, leave it a wired, flag-gated
extension point with a clear TODO. If they picked **deep**, implement it now and merge its edges
into the resolver graph by `(source, target)` with provenance union. (For a language whose call
graph is *only* available this way — e.g. Java/WALA — this stage is where that call graph lives,
regardless of the depth choice.)

### Write the analyzer README (last build step)
The analyzer's `codeanalyzer-<lang>/README.md` already holds the **Architecture & Tooling**
decisions recorded back in *Orient & choose the backend tooling*. As the **final build step**,
grow that file into a complete, user-facing README modeled on the reference analyzers'
**`main`-branch** READMEs — `codeanalyzer-python/README.md` (the model to replicate) and
`codeanalyzer-java/README.md`. Don't invent a layout; mirror theirs, in this order:
- **Logo + title + one-line what-it-is** — open with the shared CLDK logo, reusing the Python
  repo's hosted URL (the analyzers share branding) rather than committing a per-language copy:
  ```md
  ![logo](https://github.com/codellm-devkit/codeanalyzer-python/blob/main/docs/assets/logo.png?raw=true)
  ```
  Then name the language and the chosen backend tooling (e.g. "Static analysis for `<lang>`
  using `<parser>` + `<resolver>`"), echoing the reference openers.
- **Prerequisites / installation** — the toolchain confirmed installed up front (runtime,
  parser, resolver, plus any framework backend if *deep*), with exact per-platform install
  commands as Python does for `venv`/build tools. Read the minimum version from the **build
  manifest** (`go.mod`'s `go` directive, `Cargo.toml`'s `rust` field, `pyproject.toml`'s
  `requires-python`, etc.) — not from what happens to be installed. Record both the minimum
  and the version the analyzer was actually tested on.
- **Building, packaging & releasing** — how to build the self-contained binary and ship it
  as the `codeanalyzer-<lang>` PyPI package + GitHub Release assets, and how releases are cut
  (`packaging/python/` + `packaging/homebrew/` + tag-triggered `release.yml`), per *CLI,
  caching/incremental, packaging & release* and `references/packaging-and-release.md`. For an SDK
  user it's just `pip install codeanalyzer-<lang>`; for an end user, `brew tap codellm-devkit/tap &&
  brew install codeanalyzer-<lang>`.
- **Usage + CLI options** — paste the real `--help` output (from `cli-contract.md`), then a few
  worked **examples** like the Python README (basic symbol table, `--output`, level-2/framework
  flag).
- **Analysis levels** — what level 1 (symbol table + resolver call graph) emits today and what
  level 2 (framework backend) adds — flagged stubbed-vs-implemented per the depth choice.
- **Output schema** — point at the canonical `analysis.json` / `<Lang>Application` contract.
- **SDK integration** — note that the CLDK SDKs bind this analyzer (Python:
  `CLDK(language="<lang>").analysis(...)`; others later), wired by the **cldk-sdk-frontend** skill.
- Keep the **Architecture & Tooling** section (the locked decisions) intact as its own heading.

Write only what actually runs — don't document level-2 as working if it's a stubbed extension
point. The README is the human-readable counterpart to the validated `analysis.json`: like every
other stage, it describes the analyzer as it really is.

### Write the agent guide (CLAUDE.md + AGENTS.md symlink) — a default artifact
Every analyzer repo ships an **agent onboarding guide as a standing deliverable**, not an
afterthought: a root `CLAUDE.md`, with `AGENTS.md` as a **symlink pointing at it**, so Claude Code
and the generic-agent convention read one source of truth. Always produce these — even for a
minimal analyzer.

**The template is `codeanalyzer-typescript/CLAUDE.md` — mirror it.** It is the canonical form; do
not invent a layout. Read it and reproduce its structure, regenerating the analyzer-specific
sections for `<lang>` and carrying the standard sections over near-verbatim (adjusted for the new
repo). `CLAUDE.md` is the *contributor/maintainer* counterpart to the user-facing README — it tells
a coding agent how this repo is built, not how to use the CLI. Keep it concise and **specific to
the analyzer as actually built** (no boilerplate), in the template's order:

- **Title + one-liner** — `Agent guidance for codellm-devkit/codeanalyzer-<lang> (<short-name>)`.
- **What this project is** — the language, the chosen backend tooling, that it emits the canonical
  `analysis.json` (symbol table + resolver call graph) **and** (if built) the optional Neo4j
  projection, and that it **mirrors the Java/Python/TS sibling analyzers so output-shape parity is
  a first-class concern**. One line, pointing at the README's *Architecture & Tooling* section for
  the locked decisions.
- **Architecture — follow the pipeline** — name the single `analyze()`/`core` orchestrator and
  list its ordered stages (materialize → symbol table → call graph → cache → output/neo4j), the way
  the template walks `src/core.ts`. State the **modularity rules as invariants** a change must
  preserve (no inlined analysis in `core`, no hardcoded `entrypoints: {}`, builder split by node
  kind — from `references/analyzer-architecture.md`), and that `<Lang>Application` in the schema is
  the output contract.
- **Directory map** — a path → responsibility table for the actual package layout.
- **Commands** — the real build/test/run/typecheck/schema-gen commands (e.g. `bun run build`,
  `bun test`, `bun run gen:schema`; or the Go/Rust/Python equivalents), and the fixture used to
  validate `analysis.json`.
- **Schema + packaging contract** — output must validate against the SDK `<Lang>Application` model
  (point at `.claude/SCHEMA_DECISIONS.md`); the Neo4j schema is versioned and enforced by a
  conformance test — treat it as a contract; and the version-lockstep rule across the manifest,
  `packaging/python/`, the SDK pins, and the brew formula (`references/packaging-and-release.md`).
- **The standard working-style + rules + auxiliary sections** — carry the template's *"I implement
  features myself — you assist"*, the numbered **Rules** (think before coding; simplicity;
  issue → branch → PR; guard the contract), the teaching-loop / spaced-repetition section (which
  defers to `~/.claude/CLAUDE.md`), and the *Auxiliary support tasks* (e.g. tidy up the release
  announcement) over near-verbatim, adjusting repo name, short-name, and the upgrade one-liners
  (`pip install -U codeanalyzer-<lang>`, the brew tap) for this analyzer.
- **Repo rules** — carry over any unbreakable conventions the repo already states (never add
  AI-authorship trailers / `🤖` signoffs to PRs); preserve an existing `CLAUDE.md`'s rules rather
  than dropping them.

Create the symlink as a **relative** link at the repo root so it survives clone/checkout:
```bash
ln -sf CLAUDE.md AGENTS.md
```
Commit both (git stores the symlink). If a `CLAUDE.md` already exists (as a one-line rule file),
**fold its content into the new guide** before adding the symlink — never silently discard it.

### Summarize & hand off to the frontend skill
Report: the build plan, the schema decisions the user made (`SCHEMA_DECISIONS.md`), what runs today
(the cheap level-1 analysis — symbol table + resolver call graph — on the fixture), what's stubbed
(the level-2 framework backend), the **distribution artifacts** (the `codeanalyzer-<lang>` PyPI
package under `packaging/python/`, the `packaging/homebrew/` formula generator + the
`codellm-devkit/homebrew-tap` push, the tag-triggered `release.yml`, and the **published package
name + version**), the analyzer `README.md` and the **`CLAUDE.md` agent guide with its `AGENTS.md`
symlink** (mirroring `codeanalyzer-typescript/CLAUDE.md`), and the diff summary. Confirm
the **modularity** checks from `references/analyzer-architecture.md` actually hold (delegating
`core`, node-kind-split builder, isolated framework subpackage, present-and-wired `analysis/` +
`frameworks/` layer) — report it as a checklist, not an aspiration.

**Hand-off to cldk-sdk-frontend.** This skill ends at a working, released analyzer. To make the
language usable from a CLDK SDK, run the **cldk-sdk-frontend** skill next; it consumes exactly what
you produced here: a sample `analysis.json`, the approved schema contract + `SCHEMA_DECISIONS.md`,
the CLI contract (`--help`), and the published `codeanalyzer-<lang>` package name + version to pin.
State these explicitly in the summary so the frontend skill (or a later session) has its inputs.

> **Never fake verification.** Every stage's verify step must actually run. If a required tool
> is found missing mid-build, stop and instruct the user to install it (exact commands + what
> it's for) and wait — don't scaffold-and-leave-unverified, and don't claim a stage passed
> without running it. Full criteria, fixture design rules, and definitions of done:
> `references/testing-and-validation.md`.

## Guardrails
- **Modularity is a success criterion, not a nicety.** A monolithic analyzer that emits valid
  `analysis.json` has met the schema bar and *failed* the maintainability bar — both are
  required. Mirror `codeanalyzer-python`'s package structure (`references/analyzer-architecture.md`):
  a delegating `core` (never inlined analysis, never a hardcoded `entrypoints: {}`), a cohesive
  symbol-table builder split by node kind (not a flat pile of free functions), the framework
  backend isolated in its own subpackage, and a real pluggable layer — `analysis/` (pass +
  registry) and `frameworks/` (finder base), scaffolded even when the built-in pass list is
  empty. `codeanalyzer-ts` is the anti-example of every one of these; do not reproduce it.
- **The schema contract is the success criterion.** An analyzer that runs but emits
  non-conformant JSON has failed the real job — the SDK can't load it. Mirror the schema
  **comprehensively** (`schema-reference.md`) and prove it by validating output against the
  SDK `<Lang>Application` Pydantic model at every level. A thin schema that "looks right" but
  drops fields is a silent failure.
- **Expand the schema for the language — that's a feature, not a deviation.** Keep the
  invariant spine (root keys, Module→Class/Callable nesting, identity-only edges,
  `signatureOf()`), then add the target language's own node kinds and fields as first-class
  data rather than forcing it into the Java/Python mold. The contract you design here is what the
  frontend skill encodes as SDK models, so record every new kind/field in `SCHEMA_DECISIONS.md`.
  See the expansion rubric in `schema-reference.md`.
- **Don't fake the call graph.** Identity-only edges must reference signatures that actually
  exist in the symbol table, produced by the same `signatureOf()`. Dangling edges are worse
  than no edges.
- **Scope discipline.** This skill builds the *analyzer* and its distribution — nothing in a CLDK
  SDK repo. Wiring the analyzer into the Python/TS/… SDKs is **cldk-sdk-frontend**. Enriching an
  *existing* analyzer with a new contribution point is `codeanalyzer-extension-builder`.
- **No invented tooling.** If a recommended parser/resolver doesn't exist for the language,
  say so and fall back per the menu's reasoning (compiler API → tree-sitter + external
  resolver → CodeQL/Joern), rather than inventing a package name.
- **Path predicates must operate on relative paths.** Any skip predicate (`IsVendored`,
  `IsTestFile`, or a custom equivalent) applied to an absolute file path will silently match
  directory segments from the analyzer's own source tree and discard all files under them.
  Apply every such predicate to the path relative to the project root — never to the absolute
  path. This is an invisible failure: the analyzer compiles cleanly, all tests pass on the
  project, and the symbol table is empty.
- **Every language-specific schema field needs a test that asserts its value.** Pydantic
  validation confirms the JSON is structurally well-formed; it does not confirm that
  language-specific fields are correctly populated. For every field added beyond the
  Java/Python spine, write at least one test asserting a known concrete value. A field with
  no value test is guaranteed to break silently when the builder logic changes.
