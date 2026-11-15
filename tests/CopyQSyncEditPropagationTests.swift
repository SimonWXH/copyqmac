// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncEditPropagationTests.swift
//
// Content edits are bidirectional: a local edit rewrites the entry's own file
// group, an upstream edit updates the row in place when it is newer, an older
// edit loses with a log line, and the retired per-tab switches no longer gate
// either direction.

import Foundation

func registerCopyQSyncEditPropagationTests() {
    TestRunner.currentSuite = "CopyQSyncEditPropagation"

    func makeTempDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writeGroup(_ text: String, stem: String, in folder: URL, mtime: Date? = nil) throws {
        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data(text.utf8))
        try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: data), into: folder.path)
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime],
                ofItemAtPath: folder.appendingPathComponent("\(stem).txt").path
            )
        }
    }

    func syncFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func insertLegacyRow(
        stem: String,
        text: String,
        in folder: URL,
        store: ClipboardStore,
        tabID: Int64
    ) throws -> ClipboardEntry {
        let stemDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the legacy stem timestamp")
        try writeGroup(text, stem: stem, in: folder, mtime: stemDate)
        return try store.insert(ClipboardEntry(
            createdAt: stemDate,
            tabID: tabID,
            flavours: [Fixtures.text(text)]
        ))
    }

    TestRunner.add("a local content edit rewrites exactly one group and leaves no orphan") {
        let folder = try makeTempDirectory(prefix: "copyq-edit-group")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "EditGroup", syncFolder: folder.path))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = try store.insert(ClipboardEntry(
            createdAt: createdAt,
            tabID: tab.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("alpha".utf8)),
                Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>alpha</b>".utf8)),
            ]
        ))

        let capture = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        let stem = try unwrap(capture?.stem, "the capture was written")
        expectEqual(try syncFiles(in: folder), ["\(stem).html", "\(stem).txt"], "the capture group has two files")

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")

        let files = try syncFiles(in: folder)
        expectEqual(files, ["\(stem).txt"], "the stale HTML file is removed and no second group appears")
        let contents = try CopyQSyncFolder.read(atPath: folder.path)
        expectEqual(contents.items.count, 1, "the folder holds exactly one group")
        expectEqual(contents.items.first?.baseName, stem, "the edit keeps the entry's own stem")
        expectEqual(contents.items.first?.text, "beta", "the group carries the edited text")

        let updated = try unwrap(try store.entry(id: entry.id), "the edited row")
        expectEqual(
            updated.createdAt.timeIntervalSince1970,
            createdAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the edit keeps the entry's original creation time"
        )
        expectEqual(
            CopyQSyncDeletion.syncBaseName(of: updated, in: store, folder: folder.path),
            stem,
            "the entry still owns the rewritten stem"
        )
    }

    TestRunner.add("a capture write after an edit reuses the group instead of adding a second one") {
        let folder = try makeTempDirectory(prefix: "copyq-capture-after-edit")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "CaptureAfterEdit", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")
        let stem = try unwrap(
            CopyQSyncDeletion.syncBaseName(
                of: try unwrap(try store.entry(id: entry.id)),
                in: store,
                folder: folder.path
            ),
            "the edit allocated a stem"
        )

        // The queued capture still holds the pre-edit snapshot. It must reuse
        // the group and write the stored (edited) content, not the snapshot.
        let capture = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        expectEqual(capture?.stem, stem, "the queued capture write reuses the owned stem")
        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "no second group is created")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "beta",
            "the queued write uses the edited row, not its stale snapshot"
        )
    }

    TestRunner.add("a newer local edit wins an older upstream change and is re-asserted") {
        let folder = try makeTempDirectory(prefix: "copyq-local-wins")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LocalWins", syncFolder: folder.path))
        let stem = "copyq_20261025120000101"
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try writeGroup("alpha", stem: stem, in: folder, mtime: oldDate)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let imported = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(imported.importedCount, 1)

        guard let entry = try store.recentEntries(tabID: tab.id).first else {
            TestRunner.fail("the initial group was not imported")
            return
        }
        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "local beta")

        let logPath = folder.appendingPathComponent("sync.log").path
        CopyQSyncWriter.shared.customLogFilePath = logPath
        defer { CopyQSyncWriter.shared.customLogFilePath = nil }

        // An upstream write with a timestamp older than the local edit.
        try writeGroup(
            "remote gamma",
            stem: stem,
            in: folder,
            mtime: oldDate.addingTimeInterval(1)
        )

        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.updatedCount, 0, "the older upstream edit does not replace the local one")
        expectEqual(report.skippedUpstreamCount, 1, "the upstream edit is discarded")
        expectEqual(report.reassertedCount, 1, "the winning local version is written back")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "local beta"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "local beta",
            "the folder converges on the local version"
        )

        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        expect(log.contains("upstream-edit-discarded"), "the discarded upstream edit is logged")
        expect(!log.contains("remote gamma"), "the log does not carry the discarded payload text")
        expect(log.contains("sha256="), "the log carries a payload summary")
    }

    TestRunner.add("conflict logging never writes clipboard content to the sync log") {
        let folder = try makeTempDirectory(prefix: "copyq-log-privacy")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LogPrivacy", syncFolder: folder.path))
        let skippedStem = "copyq_20261025120000901"
        let replacedStem = "copyq_20261025120000902"
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secrets = [
            "Q7mZ2pX9kN4vT6",
            "R3sW8bY5cD1fG7",
            "H6jK9lM2nP4qS8",
            "T5uV1wX7yZ3aB9",
            "C8dE4fG2hJ6kL1",
            "N3oP7qR5sT9uV2",
        ]

        try writeGroup(secrets[0], stem: skippedStem, in: folder, mtime: oldDate)
        try writeGroup(secrets[1], stem: replacedStem, in: folder, mtime: oldDate)

        let logPath = folder.appendingPathComponent("sync.log").path
        CopyQSyncWriter.shared.customLogFilePath = logPath
        defer { CopyQSyncWriter.shared.customLogFilePath = nil }

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        _ = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        let rows = try store.recentEntries(limit: Int.max, tabID: tab.id)
        let skippedRow = try unwrap(
            rows.first { FlavourDecoder.storedPlainText(from: $0.flavours) == secrets[0] },
            "the row whose upstream edit loses"
        )
        let replacedRow = try unwrap(
            rows.first { FlavourDecoder.storedPlainText(from: $0.flavours) == secrets[1] },
            "the row whose local edit is replaced"
        )

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: skippedRow.id, with: secrets[3])
        _ = try history.replaceText(of: replacedRow.id, with: secrets[5])

        try writeGroup(secrets[4], stem: skippedStem, in: folder, mtime: oldDate.addingTimeInterval(1))
        try writeGroup(secrets[2], stem: replacedStem, in: folder, mtime: Date().addingTimeInterval(60))
        _ = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )

        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        expect(log.contains("upstream-edit-discarded"), "the losing upstream edit is logged")
        expect(log.contains("local-edit-replaced"), "the replaced local edit is logged")
        expect(log.contains("formats=["), "the log carries a payload format summary")
        expect(log.contains("sha256="), "the log carries a payload hash summary")
        for secret in secrets {
            expect(!log.contains(secret), "the log never contains payload text")
            let characters = Array(secret)
            guard characters.count >= 6 else { continue }
            for start in 0...(characters.count - 6) {
                let window = String(characters[start..<(start + 6)])
                expect(!log.contains(window), "the log never contains a payload substring")
            }
        }
    }

    TestRunner.add("a written-back edit clears the local marker so a later upstream edit applies") {
        let folder = try makeTempDirectory(prefix: "copyq-edit-marker")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "EditMarker", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        let stem = try unwrap(written?.stem, "the capture was written")

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")
        expectEqual(
            try store.isEntryLocallyEdited(id: entry.id),
            false,
            "a successful write-back clears the pending local-edit marker"
        )

        try writeGroup("gamma", stem: stem, in: folder, mtime: Date().addingTimeInterval(60))
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.updatedCount, 1, "the later upstream edit applies")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "gamma",
            "the row takes the upstream edit"
        )
        expectEqual(try store.isEntryLocallyEdited(id: entry.id), false)
    }

    TestRunner.add("a capture with a same-key MIME flavour publishes the canonical payload and settles") {
        let folder = try makeTempDirectory(prefix: "copyq-canonical-mime")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "CanonicalMime", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Data([0x01])),
                Flavour(itemIndex: 0, type: "image/png", data: Data([0x02])),
            ]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        let stem = try unwrap(written?.stem, "the capture was written")
        expectEqual(
            try Data(contentsOf: folder.appendingPathComponent("\(stem).png")),
            Data([0x01]),
            "the mapped native flavour is the payload the folder receives"
        )

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        for _ in 0..<3 {
            let report = try watcher.scanFolder(
                atPath: folder.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(report.skippedUpstreamCount, 0, "the write is never an upstream edit")
            expectEqual(report.reassertedCount, 0, "the local version is never rewritten")
            expectEqual(report.updatedCount, 0)
        }
        expectEqual(try store.count(tabID: tab.id), 1, "the capture stays one row")
    }

    TestRunner.add("a capture with a divergent uri-list flavour publishes the canonical payload and settles") {
        let folder = try makeTempDirectory(prefix: "copyq-canonical-uri")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "CanonicalUri", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [
                Flavour(
                    itemIndex: 0,
                    type: PasteboardTypes.fileURL,
                    data: Data("file:///tmp/canonical-one.pdf".utf8)
                ),
                Flavour(
                    itemIndex: 0,
                    type: PasteboardTypes.mimeUriList,
                    data: Data("file:///tmp/shadow-two.pdf\n".utf8)
                ),
            ]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        let stem = try unwrap(written?.stem, "the capture was written")
        expectEqual(
            try String(contentsOf: folder.appendingPathComponent("\(stem).uri"), encoding: .utf8),
            "file:///tmp/canonical-one.pdf\r\nfile:///tmp/shadow-two.pdf\r\n",
            "the folder receives the canonical uri list"
        )

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        for _ in 0..<3 {
            let report = try watcher.scanFolder(
                atPath: folder.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(report.skippedUpstreamCount, 0, "the write is never an upstream edit")
            expectEqual(report.reassertedCount, 0, "the local version is never rewritten")
            expectEqual(report.updatedCount, 0)
        }
        expectEqual(try store.count(tabID: tab.id), 1, "the capture stays one row")
    }

    TestRunner.add("a stem recorded for an entry in another tab is not owned by the scanning tab") {
        let folder = try makeTempDirectory(prefix: "copyq-foreign-owner")
        let otherFolder = try makeTempDirectory(prefix: "copyq-foreign-owner-other")
        let trash = try makeTempDirectory(prefix: "copyq-foreign-owner-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: otherFolder)
            try? FileManager.default.removeItem(at: trash)
        }

        let store = try ClipboardStore(inMemory: true)
        var original = try store.insertTab(ClipboardTab(name: "Original", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: original.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        let stem = try unwrap(written?.stem, "the capture was written")

        let scanning = try store.insertTab(ClipboardTab(name: "Scanning", syncFolder: folder.path))
        original.syncFolder = otherFolder.path
        try store.updateTab(original)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        watcher.trashRoot = trash

        try writeGroup("remote beta", stem: stem, in: folder, mtime: Date().addingTimeInterval(60))
        let editReport = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: scanning.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(editReport.updatedCount, 0, "the row in the other tab is not updated")
        expectEqual(editReport.importedCount, 0, "the written stem is not imported into this tab")
        expectEqual(try store.count(tabID: scanning.id), 0)
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "alpha",
            "the row in the other tab keeps its content"
        )

        try FileManager.default.removeItem(at: folder.appendingPathComponent("\(stem).txt"))
        _ = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: scanning.id,
            in: store,
            settleDelayOverride: 0
        )
        let deletionReport = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: scanning.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(deletionReport.remoteDeletedCount, 0, "the row in the other tab is not removed")
        expectNotNil(try store.entry(id: entry.id), "the row in the other tab survives")
    }

    TestRunner.add("a capture with aliased text flavours is not mistaken for an upstream edit") {
        let folder = try makeTempDirectory(prefix: "copyq-alias-echo")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "AliasEcho", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("aliased".utf8)),
                Flavour(itemIndex: 0, type: PasteboardTypes.plainText, data: Data("aliased".utf8)),
            ]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        expectNotNil(written, "the capture is written")

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.updatedCount, 0, "our own alias-rich capture is not an upstream edit")
        expectEqual(report.importedCount, 0, "our own capture is not imported again")
        expectEqual(report.skippedWrittenByUsCount, 1, "the group is recognised as our own write")
        expectEqual(try store.count(tabID: tab.id), 1, "the tab keeps one entry")
    }

    TestRunner.add("two machines update each other's edits in place through one folder") {
        let folder = try makeTempDirectory(prefix: "copyq-two-machines")
        defer { try? FileManager.default.removeItem(at: folder) }

        let storeA = try ClipboardStore(inMemory: true)
        let tabA = try storeA.insertTab(ClipboardTab(name: "Mac", syncFolder: folder.path))
        let storeB = try ClipboardStore(inMemory: true)
        let tabB = try storeB.insertTab(ClipboardTab(name: "Fedora", syncFolder: folder.path))

        // A captures; B imports it.
        let entryA = try storeA.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tabA.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entryA, in: storeA, reason: "capture")
        let stem = try unwrap(written?.stem, "A wrote its capture")

        let watcherB = CopyQSyncWatcher(store: storeB)
        watcherB.settleDelay = 0
        let importB = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        expectEqual(importB.importedCount, 1, "B imports A's capture")
        guard let entryB = try storeB.recentEntries(tabID: tabB.id).first else {
            TestRunner.fail("B did not store the imported item")
            return
        }

        // A edits; B updates the same row in place.
        let historyA = ClipboardHistory(store: storeA)
        _ = try historyA.replaceText(of: entryA.id, with: "beta")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.baseName,
            stem,
            "A's edit keeps the group's stem"
        )
        let editB = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        expectEqual(editB.updatedCount, 1, "B updates A's edit in place")
        expectEqual(try storeB.count(tabID: tabB.id), 1, "B does not add a second row")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try storeB.entry(id: entryB.id)?.flavours ?? []),
            "beta",
            "B's row carries A's edited text"
        )

        // B edits; A updates the same row in place.
        let historyB = ClipboardHistory(store: storeB)
        _ = try historyB.replaceText(of: entryB.id, with: "gamma")
        let watcherA = CopyQSyncWatcher(store: storeA)
        watcherA.settleDelay = 0
        let editA = try watcherA.scanFolder(
            atPath: folder.path,
            intoTabID: tabA.id,
            in: storeA,
            settleDelayOverride: 0
        )
        expectEqual(editA.updatedCount, 1, "A updates B's edit in place")
        expectEqual(try storeA.count(tabID: tabA.id), 1, "A does not add a second row")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try storeA.entry(id: entryA.id)?.flavours ?? []),
            "gamma",
            "A's row carries B's edited text"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.baseName,
            stem,
            "the whole exchange keeps one stem"
        )
    }

    TestRunner.add("a failed group rewrite leaves the previous group intact") {
        let folder = try makeTempDirectory(prefix: "copyq-edit-atomic")
        let logFolder = try makeTempDirectory(prefix: "copyq-edit-atomic-log")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: logFolder)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "AtomicEdit", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("alpha".utf8)),
                Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>alpha</b>".utf8)),
            ]
        ))
        let capture = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        expectNotNil(capture, "the capture was written")
        let before = try syncFiles(in: folder)

        CopyQSyncWriter.shared.customLogFilePath = logFolder.appendingPathComponent("sync.log").path
        defer { CopyQSyncWriter.shared.customLogFilePath = nil }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        let history = ClipboardHistory(store: store)
        var failures: [String] = []
        history.onSyncEditFailure = { failures.append($0) }
        _ = try history.replaceText(of: entry.id, with: "beta")

        expectEqual(failures.count, 1, "the failed rewrite is reported")
        expectEqual(try syncFiles(in: folder), before, "the previous group is left untouched")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "alpha",
            "the folder keeps the previous content"
        )
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "beta",
            "the local edit still applies"
        )
    }

    TestRunner.add("a failure during the group swap restores the previous group") {
        final class FailingMoveFileManager: FileManager {
            let failingMove: Int
            private(set) var moveCount = 0

            init(failingMove: Int) {
                self.failingMove = failingMove
                super.init()
            }

            override func moveItem(at srcURL: URL, to dstURL: URL) throws {
                moveCount += 1
                if moveCount == failingMove {
                    throw CocoaError(.fileWriteUnknown)
                }
                try super.moveItem(at: srcURL, to: dstURL)
            }
        }

        let folder = try makeTempDirectory(prefix: "copyq-edit-swap")
        let logFolder = try makeTempDirectory(prefix: "copyq-edit-swap-log")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: logFolder)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "SwapEdit", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let capture = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        let stem = try unwrap(capture?.stem, "the capture was written")

        try store.replaceFlavours(of: entry.id, with: [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("beta".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Data([0x01])),
        ], locallyEdited: true)

        CopyQSyncWriter.shared.customLogFilePath = logFolder.appendingPathComponent("sync.log").path
        defer { CopyQSyncWriter.shared.customLogFilePath = nil }

        // One backup move, then one installed file, then a failure while the
        // second staged file is renamed into place.
        let failingManager = FailingMoveFileManager(failingMove: 3)
        let failed = CopyQSyncWriter.shared.updateEntry(
            try unwrap(try store.entry(id: entry.id), "the edited row"),
            in: store,
            reason: "edit",
            fileManager: failingManager
        )
        expectNotNil(failed?.error, "the interrupted swap is reported as a failure")
        expect(failingManager.moveCount >= 3, "the swap failed after it started")
        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "no file of the new group or temporary name is left behind")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "alpha",
            "the previous group is restored after the failed swap"
        )

        let retried = CopyQSyncWriter.shared.updateEntry(
            try unwrap(try store.entry(id: entry.id), "the edited row"),
            in: store,
            reason: "edit"
        )
        expectNil(retried?.error, "a retry writes the pending edit")
        expectEqual(try syncFiles(in: folder), ["\(stem).png", "\(stem).txt"], "the retry installs the whole new group")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "beta",
            "the retry publishes the edited content"
        )
    }

    TestRunner.add("a duplicate group without stem ownership leaves a pending local edit intact") {
        let folder = try makeTempDirectory(prefix: "copyq-foreign-duplicate")
        let trash = try makeTempDirectory(prefix: "copyq-foreign-duplicate-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "ForeignDuplicate", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Fixtures.text("old")]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        let stem = try unwrap(written?.stem, "the capture was written")

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        watcher.trashRoot = trash
        _ = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )

        var preferences = try store.preferences()
        preferences.syncPaused = true
        try store.setPreferences(preferences)
        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "alpha")
        preferences.syncPaused = false
        try store.setPreferences(preferences)
        expectEqual(try store.isEntryLocallyEdited(id: entry.id), true, "the paused edit is pending")
        let editVersion = try unwrap(try store.syncUpdatedAt(id: entry.id), "the edit version")

        // The other machine stored the same text under a stem this row does not
        // own, while the group it does own disappears from the folder.
        try writeGroup(
            "alpha",
            stem: "copyq_20261025120000401",
            in: folder,
            mtime: Date().addingTimeInterval(60)
        )
        try FileManager.default.removeItem(at: folder.appendingPathComponent("\(stem).txt"))

        let duplicateReport = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(duplicateReport.remoteDeletedCount, 0, "the first absent scan only records the pending deletion")
        expectEqual(duplicateReport.importedCount, 0, "the same content is not inserted again")
        expectEqual(try store.count(tabID: tab.id), 1)
        expectEqual(
            try store.isEntryLocallyEdited(id: entry.id),
            true,
            "a group the row does not own does not clear the pending edit"
        )
        expectEqual(
            try unwrap(try store.syncUpdatedAt(id: entry.id), "the version after the duplicate"),
            editVersion,
            "a group the row does not own does not advance the row's version"
        )

        let deletionReport = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(deletionReport.remoteDeletedCount, 0, "the pending edit protects the row from upstream deletion")
        expectEqual(try store.count(tabID: tab.id), 1)
        expectNotNil(try store.entry(id: entry.id), "the edited row survives")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "alpha",
            "the local edit survives"
        )
    }

    TestRunner.add("a newer upstream version wins over a pending local edit") {
        let folder = try makeTempDirectory(prefix: "copyq-pending-upstream-newer")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "PendingUpstreamNewer", syncFolder: folder.path))
        let stem = "copyq_20261025120000911"
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try writeGroup("alpha", stem: stem, in: folder, mtime: oldDate)

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        _ = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        let entry = try unwrap(try store.recentEntries(tabID: tab.id).first, "the imported row")

        var preferences = try store.preferences()
        preferences.syncPaused = true
        try store.setPreferences(preferences)
        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")
        expectEqual(try store.isEntryLocallyEdited(id: entry.id), true, "the paused edit is pending")
        preferences.syncPaused = false
        try store.setPreferences(preferences)

        try writeGroup("alpha", stem: stem, in: folder, mtime: Date().addingTimeInterval(60))

        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.updatedCount, 1, "the newer upstream version replaces the pending local edit")
        expectEqual(report.reassertedCount, 0, "the stale local edit is not written over the newer version")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "alpha",
            "the row takes the newer upstream version"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "alpha",
            "the folder keeps the newer upstream version"
        )
    }

    TestRunner.add("notes and pins travel both ways without echo") {
        let folder = try makeTempDirectory(prefix: "copyq-metadata-both-ways")
        defer { try? FileManager.default.removeItem(at: folder) }

        let storeA = try ClipboardStore(inMemory: true)
        let tabA = try storeA.insertTab(ClipboardTab(name: "MacMeta", syncFolder: folder.path))
        let storeB = try ClipboardStore(inMemory: true)
        let tabB = try storeB.insertTab(ClipboardTab(name: "FedoraMeta", syncFolder: folder.path))

        let entryA = try storeA.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tabA.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entryA, in: storeA, reason: "capture")
        let stem = try unwrap(written?.stem, "A wrote its capture")

        let watcherB = CopyQSyncWatcher(store: storeB)
        watcherB.settleDelay = 0
        _ = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        let entryB = try unwrap(try storeB.recentEntries(tabID: tabB.id).first, "B imported A's capture")

        let historyA = ClipboardHistory(store: storeA)
        let historyB = ClipboardHistory(store: storeB)

        _ = try historyA.setNote(entryA.id, "mac note")
        expectEqual(
            try String(contentsOf: folder.appendingPathComponent("\(stem)_note.txt"), encoding: .utf8),
            "mac note",
            "A's note is written to the item's note file"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first { $0.baseName == stem }?.text,
            "alpha",
            "a note-only change leaves the content as it was"
        )
        let noteScanB = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        expectEqual(noteScanB.updatedCount, 1, "B applies A's note")
        expectEqual(try storeB.entry(id: entryB.id)?.note, "mac note")

        _ = try historyB.setNote(entryB.id, "fedora note")
        let watcherA = CopyQSyncWatcher(store: storeA)
        watcherA.settleDelay = 0
        let noteScanA = try watcherA.scanFolder(
            atPath: folder.path,
            intoTabID: tabA.id,
            in: storeA,
            settleDelayOverride: 0
        )
        expectEqual(noteScanA.updatedCount, 1, "A applies B's note")
        expectEqual(try storeA.entry(id: entryA.id)?.note, "fedora note")

        _ = try historyA.setPinned(entryA.id, true)
        let pinnedItem = try unwrap(
            try CopyQSyncFolder.read(atPath: folder.path).items.first { $0.baseName == stem },
            "the pinned group"
        )
        expectEqual(pinnedItem.isPinned, true, "A's pin travels in the group")
        let pinScanB = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        expectEqual(pinScanB.updatedCount, 1, "B applies A's pin")
        expectEqual(try storeB.entry(id: entryB.id)?.pinned, true)

        _ = try historyB.setPinned(entryB.id, false)
        let unpinScanA = try watcherA.scanFolder(
            atPath: folder.path,
            intoTabID: tabA.id,
            in: storeA,
            settleDelayOverride: 0
        )
        expectEqual(unpinScanA.updatedCount, 1, "A applies B's unpin")
        expectEqual(try storeA.entry(id: entryA.id)?.pinned, false)

        _ = try historyB.setNote(entryB.id, "")
        let clearScanA = try watcherA.scanFolder(
            atPath: folder.path,
            intoTabID: tabA.id,
            in: storeA,
            settleDelayOverride: 0
        )
        expectEqual(clearScanA.updatedCount, 1, "A applies B's cleared note")
        expectEqual(try storeA.entry(id: entryA.id)?.note, "")
        expectEqual(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(stem)_note.txt").path),
            false,
            "clearing the note removes its file from the group"
        )

        let filesBefore = try syncFiles(in: folder)
        for _ in 0..<2 {
            let reportA = try watcherA.scanFolder(
                atPath: folder.path,
                intoTabID: tabA.id,
                in: storeA,
                settleDelayOverride: 0
            )
            let reportB = try watcherB.scanFolder(
                atPath: folder.path,
                intoTabID: tabB.id,
                in: storeB,
                settleDelayOverride: 0
            )
            expectEqual(
                reportA.importedCount + reportA.updatedCount + reportA.reassertedCount,
                0,
                "A settles with no changes"
            )
            expectEqual(
                reportB.importedCount + reportB.updatedCount + reportB.reassertedCount,
                0,
                "B settles with no changes"
            )
        }
        expectEqual(try syncFiles(in: folder), filesBefore, "converged rounds leave the folder unchanged")
        expectEqual(try storeA.entry(id: entryA.id)?.note, "")
        expectEqual(try storeB.entry(id: entryB.id)?.note, "")
        expectEqual(try storeA.entry(id: entryA.id)?.pinned, false)
        expectEqual(try storeB.entry(id: entryB.id)?.pinned, false)
    }

    TestRunner.add("a newer upstream content and note edit wins together") {
        let folder = try makeTempDirectory(prefix: "copyq-metadata-newest")
        defer { try? FileManager.default.removeItem(at: folder) }

        let storeA = try ClipboardStore(inMemory: true)
        let tabA = try storeA.insertTab(ClipboardTab(name: "MacNewest", syncFolder: folder.path))
        let storeB = try ClipboardStore(inMemory: true)
        let tabB = try storeB.insertTab(ClipboardTab(name: "FedoraNewest", syncFolder: folder.path))

        let entryA = try storeA.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tabA.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entryA, in: storeA, reason: "capture")
        expectNotNil(written, "A wrote its capture")

        let watcherB = CopyQSyncWatcher(store: storeB)
        watcherB.settleDelay = 0
        _ = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        let entryB = try unwrap(try storeB.recentEntries(tabID: tabB.id).first, "B imported A's capture")

        let historyA = ClipboardHistory(store: storeA)
        let historyB = ClipboardHistory(store: storeB)
        _ = try historyA.setNote(entryA.id, "older note")
        Thread.sleep(forTimeInterval: 0.05)
        _ = try historyB.replaceText(of: entryB.id, with: "newer text")
        _ = try historyB.setNote(entryB.id, "newer note")

        let watcherA = CopyQSyncWatcher(store: storeA)
        watcherA.settleDelay = 0
        let reportA = try watcherA.scanFolder(
            atPath: folder.path,
            intoTabID: tabA.id,
            in: storeA,
            settleDelayOverride: 0
        )
        expectEqual(reportA.updatedCount, 1, "the newer upstream version replaces the local edit")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try storeA.entry(id: entryA.id)?.flavours ?? []),
            "newer text"
        )
        expectEqual(try storeA.entry(id: entryA.id)?.note, "newer note")

        let reportB = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        expectEqual(reportB.updatedCount, 0, "B's own write is an echo")
        expectEqual(reportB.reassertedCount, 0)
        expectEqual(
            FlavourDecoder.storedPlainText(from: try storeB.entry(id: entryB.id)?.flavours ?? []),
            "newer text"
        )
        expectEqual(try storeB.entry(id: entryB.id)?.note, "newer note")
    }

    TestRunner.add("editing a legacy imported row reuses its existing stem") {
        let folder = try makeTempDirectory(prefix: "copyq-legacy-stem")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LegacyStem", syncFolder: folder.path))
        let stem = "copyq_20261025120000501"
        let unrelatedStem = "copyq_20261025120000502"
        let stemDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the legacy stem timestamp")
        try writeGroup("alpha", stem: stem, in: folder, mtime: stemDate)
        try writeGroup("unrelated", stem: unrelatedStem, in: folder)

        let entry = try store.insert(ClipboardEntry(
            createdAt: stemDate,
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        expectNil(CopyQSyncDeletion.syncBaseName(of: entry), "the legacy row records no stem")

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        _ = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")

        expectEqual(
            try syncFiles(in: folder).filter { $0.hasSuffix(".txt") },
            ["\(stem).txt", "\(unrelatedStem).txt"],
            "the edit reuses the legacy group instead of adding a second stem"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first { $0.baseName == stem }?.text,
            "beta"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first { $0.baseName == unrelatedStem }?.text,
            "unrelated",
            "an unrelated group is untouched"
        )
        expectEqual(
            try store.writtenSyncStem(forEntryID: entry.id, folder: folder.path),
            stem,
            "the row now records the stem it reused"
        )

        for _ in 0..<2 {
            let report = try watcher.scanFolder(
                atPath: folder.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(report.importedCount + report.updatedCount + report.reassertedCount, 0)
        }
        expectEqual(try syncFiles(in: folder).count, 2, "the folder keeps exactly two groups")
    }

    TestRunner.add("deleting a legacy imported row moves its existing group to trash") {
        let folder = try makeTempDirectory(prefix: "copyq-legacy-delete")
        let trash = try makeTempDirectory(prefix: "copyq-legacy-delete-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LegacyDelete", syncFolder: folder.path))
        let stem = "copyq_20261025120000504"
        let stemDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the legacy stem timestamp")
        try writeGroup("alpha", stem: stem, in: folder, mtime: stemDate)
        let entry = try store.insert(ClipboardEntry(
            createdAt: stemDate,
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))

        let history = ClipboardHistory(store: store)
        history.syncTrashRoot = trash
        try history.delete(entry.id)

        expectEqual(try store.count(tabID: tab.id), 0, "the row is deleted")
        expectEqual(try syncFiles(in: folder), [], "the owned legacy group leaves the folder")
        expectEqual(try CopyQSyncTrash.summary(trashRoot: trash).batchCount, 1)
    }

    TestRunner.add("a capture write reuses an imported row's base-name stem") {
        let folder = try makeTempDirectory(prefix: "copyq-capture-base-name")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "CaptureBaseName", syncFolder: folder.path))
        let stem = "copyq_20261025120000503"
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        try writeGroup("alpha", stem: stem, in: folder, mtime: createdAt)
        let entry = try store.insert(ClipboardEntry(
            createdAt: createdAt,
            tabID: tab.id,
            flavours: [
                Fixtures.text("alpha"),
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(stem.utf8)),
            ]
        ))

        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        expectEqual(written?.stem, stem, "the write reuses the imported row's stem")
        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "no second group is created")
        expectEqual(
            try store.writtenSyncStem(forEntryID: entry.id, folder: folder.path),
            stem,
            "the row records the stem it wrote"
        )
    }

    TestRunner.add("a duplicate capture that moves the date keeps the legacy stem for the next edit") {
        let folder = try makeTempDirectory(prefix: "copyq-legacy-duplicate")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LegacyDuplicate", syncFolder: folder.path))
        let stem = "copyq_20261025120000601"
        let entry = try insertLegacyRow(stem: stem, text: "alpha", in: folder, store: store, tabID: tab.id)

        let history = ClipboardHistory(store: store)
        let outcome = try history.record(
            [Fixtures.text("alpha")],
            into: tab,
            at: Date().addingTimeInterval(30)
        )
        guard case .duplicate = outcome else {
            TestRunner.fail("the repeated copy must collapse onto the legacy row")
            return
        }
        expectEqual(
            try store.writtenSyncStem(forEntryID: entry.id, folder: folder.path),
            stem,
            "the duplicate capture records the legacy stem before moving the date"
        )

        _ = try history.replaceText(of: entry.id, with: "beta")
        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "the edit rewrites the legacy group instead of adding a stem")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "beta",
            "the legacy group carries the edit"
        )
    }

    TestRunner.add("moving a legacy row to the top keeps its stem for the next edit") {
        let folder = try makeTempDirectory(prefix: "copyq-legacy-move-top")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LegacyMoveTop", syncFolder: folder.path))
        let stem = "copyq_20261025120000602"
        let entry = try insertLegacyRow(stem: stem, text: "alpha", in: folder, store: store, tabID: tab.id)

        let history = ClipboardHistory(store: store)
        try history.moveToTop(entry.id, at: Date().addingTimeInterval(30))
        expectEqual(
            try store.writtenSyncStem(forEntryID: entry.id, folder: folder.path),
            stem,
            "moving the row to the top records the legacy stem first"
        )

        _ = try history.replaceText(of: entry.id, with: "beta")
        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "the edit keeps the legacy group")
    }

    TestRunner.add("a rescan with a newer unchanged file keeps the legacy stem for the next edit") {
        let folder = try makeTempDirectory(prefix: "copyq-legacy-refreshed")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LegacyRefreshed", syncFolder: folder.path))
        let stem = "copyq_20261025120000603"
        let entry = try insertLegacyRow(stem: stem, text: "alpha", in: folder, store: store, tabID: tab.id)
        let originalDate = entry.createdAt

        let newerDate = Date().addingTimeInterval(60)
        try writeGroup("alpha", stem: stem, in: folder, mtime: newerDate)
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.duplicateCount, 1, "the unchanged rescan refreshes the linked row's date")
        let rescanned = try unwrap(try store.entry(id: entry.id), "the rescanned row")
        expect(
            abs(rescanned.createdAt.timeIntervalSince(newerDate)) < 0.01,
            "the newer file moves the row's creation time"
        )
        expect(rescanned.createdAt != originalDate, "the creation time changed")
        expectEqual(
            try store.writtenSyncStem(forEntryID: entry.id, folder: folder.path),
            stem,
            "the rescan records the link before moving the date"
        )

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")
        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "the edit keeps the legacy group after the rescan")
    }

    TestRunner.add("a rescan with a newer changed file keeps the legacy stem for the next edit") {
        let folder = try makeTempDirectory(prefix: "copyq-legacy-updated")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LegacyUpdated", syncFolder: folder.path))
        let stem = "copyq_20261025120000604"
        let entry = try insertLegacyRow(stem: stem, text: "alpha", in: folder, store: store, tabID: tab.id)

        let newerDate = Date().addingTimeInterval(60)
        try writeGroup("gamma", stem: stem, in: folder, mtime: newerDate)
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.updatedCount, 1, "the newer upstream file updates the row")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "gamma"
        )

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "delta")
        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "the edit keeps the legacy group after the update")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "delta"
        )
    }

    TestRunner.add("deleting a legacy row after its date moved does not resurrect the group") {
        let folder = try makeTempDirectory(prefix: "copyq-legacy-delete-moved")
        let trash = try makeTempDirectory(prefix: "copyq-legacy-delete-moved-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LegacyDeleteMoved", syncFolder: folder.path))
        let stem = "copyq_20261025120000605"
        let entry = try insertLegacyRow(stem: stem, text: "alpha", in: folder, store: store, tabID: tab.id)

        let history = ClipboardHistory(store: store)
        history.syncTrashRoot = trash
        _ = try history.record([Fixtures.text("alpha")], into: tab, at: Date().addingTimeInterval(30))
        try history.delete(entry.id)

        expectEqual(try store.count(tabID: tab.id), 0, "the row is deleted")
        expectEqual(try syncFiles(in: folder), [], "the moved legacy row still owned its group")
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        _ = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(try store.count(tabID: tab.id), 0, "the trashed group is not re-imported")
    }

    TestRunner.add("an interrupted install is repaired by the next write of the stem") {
        let folder = try makeTempDirectory(prefix: "copyq-interrupted-install")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "InterruptedInstall", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let capture = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        let stem = try unwrap(capture?.stem, "the capture was written")

        try Data("beta".utf8).write(to: folder.appendingPathComponent("\(stem).txt.tmp"))
        try Data("stale html".utf8).write(to: folder.appendingPathComponent("\(stem).html.tmp"))
        try Data("<b>stale</b>".utf8).write(to: folder.appendingPathComponent("\(stem).html.bak"))

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let stalled = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(stalled.incompleteCount, 1, "the leftover staging files stall the group")

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")

        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "the next write removes the interrupted install files")
        let repaired = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(repaired.incompleteCount, 0, "the repaired group is complete again")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "beta",
            "the repaired group carries the new content"
        )
    }

    TestRunner.add("independently captured duplicates adopt each other's stem and converge") {
        let folder = try makeTempDirectory(prefix: "copyq-duplicate-stems")
        defer { try? FileManager.default.removeItem(at: folder) }

        let storeA = try ClipboardStore(inMemory: true)
        let tabA = try storeA.insertTab(ClipboardTab(name: "DuplicateA", syncFolder: folder.path))
        let storeB = try ClipboardStore(inMemory: true)
        let tabB = try storeB.insertTab(ClipboardTab(name: "DuplicateB", syncFolder: folder.path))

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let entryA = try storeA.insert(ClipboardEntry(
            createdAt: baseDate,
            tabID: tabA.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let writtenA = try CopyQSyncWriter.shared.writeEntry(entryA, in: storeA, reason: "capture")
        let stemA = try unwrap(writtenA?.stem, "A wrote its capture")

        let entryB = try storeB.insert(ClipboardEntry(
            createdAt: baseDate.addingTimeInterval(60),
            tabID: tabB.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let writtenB = try CopyQSyncWriter.shared.writeEntry(entryB, in: storeB, reason: "capture")
        let stemB = try unwrap(writtenB?.stem, "B wrote its capture")
        expect(stemA != stemB, "the independent captures use different stems")

        let watcherA = CopyQSyncWatcher(store: storeA)
        watcherA.settleDelay = 0
        let watcherB = CopyQSyncWatcher(store: storeB)
        watcherB.settleDelay = 0

        func scanBoth() throws {
            _ = try watcherA.scanFolder(
                atPath: folder.path,
                intoTabID: tabA.id,
                in: storeA,
                settleDelayOverride: 0
            )
            _ = try watcherB.scanFolder(
                atPath: folder.path,
                intoTabID: tabB.id,
                in: storeB,
                settleDelayOverride: 0
            )
        }

        try scanBoth()
        expectEqual(
            try storeA.entryID(forWrittenSyncStem: stemB, folder: folder.path),
            entryA.id,
            "A adopts B's stem for the matching content"
        )
        expectEqual(
            try storeB.entryID(forWrittenSyncStem: stemA, folder: folder.path),
            entryB.id,
            "B adopts A's stem for the matching content"
        )
        expectEqual(try storeA.count(tabID: tabA.id), 1)
        expectEqual(try storeB.count(tabID: tabB.id), 1)

        let trash = try makeTempDirectory(prefix: "copyq-duplicate-stems-trash")
        defer { try? FileManager.default.removeItem(at: trash) }
        let historyA = ClipboardHistory(store: storeA)
        historyA.syncTrashRoot = trash
        _ = try historyA.replaceText(of: entryA.id, with: "beta")

        for _ in 0..<3 {
            try scanBoth()
        }

        let keptStem = min(stemA, stemB)
        let removedStem = max(stemA, stemB)
        expectEqual(
            try syncFiles(in: folder),
            ["\(keptStem).txt"],
            "the duplicate groups converge to one group"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "beta",
            "the converged group carries the edit"
        )
        let trashSummary = try CopyQSyncTrash.summary(trashRoot: trash)
        expectEqual(trashSummary.batchCount, 1, "the superseded group is recoverable in the trash")
        expectEqual(try storeA.count(tabID: tabA.id), 1, "A keeps one row")
        expectEqual(try storeB.count(tabID: tabB.id), 1, "B keeps one row")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try storeB.entry(id: entryB.id)?.flavours ?? []),
            "beta",
            "B's row takes the edit"
        )
        expectEqual(
            try storeA.entryID(forWrittenSyncStem: removedStem, folder: folder.path),
            nil,
            "A no longer owns the superseded stem"
        )
    }

    TestRunner.add("deleting a converged duplicate removes every owned group") {
        let folder = try makeTempDirectory(prefix: "copyq-duplicate-delete")
        let trash = try makeTempDirectory(prefix: "copyq-duplicate-delete-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }

        let storeA = try ClipboardStore(inMemory: true)
        let tabA = try storeA.insertTab(ClipboardTab(name: "DuplicateDeleteA", syncFolder: folder.path))
        let storeB = try ClipboardStore(inMemory: true)
        let tabB = try storeB.insertTab(ClipboardTab(name: "DuplicateDeleteB", syncFolder: folder.path))

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let entryA = try storeA.insert(ClipboardEntry(
            createdAt: baseDate,
            tabID: tabA.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let writtenA = try CopyQSyncWriter.shared.writeEntry(entryA, in: storeA, reason: "capture")
        let stemA = try unwrap(writtenA?.stem, "A wrote its capture")
        let entryB = try storeB.insert(ClipboardEntry(
            createdAt: baseDate.addingTimeInterval(60),
            tabID: tabB.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let writtenB = try CopyQSyncWriter.shared.writeEntry(entryB, in: storeB, reason: "capture")
        let stemB = try unwrap(writtenB?.stem, "B wrote its capture")
        expect(stemA != stemB, "the independent captures use different stems")

        let watcherA = CopyQSyncWatcher(store: storeA)
        watcherA.settleDelay = 0
        let watcherB = CopyQSyncWatcher(store: storeB)
        watcherB.settleDelay = 0
        _ = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        _ = try watcherA.scanFolder(
            atPath: folder.path,
            intoTabID: tabA.id,
            in: storeA,
            settleDelayOverride: 0
        )
        expectEqual(try storeA.count(tabID: tabA.id), 1)
        expectEqual(
            try storeA.entryID(forWrittenSyncStem: stemB, folder: folder.path),
            entryA.id
        )

        let historyA = ClipboardHistory(store: storeA)
        historyA.syncTrashRoot = trash
        try historyA.delete(entryA.id)

        expectEqual(try storeA.count(tabID: tabA.id), 0, "the row is deleted")
        expectEqual(try syncFiles(in: folder), [], "both owned groups leave the folder")
        expectEqual(
            try CopyQSyncTrash.summary(trashRoot: trash).batchCount,
            2,
            "both owned groups are recoverable in the trash"
        )
    }

    TestRunner.add("moving a converged duplicate relocates every owned group") {
        let folder = try makeTempDirectory(prefix: "copyq-duplicate-move")
        let destination = try makeTempDirectory(prefix: "copyq-duplicate-move-destination")
        let trash = try makeTempDirectory(prefix: "copyq-duplicate-move-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: trash)
        }

        let storeA = try ClipboardStore(inMemory: true)
        let tabA = try storeA.insertTab(ClipboardTab(name: "DuplicateMoveA", syncFolder: folder.path))
        let storeB = try ClipboardStore(inMemory: true)
        let tabB = try storeB.insertTab(ClipboardTab(name: "DuplicateMoveB", syncFolder: folder.path))
        let destinationTab = try storeA.insertTab(ClipboardTab(
            name: "DuplicateMoveDestination",
            syncFolder: destination.path
        ))

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let entryA = try storeA.insert(ClipboardEntry(
            createdAt: baseDate,
            tabID: tabA.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let writtenA = try CopyQSyncWriter.shared.writeEntry(entryA, in: storeA, reason: "capture")
        _ = try unwrap(writtenA?.stem, "A wrote its capture")
        let entryB = try storeB.insert(ClipboardEntry(
            createdAt: baseDate.addingTimeInterval(60),
            tabID: tabB.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let writtenB = try CopyQSyncWriter.shared.writeEntry(entryB, in: storeB, reason: "capture")
        let stemB = try unwrap(writtenB?.stem, "B wrote its capture")

        let watcherA = CopyQSyncWatcher(store: storeA)
        watcherA.settleDelay = 0
        let watcherB = CopyQSyncWatcher(store: storeB)
        watcherB.settleDelay = 0
        _ = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        _ = try watcherA.scanFolder(
            atPath: folder.path,
            intoTabID: tabA.id,
            in: storeA,
            settleDelayOverride: 0
        )
        _ = try watcherB.scanFolder(
            atPath: folder.path,
            intoTabID: tabB.id,
            in: storeB,
            settleDelayOverride: 0
        )
        expectEqual(
            try storeA.entryID(forWrittenSyncStem: stemB, folder: folder.path),
            entryA.id
        )

        let historyA = ClipboardHistory(store: storeA)
        historyA.syncTrashRoot = trash
        let report = try historyA.move(ids: [entryA.id], toTabID: destinationTab.id)

        expectEqual(report.movedEntryCount, 1)
        expectEqual(try syncFiles(in: folder), [], "every source group leaves the source folder")
        let destinationFiles = try syncFiles(in: destination)
        expectEqual(destinationFiles.count, 1, "the destination receives one group")
        let moved = try unwrap(try storeA.entry(id: entryA.id), "the moved row")
        expectEqual(moved.tabID, destinationTab.id)
        expectEqual(
            FlavourDecoder.storedPlainText(from: moved.flavours),
            "alpha",
            "the relocated group carries the content"
        )
    }

    TestRunner.add("a canonical duplicate adopts the incoming stem") {
        let folder = try makeTempDirectory(prefix: "copyq-canonical-duplicate")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "CanonicalDuplicate", syncFolder: folder.path))
        let stem = "copyq_20261025120000701"
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            tabID: tab.id,
            flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("alpha".utf8)),
                Flavour(itemIndex: 0, type: PasteboardTypes.plainText, data: Data("alpha".utf8)),
            ]
        ))
        try writeGroup("alpha", stem: stem, in: folder, mtime: Date().addingTimeInterval(60))

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.duplicateCount, 1, "the canonical duplicate is not inserted")
        expectEqual(try store.count(tabID: tab.id), 1)
        expectEqual(
            try store.entryID(forWrittenSyncStem: stem, folder: folder.path),
            entry.id,
            "the incoming stem is adopted for the matching row"
        )

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")
        expectEqual(try syncFiles(in: folder), ["\(stem).txt"], "the edit rewrites the adopted stem")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "beta"
        )
    }

    TestRunner.add("a legacy written stem is recovered when the row's creation time moved") {
        let folder = try makeTempDirectory(prefix: "copyq-recover-stem")
        let trash = try makeTempDirectory(prefix: "copyq-recover-stem-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "RecoverStem", syncFolder: folder.path))
        let stem = "copyq_20261025120000711"
        let entry = try insertLegacyRow(stem: stem, text: "alpha", in: folder, store: store, tabID: tab.id)
        try store.recordWrittenSyncStem(stem, folder: folder.path)
        try store.touch(id: entry.id, at: Date().addingTimeInterval(3600))

        let history = ClipboardHistory(store: store)
        history.syncTrashRoot = trash
        _ = try history.replaceText(of: entry.id, with: "beta")

        expectEqual(
            try syncFiles(in: folder),
            ["\(stem).txt"],
            "the recovered stem is rewritten instead of adding a group"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first?.text,
            "beta"
        )
        expectEqual(
            try store.entryID(forWrittenSyncStem: stem, folder: folder.path),
            entry.id,
            "the recovered link is durable"
        )
    }

    TestRunner.add("an owned unlinked written stem with a stale payload stays suppressed") {
        let folder = try makeTempDirectory(prefix: "copyq-owned-unlinked")
        let root = try makeTempDirectory(prefix: "copyq-owned-unlinked-db")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: root)
        }

        let stem = "copyq_20261025120000714"
        let stemDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the stem timestamp")
        try writeGroup("gamma", stem: stem, in: folder, mtime: stemDate)

        let dbPath = root.appendingPathComponent("history.sqlite").path
        let store = try ClipboardStore(path: dbPath)
        let tab = try store.insertTab(ClipboardTab(name: "OwnedUnlinked", syncFolder: folder.path))
        let entry = try store.insert(ClipboardEntry(
            createdAt: stemDate,
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        try store.recordWrittenSyncStem(stem, folder: folder.path, entryID: entry.id)
        var preferences = try store.preferences()
        preferences.syncPaused = true
        try store.setPreferences(preferences)
        try store.delete(id: entry.id)
        expect(try store.isWrittenSyncStem(stem, folder: folder.path), "the paused delete keeps the watermark")

        let reopened = try ClipboardStore(path: dbPath)
        expect(try reopened.isWrittenSyncStem(stem, folder: folder.path), "the owned stale stem stays suppressed")
        expectNil(
            try reopened.entryID(forWrittenSyncStem: stem, folder: folder.path),
            "the owner is gone"
        )
        let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: reopened)
        expectEqual(report.importedCount, 0, "the stale group is not imported back")
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first { $0.baseName == stem }?.text,
            "gamma",
            "the suppressed group is untouched"
        )
    }

    TestRunner.add("a legacy unowned written stem is released once at upgrade") {
        let folder = try makeTempDirectory(prefix: "copyq-legacy-release")
        let root = try makeTempDirectory(prefix: "copyq-legacy-release-db")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: root)
        }

        let stem = "copyq_20261025120000715"
        let stemDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the stem timestamp")
        try writeGroup("delta", stem: stem, in: folder, mtime: stemDate)

        let dbPath = root.appendingPathComponent("history.sqlite").path
        let store = try ClipboardStore(path: dbPath)
        let tab = try store.insertTab(ClipboardTab(name: "LegacyRelease", syncFolder: folder.path))
        try store.recordWrittenSyncStem(stem, folder: folder.path)
        expect(try store.isWrittenSyncStem(stem, folder: folder.path), "the legacy row suppresses until the next open")

        let reopened = try ClipboardStore(path: dbPath)
        expect(
            !(try reopened.isWrittenSyncStem(stem, folder: folder.path)),
            "the unowned legacy stem is released on open"
        )
        let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: reopened)
        expectEqual(report.importedCount, 1, "the released group imports")
        expectEqual(try reopened.count(tabID: tab.id), 1, "the imported row is visible")
    }

    TestRunner.add("a legacy unowned written stem is kept while its folder is unreadable") {
        let root = try makeTempDirectory(prefix: "copyq-unreadable-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("missing-sync", isDirectory: true)

        let dbPath = root.appendingPathComponent("history.sqlite").path
        let stem = "copyq_20261025120000716"
        let store = try ClipboardStore(path: dbPath)
        let tab = try store.insertTab(ClipboardTab(name: "UnreadableLegacy", syncFolder: folder.path))
        try store.recordWrittenSyncStem(stem, folder: folder.path)
        expect(try store.isWrittenSyncStem(stem, folder: folder.path), "the legacy row starts suppressed")

        let reopened = try ClipboardStore(path: dbPath)
        expect(
            try reopened.isWrittenSyncStem(stem, folder: folder.path),
            "an unreadable folder does not release the legacy row"
        )
        expectEqual(
            try reopened.reclaimOrphanedWrittenSyncStems(),
            0,
            "the unreadable folder keeps its rows"
        )

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeGroup("delta", stem: stem, in: folder)
        expectEqual(
            try reopened.reclaimOrphanedWrittenSyncStems(),
            1,
            "the readable folder releases the unlinked row"
        )
        expect(
            !(try reopened.isWrittenSyncStem(stem, folder: folder.path)),
            "the row is released once the folder is readable"
        )
        let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: reopened)
        expectEqual(report.importedCount, 1, "the released group imports")
        expectEqual(try reopened.count(tabID: tab.id), 1, "the imported row is visible")
    }

    TestRunner.add("an unlinked written stem with a different payload stays suppressed") {
        let folder = try makeTempDirectory(prefix: "copyq-recover-mismatch")
        let trash = try makeTempDirectory(prefix: "copyq-recover-mismatch-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "RecoverMismatch", syncFolder: folder.path))
        let stem = "copyq_20261025120000712"
        let stemDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the stem timestamp")
        try writeGroup("gamma", stem: stem, in: folder, mtime: stemDate)
        let entry = try store.insert(ClipboardEntry(
            createdAt: stemDate,
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        try store.recordWrittenSyncStem(stem, folder: folder.path)
        try store.touch(id: entry.id, at: Date().addingTimeInterval(3600))

        let history = ClipboardHistory(store: store)
        history.syncTrashRoot = trash
        _ = try history.replaceText(of: entry.id, with: "beta")

        expectNil(
            try store.entryID(forWrittenSyncStem: stem, folder: folder.path),
            "a mismatched payload is not adopted"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first { $0.baseName == stem }?.text,
            "gamma",
            "the suppressed group is untouched"
        )
    }

    TestRunner.add("an unlinked written stem with ambiguous payload matches stays suppressed") {
        let folder = try makeTempDirectory(prefix: "copyq-recover-ambiguous")
        let trash = try makeTempDirectory(prefix: "copyq-recover-ambiguous-trash")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "RecoverAmbiguous", syncFolder: folder.path))
        let stem = "copyq_20261025120000713"
        let stemDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the stem timestamp")
        try writeGroup("alpha", stem: stem, in: folder, mtime: stemDate)
        _ = try store.insert(ClipboardEntry(
            createdAt: stemDate,
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        _ = try store.insert(ClipboardEntry(
            createdAt: stemDate.addingTimeInterval(1),
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let editing = try store.insert(ClipboardEntry(
            createdAt: stemDate.addingTimeInterval(2),
            tabID: tab.id,
            flavours: [Fixtures.text("gamma")]
        ))
        try store.recordWrittenSyncStem(stem, folder: folder.path)
        try store.touch(id: editing.id, at: Date().addingTimeInterval(3600))

        let history = ClipboardHistory(store: store)
        history.syncTrashRoot = trash
        _ = try history.replaceText(of: editing.id, with: "delta")

        expectNil(
            try store.entryID(forWrittenSyncStem: stem, folder: folder.path),
            "an ambiguous payload match is not adopted"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items.first { $0.baseName == stem }?.text,
            "alpha",
            "the suppressed group is untouched"
        )
    }

    TestRunner.add("a manual import keeps the creation time of this app's own edited group") {
        let folder = try makeTempDirectory(prefix: "copyq-import-own-edit")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "ImportOwnEdit", syncFolder: folder.path))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = try store.insert(ClipboardEntry(
            createdAt: createdAt,
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        expectNotNil(written, "the capture was written")

        let history = ClipboardHistory(store: store)
        _ = try history.replaceText(of: entry.id, with: "beta")

        let report = try CopyQSyncBridge.importSyncFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store
        )
        expectEqual(report.duplicateCount, 1, "this app's own edit is an echo duplicate")
        let row = try unwrap(try store.entry(id: entry.id), "the edited row")
        expect(
            abs(row.createdAt.timeIntervalSince(createdAt)) < 0.001,
            "the manual import keeps the row's creation time"
        )
        expectEqual(FlavourDecoder.storedPlainText(from: row.flavours), "beta")
    }

    TestRunner.add("a manual import refreshes the creation time for an unchanged external group") {
        let folder = try makeTempDirectory(prefix: "copyq-import-external")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "ImportExternal", syncFolder: folder.path))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date().addingTimeInterval(60)
        let stem = CopyQSyncBridge.formatTimestamp(createdAt)
        try writeGroup("alpha", stem: stem, in: folder, mtime: newerDate)
        let entry = try store.insert(ClipboardEntry(
            createdAt: createdAt,
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))

        let report = try CopyQSyncBridge.importSyncFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store
        )
        expectEqual(report.duplicateCount, 1, "the external group is an unchanged duplicate")
        let row = try unwrap(try store.entry(id: entry.id), "the row")
        expect(
            abs(row.createdAt.timeIntervalSince(newerDate)) < 0.01,
            "an unchanged external group may refresh the row's date"
        )
    }

    TestRunner.add("a tab migrated from switches-off becomes bidirectional") {
        let folder = try makeTempDirectory(prefix: "copyq-migrated-tab")
        defer { try? FileManager.default.removeItem(at: folder) }
        let dbDir = try makeTempDirectory(prefix: "copyq-migrated-db")
        defer { try? FileManager.default.removeItem(at: dbDir) }
        let dbPath = dbDir.appendingPathComponent("history.sqlite").path

        let rawDB = try SQLiteDatabase(path: dbPath)
        rawDB.userVersion = 7
        try rawDB.execute("""
        CREATE TABLE tabs (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT    NOT NULL,
            position        INTEGER NOT NULL,
            is_default      INTEGER NOT NULL DEFAULT 0,
            sync_folder     TEXT,
            sync_write_back INTEGER NOT NULL DEFAULT 0,
            sync_watch      INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE written_sync_stems (
            stem TEXT NOT NULL, folder TEXT NOT NULL, written_at REAL NOT NULL,
            PRIMARY KEY (stem, folder)
        );
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            tab_id INTEGER NOT NULL DEFAULT 0,
            note TEXT NOT NULL DEFAULT '',
            locally_edited INTEGER NOT NULL DEFAULT 0,
            last_imported_fingerprint TEXT NOT NULL DEFAULT '',
            fingerprint TEXT NOT NULL
        );
        CREATE TABLE flavours (
            entry_id INTEGER NOT NULL, item_index INTEGER NOT NULL, type TEXT NOT NULL,
            data BLOB NOT NULL, compressed INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entry_id, item_index, type)
        );
        CREATE VIRTUAL TABLE search_fts USING fts5(text, tokenize='trigram');
        """)
        let insert = try rawDB.prepare("""
            INSERT INTO tabs (name, position, is_default, sync_folder, sync_write_back, sync_watch)
            VALUES ('Retired switches', 1, 1, ?, 0, 0)
            """)
        try insert.bind(1, folder.path)
        try insert.run()
        insert.finalize()

        // A stem written by the old build, plus a row whose creation time has
        // since moved away from the stem's name stamp. The migration should
        // still link them by the one-second proximity rule.
        let legacyStem = "copyq_20231114221320000"
        let legacyEntry = try rawDB.prepare("""
            INSERT INTO entries (created_at, pinned, tab_id, note, fingerprint)
            VALUES (?, 0, 1, '', 'legacy')
            """)
        try legacyEntry.bind(1, Date(timeIntervalSince1970: 1_700_000_000.5).timeIntervalSince1970)
        try legacyEntry.run()
        let legacyEntryID = rawDB.lastInsertRowID
        legacyEntry.finalize()
        let legacyStemRow = try rawDB.prepare(
            "INSERT INTO written_sync_stems (stem, folder, written_at) VALUES (?, ?, 1)"
        )
        try legacyStemRow.bind(1, legacyStem)
        try legacyStemRow.bind(2, folder.path)
        try legacyStemRow.run()
        legacyStemRow.finalize()

        // A pending local edit from the previous build. That build never wrote
        // the edit to the folder, so it is newer than the row's creation time.
        let editedStem = "copyq_20231114221500999"
        let editedCreatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let editedEntry = try rawDB.prepare("""
            INSERT INTO entries (created_at, pinned, tab_id, note, locally_edited, fingerprint)
            VALUES (?, 0, 1, '', 1, 'edited')
            """)
        try editedEntry.bind(1, editedCreatedAt.timeIntervalSince1970)
        try editedEntry.run()
        let editedEntryID = rawDB.lastInsertRowID
        editedEntry.finalize()
        let editedFlavour = try rawDB.prepare(
            "INSERT INTO flavours (entry_id, item_index, type, data, compressed) VALUES (?, 0, ?, ?, 0)"
        )
        try editedFlavour.bind(1, editedEntryID)
        try editedFlavour.bind(2, CopyQFormat.text)
        try editedFlavour.bind(3, Data("local edit".utf8))
        try editedFlavour.run()
        editedFlavour.reset()
        try editedFlavour.bind(1, editedEntryID)
        try editedFlavour.bind(2, Fingerprint.syncBaseNameFlavour)
        try editedFlavour.bind(3, Data(editedStem.utf8))
        try editedFlavour.run()
        editedFlavour.finalize()
        try writeGroup(
            "stale upstream",
            stem: editedStem,
            in: folder,
            mtime: editedCreatedAt.addingTimeInterval(50)
        )
        rawDB.userVersion = 7

        let store = try ClipboardStore(path: dbPath)
        expectEqual(store.database.userVersion, ClipboardStore.currentSchemaVersion)
        expectEqual(try store.tabs().first?.syncFolder, folder.path, "the folder survives the migration")

        let columns = try store.database.prepare("PRAGMA table_info(tabs)")
        defer { columns.finalize() }
        var names: [String] = []
        while try columns.step() {
            names.append(columns.string(at: 1) ?? "")
        }
        expect(!names.contains("sync_write_back"), "the retired write-back column is gone")
        expect(!names.contains("sync_watch"), "the retired watch column is gone")

        guard let tab = try store.tabs().first else {
            TestRunner.fail("the migrated tab disappeared")
            return
        }
        guard let legacy = try store.entry(id: legacyEntryID) else {
            TestRunner.fail("the legacy entry was not migrated")
            return
        }
        expectEqual(
            try store.writtenSyncStem(forEntryID: legacy.id, folder: folder.path),
            legacyStem,
            "the migration links a legacy written stem to its row"
        )
        expectEqual(
            try store.entryID(forWrittenSyncStem: legacyStem, folder: folder.path),
            legacy.id,
            "the legacy stem resolves back to the row"
        )
        expectEqual(
            try unwrap(try store.syncUpdatedAt(id: legacyEntryID), "the migrated version"),
            legacy.createdAt,
            "a row without a pending edit keeps its creation time as its version"
        )

        let editedVersion = try unwrap(
            try store.syncUpdatedAt(id: editedEntryID),
            "the version of the pending edit"
        )
        expect(
            editedVersion > editedCreatedAt,
            "a pending local edit is stamped newer than its creation time"
        )

        // The other machine's version is newer than the row's creation time but
        // older than the pending local edit, so it must not replace the edit.
        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let migrationScan = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(migrationScan.updatedCount, 0, "the older upstream version does not replace the edit")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: editedEntryID)?.flavours ?? []),
            "local edit",
            "the migrated local edit survives the first scan"
        )
        expectEqual(
            try CopyQSyncFolder.read(atPath: folder.path).items
                .first { $0.baseName == editedStem }?.text,
            "local edit",
            "the pending edit is re-asserted into the folder"
        )
        expectEqual(
            try store.isEntryLocallyEdited(id: editedEntryID),
            false,
            "writing the pending edit back clears its marker"
        )

        // Outbound: a capture is written even though both switches were off.
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Fixtures.text("outbound")]
        ))
        let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
        expectNotNil(written, "a folder alone enables write-back after the migration")

        // Inbound: an arriving group is imported.
        try writeGroup("inbound", stem: "copyq_20261025120000111", in: folder)
        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.importedCount, 1, "a folder alone enables watching after the migration")
    }

    TestRunner.add("unknown and non-item files in a sync folder stay ignored") {
        let folder = try makeTempDirectory(prefix: "copyq-unknown-files")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "IgnoredFiles", syncFolder: folder.path))

        try Data("not an item".utf8).write(to: folder.appendingPathComponent("notes.md"))
        try Data("not an item".utf8).write(to: folder.appendingPathComponent("report.pdf"))
        try Data("finder noise".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        try writeGroup("a real item", stem: "copyq_20261025120000121", in: folder)

        let contents = try CopyQSyncFolder.read(atPath: folder.path)
        expectEqual(contents.items.count, 1, "only the known item extension is read")
        expectEqual(Set(contents.ignoredFiles), ["notes.md", "report.pdf"], "unknown extensions are ignored")

        let watcher = CopyQSyncWatcher(store: store)
        watcher.settleDelay = 0
        let report = try watcher.scanFolder(
            atPath: folder.path,
            intoTabID: tab.id,
            in: store,
            settleDelayOverride: 0
        )
        expectEqual(report.importedCount, 1, "the known item imports")
        expectEqual(report.failureCount, 0, "ignored files are not failures")
        expectEqual(try store.count(tabID: tab.id), 1, "no entry is created for an ignored file")
        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.recentEntries(tabID: tab.id).first?.flavours ?? []),
            "a real item"
        )
    }

    TestRunner.add("an edit without a sync folder succeeds locally and reports no sync failure") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "LocalOnly"))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))

        let history = ClipboardHistory(store: store)
        var failures: [String] = []
        history.onSyncEditFailure = { failures.append($0) }
        _ = try history.replaceText(of: entry.id, with: "beta")

        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "beta",
            "the local edit succeeds"
        )
        expectEqual(failures, [], "a tab without a folder reports no sync failure")
    }

    TestRunner.add("an edit with an unreadable sync folder keeps the local text and reports the failure") {
        let folder = try makeTempDirectory(prefix: "copyq-edit-unreadable")
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("gone").path

        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: "Unreadable", syncFolder: missing))
        let entry = try store.insert(ClipboardEntry(
            createdAt: Date(),
            tabID: tab.id,
            flavours: [Fixtures.text("alpha")]
        ))

        let logPath = folder.appendingPathComponent("sync.log").path
        CopyQSyncWriter.shared.customLogFilePath = logPath
        defer { CopyQSyncWriter.shared.customLogFilePath = nil }

        let history = ClipboardHistory(store: store)
        var failures: [String] = []
        history.onSyncEditFailure = { failures.append($0) }
        _ = try history.replaceText(of: entry.id, with: "beta")

        expectEqual(
            FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
            "beta",
            "the local edit succeeds even when the folder is unreadable"
        )
        expectEqual(failures.count, 1, "the sync failure is reported once")
        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        expect(log.contains("ERROR"), "the sync failure is written to the log")
        expect(log.contains("does not exist"), "the log explains why the write failed")
    }
}
