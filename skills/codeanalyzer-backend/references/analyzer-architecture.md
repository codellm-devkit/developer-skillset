# Analyzer architecture: build it modular (the package skeleton)

A `codeanalyzer-<lang>` that *runs* but is one flat pile of files has failed a real
requirement. CLDK analyzers are maintained and extended for years; the generated analyzer must
land as a **modular package** that mirrors the structure of the mature reference — not a
monolith you "clean up later." This is a first-class success criterion, alongside schema
conformance.

This reference is built from a side-by-side of the two real analyzers:

- **`codeanalyzer-python` — the model to replicate.** Cohesive, pluggable, separated by concern.
- **`codeanalyzer-ts` — the cautionary counter-example.** It validates and runs, but it was
  generated as a flat, monolithic codebase. **Read it to learn what *not* to ship.** Every
  anti-pattern below is taken from it verbatim.

Anchor on the Python package every time you decide where code goes. When in doubt, open the
sibling file in `codeanalyzer-python/codeanalyzer/` and put the equivalent in the same place.

## The package layout to replicate

`codeanalyzer-python/codeanalyzer/` is organized by concern, one subpackage per phase, plus a
pluggable extension layer. Reproduce this shape in the target language's idiom (a Python
package, a TS `src/` tree, a Go module, Rust crates/modules):

```
codeanalyzer/
  __main__.py            # CLI entry: parse args -> build options -> call core. Thin.
  core.py                # ORCHESTRATOR ONLY. Delegates every phase; inlines no analysis logic.
  options/               # CLI option / AnalysisOptions model
  config/                # static / environment config, distinct from CLI options
  schema/                # the Pydantic (or native) models — the data contract
  syntactic_analysis/    # symbol-table construction (the per-file builder)
  semantic_analysis/     # call-graph construction
    call_graph.py        #   the resolver-based graph + graph<->schema adaptation
    codeql/              #   the heavy framework backend, ISOLATED in its own subpackage
  analysis/              # the PLUGGABLE pass layer (registry + AnalysisPass base)
  frameworks/            # entrypoint-finder base + concrete finders, built ON the pass layer
  utils/                 # logging, progress, fs helpers — no analysis logic
```

Not every language needs every box on day one (the framework backend and pass finders may ship
empty), but the **skeleton and the seams must exist from the start**, because that is what makes
the analyzer extensible without a rewrite.

## The four modularity rules (each with the anti-pattern it prevents)

### 1. The orchestrator delegates; it never inlines analysis logic
`core.py`'s `analyze()` is ~50 lines of pure delegation: build the symbol table → build the base
call graph → cache the *base* application → `run_pipeline(app)` (the pluggable passes) → return
the enriched app. Each phase lives in its own module.

> **Anti-pattern (from `codeanalyzer-ts/src/core.ts`):** a 36-line `analyze()` that inlines the
> whole flow and hardcodes `entrypoints: {}`. There is no seam between "build the base analysis"
> and "enrich it," so framework detection, synthetic edges, or any post-pass enrichment has
> nowhere to plug in.
>
> **Rule:** `core` orchestrates and delegates. The post-symbol-table enrichment goes through a
> single `run_pipeline(app, ctx)`-style call. Never hardcode `entrypoints` — populate them from
> discovered passes.

### 2. The symbol-table builder is a cohesive unit, split by node kind
Python's `syntactic_analysis/symbol_table_builder.py` is large (~968 lines) **but cohesive**: a
single `SymbolTableBuilder` class whose private methods are grouped by node kind and concern —
`_add_class`, `_callables`, `_pydecorators`, `_class_attributes`, `_callable_parameters`,
`_call_sites`, `_module_variables`, `_cyclomatic_complexity`, the `_infer_*` resolver helpers.
Shared resolver/project state lives on `self`; a reader finds "how are classes built?" in one
named place.

> **Anti-pattern (from `codeanalyzer-ts/src/syntactic_analysis/builders.ts`):** ~968 lines of
> **36+ free functions** in a flat namespace, threading state through arguments. `buildClass`,
> `buildInterface`, `buildEnum`, `buildTypeAlias` are scattered across the file; adding a node
> kind means touching 5–6 unrelated spots.
>
> **Rule:** Make the per-file builder a cohesive unit (a class, or a builder module with one
> focused function *per node kind*: `build_class`, `build_callable`, `build_interface`, …). If
> the file grows past a few hundred lines, **split per node kind into sibling modules** under
> `syntactic_analysis/` (e.g. `class_builder`, `callable_builder`) sharing one resolver/context
> object — do not let it stay a flat grab-bag of free functions.

