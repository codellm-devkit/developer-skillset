# The Neo4j projection (the co-primary output surface)

Every CLDK analyzer emits **two projections of the one structure**
(`skills/designing-cldk-changes/references/canonical-schema.md`): the `analysis.json` tree and a
**Neo4j graph**. They are **co-primary** — building both is a first-class deliverable, not an
afterthought. The graph is **not** an ingestion of `analysis.json`; it is a projection of the **same
node tree + edge overlays**, selected by `--emit neo4j`. `analysis.json` is the SDK's default
contract; the graph is the queryable, incrementally-updatable surface. Java, Python, and TypeScript
analyzers all ship it.

**Containment renders as edges.** A graph DB has no nesting, so the schema's containment tree becomes
typed `HAS_*`/`DECLARES` relationships (`HAS_MODULE`, `DECLARES`, `HAS_CALLABLE`, `HAS_FIELD`,
`HAS_CALLSITE`, and at L3/L4 `HAS_BODY_NODE`/`HAS_CFG_NODE`), while the overlay edges (`call_graph`,
`cfg`, `cdg`, `ddg`, `param_in`/`param_out`, `summary`) become their own typed relationships. Node
labels are the v2 node **kinds**; the `can://` id is the merge key. This is a **near-identity**
projection — the same nodes and edges, rendered as a property graph.

