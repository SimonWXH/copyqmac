---
name: copyqmac-build-and-run
description: Build, run, sign, and re-authorize CopyQmac, with the commands and Accessibility re-grant procedure. Load when building, running, or signing the app, launching it for manual checking, or when automatic paste-back fails because the Accessibility grant no longer covers the current binary.
---

# CopyQmac build, run, sign, and Accessibility

`docs/build.md` is authoritative for procedure and rationale. `Makefile` is authoritative for commands, `app/Info.plist` for bundle identity, and `.github/release-notes.md` for user-facing first-launch wording. This skill is a checklist, not a second source of truth. Release, dmg, and CI procedures are out of scope here.

## Build

- There is no Xcode project and no `xcodebuild`; use the Xcode Command Line Tools `swiftc` and the macOS 26 SDK.
- `make build` compiles `core/*.swift`, `core/CopyQSync/Sources/CopyQSync/*.swift`, and `app/*.swift` in Swift 5 language mode, links system zlib with `-lz`, stages the binary at `build/CopyQmac-bin`, assembles and ad-hoc signs `build/CopyQmac.app`.
- Staging the binary outside the bundle keeps the `.dSYM` and other side products out of the sealed signed app.
- `TARGET`, `SDK`, `SWIFTC`, `CODESIGN`, and `ARCH` are overridable; defaults derive from `uname -m` and `xcrun --show-sdk-path`.
- `app/Info.plist` must stay in step with the Makefile's `APP_NAME`: bundle id `local.copyqmac.app`, executable `CopyQmac`, package type `APPL`, and `LSUIElement` true.
- `make test` runs the headless suites; a few layout suites need a window server. Details of the suites stay in `docs/build.md`.

## Run

- `make run` builds and opens the bundle; `open build/CopyQmac.app` opens an existing build without rebuilding.
- To install, run `make build`, `rm -rf /Applications/CopyQmac.app`, then `ditto build/CopyQmac.app /Applications/CopyQmac.app`; removing the old bundle first prevents `ditto` from merging stale files.
- Launch at login registers `SMAppService.mainApp`, which also needs the bundle.
- `open build/CopyQmac.app --env COPYQMAC_DATA_DIR=/tmp/copyqmac-test` isolates real clipboard history and the sync trash for an experimental launch.

## Why the bundle matters

- Launching `build/CopyQmac.app/Contents/MacOS/CopyQmac` directly makes it a child of the shell, so it inherits the terminal's permissions.
- A trusted terminal then masks the missing grant, macOS never registers CopyQmac as its own TCC client, and no `CopyQmac` row appears under Privacy & Security ▸ Accessibility.
- Opening the bundle is what makes the app its own client and allows a grant that covers automatic paste-back.

## Signing

- Sign ad hoc only with `codesign --force --sign -`, the invocation `make build` already uses.
- No Apple Developer account and no notarization; first-launch Gatekeeper steps for downloaded builds belong in `.github/release-notes.md`.
- A stable self-signed signing identity was proposed and rejected, so do not reintroduce it; every rebuild is a new code identity and needs a fresh grant.

## The Accessibility grant

- The first paste attempt without permission shows macOS's own accessibility dialog, which also registers `CopyQmac` in System Settings ▸ Privacy & Security ▸ Accessibility.
- While permission is missing, an orange status-bar item and a brief banner explain the problem; the status-bar item requests the dialog and opens the pane.
- Trust is re-read when the app activates and at each paste, so the notice clears without restarting once the grant works.
- A paste that actually posts its synthetic Command-V counts as trust for the rest of the launch and retires further prompts, even when macOS still reports the build as untrusted.
- Without the grant, paste-back still puts the payload on the clipboard and shows a notice explaining that a manual paste is needed.

## Re-grant after a rebuild

- Because the grant follows the ad-hoc signature, macOS leaves the old entry switched on while refusing the new binary; toggling that entry off and on does not transfer the grant.
- Open System Settings ▸ Privacy & Security ▸ Accessibility, select **CopyQmac**, and remove it with the minus button.
- Add the app back with the plus button, choosing `/Applications/CopyQmac.app`, or use the app's orange status-bar item to register the current binary and open the pane.
- Return to the app; the banner clears on activation or the next paste and the status-bar item goes with it.
- The same remove-and-add procedure applies when upgrading from an earlier build, as `.github/release-notes.md` tells downloaders.

## Verifying the grant

- Launch from the bundle and confirm the process with `pgrep -fl CopyQmac.app`; a terminal that already has Accessibility hides a broken grant.
- Check paste-back in an ordinary app that does not handle its own paste keys, so an actual synthetic Command-V is exercised.
- For automated UI inspection without taking over the desktop, use `osascript` with System Events to read the accessibility tree and trigger menu items.

## Bounds

- Do not synthesize mouse or keyboard input into the live desktop outside the app's own paste path.
- Do not change signing to skip the re-grant, and leave the release-note wording about ad-hoc builds untouched.
