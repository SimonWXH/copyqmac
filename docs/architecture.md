# Architecture

This document describes how CopyQmac is put together and why the main decisions
were made. It covers the data model, the capture-to-paste-back path, the
permission requirements, and the reasoning behind the storage and hotkey
choices.

## Layers

```
core/   AppKit-free logic: clipboard model, SQLite store, zlib compression,
        tabs, preferences, search, relative time, the localization catalog,
        styled text and its HTML/RTF encoding, CopyQSync format module, sync
        bridge, sync writer, sync watcher, deletion/trash, relocation, and
        reconciliation. Compiled into both the app and the test binary.
app/    AppKit/SwiftUI shell: window (with AppKit frame autosave), views, view
        model, design tokens, theme policy, pasteboard bridge, hotkey, paste
        service, menus.
tests/  Test suite: `core/`, plus the app files it drives. Most of it is
        headless; `docs/build.md` lists which suites need a window server.
```

The split keeps most of `make test` runnable without a window server or a
logged-in GUI session. Nothing under `core/` imports AppKit or touches
`NSPasteboard`; the pasteboard is read and written only through
`app/PasteboardBridge.swift`, and image dimensions are read with ImageIO, which
works headlessly. A few suites lay out real AppKit views or open a window, so
they need a window server; `docs/build.md` lists them.

## Data model

### Flavours

A clipboard change is stored as a list of `Flavour` values:

```swift
struct Flavour {
    var itemIndex: Int  // which pasteboard item it belongs to
    var type: String    // UTI, e.g. "public.utf8-plain-text"
    var data: Data      // original bytes, decompressed on demand if compressed
}
```

`itemIndex` preserves multi-item pasteboards (for example two file URLs or
multiple text items copied together; text items across snapshot items are
aggregated with newlines into preview and search). Keeping every flavour's exact
bytes, keyed by its type identifier, is what makes a paste-back faithful: no
conversion to text happens on the way in, and the store always returns the bytes
it was given. Large payloads may be compressed on disk; that encoding is reversed
lazily when a flavour's bytes are actually needed (see Storage below).

Several flavours usually describe the same content: a copy from a browser may
carry `public.utf8-plain-text`, `public.html`, and `public.rtf` together, and an
image copy often carries `public.png` and `public.tiff`. `FlavourDecoder.preview`
picks a preferred flavour for display (file URLs > image > plain text > RTF/HTML
> URL > unknown), while all flavours remain stored. Among image flavours it
prefers PNG, then BMP, JPEG, and GIF before any other image type, matching
CopyQ.

File URLs come first because a file copied in Finder also puts the file's icon
on the pasteboard as `com.apple.icns` and `public.tiff`. Those icon flavours are
images, so an image-first decoder showed such an entry as "Image 1024x1024
(icns)" instead of the file name CopyQ shows. File entries display and index the
file name (plus the full path, so folder and partial-path searches work), and
the icon flavours stay stored so paste-back still writes the whole payload back.

The text derived for display and search is decoded, never the stored payload:
HTML entities and JavaScript-style `\uXXXX` escapes (including surrogate pairs)
become the characters they stand for. Some apps write a rich copy's plain-text
companion through a JavaScript escaper, so a text flavour is decoded the same way
when the same item also carries HTML or RTF; a plain-text-only capture keeps its
literal escapes, which is what a copied code snippet needs.

### Entries, tabs, and notes

```swift
struct ClipboardEntry {
    var id: Int64
    var createdAt: Date
    var pinned: Bool
    var tabID: Int64
    var note: String
    var flavours: [Flavour]
}

struct ClipboardTab {
    var id: Int64
    var name: String
    var position: Int
    var isDefault: Bool             // captures land here
    var syncFolder: String?         // CopyQ-compatible sync directory
}
```

`Fingerprint.of` produces a SHA-256 over a canonical serialisation of the
flavours (sorted by item index and type, every field length-prefixed). It is
used to collapse consecutive duplicates. The digest is computed in one linear
pass over the payload: a file copy from Finder carries the file's icon as a
multi-megabyte image flavour, and hashing that payload quadratically froze the
app for minutes.

## Storage

SQLite through the system library (`import SQLite3`), which the SDK ships with
FTS5 and the `trigram` tokenizer enabled. This avoids a Swift package dependency
and any need for Xcode.

Schema (version 9, tracked with `PRAGMA user_version`):

```sql
tabs(id, name, position, is_default, sync_folder)
settings(key, value)  -- preferences as one JSON blob
entries(id, created_at, position, pinned, tab_id, note, locally_edited,
        last_imported_fingerprint, sync_updated_at, fingerprint)
flavours(entry_id, item_index, type, data, compressed)  -- PRIMARY KEY(entry_id, item_index, type)
written_sync_stems(stem, folder, written_at, entry_id, tab_id)  -- PRIMARY KEY(stem, folder), durable echo-loop suppression
search_fts USING fts5(text, tokenize='trigram')  -- rowid = entry id
```

Version 8 drops the retired per-tab `sync_write_back` and `sync_watch` columns.
A tab with a sync folder is always bidirectional; a tab without one never syncs.
The global `syncPaused` preference is the only off switch. `sync_updated_at`
records the timestamp of the sync version an entry currently reflects (the last
local write, or the resolved date of the last upstream version applied), and
`written_sync_stems.entry_id` links a locally written stem to its row while
`written_sync_stems.tab_id` records the tab that maps the folder when the stem
was written; a stem recorded for a live entry in a folder no tab maps, or whose
entry no longer resolves, stays unowned. The migration stamps a pending local
edit from the previous build with the migration time, because that build never
wrote the edit to the folder, so the edit stays newer than the row's creation
time and wins its first comparison. Version 9 adds the nullable `tab_id` owner.
Orphan reclaim on open, at migration, and when a folder becomes mapped releases
a legacy row whose entry is gone, and, while the folder is readable, a legacy
null-owner row that neither content-verified recovery nor the
base-name/timestamp proximity matcher can link, so those folder files can be
imported once. A row with a `tab_id` is never released by reclaim: deleting its
entry while sync is active removes it, deleting its tab removes it, unmapping
its folder from the last tab that maps it removes its rows, and a paused
deletion keeps it as a suppression watermark. The version bump is required
because version-8 stores lack the `tab_id` column and cannot record or interpret
stem ownership; the version guard makes those builds refuse to open a version-9
store instead of silently misreading it.

Design points:

- **One row per flavour.** Deleting an entry is a small cascade over
  `flavours`, `search_fts`, and `written_sync_stems`, so nothing is ever left
  dangling. While sync is paused, the stem row for a group this app wrote is
  kept with a null `entry_id` as a suppression watermark, so the file group is
  not re-imported when sync resumes; the row is removed when its tab is deleted
  or when its folder loses its last mapping.
- **Explicit sort position.** `position` starts equal to `created_at` and the
  list orders by `pinned DESC, position DESC, created_at DESC`. Move Up / Down /
  Top / Bottom rewrite only `position`, so reordering never changes the creation
  time a row displays or the timestamp the sync writer matches a stem against.
  A move stays inside its own pin group, so an unpinned row never rises above a
  pinned one.
- **Large flavours are compressed at rest.** A payload above 1 KiB is stored as
  zlib in Qt's `qCompress` framing with `compressed = 1`; smaller payloads stay
  raw with `compressed = 0`. Payloads above the read cap (256 MB) stay raw with
  `compressed = 2`, so anything the write path accepts stays readable and the
  migration does not retry it on every open. Reads keep the compressed bytes in
  place and only validate the `qCompress` framing; decompression happens lazily
  in `Flavour.data` when a preview, fingerprint, or paste-back actually needs
  the bytes, and a damaged flavour is isolated instead of discarding the whole
  entry list. Compression is a storage encoding, never a payload conversion:
  previews and paste-back operate on the original bytes.
- **Rowid equals entry id** in `search_fts`, so search is a single indexed
  lookup rather than an external-content join.
- **Trigram tokenizer** is what makes substring and CJK queries work. It needs
  at least three characters, so shorter queries fall back to a `LIKE` scan over
  the same table. Both paths are covered by tests.
- **Notes are indexed too**, so searching finds an entry by its note.
- **Migrations are linear and forward-only.** A version-1 database (the initial
  vertical slice, with no tabs or notes) is upgraded in place: the tab and
  settings tables are created, `tab_id` and `note` are added, and existing
  entries are assigned to a newly seeded default tab. Version 2 databases drop
  the removed per-tab limit column. Both paths continue through the version-3
  reindex, and version-3 databases run it directly: every file entry's search
  row is rebuilt because the older decoder indexed the Finder icon image rather
  than the file name. Every path then runs the compression step: add the
  `compressed` column and compress existing large flavours in batches. The step
  is idempotent and resumes on the next open if it was interrupted. Version-5
  databases then run the version-6 repair: imported entries that carry the sync
  base-name flavour and whose backing group still exists in a configured sync
  folder get `created_at` re-resolved to the later of the file-name stamp and
  the newest backing-file modification time. A row is also moved to the unique
  tab that owns its backing folder when that differs from its current tab.
  Resolution prefers the row's own tab folder, then falls back to the sole
  configured folder containing the group. Rows whose group or owner is missing
  or ambiguous, or whose owning tab already holds the same sync identity or
  payload, are left where they are and logged in aggregate. Folder enumeration
  and row resolution run before the write transaction. The same step rebuilds
  `written_sync_stems` with a `(stem, folder)` primary key. It is transactional
  and only rewrites rows whose date or tab actually changes, so an interrupted
  run rolls back and a re-run completes without rewriting correct rows.
  Corrected and relocated rows are queued for the watcher's import notification
  so the open list reloads with their new dates and tabs. The retired
  `imported_sync_stems` table is neither created nor read any more; a database
  that still contains it opens directly without a migration. Version-6
  databases then run the version-7 reindex: every entry whose text or HTML
  payload carries a complete `\uXXXX` escape has its search row rebuilt from
  the decoded text, because older builds indexed the gibberish form. Only the
  search row changes; the flavours the migration reads are left byte-identical
  for paste-back. A database from a newer build is refused rather than silently
  misread.
- **Preferences are one JSON blob** under a single settings key. Adding a field
  later does not need a migration, and decoding is tolerant: unknown or missing
  fields fall back to defaults, so a blob written by a newer build does not brick
  an older one.

The default database location and private test-folder override are documented
in `docs/build.md`.

### History bounds

The global `Preferences.defaultMaxItems` (default 1000, editable) applies to
every tab. Saving preferences immediately trims stored entries in every tab.
`ClipboardStore.trim(tabID:to:)` deletes exactly the rows below the top `limit`
in display order; pinned entries are never evicted. A trim is a delete like any
other, so it runs `onEntriesWillBeDeleted` and an evicted entry's owned sync
group goes to the app trash instead of being left behind in its folder. A
preference save applies the limit together with the preferences being saved, so
shrinking the limit still propagates the removals.

