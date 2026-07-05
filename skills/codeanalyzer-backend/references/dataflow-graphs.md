# Dataflow graphs (levels 3–4) — the contract

The two dataflow levels: **native dependence graphs** built from the language's own AST in the
analyzer's own ecosystem — **level 3 intraprocedural** (CFG, DFG, PDG per function) and **level 4
interprocedural** (the whole-program SDG, plus client queries: slicing, taint). This file is the
**contract** (what the graphs are, how they're keyed, emitted, and verified). The construction
method lives in `dataflow-construction.md`; the per-language engine decisions in
`dataflow-substrate-menu.md`; the issue template for planning the work in
`dataflow-issue-template.md`.

**Native is the defining constraint.** Levels 3–4 are built from the language's own AST/compiler
API (ts-morph/Babel for TS, `go/ast` for Go, tree-sitter+Jedi-adjacent for Python, JavaParser/WALA
IR for Java) — *not* by shelling out to an external engine like Joern. Those engines remain the
separate **level-2 framework axis** and are unchanged by this contract. A points-to *oracle*
library that runs in-process in the analyzer's own language (Jelly, WALA, `go/ssa`) counts as
native.

## Position in the level ladder

The levels are **progressive population of one structure** (the containment tree + typed edge
overlays), each additive over the last — `L1 ⊆ L2 ⊆ L3 ⊆ L4`, superset modulo null-refinement.
The seam between 3 and 4 is real, not cosmetic: it is the **substrate + cost boundary** — L3 needs
nothing but the AST and is embarrassingly parallel per callable; L4 needs the points-to oracle and
the whole-program summary fixpoint.

| Level | What | Grows | Cost / substrate | Flag |
| --- | --- | --- | --- | --- |
| 1 | Symbol table + resolver call graph | tree to `function` depth + `calls` edges | Cheap, AST + resolver | `-a 1` / `-a 2` (default 1) |
| 2 | Framework-based call-graph enrichment (Joern/WALA) | more `calls` edges (provenance-merged) | Heavy, external | own toggle, off by default |
| **3** | **Native intraprocedural graphs (CFG / DFG / PDG per function)** | tree *below* `function` + within-function edges | Heavy but **AST-only, per-callable parallel** | `-a 3` (+ `--graphs`) |
| **4** | **Native interprocedural graph (SDG) + clients (slicing, taint)** | cross-function `PARAM_*` / `SUMMARY` edges | Heaviest: **needs the points-to oracle** + summary fixpoint | `-a 4` |

`-a 3` implies `-a 2`'s resolver call graph; `-a 4` implies `-a 3` (the SDG stitches L3's PDGs).
The framework toggle stays orthogonal — its edges merge into the call graph with provenance,
exactly as at level 2. The cheap path stays cheap: **nothing at level 3 or 4 runs unless
requested.** A language can ship L3 with **zero oracle work** and add L4 when its points-to
substrate (`dataflow-substrate-menu.md`) lands.

The levels gate the **JSON path only**. When the output target is the graph (`--emit neo4j`),
levels don't apply: the analyzer runs at maximum implemented depth and projects the **full SDG**
unconditionally (`neo4j-projection.md § Depth rule`).

## The graph ladder (definitions and edge vocabulary)

Each graph builds on the previous. Graphs **1–3 are level 3** (per-function, AST-only); the
**SDG (4) is level 4** (whole-program, needs the oracle), as is the CPG projection.

1. **CFG (control-flow graph)** — statement/basic-block-level nodes, one graph per callable, with
   a single synthetic `ENTRY` and single synthetic `EXIT`. Edges are `CFG_NEXT` with a `kind`
   label: `fallthrough`, `true`, `false`, `switch_case`, `loop_back`, `exception`, `return`,
   `break`, `continue`, `yield`, `await_resume`. Exceptional edges are first-class — a CFG that
   ignores throw/panic paths fails the gate.
2. **DFG (data-flow graph)** — def-use edges over the CFG: `DDG` edges labeled with the variable
   (an access path, k-limited — see `dataflow-construction.md § k-limiting`). Built from reaching
   definitions or SSA (SSA is an implementation detail; the contract is def-use edges).
3. **PDG (program dependence graph)** — per-function union of control dependence (`CDG` edges,
   computed from the post-dominance frontier) and data dependence (`DDG` edges).
4. **SDG (system dependence graph)** — **level 4**, the whole-program graph: all PDGs stitched
   together at call sites via `CALL`, `PARAM_IN`, `PARAM_OUT`, and transitive `SUMMARY` edges
   (Horwitz–Reps–Binkley). Global/module state is modeled as extra parameters. This is the first
   rung that needs the points-to oracle and the interprocedural summary fixpoint, and the graph
   client analyses (slicing, taint) query.

## Node identity (the invariant that makes everything joinable)

Every graph node is keyed by **`(signature, node_id)`**:

