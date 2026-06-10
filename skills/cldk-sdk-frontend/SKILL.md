---
name: cldk-sdk-frontend
description: >-
  Wire an existing `codeanalyzer-<lang>` backend analyzer into a CodeLLM-DevKit (CLDK) FRONTEND
  SDK so a developer can call it — `CLDK(language="<lang>").analysis(...)` in the Python SDK today,
  and the TypeScript / Rust / Go / Java SDKs as they come online. Use this whenever a CLDK
  maintainer wants to "add <lang> to the cldk SDK", "wire the analyzer into python-sdk", "register
  a language in CLDK", "build the SDK facade/bindings for <lang>", or "expose <lang> analysis
  through CLDK" — even if they don't say the word "skill". The core move is a guided, interactive
  design of the SDK facade's query surface (anchored on the Java + Python + C facades, every
  divergence decided WITH the user), then encoding that one approved surface into the target
  SDK(s): the `<L>` models that validate against the analyzer's `analysis.json`, the facade class,
  the dispatch branch, and the version pin — each on a branch. PRECONDITION: a working,
  schema-conformant `codeanalyzer-<lang>` already exists (built by the **codeanalyzer-backend**
  skill). Do NOT use this to BUILD the analyzer itself (that's codeanalyzer-backend), to add a
  contribution point to an existing analyzer (codeanalyzer-extension-builder), or to merely *use*
  CLDK.
---

# CLDK SDK frontend

Bind an existing `codeanalyzer-<lang>` analyzer into a CLDK **frontend SDK** so the language is
reachable through the user-facing API. Today that means the **Python SDK** (`python-sdk`,
`CLDK(language="<lang>").analysis(project_path=...)`); the **TypeScript SDK** (`typescript-sdk` =
`@codellm-devkit/cldk`, `CLDK.for("<lang>").analysis({ projectPath })`) is wired the same way, and
Rust/Go/Java SDKs will follow as they exist. This skill owns **one surface** — the SDK bindings.
Building the analyzer and its `analysis.json` contract is the separate **codeanalyzer-backend**
skill, whose output this skill consumes.

The skill's defining move is **not** filling in files — it's running a guided, interactive design
of the facade's *query surface* (the SDK-side mirror of the backend's schema design), then encoding
that one approved surface into each target SDK. One facade vocabulary feeds every SDK encoding, so
the SDKs stay in lockstep.

## Precondition & inputs (what the backend skill hands you)

Do not start until a **working, schema-conformant `codeanalyzer-<lang>`** exists. You need, from the
**codeanalyzer-backend** skill's hand-off (or recover them yourself):
- a **sample `analysis.json`** emitted on a small fixture — the validation target for the SDK models;
- the **approved schema contract** + `.claude/SCHEMA_DECISIONS.md` (the node kinds/fields the
  language added) — see `references/schema-contract.md` for the invariants the SDK models must hold;
- the **CLI contract** — the analyzer's `--help` / documented flags the facade shells out with;
- the **published package name + version** — `codeanalyzer-<lang>==X` to pin (Python SDK depends on
  the PyPI wheel; the TS SDK pins the matching GitHub Release tag).

If any input is missing, get it from the analyzer (run it on a fixture, read its README's
*Architecture & Tooling* section) before designing the facade.

## Before you start: orient

- Locate the CLDK reference repos (read-only; prefer a local sibling checkout, else clone into
  `/tmp` from `https://github.com/codellm-devkit/<repo>.git`):
  - `python-sdk/` — the SDK you wire today; the facades you anchor on live at
    `cldk/analysis/{java,python,c}/` and the model trees at `cldk/models/{java,python,c}/`.
  - `typescript-sdk/` (`@codellm-devkit/cldk`, Bun-built) — the second binding target, when you
    wire TS; anchor on `src/analysis/java/` + `src/models/java/`.
  The analyzer repo (`codeanalyzer-<lang>`) only needs to be runnable enough to emit a sample
  `analysis.json`; you are not modifying it here.
