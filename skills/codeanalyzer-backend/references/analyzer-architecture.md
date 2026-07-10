# Analyzer architecture — the modular package skeleton

A `codeanalyzer-<lang>` that *runs* but is one flat pile of files has failed a real requirement.
CLDK analyzers are maintained and extended for years, so the analyzer must land as a **modular
package** whose seams mirror the pipeline the schema implies: **parser → resolver → per-level
builders → emitters**. Modularity is a first-class success criterion, alongside schema conformance.

Anchor every "where does this code go?" decision on **`codeanalyzer-python`** (the model to
replicate: cohesive, pluggable, separated by concern). **`codeanalyzer-ts`'s original flat build**
is the cautionary counter-example — it validates and runs, yet ships as a monolith; every
anti-pattern below is taken from it.

## The pipeline, and the package that mirrors it

The additive schema (`skills/designing-cldk-changes/references/canonical-schema.md`) is grown by a
straight pipeline. Each stage is a subpackage with a real boundary:

```
codeanalyzer/
  __main__          # CLI entry: parse args -> AnalysisOptions -> call core. Thin. (references/cli-contract.md)
  core              # ORCHESTRATOR ONLY. Delegates every stage; inlines no analysis logic.
  options/ config/  # CLI option model; static/environment config
  schema/           # the node/edge models — the v2 data contract (the keystone)
  materialize/      # PARSER's prerequisite: deps -> classpath/venv/module graph (references/project-materialization.md)
  syntactic_analysis/  # PARSER + L1 builder: the tree to callable depth + `call` nodes
  semantic_analysis/   # RESOLVER + per-level builders
    call_graph        #   L2: resolver-based call_graph + graph<->schema adaptation
    dataflow/         #   L3/L4: cfg/cdg/ddg builders, then the SDG builder (per-callable modules)
    <framework>/      #   optional heavy backend (joern/wala/svf), ISOLATED in its own subpackage
  neo4j/            # EMITTER (co-primary): project() -> GraphRows -> cypher/bolt + schema catalog
  analysis/         # the PLUGGABLE pass layer (registry + AnalysisPass base)
  frameworks/       # entrypoint-finder base + concrete finders, built ON the pass layer
  utils/            # logging, progress, fs helpers — no analysis logic
```

The two **emitters** are co-primary: the JSON serializer of `schema/` and the `neo4j/` projection
subpackage. Neither is optional — the Neo4j graph is a first-class output
(`references/neo4j-projection.md`), so its seam exists in the skeleton from day one.

Not every box is filled on day one (the framework backend and pass finders may ship empty), but the
**skeleton and seams must exist from the start** — that is what makes the analyzer grow through the
levels, and host extensions, without a rewrite. Scaffold the empty-but-wired skeleton **once, up
front**, before filling stages.

## The four modularity rules (each with the anti-pattern it prevents)

### 1. The orchestrator delegates; it never inlines analysis logic
`core`'s `analyze()` is short, pure delegation: materialize deps → build the symbol table (L1) →
build the call graph (L2) → run the dataflow builders (L3/L4, when in scope) → cache the *base*
application → `run_pipeline(app)` (the pluggable passes) → return the enriched app. Each stage lives
in its own module.

> **Anti-pattern (`codeanalyzer-ts/src/core.ts`):** a 36-line `analyze()` that inlines the whole
> flow and hardcodes `entrypoints: {}`. There is no seam between "build the base analysis" and
> "enrich it," so framework detection or any post-pass enrichment has nowhere to plug in.
>
> **Rule:** `core` orchestrates and delegates; enrichment goes through a single `run_pipeline(app,
> ctx)`-style call. Never hardcode `entrypoints` — populate them from discovered passes.

