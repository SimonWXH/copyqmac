// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tests for Stage 2a CopyQSync write-back: naming/format agreement, collision bumping,
// no-write on import/selection/note-change, pause switch, and sandboxed log rotation.

import Foundation

func registerCopyQSyncWriteBackTests() {
    TestRunner.currentSuite = "CopyQSyncWriteBack"

    TestRunner.add("naming and format agreement matches CopyQ itemsync plugin specification") {
        // Documented mappings from upstream plugins/itemsync/filewatcher.cpp:
        // noteFileSuffix: "_note.txt" -> mimeItemNotes ("application/x-copyq-item-notes")
        // ".txt" -> mimeText ("text/plain")
        // ".html" -> mimeHtml ("text/html")
        // ".uri" -> mimeUriList ("text/uri-list")
        // ".png" -> "image/png"
        // dataFileSuffix: "_copyq.dat" -> mimeUnknownFormats
        expectEqual(CopyQFormat.noteFileSuffix, "_note.txt", "noteFileSuffix must be _note.txt")
        expectEqual(CopyQFormat.dataFileSuffix, "_copyq.dat", "dataFileSuffix must be _copyq.dat")
        expectEqual(CopyQFormat.fileExtension(for: "text/plain"), ".txt", "text/plain extension")
        expectEqual(CopyQFormat.fileExtension(for: "text/html"), ".html", "text/html extension")
        expectEqual(CopyQFormat.fileExtension(for: "text/uri-list"), ".uri", "text/uri-list extension")
        expectEqual(CopyQFormat.fileExtension(for: "image/png"), ".png", "image/png extension")
        expectEqual(CopyQFormat.fileExtension(for: "application/x-copyq-item-notes"), "_note.txt", "notes extension")
        expectEqual(CopyQFormat.fileExtension(for: "custom/unknown"), nil, "custom format packed into _copyq.dat")

        // Render a rich item with all format types and check written filenames
        var dataMap = CopyQDataMap()
        dataMap.set("text/plain", Data("Hello text".utf8))
        dataMap.set("text/html", Data("<b>Hello html</b>".utf8))
        dataMap.set("image/png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        dataMap.set("application/x-copyq-item-notes", Data("Note content".utf8))
        dataMap.set("custom/flavour", Data("extra binary data".utf8))

        let stem = "copyq_20261025120000123"
        let item = CopyQSyncItem(baseName: stem, data: dataMap)
        let files = item.onDiskFiles()

        let expectedExtensions = Set([".txt", ".html", ".png", "_note.txt", "_copyq.dat"])
        expectEqual(Set(files.keys), expectedExtensions, "written suffixes must exactly match specification")

        // Write to a temporary folder and read back with CopyQSyncFolder.read
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-format-agreement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try CopyQSyncFolder.write(item, into: tempDir.path)

        let contents = try CopyQSyncFolder.read(atPath: tempDir.path)
        expectEqual(contents.items.count, 1, "reader must accept the written file set")
        if let readItem = contents.items.first {
            expectEqual(readItem.baseName, stem, "stem must match")
            expectEqual(readItem.text, "Hello text", "text content must match")
            expectEqual(readItem.html, "<b>Hello html</b>", "html content must match")
            expectEqual(readItem.notes, "Note content", "notes must match")
            expectEqual(readItem.data.bytes("custom/flavour"), Data("extra binary data".utf8), "container flavour must match")
        }
    }

    TestRunner.add("collision bumping preserves existing files and advances the timestamp") {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-collision-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1700000000.123)
        let initialStem = CopyQSyncBridge.formatTimestamp(baseDate)

        // Pre-create an existing file with initialStem
        let existingFilePath = tempDir.appendingPathComponent("\(initialStem).txt").path
        let originalContent = "Original file that must not be modified or overwritten"
        try originalContent.write(toFile: existingFilePath, atomically: true, encoding: .utf8)

        // Resolve unique stem
        let (resolvedStem, bumpedDate) = try CopyQSyncWriter.resolveUniqueStem(
            initialDate: baseDate,
            directory: tempDir.path
        )

        expect(resolvedStem != initialStem, "resolved stem must differ from initial collided stem")
        expect(bumpedDate > baseDate, "bumped date must be after base date")

        // Write an entry using the writer
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "CollisionTab",
            syncFolder: tempDir.path
        ))
        var prefs = try store.preferences()
        prefs.syncPaused = false
        try store.setPreferences(prefs)

        let entry = ClipboardEntry(
            createdAt: baseDate,
            tabID: tab.id,
            flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.plainText, data: Data("New entry content".utf8))]
        )

        let writer = CopyQSyncWriter()
        let log = try writer.writeEntry(entry, in: store, reason: "capture")
        expectNotNil(log, "writeEntry must succeed")
        expectEqual(log?.stem, resolvedStem, "logged stem must be the bumped stem")

        // Assert original file was completely preserved
        let survivingOriginal = try String(contentsOfFile: existingFilePath, encoding: .utf8)
        expectEqual(survivingOriginal, originalContent, "original file must remain untouched")

        // Assert new file exists
        let newFilePath = tempDir.appendingPathComponent("\(resolvedStem).txt").path
        expect(FileManager.default.fileExists(atPath: newFilePath), "new file must exist at bumped stem")
        let newContent = try String(contentsOfFile: newFilePath, encoding: .utf8)
        expectEqual(newContent, "New entry content", "new entry content must match")
    }

    TestRunner.add("import operations never trigger write-back") {
        let tempSyncDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-nowrite-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempSyncDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempSyncDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "ImportTab",
            syncFolder: tempSyncDir.path
        ))
        var prefs = try store.preferences()
        prefs.syncPaused = false
        try store.setPreferences(prefs)

        // Create a separate external folder to import from
        let sourceDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-import-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        var itemData = CopyQDataMap()
        itemData.set("text/plain", Data("Imported content".utf8))
        let sourceItem = CopyQSyncItem(baseName: "copyq_20261025111111111", data: itemData)
        try CopyQSyncFolder.write(sourceItem, into: sourceDir.path)

        // Perform import
        let report = try CopyQSyncBridge.importSyncFolder(atPath: sourceDir.path, intoTabID: tab.id, in: store)
        expectEqual(report.importedCount, 1, "must import 1 entry")

        // Verify that NOTHING was written to tempSyncDir
        let syncDirFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempSyncDir.path)) ?? []
        expectEqual(syncDirFiles.count, 0, "import must not write any files to the mapped sync folder")
    }

    TestRunner.add("the pause switch inhibits write-back immediately and resume restores it") {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-pause-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "PauseTab",
            syncFolder: tempDir.path
        ))

        let entry = ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.plainText, data: Data("Pause test content".utf8))]
        )

        let writer = CopyQSyncWriter()

        // Paused: no files are written.
        var prefs = try store.preferences()
        prefs.syncPaused = true
        try store.setPreferences(prefs)
        let paused = try writer.writeEntry(entry, in: store)
        expect(paused == nil, "writeEntry must return nil when syncPaused is true")
        expectEqual((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?.count ?? 0, 0)

        // Resumed: the folder is enough to write, with no per-tab switch.
        prefs.syncPaused = false
        try store.setPreferences(prefs)
        let resumed = try writer.writeEntry(entry, in: store)
        expectNotNil(resumed, "writeEntry must succeed when sync is not paused")
        let writtenFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        expect(writtenFiles.count > 0, "file must be created when sync is not paused")
    }

    TestRunner.add("note changes on existing entries write the note file") {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-note-writeback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "NoteTab",
            syncFolder: tempDir.path
        ))
        var prefs = try store.preferences()
        prefs.syncPaused = false
        try store.setPreferences(prefs)

        let initialDate = Date(timeIntervalSince1970: 1700000000)
        let entry = ClipboardEntry(
            createdAt: initialDate,
            tabID: tab.id,
            flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.plainText, data: Data("Original text".utf8))]
        )
        let inserted = try store.insert(entry)

        let writer = CopyQSyncWriter()
        let captureLog = try writer.writeEntry(inserted, in: store, reason: "capture")
        expectNotNil(captureLog, "initial capture write must succeed")
        let stem = try unwrap(captureLog?.stem, "the capture stem")

        let initialFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        expectEqual(initialFiles, ["\(stem).txt"], "only the text file is written on initial capture")
        let initialFilePath = tempDir.appendingPathComponent("\(stem).txt").path
        let initialFileContent = try String(contentsOfFile: initialFilePath, encoding: .utf8)
        expectEqual(initialFileContent, "Original text", "file content before note change")

        let history = ClipboardHistory(store: store)
        MainActor.assumeIsolated {
            let model = AppModel(history: history)
            model.bootstrap()
            model.selectTab(tab.id)
            model.select(inserted.id)
            model.setNoteEditing(true)
            model.setNoteDraft("Added note that now syncs")
            let failure = model.flushPendingNote()
            expect(failure == nil, "flushPendingNote must succeed")
        }

        let fetched = try store.entry(id: inserted.id)
        expectEqual(fetched?.note, "Added note that now syncs", "note must be updated in store")

        let filesAfterNote = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        expectEqual(
            filesAfterNote.sorted(),
            ["\(stem).txt", "\(stem)_note.txt"].sorted(),
            "the note travels with the item's file group"
        )
        let contentAfter = try String(contentsOfFile: initialFilePath, encoding: .utf8)
        expectEqual(contentAfter, "Original text", "the content file is unchanged by a note edit")
        let noteAfter = try String(
            contentsOf: tempDir.appendingPathComponent("\(stem)_note.txt"),
            encoding: .utf8
        )
        expectEqual(noteAfter, "Added note that now syncs", "the note file carries the new note")
    }

    TestRunner.add("sync log path respects sandboxed data directory and rotates at bound") {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-log-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            unsetenv(ClipboardStore.dataDirectoryEnvironmentKey)
            try? FileManager.default.removeItem(at: tempDir)
        }

        setenv(ClipboardStore.dataDirectoryEnvironmentKey, tempDir.path, 1)

        let writer = CopyQSyncWriter()
        let expectedLogPath = tempDir.appendingPathComponent("sync.log").path
        expectEqual(writer.logFilePath, expectedLogPath, "log path must resolve to COPYQMAC_DATA_DIR/sync.log")

        writer.maxLogFileSize = 100
        writer.maxRotatedFiles = 2

        let entry1 = SyncLogEntry(stem: "stem1", folderPath: tempDir.path, reason: "test", error: String(repeating: "A", count: 80))
        writer.recordLog(entry1)
        expect(FileManager.default.fileExists(atPath: expectedLogPath), "sync.log should exist")

        let entry2 = SyncLogEntry(stem: "stem2", folderPath: tempDir.path, reason: "test", error: String(repeating: "B", count: 80))
        writer.recordLog(entry2)

        let log1Path = "\(expectedLogPath).1"
        expect(FileManager.default.fileExists(atPath: log1Path), "sync.log.1 should exist after first rotation")

        let entry3 = SyncLogEntry(stem: "stem3", folderPath: tempDir.path, reason: "test", error: String(repeating: "C", count: 80))
        writer.recordLog(entry3)

        let log2Path = "\(expectedLogPath).2"
        expect(FileManager.default.fileExists(atPath: log2Path), "sync.log.2 should exist after second rotation")

        let entry4 = SyncLogEntry(stem: "stem4", folderPath: tempDir.path, reason: "test", error: String(repeating: "D", count: 80))
        writer.recordLog(entry4)

        let log3Path = "\(expectedLogPath).3"
        expect(!FileManager.default.fileExists(atPath: log3Path), "sync.log.3 must not exist (capped at 2 rotated files)")
    }
}
