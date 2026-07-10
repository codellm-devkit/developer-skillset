# Propagation checklist

Run this after the fix loop, before you say the work is done. A fix that
compiles and passes its own repo's tests is a **local** fix; this checklist
is what turns it into a **CLDK-wide** one, or confirms deliberately that it
doesn't need to be. Every item gets an explicit answer — "didn't check" is
not an option.

## 1. Sibling analyzers — same bug class?

Pull the sibling list from `references/repo-map.md`. For a resolver /
symbol-table / call-graph bug in one `codeanalyzer-<lang>`, ask: does the
same *shape* of bug exist in the others' equivalent code path? Look for the
structurally same construct across languages — e.g. a dropped call edge
through struct embedding (Go) has analogues in interface default methods
(Java), mixins/traits (Rust, Swift), and prototype-chain method resolution
(TypeScript). You do not need to fix siblings now; you need to **check and
report**, per sibling:

- Confirmed present, filed as a follow-on issue.
- Confirmed absent (state why — different resolver design, no equivalent
  language construct, etc.).
- Not checked (only acceptable if the sibling doesn't implement this
  analysis level/feature at all — say so).

## 2. SDK version pins — bump needed?

Check `references/repo-map.md`'s pin chain. If the analyzer you fixed is
pinned by a version-locked dependency (`python-sdk`'s
`codeanalyzer-<lang>==X.Y.Z`, `typescript-sdk`'s equivalent), the fix does not
reach a single SDK user until:

1. the analyzer cuts a release with the fix (per
   `skills/codeanalyzer-backend/references/packaging-and-release.md`), and
2. the pinning SDK bumps its dependency to that version.

State explicitly whether a pin bump is needed, and in which SDK(s). "The fix
is released" is not the same claim as "the fix is consumable" — the pin is
the gate between them.

## 3. Docs — stale?

Does anything user-facing describe the old (buggy) behavior, the field/API
surface you touched, or the version you just bumped? Check the `docs` repo
(both fronts — see `references/repo-map.md`'s note that `main` and the
`astro` branch are the same repo with two live docs surfaces) and the
analyzer/SDK's own `README.md`. A behavior-preserving bug fix rarely needs a
docs change; a fix that changes an error message, a CLI flag's behavior, or
a documented limitation usually does.

## 4. Fixtures elsewhere encoding the old (buggy) behavior?

Search sibling repos' test fixtures for a fixture that asserts the *old,
wrong* behavior as if it were correct — these silently pin a regression in
place and will fight a sibling fix later. This is different from item 1:
item 1 asks whether the bug exists elsewhere; item 4 asks whether some other
repo's test suite has **already encoded the bug as expected output**. Flag
any you find, even if you don't fix them now.

## Output: the propagation verdict (required)

Once all four items are answered, produce this exact shape — it is what
`finishing-cldk-work` reads at closeout:

**Propagation verdict:** <list of follow-on repos + why> | none, because
<reason>.

Two valid forms, nothing else:

- `**Propagation verdict:** codeanalyzer-java (same embedded-method call-edge
  gap in interface default methods, issue filed), python-sdk (pin bump to
  0.4.0 needed once codeanalyzer-python releases).`
- `**Propagation verdict:** none, because the bug was in codeanalyzer-go's
  Go-specific embedded-struct promotion logic; no sibling analyzer models
  struct embedding the same way, no SDK pins codeanalyzer-go yet, and no
  fixture elsewhere encodes the old behavior.`

A verdict of "none" must still show its work — name what you checked and why
each came back negative, not just the word "none."
