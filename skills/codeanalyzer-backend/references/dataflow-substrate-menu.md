# Dataflow substrate menu (per-language, level 3)

The level-3 counterpart of `tooling-menu.md`: the **native substrate decisions** each language
must make before building the graphs in `dataflow-construction.md`. Like the level-1 menu,
pre-fill a recommendation per slot and confirm with the user (`AskUserQuestion`) — these are
load-bearing, locked decisions recorded in the analyzer README's *Architecture & Tooling*
section.

**The three slots:**

1. **CFG source** — hand-build from the AST, or use an ecosystem library?
2. **Def-use source** — hand-build reaching definitions, or read an SSA IR?
3. **Points-to oracle** — which in-process engine answers *may-alias* / *dispatch targets*?
   (An MVP may stub this with type-based aliasing and upgrade later — stage it as its own PR.)

Whatever is chosen: the oracle is **frozen** (read its solved state, never fork its solver), and
an **identity-mapping layer** onto canonical `(signature, node_id)` keys is mandatory and on the
critical path (`dataflow-construction.md § Stage 5`).

## Per-language recommendations

| Language | CFG | Def-use / SSA | Points-to oracle | Notes |
| --- | --- | --- | --- | --- |
| **Go** | Hand-build from `go/ast` (recommended for control), or `golang.org/x/tools/go/cfg` | `go/ssa` (x/tools) | VTA (`x/tools/go/callgraph/vta`) for dispatch; type-based may-alias MVP, or a native Andersen over `go/ssa` | The stdlib is an **answer key**: hand-build each rung and differentially test against `go/cfg`/`go/ssa` output. `x/tools/go/pointer` is deprecated — don't adopt it |
| **TypeScript/JS** | Hand-build from ts-morph AST | Hand-build reaching defs (no usable SSA library) | **Jelly** (`@cs-au-dk/jelly`) — Andersen-style points-to + call graph, pure TS, runs in-process under `bun --compile` (verified; see the `bun patch` caveat in codeanalyzer-typescript issue #2) | Two parsing foundations (tsc type-aware vs Jelly's Babel) must be reconciled in the identity map. Flow-sensitive on locals, heap capped by Jelly's flow-insensitive solve |
| **Java** | WALA IR (already the level-2 backend) | WALA SSA (free with the IR) | WALA's pointer analysis (ZeroCFA/ZeroOneCFA) | **WALA ships an SDG implementation** (`com.ibm.wala.ipa.slicer`) — the Java work is largely *exposure and identity-mapping onto the canonical schema*, not construction. Validate its output against the same gates rather than rebuilding |
| **Python** | Hand-build from the AST (`ast` module / tree-sitter) | Hand-build reaching defs | Hardest slot: no Jelly-equivalent. Options: (a) type-guided may-alias from inferred types (Jedi/pyright output) — imprecise, document as such; (b) a native Andersen over your own AST — significant build; (c) type-based MVP stub | Dynamic typing makes this the weakest-oracle language; lean on the conservative-default posture and models-as-data. Do **not** start learning here |
| **Rust** | Hand-build from `syn`/`rust-analyzer` AST | Prefer HIR/THIR-level def-use; **MIR access requires unstable rustc internals** — treat MIR-based dataflow as out of scope for a stable analyzer | Type-based MVP; borrow-checker facts are not exposed stably | The ownership system means many aliasing questions are answerable from types alone (`&mut` is exclusive) — a type-based oracle is unusually strong here |
| **C/C++** | libclang CFG (`clang::CFG` via bindings) | Hand-build reaching defs over clang CFG | Type-based MVP; a native Steensgaard is the cheap upgrade | `setjmp/longjmp` and pointer arithmetic: document as unsound-if-unmodeled |

## Choosing where to start (multi-language rollout)

Recommended order when rolling level 3 across the fleet: **Go first** (simplest lowering
semantics — structured control flow, no exceptions, explicit pointers — plus stdlib answer keys
for differential testing), **TypeScript second** (the substrate spike and staged plan already
exist in codeanalyzer-typescript issue #2), **Java third** (mostly WALA exposure),
**Python/Rust/C last** (weakest oracles, hardest lowering). Each language instantiates
`dataflow-issue-template.md` with its row from this menu.
