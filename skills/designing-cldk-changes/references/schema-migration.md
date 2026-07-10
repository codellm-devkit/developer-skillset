# Migrating an existing analyzer/SDK to a new schema major

Invoked from `designing-cldk-changes` when the Contract-Impact Triage says the change is a
**schema major** — an existing `codeanalyzer-<lang>` (and its SDK) must move to a new keystone.
This doc is the **design-and-staging plan** for that migration: it names the field-by-field deltas,
the compat/staging posture, and the version lockstep, so the spec and epic capture them and the
implementation rungs (`codeanalyzer-backend`, `cldk-sdk-frontend`) execute a decided plan rather
than improvising a breaking change. A schema-major migration is a **coordinated major release
across repos** — that coordination is exactly what design mode exists to plan.

The worked case below is the canonical one: an analyzer on the **old** schema (flat
`symbol_table: {path → CompilationUnit}` + a `call_graph` of rich or identity edges, per-callable
`code`, `is_*` boolean flags) moving to the v2 keystone (`references/canonical-schema.md`). The
parsing/resolution guts stay; the *emission layer* is rewritten to produce the additive tree +
typed edges, in both projections.

**Golden rule:** keep everything that *computes* facts (the parser, the resolver, WALA/Jelly/
go-ssa, the call-graph builder); replace only what *serializes* them. The analyzer already knows
the facts — v2 is a different shape for the same facts, plus deeper ones at L3/L4.

## Stage it level by level, lowest first

Migrate in the same additive order you would build a new analyzer, so each step is independently
validatable against the v2 SDK models — this staging *is* the child-issue breakdown in the epic:

1. **L1 emission** — the tree + `source` + ids. The biggest structural change; do it first and get
   the symbol-table gate green before touching edges.
2. **L2 emission** — the `call_graph` list at application scope.
3. **Neo4j projection** — re-point (or add) the graph emitter at the v2 node/edge families.
4. **L3/L4** — if the analyzer already computes dataflow (e.g. Java via WALA's slicer, which
   already emits program graphs), remap it into `body` + the split edge lists; otherwise it is new
   construction per `skills/codeanalyzer-backend/references/level-3-intraprocedural-dataflow.md`
   and `skills/codeanalyzer-backend/references/level-4-interprocedural-sdg.md`.

## Field-by-field: old → v2

### Root envelope
| Old | v2 |
| --- | --- |
| `{ symbol_table, call_graph }` (two top-level keys) | `{ schema_version, language, max_level, application: { id, symbol_table, call_graph, param_in, param_out } }` |
| — (no version) | `schema_version: "2.0.0"`, `max_level` (authoritative) |
| — (no app identity) | `application.id = can://<lang>/<app>` — **new**, disambiguates apps |

### Container / symbol nodes
| Old | v2 |
| --- | --- |
| `symbol_table[path]` = `CompilationUnit`/`Module` | `symbol_table[path]` = `module` node with `id`, `kind:"module"`, **`source`** (whole file, once) |
| `Type` with `is_interface`/`is_enum`/`is_record`/… booleans | one `type` node with a single **`kind`** (`class`\|`interface`\|`enum`\|`struct`\|…) |
| `CallSite.is_public/is_private/is_protected` booleans | one `access` field (or on the node) |
| flat-string `annotations[]` | structured `decorators[]` (`{name,args,span}`) |
| `thrown_exceptions[]` (Java) | generalized `error_channel[]` |
| per-callable `code` string | **dropped** — `get_method_body` slices `module.source[callable.span.bytes]` |
| `start_line`/`end_line`/`start_column`/`end_column` (flat ints) | `span: { start:[l,c], end:[l,c], bytes:[from,to] }` — **add byte offsets** for O(1) slicing |

### Edges (the biggest semantic change)
| Old | v2 |
| --- | --- |
| Java **rich edges** (`JGraphEdges` embedding `JMethodDetail`) | **identity-only**: `call_graph: [{ src, dst, prov, weight }]` — ids only; join detail via id |
| identity edges `{ source, target, type:"CALL_DEP", provenance }` | rename keys → `{ src, dst, prov }`; `call_graph` list at application scope |
| call graph mixed granularity | `call_graph` is **callable→callable** and immutable; call-site-level linking is L4 `param_*` |
| `program_graphs.functions[sig].cfg.nodes` + `sdg_edges` (Java today) | move nodes into the callable's **`body{}`**; split edges into `cfg`/`cdg`/`ddg`/`summary` (intra) + `param_in`/`param_out` (cross); endpoints become `can://…@line:col` ids |
| `data_dependence: "no-heap"\|"full"` (Java) | this **is** the syntactic/semantic DDG split — emit as `ddg` edges tagged `prov:["ssa"]` (no-heap, L3) vs `prov:["points-to"]` (full, L4) |

### Identity
| Old | v2 |
| --- | --- |
| `signature` string as the id | keep `signature` as the callable's human-readable field, but the **`id`** is the full `can://<lang>/<app>/<file>/<type>/<signature>` path |
| `(signature, node)` pair for graph endpoints (Java) | single string id `…<signature>@<line>:<col>` (or `@tag` for synthetic) |
| bare `signatureOf()` | unchanged — still the one canonicalizer; it now produces the *last path segment* of the id |

## Practical mechanics (for the backend rung)

- **Wrap, don't rewrite, the model layer.** If the analyzer builds in-memory model objects then
  serializes, add a **v2 emitter** that walks those same objects and produces the new shape — the
  cleanest diff, and it lets you keep the old emitter behind a flag during transition. That flag is
  the **compat shim** the migration leans on while both schemas coexist.
- **Byte offsets:** the parser already has token positions; thread the byte/char offset through to
  `span.bytes`. This is the one genuinely new datum L1 needs.
- **`source`:** you already read each file — retain its text on the module node instead of slicing
  per-callable `code`.
- **Neo4j:** if the analyzer already has a graph projection, it is largely a **relabel** to the v2
  node/edge families and id scheme; if not, add the `neo4j/` subpackage per
  `skills/codeanalyzer-backend/references/neo4j-projection.md`.
- **Validate against the SDK v2 models at each level** — the same gates as a new analyzer
  (`skills/codeanalyzer-backend/references/testing-and-validation.md`), plus a **superset check** if
  you keep the old emitter: v2 output must contain every fact the old output did (modulo the
  deliberate drops above).

## The SDK side migrates in lockstep

A schema major is **also a major SDK release**, planned in the same epic. The `cldk-sdk-frontend`
rung remaps the Pydantic models to v2 **while keeping every public accessor's name and return type
identical** — the device that makes API-stability possible is the two-layer model / per-language
views (`skills/cldk-sdk-frontend/references/schema-contract.md`). So the migration epic has two
coupled tracks: the analyzer's emission rewrite (backend) and the SDK's model remap (frontend),
released together.

## Release & coordination (the lockstep the epic tracks)

- **Major version bump** on the analyzer; note the breaking output change in the release notes
  (Keep-a-Changelog *Changed/Breaking*).
- **Pin only once both are cut.** The SDK revises its models to v2 in lockstep, keeping the public
  API stable; pin the analyzer version in the SDK **only once both are released**. Until then, the
  SDK's old models won't parse v2 output — don't publish the analyzer's new major as the SDK's
  pinned version prematurely. This ordering constraint is a first-class item on the epic checklist.
- Update the repo's **`CLAUDE.md`** to describe the v2 model (it is now what the analyzer emits).
