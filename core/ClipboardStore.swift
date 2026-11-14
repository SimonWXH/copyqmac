// Versioned local storage for clipboard history, tabs, and preferences.
//
// Design notes
// ------------
// * Every flavour of every pasteboard item is stored keyed by its type
//   identifier, so an entry can be written back to the pasteboard exactly as it
//   was captured. Payloads above 1 KiB are zlib compressed at rest in Qt's
//   `qCompress` framing; loading only validates the framing and the bytes are
//   decompressed lazily by `Flavour.data` when a consumer needs them.
// * Search text lives in an FTS5 table with the `trigram` tokenizer, which is
//   what makes substring and CJK queries work. The tokenizer needs at least
//   three characters, so shorter queries fall back to a LIKE scan over the same
//   table; both paths are exercised by the tests.
// * `PRAGMA user_version` carries the schema version. Migrations are linear and
//   forward-only.
//
// This store only ever touches its own database. It never reads or writes
// CopyQ's own data files.

import Foundation

public final class ClipboardStore {
    public static let currentSchemaVersion: Int32 = 9

    /// Flavours larger than this are stored zlib compressed.
    private static let itemDataThreshold = CopyQItemData.itemDataThreshold
    /// Largest payload that may be compressed at rest. It has to match the read
    /// limit, otherwise a stored flavour could not be read back again.
    private static let maximumCompressibleSize = QtCompression.defaultMaximumUncompressedSize

    private var cachedHasCompressedColumn: Bool?
    private var pendingSyncRepairs: [ClipboardEntry] = []

    /// Called with the rows a delete is about to remove.  The clipboard history
    /// installs the sync deletion handler so every user-visible delete path -
    /// single, bulk, confirmed clear tab, marker cleanup - moves owned files to
    /// the app trash before the rows disappear. Tab removal leaves sync files
    /// untouched and does not invoke this callback.
    public var onEntriesWillBeDeleted: (([ClipboardEntry], Preferences?) throws -> Void)?

    /// Called when a written sync stem is removed from durable storage.
    public var onWrittenSyncStemRemoved: ((_ stem: String, _ folder: String) -> Void)?

    private static let entriesBeyondLimit = """
        SELECT id FROM entries
        WHERE pinned = 0 AND tab_id = ?
        ORDER BY position DESC, created_at DESC, id DESC
        LIMIT -1 OFFSET ?
        """

    /// Default bound used for each tab. Pinned entries are never evicted.
    public static let defaultHistoryLimit = Preferences.defaultMaxItems

    /// Name of the tab created on a fresh install. It is stored once, never
    /// retranslated, and is renameable.
    public static let initialTabName = "Clipboard"

    /// Environment override used to keep experiments out of the real store.
    public static let dataDirectoryEnvironmentKey = "COPYQMAC_DATA_DIR"

