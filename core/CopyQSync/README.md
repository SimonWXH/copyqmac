# CopyQSync

A dependency-free Swift module that reads and writes the file formats CopyQ
uses for cross-device synchronisation, and reads and writes CopyQ's `.cpq`
export archives. It is the prerequisite format layer for sync wiring, not a
complete bidirectional sync feature. App-side reading, import and backup
orchestration, settled watcher import, two-way content edits, two-way deletion
and trash, and dry-run export are integrated via `core/CopyQSyncBridge.swift` and
the neighbouring `core/CopyQSync*.swift` services (see `docs/README.md` for the
phased delivery plan). This module never touches CopyQ's own history store.

## What it knows

### Sync folders

The CopyQ `itemsync` plugin syncs a tab with a directory.  One clipboard item
becomes a group of files sharing a name stem:

```
copyq_20260829120939486.txt          text/plain
copyq_20260829120939486.html         text/html
copyq_20260829120939486_note.txt     application/x-copyq-item-notes
copyq_20260829120939486_copyq.dat    every flavour without its own file
copyq_20260829120939486.png          image/png
```

The stem is CopyQ's UTC creation stamp, `copyq_yyyyMMddhhmmsszzz` (the `hh`
field is the 24 hour clock because no AM/PM marker is present).  Some builds
append a counter after those 17 digits and may reuse a stale stamp, so only the
leading stamp is parsed as the creation time; `CopyQSyncItem.timestamp` also
considers the newest backing-file modification time.  The extension table and
the format names are the ones in `plugins/itemsync/filewatcher.cpp` upstream.

`CopyQSyncFolder.read(atPath:)` enumerates items and never writes.  It reports
items, per-format flavour counts, notes, images and a reason for every file
that cannot be decoded.  `CopyQSyncFolder.readItem(baseName:atPath:candidateFiles:)`
reads and decodes an individual item group by stem without enumerating unrelated files.
Both paths skip Syncthing conflict copies, whose names contain `.sync-conflict-`
between the stem and extension: a concurrent edit produces files such as
`copyq_20260829120939486.sync-conflict-20261118-120500.txt`, and treating them
as new stems would import ghost items and pollute two-way sync history.

`CopyQSyncFolder.write(_:into:)` writes an item back in the same shape; callers
must point it at a scratch directory.

### The `_copyq.dat` container

The container is a Qt `QDataStream` in big-endian order:

```
qint32   version            -2 (current), -3 (encrypted), or a legacy count
qint32   flavour count
for each flavour:
  QString    MIME type, prefix compressed
  qint8      compression flag
  QByteArray bytes           0xFFFFFFFF means a null value
```

