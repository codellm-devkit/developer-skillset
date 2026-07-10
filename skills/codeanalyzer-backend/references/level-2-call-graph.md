# L2 — the call graph

L2 is a **pure refinement + one edge family** over the L1 tree
(`skills/designing-cldk-changes/references/canonical-schema.md`): it grows no depth. It does two
things, and only two:

1. **Backfill `callee`** on each `call` node recorded at L1 — `null → id` — the *one* sanctioned
   mutation in the whole additive paradigm (null-to-value only, never value-to-different-value).
2. **Emit the `call_graph` edge list** at the **application scope**: one `{ src, dst, prov[], weight }`
   record per resolved call, both endpoints **callable ids**.

`call_graph` lives on the `application` (it is a cross-callable overlay; intra-callable edges live on
the callable). `-a 2` implies `-a 1`. Nothing here rewrites an L1 fact — spans, ids, and the tree are
untouched.

## Resolver-based construction (the default)

The **same resolver already loaded for the tree** (`references/tooling-menu.md` slot 3) resolves the
call nodes. For each `call` node:

- Map the callee expression to a declaration; if it resolves, **set `callee` to that callable's `id`**
  and emit a `call_graph` edge `{ src: <caller id>, dst: <callee id>, prov: ["<resolver>"], weight: 1 }`
  (e.g. `prov:["tsc"]`, `["go/types"]`, `["jedi"]`).
- **Never mutate the tree beyond filling `callee`.** `call_graph` edges are **immutable once
  written** — they are never re-anchored to a statement at L3.

### Dispatch / virtual-call handling

- **Constructors / `new`**: resolve to the constructor/initializer callable.
- **Method dispatch via receiver type**: resolve through the receiver's static type.
- **Virtual / polymorphic dispatch**: decide how far to expand, and **make it a recorded decision**
  (`AskUserQuestion`) — declared type only ≈ CHA; declared type + instantiated subtypes ≈ RTA-style.
  Record the choice in `.claude/SCHEMA_DECISIONS.md` / the README's Architecture & Tooling block.
- **Unresolved sites**: an **explicit fallback** — keep the `call` node (with `callee` still `null`),
  **skip the edge**, and **never crash**. A partial graph with honest gaps beats an exception.

Precision follows the type system: exact for static/monomorphic dispatch, over-approximate and
flagged for the dynamic cases. The precision posture is **sound-leaning** — prefer a false edge to a
missed one; precision is recovered downstream by SDK ranking/pruning. Document known unsoundness
(reflection, `eval`, monkey-patching, unmodeled natives) per language in the analyzer README.

## Framework enrichment (flag-gated, an orthogonal axis — NOT a level)

A dedicated engine (WALA RTA over bytecode, Joern over a CPG, SVF/Phasar Andersen points-to) catches
indirect/dynamic dispatch the resolver missed. Its edges **merge into the *same* `call_graph` list** —
match by `(src, dst)`, **union the `prov`**, **accumulate `weight`** — exactly the resolver∪framework
merge in `codeanalyzer-python`'s core. This is the **orthogonal precision axis**, not a new level:
`max_level` stays 2. Gate it behind a flag (`--joern`/…) so the cheap path stays cheap, and isolate
the engine in its own subpackage (`references/analyzer-architecture.md` rule 3), scaffolded even when
it ships stubbed. (The one exception is a language like Java whose *only* call graph is WALA's — there
the framework engine effectively *is* the L2 producer.)

## Both projections

Emit L2 in **both** surfaces: the `call_graph` list in `analysis.json`, and the corresponding `CALLS`
relationships (with `weight`/`prov` props) plus `RESOLVES_TO` in the Neo4j projection
(`references/neo4j-projection.md`). The graph's **deferred-edge rule** is the same "edge only when
resolved" invariant: `CALLS`/`RESOLVES_TO` never dangle; the unresolved string fallback rides on the
source node's props.

## The L2 gate

Run the analyzer at `-a 2` on the fixture and confirm all of:

- **No dangling endpoints** — every edge `src` and `dst` resolves to a real callable id in the symbol
  table (`for e in call_graph: assert e.src in all_sigs and e.dst in all_sigs`);
- every edge has a **non-empty `prov`** naming the resolver;
- **`callee` is backfilled** (non-null id) on successfully resolved call sites, and still `null` on
  the honest-unresolved ones;
- a **named expected edge** is present — assert the exact `(src, dst)` pair, not just "graph
  non-empty" (a graph of only stdlib edges validates the shape but not correctness);
- at least one **cross-package / cross-module** edge is present;
- output still validates against `Application`, and the L1 ⊆ L2 superset holds (nothing L1 emitted
  changed except the `callee` backfill).

Only when this is green do you advance to L3 (`references/level-3-intraprocedural-dataflow.md`). Full
gate commands: `references/testing-and-validation.md`.
