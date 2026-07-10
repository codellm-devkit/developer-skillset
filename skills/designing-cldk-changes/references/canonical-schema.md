# The canonical CLDK analysis schema (v2) — the keystone

This is the contract every CLDK analyzer emits and every SDK consumes. It is the **single
source of truth** for the CLDK contract: **the design mode owns it**, and the implementation rungs
point here rather than restating it — `codeanalyzer-backend` builds analyzers that produce this
shape, and `cldk-sdk-frontend` builds SDKs whose models mirror it. The shape exists in **two
projections** — `analysis.json` and a Neo4j graph.

This document has two parts. **Part I states the model** — the additive tree, the ids, the levels,
the edge families, the two projections. **Part II is the field-by-field appendix** — every node
kind's fields and every edge list's shape, so an analyzer emits them comprehensively and an SDK
models them exactly. Read Part I first; it is the keystone every design decision serves.

---

# Part I — the model

## The one idea: an additive analysis paradigm

> **Codeanalyzer is an additive analysis paradigm: each analysis level is the same tree grown
> one layer deeper, plus one edge family over the new layer.**

There is exactly **one structure** — a tree of nodes with typed edges laid over it (a Code
Property Graph). Every "section" anyone has ever named — symbol table, call graph, CFG, PDG,
SDG, taint — is a **projection of that one structure**, not a separate thing. Analysis
**levels** are how deeply the structure is populated; they only ever *add*, never rewrite.

### The atom

One **scale-free node** — a region of code — is the whole vocabulary. A `file`, a `struct`, a
`method`, a `statement` are not different kinds of thing; they are the same node at different
granularity. Every node has:

- an **`id`** (see § Identity),
- a **`kind`** (the node-kind ladder below),
- a **`span`** (the one universal attribute — where in source it lives),
- **children** (containment), and
- **edges** (typed overlays).

### Two relations, and only two

1. **Containment** — the **single-parent** relation. Every node has exactly one parent (the
   root `application` excepted). *Exactly one* is what makes it a **tree**, and what
   distinguishes it from the overlays.
2. **Typed edges** — the multi-valued overlays: `call_graph`, `cfg`, `cdg`, `ddg`, `param_in`,
   `param_out`, `summary`. A node has one parent but many edges.

A node + containment tree + typed edge overlays **is a CPG.** Hold this and the rest follows.

## The hierarchy (named-map containment)

Containment above the callable is expressed as **named maps** — the classic symbol-table
shape, keyed for lookup. The tree grows *downward* as the level rises:

```
application                                   ← the root; carries an id
  symbol_table: { <file>: module }            ← L1
    module: { types{}, functions{} }          ← L1  (per-file / compilation-unit container)
      type: { callables{}, fields{} }         ← L1
        callable: { body{}, cfg[], cdg[], ddg[], summary[] }
          body: { <local-id>: node }          ← L1: call nodes; completes at L3
  call_graph[], param_in[], param_out[]       ← cross-function edges, at the application scope
```

- **Above the callable**: name-keyed maps (`types`, `functions`, `callables`) — each node
  carries its full `id`.
- **At the callable**: `body` is the container that exists from L1 (holding the `call` nodes)
  and completes at L3. It is a map keyed by the
  node's **local id** (a source position `line:col`, or an `@tag` for synthetic vertices).
- **Edges live at the lowest common ancestor of their endpoints**: intra-callable edges
  (`cfg`/`cdg`/`ddg`/`summary`) hang on the callable; cross-callable edges
  (`call_graph`/`param_in`/`param_out`) hang on the application.

### Node-kind ladder

```
application → file/module → type (class|struct|interface|enum|…) → callable (function|method|constructor)
            → statement (statement|call|return|branch|loop|…) → [expression, opt]
```

plus the **synthetic** vertices: `entry`/`exit` introduced at L3, and `formal_in`/`formal_out`/
`actual_in`/`actual_out` introduced at L4. A node is therefore *either an AST region or a
synthetic analysis vertex*; both fit the tree (synthetic vertices are children of the callable or
of a call-site statement).

