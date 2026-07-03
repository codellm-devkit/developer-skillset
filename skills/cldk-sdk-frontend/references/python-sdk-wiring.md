# Wiring the new language into the Python SDK

Once `codeanalyzer-<lang>` emits a conformant `analysis.json`, the second surface is the
CLDK Python SDK (`python-sdk/`). The SDK's user-facing API now selects behavior along **two
orthogonal axes**: the **language** (a static factory method `CLDK.<lang>(project_path=...)`)
and the **backend** (the *type* of the config object passed as `backend=`). Adding a language
means creating the model tree, the facade, a **backend ABC with (at least) a local
implementation**, a factory method, and a dispatch branch. **Do all of this on a git branch in
`python-sdk`** (the user chose branch-based edits) so the changes are reviewable and reversible.

```python
# Current entry API — one factory method per language:
CLDK.<lang>(project_path="...", backend=CodeAnalyzerConfig())      # local codeanalyzer backend (default)
CLDK.<lang>(backend=Neo4jConnectionConfig(uri="bolt://..."))       # read-only Neo4j backend (no project_path needed)

# Legacy CLDK(language="<lang>").analysis(project_path=...) still works — it's a compat shim
# forwarding to the factory method. Keep it wired, but the factory methods are canonical.
```

Pick the worked example to copy based on how your analyzer is invoked:
- **Subprocess binary/JAR** (TS, Go, most new languages) → copy the **Java** pattern
  (`cldk/analysis/java/`, `cldk/models/java/`). The facade shells out and parses `analysis.json`.
- **In-process pip package** (only if the analyzer is written in Python) → copy the **Python**
  pattern (`cldk/analysis/python/`), which imports the backend and calls `.analyze()`.

**Backend selection is now config-object driven**, not per-parameter flags. Each language has a
discriminated union (`cldk/analysis/commons/backend_config.py`): `JavaBackend = Union[
CodeAnalyzerConfig, Neo4jConnectionConfig]`, `PyBackend = Union[PyCodeAnalyzerConfig,
Neo4jConnectionConfig]`, `TSBackend = Union[TSCodeAnalyzerConfig, CodeAnalyzerConfig,
Neo4jConnectionConfig]`. The facade `isinstance`-checks the config and constructs the matching
backend. Ship the **local backend always**; ship the **Neo4j backend** if the analyzer emits a
graph (`--emit neo4j`) — see `references/neo4j-backend.md`.

## Branch first
```
cd python-sdk
git checkout -b add-<lang>-support
```
Confirm the working tree is clean before branching; if not, surface that to the user rather
than committing unrelated changes.

## Files to create / edit (checklist)

### 1. Models — the shared `cldk/models/cpg/` + per-language view aliases
Schema v2 is **one node-tree modeled once**, not a per-language Pydantic tree (`schema-contract.md`).
So the model work is:
- **`cldk/models/cpg/` (shared, build once, may already exist for another language):**
  - `models.py` — `AnalysisPayload` (envelope: `schema_version`, `language`, `max_level`,
    `k_limit?`, `application`), `Application`, `Module`, `Node` (single model, `kind` string
    discriminator, all kind-specific fields Optional), `Edge` (`{src, dst, kind?, var?, prov[],
    weight}`), `Span`, `Import`, `Param`, `Decorator`. All inherit `_NullSafeBase`. Field names
    match the v2 JSON keys so `AnalysisPayload(**json.load(f))` validates.
  - `views.py` — `CallableView`, `TypeView`, `ModuleView`, `CallsiteView`, `FieldView`: thin
    `(node, module)` wrappers exposing the **old field names** as `@property`/`@computed_field`
    (`.signature`, `.parameters`, `.code` = source slice, `.call_sites` = `body` call nodes,
    `ModuleView.classes/.interfaces` = kind-filters over one `types{}`).
  - `index.py` — build `by_id`, `sig_to_id`, `owner_module` once at load; the string-addressed
    public API (which speaks `signature`) resolves signature→id here.
