# L4 — interprocedural dataflow (the SDG)

L4 stitches L3's per-callable PDGs into the whole-program **System Dependence Graph**. It is the
**heaviest** level and the seam is real: L4 is the only level that needs the **points-to oracle** and
the **whole-program summary fixpoint**. It builds strictly on L3 (`-a 4` implies `-a 3`) and, like
every level, only *adds*. Read the keystone
(`skills/designing-cldk-changes/references/canonical-schema.md`) for the shape; this guide is the
method.

## What L4 adds (v2 shape)

- **Synthetic parameter vertices** in `body{}` (keyed by `@tag` / `…/tag`):
  - `formal_in` (`of`: param name; child of the callable), `formal_out` (`of`: `$ret` or a by-ref
    param; callable exit);
  - `actual_in` (`of`: `argN`, `parent`: the call-site local-id; child of a `call` node), `actual_out`
    (`of`: `$ret`, `parent`).
- **Edge lists:**
  - **`summary`** — `actual_in → actual_out` at the **same call site**, lives on the **callable**; the
    transitive intra-caller shortcut.
  - **`param_in`** — `actual_in → formal_in`, lives on the **application** (argument into callee).
  - **`param_out`** — `formal_out → actual_out`, lives on the **application** (result back to caller).
- **Semantic `ddg`** — L4 *adds* alias-derived def-use edges tagged **`prov:["points-to"]`** to the
  callable's existing `ddg` list. L3's syntactic `prov:["ssa"]` edges stay untouched.

**Monotonicity subtlety:** L3 emits the syntactic (name-equality, no-alias) def-use — a strict subset
— and L4 **adds** the alias-derived edges. This holds *because* the precision posture is
weak-update / over-approximate (no strong updates through aliases); a strong update would *remove* an
edge and break the additive chain. The `prov` tag makes the syntactic/semantic split visible in the
data. Global/module state is modeled as **extra parameters** (extra formal/actual vertices), so it
rides the same mechanism.

## Step 0 — lock the points-to oracle (the L4 gate slot)

Nothing interprocedural runs without it. Fill this slot (`AskUserQuestion`; record under the README's
Architecture & Tooling heading). The oracle is **frozen** — read its solved state, never fork its
solver — and its API is small: *may-alias(path₁, path₂)* and *points-to(callsite receiver) → targets*.

