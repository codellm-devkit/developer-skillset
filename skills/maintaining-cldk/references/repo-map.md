# Repo map

Where a fix lands, and what pins to what. Enumerated live via
`gh repo list codellm-devkit --limit 100 --json name,description` (27 returned,
25 after excluding the two org-meta repos `.github` / `.github-private`). Facts below
are evidenced from that enumeration plus local checkouts under
`/Users/rkrsn/workspace/codellm-devkit/`; anything not directly checked is
marked **verify per repo**.

## Tier 1 — SDKs (frontend)

| Repo | Owns | Evidence |
| --- | --- | --- |
| `python-sdk` | The `cldk` PyPI package — the public Python facade (`CLDK(language=...).analysis(...)`). Wires Java, Python, C, and TypeScript backends today (`cldk/analysis/{java,python,c,typescript}`); no Go/Rust wiring yet. | Checked out; `cldk/analysis/` listing. |
| `typescript-sdk` | The `@codellm-devkit/cldk` npm package — the TS/JS facade. | No local checkout — **verify per repo**. |

## Tier 2 — Analysis backends (`codeanalyzer-<lang>`)

The sibling-analyzer list, explicitly: **`codeanalyzer-java`, `codeanalyzer-python`,
`codeanalyzer-typescript`, `codeanalyzer-go`, `codeanalyzer-rust`,
`codeanalyzer-kotlin`, `codeanalyzer-clang`, `codeanalyzer-dotnet`,
`codeanalyzer-swift`, `codeanalyzer-abap`**, plus the shared
**`codeanalyzer-codeql`** (CodeQL-driven analysis backing `codeanalyzer-python`'s
deeper dataflow) and the general **`codeanalyzer`** repo (scope unconfirmed —
**verify per repo**). All of these parse one language and emit the shared
schema contract (`skills/designing-cldk-changes/references/canonical-schema.md`
owns the model). A bug class in one resolver (e.g. embedded/promoted-method
call-edge dropping) is a candidate bug in every other structural resolver,
not just the repo where it was found — that is what the propagation sweep
checks.

| Repo | Owns | Evidence |
| --- | --- | --- |
| `codeanalyzer-java` | Java, via WALA + JavaParser. Has its own Neo4j `SchemaCatalog` (`SCHEMA_VERSION` constant, currently `1.1.0` in the local checkout) — **verify per repo** whether this has moved to schema v2 by the time you're reading this. | Checked out. |
| `codeanalyzer-python` | Python, via Jedi + Tree-sitter (+ `codeanalyzer-codeql` for deeper dataflow). Local checkout's `codeanalyzer/core.py` gates its analysis cache on `schema_version == "2.0.0"` — already on schema v2. | Checked out. |
| `codeanalyzer-typescript` | TypeScript/JavaScript, via ts-morph + Jelly. One repo, multiple in-flight branches: the `main`-tracking checkout sits on `feat/issue-2-program-graphs`; a second worktree of the **same repo** sits on `fix/issue-46-bolt-symbol-labels`, which is where the schema-v2 additive-CPG emitter + Neo4j v2 projection work is landing (`PROGRAM_GRAPHS_SCHEMA_VERSION` in `src/schema/graphs.ts`). Do not mistake the two worktrees for two repos. | Checked out (two worktrees, one `origin`). |
| `codeanalyzer-go` | Go. **In development** per the org description; the local checkout of `main` is a near-empty stub (`LICENSE`, `README.md` only) — the working analyzer, if any, lives on a feature branch/PR, not `main`. This is also the scenario dry-run cwd: treat anything you find here as real repo state, not an answer key. | Checked out. |
| `codeanalyzer-rust` | Rust, via the Rust compiler's IR. **In development**; local checkout has no source tree yet (just `docs/`, `.devcontainer/`). | Checked out. |
| `codeanalyzer-kotlin`, `codeanalyzer-swift`, `codeanalyzer-dotnet`, `codeanalyzer-abap` | Kotlin / Swift / .NET / ABAP backends. All **in development**; local checkouts are empty (git metadata only, no source). | Checked out. |
| `codeanalyzer-clang` | C/C++ family. Has a `CLAUDE.md` and `docs/` but no visible source tree in the checkout — **verify per repo** for current depth. | Checked out. |
| `codeanalyzer-codeql` | Shared CodeQL-driven analysis; described by the org as backing `codeanalyzer-python`'s deeper dataflow/reachability queries, on by default. | No local checkout — **verify per repo**. |
| `codeanalyzer` | "Codeanalyzer General Purpose Backend" per its org description — relationship to the per-language `codeanalyzer-<lang>` repos is unconfirmed. **Verify per repo** before assuming it's in scope for a language-specific sweep. | No local checkout — **verify per repo**. |

## Tier 3 — Agent integrations