## Identity

Two tiers, and the boundary is the **callable leaf line** — the same line where L1 stops.

- **Durable ids (≥ callable)** — files, modules, types, callables get stable
  `can://` URIs (an extension of the upstream `cldk://` RFC grammar; grammar in
  `skills/cldk-sdk-frontend/references/schema-contract.md`) that
  survive re-analysis and are what external tools (SCIP export, cross-repo joins) address. The grammar
  is a **containment path** with an application segment so multiple apps in one language don't
  collide:

  ```
  can://<lang>/<app>/<file>/<type>/<callable-signature>
  can://go/myapp/src/util.go/Hasher/Hash(string)uint64
  ```

- **Ordinal ids (< callable)** — statements and synthetic vertices are addressed *within* their
  callable by a **source position** (real nodes) or an **`@tag`** (synthetic):

  ```
  <callable-id>@<line>:<col>          e.g. …/Hash(string)uint64@15:2      (a statement)
  <callable-id>@<tag>                  e.g. …/Hash(string)uint64@entry     (synthetic)
                                            …@formal_in:0, …@16:2/actual_in:0
  ```

  Positions are addressable (the SDK can expose `flows_to_statement("util.go:42")` as a
  line-level query) and unique within a single analysis when they carry `line:col` — a bare
  line is **not** unique (`if err != nil { return err }`), so always keep the column. These are
  content-stable within one run; they are **not** promised across edits (analysis is recomputed
  wholesale, so cross-edit durability is a non-goal below the callable line).

The delimiters `/`, `@`, `:` are chosen to not collide with the durable `#`/symbol grammar; the
`can://` scheme and the app segment are extensions to be kept in lockstep with the SDK's
`schema-contract.md` and the upstream `cldk://` RFC.

## The levels (what each one grows)

The levels are progressive population of the one tree, each additive over the last —
`L1 ⊆ L2 ⊆ L3 ⊆ L4`, superset **modulo null-refinement** (see § Monotonicity). Depth grows only
at **L1 and L3**; L2 adds only edges; L4 adds synthetic vertices + edges.

| Level | Grows (nodes) | Adds (edges) | Cost / substrate | Flag |
| --- | --- | --- | --- | --- |
| **1** | the tree to **callable** depth, + `call` nodes in `body` (call sites, `callee` unresolved) | — | cheap, parser + resolver | `-a 1` |
| **2** | `callee` on each `call` node backfilled (`null → id`) | `call_graph` (callable → callable) | cheap | `-a 2` |
| **3** | the **rest of `body`** (non-call statements) under each callable | `cfg`, `cdg`, `ddg` (**syntactic**) — all intra-callable | heavy, **AST-only, per-callable parallel** | `-a 3` |
| **4** | **synthetic** param vertices (formal/actual in-out) | `param_in`, `param_out`, `summary`, + `ddg` (**semantic**, alias-aware) | heaviest: **needs the points-to oracle** + summary fixpoint | `-a 4` |

`body` therefore begins at **L1** holding just the `call` nodes (so `get_call_sites` is an L1
accessor, preserving the old SDK surface) and completes at **L3** with the remaining statements.
Depth grows at L1 (tree + call sites) and L3 (full body); L2 is a pure refinement + edge add; L4
adds synthetic vertices + cross edges.

`-a 3` implies `-a 2`; `-a 4` implies `-a 3`. Framework enrichment (Joern/WALA) and points-to
precision are an **orthogonal axis** — provenance-merged evidence into an existing edge family,
**not** a level. `max_level` in the payload declares which level was populated; consumers
**read it** rather than sniffing for keys.

### Edge families and their placement

