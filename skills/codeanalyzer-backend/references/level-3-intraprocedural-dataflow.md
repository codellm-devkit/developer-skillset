# L3 — intraprocedural dataflow

L3 is the first **dataflow** level. It grows the tree **below the callable** — populating the rest of
each callable's `body{}` with statement nodes — and lays three **intra-callable edge overlays** on
top: `cfg`, `cdg`, `ddg` (all **syntactic** at this level: name-equality, no points-to oracle).
Everything here is **AST-only and embarrassingly parallel per callable**, which is exactly why it is
its own shippable level (`-a 3`, implies `-a 2`) and why the seam to L4 is real: L4 is the part that
needs the points-to oracle and whole-program stitching. Read the keystone
(`skills/designing-cldk-changes/references/canonical-schema.md`) for the authoritative shape; this
guide is the construction method that fills it.

## What L3 populates (v2 shape)

- **`body{}` completes.** L1 put the `call` nodes there; L3 adds the remaining statements, keyed by
  **local id** — a source position `line:col` (real nodes) or an `@tag` (synthetic). Statement kinds:
  `statement`, `return`, `branch`/`loop`/`switch`, plus the synthetic **`@entry`/`@exit`** vertices
  (`kind:"entry"`/`"exit"`, one each per callable, no span).
- **Three edge lists on the callable** (endpoints are the `body` local ids — `…@line:col` / `…@tag`,
  **not** `(signature, node)` pairs):
  - **`cfg`** — statement → statement, with a `kind` label: `fallthrough`|`true`|`false`|
    `switch_case`|`loop_back`|`exception`|`return`|`break`|`continue`|language-adds.
  - **`cdg`** — statement → statement control dependence (from post-dominance).
  - **`ddg`** — statement → statement def-use, `var` = a **k-limited access path**, and
    **`prov:["ssa"]`** to mark it **syntactic**. (L4 later *adds* alias-derived edges tagged
    `prov:["points-to"]`; L3 never emits those.)

The DFG is emitted **as the `ddg` edges** — there is no separate section. Both projections are
required: the lists in `analysis.json`, and `CFG_NEXT`/`CDG`/`DDG` relationships plus
`HAS_CFG_NODE`/`HAS_BODY_NODE` ownership in Neo4j (`references/neo4j-projection.md`).

## Step 0 — lock the L3 substrate (the per-language menu)

Before building, fill **two** load-bearing slots (`AskUserQuestion`; record under the README's
Architecture & Tooling heading). These are the L3 half of the substrate menu; the third slot (the
points-to oracle) belongs to L4 (`references/level-4-interprocedural-sdg.md`).

1. **CFG source** — hand-build from the AST (recommended, for control and 1:1 span mapping), or use
   an ecosystem library.
2. **Def-use source** — hand-build reaching definitions, or read an SSA IR the ecosystem hands you.

| Language | CFG | Def-use / SSA |
| --- | --- | --- |
| **Go** | Hand-build from `go/ast` (or `x/tools/go/cfg`) | `go/ssa` — and differential-test your hand-build against it (the stdlib is an answer key) |
| **TypeScript/JS** | Hand-build from the ts-morph AST | Hand-build reaching defs (no usable SSA library) |
| **Java** | WALA IR (already the framework backend) | WALA SSA (free with the IR) |
| **Python** | Hand-build from the AST | Hand-build reaching defs |
| **Rust** | Hand-build from `syn`/rust-analyzer AST | HIR/THIR-level def-use (MIR needs unstable rustc internals — out of scope for a stable analyzer) |
| **C/C++** | libclang CFG (`clang::CFG`) | Hand-build reaching defs over the clang CFG |

## The three first steps (construction, in order; each gated before the next)

The stages are **language-independent** algorithms; what differs per language is the AST→CFG lowering
and the variable-identity model. Work them in order — this is the "CFG substrate first, then DFG over
it, fixtures per construct" ladder.

### Step 1 — build the CFG substrate (the exceptional CFG per callable)

From each callable's AST, build a statement-level CFG into `body` + the `cfg` list:

- One synthetic **`@entry`** and one **`@exit`**. **Multi-exit is normalized**: every `return`/
  `throw`/fall-off-end gets an edge to `@exit` with the right `kind`, so post-dominance has a unique
  root.
- Branches emit `true`/`false`; loops emit `loop_back` for the back edge; `switch`/`match` emit
  `switch_case`.
- **Exceptional edges are not optional.** Every construct that can throw/panic/raise gets an
  `exception` edge to the nearest enclosing handler, or to `@exit` if none. Over-approximate: if you
  can't prove a call doesn't throw, give it the edge.

