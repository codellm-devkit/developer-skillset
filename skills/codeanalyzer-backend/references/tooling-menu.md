# The backend tooling menu

The defining act of a language pack is **choosing the moving parts of the analyzer** for the
target language. This is a decision the user owns — there are real tradeoffs and the
"right" answer depends on what they already run in CI, what they're willing to depend on,
and how much resolution accuracy they need. The skill's job is to present **informed
options with a recommended default per slot**, let the user confirm or override, then commit
the choices to a written build plan that the scaffolding follows.

Don't silently pick. Don't ask an open-ended "what tools do you want?" either. Present this
menu, pre-filled with a recommendation derived from the target language, and let the user
adjust the slots they care about.

## The six slots

For the target language, fill each slot. The first three are the load-bearing ones; ask
about the rest only if the user engages.

| # | Slot | What it decides | Recommendation heuristic |
| --- | --- | --- | --- |
| 1 | **Native runtime/ecosystem** | Where the analyzer process runs | Follow the language's own toolchain (don't analyze Go from Python if Go has native tooling) |
| 2 | **Structural pass (parser)** | How files become a parse tree (step 5) | tree-sitter grammar if one exists and you only need structure; else the language's native AST / compiler API |
| 3 | **Resolution (symbols/types)** | How call sites resolve to declarations (step 6) | Reuse the structural tool **if it also resolves** (TS checker, clang); else add an LSP / type checker / Jedi-equivalent; Joern as a heavyweight fallback |
| 4 | **Framework-based analysis backend** (optional) | A dedicated analysis engine (WALA/Joern) for deeper edges (step 7) | Off by default; offer Joern behind a flag if the language has a CPG frontend |
| 5 | **Build/dep materialization** | What to set up before resolution (step 4) | Whatever slot 3 needs: classpath, venv, `node_modules`, module graph |
| 6 | **Packaging** | How the SDK invokes it (step 9) | **Be opinionated: compile to a self-contained binary** so SDK users need no language runtime (Go/Rust/C++ native; TS via `bun build --compile`/`deno compile`; JVM via GraalVM `native-image`). Version-pinned. pip package (in-process) **only** if the analyzer is itself Python |

## Key decision: is the structural tool also the resolver?

This is the question that most changes the shape of the analyzer:

- **Same tool does both** (TS compiler API via ts-morph; libclang for C). The structural pass
  and call-site resolution share one parse/typecheck. Simpler, but you depend on the full
  compiler and need its project model (e.g. `tsconfig.json`) materialized.
- **Separate tools** (tree-sitter for structure + a distinct resolver for types — the Go,
  Rust, Ruby shape). The structural pass is fast and dependency-light; resolving call sites
  needs a second tool (gopls/`go/packages`, rust-analyzer, or Sorbet). More moving
  parts, but the structural path stays genuinely cheap.

Name this explicitly in the build plan, because it determines whether step 6 reuses the
step-5 tool or stands up a new one.

## Call-graph tiers: resolver-based vs framework-based (not "whole-program")

Avoid the term "whole-program" to distinguish the call-graph tiers — it's misleading. Once
dependencies are materialized, **even the cheap tier resolves across the whole program**
(it follows imports into `node_modules`/the venv/the crate graph). Both tiers are
whole-program in *reach*. The real difference is the **engine** and the precision it unlocks:

- **Tier 1 — Resolver-based** (per call site). The language's own type resolver — Jedi, the TS
  checker, rust-analyzer, clang — answers "what does this site resolve to?" It falls out of the
  same tool that built the symbol table, so it's cheap. Precision = what the type system gives:
  exact for static/monomorphic dispatch, with an explicit unresolved fallback for the dynamic
  cases. This is the default base graph.
- **Tier 2 — Framework-based** (a dedicated analysis engine: WALA, Joern, SVF). Builds the
  graph via global reachability / points-to / dataflow over an IR, bytecode, or CPG — this is
  where RTA, Andersen points-to, and taint live, and where indirect/dynamic dispatch the
  resolver missed gets caught. More setup and cost; gate it behind a flag (step 7).

So the build-plan choice is "resolver-based base graph (always) + optional framework-based
backend," not "lightweight vs whole-program." In level terms: **Tier 1 *is* level 1** — the
cheap analysis is symbol table **+ resolver call graph** — and **Tier 2 is level 2** (heavy,
optional). The one exception is a language like Java whose only call graph is the framework one
(WALA) — there the call graph effectively sits at level 2.

## Packaging: be opinionated — prefer a self-contained binary

This slot is **not** an open question; default strongly to **compiling the analyzer to a
self-contained binary**. The SDK invokes it as a subprocess, and an SDK user who `pip install`s
cldk should not have to install Node, a JVM, or rustc just to analyze code. Concretely:

- **Go / Rust / C++** → native compile (`go build`, `cargo build --release`, clang). Ideal:
  zero runtime deps.
- **TypeScript / JS** → `bun build --compile` or `deno compile` — bundles the Node runtime into
  one binary. *Not* a plain npm bin.
- **JVM-based** → GraalVM **`native-image`**, not a fat JAR. (codeanalyzer-java already does
  this — it produces `build/bin/codeanalyzer` alongside the JAR.) A fat JAR forces a JVM on
  every SDK user.
- **Python analyzer only** → the exception: ship a pip package and invoke it **in-process** (no
  subprocess, no binary), because the Python runtime is already present wherever cldk runs.

