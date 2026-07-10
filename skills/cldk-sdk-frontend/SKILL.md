---
name: cldk-sdk-frontend
description: Use when wiring a codeanalyzer-<lang> analyzer into a CLDK frontend SDK (Python or TypeScript today, other SDKs as they come online), or migrating an SDK's model layer to a new schema version.
---

# CLDK SDK frontend

Wire an existing `codeanalyzer-<lang>` analyzer into a CLDK **frontend SDK** so the
language is reachable through the user-facing API — `CLDK.<lang>(project_path=...,
backend=...)` in the Python SDK today (legacy `CLDK(language="<lang>").analysis(...)`
kept as a compat shim), the TypeScript SDK (`CLDK.for("<lang>").analysis(...)`) the
same way, other SDKs as they come online. This rung **encodes** an already-designed
facade surface into the SDK(s); it does not design the surface and does not build the
analyzer.

## Entry Preconditions

Two gates, both hard:

(a) **A working, schema-conformant `codeanalyzer-<lang>` exists** — it emits a real
`analysis.json` (per `skills/designing-cldk-changes/references/canonical-schema.md`)
that the SDK models can validate against. Stubbing models from a schema doc or an
unshipped analyzer is the anti-pattern — you can't validate against output that
doesn't exist. **If the analyzer isn't emitting conformant output yet, STOP → invoke
codeanalyzer-backend.**

(b) **For any change to the facade *surface*** (a new language's facade, a new or
changed accessor), a **spec + GitHub epic cover it**, with the surface already decided
in the SDK facade design loop. **If it isn't designed, STOP → invoke
designing-cldk-changes** — `skills/designing-cldk-changes/references/sdk-facade-design-loop.md`
owns the surface-shape question; do not re-decide it here.

## The Iron Rule

**The public API does not move.** Adding a language, or migrating one to a new schema
version, is invisible to callers: every accessor keeps its name, signature, and return
type. This is the migration's headline guarantee.

<HARD-GATE>
No public accessor changes name, signature, or return type without going back through designing-cldk-changes. 'Cleaner against the new schema' is not an exception.
</HARD-GATE>

## Two-Layer Model

Two layers hold API stability and a new schema at once (`references/schema-contract.md`):

- **Schema-facing models** — model the analyzer's tree **once** (the shared CPG models
  `Application`/`Module`/`Node`/`Edge`), validating `analysis.json` for every language
  (the parity clause). Adding or migrating a language changes *this* layer.
- **Public facade** — the old return types (`<L>Callable`/`<L>Class`/`<L>Module`)
  become thin **views** over the CPG, exported under the same names. Accessor names,
  signatures, and return types are frozen; only each method *body* changes from "index
  the flat tree" to "walk the CPG."

New schema-native capability (program-graph, slicing, taint) enters as **new** methods,
never by retrofitting an existing signature. Client analyses (slice / taint /
reachability) run **in the SDK** over the analyzer's emitted graph — the analyzer is a
pure graph provider (`skills/codeanalyzer-backend/references/level-4-interprocedural-sdg.md`
§ Provider/client boundary).

## Per-SDK Wiring

Design the surface once (in design mode), then **encode** it into each target SDK, each
on its own `add-<lang>-support` branch, validated against the sample `analysis.json`
before finishing. The encoding is the same pipeline everywhere:

```
models ──▶ facade ──▶ dispatch branch ──▶ version pin ──▶ tests
(CPG +      (<Lang>    (CLDK.<lang>() /    (codeanalyzer-   (all
 views)     Analysis   CLDK.for(...))       <lang>==X,        green)
            + backend                       lockstep)
            ABC)
```

Per-SDK specifics:

- **Python SDK** — `references/python-sdk-wiring.md`: the `CLDK.<lang>()` factory, the
  `<Lang>AnalysisBackend` ABC (a local codeanalyzer backend plus an optional read-only
  Neo4j backend — `references/neo4j-backend.md`), the Pydantic CPG models, the dispatch
  branch, and the analyzer version pin.
- **TypeScript SDK** — `references/typescript-sdk-wiring.md`:
  `CLDK.for("<lang>").analysis({projectPath})`, the `@codellm-devkit/cldk` package
  layout, the subprocess-only binding, and the model-validation approach.

Keep the analyzer-version pin identical across every SDK touched and equal to the
backend's published `codeanalyzer-<lang>` release.

## Testing

Three tiers, all green before the PR (`references/sdk-testing.md`):

- **Mocked** — patch the backend to return a fixture `AnalysisPayload`; assert the
  public API is unchanged and each accessor is correct. Never touches the binary.
- **E2E** — run the real binary on a fixture project; skip cleanly when it is absent.
- **Backend-contract** — assert the concrete backend implements every
  `<Lang>AnalysisBackend` ABC method, so the local and Neo4j backends stay in parity.

Never fake verification: the models must validate a real sample, `get_call_graph()`
must be dangling-free, and a public-API-stability test is part of done.

## Terminal State

The ONLY skill you invoke after cldk-sdk-frontend is finishing-cldk-work. (A future
cocoa rung slots in here.)