| Repo | Owns | Evidence |
| --- | --- | --- |
| `cldk-devtools` | This plugin — the skills that extend/maintain CLDK itself (this repo, worked in as a git worktree). Note: this repo was renamed from `cldk-forge` (`gh repo view codellm-devkit/cldk-forge` redirects to `cldk-devtools`) — a local checkout still pointing at the old `cldk-forge` remote is this same repo, pre-rename, not a distinct one. | Checked out (this worktree); `git remote`/`gh repo view` redirect confirmed. |
| `cocoa` | COCOA (Code Context Agent) — the Python implementation + MCP toolbox server wrapping CLDK for coding agents. | Checked out. |
| `cocoa-mcp` | A second COCOA/MCP repo; its `gh` description text says "Python Implementation" but `primaryLanguage` reports Java in the enumeration — **verify per repo** which is authoritative before treating this as pure-Python. | Checked out; description/language mismatch observed directly. |
| `cocoa-ts` | The TypeScript implementation of COCOA + its MCP server. | No local checkout — **verify per repo**. |

## Tier 4 — Docs, packaging, ecosystem

| Repo | Owns | Evidence |
| --- | --- | --- |
| `docs` | The published docs site (`codellm-devkit.info`). One repo, two live fronts: the checkout on `main` is the current mkdocs-based site; a second worktree (locally named `docs-astro`, same `origin`) sits on branch `astro` building an Astro/Starlight redesign (`REDESIGN_PLAN.md`). Both are the same repo — don't file a docs fix against only one front without checking whether the other needs it too. | Checked out (two worktrees, one `origin`); branches confirmed (`main` vs `astro`). |
| `codellm-devkit` | The org's meta/ecosystem repo — `README.md`, `ECOSYSTEM.md` (the org-wide repo map, tiered by visitor journey), `ROADMAP.md`. Its `ECOSYSTEM.md` is itself a **live example of docs staleness**: it lists this plugin under its pre-rename name/URL (`developer-skillset`) and calls the TypeScript analyzer `codeanalyzer-ts`, but the actual repo names are `cldk-devtools` and `codeanalyzer-typescript` — check whether a fix you're making also needs an `ECOSYSTEM.md` update. | Checked out; read directly, names cross-checked against `gh repo list`. |
| `homebrew-tap` | The Homebrew tap formulas for CLDK tooling (analyzer binaries per `packaging-and-release.md` in `codeanalyzer-backend`). | Checked out. |
| `cldk-tutorial` | Hands-on tutorial content. | No local checkout — **verify per repo**. |
| `python-sdk-codeql-backend`, `scalpel`, `orchard` | `python-sdk-codeql-backend` is described as CLDK with a CodeQL backend (restrictive-license alternative packaging); `scalpel` is the standalone Python static-analysis framework `codeanalyzer-python` may depend on; `orchard` is described only as "context-picking." Relationship of each to the maintenance sweep is unconfirmed — **verify per repo**. | No local checkout — **verify per repo**. |

## The pin chain

- `python-sdk`'s `pyproject.toml` pins backend versions directly as PyPI
  dependencies: `codeanalyzer-python==0.3.0`, `codeanalyzer-typescript==0.4.3`
  (exact pins, not ranges). At the time of this enumeration, the
  `codeanalyzer-python` checkout's own `pyproject.toml` was already at
  `0.3.1` — i.e. the pin can trail the analyzer's own released version; check
  both sides before assuming a fix is already picked up downstream.
- The Java backend is bundled/downloaded rather than pinned as a plain PyPI
  dependency (no `codeanalyzer-java==` line in `python-sdk`'s
  `pyproject.toml`). However, `pyproject.toml` lines 89–92 contain a
  `[tool.backend-versions]` table with `codeanalyzer-java = "2.4.1"`, which is
  informational only — not consumed by python-sdk code or release.yml (which fetches the latest GitHub release dynamically). Verify the exact bundling/version
  mechanism before assuming a Java-side fix needs a `python-sdk` pin bump the
  same way Python/TypeScript do.
- `codeanalyzer-go` and `codeanalyzer-rust` have no wiring in `python-sdk`
  yet (`cldk/analysis/` has no `go` or `rust` package) — a Go/Rust-side fix
  today has no SDK pin to bump, but check again once either lands.
- `typescript-sdk`'s own pin chain to `codeanalyzer-typescript` — **verify
  per repo**, no local checkout.

## Which repos share the schema

Every `codeanalyzer-<lang>` backend and every SDK frontend consume the same
canonical schema (owned in `designing-cldk-changes/references/
canonical-schema.md`) — that is the entire reason a resolver-class bug or a
schema-shape change is a cross-repo concern, not a local one. Per-repo
adoption of the current schema major is not uniform at any given moment
(see the `codeanalyzer-java`/`-python`/`-typescript` version notes above) —
**verify per repo** which schema version a given analyzer actually emits
before assuming parity.
