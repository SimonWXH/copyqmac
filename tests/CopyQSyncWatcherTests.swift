// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncWatcherTests.swift
//
// Tests for Stage 2b CopyQ sync folder watcher: FSEvents watching, group completeness and stability,
// durable echo prevention, duplicate skipping, non-destructive file handling, burst handling,
// and pause/resume gating.

import Foundation

func registerCopyQSyncWatcherTests() {
    TestRunner.currentSuite = "CopyQSyncWatcher"

    func createTempDirectory(prefix: String) -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    func makeLegacyDatabase(at path: String, extraSchemaAndRows: String) throws {
        let rawDB = try SQLiteDatabase(path: path)
        rawDB.userVersion = 5
        try rawDB.execute("""
        CREATE TABLE tabs (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT    NOT NULL,
            position        INTEGER NOT NULL,
            is_default      INTEGER NOT NULL DEFAULT 0,
            sync_folder     TEXT,
            sync_write_back INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE entries (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at REAL, pinned INTEGER, tab_id INTEGER, note TEXT, fingerprint BLOB);
        CREATE TABLE flavours (entry_id INTEGER, item_index INTEGER, type TEXT, data BLOB, compressed INTEGER, PRIMARY KEY (entry_id, item_index, type));
        CREATE VIRTUAL TABLE search_fts USING fts5(text, tokenize='trigram');
        """)
        try rawDB.execute(extraSchemaAndRows)
        try rawDB.execute("""
        INSERT INTO tabs (name, position, is_default, sync_folder, sync_write_back)
        VALUES ('Archive', 0, 1, '/path/to/Archive', 1);
        INSERT INTO tabs (name, position, is_default, sync_folder, sync_write_back)
        VALUES ('Fedora', 1, 0, '/path/to/Fedora', 0);
        """)
    }

    TestRunner.add("a new group in a watched folder imports exactly once") {
        let tempDir = createTempDirectory(prefix: "copyq-watch-once")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "TestWatch",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000001"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Hello incoming sync".utf8).write(to: txtFile)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0

        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report.importedCount, 1, "exactly one group should be imported")
        expectEqual(report.duplicateCount, 0, "no duplicates on first import")

        let entries = try store.recentEntries(tabID: tab.id)
        expectEqual(entries.count, 1, "store should contain one entry")
        expectEqual(FlavourDecoder.plainText(from: entries.first?.flavours ?? []), "Hello incoming sync", "imported content must match")
    }

    TestRunner.add("a second scan imports nothing") {
        let tempDir = createTempDirectory(prefix: "copyq-second-scan")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "SecondScan",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000002"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Repeat scan item".utf8).write(to: txtFile)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0

        let report1 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report1.importedCount, 1, "first scan imports 1")

        guard let before = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("first scan stored no entry")
            return
        }
        let beforeFingerprint = before.fingerprint
        let beforeCreatedAt = before.createdAt

        let report2 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report2.importedCount, 0, "second scan must import 0")
        expectEqual(report2.updatedCount, 0, "an unchanged file must not update the entry")
        expectEqual(report2.duplicateCount, 1, "second scan must count 1 duplicate")

        let count = try store.count(tabID: tab.id)
        expectEqual(count, 1, "store must still have exactly 1 entry")
        let after = try store.entry(id: before.id)
        expectEqual(after?.fingerprint, beforeFingerprint, "the entry must keep its payload")
        expectEqual(
            after?.createdAt.timeIntervalSince1970 ?? 0,
            beforeCreatedAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the entry must keep its creation time"
        )
    }

    TestRunner.add("an upstream content change updates the entry in place") {
        let tempDir = createTempDirectory(prefix: "copyq-upstream-rewrite")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "RewriteTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_custom_rewrite"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(120)

        try Data("alpha".utf8).write(to: txtFile)
        try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: txtFile.path)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report1 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report1.importedCount, 1)

        guard let imported = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("first scan stored no entry")
            return
        }

        try Data("beta".utf8).write(to: txtFile)
        try FileManager.default.setAttributes([.modificationDate: secondDate], ofItemAtPath: txtFile.path)

        let report2 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report2.importedCount, 0, "an upstream rewrite must not add a row")
        expectEqual(report2.updatedCount, 1, "the newer upstream content is applied in place")
        expectEqual(report2.duplicateCount, 0)
        expectEqual(try store.count(tabID: tab.id), 1, "the row count stays unchanged")

        guard let stored = try store.entry(id: imported.id) else {
            TestRunner.fail("the imported entry disappeared")
            return
        }
        expectEqual(FlavourDecoder.storedPlainText(from: stored.flavours), "beta")
        expectEqual(
            stored.createdAt.timeIntervalSince1970,
            secondDate.timeIntervalSince1970,
            accuracy: 0.001,
            "the creation time is refreshed to the rewritten file's time"
        )

        let report3 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report3.updatedCount, 0, "a further unchanged scan must not update again")
        expectEqual(report3.duplicateCount, 1)
    }

    TestRunner.add("a newer upstream edit replaces an older local edit and logs what was discarded") {
        let tempDir = createTempDirectory(prefix: "copyq-local-edit-rewrite")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "LocalEditTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000082"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("alpha".utf8).write(to: txtFile)
        try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: txtFile.path)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report1 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report1.importedCount, 1)

        guard let localEntry = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("first scan stored no entry")
            return
        }
        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: localEntry.id, with: "alpha beta")

        let logPath = tempDir.appendingPathComponent("sync.log").path
        CopyQSyncWriter.shared.customLogFilePath = logPath
        defer { CopyQSyncWriter.shared.customLogFilePath = nil }

        let laterDate = Date(timeIntervalSinceNow: 60)
        try Data("gamma".utf8).write(to: txtFile)
        try FileManager.default.setAttributes([.modificationDate: laterDate], ofItemAtPath: txtFile.path)

        let report2 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report2.importedCount, 0)
        expectEqual(report2.updatedCount, 1, "the newer upstream edit wins")
        expectEqual(report2.skippedUpstreamCount, 0)
        expectEqual(try store.count(tabID: tab.id), 1, "one entry remains for the stem")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: localEntry.id)?.flavours ?? []),
            "gamma"
        )
        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        expect(log.contains("local-edit-replaced"), "the replaced local edit is written to the sync log")
        expect(!log.contains("alpha beta"), "the log does not carry the discarded payload text")
        expect(log.contains("sha256="), "the log carries a payload summary")

        let report3 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report3.importedCount, 0)
        expectEqual(report3.updatedCount, 0, "a repeated scan does not apply the same version twice")
        expectEqual(report3.duplicateCount, 0)
        expectEqual(report3.skippedWrittenByUsCount, 1, "the now-current group is our own write")
    }

    TestRunner.add("watcher skips a natively captured entry already in the tab") {
        let tempDir = createTempDirectory(prefix: "copyq-watch-native-dedupe")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        var tab = try store.insertTab(ClipboardTab(
            name: "NativeDedupe"
        ))
        try store.insert(ClipboardEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_001_000),
            tabID: tab.id,
            flavours: [Fixtures.text("native watcher text")]
        ))
        _ = try CopyQSyncBridge.dryRunExport(tabID: tab.id, in: store, into: tempDir.path)

        tab.syncFolder = tempDir.path
        try store.updateTab(tab)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.importedCount, 0, "watcher skips the native duplicate")
        expectEqual(report.duplicateCount, 1, "watcher reports the native duplicate")
        expectEqual(try store.count(tabID: tab.id), 1, "watcher does not grow the tab")
    }

    TestRunner.add("watcher scan that skips unsettled groups does no whole-tab fingerprint work") {
        let tempDir = createTempDirectory(prefix: "copyq-watch-lazy-scan")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "LazyScan",
            syncFolder: tempDir.path
        ))
        try store.insert(ClipboardEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_001_200),
            tabID: tab.id,
            flavours: [Fixtures.text("existing watcher entry")]
        ))

        let stem = "copyq_20261025120000001"
        try Data("unsettled".utf8).write(to: tempDir.appendingPathComponent("\(stem).txt"))

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 10
        FingerprintProbe.reset()
        let report = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 10
        )
        expectEqual(report.unsettledCount, 1, "the group is skipped as unsettled")
        expectEqual(FingerprintProbe.count, 0, "skipped groups do not hash the tab")
    }

    TestRunner.add("a group we wrote ourselves is not imported back (echo loop prevention)") {
        let tempDir = createTempDirectory(prefix: "copyq-echo-prevent")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "EchoTab",
            syncFolder: tempDir.path
        ))
        let prefs = try store.preferences()
        try store.setPreferences(prefs)

        let entry = ClipboardEntry(
            createdAt: Date(),
            pinned: false,
            tabID: tab.id,
            note: "macOS local note",
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Mac written content".utf8))
            ]
        )
        try store.insert(entry)

        // Write to folder via CopyQSyncWriter
        let writer = CopyQSyncWriter.shared
        let log = try writer.writeEntry(entry, in: store, reason: "capture")
        expect(log != nil, "writeEntry must succeed")
        let writtenStem = log?.stem
        expect(writtenStem != nil, "stem must be resolved")

        guard let stem = writtenStem else { return }

        // Verify stem is recorded durably in SQLite and in watcher memory
        expect(try store.isWrittenSyncStem(stem, folder: tempDir.path), "store must record written stem durably")
        expect(CopyQSyncWatcher.shared.isWrittenByUs(stem, folder: tempDir.path), "watcher must remember written stem in memory")

        // Now run watcher scan over the directory
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)

        expectEqual(report.importedCount, 0, "must not re-import our own written group")
        expectEqual(report.skippedWrittenByUsCount, 1, "must record that stem was skipped as written by us")

        // Simulate app restart: new watcher instance starting from store
        let restartedWatcher = CopyQSyncWatcher(store: store)
        restartedWatcher.settleDelay = 0
        expect(restartedWatcher.isWrittenByUs(stem, folder: tempDir.path), "restarted watcher must have loaded durable stems automatically")

        let restartReport = try restartedWatcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(restartReport.importedCount, 0, "restart scan must still ignore our own write")
        expectEqual(restartReport.skippedWrittenByUsCount, 1, "restart scan must skip stem written by us")
    }

    TestRunner.add("a partially written group is not imported until complete") {
        let tempDir = createTempDirectory(prefix: "copyq-partial-group")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "PartialTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000004"
        let noteFile = tempDir.appendingPathComponent("\(stem)_note.txt")
        // Only a note file - no container and no text file
        try Data("Only a note".utf8).write(to: noteFile)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0

        // Attempt scan: should not be imported
        let report1 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report1.importedCount, 0, "incomplete group (note only) must not import")
        expectEqual(report1.incompleteCount, 1, "must report 1 incomplete group")
        expectEqual(try store.count(tabID: tab.id), 0, "no entries in store yet")

        // Now add a temporary syncthing file for another stem
        let stem2 = "copyq_20261025120000005"
        let txt2 = tempDir.appendingPathComponent("\(stem2).txt")
        let tmp2 = tempDir.appendingPathComponent(".syncthing.\(stem2).txt.tmp")
        try Data("Text 2".utf8).write(to: txt2)
        try Data("in flight".utf8).write(to: tmp2)

        let report2 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report2.importedCount, 0, "group with temporary sync file must not import")

        // Remove temporary file and complete the first group
        try FileManager.default.removeItem(at: tmp2)
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Completed text for group 1".utf8).write(to: txtFile)

        // Now scan again
        let report3 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report3.importedCount, 2, "both completed groups must now import")

        let entries = try store.recentEntries(tabID: tab.id)
        expectEqual(entries.count, 2, "store must contain both completed items")
    }

    TestRunner.add("a deleted file removes its entry only after a settled rescan") {
        let tempDir = createTempDirectory(prefix: "copyq-delete-file")
        let trashDir = createTempDirectory(prefix: "copyq-delete-file-trash")
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: trashDir)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "DeleteSafetyTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000006"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Protected entry content".utf8).write(to: txtFile)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0.05
        watcher.trashRoot = trashDir

        _ = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(try store.count(tabID: tab.id), 1, "entry imported")

        // Delete the file from the filesystem
        try FileManager.default.removeItem(at: txtFile)
        expect(!FileManager.default.fileExists(atPath: txtFile.path), "file was deleted from disk")

        // The absent scan only records the candidate.
        let missing = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0.05
        )
        expectEqual(missing.remoteDeletedCount, 0)
        expectEqual(missing.pendingRemoteDeletionCount, 1)
        expectEqual(try store.count(tabID: tab.id), 1, "entry stays until the settled rescan")

        Thread.sleep(forTimeInterval: 0.12)
        let settled = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0.05
        )
        expectEqual(settled.remoteDeletedCount, 1, "the settled rescan removes the entry")
        expectEqual(try store.count(tabID: tab.id), 0)
    }

    TestRunner.add("a burst of N groups imports all of them without blocking") {
        let tempDir = createTempDirectory(prefix: "copyq-burst-test")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "BurstTab",
            syncFolder: tempDir.path
        ))

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        watcher.debounceInterval = 0.05

        let burstCount = 60
        let start = Date()

        for i in 1...burstCount {
            let stem = String(format: "copyq_burst_%04d", i)
            let txtFile = tempDir.appendingPathComponent("\(stem).txt")
            try Data("Burst item \(i) payload".utf8).write(to: txtFile)
        }

        let writeElapsed = Date().timeIntervalSince(start)
        expect(writeElapsed < 1.0, "writing 60 files must be rapid")

        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report.importedCount, burstCount, "all 60 burst items must be imported")

        let count = try store.count(tabID: tab.id)
        expectEqual(count, burstCount, "store must contain all 60 entries")
    }

    TestRunner.add("global pause sync stops watching and resume sync catches up") {
        let tempDir = createTempDirectory(prefix: "copyq-pause-watch")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "PauseWatchTab",
            syncFolder: tempDir.path
        ))

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        watcher.start(store: store)
        expect(watcher.isRunning, "watcher must run when started unpaused")

        // Pause sync globally
        var prefs = try store.preferences()
        prefs.syncPaused = true
        try store.setPreferences(prefs)

        // Write an item
        let stem = "copyq_20261025120000007"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Item while paused".utf8).write(to: txtFile)

        // Updating configuration while paused stops stream and scans
        watcher.updateConfiguration(store: store)
        expect(!watcher.isRunning, "watcher must not run while syncPaused is true")

        // Unpause sync
        prefs.syncPaused = false
        try store.setPreferences(prefs)
        watcher.updateConfiguration(store: store)
        expect(watcher.isRunning, "watcher must resume running when sync unpaused")

        // The resume scan may already have imported the item before this
        // explicit scan runs, so assert the observable outcome, not which scan
        // won the race.
        _ = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(try store.count(tabID: tab.id), 1, "item imported exactly once after sync resumes")

        watcher.stop()
        expect(!watcher.isRunning, "watcher must not run after stop")
    }

    TestRunner.add("every tab with a sync folder is watched") {
        let tempDirA = createTempDirectory(prefix: "copyq-tab-a")
        let tempDirB = createTempDirectory(prefix: "copyq-tab-b")
        defer {
            try? FileManager.default.removeItem(at: tempDirA)
            try? FileManager.default.removeItem(at: tempDirB)
        }

        let store = try ClipboardStore(inMemory: true)
        let tabA = try store.insertTab(ClipboardTab(
            name: "TabA",
            syncFolder: tempDirA.path
        ))
        let tabB = try store.insertTab(ClipboardTab(
            name: "TabB",
            syncFolder: tempDirB.path
        ))

        let stemA = "copyq_20261025120000008"
        try Data("Folder A content".utf8).write(to: tempDirA.appendingPathComponent("\(stemA).txt"))

        let stemB = "copyq_20261025120000009"
        try Data("Folder B content".utf8).write(to: tempDirB.appendingPathComponent("\(stemB).txt"))

        let watcher = CopyQSyncWatcher(store: store)
        defer { watcher.stop() }
        watcher.settleDelay = 0
        watcher.start(store: store)

        // Both folders are registered, because a folder alone enables sync.
        _ = try watcher.scanFolder(atPath: tempDirA.path, intoTabID: tabA.id, in: store, settleDelayOverride: 0)
        _ = try watcher.scanFolder(atPath: tempDirB.path, intoTabID: tabB.id, in: store, settleDelayOverride: 0)
        expectEqual(try store.count(tabID: tabA.id), 1, "tab A imports from its folder")
        expectEqual(try store.count(tabID: tabB.id), 1, "tab B imports from its folder")
    }

    TestRunner.add("a tab with a sync folder is bidirectional without switches") {
        let tempDir = createTempDirectory(prefix: "copyq-bidirectional")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "Fedora",
            syncFolder: tempDir.path
        ))

        var prefs = try store.preferences()
        prefs.syncPaused = false
        try store.setPreferences(prefs)

        // 1. Inbound sync: an external item arrives in the folder.
        let stem = "copyq_20261025120000010"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Fedora copied item".utf8).write(to: txtFile)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report.importedCount, 1, "the tab imports incoming items")

        let entries = try store.recentEntries(tabID: tab.id)
        expectEqual(entries.count, 1, "store must contain imported entry")
        expectEqual(FlavourDecoder.plainText(from: entries.first?.flavours ?? []), "Fedora copied item")

        // 2. Outbound sync: a local entry in this tab is written back.
        let localEntry = ClipboardEntry(
            createdAt: Date(),
            pinned: false,
            tabID: tab.id,
            flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Local text".utf8))]
        )
        let inserted = try store.insert(localEntry)

        let writerLog = try CopyQSyncWriter.shared.writeEntry(inserted, in: store, reason: "capture")
        expectNotNil(writerLog, "the writer writes when the tab has a folder and sync is not paused")

        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        expect(remainingFiles.count > 1, "the inbound group and the new local group both exist")
    }

    TestRunner.add("an old database with the retired sync ledger table opens directly") {
        let tempDir = createTempDirectory(prefix: "copyq-retired-ledger")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbPath = tempDir.appendingPathComponent("retired_ledger.sqlite").path

        try makeLegacyDatabase(at: dbPath, extraSchemaAndRows: """
        CREATE TABLE imported_sync_stems (folder TEXT NOT NULL, stem TEXT NOT NULL, imported_at REAL NOT NULL, PRIMARY KEY (folder, stem));
        INSERT INTO imported_sync_stems (folder, stem, imported_at)
        VALUES ('/path/to/Fedora', 'copyq_old', 1);
        """)

        let store = try ClipboardStore(path: dbPath)
        expectEqual(store.database.userVersion, ClipboardStore.currentSchemaVersion)
        expectEqual(try store.tabs().count, 2, "the legacy tabs are intact")
    }

    TestRunner.add("an upstream edit to a locally captured item updates it in place") {
        let tempDir = createTempDirectory(prefix: "copyq-local-capture-edit")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "LocalCaptureEditTab",
            syncFolder: tempDir.path
        ))

        let createdAt = Date(timeIntervalSince1970: 1_700_000_500)
        let localEntry = try store.insert(ClipboardEntry(
            createdAt: createdAt,
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let captureLog = try CopyQSyncWriter.shared.writeEntry(localEntry, in: store, reason: "capture")
        let stem = try unwrap(captureLog?.stem, "the capture was written")
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")

        let laterDate = Date(timeIntervalSinceNow: 60)
        try Data("gamma".utf8).write(to: txtFile)
        try FileManager.default.setAttributes([.modificationDate: laterDate], ofItemAtPath: txtFile.path)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report.importedCount, 0, "the known item is not duplicated")
        expectEqual(report.updatedCount, 1, "the newer upstream edit updates the local row")
        expectEqual(try store.count(tabID: tab.id), 1)

        let updated = try unwrap(try store.entry(id: localEntry.id), "the local row survives")
        expectEqual(FlavourDecoder.storedPlainText(from: updated.flavours), "gamma")
        expectEqual(
            CopyQSyncDeletion.syncBaseName(of: updated, in: store, folder: tempDir.path),
            stem,
            "the entry still owns the stem it was captured under"
        )
    }

    TestRunner.add("the edit write-back is not re-imported as an upstream change") {
        let tempDir = createTempDirectory(prefix: "copyq-edit-rescan")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "EditRescanTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000061"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("alpha".utf8).write(to: txtFile)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report1 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report1.importedCount, 1, "the first scan imports the item")

        guard let entry = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("imported entry was not stored")
            return
        }
        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "alpha beta")

        let report2 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report2.importedCount, 0)
        expectEqual(report2.updatedCount, 0, "our own edit write is not an upstream change")
        expectEqual(report2.skippedUpstreamCount, 0)
        expectEqual(report2.skippedWrittenByUsCount, 1, "the rewritten group is recognised as our own write")
        expectEqual(try store.count(tabID: tab.id), 1, "one entry remains for the stem")

        let report3 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report3.importedCount, 0)
        expectEqual(report3.updatedCount, 0)
        expectEqual(try store.count(tabID: tab.id), 1)
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "alpha beta"
        )
    }

    TestRunner.add("deleting an imported entry lets the next scan import it again") {
        let tempDir = createTempDirectory(prefix: "copyq-delete-reimport")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "DeleteReimportTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000062"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("resurrect me".utf8).write(to: txtFile)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report1 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report1.importedCount, 1)

        guard let entry = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("imported entry was not stored")
            return
        }
        try store.delete(id: entry.id)
        expectEqual(try store.count(tabID: tab.id), 0)

        let report2 = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report2.importedCount, 1, "the file must import again after its entry is deleted")
        expectEqual(try store.count(tabID: tab.id), 1)
    }

    TestRunner.add("xml format item imports cleanly as a complete group") {
        let tempDir = createTempDirectory(prefix: "copyq-xml-group")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "XmlTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000099"
        let xmlFile = tempDir.appendingPathComponent("\(stem).xml")
        let xmlData = "<clipboard><content>Hello XML</content></clipboard>"
        try Data(xmlData.utf8).write(to: xmlFile)

        let groups = CopyQSyncWatcher.findItemGroups(in: tempDir.path)
        expectEqual(groups.count, 1, "found 1 item group")
        expect(groups.first?.isComplete == true, "xml group must be complete")

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report.importedCount, 1, "xml item must be imported")
        expectEqual(report.incompleteCount, 0, "xml item must not be incomplete")

        let entries = try store.recentEntries(tabID: tab.id)
        expectEqual(entries.count, 1, "store must contain 1 entry")
        let xmlFlavour = entries.first?.flavours.first { $0.type == "application/xml" }
        expect(xmlFlavour != nil, "imported entry must contain application/xml flavour")
        if let data = xmlFlavour?.data {
            expectEqual(String(data: data, encoding: .utf8), xmlData, "flavour data matches")
        }
    }

    TestRunner.add("remote clock drift into the future is treated as settled") {
        let tempDir = createTempDirectory(prefix: "copyq-future-clock")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "FutureClockTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000088"
        let txtFile = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Future clock item".utf8).write(to: txtFile)

        let futureDate = Date().addingTimeInterval(600)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: txtFile.path)

        let groups = CopyQSyncWatcher.findItemGroups(in: tempDir.path)
        expectEqual(groups.count, 1, "one group found")
        let group = groups.first!
        expect(group.newestModificationDate > Date(), "modification date is in the future")
        expect(group.isSettled(), "group with future date must evaluate to settled")

        let watcher = CopyQSyncWatcher(store: store)
        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0.5)
        expectEqual(report.importedCount, 1, "future clock item imports without delay")
        expectEqual(report.unsettledCount, 0, "unsettled count must be zero")
    }

    TestRunner.add("incomplete item increments incompleteCount and does not busy loop") {
        let tempDir = createTempDirectory(prefix: "copyq-no-busy-loop")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "NoBusyLoopTab",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_incomplete_note_only"
        let noteFile = tempDir.appendingPathComponent("\(stem)_note.txt")
        try Data("Note without item".utf8).write(to: noteFile)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0.5
        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report.incompleteCount, 1, "incomplete count must be 1")
        expectEqual(report.unsettledCount, 0, "unsettled count must be 0")
        expectEqual(report.importedCount, 0, "imported count must be 0")
    }

    TestRunner.add("watcher synchronous stop halts background execution") {
        let tempDir = createTempDirectory(prefix: "copyq-sync-stop")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        _ = try store.insertTab(ClipboardTab(
            name: "SyncStopTab",
            syncFolder: tempDir.path
        ))

        let watcher = CopyQSyncWatcher(store: store)
        watcher.start(store: store)
        expect(watcher.isRunning, "watcher must be running after start")

        watcher.stop()
        expect(!watcher.isRunning, "watcher must not be running after stop()")
    }

    // MARK: - Date resolution and folder-to-tab routing

    func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    TestRunner.add("a group with a stale name stamp and a recent mtime gets the recent timestamp") {
        let tempDir = createTempDirectory(prefix: "copyq-stale-stamp")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let fedora = try store.insertTab(ClipboardTab(
            name: "Fedora",
            syncFolder: tempDir.path
        ))

        // Fedora writes a stale base stamp plus a counter, like the live folder:
        // copyq_2024120703474115664.txt with today's modification time.
        let stem = "copyq_2024120703474115664"
        let recent = Date(timeIntervalSince1970: 1_792_969_788) // 2026-10-26T02:03:08Z
        let file = tempDir.appendingPathComponent("\(stem).txt")
        try Data("A clip copied on Fedora today".utf8).write(to: file)
        try setModificationDate(recent, of: file)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: fedora.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.importedCount, 1, "the group must import")

        let entries = try store.recentEntries(limit: 10, tabID: fedora.id)
        expectEqual(entries.count, 1, "one entry imported")
        guard let stored = entries.first else { return }
        expectEqual(stored.tabID, fedora.id, "the entry belongs to the Fedora tab")
        expect(abs(stored.createdAt.timeIntervalSince(recent)) < 0.01, "stored timestamp must be the file modification time")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: stored.createdAt)
        expectEqual(parts.year, 2026, "the list must not show the stale 2024 stamp")
        expectEqual(parts.month, 10, "the list must show the arrival month")
    }

    TestRunner.add("a group with a matching old name stamp and mtime keeps the old timestamp") {
        let tempDir = createTempDirectory(prefix: "copyq-old-stamp")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "Archive",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_2024120703474115665"
        guard let old = CopyQSyncItem.parseTimestamp(baseName: stem) else {
            expect(false, "the test stem must parse as a CopyQ stamp")
            return
        }
        let file = tempDir.appendingPathComponent("\(stem).txt")
        try Data("A genuinely old clip".utf8).write(to: file)
        // Syncthing preserves mtimes, so a real old item has an old mtime too.
        try setModificationDate(old, of: file)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.importedCount, 1, "the group must import")

        let entries = try store.recentEntries(limit: 10, tabID: tab.id)
        guard let stored = entries.first?.createdAt else {
            expect(false, "the entry must be stored")
            return
        }
        expect(abs(stored.timeIntervalSince(old)) < 0.002, "the old timestamp must be kept")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        expectEqual(calendar.component(.year, from: stored), 2024, "the real old year is preserved")
    }

    TestRunner.add("a repeated group with a newer date refreshes the stored timestamp") {
        let tempDir = createTempDirectory(prefix: "copyq-repeat-newer")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "Fedora",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_2024120703474115777"
        let first = Date(timeIntervalSince1970: 1_792_969_788)
        let later = first.addingTimeInterval(86_400)
        let file = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Repeated Fedora clip".utf8).write(to: file)
        try setModificationDate(first, of: file)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        _ = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(try store.count(tabID: tab.id), 1, "the first arrival is stored")
        let firstEntryID = try store.recentEntries(limit: 10, tabID: tab.id).first?.id

        // Let the first import's pending main-thread notification run before
        // installing the observer for the refresh notification.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        var notified: [ClipboardEntry] = []
        watcher.onImport = { notified.append(contentsOf: $0) }
        try setModificationDate(later, of: file)
        let repeatReport = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(repeatReport.importedCount, 0, "the repeat keeps one row")
        expectEqual(repeatReport.duplicateCount, 1, "the repeat is a duplicate identity")
        expectEqual(try store.count(tabID: tab.id), 1, "no second row is written")
        let stored = try store.recentEntries(limit: 10, tabID: tab.id).first?.createdAt
        expectNotNil(stored, "the entry is still stored")
        if let stored {
            expect(abs(stored.timeIntervalSince(later)) < 0.01, "the newer resolved date replaces the stale one")
        }

        let deadline = Date().addingTimeInterval(1)
        while notified.isEmpty && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        expectEqual(notified.count, 1, "the refreshed row is in the notification list")
        expectEqual(notified.first?.id, firstEntryID, "the notification names the refreshed row")
        if let notifiedDate = notified.first?.createdAt {
            expect(abs(notifiedDate.timeIntervalSince(later)) < 0.01, "the notification carries the refreshed date")
        }
    }

    TestRunner.add("a repeat stays the same identity when its resolved date moves past the name stamp") {
        let tempDir = createTempDirectory(prefix: "copyq-repeat-identity")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "Fedora",
            syncFolder: tempDir.path
        ))

        let stem = "copyq_20261025120000051"
        guard let nameDate = CopyQSyncItem.parseTimestamp(baseName: stem) else {
            expect(false, "the test stem parses")
            return
        }
        let file = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Same item, later arrival".utf8).write(to: file)
        try setModificationDate(nameDate, of: file)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        _ = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(try store.count(tabID: tab.id), 1, "the first import stores one row")

        let later = nameDate.addingTimeInterval(86_400)
        try setModificationDate(later, of: file)
        let repeatReport = try watcher.scanFolder(
            atPath: tempDir.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(repeatReport.importedCount, 0, "the same file name is not a new item")
        expectEqual(repeatReport.duplicateCount, 1, "the same file name matches the stored identity")
        expectEqual(try store.count(tabID: tab.id), 1, "the repeat does not add a second row")
        let stored = try store.recentEntries(limit: 10, tabID: tab.id).first?.createdAt
        expectNotNil(stored, "the row is still readable")
        if let stored {
            expect(abs(stored.timeIntervalSince(later)) < 0.01, "the repeat refreshes the stored date")
        }
    }

    TestRunner.add("an item from a watched folder always lands in that folder's tab, never the capture tab") {
        let fedoraDir = createTempDirectory(prefix: "copyq-route-fedora")
        let macDir = createTempDirectory(prefix: "copyq-route-mac")
        defer {
            try? FileManager.default.removeItem(at: fedoraDir)
            try? FileManager.default.removeItem(at: macDir)
        }

        let store = try ClipboardStore(inMemory: true)
        var capture = try store.ensureDefaultTab()
        capture.syncFolder = macDir.path
        try store.updateTab(capture)
        let fedora = try store.insertTab(ClipboardTab(
            name: "Fedora",
            syncFolder: fedoraDir.path
        ))
        expect(capture.id != fedora.id, "the capture tab and the Fedora tab must be distinct")

        let stem = "copyq_2024120703474115666"
        try Data("Fedora routing payload".utf8)
            .write(to: fedoraDir.appendingPathComponent("\(stem).txt"))

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        // Hand the scan the capture tab id on purpose: the folder mapping, not
        // the caller's hint, decides where the item goes.
        let report = try watcher.scanFolder(
            atPath: fedoraDir.path,
            intoTabID: capture.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.importedCount, 1, "the watched folder's group imports")
        expectEqual(try store.count(tabID: fedora.id), 1, "the item must land in the Fedora tab")
        expectEqual(try store.count(tabID: capture.id), 0, "the capture tab must stay untouched")
        expectEqual(try store.recentEntries(limit: 10, tabID: fedora.id).first?.tabID, fedora.id, "the entry names the Fedora tab")

        // The mapping is resolved from the store on every scan, so moving the
        // mapping moves subsequent imports with it.
        let movedDir = createTempDirectory(prefix: "copyq-route-moved")
        defer { try? FileManager.default.removeItem(at: movedDir) }
        var moved = fedora
        moved.syncFolder = movedDir.path
        try store.updateTab(moved)

        let movedStem = "copyq_2024120703474115667"
        try Data("Moved mapping payload".utf8)
            .write(to: movedDir.appendingPathComponent("\(movedStem).txt"))
        let movedReport = try watcher.scanFolder(
            atPath: movedDir.path,
            intoTabID: capture.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(movedReport.importedCount, 1, "the moved folder still imports")
        expectEqual(try store.count(tabID: fedora.id), 2, "both groups are in the Fedora tab")
        expectEqual(try store.count(tabID: capture.id), 0, "the capture tab is still untouched")
    }

    TestRunner.add("an unmatched folder is skipped with a log entry instead of using the capture tab") {
        let fedoraDir = createTempDirectory(prefix: "copyq-unmatched-fedora")
        let orphanDir = createTempDirectory(prefix: "copyq-unmatched-orphan")
        let macDir = createTempDirectory(prefix: "copyq-unmatched-mac")
        defer {
            try? FileManager.default.removeItem(at: fedoraDir)
            try? FileManager.default.removeItem(at: orphanDir)
            try? FileManager.default.removeItem(at: macDir)
        }

        let store = try ClipboardStore(inMemory: true)
        var capture = try store.ensureDefaultTab()
        capture.syncFolder = macDir.path
        try store.updateTab(capture)
        _ = try store.insertTab(ClipboardTab(
            name: "Fedora",
            syncFolder: fedoraDir.path
        ))

        let stem = "copyq_2024120703474115999"
        try Data("Orphan folder payload".utf8)
            .write(to: orphanDir.appendingPathComponent("\(stem).txt"))

        let tabsBefore = try store.tabs()
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0

        let report = try watcher.scanFolder(
            atPath: orphanDir.path,
            intoTabID: capture.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.importedCount, 0, "nothing is imported from an unmatched folder")
        expectEqual(report.failureCount, 1, "the skipped folder is counted as a failure")
        expect(
            report.failures.contains { $0.contains("no tab has this path as its sync folder") },
            "the skip is recorded as a log entry"
        )
        expectEqual(try store.count(tabID: capture.id), 0, "the capture tab must not receive orphan items")
        expectEqual(try store.tabs().count, tabsBefore.count, "no tab is created for an unmatched folder")
    }

    TestRunner.add("a folder claimed by two tabs is skipped instead of resolved by position") {
        let sharedDir = createTempDirectory(prefix: "copyq-ambiguous-folder")
        defer { try? FileManager.default.removeItem(at: sharedDir) }

        let store = try ClipboardStore(inMemory: true)
        let fedora = try store.insertTab(ClipboardTab(
            name: "Fedora",
            syncFolder: sharedDir.path
        ))
        let other = try store.insertTab(ClipboardTab(
            name: "Other",
            syncFolder: sharedDir.path
        ))

        let stem = "copyq_2024120703474115888"
        try Data("Ambiguous folder payload".utf8)
            .write(to: sharedDir.appendingPathComponent("\(stem).txt"))

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: sharedDir.path,
            intoTabID: fedora.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.importedCount, 0, "an ambiguous folder must not import")
        expectEqual(try store.count(tabID: fedora.id), 0, "neither conflicting tab receives the item")
        expectEqual(try store.count(tabID: other.id), 0, "neither conflicting tab receives the item")
        let diagnostic = report.failures.first { $0.contains("multiple tabs claim this sync folder") }
        expectNotNil(diagnostic, "the ambiguity is logged")
        if let diagnostic {
            expect(diagnostic.contains("Fedora"), "the diagnostic names the first tab")
            expect(diagnostic.contains("Other"), "the diagnostic names the second tab")
        }

        var cleared = other
        cleared.syncFolder = nil
        try store.updateTab(cleared)

        let resolved = try watcher.scanFolder(
            atPath: sharedDir.path,
            intoTabID: other.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(resolved.importedCount, 1, "a single remaining owner imports")
        expectEqual(try store.count(tabID: fedora.id), 1, "the single owner receives the item")
        expectEqual(try store.count(tabID: other.id), 0, "the tab no longer claiming the folder stays empty")
    }

    TestRunner.add("a stem written into one sync folder does not suppress the same stem in another") {
        let folderA = createTempDirectory(prefix: "copyq-echo-folder-a")
        let folderB = createTempDirectory(prefix: "copyq-echo-folder-b")
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
        }

        let store = try ClipboardStore(inMemory: true)
        let tabA = try store.insertTab(ClipboardTab(name: "A", syncFolder: folderA.path))
        let tabB = try store.insertTab(ClipboardTab(name: "B", syncFolder: folderB.path))

        let stem = "copyq_20241010101010123"
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        watcher.recordWrittenStem(stem, folder: folderA.path)
        try store.recordWrittenSyncStem(stem, folder: folderA.path)

        let restarted = CopyQSyncWatcher(store: store)
        restarted.settleDelay = 0
        expect(restarted.isWrittenByUs(stem, folder: folderA.path), "folder A's write is remembered after restart")
        expect(!restarted.isWrittenByUs(stem, folder: folderB.path), "folder B does not inherit folder A's write")

        try Data("Same stem, folder A".utf8)
            .write(to: folderA.appendingPathComponent("\(stem).txt"))
        try Data("Same stem, folder B".utf8)
            .write(to: folderB.appendingPathComponent("\(stem).txt"))

        let reportB = try restarted.scanFolder(
            atPath: folderB.path,
            intoTabID: tabB.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(reportB.importedCount, 1, "folder B imports the same stem")
        expectEqual(reportB.skippedWrittenByUsCount, 0, "folder A's write does not suppress folder B")

        let reportA = try restarted.scanFolder(
            atPath: folderA.path,
            intoTabID: tabA.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(reportA.importedCount, 0, "our own write is still skipped in its own folder")
        expectEqual(reportA.skippedWrittenByUsCount, 1, "the echo check stays scoped to folder A")

        try store.recordWrittenSyncStem(stem, folder: folderB.path)
        let durable = try store.allWrittenSyncStemsByFolder()
        expect(durable[CopyQSyncBridge.normalizePath(folderA.path)]?.contains(stem) == true, "folder A keeps its durable row")
        expect(durable[CopyQSyncBridge.normalizePath(folderB.path)]?.contains(stem) == true, "folder B keeps its separate durable row")
    }

    TestRunner.add("watcher skips Syncthing conflict files and does not import ghost entries") {
        let tempDir = createTempDirectory(prefix: "copyq-watcher-syncthing-conflict")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "WatcherConflictTab",
            syncFolder: tempDir.path
        ))

        let regularStem = "copyq_20261118120000100"
        let conflictStem = "\(regularStem).sync-conflict-20261118-120600-DEV01"

        try Data("Watcher regular content".utf8)
            .write(to: tempDir.appendingPathComponent("\(regularStem).txt"))
        try Data("Watcher conflict content".utf8)
            .write(to: tempDir.appendingPathComponent("\(conflictStem).txt"))

        // Verify findItemGroups skips conflict files
        let groups = CopyQSyncWatcher.findItemGroups(in: tempDir.path)
        expectEqual(groups.count, 1, "findItemGroups must discover only 1 group")
        expectEqual(groups.first?.stem, regularStem, "discovered group stem must be regularStem")

        // Verify itemStem skips conflict files
        expectEqual(CopyQSyncWatcher.itemStem(ofFileName: "\(conflictStem).txt"), nil, "itemStem must return nil for conflict files")
        expectEqual(CopyQSyncWatcher.itemStem(ofFileName: "\(regularStem).txt"), regularStem, "itemStem returns regularStem")

        // Verify itemGroupStems skips conflict files
        let stems = CopyQSyncWatcher.itemGroupStems(in: tempDir.path)
        expectEqual(stems, Set([regularStem]), "itemGroupStems must contain only regularStem")

        // Verify watcher scan
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(atPath: tempDir.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
        expectEqual(report.importedCount, 1, "watcher must import only the regular item")

        let entries = try store.recentEntries(tabID: tab.id)
        expectEqual(entries.count, 1, "store must contain only 1 entry")
        let textData = entries.first?.flavours.first(where: { $0.type == PasteboardTypes.utf8Text })?.data
        expectEqual(textData.flatMap { String(data: $0, encoding: .utf8) }, "Watcher regular content", "imported entry must be regular item")
    }
}
