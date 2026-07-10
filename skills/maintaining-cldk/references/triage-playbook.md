# Triage playbook

Reproduce-first discipline for maintenance work. A report is a claim, not a
fact — the first job is turning it into an observed, minimal failure, or
concluding it isn't one.

## Fixture conventions per repo type

Fixture layout is **not uniform** across the org — check the actual repo,
don't assume a shared convention:

- **`codeanalyzer-python`, `codeanalyzer-typescript`** — `test/fixtures/`,
  split by intent (`single_functionalities/` for one-construct-at-a-time
  cases, `whole_applications/` or `sample-app/`/`dataflow-app/` for realistic
  multi-file programs).
- **`codeanalyzer-java`** — `src/test/resources/test-applications/<case>/`,
  one directory per named scenario (e.g. `record-class-test/`,
  `call-graph-test/`, `missing-node-range-test/` — the naming pattern is
  `<feature>-test`).
- **`codeanalyzer-go`** — `testdata/<case>/` as a real Go module per case,
  registered in a shared fixture table in `internal/core/testsetup_test.go`
  and exercised by `internal/core/<case>_test.go`. As of this writing the
  local `main` checkout is a stub with no `testdata/` at all — the working
  fixtures live on the implementation branch; check which branch actually
  has source before assuming `main` reflects current behavior.
- **`python-sdk`** (frontend) — `tests/resources/<lang>/` (sample projects),
  `tests/analysis/<lang>/` (facade-level tests), `tests/models/<lang>/`
  (Pydantic model tests) — one fixture can serve both the analyzer's own
  tests and the SDK's E2E tests when the two repos are checked out side by
  side (`skills/cldk-sdk-frontend/references/sdk-testing.md`).
- **`docs`** — no code fixture; the "repro" is the broken render or the
  broken command. Check both live fronts (`main`'s mkdocs tree under
  `docs/`, the `astro` branch's content collections under
  `src/content/docs/` — see `references/repo-map.md`).
- Anything not covered above: read the target repo's own `CLAUDE.md`/`AGENTS.md`
  first; do not invent a fixture convention that contradicts it.

## Minimal-repro construction

- **Analyzer bug**: construct the smallest fixture that exhibits the
  reported symptom, add it alongside existing fixtures using the repo's own
  naming convention (above), and write the assertion that fails today. Don't
  reuse an existing fixture that only incidentally triggers the bug — a
  fixture built to isolate one construct is what lets the fix loop's failing
  test be specific rather than coincidental.
- **SDK bug**: write the failing test against the public facade first,
  using the smallest analyzer output (real or a minimal recorded fixture)
  that reproduces it.
- **Docs bug**: reproduce the broken render (build the site locally) or the
  broken command (run it as documented, verbatim) before touching content —
  a docs bug report is sometimes stale instructions against current behavior,
  not a doc defect.
- Before writing the repro, check whether one already exists: search the
  target repo's fixtures for anything closely related — you may be able to
  extend an existing case instead of adding a near-duplicate.

## When to stop at a triage verdict

Triage can legitimately end without a fix. Say so explicitly, as one of:

- **not-a-bug** — the reported behavior is correct; reproduce it, show why
  it's correct, and say so in the issue.
- **duplicate** — an existing issue/fixture already covers this; link it.
- **needs-design** — reproducing the report confirms it's real, but fixing
  it would move schema v2 output or a public SDK API (the contract gate in
  `SKILL.md`), or it genuinely spans repos in a way that needs a spec before
  any code moves. Route to `designing-cldk-changes`, and say why.

A triage verdict is a legitimate terminal state for this mode — it is not a
failure to "not fix" something that shouldn't be fixed as reported.

## Issue-comment etiquette

- State the verdict first (reproduced / not-a-bug / duplicate / needs-design),
  then the evidence — don't bury the conclusion under process narration.
- If you reproduced it, show the minimal repro (or link the fixture/commit),
  not just "confirmed."
- If you're closing as not-a-bug or duplicate, say precisely what the
  correct behavior is or which issue it duplicates — a bare "not a bug" with
  no reasoning invites the same report again.
- If you're routing to `designing-cldk-changes`, say what changed your mind
  mid-triage (which schema/API surface got touched) — the next person
  picking this up should not have to re-derive the escalation.
- Never claim a fix is verified without having actually run the reproduction
  and the fix's test — matching the global "never fake verification" rule
  used across this ladder.
