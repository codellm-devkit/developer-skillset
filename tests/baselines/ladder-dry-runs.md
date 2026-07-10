# Ladder dry runs (WI8 validation pass)

Whole-ladder walks: a subagent, dispatcher's `using-cldk-devtools` skill
prepended, cwd = this worktree
(`/Users/rkrsn/workspace/codellm-devkit/developer-skillset-sdd`), instructed
DRY RUN — narrate the ladder end to end, do not implement, and ground every
claim by reading the actual `SKILL.md` files under `skills/` as it goes.
These are validation walks, not RED/GREEN scenario baselines — there is no
no-skill counterpart run for either.

## Dry-run A — maintenance flow

Task (verbatim): "In codeanalyzer-go, call edges to methods on embedded
structs are dropped (resolver bug, no schema change needed). Walk the
cldk-devtools ladder for this work end to end — do not implement; narrate
each skill you would enter, what you would do there, its hard gates, and the
exact handoff to the next skill, reading the actual SKILL.md files in
skills/ as you go."

### Outcome: PASS

The agent routed via the dispatcher's routing table
("Bug fix (analyzer or SDK), behavior-preserving" → `maintaining-cldk` →
`maintain → finishing`), correctly staying off the `designing-cldk-changes`
branch since the task itself states no schema change is needed.

