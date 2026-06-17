# CLI family surface

The SDK facade invokes a subprocess analyzer by shelling out with a fixed set of flags. Use
the target ecosystem's idiomatic CLI framework, but expose **these flags with these
meanings** so one facade code path works across analyzers. Java (Picocli) and Python (Typer)
are the references.

| Flag | Meaning | Notes |
| --- | --- | --- |
| `-i, --input <path>` | Project root to analyze | Required |
| `-o, --output <dir>` | Directory to write `analysis.json` | **When omitted, print compact JSON to stdout.** The facade relies on this |
| `-f, --format <json\|msgpack>` | Serialization format | Default `json` |
| `-a, --analysis-level <1\|2>` | 1 = symbol table only; 2 = + **resolver-based** call graph (still cheap) | Java style. Python instead uses toggles; either is fine as long as the cheap symbol-table-only run is the default |
| `--codeql / --joern` (or similar) | Add the **framework-based** (heavy) call graph | Separate toggle, **not** an `-a` level; off by default |
| `-t, --target-files <paths>` | Restrict analysis to specific files | Incremental analysis |
| `--skip-tests / --include-tests` | Skip test trees | Default skip |
| `--eager / --lazy` | Force clean rebuild vs reuse cache | Default lazy |
| `-c, --cache-dir <dir>` | Where caches/intermediate DBs live | |
| `-v` | Verbosity (repeatable) | |

## The output contract
The only thing the facade depends on is that, after a successful run, **`<output>/analysis.json`
exists and conforms to `canonical-schema.md`** (or, with no `-o`, the same JSON is on
stdout). Everything else — cache files, CodeQL databases, build artifacts — is internal.

## Flag validation requirements

Flags that accept a fixed vocabulary must be validated — never silently ignored.

**`--format`** — Only `json` is currently required to be implemented. If `msgpack` or any
other value is passed and not implemented, return an explicit error:
```
error: msgpack output is not yet implemented; use --format json
```
Silently falling back to JSON is worse than an error: the caller asked for msgpack,
received JSON, and may process the output incorrectly.

The general rule: any flag whose value is unrecognized or unimplemented **must** return a
non-zero exit with a clear message. The Python SDK wrapper passes the format flag through
to the binary; if the binary silently accepts and ignores the flag, the SDK has no way to
know the output format differs from what was requested.

## Level selection
Two orthogonal axes, don't conflate them:
- **`-a 1|2`** scopes the **cheap, resolver-based (level-1)** analysis: `-a 1` = symbol table
  only; `-a 2` = + the resolver call graph. The resolver call graph is cheap (the resolver is
  already loaded), so `-a 2` is still the lightweight tier — keep `-a 1` (symbol table only) as
  the default.
- **A separate flag** (`--codeql`/`--joern`/…) turns on the **heavy, framework-based (level-2)**
  backend. Off by default so the cheap path stays cheap.

The SDK passes its `AnalysisLevel` enum through to the `-a` flag; the framework backend is its
own opt-in.

## Example invocations the facade will issue
```
# symbol table only, JSON to a temp dir
codeanalyzer-ts -i /path/to/project -o /tmp/cldk-xyz -a 1

# symbol table + resolver call graph (both cheap, level 1), with caching
codeanalyzer-ts -i /path/to/project -o /tmp/cldk-xyz -a 2 -c ~/.cldk/ts-cache

# single-file incremental, stdout
codeanalyzer-ts -i /path/to/project -t src/foo.ts
```
