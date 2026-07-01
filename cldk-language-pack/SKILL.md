---
name: cldk-language-pack
description: >-
  Scaffold first-class support for a NEW programming language in CodeLLM-DevKit (CLDK),
  end to end: a `codeanalyzer-<lang>` backend analyzer plus Python SDK bindings. Use this
  whenever a CLDK maintainer wants to "add a language", "support <X> in CLDK", "build a
  codeanalyzer for <X>", "write a CLDK language pack/backend/analyzer", or wire a new
  language into the cldk Python SDK — even if they don't say the word "skill". The skill's
  core move is a guided, informed decision about the analyzer's backend tooling (parser,
  resolver, enrichment, packaging) for the target language, then scaffolding the analyzer
  to a working, validated level-1 analysis (symbol table + resolver call graph) and registering
  it in the SDK on a branch. Do NOT use this
  for adding an extension/contribution point to an EXISTING analyzer (that's
  codeanalyzer-extension-builder), or for merely *using* CLDK to analyze code.
---

# CLDK language pack

Add a new language to CLDK across two surfaces in one pass:

1. **Backend analyzer** `codeanalyzer-<lang>` — parses the language and emits the canonical
   `analysis.json` (symbol table + call graph).
2. **Python SDK bindings** — `CLDK(language="<lang>").analysis(...)` returns a facade like
   `JavaAnalysis`/`PythonAnalysis`.

(The TypeScript SDK is intentionally **out of scope** for this skill.)

The skill's defining move is **not** picking a template — it's running a guided, informed
decision about *how to build the backend* for this specific language, then scaffolding from
that decision. A new language's analyzer must live in that language's own ecosystem to reach
its best tooling, so the tooling choices genuinely differ per language and the user owns
them.

## Before you start: orient

- Confirm the **target language** and locate the CLDK reference repos — you anchor the schema
  and construction on the **already-implemented** analyzers. They normally sit as siblings:
  `codeanalyzer-java/`, `codeanalyzer-python/` (analyzer templates), `codeanalyzer-ts/` (a
  **cautionary** reference — see below), and `python-sdk/` (the SDK, which also contains the
  **C** analyzer under `cldk/analysis/c/` — the procedural, non-class anchor). **If any of these
  is not present locally, clone it into `/tmp` and anchor on that copy** (read-only — never push
  to these):
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
  - `references/cli-contract.md` — the CLI flags the SDK facade depends on.
  - `references/python-sdk-wiring.md` — the exact SDK files to create/edit.
  - `references/sdk-testing.md` — **all verification criteria, fixture design rules, and definitions of done** for both surfaces. Read before writing any tests.

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
and deep is opt-in. Record the agreed choices — including the depth — under an
**"Architecture & Tooling"** heading in the analyzer's own `codeanalyzer-<lang>/README.md`. This
is deliberately a public, top-level doc: it documents for human readers *which backend tooling
was chosen and why*, and it doubles as the guide any later session (you included) reads to recover
the locked decisions without re-litigating them. Capture each load-bearing slot (runtime,
structural parser, resolver, optional enrichment, build/dep materialization, packaging, depth,
extra node kinds) and a one-line rationale per non-default choice. Keep the *Schema Design*
`SCHEMA_DECISIONS.md` under the analyzer's `.claude/` folder (create it if needed); only these
tooling decisions are promoted into the README.

**Then check the toolchain is installed, before building anything.** The chosen tooling has hard
prerequisites (Node + the analyzer's deps for ts-morph; the Go toolchain for `go/types`; the
Rust toolchain + rust-analyzer; clang/libclang for C++; plus any framework backend like CodeQL/
Joern if *deep*). Probe for them (e.g. `node --version`, `go version`, `rustc --version`,
`clang --version`). **If anything required is missing, stop and instruct the user to install it**
— give the exact install commands for their platform and what each is for — and **wait** until
they confirm it's available. Do **not** proceed to scaffold-and-leave-unverified: an analyzer you
can't run is an analyzer you can't validate against the schema, which is the whole success
criterion. Only continue once the toolchain is present.