### Duplicate collapsing

`ClipboardHistory.record` compares each capture against the newest entry of the
target tab. If the fingerprints match, the existing entry's timestamp is
refreshed (so it returns to the top) and no second row is written. The
comparison is per tab and uses the whole content flavour set, not just the
visible text, so two visually identical entries with different rich flavours stay
distinct. The sync base-name bookkeeping flavour (`application/x-copyq-itemsync-base-name`)
records where an imported entry came from rather than what it holds. It is part
of the stored identity fingerprint, so two sync file names stay two entries, while
the payload fingerprint used for content dedupe ignores it.

Stem ownership is derived from that data, not from a separate ledger. In a tab,
the owner of a stem is the entry carrying the stem's base-name flavour, or the
row `written_sync_stems.entry_id` names for a stem this app wrote. A legacy row
imported before that flavour existed is matched by comparing the stem timestamp
with the stored creation time; the lookup never adds the flavour, but every path
that acts on the row records the resolved match in `written_sync_stems` before
it can move the row's creation time, so the link survives re-scans, duplicate
captures, and move-to-top. Reporting paths resolve the same match without
recording it. A written stem recorded for a live row is owned by the tab that
maps the folder and reclaim never releases it; it is removed with its entry or
tab, or when its folder loses its last mapping. A legacy row (no `tab_id`) is
released once at open or when its folder becomes mapped: a row whose `entry_id`
is gone is released regardless of folder state, while a null-owner row that
neither content-verified recovery nor the base-name/timestamp proximity matcher
can link is released only while the folder exists and is readable, so an
unmounted or unreadable folder keeps those rows suppressed. Resolution-time
recovery can link a legacy null-owner stem whose group exists, is complete, and
matches exactly one row in the tab, and records the link; an owned group is
never released or re-linked by that sweep. Content-equal adoption can give one
row several stems in the same folder; delete, tab move, rewrite, reconciliation,
and the Clear Tab count act on that whole owned set, and a rewrite converges it
to one stem (its base-name flavour, else the oldest) by moving the extra groups
to the app trash.
Sync import looks up the owner first. An unchanged external file refreshes the owner's date and is a duplicate; a group this app wrote for the owner never moves the date, so a manual import cannot reorder a locally edited item. A
same-stem file whose content differs is a content change and the newest
timestamp wins: when the upstream group's resolved date is later than the entry's
`sync_updated_at`, the row's flavours are replaced in place (same id and tab, and
creation time unless the upstream date is later) together with the item's note and
pinned state, and the applied
version is recorded. When the local version is later, the upstream version is
discarded, the winning local version is written back to the folder, and the sync
log records a payload summary of the discarded upstream payload (formats, byte
length, and the first 8 hash characters). Either way one stem keeps exactly
one owner and no second entry is created. Without an owner, a content-fingerprint
match is a duplicate that only refreshes its date and records the incoming stem
for the matched row, so two machines that captured the same content under
different stems converge instead of each editing only its own group; otherwise a
new entry is inserted.

Canonical fingerprints fold native pasteboard aliases (`public.plain-text`,
`NSStringPboardType`, ...) onto the CopyQ MIME name the folder carries, so an
alias-rich local capture and the item read back from its own group compare
equal. The item's note (`application/x-copyq-item-notes`) and pinned marker
(`application/x-copyq-item-pinned`) are part of that identity because they
travel in the same file group. The stored `last_imported_fingerprint` is
canonical for the same reason.

Fingerprint values are not backfilled when the hash rule changes. Rows written
by older builds may therefore fail to collapse with a content-identical new
stem, and the archive lookup has the same historical limitation; no migration
is added for this.

### Internal bookkeeping flavours

A flavour whose type is `application/x-copyq-itemsync-*` or
`application/x-copyq-private-*` is ours, not clipboard content. The
`application/x-copyq-itemsync-base-name` marker is the sync identity: it
records which file stem an imported entry owns, and nothing else. Those
flavours are therefore excluded everywhere content leaves the store: an
exported `.cpq` archive carries none of them, a sync-folder write never turns
one into an item file, and paste-back filters them out. The local store keeps
them, because dropping the base-name marker would free its stem for a second
import.

Import is the other direction of the same rule. A sync item or archive item
whose flavours are all bookkeeping markers carries no content: it is skipped
before it can claim a stem or create an entry, and the scan logs one line with
the count rather than one line per item. Export skips entries that hold
nothing but bookkeeping flavours, so a payload-less entry never becomes an
empty item on the other device. A store written by an older build can still
hold such entries; `CopyQmac --cleanup-internal-marker-entries` or
Item ▸ "Remove Internal-Marker Entries…" deletes the shell entries that carry
no payload flavours (zero flavours or only internal markers) and no note or pin,
reports single-marker and other payload-less counts per tab and in the total,
and is never run automatically.

## Capture path

```
NSPasteboard.general
   │  poll changeCount (GCD timer, 0.35 s)
   ▼
ClipboardWatcher.poll
   │  skip if the changeCount is our own paste-back write
   │  judge the apps that were frontmost since the last check; skip if any
   │  is on the ignore list, if the window is empty or stale, or if the
   │  pasteboard carries a privacy marker (before any payload is read)
   │  read every item and every type via PasteboardBridge.snapshot
   │  skip if a capture made here carries an AI-service API key
   │  (APIKeyDetection, before anything reaches the store)
   ▼
ClipboardHistory.record
   │  collapse consecutive duplicates; trim to the global limit
   ▼
ClipboardStore.insert → SQLite
   │
   ├─ AppModel.reload → row models → native list
   │
   └─ AppModel.handleCapturedEntry → CopyQSyncWriter.enqueue (utility queue)
        │
        └─ writeEntry → new files with 1 ms stem bumping into tab.syncFolder
```

`NSPasteboard` has no change notification, so the watcher polls `changeCount`,
which is a single integer comparison. Two details make this reliable:

- The timer is a GCD timer on its own queue (less run-loop coalescing than a
  `Timer`), and `AppDelegate` holds a `ProcessInfo` activity token
  (`.userInitiatedAllowingIdleSystemSleep`) for the app's lifetime. Without the
  token, App Nap throttles the poll timer while the window is closed and
  clipboard changes are captured late or missed.
- Writes made by the app itself are recorded in `ClipboardWatcher.ignore(changeCount:)`
  and skipped, so paste-back never feeds the history.

### Capture exclusions

`Preferences.captureExclusions` is the single list of apps whose content is
skipped when the app was frontmost since the last clipboard check, keyed by
bundle identifier and carrying a readable name. `sanitized()` trims each rule,
drops an empty identifier, and keeps the first rule for a bundle identifier.
`defaultValue` starts with the built-in password-manager list in
`CaptureExclusionCatalog`, so protection exists before any configuration; an
older preferences blob without the field decodes to the same list. Because the
stored list is the source of truth, a removed or disabled built-in stays that
way.

`ClipboardWatcher` maintains a small timestamped `CaptureWindow` of the apps
that have been frontmost since the last check, fed by
`NSWorkspace.didActivateApplicationNotification` and the live frontmost app
sampled at each check, including a second sample when the change is judged.
CopyQmac itself is recorded in the window as a known, non-ignored source, so its
own window never makes a change unattributable. A detected change is judged on
the next main-queue turn, which gives activation notifications already queued
behind the poll a chance to reach the window first; the workspace delivers
activations on the main operation queue, so that ordering is best-effort, not
guaranteed. `CaptureExclusionPolicy.decide(window:)` is the single decision: an
empty window, or one whose newest observation is stale after a gap, skips and
increments the unattributable-skip counter, so the payload is never read on that
fail-safe path; otherwise any excluded app in the window skips the change, and a
fresh excluded-free window captures it. The watcher keeps a separate
last-observed frontmost app for the Preferences "Add Last App" hint; that field
never takes part in the capture decision and never holds CopyQmac itself, so the
hint still shows the last other app. `PasteboardPrivacy` is checked before
`PasteboardBridge.snapshot` reads anything. An excluded app in the window or a
pasteboard type such as `org.nspasteboard.ConcealedType` therefore creates no
row and writes no sync file, and the skip log names only the rule or the
unattributable window, never the content. Preferences ▸ Ignored Apps lists the
rules with enable and remove controls and adds the last observed frontmost app.

`Preferences.apiKeyGuardEnabled` is the content-level sibling of those app rules
and is on by default; an older preferences blob without the field decodes to on.
After `PasteboardBridge.snapshot` and before `ClipboardHistory.record`, the
watcher asks `APIKeyDetection.match(in:)`, a single table of prefixes, body
lengths, and body character sets covering the OpenAI, Anthropic, Google, and
OpenRouter shapes, with the specific openings ordered before the generic `sk-`
one so the skip log names the right rule. A generic `Bearer` credential is not
a shape of its own: a bearer header is skipped only when the credential inside
it has one of those service shapes. A match skips the capture, so the payload
never reaches SQLite or a sync folder, and the log names only the rule, never
the secret; a small status-item notice type shows a short note in the menu bar
for a few seconds and restores the resting appearance, following a language
change without restarting its timer. The guard covers captures made on this
machine: items already arriving through a sync folder are not filtered, and
because sync is bidirectional, dropping them could delete the other machine's
copy. Detection is deliberately narrow - no scoring, no entropy heuristic, no
general secrets scanner - so it greatly reduces what can leak but promises
nothing, which is exactly what the Preferences hint tells the reader. Entries
already in the history are left alone, and the paste path is untouched, so a
blocked capture can still be pasted straight away.

## Sync write-back (Stage 2a)

`CopyQSyncWriter` manages asynchronous writing of newly captured items, typed new items, and local content edits into mapped CopyQ itemsync directories:

- **Asynchronous queue**: Capture and new-item writes are scheduled onto a dedicated serial utility queue (`local.copyqmac.sync-writer`), keeping the capture path and UI latency-free. A local edit writes synchronously on the editing path so its outcome can be reported at once.
- **Gating**: A write needs only a non-empty `syncFolder` on the entry's tab and `Preferences.syncPaused == false`. There is no per-tab write-back or watch switch and no master write-back switch.
- **Capture writes**: A capture or typed New Item creates a new file group under a fresh stem by staging each file as `<stem><ext>.tmp` and renaming the group into place (an existing destination is never overwritten), records the stem in `written_sync_stems` with the entry id and the tab that maps the folder, and records the canonical payload it wrote as the entry's `last_imported_fingerprint`.
- **Content edits rewrite the entry's own group**: `CopyQSyncWriter.updateEntry` resolves the stem the entry already owns (the exact `written_sync_stems` row first, then its base-name flavour, then a recorded or folder group whose stamp matches its creation time) and regenerates every file of that group under the same stem. Files from the previous content that the new version no longer produces are removed, so a dropped HTML or note flavour leaves no orphan. Keeping the stem is what makes the other machine update the item in place rather than seeing a deletion plus a new item. The entry keeps its creation time and the folder gets the edit's timestamp, which is what the newest-wins rule compares. The writer lists the folder once and only touches files whose parsed stem is exactly the entry's, so an edit does not stat or rebuild every other group.
- **Honest failure**: A missing or unreadable folder, or a protected path, never fails the local edit. The writer logs the failure, returns it, and the app reports it while keeping the new text.
- **Collision bumping**: If a new capture's target files exist or match candidate stems, `CopyQSyncWriter.resolveUniqueStem` advances the timestamp stem by 1 ms iteratively until an unused stem is found. An edit reuses its own stem instead of bumping.
- **Path protection**: `CopyQSyncWriterSafety.isForbiddenPath` guards against writing to upstream CopyQ application support, configuration, or archive paths.
- **Rotating log**: Sync operations and errors are logged to `sync.log` in `ClipboardStore.defaultDirectoryURL()` (honouring `COPYQMAC_DATA_DIR`), rotated up to 2 files of 1 MB each. Conflict outcomes use the same log: `local-edit-replaced` and `upstream-edit-discarded` log a payload summary of the side that lost (formats, byte length, and the first 8 hash characters). Those conflict lines never contain clipboard bytes or note text.