**Per-construct lowering checklist** — each needs an explicit, documented rule *and a fixture*
exercising it before the CFG gate:

| Language | Constructs needing explicit lowering |
| --- | --- |
| Go | `defer` (runs at every exit), `panic`/`recover`, `go` (the spawned call is a call-site fact, *not* a CFG successor), `select`, labeled break/continue |
| TS/JS | `async`/`await` (`await_resume`), generators (`yield`), `??`/`&&`/`||` short-circuit, `try/catch/finally`, closures (separate CFG per closure) |
| Python | generators/`yield`, comprehensions (implicit loops, own scope), `with` (implicit try/finally), `try/except/else/finally` |
| Java | checked exceptions (edge per `throws` type), `finally` duplication, static/instance initializer blocks, synchronized blocks |
| Rust | `?` (implicit early-return), `match` guards, `panic!`/`unwrap`, drop order at scope exit |
| C/C++ | `goto`/labels, `setjmp`/`longjmp` (document as unsound if unmodeled), C++ destructors at scope exit |

**CFG gate:** every node maps to a real source span; single `@entry`/`@exit`; every node reachable
from `@entry` and reaching `@exit`; each fixture construct produces its documented edges; node count
per callable is stable across two runs on identical content.

### Step 2 — dominance → control dependence (the `cdg` overlay)

- Compute post-dominators on the reverse CFG (Cooper–Harper–Kennedy iterative is ~40 lines and fast
  enough). Infinite loops (`for {}`, `while True`) break post-dominance — add a synthetic edge from
  one loop node to `@exit` first, and document which.
- **Control dependence** (Ferrante–Ottenstein–Warren): for each CFG edge `(a,b)` where `b` does not
  post-dominate `a`, walk from `b` up the post-dominator tree to (not including) `a`'s post-dominator,
  marking each visited node control-dependent on `a`. These are the `cdg` edges.

**Dominance gate:** the post-dominator tree is rooted at `@exit`; hand-computed control dependences
for the fixture's `if`/loop/early-return callables match exactly.

### Step 3 — local def-use → the `ddg` overlay, then assemble the PDG (the L3 gate)

- **Decide the access-path model first** — it is the vocabulary every `ddg.var` is labeled with:
  `base(.field | [*])*` (e.g. `x`, `x.f`, `arr[*]`), **k-limited** (default 3, a CLI knob): `x.f.g.h`
  at k=3 becomes `x.f.g.*` and conservatively aliases deeper paths. Bases are locals, parameters, the
  receiver/`self`, module/global bindings, and captured variables — each tagged.
- Compute **reaching definitions** over the CFG (classic forward may-analysis), or read SSA if the
  ecosystem hands it to you (SSA is an implementation shortcut; the contract is the def-use edges).
  Each `ddg` edge runs def-node → use-node, labeled with the access path, **`prov:["ssa"]`**. Writes
  through aliases are **not** resolved here — that is the L4 points-to refinement.
- **PDG assembly** is bookkeeping: per callable, the PDG *is* `cdg ∪ ddg` over the same `body` nodes.

**L3 gate (the highest-value test in the level):** a **backward intraprocedural slice** — reverse
reachability over `cdg ∪ ddg` — of a named variable at a named line in the fixture equals the
hand-computed node set, **exactly**. Write that expected set into the fixture's test; it catches both
missing control dependences and missing def-use edges. **DFG gate** en route: a loop-carried
dependency (`x = x + 1` in a loop) produces the loop-carried edge; shadowed variables in nested
scopes do not leak edges across scopes.

## Slicing and taint are queries, not L3 output

The analyzer is a **pure graph provider**: L3 emits the `cfg`/`cdg`/`ddg` substrate and stops.
**Backward/forward slicing and taint are reachability *queries* over these edges** and live in the
**frontend SDK** (`cldk-sdk-frontend`), never in the analyzer — do **not** build a slicer or a taint
engine here and do **not** emit a `taint_flows` section. (The full provider/client rationale, and the
`summary` edges that make those queries context-sensitive, are L4 —
`references/level-4-interprocedural-sdg.md`.)

## Determinism and parallelism

Stages 1–4 fan out **per callable** with no cross-function dependency — parallelize with `-j`, but
**`-j N` output must be byte-identical to `-j 1`**: never assign ids or emit during parallel
execution — collect, then sort by node id. Implement sequentially first and use `-j 1` as the
differential oracle forever (`references/testing-and-validation.md`). Ship L3 when its three gates
(CFG, dominance, PDG-slice) pass; L4 waits on the oracle.
