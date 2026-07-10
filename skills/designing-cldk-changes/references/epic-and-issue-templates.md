# Epic + child-issue templates

This is how the **Spec → Epic → Issues** step of `designing-cldk-changes` materializes on GitHub.
The gate is not satisfied until both the spec **and** the epic + child issues exist. This file
gives the template forms, the `gh issue create` invocations, and the one-child-per-rung rule.

## The shape

- **One epic issue** — the cross-repo coordination record. It holds the design summary (from the
  spec), the affected-repo list (from the Contract-Impact Triage), the locked design decisions, and
  a **checklist that links every child issue**. The epic is the durable design record; it is not
  ceremony you can skip for a "small" change.
- **One child issue per ladder rung / PR-unit.** Each child is a single unit of implementation work
  on a single repo, closed by a single PR. Map the children straight off the triage table:

  | Affected by triage | Child issue → rung |
  | --- | --- |
  | schema shape decided (this skill) | already done here — captured in the epic body, not a child |
  | any analyzer touched | one child per analyzer → **codeanalyzer-backend** |
  | any SDK surface touched | one child per SDK → **cldk-sdk-frontend** |
  | docs / release / verify | one child → **finishing-cldk-work** |

  **One-child-per-rung is the default.** A single heavy rung (e.g. a full L3/L4 dataflow build) may
  fan its child into a small stack of PR-unit sub-issues — but that staging lives *under* the rung's
  child and stays linked to the epic; it never replaces the one-per-rung mapping with an
  internal-build-phase mapping.

- **Each child → a branch `<type>/issue-NNN-<short-title>` → one PR that closes it** (`Closes #NNN`).
  The epic is closed when its checklist is complete.

## Placement convention

- The **epic** lives on the repo that is the primary new deliverable (a new language → the new
  `codeanalyzer-<lang>` repo; a schema-wide migration → the coordinating repo). Match the org's
  existing precedent — language epics live on their `codeanalyzer-<lang>` repo.
- Each **child** lives on the repo it changes (`codeanalyzer-<lang>`, `python-sdk`, `docs`, …), and
  its body ends with `Part of <owner>/<epic-repo>#<epic-number>` so GitHub cross-links it.

## Epic template

```markdown
Title: Epic: <one-line change> (<affected surfaces, e.g. analyzer + SDK>)

SUMMARY
<2–4 sentences from the spec: what changes and why. Name the schema-v2 impact
explicitly — "adds a `comment` body-node kind" / "no schema change, SDK surface only".>

AFFECTED REPOS (from Contract-Impact Triage)
  - <repo>  — <role: new analyzer | SDK facade | docs | …>  — <rung>
  - …

DESIGN DECISIONS (locked with the user before build starts)
  - <decision 1 — recorded in .claude/SCHEMA_DECISIONS.md / FACADE_DECISIONS.md>
  - <decision 2>
  - Scope guard: <what is explicitly OUT of scope for this change>

CHILDREN (one per rung/PR-unit; checklist updated as they land)
  - [ ] <analyzer work> — <owner>/<repo>#NNN
  - [ ] <SDK facade work> — <owner>/<repo>#NNN
  - [ ] <docs / release / verify> — <owner>/<repo>#NNN

DEFINITION OF DONE (epic-level)
  - Every child PR merged and its gate green.
  - Analyzer output validates against the SDK v2 models at its max_level; L1 ⊆ … ⊆ L4
    superset gate holds; parity clause holds (no renamed/repurposed shared vocabulary).
  - SDK public API unchanged (or the major bump + shims are documented).
  - Docs / CHANGELOG updated; versions pinned in lockstep.
```

## Child-issue template

Keep the CAVEATS and DEFINITION OF DONE sections — they are the parts that make the issue honest.
Fill `<slots>` from the design decisions; delete parts that don't apply.

