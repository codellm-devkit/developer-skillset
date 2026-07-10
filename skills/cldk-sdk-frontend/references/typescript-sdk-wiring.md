# Wiring the language into the TypeScript SDK

The CLDK **TypeScript SDK** (`typescript-sdk/`, published as `@codellm-devkit/cldk`,
built and tested with **Bun**) is the user-facing API for Node/TS consumers:
`CLDK.for("<lang>").analysis({ projectPath })`. Adding a language mirrors the Python SDK
move — a models tree, an analysis facade, and a dispatch branch — but in TypeScript.
**Do it on a git branch** (`add-<lang>-support`), confirming a clean tree first.

> **Design the surface once, in design mode.** This file is the *encoding* mechanics for
> the TS side. The facade's query *surface* is designed with the user in
> `skills/designing-cldk-changes/references/sdk-facade-design-loop.md`, and that one
> approved vocabulary (from `.claude/FACADE_DECISIONS.md`) is shared by **both** SDKs —
> so the TS `<Lang>Analysis` mirrors the Python `<Lang>Analysis` method-for-method, just
> transposed to `camelCase` and TS types. Don't re-decide the surface here.

> **One invocation model only.** The TS SDK has **no in-process backend pattern** —
> there is no TS equivalent of importing a pip package. Every language is invoked as a
> **subprocess** (Java shells out to a bundled JAR). So even a Python-authored analyzer
> is reached through its **CLI binary**, never imported. Copy the **Java** facade
> (`src/analysis/java/`, `src/models/java/`) as the one worked example. *(Verify the
> exact paths against the current `typescript-sdk` layout.)*

## Branch first
```
cd typescript-sdk
git checkout -b add-<lang>-support
```

## Files to create / edit

### 1. Models — the shared CPG types + per-language aliases
The schema is **one node-tree modeled once** (`schema-contract.md`), so the TS side
mirrors the Python two-layer approach:
- `src/models/cpg/schema.ts` (shared, build once) — the envelope `AnalysisPayload`
  (`schema_version`, `language`, `max_level`, `k_limit?`, `application`) and the
  canonical types `Application`, `Module`, `Node` (single interface, `kind` string,
  kind-specific fields optional), `Edge` (`{ src, dst, kind?, var?, prov[], weight }`),
  `Span` (with `bytes` for slicing). Property names match the JSON keys so a parsed
  `analysis.json` satisfies the type. Language extras are **additive optional fields**
  on `Node` + an open `tags`.
- `src/models/cpg/views.ts` — thin view classes (`CallableView`, `TypeView`,
  `ModuleView`, `CallsiteView`) exposing the old field names (`.code =
  module.source.slice(...bytes)`, `.callSites` = `body` `call` nodes,
  `ModuleView.classes` = kind-filter over one `types`).
- `src/models/<lang>/index.ts` — **aliases only**: `export type TSCallable =
  CallableView` etc. (the remap table in `schema-contract.md`), plus that language's
  added `Node` fields / `kind` strings. No per-language schema tree.
- **Don't** mirror the old per-language rich-edge split. Edges are identity-only
  `{ src, dst }` with **id** endpoints; there is no `<L>CallEdge`/`<L>Callsite` type (a
  call is a `body` `call` node; the list name is the edge type).
- `index.ts` — re-export the public model names.

### Model validation approach (TS-specific)
TypeScript is **structurally typed and erases types at runtime**, so a parsed
`analysis.json` satisfies an interface *by shape alone* and an extra JSON key is silently
tolerated. Two consequences:
- **Define every field you intend to read** — an unmodeled field simply isn't visible;
  there is no Pydantic-style validation error to catch drift, and no Go-style `null`
  collection problem to coerce (JSON `null` typechecks against an optional field).
- To get an actual runtime check (the TS counterpart of Pydantic validation), the
  existing `src/models/java/` uses a strict base with `extra: "forbid"`-style parsing to
  **catch drift** rather than tolerate it. Follow the repo's established convention —
  a runtime schema guard (e.g. a validator over `schema.ts`) if the Java models use one,
  or plain interfaces if they don't. **Verify which the current repo does per SDK** and
  match it; the goal is that a real fixture round-trips and unmodeled drift is caught.

