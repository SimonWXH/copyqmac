// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncDeletionTests.swift
//
// Two-way deletion sync: app deletes move owned groups into the app trash,
// upstream group removal drops the tracked local entry only on a settled
// rescan, pause gates both directions, and reconciliation reports before it
// acts.

import AppKit
import Foundation

@MainActor
private final class SyncDeletionWindowControllerStub: NSObject, WindowControllerProtocol {
    var isVisible = false
    func show() {}
    func hide() {}
}

func registerCopyQSyncDeletionTests() {
    TestRunner.currentSuite = "CopyQSyncDeletion"

    func scratch() throws -> (root: URL, sync: URL, trash: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-deletion-\(UUID().uuidString)", isDirectory: true)
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        return (root, sync, trash)
    }

    func writeTextGroup(_ text: String, stem: String, in folder: URL) throws {
        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data(text.utf8))
        try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: data), into: folder.path)
    }

    func readTrashRecord(in trash: URL) throws -> (directory: URL, record: CopyQSyncTrashRecord) {
        let directories = try FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let directory = try unwrap(directories.first, "a trash batch directory")
        let data = try Data(contentsOf: directory.appendingPathComponent(CopyQSyncTrash.metadataFileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([CopyQSyncTrashRecord].self, from: data)
        return (directory, try unwrap(records.first, "a trash metadata record"))
    }

    TestRunner.add("deleting an owning entry moves its group into the trash and removes it from the folder") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "OwningTab",
                syncFolder: paths.sync.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let stem = "copyq_20261025120000123"
            var data = CopyQDataMap()
            data.set(CopyQFormat.text, Data("delete this payload".utf8))
            data.set(CopyQFormat.html, Data("<b>delete this payload</b>".utf8))
            try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: data), into: paths.sync.path)

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0
            let report = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(report.importedCount, 1, "the item is imported and owns its stem")
            let entry = try unwrap(try store.recentEntries(tabID: tab.id).first)
            expectEqual(CopyQSyncDeletion.syncBaseName(of: entry), stem)

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            try history.delete(entry.id)

            expectEqual(try store.count(tabID: tab.id), 0, "the entry is gone from the store")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.sync.path),
                [],
                "the sync folder no longer holds the deleted group"
            )

            let trash = try readTrashRecord(in: paths.trash)
            expectEqual(trash.record.stem, stem, "trash records the stem")
            expectEqual(trash.record.tabID, tab.id, "trash records the tab id")
            expectEqual(trash.record.tabName, "OwningTab", "trash records the tab name")
            expectEqual(trash.record.reason, .localDelete)
            expectEqual(
                Set(trash.record.files),
                Set(["\(stem).txt", "\(stem).html"]),
                "trash records the original file names"
            )
            expectEqual(
                try String(contentsOf: trash.directory.appendingPathComponent("\(stem).txt"), encoding: .utf8),
                "delete this payload",
                "the text bytes are unchanged"
            )
            expectEqual(
                try String(contentsOf: trash.directory.appendingPathComponent("\(stem).html"), encoding: .utf8),
                "<b>delete this payload</b>",
                "the HTML bytes are unchanged"
            )

            let summary = try CopyQSyncTrash.summary(trashRoot: paths.trash)
            expectEqual(summary.batchCount, 1)
            expectEqual(summary.fileCount, 2, "metadata is not counted as a recovered file")
            let emptied = try CopyQSyncTrash.empty(trashRoot: paths.trash)
            expectEqual(emptied.batchCount, 1)
            expect(!FileManager.default.fileExists(atPath: paths.trash.path), "emptying removes the trash")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("deleting a non-owning entry leaves unrelated sync files alone") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "LocalOnlyTab",
                syncFolder: paths.sync.path
            ))
            var preferences = try store.preferences()
            try store.setPreferences(preferences)

            let unrelatedStem = "copyq_20261025120000999"
            try writeTextGroup("someone else's entry", stem: unrelatedStem, in: paths.sync)

            let local = try store.insert(ClipboardEntry(
                createdAt: Date(),
                tabID: tab.id,
                flavours: [Fixtures.text("a local capture with no sync stem")]
            ))
            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            try history.delete(local.id)

            expectEqual(try store.count(tabID: tab.id), 0, "the local entry is deleted")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.sync.path),
                ["\(unrelatedStem).txt"],
                "a group the entry does not own is untouched"
            )
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a group disappearing is acted on only after a settled rescan") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "RemoteDeleteTab",
                syncFolder: paths.sync.path
            ))
            let stem = "copyq_20261025120000124"
            try writeTextGroup("remove me upstream", stem: stem, in: paths.sync)

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0.05
            watcher.trashRoot = paths.trash
            let first = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(first.importedCount, 1)

            try FileManager.default.removeItem(at: paths.sync.appendingPathComponent("\(stem).txt"))
            let missingScan = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0.05
            )
            expectEqual(missingScan.remoteDeletedCount, 0, "the scan that first notices absence only records it")
            expectEqual(missingScan.pendingRemoteDeletionCount, 1)
            expectEqual(try store.count(tabID: tab.id), 1, "the entry survives the first absent scan")

            Thread.sleep(forTimeInterval: 0.12)
            let settledScan = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0.05
            )
            expectEqual(settledScan.remoteDeletedCount, 1, "the settled rescan removes the tracked entry")
            expectEqual(settledScan.pendingRemoteDeletionCount, 0)
            expectEqual(try store.count(tabID: tab.id), 0)

            let trash = try readTrashRecord(in: paths.trash)
            expectEqual(trash.record.stem, stem)
            expectEqual(trash.record.reason, .remoteDelete)
            expectEqual(
                try String(contentsOf: trash.directory.appendingPathComponent("\(stem).txt"), encoding: .utf8),
                "remove me upstream",
                "the removed payload stays recoverable"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a group recreated before the settled rescan keeps its entry") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "RewriteTransientTab",
                syncFolder: paths.sync.path
            ))
            let stem = "copyq_20261025120000125"
            try writeTextGroup("alpha", stem: stem, in: paths.sync)

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0.05
            watcher.trashRoot = paths.trash
            _ = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )

            let file = paths.sync.appendingPathComponent("\(stem).txt")
            try FileManager.default.removeItem(at: file)
            let missingScan = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0.05
            )
            expectEqual(missingScan.pendingRemoteDeletionCount, 1)

            try Data("beta".utf8).write(to: file)
            Thread.sleep(forTimeInterval: 0.12)
            let settledScan = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0.05
            )
            expectEqual(settledScan.remoteDeletedCount, 0, "a rewritten group is not a deletion")
            expectEqual(settledScan.pendingRemoteDeletionCount, 0)
            expectEqual(try store.count(tabID: tab.id), 1, "the entry stays")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a locally edited entry is removed after its edit was written back") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "EditedProtectionTab",
                syncFolder: paths.sync.path
            ))
            let stem = "copyq_20261025120000126"
            try writeTextGroup("alpha", stem: stem, in: paths.sync)

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0
            watcher.trashRoot = paths.trash
            _ = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            let entry = try unwrap(try store.recentEntries(tabID: tab.id).first)
            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            _ = try history.replaceText(of: entry.id, with: "alpha edited locally")
            expectEqual(
                try store.isEntryLocallyEdited(id: entry.id),
                false,
                "a successful write-back leaves no pending local edit"
            )

            try FileManager.default.removeItem(at: paths.sync.appendingPathComponent("\(stem).txt"))
            _ = try watcher.scanFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
            let settledScan = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(settledScan.remoteDeletedCount, 1, "an edit that reached the folder does not block upstream deletion")
            expectEqual(settledScan.remoteDeletionSkippedCount, 0)
            expectEqual(try store.count(tabID: tab.id), 0)
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("an upstream deletion removes a locally captured entry that has no base-name flavour") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "LocalCaptureRemoteDeleteTab",
                syncFolder: paths.sync.path
            ))
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(),
                tabID: tab.id,
                flavours: [Fixtures.text("captured on this machine")]
            ))
            let written = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
            let stem = try unwrap(written?.stem, "the capture was written")
            expectNil(
                CopyQSyncDeletion.syncBaseName(of: entry),
                "a local capture is identified only through its written stem"
            )

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0
            watcher.trashRoot = paths.trash
            _ = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )

            try FileManager.default.removeItem(at: paths.sync.appendingPathComponent("\(stem).txt"))
            _ = try watcher.scanFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
            let settledScan = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(settledScan.remoteDeletedCount, 1, "the locally captured owner is resolved from its recorded stem")
            expectEqual(try store.count(tabID: tab.id), 0, "the captured row is removed")

            let trash = try readTrashRecord(in: paths.trash)
            expectEqual(trash.record.stem, stem)
            expectEqual(trash.record.reason, .remoteDelete)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a local edit that never reached the folder is kept when its group disappears") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "PendingEditProtectionTab",
                syncFolder: paths.sync.path
            ))
            let stem = "copyq_20261025120000136"
            try writeTextGroup("alpha", stem: stem, in: paths.sync)

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0
            watcher.trashRoot = paths.trash
            _ = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            let entry = try unwrap(try store.recentEntries(tabID: tab.id).first)
            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash

            var preferences = try store.preferences()
            preferences.syncPaused = true
            try store.setPreferences(preferences)
            _ = try history.replaceText(of: entry.id, with: "alpha edited locally")
            preferences.syncPaused = false
            try store.setPreferences(preferences)
            expectEqual(try store.isEntryLocallyEdited(id: entry.id), true, "the paused edit is still pending")

            try FileManager.default.removeItem(at: paths.sync.appendingPathComponent("\(stem).txt"))
            _ = try watcher.scanFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
            let settledScan = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(settledScan.remoteDeletedCount, 0, "a pending local edit is never removed")
            expectEqual(settledScan.remoteDeletionSkippedCount, 1)
            expectEqual(try store.count(tabID: tab.id), 1)
            expectEqual(
                FlavourDecoder.storedPlainText(from: try store.entry(id: entry.id)?.flavours ?? []),
                "alpha edited locally"
            )
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("paused sync performs neither deletion direction") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "PausedDeletionTab",
                syncFolder: paths.sync.path
            ))
            let stem = "copyq_20261025120000127"
            try writeTextGroup("paused payload", stem: stem, in: paths.sync)

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0
            watcher.trashRoot = paths.trash
            _ = try watcher.scanFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
            let entry = try unwrap(try store.recentEntries(tabID: tab.id).first)

            var preferences = try store.preferences()
            preferences.syncPaused = true
            try store.setPreferences(preferences)

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            try history.delete(entry.id)
            expectEqual(try store.count(tabID: tab.id), 0, "the app still deletes its local row")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.sync.path),
                ["\(stem).txt"],
                "the paused delete leaves the sync file in place"
            )
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)

            // Re-import, then delete upstream while still paused.
            _ = try watcher.scanFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
            expectEqual(try store.count(tabID: tab.id), 1)
            try FileManager.default.removeItem(at: paths.sync.appendingPathComponent("\(stem).txt"))
            _ = try watcher.scanFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)
            let pausedScan = try watcher.scanFolder(
                atPath: paths.sync.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(pausedScan.remoteDeletedCount, 0, "paused watch never removes an entry")
            expectEqual(try store.count(tabID: tab.id), 1, "the entry survives while sync is paused")
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("reconciliation reports both mismatch directions and only acts on request") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "ReconcileTab",
                syncFolder: paths.sync.path
            ))
            let orphanStem = "copyq_20261025120000128"
            try writeTextGroup("orphan group", stem: orphanStem, in: paths.sync)

            let missingStem = "copyq_20261025120000129"
            var missingData = CopyQDataMap()
            missingData.set(CopyQFormat.text, Data("entry without a file".utf8))
            let missingItem = CopyQSyncItem(baseName: missingStem, data: missingData)
            let missingEntry = try store.insert(CopyQSyncBridge.itemToEntry(missingItem, tabID: tab.id))

            let report = try CopyQSyncReconciliation.report(in: store)
            expectEqual(report.entriesWithoutFilesCount, 1, "the missing file is reported")
            expectEqual(report.fileGroupsWithoutEntriesCount, 1, "the orphan group is reported")
            expectEqual(report.tabs.first?.missingEntries.first?.stem, missingStem)
            expectEqual(report.tabs.first?.groupsWithoutEntries, [orphanStem])

            // Reporting is read-only.
            expectEqual(try store.count(tabID: tab.id), 1)
            expect(FileManager.default.fileExists(atPath: paths.sync.appendingPathComponent("\(orphanStem).txt").path))
            expectNotNil(try store.entry(id: missingEntry.id))
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)

            let result = try CopyQSyncReconciliation.apply(report, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesRemoved, 1)
            expectEqual(result.groupsImported, 1)
            expectNil(try store.entry(id: missingEntry.id), "the missing-file entry is removed")
            expectEqual(try store.count(tabID: tab.id), 1, "the orphan group becomes one entry")

            let imported = try unwrap(try store.recentEntries(tabID: tab.id).first)
            expectEqual(CopyQSyncDeletion.syncBaseName(of: imported), orphanStem)
            let trash = try readTrashRecord(in: paths.trash)
            expectEqual(trash.record.stem, missingStem)
            expectEqual(trash.record.reason, .reconciliation)
            expectEqual(
                try String(contentsOf: trash.directory.appendingPathComponent("\(missingStem).txt"), encoding: .utf8),
                "entry without a file",
                "the removed entry is recoverable"
            )

            let after = try CopyQSyncReconciliation.report(in: store)
            expectEqual(after.entriesWithoutFilesCount, 0)
            expectEqual(after.fileGroupsWithoutEntriesCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("deletion trash and archive clauses follow the selected language") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "LocalizedDeletionTab",
                syncFolder: paths.sync.path
            ))
            let stem = "copyq_20261025120000199"
            var data = CopyQDataMap()
            data.set(CopyQFormat.text, Data("blocked payload".utf8))
            let item = CopyQSyncItem(baseName: stem, data: data)
            try CopyQSyncFolder.write(item, into: paths.sync.path)
            let entry = try store.insert(CopyQSyncBridge.itemToEntry(item, tabID: tab.id))

            let blockedRoot = paths.root.appendingPathComponent("blocked-trash")
            try Data("not a directory".utf8).write(to: blockedRoot)

            let report = try CopyQSyncDeletion.deleteEntriesMissingFiles(
                [entry],
                in: store,
                trashRoot: blockedRoot,
                keepUnarchivedRows: true,
                language: .simplifiedChinese
            )
            expect(
                report.failures.contains { $0.hasPrefix("无法在重新协调前将 \(stem) 移到废纸篓：") },
                "the move clause is Chinese: \(report.failures)"
            )
            expect(
                report.failures.contains { $0.hasPrefix("无法在重新协调前归档 \(stem)：") },
                "the archive clause is Chinese: \(report.failures)"
            )
            expect(
                !report.failures.contains { $0.hasPrefix("Could not ") },
                "no English clause is left in the Chinese report: \(report.failures)"
            )
            guard let kept = report.failures.first(where: { $0.contains("Kept \(stem)") }) else {
                TestRunner.fail("the kept row is reported: \(report.failures)")
                return
            }
            expectEqual(
                Localization.runtimeMessage(kept, language: .simplifiedChinese),
                "保留了 \(stem)：其内容无法归档到应用废纸篓。"
            )
            expectNotNil(try store.entry(id: entry.id), "the row whose payload was not archived stays")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("reconciliation keeps its shipped behaviour when a payload cannot be archived") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "ReconcileBlockedTab",
                syncFolder: paths.sync.path
            ))
            let stem = "copyq_20261025120000134"
            var data = CopyQDataMap()
            data.set(CopyQFormat.text, Data("missing file".utf8))
            let entry = try store.insert(CopyQSyncBridge.itemToEntry(
                CopyQSyncItem(baseName: stem, data: data),
                tabID: tab.id
            ))

            let report = try CopyQSyncReconciliation.report(in: store)
            expectEqual(report.entriesWithoutFilesCount, 1)

            let blockedRoot = paths.root.appendingPathComponent("blocked-trash")
            try Data("not a directory".utf8).write(to: blockedRoot)
            let result = try CopyQSyncReconciliation.apply(report, in: store, trashRoot: blockedRoot)
            expectEqual(result.entriesRemoved, 1, "reconcile still removes the missing-file entry")
            expect(
                result.failures.contains { $0.contains("Could not archive") },
                "the archive failure is still reported: \(result.failures)"
            )
            expectNil(try store.entry(id: entry.id))
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("the reconciliation dialog defaults to reporting only") {
        MainActor.assumeIsolated {
            do {
                let paths = try scratch()
                defer { try? FileManager.default.removeItem(at: paths.root) }

                let store = try ClipboardStore(inMemory: true)
                let tab = try store.insertTab(ClipboardTab(
                    name: "DialogReconcileTab",
                    syncFolder: paths.sync.path
                ))
                let orphanStem = "copyq_20261025120000131"
                try writeTextGroup("orphan in dialog", stem: orphanStem, in: paths.sync)
                let missingStem = "copyq_20261025120000132"
                var missingData = CopyQDataMap()
                missingData.set(CopyQFormat.text, Data("missing file".utf8))
                let missingEntry = try store.insert(CopyQSyncBridge.itemToEntry(
                    CopyQSyncItem(baseName: missingStem, data: missingData),
                    tabID: tab.id
                ))

                let history = ClipboardHistory(store: store)
                history.syncTrashRoot = paths.trash
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                let actions = AppActions(
                    model: model,
                    windowController: SyncDeletionWindowControllerStub(),
                    presentPreferences: {}
                )
                var buttonTitles: [String] = []
                actions.alertPresenter = { alert in
                    buttonTitles = alert.buttons.map(\.title)
                    return .alertFirstButtonReturn
                }

                actions.reconcileSyncFolders(nil)

                expectEqual(buttonTitles, ["Report Only", "Reconcile", "Cancel"])
                expectEqual(try store.count(tabID: tab.id), 1, "Report Only changes nothing")
                expectNotNil(try store.entry(id: missingEntry.id))
                expect(FileManager.default.fileExists(
                    atPath: paths.sync.appendingPathComponent("\(orphanStem).txt").path
                ))
                expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a trash folder inside the sync folder is refused without deleting the entry") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "UnsafeTrashTab",
                syncFolder: paths.sync.path
            ))
            var preferences = try store.preferences()
            try store.setPreferences(preferences)

            let stem = "copyq_20261025120000130"
            try writeTextGroup("must survive", stem: stem, in: paths.sync)
            _ = try CopyQSyncBridge.importSyncFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store)
            let entry = try unwrap(try store.recentEntries(tabID: tab.id).first)

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.sync.appendingPathComponent("trash", isDirectory: true)
            expectThrows {
                try history.delete(entry.id)
            }
            expectNotNil(try store.entry(id: entry.id), "the entry stays when the files cannot be trashed")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.sync.path),
                ["\(stem).txt"],
                "the group stays in the sync folder"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("deleting a locally captured entry moves its written group to trash and removes it from sync folder") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "LocalCaptureSyncTab",
                syncFolder: paths.sync.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash

            let recorded = try history.record([Fixtures.text("local captured text")], into: tab)
            guard case .inserted(let entry) = recorded else {
                TestRunner.fail("entry should have been inserted")
                return
            }
            let writer = CopyQSyncWriter()
            let log = try writer.writeEntry(entry, in: store, reason: "capture")
            let stem = try unwrap(log?.stem)

            expect(FileManager.default.fileExists(atPath: paths.sync.appendingPathComponent("\(stem).txt").path))

            try history.delete(entry.id)

            expectEqual(try store.count(tabID: tab.id), 0, "entry deleted from store")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.sync.path),
                [],
                "file group removed from sync folder"
            )
            let trash = try readTrashRecord(in: paths.trash)
            expectEqual(trash.record.stem, stem)
            expectEqual(trash.record.reason, .localDelete)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("removing a tab leaves every file in the sync folder untouched") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            _ = try store.insertTab(ClipboardTab(name: "DefaultTab"))
            let tab = try store.insertTab(ClipboardTab(
                name: "SyncTabToRemove",
                syncFolder: paths.sync.path
            ))
            var preferences = try store.preferences()
            try store.setPreferences(preferences)

            let stem = "copyq_20261025120000777"
            try writeTextGroup("file that must survive tab deletion", stem: stem, in: paths.sync)
            _ = try CopyQSyncBridge.importSyncFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store)

            expectEqual(try store.count(tabID: tab.id), 1)
            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash

            try history.deleteTab(id: tab.id)

            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.sync.path),
                ["\(stem).txt"],
                "sync files must remain untouched on Remove Tab"
            )
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("clearing a tab requires confirmation and reports the correct count") {
        MainActor.assumeIsolated {
            do {
                let paths = try scratch()
                defer { try? FileManager.default.removeItem(at: paths.root) }

                let store = try ClipboardStore(inMemory: true)
                let tab = try store.insertTab(ClipboardTab(
                    name: "SyncTabToClear",
                    syncFolder: paths.sync.path
                ))
                var preferences = try store.preferences()
                try store.setPreferences(preferences)

                let stem1 = "copyq_20261025120000881"
                let stem2 = "copyq_20261025120000882"
                try writeTextGroup("first file", stem: stem1, in: paths.sync)
                var data2 = CopyQDataMap()
                data2.set(CopyQFormat.text, Data("second file".utf8))
                data2.set(CopyQFormat.html, Data("<b>second file</b>".utf8))
                try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem2, data: data2), into: paths.sync.path)

                _ = try CopyQSyncBridge.importSyncFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store)
                expectEqual(try store.count(tabID: tab.id), 2)

                let history = ClipboardHistory(store: store)
                history.syncTrashRoot = paths.trash
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                model.selectTab(tab.id)
                let actions = AppActions(
                    model: model,
                    windowController: SyncDeletionWindowControllerStub(),
                    presentPreferences: {}
                )

                var alertSeen = false
                var presentedInformativeText = ""
                actions.alertPresenter = { alert in
                    alertSeen = true
                    presentedInformativeText = alert.informativeText
                    return .alertSecondButtonReturn
                }

                actions.clearTab(nil)

                expect(alertSeen, "confirmation dialog was shown")
                expect(
                    presentedInformativeText.contains(paths.sync.path),
                    "dialog names the sync folder"
                )
                expect(
                    presentedInformativeText.contains("3 files"),
                    "dialog reports the correct entry file count"
                )
                expectEqual(try store.count(tabID: tab.id), 2, "cancel leaves entries untouched")
                expectEqual(
                    try Set(FileManager.default.contentsOfDirectory(atPath: paths.sync.path)),
                    Set(["\(stem1).txt", "\(stem2).txt", "\(stem2).html"]),
                    "cancel leaves sync folder files untouched"
                )

                actions.alertPresenter = { _ in .alertFirstButtonReturn }
                actions.clearTab(nil)

                expectEqual(try store.count(tabID: tab.id), 0, "confirm clears entries")
                expectEqual(
                    try FileManager.default.contentsOfDirectory(atPath: paths.sync.path),
                    [],
                    "confirm removes files from sync folder"
                )
                expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 2)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a tab with a sync folder propagates deletion without a separate switch") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "FolderOnlyTab",
                syncFolder: paths.sync.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let stem = "copyq_20261025120000991"
            try writeTextGroup("folder only text", stem: stem, in: paths.sync)
            _ = try CopyQSyncBridge.importSyncFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store)
            let entry = try unwrap(try store.recentEntries(tabID: tab.id).first)

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            try history.delete(entry.id)

            expectEqual(try store.count(tabID: tab.id), 0, "entry deleted from store")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.sync.path),
                [],
                "the group is moved to the trash because the tab has a sync folder"
            )
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("deleting an entry evicts stem from watcher in-memory knownWrittenStems") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "EvictStemTab",
                syncFolder: paths.sync.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let watcher = CopyQSyncWatcher(store: store)
            let stem = "copyq_20261025120000992"
            watcher.recordWrittenStem(stem, folder: paths.sync.path)
            expect(watcher.isWrittenByUs(stem, folder: paths.sync.path))

            try writeTextGroup("written by us text", stem: stem, in: paths.sync)
            _ = try CopyQSyncBridge.importSyncFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store)
            let entry = try unwrap(try store.recentEntries(tabID: tab.id).first)

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            try history.delete(entry.id)

            expectEqual(watcher.isWrittenByUs(stem, folder: paths.sync.path), false, "stem must be evicted from knownWrittenStems")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("retry timer is rescheduled when a remote deletion remains pending") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "RescheduleRetryTab",
                syncFolder: paths.sync.path
            ))
            let stem = "copyq_20261025120000993"
            try writeTextGroup("retry payload", stem: stem, in: paths.sync)

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 10.0
            _ = try watcher.scanFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store, settleDelayOverride: 0)

            try FileManager.default.removeItem(at: paths.sync.appendingPathComponent("\(stem).txt"))

            let report = try watcher.scanFolder(atPath: paths.sync.path, intoTabID: tab.id, in: store, settleDelayOverride: 10.0)
            expectEqual(report.pendingRemoteDeletionCount, 1)

            _ = watcher.scanAllWatchedFolders(store: store)
            expect(watcher.hasActiveRetryTimer, "retry timer must be scheduled for pending remote deletion")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }
}
