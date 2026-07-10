---
name: cldk-sdk-frontend
description: >-
  Wire an existing `codeanalyzer-<lang>` backend analyzer into a CodeLLM-DevKit (CLDK) FRONTEND
  SDK so a developer can call it — `CLDK.<lang>(project_path=..., backend=...)` in the Python SDK
  today (with the legacy `CLDK(language="<lang>").analysis(...)` retained as a compat shim),
  and the TypeScript / Rust / Go / Java SDKs as they come online. Use this whenever a CLDK
  maintainer wants to "add <lang> to the cldk SDK", "wire the analyzer into python-sdk", "register
  a language in CLDK", "build the SDK facade/bindings for <lang>", or "expose <lang> analysis
  through CLDK" — even if they don't say the word "skill". The core move is a guided, interactive
  design of the SDK facade's query surface (anchored on the Java + Python + C facades, every
  divergence decided WITH the user), then encoding that one approved surface into the target
  SDK(s): the `<L>` models that validate against the analyzer's `analysis.json`, the facade class,
  the dispatch branch, and the version pin — each on a branch. PRECONDITION: a working,
  schema-conformant `codeanalyzer-<lang>` already exists (built by the **codeanalyzer-backend**
  skill). Do NOT use this to BUILD the analyzer itself (that's codeanalyzer-backend), to add a
  contribution point to an existing analyzer (codeanalyzer-extension-builder), or to merely *use*
  CLDK.
---

# CLDK SDK frontend

Bind a `codeanalyzer-<lang>` analyzer into a CLDK **frontend SDK** so the language is reachable
through the user-facing API. Today that means the **Python SDK** (`python-sdk`,
`CLDK.<lang>(project_path=..., backend=...)`, with the legacy `CLDK(language="<lang>")
.analysis(...)` as a compat shim); the **TypeScript SDK** (`typescript-sdk` =
`@codellm-devkit/cldk`, `CLDK.for("<lang>").analysis({ projectPath })`) is wired the same way, and
Rust/Go/Java SDKs will follow as they exist. This skill owns **one surface** — the SDK bindings.
Building the analyzer and its `analysis.json` contract is the separate **codeanalyzer-backend**
skill, whose output this skill consumes.

**The analyzer now emits schema v2** (`codeanalyzer-backend/references/canonical-schema.md`): one
additive node-tree + typed edges (a CPG), not the old per-language flat schema. So this skill has
**two contexts**, and both are governed by one rule — **the public API does not move**:

- **Add a new language** to the SDK — encode the v2 surface for it.
- **Migrate an existing language's SDK to v2** — a **major SDK release** that remaps the model layer
  to the shared CPG model while keeping every accessor's name and return type identical.

The device that makes API-stability possible is the **two-layer model** (`schema-contract.md`):
model the v2 tree **once** (`cldk/models/cpg/`: `Application`/`Module`/`Node`/`Edge`), and
re-express the old `<L>Callable`/`<L>Class`/`<L>Module` return types as thin **views** exported
under the same names. The facade and backend ABC keep their exact surface; only each method's
*body* changes from "index the flat tree" to "walk/slice the v2 tree."

The Python SDK now selects behavior along **two orthogonal axes**: the **language** (which
`CLDK.<lang>()` factory method) and the **backend** (the *type* of the `backend=` config object —
a local `CodeAnalyzerConfig` that runs the packaged binary, or a `Neo4jConnectionConfig` that
reads a graph populated out of band). Both backends sit behind a per-language backend ABC
(`<Lang>AnalysisBackend`), so wiring a language means a facade **plus** a backend contract, not
just a wrapper.

The skill's defining move is **not** filling in files — it's running a guided, interactive design
of the facade's *query surface* (the SDK-side mirror of the backend's schema design), then encoding
that one approved surface into each target SDK. One facade vocabulary feeds every SDK encoding, so
the SDKs stay in lockstep.