- `signature` — the owning callable's canonical signature, the *same* `signatureOf()` key used by
  `symbol_table` and `call_graph`. This is non-negotiable: it is what lets the SDK join a PDG
  node back to its `Callable`, and what lets SDG edges reference call-graph edges.
- `node_id` — a small integer, stable across runs on identical content: the index of the owning
  AST node in **source-span order** within the callable (synthetic `ENTRY` = 0, `EXIT` = last).
  Every node also carries `start_line`/`end_line` (and column when available) so a node maps back
  to source.

Cross-function edges (`CALL`, `PARAM_IN/OUT`, `SUMMARY`) reference both endpoints by
`(signature, node_id)`. **No dangling endpoints** — the same rule as the call graph: every
referenced signature exists in the symbol table, every referenced node_id exists in that
function's emitted graph.

## Emission — where the graphs live in the tree

> **Schema v2 supersedes the standalone `program_graphs` section below.** In the canonical schema
> (`canonical-schema.md`), dataflow is **not** a separate top-level object — it grows *inside the
> tree*: each callable gains a `body{}` map of statement/vertex nodes plus the intra-callable edge
> lists `cfg`/`cdg`/`ddg`/`summary`, and the application gains the cross-callable `param_in`/
> `param_out` lists. Node endpoints are `can://…@line:col` ids, not `(signature, node)` pairs.
> Read `canonical-schema.md` for the authoritative shape; the ladder, gates, and construction
> stages in this file are shape-agnostic and still govern. The block below is retained only as the
> conceptual node/edge inventory (kinds, `cfg`/`pdg`/`sdg` families) — map it onto the v2 tree.

Historically graphs were a top-level `program_graphs` object; the families (CFG, PDG = CDG+DDG,
SDG) and their level assignment are unchanged, only their placement:

```jsonc
{
  "symbol_table": { ... },
  "call_graph": [ ... ],
  "program_graphs": {                    // functions{}: -a 3 and up; sdg_edges: -a 4
    "schema_version": "1.0.0",
    "max_level": 3,                      // highest level actually populated here (3 or 4)
    "k_limit": 3,
    "functions": {                       // LEVEL 3 — per-function, AST-only
      "<signature>": {
        "cfg":  { "nodes": [{ "id": 0, "kind": "entry", "start_line": ... }, ...],
                  "edges": [{ "source": 0, "target": 1, "kind": "fallthrough" }, ...] },
        "pdg":  { "edges": [{ "source": 4, "target": 9, "type": "CDG" },
                            { "source": 2, "target": 7, "type": "DDG", "var": "x.f" }, ...] }
      }
    },
    "sdg_edges": [                       // LEVEL 4 — cross-function only; intra-function edges live in pdg
      { "source": { "signature": "...", "node": 12 },
        "target": { "signature": "...", "node": 0 },
        "type": "PARAM_IN", "var": "arg0" }
    ]
  },
  "taint_flows": [ ... ]                 // LEVEL 4 client-analysis output, see below
}
```

- The **level split is a data split**: `-a 3` emits `functions` (CFG/PDG) and *omits* `sdg_edges`
  and `taint_flows`; `-a 4` adds them. `max_level` declares which was populated so a consumer
  reads it instead of sniffing for `sdg_edges`.
- `--graphs cfg,dfg,pdg,sdg` further scopes *within* the requested level (default: all rungs at or
  below the level). `sdg` requires `-a 4`; requesting it at `-a 3` is a flag error. DFG is emitted
  *as* the `DDG` edges of the PDG — there is no separate `dfg` section; requesting `dfg` without
  `pdg` emits a PDG with only `DDG` edges.
- Unrecognized `--graphs` values follow the **flag-validation rule** (`cli-contract.md`): explicit
  non-zero error, never silent fallback.
- The CPG is **Neo4j-only**, and the graph surface is **level-agnostic**: `--emit neo4j` always
  runs at maximum implemented depth and projects the full SDG — `-a` and `--graphs` gate only
  the JSON path, and combining them with `--emit neo4j` is an explicit error
  (`neo4j-projection.md § Depth rule`). `--emit schema` includes the CFG/PDG/SDG labels in
  `schema.neo4j.json`.
- `program_graphs.schema_version` is versioned independently of the top-level schema and bumps
  additively, like `schema.neo4j.json`.

## Client analyses are queries, not engines

Slicing and taint are **reachability queries over the SDG**, not separate analyses:

- **Backward slice** of `(signature, node)`: reverse reachability over `CDG ∪ DDG ∪ PARAM_* ∪
  SUMMARY` (context-sensitive via the two-phase HRB traversal — up then down).
- **Taint**: seed at *sources*, propagate labeled reachability along dependence edges, block at
  *sanitizers* on the path, report when a source label reaches a matching *sink*. Sources, sinks,
  sanitizers, and library models are **data, not code** — a JSON spec validated against a JSON
  Schema, with precedence *built-in pack < config file < inline flags*. Output is the
  `taint_flows` section: `{ source, sink, rule, sanitized, path }`, each path a list of
  `(signature, node_id)` pairs, with the matching model id for explainability.

