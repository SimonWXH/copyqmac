// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tests for CopyQSyncBridge: deduplication, tab mapping, note import, .cpq archive import,
// and dry-run writer round-trip.

import AppKit
import Foundation

/// Puts an imported entry on a throwaway pasteboard through the real paste
/// path, so a test can prove what a native app would receive from a paste-back.
@MainActor
private final class RichImportPasteFixture {
    let pasteboard: NSPasteboard
    let service: PasteService

    init() throws {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        pasteboard = NSPasteboard(name: .init("copyqmac-rich-import-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let watcher = ClipboardWatcher(history: history, pasteboard: pasteboard)
        service = PasteService(
            tracker: FrontmostAppTracker(),
            watcher: watcher,
            pasteboard: pasteboard,
            requestTrust: { false }
        )
    }

    /// Copies the entry the way the UI's copy command does, then waits for the
    /// asynchronous prepare queue to land the flavours on the pasteboard.
    func paste(_ entry: ClipboardEntry, waitingFor type: String, timeout: TimeInterval = 2) -> Data? {
        service.copy(entry)
        let pasteboardType = NSPasteboard.PasteboardType(type)
        let deadline = Date().addingTimeInterval(timeout)
        while pasteboard.data(forType: pasteboardType) == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return pasteboard.data(forType: pasteboardType)
    }
}

func registerCopyQSyncTests() {
    TestRunner.currentSuite = "CopyQSync"
    TestRunner.add("import deduplicates by content fingerprint and is a no-op on repeat") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "SyncTab")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-dedupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 3 synthetic sync items in tempDir
        let stamps = ["copyq_20261025120000001", "copyq_20261025120000002", "copyq_20261025120000003"]
        for (i, stamp) in stamps.enumerated() {
            var data = CopyQDataMap()
            data.set(CopyQFormat.text, Data("Text payload \(i)".utf8))
            let item = CopyQSyncItem(baseName: stamp, data: data)
            try CopyQSyncFolder.write(item, into: tempDir.path)
        }

        // First import
        let report1 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report1.importedCount, 3, "first import should import 3 items")
        expectEqual(report1.duplicateCount, 0, "first import should have 0 duplicates")
        expectEqual(try store.count(tabID: tab.id), 3, "store should have 3 entries")

