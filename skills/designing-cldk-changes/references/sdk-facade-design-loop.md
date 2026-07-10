# The SDK facade design loop (comparison-and-differentiation)

This is the **SDK-side** design loop of `designing-cldk-changes` — invoked when the
Contract-Impact Triage says a change touches the SDK facade *surface* (a new language's facade, a
new query, a changed accessor). It designs the surface; it does **not** implement it. Creating the
facade files, the dispatch branch, the version pins, and the tests is the **encoding** step, and
it belongs to the `cldk-sdk-frontend` rung — entered only after the spec + epic gate is satisfied
(mechanics: `skills/cldk-sdk-frontend/references/python-sdk-wiring.md` and
`skills/cldk-sdk-frontend/references/typescript-sdk-wiring.md`).

Designing the facade is **not** "copy `JavaAnalysis`, fill in the methods." It is the same
iterative, reflective process as the analyzer-side schema loop (`references/schema-design-loop.md`):
you anchor on the **mature reference facades** (currently **Java**, **Python**, and **C**),
interrogate how the target language's *query surface* genuinely differs, and — crucially — **bring
every divergence to the user as a decision** rather than choosing silently. Do it **slot by slot**,
not all at once.

One facade vocabulary feeds **two encodings** of the same query surface — the Python SDK
`cldk/analysis/<lang>/<Lang>Analysis` and the TypeScript SDK `src/analysis/<lang>/<Lang>Analysis` —
exactly as one schema feeds every analyzer. So **design the surface once, here, with the user**;
the two facades then mirror each other method-for-method. Deciding the vocabulary once is what
keeps them in lockstep.

## The golden rule: surface divergences, don't resolve them yourself

The agent does **not** get to quietly pick the facade shape when the references disagree or when
the target language introduces something new. Each such point is the user's call. Show how each
reference facade handled it, explain the tradeoffs, recommend a default, and **ask**
(`AskUserQuestion`). This is what keeps the API faithful to how *this* team wants developers to
query *their* language.

## What is invariant vs what is a decision

Like the schema's spine, **Tier A is invariant — reproduce it verbatim, don't re-litigate it.**
Every facade, in every language, exposes the same lifecycle / whole-program vocabulary, because
callers duck-type across the union return of `CLDK.analysis()` and nothing enforces it but
convention:

> `get_application_view`, `get_symbol_table`, `get_call_graph` (→ `nx.DiGraph`),
> `get_call_graph_json`, `get_callers`, `get_callees`, `get_class_call_graph`,
> `get_class_hierarchy`.

Don't ask the user whether to implement these — they are the floor (the SDK is unusable without
them). The **decisions** are everything *below* Tier A: the leaf-accessor names, the
class-centric-vs-procedural shape, the constructor extras and guards, and which optional tiers to
populate. Those are where the references genuinely diverge and where the language's reality has to
be modeled — so those are what you take to the user.

## The loop (per facade slot)

### 1. Anchor
Open the *same* slot in **every** mature reference facade and read them side by side (paths are
relative to the located reference repos — a local sibling checkout, else a `/tmp` clone):
- Java: `python-sdk/cldk/analysis/java/java_analysis.py`
- Python: `python-sdk/cldk/analysis/python/python_analysis.py`
- C (procedural, non-class anchor): `python-sdk/cldk/analysis/c/c_analysis.py` — **read this
  whenever the target language is not class-centric.** C drops `get_classes`/`get_methods`
  entirely and instead exposes `get_functions`/`get_function`/`get_functions_in_file` plus
  `get_macros`/`get_macros_in_file`; its constructor is just `project_dir`; its
  `get_callers`/`get_callees` take a `CFunction`, not class+method name strings. It is the proof
  that the surface below Tier A is genuinely language-shaped, not boilerplate.

Catalog two things: (a) the **shared Tier-A vocabulary** — reproduce as-is; and (b) **every place
the references disagree** — each disagreement is a divergence point for the user.

### 2. Differentiate
Ask the surface question: **"How is the `<lang>` query surface genuinely different here?"** —
about language constructs developers will query, not application domain. Each new construct the
language introduces is *also* a decision point even if no reference has it (Go has no classes but
has interfaces + structs + receiver methods; Rust has traits + impls + enums-with-data; TS has
namespaces + type aliases).

### 3. Decide each open point **with the user** (the interactive step)
For every divergence and every new construct, present it and **ask** (`AskUserQuestion`). Don't
batch a whole facade into one vague question; ask per real decision, with a recommended default
first, anchored in what the references did. The load-bearing slots:

- **Facade shape — class-centric or procedural?** *Java/Python* expose `get_classes` / `get_class`
  / `get_methods` / `get_method`; *C* drops all of those and exposes `get_functions` /
  `get_function` / `get_functions_in_file`. For a language with no classes, which surface — and
  what are the top-level callable accessors named?