- Read these reference files now:
  - `references/schema-contract.md` — the invariant `analysis.json` contract the SDK `<L>` models
    must satisfy (root keys, `Module→Class/Callable`, identity-only edges, snake_case, "validate
    against `<Lang>Application`"). **Read first** — it's the contract; the full field-by-field
    catalog is whatever the sample `analysis.json` actually contains.
  - `references/sdk-facade-design-loop.md` — **the method** for *SDK Facade Design*: design the
    facade's query surface slot by slot by anchoring on the Java + Python + C facades and
    **bringing every divergence to the user as a decision**. Read before touching any SDK.
  - `references/python-sdk-wiring.md` — the exact Python SDK files to create/edit (the *encoding*
    of the approved facade surface in `python-sdk`).
  - `references/typescript-sdk-wiring.md` — the exact TypeScript SDK files to create/edit; the
    subprocess-only binding surface (the second *encoding*).

## Workflow

Design the surface once, then encode it into each target SDK. Validate every SDK against the sample
`analysis.json` before moving on.

### SDK Facade Design (interactive, slot by slot)
**Don't jump straight to filling files.** The facade's query surface gets the **same level of
questioning and design the analyzer schema did** — it's the SDK-side mirror of the backend's
schema-design loop. Run the loop in `references/sdk-facade-design-loop.md` per slot: **anchor** on
the Java + Python + C facades side by side (`cldk/analysis/{java,python,c}/`), **differentiate**
("how is the `<lang>` query surface genuinely different?"), and **decide each open point WITH the
user** (`AskUserQuestion`) — never silently.

Tier A (lifecycle/whole-program: `get_application_view`, `get_symbol_table`, `get_call_graph` →
`nx.DiGraph`, `get_call_graph_json`, `get_callers`, `get_callees`, `get_class_call_graph`,
`get_class_hierarchy`) is the **invariant floor** — reproduce it verbatim, don't ask about it. The
*decisions* are everything below it:
- the **class-centric-vs-procedural shape** (C drops `get_classes` and exposes
  `get_functions`/`get_macros` — use it as the non-class anchor);
- the **per-file unit accessor name + type** (`get_<lang>_file` / `get_<lang>_<unit>`, mirroring
  `get_java_compilation_unit` vs `get_python_module`);
- the **decoration accessor** (`get_methods_with_annotations` vs `get_methods_with_decorators`);
- **native-kind accessors** for the schema kinds the analyzer added (from `SCHEMA_DECISIONS.md`);
- the **`get_callers`/`get_callees` addressing model** (name strings vs object);
- the **constructor extras + guards** (Java `source_code`/`analysis_backend_path`; Python
  `cache_dir`/`use_codeql`/`use_ray`; C bare `project_dir`);
- which optional **Tier C** (tree-sitter) and **Tier D** (framework/semantic views) methods the
  analyzer **actually populates** — implement only those; the rest are progressive.

One facade vocabulary feeds **every** SDK encoding, so decide it once here. Record each answer in
`.claude/FACADE_DECISIONS.md` (the SDK-side counterpart to the backend's `SCHEMA_DECISIONS.md`).

### Encode into the target SDK(s) — each on its own branch
Encode the approved surface into each SDK, each on an `add-<lang>-support` branch in its own repo;
confirm the tree is clean before branching. Validate against the sample `analysis.json` before
finishing. Do the surfaces back to back when more than one is in scope (order doesn't matter).

**Python SDK** (`python-sdk`, branch `add-<lang>-support`) — `references/python-sdk-wiring.md`.
Create the `cldk/models/<lang>/` Pydantic models that **validate against the sample
`analysis.json`** (built from the contract + `SCHEMA_DECISIONS.md`); add the `cldk/analysis/<lang>/`
facade (mirror the method surface decided above), the backend wrapper that resolves the binary via
`analysis_backend_path → $CODEANALYZER_<LANG>_BIN → codeanalyzer_<lang>.bin_path() → in-tree
fallback` (or imports the package in-process, for a Python analyzer), the `cldk/core.py` dispatch
branch, the `pyproject.toml` dependency + `[tool.backend-versions]` pin (`codeanalyzer-<lang>==X`,
the version from the backend hand-off), and mocked tests. **Verify:**
`CLDK(language="<lang>").analysis(project_path=<fixture>)` yields a non-empty symbol table and a
dangling-free call graph; SDK tests pass with the backend mocked.

**TypeScript SDK** (`typescript-sdk` = `@codellm-devkit/cldk`, branch `add-<lang>-support`) —
`references/typescript-sdk-wiring.md`. Add the `src/models/<lang>/` types (mirror
`src/models/java/`'s `schema.ts`/`types.ts`/`enums.ts` split) encoding the **same approved
schema**, the `src/analysis/<lang>/` facade that resolves the binary from the analyzer's **GitHub
Release asset** at the pinned tag (the TS SDK can't consume the PyPI wheel), the `src/CLDK.ts`
dispatch branch (widen the return type to the union), the `package.json` version/tag pin (+ `files`
entry if you vendor the binary), and `bun test` mocked tests. The TS SDK is **subprocess-only** —
there is no in-process pattern, so even a Python analyzer is reached via its CLI binary, always
copying the **Java** facade. **Verify:** `CLDK.for("<lang>").analysis({ projectPath: <fixture> })`
yields a non-empty symbol table and a dangling-free call graph; `bun test` passes with the backend
mocked.

*(Rust/Go/Java SDKs, when they exist, follow the same two moves: encode the approved facade surface
+ the `<L>` models that validate against `analysis.json`, on a branch, with the analyzer-version pin
kept in lockstep.)*

### Summarize
Report: the facade decisions the user made (`FACADE_DECISIONS.md`), which SDK(s) were wired and on
what branch (`add-<lang>-support` per repo), the analyzer-version pin used (kept in lockstep with
the backend's published `codeanalyzer-<lang>` release across every SDK touched), the verify results
(`get_symbol_table()` non-empty, `get_call_graph()` dangling-free, tests green with the backend
mocked), and the diff summary per repo.

> **Never fake verification.** Each SDK's verify step must actually run against the sample
> `analysis.json` with the backend mocked. If the models don't validate the sample, fix the models
> (or surface a schema gap back to the analyzer) — don't claim a surface passed without running it.

## Guardrails
- **Precondition is real.** This skill binds an *existing* analyzer. If `codeanalyzer-<lang>` isn't
  emitting conformant `analysis.json` yet, stop and run **codeanalyzer-backend** first — you can't
  validate SDK models against output that doesn't exist.
- **Design the surface once; encode it everywhere.** There is no shared base class across facades —
  `JavaAnalysis`/`PythonAnalysis`/`CAnalysis` mirror each other by convention and callers
  duck-type. Reproduce Tier A verbatim and name the leaf accessors exactly as decided, identically
  across every SDK, because drift won't be caught by the type system.
- **Models must validate against a real sample.** Build the `<L>` models against the actual
  `analysis.json` the analyzer emits, field-for-field (Pydantic silently drops unknown keys — define
  every field you intend to read). Validation against the `<Lang>Application` model is the
  definition of done, not "looks right".
- **Don't fake the call graph.** The derived `get_call_graph()` view must have no dangling nodes —
  every edge endpoint is a real callable signature in the symbol table.
- **Branch + lockstep.** Edit each SDK repo only on an `add-<lang>-support` branch; keep the
  analyzer-version pin identical across every SDK and equal to the backend's published release.
- **Scope discipline.** This skill touches SDK repos only. Building or releasing the analyzer is
  **codeanalyzer-backend**; enriching an existing analyzer with a contribution point is
  `codeanalyzer-extension-builder`.