Bundle or download the binary on first use, **version it**, and pin that version in the SDK
(`[tool.backend-versions]`). Only deviate from "binary" if the user has a hard constraint —
and say why under the analyzer `README.md`'s **Architecture & Tooling** heading.

## Worked recommendations by language

These are starting points to present, not laws. Confirm with the user.

### TypeScript / JavaScript (the ts-morph path)
- Runtime: **Node**
- Structural + resolution: **ts-morph** (wraps the TypeScript compiler API — one tool does
  both; the checker resolves call targets, types, and `extends`/`implements`)
- Enrichment (optional): **Joern `jssrc2cpg`** for dynamic dispatch
- Build/deps: read `tsconfig.json`, ensure `node_modules`
- Packaging: **`bun build --compile`** (or `deno compile`) → single self-contained binary that
  bundles the Node runtime, so SDK users need **no** Node install. *Avoid* a plain npm bin / `node
  script.js`, which forces every SDK user to have Node.
- Add node kinds: `interface`, `type`-alias, `enum`; capture `extends`/`implements` chains
  in `base_classes`; TS decorators on the decorator field.

### Go (the tree-sitter + separate-resolver path)
- Runtime: **Go**
- Structural: **tree-sitter-go** (or `go/ast`) for the fast level-1 walk
- Resolution (Tier 1): **`go/packages` + `go/types`** (native, accurate) — the separate
  resolver; or gopls if you want LSP-driven resolution
- Framework backend (Tier 2, optional): **Joern** (`gosrc2cpg`)
- Build/deps: `go mod download` so `go/packages` can load the module graph
- Packaging: `go build` → single static binary (natural fit), version-pinned
- Add node kinds: `struct`, `interface`; methods carry a receiver type; embedded structs and
  satisfied interfaces populate `base_classes`; struct tags into `tags`.

### C++ (the clang/libclang path — like the existing C analyzer)
- Runtime: native clang toolchain. CLDK already ships a C analyzer on **libclang**
  (`cldk/analysis/c/clang/clang_analyzer.py`) — C++ extends that pattern.
- Structural + resolution (Tier 1): **libclang / Clang AST** — one tool does both; the checker
  resolves overloads and virtual dispatch via the class/vtable hierarchy.
- Framework backend (Tier 2, optional): **LLVM IR + SVF or Phasar** — Andersen/Steensgaard
  points-to, *stronger* than RTA. This is the one new-language case (like Java)
  with a true heavyweight builder available.
- Build/deps: a **compilation database** (`compile_commands.json` via
  `CMAKE_EXPORT_COMPILE_COMMANDS=ON` or Bear) so clang gets per-translation-unit include
  paths/flags — without it, types and includes won't resolve.
- Packaging: native binary, or a libclang-based Python package mirroring the C analyzer.
- Add node kinds: free functions, **namespaces**, **templates** (decide: one entity per
  instantiation vs the template), operator overloads, `virtual`/`override` flags; multiple
  inheritance → `base_classes`; reconcile header/source (`.h`/`.cpp`) into one logical entity.

### Rust (the rust-analyzer path)
- Runtime: **Rust** toolchain
- Structural: **tree-sitter-rust** (fast level-1) or rust-analyzer
- Resolution (Tier 1): **rust-analyzer** (name resolution + type inference). Generics are
  **monomorphized**, so most calls are static dispatch — exact; trait objects (`dyn Trait`)
  resolve over the impl set, closures/fn-pointers are the indirect cases.
- Framework backend (Tier 2, optional): **MIR-based** (rustc internals, nightly)
  — be honest with the user that this tier is *less mature* than
  C++/Java; there is no WALA-grade builder yet.
- Build/deps: `cargo metadata` / `cargo fetch` (and `cargo build` if going to MIR)
- Packaging: `cargo build` → single static binary (natural fit)
- Add node kinds: **traits**, `impl` blocks, structs (no classes), enums-with-data, modules;
  `is_async`/`is_unsafe` and lifetime/generic params as fields; macros (decide: analyze
  expanded code vs source); trait bounds → `base_classes`.

### Other languages (how to reason)
- **Ruby**: tree-sitter-ruby + Sorbet/RBS or Joern (`rubysrc2cpg`); bundler for deps.
- **C#**: Roslyn (does both, like TS); `dotnet build`.
- General rule: **prefer the compiler's own API when it exposes one** (best resolution) for the
  Tier-1 resolver, fall back to tree-sitter + an external resolver when it doesn't, and reach
  for a Tier-2 framework backend (WALA/Joern/SVF) only for the points-to/dataflow cases
  the native resolver can't reach.

## Output of this step
A short, explicit set of **architecture & tooling** decisions the user has signed off on — e.g.:

```
codeanalyzer-ts — architecture & tooling
  depth:          rapid (level 1) — symbol table + resolver call graph; level 2 stubbed
  runtime:        Node
  structural:     ts-morph (TS compiler API)
  resolution:     ts-morph checker (same tool)
  framework (L2): Joern jssrc2cpg — OFF by default, behind --joern
  build/deps:     read tsconfig.json, ensure node_modules
  packaging:      bun build --compile → single binary, version 0.1.0
  extra nodes:    interface, type-alias, enum
```

Write this into the generated analyzer's `README.md` under an **Architecture & Tooling** heading
(e.g. `codeanalyzer-ts/README.md`) so it's explicit for human readers and the scaffolding and any
later session share the same locked decisions. Add a one-line rationale next to any non-default
choice.
