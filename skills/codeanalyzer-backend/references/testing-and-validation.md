# Testing and validation (analyzer surface)

All verification criteria, fixture design rules, and definitions of done for the **analyzer
backend** (`codeanalyzer-<lang>`). Authoritative: content here supersedes scattered verify
notes in `SKILL.md` and `backend-recipe.md`. The **SDK-side** testing (mocked + E2E tests
against the Python facade) lives in the companion **cldk-sdk-frontend** skill's
`references/sdk-testing.md`; keep the two in sync but scoped to their own surface.

> **Never fake verification.** The toolchain is confirmed installed at the start of
> *Orient & choose the backend tooling*, so every gate below should actually run.
> If a required tool is missing mid-build, stop and instruct the user to install it —
> don't scaffold-and-leave-unverified and don't claim a gate passed without running it.

---

## 1. Fixture design (analyzer-side)

Fixture location: `testdata/fixture/` (or `testdata/realistic/`) inside the analyzer repo.

The fixture must exercise every language-specific schema field you added. A field with no
test is a silent regression point: compilation passes, Pydantic validation passes, the
field is wrong in production.

**Minimum coverage:**

- Every field added beyond the Java/Python spine, with a test asserting a **specific
  value** — not just `len > 0`. For example: a method where `receiver_type` is non-empty;
  a callsite where `is_goroutine` is true; a callable where `cyclomatic_complexity > 1`.
- At least one **multi-file compilation unit** — the cross-file method attachment bug only
  surfaces here (see `symbol-table-construction.md`). The fixture must have two or more
  source files in the same package/module/namespace.
- Both exported and unexported symbols; tests must assert `is_exported: false` for at
  least one.
- The language's idiomatic compound-return or result/error pattern (Go `(T, error)`, Rust
  `Result<T, E>`, Swift `throws`, etc.).
- At least one **named expected call-graph edge** — assert the specific `source` and
  `target` signatures, not just "the graph is non-empty". A graph with only stdlib edges
  validates the shape but not correctness.
- A call site with a language-specific callsite flag set to true (goroutine, async, unsafe,
  constructor, etc.) and a test that asserts it.
- At least one variadic or spread parameter if the language has them (`...T`).
- At least one cross-package (or cross-module) call so cross-package edges appear in the
  call graph.

The same fixture can be reused by the SDK's E2E tests when the SDK lives next to the
analyzer repo — see the frontend skill's `sdk-testing.md`.

---

## 2. Analyzer-side testing gates

### Symbol-table gate (run after Symbol Table Construction)

Run the analyzer on the fixture and confirm all of the following:

1. **Output validates** against the SDK `Application` Pydantic model —
   `Application(**json.load(open("analysis.json")))` must not raise.
2. **`symbol_table` is non-empty** and keyed by **stable relative paths** — no key starts
   with `/` (absolute) or `..` (CWD-relative). Both are common bugs; assert them
   explicitly.
3. A known file's `Module` contains the expected types, functions, and call sites with
   `callee == null`. (Call sites are recorded but not resolved at this stage.)
4. **Re-running reuses the cache** — mtime of `analysis.json` (or `analysis_cache.json`)
   is unchanged on a second non-eager run.

Do not proceed to Call Graph Construction until this passes.

### Call-graph gate (run after Call Graph Construction)

1. Every edge endpoint matches a real signature in the symbol table — no dangling nodes.
   Check: `for e in app.call_graph: assert e.source in all_sigs and e.target in all_sigs`.
2. Every edge has a non-empty `provenance` list naming the resolver.
3. `callee` is backfilled on successfully resolved call sites (non-null, non-empty
   string).
4. A named expected edge is present — assert the exact `(source, target)` pair.
5. At least one cross-package/cross-module edge is present.
6. Output still validates against `Application`.

### Caching tests (add after implementing caching/incremental — `backend-recipe.md` step 8)

Caching has three independent layers (see `SKILL.md` § CLI, caching/incremental). Only the
first two live in the analyzer binary; the SDK-level skip is tested by the frontend skill.
Four behaviors to assert on the binary:

| Test | What to assert |
|------|----------------|
| `CacheFileWritten` | After `Analyze()` with `CacheDir` set, `analysis_cache.json` exists in that dir. |
| `CacheContentsRoundTrip` | `analysis_cache.json` deserializes to a valid `Application` with the same symbol table key count as the in-memory result. |
| `SecondRunReuses` | Second run with same non-eager opts returns the same symbol table key count; `analysis.json` (or cache file) mtime is unchanged. |
| `EagerForcesRebuild` | After seeding the cache, a run with `Eager=true` rewrites `analysis_cache.json` (mtime advances). Use `time.Sleep` / `time.sleep` before the eager run to ensure the filesystem timestamp differs. |

### Flag-validation test

`--format <unsupported>` (e.g. `msgpack` before it is implemented) must exit non-zero with a
clear message, never silently fall back to JSON. Assert the non-zero exit and the message.
See `cli-contract.md § Flag validation requirements`.

### Monotonicity gate (the additive-paradigm invariant)

The schema is additive (`canonical-schema.md` § Monotonicity), so the level outputs must nest:
run the analyzer at `-a 1`, `-a 2`, `-a 3`, `-a 4` on the fixture and assert
**`json(-a 1) ⊆ json(-a 2) ⊆ json(-a 3) ⊆ json(-a 4)`** — every node and edge present at a lower
level is present, unchanged, at every higher level. The **only** sanctioned differences are
additions (new `body` nodes, new edge-list entries) and the single `callee: null → id`
refinement. A diff that *changes* an existing fact (a rewritten span, a re-anchored `call_graph`
edge, a removed syntactic `ddg` edge) fails the gate — it means a level rewrote instead of added.
Also assert the two projections agree: the Neo4j node/edge counts at full depth match the JSON at
`max_level` (modulo the containment `HAS_*` edges Neo4j makes explicit).

### Two-tier identity gate

`can://` ids (≥ callable) are stable across two runs on unchanged source; `…@line:col` ids carry a
column (assert no id is a bare line); every edge endpoint resolves to a real node (no dangling, at
every level and in both projections).

---

## 3. Definition of done (analyzer surface)

Both this surface and the SDK surface (frontend skill) must pass before the language is
considered complete.

- [ ] `go test ./...` (or equivalent) passes — all symbol table, call graph, and caching tests.
- [ ] Output on the fixture validates against `Application` without error.
- [ ] `symbol_table` keys are relative paths; no key is absolute or `..`-prefixed.
- [ ] Every language-specific field has at least one test asserting a concrete value.
- [ ] Named expected call-graph edge is asserted (not just "non-empty").
- [ ] `--eager` rewrites cache; non-eager second run reuses it.
- [ ] `--format <unsupported>` returns an explicit error (never silently falls back).
- [ ] Binary builds to a self-contained executable with no runtime dependency, and the
  release artifacts (PyPI wheel, GitHub Release binaries, brew formula) build — see
  `packaging-and-release.md`.
