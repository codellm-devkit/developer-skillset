# The canonical CLDK analysis contract

Every CLDK analyzer — Java, Python, and any new language — emits the **same shape** of
JSON so the SDK facades can parse them interchangeably. A new analyzer that drifts from
this contract is the single most common way a language pack fails: the analyzer "works"
in isolation but the Python SDK can't load it. Treat this file as the spec the generated
analyzer's output must satisfy, and as the source of truth for the Pydantic models you
add to the SDK.

This file states the *rules*. For the exhaustive, field-by-field spec derived from the SDK
Pydantic models — the thing the generated analyzer must mirror comprehensively — see
`schema-reference.md`. The authoritative model code is
`codeanalyzer-python/codeanalyzer/schema/py_schema.py` (identity-only, recommended) and
`python-sdk/cldk/models/java/models.py` (legacy, rich-edge).

## The three invariants

1. **One root object, two required keys.** Output is
   `Application { symbol_table: Map<path, Module>, call_graph: Edge[] }`
   plus optional `entrypoints`. `symbol_table` is keyed by **file path** (relative to the
   project root, stable across runs). `call_graph` is a flat list of edges.

2. **Identity-only edges** (for new analyzers). A call-graph edge carries only `source` and
   `target` — both **signature strings** that must exactly equal a `Callable.signature`
   already in the symbol table. The rich per-call metadata (receiver expression, argument
   types, line/column, resolved callee) lives on a `Callsite` inside the **caller's**
   `call_sites`. This separation is what lets the SDK build a NetworkX graph whose nodes are
   the symbol-table callables. If `source`/`target` don't byte-match a real signature, the
   graph has dangling nodes.
   *Caveat:* the **Java** analyzer is a legacy exception — its `JGraphEdges` embed rich
   `JMethodDetail` objects instead of bare strings. Do **not** copy that for a new language;
   follow the Python identity-only model (your recipe's step 2 mandates it). See
   `schema-reference.md` § "The one design choice".

3. **`signatureOf()` is the linchpin.** Define exactly **one** canonicalizer in the
   analyzer that turns a declaration into its signature string, and use it everywhere a
   signature is produced — when naming a `Callable`, when writing `callee_signature` on a
   `Callsite`, and when emitting edge `source`/`target`. Caller-side and callee-side ids
   must be produced by the same function so they are identical. Constructors normalize to a
   single convention (Python uses `ClassName.__init__`; pick the target language's
   equivalent and apply it consistently). When in doubt, prefer a fully-qualified,
   human-readable string like `module.Class.method` over an opaque hash — downstream LLM
   consumers read these.

## JSON conventions (non-negotiable for SDK compatibility)

- **snake_case keys.** Java emits via Gson with
  `LOWER_CASE_WITH_UNDERSCORES`; Python via Pydantic's snake_case defaults. A new analyzer
  in any host language must serialize keys in snake_case so the shared SDK models parse it.
- **`analysis.json` is the only facade-visible artifact.** Whatever the analyzer does
  internally (caches, intermediate DBs), the contract the SDK depends on is a single
  `analysis.json` (or compact JSON on stdout when no output dir is given).
- **Round-trip safety.** Open-vocabulary fields (`provenance`, `tags`, `detection_source`)
  are plain strings/string-maps so a persisted `analysis.json` loads even if the producing
  extensions aren't installed. Don't model them as closed enums.

## Core node types

These are the canonical Python field names. For a new language, replicate the **same field
names and nesting**; add language-specific node kinds rather than renaming the shared ones.

### Module (a compilation unit / file)
`file_path`, `module_name`, `imports[]`, `comments[]`, `classes{sig→Class}`,
`functions{sig→Callable}`, `variables[]`, plus caching metadata `content_hash`,
`last_modified`, `file_size`.

### Class
`name`, `signature` (e.g. `module.ClassName`), `comments[]`, `code`, `decorators[]`,
`base_classes[]` (signature strings), `methods{sig→Callable}`, `attributes{name→Attr}`,
`inner_classes{sig→Class}`, `start_line`, `end_line`.

### Callable (function / method / constructor)
`name`, `path`, `signature` (e.g. `module.Class.method`), `comments[]`, `decorators[]`,
`parameters[]`, `return_type`, `code`, `start_line`/`end_line`/`code_start_line`,
`accessed_symbols[]`, **`call_sites[]`** (the unresolved-then-backfilled call records),
`inner_callables{}`, `inner_classes{}`, `local_variables[]`, `cyclomatic_complexity`,
`is_entrypoint`, `entrypoint_framework`.

### Callsite (rich per-call metadata; lives on the caller)
`method_name`, `receiver_expr`, `receiver_type`, `argument_types[]`, `return_type`,
**`callee_signature`** (null when the site is first recorded; backfilled in place when the
resolver call graph is built),
`is_constructor_call`, and `start_line`/`start_column`/`end_line`/`end_column`.

### CallEdge (identity-only)
`source` (caller signature), `target` (callee signature), `type` (`"CALL_DEP"`),
`weight` (int, accumulated when merging backends), `provenance[]` (e.g. `["tsc"]`,
`["jedi","codeql"]`), `tags{}` (free-form, extension-namespaced).

### Entrypoint (optional)
`signature` (references a Callable), `framework`, `detection_source`
(`decorator|base_class|url_resolver|...|extension`), plus flat optional route/method
fields and a free-form `tags{}`.

## Mapping the contract onto a new language

Keep the spine identical; extend at the leaves:

| Canonical concept | TypeScript adds | Go adds |
| --- | --- | --- |
| Class | `interface`, `type`-alias, `enum` as sibling node kinds | `struct`, `interface` |
| Callable | arrow functions, methods, getters/setters | functions, methods (receiver type), closures |
| `base_classes` | `extends` + `implements` chains | embedded structs / satisfied interfaces |
| decorators | TS decorators (`@Injectable`) | struct tags (in `tags`) |

When you introduce a new node kind, give it its own `signature` produced by the same
`signatureOf()`, so edges can point at it.

## How the SDK consumes this

The SDK defines a parallel set of Pydantic models per language under
`python-sdk/cldk/models/<lang>/models.py` (e.g. `TSApplication`, `TSModule`, `TSCallable`,
`TSCallEdge`). They must mirror these field names so `Application(**json.load(...))`
validates. The Java models (`cldk/models/java/models.py`) and the re-exported Python models
(`cldk/models/python/__init__.py`) are the two worked examples to copy from — copy the one
whose invocation pattern (subprocess vs in-process) matches your analyzer. See
`python-sdk-wiring.md`.