```markdown
Title: <rung-scoped unit of work, e.g. "codeanalyzer-<lang>: L1 symbol table + call graph">

PROBLEM
<What this repo lacks today and what this issue adds. One paragraph.>

SCOPE BOUNDARY
<What this issue does NOT do — the provider/client line especially. Example: an
analyzer emits the graph and stops; slicing and taint are frontend SDK queries
over that graph (cldk-sdk-frontend), out of scope here — no `taint_flows`
section, no sources/sinks policy.>

GOALS (the contract, as a checklist)
  1. <goal>
  2. <goal>
  …

CAVEATS AND KNOWN RISKS
  - <substrate/tooling risk — be concrete; name the workaround>
  - <inherited unsoundness / known gaps — documented, not silently absorbed>
  - <cost / determinism / incrementality notes>

DEFINITION OF DONE
  - <exact-set gate, not "non-empty" — e.g. the backward slice on the fixture
    equals the hand-computed node set>
  - Output validates against the SDK v2 models; parity clause holds.
  - <projection / determinism / timing gates as applicable>

Part of <owner>/<epic-repo>#<epic-number>
```

## `gh issue create` invocations

Create the epic first, capture its number, then the children referencing it.

```bash
# 1. Epic (label it so it's findable; create the label once if needed)
gh issue create --repo <owner>/<epic-repo> \
  --title "Epic: <one-line change> (<surfaces>)" \
  --label epic \
  --body-file /path/to/epic-body.md
# → note the returned issue number, call it EPIC

# 2. One child per rung/PR-unit, each on its target repo, each linking the epic
gh issue create --repo <owner>/codeanalyzer-<lang> \
  --title "codeanalyzer-<lang>: <analyzer unit>" \
  --body-file /path/to/child-analyzer.md      # body ends: Part of <owner>/<epic-repo>#EPIC

gh issue create --repo <owner>/python-sdk \
  --title "python-sdk: wire <lang> (CLDK.<lang>())" \
  --body-file /path/to/child-sdk.md           # Part of <owner>/<epic-repo>#EPIC

gh issue create --repo <owner>/docs \
  --title "docs: <lang> backend row + guide" \
  --body-file /path/to/child-docs.md          # Part of <owner>/<epic-repo>#EPIC

# 3. Edit the epic body to tick the CHILDREN checklist with the returned numbers
gh issue edit <EPIC> --repo <owner>/<epic-repo> --body-file /path/to/epic-body-updated.md
```

Use `--body-file` (not inline `--body`) so multi-line templates survive intact.

## Worked example — native dataflow (L3/L4) for a language

The generalized form above is the distillation of the concrete L3/L4 dataflow epic. Instantiated,
its **epic** SUMMARY says "add levels 3–4 (native CFG/PDG/SDG + CPG projection) to
`codeanalyzer-<lang>` as the graph substrate reachability queries run over"; its **SCOPE BOUNDARY**
is the provider/client line ("this analyzer is a pure graph provider — slicing and taint are
frontend SDK queries, not analyzer features"); its **DESIGN DECISIONS** record the locked substrate
choices (CFG source, def-use source, points-to oracle, precision posture); and its heavy backend
rung fans into a PR-unit stack:

- **L3 (intraprocedural, no oracle — ship and tag first):** CFG + dominance + PDG,
  `body`/`cfg`/`cdg`/`ddg` emission, the backward-slice gate green on the fixture, then per-callable
  parallel fan-out (`-j`) differential-tested against `--jobs 1`.
- **L4 (interprocedural — needs the oracle):** oracle integration + identity mapping + call-graph
  merge with provenance; summaries (hammock regions, SCC fixpoint with k-limiting); SDG assembly
  with `param_in`/`param_out`/`summary` edges; points-to-backed (alias-aware) propagation replacing
  the type-based MVP stub.
- **CPG Neo4j projection + conformance test + schema bump** (skip if the Neo4j surface is out of
  scope; the SDG is the core artifact).

Its **CAVEATS** name the oracle-integration risks, the inherited unsoundness for the language
(eval/reflection | cgo/unsafe | setjmp-longjmp), the k-limiting-for-termination requirement, and
the parallel-determinism rule (never assign ids or emit during parallel execution — collect, then
sort by `(signature, node_id)`; `--jobs N` byte-identical to `--jobs 1`). Its **DEFINITION OF
DONE** uses exact expected sets, not "non-empty": every analyzer gate on the fixture (CFG,
dominance, DDG, PDG-slice, summary, SDG), the `L1 ⊆ … ⊆ L4` superset gate, and a clean Neo4j load
with no dangling edges. Slicing + taint are a **separate child on the SDK repo**
(`cldk-sdk-frontend`), never PRs on the analyzer.
