# Docs and closeout

The last mile: making the docs match what actually shipped, closing the paperwork, and honoring
the propagation verdict `maintaining-cldk` handed off. Skipping this is how a merged, released,
gate-green change still leaves the org in a stale or half-tracked state.

## Docs surfaces

Three surfaces, each with its own staleness question — check all three, not just the one that
comes to mind first:

- **Repo READMEs** — the analyzer's or SDK's own `README.md`: supported languages/levels, install
  instructions (`pip install codeanalyzer-<lang>`, `brew install codeanalyzer-<lang>`), CLI flag
  docs, version badges. A new level, a new accessor, or a new install channel that isn't reflected
  here is invisible to anyone who doesn't read source.
- **CLAUDE.md / AGENTS.md / GEMINI.md agent guides** — each repo's own agent-facing conventions
  (branch naming, test layout, commit style). These drift when a repo's structure changes (a new
  package, a renamed workflow) but the fix rarely thinks to touch them.
- **The docs site** (`docs` repo, `codellm-devkit.info`) — two live fronts on the same repo: `main`
  (mkdocs) and the `astro` branch (Astro/Starlight redesign). A behavior-preserving bug fix rarely
  needs a docs change; a fix that changes an error message, a CLI flag's behavior, a documented
  limitation, or a version number usually does. Check whether the change reaches one front or both
  — don't assume parity between them.

If the release just cut changed a public surface (new field visible through an accessor, new CLI
flag, new facade method), at least one of these three needs an update. "No behavior changed for
users" is the only clean exemption, and it should already have been established in the Ship
Decision step.

## Issue and epic closeout etiquette

- **Close the child issue(s)** this work resolves, with a comment naming the merge commit / release
  tag that resolved it — not a bare "done."
- **Tick the epic's checklist**, if this work traces to one (`designing-cldk-changes`'s epic + child
  issue structure, `skills/designing-cldk-changes/references/epic-and-issue-templates.md`). A child
  issue closing is what advances the epic's `CHILDREN` checklist; go edit the epic, don't leave it
  for someone else to notice the child closed.
- **Don't close the epic itself** until every child on its checklist is closed and its own
  Definition of Done (gates green across every affected repo, versions pinned in lockstep, docs
  updated) is genuinely satisfied — not just the child you personally worked.
- For work with no epic (most `maintaining-cldk` entries — a bug fix or small feature stands alone),
  closing its single issue with the resolving commit/release reference is the whole of closeout on
  this axis.

## Propagation-verdict follow-through

`maintaining-cldk`'s propagation sweep hands off a **required** verdict in this exact shape:

> **Propagation verdict:** \<list of follow-on repos + why\> | none, because \<reason\>.

Reading that verdict here is not optional, and neither is acting on it:

- **If the verdict is `none`**, confirm its reasoning is still legible (it should already show its
  work — what was checked, why each came back negative) and stop; there is nothing further to file.
- **If the verdict lists follow-on repos**, file a tracking issue for each one **before** declaring
  this work closed out. Each filed issue is the seed of a new `maintaining-cldk` entry — this is
  exactly what the Terminal State means by "each becomes a new maintaining-cldk entry." A verdict
  that names `codeanalyzer-java` and `python-sdk` but produces zero new issues is a verdict that was
  read and then ignored — the most common way this rung's work silently goes incomplete.
- Link each follow-on issue back to the work that surfaced it, so the trail from "we found this
  while fixing X" to "here's the tracked fix for Y" survives past this conversation.

## Definition of done (closeout)

- [ ] Every gate in `references/release-gates.md` that applies to this repo ran on the commit being
  shipped, and its output was read.
- [ ] The ship decision was made explicitly (release vs merge-only) and, if a release was cut, its
  mechanics followed `references/packaging-and-release.md` including version lockstep.
- [ ] Docs surfaces checked against the actual change — README, agent guides, docs site — updated or
  explicitly ruled not-needed.
- [ ] Child issue(s) closed with a reference to the resolving commit/tag; epic checklist ticked if
  one exists.
- [ ] Propagation verdict re-read; every listed follow-on repo has a filed issue, or the verdict was
  `none` with visible reasoning.