### 2. The per-level builders are cohesive units, split by node kind / stage
The **L1 symbol-table builder** is the largest single piece and exactly where modularity slips.
Python's `SymbolTableBuilder` is ~968 lines **but cohesive**: one class whose private methods are
grouped per node kind — `_add_class`, `_callables`, `_class_attributes`, `_callable_parameters`,
`_pydecorators`, `_call_sites`, `_module_variables`, `_cyclomatic_complexity`, plus the `_infer_*`
resolver helpers — sharing resolver/project state on `self`. A reader finds "how are classes built?"
in one named place. The **L3/L4 dataflow builders** split the same way — one module per stage (CFG,
dominance/CDG, def-use/DDG, SDG), each fanning out per callable.

> **Anti-pattern (`codeanalyzer-ts/src/syntactic_analysis/builders.ts`):** ~968 lines of **36+ free
> functions** in a flat namespace threading state through arguments; `buildClass`/`buildInterface`/
> `buildEnum` scattered across the file, so adding a node kind means touching 5–6 unrelated spots.
>
> **Rule:** each builder is a cohesive unit — a class, or a module with one focused function per node
> kind / stage. If it grows past a few hundred lines, split per node kind into sibling modules under
> the stage's subpackage, sharing one resolver/context object.

### 3. The heavy framework backend is isolated in its own subpackage
Framework enrichment (Joern/WALA/SVF) is the **orthogonal precision axis, not a level** (see the
keystone). Python keeps it behind a clean boundary: `semantic_analysis/<framework>/` has four files —
a loader (resolve the binary), an analysis driver (build/drive the DB), a query runner (run + parse),
and typed errors. `core` talks to one facade class and never touches the binary, DB, or a query
string.

> **Anti-pattern (`codeanalyzer-ts`'s level-2 stub):** a single 45-line stub that, when implemented,
> accretes binary resolution, DB management, query execution, and parsing into one file.
>
> **Rule:** give the framework backend its own subpackage with separate loader/driver/query/error
> modules — **even when it ships stubbed** — so the deep implementation drops in without a refactor.

### 4. Extensibility is a real layer: a pass registry + a finder base
This is the gap that most defines "not modular." Python ships a genuine plugin layer:

- `analysis/_pass` — the `AnalysisPass` ABC (`run(app, ctx) -> AnalysisResult`) plus
  `AnalysisContext`/`AnalysisResult`/`BindingFact`. A pass contributes *entrypoints* and/or
  *synthetic call edges* and declares `provides`/`requires` capability tokens.
- `analysis/registry` — `discover_passes()` (built-ins **plus** out-of-tree passes under an
  entry-point group), `order_passes()` (topological sort by `requires`/`provides`, hard error on
  cycle/unsatisfied), `run_pipeline(app)` (build context, run ordered passes, merge each result into
  the running app before the next).
- `frameworks/_base` — `AbstractEntrypointFinder`, a thin `AnalysisPass` subclass concrete finders
  (Flask, Django, …) extend.

The base application is cached; **pass output is deliberately not cached**, so out-of-tree enrichment
never goes stale.

> **Anti-pattern (`codeanalyzer-ts`):** *no* `analysis/`, *no* `frameworks/`, *no* `AnalysisPass`,
> *no* registry — `grep` finds zero matches; `entrypoints` is hardcoded `{}`. The analyzer cannot be
> extended without editing core.
>
> **Rule:** scaffold the pass layer up front (the ABC + context/result types, the discover/topo-order/
> `run_pipeline` registry, and the finder base). The built-in list may start empty, but the seam and
> the discovery mechanism must exist — this is the layer the extension skill plugs into.

## Verify modularity, not just behavior

When you report the build, confirm the skeleton is real, not aspirational:

- `core`'s `analyze()` delegates each stage through a single pipeline/registry call; it inlines no
  per-node parsing and does not hardcode `entrypoints`.
- each per-level builder is a cohesive class/module split by node kind or stage, not a flat function
  pile.
- the framework backend lives in its own subpackage with separated loader/driver/query/error seams.
- `analysis/` and `frameworks/` exist and `core` calls the registry — even if the built-in pass list
  is empty.
- both emitters exist: JSON via `schema/`, Neo4j via `neo4j/` behind a pure `project()`.

A monolithic analyzer that emits valid `analysis.json` has met the schema bar and **failed the
maintainability bar**. Both are required.
