# Packaging & release: the thin-PyPI-binary model

This is the analyzer's **distribution layer** — how the compiled `codeanalyzer-<lang>` reaches the
SDKs, and how releases are cut. It is a cross-cutting concern: neither SDK builds or bundles the
binary itself anymore; both consume what the **analyzer repo** publishes. The reference
implementation is `codeanalyzer-ts` (`packaging/python/` + `.github/workflows/release.yml`); mirror
it.

## The model in one paragraph

The analyzer repo **builds its self-contained binary for every supported platform** (by
single-host cross-compilation or a native-runner build matrix — see "Build strategy" below), then
publishes them three ways from a **tag-triggered GitHub release workflow**:
1. a **thin PyPI package `codeanalyzer-<lang>`** — one **platform-tagged wheel per OS/arch**, each
   carrying the single prebuilt binary, exposing `bin_path()`;
2. the **raw binaries as GitHub Release assets**, for consumers that can't `pip install`; and
3. a **Homebrew formula `Formula/codeanalyzer-<lang>.rb`** pushed to the shared tap
   `codellm-devkit/homebrew-tap`, so end users get `brew install codeanalyzer-<lang>` (see
   "Homebrew tap distribution" below).

The SDKs then **depend on that published artifact** rather than bundling a binary: the Python SDK
`pip`-depends on the `codeanalyzer-<lang>` wheel and calls `bin_path()`; the TypeScript SDK pulls
the raw binary from the Release asset (it can't consume a PyPI wheel). This replaces the old
"bundle the binary in the SDK / download-on-first-run" approach. Homebrew is a **fourth consumer**
aimed at humans, not SDKs: it reuses the same Release-asset binaries (compiled case) or the same
PyPI package (Python case) — never a new build.

> **Why a PyPI package of binaries, not bundling in the SDK?** It makes the binary a normal,
> versioned, pip-resolved dependency — `pip install cldk` pulls the right platform wheel
> automatically, the SDK repo stays small (no committed 70 MB binaries), and the analyzer owns its
> own release cadence. It also unifies the story: **every** backend is now `pip install
> codeanalyzer-<lang>`. The only difference is what the wheel *carries* (see the two cases below).

## Two wheel shapes — binary vs in-process

`codeanalyzer-<lang>` is always a PyPI package, but its contents differ by analyzer language:

- **Compiled-binary analyzer** (TS, Go, Rust, C++, JVM — the common case): the wheel is
  **platform-tagged** (`py3-none-<platform>`) and carries the prebuilt binary under
  `_bin/`. It exposes `bin_path() -> Path`. The SDK runs it as a **subprocess**. Python-agnostic →
  one wheel per OS/arch (no per-Python-version matrix); intentionally **no usable sdist** (the
  binary can't be built without that language's toolchain).
- **Python analyzer** (the exception): the wheel carries **Python code**, is platform-independent,
  and is imported **in-process** — exactly today's `codeanalyzer-python`. No binary, no
  `bin_path()`. Still `pip install codeanalyzer-python`, pinned the same way.

So "ship a binary" and "ship a pip package" are no longer opposites: the binary *is* shipped
inside a pip package. The in-process Python case is just a wheel whose payload is code, not a
binary.

## `packaging/python/` layout (compiled-binary case)

Mirror `codeanalyzer-ts/packaging/python/`:

```
packaging/python/
  pyproject.toml                       # hatchling; force-includes _bin/* as artifacts
  build_wheels.sh                      # cross-compile + retag one wheel per platform
  README.md                            # packaging + versioning + SDK-integration notes
  src/codeanalyzer_<lang>/
    __init__.py                        # __version__, bin_path()
    _bin/.gitignore                    # binary is produced at build time, gitignored
```

- **`__init__.py`** exposes `bin_path()`: resolve `_bin/codeanalyzer-<lang>[.exe]` via
  `importlib.resources`, raise a clear `FileNotFoundError` if the platform wheel shipped no binary,
  and restore the executable bit on POSIX (wheels don't preserve it). Pin `__version__`.
- **`pyproject.toml`**: `hatchling` build backend; the binary lives under `_bin/` and is gitignored
  (built per platform), so force-include it with
  `[tool.hatch.build.targets.wheel] artifacts = ["src/codeanalyzer_<lang>/_bin/*"]` — the same
  trick the python-sdk uses to force-include the Java jar. Keep the sdist minimal (metadata only).
- **`build_wheels.sh`** (single-host case): loop over `(<compile-target> : <wheel-platform-tag>)`
  pairs; for each, cross-compile the binary into `_bin/`, build a pure `py3-none-any` wheel, then
  **retag** it to the platform with `python -m wheel tags --remove --platform-tag <plat>`. One wheel
  per platform, not per Python version. Example target/tag pairs (Bun):
  `bun-darwin-arm64:macosx_11_0_arm64`, `bun-linux-x64:manylinux2014_x86_64`,
  `bun-windows-x64:win_amd64`, etc.
  - **Linux wheels should be `auditwheel repair`-ed** to a real manylinux policy (not just tagged
    `manylinux2014` by hand) so they install across distros, not only the build image. The
    by-hand `wheel tags` retag is the quick path; `auditwheel` is the correct one for Linux.
  - **Cover musllinux** (Alpine): add `musllinux_1_2_x86_64` (+ `aarch64` if feasible), **or**
    explicitly document Alpine as unsupported — don't leave it implicit.
  - In the **native-runner-matrix case** (below), there is no single host that can produce every
    binary, so this script's per-target loop becomes one matrix leg per target instead.

For a **Python analyzer**, there is no `packaging/python/` sidecar and no `build_wheels.sh`: the
analyzer repo's own root `pyproject.toml` *is* the publishable package (like `codeanalyzer-python`
today).

## Build strategy: single-host cross-compile vs native-runner matrix

**Which CI shape you use depends on whether your toolchain can cross-compile — this is a
load-bearing per-language decision, not a detail.** Pick the right one:

- **Single-host cross-compilation** — one CI job emits every platform binary. Use it when the
  toolchain cross-compiles cleanly: **Bun** (`bun build --compile --target=…`, the
  `codeanalyzer-ts` reference), **Go** (`GOOS`/`GOARCH`), **Rust** (target triples, `cross`).
  `build_wheels.sh`'s per-target loop *is* the build. Cheapest and simplest — prefer it when
  available.
- **Native-runner build matrix** — one CI leg per `(os, arch)` on its own runner, each compiling
  natively, then a fan-in job that gathers all artifacts and publishes once. Use it when the
  toolchain **cannot** cross-compile reliably: **GraalVM `native-image`** (must build on each
  target OS/arch — there is no single-host cross build), and **clang/libclang/C++** when targets
  need their own sysroots. This is the cargo-dist-style shape (matrix → per-target artifact +
  checksum → coordinated release). It's heavier but it's the *only* correct option for GraalVM, so
  don't try to force a JVM analyzer through the single-host path.

State which one applies under the analyzer README's **Architecture & Tooling** heading, since it
follows directly from the packaging-tooling choice.

## Release automation (standard practice — every analyzer gets it)

A tag-triggered `.github/workflows/release.yml` is **not optional**; it is part of standing up a
language pack. For the **single-host** case, mirror `codeanalyzer-ts/.github/workflows/release.yml`.
Trigger on `v*.*.*` tags (plus `workflow_dispatch`), `permissions: contents: write` (+ `id-token:
write` if using OIDC, below), and:

0. **verify the tag version matches the analyzer manifest and gate on tests first.** Derive the
   version from the `vX.Y.Z` tag and fail fast if it differs from `package.json` / the build version
   (this is what keeps the PyPI/Release/brew versions in lockstep — see "Version lockstep"). Then
   run the analyzer's own typecheck + test suite **before** building any wheel, and on failure
   **delete the just-pushed tag** (`git push --delete origin <tag>`) so a broken build leaves no
   half-released `vX.Y.Z` behind. The `codeanalyzer-ts` reference does both at the top of the job;
   mirror it.
1. set up the analyzer toolchain (Bun / GraalVM / Go / Rust) **and** Python build tooling
   (`build wheel`; `auditwheel` for Linux);
2. **build the platform wheels** — single-host: `build_wheels.sh` builds every target in one job;
   **matrix**: one leg per `(os, arch)` runs the native compile (`./gradlew nativeCompile` for
   GraalVM) and packages that leg's wheel, then a **fan-in** job collects all legs;
3. **`auditwheel repair` Linux wheels** to a manylinux policy; emit a **SHA256 checksum per
   artifact** (cargo-dist-style);
4. **smoke-test every wheel before publishing** — install it on a clean runner and run
   `codeanalyzer-<lang> --help` / a tiny fixture analysis, so a broken native/reflection config
   can't ship;
5. **extract the raw binaries** from the wheels into `release-bins/` (one per platform);
6. **publish the GitHub Release** with the raw binaries **and their checksums** as assets
   (`softprops/action-gh-release@v2`);
7. **publish the wheels to PyPI** as `codeanalyzer-<lang>` in **one coordinated step**. **Use
   PyPI Trusted Publishing (OIDC)** — `pypa/gh-action-pypi-publish@release/v1` with `id-token:
   write` and no long-lived `PYPI_API_TOKEN` secret; optionally publish to **TestPyPI** first.
   **Set `with: skip-existing: true`** so a re-run is idempotent: PyPI rejects a duplicate
   version upload with a `400`, which would fail the whole job — `skip-existing` makes it skip the
   already-published version instead. (This is exactly what the `codeanalyzer-ts` reference does
   today.)
8. **push the Homebrew formula** to `codellm-devkit/homebrew-tap` (see "Homebrew tap distribution"
   below) — the third channel, cut from the same tag. Make this a **separate job**
   (`needs: release`), not a trailing step of the publish job — see "Isolate the Homebrew push in
   its own job" below for why.

For a **Python analyzer**, drop the compile/extract steps: build one pure wheel + sdist and publish
(OIDC-preferred) under the same `codeanalyzer-<lang>` name.

**sdist must be unambiguous either way:** ship no sdist, or an sdist whose build deliberately fails
with a clear "no prebuilt `codeanalyzer-<lang>` binary for this platform/arch" message — so pip
never silently falls back to a from-source compile (e.g. a GraalVM build) on an unsupported
platform.

### Release notes (mirror `codeanalyzer-python`'s style)

Tag the release `vX.Y.Z` and give it real notes, structured like `codeanalyzer-python`'s GitHub
Releases:
- a hand-curated **"Release Notes"** block in *Keep a Changelog* form — `### Added` / `### Changed`
  (mark **BREAKING** inline) / `### Fixed`; then
- an auto-generated **"Detailed Changes"** block (GitHub's release-notes generation / a
  release-drafter config) grouping merged PRs under headings like `🚀 Features`.

Keep a `CHANGELOG.md` as the source for the curated block. Don't ship a release with an empty body.

## Homebrew tap distribution (the human-facing channel)

`brew install codeanalyzer-<lang>` is the third channel and the one end users actually type. It is
**standing practice, not optional** — every analyzer gets a formula in the shared tap, generated and
pushed by the **same release workflow**, so a tag mints PyPI + Release assets + the brew formula in
lockstep. The reference implementation is `codeanalyzer-ts/packaging/homebrew/` — mirror it.

There is **one tap for all analyzers**: the repo `codellm-devkit/homebrew-tap`, holding one
`Formula/codeanalyzer-<lang>.rb` per language. Users add it once and install any backend by its
bare name:

```bash
brew tap codellm-devkit/tap            # repo codellm-devkit/homebrew-tap
brew install codeanalyzer-typescript   # bare name; installs the analyzer's CLI
```

> **Naming.** The Homebrew formula name = the **PyPI package name** = `codeanalyzer-<lang>` (file
> `Formula/codeanalyzer-<lang>.rb`, class `Codeanalyzer<Lang>`). The *installed command* keeps the
> analyzer's own binary name (e.g. `cants`), which is independent of the formula name. Bare-name
> install works as long as no homebrew-core formula shares the name (none do for `codeanalyzer-*`).

### Two formula shapes — mirror the two wheel shapes

The formula's shape follows the same binary-vs-in-process split as the wheels (see "Two wheel
shapes" above):

- **Compiled-binary analyzer** (TS/Bun, JVM/GraalVM, Go, Rust, C++): the formula **downloads the
  raw per-platform binary from the GitHub Release assets** — the *same* `release-bins/` bytes the
  Release publishes, never a rebuild — and installs it. Homebrew stages a bare (non-archive)
  executable as-is, so `install` just renames it to the canonical command. Windows is omitted
  (Homebrew is macOS/Linux only). Example for a GraalVM-compiled Java analyzer (`codeanalyzer-java`,
  native-runner matrix → one binary per `(os, arch)` already in `release-bins/`):

  ```ruby
  class CodeanalyzerJava < Formula
    desc "CLDK Java analyzer -- emits canonical CLDK analysis.json"
    homepage "https://github.com/codellm-devkit/codeanalyzer-java"
    version "2.4.0"
    license "Apache-2.0"

    on_macos do
      on_arm   { url ".../codeanalyzer-java-macosx_11_0_arm64";   sha256 "..." }
      on_intel { url ".../codeanalyzer-java-macosx_10_12_x86_64"; sha256 "..." }
    end
    on_linux do
      on_arm   { url ".../codeanalyzer-java-manylinux2014_aarch64"; sha256 "..." }
      on_intel { url ".../codeanalyzer-java-manylinux2014_x86_64";  sha256 "..." }
    end

    def install
      bin.install Dir["codeanalyzer-java-*"].first => "codeanalyzer-java"
    end

    test do
      # use a flag that exits 0 without required args (--help / --version)
      assert_match "Usage", shell_output("#{bin}/codeanalyzer-java --help")
    end
  end
  ```

  GraalVM is the **native-runner-matrix** case, so there is no single host that produces every
  binary — the formula's per-platform `url`s simply point at the matrix legs' assets that the
  fan-in job already uploaded. Nothing GraalVM-specific leaks into the formula; it only ever sees
  Release assets.

- **Python analyzer** (`codeanalyzer-python`): there is no binary to download — the formula installs
  the **PyPI package**, so `brew install codeanalyzer-python` is "ready to go the moment a new
  release is minted to PyPI." Use a `Language::Python::Virtualenv` formula whose `url` is the PyPI
  **sdist** and whose `resource` blocks are auto-generated (`brew update-python-resources` /
  `homebrew-pypi-poet`) — regenerate the resources whenever deps change. If maintaining vendored
  resources is too heavy, the lighter sanctioned alternative is to document `pipx install
  codeanalyzer-python` instead of a formula; pick one and state it, don't leave Python implicit.

  ```ruby
  class CodeanalyzerPython < Formula
    include Language::Python::Virtualenv
    desc "CLDK Python analyzer -- emits canonical CLDK analysis.json"
    homepage "https://github.com/codellm-devkit/codeanalyzer-python"
    url "https://files.pythonhosted.org/.../codeanalyzer_python-0.1.15.tar.gz"
    sha256 "..."
    license "Apache-2.0"
    depends_on "python@3.12"
    # resource "jedi" do ... end   # auto-generated; one per transitive dep

    def install
      virtualenv_install_with_resources
    end

    test do
      assert_match "Usage", shell_output("#{bin}/codeanalyzer-python --help")
    end
  end
  ```

### `packaging/homebrew/` + the release step

Mirror `codeanalyzer-ts/packaging/homebrew/`:

```
packaging/homebrew/
  generate_formula.sh    # reads release-bins/ + REPO + VERSION -> emits Formula/codeanalyzer-<lang>.rb
```

- **`generate_formula.sh`** (compiled-binary case): for each expected per-platform binary in
  `release-bins/`, compute `shasum -a 256` and template the `on_macos`/`on_linux` blocks with the
  matching Release-asset `url`. It reads the **same bytes that were uploaded**, so the checksums are
  guaranteed to match. (Python case: there is no generator — the formula's `url`/`sha256` come from
  the published PyPI sdist; bump them with `brew bump-formula-pr` or regenerate resources.)
- **Release-workflow steps** — a **separate `homebrew` job** with `needs: release` and the same
  `if: startsWith(github.ref, 'refs/tags/')` gate, so the GitHub Release + PyPI channels are
  untouched by anything here. The publish job hands the binaries over via an artifact; the
  `homebrew` job consumes it:
  1. **(publish job) Upload `release-bins/`** with `actions/upload-artifact@v4` so the separate job
     can reach the binaries. Passing the same bytes as an artifact — rather than re-downloading the
     GitHub Release assets — keeps the formula `sha256`s byte-identical to what was just published.
  2. **(homebrew job) Download the artifact + derive `VERSION` from the tag**, then **Generate** —
     `./packaging/homebrew/generate_formula.sh release-bins > codeanalyzer-<lang>.rb`.
  3. **(homebrew job) Push to tap** — `git clone` the tap with a `HOMEBREW_TAP_TOKEN` PAT (the
     default `GITHUB_TOKEN` can't push to a *different* repo), copy the formula to
     `Formula/codeanalyzer-<lang>.rb`, commit `codeanalyzer-<lang> ${VERSION}`, and push (no-op
     cleanly if unchanged).

  The token is a repo secret on the analyzer repo (`gh secret set HOMEBREW_TAP_TOKEN`) with
  write/contents on `homebrew-tap`. Smoke-test the formula in CI the same way the wheels are
  smoke-tested: `brew install` from the tap on a clean runner and run `--help`.

#### Isolate the Homebrew push in its own job

Keep the tap push **out of the publish job**. If it rides as a trailing step of the single job that
also publishes to PyPI, two failure modes bite:
- **The tap push is the most likely step to fail** (it depends on a cross-repo PAT — an empty,
  expired, or under-scoped `HOMEBREW_TAP_TOKEN` fails with `Authentication failed`), and when it
  does it marks the *whole release* red even though PyPI + the GitHub Release already succeeded.
- **You can't cleanly re-run just the tap push.** `gh run rerun --failed` re-runs the whole failed
  job from the top — which re-hits the PyPI publish, and PyPI then `400`s on the already-published
  version (unless `skip-existing: true`, step 7). So a one-line token fix forces either a manual
  out-of-band `generate_formula.sh` + push, or a brand-new tag.

A separate `homebrew` job (`needs: release`, fed `release-bins/` via artifact) fixes both: a
tap-push failure is isolated from the already-shipped channels, and `gh run rerun --failed` retries
**only** the Homebrew job once the token is fixed — no wheels re-uploaded, no new tag. This split
plus `skip-existing` (step 7) is what makes a release recoverable instead of needing a version bump.

## Version lockstep (the one rule that bites)

Keep the version identical across **all** of these for a given release, or pip will resolve a
mismatched binary:
- analyzer manifest — `package.json` `version` (TS), the build version (Go/Rust/JVM);
- `packaging/python/pyproject.toml` `project.version` **and** `__init__.py` `__version__`;
- the **Python SDK** pin — `python-sdk/pyproject.toml`: both `dependencies`
  (`codeanalyzer-<lang>==X`) and `[tool.backend-versions] codeanalyzer-<lang> = "X"`;
- the **TypeScript SDK** pin — the Release tag / binary filename it downloads, kept in lockstep with
  the same `codeanalyzer-<lang>` release;
- the **Homebrew formula** in `codellm-devkit/homebrew-tap` — `Formula/codeanalyzer-<lang>.rb`'s
  `version` (and the asset URLs/`sha256`s it points at). The release workflow regenerates this on
  every tag, so it stays in lockstep automatically — don't hand-edit it.

## How each SDK consumes the artifact

The wiring itself belongs to the **cldk-sdk-frontend** skill; this is the contract it relies on, so
publish accordingly:

- **Python SDK** — adds `codeanalyzer-<lang>==X` to `dependencies` and resolves the binary in
  priority order: `analysis_backend_path` → `$CODEANALYZER_<LANG>_BIN` →
  **`codeanalyzer_<lang>.bin_path()`** (the pip package) → in-tree bundled `bin/` fallback. (For a
  Python analyzer: `import codeanalyzer_<lang>` and run in-process — no `bin_path()`.) So the wheel
  **must expose `bin_path()`** and the published name/version must be pin-able.
- **TypeScript SDK** — cannot consume a PyPI wheel, so it resolves the binary from
  `analysisBackendPath` → `$CODEANALYZER_<LANG>_BIN` → the **GitHub Release asset** (downloaded
  on first use or vendored at the pinned tag). This is exactly why the release workflow publishes
  raw binaries alongside the wheels.