MIME names are shortened with a one hex digit prefix table (`4` = `text/plain`,
`9` = `application/`, `3` = `application/x-copyq-`, ...).  A non-zero
compression flag means the bytes are `qCompress` framed (big-endian
uncompressed size followed by a zlib stream); the build links the system zlib
with `-lz`, and the bridge (`core/QtCompression.swift`) is shared with the
app's SQLite store, which uses the same framing for compression at rest.
`CopyQItemData.encode` stores flavours raw by default, which keeps `_copyq.dat`
sync files byte-stable; `CopyQArchiveWriter` passes
`CopyQItemData.itemDataThreshold` (1024 bytes, CopyQ's `item_data_threshold`)
so larger archive flavours carry the flag and a `qCompress` payload.
Uncompressed v2 containers round-trip byte-for-byte; compressed flavours are
expanded on read, and legacy v1 containers are re-encoded in the current v2
form.

A null `QByteArray` is kept distinct from an empty one because CopyQ stores
its pinned marker as a null value.

### Item metadata

| format | meaning |
| --- | --- |
| `text/plain` | item text |
| `text/html` | rich text (HTML) |
| `text/rtf` | rich text (RTF, as GTK names it on Linux) |
| `text/uri-list` | file list |
| `image/*` | images |
| `application/x-copyq-item-notes` | note (written to `_note.txt`) |
| `application/x-copyq-item-pinned` | pinned marker, null value |
| `application/x-copyq-tags` | comma separated tags |
| `application/x-qt-mime-type-name` | Qt drag/drop marker |

`CopyQSyncItem` exposes `text`, `html`, `notes`, `isPinned`, `tags`, `images`,
`timestamp` (the later of the stem's stamp and the newest backing-file
modification time), and `fileModificationDate`. `effectiveTimestamp` is the
resolver both sources feed through.

### `.cpq` archives

`CopyQArchive.read` accepts both export versions:

* **v4** (what CopyQ writes by default and what `copyq_macOS.cpq` is): a
  `QByteArray("CopyQ v4")` magic, the export `QVariantMap`, then one
  `QVariantMap` per tab with `name`, `data` and an optional `icon`.
* **v5**: a `CopyQ v5` magic followed by CopyQ's item data containers.

The archive reader decodes the `QVariant` types CopyQ writes (bools, integers,
doubles, strings, byte arrays, string lists, lists, maps, dates and times, and
the geometry types). Unsupported `QVariant` types and encrypted (`-3`)
containers fail rather than silently dropping data. Compressed flavours that
cannot be decoded are listed in `CopyQArchive.failures`, while other readable
data is retained.

`CopyQArchiveWriter` writes archives, and only in v4, for the same reason
CopyQ only writes v4 when it has no encryption key
(`MainWindow::exportDataFrom`, `src/gui/mainwindow.cpp:2270-2273`): its v5
reader asks for a password before it reads anything
(`MainWindow::importDataV5`, `src/gui/mainwindow.cpp:2567-2577`), so an
unencrypted v5 archive cannot be imported by CopyQ at all. The writer streams
to a temporary file next to the destination and moves it into place when the
archive is complete, so an abandoned export never leaves a truncated backup
behind. The bytes it writes follow `exportDataV4` (`mainwindow.cpp:2293-2313`),
`exportSettings` (`:537-570`), `exportTabData` (`:2383-2387`),
`serializeData(model)` (`src/item/serialize.cpp:590-601`) and the item data
container (`:480-525`). Flavours larger than `CopyQItemData.itemDataThreshold`
are written with the compression flag set and a `qCompress` payload, matching
CopyQ's `item_data_threshold`, so a backup of a large history stays close to
CopyQ's own archive size. `tests/main.swift` checks that layout against an
expectation built from those same source-derived rules. The tab body framing
(tab map key order, item list count, item container) is derived from
`exportDataV4`/`exportTabData` (`src/gui/mainwindow.cpp`) and
`serializeData`/`serializeDataItems` (`src/item/serialize.cpp`), and verified
by importing multi-tab exports into CopyQ on Fedora.

```swift
let writer = try CopyQArchiveWriter(destinationURL: url, tabs: ["Clipboard"])
try writer.beginTab("Clipboard")
for item in items { try writer.append(item) }
try writer.finishTab()
try writer.finish()
```

Items written by CopyQmac carry their creation time in
`CopyQFormat.macItemCreatedAt` (`application/x-copyqmac-item-created-at`,
decimal Unix seconds). CopyQ's item model has no creation time - a tab is an
ordered list of flavour maps - so without it a restored history would collapse
onto the restore time. CopyQ keeps formats it does not know, so the archive
stays a valid CopyQ export; `CopyQArchive` lifts the value into
`CopyQSyncItem.timestamp` and removes the flavour, and
`CopyQSyncBridge.itemToEntry` drops it from every import path, so it never
reaches a store entry, the pasteboard, or a sync folder.

The archive side of the bridge (`core/CopyQSyncBridge.swift`) writes each
native pasteboard flavour under the CopyQ MIME name for the same payload
(`public.utf8-plain-text`/`public.plain-text`/`NSStringPboardType` to
`text/plain`, `public.html`/`NSHTMLPboardType` to `text/html`,
`public.rtf`/`NSRTFPboardType` to `text/rtf`, `public.png` to `image/png`,
and both file representations to `text/uri-list`), copying the payload bytes
untouched. Types CopyQ has no name for keep their original
identifier, because CopyQ keeps unknown formats verbatim (private sync
bookkeeping formats like the sync file stem and
`application/x-copyq-itemsync-*` / `application/x-copyq-private-*` are skipped
so sync internals do not leak into backups, and entries holding only bookkeeping
formats are omitted entirely so backups never contain empty items). CopyQ's v4 item is
one flavour map, so a capture that carried several pasteboard items (for
example copying two images) backs up only the first item's flavours; a
multi-file copy, which macOS records as several pasteboard items and CopyQ as
one item, keeps every file URL in a single `text/uri-list` - the representation
CopyQ uses for the same copy. Splitting a multi-item capture into separate
archive items is a follow-up. Importing the archive restores the entries; items
carrying only bookkeeping formats are skipped, and an entry whose content already
exists in the tab is skipped as a duplicate, so a repeated payload keeps only its
first capture.

## Building

The module and its tools build with only the macOS Command Line Tools.  There
is no Xcode project and no SwiftPM manifest.

```sh
tools/copyq-sync-tests.sh                      # compile and run the tests
tools/copyq-sync-probe.sh sweep <sync-folder>  # read-only folder report
tools/copyq-sync-probe.sh roundtrip <path>     # _copyq.dat byte round trip
tools/copyq-sync-probe.sh cpq <archive.cpq>    # archive summary
```

By default, both scripts compile into `${TMPDIR:-/tmp}/copyq-sync-build`; set
`COPYQ_SYNC_BUILD_DIR` to choose another build directory.

The tests carry the byte layout of the two `_copyq.dat` shapes that occur in
real CopyQ sync folders so the round trip is checked without any external
fixture.  A real corpus can be added on top:

```sh
tools/copyq-sync-tests.sh --corpus <dir-with-copies> --cpq <archive.cpq>
```

The real-archive control runs only when `--cpq` is supplied; `make test` passes
no `--cpq`, so CI has no real CopyQ archive fixture.

## Safety

Nothing in the module mutates a directory unless `CopyQSyncFolder.write` or
`CopyQArchiveWriter` is called explicitly, and the app points the archive
writer only at the path picked in the save panel. When that path is inside a
configured tab sync folder or a Syncthing folder the result says the archive
will sync to the other devices; the export still only creates the chosen
archive file and never modifies or deletes the itemsync files around it. Tests
write only to unique temporary directories; real sync folders and CopyQ config
directories are read as evidence only.
