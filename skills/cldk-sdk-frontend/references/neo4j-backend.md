# The SDK Neo4j backend (optional second backend)

Each language facade selects between **two backends** by the *type* of the `backend=`
config object (`cldk/analysis/commons/backend_config.py`):

- `CodeAnalyzerConfig` (or a `<Lang>CodeAnalyzerConfig` subclass) → the **local** backend
  `<Lang>Codeanalyzer` — runs the packaged binary, parses `analysis.json`.
- `Neo4jConnectionConfig` → the **read-only Neo4j** backend `<Lang>Neo4jBackend` —
  answers the same queries over a graph populated **out of band** (by someone running
  `codeanalyzer-<lang> --emit neo4j`; the projection is
  `skills/codeanalyzer-backend/references/neo4j-projection.md`). **The SDK never writes
  the graph.**

Ship the Neo4j backend **only if** your analyzer emits a graph. It is optional at every
layer, so it must never become a hard dependency.

## Full-depth graph assumption

`--emit neo4j` is **level-agnostic** on the analyzer side — it always projects everything
the analyzer implements (symbol table, call graph, and the full SDG once L3–L4 exist). So
the Neo4j backend takes **no analysis-level knob**: it serves whatever is in the graph and
derives its effective level from what it finds (as the Java Neo4j backend does for
`call_graph`), and program-graph accessors need no gating. This is the mirror image of
the local backend, which does gate the JSON path by `-a`.

## Connection contract

`neo4j_backend.py` — `<Lang>Neo4jBackend(<Lang>AnalysisBackend)`. Constructor takes
`uri`, `username`, `password`, `database`, and `application_name`. It **lazily imports**
the driver so the dependency stays optional:

```python
try:
    from neo4j import GraphDatabase
except ModuleNotFoundError as e:
    raise CodeanalyzerExecutionException(
        "The Neo4j backend requires the 'neo4j' driver. Install it with "
        "`pip install neo4j` (or `pip install cldk[neo4j]`)."
    ) from e
```

- `application_name` is **required** — the queries scope every match to
  `(:Application {name: $app})` (now `can://<lang>/<app>`); it must equal the
  `--app-name` the graph was loaded with. A mismatch returns an empty graph, not an
  error, so validate it early.
- On construction the backend bulk-loads the modules, **reconstructs the shared
  `Application`** (the `cldk/models/cpg/` model — not a per-language tree), derives the
  NetworkX call graph, then every ABC method reads from that reconstructed model,
  identical to the local backend.
- `project_dir` is **optional** when the backend is `Neo4jConnectionConfig` — the graph
  is read over Bolt, there is nothing local to analyze. The `CLDK.<lang>()` factory
  enforces this (it only requires `project_path` for the local backend).

## Query-surface parity with the local backend

The whole point of the `<Lang>AnalysisBackend` ABC is that **both backends are
interchangeable behind the facade**. The Neo4j backend achieves this by *reconstructing
the canonical shared `Application` tree* from the graph, then delegating to the same
indexing/query logic the local backend uses:

```
<lang>/neo4j/
  config.py            # small config plumbing
  neo4j_backend.py     # <Lang>Neo4jBackend(<Lang>AnalysisBackend)
  reconstruct.py       # graph rows → the shared cldk/models/cpg/ Application the local backend queries
```

**`reconstruct.py` is the inverse of the analyzer's `project()`.** The graph is a
**near-identity projection** of the tree (a graph DB has no nesting, so containment is
rendered as typed edges), so reconstruction MATCHes the containment edges and re-nests
them. Node labels are the **kinds** (`Module`, the type-kinds `Class`/`Struct`/
`Interface`/…, `Callable`, the body kinds `Statement`/`Call`/`Entry`/`FormalIn`/…); the
`can://` **`id` is the merge key** (one `(:Node {id})` MATCH regardless of kind — the
graph-side reflection of the single `Node` model), so the builder is **one
`node(props, labels)` keyed on `kind`** plus a handful of edge builders. Rebuild each
layer onto its correct owner:

- **Containment** (`HAS_MODULE`/`DECLARES`/`HAS_CALLABLE`/`HAS_FIELD`/`HAS_CFG_NODE`) →
  re-nest into `symbol_table{}` → `types{}`/`functions{}` → `callables{}`/`fields{}` →
  `body{}`.
- **Overlays** onto their scope: `CALLS` → `application.call_graph`;
  `CFG`/`CDG`/`DDG`/`SUMMARY` → the callable's lists (grouped by whichever callable
  `HAS_CFG_NODE` the src); `PARAM_IN`/`PARAM_OUT` → `application.param_in`/`param_out`.
  Edge props (`weight`, `prov`, `kind`, `var`) map straight across.

There is **no `callsite`/`call_edge` node family** — a call is a `Call` body node; the
call graph is a `CALLS` relationship. Keep `reconstruct.py` in lockstep with the
analyzer's `neo4j-projection.md` and the shared `schema.neo4j.json` version.

## Backend selection (in the facade `__init__`)

```python
from cldk.analysis.commons.backend_config import Neo4jConnectionConfig, <Lang>CodeAnalyzerConfig

def __init__(self, project_dir=None, *, analysis_level=..., target_files=None,
             eager_analysis=False, backend=None):
    if isinstance(backend, Neo4jConnectionConfig):
        self.backend = <Lang>Neo4jBackend(
            neo4j_uri=backend.uri, neo4j_username=backend.username,
            neo4j_password=backend.password, neo4j_database=backend.database,
            application_name=backend.application_name)
    else:  # CodeAnalyzerConfig / <Lang>CodeAnalyzerConfig / None (default)
        self.backend = <Lang>Codeanalyzer(project_dir, backend or <Lang>CodeAnalyzerConfig(), ...)
```

## Usage

```python
from cldk import CLDK
from cldk.analysis.commons.backend_config import Neo4jConnectionConfig

analysis = CLDK.<lang>(backend=Neo4jConnectionConfig(
    uri="bolt://localhost:7687", username="neo4j", password="neo4j",
    application_name="my_app"))   # must match the graph's --app-name
analysis.get_symbol_table()       # same API, answered from the graph
```

## Parity = same model modulo documented lossiness

Parity is **not** byte-identity — it is "same canonical model modulo documented
lossiness." State each gap in the backend docstring and the parity test:

- **Body-text lossiness.** `.code`/`get_method_body()` is a slice of `module.source`. If
  the graph didn't project `source` (a size choice), the reconstructed model has empty
  body text — a gap the local backend never has. This is the canonical example.
- Edges to synthetic external/library targets may be absent.
- Framework-specific views (e.g. Java CRUD) may not be projected.
- Separate analyzer runs can introduce minor call-graph variance.

## Testing
- `test_<lang>_neo4j_backend.py` — **parity** against the local backend on the same
  fixture (symbol-table key sets match; call-graph node/edge counts match within the
  documented tolerances).
- `test_<lang>_neo4j_selection.py` — passing `Neo4jConnectionConfig` constructs the Neo4j
  backend and passing a `CodeAnalyzerConfig` constructs the local one (selection-by-type).
- Skip both when no Neo4j is reachable (`pytest.mark.skipif`). See `sdk-testing.md`.
