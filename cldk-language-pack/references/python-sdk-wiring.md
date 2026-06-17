# Wiring the new language into the Python SDK

Once `codeanalyzer-<lang>` emits a conformant `analysis.json`, the second surface is the
CLDK Python SDK (`python-sdk/`). The SDK is the user-facing API: `CLDK(language="<lang>")
.analysis(project_path=...)`. Adding a language means creating two parallel module trees and
registering a dispatch branch. **Do all of this on a git branch in `python-sdk`** (the user
chose branch-based edits) so the changes are reviewable and reversible.

Pick the worked example to copy based on how your analyzer is invoked:
- **Subprocess binary/JAR** (TS, Go, most new languages) → copy the **Java** pattern
  (`cldk/analysis/java/`, `cldk/models/java/`). The facade shells out and parses `analysis.json`.
- **In-process pip package** (only if the analyzer is written in Python) → copy the **Python**
  pattern (`cldk/analysis/python/`), which imports the backend and calls `.analyze()`.

## Branch first
```
cd python-sdk
git checkout -b add-<lang>-support
```
Confirm the working tree is clean before branching; if not, surface that to the user rather
than committing unrelated changes.

## Files to create / edit (checklist)

### 1. Models — `cldk/models/<lang>/`
- `models.py` — Pydantic models mirroring `schema-reference.md` **field-for-field** (every
  shared field, not a subset): `<L>Application`, `<L>Module`, `<L>Class`, `<L>Callable`,
  `<L>Callsite`, `<L>CallEdge`, the leaf models (Import/Comment/Parameter/Decorator/Symbol/
  VariableDeclaration/ClassAttribute), plus language node kinds (`<L>Interface`, `<L>Enum`,
  `<L>Struct`, …). Use the **identity-only** `<L>CallEdge` (bare-string `source`/`target`),
  not Java's rich-edge model. Field names must match the JSON keys exactly so
  `<L>Application(**json.load(f))` validates. **Build these models first** — they are both the
  SDK binding and the validation target the analyzer's output is checked against.
  These `<L>` models are also where the language's **own** node kinds and fields live: when the
  analyzer expands the schema (`schema-reference.md`), add the matching field/model here in the
  same change so output keeps validating. Pydantic ignores unknown JSON keys by default, so an
  analyzer field with no model field is silently dropped on load — define it on both sides.
  (For loud failures on drift while developing, set `model_config = ConfigDict(extra="forbid")`.)
- `__init__.py` — export the public model names.
- Copy `cldk/models/java/models.py` as the structural template (it is the subprocess-side
  schema). For an in-process Python-style backend, re-export upstream models like
  `cldk/models/python/__init__.py` does instead of redefining them.

### 2. Analysis facade — `cldk/analysis/<lang>/`
- `<lang>_analysis.py` — the `<Lang>Analysis` class. See **"The facade abstraction"** below for
  exactly what to implement and in what priority. Back it with a backend wrapper.
- `__init__.py` — export `<Lang>Analysis`.
- `codeanalyzer/codeanalyzer.py` — the backend wrapper:
  - **Subprocess pattern**: build the CLI args (`cli-contract.md`), `subprocess.run` the
    analyzer binary with `-o <tempdir>`, read `<tempdir>/analysis.json`, and validate into
    `<L>Application`. Resolve/version-pin the binary (see step 4). This mirrors
    `cldk/analysis/java/codeanalyzer/codeanalyzer.py`.
  - **In-process pattern**: `from codeanalyzer_<lang> import Codeanalyzer, AnalysisOptions`,
    construct options from the facade args, `with Codeanalyzer(opts) as a: return a.analyze()`.
    This mirrors `cldk/analysis/python/codeanalyzer/codeanalyzer.py` (note: it imports the
    backend directly — no subprocess).
  - `__init__.py` — export the wrapper class.

### 3. Core dispatch — `cldk/core.py`
Three edits, mirroring the existing Java/Python/C branches:
- **Import** near the top with the other analysis imports:
  ```python
  from cldk.analysis.<lang> import <Lang>Analysis
  ```
- **Dispatch branch** in `CLDK.analysis(...)` (the `if self.language == ... elif ...` chain,
  currently java→python→c→`NotImplementedError`). Add before the `else`:
  ```python
  elif self.language == "<lang>":
      return <Lang>Analysis(
          project_dir=project_path,
          analysis_level=analysis_level,
          analysis_json_path=analysis_json_path,
          target_files=target_files,
          eager_analysis=eager,
          # subprocess backends also take analysis_backend_path; in-process take cache_dir
      )
  ```
  Honor the existing guards (e.g. Python rejects `source_code` and `analysis_backend_path`);
  apply whichever guards fit your invocation model.
- **(Optional) tree-sitter dispatch** in `treesitter_parser()` and `tree_sitter_utils()` if
  you ship a `Treesitter<Lang>` parser/sanitizer under `cldk/analysis/commons/treesitter/`
  and `cldk/utils/sanitization/<lang>/`. Skip if not providing them.

