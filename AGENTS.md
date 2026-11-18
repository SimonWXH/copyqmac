# AGENTS.md

The rules below are settled decisions for this repository, not suggestions.

## Build, run, and test

- There is no Xcode project and no `xcodebuild`; `make build`, `make run`, `make test`, and `make clean` are the entry points, with details in `docs/build.md`.
- Tests are a plain Swift executable with a hand-written harness under `tests/`, not XCTest; `make test` must pass and new behaviour needs a suite.
- A few layout tests lay out real AppKit views and need a window server.
- Launch the bundle with `make run`, never the inner binary, which inherits the terminal's permissions.
- Before building, running, signing, or re-granting Accessibility, read `.agents/skills/copyqmac-build-and-run/SKILL.md` first.

## Architecture invariants

- `core/` does not import AppKit or touch `NSPasteboard`; pasteboard access goes only through `app/PasteboardBridge.swift`, keeping most tests GUI-free.
- Payload flavour bytes are preserved; compression is only a storage encoding, and previews and paste-back restore the original bytes.

## Personal data and sync safety

- Clipboard history and sync folders are personal data.
- Without explicit instruction, never delete, rename, or rewrite existing sync files, and never touch manual `.cpq` archives.
- Route user-visible deletions of synced items through the recoverable in-app trash, never outright.
- Never write into upstream CopyQ application-support, configuration, or archive paths, and keep protected-path guards case-insensitive.
- Ignored or confidential content never reaches the database, sync folder, or log.
- Logs carry payload summaries only: formats, byte length, and a short hash, never clipboard text.

## Sync model

- A tab with a non-empty sync folder is always bidirectional, with no per-tab write-back or watch switches and `Pause Sync` as the only off switch.
- There is no configurable extension-to-media-type table; a fixed built-in table decides item data and ignores the rest without UI.
- Do not overwrite existing sync files; a new capture advances a colliding timestamp stem in 1 ms steps, while explicit edit and resync flows rewrite only the entry's own files.
- Echo suppression is durable and data-derived from recorded written stems and their owning entry, not a blind path or modification-time rule.

## Interface and verification

- Never take over the live desktop, and never synthesize mouse or keyboard input outside the app's own paste path.
- Prove interface behaviour headlessly first with unit tests, offscreen rendering, accessibility dumps, or pasteboard-only checks, and hand genuinely manual steps to the user.

## Delivery

- One PR does one thing, with no bundling of independent features, fixes, or refactors.
- Every PR reports the required `build-and-test` check, and the hosted `macos-26` runner builds and tests through the Makefile.
- A doc-only change still reports the check but skips the build through a classifier step, which is why the workflow has no `paths-ignore`.
- CI has no `push` trigger on `main`, merges are squash, so a `main` commit not built from a PR head needs a manual `workflow_dispatch`.
- All work targets `SimonWXH/copyqmac` only; never open a PR, issue, comment, or patch against upstream `hluk/CopyQ`.
- Commit subjects follow existing history as a conventional-commit subject with the PR number, for example `feat(app): ... (#9)`, and never include an agent name.

## Where the details live

- `docs/build.md`: build, bundle launch, Accessibility, test suites, CI, and release details.
- `docs/architecture.md`: layering, data model, capture and paste-back, sync, permissions, and UI composition.
- `docs/features.md`: user-facing features and boundary conditions.
- `docs/README.md`: phased cross-device sync plan.
- `README.md` and `README_CN.md`: public overviews and install instructions.
- `.github/workflows/ci.yml`, `.github/workflows/release.yml`, and `.github/release-notes.md`: delivery and release configuration and user-facing notes.
