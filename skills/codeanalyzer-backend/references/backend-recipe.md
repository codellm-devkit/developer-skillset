# Backend analyzer recipe (the 9 steps)

This is the canonical methodology for building a `codeanalyzer-<lang>`. It is
language-agnostic on purpose: every step names *what* must happen and *why*, and points at
the per-language decision you made in the tooling menu (`tooling-menu.md`). Java and Python
are the two worked reference implementations; cite them when you need a concrete pattern.

The throughline: **the analyzer lives in the target language's own ecosystem, builds the cheap
symbol table first, then adds resolver-resolved call-graph edges strictly on top — both are the
cheap level-1 analysis — and defers the heavy framework-based analysis (level 2) to an optional,
flagged backend, only ever exposing `analysis.json` to the SDK.**

**Cross-cutting: build it modular.** Every step below lands in a specific subpackage of a
**modular package that mirrors `codeanalyzer-python`'s structure** — a delegating `core`, a
node-kind-split symbol-table builder, an isolated framework-backend subpackage, and a real
pluggable `analysis/` (pass + registry) + `frameworks/` (finder base) layer. Lay that skeleton
down *before* filling these steps; a working monolith (the shape `codeanalyzer-ts` shipped) is a
failure even when its JSON validates. The full layout, rules, and anti-patterns:
`analyzer-architecture.md`.

## 1. Anchor in the target language's native ecosystem
The analyzer must run where the language's best tooling lives, because that's where symbol
and type resolution are accurate: Java → JVM (javaparser + WALA); Python → Python
(tree-sitter + Jedi, optional CodeQL); JS/TS → Node (ts-morph over the TS compiler, optional
Joern/CodeQL). Pick **one tool for the structural pass** and **one for resolution** — and
note when they're the *same* tool. TS's checker does both; tree-sitter languages usually
need a separate resolver (an LSP, a type checker, or CodeQL). This single fact drives steps
5 and 6.

## 2. Mirror the canonical schema, then extend at the leaves
Reproduce `Application { symbol_table: Map<path, Module>, call_graph: Edge[] }`, the
Module → Class/Callable hierarchy, identity-only edges that reference signature strings with
a provenance tag, and a Callsite that holds the rich per-call metadata. That spine is the
invariant. **Then expand the schema to capture what's idiomatic in the target language as
first-class data** — add node kinds (interfaces/type-aliases/enums for TS; structs/interfaces
for Go; traits/impls for Rust), typed fields (receiver types, async/unsafe flags, generics),
or open-vocab `tags` — don't force the language into the Java/Python field set. Define **one
`signatureOf()` canonicalizer** so caller and callee ids are byte-identical across passes.
Do this as the node-by-node **anchor → differentiate → define → populate → verify** loop in
`schema-design-loop.md` (the method), with the full field list and expansion rubric in
`schema-reference.md` and the contract rules in `canonical-schema.md`.

## 3. Match the CLI family surface
Use the ecosystem's idiomatic CLI framework (Picocli for Java, Typer for Python, a Node CLI
lib for TS). Regardless of framework, expose the **same flags** so the SDK facade can shell
out uniformly: `-i/--input`, `-o/--output` (compact JSON to stdout when omitted),
`-f/--format` (`json|msgpack`), level selection (`-a 1|2` like Java, or `--codeql`-style
toggles like Python), `-t/--target-files`, `--skip-tests`, `--eager`, `-c/--cache-dir`,
`-v`. The only output contract the facade ever sees is `analysis.json` in the output dir (or
stdout). Full surface: `cli-contract.md`.

## 4. Own build and dependency resolution
A distinct phase that runs **before parsing** (the symbol table carries resolved types).
Java's `BuildProject.downloadLibraryDependencies` runs before the symbol table for the
SymbolSolver classpath, with a full maven/gradle compile only before WALA's level-2 graph;
Python builds a venv + pip-installs and passes it to the symbol-table builder for Jedi;
JS/TS reads `tsconfig.json` and ensures `node_modules`. Make it **idempotent**, **cache it**,
and **degrade to partial types rather than crashing**. Full detail and timing (source-level
vs bytecode resolvers): `project-materialization.md`.

## 5. Build the structural symbol table (level 1, part 1)
Walk the parse tree per file and populate Module → {imports, comments, classes,
interfaces/types/enums, functions, module vars}; each class → methods/properties; each
callable → params, return type, decorators, locals, spans, raw code, and the **unresolved
call sites** (callee name + receiver expr + arg exprs + position, with `callee_signature`
left null). Stamp per-file caching metadata (content hash, mtime, size). This step records
call sites but doesn't resolve them into edges — that's the cheap next step (still level 1;
type fields may still be filled here if your resolver is a same-tool checker). Do this
file-by-file, modeled on how Java's `SymbolTable.extractAll` and Python's `core.py` iterate
the project — see `symbol-table-construction.md`.

