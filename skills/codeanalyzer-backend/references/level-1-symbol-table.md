# L1 — build the tree (symbol table)

The first level of the additive schema
(`skills/designing-cldk-changes/references/canonical-schema.md`): grow the **containment tree to
callable depth** — `application → symbol_table{module} → types{}/functions{} → callables{}` — file by
file. This is the floor everything else hangs off. You build it by **studying how the mature
reference analyzers do it** (Java's `SymbolTable`, Python's `symbol_table_builder`) and replicating
the pattern for the new language — they have already solved file discovery, per-file building,
caching, and the whole-project / target-files / single-source modes.

## What L1 populates (the v2 shape)

Every node carries an **`id`** (the `can://…` path), a **`kind`**, and a **`span` with byte
offsets**. Above the callable the containment is **named maps** — `types{}`, `functions{}`,
`callables{}`, `fields{}` — keyed for lookup, each node holding its full id. Specifically:

- **`module`** (per file): its `kind`, `span`, `package`/`namespace`, `imports[]`, `types{}`,
  `functions{}`, `content_hash`, and — crucially — **`source`: the whole file's text, stored once.**
  Every node's text is a **slice** of `module.source[span.bytes]`; there is no per-callable `code`
  field. (`get_method_body(sig)` = `module.source[callable.span.bytes]`.)
- **`type`** (`class`/`struct`/`interface`/`enum`/`trait`/…): the specific `kind` (not a pile of
  `is_*` booleans), `base_types[]`, `interfaces[]`, `modifiers[]`, structured `decorators[]`,
  `callables{}`, `fields{}`, `nesting`.
- **`callable`** (`function`/`method`/`constructor`/…): `signature` (the last segment of its id, from
  the one `signatureOf()`), ordered `parameters[]`, `return_type`, `error_channel[]` (the generalized
  channel — Go `(T, error)`, Rust `Result<T,E>`, Java `throws` — one field, not `thrown_exceptions`),
  `modifiers`, `decorators`, `metrics.cyclomatic`, cheap `refs`, and a **`body{}`** map that at L1
  holds **only `call` nodes**.
- **`call` nodes in `body`**: recorded at L1 as `{ kind:"call", span, callee:null, arguments:[…] }`.
  Recording call sites here is what makes `get_call_sites` an L1 accessor; **`callee` stays `null`
  until L2 backfills it** (the one sanctioned refinement). L1 records sites; it does **not** resolve
  them into edges.

Populate the **language-native kinds/fields** the spec confirmed for this language (the parity
clause: add at the leaves, never rename the shared spine).

## The pattern to replicate

The three reference analyzers share one shape: **discover files → (cache check) → per-file build a
Module → put it in the map keyed by relative path**, with three entry modes.

1. **Discover source files.** Recursively glob the language's extensions; skip vendored and test
   trees (`node_modules`, `.venv`, `vendor`, test dirs), honoring `--skip-tests`. Sort for
   deterministic output.
2. **Compute a stable `file_key`** — the path **relative to the project root** (the `symbol_table`
   key). It must be identical across runs so caching and the SDK's file lookups work. Never absolute,
   never `..`-prefixed.
3. **Per file, cache-check then build.** If a prior `analysis_cache.json` has this file and its
   `content_hash`/`last_modified`/`file_size` are unchanged, reuse the cached `module`. Otherwise run
   the **per-file builder** (the analog of `build_pymodule_from_file` / `processCompilationUnit`):
   parse with the structural tool, retain the file's text as `module.source`, walk the tree, fill
   `types`/`functions`/native kinds/`callables` — each node with `id`, `kind`, `span` (byte offsets)
   — and record the `call` nodes in each callable's `body` with `callee:null`. Stamp cache metadata.
4. **Assemble** `symbol_table[file_key] = module` for every file.
5. **Support the three CLI modes** (`references/cli-contract.md`): whole-project (extractAll-style),
   `-t/--target-files` incremental (extract-style), and optionally single-source.
6. **Parallelism is optional** — add the `-j` per-file fan-out only once the serial path is correct,
   and keep output deterministic regardless.

Dependency materialization runs **before** this pass so the resolver can populate type fields
(`references/project-materialization.md`); if your structural tool also resolves (ts-morph, clang),
the L1 type fields are filled here, otherwise they fill when the resolver runs at L2.

## Keep the builder modular

The per-file builder is the largest single piece, so it is exactly where modularity slips. Make it a
**cohesive unit split by node kind** — a class (or one focused module per kind: `class_builder`,
`callable_builder`, …) sharing one resolver/context object — the way Python's `SymbolTableBuilder`
groups `_add_class`/`_callables`/`_call_sites`/…, **not** the flat pile of 36+ free functions
`codeanalyzer-ts` shipped. See `references/analyzer-architecture.md` rule 2.

## Per-construct fixture checklist

Build a tiny fixture project that exercises **every** language-specific field you added — a field
with no test is a silent regression point (compilation passes, validation passes, the value is wrong
in production). Assert a **specific value**, not just `len > 0`:

- Every added-beyond-spine field with a concrete assertion (a method whose receiver type is non-empty;
  a callable whose `metrics.cyclomatic > 1`; a decorator with structured args).
- At least one **multi-file compilation unit** (two+ source files in one package/module/namespace) —
  the cross-file method-attachment bug surfaces only here.
- Both **exported and unexported** symbols; assert the unexported one's visibility encoding.
- The language's idiomatic **compound-return / error pattern** into `error_channel` (`(T, error)`,
  `Result<T,E>`, `throws`).
- At least one **variadic / spread** parameter, if the language has them, with `is_variadic` asserted.
- Each callable carrying its **`call` nodes** with `callee:null` and correct `arguments`.
- One file where a callable's text = `module.source[span.bytes]` exactly (the `get_method_body` slice).

## The L1 gate

Run the analyzer on the fixture and confirm all of:

- output **validates** against the SDK `Application` model (`Application(**json.load(...))` does not
  raise);
- `symbol_table` is non-empty and keyed by **stable relative paths** (assert no key is absolute or
  `..`-prefixed);
- a known file's `module` has the expected `types`/`functions`, a `source` blob, and callables
  carrying `call` nodes with `callee:null`; the `get_method_body` slice matches;
- `can://` ids (≥ callable) are stable across two runs on unchanged source;
- **re-running reuses cache** for unchanged files (no rebuild; `analysis.json` mtime unchanged).

Only when this is green do you advance to L2 (`references/level-2-call-graph.md`). Full gate commands
and fixture rules: `references/testing-and-validation.md`.
