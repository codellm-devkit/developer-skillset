# Testing and validation

All verification criteria, fixture design rules, and definitions of done for both the
analyzer backend and the Python SDK surface. Authoritative: content here supersedes
scattered verify notes in `SKILL.md`, `python-sdk-wiring.md`, and `backend-recipe.md`.

> **Never fake verification.** The toolchain is confirmed installed at the start of
> *Orient & choose the backend tooling*, so every gate below should actually run.
> If a required tool is missing mid-build, stop and instruct the user to install it —
> don't scaffold-and-leave-unverified and don't claim a gate passed without running it.

---

## 1. Fixture design

### Analyzer-side fixture (`testdata/fixture/` or `testdata/realistic/`)

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

### SDK-side fixture (`tests/resources/<lang>/`)

- A small `analysis.json` (or directory containing one) that can be loaded without running
  the binary. Used by mocked tests.
- Optionally, a sample Go/Rust/JS project under `tests/resources/<lang>/application/` for
  E2E tests. This can be the same fixture as the analyzer-side one if the SDK lives next
  to the analyzer repo; otherwise replicate a subset.

---

## 2. Analyzer-side testing gates

### Symbol-table gate (run after Symbol Table Construction)

Run the analyzer on the fixture and confirm all of the following:

1. **Output validates** against the SDK `<Lang>Application` Pydantic model —
   `<Lang>Application(**json.load(open("analysis.json")))` must not raise.
2. **`symbol_table` is non-empty** and keyed by **stable relative paths** — no key starts
   with `/` (absolute) or `..` (CWD-relative). Both are common bugs; assert them
   explicitly.
3. A known file's `Module` contains the expected types, functions, and call sites with
   `callee_signature == null`. (Call sites are recorded but not resolved at this stage.)
4. **Re-running reuses the cache** — mtime of `analysis.json` (or `analysis_cache.json`)
   is unchanged on a second non-eager run.

Do not proceed to Call Graph Construction until this passes.

### Call-graph gate (run after Call Graph Construction)

1. Every edge endpoint matches a real signature in the symbol table — no dangling nodes.
   Check: `for e in app.call_graph: assert e.source in all_sigs and e.target in all_sigs`.
2. Every edge has a non-empty `provenance` list naming the resolver.
3. `callee_signature` is backfilled on successfully resolved call sites (non-null, non-empty
   string).
4. A named expected edge is present — assert the exact `(source, target)` pair.
5. At least one cross-package/cross-module edge is present.
6. Output still validates against `<Lang>Application`.

### Caching tests (add after implementing caching/incremental — `backend-recipe.md` step 8)

Four behaviors to assert:

| Test | What to assert |
|------|----------------|
| `CacheFileWritten` | After `Analyze()` with `CacheDir` set, `analysis_cache.json` exists in that dir. |
| `CacheContentsRoundTrip` | `analysis_cache.json` deserializes to a valid `<Lang>Application` with the same symbol table key count as the in-memory result. |
| `SecondRunReuses` | Second run with same non-eager opts returns the same symbol table key count; `analysis.json` (or cache file) mtime is unchanged. |
| `EagerForcesRebuild` | After seeding the cache, a run with `Eager=true` rewrites `analysis_cache.json` (mtime advances). Use `time.Sleep` / `time.sleep` before the eager run to ensure the filesystem timestamp differs. |

---

## 3. SDK-side testing — mocked tests

Location: `tests/analysis/<lang>/test_<lang>_analysis.py`

**Pattern:** monkeypatch the wrapper's `_run_and_parse()` (or equivalent) to return a
pre-built `<Lang>Application` from a fixture JSON. Tests never invoke the binary.

```python
@pytest.fixture
def fake_app():
    return <Lang>Application(**json.loads(FIXTURE_JSON))

@pytest.fixture
def analysis(tmp_path, monkeypatch, fake_app):
    monkeypatch.setattr(
        "<Lang>Codeanalyzer",
        "_run_and_parse",
        lambda *a, **kw: fake_app,
    )
    return <Lang>Analysis(project_dir=tmp_path, ...)

def test_get_symbol_table_non_empty(analysis, fake_app):
    assert analysis.get_symbol_table() == fake_app.symbol_table
```

**Minimum mocked test coverage:**

- `source_code` mode raises `CldkInitializationException` (if not supported for this
  language).
- `get_symbol_table()` returns the expected dict.
- `get_file("<known_path>")` returns the correct `<Lang>File`.
- `get_all_types()` / `get_all_callables()` iterate across files correctly.
- `get_call_graph()` returns a `nx.DiGraph` with the expected node and edge counts.
- `get_callers(sig)` / `get_callees(sig)` return correct subsets.
- Pydantic round-trip: `<Lang>Application(**json.loads(app.model_dump_json()))` succeeds.
- Language-specific alias properties (e.g. `GoFile.types`, `GoFile.package_name`) return
  expected values.
- Null JSON fields coerce correctly — pass a fixture JSON with `null` list/dict fields and
  confirm the model loads without error (tests the `_NullSafeBase` guard — see
  `python-sdk-wiring.md`).

---

## 4. SDK-side testing — E2E tests

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

**Helper pattern** — one helper that constructs a real `<Lang>Analysis` pointing at the
fixture and a `tmp_path` output dir:

```python
def _analysis(tmp_path, level=AnalysisLevel.symbol_table):
    return <Lang>Analysis(
        project_dir=FIXTURE_DIR,
        analysis_backend_path=None,
        analysis_json_path=tmp_path,   # isolates each test's output
        analysis_level=level,
        eager_analysis=True,           # always re-run; don't depend on cached state
    )
```

**Minimum E2E test coverage:**

- All expected source files appear as keys in `symbol_table`.
- No key is an absolute path or starts with `..`.
- `<Lang>Application(**json.load(open(tmp_path / "analysis.json")))` succeeds (Pydantic
  round-trip on the real output file).
- Every language-specific schema field exercised by the fixture has an E2E assertion with a
  specific expected value — not just "non-empty".
- Named expected call-graph edge is present (level-2 run).
- Cross-package edge is present (level-2 run).
- No dangling call-graph nodes.
- Cache idempotency: first run with `eager=True` seeds the cache; second run with
  `eager=False` does not rewrite `analysis.json` (assert `st_mtime` unchanged after
  `time.sleep(0.05)`).

---

## 5. Definition of done

Both surfaces must pass before the skill is considered complete for a language.

### Analyzer surface
- [ ] `go test ./...` (or equivalent) passes — all symbol table, call graph, and caching tests.
- [ ] Output on the fixture validates against `<Lang>Application` without error.
- [ ] `symbol_table` keys are relative paths; no key is absolute or `..`-prefixed.
- [ ] Every language-specific field has at least one test asserting a concrete value.
- [ ] Named expected call-graph edge is asserted (not just "non-empty").
- [ ] `--eager` rewrites cache; non-eager second run reuses it.
- [ ] `--format <unsupported>` returns an explicit error (never silently falls back).
- [ ] Binary builds to a self-contained executable with no runtime dependency.

### SDK surface
- [ ] Mocked SDK tests pass under `pytest` (backend patched).
- [ ] `CLDK(language="<lang>").analysis(project_path=<fixture>).get_symbol_table()` is
  non-empty when run with the binary on PATH.
- [ ] `get_call_graph()` returns a NetworkX DiGraph with no dangling nodes.
- [ ] All changes are on the `add-<lang>-support` branch; the tree is clean.
- [ ] E2E tests exist and skip cleanly when binary is absent.
- [ ] `pyproject.toml [tool.backend-versions]` is pinned to the released version.