### Schema Design (interactive, node by node)
Design the schema — analyzer-side types **and** the SDK `cldk/models/<lang>/` Pydantic models —
by running the loop in `references/schema-design-loop.md` per node (spine first: `Module` →
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
   (recommended) …*.) Record each answer.
4. **Define & co-evolve** — encode the decisions into the analyzer type and the `<L>` model
   together; snake_case, optional-with-defaults, spine untouched, identity-only edges.

No files are walked yet. Output: a complete, user-approved schema and the `<L>` models.

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

**Symbol-table gate (verify):** Run the analyzer on the fixture and confirm the criteria
in `references/sdk-testing.md §2` (symbol-table gate). Don't proceed until this passes.

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

**Verify:** confirm the criteria in `references/sdk-testing.md §2` (call-graph gate). (`backend-recipe.md` step 6.)

### CLI, caching/incremental, packaging
Add the CLI family surface (`cli-contract.md`) with `analysis.json` as the only facade-visible
output. **Validate all flag values** — unrecognized or unimplemented values (e.g. `--format
msgpack` before msgpack is implemented) must return a non-zero exit with a clear message, never
silently fall back. See `cli-contract.md §Flag validation requirements`.

**Caching has three independent layers — implement and test each explicitly:**

1. **Materialization cache** — memoizes the dependency-fetch step (`go mod download`, `npm ci`,
   venv build) by hashing the manifest (`go.sum`, `package-lock.json`, `requirements.txt`).
   Stored in `cache_dir`. Bypassed by `--eager`.
2. **Per-run output cache** (`analysis_cache.json`) — written to `cache_dir` after every
   successful `Analyze()` call. Always rewritten; gives the SDK something to read without
   re-invoking the binary. `--eager` rewrites it; non-eager runs still write it (it's not
   a skip guard at the binary level).
3. **SDK-level skip** — the Python facade's `_check_existing_analysis()` reads the *output
   dir*'s `analysis.json`, validates it, and **skips invoking the binary entirely** if valid.
   This is where the real "don't re-run the binary" logic lives. The binary itself always
   runs fresh analysis when invoked.

The behavioral tests for caching are in `references/sdk-testing.md §2` (Caching tests).

**For packaging, be opinionated: compile to a self-contained binary** so SDK users need
no language runtime (Go/Rust/C++ native; TS via `bun build --compile`; JVM via GraalVM
`native-image`, not a fat JAR) — the *only* exception is a Python analyzer, shipped as a pip
package and invoked in-process. Version it and pin in the SDK. (`backend-recipe.md` steps 3, 8, 9;
rationale in `tooling-menu.md` § "Packaging".)

### (Optional) Level 2: framework-based analysis
Gated on the depth choice from *Orient & choose the backend tooling*. The heavy tier — a dedicated analysis engine
(CodeQL/Joern/SVF, or WALA-style; `backend-recipe.md` step 7) for points-to/dataflow edges the
cheap resolver can't reach. If the user picked **rapid (default)**, leave it a wired, flag-gated
extension point with a clear TODO. If they picked **deep**, implement it now and merge its edges
into the resolver graph by `(source, target)` with provenance union. (For a language whose call
graph is *only* available this way — e.g. Java/WALA — this stage is where that call graph lives,
regardless of the depth choice.)

### Wire the Python SDK facade (on a branch)
The `<L>` models already exist from *Schema Design*. On a `python-sdk` branch (`add-<lang>-support`),
add the `cldk/analysis/<lang>/` facade (mirror the method surface of `JavaAnalysis`/
`PythonAnalysis`), the `cldk/core.py` dispatch branch, the `pyproject.toml` version pin, and
mocked tests. Copy the **Java** SDK pattern for a subprocess binary or the **Python** pattern
for an in-process pip backend — match your packaging choice from the build plan.
(`references/python-sdk-wiring.md`.) **Verify:** `CLDK(language="<lang>").analysis(project_path=
<fixture>)` yields a non-empty symbol table and a dangling-free call graph; SDK tests pass with
the backend mocked.

