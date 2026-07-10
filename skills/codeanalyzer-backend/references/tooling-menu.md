# The backend tooling menu

The defining act of a language pack is **choosing the moving parts of the analyzer** for the target
language — the parser, the resolver, and any optional enrichment engine. These are real tradeoffs
that depend on what the team already runs in CI, what they will depend on, and how much resolution
accuracy they need. The load-bearing choices were locked in the **spec + epic** by
`designing-cldk-changes`; this menu is how you *confirm and record* them before scaffolding, and how
you fill any slot the spec left open.

## The guided-decision protocol

Do not silently pick, and do not ask an open-ended "what tools do you want?" Instead:

1. **Pre-fill a recommendation per slot**, derived from the target language (the heuristics below).
2. **Present the menu** and let the user confirm or override the slots they care about; use
   `AskUserQuestion` for the load-bearing ones (runtime, parser, resolver).
3. **Never invent tooling.** If a recommended parser/resolver/engine doesn't exist for the language,
   say so and fall back per the reasoning here rather than naming a package that isn't real.
4. **Commit the locked choices** to the analyzer `README.md` under an **Architecture & Tooling**
   heading (one-line rationale next to any non-default choice), so the scaffolding and any later
   session share one source of truth. Schema decisions go in `.claude/SCHEMA_DECISIONS.md`; these are
   *tooling* decisions.
5. **Verify the toolchain is installed** before building (parser, resolver, and — if L4 is in scope —
   the points-to oracle from `references/level-4-interprocedural-sdg.md`). If anything required is
   missing, stop, give exact install commands, and wait. An analyzer you can't run is one you can't
   validate.

## The five slots

| # | Slot | What it decides | Recommendation heuristic |
| --- | --- | --- | --- |
| 1 | **Native runtime / ecosystem** | Where the analyzer process runs | Follow the language's own toolchain — analyze Go from Go, not from Python, when native tooling exists |
| 2 | **Structural pass (parser)** | How files become a parse tree (L1) | tree-sitter grammar if one exists and you only need structure; else the language's native AST / compiler API |
| 3 | **Resolution (symbols/types)** | How call sites resolve to declarations (L2) | Reuse the structural tool **if it also resolves** (TS checker, clang); else add an LSP / type checker / Jedi-equivalent |
| 4 | **Framework enrichment engine** (optional) | A dedicated engine (WALA/Joern/SVF) for edges the resolver misses | Off by default, behind a flag; offer it if the language has a CPG frontend. **Orthogonal axis, not a level** (below) |
| 5 | **Build/dep materialization** | What to set up before resolution | Whatever slot 3 needs: classpath, venv, `node_modules`, module graph (`references/project-materialization.md`) |

The L3/L4 **dataflow substrate** decisions (CFG source, def-use source, the points-to oracle) are a
separate menu — they live in `references/level-3-intraprocedural-dataflow.md` and
`references/level-4-interprocedural-sdg.md`, filled only when those levels are in scope.

Packaging (self-contained binary vs. in-process pip package) fixes how the SDK invokes the analyzer,
so **record the invocation-model choice here** — but the release *mechanics* (wheel, GitHub Release
binaries, brew formula, `release.yml`) are cut by `finishing-cldk-work`, not this skill.

## Key decision: is the structural tool also the resolver?

This is the question that most changes the analyzer's shape:

- **Same tool does both** (TS compiler API via ts-morph; libclang for C/C++). Structural pass and
  call-site resolution share one parse/typecheck — simpler, but you depend on the full compiler and
  must materialize its project model (`tsconfig.json`, a compilation database).
- **Separate tools** (tree-sitter for structure + a distinct resolver — the Go/Rust/Ruby shape). The
  structural pass is fast and dependency-light; resolving call sites needs a second tool
  (`go/packages`/`go/types`, rust-analyzer, Sorbet). More moving parts, but the structural path stays
  genuinely cheap.

Name this explicitly, because it decides whether L2 reuses the L1 tool or stands up a new one.

## Resolver-based vs framework-based (an axis, not a "whole-program" split)

Avoid calling the two engines "whole-program vs not" — it misleads. Once deps are materialized, even
the cheap resolver reaches across the whole program (it follows imports into the venv/`node_modules`/
crate graph). The real difference is the **engine**:

