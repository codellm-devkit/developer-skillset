# Project materialization (build & dependency resolution)

Before the analyzer can resolve symbols and types, it must **materialize the target project's
dependencies** — the environment the resolver reads. This is a distinct phase with its own failure
modes, and it runs **before** the symbol table is built, because L1 carries resolved types
(parameter/return/receiver types) that the resolver can only produce when the project's deps are
present (`references/level-1-symbol-table.md`).

## Anchor: what Java and Python do, and when

**Java** (`BuildProject`, driven from `CodeAnalyzer.run()`):
- `downloadLibraryDependencies(...)` runs **before** symbol-table extraction — it locates
  `mvn`/`gradle` (or the `mvnw`/`gradlew` wrapper) and downloads the library deps, exposing them as a
  classpath the JavaParser `SymbolSolver` uses to resolve types during L1.
- A **full compile** (`build = "auto"`) runs only when a bytecode/IR engine needs it (WALA needs
  compiled bytecode). Flags: `-b/--build-cmd`, `--no-build`; `cleanLibraryDependencies()` tidies up.

**Python** (`core.py`):
- Creates a **virtualenv** at `cache_dir/<project>/virtualenv`, `pip install`s the project's
  `requirements.txt`/`pyproject.toml` deps, and `pip install -e`s the project itself. That venv is
  passed into the symbol-table builder because **Jedi** needs the environment to infer imports/types
  as the table is built. `--eager` recreates the venv; otherwise it's reused.

The shared shape: **detect the manifest → run the ecosystem's installer → expose the result
(classpath / venv / module graph) to the resolver → do it before parsing.**

## The pattern to replicate

1. **Detect the project model.** Find the manifest(s): `tsconfig.json` + `package.json` (TS), `go.mod`
   (Go), `Cargo.toml` (Rust), a compilation database (`compile_commands.json`) for C/C++. If absent,
   degrade (below).
2. **Run the ecosystem installer, idempotently:**
   - TypeScript: `npm ci` / `yarn install --frozen-lockfile` / `pnpm install` to populate
     `node_modules`; read `tsconfig.json` for the program/compiler options.
   - Go: `go mod download` so `go/packages`/`go/types` can load the module graph.
   - Rust: `cargo fetch` / `cargo build` as the resolver needs.
3. **Cache it** under `cache_dir`, keyed to the project, and reuse on reruns unless `--eager`. This
   phase is usually the slowest — don't repeat it needlessly.
4. **Degrade gracefully — never crash here.** If the *project's own dependencies* fail to install/build
   (missing lockfile, network off, partial workspace), log it to **stderr** and continue with **partial
   types** rather than aborting. A symbol table with some unresolved types is far more useful than an
   exception, and it still exits `0` (`references/cli-contract.md`). Honor `--no-build` to skip
   materialization when the user has prepared the environment.
5. **Expose the result to the resolver** — the `node_modules`/`tsconfig` program, the module graph, the
   venv — through whatever handle the structural/resolution tool consumes.

The **toolchain itself being absent** (node/go/rustc/clang) is a *different* failure: that is checked
up front in the tooling menu (`references/tooling-menu.md`), which **stops and instructs the user to
install it** rather than degrading. Materialization degrades; a missing toolchain halts.

## Build-less parsing: materialize deps, not always a full compile

Most resolvers need the project's **dependencies present**, not a full compile — this keeps L1/L2
cheap. Two tiers, by resolver kind:

- **Source-level resolvers** (the TS checker, `go/types`, Jedi, rust-analyzer, clang): need deps
  present only. `npm install` / `go mod download` / a venv / a compilation database suffices, and can
  run before the symbol-table build. No project build required.
- **Bytecode / IR resolvers** (WALA-style, used at the framework-enrichment axis or for L4 IR): need a
  **full compile**. Defer that heavier build to just before the engine runs (as Java does), so the
  cheap `-a 1`/`-a 2` path never pays for it.

If your structural tool also resolves types (ts-morph, clang), materialize deps **before parsing** so
L1's type fields populate; otherwise parse structurally first and fill types when the resolver runs at
L2. State which path you took under the README's **Architecture & Tooling** heading.

## Vendor / virtual-env handling

Two distinct roles for the same trees, don't conflate them:

- **As resolution input:** `node_modules` / the venv / the module cache is what the resolver reads to
  resolve imports into declarations. **Materialize it.**
- **As analysis input:** vendored and test trees (`node_modules`, `.venv`, `vendor`, `__tests__`) are
  **skipped during file discovery** (honoring `--skip-tests`) so the symbol table describes the
  *project*, not its dependencies. Materialize them for the resolver; do not walk them into the tree.

## Timing summary

- **Before symbol-table construction** whenever the table carries resolved types (it does). The safe
  default: **materialize before parsing.**
- **Always before any call-site resolution** (the L2 call graph, and any framework engine).
- Cache the result; reuse unless `--eager`; degrade to partial types on failure; halt only when the
  toolchain itself is missing.
