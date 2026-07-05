# SDK testing (frontend surface)

Verification criteria, fixture design, and definition of done for the **Python SDK** surface —
the `<Lang>Analysis` facade and its `<Lang>Codeanalyzer` wrapper. The **analyzer-side** gates
(symbol-table, call-graph, caching tests run against the binary) live in the companion
**codeanalyzer-backend** skill's `references/testing-and-validation.md`. Keep the two in sync
but scoped to their own surface.

> **Never fake verification.** Every test file below must actually run under `pytest`. Mocked
> tests always run (no binary needed); E2E tests skip cleanly when the binary is absent but
> must pass when it is present. Don't claim a suite passed without running it.

---

## 1. Fixture design (SDK-side)

Fixture location: `tests/resources/<lang>/`.

- A small `analysis.json` (or a directory containing one) that can be loaded without running
  the binary, under `tests/resources/<lang>/analysis_json/`. Used by mocked tests.
- A real project fixture under `tests/resources/<lang>/application/` for E2E tests. This can
  be the same fixture the analyzer's own `go test` (etc.) uses if the SDK lives next to the
  analyzer repo; otherwise replicate a subset. It must satisfy the analyzer-side fixture
  minimums (multi-file unit, exported + unexported symbols, a named call-graph edge,
  language-specific fields) — see the backend skill's `testing-and-validation.md § 1`.

---

## 2. Mocked tests

Location: `tests/analysis/<lang>/test_<lang>_analysis.py`

**Pattern:** monkeypatch the wrapper's `_run_and_parse()` (or equivalent) to return a
pre-built `AnalysisPayload` (the v2 envelope) from a fixture JSON. Tests never invoke the binary.

```python
@pytest.fixture
def fake_payload():
    return AnalysisPayload(**json.loads(FIXTURE_JSON))   # v2 envelope; .application is the tree

@pytest.fixture
def analysis(tmp_path, monkeypatch, fake_payload):
    monkeypatch.setattr(
        "<Lang>Codeanalyzer",
        "_run_and_parse",
        lambda *a, **kw: fake_payload,
    )
    return <Lang>Analysis(project_dir=tmp_path, ...)

def test_get_symbol_table_non_empty(analysis, fake_payload):
    assert analysis.get_symbol_table() == fake_payload.application.symbol_table
```

**Minimum mocked test coverage:**

- `source_code` mode raises `CldkInitializationException` (if not supported for this
  language).
- **The public API is unchanged** — assert every accessor keeps its name and *return type* (the
  `<L>*` views), since v2 remaps only the substrate.
- `get_symbol_table()` returns the expected dict (keys = relative paths, unchanged from v1).
- `get_method_body(sig)` returns the source **slice** (`module.source[span.bytes]`), and
  `get_call_sites(sig)` returns the callable's `body` `call` nodes (an L1 accessor).
- `get_all_types()` / `get_all_callables()` iterate across files correctly.
- `get_call_graph()` returns a `nx.DiGraph` with the expected node/edge counts — assert nodes are
  **`can://` ids** with `signature` as a node attribute (the deliberate node-key change).
- `get_callers(sig)` / `get_callees(sig)` return correct subsets (signature resolved to id).
- **Null-collection coercion** — pass a fixture with `null` list fields; `_NullSafeBase` loads it.
- Pydantic round-trip: `AnalysisPayload(**json.loads(payload.model_dump_json()))` succeeds (note
  the JSON keys are the v2 envelope).
- Language-specific view properties (e.g. `GoModule.types`, `.package`) return expected values.
- Null JSON fields coerce correctly — pass a fixture JSON with `null` list/dict fields and
  confirm the model loads without error (tests the `_NullSafeBase` guard — see
  `python-sdk-wiring.md § Common pitfalls`).

---

## 3. E2E tests

Location: `tests/analysis/<lang>/test_<lang>_e2e.py` (separate file from mocked tests)

**Why E2E tests alongside mocked tests:** mocked tests confirm the facade logic is correct
*given* the right `analysis.json`. They cannot catch CLI-flag bugs (e.g., the wrapper
sending `--analysis-level symbol_table` when the binary expects `--analysis-level 1`), null
serialization mismatches, or real schema fields missing from the output. E2E tests catch
that entire class.

