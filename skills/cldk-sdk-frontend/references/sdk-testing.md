# SDK testing — the three tiers

Verification for the frontend surface: the `<Lang>Analysis` facade, its backends, and
the public-API-stability guarantee. The **analyzer-side** gates (the binary emits a
correct graph) live in `skills/codeanalyzer-backend/references/testing-and-validation.md`
— keep the two in sync but scoped to their own surface.

> **Never fake verification.** Every test file below must actually run under `pytest`
> (or `bun test`). Mocked tests always run; E2E tests skip cleanly when the binary is
> absent but must pass when it is present. Don't claim a suite passed without running it.

## The tiers and what each may touch

| Tier | File | May touch | Must NOT touch |
| --- | --- | --- | --- |
| **Mocked** | `test_<lang>_analysis.py` | a fixture `analysis.json` → a pre-built `AnalysisPayload`, the facade/view logic | the real binary, the network, Neo4j |
| **E2E** | `test_<lang>_e2e.py` | the real `codeanalyzer-<lang>` binary on a fixture project, a `tmp_path` cache | nothing that requires a running Neo4j (that is the Neo4j-parity test) |
| **Backend-contract** | `test_<lang>_backend_contract.py` | the ABC and the concrete backend classes (introspection only) | the binary, the network |

Mocked tests prove the facade logic is correct *given* the right `analysis.json`. They
**cannot** catch CLI-flag bugs, null-serialization mismatches, or missing real fields —
that entire class is the E2E tier's job. The backend-contract tier proves the two
backends stay interchangeable. All three must be green before the PR.

## Fixtures

Location: `tests/resources/<lang>/`.
- A small `analysis.json` under `tests/resources/<lang>/analysis_json/` — loadable
  without the binary, used by mocked tests.
- A real project fixture under `tests/resources/<lang>/application/` for E2E. It must
  satisfy the analyzer-side fixture minimums (multi-file unit, exported + unexported
  symbols, a named call-graph edge, language-specific fields) —
  `skills/codeanalyzer-backend/references/testing-and-validation.md § 1`.

## Tier 1 — mocked

Monkeypatch the backend's `_run_and_parse()` (or equivalent) to return a pre-built
`AnalysisPayload` from a fixture JSON. Never invoke the binary.

```python
@pytest.fixture
def fake_payload(): return AnalysisPayload(**json.loads(FIXTURE_JSON))  # envelope; .application is the tree

@pytest.fixture
def analysis(tmp_path, monkeypatch, fake_payload):
    monkeypatch.setattr("<Lang>Codeanalyzer._run_and_parse", lambda *a, **k: fake_payload)
    return <Lang>Analysis(project_dir=tmp_path, ...)
```

**Minimum coverage:**
- **Public-API-stability** — assert every accessor keeps its name and *return type* (the
  `<L>*` views); the migration remaps only the substrate. This is the headline gate.
- `get_symbol_table()` returns the expected dict (keys = relative paths, unchanged).
- `get_method_body(sig)` returns the source **slice** (`module.source[span.bytes]`);
  `get_call_sites(sig)` returns the callable's `body` `call` nodes (an L1 accessor).
- `get_all_types()`/`get_all_callables()` iterate across files correctly.
- `get_call_graph()` returns an `nx.DiGraph` with expected node/edge counts — nodes are
  **`can://` ids** with `signature` as a node attribute (the deliberate key change).
- `get_callers(sig)`/`get_callees(sig)` return correct subsets (signature resolved to id).
- **Null-collection coercion** — pass a fixture with `null` list fields; `_NullSafeBase`
  loads it without error.
- Pydantic round-trip: `AnalysisPayload(**json.loads(payload.model_dump_json()))` succeeds.
- Language-specific view properties return expected values.

## Tier 2 — E2E