## Sync folder watcher (Stage 2b)

`CopyQSyncWatcher` monitors configured sync folders and automatically imports items written by other machines (such as Fedora via Syncthing):

- **FSEvents monitoring**: Watches configured tab sync folders using macOS `FSEventStream` on a dedicated background utility queue (`local.copyqmac.sync-watcher`), avoiding any polling loops.
- **Burst coalescing and debouncing**: File events are coalesced over a 300 ms debounce window, so rapid bursts of file modifications (e.g. dozens of files arriving via Syncthing) are ingested in a single pass without stalling the UI or capture paths.
- **Startup catch-up scan**: On application launch or reconfiguration, an initial scan of all watched folders catches any items written while the application was closed. A reconfiguration that adopts a new folder can skip it (`updateConfiguration(store:scan:)`) and scan that folder itself; the scan still runs on the watcher queue either way.
- **Group completeness and stability**: Files sharing a common stem are grouped and validated before import. An item group must contain a primary payload (container `_copyq.dat`, text `.txt/.html/.uri/.xml`, or media `.png/.jpg/etc.`), must have no active temporary files (`.syncthing...tmp`), and must be settled (unmodified for at least `settleDelay`). Syncthing conflict copies, whose names contain `.sync-conflict-`, are skipped rather than treated as new stems, so a concurrent edit on another device cannot import a ghost item.
- **Echo-loop prevention that still sees upstream edits**: Every stem written by `CopyQSyncWriter` is recorded in memory and in the durable SQLite table `written_sync_stems`, whose primary key is `(stem, folder)` and whose `entry_id` names the row the stem belongs to. A written group is skipped only while its canonical payload still matches the local row: that is our own echo. A written group whose payload changed is a remote edit of the same item and goes through the newest-wins rule instead of being ignored. A stem recorded for a live row is owned by the tab that maps the folder at write time, and orphan reclaim never releases an owned row: the group stays suppressed until its entry is deleted with sync active, its tab is deleted, or its folder loses its last mapping; a remap that leaves another tab mapping the folder keeps it suppressed. Legacy rows written before `tab_id` existed have no tab owner: one whose `entry_id` is gone is released regardless of folder state, while a null-owner one that neither content-verified recovery nor the base-name/timestamp proximity matcher can link is released once at open or when the folder becomes mapped, and only while the folder is readable, so its files can still be imported. Resolution-time recovery links an unowned legacy stem whose complete group payload matches exactly one row in the tab, so a row whose creation time moved before the upgrade regains its group; an owned stem stays suppressed.
- **Authoritative folder routing**: The watcher sends every scanned group to the single tab whose configured sync folder matches the scanned path; a caller-supplied tab id is only a hint and cannot divert an item. A watched folder with no owning tab, or one claimed by more than one tab, is skipped and logged with the conflicting tab names and ids instead of falling back to the capture tab or resolving by position. The manual import paths (`importSyncFolder`, `importConfiguredSyncFolders`, `findOrCreateTab`) apply the same multi-claimant rule: an ambiguously claimed folder is logged and skipped. When no tab claims a manually imported folder, `findOrCreateTab` may still create a new tab with an empty sync folder.
- **Date resolution**: An imported item's date is the later of the CopyQ stamp in its file name and the modification time of its newest backing file. Syncthing preserves mtimes, so genuinely old items keep their real date, while items whose name carries a stale base stamp (with only the counter advanced) show the date the file actually arrived. The same resolved value is what the list displays. An item that supplies neither candidate (an archive item) is stored with the import time, but a repeat import does not treat the new wall clock as newer, so its stored date is preserved.
- **Content changes update in place**: Uses canonical SHA-256 flavour hashing against the database, ensuring repeat scans or app restarts are idempotent no-ops. Ownership is data: a stem's owner is the entry carrying its `application/x-copyq-itemsync-base-name` flavour, the row `written_sync_stems.entry_id` names for a locally written stem in the same tab, or a legacy row whose original creation time matches the stem timestamp. An unchanged file refreshes its owner's date and is a duplicate. A same-stem file with different content is resolved by timestamp: a newer upstream group replaces the row's flavours in place and records the applied version; an older one is discarded, logged with a payload summary of the discarded payload, and the winning local version is written back to the folder. The local edit flag is no longer a permanent veto, so an edit made on this machine can be superseded by a later edit from the other one. When no owner exists, a content-fingerprint match is a duplicate that only refreshes its date and adopts the incoming stem for the matched row, so independently captured duplicates stay one item across both machines (a later edit then propagates to both groups); otherwise a new entry is inserted. The bookkeeping flavour is excluded from the content fingerprint, so content-identical stems still collapse into one entry (except for fingerprints stored by older builds, which are not backfilled). Deleting, clearing, or trimming an entry removes its ownership data with it; while sync is paused the watermark row for a group this app wrote stays with a null `entry_id`, so the item is not re-imported when sync resumes, and removing the tab removes the row. A user deletion first moves every owned group to the app trash, so the files are gone and the other machine deletes the item; a rewrite of a row that owns several groups keeps one stem and trashes the rest. A folder claimed by more than one tab is skipped and logged rather than imported into either. The manual import path applies the same rules.
- **Flavour names translated on import**: CopyQ on Linux names flavours with MIME types, while a macOS capture uses pasteboard types, so import maps `text/plain`, `text/html`, `text/rtf` and `image/png` to `public.utf8-plain-text`, `public.html`, `public.rtf` and `public.png` while keeping the payload bytes untouched. Kind detection, preview, and paste-back therefore treat a synced Fedora rich-text item exactly like a local capture. `CopyQSyncBridge.flavourNameMappings` is the single table both directions read, so exporting and re-importing restores the original names; formats that are not in the table keep their own name. Deduplication fingerprints are computed over the translated flavours, so an imported rich item and its local equivalent share one payload identity.
- **Settled upstream deletion**: A stem is tracked once a scan sees its group. The first scan that finds a tracked group absent only records a pending deletion. A later scan after `settleDelay`, with no temporary file for that stem, removes the local owner if it has no edit that failed to reach the folder. A rewritten group reappears before that rescan and clears the pending state. A paused watcher records but never removes.
- **Internal bookkeeping items are skipped**: An item carrying only our own bookkeeping markers and metadata (no payload, note, or pin) is not content. The scan skips it without creating an entry or claiming a stem, and logs one aggregate line with the count instead of one line per item, so a folder full of empty items cannot flood the history or the log.
- **Configuration**: Every tab with a non-empty sync folder is watched. There is no per-tab watch switch; `Preferences.syncPaused` stops both watching and writing and is the only off switch. Unknown or non-item files in a folder are ignored by the fixed built-in extension table (`CopyQFormat.defaultExtensions`), with no user-facing ignore list. Scans are serialized on the watcher queue, so a manual scan cannot race a background FSEvents scan into inserting the same item twice.
- **Picking a folder when no tab is mapped**: `CopyQSyncBridge.importConfiguredSyncFolders` counts the tabs it had a folder to read in `CopyQImportReport.mappedTabCount`, so a zero count means "no tab has a sync folder" rather than "nothing needed importing". The app turns that into a prompt that names the tab the pick will belong to, captured when the prompt is accepted (`AppActions.presentSyncFolderImportPicker`), so a selection change while the picker is open cannot redirect the folder. `AppModel.adoptPickedSyncFolder(_:intoTabID:)` refuses with a notice when that tab is gone, or when another tab gained a folder meanwhile, and otherwise stores the folder on that tab. It reconfigures with `scan: false` and calls the watcher's `scanFolder`, which serializes on the watcher queue, so one scan is the only importer and its report is what the notice shows. The pick never creates a second tab.

## Sync deletion, trash, and reconciliation (Stage 2c)

`CopyQSyncDeletion` is the single path that removes a sync identity from the local history. `ClipboardStore.onEntriesWillBeDeleted` calls it before user-visible delete transactions (single delete, bulk delete, confirmed Clear Tab, internal-marker bulk cleanup, history-limit trims), so owned files and rows stay consistent even when a move fails: a failed move throws before the rows are removed, and a partially staged batch is moved back. Tab removal unregisters the tab, releases the written-stem ownership that tab recorded, and leaves sync folder files untouched.

