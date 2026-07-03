# Wiring the new language into the TypeScript SDK

The third surface (after the analyzer and the Python SDK) is the CLDK **TypeScript SDK**
(`typescript-sdk/`, published as `@codellm-devkit/cldk`, built and tested with **Bun**). It is
the user-facing API for Node/TS consumers: `CLDK.for("<lang>").analysis({ projectPath })`.
Adding a language mirrors the Python SDK move — a models tree, an analysis facade, and a
dispatch branch — but in TypeScript and against this repo's actual layout. **Do all of this on a
git branch in `typescript-sdk`** (`add-<lang>-support`), same as the Python SDK, so the change is
reviewable and reversible.

> **Design the surface first — and only once.** This file is the *encoding* mechanics for the TS
> side. The facade's query *surface* is designed interactively with the user in
> `sdk-facade-design-loop.md`, and that one approved vocabulary is shared by **both** SDKs — so the
> TS `<Lang>Analysis` mirrors the Python `<Lang>Analysis` method-for-method (the names from
> `.claude/FACADE_DECISIONS.md`), just transposed to `camelCase` and TypeScript types. Don't
> re-decide the surface here; encode the decisions already made.

> **One invocation model only.** Unlike the Python SDK, the TS SDK has **no in-process
> backend pattern** — there is no TypeScript equivalent of importing a pip package. Every
> language here is invoked as a **subprocess** (Java shells out to a bundled JAR). So even a
> Python-authored analyzer must be reached through its **CLI binary** from the TS SDK, never
> imported. Copy the **Java** facade (`src/analysis/java/`, `src/models/java/`) as the one and
> only worked example.

## Branch first
```
cd typescript-sdk
git checkout -b add-<lang>-support
```
Confirm the working tree is clean before branching; if not, surface that to the user rather than
committing unrelated changes.

## Files to create / edit (checklist)

### 1. Models — the shared v2 CPG types + per-language view aliases
Schema v2 is **one node-tree modeled once** (`schema-contract.md`), so the TS side mirrors the
Python two-layer approach:
- `src/models/cpg/schema.ts` (shared, build once) — the envelope `AnalysisPayload`
  (`schema_version`, `language`, `max_level`, `k_limit?`, `application`) and the canonical types
  `Application`, `Module`, `Node` (single interface, `kind` string, kind-specific fields optional),
  `Edge` (`{ src, dst, kind?, var?, prov[], weight }`), `Span` (with `bytes` for slicing). Property
  names match the v2 JSON keys so a parsed `analysis.json` satisfies the type. Language extras are
  **additive optional fields** on `Node` + an open `tags`.
- `src/models/cpg/views.ts` — thin view classes (`CallableView`, `TypeView`, `ModuleView`,
  `CallsiteView`) exposing the old field names (`.code` = `module.source.slice(...bytes)`,
  `.callSites` = `body` `call` nodes, `ModuleView.classes` = kind-filter over one `types`).
- `src/models/<lang>/index.ts` — **aliases only**: `export type TSCallable = CallableView` etc.,
  plus that language's added `Node` fields / `kind` strings. No per-language schema tree.
- **Don't** mirror `src/models/java/`'s v1 per-language rich-edge split. Edges are identity-only
  `{ src, dst }` with **id** endpoints; there is no `<L>CallEdge` / `<L>Callsite` type (a call is a
  `body` `call` node; the list name is the edge type).
- `index.ts` — re-export the public model names.
These `<L>` types are where the language's **own** node kinds live: for each kind the analyzer
added (recorded in its `SCHEMA_DECISIONS.md`; see `schema-contract.md`), add the matching field/type
here in the same change. TS structural
typing means an extra JSON key is silently tolerated, so define every field you intend to read.

