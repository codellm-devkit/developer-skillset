# Symbol Table Construction (file by file)

Once the schema is designed (`schema-design-loop.md`), this stage **populates** it: walk the
project file by file and build `symbol_table: Dict[file_path, Module]`. Like the schema, you
build this by **studying how the mature reference analyzers do it** and replicating the pattern
for the new language — they have already solved file discovery, per-file building, caching, and
the whole-project / target-files / single-source modes.

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
   `content_hash`/`last_modified`/`file_size` are unchanged, reuse the cached `Module`.
   Otherwise call your **per-file builder** (the analog of `build_pymodule_from_file` /
   `processCompilationUnit`): parse with the structural tool, walk the tree, and fill the
   `Module` with classes / functions / language-native kinds / callables — and on each callable
   the **unresolved call sites** (callee name + receiver expr + arg exprs + position,
   `callee_signature` left null). Stamp the cache metadata on the `Module`.
4. **Assemble** `symbol_table[file_key] = module` for every file.
5. **Support the three CLI modes** (`cli-contract.md`): whole-project (extractAll-style),
   `-t/--target-files` incremental (extract-style), and optionally single-source.
6. **Parallelism is optional** (the Ray analog) — only add it once the serial path is correct,
   and keep output deterministic regardless.

Keep this stage to the symbol table — record call sites but **don't resolve them into edges**
yet. That resolution is the *cheap next step* (still level 1; `backend-recipe.md` step 6), where
the same resolver maps each site to its callee. Type fields may be populated here if your
resolver is a same-tool checker; only the edge resolution is deferred to the next stage.

## Verify (the level-1 gate)
Run the analyzer on a tiny fixture project and confirm:
- the output **validates** against the SDK `<L>Application` Pydantic model
  (`<L>Application(**json.load(...))` does not raise);
- `symbol_table` is non-empty and keyed by stable relative paths;
- spot-check one known file: its `Module` has the expected classes/functions, and callables
  carry unresolved call sites with `callee_signature == null`;
- re-running reuses cache for unchanged files (no rebuild).

Only when this passes do you move to call-graph construction.
