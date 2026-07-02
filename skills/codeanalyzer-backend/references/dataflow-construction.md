# Dataflow construction — the method

The stage-by-stage method for building the level-3 graphs defined in `dataflow-graphs.md`. The
algorithms here are **language-independent** — dominators, control dependence, reaching
definitions, SCC condensation, summary composition are the same in every analyzer. What differs
per language is (a) the AST→CFG lowering rules, (b) the variable-identity/aliasing model, and
(c) the points-to substrate — (c) is a menu decision (`dataflow-substrate-menu.md`); (a) and (b)
have per-language checklists below.

Work the stages **in order** and pass each gate before starting the next — the same
gate discipline as symbol table → call graph. Every stage is testable in isolation against
fixtures, which is what makes this buildable (and learnable) incrementally.

---

## Stage 1 — Exceptional CFG per callable

From the callable's AST, build a statement-level CFG (basic blocks are an optional compression —
statement-level is easier to verify and maps 1:1 to source spans):

- One synthetic `ENTRY` (node 0) and one synthetic `EXIT` (last node). **Multi-exit is
  normalized**: every `return`/`throw`/fall-off-end gets an edge to `EXIT` with the appropriate
  edge kind, so post-dominance has a unique root.
- Edge kinds are the shared vocabulary (`dataflow-graphs.md § graph ladder`). Branches emit
  `true`/`false`; loops emit `loop_back` for the back edge; `switch`/`match` emit `switch_case`.
- **Exceptional edges are not optional.** Every construct that can throw/panic/raise in the
  language gets an `exception` edge to the nearest enclosing handler, or to `EXIT` if none.
  Over-approximate: if you can't prove a call doesn't throw, give it the edge.

**Per-language lowering checklist** — each of these must have an explicit, documented rule (and a
fixture exercising it) before the CFG gate:

| Language | Constructs needing explicit lowering |
| --- | --- |
| Go | `defer` (runs at every exit — model as edges from each exit-bound node through the deferred calls to `EXIT`), `panic`/`recover`, `go` statement (the spawned call is a `CALL`-site fact, *not* a CFG successor), `select`, labeled break/continue |
| TS/JS | `async`/`await` (`await_resume` edge), generators (`yield` edge kinds), optional chaining and `??`/`&&`/`||` short-circuit (implicit branches), `try/catch/finally` (finally duplication or region splicing), closures (separate CFG per closure; capture is a DFG concern) |
| Python | generators/`yield`, comprehensions (implicit loops — own scope), `with` (implicit try/finally), `try/except/else/finally`, decorators (call-site fact, not CFG) |
| Java | checked exceptions (edge per `throws`-declared type), `finally` duplication, static/instance initializer blocks (own CFGs), synchronized blocks |
| Rust | `?` operator (implicit early-return branch), `match` guards, `panic!`/`unwrap` paths, drop order at scope exit (the `Drop` analog of `defer`) |
| C/C++ | `goto`/labels, `setjmp`/`longjmp` (document as unsound if unmodeled), destructor runs at scope exit (C++) |

**CFG gate:** every node maps to a real source span; single `ENTRY`/`EXIT`; every node is
reachable from `ENTRY` and reaches `EXIT`; each fixture construct in the table above produces its
documented edges; total node count per function is stable across two runs on identical content.

## Stage 2 — Dominators, post-dominators, control dependence

- Compute dominators and (on the reverse CFG) post-dominators. The **Cooper–Harper–Kennedy
  iterative algorithm** is ~40 lines and fast enough; Lengauer–Tarjan only if profiling demands.
- Infinite loops (`for {}`, `while True:`) break post-dominance — add a synthetic edge from one
  loop node to `EXIT` first (document which node).
- **Control dependence** via Ferrante–Ottenstein–Warren: node *n* is control-dependent on branch
  node *b* iff *b*'s post-dominance frontier contains... practically: compute the post-dominator
  tree, then for each CFG edge `(a, b)` where *b* does not post-dominate *a*, walk from *b* up
  the post-dominator tree to (but not including) *a*'s post-dominator, marking each visited node
  control-dependent on *a*. These are the `CDG` edges.

**Dominance gate:** post-dominator tree is a tree rooted at `EXIT`; hand-computed control
dependences for the fixture's `if`/loop/early-return functions match exactly.

## Stage 3 — Variable identity and local def-use (the DFG)

Decide the **access-path model** first — it is the vocabulary every `DDG` edge is labeled with:

- An access path is `base(.field | [*])*` — e.g. `x`, `x.f`, `x.f.g`, `arr[*]` (all indices
  collapse to `[*]`). Depth is **k-limited** (default 3): `x.f.g.h` with k=3 becomes `x.f.g.*`,
  which then conservatively aliases every deeper path.
- Bases are: locals, parameters, the receiver/`this`/`self`, module/global bindings, and
  captured variables (closures) — each tagged with which it is.

Then compute def-use:

