# cldk-devtools

cldk-devtools (formerly cldk-forge) is a [Claude Code](https://claude.com/claude-code)
**plugin** that turns [CodeLLM-DevKit (CLDK)](https://github.com/codellm-devkit) development
into a **mode ladder**: one skill per stage of the work — design, build the backend analyzer,
wire it into an SDK, maintain, finish — each with its own hard gates and a fixed handoff to the
next rung. Structural work gets designed before it's built; upkeep work gets triaged and swept
for propagation; nothing ships without passing through the same exit gate. Describe what you're
doing and the matching skill takes over.

## Install

```
/plugin marketplace add codellm-devkit/cldk-devtools
/plugin install cldk-devtools@codellm-devkit
```

Then just describe the task — *"add Rust support to CLDK"*, *"build a codeanalyzer for
Kotlin"*, *"wire the Go analyzer into python-sdk"*, *"fix this codeanalyzer-go issue"* — and the
matching skill triggers. Inside any codellm-devkit repository, a `SessionStart` hook also injects
the dispatcher automatically (see [How the hook behaves](#how-the-hook-behaves) below).

## The Ladder

The diagram and routing table below are copied verbatim from the dispatcher skill,
[`using-cldk-devtools`](skills/using-cldk-devtools/SKILL.md) — the same ones an agent reads
before acting on any codellm-devkit repo. Keep the two in sync;
[`tests/consistency/check-readme-dispatcher-sync.sh`](tests/consistency/check-readme-dispatcher-sync.sh)
diffs them.

```
                     using-cldk-devtools  (dispatcher)
                              │
        structural work       │ upkeep work
              ▼               ▼
   designing-cldk-changes   maintaining-cldk
        │ spec + GitHub epic     │  HARD GATE: escalate to design mode
        ▼                        │  if the fix moves schema v2 / public API
   codeanalyzer-backend          │
        ▼                        │
   cldk-sdk-frontend             │
        ▼                        ▼
           finishing-cldk-work  (verify → release → docs → close issues)
                              │
                    (future rung: cocoa)
```

## Routing

| Work type | Entry point | Path |
| --- | --- | --- |
| New language for CLDK | designing-cldk-changes | design → backend → frontend → finishing |
| Schema v2 evolution / migration | designing-cldk-changes | design → backend (all affected analyzers) → frontend (all affected SDKs) → finishing |
| New analysis level (L2/L3/L4) for a language | designing-cldk-changes | design → backend → frontend (if surface changes) → finishing |
| New facade surface / SDK feature | designing-cldk-changes | design → frontend → finishing |
| Bug fix (analyzer or SDK), behavior-preserving | maintaining-cldk | maintain → finishing |
| Small feature, no contract impact | maintaining-cldk | maintain → finishing |
| Docs gap / README / agent-guide update | maintaining-cldk | maintain → finishing (docs path) |
| Issue triage ("is this real?") | maintaining-cldk | maintain (may stop at triage verdict) |

## Skills

### [`using-cldk-devtools`](skills/using-cldk-devtools/) — dispatcher

**Owns:** the routing rule itself — the ladder diagram and routing table above. **Triggers:**
before any action on a codellm-devkit repo, including quick fixes, questions, and issue triage;
in practice it is injected automatically by the `SessionStart` hook rather than invoked by name.
**References:** none — it stays under 500 words by design and defers all workflow detail to the
other five skills.

### [`designing-cldk-changes`](skills/designing-cldk-changes/)

**Owns:** contract evolution — a new language, schema v2 evolution/migration, a new analysis
level, a new SDK facade surface, or any cross-repo structural feature — decided as a spec plus a
GitHub epic (one child issue per rung) before any implementation rung runs. **Triggers:** the
work is structural, or `maintaining-cldk`'s contract gate escalated a "small fix" here because it
moved schema v2 output or the public API. **Key references:**
[`canonical-schema.md`](skills/designing-cldk-changes/references/canonical-schema.md) (the
keystone every other skill defers to),
[`schema-design-loop.md`](skills/designing-cldk-changes/references/schema-design-loop.md),
[`sdk-facade-design-loop.md`](skills/designing-cldk-changes/references/sdk-facade-design-loop.md),
[`schema-migration.md`](skills/designing-cldk-changes/references/schema-migration.md),
[`epic-and-issue-templates.md`](skills/designing-cldk-changes/references/epic-and-issue-templates.md).

### [`maintaining-cldk`](skills/maintaining-cldk/)

**Owns:** the upkeep path — triage → contract gate → fix loop → propagation sweep — for bug
fixes, small features, and docs gaps. Most work enters here. **Triggers:** picking up an issue,
bug report, small feature, or documentation gap on any codellm-devkit repository, or triaging
whether a reported problem is real. **Key references:**
[`repo-map.md`](skills/maintaining-cldk/references/repo-map.md) (where a fix lands, what pins to
what), [`triage-playbook.md`](skills/maintaining-cldk/references/triage-playbook.md),
[`propagation-checklist.md`](skills/maintaining-cldk/references/propagation-checklist.md) (the
required propagation verdict).

### [`codeanalyzer-backend`](skills/codeanalyzer-backend/)

**Owns:** building or growing a `codeanalyzer-<lang>` backend analyzer level by level — symbol
table (L1), call graph (L2), intraprocedural dataflow (L3), interprocedural SDG (L4) — into the
canonical schema v2, in both the `analysis.json` and Neo4j projections. **Triggers:** adding a
language, growing an analyzer through the levels, or migrating an existing analyzer to schema
v2 — only once a spec + GitHub epic exists from `designing-cldk-changes` (or a maintenance
escalation arrives with its design decision already recorded). **Key references:**
[`analyzer-architecture.md`](skills/codeanalyzer-backend/references/analyzer-architecture.md),
[`tooling-menu.md`](skills/codeanalyzer-backend/references/tooling-menu.md),
[`level-1-symbol-table.md`](skills/codeanalyzer-backend/references/level-1-symbol-table.md),
[`level-2-call-graph.md`](skills/codeanalyzer-backend/references/level-2-call-graph.md),
[`level-3-intraprocedural-dataflow.md`](skills/codeanalyzer-backend/references/level-3-intraprocedural-dataflow.md),
[`level-4-interprocedural-sdg.md`](skills/codeanalyzer-backend/references/level-4-interprocedural-sdg.md),
[`cli-contract.md`](skills/codeanalyzer-backend/references/cli-contract.md),
[`project-materialization.md`](skills/codeanalyzer-backend/references/project-materialization.md),
[`neo4j-projection.md`](skills/codeanalyzer-backend/references/neo4j-projection.md),
[`testing-and-validation.md`](skills/codeanalyzer-backend/references/testing-and-validation.md).
Packaging and release do **not** live here — that's `finishing-cldk-work`.

### [`cldk-sdk-frontend`](skills/cldk-sdk-frontend/)

**Owns:** wiring an existing, schema-conformant `codeanalyzer-<lang>` into a CLDK frontend SDK —
today the [Python SDK](https://github.com/codellm-devkit/python-sdk)
(`CLDK.<lang>(project_path=..., backend=...)`, with the legacy
`CLDK(language="<lang>").analysis(...)` kept as a compat shim), the TypeScript SDK the same way,
other SDKs as they come online — behind the **Iron Rule**: the public API never moves.
**Triggers:** the analyzer already emits conformant output, and, for any change to the facade
surface, a spec + epic already decided that surface in `designing-cldk-changes`. **Key
references:** [`schema-contract.md`](skills/cldk-sdk-frontend/references/schema-contract.md) (the
two-layer model: CPG models vs. the frozen public facade),
[`python-sdk-wiring.md`](skills/cldk-sdk-frontend/references/python-sdk-wiring.md),
[`typescript-sdk-wiring.md`](skills/cldk-sdk-frontend/references/typescript-sdk-wiring.md),
[`neo4j-backend.md`](skills/cldk-sdk-frontend/references/neo4j-backend.md),
[`sdk-testing.md`](skills/cldk-sdk-frontend/references/sdk-testing.md) (mocked + E2E +
backend-contract tiers).

### [`finishing-cldk-work`](skills/finishing-cldk-work/)

**Owns:** the ladder's exit — every other rung terminates here. Verification gates, a real ship
decision, release mechanics when warranted, and closeout (docs, issue/epic bookkeeping, filing
follow-on issues for anything a propagation verdict listed). **Triggers:** implementation on a
CLDK branch is complete and the work needs verification, merge, release, documentation updates,
or issue closeout — before claiming any CLDK work is done. **Key references:**
[`release-gates.md`](skills/finishing-cldk-work/references/release-gates.md) (the gate matrix by
repo type), [`packaging-and-release.md`](skills/finishing-cldk-work/references/packaging-and-release.md)
(tag-triggered analyzer releases, SDK pin bumps),
[`docs-and-closeout.md`](skills/finishing-cldk-work/references/docs-and-closeout.md).

## Layout

```
.claude-plugin/            # plugin + marketplace manifests
hooks/                     # SessionStart hook: injects the dispatcher inside CLDK repos, silent elsewhere
skills/
  using-cldk-devtools/     # SKILL.md only — dispatcher, no references/
  designing-cldk-changes/  # SKILL.md + references/
  maintaining-cldk/        # SKILL.md + references/
  codeanalyzer-backend/    # SKILL.md + references/
  cldk-sdk-frontend/       # SKILL.md + references/
  finishing-cldk-work/     # SKILL.md + references/
docs/schema/               # schema v2 preview artifacts
tests/
  scenarios/               # per-skill prompts used to test routing and gates
  baselines/               # RED (no-skill) vs. GREEN (with-skill) evidence, ladder dry-runs
  hooks/                   # hook behavior tests
  consistency/             # README/dispatcher-skill sync checks
```

## How the hook behaves

`hooks/session-start.sh` fires on `SessionStart` (`startup|clear|compact`). It checks whether the
session's working directory sits under a path containing `codellm-devkit`, or the repo's `origin`
remote points at `codellm-devkit` — only then does it print the full
`using-cldk-devtools` dispatcher skill into context, labeled so the agent knows to fetch every
other skill through the `Skill` tool by name. Outside a codellm-devkit repo it prints nothing.
Every path exits `0`: the hook is bash + git only, with no other runtime dependency, and it must
never be the reason a session fails to start.

## Reference analyzers & typical flows

Reference analyzers this skillset anchors on:
[`codeanalyzer-java`](https://github.com/codellm-devkit/codeanalyzer-java),
[`codeanalyzer-python`](https://github.com/codellm-devkit/codeanalyzer-python),
[`codeanalyzer-typescript`](https://github.com/codellm-devkit/codeanalyzer-typescript).

Two typical flows through the ladder:

- **"Add Rust support to CLDK"** (new language) — `designing-cldk-changes` produces the spec +
  epic (target level, schema decisions) → `codeanalyzer-backend` builds and releases
  `codeanalyzer-rust` (L1, optionally L2) → `cldk-sdk-frontend` wires `CLDK.rust(project_path=...)`
  into the Python SDK (and TypeScript when ready) → `finishing-cldk-work` runs the gates, decides
  and cuts the release, and closes out the epic.
- **"Fix this codeanalyzer-go issue"** (bug fix) — `maintaining-cldk` reproduces the bug, checks
  the contract gate (escalating to `designing-cldk-changes` only if the fix would move schema v2
  output or a public API), fixes it, and runs the propagation sweep across sibling analyzers →
  `finishing-cldk-work` verifies, ships a release if the sweep or the fix itself warrants one, and
  closes the issue.

## Authoring method

Every skill in this plugin was built scenario-first, not asserted into existence: a **RED**
baseline transcript (the same task, run without the skill) is captured before a **GREEN**
transcript (the same task, with the skill's `SKILL.md` in context) shows the gate or handoff
actually changing agent behavior. Scenario prompts live under `tests/scenarios/<skill>/`; their
RED/GREEN evidence is under `tests/baselines/<skill>/`. Whole-ladder dry runs — walking multiple
rungs end to end without implementing — are recorded in
[`tests/baselines/ladder-dry-runs.md`](tests/baselines/ladder-dry-runs.md). A skill lands only
once its scenarios pass GREEN.