| Edge list | Level | Endpoints | Lives on | Notes |
| --- | --- | --- | --- | --- |
| `call_graph` | 2 | callable → callable | application | `prov[]`, `weight`; immutable once written (never re-anchored to a statement) |
| `cfg` | 3 | statement → statement | callable | `kind`: `fallthrough`\|`true`\|`false`\|`switch_case`\|`loop_back`\|`exception`\|`return`\|… |
| `cdg` | 3 | statement → statement | callable | control dependence (from post-dominance) |
| `ddg` | 3→4 | statement → statement | callable | `var` (k-limited access path), `prov`: `["ssa"]` = **syntactic** (L3), `["points-to"]` = **semantic** (L4) |
| `summary` | 4 | actual_in → actual_out (same call) | callable | transitive intra-caller shortcut |
| `param_in` | 4 | actual_in → formal_in | application | argument into callee |
| `param_out` | 4 | formal_out → actual_out | application | result back to caller |

Each list is keyed **by its type** (the list name *is* the type; no `type` field). Every edge
record is `{ src, dst, …attrs }` referencing node ids. **No dangling endpoints** — every `src`
and `dst` must resolve to a node in the tree (the same invariant at every level).

## Source and text: one blob per module, everything slices off it

The tree carries structure; source **text** is stored **once per file, on the module node**, as
`source`, and every node's text is a **slice** of it:

- `get_method_body(sig)` → `module.source[callable.span.bytes]`
- a statement's text, a call's receiver expression → the same slice by its node span.

To make slicing O(1), **spans carry byte/char offsets** alongside `line:col` (`line:col` to
address and display, offsets to slice). This is the minimum-size, self-contained choice — one
copy of each source file, zero per-node duplication, and it subsumes any per-callable `code`
field.

## Monotonicity (the invariant that makes "additive" true)

Levels **add** facts; they never contradict or delete. Exactly two sanctioned changes:

1. **Additive** — new nodes deeper in the tree, new entries in an edge list.
2. **Refinement** — an unresolved fact becoming resolved: `callee` on a call node `null → id`.
   Null-to-value only, never value-to-different-value.

So `analysis.json(-a 1) ⊆ … ⊆ analysis.json(-a 4)`, a **CI-checkable superset gate**. The one
subtlety is the DDG: L3 emits the **syntactic** (name-equality, no-alias) def-use — a strict
subset — and L4 **adds** the alias-derived edges via points-to. This holds *because* the
precision posture is weak-update / over-approximate (no strong updates through aliases); a
strong update would remove an edge and break the chain. The `prov` tag (`ssa` vs `points-to`)
makes the syntactic/semantic split visible in the data.

## Conventions

- **snake_case keys**, everywhere, in every host language (Gson `LOWER_CASE_WITH_UNDERSCORES`,
  Pydantic defaults) so one set of SDK models parses every analyzer.
- **A fact is present or absent — there is no `null`** (except the sanctioned `callee: null`
  refinement slot). Absence *is* the "no fact" encoding; do not emit empty-vs-null noise.
- **`analysis.json` is one facade-visible artifact** (or compact JSON on stdout); the Neo4j
  graph is the co-primary projection (below). Caches/DBs are internal.
- Open-vocabulary fields (`prov`, `tags`) are plain strings so a persisted payload loads even
  without the producing extension installed.

## Two projections of the one structure

The same tree + overlays is emitted two ways; they must agree.

- **`analysis.json`** — this document: named-map tree, `body` maps, split edge lists,
  `source` per module. The facade contract.
- **Neo4j** — a near-identity projection
  (`skills/codeanalyzer-backend/references/neo4j-projection.md`): every node → a node row,
  **containment → typed `HAS_*`/`DECLARES` edges** (the tree rendered as edges, since a graph DB
  has no nesting), every overlay edge → a typed relationship. Node families and the `--app-name`
  anchor must match this schema. The Neo4j graph is **always full-depth** — analysis levels gate
  the JSON path only.

Building **both** is a first-class deliverable for every analyzer, not an afterthought.

## Worked example (L1 → L4, additive)

