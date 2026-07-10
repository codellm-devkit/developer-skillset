# Wiring the language into the Python SDK

Once `codeanalyzer-<lang>` emits a conformant `analysis.json` and the facade surface is
**already designed** (in design mode — `skills/designing-cldk-changes/references/sdk-facade-design-loop.md`,
recorded in `.claude/FACADE_DECISIONS.md`), this file is the **encoding** mechanics for
the Python SDK (`python-sdk/`). You are not deciding the surface here; you are writing
the files that realize it, under the Iron Rule: **every accessor keeps its name,
signature, and return type.**

The user-facing API selects behavior along **two orthogonal axes**: the **language**
(a static factory method `CLDK.<lang>(project_path=...)`) and the **backend** (the
*type* of the config object passed as `backend=`). Adding a language means: the CPG
models, a facade, a **backend ABC with at least a local implementation**, a factory
method, a dispatch route, and a version pin.

```python
CLDK.<lang>(project_path="...", backend=CodeAnalyzerConfig())    # local codeanalyzer backend (default)
CLDK.<lang>(backend=Neo4jConnectionConfig(uri="bolt://..."))     # read-only Neo4j backend (no project_path)
# Legacy CLDK(language="<lang>").analysis(project_path=...) stays wired as a compat shim
# forwarding to the factory. Keep it working; the factory methods are canonical.
```

Pick the worked example by how the analyzer is invoked:
- **Subprocess binary/JAR** (most new languages) → copy the **Java** pattern
  (`cldk/analysis/java/`), which shells out and parses `analysis.json`.
- **In-process pip package** (only if the analyzer is itself Python) → copy the
  **Python** pattern (`cldk/analysis/python/`), which imports the backend and calls it.

## Branch first
```
cd python-sdk
git checkout -b add-<lang>-support
```
Confirm the working tree is clean before branching; if not, surface that rather than
folding in unrelated changes.

## Files to create / edit

### 1. Models — the shared `cldk/models/cpg/` + per-language aliases
The schema is **one node-tree modeled once** (`schema-contract.md`), not a per-language
tree:
- **`cldk/models/cpg/` (shared, build once; may already exist for another language):**
  - `models.py` — `AnalysisPayload` (envelope), `Application`, `Module`, `Node` (single
    model, `kind` string discriminator, kind-specific fields all Optional), `Edge`
    (`{src, dst, kind?, var?, prov[], weight}`), `Span`, `Import`, `Param`, `Decorator`.
    All inherit `_NullSafeBase`. Field names match the JSON keys so
    `AnalysisPayload(**json.load(f))` validates.
  - `views.py` — `CallableView`, `TypeView`, `ModuleView`, `CallsiteView`, `FieldView`:
    thin `(node, module)` wrappers exposing the **old field names** (`.signature`,
    `.code` = source slice, `.call_sites` = `body` `call` nodes, `ModuleView.classes/
    .interfaces` = kind-filters over one `types{}`).
  - `index.py` — build `by_id`, `sig_to_id`, `owner_module` once at load; the
    string-addressed public API (which speaks `signature`) resolves signature→id here.