- **`cldk/models/<lang>/__init__.py` shrinks to aliases + registration:**
  ```python
  from cldk.models.cpg.views import CallableView, TypeView, ModuleView, CallsiteView
  from cldk.models.cpg.models import Application
  <L>Callable, <L>Class, <L>Module, <L>Callsite, <L>Application = \
      CallableView, TypeView, ModuleView, CallsiteView, Application
  ```
  This preserves every old import path and return type. The language's **own** node kinds and
  fields are **additive Optional fields on the one `Node`** + a `kind` string value (recorded in
  the analyzer's `SCHEMA_DECISIONS.md`) — no new per-language Pydantic class. Keep `_NullSafeBase`
  (Go/Rust/C serialize empty collections as `null`).
- **Do not** copy `cldk/models/java/models.py` (v1 per-language rich-edge tree). The v2 template is
  the shared `cpg/` package; the first language to migrate builds it, the rest add fields/aliases.

### 2. Backend config — `cldk/analysis/commons/backend_config.py`
- Add a `<Lang>CodeAnalyzerConfig(CodeAnalyzerConfig)` subclass if the language has backend-only
  knobs (e.g. Python's `use_ray`, TS's `tsc_only`); if it has none, reuse `CodeAnalyzerConfig`.
- Add the discriminated union: `<Lang>Backend = Union[<Lang>CodeAnalyzerConfig,
  Neo4jConnectionConfig]` (drop the Neo4j arm if you don't ship a graph backend).
- Add the cache key to `_CACHE_KEYS` (`{"<lang>": "<lang>"}`) so `cache_subdir()` keeps a
  polyglot repo's per-language artifacts from colliding under `<project>/.codeanalyzer/`.

### 3. Analysis facade & backends — `cldk/analysis/<lang>/`
The facade is thin; the real work is the **backend ABC** and its implementations.
- `<lang>_analysis.py` — the `<Lang>Analysis` class. Constructor takes `project_dir`,
  `analysis_level`, `target_files`, `eager_analysis`, `backend=<Lang>Backend | None`. In
  `__init__`, `isinstance`-check the config and construct the backend: `Neo4jConnectionConfig`
  → `<Lang>Neo4jBackend`, else `<Lang>Codeanalyzer`. Then **forward every query to
  `self.backend`**. See **"The facade abstraction"** below for the method surface and priority.
- `backend.py` — the `<Lang>AnalysisBackend(ABC)` **base class**. This is new since the older
  "no ABC" SDK: it declares every query method the facade forwards (`get_application_view`,
  `get_symbol_table`, `get_call_graph`, `get_all_callers/callees`, the class/method/field
  accessors, …) as `@abstractmethod`. Both backends implement it, which is what guarantees
  local/Neo4j parity. Mirror `cldk/analysis/java/backend.py` (`JavaAnalysisBackend`).
- `codeanalyzer/codeanalyzer.py` — the **local** backend `<Lang>Codeanalyzer(<Lang>AnalysisBackend)`:
  - **Subprocess pattern**: build the CLI args (the **codeanalyzer-backend** skill's
    `cli-contract.md`), `subprocess.run` the binary with `-o <cache_subdir>`, read
    `analysis.json`, validate into `<L>Application`. Resolve the binary (bundled artifact like
    the Java JAR, or `$CODEANALYZER_<LANG>_BIN` / `codeanalyzer_<lang>.bin_path()` like TS, or
    `shutil.which` — see *Common pitfalls*). Mirrors `cldk/analysis/java/codeanalyzer/`.
  - **In-process pattern** (Python analyzer only): `from codeanalyzer.core import Codeanalyzer`
    + `AnalysisOptions`, construct options, `Codeanalyzer(opts).analyze()`. Mirrors
    `cldk/analysis/python/codeanalyzer/codeanalyzer.py`.
  - `__init__.py` — export the wrapper class.
- `neo4j/` — **only if** the analyzer emits a graph: `neo4j_backend.py`
  (`<Lang>Neo4jBackend(<Lang>AnalysisBackend)`), `reconstruct.py` (bulk-fetch nodes/edges over
  Bolt → rebuild `<L>Application`), `config.py`. Full spec in `references/neo4j-backend.md`.
- `__init__.py` — export `<Lang>Analysis`.

### 4. Factory method & dispatch — `cldk/core.py`
- **Import** the facade near the other analysis imports.
- **Add the static factory method** `CLDK.<lang>(...)`, mirroring `CLDK.java` / `CLDK.python` /
  `CLDK.typescript` (lines ~128–243):
  ```python
  @staticmethod
  def <lang>(
      project_path: str | Path | None = None,
      *,
      analysis_level: str = AnalysisLevel.symbol_table,
      target_files: List[str] | None = None,
      eager: bool = False,
      backend: <Lang>Backend | None = None,
  ) -> <Lang>Analysis:
      # project_path is optional ONLY when backend is a Neo4jConnectionConfig (graph read out of band)
      ...
      return <Lang>Analysis(project_dir=_normalize_project_path(project_path),
                            analysis_level=analysis_level, target_files=target_files,
                            eager_analysis=eager, backend=backend)
  ```
- **Extend the legacy `CLDK(language=...).analysis(...)` shim** to route `"<lang>"` to the new
  factory method (keep the deprecated path working).
- **(Optional) tree-sitter dispatch** in `treesitter_parser()` / `tree_sitter_utils()` if you
  ship a `Treesitter<Lang>` parser/sanitizer. Skip if not providing them.

### 5. Dependencies & version pin — `pyproject.toml`
- If the backend is a pip package: add it to `dependencies` (as Python does:
  `"codeanalyzer-python==X"`).
- If it's a subprocess binary: pin the analyzer's PyPI wheel that carries the binary
  (`"codeanalyzer-<lang>==X"`) and record it under `[tool.backend-versions]`:
  ```toml
  [tool.backend-versions]
  codeanalyzer-<lang> = "0.1.0"
  ```
- If you ship the Neo4j backend, keep the `neo4j` driver an **optional extra**
  (`pip install cldk[neo4j]`) and import it lazily — never a hard dependency.
- Add a tree-sitter grammar dep (`tree-sitter-<lang>==X`) only if you ship a parser.

### 6. Tests — `tests/analysis/<lang>/`
Full criteria and patterns in `sdk-testing.md`. The suite has three-to-four files, mirroring
the existing per-language dirs (`tests/analysis/java/`, `.../python/`, `.../typescript/`):

- `test_<lang>_analysis.py` — **mocked** facade tests. Patch the wrapper's `_run_and_parse()`
  (or equivalent) to return a pre-built `<Lang>Application` from a fixture JSON. Tests never
  invoke the binary. See `sdk-testing.md § 2` for minimum coverage.
- `test_<lang>_backend_contract.py` — assert the concrete backend implements every method on
  the `<Lang>AnalysisBackend` ABC (see *The facade abstraction* below).
- `test_<lang>_e2e.py` — **E2E** tests. Use `pytest.mark.skipif(shutil.which("codeanalyzer-<lang>")
  is None, ...)` so they skip cleanly on CI without the binary. See `sdk-testing.md § 3`.
- `test_<lang>_neo4j_backend.py` / `test_<lang>_neo4j_selection.py` — **only if** you ship a
  Neo4j backend: parity against the local backend, and backend-selection-by-config-type.
- Fixture `analysis.json` under `tests/resources/<lang>/analysis_json/` for mocked tests; a
  real project fixture under `tests/resources/<lang>/application/` for E2E, wired in
  `tests/conftest.py` following the existing per-language fixtures.

## The facade abstraction

**Two structural facts, and they pull in different directions:**

1. **The facade classes still have no shared base.** `JavaAnalysis`, `PythonAnalysis`,
   `TypeScriptAnalysis`, `CAnalysis` are independent classes that *mirror each other's method
   names by convention*; the factory methods return the union type and callers duck-type.
   Nothing enforces the *facade* vocabulary — reproduce it deliberately and match
   names/signatures exactly, because drift won't be caught by the type system.
2. **The backend layer now DOES have an ABC** (this changed since the older SDK). Each language
   defines `<Lang>AnalysisBackend(ABC)` in `cldk/analysis/<lang>/backend.py`, and **both**
   backends — the local `<Lang>Codeanalyzer` and the read-only `<Lang>Neo4jBackend` — subclass
   it. The ABC is the contract that guarantees the two backends answer identically; a
   `test_<lang>_backend_contract.py` asserts every abstract method is implemented.

**Shape — three layers now, not two:**

```
<Lang>Analysis (public facade)                     ── picks backend by config type, forwards queries
   read-only query vocabulary                          │
        │                                              ▼
        └─ backend: <Lang>AnalysisBackend (ABC)  ◀── isinstance(backend_cfg, Neo4jConnectionConfig)?
                ├─ <Lang>Codeanalyzer   → runs binary/pkg → parses analysis.json → <L>Application
                └─ <Lang>Neo4jBackend   → bulk Cypher fetch → reconstructs <L>Application (parity)
```

The facade holds almost no logic: it forwards to `self.backend` and builds a couple of *derived*
views (NetworkX graphs). Both backends produce the **same** `<L>Application`, so the facade code
above them is backend-agnostic.

**Constructor contract.** Common params: `project_dir`, `analysis_level`, `target_files`,
`eager_analysis`, and `backend=<Lang>Backend | None` (the config object). Note the changes from
the older SDK: **`analysis_backend_path` is gone** (the binary ships with the packaged
`codeanalyzer-<lang>` dependency), and **`analysis_json_path` folded into `cache_dir`** —
carried on the `CodeAnalyzerConfig` and resolved to a language-keyed subdirectory by
`cache_subdir(cache_dir, project_dir, "<lang>")` (default root `<project>/.codeanalyzer/`).
Language-specific backend knobs now live on the config subclass (Python `use_ray`, TS
`tsc_only`), not as facade constructor params. Java keeps a deprecated `source_code` param.

**Implement in priority tiers** (mirror the names exactly unless noted):

- **Tier A — lifecycle / whole-program (the must-haves; make CLDK usable):**
  `get_application_view`, `get_symbol_table`, `get_call_graph` (→ `nx.DiGraph`),
  `get_call_graph_json`, `get_callers`, `get_callees`, `get_class_call_graph`,
  `get_class_hierarchy`. Note `get_call_graph` and `get_class_hierarchy` are **derived** —
  `get_call_graph` from `application.call_graph` (nodes = callable **ids**), `get_class_hierarchy`
  from each type node's `base_types`/`interfaces` (ids) — the rest index into the tree.
  **(Tier E — bulk/program-graph accessors** that v2 newly makes modelable: `get_program_graph(sig)`
  over `body{}` + `cfg`/`cdg`/`ddg`/`summary`, slicing/taint over `ddg ∪ param_in ∪ param_out`,
  `flows_to_statement("file:line:col")` — add these as *new* methods; don't retrofit existing
  signatures.)
- **Tier B — symbol-table navigation (should-have):** `get_classes` / `get_class` /
  `get_classes_by_criteria`; `get_methods` / `get_methods_in_class` / `get_method` /
  `get_method_parameters` / `get_constructors`; `get_fields`; `get_imports`;
  `get_nested_classes` / `get_sub_classes` / `get_extended_classes` /
  `get_implemented_interfaces`; and the **per-file accessor**, which is named for the language —
  `get_java_file`/`get_java_compilation_unit` vs `get_python_file`/`get_python_module` → so
  `get_<lang>_file` / `get_<lang>_<unit>`.
- **Tier C — syntactic / tree-sitter (optional, only if you ship a grammar):** `is_parsable`,
  `get_raw_ast`, plus sanitizer utils via `tree_sitter_utils`.
- **Tier D — semantic / framework views (only if your analyzer populates them):** entrypoints
  (`get_entry_point_classes`/`_methods`, `get_service_entry_point_*`), CRUD
  (`get_all_crud_operations` + create/read/update/delete), `get_test_methods`,
  comments/docstrings. This is the framework/domain axis — it just surfaces what the analyzer's
  detection produced.
- **Tier E — bulk accessors (recommended once the Neo4j backend exists):** coarse-grained
  batch reads that avoid per-callable fan-out — `get_callables_overview()` (lightweight list of
  every callable without full reconstruction), `get_method_bodies(signatures)`,
  `get_decorated_callables(decorators)`, `get_callsites_for(signatures)`. These matter most for
  the Neo4j backend, where each fine-grained accessor would otherwise be a separate round-trip;
  declare them on the ABC so both backends provide them. Python added these first
  (`python_analysis.py`) — anchor on it.

**Minimal viable facade** = Tier A + `get_classes`/`get_class`/`get_methods`/`get_method`.
Everything else is progressive — don't stub Tier D methods the analyzer can't yet populate;
omit them until the data exists.

**Language-flavored divergence is expected** at the leaves: per-file unit (`*_compilation_unit`
vs `*_module`), decoration (`get_methods_with_annotations` vs `get_methods_with_decorators`),
comments (`get_comments_in_a_method` vs `get_all_docstrings`). Reproduce Tier A verbatim; name
the leaf accessors for your language.

## Common pitfalls

### Null-safe Pydantic models (`_NullSafeBase`)

Languages like Go serialize nil/empty slices as JSON `null`, not `[]`. Pydantic v2
`List[T]` rejects `null` with a `ValidationError` ("Input should be a valid list"). Fix
this with a shared base class that coerces null → empty collection **before** Pydantic
validates:

```python
from typing import Any
from pydantic import BaseModel, model_validator

class _NullSafeBase(BaseModel):
    @model_validator(mode="before")
    @classmethod
    def _coerce_null_collections(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data
        for field_name, field_info in cls.model_fields.items():
            if data.get(field_name) is None and field_info.default_factory is not None:
                try:
                    sentinel = field_info.default_factory()
                    if isinstance(sentinel, (list, dict)):
                        data[field_name] = sentinel
                except Exception:
                    pass
        return data
```

Have **all model classes** inherit from `_NullSafeBase` instead of `BaseModel` directly.
This affects any language whose serializer writes null for empty collections: Go (nil
slices), Rust (serde skips fields / emits null), C with cJSON, Swift/ObjC with nil
NSArray. Add a mocked test that passes a `null` list field and confirms the model loads
without error. (Note the existing TS models use a strict `_Base` with `extra="forbid"` for
the opposite goal — catching drift; the two bases are not in conflict, pick per language.)

### `_level_flag()` must emit integers, not enum names — and v2 has four levels

The CLI flag is `-a`/`--analysis-level` with **integer** values `1|2|3|4` (v2:
1 = symbol table, 2 = + call graph, 3 = + intraprocedural `cfg`/`cdg`/`ddg`, 4 = + interprocedural
`param_*`/`summary`). The Python `AnalysisLevel` enum has *string* values, so the wrapper must map
explicitly to the integer:

```python
@staticmethod
def _level_flag(analysis_level: str) -> str:
    return {
        AnalysisLevel.symbol_table: "1",
        AnalysisLevel.call_graph: "2",
        AnalysisLevel.program_dependency_graph: "3",
        AnalysisLevel.system_dependency_graph: "4",
    }.get(analysis_level, "1")
```

Sending `--analysis-level symbol_table` (the string) is rejected or silently mis-read — a bug
invisible to mocked tests, only caught by E2E (`sdk-testing.md § 3`). On the *read* side, don't
infer the level from which keys are present — read **`payload.max_level`** (the authoritative
marker); `get_call_sites` still works at L1 (call sites are `body` nodes from L1), the dataflow
overlays appear from L3/L4.

### Binary discovery: `shutil.which()` vs bundled artifact

The Java wrapper resolves a JAR **bundled inside the Python package** (`_locate_jar()` under
`cldk/analysis/java/codeanalyzer/jar/`); the TS wrapper reads `$CODEANALYZER_TS_BIN` or
`codeanalyzer_typescript.bin_path()` from its pinned PyPI package. For a language whose binary
is built separately and lives on PATH, prefer `shutil.which` with a clear error:

```python
import shutil

def _find_binary(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise FileNotFoundError(
            f"{name} not found on PATH. "
            f"Build it from the codeanalyzer-<lang> repo and install to e.g. ~/.local/bin/."
        )
    return path
```

Call this in the wrapper constructor. The error message should tell the user exactly how
to fix it — don't just say "binary not found".

## Definition of done for this surface
- `CLDK.<lang>(project_path=<fixture>)` (and the legacy `CLDK(language="<lang>").analysis(...)`
  shim) returns a facade whose `get_symbol_table()` is non-empty and `get_call_graph()` builds
  a NetworkX graph with **no dangling nodes** (every edge endpoint is a real node **id** in the
  tree) — the node key is now the `can://` id, with `signature` as a node attribute.
- The **public API is unchanged**: every pre-migration accessor keeps its name and return type
  (verified against the frozen API surface); the `<L>*` return types are the shared views.
- Mocked tests pass under the SDK's runner (`uv run pytest` / `pytest`) with the backend
  patched; E2E tests exist and skip cleanly when the binary is absent.
- The concrete backend implements every `<Lang>AnalysisBackend` ABC method
  (`test_<lang>_backend_contract.py`).
- `pyproject.toml [tool.backend-versions]` is pinned to the released **v2 (major-bumped)** analyzer
  version — only after both analyzer and SDK are cut (`codeanalyzer-backend/references/schema-migration.md`).
- All changes sit on the `add-<lang>-support` branch; summarize the diff for the user.
