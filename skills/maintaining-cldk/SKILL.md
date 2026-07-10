---
name: maintaining-cldk
description: Use when picking up an issue, bug report, small feature, or documentation gap on any codellm-devkit repository, or when triaging whether a reported problem is real.
---

# Maintaining CLDK

The upkeep mode of the CLDK ladder: triage → contract gate → fix loop →
propagation sweep. This is where bug fixes, small features, and docs gaps
land — the counterpart to `designing-cldk-changes`, which owns anything
structural. Most work enters here.

## Entry Preconditions

An issue, bug report, small feature request, or docs gap already exists. No
spec and no epic are needed to start — that is the point of this mode. If
what you're holding turns out to need a design decision spanning repos, the
contract gate below routes you out.

## 1. Triage

**Reproduce first, always** — do not start editing on the strength of a
report alone:

- Analyzer bug → build a minimal fixture that exhibits it.
- SDK bug → write the failing test first.
- Docs gap → reproduce the broken render or the broken command.

Locate the affected repo(s) via `references/repo-map.md`. Classify what
you're holding. Triage may terminate right here with a **triage verdict**:
not-a-bug, duplicate, or needs-design (route to `designing-cldk-changes`).
If it's real and local, continue to the gate below.

<HARD-GATE>
If the fix changes schema v2 output (any node/edge/field, even optional
additions) or a public SDK API, STOP. This is structural work: invoke
designing-cldk-changes. 'Optional so it can't break anyone' is the canonical
rationalization — additive fields are still contract changes.
</HARD-GATE>

## 2. Fix Loop

Failing test first, then the fix. Follow the target repo's own `CLAUDE.md`
conventions (branch naming, commit style, test layout) — this mode does not
override local repo discipline, it sits on top of it.

## 3. Propagation Sweep

Before you consider the work done, run `references/propagation-checklist.md`
— sibling analyzers, SDK version pins, docs staleness, and old-behavior
fixtures elsewhere. This produces a **required** output, in this exact shape:

**Propagation verdict:** <list of follow-on repos + why> | none, because
<reason>.

Skipping this step is the second canonical failure mode of this mode, not a
lesser one than skipping the contract gate.

## Terminal State

The ONLY skill you invoke after maintaining-cldk is finishing-cldk-work (or
designing-cldk-changes via the contract gate; or stop at a triage verdict if
there is nothing to fix).

## Red Flags

| Rationalization | Reality |
| --- | --- |
| "It's optional, can't break anyone." | Additive schema/API surface is still a contract change — the HARD-GATE applies regardless of optionality. |
| "Tests pass, wrap up." | Local tests passing is not the propagation sweep. Run `propagation-checklist.md` and produce the verdict before declaring done. |
| "That's a scope call I can just make in this conversation." | A schema-shape question is not a same-turn negotiation with whoever asked — it leaves this rung entirely, via the contract gate. |
| "This bug is local to this repo, no need to check siblings." | Siblings share the schema and the resolver patterns; a bug class rarely respects repo boundaries. The sweep exists precisely to check. |