## Client analyses (slicing, taint) are the SDK's job, not the analyzer's

The `codeanalyzer-<lang>` backend is a **pure graph provider**: at `-a 3`/`-a 4` it emits the
dependence-graph substrate — the CPG's intra-callable `cfg`/`cdg`/`ddg`/`summary` edges plus the
cross-callable `param_in`/`param_out` (the SDG), with transitive `SUMMARY` edges — and nothing
more. It deliberately does **not** emit a `taint_flows` section or run a slice
(`codeanalyzer-backend`'s `references/level-4-interprocedural-sdg.md § Provider/client boundary`). **Slicing, taint, and
reachability queries live here, in the SDK**, as part of the facade's query surface:

- **Backward/forward slice** and **taint** are reachability walks over the emitted graph —
  `cdg ∪ ddg ∪ param_in ∪ param_out ∪ summary` — computed in-SDK. The `SUMMARY` edges the analyzer
  ships are what make these **context-sensitive** (the two-phase HRB up-then-down traversal)
  without the SDK re-descending into callees.
- **Sources/sinks/sanitizers/library models are data, not code** — a JSON spec validated against a
  JSON Schema, precedence *built-in pack < config file < caller-supplied* — and they live with the
  SDK because they're a *policy* that changes far faster than the graph. This is why they aren't in
  the analyzer: a policy edit re-runs a cheap in-SDK traversal instead of forcing a graph re-emit.
- The **`TaintFlow` / slice-result models** (`{ source, sink, rule, sanitized, path }`, paths as
  `can://…@line:col` node-id lists with model ids) are SDK models — the shared CPG graph models
  (`cldk/models/cpg/`: `Node`/`Edge`, and the SDG edge shapes) come from the backend contract; the
  client-result models are added here.
- Surface these as facade methods in the query-surface design loop (e.g. `get_backward_slice(...)`,
  `get_taint_flows(spec=...)`), and gate them with the **Slice** and **Taint** frontend gates from
  `sdk-testing.md § 3b` (exact expected node set for a slice; one source→sink flow found and the
  same flow reported `sanitized` with a sanitizer interposed) over the analyzer's fixture graph.

Over-approximations inherited from the graph (e.g. ENTRY-anchored `param_in` collapsing argument
arity, missing `summary` edges before that analyzer PR lands, heap flows only under the analyzer's
heap-dependence mode) must be **surfaced in the SDK's results**, not silently absorbed.

## Precondition & inputs (what the backend skill hands you)

Do not start until a **working, schema-conformant `codeanalyzer-<lang>`** exists. You need, from the
**codeanalyzer-backend** skill's hand-off (or recover them yourself):
- a **sample `analysis.json`** emitted on a small fixture — the validation target for the SDK models;
- the **approved schema contract** + `.claude/SCHEMA_DECISIONS.md` (the node kinds/fields the
  language added) — see `references/schema-contract.md` for the invariants the SDK models must hold;
- the **CLI contract** — the analyzer's `--help` / documented flags the facade shells out with;
- the **published package name + version** — `codeanalyzer-<lang>==X` to pin (Python SDK depends on
  the PyPI wheel; the TS SDK pins the matching GitHub Release tag).

If any input is missing, get it from the analyzer (run it on a fixture, read its README's
*Architecture & Tooling* section) before designing the facade.

## Before you start: orient

- Locate the CLDK reference repos (read-only; prefer a local sibling checkout, else clone into
  `/tmp` from `https://github.com/codellm-devkit/<repo>.git`):
  - `python-sdk/` — the SDK you wire today; the facades you anchor on live at
    `cldk/analysis/{java,python,c}/` and the model trees at `cldk/models/{java,python,c}/`.
  - `typescript-sdk/` (`@codellm-devkit/cldk`, Bun-built) — the second binding target, when you
    wire TS; anchor on `src/analysis/java/` + `src/models/java/`.
  The analyzer repo (`codeanalyzer-<lang>`) only needs to be runnable enough to emit a sample
  `analysis.json`; you are not modifying it here.
- Read these reference files now:
  - `references/schema-contract.md` — the **v2** contract the SDK models satisfy: the envelope root,
    the `application → symbol_table{module} → types/functions → callable → body` tree, one shared
    `Application`/`Module`/`Node`/`Edge` (not per-language `<L>` trees), id join keys, source-slice
    text, and the **two-layer model** that keeps the public API identical. **Read first** — the full
    field catalog is whatever the sample v2 `analysis.json` contains.
  - `references/sdk-facade-design-loop.md` — **the method** for *SDK Facade Design*: design the
    facade's query surface slot by slot by anchoring on the Java + Python + C facades and
    **bringing every divergence to the user as a decision**. Read before touching any SDK.
  - `references/python-sdk-wiring.md` — the exact Python SDK files to create/edit (the *encoding*
    of the approved facade surface in `python-sdk`): backend config, the `<Lang>AnalysisBackend`
    ABC + local backend, the `CLDK.<lang>()` factory method, models, and tests.
  - `references/neo4j-backend.md` — the **optional second backend**: `<Lang>Neo4jBackend`, which
    reconstructs the canonical model from a graph (`--emit neo4j`) for local/Neo4j parity. Read
    only if the analyzer emits a graph.
  - `references/typescript-sdk-wiring.md` — the exact TypeScript SDK files to create/edit; the
    subprocess-only binding surface (the second *encoding*).

## Workflow

Design the surface once, then encode it into each target SDK. Validate every SDK against the sample
`analysis.json` before moving on.

### SDK Facade Design (interactive, slot by slot)
**Don't jump straight to filling files.** The facade's query surface gets the **same level of
questioning and design the analyzer schema did** — it's the SDK-side mirror of the backend's
schema-design loop. Run the loop in `references/sdk-facade-design-loop.md` per slot: **anchor** on
the Java + Python + C facades side by side (`cldk/analysis/{java,python,c}/`), **differentiate**
("how is the `<lang>` query surface genuinely different?"), and **decide each open point WITH the
user** (`AskUserQuestion`) — never silently.

Tier A (lifecycle/whole-program: `get_application_view`, `get_symbol_table`, `get_call_graph` →
`nx.DiGraph`, `get_call_graph_json`, `get_callers`, `get_callees`, `get_class_call_graph`,
`get_class_hierarchy`) is the **invariant floor** — reproduce it verbatim, don't ask about it. The
*decisions* are everything below it:
- the **class-centric-vs-procedural shape** (C drops `get_classes` and exposes
  `get_functions`/`get_macros` — use it as the non-class anchor);
- the **per-file unit accessor name + type** (`get_<lang>_file` / `get_<lang>_<unit>`, mirroring
  `get_java_compilation_unit` vs `get_python_module`);
- the **decoration accessor** (`get_methods_with_annotations` vs `get_methods_with_decorators`);
- **native-kind accessors** for the schema kinds the analyzer added (from `SCHEMA_DECISIONS.md`);
- the **`get_callers`/`get_callees` addressing model** (name strings vs object);
- the **backend config + knobs** (which `<Lang>CodeAnalyzerConfig` subclass, if any — Python's
  `use_ray`, TS's `tsc_only`; whether a `Neo4jConnectionConfig` arm exists) — backend-only knobs
  live on the config object now, not on the facade constructor, which carries only `project_dir`
  / `analysis_level` / `target_files` / `eager_analysis` / `backend`;
- which optional **Tier C** (tree-sitter) and **Tier D** (framework/semantic views) methods the
  analyzer **actually populates** — implement only those; the rest are progressive;
- whether to ship the **Neo4j backend** (only if the analyzer emits a graph) and, if so, the
  **bulk accessors** (`get_callables_overview`, `get_method_bodies`, …) worth adding to the ABC.

One facade vocabulary feeds **every** SDK encoding, so decide it once here. Record each answer in
`.claude/FACADE_DECISIONS.md` (the SDK-side counterpart to the backend's `SCHEMA_DECISIONS.md`).

### Encode into the target SDK(s) — each on its own branch
Encode the approved surface into each SDK, each on an `add-<lang>-support` branch in its own repo;
confirm the tree is clean before branching. Validate against the sample `analysis.json` before
finishing. Do the surfaces back to back when more than one is in scope (order doesn't matter).

**Python SDK** (`python-sdk`, branch `add-<lang>-support`) — `references/python-sdk-wiring.md`.
Create the `cldk/models/<lang>/` Pydantic models that **validate against the sample
`analysis.json`** (built from the contract + `SCHEMA_DECISIONS.md`); add the backend config +
discriminated union + cache key in `backend_config.py`; the `cldk/analysis/<lang>/` facade
(mirror the method surface decided above) backed by a **`<Lang>AnalysisBackend` ABC** with a local
`<Lang>Codeanalyzer` implementation (resolving the binary from the packaged `codeanalyzer-<lang>`
wheel / `$CODEANALYZER_<LANG>_BIN` / `shutil.which`, or importing the package in-process for a
Python analyzer) and — if the analyzer emits a graph — a `<Lang>Neo4jBackend`
(`references/neo4j-backend.md`); the `CLDK.<lang>()` factory method in `cldk/core.py` (plus the
legacy `.analysis()` shim route); the `pyproject.toml` dependency + `[tool.backend-versions]` pin
(`codeanalyzer-<lang>==X`, from the backend hand-off; keep `neo4j` an optional extra); and mocked
+ E2E + backend-contract tests. **Verify:** `CLDK.<lang>(project_path=<fixture>)` yields a
non-empty symbol table and a dangling-free call graph; SDK tests pass with the backend mocked.

**TypeScript SDK** (`typescript-sdk` = `@codellm-devkit/cldk`, branch `add-<lang>-support`) —
`references/typescript-sdk-wiring.md`. Add the `src/models/<lang>/` types (mirror
`src/models/java/`'s `schema.ts`/`types.ts`/`enums.ts` split) encoding the **same approved
schema**, the `src/analysis/<lang>/` facade that resolves the binary from the analyzer's **GitHub
Release asset** at the pinned tag (the TS SDK can't consume the PyPI wheel), the `src/CLDK.ts`
dispatch branch (widen the return type to the union), the `package.json` version/tag pin (+ `files`
entry if you vendor the binary), and `bun test` mocked tests. The TS SDK is **subprocess-only** —
there is no in-process pattern, so even a Python analyzer is reached via its CLI binary, always
copying the **Java** facade. **Verify:** `CLDK.for("<lang>").analysis({ projectPath: <fixture> })`
yields a non-empty symbol table and a dangling-free call graph; `bun test` passes with the backend
mocked.

*(Rust/Go/Java SDKs, when they exist, follow the same two moves: encode the approved facade surface
+ the `<L>` models that validate against `analysis.json`, on a branch, with the analyzer-version pin
kept in lockstep.)*

### Update the SDK agent guide (CLAUDE.md) — update, don't create
Each SDK repo **already ships a `CLAUDE.md`** (e.g. `python-sdk/CLAUDE.md`) — the maintainer's
standing agent guide with personal working-style rules and auxiliary tasks. **Do not create a new
one and do not overwrite it.** On the `add-<lang>-support` branch, edit the existing file in place
to reflect the newly-wired language, surgically:
- Add `<lang>` wherever the guide enumerates **supported languages / backends / entry points** (the
  `CLDK.<lang>()` factory, the local + Neo4j backends) or keeps a **directory map / prior-art
  pointers** — extend those lists; don't restructure the doc.
- If the guide has **no** language-specific section to extend (as `python-sdk/CLAUDE.md` currently
  doesn't), add a single concise line noting `<lang>` is now wired (facade + backend ABC + models,
  pinned to `codeanalyzer-<lang>==X`) rather than a wholesale rewrite.
- **Preserve every existing section verbatim** — the *"I implement features myself"* stance, the
  numbered Rules, the teaching loop, and the *Auxiliary support tasks*. Never drop or reword them.
- Match the repo's symlink convention. `python-sdk` ships `CLAUDE.md` with `AGENTS.md` and
  `GEMINI.md` as relative symlinks, un-ignored via a local `.gitignore` negation (`!AGENTS.md`,
  since the global `~/.gitignore_global` excludes `AGENTS.md`). If a repo has the guide but not
  the symlinks/negation, adding them is fine; if it deliberately has neither, don't force them.
  When symlinks are present, keep the `.gitignore` negation so the globally-ignored `AGENTS.md`
  stays tracked (verify `git ls-files AGENTS.md`; `git add -f` as a fallback).

### Summarize
Report: the facade decisions the user made (`FACADE_DECISIONS.md`), which SDK(s) were wired and on
what branch (`add-<lang>-support` per repo), the analyzer-version pin used (kept in lockstep with
the backend's published `codeanalyzer-<lang>` release across every SDK touched), the verify results
(`get_symbol_table()` non-empty, `get_call_graph()` dangling-free, tests green with the backend
mocked), the **in-place `CLAUDE.md` update** (the language added to the existing guide, personal
rules preserved), and the diff summary per repo.

> **Never fake verification.** Each SDK's verify step must actually run against the sample
> `analysis.json` with the backend mocked. If the models don't validate the sample, fix the models
> (or surface a schema gap back to the analyzer) — don't claim a surface passed without running it.

## Guardrails
- **Precondition is real.** This skill binds an *existing* analyzer. If `codeanalyzer-<lang>` isn't
  emitting conformant `analysis.json` yet, stop and run **codeanalyzer-backend** first — you can't
  validate SDK models against output that doesn't exist.
- **Design the surface once; encode it everywhere.** The **facade** classes still share no base —
  `JavaAnalysis`/`PythonAnalysis`/`TypeScriptAnalysis`/`CAnalysis` mirror each other by convention
  and callers duck-type, so reproduce Tier A verbatim and name the leaf accessors exactly as
  decided, identically across every SDK. The **backend** layer, however, now *does* have a
  per-language ABC (`<Lang>AnalysisBackend`) that both the local and Neo4j backends implement — a
  `test_<lang>_backend_contract.py` enforces it. Design the facade vocabulary once; declare it on
  the backend ABC so both backends stay in lockstep.
- **Model once; validate against a real v2 sample.** Build the shared `cldk/models/cpg/`
  `Application`/`Node`/`Edge` against the actual v2 `analysis.json` (Pydantic drops unknown keys —
  define every field you read; add language kinds as additive optional `Node` fields). Validation
  against the **envelope** `AnalysisPayload` (whose `.application` is the tree) is the definition of
  done, not "looks right".
- **Preserve the public API — the migration's headline guarantee.** Every accessor keeps its name
  and return type; the `<L>Callable`/`<L>Class`/`<L>Module` return types are the shared **views**.
  A `test_<lang>_public_api.py` asserting the surface is unchanged is part of done.
- **Don't fake the call graph.** The derived `get_call_graph()` view must have no dangling nodes —
  every edge endpoint is a real node **id** in the tree (`signature` is a node attribute; the nx
  node key is now the `can://` id — a deliberate, documented change).
- **Branch + lockstep.** Edit each SDK repo only on an `add-<lang>-support` branch; keep the
  analyzer-version pin identical across every SDK and equal to the backend's published release.
- **Scope discipline.** This skill touches SDK repos only. Building or releasing the analyzer is
  **codeanalyzer-backend**; enriching an existing analyzer with a contribution point is
  `codeanalyzer-extension-builder`.