- **Ownership**: An entry owns its stem via its `application/x-copyq-itemsync-base-name` flavour, its `written_sync_stems.entry_id` row, or a legacy creation-time match. A stem is moved only from the owning tab's exact sync folder and only while sync is not paused; a tab with a folder needs no separate enable switch. Clear Tab is confirmed with a dialog before propagating deletion.
- **App trash**: `CopyQSyncTrash` writes each batch under `ClipboardStore.defaultDirectoryURL()/trash/<timestamp>-<stem>/`, keeping the original file names and a `metadata.json` with stem, folder, tab id and name, reason, time, and files. Upstream deletions have no files left to move, so their local payload is written with `CopyQSyncFolder.write` under the original stem. A trash path inside any configured sync folder is refused, because the deletion would not propagate. The trash is local-only and File ▸ "Empty Sync Trash…" is the only hard deletion.
- **Upstream removal**: The watcher keeps in-memory per-folder stem tracking. On first absence it schedules a retry after the settle window; only the later scan may remove, and only with no temporary file for the stem and an owner without a local edit that never reached the folder. Removal archives the payload and deletes the row without re-entering the app-delete handler.
- **One-shot reconciliation**: `CopyQSyncReconciliation.report` counts entries carrying a stem with no matching group and groups with no owner, without mutating the store. `apply` archives and removes the missing-file entries, then imports orphan groups through the canonical folder importer. File ▸ "Reconcile Sync Folders…" shows the counts with Report Only as the default button; nothing runs at launch.
- **Per-tab comparison and resync apply**: `CopyQSyncResync.report` scans one tab's folder once and returns exact read-only counts: entries whose stem and decoded content match, content-different rows, entries whose stem has no file, importable stems with no entry, entries with no usable folder content (including internal-only stems) or unresolved historical identity, entries whose stem could not be decoded, and distinct files that failed or were skipped while reading. Internal-only and empty stems are surfaced separately; a stem whose files failed to decode is counted as unreadable, not internal. A row is compared through its whole owned set (base-name flavour plus every recorded stem), so content-equal adopted groups are matched rather than reported as folder-only. A flavourless row resolves through the shipped ownership rule: a recorded `written_sync_stems` stem within one second, or a legacy creation-time match to the stem stamp; a folder stem is reported as unowned only when no row owns it through the same resolver reconciliation uses, and any stem with a file that failed to read or decode is counted unreadable rather than matched or content-different. Payload equality alone is not ownership. The folder is read once into a stem/content index rather than rescanned per entry. Nothing is written, moved, deleted, imported, adopted, or merged, so the folder bytes, store rows, notes, pins, and locally edited content are unchanged. The tab context menu “Compare with Sync Folder…” opens the report with OK as the default button; a second report is identical when nothing changes. The dialog builds its report and plan from one comparison on a background task, so the folder scan never blocks the main thread.
- **Sync identity model**: `CopyQSyncIdentityResolver` is the single answer to “which group belongs to this row?”, and deletion, the comparison, and the resync apply all ask it. Identity is layered, strongest first: the row's `application/x-copyq-itemsync-base-name` flavour; every stem `written_sync_stems` records for its id in this folder; then the legacy rule: a written stem whose stamp is within one second of the creation time, matched to the row when a row already owns it or adopted when it has no owner at all, or a folder group whose stamp matches the row exactly and resolves back to it through `existingOwner`. A row can own several stems (legacy duplicate groups), so the owned set is compared whole and `canonicalStem` names the preferred stem a write uses: the base-name flavour when the row owns it, otherwise the oldest recorded stem. When that stem has no folder item the write falls back to a differing owned stem that does, so a planned update always has its item. `isLegacyIdentity` marks a row whose ownership rests only on layer three, whether matched back to the row or adopted from an unowned released stem: that layer is a guess about history, so the plan reports such a row as `.unrelatedHistory` and the write path never treats a same-stem different-content file as a newer version of it. A row with no resolved stem is never written; it stays in the unresolved bucket.
- **Resync apply**: `CopyQSyncResync.plan` turns the same comparison into the three writable categories the report counts and names every row it refuses to resolve, and `apply` executes exactly that plan. Imports go through the canonical `importSyncItem` rule, so a folder stem whose payload already exists links to that row instead of adding a duplicate. Removals run first through `CopyQSyncDeletion.deleteEntriesMissingFiles`, which archives each payload to the app trash before dropping the row. A row whose own payload cannot be archived is kept and reported while the other planned removals still proceed, so resync never deletes a row without its recovery copy; File ▸ "Reconcile Sync Folders…" keeps its shipped behaviour, where the failure is reported but the row is still removed. Running removals first stops an import from deduplicating onto a row that is about to be removed. Updates apply the folder's content flavours, keep the row's id, creation time, note, and pin, record the synced version, persist the durable stem link, and archive the replaced payload to the trash. A row with a pending local edit is a conflict instead of an update or a removal, as is a content-different row whose folder item has a different note or pin, or whose owned groups do not all carry the same payload, including a group the folder could not fully decode; a row whose identity is legacy-only is a conflict instead of an update or a removal. The apply only uses groups that have settled by the watcher's own rule: a stem with an in-flight temporary file, or a group that is incomplete or was modified within the watcher's settle delay, is skipped with a reported reason instead of being imported, updated, or removed, so a resync never writes from a group that may still be mid-transfer. An update whose work is already done is reported as already in sync instead of counted as updated. The whole apply runs inside `CopyQSyncWriter.withSettledWrites`, which drains queued capture writes and then holds the writer lock: a write enqueued before the apply has finished, and a write enqueued during it waits until afterwards, finds no stored row for a removed entry, and writes nothing. An apply that has work to do re-reads the folder inside that barrier, so a folder that is missing, unreadable, or no longer the tab's configured one fails before any row, trash, or file write, and a plan confirmed before the folder disappeared cannot delete the rows whose files are gone. Every planned action is re-validated against that settled state and skipped with a reported reason when it no longer applies, so a stale confirmation cannot perform an unconfirmed write. After each action the in-memory echo cache is re-derived from the durable `written_sync_stems` record instead of being reused. The plan's own per-category counts are the confirmation text: the report dialog's first button is OK, the second offers the explicit write, and that confirmation defaults to Cancel. The dialog asks `reportAndPlan` for one comparison on a background task, so its counts and the plan it offers describe the same scan and the main thread stays responsive, and the apply's failures are shown next to its summary instead of being dropped. Apply is refused while sync is paused, and a tab without a sync folder stays local. The apply never rewrites the folder: imports read files that already exist, updates take the folder's content, and removals archive the local payload, so resync creates, changes, moves, and deletes no folder file.

## Tab and note operations

- Tab mutations go through `ClipboardStore+Tabs.swift`. `setDefaultTab` clears
  every flag and sets one, so exactly one capture tab exists. Deleting a tab
  removes its entries and promotes a survivor, leaving sync folder files
  untouched; the last tab cannot be deleted.
- The per-tab Sync folder field commits on every change after a 400 ms pause, and
  also on Return, on losing focus, when the view disappears, and when the row's
  tab changes.
  `SyncFolderDraft` owns that decision so it is testable without a window: a
  pending draft remembers the tab it was typed for, so a pause cannot store the
  text on another tab; text that trims to the stored folder needs no write; and
  a focused field keeps the typed text instead of the folder a commit
  republished, so a folder assigned from elsewhere while the field is focused
  still appears in it.
- Notes are saved with a 500 ms debounce. `AppModel.setNoteDraft` updates the row
  in place so typing stays responsive, then persists; pending drafts are flushed
  before termination and when editing ends or selection changes, while background
  refreshes preserve an active note draft. `NoteEditingSession` keeps the editor
  bound to its entry when that entry remains visible, or commits, ends editing,
  and selects a survivor with a notice when it leaves the results. Failed note
  writes remain buffered for retry and are overlaid when their entry is visible
  again. The store refreshes the entry's FTS row so notes are searchable.
- The note editor never holds the list hostage. Every selection change - a
  click, a Command-click, a Shift range, Command-A, or Escape - funnels into
  `AppModel.applySelection(ids:focus:anchor:)`, which asks
  `SelectionChangePolicy` for a plan and applies it in order: commit the
  pending draft, make the editor resign focus, then install the new selection.
  A selection change is pure view state: the visible entries are already in
  memory, the row models are precomputed, and the native list only moves its
  selected row index - the store is not read, no row is rebuilt, and no
  thumbnail is decoded. Clicking a row has to feel exactly as immediate as
  pressing an arrow key. The window's key monitor keeps handing
  Up/Down/Page/Home/End to the list while the editor has the keyboard. Return
  and Backspace still belong to the editor.

## Editing item text

- `EntryTextEditing` is the single rule set behind Item ▸ Edit Item… and Item ▸
  New Item…. The plain editor opens with the entry's stored plain text. When
  the stored plain text is empty it falls back, with a hint in the sheet, to the
  full preview text rather than the truncated preview excerpt, so an RTF-,
  HTML-, or URL-only entry that stayed on the plain editor is edited in full.
  An entry whose preview shows no editable text (an image, a file list, or an
  unknown non-text payload) opens with an empty editor instead of the type-name
  summary the preview shows.
- An entry whose HTML or RTF payload belongs to a single item, and whose
  formatting is only text runs the editor can keep, opens the styled editor
  instead of the plain one. It shows the entry's own styling and a toolbar with
  exactly the five attributes the item editor changes: bold, italic,
  underline, colour, and size.
  Bold, italic, and underline answer to ⌘B, ⌘I, and ⌘U in the text view
  (`StyledTextView`); colour and size are toolbar controls, and the toolbar
  reflects the attributes at the selection or, for a collapsed caret, the
  typing attributes the next keystroke will use. The editing value is
  `StyledTextDocument` in `core/StyledText.swift` - text, those five
  attributes, a link per run, and a font family - and `RichTextEncoding` writes
  it in the entry's own format: HTML for an HTML item, RTF for an RTF item. A
  payload's links are carried through the edit unchanged; the toolbar has no
  link control. `RichTextEditing` is the only place that crosses between the
  payload and AppKit's attributed string. An explicit payload colour is drawn
  through `RichTextAppearance.adjusted`, the same appearance adaptation the
  list row and preview use, while the payload keeps its own colour and a save
  writes that colour back. Copying inside the editor writes the payload colour,
  and a paste restores it, so a display adjustment can never become a stored
  colour. Saving cannot change the entry's format: the other rich family is
  dropped as stale, the plain-text companions carry the edited text, and a
  plain-text item never gains HTML or RTF. The writers are canonical (newlines
  normalised, empty runs dropped, equal neighbours merged) and both aim at the
  same document reader the row and preview use. The HTML writer ends the body
  with the one terminator newline the reader passes through, so seeding removes
  exactly that injected newline and a genuine trailing newline survives; a
  document read from a payload this app wrote encodes to the same bytes again,
  and re-saving an untouched item is a no-op rather than a rewrite that marks
  the entry locally edited. HTML writes sizes in CSS pixels (one pixel is one
  AppKit point in the system reader), colours as `#rrggbb`, and links as
  anchors; RTF writes half-points, `\uN?` escapes, both the device-RGB and sRGB
  colour tables, and links as hyperlink fields, which is what keeps a chosen
  colour exactly the colour that comes back.
