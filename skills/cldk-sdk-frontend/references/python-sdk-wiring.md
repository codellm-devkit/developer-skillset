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
- `models.py` — Pydantic models mirroring the analyzer's emitted schema **field-for-field** (the
  local `schema-contract.md`, backed by the **codeanalyzer-backend** skill's exhaustive
  `schema-reference.md`) — every
  shared field, not a subset): `<L>Application`, `<L>Module`, `<L>Class`, `<L>Callable`,
  `<L>Callsite`, `<L>CallEdge`, the leaf models (Import/Comment/Parameter/Decorator/Symbol/
  VariableDeclaration/ClassAttribute), plus language node kinds (`<L>Interface`, `<L>Enum`,
  `<L>Struct`, …). Use the **identity-only** `<L>CallEdge` (bare-string `source`/`target`),
  not Java's rich-edge model. Field names must match the JSON keys exactly so
  `<L>Application(**json.load(f))` validates. **Build these models first** — they are both the
  SDK binding and the validation target the analyzer's output is checked against.
  These `<L>` models are also where the language's **own** node kinds and fields live: when the
  analyzer expands the schema (recorded in the **codeanalyzer-backend** skill's `schema-reference.md`
  and its `SCHEMA_DECISIONS.md`), add the matching field/model here in the
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
  - **Subprocess pattern**: build the CLI args (the contract the **codeanalyzer-backend** skill
    defines in its `cli-contract.md`), `subprocess.run` the
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
- `test_<lang>_analysis.py` — mirror `tests/analysis/java/test_java_analysis.py` /
  `tests/analysis/python/test_python_analysis.py`. **Mock the backend** (patch the wrapper's
  run method to return a fixture `analysis.json`) so tests don't require the binary, then
  assert `get_symbol_table()` is non-empty, the call graph builds, etc.
- Add a fixture `analysis.json` under `tests/resources/<lang>/analysis_json/` and any sample
  project fixture in `tests/conftest.py`, following the existing per-language fixtures.

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

## Definition of done for this surface
- `CLDK(language="<lang>").analysis(project_path=<fixture>)` returns a facade whose
  `get_symbol_table()` is non-empty and `get_call_graph()` builds a NetworkX graph with no
  dangling nodes (every edge endpoint is a real callable signature).
- Tests pass under the SDK's runner (`uv run pytest` / `pytest`), with the backend mocked.
- All changes sit on the `add-<lang>-support` branch; summarize the diff for the user.