### 2. Analysis facade — `src/analysis/<lang>/`
- `<Lang>Analysis.ts` — the `<Lang>Analysis` class, mirroring `src/analysis/java/JavaAnalysis.ts`.
  Constructor takes `{ projectDir, analysisLevel, ... }`. Internally it builds the CLI args
  (the analyzer's documented CLI / `--help`), runs the binary (`spawnSync`/`bun`), reads the emitted `analysis.json`,
  parses it into the shared `Application` (v2 CPG model), and exposes the read-only query vocabulary (see
  **"The facade abstraction"** below).
- **Binary resolution** — the TS SDK can't consume the `codeanalyzer-<lang>` PyPI wheel the Python
  SDK depends on, so it resolves the self-contained binary in this order: `analysisBackendPath` →
  `$CODEANALYZER_<LANG>_BIN` → the **GitHub Release asset** at the pinned tag (downloaded to a
  cache on first use, or vendored under `src/analysis/<lang>/bin/` and listed in `package.json`
  `files`). This is exactly why the analyzer's `release.yml` publishes raw binaries alongside the
  PyPI wheels (both published by the **codeanalyzer-backend** skill). A native binary needs no runtime guard; Java needs
  `makeSureJavaIsInstalled` only because it ships a JAR.
- `index.ts` — export `<Lang>Analysis`.

### 3. Core dispatch — `src/CLDK.ts`
Mirror the existing Java branch in `CLDK.analysis(...)`:
- **Import** at the top with the other analysis imports:
  ```ts
  import { <Lang>Analysis } from "./analysis/<lang>";
  ```
- **Widen the return type.** `analysis()` currently returns `JavaAnalysis` concretely — change it
  to the union (`JavaAnalysis | <Lang>Analysis`) so the new facade is a legal return.
- **Dispatch branch** before the `else throw`:
  ```ts
  } else if (this.language === "<lang>") {
      // run a toolchain guard ONLY if the binary needs a runtime (a native binary needs none)
      return new <Lang>Analysis({ projectDir: projectPath, analysisLevel });
  }
  ```
  Add a `makeSure<X>IsInstalled()` probe (parallel to `makeSureJavaIsInstalled`) **only** if your
  packaging depends on a runtime being present; a self-contained native binary needs no guard.

### 4. Packaging & version pin — `package.json`
- The binary comes from the analyzer's **GitHub Release asset**, not a bundle the SDK builds. Pin
  the release **tag** the SDK pulls (download-on-first-use into a cache, or vendor the binary under
  `src/analysis/<lang>/bin/` and add it to the `files` array so it ships with the published
  package). Either way the binary is the `release.yml` output, not committed source.
- Keep that pinned tag in **lockstep with the Python SDK's `codeanalyzer-<lang>` pin** — both
  reference the same release the **codeanalyzer-backend** skill published and handed off.
- Add any new runtime deps to `dependencies`; this SDK builds with `bun build` and tests with
  `bun test`.

### 5. Tests — `test/`
- `<lang>Analysis.test.ts` — mirror the Java test. **Mock the backend** (stub the binary
  invocation to return a fixture `analysis.json`) so tests don't require the binary, then assert
  the symbol table is non-empty and the call graph builds with no dangling endpoints (id-keyed).
- Add a fixture `analysis.json` and any sample-project fixture alongside the existing Java
  fixtures, wired through `test/conftest.ts`.

## The facade abstraction

Same structural fact as the Python SDK: **there is no shared base class.** `JavaAnalysis` (and
your `<Lang>Analysis`) are independent classes that mirror each other's method names by
convention; `CLDK.analysis()` returns the union and callers duck-type. Reproduce the shared
vocabulary deliberately and match names/signatures to the Java facade, because drift won't be
caught by the compiler across the union.

**Shape.** A facade is a **thin, read-only query layer over the parsed `Application`**: it runs
the binary once, parses `analysis.json`, and answers queries (symbol table, call graph,
callers/callees, class hierarchy) by indexing into that object or building derived graph views.
Implement Java's method surface; name leaf accessors for your language (`get<Lang>File`, the
decoration/comment accessors). Don't stub framework/semantic methods the analyzer can't populate
yet — add them when the data exists.

## Definition of done for this surface
- `CLDK.for("<lang>").analysis({ projectPath: <fixture> })` returns a facade whose symbol table is
  non-empty and whose call graph has no dangling nodes (every edge endpoint is a real node id).
- `bun test` passes with the backend mocked.
- All changes sit on the `add-<lang>-support` branch in `typescript-sdk`; summarize the diff for
  the user.