    let database: SQLiteDatabase

    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try migrate()
    }

    public init(inMemory: Bool = true) throws {
        database = try SQLiteDatabase(inMemory: inMemory)
        try migrate()
    }

    /// Opens the store at the default application-support location, creating
    /// the directory if needed. Honours `COPYQMAC_DATA_DIR` so a test build can
    /// run against a private directory.
    public static func defaultDirectoryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment[dataDirectoryEnvironmentKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let directory = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("CopyQmac", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func defaultURL() throws -> URL {
        let directory = try defaultDirectoryURL()
        return directory.appendingPathComponent("history.sqlite")
    }

    public static func openDefault() throws -> ClipboardStore {
        try ClipboardStore(path: try defaultURL().path)
    }

    // MARK: - Schema

    private func migrate() throws {
        switch database.userVersion {
        case 0:
            try database.transaction {
                try createSchema()
                try seedInitialTab()
                database.userVersion = Self.currentSchemaVersion
            }
        case 1:
            try migrateFromV1()
            try migrateFromV3()
            try migrateFromV4()
            try migrateFromV5()
            try migrateFromV6()
            try migrateFromV7()
            try migrateFromV8()
        case 2:
            try migrateFromV2()
            try migrateFromV3()
            try migrateFromV4()
            try migrateFromV5()
            try migrateFromV6()
            try migrateFromV7()
            try migrateFromV8()
        case 3:
            try migrateFromV3()
            try migrateFromV4()
            try migrateFromV5()
            try migrateFromV6()
            try migrateFromV7()
            try migrateFromV8()
        case 4:
            try migrateFromV4()
            try migrateFromV5()
            try migrateFromV6()
            try migrateFromV7()
            try migrateFromV8()
        case 5:
            try migrateFromV5()
            // A version-5 open may still owe compression work from an
            // interrupted version-4 migration.
            try resumeCompressionMigrationIfNeeded()
            try migrateFromV6()
            try migrateFromV7()
            try migrateFromV8()
        case 6:
            try migrateFromV6()
            try migrateFromV7()
            try migrateFromV8()
        case 7:
            try migrateFromV7()
            try migrateFromV8()
        case 8:
            try migrateFromV8()
        case Self.currentSchemaVersion:
            try resumeCompressionMigrationIfNeeded()
            try reclaimOrphanedWrittenSyncStems()
        case let other:
            throw SQLiteError.open(
                "database schema version \(other) is newer than this build understands (\(Self.currentSchemaVersion))"
            )
        }
        try ensureSyncColumns()
    }

    private func ensureSyncColumns() throws {
        try? database.execute("ALTER TABLE entries ADD COLUMN locally_edited INTEGER NOT NULL DEFAULT 0")
        try? database.execute("ALTER TABLE entries ADD COLUMN last_imported_fingerprint TEXT NOT NULL DEFAULT ''")
        try? database.execute("ALTER TABLE entries ADD COLUMN sync_updated_at REAL NOT NULL DEFAULT 0")
        try? database.execute("ALTER TABLE written_sync_stems ADD COLUMN entry_id INTEGER")
        try? database.execute("ALTER TABLE written_sync_stems ADD COLUMN tab_id INTEGER")
        try ensureEntryPositionColumn()
        try ensureWrittenSyncStemsTable()
    }

    /// Adds the explicit sort key the item list reorders.
    ///
    /// Existing rows are backfilled from `created_at`, so a database that has
    /// never been reordered keeps exactly the newest-first order it had.
    /// Reordering only ever changes `position`, never the creation time a row
    /// displays or the timestamp the sync writer matches against.
    private func ensureEntryPositionColumn() throws {
        if (try? database.execute("ALTER TABLE entries ADD COLUMN position REAL NOT NULL DEFAULT 0")) != nil {
            try database.execute("UPDATE entries SET position = created_at")
        }
        try database.execute("CREATE INDEX IF NOT EXISTS entries_position ON entries(position DESC);")
    }

    private func ensureWrittenSyncStemsTable() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS written_sync_stems (
            stem       TEXT NOT NULL,
            folder     TEXT NOT NULL,
            written_at REAL NOT NULL,
            entry_id   INTEGER,
            tab_id     INTEGER,
            PRIMARY KEY (stem, folder)
        );
        """)
    }

    /// Creates the full current schema. Used for a fresh database.
    private func createSchema() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS tabs (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT    NOT NULL,
            position        INTEGER NOT NULL,
            is_default      INTEGER NOT NULL DEFAULT 0,
            sync_folder     TEXT
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS written_sync_stems (
            stem       TEXT NOT NULL,
            folder     TEXT NOT NULL,
            written_at REAL NOT NULL,
            entry_id   INTEGER,
            tab_id     INTEGER,
            PRIMARY KEY (stem, folder)
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS entries (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at  REAL    NOT NULL,
            position    REAL    NOT NULL DEFAULT 0,
            pinned      INTEGER NOT NULL DEFAULT 0,
            tab_id      INTEGER NOT NULL DEFAULT 0,
            note        TEXT    NOT NULL DEFAULT '',
            locally_edited INTEGER NOT NULL DEFAULT 0,
            last_imported_fingerprint TEXT NOT NULL DEFAULT '',
            sync_updated_at REAL NOT NULL DEFAULT 0,
            fingerprint TEXT    NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS flavours (
            entry_id   INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
            item_index INTEGER NOT NULL,
            type       TEXT    NOT NULL,
            data       BLOB    NOT NULL,
            compressed INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entry_id, item_index, type)
        );
        """)
        // Rowid of the FTS table is the entry id, which keeps search a single
        // indexed lookup and avoids an external-content table.
        try database.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS search_fts
            USING fts5(text, tokenize='trigram');
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS entries_created_at ON entries(created_at DESC);")
        try database.execute("CREATE INDEX IF NOT EXISTS entries_position ON entries(position DESC);")
        try database.execute("CREATE INDEX IF NOT EXISTS entries_pinned ON entries(pinned);")
        try database.execute("CREATE INDEX IF NOT EXISTS entries_tab ON entries(tab_id);")
    }

    /// Upgrades a version-1 database (no tabs, no notes) to the current schema.
    private func migrateFromV1() throws {
        try database.transaction {
            try database.execute("""
            CREATE TABLE IF NOT EXISTS tabs (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                name            TEXT    NOT NULL,
                position        INTEGER NOT NULL,
                is_default      INTEGER NOT NULL DEFAULT 0,
                sync_folder     TEXT,
                sync_write_back INTEGER NOT NULL DEFAULT 0
            );
            """)
            try database.execute("""
            CREATE TABLE IF NOT EXISTS settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
            try database.execute("ALTER TABLE entries ADD COLUMN tab_id INTEGER NOT NULL DEFAULT 0")
            try database.execute("ALTER TABLE entries ADD COLUMN note TEXT NOT NULL DEFAULT ''")
            try database.execute("CREATE INDEX IF NOT EXISTS entries_tab ON entries(tab_id);")
            let tabID = try seedInitialTab()
            try database.execute("UPDATE entries SET tab_id = \(tabID) WHERE tab_id = 0")
            database.userVersion = 3
        }
    }

    private func migrateFromV2() throws {
        try database.transaction {
            try database.execute("ALTER TABLE tabs DROP COLUMN max_items")
            database.userVersion = 3
        }
    }

    /// Rebuilds the search text of file entries.
    ///
    /// File copies used to be indexed as the icon image flavours Finder puts on
    /// the pasteboard with a file URL, so an entry's search row read
    /// "Image 1024x1024 (icns)" instead of the file name. The display was fixed
    /// in `FlavourDecoder`, but the stale rows would otherwise stay unsearchable
    /// by name, so they are recomputed here once.
    private func migrateFromV3() throws {
        let ids = try fileEntryIDs()
        try database.transaction {
            for id in ids {
                guard let entry = try entry(id: id) else { continue }
                try reindexSearchText(entry: entry)
            }
            database.userVersion = 4
        }
    }

    /// Compresses existing flavours larger than item_data_threshold.
    private func migrateFromV4() throws {
        let hasCompressed = try checkHasCompressedColumn()
        if !hasCompressed {
            try database.execute("ALTER TABLE flavours ADD COLUMN compressed INTEGER NOT NULL DEFAULT 0")
            cachedHasCompressedColumn = true
        }
        database.userVersion = 5
        try compressUncompressedFlavours()
    }

    /// Re-resolves dates and re-homes entries imported before an item's date
    /// was taken from the later of its name stamp and its backing file time,
    /// and makes durable echo prevention keyed by sync folder as well as stem.
    ///
    /// Rows are moved to the unique tab that owns their backing folder when it
    /// differs from their current tab. Ambiguous or missing owners, and target
    /// tabs that already hold the same identity or payload, are left untouched
    /// and logged in aggregate. Folder enumeration and row resolution happen
    /// before the write transaction, so an interrupted run rolls back and a
    /// re-run is safe.
    private func migrateFromV5() throws {
        let rows = try syncImportedEntryRows()
        let tabFolders = try syncFolderByTabID()
        let configuredFolders = Set(tabFolders.values)
        var folderStems: [String: [String: Date]] = [:]
        for folder in configuredFolders {
            var stems: [String: Date] = [:]
            for group in CopyQSyncWatcher.findItemGroups(in: folder) {
                stems[group.stem] = group.newestModificationDate
            }
            folderStems[folder] = stems
        }

        struct PendingRepair {
            let id: Int64
            let createdAt: Double
            let tabID: Int64
        }
        var repairs: [PendingRepair] = []
        var noStoredNameCount = 0
        var missingGroupCount = 0
        var ambiguousGroupCount = 0
        var ambiguousOwnerCount = 0
        var duplicateConflictCount = 0
        var dateCorrectedInPlaceCount = 0
        var relocatedCount = 0
        var alreadyCorrectCount = 0
        var ambiguousGroupFolders = Set<String>()
        var ambiguousOwnerFolders = Set<String>()

        var tabsByFolder: [String: [Int64]] = [:]
        for (tabID, folder) in tabFolders {
            tabsByFolder[folder, default: []].append(tabID)
        }

        for row in rows {
            guard let baseName = row.baseName, !baseName.isEmpty else {
                noStoredNameCount += 1
                continue
            }
            let ownFolder = tabFolders[row.tabID]
            let matchingFolders: [String]
            if let ownFolder, folderStems[ownFolder]?[baseName] != nil {
                matchingFolders = [ownFolder]
            } else {
                matchingFolders = configuredFolders.filter { folderStems[$0]?[baseName] != nil }
            }
            if matchingFolders.count > 1 {
                ambiguousGroupCount += 1
                ambiguousGroupFolders.formUnion(matchingFolders)
                continue
            }
            guard let folder = matchingFolders.first,
                  let modified = folderStems[folder]?[baseName]
            else {
                missingGroupCount += 1
                continue
            }
            let owners = tabsByFolder[folder] ?? []
            guard owners.count == 1 else {
                if owners.count > 1 {
                    ambiguousOwnerCount += 1
                    ambiguousOwnerFolders.insert(folder)
                } else {
                    missingGroupCount += 1
                }
                continue
            }
            let ownerTabID = owners[0]
            let resolved = CopyQSyncItem.effectiveTimestamp(
                nameTimestamp: CopyQSyncItem.parseTimestamp(baseName: baseName),
                fileModificationDate: modified
            )
            let resolvedIsLater = resolved.map {
                $0.timeIntervalSince1970 > row.createdAt + 0.001
            } ?? false

            if ownerTabID != row.tabID {
                let rowEntry = try entry(id: row.id)
                let payloadFingerprint = rowEntry.map { Fingerprint.of($0.flavours) }
                let sameIdentity = try entry(withSyncBaseName: baseName, tabID: ownerTabID)
                let samePayload = try payloadFingerprint.flatMap {
                    try entry(withFingerprint: $0, tabID: ownerTabID)
                }
                guard sameIdentity == nil, samePayload == nil else {
                    duplicateConflictCount += 1
                    continue
                }
                repairs.append(PendingRepair(
                    id: row.id,
                    createdAt: resolvedIsLater ? resolved!.timeIntervalSince1970 : row.createdAt,
                    tabID: ownerTabID
                ))
                relocatedCount += 1
            } else if let resolved, resolvedIsLater {
                repairs.append(PendingRepair(
                    id: row.id,
                    createdAt: resolved.timeIntervalSince1970,
                    tabID: row.tabID
                ))
                dateCorrectedInPlaceCount += 1
            } else {
                alreadyCorrectCount += 1
            }
        }

        var repairedIDs: [Int64] = []
        try database.transaction {
            let update = try database.prepare("UPDATE entries SET created_at = ?, tab_id = ? WHERE id = ?")
            defer { update.finalize() }
            for repair in repairs {
                update.reset()
                try update.bind(1, repair.createdAt)
                try update.bind(2, repair.tabID)
                try update.bind(3, repair.id)
                try update.run()
                repairedIDs.append(repair.id)
            }
            try migrateWrittenSyncStemsToCompositeKey()
            database.userVersion = 5
        }

        if !repairedIDs.isEmpty {
            pendingSyncRepairs = try repairedIDs.compactMap { try entry(id: $0) }
        }
        if noStoredNameCount > 0 {
            NSLog(
                "ClipboardStore: left %ld imported entries unchanged: no stored sync file name",
                noStoredNameCount
            )
        }
        if missingGroupCount > 0 {
            NSLog(
                "ClipboardStore: left %ld imported entries unchanged: backing group not found in any configured sync folder",
                missingGroupCount
            )
        }
        if ambiguousGroupCount > 0 {
            NSLog(
                "ClipboardStore: left %ld imported entries unchanged: backing group found in multiple sync folders (%@)",
                ambiguousGroupCount,
                ambiguousGroupFolders.sorted().joined(separator: ", ")
            )
        }
        if ambiguousOwnerCount > 0 {
            NSLog(
                "ClipboardStore: left %ld imported entries unchanged: backing folder claimed by multiple tabs (%@)",
                ambiguousOwnerCount,
                ambiguousOwnerFolders.sorted().joined(separator: ", ")
            )
        }
        if duplicateConflictCount > 0 {
            NSLog(
                "ClipboardStore: left %ld imported entries unchanged: owning tab already has the same sync identity or payload",
                duplicateConflictCount
            )
        }
        NSLog(
            "ClipboardStore: sync repair examined %ld entries: date-corrected in place %ld, relocated %ld, already correct %ld, left unchanged %ld",
            rows.count,
            dateCorrectedInPlaceCount,
            relocatedCount,
            alreadyCorrectCount,
            noStoredNameCount + missingGroupCount + ambiguousGroupCount + ambiguousOwnerCount + duplicateConflictCount
        )
    }

    /// Re-indexes entries whose payload carries JavaScript-style `\uXXXX`
    /// escapes.
    ///
    /// Builds before this one decoded HTML entities but left those escapes in
    /// the preview and search text, so a rich copy from Fedora stayed
    /// searchable by its gibberish (`\u4f55\u6b62...`) instead of the
    /// characters the source app meant. The derivation decodes them now; this
    /// recomputes the rows written by the older build. The stored flavours are
    /// never touched, so paste-back keeps the original markup.
    private func migrateFromV6() throws {
        let ids = try escapedTextEntryIDs()
        try database.transaction {
            for id in ids {
                guard let entry = try entry(id: id) else { continue }
                try reindexSearchText(entry: entry)
            }
            database.userVersion = 7
        }
    }

    /// Ids of entries whose text or markup payload has at least one complete
    /// `\uXXXX` escape. Only those rows can have been indexed differently by an
    /// older build, so the migration stays cheap on a large history.
    private func escapedTextEntryIDs() throws -> [Int64] {
        let types = Array(PasteboardTypes.textTypes) + Array(PasteboardTypes.htmlTypes)
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        let statement = try database.prepare("""
            SELECT DISTINCT entry_id, data, compressed FROM flavours
            WHERE type IN (\(placeholders))
            """)
        defer { statement.finalize() }
        for (offset, type) in types.enumerated() {
            try statement.bind(Int32(offset + 1), type)
        }
        var ids: Set<Int64> = []
        while try statement.step() {
            let id = statement.int64(at: 0)
            guard !ids.contains(id), let raw = statement.data(at: 1) else { continue }
            let data: Data
            if statement.int64(at: 2) == 1 {
                guard let decompressed = try? QtCompression.decompress(raw) else { continue }
                data = decompressed
            } else {
                data = raw
            }
            let text = String(decoding: data, as: UTF8.self)
            if UnicodeEscapeDecoder.decode(text) != text {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }

    /// Retires the per-tab write-back and watch switches.
    ///
    /// A tab used to need two independent switches on top of its sync folder,
    /// which made a half-configured tab possible. Sync is now implied by the
    /// folder: a tab with one always writes and always watches, and a tab
    /// without one never does. The columns are therefore dropped, and existing
    /// rows keep their folder unchanged. Entries also gain the timestamp of the
    /// sync version they currently reflect, which is what lets the newest edit
    /// win instead of a permanent local-edit veto.
    private func migrateFromV7() throws {
        try database.transaction {
            // SQLite's DROP COLUMN support varies with the linked library, so
            // rebuild the table instead. Ids, order, and the capture flag are
            // preserved exactly.
            try database.execute("""
            CREATE TABLE tabs_v8 (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                name            TEXT    NOT NULL,
                position        INTEGER NOT NULL,
                is_default      INTEGER NOT NULL DEFAULT 0,
                sync_folder     TEXT
            );
            """)
            try database.execute("""
            INSERT INTO tabs_v8 (id, name, position, is_default, sync_folder)
            SELECT id, name, position, is_default, sync_folder FROM tabs;
            """)
            try database.execute("DROP TABLE tabs")
            try database.execute("ALTER TABLE tabs_v8 RENAME TO tabs")

            try? database.execute("ALTER TABLE entries ADD COLUMN sync_updated_at REAL NOT NULL DEFAULT 0")
            // A local edit the previous build never wrote to the folder is
            // newer than the row's creation time, so it wins the first
            // comparison after the upgrade instead of being overwritten by an
            // older upstream version. A database older than v7 gains the
            // column after the migrations and cannot hold a pending edit yet.
            if let pendingEdits = try? database.prepare(
                "UPDATE entries SET sync_updated_at = ? WHERE locally_edited = 1"
            ) {
                try pendingEdits.bind(1, Date().timeIntervalSince1970)
                try pendingEdits.run()
                pendingEdits.finalize()
            }
            try database.execute(
                "UPDATE entries SET sync_updated_at = created_at WHERE sync_updated_at = 0"
            )
            try ensureWrittenSyncStemsTable()
            try? database.execute("ALTER TABLE written_sync_stems ADD COLUMN entry_id INTEGER")
            try backfillWrittenStemEntryIDs()
            database.userVersion = 8
        }
    }

    private func migrateFromV8() throws {
        try database.transaction {
            try? database.execute("ALTER TABLE written_sync_stems ADD COLUMN tab_id INTEGER")
            try reclaimOrphanedWrittenSyncStems()
            database.userVersion = 9
        }
    }

    /// Reclaims orphaned written sync stems in mapped sync folders.
    ///
    /// Owned rows (non-null `tab_id`) are never released here: they stop
    /// suppressing when their entry is deleted with sync active, their tab is
    /// deleted, or their folder loses its last mapping, while a paused deletion
    /// keeps the row as a null-entry watermark. Legacy rows without a `tab_id`
    /// are released when their `entry_id` is gone, or, for null-entry rows, when
    /// the folder is readable and content-verified recovery and the proximity
    /// matcher cannot link them. Released stems stop suppressing the folder
    /// files so they can be imported.
    @discardableResult
    public func reclaimOrphanedWrittenSyncStems(folder: String? = nil) throws -> Int {
        let tabFolderMap = try syncFolderByTabID()
        let targetFolders: [String]
        if let folder {
            targetFolders = [CopyQSyncBridge.normalizePath(folder)]
        } else {
            targetFolders = Array(Set(tabFolderMap.values))
        }
        guard !targetFolders.isEmpty else { return 0 }

        var totalReclaimed = 0

        for targetFolder in targetFolders {
            let matchingTabIDs = tabFolderMap.compactMap { $0.value == targetFolder ? $0.key : nil }

            // 1. Release legacy rows whose entry is gone.
            let lostStmt = try database.prepare("""
                SELECT stem FROM written_sync_stems
                WHERE folder = ? AND tab_id IS NULL AND entry_id IS NOT NULL
                  AND entry_id NOT IN (SELECT id FROM entries)
            """)
            defer { lostStmt.finalize() }
            try lostStmt.bind(1, targetFolder)
            var lostStems: [String] = []
            while try lostStmt.step() {
                if let stem = lostStmt.string(at: 0) {
                    lostStems.append(stem)
                }
            }

            if !lostStems.isEmpty {
                let deleteLost = try database.prepare("""
                    DELETE FROM written_sync_stems
                    WHERE folder = ? AND tab_id IS NULL AND entry_id IS NOT NULL
                      AND entry_id NOT IN (SELECT id FROM entries)
                """)
                defer { deleteLost.finalize() }
                try deleteLost.bind(1, targetFolder)
                try deleteLost.run()

                for stem in lostStems {
                    onWrittenSyncStemRemoved?(stem, targetFolder)
                }
                totalReclaimed += lostStems.count
            }

            var isDirectory: ObjCBool = false
            let readable = FileManager.default.fileExists(
                atPath: targetFolder,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
                && FileManager.default.isReadableFile(atPath: targetFolder)
            guard readable else { continue }

            // 2. Legacy unowned rows: link by content or proximity, otherwise release once.
            for tabID in matchingTabIDs {
                CopyQSyncBridge.recoverUnlinkedOwnership(
                    in: self,
                    folder: targetFolder,
                    tabID: tabID
                )
            }
            let nullStmt = try database.prepare("""
                SELECT stem FROM written_sync_stems
                WHERE folder = ? AND tab_id IS NULL AND entry_id IS NULL
            """)
            defer { nullStmt.finalize() }
            try nullStmt.bind(1, targetFolder)
            var nullStems: [String] = []
            while try nullStmt.step() {
                if let stem = nullStmt.string(at: 0) {
                    nullStems.append(stem)
                }
            }

            var unlinkedStemsToReclaim: [String] = []
            for stem in nullStems {
                var linkedEntryID: Int64?
                var linkedTabID: Int64?
                for tabID in matchingTabIDs {
                    let baseNameMatch = try database.prepare("""
                        SELECT e.id FROM entries e
                        JOIN flavours f ON f.entry_id = e.id
                        WHERE e.tab_id = ? AND f.type = ? AND f.data = ?
                        LIMIT 1
                    """)
                    do {
                        defer { baseNameMatch.finalize() }
                        try baseNameMatch.bind(1, tabID)
                        try baseNameMatch.bind(2, Fingerprint.syncBaseNameFlavour)
                        try baseNameMatch.bind(3, Data(stem.utf8))
                        if try baseNameMatch.step() {
                            linkedEntryID = baseNameMatch.int64(at: 0)
                            linkedTabID = tabID
                            break
                        }
                    }

                    if let stemDate = CopyQSyncItem.parseTimestamp(baseName: stem) {
                        let timestamp = stemDate.timeIntervalSince1970
                        let timeMatch = try database.prepare("""
                            SELECT id, created_at FROM entries
                            WHERE tab_id = ? AND created_at BETWEEN ? AND ?
                              AND NOT EXISTS (
                                  SELECT 1 FROM flavours f
                                  WHERE f.entry_id = entries.id AND f.type = ?
                              )
                              AND id NOT IN (
                                  SELECT entry_id FROM written_sync_stems
                                  WHERE folder = ? AND entry_id IS NOT NULL
                              )
                        """)
                        do {
                            defer { timeMatch.finalize() }
                            try timeMatch.bind(1, tabID)
                            try timeMatch.bind(2, timestamp - 1.0)
                            try timeMatch.bind(3, timestamp + 1.0)
                            try timeMatch.bind(4, Fingerprint.syncBaseNameFlavour)
                            try timeMatch.bind(5, targetFolder)
                            var best: (id: Int64, delta: TimeInterval)?
                            while try timeMatch.step() {
                                let id = timeMatch.int64(at: 0)
                                let delta = abs(timeMatch.double(at: 1) - timestamp)
                                if best == nil || delta < best!.delta {
                                    best = (id, delta)
                                }
                            }
                            if let best {
                                linkedEntryID = best.id
                                linkedTabID = tabID
                                break
                            }
                        }
                    }
                }

                if let linkedEntryID {
                    let updateStmt = try database.prepare("""
                        UPDATE written_sync_stems SET entry_id = ?, tab_id = ?
                        WHERE stem = ? AND folder = ? AND tab_id IS NULL AND entry_id IS NULL
                    """)
                    defer { updateStmt.finalize() }
                    try updateStmt.bind(1, linkedEntryID)
                    if let linkedTabID {
                        try updateStmt.bind(2, linkedTabID)
                    } else {
                        try updateStmt.bindNull(2)
                    }
                    try updateStmt.bind(3, stem)
                    try updateStmt.bind(4, targetFolder)
                    try updateStmt.run()
                } else {
                    unlinkedStemsToReclaim.append(stem)
                }
            }

            if !unlinkedStemsToReclaim.isEmpty {
                let deleteNull = try database.prepare("""
                    DELETE FROM written_sync_stems
                    WHERE stem = ? AND folder = ? AND tab_id IS NULL AND entry_id IS NULL
                """)
                defer { deleteNull.finalize() }
                for stem in unlinkedStemsToReclaim {
                    deleteNull.reset()
                    try deleteNull.bind(1, stem)
                    try deleteNull.bind(2, targetFolder)
                    try deleteNull.run()
                    onWrittenSyncStemRemoved?(stem, targetFolder)
                }
                totalReclaimed += unlinkedStemsToReclaim.count
            }
        }
        return totalReclaimed
    }

    /// Links stems written by an older build to the row that owns them.
    ///
    /// Older builds recorded only `(stem, folder)` and resolved the owner by
    /// matching the stem's name stamp with the entry's creation time. That
    /// proximity lookup stops working once a row's creation time is refreshed,
    /// so an edit could allocate a second stem and leave the first group behind.
    /// The best candidate in the owning tab within one second is recorded here;
    /// rows that cannot be matched keep a null link and still use the proximity
    /// fallback.
    private func backfillWrittenStemEntryIDs() throws {
        var tabIDByFolder: [String: Int64] = [:]
        for (tabID, folder) in try syncFolderByTabID() where tabIDByFolder[folder] == nil {
            tabIDByFolder[folder] = tabID
        }
        guard !tabIDByFolder.isEmpty else { return }

        let statement = try database.prepare(
            "SELECT stem, folder FROM written_sync_stems WHERE entry_id IS NULL"
        )
        defer { statement.finalize() }
        var links: [(stem: String, folder: String, entryID: Int64)] = []
        while try statement.step() {
            guard let stem = statement.string(at: 0),
                  let folder = statement.string(at: 1),
                  let tabID = tabIDByFolder[CopyQSyncBridge.normalizePath(folder)],
                  let stemDate = CopyQSyncItem.parseTimestamp(baseName: stem)
            else { continue }

            let candidates = try database.prepare("""
                SELECT id, created_at FROM entries
                WHERE tab_id = ? AND created_at BETWEEN ? AND ?
                  AND NOT EXISTS (
                      SELECT 1 FROM flavours f
                      WHERE f.entry_id = entries.id AND f.type = ?
                  )
                """)
            do {
                defer { candidates.finalize() }
                let timestamp = stemDate.timeIntervalSince1970
                try candidates.bind(1, tabID)
                try candidates.bind(2, timestamp - 1.0)
                try candidates.bind(3, timestamp + 1.0)
                try candidates.bind(4, Fingerprint.syncBaseNameFlavour)
                var best: (id: Int64, delta: TimeInterval)?
                while try candidates.step() {
                    let id = candidates.int64(at: 0)
                    let delta = abs(candidates.double(at: 1) - timestamp)
                    if best == nil || delta < best!.delta {
                        best = (id, delta)
                    }
                }
                if let best {
                    links.append((stem, folder, best.id))
                }
            }
        }

        let update = try database.prepare(
            "UPDATE written_sync_stems SET entry_id = ? WHERE stem = ? AND folder = ?"
        )
        defer { update.finalize() }
        for link in links {
            update.reset()
            try update.bind(1, link.entryID)
            try update.bind(2, link.stem)
            try update.bind(3, link.folder)
            try update.run()
        }
    }

    private struct SyncImportedEntryRow {
        let id: Int64
        let createdAt: Double
        let tabID: Int64
        let baseName: String?
    }

    private func syncFolderByTabID() throws -> [Int64: String] {
        let statement = try database.prepare("SELECT id, sync_folder FROM tabs")
        defer { statement.finalize() }
        var result: [Int64: String] = [:]
        while try statement.step() {
            guard let folder = statement.string(at: 1) else { continue }
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result[statement.int64(at: 0)] = CopyQSyncBridge.normalizePath(trimmed)
        }
        return result
    }

    private func syncImportedEntryRows() throws -> [SyncImportedEntryRow] {
        let statement = try database.prepare("""
            SELECT e.id, e.created_at, e.tab_id, f.data
            FROM entries e JOIN flavours f ON f.entry_id = e.id
            WHERE f.type = ?
            ORDER BY e.id
            """)
        defer { statement.finalize() }
        try statement.bind(1, Fingerprint.syncBaseNameFlavour)
        var rows: [SyncImportedEntryRow] = []
        while try statement.step() {
            let baseName = statement.data(at: 3).flatMap { String(data: $0, encoding: .utf8) }
            rows.append(SyncImportedEntryRow(
                id: statement.int64(at: 0),
                createdAt: statement.double(at: 1),
                tabID: statement.int64(at: 2),
                baseName: baseName
            ))
        }
        return rows
    }

    private func migrateWrittenSyncStemsToCompositeKey() throws {
        let info = try database.prepare("PRAGMA table_info(written_sync_stems)")
        defer { info.finalize() }
        var primaryKeyOrder: [String: Int] = [:]
        while try info.step() {
            let name = info.string(at: 1) ?? ""
            primaryKeyOrder[name] = Int(info.int(at: 5))
        }
        guard !primaryKeyOrder.isEmpty else { return }
        guard primaryKeyOrder["stem"] != 1 || primaryKeyOrder["folder"] != 2 else { return }

        try database.execute("DROP TABLE IF EXISTS written_sync_stems_composite")
        try database.execute("""
            CREATE TABLE written_sync_stems_composite (
                stem       TEXT NOT NULL,
                folder     TEXT NOT NULL,
                written_at REAL NOT NULL,
                PRIMARY KEY (stem, folder)
            );
            """)
        try database.execute("""
            INSERT OR REPLACE INTO written_sync_stems_composite (stem, folder, written_at)
            SELECT stem, folder, written_at FROM written_sync_stems
            """)
        try database.execute("DROP TABLE written_sync_stems")
        try database.execute("ALTER TABLE written_sync_stems_composite RENAME TO written_sync_stems")
    }

    private func resumeCompressionMigrationIfNeeded() throws {
        let hasCompressed = try checkHasCompressedColumn()
        if !hasCompressed {
            try database.execute("ALTER TABLE flavours ADD COLUMN compressed INTEGER NOT NULL DEFAULT 0")
            cachedHasCompressedColumn = true
        }
        try compressUncompressedFlavours()
    }

    private func checkHasCompressedColumn() throws -> Bool {
        if let cached = cachedHasCompressedColumn { return cached }
        let tableInfo = try database.prepare("PRAGMA table_info(flavours)")
        defer { tableInfo.finalize() }
        while try tableInfo.step() {
            if (tableInfo.string(at: 1) ?? "") == "compressed" {
                cachedHasCompressedColumn = true
                return true
            }
        }
        cachedHasCompressedColumn = false
        return false
    }

    private func compressUncompressedFlavours(batchSize: Int = 100) throws {
        var didWork = false
        while true {
            let select = try database.prepare("""
                SELECT entry_id, item_index, type, data FROM flavours
                WHERE compressed = 0 AND length(data) > ?
                LIMIT ?
                """)
            defer { select.finalize() }
            try select.bind(1, Self.itemDataThreshold)
            try select.bind(2, batchSize)

            struct RowToReencode {
                let entryID: Int64
                let itemIndex: Int
                let type: String
                let data: Data
                let compressed: Int64
            }
            var batch: [RowToReencode] = []

            while try select.step() {
                let entryID = select.int64(at: 0)
                let itemIndex = Int(select.int64(at: 1))
                let type = select.string(at: 2) ?? ""
                guard let data = select.data(at: 3) else { continue }
                let form = Self.storageForm(for: data)
                batch.append(RowToReencode(
                    entryID: entryID,
                    itemIndex: itemIndex,
                    type: type,
                    data: form.data,
                    compressed: form.flag
                ))
            }

            if batch.isEmpty { break }

            try database.transaction {
                let update = try database.prepare("""
                    UPDATE flavours SET data = ?, compressed = ?
                    WHERE entry_id = ? AND item_index = ? AND type = ?
                    """)
                defer { update.finalize() }
                for row in batch {
                    update.reset()
                    try update.bind(1, row.data)
                    try update.bind(2, row.compressed)
                    try update.bind(3, row.entryID)
                    try update.bind(4, row.itemIndex)
                    try update.bind(5, row.type)
                    try update.run()
                }
            }
            didWork = true
        }
        // Rewriting the whole file is only worth it when this run compressed or
        // flagged something; the resume path runs on every open.
        if didWork {
            try? database.execute("VACUUM;")
            try? database.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    /// Storage form for one flavour payload: zlib above the compression
    /// threshold when it is small enough to be read back, otherwise raw. The
    /// flag is 0 for raw, 1 for zlib, and 2 for raw payloads that must not be
    /// compressed so the migration does not retry them on every open.
    private static func storageForm(for data: Data) -> (data: Data, flag: Int64) {
        guard data.count > itemDataThreshold else { return (data, 0) }
        guard data.count <= maximumCompressibleSize,
              let compressed = QtCompression.compress(data)
        else {
            return (data, 2)
        }
        return (compressed, 1)
    }

    /// Ids of every entry that carries a file-URL flavour.
    private func fileEntryIDs() throws -> [Int64] {
        let statement = try database.prepare("""
            SELECT DISTINCT entry_id FROM flavours
            WHERE type IN (?, ?)
            """)
        defer { statement.finalize() }
        try statement.bind(1, PasteboardTypes.fileURL)
        try statement.bind(2, PasteboardTypes.legacyFilenames)
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int64(at: 0)) }
        return ids
    }

    /// Recomputes one entry's search row from its current flavours and note.
    ///
    /// The stored plain text is included in addition to the preview text so a
    /// capture that also carries a text flavour stays searchable by that text
    /// even when the preview shows something else, such as an image summary.
    private func reindexSearchText(entry: ClipboardEntry) throws {
        let preview = FlavourDecoder.preview(for: entry.flavours)
        let statement = try database.prepare(
            "INSERT OR REPLACE INTO search_fts (rowid, text) VALUES (?, ?)"
        )
        defer { statement.finalize() }
        try statement.bind(1, entry.id)
        try statement.bind(2, Self.searchBlob(
            preview: preview,
            note: entry.note,
            storedText: FlavourDecoder.storedPlainText(from: entry.flavours)
        ))
        try statement.run()
    }

    /// Inserts the first tab when there is none. Returns its id.
    @discardableResult
    private func seedInitialTab() throws -> Int64 {
        let statement = try database.prepare("SELECT COUNT(*) FROM tabs")
        defer { statement.finalize() }
        let existing = try statement.step() ? statement.int64(at: 0) : 0
        if existing > 0 {
            return try defaultTab()?.id ?? 0
        }
        let insert = try database.prepare("""
            INSERT INTO tabs (name, position, is_default, sync_folder)
            VALUES (?, 1, 1, NULL)
            """)
        defer { insert.finalize() }
        try insert.bind(1, Self.initialTabName)
        try insert.run()
        return database.lastInsertRowID
    }

    // MARK: - Writing

    /// Inserts an entry and its search row. Returns the entry with its assigned id.
    @discardableResult
    public func insert(_ entry: ClipboardEntry) throws -> ClipboardEntry {
        var inserted = entry
        if inserted.tabID == ClipboardTab.unsavedID {
            inserted.tabID = try defaultTab()?.id ?? 0
        }
        try database.transaction {
            let statement = try database.prepare("""
                INSERT INTO entries (created_at, position, pinned, tab_id, note, fingerprint, sync_updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            defer { statement.finalize() }
            try statement.bind(1, entry.createdAt.timeIntervalSince1970)
            try statement.bind(2, entry.createdAt.timeIntervalSince1970)
            try statement.bind(3, entry.pinned)
            try statement.bind(4, inserted.tabID)
            try statement.bind(5, entry.note)
            try statement.bind(6, entry.fingerprint)
            try statement.bind(7, entry.createdAt.timeIntervalSince1970)
            try statement.run()
            inserted.id = database.lastInsertRowID

            try writeFlavours(entry.flavours, for: inserted.id)
            try reindexSearchText(entry: inserted)
        }
        return inserted
    }

    private func writeFlavours(_ flavours: [Flavour], for entryID: Int64) throws {
        let flavourStatement = try database.prepare(
            "INSERT OR REPLACE INTO flavours (entry_id, item_index, type, data, compressed) VALUES (?, ?, ?, ?, ?)"
        )
        defer { flavourStatement.finalize() }
        for flavour in flavours {
            let form: (data: Data, flag: Int64)
            if flavour.isCompressed {
                form = (flavour.rawData, 1)
            } else {
                form = Self.storageForm(for: flavour.data)
            }
            flavourStatement.reset()
            try flavourStatement.bind(1, entryID)
            try flavourStatement.bind(2, flavour.itemIndex)
            try flavourStatement.bind(3, flavour.type)
            try flavourStatement.bind(4, form.data)
            try flavourStatement.bind(5, form.flag)
            try flavourStatement.run()
        }
    }

    /// Replaces the flavour set, fingerprint, and search text of an existing
    /// entry, optionally moves its creation time and updates its note and
    /// pinned state, and can mark it locally edited. A local edit also records
    /// the time of that edit, which is what the newest-wins rule compares
    /// against an upstream group's timestamp.
    public func replaceFlavours(
        of id: Int64,
        with flavours: [Flavour],
        createdAt: Date? = nil,
        locallyEdited: Bool = false,
        editedAt: Date = Date(),
        note: String? = nil,
        pinned: Bool? = nil
    ) throws {
        guard var existing = try entry(id: id) else { return }
        let updatedCreatedAt = createdAt ?? existing.createdAt
        try database.transaction {
            let deleteFlavours = try database.prepare("DELETE FROM flavours WHERE entry_id = ?")
            defer { deleteFlavours.finalize() }
            try deleteFlavours.bind(1, id)
            try deleteFlavours.run()

            try writeFlavours(flavours, for: id)

            let update = try database.prepare("""
                UPDATE entries
                SET fingerprint = ?, created_at = ?, locally_edited = locally_edited OR ?,
                    sync_updated_at = CASE WHEN ? THEN ? ELSE sync_updated_at END,
                    note = COALESCE(?, note), pinned = COALESCE(?, pinned)
                WHERE id = ?
                """)
            defer { update.finalize() }
            try update.bind(1, Fingerprint.of(flavours))
            try update.bind(2, updatedCreatedAt.timeIntervalSince1970)
            try update.bind(3, locallyEdited)
            try update.bind(4, locallyEdited)
            try update.bind(5, editedAt.timeIntervalSince1970)
            if let note {
                try update.bind(6, note)
            } else {
                try update.bindNull(6)
            }
            if let pinned {
                try update.bind(7, pinned)
            } else {
                try update.bindNull(7)
            }
            try update.bind(8, id)
            try update.run()

            existing.flavours = flavours
            existing.createdAt = updatedCreatedAt
            if let note {
                existing.note = note
            }
            if let pinned {
                existing.pinned = pinned
            }
            try reindexSearchText(entry: existing)
        }
    }

    /// Marks the row as a local change that has not reached its sync folder.
    public func markLocalEdit(id: Int64, at date: Date = Date()) throws {
        let statement = try database.prepare(
            "UPDATE entries SET locally_edited = 1, sync_updated_at = ? WHERE id = ?"
        )
        defer { statement.finalize() }
        try statement.bind(1, date.timeIntervalSince1970)
        try statement.bind(2, id)
        try statement.run()
    }

    /// Moves an entry to the top of its tab by refreshing its timestamp.
    public func touch(id: Int64, at date: Date = Date()) throws {
        let statement = try database.prepare("UPDATE entries SET created_at = ?, position = ? WHERE id = ?")
        defer { statement.finalize() }
        try statement.bind(1, date.timeIntervalSince1970)
        try statement.bind(2, date.timeIntervalSince1970)
        try statement.bind(3, id)
        try statement.run()
    }

    public func setPinned(id: Int64, pinned: Bool) throws {
        let statement = try database.prepare("UPDATE entries SET pinned = ? WHERE id = ?")
        defer { statement.finalize() }
        try statement.bind(1, pinned)
        try statement.bind(2, id)
        try statement.run()
    }

    /// Sets the note and refreshes the search row so notes are searchable.
    public func setNote(id: Int64, note: String) throws {
        guard var existing = try entry(id: id) else { return }
        try database.transaction {
            let update = try database.prepare("UPDATE entries SET note = ? WHERE id = ?")
            defer { update.finalize() }
            try update.bind(1, note)
            try update.bind(2, id)
            try update.run()

            existing.note = note
            try reindexSearchText(entry: existing)
        }
    }

    public func delete(id: Int64, propagateSyncDeletion: Bool = true) throws {
        if propagateSyncDeletion,
           let entry = try entry(id: id),
           let onEntriesWillBeDeleted
        {
            try onEntriesWillBeDeleted([entry], nil)
        }
        try database.transaction {
            try deleteRows(selectedBy: "SELECT id FROM entries WHERE id = ?", bindings: [id])
        }
    }

    /// Deletes several entries in one transaction. Ids that no longer exist
    /// are ignored, so a caller working from a snapshot cannot fail on a row
    /// that disappeared meanwhile.
    public func delete(ids: [Int64], propagateSyncDeletion: Bool = true) throws {
        guard !ids.isEmpty else { return }
        if propagateSyncDeletion, let onEntriesWillBeDeleted {
            let victims = try entries(ids: ids)
            if !victims.isEmpty {
                try onEntriesWillBeDeleted(victims, nil)
            }
        }
        try database.transaction {
            try deleteRows(ids: ids)
        }
    }

    public func deleteAll() throws {
        let victimIDs = try recentEntryIDs(limit: Int.max)
        if !victimIDs.isEmpty, let onEntriesWillBeDeleted {
            let victims = try entries(ids: victimIDs)
            if !victims.isEmpty {
                try onEntriesWillBeDeleted(victims, nil)
            }
        }
        try database.transaction {
            try deleteRows(ids: victimIDs)
        }
    }

    public func deleteEntries(tabID: Int64) throws {
        let victimIDs = try recentEntryIDs(limit: Int.max, tabID: tabID)
        if !victimIDs.isEmpty, let onEntriesWillBeDeleted {
            let victims = try entries(ids: victimIDs)
            if !victims.isEmpty {
                try onEntriesWillBeDeleted(victims, nil)
            }
        }
        try database.transaction {
            try deleteRows(ids: victimIDs)
        }
    }

    /// Moves entries into another tab, placing them at the top of the
    /// destination in the order given.
    ///
    /// The rows keep their ids, notes, flavours, and creation times; only
    /// their tab and sort position change. Callers do the sync-folder file
    /// work first, so a failed file move never leaves rows in the wrong tab.
    ///
    /// The destination is re-ranked within its existing position range rather
    /// than above it, so a later capture still sorts above the moved block.
    public func moveEntries(ids: [Int64], toTabID tabID: Int64) throws {
        guard !ids.isEmpty else { return }
        try database.transaction {
            let maxStatement = try database.prepare(
                "SELECT COALESCE(MAX(position), 0) FROM entries WHERE tab_id = ?"
            )
            defer { maxStatement.finalize() }
            try maxStatement.bind(1, tabID)
            let currentTop = try maxStatement.step() ? maxStatement.double(at: 0) : 0

            let moved = Set(ids)
            let order = ids + (try recentEntryIDs(limit: Int.max, tabID: tabID))
                .filter { !moved.contains($0) }
            let base = max(currentTop, Double(order.count))

            let update = try database.prepare(
                "UPDATE entries SET tab_id = ?, position = ? WHERE id = ?"
            )
            defer { update.finalize() }
            for (index, id) in order.enumerated() {
                update.reset()
                try update.bind(1, tabID)
                try update.bind(2, base - Double(index))
                try update.bind(3, id)
                try update.run()
            }
        }
    }

    /// Stores a complete display order for one tab.
    ///
    /// `order` is top to bottom and has to contain every entry the caller
    /// wants ranked. Entries keep their creation time, so a reorder never
    /// changes a row's displayed timestamp or the sync writer's stem match.
    ///
    /// Positions are anchored at the tab's current top rather than packed into
    /// 1..n, which keeps cross-tab search results in roughly chronological
    /// order and lets the next capture land above the reordered block.
    public func reorderEntries(tabID: Int64, order: [Int64]) throws {
        guard !order.isEmpty else { return }
        try database.transaction {
            let maxStatement = try database.prepare(
                "SELECT COALESCE(MAX(position), 0) FROM entries WHERE tab_id = ?"
            )
            defer { maxStatement.finalize() }
            try maxStatement.bind(1, tabID)
            let currentTop = try maxStatement.step() ? maxStatement.double(at: 0) : 0
            let base = max(currentTop, Double(order.count))

            let update = try database.prepare(
                "UPDATE entries SET position = ? WHERE id = ? AND tab_id = ?"
            )
            defer { update.finalize() }
            for (index, id) in order.enumerated() {
                update.reset()
                try update.bind(1, base - Double(index))
                try update.bind(2, id)
                try update.bind(3, tabID)
                try update.run()
            }
        }
    }

    /// Sets or removes the CopyQ sync stem an entry owns.
    ///
    /// Moving an entry between sync folders renames its stem; moving it into a
    /// tab with no folder drops the stem so a later delete cannot claim a file
    /// group that no longer belongs to it. The stored fingerprint is recomputed
    /// because it covers every flavour, including this bookkeeping one.
    public func replaceSyncBaseName(id: Int64, with stem: String?) throws {
        try database.transaction {
            let delete = try database.prepare(
                "DELETE FROM flavours WHERE entry_id = ? AND type = ?"
            )
            defer { delete.finalize() }
            try delete.bind(1, id)
            try delete.bind(2, Fingerprint.syncBaseNameFlavour)
            try delete.run()

            if let stem, !stem.isEmpty {
                let insert = try database.prepare("""
                    INSERT OR REPLACE INTO flavours (entry_id, item_index, type, data, compressed)
                    VALUES (?, 0, ?, ?, 0)
                    """)
                defer { insert.finalize() }
                try insert.bind(1, id)
                try insert.bind(2, Fingerprint.syncBaseNameFlavour)
                try insert.bind(3, Data(stem.utf8))
                try insert.run()
            }

            try refreshFingerprint(of: id)
        }
    }

    /// Drops the oldest unpinned entries in a tab beyond `limit`.
    /// Returns how many were removed.
    @discardableResult
    public func trim(
        tabID: Int64,
        to limit: Int = ClipboardStore.defaultHistoryLimit,
        willDelete: (([Int64]) -> Void)? = nil
    ) throws -> Int {
        let victimIDs = try entriesToTrim(tabID: tabID, to: limit)
        guard !victimIDs.isEmpty else { return 0 }
        if let onEntriesWillBeDeleted {
            let victims = try entries(ids: victimIDs)
            if !victims.isEmpty {
                try onEntriesWillBeDeleted(victims, nil)
            }
        }
        willDelete?(victimIDs)
        try database.transaction {
            try deleteRows(ids: victimIDs)
        }
        return victimIDs.count
    }

    func entriesToTrim(limit: Int) throws -> [Int64] {
        let statement = try database.prepare("SELECT id FROM tabs ORDER BY id")
        defer { statement.finalize() }
        var tabIDs: [Int64] = []
        while try statement.step() { tabIDs.append(statement.int64(at: 0)) }
        var victimIDs: [Int64] = []
        for tabID in tabIDs {
            victimIDs.append(contentsOf: try entriesToTrim(tabID: tabID, to: limit))
        }
        return victimIDs
    }

    private func entriesToTrim(tabID: Int64, to limit: Int) throws -> [Int64] {
        precondition(limit >= 0)
        let count = try database.prepare("SELECT COUNT(*) FROM entries WHERE pinned = 0 AND tab_id = ?")
        defer { count.finalize() }
        try count.bind(1, tabID)
        let unpinnedCount = Int(try count.step() ? count.int64(at: 0) : 0)
        let victimCount = max(0, unpinnedCount - limit)
        guard victimCount > 0 else { return [] }

        let statement = try database.prepare(Self.entriesBeyondLimit)
        defer { statement.finalize() }
        try statement.bind(1, tabID)
        try statement.bind(2, limit)
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int64(at: 0)) }
        return ids
    }

    func deleteRows(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        // One bound variable per id, so stay well below SQLite's variable limit.
        let chunkSize = 500
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + chunkSize, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try deleteRows(
                selectedBy: "SELECT id FROM entries WHERE id IN (\(placeholders))",
                bindings: chunk
            )
            start += chunk.count
        }
    }

    func deleteRows(selectedBy selection: String, bindings: [Int64]) throws {
        let syncPaused = (try? preferences().syncPaused) ?? false
        var removedStems: [(stem: String, folder: String)] = []
        if !syncPaused, onWrittenSyncStemRemoved != nil {
            let stemsStatement = try database.prepare(
                "SELECT stem, folder FROM written_sync_stems WHERE entry_id IN (\(selection))"
            )
            defer { stemsStatement.finalize() }
            for (offset, value) in bindings.enumerated() {
                try stemsStatement.bind(Int32(offset + 1), value)
            }
            while try stemsStatement.step() {
                if let stem = stemsStatement.string(at: 0), let folder = stemsStatement.string(at: 1) {
                    removedStems.append((stem, folder))
                }
            }
        }

        for (table, column) in [
            ("flavours", "entry_id"),
            ("search_fts", "rowid"),
        ] {
            let statement = try database.prepare(
                "DELETE FROM \(table) WHERE \(column) IN (\(selection))"
            )
            defer { statement.finalize() }
            for (offset, value) in bindings.enumerated() {
                try statement.bind(Int32(offset + 1), value)
            }
            try statement.run()
        }

        if syncPaused {
            let statement = try database.prepare("""
                UPDATE written_sync_stems
                SET entry_id = NULL,
                    tab_id = COALESCE(tab_id, (SELECT tab_id FROM entries WHERE entries.id = written_sync_stems.entry_id))
                WHERE entry_id IN (\(selection))
                """)
            defer { statement.finalize() }
            for (offset, value) in bindings.enumerated() {
                try statement.bind(Int32(offset + 1), value)
            }
            try statement.run()
        } else {
            let statement = try database.prepare(
                "DELETE FROM written_sync_stems WHERE entry_id IN (\(selection))"
            )
            defer { statement.finalize() }
            for (offset, value) in bindings.enumerated() {
                try statement.bind(Int32(offset + 1), value)
            }
            try statement.run()
        }

        let entries = try database.prepare("DELETE FROM entries WHERE id IN (\(selection))")
        defer { entries.finalize() }
        for (offset, value) in bindings.enumerated() {
            try entries.bind(Int32(offset + 1), value)
        }
        try entries.run()

        for item in removedStems {
            onWrittenSyncStemRemoved?(item.stem, item.folder)
        }
    }

    // MARK: - Reading

    public func count(tabID: Int64? = nil) throws -> Int {
        let statement: SQLiteStatement
        if let tabID {
            statement = try database.prepare("SELECT COUNT(*) FROM entries WHERE tab_id = ?")
            try statement.bind(1, tabID)
        } else {
            statement = try database.prepare("SELECT COUNT(*) FROM entries")
        }
        defer { statement.finalize() }
        return Int(try statement.step() ? statement.int64(at: 0) : 0)
    }

    /// Entries stored in every tab, counted in one grouped query.
    public func entryCountsByTab() throws -> [Int64: Int] {
        let statement = try database.prepare("SELECT tab_id, COUNT(*) FROM entries GROUP BY tab_id")
        defer { statement.finalize() }
        var counts: [Int64: Int] = [:]
        while try statement.step() {
            counts[statement.int64(at: 0)] = Int(statement.int64(at: 1))
        }
        return counts
    }

    public func pinnedCount(tabID: Int64? = nil) throws -> Int {
        let statement: SQLiteStatement
        if let tabID {
            statement = try database.prepare("SELECT COUNT(*) FROM entries WHERE pinned = 1 AND tab_id = ?")
            try statement.bind(1, tabID)
        } else {
            statement = try database.prepare("SELECT COUNT(*) FROM entries WHERE pinned = 1")
        }
        defer { statement.finalize() }
        return Int(try statement.step() ? statement.int64(at: 0) : 0)
    }

    public func entry(id: Int64) throws -> ClipboardEntry? {
        let statement = try database.prepare("""
            SELECT id, created_at, pinned, tab_id, note FROM entries WHERE id = ?
            """)
        defer { statement.finalize() }
        try statement.bind(1, id)
        guard let row = try readEntryRows(statement).first else { return nil }
        return try makeEntry(row)
    }

    /// Entries in a tab ordered pinned-first, then newest-first.
    public func recentEntries(limit: Int = 200, offset: Int = 0, tabID: Int64? = nil) throws -> [ClipboardEntry] {
        var sql = "SELECT id, created_at, pinned, tab_id, note FROM entries"
        if tabID != nil { sql += " WHERE tab_id = ?" }
        sql += " ORDER BY pinned DESC, position DESC, created_at DESC, id DESC LIMIT ? OFFSET ?"
        let statement = try database.prepare(sql)
        defer { statement.finalize() }
        var index: Int32 = 1
        if let tabID {
            try statement.bind(index, tabID)
            index += 1
        }
        try statement.bind(index, limit)
        try statement.bind(index + 1, offset)
        return try makeEntries(try readEntryRows(statement))
    }

    /// Ids of the entries in a tab, in display order: pinned first, then
    /// newest first, with the id as a tie break so the order is deterministic.
    ///
    /// A backup export needs the order and nothing else up front, and
    /// fetching only ids keeps a whole tab's worth of payloads out of memory
    /// until the entries are actually read, a chunk at a time, by
    /// `entries(ids:)`.
    public func recentEntryIDs(limit: Int = 200, offset: Int = 0, tabID: Int64? = nil) throws -> [Int64] {
        var sql = "SELECT id FROM entries"
        if tabID != nil { sql += " WHERE tab_id = ?" }
        sql += " ORDER BY pinned DESC, position DESC, created_at DESC, id DESC LIMIT ? OFFSET ?"
        let statement = try database.prepare(sql)
        defer { statement.finalize() }
        var index: Int32 = 1
        if let tabID {
            try statement.bind(index, tabID)
            index += 1
        }
        try statement.bind(index, limit)
        try statement.bind(index + 1, offset)
        var ids: [Int64] = []
        while try statement.step() {
            ids.append(statement.int64(at: 0))
        }
        return ids
    }

    /// The entries for `ids`, in the order given.  Ids that no longer exist
    /// are skipped rather than reported, so a backup can keep reading while
    /// the history is trimmed underneath it.
    public func entries(ids: [Int64]) throws -> [ClipboardEntry] {
        guard !ids.isEmpty else { return [] }
        // The flavour query binds one variable per id, so read in bounded
        // chunks well below SQLite's default variable limit.
        let chunkSize = 500
        var result: [ClipboardEntry] = []
        result.reserveCapacity(ids.count)
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + chunkSize, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let statement = try database.prepare("""
                SELECT id, created_at, pinned, tab_id, note FROM entries
                WHERE id IN (\(placeholders))
                """)
            defer { statement.finalize() }
            for (offset, id) in chunk.enumerated() {
                try statement.bind(Int32(offset + 1), id)
            }
            let rows = try readEntryRows(statement)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let ordered = chunk.compactMap { byID[$0] }
            result.append(contentsOf: try makeEntries(ordered))
            start += chunk.count
        }
        return result
    }

    /// Candidate entry for internal marker cleanup: an unpinned entry with no
    /// note and no payload flavours.
    public struct ShellCandidateEntry: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// The entry holds exactly one flavour, which is an internal bookkeeping marker.
            case singleMarker
            /// The entry has zero flavours, or multiple flavours all of which are internal markers.
            case otherPayloadless
        }

        public let id: Int64
        public let kind: Kind

        public init(id: Int64, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    /// Finds candidate shell entries in the specified tab that carry no payload
    /// flavours, protecting pinned entries and entries with notes.
    public func shellCandidateEntries(tabID: Int64) throws -> [ShellCandidateEntry] {
        let statement = try database.prepare("""
            SELECT e.id, f.type
            FROM entries e
            LEFT JOIN flavours f ON f.entry_id = e.id
            WHERE e.tab_id = ? AND e.pinned = 0 AND e.note = ''
            ORDER BY e.id
            """)
        defer { statement.finalize() }
        try statement.bind(1, tabID)

        var currentID: Int64?
        var currentTypes: [String] = []
        var candidates: [ShellCandidateEntry] = []

        func evaluateCurrent() {
            guard let id = currentID else { return }
            let hasPayload = currentTypes.contains { !Fingerprint.isBookkeepingFlavour($0) }
            if !hasPayload {
                let kind: ShellCandidateEntry.Kind = currentTypes.count == 1 ? .singleMarker : .otherPayloadless
                candidates.append(ShellCandidateEntry(id: id, kind: kind))
            }
        }

        while try statement.step() {
            let id = statement.int64(at: 0)
            let type = statement.string(at: 1)
            if id != currentID {
                evaluateCurrent()
                currentID = id
                currentTypes.removeAll(keepingCapacity: true)
            }
            if let type {
                currentTypes.append(type)
            }
        }
        evaluateCurrent()
        return candidates
    }

    /// Id and stored payload fingerprint of the newest entry in a tab.
    ///
    /// Consecutive-duplicate collapsing only needs the fingerprint that was
    /// persisted with the entry, so this deliberately avoids loading (and
    /// decompressing) its flavours.
    public func mostRecentEntryIdentity(tabID: Int64? = nil) throws -> (id: Int64, fingerprint: String)? {
        let statement: SQLiteStatement
        if let tabID {
            statement = try database.prepare("""
                SELECT id, fingerprint FROM entries
                WHERE tab_id = ? ORDER BY created_at DESC LIMIT 1
                """)
            try statement.bind(1, tabID)
        } else {
            statement = try database.prepare("""
                SELECT id, fingerprint FROM entries
                ORDER BY created_at DESC LIMIT 1
                """)
        }
        defer { statement.finalize() }
        guard try statement.step() else { return nil }
        return (statement.int64(at: 0), statement.string(at: 1) ?? "")
    }

    /// Case-insensitive substring search. An empty query returns recent entries.
    /// `tabID` of nil searches every tab.
    public func search(_ query: String, limit: Int = 200, tabID: Int64? = nil) throws -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recentEntries(limit: limit, tabID: tabID) }

        let ids: [Int64]
        if trimmed.count >= 3, let phrase = Self.ftsPhrase(trimmed) {
            ids = try ftsSearch(phrase, limit: limit, tabID: tabID)
        } else {
            ids = try likeSearch(trimmed, limit: limit, tabID: tabID)
        }
        guard !ids.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var sql = """
            SELECT id, created_at, pinned, tab_id, note FROM entries
            WHERE id IN (\(placeholders))
            """
        sql += " ORDER BY pinned DESC, position DESC, created_at DESC, id DESC"
        let statement = try database.prepare(sql)
        defer { statement.finalize() }
        var index: Int32 = 1
        for id in ids {
            try statement.bind(index, id)
            index += 1
        }
        return try makeEntries(try readEntryRows(statement))
    }

    /// Exact content-fingerprint match within a tab, used by tests and
    /// duplicate detection. The fingerprint ignores the sync base-name
    /// bookkeeping flavour, so an imported entry matches rows that predate it.
    public func entry(withFingerprint fingerprint: String, tabID: Int64? = nil) throws -> ClipboardEntry? {
        let statement: SQLiteStatement
        if let tabID {
            statement = try database.prepare("""
                SELECT id, created_at, pinned, tab_id, note FROM entries
                WHERE fingerprint = ? AND tab_id = ? LIMIT 1
                """)
            try statement.bind(1, fingerprint)
            try statement.bind(2, tabID)
        } else {
            statement = try database.prepare("""
                SELECT id, created_at, pinned, tab_id, note FROM entries
                WHERE fingerprint = ? LIMIT 1
                """)
            try statement.bind(1, fingerprint)
        }
        defer { statement.finalize() }
        guard let row = try readEntryRows(statement).first else { return nil }
        return try makeEntry(row)
    }

    /// Returns the entries whose date or tab the one-time sync repair changed.
    ///
    /// The watcher adds them to its import notification list so the open list
    /// reloads with the corrected dates and tabs, even though no new row was
    /// inserted.
    public func takeSyncRepairs() -> [ClipboardEntry] {
        defer { pendingSyncRepairs = [] }
        return pendingSyncRepairs
    }

    /// Read-only lookup of the row carrying a stem's base-name flavour, which
    /// must not adopt a legacy row or change stored flavours merely to find it.
    /// Callers that also accept a locally written stem resolve the owner through
    /// `CopyQSyncBridge.existingOwner`.
    public func entryMatchingSyncStem(
        _ stem: String,
        tabID: Int64
    ) throws -> ClipboardEntry? {
        try entry(withSyncBaseName: stem, tabID: tabID)
    }

    /// Records the version of an entry that the row and its file group now
    /// agree on, after a local write reached the folder or an upstream version
    /// was applied. A pending local-edit marker is cleared at this single
    /// boundary, so the flag only ever means that the row and folder differ.
    public func recordSyncedVersion(id: Int64, date: Date, fingerprint: String) throws {
        let statement = try database.prepare("""
            UPDATE entries
            SET locally_edited = 0, sync_updated_at = ?, last_imported_fingerprint = ?
            WHERE id = ?
            """)
        defer { statement.finalize() }
        try statement.bind(1, date.timeIntervalSince1970)
        try statement.bind(2, fingerprint)
        try statement.bind(3, id)
        try statement.run()
    }

    /// Records the payload fingerprint of the sync file last applied to an
    /// entry without changing the sync version it reflects or its pending
    /// local-edit marker. Used when a file only matches a row by content and
    /// the row does not own that file's stem.
    public func setLastImportedPayloadFingerprint(id: Int64, fingerprint: String) throws {
        let statement = try database.prepare(
            "UPDATE entries SET last_imported_fingerprint = ? WHERE id = ?"
        )
        defer { statement.finalize() }
        try statement.bind(1, fingerprint)
        try statement.bind(2, id)
        try statement.run()
    }

    public func lastImportedPayloadFingerprint(id: Int64) throws -> String {
        let statement = try database.prepare(
            "SELECT last_imported_fingerprint FROM entries WHERE id = ?"
        )
        defer { statement.finalize() }
        try statement.bind(1, id)
        guard try statement.step() else { return "" }
        return statement.string(at: 0) ?? ""
    }

    /// The timestamp of the sync version this entry currently reflects: the
    /// time of the last local write, or the resolved date of the last upstream
    /// version applied. A zero value falls back to the entry's creation time.
    public func syncUpdatedAt(id: Int64) throws -> Date? {
        let statement = try database.prepare("SELECT sync_updated_at FROM entries WHERE id = ?")
        defer { statement.finalize() }
        try statement.bind(1, id)
        guard try statement.step() else { return nil }
        let seconds = statement.double(at: 0)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// True when the entry was edited locally through Item ▸ Edit Item….
    public func isEntryLocallyEdited(id: Int64) throws -> Bool {
        let statement = try database.prepare("SELECT locally_edited FROM entries WHERE id = ?")
        defer { statement.finalize() }
        try statement.bind(1, id)
        guard try statement.step() else { return false }
        return statement.bool(at: 0)
    }

    /// Moves an entry's creation time forward when `date` is later, and
    /// returns the refreshed row.
    public func refreshEntryDate(id: Int64, to date: Date?) throws -> ClipboardEntry? {
        guard let date, let existing = try entry(id: id), date > existing.createdAt else { return nil }
        try touch(id: id, at: date)
        var refreshed = existing
        refreshed.createdAt = date
        return refreshed
    }

    private func refreshFingerprint(of id: Int64) throws {
        guard let updated = try entry(id: id) else { return }
        let update = try database.prepare(
            "UPDATE entries SET fingerprint = ? WHERE id = ?"
        )
        defer { update.finalize() }
        try update.bind(1, Fingerprint.of(updated.flavours))
        try update.bind(2, id)
        try update.run()
    }

    private func entry(withSyncBaseName baseName: String, tabID: Int64) throws -> ClipboardEntry? {
        let statement = try database.prepare("""
            SELECT e.id, e.created_at, e.pinned, e.tab_id, e.note
            FROM entries e JOIN flavours f ON f.entry_id = e.id
            WHERE e.tab_id = ? AND f.type = ? AND f.data = ?
            ORDER BY e.created_at DESC LIMIT 1
            """)
        defer { statement.finalize() }
        try statement.bind(1, tabID)
        try statement.bind(2, Fingerprint.syncBaseNameFlavour)
        try statement.bind(3, Data(baseName.utf8))
        if let row = try readEntryRows(statement).first {
            return try makeEntry(row)
        }

        guard let nameDate = CopyQSyncItem.parseTimestamp(baseName: baseName),
              CopyQSyncBridge.formatTimestamp(nameDate) == baseName
        else { return nil }
        let legacy = try database.prepare("""
            SELECT e.id, e.created_at, e.pinned, e.tab_id, e.note
            FROM entries e
            WHERE e.tab_id = ? AND e.created_at BETWEEN ? AND ?
              AND NOT EXISTS (
                  SELECT 1 FROM flavours f
                  WHERE f.entry_id = e.id AND f.type = ?
              )
            ORDER BY e.id LIMIT 1
            """)
        defer { legacy.finalize() }
        let timestamp = nameDate.timeIntervalSince1970
        try legacy.bind(1, tabID)
        try legacy.bind(2, timestamp - 0.0005)
        try legacy.bind(3, timestamp + 0.0005)
        try legacy.bind(4, Fingerprint.syncBaseNameFlavour)
        guard let row = try readEntryRows(legacy).first else { return nil }
        return try makeEntry(row)
    }

    // MARK: - Internals

    struct EntryRow {
        var id: Int64
        var createdAt: Date
        var pinned: Bool
        var tabID: Int64
        var note: String
    }

    private func readEntryRows(_ statement: SQLiteStatement) throws -> [EntryRow] {
        var rows: [EntryRow] = []
        while try statement.step() {
            rows.append(
                EntryRow(
                    id: statement.int64(at: 0),
                    createdAt: Date(timeIntervalSince1970: statement.double(at: 1)),
                    pinned: statement.bool(at: 2),
                    tabID: statement.int64(at: 3),
                    note: statement.string(at: 4) ?? ""
                )
            )
        }
        return rows
    }

    private func makeEntry(_ row: EntryRow) throws -> ClipboardEntry {
        let flavourMap = try flavours(for: [row.id])
        return ClipboardEntry(
            id: row.id,
            createdAt: row.createdAt,
            pinned: row.pinned,
            tabID: row.tabID,
            note: row.note,
            flavours: flavourMap[row.id] ?? []
        )
    }

    private func makeEntries(_ rows: [EntryRow]) throws -> [ClipboardEntry] {
        let flavourMap = try flavours(for: rows.map(\.id))
        return rows.map { row in
            ClipboardEntry(
                id: row.id,
                createdAt: row.createdAt,
                pinned: row.pinned,
                tabID: row.tabID,
                note: row.note,
                flavours: flavourMap[row.id] ?? []
            )
        }
    }

    private func flavours(for ids: [Int64]) throws -> [Int64: [Flavour]] {
        guard !ids.isEmpty else { return [:] }
        // The version-3 migration reindexes entries before the version-4 step
        // adds the column, so reads have to work without it too.
        let hasCompressed = try checkHasCompressedColumn()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = hasCompressed
            ? "SELECT entry_id, item_index, type, data, compressed FROM flavours WHERE entry_id IN (\(placeholders)) ORDER BY entry_id, item_index, type"
            : "SELECT entry_id, item_index, type, data, 0 FROM flavours WHERE entry_id IN (\(placeholders)) ORDER BY entry_id, item_index, type"
        let statement = try database.prepare(sql)
        defer { statement.finalize() }
        for (offset, id) in ids.enumerated() { try statement.bind(Int32(offset + 1), id) }
        var result: [Int64: [Flavour]] = [:]
        while try statement.step() {
            let entryID = statement.int64(at: 0)
            let itemIndex = Int(statement.int64(at: 1))
            let type = statement.string(at: 2) ?? ""
            let rawData = statement.data(at: 3) ?? Data()
            let isCompressed = statement.int64(at: 4) == 1
            // One damaged row must not make the whole history unreadable: drop
            // the unreadable flavour and keep the entry selectable.
            if isCompressed {
                guard QtCompression.isValid(rawData) else { continue }
            }
            let flavour = Flavour(
                itemIndex: itemIndex,
                type: type,
                rawData: rawData,
                isCompressed: isCompressed
            )
            result[entryID, default: []].append(flavour)
        }
        return result
    }

    private func ftsSearch(_ phrase: String, limit: Int, tabID: Int64?) throws -> [Int64] {
        var sql = """
            SELECT search_fts.rowid FROM search_fts
            JOIN entries ON entries.id = search_fts.rowid
            WHERE search_fts MATCH ?
            """
        if tabID != nil { sql += " AND entries.tab_id = ?" }
        sql += " ORDER BY entries.pinned DESC, entries.position DESC, entries.created_at DESC LIMIT ?"
        let statement = try database.prepare(sql)
        defer { statement.finalize() }
        try statement.bind(1, phrase)
        if let tabID { try statement.bind(2, tabID) }
        try statement.bind(tabID == nil ? 2 : 3, limit)
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int64(at: 0)) }
        return ids
    }

    private func likeSearch(_ query: String, limit: Int, tabID: Int64?) throws -> [Int64] {
        // Escape LIKE wildcards so a query containing % or _ stays a literal.
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        var sql = """
            SELECT search_fts.rowid FROM search_fts
            JOIN entries ON entries.id = search_fts.rowid
            WHERE search_fts.text LIKE ? ESCAPE '\\'
            """
        if tabID != nil { sql += " AND entries.tab_id = ?" }
        sql += " ORDER BY entries.pinned DESC, entries.position DESC, entries.created_at DESC LIMIT ?"
        let statement = try database.prepare(sql)
        defer { statement.finalize() }
        try statement.bind(1, "%\(escaped)%")
        if let tabID { try statement.bind(2, tabID) }
        try statement.bind(tabID == nil ? 2 : 3, limit)
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int64(at: 0)) }
        return ids
    }

    /// Wraps a user query as an FTS5 phrase, doubling embedded quotes. Returns
    /// nil when the query is only FTS syntax that would otherwise error.
    static func ftsPhrase(_ query: String) -> String? {
        let stripped = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        let escaped = stripped.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// The text indexed for search: the content text, any stored plain text
    /// the preview does not already represent, plus the note.
    static func searchBlob(preview: EntryPreview, note: String, storedText: String? = nil) -> String {
        var content = FlavourDecoder.searchText(for: preview)
        if let storedText, !storedText.isEmpty, storedText != content {
            content = content.isEmpty ? storedText : "\(content)\n\(storedText)"
        }
        let maximumLength = FlavourDecoder.maxSearchTextLength
        if content.count > maximumLength {
            content = String(content.prefix(maximumLength))
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else { return content }

        let indexedNote = String(trimmedNote.prefix(maximumLength))
        let separator = content.isEmpty ? "" : "\n"
        let contentLength = max(0, maximumLength - indexedNote.count - separator.count)
        let indexedContent = String(content.prefix(contentLength))
        guard !indexedContent.isEmpty else { return indexedNote }
        return "\(indexedContent)\n\(indexedNote)"
    }

    // MARK: - Written Sync Stems

    /// Records a stem written by this application into a sync folder, preventing echo loops.
    /// `entryID` is the row the stem belongs to. A stem recorded for a live
    /// entry is owned by the tab that maps the folder at write time, so tab
    /// deletion removes it and orphan reclaim never releases it. A stem whose
    /// entry cannot be resolved, or whose folder no tab maps, stays unowned for
    /// the legacy release rule.
    public func recordWrittenSyncStem(
        _ stem: String,
        folder: String,
        entryID: Int64? = nil
    ) throws {
        let owningTabID = try syncOwningTabID(forFolder: folder, entryID: entryID)
        let statement = try database.prepare("""
            INSERT OR REPLACE INTO written_sync_stems (stem, folder, written_at, entry_id, tab_id)
            VALUES (?, ?, ?, ?, ?)
            """)
        defer { statement.finalize() }
        try statement.bind(1, stem)
        try statement.bind(2, CopyQSyncBridge.normalizePath(folder))
        try statement.bind(3, Date().timeIntervalSince1970)
        if let entryID {
            try statement.bind(4, entryID)
        } else {
            try statement.bindNull(4)
        }
        if let owningTabID {
            try statement.bind(5, owningTabID)
        } else {
            try statement.bindNull(5)
        }
        try statement.run()
    }

    private func syncOwningTabID(forFolder folder: String, entryID: Int64?) throws -> Int64? {
        guard let entryID else { return nil }
        let lookup = try database.prepare("SELECT tab_id FROM entries WHERE id = ?")
        defer { lookup.finalize() }
        try lookup.bind(1, entryID)
        guard try lookup.step() else { return nil }
        let entryTabID = lookup.int64(at: 0)

        let normalized = CopyQSyncBridge.normalizePath(folder)
        let mapping = try database.prepare("SELECT id, sync_folder FROM tabs")
        defer { mapping.finalize() }
        var firstMappedTabID: Int64?
        while try mapping.step() {
            guard let raw = mapping.string(at: 1) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  CopyQSyncBridge.normalizePath(trimmed) == normalized else { continue }
            let mappedTabID = mapping.int64(at: 0)
            if mappedTabID == entryTabID {
                return entryTabID
            }
            if firstMappedTabID == nil {
                firstMappedTabID = mappedTabID
            }
        }
        return firstMappedTabID
    }

    /// Every stem this application recorded for `entryID` in `folder`, in a
    /// stable order. An entry can own more than one while duplicate groups
    /// converge.
    public func writtenSyncStems(forEntryID entryID: Int64, folder: String) throws -> [String] {
        let statement = try database.prepare(
            "SELECT stem FROM written_sync_stems WHERE entry_id = ? AND folder = ? ORDER BY stem"
        )
        defer { statement.finalize() }
        try statement.bind(1, entryID)
        try statement.bind(2, CopyQSyncBridge.normalizePath(folder))
        var stems: [String] = []
        while try statement.step() {
            guard let stem = statement.string(at: 0), !stem.isEmpty else { continue }
            stems.append(stem)
        }
        return stems
    }

    /// Legacy written stems in `folder` that have no recorded owner or tab yet.
    public func writtenSyncStemsWithoutOwner(folder: String) throws -> [String] {
        let statement = try database.prepare("""
            SELECT stem FROM written_sync_stems
            WHERE entry_id IS NULL AND tab_id IS NULL AND folder = ?
            ORDER BY stem
            """)
        defer { statement.finalize() }
        try statement.bind(1, CopyQSyncBridge.normalizePath(folder))
        var stems: [String] = []
        while try statement.step() {
            guard let stem = statement.string(at: 0), !stem.isEmpty else { continue }
            stems.append(stem)
        }
        return stems
    }

    /// The exact stem this application wrote for `entryID` into `folder`, if it
    /// still owns one. This is more reliable than matching the entry's creation
    /// time, which a refresh can move away from the stem's name stamp.
    public func writtenSyncStem(forEntryID entryID: Int64, folder: String) throws -> String? {
        let statement = try database.prepare(
            "SELECT stem FROM written_sync_stems WHERE entry_id = ? AND folder = ? LIMIT 1"
        )
        defer { statement.finalize() }
        try statement.bind(1, entryID)
        try statement.bind(2, CopyQSyncBridge.normalizePath(folder))
        guard try statement.step() else { return nil }
        return statement.string(at: 0)
    }

    /// The entry that owns a stem this application wrote into `folder`, if any.
    public func entryID(forWrittenSyncStem stem: String, folder: String) throws -> Int64? {
        let statement = try database.prepare(
            "SELECT entry_id FROM written_sync_stems WHERE stem = ? AND folder = ? AND entry_id IS NOT NULL LIMIT 1"
        )
        defer { statement.finalize() }
        try statement.bind(1, stem)
        try statement.bind(2, CopyQSyncBridge.normalizePath(folder))
        guard try statement.step() else { return nil }
        return statement.int64(at: 0)
    }

    /// Forgets a stem this app wrote, after its group is removed from the
    /// folder, so a restored group can be imported again.
    public func removeWrittenSyncStem(_ stem: String, folder: String) throws {
        let normalized = CopyQSyncBridge.normalizePath(folder)
        let statement = try database.prepare(
            "DELETE FROM written_sync_stems WHERE stem = ? AND folder = ?"
        )
        defer { statement.finalize() }
        try statement.bind(1, stem)
        try statement.bind(2, normalized)
        try statement.run()
        onWrittenSyncStemRemoved?(stem, normalized)
    }

    /// Checks whether this application wrote `stem` into `folder`.
    ///
    /// Echo prevention is scoped per folder: the same stem can legitimately
    /// appear in two different sync folders, and a stem written into one folder
    /// must never suppress importing the other folder's group.
    public func isWrittenSyncStem(_ stem: String, folder: String) throws -> Bool {
        let statement = try database.prepare(
            "SELECT 1 FROM written_sync_stems WHERE stem = ? AND folder = ? LIMIT 1"
        )
        defer { statement.finalize() }
        try statement.bind(1, stem)
        try statement.bind(2, CopyQSyncBridge.normalizePath(folder))
        return try statement.step()
    }

    /// Returns every stem written by this application, grouped by sync folder.
    public func allWrittenSyncStemsByFolder() throws -> [String: Set<String>] {
        let statement = try database.prepare("SELECT stem, folder FROM written_sync_stems")
        defer { statement.finalize() }
        var result: [String: Set<String>] = [:]
        while try statement.step() {
            guard let stem = statement.string(at: 0), let folder = statement.string(at: 1) else { continue }
            result[CopyQSyncBridge.normalizePath(folder), default: []].insert(stem)
        }
        return result
    }

    /// Resolves the stem written into `folder` for an entry created at `date`.
    public func writtenSyncStem(matching date: Date, folder: String) throws -> String? {
        let expectedStem = CopyQSyncBridge.formatTimestamp(date)
        if try isWrittenSyncStem(expectedStem, folder: folder) {
            return expectedStem
        }
        let statement = try database.prepare(
            "SELECT stem FROM written_sync_stems WHERE folder = ?"
        )
        defer { statement.finalize() }
        try statement.bind(1, CopyQSyncBridge.normalizePath(folder))
        let targetTimestamp = date.timeIntervalSince1970
        var bestStem: String?
        var smallestDelta: TimeInterval = 1.0
        while try statement.step() {
            guard let stem = statement.string(at: 0),
                  let stemDate = CopyQSyncItem.parseTimestamp(baseName: stem)
            else { continue }
            let delta = abs(stemDate.timeIntervalSince1970 - targetTimestamp)
            if delta < smallestDelta {
                smallestDelta = delta
                bestStem = stem
            }
        }
        return bestStem
    }

}