In `maintaining-cldk` it ran, in order: **triage** (reproduce-first per
`references/triage-playbook.md`, flagging that `codeanalyzer-go`'s `main` is
a stub and the real fixtures live on a feature branch — checked the actual
repo-map note rather than assuming); the **HARD-GATE** check, quoted
verbatim from the file ("If the fix changes schema v2 output ... or a public
SDK API, STOP") and explicitly reasoned as *not tripped* (resolver-only,
no new node/edge/field, no public API move); the **fix loop**; and the
**propagation sweep** per `references/propagation-checklist.md`, producing a
verdict in the required shape ("**Propagation verdict:** codeanalyzer-java
(same-shape gap suspected ...) | none for SDK pins, because neither
python-sdk nor typescript-sdk currently wires codeanalyzer-go").

Handoff out of `maintaining-cldk` quoted its `## Terminal State` verbatim
("The ONLY skill you invoke after maintaining-cldk is finishing-cldk-work
(or designing-cldk-changes via the contract gate; or stop at a triage
verdict if there is nothing to fix)") and correctly took the
`finishing-cldk-work` branch, carrying the propagation verdict.

In `finishing-cldk-work` it walked verification gates (per
`references/release-gates.md`'s analyzer matrix — fixture suite, schema
conformance, monotonicity, determinism, cross-projection, re-run "now," not
trusted from an earlier pass — quoting the file's own HARD-GATE on this),
made an explicit **ship decision** ("a bug fix ... forces a release," per
the file's stated criteria — release warranted even though no SDK pin needs
bumping), release mechanics (tag-triggered PyPI + GitHub Release + Homebrew,
per `references/packaging-and-release.md`), and closeout — including
following the propagation verdict through to a filed follow-on issue for
`codeanalyzer-java`, quoting the finishing skill's own line that "a verdict
that names [a repo] and produces zero new issues is a verdict that was read
and then ignored."

**PASS criterion met:** `maintaining-cldk` (triage → gate check → fix loop →
propagation verdict) → `finishing-cldk-work` (gates → ship decision →
closeout); each handoff named the correct next skill, quoting the actual
`## Terminal State` text from both `skills/maintaining-cldk/SKILL.md` and
`skills/finishing-cldk-work/SKILL.md` rather than inferring it from the
dispatcher diagram alone. `designing-cldk-changes` was never entered.

## Dry-run B — new-language flow

Task (verbatim): "Add Zig support to CLDK end to end — walk the ladder, do
not implement, narrate each skill entry/exit and entry-precondition checks."

### Outcome: PASS

The agent routed via the dispatcher's routing table's "New language for
CLDK" row → `designing-cldk-changes` → `design → backend → frontend →
finishing`, explicitly ruling out `maintaining-cldk` since this is the
canonical structural-work case.

In `designing-cldk-changes` it checked its own stated **Entry
Preconditions** (structural work, not a bare maintenance escalation), ran
the **Contract-Impact Triage** ("does this change the schema v2 output?" /
"which repos are touched?" against the triage table's "New language" row —
new `codeanalyzer-zig`, `python-sdk` + TS SDK, docs), named both **design
loops** (analyzer-side and SDK-side, run with the user, never solo) as
applicable, and quoted the `<HARD-GATE>` verbatim ("No implementation rung
may be entered for structural work until the spec exists AND the GitHub
epic + child issues exist"). It then quoted the exact `## Terminal State`
handoff ("the first affected rung: codeanalyzer-backend if any analyzer is
touched...") and correctly proceeded to `codeanalyzer-backend`, since a new
analyzer is touched.

In `codeanalyzer-backend` it checked entry preconditions (spec + epic must
exist — satisfied by the prior rung's gate), identified **Path (A) new
language**, walked the level ladder (L1→L2→L3→L4, each gated on "fixture
suite green + schema conformance green"), quoted the `<HARD-GATE>` on level
advancement and schema divergence, and correctly noted packaging/release is
out of scope here. It quoted the exact Terminal State handoff ("cldk-sdk-
frontend if any SDK is affected... else finishing-cldk-work") and proceeded
to `cldk-sdk-frontend`, since the spec named `python-sdk` (+ TS SDK) as
affected.

In `cldk-sdk-frontend` it explicitly checked **both** entry gates before
proceeding (analyzer conformant and emitting real output; facade surface
already decided by the prior rung's SDK-side design loop — not re-decided
here), quoted the **Iron Rule** and its `<HARD-GATE>` (no public accessor
changes name/signature/return type without going back through design), and
described per-SDK wiring (`models → facade → dispatch branch → version pin →
tests`) and the three testing tiers. It quoted the Terminal State handoff
("finishing-cldk-work. (A future cocoa rung slots in here.)") and proceeded
to `finishing-cldk-work`.

In `finishing-cldk-work` it checked entry preconditions correctly for this
arrival path — noting arrivals from `codeanalyzer-backend`/`cldk-sdk-
frontend` "carry no verdict of their own" and gates must be re-run here, not
assumed (quoting the file) — walked the verification-gates HARD-GATE, made
an explicit ship decision (new language reaching users forces a release),
described release mechanics for both the analyzer and the SDK pin bump, and
closeout. Since this walk originated in `designing-cldk-changes` rather than
a `maintaining-cldk` propagation sweep, it correctly noted there is no
propagation verdict to carry forward and the ladder ends here.

**PASS criterion met:** `designing-cldk-changes` (triage, both design loops
named, spec+epic gate quoted) → `codeanalyzer-backend` (levels, gates) →
`cldk-sdk-frontend` (iron rule, wiring) → `finishing-cldk-work`, strictly in
that order, with entry preconditions explicitly checked and quoted at every
rung before entering it.

## Files read by both walks (confirmed to exist on disk)

`skills/using-cldk-devtools/SKILL.md`, `skills/designing-cldk-changes/SKILL.md`,
`skills/maintaining-cldk/SKILL.md`, `skills/codeanalyzer-backend/SKILL.md`,
`skills/cldk-sdk-frontend/SKILL.md`, `skills/finishing-cldk-work/SKILL.md`,
plus the references each walk cited (`canonical-schema.md`,
`schema-design-loop.md`, `sdk-facade-design-loop.md`,
`epic-and-issue-templates.md`, `tooling-menu.md`, `analyzer-architecture.md`,
`testing-and-validation.md`, `python-sdk-wiring.md`,
`typescript-sdk-wiring.md`, `release-gates.md`, `packaging-and-release.md`,
`docs-and-closeout.md`, `triage-playbook.md`, `propagation-checklist.md`,
`repo-map.md`). No write actions were taken by either subagent.