- **Resolver-based** (per call site) — the language's own type resolver (Jedi, the TS checker,
  rust-analyzer, `go/types`, clang) answers "what does this site resolve to?" It falls out of the
  same tool that built the symbol table, so it's cheap. This is the **default L2 call graph**
  (`references/level-2-call-graph.md`). Exact for static/monomorphic dispatch, with an explicit
  unresolved fallback.
- **Framework-based** (a dedicated engine: WALA, Joern, SVF) — builds edges via global reachability /
  points-to / dataflow over an IR, bytecode, or CPG. This is where RTA and Andersen points-to live,
  and where indirect/dynamic dispatch the resolver missed gets caught.

In the canonical schema the framework engine is the **orthogonal precision axis, not a level**: its
edges **merge into the same `call_graph` list** with added `prov`, they do not create a new level.
(The one exception is a language like Java whose only call graph is the framework one — there WALA
effectively *is* the L2 producer.) Keep it flag-gated so the cheap path stays cheap.

## Worked recommendations by language (starting points, confirm with the user)

### TypeScript / JavaScript
- Runtime **Node**; structural + resolution **ts-morph** (one tool — the checker resolves call
  targets, types, `extends`/`implements`); enrichment **Joern `jssrc2cpg`** (off by default);
  build/deps: read `tsconfig.json`, ensure `node_modules`.
- Add node kinds: `interface`, `type_alias`, `enum`; capture `extends`/`implements` into `base_types`/
  `interfaces`; TS decorators on the `decorators` field.

### Go
- Runtime **Go**; structural **tree-sitter-go** (or `go/ast`); resolution **`go/packages` + `go/types`**
  (native, accurate — the separate resolver); enrichment **Joern `gosrc2cpg`** (optional); build/deps
  `go mod download`.
- Add node kinds: `struct`, `interface`; a receiver type on methods; embedded structs / satisfied
  interfaces into `base_types`/`interfaces`; struct tags into `tags`.

### C++ (the libclang path, like the existing C analyzer)
- Runtime native clang; structural + resolution **libclang / Clang AST** (one tool — resolves
  overloads and virtual dispatch via the class/vtable hierarchy); enrichment **LLVM IR + SVF/Phasar**
  (Andersen/Steensgaard, *stronger* than RTA); build/deps a **compilation database**
  (`compile_commands.json`) so includes/flags resolve per translation unit.
- Add node kinds: free functions, namespaces, templates (decide: one entity per instantiation vs the
  template), operator overloads, `virtual`/`override` flags; reconcile `.h`/`.cpp` into one entity.

### Rust
- Runtime **Rust**; structural **tree-sitter-rust** (or rust-analyzer); resolution **rust-analyzer**
  (name resolution + type inference — generics are monomorphized, so most calls are static dispatch;
  `dyn Trait` resolves over the impl set); enrichment MIR-based (nightly, *less mature* — be honest
  there is no WALA-grade builder); build/deps `cargo metadata` / `cargo fetch`.
- Add node kinds: `trait`, `impl` blocks, structs, enums-with-data, modules; `is_async`/`is_unsafe`
  and lifetime/generic params as fields; trait bounds into `interfaces`.

### Reasoning for other languages
Ruby: tree-sitter-ruby + Sorbet/RBS or Joern (`rubysrc2cpg`); bundler for deps. C#: Roslyn (does both,
like TS); `dotnet build`. **General rule:** prefer the compiler's own API when it exposes one (best
resolution) for the resolver, fall back to tree-sitter + an external resolver when it doesn't, and
reach for a framework engine (WALA/Joern/SVF) only for the points-to/dataflow cases the native
resolver can't reach.

## Output of this step

A short, explicit **Architecture & Tooling** block the user has signed off on, e.g.:

```
codeanalyzer-go — architecture & tooling
  runtime:        Go
  structural:     tree-sitter-go
  resolution:     go/packages + go/types (separate resolver)
  enrichment:     Joern gosrc2cpg — OFF by default, behind --joern
  build/deps:     go mod download
  invocation:     self-contained binary (go build); SDK shells out
  extra kinds:    struct, interface; receiver type; struct tags
```

Write it into the analyzer `README.md`. The scaffolding follows it; a later session reads the same
locked decisions.
