# Building, testing, and running

## Requirements

- macOS 26 or later.
- The Xcode Command Line Tools (`xcode-select --install`). A full Xcode
  installation is not required: the Command Line Tools ship the Swift compiler
  and the macOS 26 SDK, which is enough to compile, assemble, code-sign, and run
  a SwiftUI application locally.

Verified on this machine:

```
swift 6.3.3 (swiftlang-6.3.3.1.3), target arm64-apple-macosx26.0
macOS SDK 26.5 at /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
codesign, iconutil, sqlite3 (3.51.0, FTS5 with the trigram tokenizer)
Liquid Glass APIs (.glassEffect, .buttonStyle(.glass))
typecheck against this SDK
```

## No Apple Developer account needed

Local personal use needs no Apple Developer Program membership and no Team ID.
An app bundle can be signed ad hoc:

```sh
codesign --force --sign - CopyQmac.app
```

An Apple ID is only needed to download Xcode from the App Store. A paid
Developer Program membership is only needed for notarization, which is what
would spare downloaders the first-launch authorization. The project has no
membership, so published releases stay ad-hoc signed and unnotarized - see
[First-launch authorization](#first-launch-authorization-ad-hoc-signed-builds).

## Commands

```sh
make build   # compiles app/ and core/ into CopyQmac.app
make run     # launches the built app
make test    # runs the headless test suite
make dmg     # packages build/CopyQmac.app into a compressed disk image
make clean   # removes build/ and .build/
```

`make build` compiles `core/*.swift`, `core/CopyQSync/Sources/CopyQSync/*.swift`,
and `app/*.swift` with `swiftc` against the macOS 26 SDK, copies the binary into
a bundle with a hand-written `Info.plist` (`LSUIElement` is true so the app lives
in the menu bar without a Dock icon while no window is open), installs the app
icon from `resources/` into
`Contents/Resources` where `CFBundleIconFile` points at it, and ad-hoc signs the
bundle last. The app and test binaries link the system zlib (`-lz`) for flavour
compression; macOS ships it, so nothing extra needs installing. The binary is
staged outside the bundle first so the `.dSYM` is not sealed inside the signed app.
`make run` opens the finished bundle through LaunchServices.

### Launching the app (and why it matters)

Launch the bundle, not the binary inside it:

```sh
make run                     # runs `open build/CopyQmac.app`
open build/CopyQmac.app      # equivalent, without rebuilding
```

Launch at login is registered from Preferences through
`SMAppService.mainApp`, so it also needs the app to run from its bundle. macOS
may ask the user to allow the entry under System Settings ▸ General ▸ Login
Items; a registration failure is reported in the window's notice banner and does
not stop the app from working.

`build/CopyQmac.app/Contents/MacOS/CopyQmac` starts too, but it runs as a child
of the shell rather than as its own application. The process then inherits the
terminal's permissions: if the terminal has Accessibility, so does the app for
that session, macOS never asks, and no `CopyQmac` entry is created in System
Settings. Opening the bundle is what makes the app its own TCC client, which is
the only way it can be listed in System Settings ▸ Privacy & Security ▸
Accessibility and be granted automatic paste-back.

The bundle identity in `app/Info.plist` is what LaunchServices and TCC record:
`CFBundleIdentifier` is `local.copyqmac.app`, `CFBundleExecutable` is `CopyQmac`
(matching the binary the Makefile installs), `CFBundlePackageType` is `APPL`, and
`CFBundleName`/`CFBundleDisplayName` are `CopyQmac`. Keep those in step with
`APP_NAME` in the Makefile if either is ever renamed.

### Granting Accessibility

Automatic paste-back needs Accessibility permission. Everything needed is in
the app:

1. The first time you paste an entry while the permission is missing, macOS
   shows its own "CopyQmac would like to control this computer using
   accessibility features" dialog. Say yes there, or open System Settings.
2. Either way `CopyQmac` now appears in System Settings ▸ Privacy & Security ▸
   Accessibility; switch it on. While the permission is missing, the window's
   status bar carries an orange "Accessibility permission not granted" item;
   clicking it shows the dialog again and opens that pane.
3. Paste again. Until the toggle is on, the entry is still put on the clipboard
   and the window's banner explains that a manual ⌘V works instead. The banner
   fades out after a few seconds; the status-bar item stays as the persistent
   reminder.

Once granted, the app re-reads the trust state when it becomes active
and at each paste, so the orange banner and the status-bar item disappear
without restarting the app. A paste that actually posts
its synthetic Command-V also counts as trust for the rest of the launch: the
notice is retired and no further system dialog is requested, even if macOS keeps
reporting the build as untrusted.

The grant is recorded against the ad-hoc code signature, so it belongs to the
exact binary that was in the pane when it was granted. Every `make build` (or app
update) produces a new binary, and macOS keeps showing the old entry switched on
while refusing the new one. Toggling that old entry off and on does **not**
transfer the grant to the new binary. Re-establish it by removing and re-adding
the app:

1. Open System Settings ▸ Privacy & Security ▸ Accessibility.
2. Select **CopyQmac** and remove it with the **−** button.
3. Add the app back with **+** and choose `/Applications/CopyQmac.app` (or click
   the app's **Accessibility permission not granted** status-bar item, which
   registers the current binary and opens the pane).
4. Return to the app; the orange banner clears once the window is active or on
   the next paste, and the status-bar item goes with it.

The orange banner explains the remove-and-add path, distinguishes the case where
the switch already looks on, and has a button to the pane. It fades out after a
few seconds; while the permission is still missing, the status-bar item takes
over as the persistent explanation.

An earlier commit on this branch tried a self-signed local signing identity to
keep the grant across rebuilds; it was removed by the user's decision, so the
build signs ad hoc and the grant is re-established after each update.

A terminal that already has Accessibility is the other way this can look broken:
such an app inherits the trust, so macOS never prompts - see
[Launching the app](#launching-the-app-and-why-it-matters).

`build/` is ignored by git.

### Variables

The Makefile accepts `TARGET`, `SDK`, `SWIFTC`, `CODESIGN`, and `ARCH`
overrides. Defaults derive from `uname -m` and `xcrun --show-sdk-path`.

## Release flow and packaging

### Versioning

The single source of truth for the application version is the `VERSION` file at
the repository root. During `make build`, the version string from `VERSION` is
stamped into the application bundle's `Info.plist` as both
`CFBundleShortVersionString` and `CFBundleVersion`. The application version is
not repeated anywhere else in the tree.

The application's About panel (`orderFrontStandardAboutPanel`) displays this
version string read directly from the bundle, matching the release downloaded by
the user.

### Disk image (.dmg) packaging

`make dmg` packages `build/CopyQmac.app` into a compressed disk image:

```sh
make dmg
```

This creates a staging directory containing `CopyQmac.app` and a symlink to
`/Applications`, then invokes `hdiutil create` with the `UDZO` format to produce
`build/CopyQMac-<version>.dmg`.

### Release workflow (GitHub Actions)

Releases are published automatically by `.github/workflows/release.yml`
whenever a tag matching `v*` is pushed:

1. The runner checks out the repository.
2. Fails the job unless the tag minus its leading `v` equals `VERSION`, so bump
   `VERSION` before tagging.
3. Runs `make test` and `make build`.
4. Packages the disk image with `make dmg`.
5. Creates a GitHub Release for the tag using `gh release create`, attaches
   `CopyQMac-<version>.dmg`, marks the release as a **pre-release** (beta), and
   uses the notes in `.github/release-notes.md`, which explain the ad-hoc
   signature and first-launch steps.

### First-launch authorization (ad-hoc signed builds)

Because the project does not use a paid Apple Developer account, releases are
ad-hoc signed and unnotarized, so macOS blocks the first launch of a downloaded
build; the exact authorization steps live in `.github/release-notes.md`, which is
the body of every release.

## Tests

The tests are a plain executable rather than XCTest, because XCTest and
swift-testing both ship with Xcode and this machine has only the Command Line
Tools. `tests/` contains a small assertion harness and the suites:

- flavour decoding (text encodings, HTML/RTF text extraction, JavaScript-style
  `\uXXXX` escapes and their surrogate pairs, images, file URLs)
- capture model (fingerprints, item structure, relative time, SHA-256 vectors)
- dedupe and history bounds (consecutive duplicates, global limit, pinning)
- store round-trip (every flavour, reopen, migration, at-rest compression,
  damaged-row isolation, mutations)
- search (trigram, short-query fallback, CJK, wildcards, FTS syntax safety)
- tabs, notes, global limits, preferences, and schema migrations
- item text editing and new items: editor seed and preview fallback, flavour
  rewriting and preservation, validation, in-place save identity and
  locally-edited marking, menu and sheet gating, and the hidden-filter notice
- styled editing of HTML and RTF items: the representability rules, including a
  paragraph whose base writing direction is not left or natural and an RTF font
  family the writer cannot record (non-ASCII) keeping the plain editor while
  the same family stays editable in HTML, the writer round trip that keeps an
  untouched save a byte-for-byte no-op, the five toolbar commands and their key
  equivalents, the caret style when an item opens, colour handling across copy
  and paste, the paste guard (a picture beside text, a file reference), and a
  payload that names an uninstalled font staying editable because fonts are
  otherwise not validated
- entry context and status menus: row context menu (New Item, Edit Item, Activate,
  Copy, Pin/Unpin, Remove with key equivalents), empty-area table menu, and
  status menu items sharing the same action routing and validation rules
- multi-selection and bulk actions: the selection maths behind Command-click,
  Shift-click and Shift-arrow ranges, Command-A, and Escape; focus and anchor
  handling; a selection surviving refreshes and clearing on a tab change;
  reorder up/down/top/bottom within each pin group, the order it persists, and
  a capture landing above a block moved into another tab; bulk delete asking
  once and routing every entry's owned group to the trash; history trims
  (capture, preference save, and a move into a fuller tab) deleting exactly the
  rows they trashed; and tab moves through `CopyQSyncRelocation` - the plan and
  its confirmation, rewriting into a destination folder, and trashing when the
  destination has no folder
- CopyQ sync and format bridge: itemsync folder and .cpq archive import and backup
  export, exact tab syncFolder matching, content deduplication, batch sync folder
  import, protected path safety checks, and pasteboard MIME flavour enrichment
- sync folder field and the unmapped import prompt: the debounced commit
  decision behind the per-tab Sync folder field (the last typed value wins, a
  surrounding-whitespace change writes nothing, a pending draft stays with the
  tab it was typed for, and a focused field keeps the text being typed),
  trimming and empty-means-no-folder, the same paste, pause, blur, and Return
  paths through the shipped row hosted in an unshown window, the import report's
  mapped-tab count, the banner and the delivered alert and picker copy naming
  the tab, a pick that completes after the selection moved still giving the
  folder to the named tab, the refusal when a mapping appeared or the tab is
  gone, and one row per item when adopting a folder that already holds items
- CopyQ sync write-back: live capture write-back to mapped sync folders,
  millisecond collision bumping, the single pause switch, content-edit group
  rewriting without orphans, protected path guards, and rotating sandboxed sync
  log
- CopyQ sync folder watcher: FSEvents watching, group completeness and stability,
  durable echo-loop prevention that still sees upstream edits, data-derived stem
  ownership and content dedupe, newest-wins content updates, discarded-side
  logging, burst handling, and pause/resume gating
- CopyQ sync edit propagation: a local edit rewrites exactly one group under its
  own stem and removes stale files, a newer upstream edit updates the row in
  place, an older local or upstream edit loses with a log line, a migrated
  switches-off tab is bidirectional, and unknown files stay ignored
- CopyQ sync deletion and recovery: owned-group moves into the app trash with
  original names and metadata, non-owning entries left alone, settled upstream
  removal and rewritten-group protection, paused-sync gating, trash summary and
  emptying, one-shot reconciliation reporting and apply, read-only per-tab
  comparison with exact matched/content-difference/missing/folder-extra/
  unresolved/unreadable counts, idempotent second reports, folder read-only proof,
  refusal of a trash path inside a sync folder, tab removal leaving sync files
  untouched, and Clear Tab confirmation
- CopyQ sync resync apply: the identity model (base-name flavour, durable
  `written_sync_stems`, legacy creation-time fallback, multi-group rows, the
  legacy-only flag, and the update stem falling back to a differing stem that
  has a folder item), plan and apply of imports/removals/updates, the app-trash
  archive of removed and replaced payloads, a failed removal archive keeping its
  own row while the others proceed, reconcile keeping its shipped removal
  behaviour, a pending local edit blocking its own removal while the clean rows
  in the same run proceed, an undecodable owned group refused as conflicting,
  unsettled and in-flight groups skipped until they settle, an already-applied
  update reported as already in sync, notes and pins surviving an update, the
  four refused-conflict cases, a missing or unreadable folder failing before any
  row, trash, or file write even for a plan built while the folder existed, the
  writer barrier that settles queued captures and refuses to recreate a removed
  row's group, in-memory stem cache invalidation after each write, paused-sync
  refusal, and the two-step dialog whose default button only reports, which gets
  its report and plan from one comparison on a background task, and whose
  confirmed apply refreshes the visible list
- row presentation, thumbnail, and rich-text caches: hits, misses, byte-budget
  LRU bounds, invalidation on change and delete, thumbnail downsampling, rich
  HTML/RTF rendering and appearance adaptation, the full-text line count the
  inspector reads from a cached presentation (counted with the background
  full-text read and carried through the cache), and a guard that the render path
  never computes a fingerprint
- display and interaction rules that have to hold outside the GUI: file entries
  showing the file name (and being reindexed by name on upgrade), the
  Accessibility prompt policy (asked on the first untrusted attempt, never while
  trusted, and re-armed after a trusted check), an injected trust check
  governing the paste notice, selection changes committing and blurring the note
  editor, search reloads and history eviction keeping note editing attached to a
  visible entry, keys the list keeps while the note editor is focused, and which
  row the list has to reveal
- Paste as Plain Text: rich entries reduced to text, multi-item ordering,
  compressed-flavour decoding, the ⇧⌘V key equivalent reaching the action
  through the real menu builder, an image-only entry keeping the item enabled
  and reporting a notice instead of beeping, the global shortcut choosing the
  selected entry while the window is open, stripping the live clipboard when it
  is not, reporting an image-only clipboard (and bringing the window forward so
  the notice is visible), conflict reporting for identical or taken shortcuts,
  and a paste that leaves the stored entry and its rich flavours unchanged.
- Accessibility trust: the prompt policy and the "a paste already worked" latch
  (a successful paste retires the notice for the session, a stale grant switches
  the notice to the remove-and-add text, and a trusted or already-successful
  session is never prompted).
- transient notices, the click-through banner, and the status-bar items: the
  banner's few-second lifetime on an injected timer (no test waits on the clock),
  replacement instead of stacked timers, a repeated identical message restarting
  its timer, the close control dismissing at once, the AppKit hit test that sends
  a click on the banner's plate to the list underneath while its own buttons keep
  their clicks, failure notices leaving a status-bar record plus an app-log entry
  that outlives the banner, and the Accessibility item's visibility given granted
  and missing trust including its hand-over from the permission banner.
- launch at login: the `SMAppService` status mapping and the toggle behaviour
  (including a failed registration, pending approval, the approval notice being
  retracted once the item is usable, a failure notice and its reason surviving
  refreshes until the requested state is reached, dismissal clearing both, and
  unrelated notices surviving refreshes and toggles) against a mock service, so
  no login item is touched while testing; the launch-source decision that keeps
  a login launch in the menu bar is checked against a synthetic Apple event
- the application menu and the activation policy: the built main menu contains
  the application, File, Edit, Item, Tabs, and Help menus with About opening the
  standard about panel, Quit, and the AppKit help menu, no two items in the
  main, row, or status menus resolve to the same key equivalent (that guard is
  itself checked against AppKit's own key-equivalent
  dispatch), and the policy is regular exactly while an app window is visible and
  accessory again once the last one closes (so the menu bar is drawn and the Dock
  icon is temporary)
- click activation policy: immediate activation on single click when enabled,
  duplicate suppression across rapid clicks and double clicks in the same
  sequence, and reset
- item activation plan and path: the ordered activation plan (copy, paste,
  focus, close, move to top), coherence rules (paste implies focus, failed
  delivery keeps window open), tolerant preferences decoding, and the app's
  activation path (copy-only activation, moving to top, and fallback when
  delivery fails)
- AI-service API-key guard: the detection table and body scan (each service
  shape blocked and named, ordinary prose, short identifiers, and non-AI bearer
  credentials such as a GitHub token or a JWT untouched, UTF-16 flavours read,
  and the specific openings winning over the generic `sk-` row), the capture
  path proving a key is skipped before SQLite and the sync folder while an
  ordinary capture is stored, and the status-item notice's state machine on an
  injected timer: widen and name the skip, replacement and timer restart on a
  second blocked capture, the resting appearance restored on expiry, and a
  language change re-rendering the notice without restarting it
- localization: the English and Simplified Chinese catalog (every key filled in
  both languages, the same key set in both, and no Chinese value left as the
  English text apart from the app name), the language preference round trip and
  its English default, an unrecognized stored language keeping the other
  preferences, the main and status menus built in either language, the status
  bar and settings strings resolving for the selected language, a status-bar
  failure record switching with it, the permission banner and its controls
  rendering in it, the runtime mapping of failure and launch-at-login records,
  the relative-time wording for every interval in both languages, the row
  timestamps following a live language switch, a stored Chinese preference
  localizing the rows on launch, a row materialized after a switch using the new
  wording, and localized dialog, file-panel, and Help copy including shortcut
  labels that keep modifier glyphs and translate key names; it also checks the
  main window's filter bar, empty states, row help, content-kind badge, and
  text-edit copy, the translated row context menu, and the report summaries and
  notice messages that carry counts, byte sizes, file names, and system errors
- appearance: the theme preference's system default, tolerant decoding (a
  stored blob without the key and an unrecognized value both keeping system),
  JSON and store round-trips, the System/Light/Dark mapping to the standard or
  Increase Contrast `NSAppearance`, and `AppearanceManager` applying a theme to
  `NSApp` and a window and clearing it again for System
- window layout: the inspector split ratio clamp, the pointer-to-ratio mapping
  keeping a divider drag one-for-one with the pointer from the ratio the divider
  is drawn at (the preview growing by exactly the distance the note shrinks, the
  two still summing to the column height, and each pane keeping its minimum),
  the default reset, the layout preference and split ratio round-tripping through
  the store with an unknown layout value falling back, and the shipped divider
  view reporting drags from a window-coordinate anchor so it follows the pointer
  while it moves itself and persisting the ratio once on release, a double-click
  asking for the default ratio without starting a drag, and the shipped Layout B
  window hosted with a stored `windowLayout = .layoutB`: the metadata block above
  a split column whose preview pane, 7pt divider, and note pane fill the column,
  and whose double-click stores and redraws the default ratio; the same view
  hosted short enough for the 60pt pane minimum, where the drawn ratio has to
  differ from the stored one; and the Layout B sidebar taking keyboard focus
  from a real click on a tab row, with the window's key monitor turning
  Page/Home/End into tab selection and leaving Up/Down to the list, while Return
  never pastes and Escape still reaches the window; the sidebar's tab badges read
  the stored per-tab totals counted in one grouped query and refreshed with the
  list, so they stay correct while the visible list is capped
- window layout switching: the default preference, a stored blob with no layout
  information, and a legacy blob carrying the pre-control layout field all resolving
  to Layout B while that legacy field is left unchanged on re-encode; a layout
  chosen under the new key surviving an encode/decode round trip and the store, the
  settings Window layout control writing the chosen layout through its binding when
  its segments are clicked, the control's copy in both languages, a hosted main
  window swapping its rendered arrangement when the preference flips, and the active
  tab, selection, and unfiltered list state surviving a switch at the model level

Most of the suite runs without a window server or a GUI session. The row-height
and styled-editor tests lay out real AppKit views, and the editor focus, font
picker, sync folder field, divider drag, shipped-layout window render, settings
picker, and appearance tests create a window,
so those need a window server. See [Architecture](architecture.md#layers) for
the core/app boundary that keeps the rest of the suite independent of the app:

```sh
make test
# Prints a summary of the test and assertion results.
```

## Keeping tests away from real data

The app stores its history under `~/Library/Application Support/CopyQmac`, never
in CopyQ's own directories. To run an experimental build against a private
directory:

```sh
open build/CopyQmac.app --env COPYQMAC_DATA_DIR=/tmp/copyqmac-test
```

`COPYQMAC_DATA_DIR` is honoured by `ClipboardStore.defaultURL()` and by
`CopyQSyncWriter` for `sync.log`. The app-side sync trash lives at
`<data directory>/trash`, so the same override keeps experiments away from the
real recovered files. `open --env` keeps the normal bundle launch, so the app
still registers itself for Accessibility while writing to the private directory.

## One-time maintenance: internal marker entries

Stores written by builds that imported payload-less sync items can contain
entries whose only flavour is the internal `application/x-copyq-itemsync-base-name`
marker, or that hold no payload flavours. Import and export refuse those items
now, so no new ones appear. To remove the ones already stored, run the cleanup
explicitly from the menu (Item ▸ "Remove Internal-Marker Entries…") or the CLI:

```sh
COPYQMAC_DATA_DIR=/path/to/store-directory \
  build/CopyQmac.app/Contents/MacOS/CopyQmac --cleanup-internal-marker-entries
```

The menu item confirms the counts before removing, while the CLI runs headless
and prints how many entries it deleted per tab (and the total), reporting
single-marker shells and other payload-less entries separately. Both paths delete only
entries that have no payload flavours, and leave every other entry, note, and pin untouched.
Re-running it is a no-op. An ordinary launch never passes the flag, so every deletion
stays user-triggered.

## What the Command Line Tools cannot do

- No Xcode SwiftUI Previews.
- No Interface Builder / `actool`, so asset catalogues are not part of the
  build. The app icon ships as a prebuilt `.icns` in `resources/` instead,
  drawn by `tools/generate-app-icon.swift`: `swift tools/generate-app-icon.swift`
  rewrites `resources/AppIcon.icns` through `iconutil`, so `iconutil` is only
  needed for that regeneration.
- No `xcodebuild`, so anything that expects an `.xcodeproj` will not work here;
  the Makefile is the build system of record.

## Verifying a build actually runs

```sh
make build
open build/CopyQmac.app --env COPYQMAC_DATA_DIR=/tmp/copyqmac-test
pgrep -fl CopyQmac.app        # the process should be alive
```

The menu-bar item should appear in the system menu bar. A manual launch opens
the main window, and the full menu bar is CopyQmac / File / Edit / Item / Tabs /
Help. A launch macOS starts as a login item stays in the menu bar instead (see
[Architecture](architecture.md#launch-at-login)). While a window is open the app
is regular, so the Dock shows its icon; closing the last window removes that icon
and returns the system menu bar to the previous app (see
[Architecture](architecture.md#the-menu-bar-and-the-activation-policy)).
Status-item click handling must allow AppKit's mouse-tracking loop to return
before activating the window; see [Architecture](architecture.md#ui-composition)
for the interaction invariant and right-click menu path.
Automated screenshots require granting Screen Recording permission to the
terminal once; without it, `screencapture` fails with "could not create image
from display".

Automated UI verification without a screenshot uses the Accessibility API;
`osascript` with System Events can read the window tree, click tab chips, trigger
menu items, and type into the filter and note field.

Automatic paste-back needs Accessibility permission for `CopyQmac.app`; the app
asks for it on the first paste attempt and is listed in System Settings ▸ Privacy
& Security ▸ Accessibility from then on. Without the grant it still copies the
entry to the clipboard and shows a notice. Running the binary from a terminal
that already has Accessibility makes it inherit that trust for the session,
which hides the prompt - see [Launching the app](#launching-the-app-and-why-it-matters).

## Continuous integration

`.github/workflows/ci.yml` is the pull-request gate. It runs on `pull_request`
and can be started by hand with `workflow_dispatch`; it deliberately does not
run on `push`. Every merge here is a squash merge, so the commit that lands on
`main` carries exactly the tree of the `pull_request` head that was built and
tested, provided the base branch did not move between that run and the merge. A
second run for it would spend another full macOS job re-validating identical
code. The tradeoff is that `main` is not validated automatically: after a direct
push to `main`, or a merge whose tree differs from the tested pull-request head,
including one whose base moved, start the workflow manually with
`workflow_dispatch`. The workflow contains no compiler or test command of its
own, so the Makefile stays the single place to change them. The build target
compiles the app and the CopyQSync format module; the test target runs both the
app's headless suite and the CopyQSync test runner.

A pull request that only touches documentation - markdown anywhere, or the
root `NOTICE` or `LICENSE` text - skips the build and tests. Anything outside
that set runs the full build and tests, including a rename that moves a file
across the documentation boundary. The `build-and-test` check still appears and
reports success from a classifier step that finishes in seconds instead of
minutes. The classifier is a normal step rather than a workflow-level
`paths-ignore`, so the required check never goes missing.

The job runs on the GitHub-hosted `macos-26` image (arm64, 3 vCPU). The
repository has no self-hosted runners, so only GitHub-hosted labels apply;
`macos-26` is the image that ships macOS 26 and Xcode 26, and therefore the
macOS 26 SDK and a Swift 6 toolchain. `macos-15` and `macos-14` predate that
SDK, and `macos-26-intel` would double the metered minutes for the same
coverage, so CI uses one arm64 job with no matrix. Superseded runs on the same
pull request are cancelled; runs on `main` are never cancelled, because a
manual run there is explicit and must be allowed to finish.

The workflow does not cache Swift build products. A cache keyed on the sources
cannot hit for ordinary pull requests (every non-documentation pull request
changes sources, and every run recorded before this decision used a distinct
commit), and a partial restore cannot skip work because each `swiftc`
invocation compiles whole modules from all sources. The cache would add restore
and save time to every run and save none.

`xcode-select` on the image points at Xcode 26.6 rather than the Command Line
Tools used locally. The workflow prints `swift --version` and
`xcrun --show-sdk-path` so that selection is visible in every run that builds.
The build itself still uses only `swiftc` and the SDK: no `xcodebuild`, no Xcode
project.