### 2. Analysis facade — `src/analysis/<lang>/`
- `<Lang>Analysis.ts` — mirroring `src/analysis/java/JavaAnalysis.ts`. Constructor takes
  `{ projectDir, analysisLevel, ... }`; it builds the CLI args (the analyzer's
  documented CLI / `--help`), runs the binary (`spawnSync`/`bun`), reads the emitted
  `analysis.json`, parses it into the shared `Application`, and exposes the read-only
  query vocabulary (Tier A verbatim; leaf accessors named for the language, in
  `camelCase`).
- **Binary resolution** — the TS SDK **can't** consume the `codeanalyzer-<lang>` PyPI
  wheel, so it resolves the self-contained binary in order: `analysisBackendPath` →
  `$CODEANALYZER_<LANG>_BIN` → the **GitHub Release asset** at the pinned tag (downloaded
  to a cache on first use, or vendored under `src/analysis/<lang>/bin/` and listed in
  `package.json` `files`). This is why the analyzer's `release.yml` publishes raw
  binaries alongside the wheels. A native binary needs no runtime guard; Java needs
  `makeSureJavaIsInstalled` only because it ships a JAR.
- `index.ts` — export `<Lang>Analysis`.

### 3. Core dispatch — `src/CLDK.ts`
Mirror the Java branch in `CLDK.analysis(...)`:
- **Import** at the top: `import { <Lang>Analysis } from "./analysis/<lang>";`.
- **Widen the return type** from `JavaAnalysis` to the union (`JavaAnalysis |
  <Lang>Analysis`) so the new facade is a legal return.
- **Dispatch branch** before the `else throw`:
  ```ts
  } else if (this.language === "<lang>") {
      // toolchain guard ONLY if the binary needs a runtime (a native binary needs none)
      return new <Lang>Analysis({ projectDir: projectPath, analysisLevel });
  }
  ```

### 4. Packaging & version pin — `package.json`
- The binary is the analyzer's **GitHub Release asset**, not a bundle the SDK builds.
  Pin the release **tag** (download-on-first-use into a cache, or vendor under
  `src/analysis/<lang>/bin/` and add to `files`). Either way the binary is `release.yml`
  output, not committed source.
- Keep that pinned tag in **lockstep with the Python SDK's `codeanalyzer-<lang>` pin** —
  both reference the same release the **codeanalyzer-backend** skill published.
- Builds with `bun build`; tests with `bun test`.

### 5. Tests — `test/`
- `<lang>Analysis.test.ts` — mirror the Java test. **Mock the backend** (stub the binary
  invocation to return a fixture `analysis.json`) so tests don't require the binary, then
  assert the symbol table is non-empty and the call graph builds with **no dangling
  endpoints** (id-keyed). Add a fixture `analysis.json` alongside the Java fixtures.
- Full tiering (mocked / E2E / backend-contract) and what each tier may touch:
  `sdk-testing.md`.

## The facade abstraction
Same structural fact as the Python SDK: **there is no shared base class.** `JavaAnalysis`
(and your `<Lang>Analysis`) are independent classes mirroring each other's method names
by convention; `CLDK.analysis()` returns the union and callers duck-type. Reproduce the
shared vocabulary deliberately and match names/signatures to the Java facade — drift
won't be caught by the compiler across the union. A facade is a **thin, read-only query
layer over the parsed `Application`**: it runs the binary once, parses `analysis.json`,
and answers queries by indexing into that object or building derived graph views. Don't
stub framework/semantic methods the analyzer can't populate yet.

## Definition of done
- `CLDK.for("<lang>").analysis({ projectPath: <fixture> })` returns a facade whose symbol
  table is non-empty and whose call graph has no dangling nodes (every edge endpoint a
  real node id).
- The **public API is unchanged** — every accessor keeps its name, signature, and return
  type; the `<L>*` types are the shared views.
- `bun test` passes with the backend mocked.
- The pinned release tag matches the Python SDK's `codeanalyzer-<lang>` pin.
- All changes sit on the `add-<lang>-support` branch; summarize the diff.