        // Second import (must be a no-op)
        let report2 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report2.importedCount, 0, "second import should import 0 items")
        expectEqual(report2.duplicateCount, 3, "second import should report 3 duplicates")
        expectEqual(try store.count(tabID: tab.id), 3, "store should still have 3 entries")
    }

    TestRunner.add("editing an imported item skips the unchanged upstream version") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "EditImportTab")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-edit-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stamp = "copyq_20261025120000011"
        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("alpha".utf8))
        try CopyQSyncFolder.write(CopyQSyncItem(baseName: stamp, data: data), into: tempDir.path)

        let report1 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report1.importedCount, 1)

        guard let entry = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("imported entry was not stored")
            return
        }
        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "alpha beta")

        let report2 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report2.importedCount, 0)
        expectEqual(report2.updatedCount, 0, "the local edit must not be overwritten")
        expectEqual(report2.skippedUpstreamCount, 0, "an unchanged upstream version is a duplicate")
        expectEqual(report2.duplicateCount, 1)
        expectEqual(try store.count(tabID: tab.id), 1, "one entry remains for the stem")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "alpha beta"
        )
    }

    TestRunner.add("an upstream content change updates the entry in place") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "RewriteImportTab")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-rewrite-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stem = "copyq_custom_rewrite"
        let txtPath = tempDir.appendingPathComponent("\(stem).txt").path
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(120)

        var firstData = CopyQDataMap()
        firstData.set(CopyQFormat.text, Data("alpha".utf8))
        try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: firstData), into: tempDir.path)
        try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: txtPath)

        let report1 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report1.importedCount, 1)
        guard let imported = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("imported entry was not stored")
            return
        }

        var secondData = CopyQDataMap()
        secondData.set(CopyQFormat.text, Data("beta".utf8))
        try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: secondData), into: tempDir.path)
        try FileManager.default.setAttributes([.modificationDate: secondDate], ofItemAtPath: txtPath)

        let report2 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report2.importedCount, 0, "the rewrite must not add a row")
        expectEqual(report2.updatedCount, 1, "the newer upstream content is applied in place")
        expectEqual(report2.duplicateCount, 0)
        expectEqual(try store.count(tabID: tab.id), 1, "the row count stays unchanged")

        guard let stored = try store.entry(id: imported.id) else {
            TestRunner.fail("the imported entry disappeared")
            return
        }
        expectEqual(FlavourDecoder.storedPlainText(from: stored.flavours), "beta", "the stored content is updated")
        expectEqual(
            stored.createdAt.timeIntervalSince1970,
            secondDate.timeIntervalSince1970,
            accuracy: 0.001,
            "the creation time is refreshed to the rewritten file's time"
        )

        let report3 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report3.updatedCount, 0, "a further unchanged import must not update again")
        expectEqual(report3.duplicateCount, 1)
    }

    TestRunner.add("a newer upstream edit replaces an older local edit and logs what was discarded") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "LocalEditImportTab")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-local-edit-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stem = "copyq_20261025120000012"
        let txtPath = tempDir.appendingPathComponent("\(stem).txt").path
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        var firstData = CopyQDataMap()
        firstData.set(CopyQFormat.text, Data("alpha".utf8))
        try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: firstData), into: tempDir.path)
        try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: txtPath)

        let report1 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report1.importedCount, 1)
        guard let localEntry = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("imported entry was not stored")
            return
        }
        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: localEntry.id, with: "alpha beta")

        let logPath = tempDir.appendingPathComponent("sync.log").path
        CopyQSyncWriter.shared.customLogFilePath = logPath
        defer { CopyQSyncWriter.shared.customLogFilePath = nil }

        var secondData = CopyQDataMap()
        secondData.set(CopyQFormat.text, Data("gamma".utf8))
        let laterDate = Date(timeIntervalSinceNow: 60)
        try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: secondData), into: tempDir.path)
        try FileManager.default.setAttributes([.modificationDate: laterDate], ofItemAtPath: txtPath)

        let report2 = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
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

        let repeated = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(repeated.updatedCount, 0, "a repeated import does not apply the same version twice")
        expectEqual(repeated.duplicateCount, 1)
    }

    TestRunner.add("folder maps to tab configured with matching syncFolder") {
        let store = try ClipboardStore(inMemory: true)
        let syncPath = "/tmp/copyq-test-mapped-folder"
        let tab = try store.insertTab(ClipboardTab(name: "ConfiguredTab", syncFolder: syncPath))

        let tempDir = URL(fileURLWithPath: syncPath)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("Configured payload".utf8))
        let item = CopyQSyncItem(baseName: "copyq_20261025120000010", data: data)
        try CopyQSyncFolder.write(item, into: tempDir.path)

        let resolvedTab = try CopyQSyncBridge.findOrCreateTab(forFolder: syncPath, in: store)
        expectEqual(resolvedTab.id, tab.id, "should map to existing configured tab")

        let report = try CopyQSyncBridge.importSyncFolder(atPath: syncPath, in: store)
        expectEqual(report.importedCount, 1)
        expectEqual(try store.count(tabID: tab.id), 1, "entry should be in ConfiguredTab")
    }

    TestRunner.add("folder creates new tab with empty syncFolder when path does not match configured syncFolder") {
        let store = try ClipboardStore(inMemory: true)
        let existingTab = try store.insertTab(ClipboardTab(name: "MatchedByName", syncFolder: nil))

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MatchedByName")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("Name match payload".utf8))
        let item = CopyQSyncItem(baseName: "copyq_20261025120000020", data: data)
        try CopyQSyncFolder.write(item, into: tempDir.path)

        let resolvedTab = try CopyQSyncBridge.findOrCreateTab(forFolder: tempDir.path, in: store)
        expect(resolvedTab.id != existingTab.id, "must create a new tab rather than matching by name")
        expect(resolvedTab.syncFolder == nil, "new tab must have empty syncFolder")

        let report = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: resolvedTab.id, in: store)
        expectEqual(report.importedCount, 1)
        expectEqual(try store.count(tabID: resolvedTab.id), 1)
        expectEqual(try store.count(tabID: existingTab.id), 0)
    }

    TestRunner.add("folder creates a new tab when neither syncFolder nor name matches") {
        let store = try ClipboardStore(inMemory: true)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BrandNewTab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("New tab payload".utf8))
        let item = CopyQSyncItem(baseName: "copyq_20261025120000030", data: data)
        try CopyQSyncFolder.write(item, into: tempDir.path)

        let report = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, in: store)
        expectEqual(report.importedCount, 1)

        let tabs = try store.tabs()
        let createdTab = tabs.first { $0.name == tempDir.lastPathComponent }
        expectNotNil(createdTab, "new tab should be created with folder name")
        if let createdTab {
            expectEqual(try store.count(tabID: createdTab.id), 1)
            expect(createdTab.syncFolder == nil, "new tab must have empty syncFolder")
        }
    }

    TestRunner.add("importing items with notes preserves notes and indexes them for search") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "NotesTab")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("Item text content".utf8))
        data.set(CopyQFormat.itemNotes, Data("SpecialNoteText12345".utf8))
        let item = CopyQSyncItem(baseName: "copyq_20261025120000040", data: data)
        try CopyQSyncFolder.write(item, into: tempDir.path)

        let report = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report.importedCount, 1)

        let entries = try store.recentEntries(limit: 10, tabID: tab.id)
        expectEqual(entries.count, 1)
        expectEqual(entries.first?.note, "SpecialNoteText12345")

        // Search for note content in FTS
        let found = try store.search("SpecialNoteText12345", tabID: tab.id)
        expectEqual(found.count, 1, "search should locate entry by note")
        expectEqual(found.first?.id, entries.first?.id)
    }

    TestRunner.add("importing a .cpq archive populates tabs, items, and deduplicates") {
        let store = try ClipboardStore(inMemory: true)

        var item1 = CopyQSyncItem()
        item1.data.set(CopyQFormat.text, Data("CPQ item 1".utf8))
        item1.data.set(CopyQFormat.itemNotes, Data("CPQ note 1".utf8))
        item1.data.set(CopyQFormat.itemPinned, nil)

        var item2 = CopyQSyncItem()
        item2.data.set(CopyQFormat.text, Data("CPQ item 2".utf8))
        item2.data.set(CopyQFormat.itemNotes, Data("CPQ note 2".utf8))

        var stream = QDataStreamWriter()
        stream.writeQByteArray(Data("CopyQ v4".utf8))
        stream.writeUInt32(1)
        stream.writeQString("tabs")
        stream.writeUInt32(11) // QStringList type
        stream.writeBool(false)
        stream.writeQStringList(["CPQTab1"])
        stream.writeUInt32(2)
        stream.writeQString("name")
        stream.writeUInt32(10) // QString type
        stream.writeBool(false)
        stream.writeQString("CPQTab1")
        stream.writeQString("data")
        stream.writeUInt32(12) // QByteArray type
        stream.writeBool(false)
        stream.writeQByteArray(CopyQArchive.encodeItemListForTesting([item1, item2]))

        let archiveData = stream.data
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_archive.cpq")
        try archiveData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // First import
        let report1 = try CopyQSyncBridge.importArchive(atPath: tempFile.path, in: store)
        expectEqual(report1.importedCount, 2)
        expectEqual(report1.duplicateCount, 0)
        expectEqual(report1.failedCount, 0)

        let tabs = try store.tabs()
        let cpqTab = tabs.first { $0.name == "CPQTab1" }
        expectNotNil(cpqTab, "tab CPQTab1 should be created")

        if let cpqTab {
            let entries = try store.recentEntries(limit: 10, tabID: cpqTab.id)
            expectEqual(entries.count, 2)
            expect(entries.contains { $0.pinned }, "one item should be pinned")
            expect(entries.contains { $0.note == "CPQ note 1" }, "note 1 should be imported")
            expect(entries.contains { $0.note == "CPQ note 2" }, "note 2 should be imported")
        }

        // Second import of the same archive (must deduplicate all)
        let report2 = try CopyQSyncBridge.importArchive(atPath: tempFile.path, in: store)
        expectEqual(report2.importedCount, 0, "second archive import should import 0 items")
        expectEqual(report2.duplicateCount, 2, "second archive import should report 2 duplicates")
    }

    TestRunner.add("dry-run writer produces byte-identical round-trip re-read by sync folder reader") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "RoundTripTab")

        let sourceDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-source-\(UUID().uuidString)")
        let scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: scratchDir)
        }

        // Create a rich item with text, html, png, note, pinned marker, and extra MIME flavour in _copyq.dat
        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("Roundtrip text message".utf8))
        data.set(CopyQFormat.html, Data("<b>Roundtrip HTML message</b>".utf8))
        data.set("image/png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        data.set(CopyQFormat.itemNotes, Data("Roundtrip note payload".utf8))
        data.set(CopyQFormat.itemPinned, nil)
        data.set("application/x-custom-meta", Data([0x01, 0x02, 0x03, 0x04]))

        let stamp = "copyq_20261025120939500"
        let originalItem = CopyQSyncItem(baseName: stamp, data: data)
        let writtenSourceFiles = try CopyQSyncFolder.write(originalItem, into: sourceDir.path)
        expect(writtenSourceFiles.contains("\(stamp).txt"))
        expect(writtenSourceFiles.contains("\(stamp).html"))
        expect(writtenSourceFiles.contains("\(stamp).png"))
        expect(writtenSourceFiles.contains("\(stamp)_note.txt"))
        expect(writtenSourceFiles.contains("\(stamp)_copyq.dat"))

        // Read from sourceDir with CopyQSyncFolder
        let sourceContents = try CopyQSyncFolder.read(atPath: sourceDir.path)
        expectEqual(sourceContents.items.count, 1)
        let readItem = sourceContents.items.first!

        // Import into store
        let importReport = try CopyQSyncBridge.importSyncFolder(atPath: sourceDir.path, intoTabID: tab.id, in: store)
        expectEqual(importReport.importedCount, 1)

        // Perform dry-run export into scratchDir
        let exportedFiles = try CopyQSyncBridge.dryRunExport(tabID: tab.id, in: store, into: scratchDir.path)
        expectEqual(exportedFiles, writtenSourceFiles, "exported file list should match original file set")

        // Re-read scratchDir with CopyQSyncFolder
        let scratchContents = try CopyQSyncFolder.read(atPath: scratchDir.path)
        expectEqual(scratchContents.items.count, 1)
        let reReadItem = scratchContents.items.first!

        // Prove byte-identical round-trip
        expectEqual(reReadItem.baseName, readItem.baseName, "stem baseName must match")
        expectEqual(reReadItem.notes, readItem.notes, "notes must match")
        expectEqual(reReadItem.isPinned, readItem.isPinned, "pinned state must match")
        expectEqual(reReadItem.data.formats, readItem.data.formats, "formats must match")
        for format in readItem.data.formats {
            expectEqual(reReadItem.data.bytes(format), readItem.data.bytes(format), "bytes for format \(format) must match")
        }

        // Compare actual file bytes on disk between sourceDir and scratchDir
        for fileName in writtenSourceFiles {
            let sourceBytes = try Data(contentsOf: sourceDir.appendingPathComponent(fileName))
            let scratchBytes = try Data(contentsOf: scratchDir.appendingPathComponent(fileName))
            expectEqual(scratchBytes, sourceBytes, "file \(fileName) on disk must be byte-for-byte identical")
        }
    }

    TestRunner.add("sync folder round trip strips the private created-at flavour") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.ensureDefaultTab(name: "CreatedAtTab")
            let sourceDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-created-at-source-\(UUID().uuidString)")
            let scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-created-at-scratch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: sourceDir)
                try? FileManager.default.removeItem(at: scratchDir)
            }

            var data = CopyQDataMap()
            data.set(CopyQFormat.text, Data("created at payload".utf8))
            guard let createdBytes = CopyQFormat.encodeCreatedAt(Date(timeIntervalSince1970: 1_700_000_700.5)) else {
                TestRunner.fail("created-at encodes")
                return
            }
            data.set(CopyQFormat.macItemCreatedAt, createdBytes)
            try CopyQSyncFolder.write(
                CopyQSyncItem(baseName: "copyq_20261025120000001", data: data),
                into: sourceDir.path
            )

            let importReport = try CopyQSyncBridge.importSyncFolder(
                atPath: sourceDir.path,
                intoTabID: tab.id,
                in: store
            )
            expectEqual(importReport.importedCount, 1, "sync item imports")

            let entries = try store.recentEntries(limit: 10, tabID: tab.id)
            let entry = try unwrap(entries.first)
            expect(
                !entry.flavours.contains { $0.type == CopyQFormat.macItemCreatedAt },
                "created-at flavour is not stored"
            )

            _ = try CopyQSyncBridge.dryRunExport(tabID: tab.id, in: store, into: scratchDir.path)
            let scratch = try CopyQSyncFolder.read(atPath: scratchDir.path)
            let reread = try unwrap(scratch.items.first)
            expect(
                !reread.data.contains(CopyQFormat.macItemCreatedAt),
                "created-at flavour is not written back to the sync folder"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("sync folder re-import deduplicates a natively captured entry and imports a new item") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.ensureDefaultTab(name: "SyncDedupe")
            try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_900),
                tabID: tab.id,
                flavours: [Fixtures.text("native sync text")]
            ))

            let sourceDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-sync-dedupe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sourceDir) }

            _ = try CopyQSyncBridge.dryRunExport(tabID: tab.id, in: store, into: sourceDir.path)
            var newData = CopyQDataMap()
            newData.set(CopyQFormat.text, Data("brand new sync text".utf8))
            try CopyQSyncFolder.write(
                CopyQSyncItem(baseName: "copyq_20261025120000002", data: newData),
                into: sourceDir.path
            )

            let report = try CopyQSyncBridge.importSyncFolder(
                atPath: sourceDir.path,
                intoTabID: tab.id,
                in: store
            )
            expectEqual(report.importedCount, 1, "only the genuinely new sync item is imported")
            expectEqual(report.duplicateCount, 1, "the natively captured entry is skipped")
            expectEqual(try store.count(tabID: tab.id), 2, "the duplicate does not grow the tab")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("different sync file names keep separate identities even with identical payload during folder import") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.ensureDefaultTab(name: "SyncIdenticalPayload")

            let sourceDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-sync-ident-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sourceDir) }

            var data = CopyQDataMap()
            data.set(CopyQFormat.text, Data("Identical fingerprint payload".utf8))
            try CopyQSyncFolder.write(
                CopyQSyncItem(baseName: "copyq_20261025120000051", data: data),
                into: sourceDir.path
            )
            try CopyQSyncFolder.write(
                CopyQSyncItem(baseName: "copyq_20261025120000052", data: data),
                into: sourceDir.path
            )

            let report = try CopyQSyncBridge.importSyncFolder(
                atPath: sourceDir.path,
                intoTabID: tab.id,
                in: store
            )
            expectEqual(report.importedCount, 2, "both sync file names import as distinct entries")
            expectEqual(report.duplicateCount, 0, "neither file is treated as duplicate on initial import")
            expectEqual(try store.count(tabID: tab.id), 2, "store holds both entries")

            let secondReport = try CopyQSyncBridge.importSyncFolder(
                atPath: sourceDir.path,
                intoTabID: tab.id,
                in: store
            )
            expectEqual(secondReport.importedCount, 0, "no new items imported on repeat")
            expectEqual(secondReport.duplicateCount, 2, "both existing file names are recognized as repeats")
            expectEqual(try store.count(tabID: tab.id), 2, "store count remains 2")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("empty sync folder import does no whole-tab fingerprint work") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.ensureDefaultTab(name: "EmptyImport")
            try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_001_100),
                tabID: tab.id,
                flavours: [Fixtures.text("existing entry")]
            ))

            let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-empty-import-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyDir) }

            FingerprintProbe.reset()
            let report = try CopyQSyncBridge.importSyncFolder(
                atPath: emptyDir.path,
                intoTabID: tab.id,
                in: store
            )
            expectEqual(report.importedCount, 0, "empty sync folder imports nothing")
            expectEqual(FingerprintProbe.count, 0, "empty sync folder import does not hash the tab")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("dry-run writer refuses to write into protected directories") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "SafetyTab")
        let entry = ClipboardEntry(createdAt: Date(), tabID: tab.id, flavours: [Fixtures.text("safe")])
        try store.insert(entry)

        let home = NSHomeDirectory()
        let protected1 = (home as NSString).appendingPathComponent("Library/Application Support/copyq/scratch")
        let protected2 = (home as NSString).appendingPathComponent(".config/copyq/scratch")
        let protected3 = "/Volumes/Data/Syncthing/Config/CopyQ/test"
        let caseProtected1 = (home as NSString).appendingPathComponent("LIBRARY/APPLICATION SUPPORT/COPYQ/SCRATCH")
        let caseProtected2 = (home as NSString).appendingPathComponent("Library/Application Support/CopyQ/scratch")
        let caseProtected3 = "/volumes/data/syncthing/config/copyq/test"

        for path in [protected1, protected2, protected3, caseProtected1, caseProtected2, caseProtected3] {
            expectThrows({
                _ = try CopyQSyncBridge.dryRunExport(tabID: tab.id, in: store, into: path)
            }, "should refuse dry-run export into protected path: \(path)")
        }

        let tabSyncFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tab-sync-protected-\(UUID().uuidString)").path
        _ = try store.insertTab(ClipboardTab(name: "ProtectedTab", syncFolder: tabSyncFolder))

        expectThrows({
            _ = try CopyQSyncBridge.dryRunExport(tabID: tab.id, in: store, into: tabSyncFolder)
        }, "should refuse dry-run export into configured tab syncFolder")

        expectThrows({
            _ = try CopyQSyncBridge.dryRunExport(tabID: tab.id, in: store, into: tabSyncFolder + "/subfolder")
        }, "should refuse dry-run export into subfolder of configured tab syncFolder")
    }

    TestRunner.add("formatTimestamp truncates nanoseconds and never overflows to 1000ms") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 10
        comps.day = 25
        comps.hour = 12
        comps.minute = 30
        comps.second = 45
        comps.nanosecond = 999_500_000

        guard let testDate = calendar.date(from: comps) else {
            TestRunner.fail("could not construct test date")
            return
        }

        let formatted = CopyQSyncBridge.formatTimestamp(testDate)
        expectEqual(formatted.count, 23, "timestamp must be 23 characters")
        expect(formatted.hasPrefix("copyq_20261025123045"), "timestamp date/time prefix must match")
        expectEqual(formatted, "copyq_20261025123045999", "millisecond must be 999, not 1000")

        let parsed = CopyQSyncItem.parseTimestamp(baseName: formatted)
        expectNotNil(parsed, "parsed timestamp must not be nil")
    }

    TestRunner.add("entryToItem converts macOS file URLs to CopyQ uri-list") {
        let fileURL = URL(fileURLWithPath: "/tmp/sample-document.pdf")
        let urlFlavour = Flavour(
            itemIndex: 0,
            type: PasteboardTypes.fileURL,
            data: Data(fileURL.absoluteString.utf8)
        )
        let entry = ClipboardEntry(createdAt: Date(), tabID: 1, flavours: [urlFlavour])
        let item = CopyQSyncBridge.entryToItem(entry)

        expect(item.data.contains(CopyQFormat.uriList), "must contain text/uri-list format")
        expect(!item.data.contains(PasteboardTypes.fileURL), "must not store native macOS file URL format")

        let files = item.onDiskFiles()
        expect(files.keys.contains(".uri"), "files on disk must contain .uri")
        expect(!files.keys.contains(CopyQFormat.dataFileSuffix), "should not write _copyq.dat when only known files exist")

        if let uriData = files[".uri"] {
            let content = String(decoding: uriData, as: UTF8.self)
            expect(content.contains(fileURL.absoluteString), "uri file content must contain file url")
        }
    }

    TestRunner.add("importConfiguredSyncFolders imports all tabs with configured syncFolder") {
        let store = try ClipboardStore(inMemory: true)

        let folderA = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syncA-\(UUID().uuidString)")
        let folderB = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syncB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
        }

        let tabA = try store.insertTab(ClipboardTab(name: "TabA", syncFolder: folderA.path))
        let tabB = try store.insertTab(ClipboardTab(name: "TabB", syncFolder: folderB.path))
        _ = try store.insertTab(ClipboardTab(name: "TabC", syncFolder: nil))

        var dataA = CopyQDataMap()
        dataA.set(CopyQFormat.text, Data("Sync A content".utf8))
        let itemA = CopyQSyncItem(baseName: "copyq_20261025120000001", data: dataA)
        try CopyQSyncFolder.write(itemA, into: folderA.path)

        var dataB = CopyQDataMap()
        dataB.set(CopyQFormat.text, Data("Sync B content".utf8))
        let itemB = CopyQSyncItem(baseName: "copyq_20261025120000002", data: dataB)
        try CopyQSyncFolder.write(itemB, into: folderB.path)

        let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: store)
        expectEqual(report.importedCount, 2)
        expectEqual(try store.count(tabID: tabA.id), 1)
        expectEqual(try store.count(tabID: tabB.id), 1)
    }

    TestRunner.add("importConfiguredSyncFolders continues on per-tab errors and records failures") {
        let store = try ClipboardStore(inMemory: true)

        let validFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("validSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: validFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: validFolder) }

        let invalidFolder = "/tmp/non-existent-folder-\(UUID().uuidString)"

        let invalidTab = try store.insertTab(ClipboardTab(name: "InvalidTab", syncFolder: invalidFolder))
        let validTab = try store.insertTab(ClipboardTab(name: "ValidTab", syncFolder: validFolder.path))

        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("Valid content".utf8))
        let item = CopyQSyncItem(baseName: "copyq_20261025120000001", data: data)
        try CopyQSyncFolder.write(item, into: validFolder.path)

        let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: store)
        expectEqual(report.importedCount, 1, "valid tab should still be imported")
        expectEqual(report.failedCount, 1, "invalid tab should be counted as failure")
        expectEqual(report.failures.count, 1, "failure message should be recorded")
        expectEqual(try store.count(tabID: validTab.id), 1)
        expectEqual(try store.count(tabID: invalidTab.id), 0)
    }

    TestRunner.add("importSyncFolder skips a folder claimed by more than one tab") {
        let store = try ClipboardStore(inMemory: true)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-ambiguous-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let explicitTabName = "Workstation"
        let fedora = try store.insertTab(ClipboardTab(name: "Fedora", syncFolder: tempDir.path))
        let workstation = try store.insertTab(ClipboardTab(name: explicitTabName, syncFolder: tempDir.path))
        let tabsBefore = try store.tabs().count

        let stem = "copyq_20261025120000091"
        let file = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Ambiguous manual import".utf8).write(to: file)

        let report = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, in: store)
        expectEqual(report.importedCount, 0, "an ambiguous folder imports nothing")
        expectEqual(report.failedCount, 1, "the ambiguity is reported as a failure")
        expect(report.failures.first?.contains("multiple tabs claim") == true, "the failure names the conflict")
        expect(report.failures.first?.contains("Fedora") == true, "the failure names the Fedora tab")
        expect(report.failures.first?.contains(explicitTabName) == true, "the failure names the explicit fixture tab")
        expectEqual(try store.count(tabID: fedora.id), 0, "the Fedora tab stays empty")
        expectEqual(try store.count(tabID: workstation.id), 0, "the second tab stays empty")
        expectEqual(try store.tabs().count, tabsBefore, "no new tab is created")

        let hinted = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: fedora.id, in: store)
        expectEqual(hinted.importedCount, 0, "an explicit tab id cannot import an ambiguous folder")
        expectEqual(hinted.failedCount, 1, "the explicit path reports the ambiguity too")
        expectEqual(try store.count(tabID: fedora.id), 0, "the explicit tab stays empty")
        expectEqual(try store.count(tabID: workstation.id), 0, "the second tab stays empty")
    }

    TestRunner.add("importConfiguredSyncFolders skips an ambiguous folder once") {
        let store = try ClipboardStore(inMemory: true)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-ambiguous-configured-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let explicitTabName = "Workstation"
        let fedora = try store.insertTab(ClipboardTab(name: "Fedora", syncFolder: tempDir.path))
        let workstation = try store.insertTab(ClipboardTab(name: explicitTabName, syncFolder: tempDir.path))
        let tabsBefore = try store.tabs().count

        let stem = "copyq_20261025120000092"
        let file = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Ambiguous configured import".utf8).write(to: file)

        let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: store)
        expectEqual(report.importedCount, 0, "the ambiguous folder imports nothing")
        expectEqual(report.failedCount, 1, "the ambiguity is reported once")
        expectEqual(report.failures.count, 1, "one diagnostic covers both claiming tabs")
        expectEqual(try store.count(tabID: fedora.id), 0, "the Fedora tab stays empty")
        expectEqual(try store.count(tabID: workstation.id), 0, "the second tab stays empty")
        expectEqual(try store.tabs().count, tabsBefore, "no new tab is created")
    }

    TestRunner.add("findOrCreateTab refuses an ambiguous folder without creating a tab") {
        let store = try ClipboardStore(inMemory: true)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-ambiguous-find-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let explicitTabName = "Workstation"
        _ = try store.insertTab(ClipboardTab(name: "Fedora", syncFolder: tempDir.path))
        _ = try store.insertTab(ClipboardTab(name: explicitTabName, syncFolder: tempDir.path))
        let tabsBefore = try store.tabs().count

        var message: String?
        do {
            _ = try CopyQSyncBridge.findOrCreateTab(forFolder: tempDir.path, in: store)
        } catch {
            message = error.localizedDescription
        }
        expectNotNil(message, "an ambiguous folder throws instead of creating a tab")
        expect(message?.contains("multiple tabs claim") == true, "the error names the conflict")
        expect(message?.contains("Fedora") == true, "the error names the Fedora tab")
        expect(message?.contains(explicitTabName) == true, "the error names the explicit fixture tab")
        expectEqual(try store.tabs().count, tabsBefore, "no new tab is created")
    }

    TestRunner.add("PasteboardBridge write enriches mime flavours and filters bookkeeping metadata") {
        let pboard = NSPasteboard(name: .init("copyqmac-enrichment-test-\(UUID().uuidString)"))
        pboard.declareTypes([], owner: nil)

        let rtf = Data(#"{\rtf1\ansi Item 3 rich}"#.utf8)
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.mimeTextUtf8, data: Data("Plain UTF8".utf8)),
            Flavour(itemIndex: 0, type: "application/x-copyq-itemsync-base-name", data: Data("copyq_test".utf8)),
            Flavour(itemIndex: 1, type: PasteboardTypes.mimeText, data: Data("Item 1 text".utf8)),
            Flavour(itemIndex: 1, type: PasteboardTypes.mimeHtml, data: Data("<b>bold</b>".utf8)),
            Flavour(itemIndex: 2, type: PasteboardTypes.mimeUriList, data: Data("file:///tmp/enriched.txt\r\n".utf8)),
            Flavour(itemIndex: 3, type: PasteboardTypes.mimeRtf, data: rtf),
        ]

        PasteboardBridge.write(flavours, to: pboard)
        let snapshot = PasteboardBridge.snapshot(of: pboard)

        let item0Utf8 = snapshot.first { $0.itemIndex == 0 && $0.type == PasteboardTypes.utf8Text }
        expectNotNil(item0Utf8, "item 0 should be enriched with utf8Text")

        let leakedMeta = snapshot.first { $0.type == "application/x-copyq-itemsync-base-name" }
        expect(leakedMeta == nil, "private bookkeeping metadata must not leak to pasteboard")

        let item1Utf8 = snapshot.first { $0.itemIndex == 1 && $0.type == PasteboardTypes.utf8Text }
        expectNotNil(item1Utf8, "item 1 should be enriched with utf8Text")
        let item1Html = snapshot.first { $0.itemIndex == 1 && $0.type == PasteboardTypes.html }
        expectNotNil(item1Html, "item 1 should be enriched with html")

        let item2FileURL = snapshot.first { $0.itemIndex == 2 && $0.type == PasteboardTypes.fileURL }
        expectNotNil(item2FileURL, "item 2 should be enriched with fileURL")

        // Rows imported before the import mapping existed still carry the CopyQ
        // MIME names; pasting them must still produce native rich text.
        let item3Rtf = snapshot.first { $0.itemIndex == 3 && $0.type == PasteboardTypes.rtf }
        expectEqual(item3Rtf?.data, rtf, "a legacy text/rtf flavour is enriched with public.rtf")
    }

    TestRunner.add("re-importing a sync item with a newer date refreshes the stored timestamp") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "SyncTab")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stem = "copyq_20240101000000000"
        let first = Date(timeIntervalSince1970: 1_792_969_788)
        let later = first.addingTimeInterval(86_400)
        let file = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Repeated sync payload".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: first], ofItemAtPath: file.path)

        let firstReport = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(firstReport.importedCount, 1, "the first import stores the item")
        expectEqual(try store.count(tabID: tab.id), 1, "one row is stored")
        let firstStored = try store.recentEntries(limit: 10, tabID: tab.id).first?.createdAt
        expectNotNil(firstStored, "the first row is readable")
        if let firstStored {
            expect(abs(firstStored.timeIntervalSince(first)) < 0.01, "the first resolved date is stored")
        }

        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
        let secondReport = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(secondReport.importedCount, 0, "the repeat does not create a second row")
        expectEqual(secondReport.duplicateCount, 1, "the repeat is a duplicate identity")
        expectEqual(try store.count(tabID: tab.id), 1, "the repeat keeps one row")
        let secondStored = try store.recentEntries(limit: 10, tabID: tab.id).first?.createdAt
        expectNotNil(secondStored, "the row is still readable")
        if let secondStored {
            expect(abs(secondStored.timeIntervalSince(later)) < 0.01, "the newer resolved date replaces the stale one")
        }
    }

    TestRunner.add("an old payload-only row matches the same sync file name without duplicating") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "LegacySyncTab")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-test-legacy-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stem = "copyq_20240101000000000"
        guard let stale = CopyQSyncItem.parseTimestamp(baseName: stem) else {
            expect(false, "the canonical sync stem parses")
            return
        }
        let recent = Date(timeIntervalSince1970: 1_792_969_788)
        let file = tempDir.appendingPathComponent("\(stem).txt")
        try Data("Legacy sync payload".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: file.path)

        // The previous build stored a canonical 17-digit name as a payload-only
        // fingerprint with no base-name bookkeeping flavour.
        let legacy = try store.insert(ClipboardEntry(
            createdAt: stale,
            tabID: tab.id,
            flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Legacy sync payload".utf8))]
        ))

        let report = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report.importedCount, 0, "the legacy row must not gain a duplicate")
        expectEqual(report.duplicateCount, 1, "the same sync file name is the same item")
        expectEqual(report.updatedCount, 0)
        expectEqual(try store.count(tabID: tab.id), 1, "one row remains")
        let stored = try store.recentEntries(limit: 10, tabID: tab.id).first
        expectEqual(stored?.id, legacy.id, "the legacy row is the one refreshed")
        if let stored {
            expect(abs(stored.createdAt.timeIntervalSince(recent)) < 0.01, "the legacy row gets the newer resolved date")
        }
    }

    TestRunner.add("re-importing an archive preserves the original creation date") {
        let store = try ClipboardStore(inMemory: true)

        var item = CopyQSyncItem()
        item.data.set(CopyQFormat.text, Data("Archive refresh payload".utf8))

        var stream = QDataStreamWriter()
        stream.writeQByteArray(Data("CopyQ v4".utf8))
        stream.writeUInt32(1)
        stream.writeQString("tabs")
        stream.writeUInt32(11)
        stream.writeBool(false)
        stream.writeQStringList(["RefreshTab"])
        stream.writeUInt32(2)
        stream.writeQString("name")
        stream.writeUInt32(10)
        stream.writeBool(false)
        stream.writeQString("RefreshTab")
        stream.writeQString("data")
        stream.writeUInt32(12)
        stream.writeBool(false)
        stream.writeQByteArray(CopyQArchive.encodeItemListForTesting([item]))

        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_refresh_\(UUID().uuidString).cpq")
        try stream.data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let firstReport = try CopyQSyncBridge.importArchive(atPath: tempFile.path, in: store)
        expectEqual(firstReport.importedCount, 1, "the first archive import stores the item")
        let tab = try store.tabs().first { $0.name == "RefreshTab" }
        expectNotNil(tab, "the archive tab exists")
        guard let tab else { return }
        let firstStored = try store.recentEntries(limit: 10, tabID: tab.id).first?.createdAt
        expectNotNil(firstStored, "the first archive row is readable")

        Thread.sleep(forTimeInterval: 0.02)
        let secondReport = try CopyQSyncBridge.importArchive(atPath: tempFile.path, in: store)
        expectEqual(secondReport.importedCount, 0, "the second archive import does not duplicate")
        expectEqual(secondReport.duplicateCount, 1, "the second archive import is a duplicate identity")
        expectEqual(try store.count(tabID: tab.id), 1, "the archive repeat keeps one row")
        let secondStored = try store.recentEntries(limit: 10, tabID: tab.id).first?.createdAt
        expectNotNil(secondStored, "the archive row is still readable")
        if let firstStored, let secondStored {
            expect(abs(secondStored.timeIntervalSince(firstStored)) < 0.001, "a repeat with no date candidate keeps the stored date")
        }
    }

    TestRunner.add("opening a version-5 store repairs stale dates of imported sync entries") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let syncFolder = directory.appendingPathComponent("fedora")
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path

        let store = try ClipboardStore(path: path)
        let tab = try store.insertTab(ClipboardTab(name: "Fedora", syncFolder: syncFolder.path))

        let stem = "copyq_2024120703474115664"
        guard let stale = CopyQSyncItem.parseTimestamp(baseName: stem) else {
            expect(false, "the stale stem parses")
            return
        }
        let recent = Date(timeIntervalSince1970: 1_792_969_788)
        let file = syncFolder.appendingPathComponent("\(stem).txt")
        try Data("Stale Fedora clip".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: file.path)

        let inserted = try store.insert(ClipboardEntry(
            createdAt: stale,
            tabID: tab.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Stale Fedora clip".utf8)),
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(stem.utf8)),
            ]
        ))

        let missingStem = "copyq_20231201000000000"
        guard let missingDate = CopyQSyncItem.parseTimestamp(baseName: missingStem) else {
            expect(false, "the missing stem parses")
            return
        }
        let untouched = try store.insert(ClipboardEntry(
            createdAt: missingDate,
            tabID: tab.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Backing file is gone".utf8)),
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(missingStem.utf8)),
            ]
        ))

        let legacyDatabase = try SQLiteDatabase(path: path)
        legacyDatabase.userVersion = 5

        let migrated = try ClipboardStore(path: path)
        expectEqual(migrated.database.userVersion, ClipboardStore.currentSchemaVersion)
        let repaired = try migrated.entry(id: inserted.id)
        expectNotNil(repaired, "the imported entry still exists")
        if let repaired {
            expect(abs(repaired.createdAt.timeIntervalSince(recent)) < 0.01, "the repair uses the newer backing file date")
            expectEqual(repaired.tabID, tab.id, "the repair keeps the entry in its tab")
        }
        let leftAlone = try migrated.entry(id: untouched.id)
        expectNotNil(leftAlone, "the entry without a backing file still exists")
        if let leftAlone {
            expect(abs(leftAlone.createdAt.timeIntervalSince(missingDate)) < 0.002, "a missing backing file keeps the stored date")
        }

        let watcher = CopyQSyncWatcher(store: migrated)
        let notified = watcher.scanAllWatchedFolders(store: migrated)
        expectEqual(notified.count, 1, "the repaired row is in the notification list")
        expectEqual(notified.first?.id, inserted.id, "the notification names the repaired row")
        if let notifiedDate = notified.first?.createdAt {
            expect(abs(notifiedDate.timeIntervalSince(recent)) < 0.01, "the notification carries the corrected date")
        }
        expect(migrated.takeSyncRepairs().isEmpty, "the repair notification is drained once")
    }

    TestRunner.add("the version-5 repair moves a row to the tab that owns its backing folder") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let syncFolder = directory.appendingPathComponent("fedora")
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path

        let store = try ClipboardStore(path: path)
        let archive = try store.insertTab(ClipboardTab(name: "Archive", syncFolder: nil))
        let fedora = try store.insertTab(ClipboardTab(name: "Fedora", syncFolder: syncFolder.path))

        let stem = "copyq_2024120703474115664"
        guard let stale = CopyQSyncItem.parseTimestamp(baseName: stem) else {
            expect(false, "the stale stem parses")
            return
        }
        let recent = Date(timeIntervalSince1970: 1_792_969_788)
        let file = syncFolder.appendingPathComponent("\(stem).txt")
        try Data("Misrouted Fedora clip".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: file.path)

        let inserted = try store.insert(ClipboardEntry(
            createdAt: stale,
            tabID: archive.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Misrouted Fedora clip".utf8)),
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(stem.utf8)),
            ]
        ))

        let legacyDatabase = try SQLiteDatabase(path: path)
        legacyDatabase.userVersion = 5

        let migrated = try ClipboardStore(path: path)
        let repaired = try migrated.entry(id: inserted.id)
        expectNotNil(repaired, "the row still exists")
        if let repaired {
            expect(abs(repaired.createdAt.timeIntervalSince(recent)) < 0.01, "the repair corrects the stored date")
            expectEqual(repaired.tabID, fedora.id, "the repair moves the row to the tab that owns its folder")
        }
        expectEqual(try migrated.count(tabID: archive.id), 0, "the old tab no longer holds the row")
        expectEqual(try migrated.count(tabID: fedora.id), 1, "the owning tab holds exactly one row")
        let notified = CopyQSyncWatcher(store: migrated).scanAllWatchedFolders(store: migrated)
        expectEqual(notified.first?.id, inserted.id, "the relocated row is queued for notification")
    }

    TestRunner.add("the version-5 repair skips a row whose backing group is in two folders") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folderA = directory.appendingPathComponent("a")
        let folderB = directory.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path

        let store = try ClipboardStore(path: path)
        let importedTab = try store.insertTab(ClipboardTab(name: "Imported", syncFolder: nil))
        _ = try store.insertTab(ClipboardTab(name: "A", syncFolder: folderA.path))
        _ = try store.insertTab(ClipboardTab(name: "B", syncFolder: folderB.path))

        let stem = "copyq_2024120703474115664"
        guard let stale = CopyQSyncItem.parseTimestamp(baseName: stem) else {
            expect(false, "the stale stem parses")
            return
        }
        let recent = Date(timeIntervalSince1970: 1_792_969_788)
        for folder in [folderA, folderB] {
            let file = folder.appendingPathComponent("\(stem).txt")
            try Data("Ambiguous backing group".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: file.path)
        }

        let inserted = try store.insert(ClipboardEntry(
            createdAt: stale,
            tabID: importedTab.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Ambiguous backing group".utf8)),
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(stem.utf8)),
            ]
        ))

        let legacyDatabase = try SQLiteDatabase(path: path)
        legacyDatabase.userVersion = 5

        let migrated = try ClipboardStore(path: path)
        let unchanged = try migrated.entry(id: inserted.id)
        expectNotNil(unchanged, "the row still exists")
        if let unchanged {
            expect(abs(unchanged.createdAt.timeIntervalSince(stale)) < 0.002, "an ambiguous backing group keeps the stored date")
        }
        expect(migrated.takeSyncRepairs().isEmpty, "an ambiguous row is not queued as a repair")
    }

    TestRunner.add("the version-5 repair leaves rows in folders with ambiguous or missing owners") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedFolder = directory.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path

        let store = try ClipboardStore(path: path)
        let archive = try store.insertTab(ClipboardTab(name: "Archive", syncFolder: nil))
        _ = try store.insertTab(ClipboardTab(name: "Fedora", syncFolder: sharedFolder.path))
        _ = try store.insertTab(ClipboardTab(name: "Other", syncFolder: sharedFolder.path))

        let sharedStem = "copyq_2024120703474115664"
        guard let sharedStale = CopyQSyncItem.parseTimestamp(baseName: sharedStem) else {
            expect(false, "the shared stem parses")
            return
        }
        let recent = Date(timeIntervalSince1970: 1_792_969_788)
        let sharedFile = sharedFolder.appendingPathComponent("\(sharedStem).txt")
        try Data("Ambiguous owner".utf8).write(to: sharedFile)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: sharedFile.path)
        let sharedRow = try store.insert(ClipboardEntry(
            createdAt: sharedStale,
            tabID: archive.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Ambiguous owner".utf8)),
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(sharedStem.utf8)),
            ]
        ))

        let missingStem = "copyq_2024120703474115777"
        guard let missingStale = CopyQSyncItem.parseTimestamp(baseName: missingStem) else {
            expect(false, "the missing stem parses")
            return
        }
        let missingRow = try store.insert(ClipboardEntry(
            createdAt: missingStale,
            tabID: archive.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Missing owner".utf8)),
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(missingStem.utf8)),
            ]
        ))

        let legacyDatabase = try SQLiteDatabase(path: path)
        legacyDatabase.userVersion = 5

        let migrated = try ClipboardStore(path: path)
        let sharedUnchanged = try migrated.entry(id: sharedRow.id)
        expectEqual(sharedUnchanged?.tabID, archive.id, "an ambiguous owning tab leaves the row where it was")
        if let createdAt = sharedUnchanged?.createdAt {
            expect(abs(createdAt.timeIntervalSince(sharedStale)) < 0.002, "an ambiguous owning tab keeps the old date")
        }
        let missingUnchanged = try migrated.entry(id: missingRow.id)
        expectEqual(missingUnchanged?.tabID, archive.id, "a row with no owning folder stays where it was")
        if let createdAt = missingUnchanged?.createdAt {
            expect(abs(createdAt.timeIntervalSince(missingStale)) < 0.002, "a row with no owning folder keeps the old date")
        }
    }

    TestRunner.add("the version-5 repair does not move a row when the owning tab already has it") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let syncFolder = directory.appendingPathComponent("fedora")
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.sqlite").path

        let store = try ClipboardStore(path: path)
        let archive = try store.insertTab(ClipboardTab(name: "Archive", syncFolder: nil))
        let fedora = try store.insertTab(ClipboardTab(name: "Fedora", syncFolder: syncFolder.path))

        let stem = "copyq_2024120703474115664"
        guard let stale = CopyQSyncItem.parseTimestamp(baseName: stem) else {
            expect(false, "the stale stem parses")
            return
        }
        let recent = Date(timeIntervalSince1970: 1_792_969_788)
        let file = syncFolder.appendingPathComponent("\(stem).txt")
        try Data("Already in Fedora".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: file.path)

        let flavours: [Flavour] = [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Already in Fedora".utf8)),
            Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(stem.utf8)),
        ]
        _ = try store.insert(ClipboardEntry(createdAt: recent, tabID: fedora.id, flavours: flavours))
        let staleRow = try store.insert(ClipboardEntry(createdAt: stale, tabID: archive.id, flavours: flavours))

        let legacyDatabase = try SQLiteDatabase(path: path)
        legacyDatabase.userVersion = 5

        let migrated = try ClipboardStore(path: path)
        expectEqual(try migrated.entry(id: staleRow.id)?.tabID, archive.id, "the duplicate row is not moved")
        expectEqual(try migrated.count(tabID: archive.id), 1, "the old tab still holds the skipped row")
        expectEqual(try migrated.count(tabID: fedora.id), 1, "the owning tab keeps its single existing row")
    }

    TestRunner.add("opening a version-5 store makes written stems durable per folder") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path

        _ = try ClipboardStore(path: path)
        let legacyDatabase = try SQLiteDatabase(path: path)
        try legacyDatabase.execute("DROP TABLE written_sync_stems")
        try legacyDatabase.execute("""
            CREATE TABLE written_sync_stems (
                stem       TEXT PRIMARY KEY,
                folder     TEXT NOT NULL,
                written_at REAL NOT NULL
            )
            """)
        legacyDatabase.userVersion = 5

        let migrated = try ClipboardStore(path: path)
        let stem = "copyq_20241010101010123"
        try migrated.recordWrittenSyncStem(stem, folder: "/tmp/copyq-folder-a")
        try migrated.recordWrittenSyncStem(stem, folder: "/tmp/copyq-folder-b")
        let durable = try migrated.allWrittenSyncStemsByFolder()
        expect(durable["/tmp/copyq-folder-a"]?.contains(stem) == true, "folder A keeps its durable row")
        expect(durable["/tmp/copyq-folder-b"]?.contains(stem) == true, "folder B keeps its durable row")
        expect(try migrated.isWrittenSyncStem(stem, folder: "/tmp/copyq-folder-a"), "folder A lookup still matches")
        expect(try migrated.isWrittenSyncStem(stem, folder: "/tmp/copyq-folder-b"), "folder B lookup still matches")
    }

    TestRunner.add("export backup round-trips tabs, order, notes, pins and flavours") {
        do {
            let (source, clipboard, _) = try backupFixtureStore()
            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("backup.cpq")

            var progress: [CopyQSyncBridge.ExportProgress] = []
            let report = try CopyQSyncBridge.exportArchive(
                toPath: archiveURL.path,
                in: source
            ) { progress.append($0) }

            expectEqual(report.tabNames, ["Clipboard", "Fedora"], "report lists every tab in order")
            expectEqual(report.itemCount, 4, "report counts every item")
            expect(FileManager.default.fileExists(atPath: archiveURL.path), "report path exists")
            expectEqual(progress.last?.exportedItems, 4, "progress reaches the item count")
            expectEqual(progress.last?.totalItems, 4, "progress knows the total up front")
            expectEqual(progress.last?.fraction, 1, "progress ends at 100%")

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            expectEqual(archive.format, .v4, "backup is a CopyQ v4 archive")
            expectEqual(archive.tabNames, ["Clipboard", "Fedora"], "archive keeps the tab list")
            expectEqual(archive.failures.count, 0, "archive has no flavour failures")

            // Pinned entries come first, then newest first: the order the list shows.
            let sourceClipboard = try source.recentEntries(limit: 100, tabID: clipboard.id)
            expectEqual(
                archive.tabItems["Clipboard"]?.map(\.notes),
                sourceClipboard.map { $0.note.isEmpty ? nil : $0.note },
                "archive keeps item order"
            )

            let richItem = try unwrap(archive.tabItems["Clipboard"]?.first)
            expectEqual(
                Set(richItem.data.formats),
                Set([
                    CopyQFormat.text,
                    CopyQFormat.html,
                    "image/png",
                    CopyQFormat.itemNotes,
                    CopyQFormat.itemPinned,
                ]),
                "archive writes native pasteboard flavours under CopyQ MIME names"
            )
            expectEqual(richItem.data.bytes(CopyQFormat.text), Data("rich entry".utf8), "text payload is byte for byte")
            expectEqual(richItem.data.bytes(CopyQFormat.html), Data("<b>rich entry</b>".utf8), "html payload is byte for byte")
            expectEqual(richItem.data.bytes("image/png"), Fixtures.pngData, "image payload is byte for byte")
            expect(richItem.isPinned, "archive carries the pin")

            let fileItem = try unwrap(archive.tabItems["Clipboard"]?.first { $0.notes == "file note" })
            expectEqual(
                fileItem.data.bytes(CopyQFormat.uriList).map { String(decoding: $0, as: UTF8.self) },
                "file:///tmp/report.pdf\r\n",
                "a single file maps to text/uri-list"
            )
            expectEqual(
                fileItem.data.bytes("com.example.custom-flavour"),
                Data([0x00, 0x01, 0xFE, 0xFF]),
                "an unknown type keeps its identifier and bytes"
            )

            // Restore into a fresh history: notes, pins and capture times stay,
            // and the CopyQ MIME names paste back as native pasteboard types.
            let restored = try ClipboardStore(inMemory: true)
            let importReport = try CopyQSyncBridge.importArchive(atPath: archiveURL.path, in: restored)
            expectEqual(importReport.failedCount, 0, "restore reports no failures")
            expectEqual(importReport.importedCount, 4, "restore imports every item")

            let restoredTabs = try restored.tabs()
            let restoredClipboard = try unwrap(restoredTabs.first { $0.name == "Clipboard" })
            let restoredFedora = try unwrap(restoredTabs.first { $0.name == "Fedora" })

            let restoredClipboardEntries = try restored.recentEntries(limit: 100, tabID: restoredClipboard.id)
            let restoredFedoraEntries = try restored.recentEntries(limit: 100, tabID: restoredFedora.id)
            expectEqual(restoredClipboardEntries.map(\.note), sourceClipboard.map(\.note), "restored notes match")
            expectEqual(restoredClipboardEntries.map(\.pinned), sourceClipboard.map(\.pinned), "restored pins match")
            expectEqual(restoredClipboardEntries.map(\.createdAt), sourceClipboard.map(\.createdAt), "restored capture times match")
            expectEqual(restoredFedoraEntries.count, 1, "restored second tab keeps its item")

            let restoredRich = try unwrap(restoredClipboardEntries.first)
            let pboard = NSPasteboard(name: .init("copyq-export-restore-\(UUID().uuidString)"))
            PasteboardBridge.write(restoredRich.flavours, to: pboard)
            let pasted = PasteboardBridge.snapshot(of: pboard)
            expectEqual(
                pasted.first { $0.type == PasteboardTypes.utf8Text }?.data,
                Data("rich entry".utf8),
                "restored text pastes as native text"
            )
            expectEqual(
                pasted.first { $0.type == PasteboardTypes.html }?.data,
                Data("<b>rich entry</b>".utf8),
                "restored html pastes as native html"
            )
            expectEqual(
                pasted.first { $0.type == PasteboardTypes.png }?.data,
                Fixtures.pngData,
                "restored image pastes as native png"
            )

            let restoredFile = try unwrap(restoredClipboardEntries.first { $0.note == "file note" })
            let fileBoard = NSPasteboard(name: .init("copyq-export-file-\(UUID().uuidString)"))
            PasteboardBridge.write(restoredFile.flavours, to: fileBoard)
            let pastedFiles = PasteboardBridge.snapshot(of: fileBoard)
            expectEqual(
                pastedFiles.first { $0.type == PasteboardTypes.fileURL }?.data,
                Data("file:///tmp/report.pdf".utf8),
                "restored file pastes as a native file URL"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("archive re-import deduplicates entries already stored with native types") {
        do {
            let (store, clipboard, _) = try backupFixtureStore()
            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("reimport.cpq")
            _ = try CopyQSyncBridge.exportArchive(
                toPath: archiveURL.path,
                scope: .tab(clipboard.id),
                in: store
            )

            let clipboardCount = try store.count(tabID: clipboard.id)
            let report = try CopyQSyncBridge.importArchive(atPath: archiveURL.path, in: store)
            expectEqual(report.importedCount, 0, "re-import inserts no duplicate")
            expectEqual(report.duplicateCount, 3, "re-import reports every entry as duplicate")
            expectEqual(try store.count(tabID: clipboard.id), clipboardCount, "clipboard count is unchanged")

            let removed = try unwrap(
                store.recentEntries(limit: 100, tabID: clipboard.id).first { $0.note == "file note" }
            )
            try store.delete(id: removed.id)
            let afterDelete = try store.count(tabID: clipboard.id)
            let secondReport = try CopyQSyncBridge.importArchive(atPath: archiveURL.path, in: store)
            expectEqual(secondReport.importedCount, 1, "a genuinely new item is still imported")
            expectEqual(secondReport.duplicateCount, 2, "the remaining entries are skipped")
            expectEqual(try store.count(tabID: clipboard.id), afterDelete + 1, "the missing item is restored")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("sync-imported entry exports without internal stem flavour and re-imports without duplicating") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var tab = try store.ensureDefaultTab()
            tab.name = "SyncTab"
            try store.updateTab(tab)

            let tempDir = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let stem = "copyq_20261025120000001"
            var data = CopyQDataMap()
            data.set(CopyQFormat.text, Data("Synced item content".utf8))
            data.set(CopyQFormat.itemNotes, Data("Sync item note".utf8))
            data.set("application/x-copyq-itemsync-unknown-formats", Data("bookkeeping".utf8))
            data.set("application/x-copyq-private-tag", Data("secret".utf8))
            let item = CopyQSyncItem(baseName: stem, data: data)
            try CopyQSyncFolder.write(item, into: tempDir.path)

            let syncReport = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
            expectEqual(syncReport.importedCount, 1, "sync folder imports 1 item")
            let storedEntries = try store.recentEntries(limit: 10, tabID: tab.id)
            expectEqual(storedEntries.count, 1, "store holds 1 item")
            let imported = try unwrap(storedEntries.first)
            expect(
                imported.flavours.contains { $0.type == Fingerprint.syncBaseNameFlavour },
                "imported entry holds internal base name flavour in store"
            )
            expect(
                !imported.flavours.contains { $0.type == "application/x-copyq-itemsync-unknown-formats" },
                "imported entry does not store itemsync bookkeeping format"
            )
            expect(
                !imported.flavours.contains { $0.type == "application/x-copyq-private-tag" },
                "imported entry does not store private bookkeeping format"
            )

            let archiveURL = tempDir.appendingPathComponent("backup.cpq")
            _ = try CopyQSyncBridge.exportArchive(toPath: archiveURL.path, scope: .tab(tab.id), in: store)

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            let exportedItems = archive.tabItems["SyncTab"] ?? []
            expectEqual(exportedItems.count, 1, "archive contains the exported tab item")
            let exportedItem = try unwrap(exportedItems.first)
            expectEqual(exportedItem.data.bytes(CopyQFormat.text), Data("Synced item content".utf8), "archive holds content payload")
            expectEqual(exportedItem.notes, "Sync item note", "archive holds item note")
            expect(
                !exportedItem.data.contains(Fingerprint.syncBaseNameFlavour),
                "archive item does not contain internal sync base name flavour"
            )
            expect(
                !exportedItem.data.formats.contains { Fingerprint.isBookkeepingFlavour($0) },
                "archive item contains no bookkeeping formats"
            )

            let reimportReport = try CopyQSyncBridge.importArchive(atPath: archiveURL.path, in: store)
            expectEqual(reimportReport.importedCount, 0, "re-import does not duplicate sync-imported entry")
            expectEqual(reimportReport.duplicateCount, 1, "re-import detects existing entry as duplicate")
            expectEqual(try store.count(tabID: tab.id), 1, "store entry count is unchanged")

            let nativeStore = try ClipboardStore(inMemory: true)
            var nativeTab = try nativeStore.ensureDefaultTab()
            nativeTab.name = "SyncTab"
            try nativeStore.updateTab(nativeTab)
            try nativeStore.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: nativeTab.id,
                flavours: [Fixtures.text("Synced item content")]
            ))
            let nativeImportReport = try CopyQSyncBridge.importArchive(atPath: archiveURL.path, in: nativeStore)
            expectEqual(nativeImportReport.importedCount, 0, "import into store with matching native entry deduplicates")
            expectEqual(nativeImportReport.duplicateCount, 1, "native entry is matched as canonical duplicate")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("export current tab only writes that tab") {
        do {
            let (store, clipboard, _) = try backupFixtureStore()
            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("tab.cpq")

            let report = try CopyQSyncBridge.exportArchive(
                toPath: archiveURL.path,
                scope: .tab(clipboard.id),
                in: store
            )
            expectEqual(report.tabNames, ["Clipboard"], "single-tab export names one tab")
            expectEqual(report.itemCount, 3, "single-tab export counts one tab's items")

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            expectEqual(archive.tabNames, ["Clipboard"], "single-tab archive keeps one tab")
            expectEqual(archive.items.count, 3, "single-tab archive keeps that tab's items")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("export disambiguates duplicate tab names so restore keeps every item") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var work = try store.ensureDefaultTab()
            work.name = "Work"
            try store.updateTab(work)
            let second = try store.insertTab(ClipboardTab(name: "Work"))

            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("duplicate-tabs.cpq")

            for index in 0..<2 {
                try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    tabID: work.id,
                    flavours: [Flavour(itemIndex: 0, type: CopyQFormat.text, data: Data("first \(index)".utf8))]
                ))
            }
            for index in 0..<3 {
                try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)),
                    tabID: second.id,
                    flavours: [Flavour(itemIndex: 0, type: CopyQFormat.text, data: Data("second \(index)".utf8))]
                ))
            }

            let report = try CopyQSyncBridge.exportArchive(toPath: archiveURL.path, in: store)
            expectEqual(report.tabNames, ["Work", "Work (2)"], "report names the disambiguated tabs")
            expectEqual(report.renamedTabCount, 1, "report counts the renamed tab")
            expectEqual(report.itemCount, 5, "report still counts every item")
            expect(
                report.summary.contains("1 duplicate tab name renamed"),
                "summary reports the rename"
            )

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            expectEqual(archive.tabNames, ["Work", "Work (2)"], "archive names are unique")
            expectEqual(archive.tabItems["Work"]?.count, 2, "first tab keeps its items")
            expectEqual(archive.tabItems["Work (2)"]?.count, 3, "second tab keeps its items")

            let restored = try ClipboardStore(inMemory: true)
            let importReport = try CopyQSyncBridge.importArchive(atPath: archiveURL.path, in: restored)
            expectEqual(importReport.importedCount, 5, "restore imports every item")
            let restoredTabs = try restored.tabs()
            let restoredWork = try unwrap(restoredTabs.first { $0.name == "Work" })
            let restoredSecond = try unwrap(restoredTabs.first { $0.name == "Work (2)" })
            expectEqual(try restored.count(tabID: restoredWork.id), 2, "restored first tab keeps its item count")
            expectEqual(try restored.count(tabID: restoredSecond.id), 3, "restored second tab keeps its item count")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("export allows sync folder destinations and reports that they will sync") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let syncFolder = directory.appendingPathComponent("Fedora", isDirectory: true)
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
            var tab = try store.ensureDefaultTab(name: "Fedora")
            tab.syncFolder = syncFolder.path
            try store.updateTab(tab)

            let existingItem = syncFolder.appendingPathComponent("copyq_20261025120000001.txt")
            try Data("existing sync item".utf8).write(to: existingItem)

            let insideSyncFolder = syncFolder.appendingPathComponent("backup.cpq")
            let report = try CopyQSyncBridge.exportArchive(toPath: insideSyncFolder.path, in: store)
            expect(
                FileManager.default.fileExists(atPath: insideSyncFolder.path),
                "export writes inside a configured tab sync folder"
            )
            expect(report.syncDestination, "export reports that the archive will sync")
            expect(
                report.summary.contains("The archive will sync to your other devices"),
                "summary says the archive will reach the other devices"
            )
            expectEqual(
                try String(contentsOf: existingItem, encoding: .utf8),
                "existing sync item",
                "export leaves existing itemsync files untouched"
            )
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: syncFolder.path).sorted(),
                ["backup.cpq", existingItem.lastPathComponent].sorted(),
                "export only adds the chosen archive"
            )

            let syncthingPath = directory.appendingPathComponent("Syncthing/Config/CopyQ/backup.cpq")
            try FileManager.default.createDirectory(
                at: syncthingPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let syncedReport = try CopyQSyncBridge.exportArchive(toPath: syncthingPath.path, in: store)
            expect(syncedReport.syncDestination, "a Syncthing destination reports syncing")
            expect(
                FileManager.default.fileExists(atPath: syncthingPath.path),
                "a Syncthing destination accepts the export"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("export leaves no file behind when the destination cannot be written") {
        do {
            let (store, _, _) = try backupFixtureStore()
            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let missing = directory.appendingPathComponent("no-such-directory/backup.cpq")

            expectThrows({
                _ = try CopyQSyncBridge.exportArchive(toPath: missing.path, in: store)
            }, "export into a missing directory fails")
            expect(
                !FileManager.default.fileExists(atPath: missing.path),
                "failed export leaves no archive"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("archive maps single and multi-file copies to text/uri-list") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var tab = try store.ensureDefaultTab()
            tab.name = "Clipboard"
            try store.updateTab(tab)

            try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_400),
                tabID: tab.id,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.fileURL, data: Data("file:///tmp/one.pdf".utf8)),
                    Flavour(itemIndex: 1, type: PasteboardTypes.fileURL, data: Data("file:///tmp/two.pdf".utf8)),
                ]
            ))
            try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_500),
                tabID: tab.id,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.fileURL, data: Data("file:///tmp/single.pdf".utf8)),
                ]
            ))

            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("types.cpq")
            _ = try CopyQSyncBridge.exportArchive(toPath: archiveURL.path, in: store)

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            let items = try unwrap(archive.tabItems["Clipboard"])
            expectEqual(items.count, 2, "both entries are exported")

            // Newest first: even a single file is CopyQ's text/uri-list.
            expectEqual(
                items[0].data.formats,
                [CopyQFormat.uriList],
                "a single-file copy maps to text/uri-list"
            )
            expectEqual(
                items[0].data.bytes(CopyQFormat.uriList).map { String(decoding: $0, as: UTF8.self) },
                "file:///tmp/single.pdf\r\n",
                "a single-file copy keeps its path"
            )

            // The multi-file copy cannot be split across CopyQ's one flavour
            // map per item, so its file URLs travel as CopyQ's own uri list.
            expectEqual(
                items[1].data.formats,
                [CopyQFormat.uriList],
                "a multi-file copy maps to text/uri-list"
            )
            expectEqual(
                items[1].data.bytes(CopyQFormat.uriList).map { String(decoding: $0, as: UTF8.self) },
                "file:///tmp/one.pdf\r\nfile:///tmp/two.pdf\r\n",
                "a multi-item copy keeps every file URL in a uri list"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("written archive uses CopyQ MIME names and preserves custom types") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var tab = try store.ensureDefaultTab()
            tab.name = "Types"
            try store.updateTab(tab)

            try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_800),
                pinned: true,
                tabID: tab.id,
                note: "type note",
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("text".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>html</b>".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
                    Flavour(itemIndex: 0, type: PasteboardTypes.fileURL, data: Data("file:///tmp/typed.pdf".utf8)),
                    Flavour(itemIndex: 0, type: "com.example.custom-flavour", data: Data([0xAA, 0xBB])),
                ]
            ))
            let legacyFileList = try PropertyListSerialization.data(
                fromPropertyList: ["/tmp/legacy.txt"],
                format: .binary,
                options: 0
            )
            try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_700),
                tabID: tab.id,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.legacyText, data: Data("legacy text".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.legacyHTML, data: Data("<i>legacy html</i>".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.legacyFilenames, data: legacyFileList),
                ]
            ))

            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("formats.cpq")
            _ = try CopyQSyncBridge.exportArchive(toPath: archiveURL.path, in: store)

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            let items = try unwrap(archive.tabItems["Types"])
            expectEqual(items.count, 2, "both entries are exported")

            let modern = items[0]
            expectEqual(
                Set(modern.data.formats),
                Set([
                    CopyQFormat.text,
                    CopyQFormat.html,
                    "image/png",
                    CopyQFormat.uriList,
                    CopyQFormat.itemNotes,
                    CopyQFormat.itemPinned,
                    "com.example.custom-flavour",
                ]),
                "native types map to CopyQ MIME names and custom types are preserved"
            )
            expectEqual(modern.data.bytes(CopyQFormat.text), Data("text".utf8), "text bytes are unchanged")
            expectEqual(modern.data.bytes(CopyQFormat.html), Data("<b>html</b>".utf8), "html bytes are unchanged")
            expectEqual(modern.data.bytes("image/png"), Fixtures.pngData, "image bytes are unchanged")
            expectEqual(
                modern.data.bytes(CopyQFormat.uriList).map { String(decoding: $0, as: UTF8.self) },
                "file:///tmp/typed.pdf\r\n",
                "a file URL is written as a uri list"
            )
            expectEqual(
                modern.data.bytes("com.example.custom-flavour"),
                Data([0xAA, 0xBB]),
                "custom bytes are unchanged"
            )

            let legacy = items[1]
            expectEqual(
                Set(legacy.data.formats),
                Set([CopyQFormat.text, CopyQFormat.html, CopyQFormat.uriList]),
                "legacy pasteboard types map to CopyQ MIME names"
            )
            expectEqual(legacy.data.bytes(CopyQFormat.text), Data("legacy text".utf8), "legacy text bytes are unchanged")
            expectEqual(legacy.data.bytes(CopyQFormat.html), Data("<i>legacy html</i>".utf8), "legacy html bytes are unchanged")
            expectEqual(
                legacy.data.bytes(CopyQFormat.uriList).map { String(decoding: $0, as: UTF8.self) },
                "file:///tmp/legacy.txt\r\n",
                "a legacy filename list is written as a uri list"
            )

            for item in items {
                for format in item.data.formats {
                    let recognised = format == CopyQFormat.text
                        || format == CopyQFormat.textUtf8
                        || format == CopyQFormat.html
                        || format == CopyQFormat.uriList
                        || format.hasPrefix("image/")
                        || format.hasPrefix("application/x-copyq-")
                        || format.hasPrefix("application/x-copyqmac-")
                    expect(
                        recognised || format == "com.example.custom-flavour",
                        "\(format) is either a CopyQ-recognised name or an intentional custom type"
                    )
                }
            }
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("archive fold prefers utf8 text, modern html, and native png") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var tab = try store.ensureDefaultTab()
            tab.name = "Preference"
            try store.updateTab(tab)

            try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_001_300),
                tabID: tab.id,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.legacyText, data: Data("legacy text".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.mimeText, data: Data("mime text".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.plainText, data: Data("plain text".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("utf8 text".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.legacyHTML, data: Data("<i>legacy html</i>".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.mimeHtml, data: Data("<u>mime html</u>".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>modern html</b>".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Data([0x01])),
                    Flavour(itemIndex: 0, type: "image/png", data: Data([0x02])),
                ]
            ))

            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("preference.cpq")
            _ = try CopyQSyncBridge.exportArchive(
                toPath: archiveURL.path,
                scope: .tab(tab.id),
                in: store
            )

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            let item = try unwrap(archive.tabItems["Preference"]?.first)
            expectEqual(
                item.data.bytes(CopyQFormat.text),
                Data("utf8 text".utf8),
                "archive keeps the preferred text flavour"
            )
            expectEqual(
                item.data.bytes(CopyQFormat.html),
                Data("<b>modern html</b>".utf8),
                "archive keeps the preferred html flavour"
            )
            expectEqual(
                item.data.bytes("image/png"),
                Data([0x01]),
                "archive keeps the preferred png flavour"
            )

            let restored = try ClipboardStore(inMemory: true)
            _ = try CopyQSyncBridge.importArchive(atPath: archiveURL.path, in: restored)
            let restoredTab = try unwrap(restored.tabs().first { $0.name == "Preference" })
            let restoredEntry = try unwrap(restored.recentEntries(limit: 1, tabID: restoredTab.id).first)
            expectEqual(
                restoredEntry.flavours.first { $0.type == PasteboardTypes.utf8Text }?.data,
                Data("utf8 text".utf8),
                "restored text keeps the preferred payload"
            )
            expectEqual(
                restoredEntry.flavours.first { $0.type == PasteboardTypes.html }?.data,
                Data("<b>modern html</b>".utf8),
                "restored html keeps the preferred payload"
            )
            expectEqual(
                restoredEntry.flavours.first { $0.type == PasteboardTypes.png }?.data,
                Data([0x01]),
                "restored png keeps the preferred payload"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("multi pasteboard item capture keeps only the first item's repeated flavours") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var tab = try store.ensureDefaultTab()
            tab.name = "Images"
            try store.updateTab(tab)

            try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_600),
                tabID: tab.id,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Data([0x01])),
                    Flavour(itemIndex: 1, type: PasteboardTypes.png, data: Data([0x02])),
                ]
            ))

            let directory = try Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("images.cpq")
            let report = try CopyQSyncBridge.exportArchive(toPath: archiveURL.path, in: store)
            expect(
                report.summary.contains("first item's flavours"),
                "summary states the multi-item limitation"
            )

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            let item = try unwrap(archive.tabItems["Images"]?.first)
            expectEqual(
                item.data.bytes("image/png"),
                Data([0x01]),
                "only the first pasteboard item's image is kept"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("recentEntryIDs and entries(ids:) keep display order and skip missing ids") {
        do {
            let (store, clipboard, _) = try backupFixtureStore()
            let ids = try store.recentEntryIDs(limit: 100, tabID: clipboard.id)
            let entries = try store.recentEntries(limit: 100, tabID: clipboard.id)
            expectEqual(ids, entries.map(\.id), "ids follow the display order")

            let requested = [ids[2], ids[0]]
            let fetched = try store.entries(ids: requested)
            expectEqual(fetched.map(\.id), requested, "entries(ids:) keeps the requested order")

            let withMissing = [ids[0], Int64.max]
            let partial = try store.entries(ids: withMissing)
            expectEqual(partial.map(\.id), [ids[0]], "entries(ids:) skips ids that no longer exist")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    // MARK: - CopyQ MIME names become native pasteboard flavours on import

    TestRunner.add("a CopyQ text/html item imports as public.html and pastes back with formatting") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let tab = try store.ensureDefaultTab(name: "Fedora")
                let folder = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: folder) }

                let html = "<p>Fedora <b>bold</b> text</p>"
                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("Fedora bold text".utf8))
                data.set(CopyQFormat.html, Data(html.utf8))
                data.set("application/x-custom-meta", Data([0x01, 0x02, 0x03]))
                let stem = "copyq_20261025120000101"
                try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: data), into: folder.path)

                let report = try CopyQSyncBridge.importSyncFolder(atPath: folder.path, intoTabID: tab.id, in: store)
                expectEqual(report.importedCount, 1, "the HTML item imports")

                let entry = try store.recentEntries(limit: 1, tabID: tab.id).first
                expectNotNil(entry, "the import stores one entry")
                guard let entry else { return }

                let types = Set(entry.flavours.map(\.type))
                expect(types.contains(PasteboardTypes.html), "the entry carries the native public.html flavour")
                expect(!types.contains(CopyQFormat.html), "the CopyQ MIME name must not survive the import")
                expect(types.contains(PasteboardTypes.utf8Text), "the text/plain companion maps to native text")
                expect(types.contains("application/x-custom-meta"), "unknown types stay untouched")
                if let htmlFlavour = entry.flavours.first(where: { $0.type == PasteboardTypes.html }) {
                    expectEqual(htmlFlavour.data, Data(html.utf8), "the HTML payload bytes are unchanged")
                }

                let preview = FlavourDecoder.preview(for: entry.flavours)
                expectEqual(preview.kind, .html, "the imported item displays as HTML")

                let fixture = try RichImportPasteFixture()
                let pasted = fixture.paste(entry, waitingFor: PasteboardTypes.html)
                expectEqual(pasted, Data(html.utf8), "paste-back puts the identical HTML bytes on the pasteboard")
                expectEqual(
                    fixture.pasteboard.string(forType: .html),
                    html,
                    "AppKit reads the pasted HTML flavour back"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a Fedora item with an escaped text flavour shows the characters and pastes the original markup") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let tab = try store.ensureDefaultTab(name: "Fedora")
                let folder = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: folder) }

                // The three files CopyQ's sync plugin writes for one rich copy
                // from Fedora: the markup carries the characters, the `.txt`
                // companion went through a JavaScript escaper, and the `.dat`
                // holds the flavour that has no file of its own.
                let html = "<meta http-equiv=\"content-type\" content=\"text/html; charset=utf-8\"><p class=\"headline\">何止厉害一点点</p>"
                let escapedText = #"\u4f55\u6b62\u5389\u5bb3\u4e00\u70b9\u70b9"#
                let readableText = "何止厉害一点点"
                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data(escapedText.utf8))
                data.set(CopyQFormat.html, Data(html.utf8))
                data.set(CopyQFormat.textUtf8, Data(readableText.utf8))
                data.set("application/x-custom-meta", Data([0x01, 0x02, 0x03]))
                let stem = "copyq_20261027023054834"
                try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: data), into: folder.path)

                let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
                expect(files.contains(stem + ".txt"), "the sync folder carries the .txt flavour")
                expect(files.contains(stem + ".html"), "the sync folder carries the .html flavour")
                expect(files.contains(stem + CopyQFormat.dataFileSuffix), "the sync folder carries the _copyq.dat container")

                let report = try CopyQSyncBridge.importSyncFolder(atPath: folder.path, intoTabID: tab.id, in: store)
                expectEqual(report.importedCount, 1, "the item imports")
                let storedEntry = try unwrap(
                    try store.recentEntries(limit: 1, tabID: tab.id).first,
                    "the import stores one entry"
                )

                // The list row, the preview pane, and search all read the text.
                let preview = FlavourDecoder.preview(for: storedEntry.flavours)
                expectEqual(preview.kind, .html)
                expectEqual(preview.text, readableText)
                expectEqual(EntryPresentation(entry: storedEntry).primaryText, readableText)
                expectEqual(try store.search("何止", tabID: tab.id).count, 1)
                expectEqual(try store.search("u4f55", tabID: tab.id).count, 0)

                // Paste-back still hands the untouched markup to the target app.
                expectEqual(
                    storedEntry.flavours.first { $0.type == PasteboardTypes.html }?.data,
                    Data(html.utf8),
                    "the stored HTML flavour is unchanged byte for byte"
                )
                let fixture = try RichImportPasteFixture()
                let pasted = fixture.paste(storedEntry, waitingFor: PasteboardTypes.html)
                expectEqual(pasted, Data(html.utf8), "paste-back puts the original markup on the pasteboard")
                expectEqual(fixture.pasteboard.string(forType: .html), html, "AppKit reads the rich HTML back")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a CopyQ text/rtf item imports as public.rtf and pastes back with formatting") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let tab = try store.ensureDefaultTab(name: "Fedora")
                let folder = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: folder) }

                let rtf = #"{\rtf1\ansi Fedora \b bold\b0 text}"#
                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("Fedora bold text".utf8))
                data.set(CopyQFormat.rtf, Data(rtf.utf8))
                let stem = "copyq_20261025120000102"
                try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: data), into: folder.path)

                let report = try CopyQSyncBridge.importSyncFolder(atPath: folder.path, intoTabID: tab.id, in: store)
                expectEqual(report.importedCount, 1, "the RTF item imports")

                let entry = try store.recentEntries(limit: 1, tabID: tab.id).first
                expectNotNil(entry, "the import stores one entry")
                guard let entry else { return }

                let types = Set(entry.flavours.map(\.type))
                expect(types.contains(PasteboardTypes.rtf), "the entry carries the native public.rtf flavour")
                expect(!types.contains(CopyQFormat.rtf), "the CopyQ MIME name must not survive the import")
                if let rtfFlavour = entry.flavours.first(where: { $0.type == PasteboardTypes.rtf }) {
                    expectEqual(rtfFlavour.data, Data(rtf.utf8), "the RTF payload bytes are unchanged")
                }

                let preview = FlavourDecoder.preview(for: entry.flavours)
                expectEqual(preview.kind, .rtf, "the imported item displays as rich text")

                let fixture = try RichImportPasteFixture()
                let pasted = fixture.paste(entry, waitingFor: PasteboardTypes.rtf)
                expectEqual(pasted, Data(rtf.utf8), "paste-back puts the identical RTF bytes on the pasteboard")
                expectEqual(
                    fixture.pasteboard.data(forType: .rtf),
                    Data(rtf.utf8),
                    "AppKit reads the pasted rich text flavour back"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a CopyQ RTF item with no plain-text companion still displays its stripped text") {
        let item = CopyQSyncItem(
            baseName: "copyq_20261025120000103",
            data: {
                var data = CopyQDataMap()
                data.set(CopyQFormat.rtf, Data(#"{\rtf1\ansi Only \b rich\b0\par text}"#.utf8))
                return data
            }()
        )
        let entry = CopyQSyncBridge.itemToEntry(item, tabID: 1)
        let preview = FlavourDecoder.preview(for: entry.flavours)
        expectEqual(preview.kind, .rtf, "an RTF-only item is rich text")
        expectEqual(preview.text, "Only rich text", "its preview is the stripped RTF text")
    }

    TestRunner.add("a CopyQ text/plain item imports as native text and pastes back") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let tab = try store.ensureDefaultTab(name: "Fedora")
                let folder = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: folder) }

                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("Plain Fedora text".utf8))
                try CopyQSyncFolder.write(
                    CopyQSyncItem(baseName: "copyq_20261025120000104", data: data),
                    into: folder.path
                )

                let report = try CopyQSyncBridge.importSyncFolder(atPath: folder.path, intoTabID: tab.id, in: store)
                expectEqual(report.importedCount, 1, "the plain item imports")

                guard let entry = try store.recentEntries(limit: 1, tabID: tab.id).first else {
                    TestRunner.fail("the import stores one entry")
                    return
                }
                let types = Set(entry.flavours.map(\.type))
                expect(types.contains(PasteboardTypes.utf8Text), "the entry carries the native text flavour")
                expect(!types.contains(CopyQFormat.text), "the CopyQ MIME name must not survive the import")
                expectEqual(FlavourDecoder.preview(for: entry.flavours).kind, .text, "it still displays as text")

                let fixture = try RichImportPasteFixture()
                _ = fixture.paste(entry, waitingFor: PasteboardTypes.utf8Text)
                expectEqual(
                    fixture.pasteboard.string(forType: .string),
                    "Plain Fedora text",
                    "paste-back puts the plain text on the pasteboard"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("CopyQ MIME flavours fingerprint the same as their native equivalents") {
        let html = Data("<b>same</b>".utf8)
        let rtf = Data(#"{\rtf1\ansi same}"#.utf8)
        let text = Data("same".utf8)

        var data = CopyQDataMap()
        data.set(CopyQFormat.text, text)
        data.set(CopyQFormat.html, html)
        data.set(CopyQFormat.rtf, rtf)
        let imported = CopyQSyncBridge.itemToEntry(CopyQSyncItem(baseName: nil, data: data), tabID: 1)
        let local = ClipboardEntry(
            createdAt: Date(),
            tabID: 1,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: text),
                Flavour(itemIndex: 0, type: PasteboardTypes.html, data: html),
                Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: rtf),
            ]
        )
        expectEqual(
            Fingerprint.payload(of: imported.flavours),
            Fingerprint.payload(of: local.flavours),
            "an imported rich item and the same local capture share one payload identity"
        )
    }

    TestRunner.add("a .cpq archive item imports its rich text under native pasteboard names") {
        let store = try ClipboardStore(inMemory: true)

        let html = Data("<b>Archive rich</b>".utf8)
        let rtf = Data(#"{\rtf1\ansi Archive \b rich\b0}"#.utf8)
        var item = CopyQSyncItem()
        item.data.set(CopyQFormat.text, Data("Archive rich".utf8))
        item.data.set(CopyQFormat.html, html)
        item.data.set(CopyQFormat.rtf, rtf)

        var stream = QDataStreamWriter()
        stream.writeQByteArray(Data("CopyQ v4".utf8))
        stream.writeUInt32(1)
        stream.writeQString("tabs")
        stream.writeUInt32(11)
        stream.writeBool(false)
        stream.writeQStringList(["ArchiveRichTab"])
        stream.writeUInt32(2)
        stream.writeQString("name")
        stream.writeUInt32(10)
        stream.writeBool(false)
        stream.writeQString("ArchiveRichTab")
        stream.writeQString("data")
        stream.writeUInt32(12)
        stream.writeBool(false)
        stream.writeQByteArray(CopyQArchive.encodeItemListForTesting([item]))

        let tempFile = try Fixtures.temporaryDirectory().appendingPathComponent("rich.cpq")
        defer { try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent()) }
        try stream.data.write(to: tempFile)

        let report = try CopyQSyncBridge.importArchive(atPath: tempFile.path, in: store)
        expectEqual(report.importedCount, 1, "the archive item imports")

        let tab = try store.tabs().first { $0.name == "ArchiveRichTab" }
        expectNotNil(tab, "the archive tab is created")
        guard let tab, let entry = try store.recentEntries(limit: 1, tabID: tab.id).first else {
            TestRunner.fail("the archived item is stored")
            return
        }
        let types = Set(entry.flavours.map(\.type))
        expect(types.contains(PasteboardTypes.html), "the archive HTML uses public.html")
        expect(types.contains(PasteboardTypes.rtf), "the archive RTF uses public.rtf")
        expect(types.contains(PasteboardTypes.utf8Text), "the archive text uses the native text flavour")
        expectEqual(FlavourDecoder.preview(for: entry.flavours).kind, .html, "the archived item displays as rich text")
    }

    TestRunner.add("import then export then import does not duplicate a rich item") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.ensureDefaultTab(name: "RoundTripRichTab")
        let sourceFolder = try Fixtures.temporaryDirectory()
        let scratchFolder = try Fixtures.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceFolder)
            try? FileManager.default.removeItem(at: scratchFolder)
        }

        let html = Data("<b>Roundtrip rich</b>".utf8)
        let rtf = Data(#"{\rtf1\ansi Roundtrip \b rich\b0}"#.utf8)
        let text = Data("Roundtrip rich".utf8)
        var data = CopyQDataMap()
        data.set(CopyQFormat.text, text)
        data.set(CopyQFormat.html, html)
        data.set(CopyQFormat.rtf, rtf)
        data.set("image/png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let stem = "copyq_20261025120000105"
        try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: data), into: sourceFolder.path)

        let firstReport = try CopyQSyncBridge.importSyncFolder(
            atPath: sourceFolder.path,
            intoTabID: tab.id,
            in: store
        )
        expectEqual(firstReport.importedCount, 1, "the source item imports")
        expectEqual(try store.count(tabID: tab.id), 1, "one row is stored")

        let exported = try CopyQSyncBridge.dryRunExport(tabID: tab.id, in: store, into: scratchFolder.path)
        expect(exported.contains("\(stem).html"), "the HTML is exported under CopyQ's MIME name")
        expect(exported.contains("\(stem).txt"), "the plain text is exported")
        let exportedItem = try CopyQSyncFolder.read(atPath: scratchFolder.path).items.first
        expectEqual(exportedItem?.data.bytes(CopyQFormat.html), html, "the exported HTML payload is unchanged")
        expectEqual(exportedItem?.data.bytes(CopyQFormat.rtf), rtf, "the exported RTF payload is unchanged")

        let secondReport = try CopyQSyncBridge.importSyncFolder(
            atPath: scratchFolder.path,
            intoTabID: tab.id,
            in: store
        )
        expectEqual(secondReport.importedCount, 0, "re-importing the export creates no second row")
        expectEqual(secondReport.duplicateCount, 1, "the re-import is recognised as the same entry")
        expectEqual(try store.count(tabID: tab.id), 1, "one row remains")
    }

    TestRunner.add("sync folder scanning skips Syncthing conflict files") {
        let tempDir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(
            name: "SyncthingTab",
            syncFolder: tempDir.path
        ))

        let regularStem = "copyq_20261118120000000"
        let conflictStem1 = "\(regularStem).sync-conflict-20261118-120500"
        let conflictStem2 = "copyq_20261118120000001.sync-conflict-20261118-121000-XYZ123"

        // Regular item
        try Data("Valid item content".utf8)
            .write(to: tempDir.appendingPathComponent("\(regularStem).txt"))

        // Syncthing conflict items
        try Data("Conflict item 1".utf8)
            .write(to: tempDir.appendingPathComponent("\(conflictStem1).txt"))
        try Data("Conflict item 2".utf8)
            .write(to: tempDir.appendingPathComponent("\(conflictStem2).txt"))
        try Data("Conflict dat".utf8)
            .write(to: tempDir.appendingPathComponent("\(regularStem).sync-conflict-20261118-120500._copyq.dat"))

        // Verify CopyQSyncFolder.read directly
        let contents = try CopyQSyncFolder.read(atPath: tempDir.path)
        expectEqual(contents.items.count, 1, "only regular item must be read; conflict files must be skipped")
        expectEqual(contents.items.first?.baseName, regularStem, "read item baseName must match regularStem")
        expectEqual(contents.items.first?.text, "Valid item content", "read item text matches")

        // Verify folder import
        let report = try CopyQSyncBridge.importSyncFolder(atPath: tempDir.path, intoTabID: tab.id, in: store)
        expectEqual(report.importedCount, 1, "only 1 item should be imported")
        expectEqual(report.duplicateCount, 0, "no duplicates")
        expectEqual(report.failedCount, 0, "no failures")

        let entries = try store.recentEntries(tabID: tab.id)
        expectEqual(entries.count, 1, "store must contain only 1 entry")
        let textData = entries.first?.flavours.first(where: { $0.type == PasteboardTypes.utf8Text })?.data
        expectEqual(textData.flatMap { String(data: $0, encoding: .utf8) }, "Valid item content", "imported entry content must be regular item")
    }
}