**Skip pattern** — tests must be skippable when the binary is absent (CI without the
language toolchain must not fail):

```python
pytestmark = pytest.mark.skipif(
    shutil.which("codeanalyzer-<lang>") is None,
    reason="codeanalyzer-<lang> not found on PATH",
)
```

**Helper pattern** — one helper that constructs a real analysis via the factory method,
pointing at the fixture, with a `tmp_path` cache dir to isolate each test's output:

```python
def _analysis(tmp_path, level=AnalysisLevel.symbol_table):
    return CLDK.<lang>(
        project_path=FIXTURE_DIR,
        analysis_level=level,
        eager=True,                                       # always re-run; don't depend on cached state
        backend=<Lang>CodeAnalyzerConfig(cache_dir=tmp_path),  # isolates each test's artifacts
    )
```

**Minimum E2E test coverage:**

- All expected source files appear as keys in `application.symbol_table`.
- No key is an absolute path or starts with `..`.
- `AnalysisPayload(**json.load(open(tmp_path / "analysis.json")))` succeeds (round-trip on the
  real v2 output file — the envelope, `.application` the tree); `payload.max_level` reads the level.
- Every language-specific schema field/`kind` exercised by the fixture has an E2E assertion with a
  specific expected value — not just "non-empty".
- Named expected call-graph edge is present at `-a 2` (endpoints are `can://` ids).
- Cross-package edge is present at `-a 2`.
- **Level matrix**: assert `-a 1` has `body` `call` nodes but no `cfg`/`ddg`; `-a 3` populates
  `cfg`/`cdg`/`ddg` on a callable; `-a 4` populates `param_in`/`param_out` — when the analyzer
  implements those levels. Also assert the **monotone superset** across levels.
- No dangling edges (every `src`/`dst` resolves to a node in the tree).
- Cache idempotency (SDK-level skip): first run with `eager=True` seeds the cache; second run
  with `eager=False` does not rewrite `analysis.json` (assert `st_mtime` unchanged after
  `time.sleep(0.05)`). This exercises the facade's `_check_existing_analysis()` skip, the
  third caching layer described in the backend skill's `SKILL.md`.

---

## 3b. Client-analysis gates (slicing & taint — SDK-side, only when the language has level 3/4)

Slicing and taint run in the SDK over the analyzer's emitted dependence graph, not in the analyzer
(see `SKILL.md § Client analyses`). When the wired language exposes the level-3/4 graphs, the query
surface gets these gates, over the analyzer's own dataflow fixture:

- **Slice gate:** a backward slice of a named `can://…@line:col` criterion equals the hand-computed
  expected node set — **exact**, not "non-empty". This catches both missing control dependences and
  missing def-use edges in the consumed graph, and a broken traversal in the SDK.
- **Taint gate:** with a small sources/sinks/sanitizers spec, one known source→sink flow is found;
  the **same** flow with a sanitizer interposed is reported `sanitized` (not dropped). Assert the
  witness `path` is a contiguous `can://…@line:col` chain and carries the matching model id.
- **Context-sensitivity check (if `summary` edges are present):** a flow that enters a callee from
  call site A does **not** exit at an unrelated call site B (no unrealizable path). If the analyzer
  hasn't shipped `summary` edges yet, record this as a known over-approximation in the result
  rather than asserting it away.

These are the frontend counterparts of the backend's CFG/PDG/SDG gates — the backend proves the
graph is correct; these prove the SDK's queries over it are correct.

---

## 4. Definition of done (SDK surface)

- [ ] Mocked SDK tests pass under `pytest` (backend patched).
- [ ] **Public-API-stability test**: every pre-migration accessor keeps its name + return type (the
  `<L>*` views over the shared model) — the migration's headline guarantee.
- [ ] `CLDK.<lang>(project_path=<fixture>).get_symbol_table()` is non-empty when run with the
  binary on PATH (and the legacy `CLDK(language="<lang>").analysis(...)` shim still works).
- [ ] `get_call_graph()` returns a NetworkX DiGraph with no dangling nodes (endpoints are `can://`
  ids; `signature` is a node attribute).
- [ ] E2E tests exist and skip cleanly when the binary is absent.
- [ ] `pyproject.toml [tool.backend-versions]` is pinned to the released version.
- [ ] All changes are on the `add-<lang>-support` branch; the tree is clean.