### 4. Dependencies & version pin — `pyproject.toml`
- If the backend is a pip package: add it to `dependencies` (as Python does:
  `"codeanalyzer-python==X"`).
- If it's a subprocess binary: arrange distribution (bundled like the Java JAR under
  `cldk/analysis/<lang>/codeanalyzer/bin/`, or downloaded on first run) and record the pinned
  version under `[tool.backend-versions]`:
  ```toml
  [tool.backend-versions]
  codeanalyzer-<lang> = "0.1.0"
  ```
- Add a tree-sitter grammar dep (`tree-sitter-<lang>==X`) only if you ship a parser.

### 5. Tests — `tests/analysis/<lang>/`
Two test files — mocked and E2E. Full criteria and patterns in `sdk-testing.md`.

- `test_<lang>_analysis.py` — mocked tests. Patch the wrapper's `_run_and_parse()` (or
  equivalent) to return a pre-built `<Lang>Application` from a fixture JSON. Tests never
  invoke the binary. See `sdk-testing.md §3` for minimum coverage.
- `test_<lang>_e2e.py` — E2E tests. Use `pytest.mark.skipif(shutil.which("codeanalyzer-<lang>")
  is None, ...)` so they skip cleanly on CI without the binary. See `sdk-testing.md §4`.
- Fixture `analysis.json` under `tests/resources/<lang>/analysis_json/` for mocked tests.
- Real project fixture under `tests/resources/<lang>/application/` for E2E tests (can
  be the same fixture used by the analyzer's own `go test`).

## The facade abstraction

The single most important structural fact: **there is no shared base class or ABC.**
`JavaAnalysis`, `PythonAnalysis`, and `CAnalysis` are independent classes that *mirror each
other's method names by convention*; `CLDK.analysis()` returns the union type and callers
duck-type. Nothing enforces the interface — so reproduce the shared vocabulary deliberately and
match names/signatures exactly, because drift won't be caught by the type system.

**Shape.** A facade is a **thin, read-only, lazily-evaluated query layer over the canonical
`Application`**, backed by a swappable `<Lang>Codeanalyzer` wrapper. The facade holds almost no
logic — it forwards to the wrapper and builds a couple of *derived* views (NetworkX graphs).
Two layers:

```
<Lang>Analysis (public facade)  ──forwards to──▶  <Lang>Codeanalyzer (backend wrapper)
   read-only query vocabulary                       runs binary/pkg → parses analysis.json → Application
```

**Constructor contract.** Common params: `project_dir`, `analysis_level`, `analysis_json_path`,
`target_files`, `eager_analysis`. Then language-specific extras (Java: `source_code`,
`analysis_backend_path` to locate the JAR; Python: `cache_dir`, `use_codeql`, `use_ray`) —
supplied and guarded in the `cldk/core.py` dispatch.

**Implement in priority tiers** (mirror the names exactly unless noted):

- **Tier A — lifecycle / whole-program (the must-haves; make CLDK usable):**
  `get_application_view`, `get_symbol_table`, `get_call_graph` (→ `nx.DiGraph`),
  `get_call_graph_json`, `get_callers`, `get_callees`, `get_class_call_graph`,
  `get_class_hierarchy`. Note `get_call_graph` and `get_class_hierarchy` are **derived** — built
  from the model's edges / `base_classes` — the rest index into the model.
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
without error.

### `_level_flag()` must emit integers, not enum names

The CLI flag is `--analysis-level 1` or `--analysis-level 2` (integers). The Python
`AnalysisLevel` enum has string values (`"symbol_table"`, `"call_graph"`). The backend
wrapper must explicitly map:

```python
@staticmethod
def _level_flag(analysis_level: str) -> str:
    if analysis_level == AnalysisLevel.call_graph:
        return "2"
    return "1"
```

Sending `--analysis-level symbol_table` will either be rejected by the CLI or silently
treated as level 0. This bug is invisible to mocked tests — it only surfaces in E2E tests
(which is why `sdk-testing.md §4` mandates them).

### Binary discovery: `shutil.which()` vs `importlib.resources`

The Java wrapper uses `importlib.resources.files()` because the JAR is **bundled inside
the Python package** under `cldk/analysis/java/codeanalyzer/bin/`. For all other languages
(Go, Rust, TS), the binary is built separately and lives on PATH — do **not** bundle it.

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
- `CLDK(language="<lang>").analysis(project_path=<fixture>)` returns a facade whose
  `get_symbol_table()` is non-empty and `get_call_graph()` builds a NetworkX graph with no
  dangling nodes (every edge endpoint is a real callable signature).
- Tests pass under the SDK's runner (`uv run pytest` / `pytest`), with the backend mocked.
- All changes sit on the `add-<lang>-support` branch; summarize the diff for the user.
