# Release gates — the verification matrix

What "run the gate commands NOW" (the SKILL.md HARD-GATE) means, concretely, per repo type. This
file is a **summary matrix** for the ship decision — it names which gates exist and the commands
that invoke them. It does not restate their pass/fail criteria or fixture design; those live in the
two authoritative references and must stay in sync with them, not be re-derived here:

- **Analyzer repos** (`codeanalyzer-<lang>`) — full gate detail in
  `skills/codeanalyzer-backend/references/testing-and-validation.md`.
- **SDK repos** (`python-sdk`, `typescript-sdk`, …) — full gate detail in
  `skills/cldk-sdk-frontend/references/sdk-testing.md`.

Re-run every gate in this matrix that applies to the repo you're finishing, on the exact commit
you're about to tag or merge. A green run from an earlier commit, an earlier session, or someone
else's machine does not satisfy the HARD-GATE.

## Analyzer repos (`codeanalyzer-<lang>`)

| Gate | Command | What it proves |
| --- | --- | --- |
| Fixture suite | `go test ./...` (or the ecosystem equivalent — `pytest`, `mvn test`, `cargo test`) | Per-level unit/fixture assertions pass, up to the analyzer's current `max_level`. |
| Schema conformance | Run the CLI at the target level (`codeanalyzer-<lang> -i testdata/fixture -a <1\|2\|3\|4> -o out/`), then `python -c "import json; from cldk_models import Application; Application(**json.load(open('out/analysis.json')))"` | Output validates against the shared CPG models — not just "the binary ran." |
| Monotonicity | Run `-a 1`, `-a 2`, `-a 3`, `-a 4` on the same fixture; diff the JSON | `json(-a 1) ⊆ json(-a 2) ⊆ json(-a 3) ⊆ json(-a 4)` — no level rewrites a lower level's facts. |
| Determinism | `codeanalyzer-<lang> -i testdata/fixture -j 1 -o j1/` vs `... -j <N> -o jN/`; diff | `-j N` output is byte-identical to `-j 1`. |
| Cross-projection | Compare `--emit neo4j` node/edge counts (at full depth) against the JSON at `max_level` | The two projections agree, modulo documented `HAS_*` containment edges. |

The full per-level assertions (named expected call-graph edges, exact PDG-slice sets, cache
round-trip tests, the two-tier identity gate) are in `testing-and-validation.md` — this matrix only
names the commands, not what "green" means field by field.

## SDK repos (`python-sdk`, `typescript-sdk`, …)

| Gate | Command | What it proves |
| --- | --- | --- |
| Mocked | `pytest tests/test_<lang>_analysis.py` (or `bun test` for the TS SDK) | Facade/view logic is correct given a fixture `analysis.json`; includes the public-API-stability assertion. |
| E2E | `pytest tests/test_<lang>_e2e.py` | The real binary produces conformant output end to end; skips cleanly when the binary is absent, must pass when it's on `PATH`. |
| Backend-contract | `pytest tests/test_<lang>_backend_contract.py` | The concrete backend implements every `<Lang>AnalysisBackend` ABC method (local/Neo4j parity). |
| Client-analysis (if L3/L4 exposed) | the slice/taint gate tests named in `sdk-testing.md § Client-analysis gates` | Slice and taint queries over the analyzer's graph match hand-computed expected sets. |

All three core tiers must be green before a merge is even considered mergeable, independent of
whether a release follows.

## Docs repos (`docs`)

| Gate | Command | What it proves |
| --- | --- | --- |
| Build | `mkdocs build --strict` (the `main` mkdocs front) and/or `npm run build` (the `astro` branch's Astro/Starlight front) | The site builds cleanly on the content you're about to publish — a broken build is not a docs-only no-op. |

Both fronts are the same repo (`skills/maintaining-cldk/references/repo-map.md`) — check whether the
change reaches one or both before treating a single green build as sufficient.

## Reading the result

"Green" means every applicable row above ran on the current commit and its output was read, not
assumed. A gate you didn't run is not a gate you passed.