Run the real binary; skip cleanly when it's absent so CI without the toolchain passes:
```python
pytestmark = pytest.mark.skipif(shutil.which("codeanalyzer-<lang>") is None,
                                reason="codeanalyzer-<lang> not found on PATH")
def _analysis(tmp_path, level=AnalysisLevel.symbol_table):
    return CLDK.<lang>(project_path=FIXTURE_DIR, analysis_level=level, eager=True,
                       backend=<Lang>CodeAnalyzerConfig(cache_dir=tmp_path))  # isolate artifacts
```

**Minimum coverage:**
- All expected source files appear as keys in `application.symbol_table`; no key is an
  absolute path or starts with `..`.
- `AnalysisPayload(**json.load(open(tmp_path/"analysis.json")))` succeeds (round-trip on
  the real output file); `payload.max_level` reads the level.
- Every language-specific field/`kind` the fixture exercises has an assertion with a
  **specific** expected value — not just "non-empty".
- A named expected call-graph edge and a cross-package edge are present at `-a 2`
  (endpoints are `can://` ids).
- **Level matrix**: `-a 1` has `body` `call` nodes but no `cfg`/`ddg`; `-a 3` populates
  `cfg`/`cdg`/`ddg`; `-a 4` populates `param_in`/`param_out` — when the analyzer
  implements those levels. Assert the **monotone superset** across levels.
- No dangling edges (every `src`/`dst` resolves to a node in the tree).
- Cache idempotency: first run with `eager=True` seeds the cache; a second run with
  `eager=False` does not rewrite `analysis.json` (assert `st_mtime` unchanged).

## Tier 3 — backend-contract

Assert the concrete backend implements every `@abstractmethod` on the
`<Lang>AnalysisBackend` ABC — introspection only, no binary. This is what guarantees the
local and Neo4j backends answer identically:
```python
def test_backend_implements_abc():
    missing = {m for m in <Lang>AnalysisBackend.__abstractmethods__}
    assert not (missing - set(dir(<Lang>Codeanalyzer)))
```
If you ship the Neo4j backend, add `test_<lang>_neo4j_backend.py` (parity vs local) and
`test_<lang>_neo4j_selection.py` (selection-by-config-type), both skipped when no Neo4j
is reachable — `neo4j-backend.md`.

## Client-analysis gates (slice & taint — only when the language has L3/L4)

Slicing and taint run **in the SDK** over the analyzer's emitted graph, not in the
analyzer (`skills/codeanalyzer-backend/references/level-4-interprocedural-sdg.md`
§ Provider/client boundary). When the language exposes the L3/L4 graphs, add these gates
over the analyzer's own dataflow fixture:
- **Slice gate** — a backward slice of a named `can://…@line:col` criterion equals the
  hand-computed expected node set (**exact**, not "non-empty").
- **Taint gate** — with a small sources/sinks/sanitizers spec, one known source→sink flow
  is found; the **same** flow with a sanitizer interposed is reported `sanitized` (not
  dropped). Assert the witness `path` is a contiguous `can://…@line:col` chain.
- **Context-sensitivity** (if `summary` edges are present) — a flow entering a callee at
  call site A does not exit at an unrelated site B. If `summary` edges aren't shipped
  yet, record the over-approximation in the result rather than asserting it away.

## Definition of done (SDK surface)
- [ ] Mocked tests pass with the backend patched.
- [ ] **Public-API-stability test**: every pre-migration accessor keeps its name +
  return type (the `<L>*` views over the shared model).
- [ ] `CLDK.<lang>(project_path=<fixture>).get_symbol_table()` non-empty with the binary
  on PATH (and the legacy `CLDK(language="<lang>").analysis(...)` shim still works).
- [ ] `get_call_graph()` is a NetworkX DiGraph with no dangling nodes (`can://`-id keys).
- [ ] E2E tests exist and skip cleanly when the binary is absent.
- [ ] Backend implements every ABC method (backend-contract test green).
- [ ] `pyproject.toml [tool.backend-versions]` pinned to the released version.
- [ ] All changes on the `add-<lang>-support` branch; the tree is clean.
