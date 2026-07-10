# The codeanalyzer CLI contract

The SDK facade invokes the analyzer as a subprocess by shelling out with a fixed set of flags. Use the
target ecosystem's idiomatic CLI framework (Picocli for Java, Typer for Python, a Node CLI lib for
TS), but expose **these flags with these meanings** so one facade code path works across every
analyzer.

## Core flags

| Flag | Meaning | Notes |
| --- | --- | --- |
| `-i, --input <path>` | Project root to analyze | Required (except `--emit schema`) |
| `-o, --output <dir>` | Directory to write `analysis.json` | **When omitted, print compact JSON to stdout.** The facade relies on this |
| `-f, --format <json\|msgpack>` | Serialization format | Default `json`; only `json` need be implemented — see Flag validation |
| `-a, --analysis-level <1\|2\|3\|4>` | Progressive analysis depth (the canonical levels) | See the level table below. `-a 1` (symbol table only) is the default |
| `--joern` (or similar) | Add **framework** call-graph enrichment | A **separate toggle, not an `-a` level** (the orthogonal precision axis); off by default |
| `--graph-field-depth <k>` | Access-path k-limit for L3/L4 dataflow | Default 3; mandatory for L4 fixpoint termination |
| `-t, --target-files <paths>` | Restrict analysis to specific files | Incremental analysis |
| `--skip-tests / --include-tests` | Skip test trees | Default skip |
| `--eager / --lazy` | Force clean rebuild vs. reuse cache | Default lazy |
| `-c, --cache-dir <dir>` | Where caches / intermediate DBs live | |
| `-j, --jobs <n>` | Worker parallelism | Default: CPU cores. Output must be **byte-identical** across `-j` values (`references/testing-and-validation.md`); applies to the L1 per-file build and the L3/L4 per-callable fan-out alike |
| `-v` | Verbosity (repeatable) | Diagnostics to **stderr** only |

### The `-a` level ladder (the canonical levels)

`-a` is a single progressive axis mirroring
`skills/designing-cldk-changes/references/canonical-schema.md`; each level *implies* the ones below it:

| `-a` | Adds | Reference |
| --- | --- | --- |
| `1` | symbol table — the tree to callable depth + `call` nodes | `references/level-1-symbol-table.md` |
| `2` | `call_graph` edges (resolver-based); backfills `callee` | `references/level-2-call-graph.md` |
| `3` | intraprocedural dataflow — `body` statements + `cfg`/`cdg`/`ddg` (syntactic) | `references/level-3-intraprocedural-dataflow.md` |
| `4` | interprocedural SDG — synthetic vertices + `param_in`/`param_out`/`summary` + semantic `ddg` | `references/level-4-interprocedural-sdg.md` |

Framework enrichment (`--joern`/…) is **orthogonal** to `-a` — its edges merge into `call_graph` with
provenance; it is not a level. Don't conflate the two axes.

## Neo4j projection flags

The second output surface (full spec in `references/neo4j-projection.md`); present on all mature
analyzers.

| Flag | Meaning |
| --- | --- |
| `--emit <json\|neo4j\|schema>` | Output target. `json` (default) → `analysis.json`; `neo4j` → `graph.cypher` or a live Bolt push **at full implemented depth**; `schema` → the static `schema.neo4j.json` contract (needs no `-i`) |
| `--neo4j-uri <uri>` | Live Bolt push target. Omit → write `graph.cypher`. Env `NEO4J_URI` |
| `--neo4j-user <user>` | Env `NEO4J_USERNAME`, default `neo4j` |
| `--neo4j-password <pw>` | Env `NEO4J_PASSWORD`, default `neo4j` |
| `--neo4j-database <db>` | Env `NEO4J_DATABASE`, optional |
| `--app-name <name>` | `:Application` anchor name. Default: input dir name. The SDK's Neo4j backend must use the **same** name |

Precedence for these: **explicit flag > env var > default**.

**Levels gate the JSON path only.** With `--emit neo4j` the analyzer always runs at maximum
implemented depth and projects the full graph; passing `-a`/`--graph-field-depth` alongside `--emit
neo4j` is an **explicit error** (`references/neo4j-projection.md § Depth rule`).

## Flag validation

Any flag whose value is unrecognized or unimplemented **must return a non-zero exit with a clear
message** — never silently ignore or fall back. Silent fallback is worse than an error: the caller
asked for one thing, got another, and processes it wrongly. The SDK passes flags like `--format` and
`--emit` straight through, so it has no way to detect a silently-ignored flag. Example:

```
error: msgpack output is not yet implemented; use --format json
```

## Exit codes and stdout/stderr discipline

The facade depends on a strict channel split:

- **Exit `0`** — a successful run: `<output>/analysis.json` exists and conforms to the keystone (or,
  with no `-o`, the same JSON is on stdout).
- **Non-zero exit** — a flag/validation error (unimplemented `--format`, `-a`/`--emit` conflict,
  missing required `-i`) or a fatal internal error. Fatal only; **partial resolution is not a failure**
  — a symbol table with some unresolved types still exits `0` (project-materialization degrades
  gracefully).
- **stdout is the data channel.** When `-o` is omitted, stdout carries **only** the analysis JSON —
  nothing else, so the facade can parse it directly. No log lines, no progress bars on stdout, ever.
- **stderr is the diagnostics channel.** All logging, progress (`-v`), warnings, and error messages go
  to stderr, so they never corrupt the JSON the facade reads.

## The output contract

The only thing the facade depends on is that, after a successful run, **`<output>/analysis.json`
exists and conforms to the keystone** (or the same JSON is on stdout). Everything else — cache files,
framework databases, build artifacts — is internal.

## Example invocations the facade will issue

```
# symbol table only, JSON to a temp dir
codeanalyzer-ts -i /path/to/project -o /tmp/cldk-xyz -a 1

# symbol table + call graph, with caching
codeanalyzer-ts -i /path/to/project -o /tmp/cldk-xyz -a 2 -c ~/.cldk/ts-cache

# intraprocedural dataflow, deterministic single-worker (debug)
codeanalyzer-ts -i /path/to/project -o /tmp/cldk-xyz -a 3 -j 1

# single-file incremental, JSON to stdout
codeanalyzer-ts -i /path/to/project -t src/foo.ts
```