```jsonc
{
  "schema_version": "2.0.0", "language": "go", "max_level": 4, "k_limit": 3,
  "analyzer": { "name": "codeanalyzer-go", "version": "1.4.0" },
  "application": {
    "id": "can://go/myapp", "kind": "application",
    "symbol_table": {
      "src/util.go": {                                                            // L1
        "id": "can://go/myapp/src/util.go", "kind": "module", "package": "util",
        "source": "package util\n\nimport \"hash/fnv\"\n\nfunc (h Hasher) Hash(s string) uint64 {\n\th := fnv.New64()\n\th.Write([]byte(s))\n\treturn h.Sum64()\n}\n",
        "types": {
          "Hasher": {
            "id": "can://go/myapp/src/util.go/Hasher", "kind": "struct",
            "span": { "start":[10,1], "end":[40,1], "bytes":[0,400] },
            "callables": {
              "Hash(string)uint64": {
                "id": "can://go/myapp/src/util.go/Hasher/Hash(string)uint64", "kind": "method",
                "span": { "start":[14,1], "end":[22,1], "bytes":[42,180] },
                "body": {                                                 // L1: call nodes; completes at L3
                  "@entry": { "kind":"entry" },
                  "15:2":   { "kind":"statement", "span":{ "start":[15,2],"end":[15,18],"bytes":[84,100] } },
                  "16:2":   { "kind":"call", "span":{...}, "callee":"can://go/myapp/src/fnv.go/New64()" },
                  "17:2":   { "kind":"return", "span":{...} },
                  "@exit":  { "kind":"exit" },
                  "@formal_in:0":     { "kind":"formal_in",  "of":"s" },           // L4
                  "@formal_out":      { "kind":"formal_out", "of":"$ret" },        // L4
                  "16:2/actual_in:0": { "kind":"actual_in",  "of":"arg0", "parent":"16:2" },  // L4
                  "16:2/actual_out":  { "kind":"actual_out", "of":"$ret", "parent":"16:2" }
                },
                "cfg": [ {"src":"@entry","dst":"15:2","kind":"fallthrough"},       // L3
                         {"src":"15:2","dst":"16:2","kind":"fallthrough"} ],
                "cdg": [ {"src":"@entry","dst":"15:2"} ],                          // L3
                "ddg": [ {"src":"15:2","dst":"17:2","var":"h","prov":["ssa"]},     // L3 syntactic
                         {"src":"16:2","dst":"17:2","var":"h","prov":["points-to"]} ], // L4 semantic
                "summary": [ {"src":"16:2/actual_in:0","dst":"16:2/actual_out"} ]  // L4
              }
            }
          }
        },
        "functions": {}
      }
    },
    "call_graph": [ {"src":"can://go/myapp/src/util.go/Hasher/Hash(string)uint64",  // L2
                     "dst":"can://go/myapp/src/fnv.go/New64()","prov":["go/types"],"weight":1} ],
    "param_in":  [ {"src":"…/Hash(string)uint64@16:2/actual_in:0","dst":"…/New64()@formal_in:0"} ], // L4
    "param_out": [ {"src":"…/New64()@formal_out","dst":"…/Hash(string)uint64@16:2/actual_out"} ]     // L4
  }
}
```

Every level only *added* — a key, `body` nodes, or edge entries. Nothing was rewritten except
the `callee: null → id` backfill. That is the additive paradigm made literal.

## Cross-language parity clause

The **vocabulary is shared; language extras are additive.** Node `kind`s, edge list names, edge
`kind`/`prov` values, and the shapes above are identical across analyzers. A language **adds**
kinds (Go `defer_resume` CFG edges, Rust `unsafe` flags, TS `interface`/`enum` types) — recorded
in its `.claude/SCHEMA_DECISIONS.md` — but must **never rename or repurpose** a shared name. This
is what lets the SDK model the schema **once** (one `Node`, one `Edge`, one `Application`), and
what lets the Neo4j schema be a single versioned contract. Hold the parity line, or the whole
one-model premise collapses. This clause is the rule the design loop (`references/schema-design-loop.md`)
enforces node by node.

---

# Part II — the field-by-field appendix

Part I states the model; this part enumerates every node kind's fields and every edge list's
shape. Every node shares the **common node fields**; each kind adds its own. Absent = no fact (no
`null`, except the one sanctioned `callee` slot).

## Common node fields (every node)

