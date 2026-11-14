// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncResyncTests.swift
//
// Per-tab sync comparison: exact read-only counters for matched content,
// content differences, missing files, orphan stems, unresolved restored rows,
// and unreadable or internal items.  Reporting never changes either side.

import AppKit
import Foundation

@MainActor
private final class ResyncWindowControllerStub: NSObject, WindowControllerProtocol {
    var isVisible = false
    func show() {}
    func hide() {}
}

func registerCopyQSyncResyncTests() {
    TestRunner.currentSuite = "CopyQSyncResync"

    func scratch() throws -> (root: URL, sync: URL, trash: URL, database: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-resync-\(UUID().uuidString)", isDirectory: true)
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        return (root, sync, trash, root.appendingPathComponent("history.sqlite"))
    }

    func writeItem(_ item: CopyQSyncItem, in folder: URL) throws {
        try CopyQSyncFolder.write(item, into: folder.path)
    }

    func writeGroup(stem: String, text: String, in folder: URL) throws {
        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data(text.utf8))
        try writeItem(CopyQSyncItem(baseName: stem, data: data), in: folder)
    }

    /// File names and bytes, so a test can prove the folder was not touched.
    func folderSnapshot(_ folder: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        var snapshot: [String: Data] = [:]
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            snapshot[name] = try Data(contentsOf: url)
        }
        return snapshot
    }

    TestRunner.add("resync reports exact read-only counters") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(path: paths.database.path)
            let tab = try store.insertTab(ClipboardTab(
                name: "ReportTab",
                syncFolder: paths.sync.path
            ))

            let keepStem = "copyq_20261025120000101"
            let addStem = "copyq_20261025120000102"
            let internalStem = "copyq_20261025120000103"
            let emptyStem = "copyq_20261025120000104"
            let missingStem = "copyq_20261025120000105"

            try writeGroup(stem: keepStem, text: "keep this", in: paths.sync)
            try writeGroup(stem: addStem, text: "import this", in: paths.sync)

            var internalData = CopyQDataMap()
            internalData.set(CopyQFormat.unknownFormats, Data())
            try writeItem(CopyQSyncItem(baseName: internalStem, data: internalData), in: paths.sync)
            try writeItem(CopyQSyncItem(baseName: emptyStem, data: CopyQDataMap()), in: paths.sync)

            let keepItem = try unwrap(
                try CopyQSyncFolder.readItem(baseName: keepStem, atPath: paths.sync.path)?.item,
                "the existing stem's item"
            )
            let keepEntry = try store.insert(CopyQSyncBridge.itemToEntry(keepItem, tabID: tab.id))

            var missingData = CopyQDataMap()
            missingData.set(CopyQFormat.text, Data("this file is gone".utf8))
            let missingEntry = try store.insert(CopyQSyncBridge.itemToEntry(
                CopyQSyncItem(baseName: missingStem, data: missingData),
                tabID: tab.id
            ))

            let localEntry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                note: "local note",
                flavours: [Fixtures.text("local capture waiting")]
            ))

            let before = try folderSnapshot(paths.sync)
            let entriesBefore = try store.recentEntries(limit: Int.max, tabID: tab.id)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 1, "only the stem with equal content matches")
            expectEqual(report.contentDifferenceCount, 0)
            expectEqual(report.entriesWithoutFilesCount, 1)
            expectEqual(report.entriesWithoutFiles.first?.entryID, missingEntry.id)
            expectEqual(report.entriesWithoutFiles.first?.stem, missingStem)
            expectEqual(report.stemsWithoutEntries, [addStem])
            expectEqual(report.unresolvedEntryCount, 1)
            expectEqual(report.unreadableEntryCount, 0)
            expectEqual(report.unreadableFileCount, 0)
            expectEqual(report.skippedInternalStems.sorted(), [emptyStem, internalStem].sorted())
            expect(report.mismatches)

            expectEqual(try store.count(tabID: tab.id), 3)
            expectEqual(try store.recentEntries(limit: Int.max, tabID: tab.id), entriesBefore)
            expectNotNil(try store.entry(id: keepEntry.id))
            expectNotNil(try store.entry(id: missingEntry.id))
            expectNotNil(try store.entry(id: localEntry.id))
            expectEqual(try folderSnapshot(paths.sync), before)
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)

            let second = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(second, report, "a second report is identical")
            expectEqual(try folderSnapshot(paths.sync), before)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("content differences are separate and never mutate the row") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000201"
            try writeGroup(stem: stem, text: "folder version", in: paths.sync)
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "ContentDiffTab",
                syncFolder: paths.sync.path
            ))
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                note: "keep this note",
                flavours: [
                    Fixtures.text("local version"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(stem.utf8)
                    ),
                ]
            ))
            try store.replaceFlavours(of: entry.id, with: entry.flavours, locallyEdited: true)
            let before = try folderSnapshot(paths.sync)
            let rowBefore = try unwrap(try store.entry(id: entry.id), "the row before reporting")

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 0, "different content is not a match")
            expectEqual(report.contentDifferenceCount, 1)
            expectEqual(report.entriesWithoutFilesCount, 0)
            expectEqual(report.stemsWithoutEntriesCount, 0)
            expect(report.mismatches, "content differences are a visible divergence")

            let rowAfter = try unwrap(try store.entry(id: entry.id), "the row after reporting")
            expectEqual(rowAfter, rowBefore, "reporting changes no content, note, pin, or date")
            expectEqual(try store.isEntryLocallyEdited(id: entry.id), true)
            expectEqual(try folderSnapshot(paths.sync), before)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("restored payload without recorded ownership is unresolved") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000301"
            try writeGroup(stem: stem, text: "restored payload", in: paths.sync)
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "RestoredReportTab",
                syncFolder: paths.sync.path
            ))
            let restored = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                tabID: tab.id,
                flavours: [Fixtures.text("restored payload")]
            ))
            let before = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 0, "payload alone is not shared ownership")
            expectEqual(report.contentDifferenceCount, 0)
            expectEqual(report.entriesWithoutFilesCount, 0)
            expectEqual(report.stemsWithoutEntriesCount, 1)
            expectEqual(report.unresolvedEntryCount, 1)
            expect(report.mismatches)

            let row = try unwrap(try store.entry(id: restored.id), "the restored row")
            expect(!row.hasSyncBaseName, "reporting does not adopt a stem identity")
            expectEqual(try folderSnapshot(paths.sync), before)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a payload match never claims a stem already owned by another restored row") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000351"
            try writeGroup(stem: stem, text: "shared report payload", in: paths.sync)
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "SharedRestoredTab",
                syncFolder: paths.sync.path
            ))
            try store.recordWrittenSyncStem(stem, folder: paths.sync.path)
            let owner = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("shared report payload"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(stem.utf8)
                    ),
                ]
            ))
            expectNotNil(try store.entry(id: owner.id))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_600_000_001),
                tabID: tab.id,
                flavours: [Fixtures.text("shared report payload")]
            ))
            let before = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 1, "only one row can own the stem")
            expectEqual(report.unresolvedEntryCount, 1, "the second row is unresolved, not matched")
            expectEqual(report.stemsWithoutEntriesCount, 0)
            expectEqual(try folderSnapshot(paths.sync), before)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a recorded owner keeps its stem when display order would prefer another row") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let ownerDate = Date(timeIntervalSince1970: 1_720_000_000)
            let stem = CopyQSyncBridge.formatTimestamp(ownerDate)
            try writeGroup(stem: stem, text: "owner content", in: paths.sync)
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "RecordedOwnerReportTab",
                syncFolder: paths.sync.path
            ))
            try store.recordWrittenSyncStem(stem, folder: paths.sync.path)

            let owner = try store.insert(ClipboardEntry(
                createdAt: ownerDate,
                tabID: tab.id,
                flavours: [Fixtures.text("owner content")]
            ))
            let nearby = try store.insert(ClipboardEntry(
                createdAt: ownerDate.addingTimeInterval(0.4),
                tabID: tab.id,
                flavours: [Fixtures.text("different content")]
            ))
            expectEqual(try store.recentEntries(limit: Int.max, tabID: tab.id).first?.id, nearby.id)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 1, "the recorded owner matches its own group")
            expectEqual(report.contentDifferenceCount, 0, "the nearby row does not steal the owner's group")
            expectEqual(report.unresolvedEntryCount, 1, "the nearby row stays unresolved")
            expectEqual(report.entriesWithoutFilesCount, 0)
            expectEqual(report.stemsWithoutEntriesCount, 0)
            expectNotNil(try store.entry(id: owner.id))
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("resync classifies every owned stem of an adopted duplicate") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "AdoptedReportTab",
                syncFolder: paths.sync.path
            ))
            let stemA = "copyq_20261025120000801"
            let stemB = "copyq_20261025120000802"
            try writeGroup(stem: stemA, text: "alpha", in: paths.sync)
            try writeGroup(stem: stemB, text: "alpha", in: paths.sync)
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [Fixtures.text("alpha")]
            ))
            try store.recordWrittenSyncStem(stemA, folder: paths.sync.path, entryID: entry.id)
            try store.recordWrittenSyncStem(stemB, folder: paths.sync.path, entryID: entry.id)
            let before = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 1, "the row's owned groups match")
            expectEqual(report.stemsWithoutEntriesCount, 0, "every owned stem is accounted for")
            expectEqual(report.entriesWithoutFilesCount, 0)
            expectEqual(report.contentDifferenceCount, 0)
            expectEqual(report.unresolvedEntryCount, 0)
            expectEqual(try folderSnapshot(paths.sync), before, "reporting stays read-only")
            expectEqual(
                try store.writtenSyncStems(forEntryID: entry.id, folder: paths.sync.path).count,
                2,
                "reporting does not change the owned set"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a partially unreadable group is counted as unreadable, not compared") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000471"
            try writeGroup(stem: stem, text: "readable text", in: paths.sync)
            var stream = QDataStreamWriter()
            stream.writeInt32(-2)
            stream.writeInt32(1)
            stream.writeQString("0text/corrupt")
            stream.writeBool(true)
            stream.writeQByteArray(Data([0x78, 0x9C, 0x00]))
            try stream.data.write(
                to: paths.sync.appendingPathComponent(stem + CopyQFormat.dataFileSuffix)
            )

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "PartialUnreadableReportTab",
                syncFolder: paths.sync.path
            ))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("readable text"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(stem.utf8)
                    ),
                ]
            ))

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.unreadableFileCount, 1)
            expectEqual(report.unreadableEntryCount, 1, "the owning entry is unreadable")
            expectEqual(report.matchedEntryCount, 0)
            expectEqual(report.contentDifferenceCount, 0, "no comparison is claimed for a partial group")
            expectEqual(report.skippedInternalStems, [])
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("internal-only or undecodable stems are counted, not matched") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000401"
            var data = CopyQDataMap()
            data.set(CopyQFormat.unknownFormats, Data())
            try writeItem(CopyQSyncItem(baseName: stem, data: data), in: paths.sync)
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "InternalReportTab",
                syncFolder: paths.sync.path
            ))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("visible local content"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(stem.utf8)
                    ),
                ]
            ))
            let before = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 0, "an internal-only stem is not a content match")
            expectEqual(report.unreadableEntryCount, 0, "the internal stem decoded without error")
            expectEqual(report.unresolvedEntryCount, 1, "an internal-only stem is not usable content")
            expectEqual(report.skippedInternalStems, [stem])
            expect(
                !report.summary.contains("could not be decoded"),
                "the summary does not call an internal stem undecodable"
            )
            expect(report.mismatches, "an incomplete folder read never claims consistency")
            expectEqual(try folderSnapshot(paths.sync), before)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("unreadable files are counted once per file, not once per failed flavour") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000451"
            var stream = QDataStreamWriter()
            stream.writeInt32(-2)
            stream.writeInt32(2)
            for format in ["0text/corrupt-one", "0text/corrupt-two"] {
                stream.writeQString(format)
                stream.writeBool(true)
                stream.writeQByteArray(Data([0x78, 0x9C, 0x00]))
            }
            try stream.data.write(
                to: paths.sync.appendingPathComponent(stem + CopyQFormat.dataFileSuffix)
            )

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "UnreadableReportTab",
                syncFolder: paths.sync.path
            ))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("unreadable local content"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(stem.utf8)
                    ),
                ]
            ))

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.failures.count, 2, "both flavour failures are recorded")
            expectEqual(report.unreadableFileCount, 1, "one file failed, not two")
            expectEqual(report.unreadableEntryCount, 1)
            expectEqual(report.skippedInternalStems, [], "a corrupt file is not internal")
            expect(
                report.summary.contains("1 file could not be read"),
                "the summary counts the file once"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a folder file read failure is composed in the selected language") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000461"
            var stream = QDataStreamWriter()
            stream.writeInt32(-2)
            stream.writeInt32(1)
            stream.writeQString("0text/corrupt")
            stream.writeBool(true)
            stream.writeQByteArray(Data([0x78, 0x9C, 0x00]))
            let fileName = stem + CopyQFormat.dataFileSuffix
            try stream.data.write(to: paths.sync.appendingPathComponent(fileName))

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "LocalizedReadFailureTab",
                syncFolder: paths.sync.path
            ))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("unreadable local content"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(stem.utf8)
                    ),
                ]
            ))

            let english = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(english.failures.count, 1, "one failed flavour is reported")
            expect(
                english.failures[0].hasPrefix("\(fileName): flavour text/corrupt: "),
                "the English clause keeps the file name and the reason: \(english.failures)"
            )

            let chinese = try CopyQSyncResync.report(
                tabID: tab.id,
                in: store,
                language: .simplifiedChinese
            )
            expectEqual(chinese.failures.count, 1, "one failed flavour is reported")
            expect(
                chinese.failures[0].hasPrefix("\(fileName)：格式 text/corrupt："),
                "the Chinese clause keeps the file name and translates the framing: \(chinese.failures)"
            )
            expect(
                !chinese.failures[0].contains("flavour"),
                "no English framing is left: \(chinese.failures)"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("the tab comparison action opens a read-only report") {
        MainActor.assumeIsolated {
            do {
                let paths = try scratch()
                defer { try? FileManager.default.removeItem(at: paths.root) }

                let store = try ClipboardStore(inMemory: true)
                let tab = try store.insertTab(ClipboardTab(
                    name: "DialogReportTab",
                    syncFolder: paths.sync.path
                ))
                try writeGroup(stem: "copyq_20261025120000501", text: "orphan", in: paths.sync)
                let before = try folderSnapshot(paths.sync)

                let history = ClipboardHistory(store: store)
                history.syncTrashRoot = paths.trash
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.reload()
                model.selectedTabID = tab.id
                model.reload()

                let actions = AppActions(
                    model: model,
                    windowController: ResyncWindowControllerStub(),
                    presentPreferences: {}
                )
                var alerts: [[String]] = []
                actions.alertPresenter = { alert in
                    alerts.append(alert.buttons.map(\.title))
                    return .alertFirstButtonReturn
                }

                model.onResyncTabRequest = { tabID in
                    actions.resyncTab(id: tabID)
                }
                model.requestResyncTab(tab.id)
                let deadline = Date().addingTimeInterval(5)
                while alerts.isEmpty, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                expectEqual(
                    alerts,
                    [["OK", "Apply Changes…"]],
                    "the report defaults to the read-only button and offers the explicit write path"
                )
                expectEqual(try store.count(tabID: tab.id), 0)
                expectEqual(try folderSnapshot(paths.sync), before)
                expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("restored 294-row history against 109 folder stems reports exact read-only counts") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let folderStems = (0..<109).map { index in
                CopyQSyncBridge.formatTimestamp(
                    Date(timeIntervalSince1970: 1_790_000_000 + Double(index))
                )
            }
            for (index, stem) in folderStems.enumerated() {
                let text = index == 0 ? "folder divergent content 0" : "folder content \(index)"
                try writeGroup(stem: stem, text: text, in: paths.sync)
            }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "RestoredHistoryTab",
                syncFolder: paths.sync.path
            ))

            for index in 0..<109 {
                _ = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                    tabID: tab.id,
                    flavours: [Fixtures.text("folder content \(index)")]
                ))
            }

            let missingStems = (0..<10).map { index in
                CopyQSyncBridge.formatTimestamp(
                    Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                )
            }
            for (index, stem) in missingStems.enumerated() {
                let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                try store.recordWrittenSyncStem(stem, folder: paths.sync.path)
                _ = try store.insert(ClipboardEntry(
                    createdAt: date,
                    tabID: tab.id,
                    flavours: [Fixtures.text("missing content \(index)")]
                ))
            }

            for index in 0..<175 {
                _ = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_650_000_000 + Double(index)),
                    tabID: tab.id,
                    flavours: [Fixtures.text("unresolved restored content \(index)")]
                ))
            }

            expectEqual(try store.count(tabID: tab.id), 294)
            let before = try folderSnapshot(paths.sync)
            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 108)
            expectEqual(report.entriesWithoutFilesCount, 10)
            expectEqual(report.stemsWithoutEntriesCount, 0)
            expectEqual(report.contentDifferenceCount, 1)
            expectEqual(report.unreadableEntryCount, 0)
            expectEqual(report.unreadableFileCount, 0)
            expectEqual(report.unresolvedEntryCount, 175)
            expect(report.mismatches)

            expectEqual(try store.count(tabID: tab.id), 294)
            expectEqual(try folderSnapshot(paths.sync), before)

            let second = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(second, report)
            expectEqual(try store.count(tabID: tab.id), 294)
            expectEqual(try folderSnapshot(paths.sync), before)

            print(
                "  restored history: matched=\(report.matchedEntryCount) "
                    + "missing=\(report.entriesWithoutFilesCount) "
                    + "folderExtra=\(report.stemsWithoutEntriesCount) "
                    + "contentDiff=\(report.contentDifferenceCount) "
                    + "unresolved=\(report.unresolvedEntryCount) "
                    + "unreadable=\(report.unreadableEntryCount + report.unreadableFileCount); "
                    + "secondRunIdentical=\(second == report)"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    // Run only when a scratch copy of a real sync folder is named in the
    // environment.  The repository never contains a real sync folder, and
    // CI therefore skips this proof; the committed synthetic tests above cover
    // the same code path on every run.
    TestRunner.add("resync reports a real CopyQ sync folder copy without changing it") {
        guard let fixturePath = ProcessInfo.processInfo.environment["COPYQMAC_RESYNC_FIXTURE"],
              !fixturePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }
            let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
            let copiedFolder = paths.root.appendingPathComponent("fixture", isDirectory: true)
            try FileManager.default.copyItem(at: fixture, to: copiedFolder)
            let before = try folderSnapshot(copiedFolder)

            let contents = try CopyQSyncFolder.read(atPath: copiedFolder.path)
            let expectedStems = Set(
                contents.items
                    .filter { !CopyQSyncBridge.isInternalOnly($0) }
                    .compactMap(\.baseName)
            )
            expect(!expectedStems.isEmpty, "the fixture contains copyable stems")

            let store = try ClipboardStore(path: paths.database.path)
            let tab = try store.insertTab(ClipboardTab(
                name: "FixtureTab",
                syncFolder: copiedFolder.path
            ))

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 0)
            expectEqual(report.contentDifferenceCount, 0)
            expectEqual(report.entriesWithoutFilesCount, 0)
            expectEqual(
                report.stemsWithoutEntriesCount,
                expectedStems.count,
                "every importable fixture stem is reported without an entry"
            )
            expectEqual(report.unreadableFileCount, 0, "the fixture files are readable")
            expectEqual(report.skippedInternalStems, [])
            expectEqual(try store.count(tabID: tab.id), 0)
            expectEqual(try folderSnapshot(copiedFolder), before, "the fixture copy is read only")

            let second = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(second, report, "a second report is identical")
            expectEqual(try folderSnapshot(copiedFolder), before)

            print(
                "  resync fixture: \(contents.fileCount) files, "
                    + "\(expectedStems.count) distinct importable stems, "
                    + "\(report.stemsWithoutEntriesCount) folder-only stems"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("recreated tab on same sync folder imports all files and other live tab suppresses echoes") {
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-recreate-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let folderA = root.appendingPathComponent("syncA", isDirectory: true)
            let folderB = root.appendingPathComponent("syncB", isDirectory: true)
            try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)

            let dbPath = root.appendingPathComponent("history.sqlite").path
            let store = try ClipboardStore(path: dbPath)
            let history = ClipboardHistory(store: store)

            let defaultTab = try history.defaultTab()
            var tabA = defaultTab
            tabA.name = "Mac mini"
            tabA.syncFolder = folderA.path
            try history.updateTab(tabA)

            let tabB = try history.addTab(name: "OtherTab")
            var updatedTabB = tabB
            updatedTabB.syncFolder = folderB.path
            try history.updateTab(updatedTabB)

            let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
            let plainEntry = try store.insert(ClipboardEntry(
                createdAt: baseDate,
                tabID: tabA.id,
                flavours: [Fixtures.text("plain text capture")]
            ))
            let log1 = try CopyQSyncWriter.shared.writeEntry(plainEntry, in: store, reason: "capture")
            expectNotNil(log1, "plain text written")

            let htmlEntry = try store.insert(ClipboardEntry(
                createdAt: baseDate.addingTimeInterval(1),
                tabID: tabA.id,
                flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>html capture</b>".utf8))]
            ))
            let log2 = try CopyQSyncWriter.shared.writeEntry(htmlEntry, in: store, reason: "capture")
            expectNotNil(log2, "html written")

            let pngEntry = try store.insert(ClipboardEntry(
                createdAt: baseDate.addingTimeInterval(2),
                tabID: tabA.id,
                flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)]
            ))
            let log3 = try CopyQSyncWriter.shared.writeEntry(pngEntry, in: store, reason: "capture")
            expectNotNil(log3, "png written")

            let multiEntry = try store.insert(ClipboardEntry(
                createdAt: baseDate.addingTimeInterval(3),
                tabID: tabA.id,
                flavours: [
                    Fixtures.text("multi flavour text"),
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<i>multi html</i>".utf8)),
                    Flavour(itemIndex: 0, type: "application/json", data: Data("{\"key\":\"value\"}".utf8)),
                ]
            ))
            let log4 = try CopyQSyncWriter.shared.writeEntry(multiEntry, in: store, reason: "capture")
            expectNotNil(log4, "multi written")

            let tabBEntry = try store.insert(ClipboardEntry(
                createdAt: baseDate.addingTimeInterval(4),
                tabID: updatedTabB.id,
                flavours: [Fixtures.text("tab B live item")]
            ))
            let logB = try CopyQSyncWriter.shared.writeEntry(tabBEntry, in: store, reason: "capture")
            expectNotNil(logB, "tab B written")
            let stemB = try unwrap(logB?.stem, "stem B")

            // Delete tab A through history.deleteTab(id:)
            try history.deleteTab(id: tabA.id)

            // Recreate tab on same folderA
            let recreated = try history.addTab(name: "Mac mini")
            var updatedRecreated = recreated
            updatedRecreated.syncFolder = folderA.path
            try history.updateTab(updatedRecreated)

            // Assert (b) before import: resync counts every folder stem in stemsWithoutEntriesCount
            let resyncReport = try CopyQSyncResync.report(tabID: updatedRecreated.id, in: store)
            expectEqual(resyncReport.stemsWithoutEntriesCount, 4, "recreated tab resync sees all 4 folder stems")

            // Assert (a): importConfiguredSyncFolders imports every file in folderA and reports zero duplicates for folder A
            let importFolderA = try CopyQSyncBridge.importSyncFolder(atPath: folderA.path, intoTabID: updatedRecreated.id, in: store)
            expectEqual(importFolderA.importedCount, 4, "all 4 items imported from folder A")
            expectEqual(importFolderA.duplicateCount, 0, "zero duplicates reported for folder A")

            // Assert (c): second sync folder owned by another live tab keeps its own rows and still suppresses its own echoes
            expect(try store.isWrittenSyncStem(stemB, folder: folderB.path), "folder B written stem preserved")
            let resyncB = try CopyQSyncResync.report(tabID: updatedTabB.id, in: store)
            expectEqual(resyncB.matchedEntryCount, 1, "tab B entry matches")
            expectEqual(resyncB.stemsWithoutEntriesCount, 0, "tab B has no orphan stems")
            let importFolderB = try CopyQSyncBridge.importSyncFolder(atPath: folderB.path, intoTabID: updatedTabB.id, in: store)
            expectEqual(importFolderB.importedCount, 0, "tab B imports nothing new")
            expectEqual(importFolderB.duplicateCount, 1, "tab B echoes suppressed")

            // Across all configured folders, folder A now already imported, tab B still suppressed
            let importAll = try CopyQSyncBridge.importConfiguredSyncFolders(in: store)
            expectEqual(importAll.importedCount, 0, "all files already imported")
            expectEqual(importAll.duplicateCount, 5, "4 from folder A + 1 from folder B")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("seeds pre-broken state with dead and null entry_id rows and recovers items") {
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-prebroken-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

            let liveStem = "copyq_20261114000000001"
            let deadStem1 = "copyq_20261114000000002"
            let deadStem2 = "copyq_20261114000000003"
            let nullStem = "copyq_20261114000000004"

            try writeGroup(stem: liveStem, text: "live content", in: syncFolder)
            try writeGroup(stem: deadStem1, text: "dead content 1", in: syncFolder)
            try writeGroup(stem: deadStem2, text: "dead content 2", in: syncFolder)
            try writeGroup(stem: nullStem, text: "null content", in: syncFolder)

            let dbPath = root.appendingPathComponent("history.sqlite").path
            let store = try ClipboardStore(path: dbPath)
            let tab = try store.defaultTab()
            var mappedTab = try unwrap(tab, "default tab")
            mappedTab.syncFolder = syncFolder.path
            try store.updateTab(mappedTab)

            let liveDate = CopyQSyncItem.parseTimestamp(baseName: liveStem) ?? Date(timeIntervalSince1970: 1_700_000_100)
            let liveEntry = try store.insert(ClipboardEntry(
                createdAt: liveDate,
                tabID: mappedTab.id,
                flavours: [
                    Fixtures.text("live content"),
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(liveStem.utf8)),
                ]
            ))

            try store.recordWrittenSyncStem(liveStem, folder: syncFolder.path, entryID: liveEntry.id)
            try store.recordWrittenSyncStem(deadStem1, folder: syncFolder.path, entryID: 999_991)
            try store.recordWrittenSyncStem(deadStem2, folder: syncFolder.path, entryID: 999_992)
            try store.recordWrittenSyncStem(nullStem, folder: syncFolder.path, entryID: nil)

            // Reopening the store runs reclamation on open
            let reopened = try ClipboardStore(path: dbPath)

            let report = try CopyQSyncResync.report(tabID: mappedTab.id, in: reopened)
            expectEqual(report.stemsWithoutEntriesCount, 3, "3 unowned stems recovered")
            expectEqual(report.matchedEntryCount, 1, "1 live stem matched")

            let importReport = try CopyQSyncBridge.importConfiguredSyncFolders(in: reopened)
            expectEqual(importReport.importedCount, 3, "imported all 3 unowned items")
            expectEqual(importReport.duplicateCount, 1, "1 duplicate for existing live entry")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a null written stem is not linked to a nearby entry that already owns a named group") {
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-basename-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

            let namedStem = "copyq_20261117000000001"
            let legacyStem = "copyq_20261117000000002"
            try writeGroup(stem: namedStem, text: "named content", in: syncFolder)
            try writeGroup(stem: legacyStem, text: "legacy content", in: syncFolder)

            let dbPath = root.appendingPathComponent("history.sqlite").path
            let store = try ClipboardStore(path: dbPath)
            var tab = try unwrap(try store.defaultTab(), "default tab")
            tab.syncFolder = syncFolder.path
            try store.updateTab(tab)

            let legacyDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: legacyStem), "legacy stem date")
            let entry = try store.insert(ClipboardEntry(
                createdAt: legacyDate.addingTimeInterval(-0.3),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("named content"),
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(namedStem.utf8)),
                ]
            ))
            try store.recordWrittenSyncStem(legacyStem, folder: syncFolder.path, entryID: nil)

            let reopened = try ClipboardStore(path: dbPath)

            expect(!(try reopened.isWrittenSyncStem(legacyStem, folder: syncFolder.path)), "legacy stem not claimed by the neighbouring entry")
            let report = try CopyQSyncResync.report(tabID: tab.id, in: reopened)
            expectEqual(report.matchedEntryCount, 1, "the named group still matches its own entry")
            expectEqual(report.contentDifferences.count, 0, "no spurious content difference")
            expectEqual(report.stemsWithoutEntriesCount, 1, "the legacy group stays an unowned folder group")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("remapping a folder keeps a live row's stem suppressed for the new tab") {
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-remap-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let sharedFolder = root.appendingPathComponent("shared", isDirectory: true)
            let otherFolder = root.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)

            let stem = "copyq_20261116000000001"
            try writeGroup(stem: stem, text: "shared content", in: sharedFolder)

            let dbPath = root.appendingPathComponent("history.sqlite").path
            let store = try ClipboardStore(path: dbPath)
            let originalTab = try store.insertTab(ClipboardTab(name: "Original", syncFolder: sharedFolder.path))
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: originalTab.id,
                flavours: [Fixtures.text("shared content")]
            ))
            try store.recordWrittenSyncStem(stem, folder: sharedFolder.path, entryID: entry.id)

            let nextTab = try store.insertTab(ClipboardTab(name: "Next"))
            var mappedTab = nextTab
            mappedTab.syncFolder = sharedFolder.path
            try store.updateTab(mappedTab)

            var movedTab = originalTab
            movedTab.syncFolder = otherFolder.path
            try store.updateTab(movedTab)

            let reopened = try ClipboardStore(path: dbPath)
            expect(try reopened.isWrittenSyncStem(stem, folder: sharedFolder.path), "the owned stem stays recorded")
            let report = try CopyQSyncResync.report(tabID: mappedTab.id, in: reopened)
            expectEqual(report.stemsWithoutEntriesCount, 0, "the owned group stays suppressed")
            let importReport = try CopyQSyncBridge.importSyncFolder(atPath: sharedFolder.path, intoTabID: mappedTab.id, in: reopened)
            expectEqual(importReport.importedCount, 0, "the owned group does not import into the new tab")
            expectEqual(try reopened.count(tabID: mappedTab.id), 0, "the new tab stays empty")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("clearing a tab's folder releases its stems for a later mapping") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261116000000021"
            try writeGroup(stem: stem, text: "restorable content", in: paths.sync)
            let before = try folderSnapshot(paths.sync)

            let dbPath = paths.database.path
            let store = try ClipboardStore(path: dbPath)
            let originalTab = try store.insertTab(ClipboardTab(name: "Original", syncFolder: paths.sync.path))
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: originalTab.id,
                flavours: [
                    Fixtures.text("restorable content"),
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(stem.utf8)),
                ]
            ))
            try store.recordWrittenSyncStem(stem, folder: paths.sync.path, entryID: entry.id)

            var cleared = originalTab
            cleared.syncFolder = nil
            try store.updateTab(cleared)

            let reopened = try ClipboardStore(path: dbPath)
            expect(
                !(try reopened.isWrittenSyncStem(stem, folder: paths.sync.path)),
                "clearing the last mapping releases the stem"
            )

            let restored = try reopened.insertTab(ClipboardTab(name: "Restored", syncFolder: paths.sync.path))
            let report = try CopyQSyncResync.report(tabID: restored.id, in: reopened)
            expectEqual(report.stemsWithoutEntriesCount, 1, "reconcile reports the released stem")
            expectEqual(report.matchedEntryCount, 0, "the restored tab has no match yet")
            let importReport = try CopyQSyncBridge.importSyncFolder(
                atPath: paths.sync.path,
                intoTabID: restored.id,
                in: reopened
            )
            expectEqual(importReport.importedCount, 1, "the released group imports into the restored tab")
            expectEqual(try reopened.count(tabID: restored.id), 1, "the restored tab shows the item")
            expectEqual(try folderSnapshot(paths.sync), before, "the folder is untouched")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("mapping a tab to a folder releases legacy orphan stems without reopening") {
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-late-mapping-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

            let deadStem = "copyq_20261116000000011"
            let nullStem = "copyq_20261116000000012"
            try writeGroup(stem: deadStem, text: "dead", in: syncFolder)
            try writeGroup(stem: nullStem, text: "null", in: syncFolder)
            let before = try folderSnapshot(syncFolder)

            let dbPath = root.appendingPathComponent("history.sqlite").path
            let store = try ClipboardStore(path: dbPath)
            try store.recordWrittenSyncStem(deadStem, folder: syncFolder.path, entryID: 999_999)
            try store.recordWrittenSyncStem(nullStem, folder: syncFolder.path)
            let tab = try store.insertTab(ClipboardTab(name: "LateMapping"))
            expect(try store.isWrittenSyncStem(deadStem, folder: syncFolder.path), "the dead legacy row starts suppressed")
            expect(try store.isWrittenSyncStem(nullStem, folder: syncFolder.path), "the null legacy row starts suppressed")

            var mapped = tab
            mapped.syncFolder = syncFolder.path
            try store.updateTab(mapped)

            expect(!(try store.isWrittenSyncStem(deadStem, folder: syncFolder.path)), "mapping releases the dead legacy row")
            expect(!(try store.isWrittenSyncStem(nullStem, folder: syncFolder.path)), "mapping releases the null legacy row")
            let report = try CopyQSyncBridge.importSyncFolder(atPath: syncFolder.path, intoTabID: tab.id, in: store)
            expectEqual(report.importedCount, 2, "both released groups import")
            expectEqual(try folderSnapshot(syncFolder), before, "the folder is untouched")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("opening the store keeps a null written stem whose group payload matches a live row") {
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-recover-content-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

            let stem = "copyq_20261119000000001"
            try writeGroup(stem: stem, text: "recoverable content", in: syncFolder)

            let dbPath = root.appendingPathComponent("history.sqlite").path
            let store = try ClipboardStore(path: dbPath)
            var tab = try unwrap(try store.defaultTab(), "default tab")
            tab.syncFolder = syncFolder.path
            try store.updateTab(tab)

            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [Fixtures.text("recoverable content")]
            ))
            try store.recordWrittenSyncStem(stem, folder: syncFolder.path, entryID: nil)

            let reopened = try ClipboardStore(path: dbPath)

            expect(try reopened.isWrittenSyncStem(stem, folder: syncFolder.path), "the content-verified stem stays recorded")
            expectEqual(
                try reopened.entryID(forWrittenSyncStem: stem, folder: syncFolder.path),
                entry.id,
                "the stem is linked to the row whose payload matches"
            )
            let stored = try unwrap(try reopened.entry(id: entry.id), "the original row")
            expectEqual(FlavourDecoder.storedPlainText(from: stored.flavours), "recoverable content", "the original row keeps its payload")
            expectEqual(try reopened.count(tabID: tab.id), 1, "no duplicate row is imported")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("deleted and trimmed entries stay deleted after paused sync resumes") {
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-paused-delete-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let syncFolder = root.appendingPathComponent("sync", isDirectory: true)
            try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

            let dbPath = root.appendingPathComponent("history.sqlite").path
            let store = try ClipboardStore(path: dbPath)
            var tab = try unwrap(try store.defaultTab(), "default tab")
            tab.syncFolder = syncFolder.path
            try store.updateTab(tab)

            let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
            var stems: [String] = []
            var entries: [ClipboardEntry] = []
            for index in 0..<3 {
                let entry = try store.insert(ClipboardEntry(
                    createdAt: baseDate.addingTimeInterval(Double(index)),
                    tabID: tab.id,
                    flavours: [Fixtures.text("paused item \(index)")]
                ))
                entries.append(entry)
                let log = try CopyQSyncWriter.shared.writeEntry(entry, in: store, reason: "capture")
                stems.append(try unwrap(log?.stem, "written stem \(index)"))
            }

            var paused = try store.preferences()
            paused.syncPaused = true
            try store.setPreferences(paused)

            try store.delete(id: entries[0].id)
            try store.trim(tabID: tab.id, to: 1)

            for index in 0..<2 {
                expect(try store.isWrittenSyncStem(stems[index], folder: syncFolder.path), "paused deletion keeps suppression \(index)")
                expectEqual(
                    try store.entryID(forWrittenSyncStem: stems[index], folder: syncFolder.path),
                    nil,
                    "paused deletion drops the owner \(index)"
                )
            }
            expectEqual(try store.count(tabID: tab.id), 1, "one survivor stays in the tab")

            paused.syncPaused = false
            try store.setPreferences(paused)

            let reopened = try ClipboardStore(path: dbPath)
            let importReport = try CopyQSyncBridge.importConfiguredSyncFolders(in: reopened)
            expectEqual(importReport.importedCount, 0, "deleted and trimmed groups are not imported back")
            expectEqual(try reopened.count(tabID: tab.id), 1, "only the survivor remains after resume")
            expectEqual(
                FlavourDecoder.storedPlainText(from: try reopened.entry(id: entries[2].id)?.flavours ?? []),
                "paused item 2",
                "the surviving item is the one that was never deleted"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }
}
