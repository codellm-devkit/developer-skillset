---
name: codeanalyzer-backend
description: Use when building or migrating a codeanalyzer-<lang> backend analyzer — adding a language to CLDK, growing an analyzer through analysis levels L1–L4, or adapting an existing analyzer to canonical schema v2.
---

# CLDK analyzer backend

Build or grow a `codeanalyzer-<lang>` — the backend that parses one language and emits the
**canonical schema v2**. You do not "build an analyzer then bolt on features"; you **grow one
structure, level by level**, and each level is independently shippable.

## Entry Preconditions

This rung is the **implementation of an already-designed change** — it does not decide contract
shape. Before you touch code:

- A **spec and a GitHub epic** must exist, produced by `designing-cldk-changes`. They fix the
  language, the target level(s), and every schema decision (which kinds/fields/edges this language
  adds). **If there is no spec + epic, STOP and go to `designing-cldk-changes`** — do not scaffold,
  do not "just start," do not settle schema shape here.
- A **maintenance escalation** enters here only when it arrives **with its design decision already
  recorded** (a `.claude/SCHEMA_DECISIONS.md` entry + issue). A bare "add a field" with no design
  is not an entry — it goes back to design mode.

## The Keystone

Read `skills/designing-cldk-changes/references/canonical-schema.md` **first, before any reference
here.** It is the single source of truth for what an analyzer emits: **one additive structure** — a
tree of code nodes with typed edge overlays (a CPG) — in **two projections**, `analysis.json` and a
Neo4j graph. **Both projections are first-class deliverables**; Neo4j is not an afterthought. Every
reference below serves that document and must not contradict it.

## Two Paths

Decide up front which you are on:

- **(A) New language.** No analyzer exists. Choose tooling (`references/tooling-menu.md`), scaffold
  the modular skeleton (`references/analyzer-architecture.md`), then build the ladder.
- **(B) Existing analyzer → schema v2.** A `codeanalyzer-<lang>` exists on the old schema. This is a
  **major release**: keep its parsing/resolution guts, re-point its *emission* onto v2, level by
  level, per `skills/designing-cldk-changes/references/schema-migration.md`.

Either way the target is identical: output that validates against `canonical-schema.md` at its
`max_level`, in both projections.

## Level Ladder

Grow the one tree one layer at a time. Each level clears its **conformance gate** before the next
begins, and each level is independently shippable.

```
L1 symbol table ──gate──▶ L2 call graph ──gate──▶ L3 intraprocedural ──gate──▶ L4 interprocedural
 (tree + call nodes)        (call_graph)         dataflow (cfg/cdg/ddg)        SDG (param_*/summary)
```

- **L1** (`references/level-1-symbol-table.md`) — the tree to callable depth + `call` nodes.
- **L2** (`references/level-2-call-graph.md`) — resolver `call_graph` edges; backfill `callee`.
- **L3** (`references/level-3-intraprocedural-dataflow.md`) — `body` statements + syntactic
  `cfg`/`cdg`/`ddg`.
- **L4** (`references/level-4-interprocedural-sdg.md`) — synthetic vertices + `param_in`/`param_out`/
  `summary` + semantic `ddg`.

Each **gate = fixture suite green + schema conformance green** (exact commands in
`references/testing-and-validation.md`). Every level emits **both** projections.

<HARD-GATE>
No level advance while the current level's conformance gate is red. No schema divergence from canonical-schema.md without going back through designing-cldk-changes.
</HARD-GATE>

## References

- `references/analyzer-architecture.md` — modular skeleton: parser → resolver → per-level builders →
  emitters; module boundaries and why.
- `references/tooling-menu.md` — per-language tooling decision (parser, resolver, enrichment) + the
  guided-decision protocol.
- `references/level-1-symbol-table.md` — L1: build the node tree to callable depth, symbol/
  declaration coverage, per-construct fixture checklist.
- `references/level-2-call-graph.md` — L2: resolver call edges, dispatch/virtual-call handling,
  flag-gated framework enrichment.
- `references/level-3-intraprocedural-dataflow.md` — L3: CFG substrate then DFG overlay, per-construct
  coverage, slicing/taint as SDK queries.
- `references/level-4-interprocedural-sdg.md` — L4: SDG over L3, call-edge stitching, cost controls,
  flag gating.
- `references/cli-contract.md` — CLI flags (`--analysis-level`, `--emit`, `-j`), exit codes,
  stdout/stderr discipline.
- `references/project-materialization.md` — making a project analyzable: dependency resolution,
  build-less parsing, venv/vendor handling.
- `references/neo4j-projection.md` — the Neo4j projection: Cypher snapshot vs live Bolt push,
  full-depth-always rule, CPG overlay.
- `references/testing-and-validation.md` — gate commands per level, fixture design, schema
  conformance, determinism (`-j`) checks.

**Packaging and release do not live here.** Cutting the `codeanalyzer-<lang>` distribution (wheel,
binaries, tag-triggered automation) is `finishing-cldk-work`.

## Terminal State

The ONLY skill you invoke after codeanalyzer-backend is cldk-sdk-frontend if any SDK is affected by this work, else finishing-cldk-work.