| Field | Type | Notes |
| --- | --- | --- |
| `id` | string | Durable `can://…` path (≥ callable) or `…@line:col` / `…@tag` (< callable). See § Identity. |
| `kind` | string | The node-kind (below). Closed vocabulary + additive language kinds. |
| `span` | `{ start:[line,col], end:[line,col], bytes:[from,to] }` | `line:col` addresses/displays; `bytes` slices `module.source`. Absent on some synthetic nodes. |
| `parent` | string | **Only** when the container ≠ the enclosing node (synthetic actuals → their call site; materialized blocks/exprs). Implicit otherwise. |

## Root and container kinds

### `application`
| Field | Type | Level | Notes |
| --- | --- | --- | --- |
| `id` | string | 1 | `can://<lang>/<app>` — the app segment disambiguates apps in one language. |
| `symbol_table` | `{ file → module }` | 1 | Named map, keyed by relative file path (no absolute, no `..`). |
| `call_graph` | `edge[]` | 2 | Cross-function; see § Edges. |
| `param_in` / `param_out` | `edge[]` | 4 | Cross-function; see § Edges. |

Top-level siblings of `application` carry the manifest: `schema_version`, `language`,
`max_level` (authoritative level marker), `k_limit` (present at L4), `analyzer{name,version}`.

### `module` (per-file compilation unit)
| Field | Type | Level | Notes |
| --- | --- | --- | --- |
| `id`, `kind`, `span` | — | 1 | `kind:"module"`. |
| `package` / `namespace` | string | 1 | Language-native grouping the file belongs to. |
| `source` | string | 1 | **The whole file's text, once.** All node text slices from this. |
| `imports` | `import[]` | 1 | `{ name, path, alias?, span }`. |
| `types` | `{ name → type }` | 1 | Named map. |
| `functions` | `{ sig → callable }` | 1 | Module-level callables (Go/Python/C); empty for class-only languages. |
| `content_hash` | string | 1 | For incremental caching; not identity. |

### `type` (`class` \| `struct` \| `interface` \| `enum` \| `trait` \| `type_alias` \| …)
| Field | Type | Level | Notes |
| --- | --- | --- | --- |
| `id`, `kind`, `span` | — | 1 | `kind` is the specific type kind, **not** a pile of `is_*` booleans. |
| `base_types` | `id[]` | 1 | `extends`/embeds — durable ids of supertypes. |
| `interfaces` | `id[]` | 1 | `implements`/satisfies. |
| `modifiers` | `string[]` | 1 | `public`/`abstract`/`sealed`/… (language set). |
| `decorators` | `decorator[]` | 1 | Structured `{ name, args[], span }` — **not** flat strings. |
| `callables` | `{ sig → callable }` | 1 | Methods/constructors. |
| `fields` | `{ name → field }` | 1 | `{ id, kind:"field", type, modifiers[], decorators[], span }`. |
| `nesting` | `{ parent?, is_local? }` | 1 | Nested/inner/local flags as data, not booleans on the node. |

### `callable` (`function` \| `method` \| `constructor` \| `initializer` \| `lambda`)
| Field | Type | Level | Notes |
| --- | --- | --- | --- |
| `id`, `kind`, `span` | — | 1 | `span.bytes` → `get_method_body` = `module.source[bytes]`. |
| `signature` | string | 1 | Human-readable; the *last* path segment of the `id`, from the one `signatureOf()`. |
| `parameters` | `param[]` | 1 | `{ name, type, span, is_variadic? }`, ordered. |
| `return_type` | string | 1 | |
| `error_channel` | `string[]` | 1 | Generalized: Go `(T, error)`, Rust `Result<T,E>`, Java `throws` — one field, not `thrown_exceptions`. |
| `modifiers`, `decorators` | — | 1 | As on `type`. |
| `metrics` | `{ cyclomatic }` | 1 | Extensible metrics map. |
| `refs` | `{ types:[id], fields:[id] }` | 1 | Cheap cross-refs the symbol pass already knows. |
| `body` | `{ local-id → node }` | 1→3 | Holds `call` nodes at L1; completes with all statements at L3. |
| `cfg` / `cdg` / `ddg` / `summary` | `edge[]` | 3–4 | Intra-callable edges (below). |