- A payload with anything else the styled editor would rewrite does not open it.
  The panel says plainly that saving will drop the formatting, and the plain
  editor is used. This covers an inline image or attachment, a list, paragraph
  alignment other than left or natural, a paragraph base writing direction
  other than left or natural, paragraph spacing, indentation, a background
  colour, a strikethrough, a superscript, and any other attribute or structure
  the five attributes plus a link do not model. Fonts are not validated,
  matching CopyQ: the editor loads the payload whatever family it names, and a
  declared family this system does not have renders in the reader's own
  substitution at the payload's size; a declared family that is installed keeps
  its own family and size. The one exception is a family the item's own writer
  cannot record: the RTF font table this app writes cannot carry a non-ASCII
  family name, so such an item keeps the plain editor instead of having its
  family silently renamed on save, while HTML keeps any name. The editor font
  in Preferences ▸ History ▸ Fonts is the base font new text is typed in once
  it is chosen, and the list font is a base font for rows whose text carries no
  font of its own; see [Fonts](#fonts).
  A paste that carries only an image, or rich content whose attributes are not
  representable, is refused instead of appearing and then disappearing on save,
  while a pasteboard that also carries a representable text representation
  contributes its text; a save whose editor content stopped being representable
  is refused with a message. Known limitation: such items can only be edited as
  plain text, which drops their formatting, and that is stated in the panel
  rather than done silently. A multi-item entry also stays in the plain editor,
  which shows every item's text joined and collapses it on save, because the
  styled editor shows only one item and a save would drop the others.
- New Item… (⌘N) and Edit Item… (`fn`-`F2`) are accessible from the Item menu, the
  status-bar right-click menu (`StatusMenuBuilder`), and table context menus
  (`EntryListView`). Context menus display their key equivalents; right-clicking
  an empty area or pressing the affordance button in an empty tab opens New Item….
  `EntryContextActions` routes these through the same `canCreateNewItem` and
  `editItemAvailability` model checks as the menu bar, preventing drift.
- Image and file entries render their payload rather than editable text, so
  Item ▸ Edit Item… is disabled for them and the menu item reads "Edit Item…
  (Use Edit Note)"; the model refuses the request as well and reports the note
  hint. The explanation is in the menu title because AppKit does not show
  tooltips for disabled items. Editing text the row and preview never show
  would be invisible to the user.
- While the editor sheet is open, Item and Tabs commands that could delete the
  target, clear or remove its tab, or start another item request are disabled,
  and `AppModel` ignores tab switches and the mutating request methods. The
  draft cannot be invalidated or silently retargeted underneath the user.
- A styled save is the same transaction with the entry's own rich format as the
  content: the flavours of that family the entry already carried are rewritten
  in place (so `public.html` and `NSHTMLPboardType` both stay), the other rich
  family is dropped, the plain-text companions are rewritten with the edited
  text, and the same image, file-URL, and base-name payloads survive. The entry
  is marked locally edited and written back to its sync folder only when the
  flavour set actually changes. The styled rewrite refuses an entry with more
  than one item instead of collapsing it onto the lowest item, because the
  styled editor is only offered for a single item.
- Saving replaces the plain-text flavours in place and preserves the types the
  entry already carried (UTF-8, the UTF-16 siblings, plain text, and the legacy
  types), adding `public.utf8-plain-text` when there was none. When the text
  changed, only image and file-URL payloads and the sync base-name bookkeeping
  flavour (`application/x-copyq-itemsync-base-name`) survive alongside the
  rewritten text: HTML, RTF, RTFD, URLs, text-bearing UTI and MIME types, and
  every other attachment are dropped because they describe or belong to the old
  content. Keeping the base name keeps a custom-named imported entry
  recognisable to stem ownership. Multi-item text is collapsed onto its lowest
  item index so the new text is not duplicated on paste.
- The store update is one transaction: flavours, fingerprint, the sync edit
  timestamp, and the FTS row change together, and the entry keeps its id, tab,
  creation time, pin state, and note. The search row also includes the stored
  plain text, so a capture that also carries a text flavour stays findable by it
  even when the preview shows an image summary. An unchanged save (same text
  after trimming surrounding whitespace) is a no-op and does not mark the entry
  locally edited; an entry without plain text gains `public.utf8-plain-text`
  only when the text actually changes. Cancelling the sheet never touches the
  store.
- A successful save whose entry is hidden by the active filter shows "Saved;
  hidden by the current filter." so a create or edit never looks like a no-op.
- New items are inserted into the current tab through the same text
  validation, with the same history bound as a capture, and without
  consecutive-duplicate collapsing because the user asked for a new row.
- Saving an edited item rewrites the entry's own file group in its tab's sync
  folder (see [Sync write-back](#sync-write-back-stage-2a)). A typed New Item is
  written back like a capture. Stem ownership lives on the entry itself: the
  sync base-name bookkeeping flavour, the `written_sync_stems.entry_id` row for
  a local write, or (for a legacy row) its original creation time decides which
  entry a stem owns. A same-stem upstream rewrite is resolved by the newest
  timestamp rather than a permanent local-edit veto: a newer upstream edit
  replaces the local content and logs a payload summary of what was discarded,
  while an older one is discarded, logged the same way, and the local version is
  written back. See
  [Duplicate collapsing](#duplicate-collapsing) for the exact rule.

## Fonts

`Preferences.itemListFont` and `Preferences.editorFont` are `FontPreference`
values: an installed family name and a point size, either of which may be nil.
Both default to `FontPreference.defaultValue`, so a store written before the
settings existed decodes to untouched, and `Preferences` still applies the rest
of its fields when one font value is unreadable.

Untouched means the surface keeps the font it drew with before the preference
existed, and `FontPreference.isDefault` is that rule in code. `nsFont` resolves
a preference to a platform font, the system body font while untouched, and the
item list draws `itemListFont.nsFont`. `chosenFont` is nil while untouched and
is what the editor sheet fixes when it opens, so both editors draw with a
chosen editor font while an untouched one keeps each editor's previous font:
the styled editor's `RichTextEditing.editorFont` (Helvetica Neue at body size,
the family the payloads are written in) and the plain editor's
`PlainTextEditor.bodyFont`. A chosen family is applied as stored,
with no validation; a family this system no longer has falls back to the system
font at the chosen size, which the styled editor draws as the default writing
family at that size because its text has to stay writable.

The editor font is a base font, not an override. The styled editor imports the
payload exactly as stored through `RichTextBuilder.document(from:)`, the same
reader the list rows and the preview use, so a run keeps the family, size, bold,
and italic the reader produced: a declared family this system does not have
renders in the reader's own substitution (Times for HTML, Helvetica for RTF)
exactly as it does everywhere else, never in the editor font. Once an editor
font is chosen it is the text view's base font, so the first keystroke at the
opening caret and text typed after the item is emptied are written in it,
without bold or italic; text typed inside an existing run keeps that run's
formatting, as the caret moves. An untouched preference keeps the text view's
own inheritance instead, exactly as before the setting existed: the attributes
of the run before the caret, so the first keystroke writes that run's style.
Nothing rewrites the payload bytes, so the item's text can never change and a
payload's own families always keep their rendering. `attributedText` still
falls back to the base font, at the run's own size, for a document built in
code that carries a family this system does not have; a payload never takes
that path, because the reader resolves every family before the editor sees it.

The styled editor's text has to be writable into the payload, and a payload has
to name a family, so a system face is drawn in the default writing family at the
chosen size. That is how the picker's System plus a size works: the styled
editor draws and types `StyledTextDocument.defaultFontFamily` at that size, and
what the editor draws, what the styled document records, what the payload
carries, and what a reopened item draws are the same family and size. The plain
editor draws the real system font at the chosen size, like the item list, whose
System is the real system font because no payload is involved.

Bold and italic are never dropped for a family that cannot supply the face.
`RichTextEditing.font(for:baseFont:)` asks `NSFontManager` for a face that
carries the run's wanted traits together, so a bold italic run keeps both: the
run's own face, its family's regular face, and the system font are tried in
turn, and the first that carries every wanted trait is used, substituting the
family when no member of it can. Only a document built in code reaches this,
because AppKit's readers drop a trait the resolved family cannot supply before
the editor sees the run.

The sheet fixes the base font when it opens, so a settings change mid-edit
applies to the next item instead of restyling text the user is editing; the
payload's own runs are never restyled either way.

The editor's family picker offers only families whose default face both
rich-text writers record unchanged
(`RichTextEditing.isRepresentable(font:format:)` for HTML and RTF, which also
rejects a condensed, expanded, or vertical face).
A family the RTF font table cannot carry would otherwise be read back into the
document and refuse every save of an item opened with it, even one the user did
not change. The item list picker offers every installed family because its font
never reaches a payload, and the list font is a base font for rows whose text
carries no font of its own: a row drawn from a rich payload keeps that
payload's fonts. `FontFamilyCatalog` loads the installed families before the
preferences window is shown, so a font installed while the app runs appears
the next time Preferences opens without the catalog being recomputed on every
body evaluation.

On the list side, `EntryListView.Coordinator.applyRows` remembers the font it
last configured the cells with. When it differs it reconfigures the visible
cells and invalidates every row height, so a font change reaches rows already on
screen instead of waiting for a capture or filter.

## Appearance and design tokens

`Preferences.theme` is the appearance policy: `AppTheme.system` (the default),
`light`, or `dark`. Decoding is tolerant the way the language choice is, so a
store written before the setting existed, or one holding an unrecognized value,
keeps following the system instead of discarding the rest of the preferences
blob.

`AppTheme.appearanceName(increaseContrast:)` is the one mapping from the policy
to an `NSAppearance.Name`. `.system` returns nil, so the system decides both the
scheme and the contrast; a forced scheme resolves to its standard name, or to
that scheme's `accessibilityHighContrast…` variant while the system's Increase
Contrast setting is on, so choosing Light or Dark never drops the contrast the
user asked for. `AppearanceManager` is the only place that applies the result:
it sets `NSApp.appearance` and, when handed one, that window's own appearance
(a window created later inherits the app-level value), and `AppDelegate`
re-applies it on launch and after every preference save, so the picker's change
reaches the windows that are already open.

`app/DesignTokens.swift` holds the values the interface draws with: semantic
colours, the spacing scale, the radius hierarchy, and text styles, plus the
`FontPreference.nsFont` and `chosenFont` resolution the [Fonts](#fonts) rules
describe and the `HoverButtonStyle` the custom buttons apply as `.hover` for a
single shared hover and pressed background. It lives in `app/`, not `core/`,
because resolving a colour or a font needs AppKit. The set is not an inventory
of candidates: it holds the values call sites use, one entry per value, so a
value only one surface draws may stay a literal until a second surface needs
it, and an unused member is removed rather than kept for later. Typography
covers text styles only, because the window chrome stays on system fonts; the
item list and the editor text are the only user-configurable fonts.

## Activation

Activating an item - a double click, Return, or Item ▸ Activate, plus a single
click once that switch is on - runs one ordered plan, so the triggers cannot
drift apart. `ActivationPlan.actions(for:hasPreviousTarget:)` is the only thing
that decides which steps run, and the order is always this one:

```
copy → paste (if enabled) → focus previous app (if enabled) →
close window (if enabled) → move to top (if enabled)
```

`ActivationPipeline.run` executes that list one step at a time, waiting for the
paste to report back before starting the next step. `AppModel.activate` supplies
the effects: the paste service, the window's hide closure, and the store. When
single-click activation is enabled, a single click activates immediately, while
`ClickActivationPolicy` suppresses the trailing click and double-click events of
a fast click sequence on the same row so it activates exactly once.

`Preferences.activation` stores the five switches, which Preferences ▸ History ▸
Activation exposes. Their defaults are the behaviour from before the switches
existed: a click only selects, and activating copies, pastes, focuses, and
closes the window. Two coherence rules keep the other combinations honest:

- **Pasting implies focusing.** The paste step brings the previous app forward
  before it posts Command-V, so "Focus the previous app" only changes anything
  with pasting off. Preferences says so next to the switch.
- **A delivery that does not arrive keeps the window and the focus.** When the
  item did not arrive, the focus step and the close step are skipped, so the
  window stays on screen with the banner that explains why. Without
  Accessibility trust the item is only copied; when that permission banner
  fades, the Accessibility item in the status bar carries the reminder until
  the app is trusted. An app that refused to activate is a genuine failure: it
  is logged and its reason stays in the status bar (`reportFailure`,
  `NoticeStatusPolicy`) until the user dismisses it. The plan also leaves the
  close step out when there is no previous app to deliver to at all: the copy
  has already happened, so the window shows the copy-only hint instead, and
  that hint is not kept as a failure. A manual ⌘V still works.

"Move to top" refreshes the entry's timestamp (`ClipboardHistory.moveToTop`), the
same way a repeated capture does, so the entry keeps its id, note, and pin state
and only changes its place in the newest-first order. It runs after the window
has closed, and the selection stays on the moved row.

Bulk deletes call `ClipboardStore.delete(ids:)`, which invokes the same
`onEntriesWillBeDeleted` handler as a single delete, so every selected entry's
owned group reaches the trash before any row disappears. Moving entries to
another tab runs `CopyQSyncRelocation`: when the destination tab has a sync
folder, the entry's group is rewritten into that folder under a fresh stem and
the source group goes to the trash; when the destination has no folder, the
source group still goes to the trash. A source tab with a folder always owns its
files, so there is no release-in-place case. The row move is persisted last, and
a failure restores the staged files, stems, and trash batches.

## Paste-back path

```
Activation: a double click, Return, Item ▸ Activate (and a single click when
that switch is on)
   ▼
PasteService.prepareFlavours  inflates every compressed flavour off the main
                              thread; only the newest request survives
   ▼
PasteService.copy        writes every flavour back with NSPasteboard.writeObjects,
                         reconstructing the original item structure, and records
                         the new changeCount so the watcher ignores it
   ▼
AXIsProcessTrustedWithOptions  (prompt: true on the first untrusted attempt, so
                                macOS shows its own dialog and lists the app;
                                every paste re-reads the state first)
   ├─ not trusted → leave the entry on the clipboard, show a notice with a link
   │                to System Settings ▸ Privacy & Security ▸ Accessibility
   └─ trusted
        ▼
   target.activate(from: NSRunningApplication.current)
        ▼
   wait until the target is frontmost (up to ~0.6 s)
        ▼
   CGEvent Command-V posted to the target's PID (postToPid)
```

The previously frontmost application is tracked by `FrontmostAppTracker`, which
updates on `NSWorkspace.didActivateApplicationNotification` and ignores this
app's own process. Reactivating the target (rather than the app re-hiding) is
why the window is a normal window and why the target is captured before the
window takes focus. `PasteboardBridge.write` filters out private sync bookkeeping
metadata (`application/x-copyq-itemsync-*`) and writes every remaining stored
flavour, including custom types, with its original bytes. It also fills in native
types when an entry only has a MIME or legacy name: text, HTML, RTF, PNG, JPEG,
TIFF, GIF, BMP, HEIC, and one `public.file-url` per file from `text/uri-list` or
`NSFilenamesPboardType` without duplicating URLs already stored natively. Import
translation handles the common text and PNG names up front, so this enrichment
mainly covers older imports and formats the shared translation table does not map.

A row dragged out of the list uses a separate pasteboard path: its writer and
`tableView(_:draggingSession:willBeginAt:forRowIndexes:)` attach standard and
legacy representations for external apps while preserving `com.copyqmac.entry-ids`
for internal tab drops. Bookkeeping and unknown custom payloads are excluded from
the drag, and each URL in a multi-file entry gets its own `public.file-url` item.
The same callback then appends one `NSFilePromiseProvider` per entry
(`app/EntryFilePromiseProvider.swift`) so a drop on Finder writes a real file: a
text, HTML, or RTF entry promises its plain text as `public.plain-text`, named
from its sanitised first line (`Text.txt` when that line leaves nothing usable),
an image promises its own stored format (PNG, JPEG, TIFF, HEIC, GIF, BMP) with
byte-for-byte unchanged payload, and a file entry promises nothing because its
`public.file-url` items already copy. The promise is the provider's own delegate,
so the payload lives as long as the promise AppKit holds for the drag, and it
rides beside the standard types instead of replacing them.

### Paste as Plain Text

Item ▸ Paste as Plain Text (⇧⌘V) and the global ⇧⌘V shortcut share one command
and the same paste tail as a normal paste; only the pasteboard content differs.
`FlavourDecoder.plainTextRepresentation` reads a set of flavours and, per item,
prefers an existing plain-text flavour, then strips HTML, then RTF, then falls
back to a URL. Multi-item snapshots keep their order joined by newlines. The
stored entry is never changed: `PasteService` writes the derived string as a
single `public.utf8-plain-text` item, records the new `changeCount` so the
watcher ignores it, and then runs the same activation, synthetic Command-V, and
Accessibility fallback as a normal paste.

The global shortcut has two sources, chosen by `PlainTextPasteSource`. With the
window open and an item selected it pastes that entry, because that is what the
user is looking at. Otherwise it reads the live clipboard
(`PasteboardBridge.snapshot`) and strips it to text, because the selected history
entry can be stale while the pasteboard is what the user just copied in another
app; that path writes the clipboard back as one plain-text item and does not
activate the target, which is already in front. A focused text control in the
CopyQmac window keeps the local behaviour and pastes into the field.

An entry with no text keeps the menu item enabled. A disabled item does not
consume its key equivalent, so macOS would play the system beep; the action
instead shows the same `noPlainTextMessage` notice. The model memoises the
derivation for the selected entry and uses it both for the enabled state and at
the start of the action, so opening the menu does not decompress a rich payload
again, and a live clipboard with no text reports `noClipboardTextMessage`. A
failed global-shortcut paste brings the hidden window forward so that notice is
visible; a successful one leaves the window hidden.

## Launch at login

Preferences ▸ History has a "Launch CopyQmac at login" toggle backed by
`SMAppService.mainApp`. Nothing about the setting is stored in the preferences
blob: the system is the source of truth, so the toggle is refreshed at launch,
whenever the app becomes active, and after every change. This also means a
disabled Login Items entry shows as off rather than as a stale on. A
`.notFound` status means macOS has no entry for this bundle yet, which is the
normal state before the first registration, so a fresh install can enable the
toggle like any unregistered app. A
`requiresApproval` result is shown as off with a pointer to System Settings ▸
General ▸ Login Items, which is also where a locally signed app has to be
allowed. That state notice is retracted as soon as the refreshed Login Items
state no longer needs it, and a successful toggle never replaces an unrelated
notice (`LaunchAtLoginNotice`). A failed `register()`/`unregister()` is reported
with the system's reason in the notice banner and next to the toggle, and the
toggle falls back to the state macOS actually reports; the app remembers which
direction failed, so a refresh retires that failure only when macOS reports the
requested state (enabled after a failed enable, disabled after a failed
disable). The close control on the banner clears the failure reason with it; the
banner's own timeout only retires the banner, and the status-bar record of the
failure stays until it is dismissed. A launch
that macOS starts as a login item stays in the menu bar instead of opening the
main window; a manual launch still opens it. The two are told apart by
`keyAEPropData == keyAELaunchedAsLogInItem` on the launch Apple event
(`AppLaunchSource`).

## Permissions

| Capability | Permission | Notes |
| --- | --- | --- |
| Capture clipboard | none | Polling `changeCount` needs no permission. |
| Summon the window | none | Carbon `RegisterEventHotKey` is not gated by Accessibility. |
| Automatic paste-back | Accessibility | Needed for `AXIsProcessTrustedWithOptions` and synthetic `CGEvent`s. One grant per ad-hoc code identity, so after a rebuild remove the old entry and add the app back in the pane. |
| Launch at login | Login Items approval (sometimes) | `SMAppService.mainApp` registration; macOS may require the user to allow the entry in System Settings ▸ General ▸ Login Items. |
| Screenshots for verification | Screen Recording | Only needed to capture the UI as an image. |

Accessibility is what puts the app in the system list at all, so the first
paste-back attempt while the process is untrusted calls
`AXIsProcessTrustedWithOptions` with `prompt: true` (`AccessibilityPermission`
decides when: the first untrusted attempt, never while already trusted, and
re-armed after a trusted check so a later revocation can ask once more). The
status-bar Accessibility item does both halves of the same job:
it requests the dialog and opens the pane. It is shown only while the permission
is missing and only once the banner that announces it has faded, so the same
explanation is never on screen twice (`AccessibilityNoticePolicy.showsStatusItem`).
The trust state is re-read whenever the window becomes key, on application
activation, and at each paste; a notice about the missing permission disappears
on its own once the app is trusted (`AccessibilityNoticePolicy`); other notices
are left alone.

A posted synthetic Command-V is treated as proof that the app can paste
(`PasteTrustSession.notePasteSucceeded`). macOS can keep reporting an
ad-hoc-signed build as untrusted after the user has re-granted the permission -
the System Settings toggle still belongs to the binary that was there first -
and the process-level check can stay stale until relaunch. Because the paste
service and the model share one `PasteTrust`, a paste that works retires the
notice, stops all further prompt requests for the launch, and keeps the notice
retired across later activations. A check that runs when the user comes back to
the app (`afterUserAction`) while the process still reads untrusted after a
prompt marks the grant as stale, and the notice then explains the remove-and-add
dance instead of repeating the first-run instruction.

The permission is
recorded against the app's own code signature, which requires the app to run as
its own process - see
[Building](build.md#launching-the-app-and-why-it-matters). When launched from a
trusted parent process (a terminal that already has Accessibility), the app
inherits that trust for the session instead of registering itself, which is why
running the binary inside the bundle is not a way to check the paste path. The
grant follows the ad-hoc code signature, so a rebuild invalidates it even though
the System Settings toggle still looks on. Switching that old entry off and on
again does not transfer the grant; selecting `CopyQmac`, removing it with
**−**, adding `CopyQmac.app` back with **+** (the app's own status-bar
Accessibility item registers the current binary), and returning to the app does.
The orange banner explains this and links to the pane.

## Hotkey choice

Carbon's `RegisterEventHotKey` is the only public API that registers a
system-wide hotkey without Accessibility permission, which is exactly the
requirement: the shortcut has to work before the user grants anything. Two
shortcuts share one event handler: the summon shortcut (Option-V by default)
and Paste as Plain Text (⇧⌘V by default). Each registration carries its own
`HotKeyAction` ID, and the handler dispatches by that ID, so a second
registration cannot run the first action's closure.

Both shortcuts are stored in `Preferences` (`hotKeyKeyCode`,
`hotKeyModifiers`, `hotKeyDisplayLabel`, plus the `plainTextHotKey…` fields), so
the preferences window can offer presets or record custom combinations, and
`AppDelegate` re-registers when either changes. `AppDelegate` registers the
summon shortcut first. If plain-text shares the same keystroke (or was
previously registered under summon's new keystroke), plain-text is unregistered
before Carbon registration so it does not fail with `eventHotKeyExistsErr`. When
both combinations are identical, Preferences shows an explicit conflict hint
next to the recorder. If the system refuses the plain-text combination because
another app owns it, Preferences likewise displays that conflict reason. A
refused summon shortcut keeps its long-standing alert and still leaves the
menu-bar item available.

## UI composition

- `MainWindowController` owns a standard titled `NSWindow`: a normal title bar
  with the traffic lights where macOS puts them, an opaque content area, and a
  frame the user can drag to resize. The SwiftUI root draws the window body in
  the standard window background colour, so the list, the preview pane, and the
  status bar never show the desktop through them; the Liquid Glass surfaces are
  accents inside the window (the tab chips, the notice, the note editor), not
  the window itself. The hosting view reports only its minimum size
  (`sizingOptions = [.minSize]`) to AppKit: SwiftUI's minimum keeps the window
  from being dragged smaller than the layout, without letting ideal sizes
  dictate the window's maximum size. The window's transient banner
  (`NoticeBannerView`) floats over the top of the item list, below the tab strip
  and the filter field: it never pushes the tabs down, never covers them, and
  never takes focus. Over the list it also never contributes height; the empty
  list has no scroll view to overlay, so there the banner sits above the
  empty-state content instead. It is built in AppKit for one reason:
  `hitTest(_:)` returns nothing for the whole plate and only the banner's
  own buttons for their rects, so clicks and double clicks on the rows underneath
  reach the list while the message is up. It fades out after a few seconds
  (`NoticeTimer`, one cancellable timer per shown message, so a replacement never
  stacks and a retired timer cannot clear its successor), a repeated identical
  message restarts that timer, and its close control dismisses it at once. The
  frame is remembered by AppKit's own window autosave (`setFrameAutosaveName`),
  so a restored frame lands where the user left it. A frame whose display is no
  longer attached is constrained to an attached screen
  (`constrainFrameRect(_:to:)`) instead of reopening out of reach; a window that
  has never been placed is centred. Closing the window hides it and leaves the
  app running in the menu bar.
- Window layouts:
  `MainWindowView` supports two window arrangements behind the `Preferences.windowLayout`
  setting:
  - **Layout A (Classic)**: A vertical stack composed of the top tab strip, filter bar,
    item list, 170pt bottom preview pane with the note editor, and status bar.
  - **Layout B (Sidebar + Inspector)**: A macOS-native arrangement using `NavigationSplitView`.
    It features a left sidebar (default 200pt, adjustable 160...260pt) showing the tab list with
    per-tab counts, capture badge, and drag-and-drop tab reordering. The sidebar column's width is
    managed explicitly (the split view's own divider is inert); an 8pt drag handle on its trailing
    edge (`NSCursor.resizeLeftRight` on hover) resizes it, and the width is debounced and persisted
    as `sidebarWidth` (clamped to 160...260), so it is restored on relaunch. A fixed-position toggle
    in the navigation toolbar
    replaces the automatic sidebar toggle: it is pinned right of the window title, stays
    there whether the sidebar is open or closed, and looks identical in both states
    (Control-Command-S). A 52pt unified toolbar
    integrates the filter search field, scope picker (Current tab / All tabs), and inspector
    toggle button (Cmd-Opt-I); a center column displays the item list at full available
    height with responsive primary text wrapping up to 6 lines (tail ellipsis
    beyond); and an adjustable trailing inspector (default 280pt, range
    240...560pt). An 8pt drag handle on the inspector
    column's leading edge (`NSCursor.resizeLeftRight` on hover) resizes it with debounced
    persistence as `inspectorColumnWidth` (clamped to 240...560pt and further capped so the
    center item list keeps at least 320pt whenever the container is at least 560pt wide;
    below that the inspector keeps its 240pt minimum and the item list takes the
    remainder), restoring the chosen width on relaunch. The inspector provides a top metadata
    block (flavour tag, line count, byte size, timestamp) and preview/note panes sharing the
    remaining height across a 7pt horizontal drag divider (grip line 22x2pt,
    `NSCursor.resizeUpDown` on hover and during drag, 60pt minimum height per pane,
    double-click reset to 0.55). The split ratio is persisted as `inspectorSplitRatio`
    (clamped to 0.20...0.80). The sidebar is a real keyboard surface: while it has
    focus, Up/Down/Page/Home/End move its tab selection and the item list and
    inspector follow, Return does not paste, and Escape still reaches the window.
    All of that reads one `ListFocus` signal on
    `AppModel`, so the filter field, the item list, and the sidebar can never
    claim the same key.
  The chosen `Preferences.windowLayout` is stored under its own `windowLayoutChoice`
  key and defaults to Layout B; a missing or unknown value falls back to Layout B, and
  a legacy `windowLayout` field from before the control existed is never read as a
  choice and is carried through unchanged. Both layouts remain available and can be
  switched at runtime in Preferences ▸ History ▸ Appearance via the Window layout
  control (Top tabs / Sidebar + inspector) without losing the active tab, item
  selection, or list state.
- The window follows the user across Spaces. Its collection behaviour includes
  `moveToActiveSpace`, so the hotkey and the menu-bar item bring it to the
  Space that is active right now instead of leaving it behind on the Space where
  it was created. The toggle treats a window that sits on another Space as not
  shown, so the hotkey moves it rather than hiding it.
- The status item's button sends its action on both mouse-up events
  (`sendAction(on: [.leftMouseUp, .rightMouseUp])`). Left click toggles the
  window, deferred to the next main-loop turn so AppKit's mouse-tracking loop
  can return first; activating the window synchronously from the button action
  left it beachballed. Right click attaches the menu to the status item and
  clicks the button once, which is the supported way to show a status-item menu
  without the deprecated `popUpStatusItemMenu`; `menuDidClose` detaches it again
  so the next left click toggles instead of reopening the menu. `StatusMenuBuilder`
  assembles the status menu, including New Item… (⌘N) and Edit Item… (`fn`-`F2`), and
  `menuWillOpen` retitles and re-targets the first item to Show or Hide to match
  the window's visibility. A gesture recognizer does not see the right click on an
  `NSStatusBarButton`, and the old synchronous `popUp(positioning:at:in:)` call
  deadlocked in its tracking loop.
- `WindowKeyMonitor` is a local `keyDown` monitor over the key window. It maps
  events to a `ListKey` and asks `ListInteractionPolicy` whether the window
  should act: Up/Down/Page/Home/End always move the selection, while Return and
  Backspace stay with the focused `PlainTextEditor` unless Escape is the one ending
  note editing. A focused Layout B sidebar keeps its Up/Down and Return keys,
  so the monitor passes those through to the tab list; Page/Home/End are answered
  by the window with tab selection so they do not fall back to native scrolling.
  Up and Down take the selection with the focus, and Shift-arrow
  extends the range from the last plain click. Digit keys 1 through 9 become
  `ListKey.digit`; `ListInteractionPolicy` accepts them with Command or an empty
  search field, rejects other modifiers and note editing, and AppModel maps the
  number to the visible row before pasting. Repeat events are dropped for
  Return, Escape, Delete, and the digit keys, and deletion has a 0.3 s cooldown,
  so holding a key cannot paste, close, or delete repeatedly.
- The list is a view-based `NSTableView` bridged through `NSViewRepresentable`
  (`EntryListView`). AppKit asks the data source only for on-screen rows, reuses
  cell views, and moves selection with `selectRowIndexes`, so neither a click
  nor an arrow key rebuilds the row hierarchy or runs a SwiftUI list diff.
  Selection lives in its own `SelectionState` object; the list subscribes to it
  directly, and only rows whose precomputed `EntryRow` changed are reconfigured.
  The table allows multiple selection, so AppKit supplies Command-click toggling
  and Shift-click ranges; the coordinator reports the whole selection plus the
  last clicked focus, and `ItemSelection` owns the keyboard rules (plain arrows
  collapse to one row, Shift extends, Command-A selects all, Escape clears a
  multi-selection before the window would hide).
  Rows drag with a private pasteboard type that the tab chips accept, which is
  how a whole selection moves to another tab. The same writer feeds external
  drags; their pasteboard contents are described in
  [Paste-back path](#paste-back-path).
- The list scrolls only when the selected row is not fully inside the viewport
  (`SelectionRevealPolicy`). After a capture or tab change `AppModel` asks for a
  reveal, so a newly captured entry - and a selection pushed down by it - stays
  on screen. Clicking a fully visible row never scrolls.
- A row's height follows its content. AppKit measures an `NSHostingView`'s ideal
  size at the content's own ideal width, where a long text fits on one line, so a
  preview that wraps used to be measured as a one-line row and the cell clipped
  the second line - and, because a row centers its content vertically, the first
  line's top with it. Rows are therefore built with the list's current width
  baked into the content, which makes the measured height the height the text
  actually needs, and visible rows are reconfigured and re-measured when their
  content changes (a placeholder that receives its preview, a thumbnail that
  arrives, an edited entry) or when the list is resized. `RowHeightPolicy`
  decides when AppKit has to measure a row again, and it ignores differences that
  are only AppKit's whole-point rounding.
- Row presentations and downsampled thumbnails are built off the main thread
  and held in bounded LRUs, keyed by entry ID (thumbnails also by pixel bound).
  `AppModel` precomputes one `EntryRow` per visible entry with only presentation
  text and metadata - never decoding flavours, computing payload fingerprints,
  or retaining thumbnail bitmaps - and rebuilds it only when the entry's data
  changes. Realized cells read the byte-budgeted thumbnail cache at draw time
  and request a background decode on a miss; off-screen entries cost nothing.
  Full preview text, the line count derived from it once, and file URL lists are
  retained only for the selected entry.
  The thumbnail cache is bounded by total decoded bytes (a 32 MB budget), so a
  long history cannot pin decoded pixels. The selected entry's subsampled
  preview image (bounded to 1600 px) lives outside both caches; hiding the
  window releases it immediately, and 60 s later the thumbnail and rich-text
  caches are emptied as well.
- HTML and RTF entries draw their stored formatting in both the list row and
  the preview pane instead of the plain-text excerpt used by search and
  paste-back. The rich payload is read once by `RichTextBuilder` on the
  main thread with `NSAttributedString` document reading, parsing the selected
  entry first and other entries lazily in bounded batches. `RichTextCache`
  keeps the parse in a bounded LRU (16 MB, 256 entries) so a layout pass only
  does a dictionary lookup. The cache stores the parsed document, so switching
  light/dark appearance re-derives the row and preview renditions without
  reading the payload again. Row fonts are fitted into a compact size band so
  a large heading cannot exceed the row height, and explicit source colours
  are lifted toward white in dark mode (or darkened in light mode to maintain at
  least 4.5:1 contrast) to stay legible. A text-only entry keeps the existing
  `primaryText` path and never invokes the document reader.
- `NoteFocusMonitor` ends note editing on mouse-down outside the editor, before
  the list sees the click, so the click that moves the selection is never spent
  ending the editing session. Clicks inside the editor keep moving the caret: the
  focused editor is the standalone `NSTextView` behind `PlainTextEditor`, which
  `isFieldEditor` tells apart from the filter field's shared field editor.
- The styled item editor (`RichTextEditor` in `app/StyledTextEditor.swift`)
  hosts a rich-text `NSTextView` in the same clip-filling scroll view and with
  the same two points of first-line headroom, so it keeps the CJK clearance the
  plain editor needed. `FirstLineClippingTests` checks it alongside the other
  editors.
- The note editor and the plain Edit Item editor use `PlainTextEditor`, which
  hosts its own `NSTextView` instead of SwiftUI's `TextEditor`. `TextEditor`
  keeps AppKit's Helvetica 12 and a zero text-container inset, and Helvetica's
  9.24 pt ascent is shorter than the roughly 10.2 pt a fallback PingFang glyph
  reaches above the baseline, so the clip view cut the tops of the first line's
  CJK glyphs; Latin ascenders stayed inside the ascent, which is why only
  Chinese text looked clipped. The plain Edit Item editor draws with the
  configured editor font, the app's body font until one is chosen, while the
  note editor keeps its previous Helvetica 12. Both reserve two points above the
  first line, so the first line's glyph tops stay inside the clip, and the note
  area keeps its previous line height and density. Its document view also fills
  the clip, so clicks below a short note reach the editor.
  `FirstLineClippingTests` checks each editor's font, line height, text-container
  inset, and rendered first-line ink, and compares that clearance with the old
  `TextEditor` configuration.
- The note pane owns its editing session through the editor's
  `NSTextViewDelegate` callbacks, not through SwiftUI state. The begin-editing
  callback starts `AppModel`'s note-editing session before the first keystroke
  arrives; a SwiftUI state round trip lands after it, and a draft that reaches the
  model before the session exists is dropped. The editor also treats the text view
  as the authority on its own text while it is being edited: an update only writes
  the model's value into the editor when the model itself changed, so the stale
  value the pane passes back after a keystroke cannot erase what was just typed.
- `AppActions` is the single target for both the main menu and the status-item
  menu, and implements `NSMenuItemValidation` so items enable, disable, and
  retitle (Pin/Unpin) correctly. When a text control is focused (such as the note
  editor or search field), editing shortcuts (Copy, Paste, Delete) defer to the
  first responder rather than operating on history entries.
- Glass surfaces come from `glassSurface(...)` and use `.glassEffect` directly
  on the macOS 26 minimum supported version.

## Interface language

The interface is available in English and Simplified Chinese, stored as
`AppLanguage.english` (`en`) and `AppLanguage.simplifiedChinese` (`zh-Hans`).
`Preferences.language` holds the choice and defaults to English, so a store
written by an earlier build keeps an English interface. Decoding is tolerant: a
missing or unrecognized stored value falls back to English instead of discarding
the rest of the preferences blob.

`core/Localization.swift` owns the text and imports only Foundation, so the test
binary can check the catalog without a GUI. `CatalogKey` is the one catalog:
every key carries an English and a Simplified Chinese value, and
`Localization.string`, `.format`, and `.formatCount` resolve a key for a
language, and `.byteCount` formats a byte count in that language's own units
rather than the system formatter's. The picker in Preferences ▸ History ▸
Language names each language in its own script. Views and dialogs read
`model.preferences.language` when they render and pass it into the lookup, so
the picker's change repaints the open surfaces immediately instead of waiting
for a relaunch. `AppDelegate` rebuilds the main menu when the stored language or
the window layout changes, because the Tabs menu names each tab move for the
layout's axis; a language change also rebuilds the status menu and updates the
status item's tooltip and accessibility description and the preferences window
title.

Some displayed text is assembled by `core/` rather than looked up: failure
records, sync diagnostics, relocation errors, and launch-at-login reasons built
from typed errors, file names, and counts. `Localization.runtimeMessage` is the
display boundary for those; it translates the framing prose while keeping a file
name or a system error string verbatim. The status-bar record, each notice-banner
clause (translated one at a time, so a record made of several clauses still
renders), the launch-at-login reason, and the text editor sheet's save-failure
notice - which the sheet keeps unresolved in its state, so a language switch made
while it is open repaints it - pass through it; a message with no catalog entry
renders unchanged in English rather than disappearing. Report types that own a
summary - import, backup export, reconcile, resync, relocation, app trash, and
marker cleanup - build it from the catalog with `summary(language:)`, so their
counts, byte sizes, and clauses read in the selected language. The watcher scan's
summary reaches the screen through the picked-folder import notice, so it is
built from the catalog too.
A sync folder's per-file read failures and a reconciliation deletion report's
trash and archive clauses are composed in the selected language where they are
produced instead of being translated again at display, with the file name and the
system error string kept verbatim in both. Failure lists nothing displays - the
watcher's background scan and the configured-folder import - keep English prose.
Menu items, dialogs, file panels, the Help dialog, the main window's content, and
the preferences window call the catalog directly. `EntryPresentationCache` keeps
the current language next to its cached rows and recomputes every row's relative
timestamp when the preference changes, so existing rows switch immediately
instead of waiting for the next timestamp tick. `AppLanguage.locale` is the one
formatter locale: the catalog's number substitutions and the absolute date
`RelativeTime` falls back to for entries older than yesterday use it instead of
the system locale, so a German system locale does not put German month names
into an English window.

Localized in this build: the menu bar, the status item and its menu, the
in-window status bar, the preferences window, the confirmation, report,
compare, and help dialogs, the file panels, the notice banner's message
controls, the main window's own content (the filter bar, the empty states, the
entry-row help and content-kind badge, the row and tab context menus, the
preview and note labels, and the text editor sheet with its styled toolbar),
the in-window success notices with the report summaries they carry, and the
item rows' relative timestamps, whose numeric values are left as they are. The
language touches no other behaviour: capture, storage, sync, item rendering, and
window layout are identical in both.

## The menu bar and the activation policy

`MainMenuBuilder` builds the main menu (CopyQmac / File / Edit / Item / Tabs /
Help) and `AppDelegate` installs it as `NSApp.mainMenu` at launch. Owning a menu
bar, however, is a property of the activation policy, not of the key window: on
macOS 26 an `.accessory` app (`LSUIElement`, no Dock icon) keeps a key window,
coloured traffic lights and all, without ever drawing its own menu bar. The menu
bar continues to show the menus of the last regular app, which is why a window
that looks and behaves active can sit under an empty application-menu area.

Measured on macOS 26.5.1 (25F80) with a minimal ad-hoc-signed probe app
(`LSUIElement` true, a titled window, and a three-item main menu, so nothing in
CopyQmac's own code was involved):

| Probe state | `NSApp.activationPolicy()` | `window.isKeyWindow` | LaunchServices front app | Menu bar shown |
| --- | --- | --- | --- | --- |
| accessory, window shown and activated | `.accessory` | true | the probe | the previous regular app's menus |
| regular, window shown and activated | `.regular` | true | the probe | the probe's own menus |
| accessory, then `.regular` while the window is already key | `.regular` | true | the probe | still the previous regular app's menus |
| `.regular` with the window visible, then back to accessory | `.accessory` | true | the next regular app | the next regular app's menus |

CopyQmac reproduced the first row before the fix: `activationPolicy=.accessory`,
`NSApp.isActive=true`, `window.isKeyWindow=true`,
`mainMenu=["CopyQmac", "File", "Edit", "Item", "Tabs", "Help"]`, and the
screen's menu bar showing another app's menus. The switch has to happen before
the window is ordered front; changing the policy after the window is already key
does not repaint the menu bar (third row).

`ActivationPolicyController` therefore makes the app regular while at least one
of its own windows is on screen and returns it to accessory when the last one
closes. The main window registers before `makeKeyAndOrderFront` and unregisters
after `orderOut`; the preferences window does the same and unregisters when it
is closing. After the fix the same diagnostic reads
`[show] activationPolicy=0 NSApp.isActive=true window.isKeyWindow=true frontmost=CopyQmac/... mainMenu=[...]`
and `[hide] activationPolicy=1 NSApp.isActive=false window.isVisible=false`;
the Dock lists the app while the window is open and drops it when the window is
closed, while the status item keeps running.

The tradeoff is a Dock icon while a window is visible: macOS has no way to give
an accessory app a menu bar, and the icon is the visible half of `.regular`. It
is temporary - closing the window (or the last preferences window) restores the
menu-bar-only state - and a launch that macOS starts as a login item never
opens a window, so a login launch never becomes regular.

## Why these choices

- **Swift + SwiftUI/AppKit, no Qt/Electron/web view.** The native stack was a
  deliberate choice; a web view would not reach the pasteboard or Carbon hotkey
  APIs cleanly.
- **No Xcode project.** The Command Line Tools ship `swiftc`, the macOS 26 SDK,
  `codesign`, and `iconutil`, which is enough. The Makefile is the build system
  of record, so the build is reproducible from a terminal. Anything that would
  require a full Xcode install (asset catalogues, `xcodebuild`, SwiftUI
  Previews) is avoided.
- **System SQLite + FTS5.** No package manager or Xcode needed, and FTS5 with
  the trigram tokenizer gives correct substring search for Latin and CJK.
- **Raw-byte flavour storage.** Keeping every flavour's exact bytes is the only
  representation that round-trips every format, including unknown custom types.
  Compression on disk is only a storage encoding, reversed lazily when an
  entry is previewed or pasted back.
- **Legacy CopyQ reading.** Reading legacy CopyQ history is a confirmed,
  scheduled deliverable with its reader already in place. Stage 1 provides
  one-way import from itemsync folders and .cpq binary archives (`core/CopyQSync`
  and `core/CopyQSyncBridge.swift`). Capture write-back, settled import,
  two-way content edits, and two-way deletion sync are delivered; tombstones
  remain scheduled work.
- **CopyQ-compatible backup export.** `CopyQArchiveWriter` streams v4 archives
  (the layout CopyQ writes when it has no encryption key) with one item encoded
  at a time, and the bridge reads the history in bounded chunks, so a large
  history neither sits in memory nor blocks the window. Native pasteboard
  flavours are written under the CopyQ MIME name for the same payload
  (`text/plain`, `text/html`, `text/rtf`, `image/png`, `text/uri-list`) and other types keep
  their identifier, with payload bytes unchanged; a multi-item capture keeps its
  first item's flavours and a multi-file copy keeps every path in
  `text/uri-list`. Importing restores those entries, skipping content that
  already exists in the tab. Duplicate tab names are disambiguated at the export
  boundary so every tab keeps its own item list, and capture times travel in
  CopyQmac's own item flavour so a restore keeps each entry's capture time.
  Internal bookkeeping flavours are never written, and an entry that holds
  nothing but them is left out entirely, so a backup never contains empty items
  that CopyQ would materialise as new empty entries.
