---
name: designing-cldk-changes
description: Use when a CLDK change is structural — a new language, schema v2 evolution, a new analysis level, a new SDK facade surface, or any cross-repo feature — before touching an implementation rung.
---

# Designing CLDK changes

The design mode of the CLDK ladder. Structural work — anything that moves the
shared contract or spans repos — is designed here, as a spec plus a GitHub epic,
**before** any implementation rung runs. You own contract evolution; the rungs
(`codeanalyzer-backend`, `cldk-sdk-frontend`) consume what you decide.

## Entry Preconditions

You are here because the work is structural: a new language, schema v2
evolution/migration, a new analysis level (L2/L3/L4), a new SDK facade surface, or
any cross-repo feature. If it arrived as a "small fix" that turned out to move
the schema v2 output or the public SDK API, **maintaining-cldk**'s contract gate
escalated it here — say so and continue; it is now a structural change, not a fix.

## Contract-Impact Triage

**First move, always — before any design detail.** Answer, out loud:

1. **Does this change the schema v2 output?** (a new node/edge kind, field, level,
   or id shape) — the keystone is `references/canonical-schema.md`.
2. **Which repos are touched** — analyzers, SDKs, docs?

Then state the change-type → repos-affected mapping:

| Change type | Analyzers | SDKs | Docs |
| --- | --- | --- | --- |
| New language | new `codeanalyzer-<lang>` | `python-sdk` (+ TS SDK) | docs |
| Schema v2 evolution / migration | every affected `codeanalyzer-*` | every affected SDK | docs |
| New analysis level (L2/L3/L4) | that `codeanalyzer-<lang>` | SDK only if the surface changes | docs |
| New facade surface / SDK feature | — | `python-sdk` (+ TS SDK) | docs |
| Docs-only structural change | — | — | docs |

Siblings share the schema — a "one analyzer" change is rarely one repo. Name
every affected repo now; each becomes a child issue below.

## Design Loops

Run the matching loop **WITH the user, never solo** — every divergence is the
user's decision (`AskUserQuestion`), not a silent pick:

- **Analyzer-side** (schema shape: node/edge kinds, fields a language adds) →
  `references/schema-design-loop.md`, anchored on `references/canonical-schema.md`.
- **SDK-side** (facade query surface) → `references/sdk-facade-design-loop.md`,
  anchored on the Java + Python + C facades.
- **Migrating an existing analyzer/SDK to a new schema major** →
  `references/schema-migration.md` (compat shims, staging, version lockstep).

A new-language change usually runs both loops; a facade-only change runs just the
SDK loop.

## <HARD-GATE>

No implementation rung may be entered for structural work until the spec exists
AND the GitHub epic + child issues exist. No exceptions — not for 'small additive
changes', not for 'we'll write it up after'.

## Spec → Epic → Issues

1. **Produce the spec** — the triage table, the design-loop decisions, and the
   affected-repo list, written down.
2. **Create the epic + child issues** with `references/epic-and-issue-templates.md`:
   one epic holding the design summary + a checklist, and **one child issue per
   ladder rung / PR-unit** (design → backend → frontend → finishing), each
   filed via `gh issue create` and linked to the epic.

Only when both exist is the gate satisfied.

## Terminal State

The ONLY skill you invoke after designing-cldk-changes is the first affected
rung: codeanalyzer-backend if any analyzer is touched, else cldk-sdk-frontend if
only SDK surface is touched, else finishing-cldk-work (docs-only structural
change).

## Red Flags

| Rationalization | Reality |
| --- | --- |
| "We can write it up after it ships." | The gate exists precisely for this — the spec + epic are inputs to implementation, not paperwork produced afterward. |
| "It's a small additive change." | Additive schema changes still move the shared cross-language vocabulary; they enter design, under the gate. |
| "A decision note, not a full spec marathon." | The spec prose can be short; the epic + one-child-per-rung is not. Scale the writing, never the gate. |
| "No epic needed — this isn't multi-stage work." | Any structural change that touches ≥1 rung gets an epic + one child per rung; the epic is the cross-repo coordination record. |
| "A heads-up to the SDK is enough." | An affected SDK repo gets a child issue, not a courtesy ping — it is on the ladder. |
| "I'll just patch the parser / SDK model directly." | That is implementing before triage. Run Contract-Impact Triage first. |
