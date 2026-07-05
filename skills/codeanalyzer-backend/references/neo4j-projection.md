# Neo4j projection (the co-primary output surface)

Every CLDK analyzer emits **two projections of the one structure** (`canonical-schema.md`): the
`analysis.json` tree and a **Neo4j graph**. They are **co-primary** — building both is a
first-class deliverable, not an afterthought. The graph is not an ingestion of `analysis.json` —
it is a projection of the **same node tree + edge overlays**, selected by `--emit neo4j`.
`analysis.json` is the SDK's default contract; the graph is the queryable, incrementally-updatable
surface. Java, Python, and TypeScript analyzers all ship it.

**Containment renders as edges.** A graph DB has no nesting, so the schema's containment tree
becomes typed `HAS_*`/`DECLARES` relationships (the `HAS_MODULE`/`DECLARES`/`HAS_CALLABLE`/
`HAS_CFG_NODE` families below), while the overlay edges (`call_graph`, `cfg`, `cdg`, `ddg`,
`param_in`/`param_out`, `summary`) become their own typed relationships. Node labels are the v2
node **kinds**; the `can://` id is the merge key. This is a **near-identity** projection of the
JSON tree — the same nodes and edges, rendered as a property graph.

Neo4j stays **optional at run time** (you don't need a running DB to emit `analysis.json`): the
driver is a lazy/optional dependency (Python/TS import it on demand; Java loads it reflectively so
GraalVM `native-image` can prune it). "Co-primary" means *the analyzer must be able to produce it*,
not that every run does.

## CLI surface (add to `cli-contract.md`)

| Flag | Meaning |
| --- | --- |
| `--emit <json\|neo4j\|schema>` | Output target. `json` (default) → `analysis.json`; `neo4j` → graph (Cypher file or live push); `schema` → the static `schema.neo4j.json` contract (needs no `-i`). |
| `--neo4j-uri <uri>` | Bolt URI for a **live** push. Omit → write a self-contained `graph.cypher` file instead. Env: `NEO4J_URI`. |
| `--neo4j-user <user>` | Env `NEO4J_USERNAME`, default `neo4j`. |
| `--neo4j-password <pw>` | Env `NEO4J_PASSWORD`, default `neo4j`. |
| `--neo4j-database <db>` | Env `NEO4J_DATABASE`, optional (server default). |
| `--app-name <name>` | Logical name for the `:Application` anchor node (default: input dir name). The SDK's Neo4j backend must be pointed at the **same** name. |

Precedence is **explicit flag > env var > default**. `--emit schema` is a static artifact and
must run without `-i`; every other target requires `-i`.

## Depth rule: the graph is always full

**Analysis levels do not apply to the graph surface.** `--emit neo4j` runs the analyzer at its
**maximum implemented depth** and projects everything — symbol table, call graph, and (once
levels 3–4 exist) the complete CFG/PDG (L3) and SDG (L4), i.e. the full CPG. There is no such
thing as a "symbol-table-only" graph:

- A queryable graph database is a whole-picture artifact — a partial graph silently answers
  queries wrongly ("no path from source to sink" when the dataflow edges were simply never
  projected).
- Incremental Bolt pushes need a **stable node/edge vocabulary** across runs; a graph whose
  shape depends on the flags of whichever run last touched it is unmergeable.

Consequently `-a`/`--analysis-level` and `--graphs` are **JSON-path flags only**. Passing either
together with `--emit neo4j` is an **explicit non-zero error** (per `cli-contract.md § Flag
validation requirements` — never silently ignore a flag), e.g.:
```
error: --analysis-level does not apply to --emit neo4j; the graph is always projected at full depth
```
This also means `--emit neo4j` inherits full L3+L4 cost once dataflow exists — that is by design;
the cheap path is `--emit json` at `-a 1`.

## Modular structure (a `neo4j/` subpackage, mirroring the analyzer's modularity rules)

The three reference analyzers converge on the identical shape — replicate it:

```
neo4j/
  project.{ts,py,java}   # pure IR → GraphRows projection (walks symbol table + call graph)
  rows.{ts,py,java}      # output-agnostic data model + RowBuilder (in-memory MERGE, deferred edges)
  cypher.{ts,py,java}    # snapshot writer → graph.cypher (self-contained script)
  bolt.{ts,py,java}      # incremental writer → live Bolt push (lazy driver import)
  schema.{ts,py,java}    # declarative schema: node labels, rel types, constraints, indexes, DDL
```

Java names these `GraphProjector` / `GraphRows`+`RowBuilder` / `CypherWriter` / `BoltWriter`+
`BoltSink`+`BoltConfig` / `SchemaCatalog`+`Schema`. The seam that matters: **`project()` is a
pure function `(IR, appName) → GraphRows`** with no I/O and no driver — both writers consume the
same rows identically. Keep it that way.

### `GraphRows` — the output-agnostic intermediate

Pure data, deterministic, deduped. Property values are Neo4j-legal only (primitives + homogeneous
primitive arrays); `null`/`undefined` are **pruned** (in Neo4j an absent property *is* null).

- `NodeRow { labels[], keyProp, value, props }` — `labels[0]` is the **constrained MERGE label**;
  the rest are SET as extra labels.
- `NodeRef { label, keyProp, value }` — how an edge addresses an endpoint to MATCH on.
- `EdgeRow { type, from: NodeRef, to: NodeRef, props }`.

`RowBuilder` accumulates with **in-memory MERGE semantics**: re-seeing the same
`(labels[0], value)` merges props (last-write-wins) and unions labels — the analog of
`MERGE (n:Label {key}) SET n += props`. Crucially it holds a **deferred edge** list: edges to a
`:Symbol` target that may be external/library code are kept only if that target was actually
emitted as a node this run (gated in `finish()`). This is the graph-side incarnation of the
analyzer's **"edge only when resolved"** rule — EXTENDS / IMPLEMENTS / RESOLVES_TO / CALLS never
dangle; the unresolved string fallback lives on the source node's props instead.

### Snapshot writer (`graph.cypher`)

Self-contained and idempotent; running it (`cypher-shell < graph.cypher`) rebuilds this
project's subgraph from scratch. Order:

1. Emit all `CONSTRAINTS` then `INDEXES` (`CREATE CONSTRAINT … IF NOT EXISTS`).
2. **Scoped wipe** of this app's prior subgraph — `MATCH (a:Application {name})` → the owned
   modules/declarations → `DETACH DELETE`. Shared nodes (External/Package/Decorator) are *not*
   wiped.
3. Batched `UNWIND [...] AS row MERGE (n:MergeLabel {key: row.k}) SET n += row.p` for nodes,
   grouped by full label-set + key, **500 per batch**.
4. Batched `UNWIND … MATCH (a) MATCH (b) MERGE (a)-[r:TYPE]->(b) SET r += row.p` for edges.

### Incremental writer (live Bolt push)

Module-scoped diffing keyed on each module's `content_hash`: fetch the DB's per-module hashes,
find changed modules, and for each — in a transaction — delete edges owned by that module, delete
its declarations no longer emitted, then MERGE the current nodes/edges. Shared nodes are
MERGE-only. On **full** runs, orphan-prune modules whose source vanished. Batch ~1000 per
transaction. Import the driver lazily (only when `--neo4j-uri` is set).

## The graph schema (`schema.neo4j.json`)

A declarative, versioned contract at the analyzer repo root, emitted by `--emit schema`. It is
the graph-side sibling of `canonical-schema.md` and is what the SDK's Neo4j backend reconstructs
against. Shape:

```json
{
  "schema_version": "1.0.0",
  "generator": "codeanalyzer-<lang>",
  "marker_labels": ["Entrypoint"],
  "node_labels": [
    { "label": "Application", "mergeLabel": "Application", "key": "name",
      "properties": { "name": "string", "schema_version": "string" } },
    { "label": "Class", "mergeLabel": "Symbol", "key": "signature",
      "properties": { "signature": "string", "name": "string", "is_exported": "boolean", "_module": "string", ... } }
  ],
  "constraints": ["CREATE CONSTRAINT ... FOR (s:Symbol) REQUIRE s.signature IS UNIQUE", ...],
  "indexes": ["CREATE INDEX ... FOR (c:Callable) ON (c.name)", "CREATE FULLTEXT INDEX ..."]
}
```

Load-bearing conventions:

- **Dual-label / MERGE-label pattern.** Type-like nodes (`Class`, `Interface`, `Enum`, …) all
  carry a shared **merge label** (`Symbol`) keyed on `signature`, plus their specific label as an
  extra. Callables likewise merge on `signature`. This gives one uniqueness constraint per family
  and lets edges MATCH targets by a single `(Symbol {signature})` lookup regardless of kind.
  (Java keys on `id` — the FQN, or `<fqn>#<signature>` for callables — instead of `signature`.)
- **`_module` provenance on every project-owned node** — the file path that emitted it. The
  incremental writer uses it to isolate and delete exactly what a re-analyzed module previously
  wrote. Shared nodes (External/Package/Decorator/Annotation) carry no `_module`.
- **Node families** map straight from the schema decisions: `Application`, `Module`/
  `CompilationUnit`, the `Symbol` types (`Class`/`Interface`/`Enum`/`TypeAlias`/`Namespace`/…),
  `Callable`, `CallSite`, `Field`/`Attribute`, `Parameter`, `Variable`, and the shared
  `Package`/`External`/`Decorator`(`Annotation`).
- **Relationship types** mirror the nesting + call graph: `HAS_MODULE`, `DECLARES`,
  `HAS_METHOD`/`HAS_CALLABLE`, `HAS_ATTRIBUTE`/`HAS_FIELD`, `HAS_CALLSITE`, `RESOLVES_TO`,
  `CALLS` (with `weight`/`provenance` props), `EXTENDS`, `IMPLEMENTS`.
- **Relationship namespacing.** Java prefixes relationship types (`J_HAS_UNIT`, `J_CALLS`);
  Python uses `PY_`; TypeScript (and a new bare-namespaced language) uses unprefixed names. Pick
  one convention and hold it. Marker labels (`Entrypoint`) flag entrypoint nodes; omit if the
  analyzer has no entrypoint detection yet.

## Where the language's schema decisions land

The **same** `SCHEMA_DECISIONS.md` node kinds and fields you designed for `analysis.json` drive
the graph: every JSON node kind becomes a node label, every field a node property, every
identity-only call edge a `CALLS` relationship. Add a `schema_version` and bump it additively as
you extend (Python is at `1.1.0` over Java's `1.0.0` for exactly this reason). Keep the graph
schema and the JSON schema in lockstep — they are two encodings of one contract.

## Verify

- `--emit schema` produces a `schema.neo4j.json` that parses and lists every node family your
  JSON emits.
- `--emit neo4j` with no `--neo4j-uri` writes a `graph.cypher` that runs clean against an empty
  Neo4j (`cypher-shell < graph.cypher`) and is **idempotent** — running it twice yields the same
  graph (the scoped wipe guarantees this).
- With `--neo4j-uri`, a second run after editing one file touches only that module's subgraph.
- No dangling relationships: every `EXTENDS`/`IMPLEMENTS`/`RESOLVES_TO`/`CALLS` endpoint resolves
  to an emitted node (the deferred-edge gate enforces this).
