# The analysis.json contract the SDK models must satisfy

> **Schema v2 — this file predates it.** The analyzer contract is now the backend skill's v2
> keystone (`codeanalyzer-backend/references/canonical-schema.md`): one additive node-tree + typed
> edges (a CPG), `can://` ids, `application → symbol_table{module} → types/functions → callables →
> body`, split edge lists, `source` per module, `max_level`. Mapping the SDK's Pydantic models to
> v2 while **keeping the same public API** (`CLDK.<lang>(...)`, the same accessors) is a **major SDK
> release** (the backend hand-off's `§ c`) and is the next rebuild of *this* skill. Until that lands,
> read the sections below as the *old* (v1) contract; the authoritative shape is the v2 keystone and
> the analyzer's real sample `analysis.json`.

The analyzer (built by the **codeanalyzer-backend** skill) emits a single `analysis.json`. Your job
in this skill is to encode SDK-side models that **load and validate that JSON**, plus a facade
that queries it. This file states the **invariant contract** the models must satisfy. It is *not*
the exhaustive field catalog — **the authoritative, complete field list is whatever the analyzer's
sample `analysis.json` actually contains** (plus the node kinds recorded in the backend's
`SCHEMA_DECISIONS.md`). Always build and validate the models against a **real sample**, not against
this summary.

> The backend skill owns the full canonical schema (its `canonical-schema.md` + `schema-reference.md`
> + the analyzer's `py_schema.py`). You don't redesign the schema here; you mirror the emitted JSON.

## The invariants (must hold for the models to load)

1. **One root object, two required keys.**
   `Application { symbol_table: Map<path, Module>, call_graph: Edge[] }` plus optional
   `entrypoints`. `symbol_table` is keyed by **file path** (relative to the project root, stable
   across runs); `call_graph` is a flat list of edges. Your `<L>Application` model mirrors this.

2. **Identity-only edges.** A `CallEdge` carries only `source` and `target` — both **signature
   strings** that exactly equal a `Callable.signature` in the symbol table. Rich per-call metadata
   (receiver, arg types, line/column, resolved callee) lives on a `Callsite` inside the **caller's**
   `call_sites`. This is what lets the facade build a NetworkX graph whose nodes are the
   symbol-table callables. *(The Java analyzer is a legacy rich-edge exception — new languages use
   identity-only, so model `<L>CallEdge` with bare-string `source`/`target`.)*

3. **`signature` is the join key.** Edge `source`/`target`, `Callsite.callee_signature`, and the
   `Callable.signature` they point at are all produced by the analyzer's single `signatureOf()`.
   Your facade's derived graphs key on these strings, so a dangling edge (endpoint not in the symbol
   table) is a real bug — the definition of done forbids it.

## JSON conventions

- **snake_case keys** — both Java (Gson `LOWER_CASE_WITH_UNDERSCORES`) and Python (Pydantic) emit
  snake_case; model field names must match the JSON keys exactly so `<L>Application(**json.load(f))`
  validates.
- **`analysis.json` is the only artifact the facade reads** (or compact JSON on stdout when no
  output dir is given).
- **Open-vocabulary fields stay strings/string-maps** — `provenance`, `tags`, `detection_source`
  are not closed enums, so a persisted `analysis.json` loads even without the producing extensions.

## Node field names the models mirror

Canonical (Python) field names — replicate the **same names and nesting**; add the language's own
node kinds (from `SCHEMA_DECISIONS.md`) rather than renaming the shared ones.

- **Module** — `file_path`, `module_name`, `imports[]`, `comments[]`, `classes{sig→Class}`,
  `functions{sig→Callable}`, `variables[]`, `content_hash`, `last_modified`, `file_size`.
- **Class** — `name`, `signature`, `comments[]`, `code`, `decorators[]`, `base_classes[]`
  (signature strings), `methods{sig→Callable}`, `attributes{name→Attr}`, `inner_classes{sig→Class}`,
  `start_line`, `end_line`.
- **Callable** — `name`, `path`, `signature`, `comments[]`, `decorators[]`, `parameters[]`,
  `return_type`, `code`, `start_line`/`end_line`/`code_start_line`, `accessed_symbols[]`,
  **`call_sites[]`**, `inner_callables{}`, `inner_classes{}`, `local_variables[]`,
  `cyclomatic_complexity`, `is_entrypoint`, `entrypoint_framework`.
- **Callsite** (on the caller) — `method_name`, `receiver_expr`, `receiver_type`,
  `argument_types[]`, `return_type`, **`callee_signature`**, `is_constructor_call`, and
  `start_line`/`start_column`/`end_line`/`end_column`.
- **CallEdge** (identity-only) — `source`, `target`, `type` (`"CALL_DEP"`), `weight`,
  `provenance[]`, `tags{}`.
- **Entrypoint** (optional) — `signature`, `framework`, `detection_source`, flat optional
  route/method fields, free-form `tags{}`.

## Language-native kinds

When the analyzer added node kinds for the language (TS `interface`/`type`/`enum`, Go
`struct`/`interface`, Rust `trait`/`impl`/`enum`, etc.), they appear in `analysis.json` and the
backend's `SCHEMA_DECISIONS.md` records each one. Add the matching `<L>` model/field **and** —
usually — a facade accessor for it (decided in the *SDK Facade Design* loop). Pydantic silently
drops unknown JSON keys, so **define every field you intend to read**; for loud failures while
developing, set `model_config = ConfigDict(extra="forbid")`.

## Worked examples to copy

Per language, the SDK defines parallel models under `python-sdk/cldk/models/<lang>/models.py`
(`TSApplication`, `TSModule`, `TSCallable`, `TSCallEdge`, …). Copy `cldk/models/java/models.py`
(subprocess-side schema) for a binary analyzer, or re-export upstream models like
`cldk/models/python/__init__.py` for an in-process Python analyzer — matching the analyzer's
invocation pattern. Mechanics: `python-sdk-wiring.md`.
