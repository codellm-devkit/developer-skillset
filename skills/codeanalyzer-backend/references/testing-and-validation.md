# Testing and validation (analyzer surface)

All verification criteria, fixture-design rules, and the per-level gate commands for the **analyzer
backend** (`codeanalyzer-<lang>`). Each level's gate is what the SKILL.md `<HARD-GATE>` refers to: **no
level advance while the current level's conformance gate is red.** The **SDK-side** testing (mocked +
E2E against the facade, and the slice/taint query gates) lives in the companion `cldk-sdk-frontend`
skill; keep the two in sync but scoped to their own surface.

> **Never fake verification.** The toolchain is confirmed installed at the start (the tooling menu),
> so every gate below should actually run. If a required tool goes missing mid-build, stop and
> instruct the user to install it — don't scaffold-and-leave-unverified, and don't claim a gate passed
> without running it.

## Conformance is the success criterion

"Conformance" means the output **validates against the SDK models generated from the keystone**
(`skills/designing-cldk-changes/references/canonical-schema.md`) — in practice,
`Application(**json.load(open("analysis.json")))` must not raise. An analyzer that *runs* but emits
non-conformant JSON has failed the real job: the SDK can't load it and the Neo4j graph won't match.
Validate at **every** level, in **both** projections. Mirror the schema *comprehensively* — a thin
shape that "looks right" but drops fields is a silent failure.

## Fixture design

Fixture location: `testdata/fixture/` (or `testdata/realistic/`) in the analyzer repo. A field with no
test is a silent regression point — assert a **specific value**, never just `len > 0`.

**L1/L2 minimum coverage:**
- Every field added beyond the shared spine, with a concrete-value assertion.
- At least one **multi-file compilation unit** (two+ files in one package/module) — the cross-file
  method-attachment bug surfaces only here.
- Both **exported and unexported** symbols; assert the unexported one's visibility encoding.
- The idiomatic **compound-return / error** pattern into `error_channel`.
- At least one **variadic / spread** parameter (if the language has them), asserted.
- At least one **named expected call-graph edge** — assert the exact `(src, dst)`, not "graph
  non-empty".
- At least one **cross-package / cross-module** call, so cross-package edges appear.
- A call site with a language-specific flag set true (goroutine/async/unsafe/constructor), asserted.

**L3/L4 additional coverage** (each with a named expected result in the test):
- an `if/else` and a loop (control dependence + a loop-carried `ddg` edge);
- an early return and a throw/panic/raise **with a handler** (exceptional CFG + multi-exit);
- a closure / nested function capturing a local (capture edges);
- **aliasing**: two names for one object, a write through one, a read through the other (the L3
  syntactic `ddg` misses it; the L4 `points-to` `ddg` catches it);
- a call chain `a → b → c` where a value flows from `a`'s argument to `c` and back (`summary` +
  `param_in`/`param_out`);
- mutual recursion (SCC fixpoint termination);
- a module-level/global variable written in one function, read in another;
- a **multi-file** flow (cross-module SDG edges);
- each language-specific lowering construct from the L3 checklist
  (`references/level-3-intraprocedural-dataflow.md`).

## Per-level gate commands

Run each level's gate on the fixture; do not build the next level until the current is green.

### L1 — symbol-table gate (`-a 1`)
1. **Output validates** against `Application` — `Application(**json.load(...))` does not raise.
2. **`symbol_table` non-empty** and keyed by **stable relative paths** — assert no key starts with `/`
   (absolute) or `..`. Both are common bugs.
3. A known file's `module` has the expected `types`/`functions`, a `source` blob, and callables
   carrying `call` nodes with `callee == null`; the `get_method_body` slice matches
   `module.source[span.bytes]`.
4. **Re-running reuses cache** — `analysis.json` (or `analysis_cache.json`) mtime unchanged on a second
   non-eager run.

### L2 — call-graph gate (`-a 2`)
1. Every edge endpoint matches a real `can://` id — `for e in call_graph: assert e.src in all_ids and
   e.dst in all_ids` (no dangling).
2. Every edge has a **non-empty `prov`** naming the resolver.
3. **`callee` backfilled** (non-null id) on resolved sites; still `null` on honest-unresolved ones.
4. A **named expected edge** present (exact `(src, dst)`), plus at least one **cross-package** edge.
5. Output still validates.