- **`cldk/models/<lang>/__init__.py` shrinks to aliases + registration** (the remap
  table in `schema-contract.md`): `<L>Callable, <L>Class, <L>Module, <L>Callsite,
  <L>Application = CallableView, TypeView, ModuleView, CallsiteView, Application`. The
  language's **own** node kinds/fields are **additive Optional fields on the one
  `Node`** + `kind` string values (from the analyzer's `SCHEMA_DECISIONS.md`) — no new
  per-language Pydantic class.
- **Do not** copy the old per-language rich-edge tree. The template is the shared
  `cpg/` package; the first language to migrate builds it, the rest add fields/aliases.

### 2. Backend config — `cldk/analysis/commons/backend_config.py`
- Add a `<Lang>CodeAnalyzerConfig(CodeAnalyzerConfig)` subclass **only if** the language
  has backend-only knobs (Python's `use_ray`, TS's `tsc_only`); otherwise reuse
  `CodeAnalyzerConfig`.
- Add the discriminated union, mirroring the existing `JavaBackend = Union[
  CodeAnalyzerConfig, Neo4jConnectionConfig]` / `PyBackend` / `TSBackend`:
  `<Lang>Backend = Union[<Lang>CodeAnalyzerConfig, Neo4jConnectionConfig]` (drop the
  Neo4j arm if you don't ship a graph backend).
- Add the language cache key so `cache_subdir(cache_dir, project_dir, "<lang>")` keeps a
  polyglot repo's per-language artifacts from colliding under `<project>/.codeanalyzer/`.

### 3. Analysis facade & backends — `cldk/analysis/<lang>/`
The facade is thin; the real work is the **backend ABC** and its implementations.
- `<lang>_analysis.py` — the `<Lang>Analysis` class. Constructor: `project_dir`,
  `analysis_level`, `target_files`, `eager_analysis`, `backend=<Lang>Backend | None`.
  In `__init__`, `isinstance`-check the config and build the backend
  (`Neo4jConnectionConfig` → `<Lang>Neo4jBackend`, else `<Lang>Codeanalyzer`), then
  **forward every query to `self.backend`**.
- `backend.py` — the `<Lang>AnalysisBackend(ABC)` base class (new since the older
  "no-ABC" SDK). It declares every query method the facade forwards as
  `@abstractmethod`; **both** backends implement it, which is what guarantees
  local/Neo4j parity. Mirror `cldk/analysis/java/backend.py` (`JavaAnalysisBackend`).
- `codeanalyzer/codeanalyzer.py` — the **local** backend
  `<Lang>Codeanalyzer(<Lang>AnalysisBackend)`:
  - **Subprocess**: build CLI args (`skills/codeanalyzer-backend/references/cli-contract.md`),
    `subprocess.run` the binary with `-o <cache_subdir>`, read `analysis.json`, validate
    into `AnalysisPayload`. Resolve the binary from the packaged wheel /
    `$CODEANALYZER_<LANG>_BIN` / `shutil.which` (see *Common pitfalls*).
  - **In-process** (Python analyzer only): import the package and call it.
- `neo4j/` — **only if** the analyzer emits a graph:
  `<Lang>Neo4jBackend(<Lang>AnalysisBackend)` + `reconstruct.py` + `config.py`. Full spec
  in `references/neo4j-backend.md`.
- `__init__.py` — export `<Lang>Analysis`.

### 4. Factory method & dispatch — `cldk/core.py`
- **Import** the facade near the other analysis imports.
- **Add the static factory** `CLDK.<lang>(...)`, mirroring `CLDK.java`/`CLDK.python`/
  `CLDK.typescript`:
  ```python
  @staticmethod
  def <lang>(project_path: str | Path | None = None, *,
             analysis_level: str = AnalysisLevel.symbol_table,
             target_files: List[str] | None = None, eager: bool = False,
             backend: <Lang>Backend | None = None) -> <Lang>Analysis:
      # project_path optional ONLY when backend is a Neo4jConnectionConfig
      return <Lang>Analysis(project_dir=_normalize_project_path(project_path),
                            analysis_level=analysis_level, target_files=target_files,
                            eager_analysis=eager, backend=backend)
  ```
- **Extend the legacy `CLDK(language=...).analysis(...)` shim** to route `"<lang>"` to
  the new factory (keep the deprecated path working).

### 5. Dependencies & version pin — `pyproject.toml`
- If the backend is a pip package: add it to `dependencies` (as Python does:
  `"codeanalyzer-python==X"`).
- If it's a subprocess binary: pin the analyzer's PyPI wheel that carries the binary and
  record it under `[tool.backend-versions]`:
  ```toml
  [tool.backend-versions]
  codeanalyzer-<lang> = "X.Y.Z"
  ```
- Keep the `neo4j` driver an **optional extra** (`pip install cldk[neo4j]`), imported
  lazily — never a hard dependency.

### 6. Tests — `tests/analysis/<lang>/`
Full criteria in `sdk-testing.md`. Mirror the existing per-language dirs: mocked
(`test_<lang>_analysis.py`), backend-contract (`test_<lang>_backend_contract.py`), E2E
(`test_<lang>_e2e.py`), and — if you ship a graph backend — Neo4j parity/selection.

## The facade abstraction

**Two structural facts, pulling in different directions:**

1. **The facade classes have no shared base.** `JavaAnalysis`/`PythonAnalysis`/
   `TypeScriptAnalysis`/`CAnalysis` are independent classes that mirror each other's
   method names by convention; the factory methods return the union and callers
   duck-type. Nothing enforces the *facade* vocabulary — reproduce it deliberately and
   match names/signatures exactly.
2. **The backend layer DOES have an ABC.** `<Lang>AnalysisBackend(ABC)` is subclassed by
   both the local `<Lang>Codeanalyzer` and the `<Lang>Neo4jBackend`; a
   `test_<lang>_backend_contract.py` asserts every abstract method is implemented.

```
<Lang>Analysis (public facade)                    ── picks backend by config type, forwards queries
   read-only query vocabulary                          │
        └─ backend: <Lang>AnalysisBackend (ABC)  ◀── isinstance(backend_cfg, Neo4jConnectionConfig)?
                ├─ <Lang>Codeanalyzer   → runs binary/pkg → parses analysis.json → AnalysisPayload
                └─ <Lang>Neo4jBackend   → bulk Cypher fetch → reconstructs Application (parity)
```

**Constructor contract.** Common params: `project_dir`, `analysis_level`,
`target_files`, `eager_analysis`, `backend`. Backend-only knobs live on the config
subclass (Python `use_ray`, TS `tsc_only`), not on the facade constructor; the older
`analysis_backend_path` is gone (binary ships with the packaged dependency) and
`analysis_json_path` folded into `cache_dir` (resolved by `cache_subdir`).

**Encode the approved surface in priority tiers** (names decided in the design loop;
reproduce Tier A verbatim, name leaf accessors for the language):
- **Tier A — lifecycle / whole-program (must-have):** `get_application_view`,
  `get_symbol_table`, `get_call_graph` (→ `nx.DiGraph`, nodes = callable **ids**),
  `get_call_graph_json`, `get_callers`, `get_callees`, `get_class_call_graph`,
  `get_class_hierarchy` (derived from each type's `base_types`/`interfaces`).
- **Tier B — symbol-table navigation:** `get_classes`/`get_class`, `get_methods`/
  `get_method`, `get_fields`, `get_imports`, the class-relation accessors, and the
  **per-file accessor** named for the language (`get_<lang>_file`/`get_<lang>_<unit>`).
- **Tier C — tree-sitter (optional, only if you ship a grammar):** `is_parsable`,
  `get_raw_ast`.
- **Tier D — semantic / framework views (only if the analyzer populates them):**
  entrypoints, CRUD, `get_test_methods`, comments/docstrings — progressive.
- **Tier E — new schema-native accessors:** `get_program_graph(sig)` over
  `body{}`+`cfg`/`cdg`/`ddg`/`summary`, slicing/taint over `ddg ∪ param_in ∪ param_out`,
  `flows_to_statement("file:line:col")`, plus bulk accessors
  (`get_callables_overview`, `get_method_bodies`) that matter most for the Neo4j
  backend. Add these as **new** methods; never retrofit an existing signature. Client
  analyses (slice/taint) run here, not in the analyzer — the analyzer is a pure graph
  provider (`skills/codeanalyzer-backend/references/level-4-interprocedural-sdg.md`
  § Provider/client boundary).

**Minimal viable facade** = Tier A + `get_classes`/`get_class`/`get_methods`/
`get_method`. Don't stub Tier D methods the analyzer can't yet populate.

## Common pitfalls

### Null-safe Pydantic models (`_NullSafeBase`)
Go/Rust/C serialize nil/empty collections as JSON `null`, which Pydantic v2 `List[T]`
rejects. Coerce null → empty collection **before** validation with a shared base:

```python
class _NullSafeBase(BaseModel):
    @model_validator(mode="before")
    @classmethod
    def _coerce_null_collections(cls, data):
        if not isinstance(data, dict): return data
        for name, info in cls.model_fields.items():
            if data.get(name) is None and info.default_factory is not None:
                sentinel = info.default_factory()
                if isinstance(sentinel, (list, dict)): data[name] = sentinel
        return data
```
Have **all** models inherit it. Add a mocked test that passes a `null` list field.

### `_level_flag()` must emit integers, not enum names
The CLI flag is `-a`/`--analysis-level` with **integer** values `1|2|3|4`. The
`AnalysisLevel` enum has string values, so map explicitly:
```python
{AnalysisLevel.symbol_table:"1", AnalysisLevel.call_graph:"2",
 AnalysisLevel.program_dependency_graph:"3", AnalysisLevel.system_dependency_graph:"4"}.get(level, "1")
```
Sending the string is silently mis-read — invisible to mocked tests, caught only by
E2E. On the *read* side, read `payload.max_level`; never sniff for keys.

### Binary discovery
Java resolves a JAR bundled in the package; TS reads `$CODEANALYZER_TS_BIN` or the
pinned wheel's `bin_path()`. For a binary on PATH, prefer `shutil.which` with an error
that tells the user exactly how to install it — don't just say "binary not found".

## Definition of done
- `CLDK.<lang>(project_path=<fixture>)` (and the legacy `.analysis(...)` shim) returns a
  facade whose `get_symbol_table()` is non-empty and `get_call_graph()` builds a NetworkX
  graph with **no dangling nodes** (every edge endpoint a real node **id**; node key is
  the `can://` id, `signature` a node attribute).
- The **public API is unchanged** — every accessor keeps its name, signature, and
  return type (verified against the frozen surface); the `<L>*` types are the views.
- Mocked tests pass with the backend patched; E2E tests exist and skip cleanly without
  the binary; the backend implements every ABC method.
- `[tool.backend-versions]` is pinned to the released analyzer version — only after both
  analyzer and SDK are cut (`skills/designing-cldk-changes/references/schema-migration.md`).
- All changes sit on the `add-<lang>-support` branch; summarize the diff.