### Write the analyzer README (last step)
The analyzer's `codeanalyzer-<lang>/README.md` already holds the **Architecture & Tooling**
decisions recorded back in *Orient & choose the backend tooling*. As the **final build step**,
grow that file into a complete, user-facing README modeled on the reference analyzers'
**`main`-branch** READMEs — `codeanalyzer-python/README.md` (the model to replicate) and
`codeanalyzer-java/README.md`. Don't invent a layout; mirror theirs, in this order:
- **Title + one-line what-it-is** — name the language and the chosen backend tooling (e.g.
  "Static analysis for `<lang>` using `<parser>` + `<resolver>`"), echoing the reference openers.
- **Prerequisites / installation** — the toolchain confirmed installed up front (runtime,
  parser, resolver, plus any framework backend if *deep*), with exact per-platform install
  commands as Python does for `venv`/build tools. Read the minimum version from the **build
  manifest** (`go.mod`'s `go` directive, `Cargo.toml`'s `rust` field, `pyproject.toml`'s
  `requires-python`, etc.) — not from what happens to be installed. Record both the minimum
  and the version the analyzer was actually tested on.
- **Building** — how to produce the self-contained binary chosen in *CLI, caching/incremental,
  packaging* (or the pip install, for a Python analyzer).
- **Usage + CLI options** — paste the real `--help` output (from `cli-contract.md`), then a few
  worked **examples** like the Python README (basic symbol table, `--output`, level-2/framework
  flag).
- **Analysis levels** — what level 1 (symbol table + resolver call graph) emits today and what
  level 2 (framework backend) adds — flagged stubbed-vs-implemented per the depth choice.
- **Output schema** — point at the canonical `analysis.json` / `<Lang>Application` contract.
- **Python SDK (CLDK) integration** — the `CLDK(language="<lang>")` entry from *Wire the Python
  SDK facade*.
- Keep the **Architecture & Tooling** section (the locked decisions) intact as its own heading.

Write only what actually runs — don't document level-2 as working if it's a stubbed extension
point. The README is the human-readable counterpart to the validated `analysis.json`: like every
other stage, it describes the analyzer as it really is.

### Summarize
Report: the build plan, the schema decisions the user made, what runs today (the cheap level-1
analysis — symbol table + resolver call graph — on the fixture), what's stubbed (the level-2
framework backend), the SDK branch name, the analyzer `README.md` written as the last step, and the diff summary.
Confirm the **modularity** checks
from `references/analyzer-architecture.md` actually hold (delegating `core`, node-kind-split
builder, isolated framework subpackage, present-and-wired `analysis/` + `frameworks/` layer) —
report it as a checklist, not an aspiration.

> **Never fake verification.** Every stage's verify step must actually run. If a required tool
> is found missing mid-build, stop and instruct the user to install it (exact commands + what
> it's for) and wait. Full criteria, fixture design rules, and definitions of done:
> `references/sdk-testing.md`.

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
  data rather than forcing it into the Java/Python mold. Co-evolve the analyzer output and the
  `cldk/models/<lang>/` models together so validation still passes (you own both sides). See
  the expansion rubric in `schema-reference.md`.
- **Don't fake the call graph.** Identity-only edges must reference signatures that actually
  exist in the symbol table, produced by the same `signatureOf()`. Dangling edges are worse
  than no edges.
- **Edit `python-sdk` only on a branch**, and confirm the tree is clean before branching.
- **Scope discipline.** This skill adds a *new language*. Enriching an *existing* analyzer
  with a new contribution point is `codeanalyzer-extension-builder`. The TypeScript SDK is
  out of scope here.
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