## Cross-language parity clause

Same rule as the canonical schema: **the graph vocabulary is shared; language extras are
additive.**

- Node `kind` values, edge `type`/`kind` values, and the JSON shapes above are identical across
  analyzers. A language may **add** kinds (e.g. Go `defer_resume`, JS `await_resume`, Python
  `yield_resume` CFG-edge kinds) — recorded in `SCHEMA_DECISIONS.md` like any schema expansion —
  but may not rename or repurpose the shared ones.
- The SDK models this section **once** (`ProgramGraphs`, `FunctionGraphs`, `GraphNode`,
  `GraphEdge`, `SDGEdge`, `TaintFlow` — shared across languages, not per-`<L>` copies), which is
  only possible if the analyzers hold the parity line.

## Precision posture (shared, non-negotiable)

The analysis is **sound-leaning and over-approximate**: prefer false positives to missed flows.
Precision is recovered downstream by ranking/pruning — the engine must not trade soundness for a
lower false-positive rate. Known unsoundness (dynamic eval, reflection, monkey-patching,
unmodeled natives) is **documented per language** in the analyzer README, not silently absorbed.

## Verification gates (summary — full assertions in `dataflow-construction.md § Gates`)

Each rung has a gate; do not build the next rung until the current one passes:

| Level | Gate | Core assertion |
| --- | --- | --- |
| 3 | CFG | Every node maps to a real source span; single ENTRY/EXIT; every node reachable from ENTRY and reaching EXIT; exceptional edges present for every throwing construct in the fixture |
| 3 | Dominance | Post-dominator tree well-formed (unique root = EXIT; infinite loops handled via synthetic edge) |
| 3 | PDG | CDG edges match hand-computed control dependence on the fixture; every DDG edge connects a real def to a real use of the same access path |
| 4 | SDG | No dangling `(signature, node_id)` endpoints; PARAM_IN/OUT arity matches the callable's parameters; SUMMARY edges exist for at least one transitive flow in the fixture |
| 4 | Slice | Backward slice of a named fixture variable equals the hand-computed expected node set — **exact**, not "non-empty" |
| 4 | Taint | One known source→sink flow found; the same flow with a sanitizer on the path is reported `sanitized` |

The **L3/L4 gate boundary** is the intraprocedural backward-slice: it is checkable *within* a
single function (level 3 done), whereas the SDG/Slice/Taint gates need whole-program stitching
(level 4). Ship L3 when its three gates pass; L4 waits on the oracle.

The fixture minimums that make these gates meaningful (branches, loops, exception paths,
closures, aliasing, recursion, a multi-file flow) are specified in
`dataflow-construction.md § Fixture minimums` and extend `testing-and-validation.md § 1`.

## CPG in the Neo4j projection

New node labels and edge types, added to `schema.neo4j.json` (additive version bump), all carried
by the same `GraphRows`/writer machinery in `neo4j-projection.md`:

- **Labels:** `CFGNode` (merge key `id` = `<signature>#<node_id>`, props: `kind`, `start_line`,
  `end_line`, `_module`).
- **Edge types:** `CFG_NEXT` (prop `kind`), `CDG`, `DDG` (prop `var`), `PARAM_IN`, `PARAM_OUT`,
  `SUMMARY`, and `HAS_CFG_NODE` (Callable → CFGNode ownership).
- The AST layer of the CPG is the existing symbol-table projection; the overlay is complete when
  a Callable's `CFGNode`s, its `CDG`/`DDG` edges, and the cross-function SDG edges are all
  present and the deferred-edge gate (no dangling endpoints) holds.

## Performance and incrementality rules

- **Flag-gated, always.** Level 3 (per-function graphs) is heavy but parallel; level 4
  (whole-program summary construction) may be orders of magnitude slower again. `-a 1`/`-a 2`
  timings must be unaffected, and `-a 3` must not pay L4's summary/points-to cost.
- **Summaries are content-hashed and cached** in `cache_dir` from day one, and every summary
  records the facts it depends on (callee summaries, points-to slices, model versions).
  Incremental re-analysis is *aspirational, not initial scope* — but recording dependency edges
  now is what makes it a switch-flip later instead of a rewrite.
- **k-limiting is mandatory** (access-path depth, CLI knob e.g. `--graph-field-depth`, default 3)
  — the interprocedural fixpoint does not terminate without it.
- **Parallel by construction, deterministic by contract.** Intraprocedural stages fan out per
  callable (embarrassingly parallel); the points-to solve runs concurrently with them; summary
  composition is a wavefront (ready-queue) over the SCC condensation DAG. `--jobs N` output must
  be **byte-identical** to `--jobs 1` — collect-then-sort, never emit during parallel execution.
  Full model: `dataflow-construction.md § Parallel execution model`.