- **Reaching definitions** over the CFG (classic forward may-analysis, worklist over basic
  blocks), or SSA construction if the ecosystem hands it to you (`go/ssa`, WALA IR) — SSA is an
  implementation shortcut, the *contract* is the def-use edges.
- A `DDG` edge runs def-node → use-node labeled with the access path. Writes through aliases are
  handled in Stage 5 (until then, a write to `p.f` where `p` may alias `q` does **not** yet kill
  or reach `q.f` — that's the points-to refinement).

**DFG gate:** every `DDG` edge connects a node that syntactically writes the path to a node that
syntactically reads it; a fixture with a loop-carried dependency (`x = x + 1` in a loop) produces
the loop-carried edge; shadowed variables in nested scopes do not leak edges across scopes.

## Stage 4 — PDG assembly

Per callable: `PDG = CDG edges (stage 2) + DDG edges (stage 3)`, over the same
`(signature, node_id)` nodes. Nothing new is computed — this stage is bookkeeping plus the gate:

**PDG gate:** a **backward intraprocedural slice** (reverse reachability over CDG ∪ DDG) of a
named variable at a named line in the fixture equals the hand-computed node set, exactly. Write
this expected set down in the fixture's test — it is the single highest-value test in the whole
level, and it is the gate that catches both missing control dependences and missing def-use
edges.

## Stage 5 — Points-to and the call-graph substrate

Interprocedural work needs two oracles, both **frozen** (read their answers; never fork their
internals):

1. **The call graph** — already built (level 1 resolver + optional level 2 framework edges,
   provenance-merged). Condense it into **SCCs (Tarjan)**; the SCC condensation DAG is the
   bottom-up processing order for Stage 6.
2. **Points-to / aliasing** — the per-language substrate decision (`dataflow-substrate-menu.md`).
   The required API is small: *may-alias(path₁, path₂)* and *points-to(callsite receiver) →
   possible targets*. An MVP may stub this with type-based aliasing (two paths may alias iff
   their types are compatible) — **sound-leaning but imprecise**; upgrade to the real substrate
   as a later PR (the issue template stages it exactly so).
3. **Identity mapping** — whatever node identities the oracle uses (source locations, its own IR)
   must be mapped onto canonical `(signature, node_id)` keys. Budget real time for this layer;
   it is on the critical path of every downstream stage and is where engine-integration bugs
   live.

## Stage 6 — Summaries: regions, bottom-up composition, fixpoint

The scalable alternative to whole-program IFDS: **relational, summary-based** propagation
(this is the design locked in codeanalyzer-typescript issue #2, generalized):

- **Hammock regions:** decompose each CFG into single-entry, multi-exit regions (loop bodies,
  conditional arms, try blocks). Process innermost-first; summarize each region as labeled edges
  *entry-facts → exit-facts* (one exit set per distinct exit kind: normal, exception, return),
  plus a global read/write footprint. Collapse the summarized region to a single node in the
  enclosing CFG, splicing exceptional exits to the nearest handler or propagating outward.
- **Function summaries:** compose region summaries bottom-up over the SCC-condensation DAG. At
  each call site, apply the callee's summary by binding formals to actuals via access-path
  rewriting and splicing exits. Within an SCC (mutual recursion), iterate all members' summaries
  to a **monotone fixpoint** — k-limiting (Stage 3) plus bounded label sets is what guarantees
  termination.
- **Globals/module state:** reads and writes of module bindings, singletons, and exported
  mutables become extra summary inputs/outputs (extra parameters in SDG terms).
- **External/library code:** modeled as **data** — summaries in the same relational format,
  shipped as a built-in model pack + user config. Unmodeled externals default to conservative
  pass-through: every argument and reachable heap flows to the return value and to external
  state. (Over-approximate by design; see the precision posture in `dataflow-graphs.md`.)

**Summary gate:** for a fixture function calling another fixture function, the composed summary
routes a parameter to the return value across the call; an SCC of two mutually recursive
functions reaches fixpoint (terminates) and its summary is identical across two runs.

## Stage 7 — SDG assembly

Stitch the PDGs with the interprocedural edges (Horwitz–Reps–Binkley):

- Per call site: an **actual-in** node per argument and **actual-out** per return/out-param; per
  callable: **formal-in**/**formal-out** nodes. Edges: `CALL` (callsite → callee ENTRY),
  `PARAM_IN` (actual-in → formal-in), `PARAM_OUT` (formal-out → actual-out).
- **SUMMARY edges** (actual-in → actual-out at the same call site) encode the callee's transitive
  flow from Stage 6 — they are what make later slicing/taint context-sensitive without
  re-descending into callees.
- Globals ride the same mechanism as extra formals/actuals.

**SDG gate:** the assertions in `dataflow-graphs.md § Verification gates` — no dangling
`(signature, node_id)` endpoints, arity match, at least one SUMMARY edge for a known transitive
flow, and the whole `program_graphs` section validates against the SDK models.

## Stage 8 — Clients and the CPG

- **Slicing and taint** as SDG queries (`dataflow-graphs.md § Client analyses`) — the two-phase
  HRB traversal for context-sensitive slices; labeled reachability with sanitizer blocking for
  taint; witness paths reconstructed lazily over reverse edges.
- **CPG:** project the new node/edge families through the existing `neo4j/` subpackage —
  new labels in the schema catalog, same `RowBuilder`/writer machinery, additive
  `schema.neo4j.json` version bump. The deferred-edge gate already enforces no-dangling.

**Client gate:** the slice and taint assertions from `dataflow-graphs.md § Verification gates`,
plus: the Cypher snapshot with graphs enabled loads clean into an empty Neo4j and a
`MATCH (:CFGNode)` count equals the JSON node count.

---

## Parallel execution model

Level 3 is compute-heavy but its dependency structure is explicit — exploit it. The units of
work and their independence, per phase:

| Phase | Unit of work | Parallelism |
| --- | --- | --- |
| Stages 1–4 (CFG, dominance, def-use, PDG) | one callable | **Embarrassingly parallel** — no cross-function dependencies; fan out over a worker pool |
| Stage 5 points-to solve | whole program | Usually the **sequential bottleneck** — the oracle is a black box; run its single whole-program solve *concurrently with* stages 1–4 (they don't need it) and join before stage 6 |
| Stages 6–7 (summaries → SDG) | one SCC | **Wavefront over the condensation DAG** (below) |
| Stage 8 clients | one query / taint seed | Independent queries in parallel |
| Emission / CPG rows | one module | Per-worker row builders, merged; deterministic sort at the end |

**Wavefront (level-order) scheduling of the SCC DAG.** Summary composition processes the
condensation DAG in reverse topological order; an SCC is *ready* when every callee SCC is
summarized. Two implementations:

- **Level barriers:** define height *h* = longest path to a leaf; process all SCCs of height
  *h* in parallel, barrier, proceed to *h+1*. Simple, and the levels make a natural progress
  display.
- **Ready queue (preferred):** per-SCC dependency counters (Kahn-style); when a summary
  completes, decrement its dependents and enqueue any that hit zero. Strictly more parallelism —
  nothing waits on a level's slowest SCC without a true dependency.

The SCC is the atomic unit either way: its internal fixpoint (mutually recursive members,
co-defined summaries) runs on one worker.

**Determinism is a hard requirement.** `--jobs N` must produce **byte-identical** output to
`--jobs 1`:

- The monotone framework already guarantees the *fixpoint* is schedule-independent (joins
  commute); what varies under parallelism is *discovery order*. So never assign ids or emit
  during parallel execution — collect, then sort by `(signature, node_id)` (the same
  collect-then-sort rule the Neo4j `RowBuilder` follows).
- **Implement sequentially first.** Pass every gate at `--jobs 1`, then parallelize using the
  sequential output as the differential oracle. `--jobs 1` remains the debug mode forever.
- Cache writes (content-hashed summaries) must be idempotent per key — two workers producing
  the same summary is a benign race, not a conflict.
- Watch memory, not just CPU: N workers each holding function ASTs/CFGs is the real ceiling;
  release per-callable structures once the PDG is emitted.

**Per-language mechanisms:** Go goroutines + `errgroup` (the ready-queue scheduler is ~50 lines
and a good exercise in its own right); Rust `rayon`; Java `ForkJoinPool` / parallel streams;
TS/JS `worker_threads` (Bun workers) — summaries must serialize cheaply across the
structured-clone boundary; Python `multiprocessing` or Ray — `codeanalyzer-python` already
exposes `use_ray` for exactly this shape of fan-out.

Note the same structure exists at **level 1**: the per-file symbol-table build is independent
per file, so the `-j/--jobs` flag (`cli-contract.md`) is not level-3-specific.

## Fixture minimums (extends `testing-and-validation.md § 1`)

The level-3 fixture must contain, each with a named expected result in the tests:

- an `if/else` and a loop (control dependence + loop-carried DDG edge);
- an early return and a throw/panic/raise with a handler (exceptional CFG + multi-exit);
- a closure or nested function capturing a local (capture edges);
- **aliasing**: two names for one object, a write through one, a read through the other;
- a call chain `a → b → c` where a value flows from `a`'s argument to `c` and back (SUMMARY
  edges, PARAM_IN/OUT);
- mutual recursion (SCC fixpoint termination);
- a module-level/global variable written in one function, read in another;
- a **multi-file** flow (cross-module SDG edges);
- one source→sink taint flow, and the same flow with a sanitizer interposed;
- each language-specific lowering construct from the Stage-1 checklist.

## Order of implementation (and of learning)

The stages are deliberately sequenced so each is testable before the next exists: CFG (1) and
dominance (2) need no dataflow; def-use (3) needs no interprocedural anything; the PDG slice gate
(4) is the checkpoint that the intraprocedural half is *right*; points-to (5) can start as a
type-based stub; summaries (6–7) are where the whole-program complexity lives; clients (8) are
queries. An MVP that stops after Stage 4 + a call-graph-only taint approximation is already
useful and shippable behind the flag — stage the rest as the issue template's PR ladder.