## Body node kinds (keyed by local id inside `body`)

| kind | Level | Extra fields | Notes |
| --- | --- | --- | --- |
| `call` | **1** | `callee` (id, **`null` until L2/resolver backfill**), `arguments:[local-id]` | Call sites — recorded at L1 so `get_call_sites` is an L1 accessor; `callee` is the one refinement slot. |
| `entry` / `exit` | 3 | — | Synthetic CFG endpoints; one each per callable; no span. |
| `statement` | 3 | — | Ordinary statement; text = `module.source[span.bytes]`. |
| `return` | 3 | — | Edge to `exit`. |
| `branch` / `loop` / `switch` | 3 | — | Control constructs; sources of `cfg` branch edges + `cdg`. |
| `formal_in` | 4 | `of` (param name) | Synthetic; child of the callable; one per formal. |
| `formal_out` | 4 | `of` (`$ret` or a by-ref param) | Synthetic; callable exit. |
| `actual_in` | 4 | `of` (`argN`), `parent` (call-site local-id) | Synthetic; child of a call node. |
| `actual_out` | 4 | `of` (`$ret`), `parent` | Synthetic; child of a call node. |
| `expression` | opt | `expr_kind` | Only with `--materialize-expressions`; carries a `parent`. |
| `block` | opt | — | Only with `--materialize-basic-blocks`; a container between callable and statement. |

## Edges

Every edge is `{ src, dst, …attrs }` where `src`/`dst` are node **ids** (local within a
callable's edge lists; full `can://` ids in the application-scope lists). The **list name is the
type** — there is no `type` field. No dangling endpoints.

| List | Scope (lives on) | Level | Endpoint kinds | Attrs |
| --- | --- | --- | --- | --- |
| `call_graph` | application | 2 | callable → callable | `prov:string[]`, `weight:int` (accumulated on merge) |
| `cfg` | callable | 3 | statement → statement | `kind` (`fallthrough`\|`true`\|`false`\|`switch_case`\|`loop_back`\|`exception`\|`return`\|`break`\|`continue`\|lang-adds) |
| `cdg` | callable | 3 | statement → statement | — (control dependence) |
| `ddg` | callable | 3→4 | statement → statement | `var` (k-limited access path), `prov` (`["ssa"]`=syntactic/L3, `["points-to"]`=semantic/L4) |
| `summary` | callable | 4 | actual_in → actual_out | — (transitive intra-caller) |
| `param_in` | application | 4 | actual_in → formal_in | — |
| `param_out` | application | 4 | formal_out → actual_out | — |

## Language expansion — the rubric

Keep the invariant spine (`application → module → type/callable → body`, identity-only edges,
one `signatureOf()`), then **add** at the leaves. Record every addition in the analyzer's
`.claude/SCHEMA_DECISIONS.md`. The design loop (`references/schema-design-loop.md`) walks this
rubric node by node, with the user.

| Add a new… | How | Example |
| --- | --- | --- |
| **type kind** | new `kind` value on a `type` node | Go `struct`; TS `interface`, `enum`, `type_alias`; Rust `trait` |
| **callable kind** | new `kind` value on a `callable` | closures, getters/setters, `init` blocks |
| **body node kind** | new `kind` value in `body` | Go `select`, Python comprehension scope |
| **CFG edge kind** | new `kind` value on a `cfg` edge | Go `defer_resume`, JS `await_resume`, Python `yield_resume` |
| **typed field** | new field on a node | receiver type, `is_async`/`is_unsafe`, struct tags |
| **open-vocab attr** | a string in `tags{}` | anything not worth a first-class field |

Never: rename a shared field, repurpose a shared `kind`, add a rich-edge variant, or introduce a
node that isn't reachable from `application` by containment. Those break the single-model premise
the whole SDK depends on. The **parity clause** (Part I) is the rule; this table is how you
satisfy it.