Neo4j stays **optional at run time** (you don't need a running DB to emit `analysis.json`): the driver
is a lazy/optional dependency (Python/TS import it on demand; Java loads it reflectively so GraalVM
`native-image` can prune it). "Co-primary" means *the analyzer must be able to produce it*, not that
every run does.

## CLI surface

The flags (`--emit`, `--neo4j-uri`, `--neo4j-user/-password/-database`, `--app-name`, precedence
**explicit > env > default**) are specified in `references/cli-contract.md`. `--emit schema` is a
static artifact and must run without `-i`; every other target requires `-i`.

## Depth rule: the graph is always full

**Analysis levels do not apply to the graph surface.** `--emit neo4j` runs the analyzer at its
**maximum implemented depth** and projects everything — symbol table, call graph, and (once L3/L4
exist) the complete `cfg`/`cdg`/`ddg` (L3) and the SDG `param_*`/`summary` (L4), i.e. the full CPG.
There is no "symbol-table-only" graph:

- A queryable graph is a whole-picture artifact — a partial graph silently answers queries wrongly
  ("no path from source to sink" when the dataflow edges were simply never projected).
- Incremental Bolt pushes need a **stable node/edge vocabulary** across runs; a graph whose shape
  depends on the flags of whichever run last touched it is unmergeable.

Consequently `-a`/`--analysis-level` and `--graph-field-depth` are **JSON-path flags only**. Passing
either together with `--emit neo4j` is an **explicit non-zero error** (never silently ignore a flag):

```
error: --analysis-level does not apply to --emit neo4j; the graph is always projected at full depth
```

`--emit neo4j` therefore inherits full L3+L4 cost once dataflow exists — by design; the cheap path is
`--emit json` at `-a 1`.

## Modular structure (a `neo4j/` subpackage)

The reference analyzers converge on one shape — replicate it (`references/analyzer-architecture.md`):

```
neo4j/
  project    # PURE (IR, appName) -> GraphRows projection (walks the tree + all overlays). No I/O, no driver.
  rows       # output-agnostic data model + RowBuilder (in-memory MERGE, deferred edges)
  cypher     # snapshot writer -> graph.cypher (self-contained script)
  bolt       # incremental writer -> live Bolt push (lazy driver import)
  schema     # declarative schema: node labels, rel types, constraints, indexes, DDL
```

The seam that matters: **`project()` is a pure function `(IR, appName) → GraphRows`** with no I/O and
no driver — both writers consume the same rows identically.

### `GraphRows` — the output-agnostic intermediate
Pure, deterministic, deduped. Property values are Neo4j-legal only (primitives + homogeneous
primitive arrays); `null`/absent are **pruned** (in Neo4j an absent property *is* null).

- `NodeRow { labels[], keyProp, value, props }` — `labels[0]` is the **constrained MERGE label**; the
  rest are extra labels.
- `NodeRef { label, keyProp, value }` — how an edge addresses an endpoint to MATCH on.
- `EdgeRow { type, from: NodeRef, to: NodeRef, props }`.

`RowBuilder` accumulates with **in-memory MERGE semantics** and holds a **deferred edge** list: edges
to an external/library target are kept only if that target was actually emitted as a node this run
(gated in `finish()`). This is the graph-side "edge only when resolved" rule — `CALLS`/`RESOLVES_TO`/
`EXTENDS`/`IMPLEMENTS` never dangle; the unresolved-string fallback lives on the source node's props.

### Snapshot writer (`graph.cypher`)
Self-contained and idempotent — running it (`cypher-shell < graph.cypher`) rebuilds this project's
subgraph from scratch. Order: (1) emit `CONSTRAINTS` then `INDEXES` (`… IF NOT EXISTS`); (2) **scoped
wipe** of this app's prior subgraph — `MATCH (a:Application {name})` → owned modules/declarations →
`DETACH DELETE` (shared External/Package nodes are *not* wiped); (3) batched `UNWIND … MERGE (n:Label
{key}) SET n += row.p` for nodes, **500 per batch**; (4) batched `UNWIND … MATCH … MERGE
(a)-[r:TYPE]->(b)` for edges.

### Incremental writer (live Bolt push)
Module-scoped diffing keyed on each module's `content_hash`: fetch the DB's per-module hashes, find
changed modules, and per module — in a transaction — delete edges owned by it, delete its
no-longer-emitted declarations, then MERGE current nodes/edges. Shared nodes are MERGE-only; full runs
orphan-prune modules whose source vanished. Batch ~1000/tx; import the driver lazily.

## The graph schema (`schema.neo4j.json`)

A declarative, versioned contract at the analyzer repo root, emitted by `--emit schema` — the
graph-side sibling of the keystone, what the SDK's Neo4j backend reconstructs against.

Load-bearing conventions:

- **Dual-label / MERGE-label pattern.** Type-like nodes (`Class`/`Interface`/`Enum`/…) carry a shared
  **merge label** (`Symbol`) keyed on the `can://` id, plus their specific label as an extra. This
  gives one uniqueness constraint per family and lets edges MATCH a target by a single
  `(Symbol {id})` lookup regardless of kind.
- **`_module` provenance on every project-owned node** — the file that emitted it; the incremental
  writer uses it to isolate and delete exactly what a re-analyzed module previously wrote. Shared
  nodes (External/Package/Decorator) carry no `_module`.
- **Node families** map straight from the schema decisions: `Application`, `Module`, the `Symbol` types,
  `Callable`, `CallSite`, `Field`, `Parameter`, plus the shared `Package`/`External`/`Decorator`.
- **Relationship types** mirror containment + overlays: `HAS_MODULE`, `DECLARES`, `HAS_CALLABLE`,
  `HAS_FIELD`, `HAS_CALLSITE`, `RESOLVES_TO`, `CALLS` (props `weight`/`prov`), `EXTENDS`, `IMPLEMENTS`.
- **Relationship namespacing.** Java prefixes (`J_HAS_UNIT`, `J_CALLS`); Python uses `PY_`; a
  bare-namespaced new language uses unprefixed names. Pick one and hold it. Marker labels
  (`Entrypoint`) flag entrypoint nodes; omit if the analyzer has no entrypoint detection yet.
- Add a `schema_version` and **bump it additively** as you extend (Python is at `1.1.0` over Java's
  `1.0.0`). The graph schema and JSON schema move in lockstep — two encodings of one contract.

## CPG overlay (L3/L4)

When dataflow exists, the same `GraphRows`/writer machinery carries the CPG overlay (additive
`schema.neo4j.json` bump):

- **Labels:** body/CFG nodes (merge key = the `…@line:col` / `@tag` id), props `kind`, `start_line`,
  `end_line`, `_module`.
- **Edge types:** `CFG_NEXT` (prop `kind`), `CDG`, `DDG` (props `var`, `prov`), `PARAM_IN`,
  `PARAM_OUT`, `SUMMARY`, and `HAS_CFG_NODE`/`HAS_BODY_NODE` (Callable → node ownership).
- The AST layer of the CPG is the existing symbol-table projection; the overlay is complete when a
  Callable's body nodes, its `cdg`/`ddg` edges, and the cross-function SDG edges are all present and
  the deferred-edge (no-dangling) gate holds.

## Verify

- `--emit schema` produces a `schema.neo4j.json` that parses and lists every node family the JSON
  emits.
- `--emit neo4j` with no `--neo4j-uri` writes a `graph.cypher` that runs clean against an empty Neo4j
  and is **idempotent** — running it twice yields the same graph (the scoped wipe guarantees this).
- With `--neo4j-uri`, a second run after editing one file touches only that module's subgraph.
- No dangling relationships: every `EXTENDS`/`IMPLEMENTS`/`RESOLVES_TO`/`CALLS`/`PARAM_*`/`SUMMARY`
  endpoint resolves to an emitted node. Node/edge counts at full depth match the JSON at `max_level`
  (modulo the explicit `HAS_*` containment edges) — the cross-projection check in
  `references/testing-and-validation.md`.