## 6. Build the resolver-based call graph (level 1, part 2 — cheap, strictly additive)
This is **cheap and part of the level-1 analysis**: the same Tier-1 resolver already loaded for
the symbol table resolves call sites into edges. For each recorded call site, map the callee to
a declaration, write its signature into `callee_signature` (**backfilling the site in place**),
and emit an identity-only edge `source_sig → target_sig` with `provenance` set to your resolver
(e.g. `"tsc"`). Handle constructors/`new`, method dispatch via receiver type, and an explicit
unresolved-fallback path (record the site, skip the edge — never crash). Never mutate the symbol
table beyond filling `callee_signature`.

This base graph comes from the **Tier-1 resolver** and is deliberately lightweight — no
points-to, dataflow, or k-CFA. *Don't call the tiers "whole-program vs not": once deps are
materialized (step 4) the resolver also resolves across the whole program.* The real axis is
the engine, and the references diverge — surface it as a decision (`tooling-menu.md` §
"Call-graph tiers"):
- **Tier 1 — Resolver-based (per call site):** the TS checker / Jedi / `go/types` / clang.
  Python's `jedi_call_graph_edges` emits one edge per site whose callee resolved and **drops
  unresolved sites**. Exact for monomorphic/static dispatch; for virtual/polymorphic dispatch
  you choose how far to expand (declared type only ≈ CHA; + instantiated subtypes ≈ RTA-style)
  — ask the user. This is the default base graph.
- **Tier 2 — Framework-based (a dedicated analysis engine):** WALA / CodeQL / Joern / SVF.
  Java's WALA `Util.makeRTABuilder(...)` yields **RTA** edges over bytecode; SVF/Phasar give
  Andersen points-to (stronger than RTA). This is step 7 (enrichment), gated behind a flag —
  it's where flow-sensitive, dynamic-dispatch, and dataflow edges come from.

## 7. (Optional) Enrich with a second backend
Layer CodeQL or Joern (`jssrc2cpg`) edges for the dynamic/dataflow cases the primary
checker misses, then **merge by `(source, target)`** with provenance union and weight
accumulation — the exact jedi∪codeql merge pattern in `codeanalyzer-python`'s core. Gate it
behind a flag so the cheap path stays cheap. This is the one step that stays a wired-but-
optional extension point even at full depth. **Isolate this backend in its own subpackage**
(Python's `semantic_analysis/codeql/` splits binary resolution, DB/driver, query execution, and
errors into separate modules; `core` talks to one class and never touches the binary) — and
scaffold those seams *even when level 2 ships stubbed*, so the deep implementation drops in
without a refactor. `analyzer-architecture.md` rule 3.

## 8. Add caching and incremental analysis
Persist `analysis_cache.json`; on rerun, reuse per-file Modules whose hash/mtime/size are
unchanged, re-analyze only what changed, and skip vendored and test trees
(`node_modules`/`.venv`/`__tests__`, honoring `--skip-tests`). `--eager` forces a clean
rebuild.

## 9. Package for the facade to invoke
**Be opinionated: compile to a self-contained binary** so an SDK user (`pip install cldk`)
needs no language runtime to analyze code. Go/Rust/C++ compile natively; JS/TS via
`bun build --compile` / `deno compile` (bundles Node); **JVM via GraalVM `native-image`**, not a
JVM-requiring fat JAR (codeanalyzer-java already produces `build/bin/codeanalyzer` this way). The
**only** exception is a Python analyzer, shipped as a pip package and invoked **in-process** (the
Python runtime is already present). **Version it**, and have the SDK pin that version
(`python-sdk/pyproject.toml [tool.backend-versions]`).

---

## Two invocation models the SDK must match

How the analyzer is packaged (step 9) determines how the SDK calls it — the SDK side is wired by
the **cldk-sdk-frontend** skill (its `python-sdk-wiring.md`), but the packaging choice you make here
fixes which of these the SDK must use:

- **Subprocess** (Java, and most new languages): the analyzer is a separate-language binary.
  The facade shells out, points `-o` at a temp dir, then reads and parses `analysis.json`.
  This is the default for TS/Go/Rust/etc.
- **In-process** (Python only, today): the analyzer is a pip package; the facade imports its
  `Codeanalyzer`/`AnalysisOptions` and calls `.analyze()` directly, getting back the Pydantic
  object with no JSON round-trip. Only choose this if the analyzer is written in Python.

## Depth target for a single skill run
Take the analyzer to a **working, validated level 1 — symbol table *and* resolver-based call
graph** — for the chosen tooling on a small fixture (steps 1–6, 8, 9). The **level-2
framework-based backend (step 7)** stays a flagged, wired extension point with a clear TODO
unless the user asks to implement it. Don't claim the call graph works until you've run the
analyzer on a fixture and confirmed edges reference real signatures.