// MARK: - Backup export

func backupFixtureStore() throws -> (store: ClipboardStore, clipboard: ClipboardTab, fedora: ClipboardTab) {
    let store = try ClipboardStore(inMemory: true)
    // A fresh store already seeds a default tab; give it the fixture name.
    var clipboard = try store.ensureDefaultTab()
    clipboard.name = "Clipboard"
    try store.updateTab(clipboard)
    let fedora = try store.insertTab(ClipboardTab(name: "Fedora"))

    try store.insert(ClipboardEntry(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000.125),
        tabID: clipboard.id,
        flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("oldest entry".utf8)),
        ]
    ))
    try store.insert(ClipboardEntry(
        createdAt: Date(timeIntervalSince1970: 1_700_000_100.25),
        pinned: true,
        tabID: clipboard.id,
        note: "a searchable note",
        flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("rich entry".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>rich entry</b>".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
        ]
    ))
    try store.insert(ClipboardEntry(
        createdAt: Date(timeIntervalSince1970: 1_700_000_200.5),
        tabID: clipboard.id,
        note: "file note",
        flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.fileURL, data: Data("file:///tmp/report.pdf".utf8)),
            Flavour(itemIndex: 0, type: "com.example.custom-flavour", data: Data([0x00, 0x01, 0xFE, 0xFF])),
        ]
    ))
    try store.insert(ClipboardEntry(
        createdAt: Date(timeIntervalSince1970: 1_700_000_300.75),
        tabID: fedora.id,
        flavours: [
            Flavour(itemIndex: 0, type: CopyQFormat.text, data: Data("synced from Fedora".utf8)),
        ]
    ))
    return (store, clipboard, fedora)
}
