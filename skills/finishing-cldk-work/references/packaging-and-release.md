# Packaging & release: tag-triggered automation

Release mechanics for both halves of the ladder that reach this rung: an **analyzer**
(`codeanalyzer-<lang>`) cutting its own distribution, and an **SDK** (`python-sdk`,
`typescript-sdk`, …) picking up a new analyzer release via a pin bump and cutting its own. Neither
is a manual, one-off act — both are `git tag vX.Y.Z && git push origin vX.Y.Z` triggering a CI
workflow that does the rest. Never publish by hand; if the tag-push doesn't produce the artifact,
fix the workflow rather than uploading around it.

## Analyzer release: the thin-PyPI-binary model

The analyzer repo builds its self-contained binary for every supported platform, then a **tag-
triggered** `.github/workflows/release.yml` publishes it three ways in one coordinated run. The
reference implementation is `codeanalyzer-ts` (`packaging/python/` + `.github/workflows/release.yml`)
— mirror it for any new analyzer.

1. **Thin PyPI package `codeanalyzer-<lang>`** — one platform-tagged wheel per OS/arch, each
   carrying the prebuilt binary under `_bin/` and exposing `bin_path()`. This is what the Python SDK
   `pip`-depends on.
2. **Raw binaries as GitHub Release assets**, with a SHA256 checksum per artifact — for consumers
   that can't `pip install`, and what the TypeScript SDK downloads directly.
3. **A Homebrew formula** (`Formula/codeanalyzer-<lang>.rb`) pushed to the shared tap
   `codellm-devkit/homebrew-tap`, so end users get `brew install codeanalyzer-<lang>`.

**Two wheel shapes.** Compiled-binary analyzers (TS, Go, Rust, C++, JVM) ship a platform-tagged
wheel (`py3-none-<platform>`) carrying the binary, no usable sdist. A **Python** analyzer (e.g.
`codeanalyzer-python`) is the exception: the wheel carries importable Python code, is platform-
independent, and is imported in-process — no binary, no `bin_path()`.

**Build strategy** is a per-language decision, not a detail: single-host cross-compilation (Bun,
Go, Rust — one CI job emits every platform binary) when the toolchain cross-compiles cleanly, or a
native-runner build matrix (GraalVM `native-image`, clang with per-target sysroots — one CI leg per
`(os, arch)` fanning in to one publish job) when it can't. State which one applies in the analyzer
README's Architecture & Tooling section.

### The release workflow, in order

Trigger on `v*.*.*` tags (+ `workflow_dispatch`); `permissions: contents: write` (+ `id-token: write`
for PyPI OIDC):

1. Verify the tag version matches the analyzer manifest; gate on the analyzer's own test suite
   **first** — on failure, delete the just-pushed tag (`git push --delete origin <tag>`) so a broken
   build leaves no half-released version behind.
2. Build the platform wheels (single-host: one job runs the per-target loop; matrix: one leg per
   `(os, arch)`, then a fan-in job).
3. `auditwheel repair` Linux wheels to a manylinux policy (cover musllinux or document it
   unsupported); emit a SHA256 checksum per artifact.
4. **Smoke-test every wheel before publishing** — install on a clean runner, run
   `codeanalyzer-<lang> --help` or a tiny fixture analysis.
5. Extract raw binaries into `release-bins/`.
6. Publish the GitHub Release with the binaries + checksums as assets.
7. Publish the wheels to PyPI as `codeanalyzer-<lang>` — Trusted Publishing (OIDC), no long-lived
   token; `skip-existing: true` so a re-run is idempotent.
8. **Separate `homebrew` job** (`needs: release`, fed `release-bins/` via artifact — not a rebuild):
   generate the formula, push it to `codellm-devkit/homebrew-tap` with a `HOMEBREW_TAP_TOKEN` PAT.
   Isolating this job matters: it's the step most likely to fail (cross-repo PAT), and if it rode
   inside the publish job a token failure would mark an otherwise-successful PyPI+Release run red
   and unrecoverable-without-a-new-tag.

For a **Python analyzer**, drop steps 2–5 (compile/extract) and publish one pure wheel + sdist.
Ship no sdist for compiled analyzers, or one whose build fails with a clear "no prebuilt binary for
this platform" message — never let pip silently fall back to a from-source compile.

Tag the release `vX.Y.Z` with real notes: a hand-curated *Keep a Changelog* block (`### Added` /
`### Changed` — mark **BREAKING** inline / `### Fixed`) plus an auto-generated "Detailed Changes"
block. Don't ship a release with an empty body.

## SDK release: pin bump, then its own release

An SDK never re-publishes an analyzer's artifact — it depends on it. Once an analyzer release
exists (PyPI + Release binaries, above), the SDK's release is a two-step act:

1. **Bump the pin** to the just-released version — the Python SDK's `pyproject.toml`
   `dependencies` (`codeanalyzer-<lang>==X.Y.Z`) and its `[tool.backend-versions]` table; the
   TypeScript SDK's equivalent pin to the same tag. This is its own PR, reviewed and merged before
   any tag.
2. **Cut the SDK's own release** the same tag-triggered way: a `chore(release): X.Y.Z` PR bumps the
   SDK's own version + changelog (this alone ships nothing), then `git tag vX.Y.Z && git push
   origin vX.Y.Z` triggers the SDK's release workflow — its own test suite, its own PyPI/npm
   publish, and (if wired) a docs-repo dispatch to regenerate the API reference. A version bump PR
   with no tag pushed is a no-op release-wise; don't mistake merging it for shipping.

A pin bump with no analyzer release behind it, or an analyzer release with no consumer ever bumping
the pin, both leave the fix unreachable by users — "the fix is released" and "the fix is
consumable" are different claims; the pin is the gate between them.

## Version lockstep (the one rule that bites)

Keep the version identical across all of these for a given analyzer release, or pip resolves a
mismatched binary:

- the analyzer manifest (`package.json` version, or the build version for Go/Rust/JVM);
- `packaging/python/pyproject.toml`'s `project.version` **and** `__init__.py`'s `__version__`;
- the Python SDK pin — both `dependencies` and `[tool.backend-versions]`;
- the TypeScript SDK pin — the Release tag/binary filename it downloads;
- the Homebrew formula's `version` and asset URLs/checksums — the release workflow regenerates this
  every tag; don't hand-edit it.

## How each SDK consumes the artifact

- **Python SDK** — resolves the binary in priority order: `analysis_backend_path` →
  `$CODEANALYZER_<LANG>_BIN` → `codeanalyzer_<lang>.bin_path()` (the pip package) → an in-tree
  bundled fallback. (Python analyzer: `import codeanalyzer_<lang>`, run in-process.)
- **TypeScript SDK** — cannot consume a PyPI wheel; resolves `analysisBackendPath` →
  `$CODEANALYZER_<LANG>_BIN` → the GitHub Release asset binary.

This is the contract `cldk-sdk-frontend` wires against — publish accordingly, and don't change the
resolution order without updating both sides.