- **Per-file unit accessor + type.** *Java* uses `get_java_file` / `get_java_compilation_unit`
  (→ `JCompilationUnit`); *Python* uses `get_python_file` / `get_python_module` (→ `PyModule`);
  *C* uses translation units (`CTranslationUnit`). What is the new language's per-file unit called
  — `get_<lang>_file` / `get_<lang>_<unit>` — and what model type does it return?
- **Decoration accessor.** *Java* has `get_methods_with_annotations`; *Python* has
  `get_methods_with_decorators`. Name this for the language's decoration concept (drop it if the
  language has none).
- **Native-kind accessors.** For each language node kind added in the schema loop (interfaces,
  enums, structs, traits, namespaces), is there a matching accessor (`get_interfaces`,
  `get_structs`, `get_macros`-style) — and what is it named? Anchor on `get_implemented_interfaces`
  (Java/Python) and C's `get_macros`/`get_macros_in_file` as precedent.
- **`get_callers`/`get_callees` signature.** *Java/Python* take class + method-declaration
  strings; *C* takes a `CFunction` object. Which addressing model fits the language's callable
  identity?
- **Backend config + guards.** The facade constructor carries only the common params
  (`project_dir`, `analysis_level`, `target_files`, `eager_analysis`, `backend`); backend-only
  knobs live on the `backend=` config object (`CodeAnalyzerConfig` and language subclasses like
  *Python*'s `PyCodeAnalyzerConfig(use_ray)`, *TS*'s `TSCodeAnalyzerConfig(tsc_only)`), with an
  optional `Neo4jConnectionConfig` arm. Which config subclass (if any) does this language need,
  and which guards does the `CLDK.<lang>()` factory apply (e.g. `project_path` optional only for
  the Neo4j backend)? Note the older `analysis_backend_path` / `analysis_json_path` params are gone
  — the binary ships with the packaged dependency and output caching is `cache_dir`.
- **Tier C — tree-sitter.** Ship a grammar so `is_parsable` / `get_raw_ast` work, or omit Tier C?
  (Default omit unless you already ship a `Treesitter<Lang>` parser.)
- **Tier D — framework / semantic views.** Entrypoints, CRUD, `get_test_methods`, comments. These
  exist **only if the analyzer populates them** — surface which the analyzer produces today and
  implement only those; the rest are progressive, added when the data exists.

Use the same question shape as the schema loop — *"Java did X, Python did Y, C did Z; for
`<lang>`, how do you want it?"* with explained options and a recommended default. Record each
answer (a one-line note per decision) in `.claude/FACADE_DECISIONS.md` in the SDK repo (under
`.claude/`, not the repo root), the same treatment `SCHEMA_DECISIONS.md` gets for the schema.

### 4. Define & co-evolve
The decisions here are encoded into **both** SDK facades in the same change — the Python
`<Lang>Analysis` and the TypeScript `<Lang>Analysis` — so they never drift. Reproduce Tier A
verbatim in both; name the leaf accessors exactly as decided; keep the constructor params and
guards identical in spirit (Python `snake_case`, TS `camelCase`). The facade stays a thin,
read-only, lazily-evaluated query layer over the canonical v2 `Application` node-tree — surfaced
through the per-language **views** (`skills/cldk-sdk-frontend/references/schema-contract.md`
§ "The two-layer model") so the accessor return types keep their old names. The *how* of encoding
is the `cldk-sdk-frontend` rung; this loop only fixes *what* the surface is.

## Keep this distinct from the schema axis
The schema loop (`references/schema-design-loop.md`) decided what data the analyzer **emits**; this
loop decides how the SDK **exposes** it to a developer. They co-evolve (a new `<L>` node kind
usually earns a new accessor) but they are different decisions: a node can exist in the schema
without a dedicated accessor, and an accessor can be a derived view (`get_call_graph`,
`get_class_hierarchy`) over data that is just edges / type-containment in the schema. Don't let
facade-naming questions reshape the schema, or vice versa.

## Why anchor on *multiple* references
Java alone biases you toward a class-centric, annotation-based, name-addressed world. Python shows
structured decorators and module-level functions; **C shows a facade with no classes at all** —
functions and macros addressed by a different vocabulary. Reading all three keeps you from
mistaking *Java's* surface for *the* surface, especially for a procedural target language.

## Output of this loop
A complete, user-approved facade vocabulary for the language — the method list, names, and
constructor contract — with every divergence decided and noted in `.claude/FACADE_DECISIONS.md`.
This is a *design artifact*: it feeds the spec and the epic's SDK-facade child issue. No facade
files are written yet — that is the `cldk-sdk-frontend` rung, entered only after the gate.