### L3 — intraprocedural gate (`-a 3`)
1. **CFG:** every body node maps to a real span; single `@entry`/`@exit`; every node reachable from
   `@entry` and reaching `@exit`; each fixture construct emits its documented `cfg` edges (including
   `exception` edges).
2. **Dominance:** post-dominator tree rooted at `@exit`; hand-computed control dependences for the
   fixture's `if`/loop/early-return callables match the `cdg` edges exactly.
3. **PDG slice (the L3 gate):** a backward intraprocedural slice — reverse reachability over
   `cdg ∪ ddg` — of a named variable at a named line equals the hand-computed node set **exactly**.
   Write the expected set into the test.

### L4 — interprocedural gate (`-a 4`)
1. **No dangling** `param_in`/`param_out`/`summary` endpoints.
2. **`param_in`/`param_out` arity** matches each callable's parameters.
3. A **`summary` edge exists** for a known transitive flow.
4. The **semantic `ddg`** (`prov:["points-to"]`) edges are present and **added to**, not replacing, the
   L3 `prov:["ssa"]` edges.
5. Output validates. (Slice/taint are **frontend gates**, in `cldk-sdk-frontend` — the backend proves
   the graph is correct; those prove the SDK's queries over it are.)

## Caching tests (after implementing caching/incremental)

| Test | Assert |
| --- | --- |
| `CacheFileWritten` | After a run with `--cache-dir` set, `analysis_cache.json` exists there. |
| `CacheContentsRoundTrip` | It deserializes to a valid `Application` with the same `symbol_table` key count as the in-memory result. |
| `SecondRunReuses` | A second non-eager run returns the same key count; `analysis.json` mtime unchanged. |
| `EagerForcesRebuild` | After seeding the cache, `--eager` rewrites `analysis_cache.json` (mtime advances; sleep before the eager run so the timestamp differs). |

## Flag-validation test

`--format <unsupported>` (e.g. `msgpack` before it's implemented) must exit **non-zero** with a clear
message, never silently fall back to JSON. Assert both the non-zero exit and the message
(`references/cli-contract.md § Flag validation`).

## Monotonicity gate (the additive-paradigm invariant)

Run `-a 1`, `-a 2`, `-a 3`, `-a 4` on the fixture and assert
**`json(-a 1) ⊆ json(-a 2) ⊆ json(-a 3) ⊆ json(-a 4)`** — every node and edge present at a lower level
is present, **unchanged**, at every higher level. The **only** sanctioned differences are additions
(new `body` nodes, new edge-list entries) and the single `callee: null → id` refinement. A diff that
*changes* an existing fact (a rewritten span, a re-anchored `call_graph` edge, a removed syntactic
`ddg` edge) **fails** the gate — a level rewrote instead of added. This is a CI-checkable superset gate.

## Cross-projection gate

Assert the two projections agree: the Neo4j node/edge counts at full depth match the JSON at
`max_level` (modulo the explicit `HAS_*` containment edges Neo4j makes explicit —
`references/neo4j-projection.md`).

## Two-tier identity gate

`can://` ids (≥ callable) are **stable across two runs** on unchanged source; `…@line:col` ids **carry
a column** (assert no id is a bare line); every edge endpoint resolves to a real node (no dangling, at
every level and in both projections).

## Determinism (`-j`) gate

`-j N` output must be **byte-identical** to `-j 1` at every level. Implement sequentially first, pass
every gate at `-j 1`, then parallelize using the `-j 1` output as the differential oracle — never
assign ids or emit during parallel execution (collect, then sort by node id). `-j 1` stays the debug
mode forever.

## Definition of done (analyzer surface)

- [ ] The level test suite passes (`go test ./...` or equivalent) — L1, L2, and, if in scope, L3/L4.
- [ ] Output on the fixture validates against `Application` at every implemented level, in both
  projections.
- [ ] `symbol_table` keys are relative; none absolute or `..`-prefixed.
- [ ] Every language-specific field has a concrete-value assertion.
- [ ] Named expected call-graph edge asserted (not just "non-empty").
- [ ] `--eager` rewrites cache; a non-eager second run reuses it.
- [ ] `--format <unsupported>` returns an explicit error.
- [ ] The monotonicity, cross-projection, identity, and determinism gates all pass.

Release-artifact validation (wheel, Release binaries, brew formula build cleanly) is **not** an
analyzer-surface gate — it belongs to `finishing-cldk-work`. Both this surface and the SDK surface
(`cldk-sdk-frontend`) must be green before the language is considered complete.
