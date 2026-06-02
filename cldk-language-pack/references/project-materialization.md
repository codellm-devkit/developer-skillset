# Project Materialization (build & dependency resolution)

Before the analyzer can resolve symbols and types, it must **materialize the target project's
dependencies** — the environment the resolver reads. This is a distinct phase with its own
failure modes, and in both reference analyzers it runs **before** the symbol table is built,
because the symbol table carries resolved types (parameter/return/receiver types) that the
resolver can only produce when the project's deps are present.

## Anchor: what Java and Python do, and when

**Java** — `codeanalyzer-java/.../utils/BuildProject.java`, driven from `CodeAnalyzer.run()`:
- `BuildProject.downloadLibraryDependencies(input, projectRootPom)` runs **before** symbol-table
  extraction. It locates `mvn`/`gradle` (or the `mvnw`/`gradlew` wrapper) and downloads the
  project's library dependencies, exposing them as a classpath (`libDownloadPath`) the
  JavaParser `SymbolSolver` uses to resolve types during symbol-table construction.
- A **full build** (maven/gradle, `build = "auto"`) runs only for **level 2**
  (`SystemDependencyGraph.construct`), because WALA needs compiled **bytecode** to build the
  call graph.
- Flags: `-b/--build-cmd` (custom), `--no-build` (skip building — use prebuilt artifacts).
  `BuildProject.cleanLibraryDependencies()` tidies up at the end.

**Python** — `codeanalyzer-python/codeanalyzer/core.py`:
- Creates a **virtualenv** at `cache_dir/<project>/virtualenv`, then `pip install`s the
  project's `requirements.txt`/`pyproject.toml` deps and `pip install -e`s the project itself.
- That venv path is passed into `SymbolTableBuilder(project_dir, virtualenv)` and used by
  `build_pymodule_from_file` — i.e. it is materialized **before** per-file building, because
  **Jedi** needs the environment to infer imports/types as the table is built.
- `--eager`/`rebuild_analysis` forces the venv to be recreated; otherwise it's reused.

The shared shape: **detect the project's manifest → run the ecosystem's installer → expose the
result (classpath / venv) to the resolver → do this before parsing.**

## The pattern to replicate for the new language

1. **Detect the project model.** Find the manifest(s): `tsconfig.json` + `package.json` for
   TypeScript; `go.mod` for Go; `Cargo.toml` for Rust. If absent, degrade (see below).
2. **Run the ecosystem installer**, idempotently:
   - TypeScript: `npm ci` / `yarn install --frozen-lockfile` / `pnpm install` to populate
     `node_modules`; read `tsconfig.json` for the program/compiler options.
   - Go: `go mod download` so `go/packages`/`go/types` can load the module graph.
   - Rust: `cargo fetch`/`cargo build` as the resolver needs.
3. **Cache it** under `cache_dir` (like Python's venv), keyed to the project, and reuse on
   reruns unless `--eager`. This phase is usually the slowest; don't repeat it needlessly.
4. **Degrade gracefully — never crash here.** If the *project's own dependencies* fail to
   install/build (missing lockfile, network off, partial workspace), log it and continue with
   **partial types** rather than aborting. A symbol table with some unresolved types is far more
   useful than an exception. Honor `--no-build` to skip materialization entirely when the user
   has prepared the environment. *(This is distinct from the **toolchain** itself — node/go/
   rustc/clang — being absent: that's checked up front in *Orient & choose the backend tooling*,
   which stops and instructs the user to install it rather than degrading.)*
5. **Expose the result to the resolver** — the `node_modules`/`tsconfig` program, the module
   graph, the venv — through whatever handle your structural/resolution tool consumes.

## Timing: when must this run?

- **Before symbol-table construction** whenever the table carries resolved types — which it
  does (parameter/return/receiver types). Both references materialize first for exactly this
  reason. The safe default is: **materialize before parsing.**
- **Always before any call-site resolution** (the call-graph stage — cheap resolver edges and,
  if used, the heavy framework backend).
- **Two tiers, by resolver kind:**
  - *Source-level resolvers* (TS checker, `go/types`, Jedi) need **deps present**, not a full
    compile — `npm install` / `go mod download` / venv suffices, and can run before the
    symbol-table build.
  - *Bytecode/IR resolvers* (WALA-style) need a **full compile** — that heavier build can be
    deferred to just before the level-2 framework call-graph construction, as Java does.
- If your structural tool also resolves types (ts-morph), you want deps materialized before
  parsing so the symbol table's type fields are populated; otherwise you parse structurally
  first and fill types when the resolver runs (the call-graph step). State which path you took
  in `BUILD_PLAN.md`.