| Language | Points-to oracle |
| --- | --- |
| **Go** | VTA (`x/tools/go/callgraph/vta`) for dispatch; type-based may-alias MVP, or a native Andersen over `go/ssa`. (`x/tools/go/pointer` is deprecated — don't adopt it) |
| **TypeScript/JS** | **Jelly** (`@cs-au-dk/jelly`) — Andersen-style points-to, pure TS, runs in-process |
| **Java** | WALA pointer analysis (ZeroCFA/ZeroOneCFA). **WALA ships an SDG** (`com.ibm.wala.ipa.slicer`) — Java L4 is largely *exposure + identity-mapping onto v2*, not construction; validate its output against these gates |
| **Python** | Hardest slot: type-guided may-alias from inferred types (imprecise, document it), a native Andersen (significant build), or a type-based MVP stub |
| **Rust** | Type-based (unusually strong — `&mut` is exclusive, so ownership answers many aliasing questions) |
| **C/C++** | Type-based MVP; native Steensgaard is the cheap upgrade |

An MVP may **stub** the oracle with type-based aliasing (two paths may-alias iff their types are
compatible) — sound-leaning but imprecise — and upgrade later as its own PR. An **identity-mapping
layer** onto the canonical `…@line:col` / `@tag` node ids is mandatory and on the critical path; it
is where engine-integration bugs live.

## Construction (stages 5–8, over L3)

### Stage 5 — points-to + the call-graph substrate
Take the L2 `call_graph` (resolver + optional merged framework edges) and **condense it into SCCs
(Tarjan)** — the SCC condensation DAG is the bottom-up processing order. Run the oracle's single
whole-program solve, and map its node identities onto canonical ids.

### Stage 6 — summaries (regions → bottom-up composition → fixpoint)
The scalable alternative to whole-program IFDS — **relational, summary-based** propagation:

- **Hammock regions:** decompose each CFG into single-entry, multi-exit regions; process
  innermost-first; summarize each as labeled edges *entry-facts → exit-facts* (one exit set per exit
  kind: normal/exception/return) plus a read/write footprint; collapse to a single node in the
  enclosing CFG.
- **Function summaries:** compose region summaries bottom-up over the SCC-condensation DAG. At each
  call site, bind formals to actuals via access-path rewriting and splice exits. Within an SCC
  (mutual recursion), iterate to a **monotone fixpoint** — k-limiting (from L3) plus bounded label
  sets is what guarantees termination.
- **External/library code** is modeled as **data** — summaries in the same relational format, shipped
  as a built-in model pack + user config. Unmodeled externals default to conservative pass-through
  (every argument and reachable heap flows to the return and to external state).

**Summary gate:** for a fixture function calling another, the composed summary routes a parameter to
the return value across the call; an SCC of two mutually recursive functions reaches fixpoint
(terminates) and its summary is identical across two runs.

### Stage 7 — SDG assembly
Materialize the synthetic vertices and the cross-function edges (Horwitz–Reps–Binkley): per call site
an `actual_in` per argument and an `actual_out` per return/out-param; per callable `formal_in`/
`formal_out`. Emit `param_in` (actual_in → formal_in), `param_out` (formal_out → actual_out), and the
**`summary`** edges (actual_in → actual_out) that carry Stage 6's transitive flow — they are what make
later slicing/taint context-sensitive without re-descending into callees.

### Stage 8 — the CPG projection
Project the new vertices/edges through the `neo4j/` subpackage — new labels + `PARAM_IN`/`PARAM_OUT`/
`SUMMARY` relationships, same `RowBuilder`/writer machinery, additive `schema.neo4j.json` version bump
(`references/neo4j-projection.md`). The deferred-edge gate enforces no-dangling.

## Provider/client boundary

The analyzer is a **pure graph provider**: L4 emits the dependence-graph substrate — the SDG plus its
transitive `summary` edges — and **stops there**. **Client analyses (taint, slicing, reachability) are
NOT analyzer concerns** — they are reachability *queries* run in the **frontend SDK**
(`cldk-sdk-frontend`) over the emitted graph. The analyzer never emits a `taint_flows` section, never
ingests a sources/sinks/sanitizers policy, and never runs a slice.

Rationale: a taint result is keyed on a *policy* (which APIs are sources/sinks) that evolves at SDK
speed; baking it into the graph would couple the universal artifact to one policy and force a re-emit
on every model-pack edit. What stays analyzer-side is **policy-agnostic substrate** — `summary` edges
are keyed on data dependence, not on any taint config, so they belong in the graph and are exactly
what make the frontend's queries context-sensitive (the two-phase HRB up-then-down traversal over
`cdg ∪ ddg ∪ param_in ∪ param_out ∪ summary`). This is Joern's factoring: the CPG stores the
substrate; `reachableBy` is a query, not materialized all-pairs taint edges.

## Cost controls and flag gating

- **Flag-gated, always.** Nothing at L4 runs unless `-a 4` is requested; `-a 1`/`-a 2`/`-a 3` timings
  must be unaffected, and `-a 3` must not pay L4's summary/points-to cost.
- **k-limiting is mandatory** (the L3 access-path knob) — the interprocedural fixpoint does not
  terminate without it.
- **Summaries are content-hashed and cached** in `cache_dir` from day one; each records the facts it
  depends on (callee summaries, points-to slices, model versions). Incremental re-analysis is
  aspirational, but recording those dependency edges now makes it a switch-flip later.
- **Parallel by construction, deterministic by contract.** Summary composition is a **wavefront**
  (ready-queue / Kahn-style) over the SCC-condensation DAG; the SCC is the atomic unit (its internal
  fixpoint runs on one worker). `-j N` output must be **byte-identical** to `-j 1` — collect, then
  sort; never emit during parallel execution. Watch memory (N workers holding ASTs/CFGs) more than CPU.

## The L4 gate

Run at `-a 4` on the fixture and confirm all of:

- **No dangling endpoints** — every `param_in`/`param_out`/`summary` `src`/`dst` resolves to a real
  node id;
- **`param_in`/`param_out` arity matches** the callable's parameters;
- a **`summary` edge exists for a known transitive flow** (a value flowing `a → b → c` and back);
- the **semantic `ddg`** (`prov:["points-to"]`) edges are present and **added to**, not replacing, the
  L3 `prov:["ssa"]` edges — the L3 ⊆ L4 superset holds;
- output validates against `Application`, and the Neo4j projection at full depth matches (modulo the
  explicit `HAS_*` containment edges).

The **slice and taint gates are frontend gates** — they exercise the SDK's queries over this graph and
live in `cldk-sdk-frontend`, not here. The backend proves the graph is correct; those prove the SDK's
queries over it are. Full gate commands: `references/testing-and-validation.md`.