### 3. The heavy framework backend (CodeQL/Joern/WALA/SVF) is isolated in its own subpackage
Python keeps CodeQL behind a clean boundary: `semantic_analysis/codeql/` has *four* files —
`codeql_loader.py` (resolve the binary), `codeql_analysis.py` (build DB + drive), 
`codeql_query_runner.py` (run queries + parse), `codeql_exceptions.py` (typed errors). `core.py`
talks to a `CodeQL` class and never touches the binary, the database, or a query string.

> **Anti-pattern (from `codeanalyzer-ts/src/semantic_analysis/codeql/codeql.ts`):** a single
> 45-line stub. When level 2 is actually implemented it will accrete binary resolution, DB
> management, query execution, and parsing into one file unless the seams are scaffolded now.
>
> **Rule:** Give the framework backend its own subpackage with separate modules for binary
> resolution, DB/driver, query execution, and errors — **even when level 2 ships stubbed.** Scaffold
> the seams so the deep implementation drops into place instead of forcing a refactor.

### 4. Extensibility is a real layer: a pass registry + a finder base
This is the gap that most defines "not modular." Python ships a genuine plugin layer:

- `analysis/_pass.py` — `AnalysisPass` ABC (`run(app, ctx) -> AnalysisResult`), plus
  `AnalysisContext` / `AnalysisResult` / `BindingFact` data types. A pass contributes
  *entrypoints* and/or *synthetic call edges* and declares `provides` / `requires` capability
  tokens.
- `analysis/registry.py` — `discover_passes()` (built-ins **plus** out-of-tree passes registered
  under an entry-point group like `codeanalyzer.analysis_passes`), `order_passes()` (topological
  sort by `requires`/`provides`, hard error on cycle/unsatisfied), `run_pipeline(app)` (build the
  context, run ordered passes, merge each result into the running app before the next pass).
- `frameworks/_base.py` — `AbstractEntrypointFinder`, a thin `AnalysisPass` subclass that
  concrete framework finders (Flask, Django, …) extend.

The base application is cached; **pass output is deliberately not cached** so out-of-tree
enrichment can never go stale.

> **Anti-pattern (from `codeanalyzer-ts`):** *no* `analysis/` package, *no* `frameworks/`
> package, *no* `AnalysisPass`, *no* registry — `grep` finds zero matches. `entrypoints` is
> hardcoded `{}`. The analyzer cannot be extended without editing core.
>
> **Rule:** Scaffold the pass layer up front — `analysis/_pass.<ext>` (the `AnalysisPass`
> abstraction + context/result types), `analysis/registry.<ext>` (discover + topo-order +
> `run_pipeline`), and `frameworks/_base.<ext>` (the entrypoint-finder base). The built-in pass
> list and concrete finders may start empty, but the seam and the entry-point discovery
> mechanism must exist. **This is the part the generated TS analyzer was missing entirely — do
> not skip it.** Note this layer is exactly where `codeanalyzer-extension-builder` plugs in; an
> analyzer without it cannot host extensions.

## How this maps onto the workflow

- The skeleton is scaffolded **once, up front** (an empty-but-wired version of every box above),
  before you fill in phases. The seams come first, not last.
- *Symbol Table Construction* fills `syntactic_analysis/` per rule 2.
- *Call Graph Construction* fills `semantic_analysis/call_graph` (rule 1's base graph).
- *Level 2: framework-based analysis* fills `semantic_analysis/codeql/` (or joern/wala/svf) per
  rule 3 — its subpackage and seams exist even when stubbed.
- The `analysis/` + `frameworks/` pass layer (rule 4) is scaffolded with the skeleton and wired
  into `core` via `run_pipeline`, even if no concrete pass ships in the first run.

## Verify modularity, not just behavior
When you report the build, confirm the skeleton is real — not aspirational:
- `core`'s `analyze()` delegates each phase and routes enrichment through a single
  pipeline/registry call; it inlines no per-node parsing and does not hardcode `entrypoints`.
- the symbol-table builder is a cohesive class/module split by node kind, not a flat function pile.
- the framework backend lives in its own subpackage with separated loader/driver/query/error seams.
- `analysis/` (pass + registry) and `frameworks/` (finder base) exist and `core` calls the
  registry — even if the built-in pass list is empty.

A monolithic analyzer that emits valid `analysis.json` has met the schema bar and **failed the
maintainability bar**. Both are required.
