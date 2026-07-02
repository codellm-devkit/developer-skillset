# L1 — build the tree (symbol table, file by file)

The first level of the additive schema (`canonical-schema.md`): grow the **containment tree to
callable depth** — `application → symbol_table{module} → types{}/functions{} → callables{}` —
file by file. This is the floor everything else hangs off. You build it by **studying how the
mature reference analyzers do it** and replicating the pattern for the new language — they have
already solved file discovery, per-file building, caching, and the whole-project / target-files /
single-source modes.

**v2 shape (vs the old flat symbol table):** every node carries an `id` (the `can://` path), a
`kind`, and a `span` **with byte offsets**; the **module stores the whole file's `source` once**
(all node text slices off it — no per-callable `code`); and call sites are recorded as `call`
nodes in each callable's `body` with `callee: null` (so `get_call_sites` works at L1; L2 backfills
`callee`). The tree is otherwise the named-map hierarchy of `canonical-schema.md`.

## Anchor: how Java and Python construct the symbol table

**Java** — `codeanalyzer-java/src/main/java/com/ibm/cldk/SymbolTable.java`:
- `extractAll(Path projectRootPath)` — whole-project build. Discovers and parses each
  compilation unit, then `symbolTable.put(<file path>, processCompilationUnit(cu))`. Returns
  `Map<String, JavaCompilationUnit>` (+ parse problems).
- `extract(Path root, List<Path> targetFiles)` — incremental build over specific files.
- `extractSingle(String code)` — single-source mode (keys a pseudo-path).
- Driven from `CodeAnalyzer.run()`: `extractAll(input)` normally, `extract(input, targetFiles)`
  when `-t` is given.

**Python** — `codeanalyzer-python/codeanalyzer/core.py` + `syntactic_analysis/symbol_table_builder.py`:
- `core.py` iterates `for py_file in self.project_dir.rglob("*.py")`, computes a stable
  `file_key`, and for each file: if cached and `_file_unchanged(py_file, cached)` →
  reuse the cached `PyModule`; else `build_pymodule_from_file(py_file) -> PyModule`, then
  `symbol_table[file_key] = py_module`.
- `symbol_table_builder.build_pymodule_from_file(py_file)` is the **per-file builder**: parses
  with `ast`, walks the tree, and fills the `PyModule` (classes, functions, callsites, imports,
  comments, variables) per the schema.
- Optional Ray parallelism for large projects; test/vendored trees skipped.

The shared shape: **discover files → (cache check) → per-file build a Module → put it in the
map keyed by path**, with three entry modes (all / target-files / single-source).

## The pattern to replicate for the new language

1. **Discover source files.** Recursively glob the language's extensions (`*.ts`/`*.tsx` for
   TypeScript, `*.go` for Go). Skip vendored and test trees (`node_modules`, `.venv`,
   `vendor`, test dirs), honoring `--skip-tests`. Sort for deterministic output.
2. **Compute a stable `file_key`** — the path **relative to the project root**. This is the
   `symbol_table` key and must be identical across runs (so caching and the SDK's file lookups
   work).
3. **Per file, cache-check then build.** If a prior `analysis_cache.json` has this file and its
   `content_hash`/`last_modified`/`file_size` are unchanged, reuse the cached `module`.
   Otherwise call your **per-file builder** (the analog of `build_pymodule_from_file` /
   `processCompilationUnit`): parse with the structural tool, retain the file's text as the
   module's **`source`**, walk the tree, and fill the `module` with `types` / `functions` /
   language-native kinds / `callables` — each node with its `id`, `kind`, and `span` (with byte
   offsets). On each callable, record the **call sites as `call` nodes in `body`** (callee name +
   receiver expr + arg exprs + span, `callee: null`). Stamp the cache metadata on the `module`.
4. **Assemble** `symbol_table[file_key] = module` for every file.
5. **Support the three CLI modes** (`cli-contract.md`): whole-project (extractAll-style),
   `-t/--target-files` incremental (extract-style), and optionally single-source.
6. **Parallelism is optional** (the Ray analog) — only add it once the serial path is correct,
   and keep output deterministic regardless.

## Keep the builder modular (don't ship a flat function pile)
The per-file builder is the largest single piece of the analyzer, so it is exactly where
modularity slips. Python's `SymbolTableBuilder` is ~968 lines **but cohesive**: one class whose
private methods are grouped *per node kind* — `_add_class`, `_callables`, `_class_attributes`,
`_callable_parameters`, `_pydecorators`, `_call_sites`, `_module_variables`,
`_cyclomatic_complexity`, plus the `_infer_*` resolver helpers — sharing the resolver/project
state on `self`. A reader finds "how are classes built?" in one named place. Replicate **that
organization**, not just the line count: a cohesive builder (a class, or one focused
function/module per node kind) with shared context, and if it grows past a few hundred lines,
split per node kind into sibling modules under `syntactic_analysis/`. **Do not** write it the way
`codeanalyzer-ts/src/syntactic_analysis/builders.ts` did — 36+ free functions in a flat namespace
threading state through arguments, with `buildClass`/`buildInterface`/`buildEnum` scattered across
the file. See `analyzer-architecture.md` rule 2.

Keep this stage to L1 — record the `call` nodes but **don't resolve them into edges** yet. That
resolution is L2 (`backend-recipe.md`), where the same resolver maps each `call` node to its
callee (backfilling `callee`) and emits the `call_graph`. Type fields may be populated here if
your resolver is a same-tool checker; only the edge resolution is deferred.

## Verify (the L1 gate)
Run the analyzer on a tiny fixture project and confirm:
- the output **validates** against the SDK `Application` model (`Application(**json.load(...))`
  does not raise);
- `symbol_table` is non-empty and keyed by stable relative paths (no absolute, no `..`);
- spot-check one known file: its `module` has the expected `types`/`functions`, a `source` blob,
  and callables carrying `call` nodes with `callee: null`; a callable's text = `module.source`
  sliced by `span.bytes` (`get_method_body`);
- re-running reuses cache for unchanged files (no rebuild).

Only when this passes do you move to L2 (call-graph construction). Full criteria:
`testing-and-validation.md`.
