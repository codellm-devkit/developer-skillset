---
name: using-cldk-devtools
description: Use when starting any session or task that touches a codellm-devkit repository — before any action, including quick fixes, questions, and issue triage.
---

## The Rule

Before ANY action on a codellm-devkit repo — including answering questions
and "quick fixes" — find your entry point in the routing table and invoke
that skill. If a ladder skill applies, you do not have a choice.

## The Ladder

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

## Red Flags

| Rationalization | Reality |
| --- | --- |
| "It's just a small schema tweak" | Schema changes enter at designing-cldk-changes. |
| "I'll patch the SDK model directly" | Check the schema contract first — enter the ladder. |
| "This fix is analyzer-local" | Siblings share the schema. maintaining-cldk runs the propagation sweep. |
| "I'll release manually just this once" | Releases go through finishing-cldk-work. |

## Scope Guard

If the task does not touch a codellm-devkit repository, this plugin stays
silent. Do not route unrelated work through this ladder.
