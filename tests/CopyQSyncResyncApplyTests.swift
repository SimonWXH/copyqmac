// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncResyncApplyTests.swift
//
// The write half of the per-tab resync comparison: imports of folder-only
// stems, removal of rows whose files are gone (through the app trash), and
// content updates that keep notes, pins, and durable identity.  Every known
// identity problem has its own test here:
//
//   * rows without a stem flavour
//   * one row owning several groups from legacy data
//   * queued writes recreating groups for removed rows
//   * content updates overwriting local edits, notes, or pins
//   * stale in-memory stem caches
//
// Everything runs headlessly in temporary directories; no real sync folder,
// no GUI automation, no synthetic input.

import AppKit
import Foundation

@MainActor
private final class ResyncApplyWindowControllerStub: NSObject, WindowControllerProtocol {
    var isVisible = false
    func show() {}
    func hide() {}
}

func registerCopyQSyncResyncApplyTests() {
    TestRunner.currentSuite = "CopyQSyncResyncApply"

    func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func waitForSettle() {
        Thread.sleep(forTimeInterval: CopyQSyncWatcher.shared.settleDelay + 0.1)
    }

    struct Paths {
        let root: URL
        let sync: URL
        let trash: URL
        let database: URL
    }

    func scratch() throws -> Paths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-resync-apply-\(UUID().uuidString)", isDirectory: true)
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        return Paths(
            root: root,
            sync: sync,
            trash: trash,
            database: root.appendingPathComponent("history.sqlite")
        )
    }

    func item(
        stem: String,
        text: String,
        note: String? = nil,
        pinned: Bool = false
    ) -> CopyQSyncItem {
        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data(text.utf8))
        if let note {
            data.set(CopyQFormat.itemNotes, Data(note.utf8))
        }
        if pinned {
            data.set(CopyQFormat.itemPinned, nil)
        }
        return CopyQSyncItem(baseName: stem, data: data)
    }

    func writeGroup(
        stem: String,
        text: String,
        note: String? = nil,
        pinned: Bool = false,
        in folder: URL
    ) throws {
        try CopyQSyncFolder.write(
            item(stem: stem, text: text, note: note, pinned: pinned),
            into: folder.path
        )
    }

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

    /// Every regular file under `root` and its bytes, keyed by relative path.
    /// A before/after comparison proves an operation wrote nothing.
    func treeSnapshot(_ root: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return snapshot }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = url.path.hasPrefix(prefix)
                ? String(url.path.dropFirst(prefix.count))
                : url.lastPathComponent
            snapshot[relative] = try Data(contentsOf: url)
        }
        return snapshot
    }

    func stemFlavour(_ stem: String) -> Flavour {
        Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data(stem.utf8))
    }

    func ownedRow(
        _ stem: String,
        text: String,
        tabID: Int64,
        note: String = "",
        pinned: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ClipboardEntry {
        ClipboardEntry(
            createdAt: createdAt,
            pinned: pinned,
            tabID: tabID,
            note: note,
            flavours: [Fixtures.text(text), stemFlavour(stem)]
        )
    }

    func rowText(_ entry: ClipboardEntry) -> String? {
        for flavour in entry.flavours where flavour.type == PasteboardTypes.utf8Text {
            return String(data: flavour.data, encoding: .utf8)
        }
        return nil
    }

    TestRunner.add("resync apply imports, removes, and updates exactly the planned categories") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let keepStem = "copyq_20261025120000101"
            let importStem = "copyq_20261025120000102"
            let updateStem = "copyq_20261025120000103"
            let goneStem = "copyq_20261025120000104"

            try writeGroup(stem: keepStem, text: "keep", in: paths.sync)
            try writeGroup(stem: importStem, text: "import me", in: paths.sync)
            try writeGroup(stem: updateStem, text: "folder version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "ApplyTab", syncFolder: paths.sync.path))

            _ = try store.insert(ownedRow(keepStem, text: "keep", tabID: tab.id))
            let updated = try store.insert(ownedRow(updateStem, text: "local version", tabID: tab.id))
            let gone = try store.insert(ownedRow(goneStem, text: "this file is gone", tabID: tab.id))

            let folderBefore = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.matchedEntryCount, 1)
            expectEqual(report.contentDifferenceCount, 1)
            expectEqual(report.contentDifferences.first?.entryID, updated.id)
            expectEqual(report.contentDifferences.first?.differingStems, [updateStem])
            expectEqual(report.entriesWithoutFiles.first?.entryID, gone.id)
            expectEqual(report.stemsWithoutEntries, [importStem])

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.imports, [importStem])
            expectEqual(plan.removals.map(\.entryID), [gone.id])
            expectEqual(plan.updates.map(\.entryID), [updated.id])
            expectEqual(plan.conflicts, [])
            expect(plan.confirmation(language: .english).contains("Import 1 entry"), plan.confirmation(language: .english))
            expect(plan.confirmation(language: .english).contains("Remove 1 entry"), plan.confirmation(language: .english))
            expect(plan.confirmation(language: .english).contains("Update 1 entry"), plan.confirmation(language: .english))

            // The dialog reads one comparison and gets both surfaces from it.
            let assessment = try CopyQSyncResync.reportAndPlan(tabID: tab.id, in: store)
            expectEqual(assessment.report, report)
            expectEqual(assessment.plan, plan)

            // Planning writes nothing.
            expectEqual(try store.count(tabID: tab.id), 3)
            expectEqual(try folderSnapshot(paths.sync), folderBefore)
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)

            waitForSettle()
            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesImported, 1, "the folder-only stem becomes an entry")
            expectEqual(result.entriesRemoved, 1, "the entry whose file is gone is removed")
            expectEqual(result.entriesUpdated, 1, "the content difference is applied")
            expectEqual(result.conflictsLeft, 0)
            expectEqual(result.failures, [])

            expectNil(try store.entry(id: gone.id), "the removed row is gone from the store")
            let keptUpdated = try unwrap(try store.entry(id: updated.id), "the updated row keeps its id")
            expectEqual(rowText(keptUpdated), "folder version")
            expectEqual(keptUpdated.note, "", "the update does not invent a note")
            expectEqual(try store.count(tabID: tab.id), 3)

            // Removal and the replaced payload are both recoverable.
            let trash = try CopyQSyncTrash.summary(trashRoot: paths.trash)
            expectEqual(trash.batchCount, 2, "one removal archive and one pre-update archive")
            expectEqual(try folderSnapshot(paths.sync), folderBefore, "apply never rewrites folder bytes")

            let after = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(after.matchedEntryCount, 3)
            expectEqual(after.contentDifferenceCount, 0)
            expectEqual(after.entriesWithoutFilesCount, 0)
            expectEqual(after.stemsWithoutEntriesCount, 0)
            expectEqual(after.unresolvedEntryCount, 0)
            expect(!after.mismatches)

            let second = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expect(second.isEmpty, "a second plan has nothing left to do")
            let again = try CopyQSyncResync.apply(second, in: store, trashRoot: paths.trash)
            expectEqual(again, CopyQSyncResyncResult())
            expectEqual(try store.count(tabID: tab.id), 3)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("an update keeps the entry's note and pin and archives the replaced payload") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000201"
            try writeGroup(stem: stem, text: "folder version", note: "my note", pinned: true, in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "NoteTab", syncFolder: paths.sync.path))
            let row = try store.insert(ownedRow(
                stem,
                text: "local version",
                tabID: tab.id,
                note: "my note",
                pinned: true
            ))
            let folderBefore = try folderSnapshot(paths.sync)

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates.map(\.entryID), [row.id])
            expectEqual(plan.conflicts, [])

            waitForSettle()
            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 1)

            let updated = try unwrap(try store.entry(id: row.id), "the updated row")
            expectEqual(rowText(updated), "folder version")
            expectEqual(updated.note, "my note", "the local note is never overwritten")
            expectEqual(updated.pinned, true, "the local pin is never overwritten")
            expectEqual(updated.createdAt, row.createdAt, "the row keeps its date and identity")
            expectEqual(try folderSnapshot(paths.sync), folderBefore)
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 1)
            expectEqual(try CopyQSyncResync.report(tabID: tab.id, in: store).matchedEntryCount, 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a local edit or a note/pin difference is a reported conflict, never an update") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let editedStem = "copyq_20261025120000301"
            let notedStem = "copyq_20261025120000302"
            try writeGroup(stem: editedStem, text: "folder edited version", in: paths.sync)
            try writeGroup(stem: notedStem, text: "folder noted version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "ConflictTab", syncFolder: paths.sync.path))
            let edited = try store.insert(ownedRow(editedStem, text: "pending local edit", tabID: tab.id))
            try store.markLocalEdit(id: edited.id)
            let noted = try store.insert(ownedRow(
                notedStem,
                text: "local noted version",
                tabID: tab.id,
                note: "local note"
            ))
            let folderBefore = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.contentDifferenceCount, 2)

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates, [])
            expectEqual(Set(plan.conflicts.map(\.reason)), [.locallyEdited, .noteOrPin])
            expectEqual(plan.conflicts.count, 2)
            expect(plan.isEmpty, "conflicts alone leave nothing to apply")
            expect(plan.confirmation(language: .english).contains("Leave 2 conflicts untouched"), plan.confirmation(language: .english))

            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 0)
            expectEqual(result.conflictsLeft, 2)

            let editedAfter = try unwrap(try store.entry(id: edited.id), "the locally edited row")
            expectEqual(rowText(editedAfter), "pending local edit", "a pending local edit is never overwritten")
            expectEqual(try store.isEntryLocallyEdited(id: edited.id), true)
            let notedAfter = try unwrap(try store.entry(id: noted.id), "the noted row")
            expectEqual(rowText(notedAfter), "local noted version")
            expectEqual(notedAfter.note, "local note")
            expectEqual(try folderSnapshot(paths.sync), folderBefore)
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a flavourless row is linked durably by an update instead of being guessed at") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000401"
            try writeGroup(stem: stem, text: "folder version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "FlavourlessTab", syncFolder: paths.sync.path))
            let row = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [Fixtures.text("local version")]
            ))
            try store.recordWrittenSyncStem(stem, folder: paths.sync.path, entryID: row.id)
            expect(!row.hasSyncBaseName, "the row starts without a stem flavour")

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates.map(\.entryID), [row.id])
            expectEqual(plan.conflicts, [])

            waitForSettle()
            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 1)

            let updated = try unwrap(try store.entry(id: row.id), "the updated row")
            expect(updated.hasSyncBaseName, "the update persists the stem flavour")
            expectEqual(
                try store.writtenSyncStem(forEntryID: row.id, folder: paths.sync.path),
                stem,
                "the durable link names the row"
            )
            expectEqual(try CopyQSyncResync.report(tabID: tab.id, in: store).matchedEntryCount, 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a same-stem difference resolved only by creation time is a conflict") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000501"
            try writeGroup(stem: stem, text: "unrelated history", in: paths.sync)
            let stampDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the stem stamp")

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "LegacyTab", syncFolder: paths.sync.path))
            let row = try store.insert(ClipboardEntry(
                createdAt: stampDate,
                tabID: tab.id,
                flavours: [Fixtures.text("my own content")]
            ))
            let folderBefore = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.contentDifferenceCount, 1)
            expectEqual(report.contentDifferences.first?.isLegacyIdentity, true)

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates, [])
            expectEqual(plan.conflicts.map(\.reason), [.unrelatedHistory])

            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 0)
            let after = try unwrap(try store.entry(id: row.id), "the row is untouched")
            expectEqual(rowText(after), "my own content")
            expect(!after.hasSyncBaseName, "resync never adopts a legacy-only identity")
            expectEqual(try folderSnapshot(paths.sync), folderBefore)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a written stem recorded for no owner never makes a legacy row durable") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000511"
            try writeGroup(stem: stem, text: "another owner's content", in: paths.sync)
            let stampDate = try unwrap(CopyQSyncItem.parseTimestamp(baseName: stem), "the stem stamp")

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "UnownedLegacyTab",
                syncFolder: paths.sync.path
            ))
            try store.recordWrittenSyncStem(stem, folder: paths.sync.path)
            let row = try store.insert(ClipboardEntry(
                createdAt: stampDate,
                tabID: tab.id,
                flavours: [Fixtures.text("my own content")]
            ))
            let folderBefore = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.contentDifferenceCount, 1)
            expectEqual(
                report.contentDifferences.first?.isLegacyIdentity,
                true,
                "a written stem the row does not own is only a creation-time guess"
            )

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates, [])
            expectEqual(plan.conflicts.map(\.reason), [.unrelatedHistory])

            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 0)
            let after = try unwrap(try store.entry(id: row.id), "the row is untouched")
            expectEqual(rowText(after), "my own content")
            expectNil(
                try store.writtenSyncStem(forEntryID: row.id, folder: paths.sync.path),
                "the guess is never recorded as the row's durable stem"
            )
            expectEqual(try folderSnapshot(paths.sync), folderBefore)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a stale plan cannot update or remove a row whose ownership is only a legacy guess") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let presentStem = "copyq_20261025120000521"
            let goneStem = "copyq_20261025120000522"
            try writeGroup(stem: presentStem, text: "folder version", in: paths.sync)
            let presentDate = try unwrap(
                CopyQSyncItem.parseTimestamp(baseName: presentStem),
                "the present stem stamp"
            )
            let goneDate = try unwrap(
                CopyQSyncItem.parseTimestamp(baseName: goneStem),
                "the gone stem stamp"
            )

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "StaleLegacyTab",
                syncFolder: paths.sync.path
            ))
            try store.recordWrittenSyncStem(presentStem, folder: paths.sync.path)
            try store.recordWrittenSyncStem(goneStem, folder: paths.sync.path)
            let updated = try store.insert(ClipboardEntry(
                createdAt: presentDate,
                tabID: tab.id,
                flavours: [Fixtures.text("keep my edit")]
            ))
            let removed = try store.insert(ClipboardEntry(
                createdAt: goneDate,
                tabID: tab.id,
                flavours: [Fixtures.text("keep my history")]
            ))

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates, [])
            expectEqual(plan.removals, [])
            expectEqual(plan.conflicts.map(\.reason), [.unrelatedHistory, .unrelatedHistory])

            let stale = CopyQSyncResyncPlan(
                tabID: tab.id,
                tabName: tab.name,
                folder: paths.sync.path,
                imports: [],
                removals: [CopyQSyncMissingEntry(entryID: removed.id, stem: goneStem)],
                updates: [CopyQSyncContentDifference(
                    entryID: updated.id,
                    differingStems: [presentStem],
                    isLegacyIdentity: false
                )],
                conflicts: []
            )
            waitForSettle()
            let result = try CopyQSyncResync.apply(stale, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 0)
            expectEqual(result.entriesRemoved, 0)
            expectEqual(result.conflictsLeft, 2)
            expectEqual(rowText(try unwrap(try store.entry(id: updated.id), "the updated row")), "keep my edit")
            expectEqual(rowText(try unwrap(try store.entry(id: removed.id), "the removed row")), "keep my history")
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a row owning several groups is updated only when they agree, and conflicts otherwise") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let agreeA = "copyq_20261025120000601"
            let agreeB = "copyq_20261025120000602"
            let splitA = "copyq_20261025120000603"
            let splitB = "copyq_20261025120000604"
            for stem in [agreeA, agreeB] {
                try writeGroup(stem: stem, text: "alpha", in: paths.sync)
            }
            try writeGroup(stem: splitA, text: "one", in: paths.sync)
            try writeGroup(stem: splitB, text: "two", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "MultiGroupTab", syncFolder: paths.sync.path))
            let agreeing = try store.insert(ownedRow(agreeA, text: "beta", tabID: tab.id))
            try store.recordWrittenSyncStem(agreeB, folder: paths.sync.path, entryID: agreeing.id)
            let split = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_710_000_000),
                tabID: tab.id,
                flavours: [Fixtures.text("beta")]
            ))
            try store.recordWrittenSyncStem(splitA, folder: paths.sync.path, entryID: split.id)
            try store.recordWrittenSyncStem(splitB, folder: paths.sync.path, entryID: split.id)
            let folderBefore = try folderSnapshot(paths.sync)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.contentDifferenceCount, 2)
            let splitDifference = try unwrap(
                report.contentDifferences.first { $0.entryID == split.id },
                "the split row's difference"
            )
            expectEqual(Set(splitDifference.differingStems), [splitA, splitB])
            expect(splitDifference.hasConflictingGroups, "the row's groups disagree with each other")

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates.map(\.entryID), [agreeing.id], "agreeing groups are updated once")
            expectEqual(plan.conflicts.map(\.reason), [.multipleGroups])
            expectEqual(plan.conflicts.first?.entryID, split.id)

            waitForSettle()
            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 1)
            expectEqual(result.conflictsLeft, 1)

            let updated = try unwrap(try store.entry(id: agreeing.id), "the agreeing row")
            expectEqual(rowText(updated), "alpha")
            let splitAfter = try unwrap(try store.entry(id: split.id), "the split row is untouched")
            expectEqual(rowText(splitAfter), "beta", "resync never chooses between two groups")
            expectEqual(try folderSnapshot(paths.sync), folderBefore)
            expectEqual(try CopyQSyncResync.report(tabID: tab.id, in: store).contentDifferenceCount, 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a row owning a partially undecodable group is refused instead of updated") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let partialStem = "copyq_20261025120000621"
            let differingStem = "copyq_20261025120000622"
            try writeGroup(stem: partialStem, text: "partial content", in: paths.sync)
            try Data([0x78, 0x9C, 0x00]).write(
                to: paths.sync.appendingPathComponent(partialStem + CopyQFormat.dataFileSuffix)
            )
            try writeGroup(stem: differingStem, text: "other content", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "PartialDecodeTab",
                syncFolder: paths.sync.path
            ))
            let row = try store.insert(ownedRow(partialStem, text: "local content", tabID: tab.id))
            try store.recordWrittenSyncStem(differingStem, folder: paths.sync.path, entryID: row.id)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.contentDifferenceCount, 1)
            let difference = try unwrap(report.contentDifferences.first, "the content difference")
            expectEqual(difference.differingStems, [differingStem])
            expect(
                difference.hasConflictingGroups,
                "an undecodable owned group means the groups cannot be shown to agree"
            )

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates, [])
            expectEqual(plan.conflicts.map(\.reason), [.multipleGroups])
            expectEqual(plan.conflicts.first?.entryID, row.id)

            waitForSettle()
            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 0)
            expectEqual(result.conflictsLeft, 1)
            expectEqual(
                rowText(try unwrap(try store.entry(id: row.id), "the row is untouched")),
                "local content"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a planned update falls back to a differing stem when the canonical stem has no group") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let canonicalStem = "copyq_20261025120000611"
            let differingStem = "copyq_20261025120000612"
            try writeGroup(stem: differingStem, text: "folder version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "CanonicalGoneTab",
                syncFolder: paths.sync.path
            ))
            let row = try store.insert(ownedRow(canonicalStem, text: "local version", tabID: tab.id))
            try store.recordWrittenSyncStem(differingStem, folder: paths.sync.path, entryID: row.id)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.contentDifferenceCount, 1)
            expectEqual(report.contentDifferences.first?.differingStems, [differingStem])

            let identity = CopyQSyncIdentityResolver.resolve(
                of: row,
                in: store,
                folder: paths.sync.path,
                groupStems: [differingStem]
            )
            expectEqual(identity.canonicalStem, canonicalStem, "the flavour stem is still preferred")
            expectEqual(identity.stems, [canonicalStem, differingStem])

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates.map(\.entryID), [row.id])
            expectEqual(
                plan.updates.first?.differingStems,
                [differingStem],
                "the plan names a stem the folder has"
            )

            waitForSettle()
            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 1, "the planned update is not permanently skipped")
            expectEqual(
                rowText(try unwrap(try store.entry(id: row.id), "the updated row")),
                "folder version"
            )
            expectEqual(
                try store.writtenSyncStem(forEntryID: row.id, folder: paths.sync.path),
                differingStem
            )
            expectEqual(try CopyQSyncResync.report(tabID: tab.id, in: store).contentDifferenceCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a multi-group row with no files is removed once and archived once") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stemA = "copyq_20261025120000701"
            let stemB = "copyq_20261025120000702"
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "MultiGoneTab", syncFolder: paths.sync.path))
            let row = try store.insert(ownedRow(stemA, text: "both groups gone", tabID: tab.id))
            try store.recordWrittenSyncStem(stemB, folder: paths.sync.path, entryID: row.id)

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.entriesWithoutFilesCount, 1, "one row, counted once")
            expectEqual(report.stemsWithoutEntriesCount, 0)

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.removals.count, 1)
            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesRemoved, 1)
            expectEqual(try store.count(tabID: tab.id), 0)
            expectEqual(
                try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount,
                1,
                "the payload is archived once, not once per owned stem"
            )
            expectEqual(try store.isWrittenSyncStem(stemA, folder: paths.sync.path), false)
            expectEqual(try store.isWrittenSyncStem(stemB, folder: paths.sync.path), false)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("the trash and archive clauses of a removal follow the selected language") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000721"
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "LocalizedTrashTab",
                syncFolder: paths.sync.path
            ))
            let row = try store.insert(ownedRow(stem, text: "the only copy", tabID: tab.id))

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.removals.map(\.entryID), [row.id])

            // A regular file where the trash root should be makes every archive fail.
            let blockedRoot = paths.root.appendingPathComponent("blocked-trash")
            try Data("not a directory".utf8).write(to: blockedRoot)

            let result = try CopyQSyncResync.apply(
                plan,
                in: store,
                trashRoot: blockedRoot,
                language: .simplifiedChinese
            )
            expect(
                result.failures.contains { $0.hasPrefix("无法在重新协调前归档 \(stem)：") },
                "the archive clause is Chinese: \(result.failures)"
            )
            expect(
                !result.failures.contains { $0.hasPrefix("Could not ") },
                "no English clause is left in the Chinese report: \(result.failures)"
            )
            guard let kept = result.failures.first(where: { $0.contains("Kept \(stem)") }) else {
                TestRunner.fail("the kept row is reported: \(result.failures)")
                return
            }
            expectEqual(
                Localization.runtimeMessage(kept, language: .simplifiedChinese),
                "保留了 \(stem)：其内容无法归档到应用废纸篓。"
            )
            expectNotNil(try store.entry(id: row.id), "the row whose payload was not archived stays")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a removal whose own payload cannot be archived is kept while the others proceed") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000711"
            let emptyStem = "copyq_20261025120000712"
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "BlockedTrashTab", syncFolder: paths.sync.path))
            let row = try store.insert(ownedRow(stem, text: "the only copy", tabID: tab.id))
            let empty = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [stemFlavour(emptyStem)]
            ))

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(Set(plan.removals.map(\.entryID)), [row.id, empty.id])

            // A regular file where the trash root should be makes every archive fail.
            let blockedRoot = paths.root.appendingPathComponent("blocked-trash")
            try Data("not a directory".utf8).write(to: blockedRoot)

            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: blockedRoot)
            expectEqual(result.entriesRemoved, 1, "the rows whose archive worked still proceed")
            expect(
                result.failures.contains { $0.contains("Could not archive") },
                "the failed archive is reported: \(result.failures)"
            )
            expect(
                result.failures.contains { $0.contains("Kept \(stem)") },
                "the kept row is named: \(result.failures)"
            )
            let kept = try unwrap(try store.entry(id: row.id), "the row whose archive failed is kept")
            expectEqual(rowText(kept), "the only copy")
            expectNil(try store.entry(id: empty.id), "a row with nothing to archive is still removed")
            expectEqual(try CopyQSyncResync.report(tabID: tab.id, in: store).entriesWithoutFilesCount, 1)

            let retriedPlan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(retriedPlan.removals.map(\.entryID), [row.id])
            let retried = try CopyQSyncResync.apply(retriedPlan, in: store, trashRoot: paths.trash)
            expectEqual(retried.entriesRemoved, 1, "the kept row is still removable")
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a row with a pending local edit is never removed and is reported as a conflict") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000721"
            let cleanStem = "copyq_20261025120000722"
            try writeGroup(stem: stem, text: "folder version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "LocalEditTab", syncFolder: paths.sync.path))
            let row = try store.insert(ownedRow(stem, text: "edited but not written", tabID: tab.id))
            try store.markLocalEdit(id: row.id)
            let cleanRow = try store.insert(ownedRow(cleanStem, text: "clean removal", tabID: tab.id))

            // The other side removes the group while the edit is still unwritten.
            for name in try FileManager.default.contentsOfDirectory(atPath: paths.sync.path)
            where name.hasPrefix(stem) {
                try FileManager.default.removeItem(at: paths.sync.appendingPathComponent(name))
            }

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(Set(report.entriesWithoutFiles.map(\.entryID)), [row.id, cleanRow.id])

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.removals.map(\.entryID), [cleanRow.id], "only the clean row is planned")
            expectEqual(plan.conflicts.map(\.reason), [.locallyEdited])
            expectEqual(plan.conflicts.first?.entryID, row.id)

            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesRemoved, 1, "the clean row is removed in the same run")
            expectEqual(result.conflictsLeft, 1)
            let kept = try unwrap(try store.entry(id: row.id), "the edited row is kept")
            expectEqual(rowText(kept), "edited but not written")
            expectNil(try store.entry(id: cleanRow.id), "the clean row is gone")
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 1)

            let stale = CopyQSyncResyncPlan(
                tabID: tab.id,
                tabName: tab.name,
                folder: paths.sync.path,
                imports: [],
                removals: [CopyQSyncMissingEntry(entryID: row.id, stem: stem)],
                updates: [],
                conflicts: []
            )
            let staleResult = try CopyQSyncResync.apply(stale, in: store, trashRoot: paths.trash)
            expectEqual(staleResult.entriesRemoved, 0, "a stale plan cannot remove a dirty row")
            expectEqual(staleResult.conflictsLeft, 1)
            expectNotNil(try store.entry(id: row.id), "the edited row survives the stale plan")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("apply skips groups that are still being written") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let goneStem = "copyq_20261025120000731"
            let updateStem = "copyq_20261025120000732"
            let importStem = "copyq_20261025120000733"
            try writeGroup(stem: updateStem, text: "folder version", in: paths.sync)
            try writeGroup(stem: importStem, text: "import me", in: paths.sync)
            for stem in [goneStem, updateStem, importStem] {
                try Data("in flight".utf8).write(
                    to: paths.sync.appendingPathComponent(".syncthing.\(stem).txt.tmp")
                )
            }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "InFlightTab", syncFolder: paths.sync.path))
            let removed = try store.insert(ownedRow(goneStem, text: "keep me", tabID: tab.id))
            let updated = try store.insert(ownedRow(updateStem, text: "local version", tabID: tab.id))

            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.entriesWithoutFiles.map(\.entryID), [removed.id])
            expectEqual(report.stemsWithoutEntries, [importStem])
            expectEqual(report.contentDifferences.map(\.entryID), [updated.id])

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.removals.map(\.entryID), [removed.id])
            expectEqual(plan.updates.map(\.entryID), [updated.id])
            expectEqual(plan.imports, [importStem])

            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesRemoved, 0, "a group in flight is not removed")
            expectEqual(result.entriesUpdated, 0, "a group in flight is not applied")
            expectEqual(result.entriesImported, 0, "a group in flight is not imported")
            expectEqual(
                result.failures.filter { $0.contains("still being written") }.count,
                3,
                "every skipped stem is reported: \(result.failures)"
            )
            expectNotNil(try store.entry(id: removed.id), "the removal waits for the transfer")
            let kept = try unwrap(try store.entry(id: updated.id), "the updated row")
            expectEqual(rowText(kept), "local version")
            expectEqual(try store.count(tabID: tab.id), 2)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a complete group that has not settled is skipped until it settles") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000741"
            try writeGroup(stem: stem, text: "folder version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "SettleTab", syncFolder: paths.sync.path))
            let row = try store.insert(ownedRow(stem, text: "local version", tabID: tab.id))

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates.map(\.entryID), [row.id])

            let early = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(early.entriesUpdated, 0, "a fresh group is not written from yet")
            expect(
                early.failures.contains { $0.contains("still being written") },
                "the fresh group is reported: \(early.failures)"
            )
            expectEqual(
                rowText(try unwrap(try store.entry(id: row.id), "the unchanged row")),
                "local version"
            )

            waitForSettle()
            let settledPlan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            let result = try CopyQSyncResync.apply(settledPlan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 1, "the settled group is applied")
            expectEqual(
                rowText(try unwrap(try store.entry(id: row.id), "the updated row")),
                "folder version"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("an update whose work was already done is reported as already in sync") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let stem = "copyq_20261025120000751"
            try writeGroup(stem: stem, text: "folder version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "AlreadySyncedTab", syncFolder: paths.sync.path))
            let row = try store.insert(ownedRow(stem, text: "local version", tabID: tab.id))

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.updates.map(\.entryID), [row.id])

            // The watcher imports the same folder version before the confirmation lands.
            try store.recordWrittenSyncStem(stem, folder: paths.sync.path, entryID: row.id)
            try store.replaceFlavours(
                of: row.id,
                with: [Fixtures.text("folder version")],
                note: "",
                pinned: false
            )
            waitForSettle()

            let result = try CopyQSyncResync.apply(plan, in: store, trashRoot: paths.trash)
            expectEqual(result.entriesUpdated, 0)
            expect(
                result.failures.contains { $0.contains("already has the folder's content") },
                "the already-finished update is reported: \(result.failures)"
            )
            expectEqual(try store.count(tabID: tab.id), 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a queued capture is settled before resync decides, so a stale removal cannot win") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "QueuedTab", syncFolder: paths.sync.path))
            let row = try store.insert(ownedRow(
                "copyq_20261025120000801",
                text: "captured but not written yet",
                tabID: tab.id
            ))

            let writer = CopyQSyncWriter()
            writer.customLogFilePath = paths.root.appendingPathComponent("sync.log").path

            // The report sees a row with no file and plans its removal...
            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(plan.removals.map(\.entryID), [row.id])

            // ...while a capture write for that row is still queued.
            writer.enqueue(entry: row, store: store, reason: "capture")

            let result = try CopyQSyncResync.apply(
                plan,
                in: store,
                trashRoot: paths.trash,
                writer: writer
            )
            expectEqual(result.entriesRemoved, 0, "the settled write wins over the stale plan")
            expect(
                result.failures.contains { $0.contains("reappeared") },
                "the skipped removal is reported: \(result.failures)"
            )
            expectNotNil(try store.entry(id: row.id), "the row survives because its group exists")
            let files = try folderSnapshot(paths.sync)
            expectEqual(files.count, 1, "exactly the queued capture's file group is present")
            expectEqual(try CopyQSyncResync.report(tabID: tab.id, in: store).matchedEntryCount, 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a write for a row resync removed recreates nothing") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "StaleSnapshotTab", syncFolder: paths.sync.path))
            let row = try store.insert(ownedRow(
                "copyq_20261025120000901",
                text: "queued capture of a removed row",
                tabID: tab.id
            ))
            let writer = CopyQSyncWriter()
            writer.customLogFilePath = paths.root.appendingPathComponent("sync.log").path

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            let result = try CopyQSyncResync.apply(
                plan,
                in: store,
                trashRoot: paths.trash,
                writer: writer
            )
            expectEqual(result.entriesRemoved, 1)
            expectEqual(try store.count(tabID: tab.id), 0)

            // The stale snapshot a queued write carries finds no stored row.
            let log = try writer.writeEntry(row, in: store, reason: "capture")
            expectNil(log, "a write for a removed row is a no-op")
            expectEqual(try folderSnapshot(paths.sync), [:], "no group is recreated in the folder")
            expectEqual(try store.count(tabID: tab.id), 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("stale in-memory stem caches are re-derived from the durable record after apply") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let removedStem = "copyq_20261025120001001"
            let updatedStem = "copyq_20261025120001002"
            try writeGroup(stem: updatedStem, text: "folder version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "CacheTab", syncFolder: paths.sync.path))
            let removed = try store.insert(ownedRow(removedStem, text: "gone", tabID: tab.id))
            let updated = try store.insert(ownedRow(updatedStem, text: "local version", tabID: tab.id))
            try store.recordWrittenSyncStem(removedStem, folder: paths.sync.path, entryID: removed.id)
            try store.recordWrittenSyncStem(updatedStem, folder: paths.sync.path, entryID: updated.id)

            let watcher = CopyQSyncWatcher(store: store)
            expect(watcher.isWrittenByUs(removedStem, folder: paths.sync.path), "the cache starts warm")
            CopyQSyncWatcher.shared.recordWrittenStem(removedStem, folder: paths.sync.path)
            CopyQSyncWatcher.shared.recordWrittenStem(updatedStem, folder: paths.sync.path)
            expect(
                CopyQSyncWatcher.shared.isWrittenByUs(removedStem, folder: paths.sync.path),
                "the shared cache starts warm too"
            )

            let plan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            waitForSettle()
            let result = try CopyQSyncResync.apply(
                plan,
                in: store,
                trashRoot: paths.trash,
                watcher: watcher
            )
            expectEqual(result.entriesRemoved, 1)
            expectEqual(result.entriesUpdated, 1)

            expectEqual(
                watcher.isWrittenByUs(removedStem, folder: paths.sync.path),
                false,
                "the removed stem is dropped from the watcher's memory"
            )
            expectEqual(
                CopyQSyncWatcher.shared.isWrittenByUs(removedStem, folder: paths.sync.path),
                false
            )
            expectEqual(try store.isWrittenSyncStem(removedStem, folder: paths.sync.path), false)
            expectEqual(
                try store.writtenSyncStem(forEntryID: updated.id, folder: paths.sync.path),
                updatedStem,
                "the updated row keeps its durable stem"
            )
            expect(watcher.isWrittenByUs(updatedStem, folder: paths.sync.path))
            expect(
                CopyQSyncWatcher.shared.isWrittenByUs(updatedStem, folder: paths.sync.path),
                "the shared cache still knows the updated stem"
            )
            expectEqual(try store.isWrittenSyncStem(updatedStem, folder: paths.sync.path), true)
            expectEqual(try CopyQSyncResync.report(tabID: tab.id, in: store).matchedEntryCount, 1)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("apply is refused while sync is paused and writes nothing") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let importStem = "copyq_20261025120001101"
            try writeGroup(stem: importStem, text: "import me", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "PausedTab", syncFolder: paths.sync.path))
            let report = try CopyQSyncResync.report(tabID: tab.id, in: store)
            expectEqual(report.stemsWithoutEntries, [importStem], "the read-only report still works")

            var preferences = try store.preferences()
            preferences.syncPaused = true
            try store.setPreferences(preferences)
            let folderBefore = try folderSnapshot(paths.sync)

            expectThrows {
                _ = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            }
            let paused = try CopyQSyncResync.reportAndPlan(tabID: tab.id, in: store)
            expectEqual(paused.report, report)
            expectNil(paused.plan, "a paused tab offers no plan while the report still reads")
            expectThrows {
                _ = try CopyQSyncResync.apply(
                    CopyQSyncResyncPlan(
                        tabID: tab.id,
                        tabName: tab.name,
                        folder: paths.sync.path,
                        imports: [importStem],
                        removals: [],
                        updates: [],
                        conflicts: []
                    ),
                    in: store,
                    trashRoot: paths.trash
                )
            }
            expectEqual(try store.count(tabID: tab.id), 0)
            expectEqual(try folderSnapshot(paths.sync), folderBefore)
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a missing or unreadable sync folder fails before resync deletes or writes anything") {
        do {
            let paths = try scratch()
            var madeUnreadable = false
            defer {
                if madeUnreadable {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: paths.sync.path
                    )
                }
                try? FileManager.default.removeItem(at: paths.root)
            }

            let goneStem = "copyq_20261025120001201"
            let matchedStem = "copyq_20261025120001202"
            try writeGroup(stem: matchedStem, text: "folder version", in: paths.sync)

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "BrokenFolderTab",
                syncFolder: paths.sync.path
            ))
            let gone = try store.insert(ownedRow(
                goneStem,
                text: "waiting to be removed",
                tabID: tab.id
            ))
            let matched = try store.insert(ownedRow(
                matchedStem,
                text: "folder version",
                tabID: tab.id
            ))

            // A healthy folder gives a plan that wants to remove the row whose
            // files are gone; planning still writes nothing.
            let healthyTree = try treeSnapshot(paths.root)
            let healthyPlan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(healthyPlan.removals.map(\.entryID), [gone.id])
            expectEqual(try treeSnapshot(paths.root), healthyTree, "planning never writes")

            // Missing folder: the comparison names it, and the plan built while
            // the folder existed cannot delete anything.
            try FileManager.default.removeItem(at: paths.sync)
            let missingTree = try treeSnapshot(paths.root)
            do {
                _ = try CopyQSyncResync.plan(tabID: tab.id, in: store)
                TestRunner.fail("planning against a missing folder must fail")
            } catch {
                expectEqual(
                    error as? CopyQSyncResyncError,
                    .folderMissing(CopyQSyncBridge.normalizePath(paths.sync.path)),
                    "the plan names the missing folder"
                )
            }
            do {
                _ = try CopyQSyncResync.apply(healthyPlan, in: store, trashRoot: paths.trash)
                TestRunner.fail("applying against a missing folder must fail")
            } catch {
                if case .folderUnreadable(let folder, _)? = error as? CopyQSyncResyncError {
                    expectEqual(folder, CopyQSyncBridge.normalizePath(paths.sync.path))
                } else {
                    TestRunner.fail("apply reports the folder it could not read, got \(error)")
                }
            }
            expectNotNil(try store.entry(id: gone.id), "a failed apply removes no row")
            expectEqual(rowText(try unwrap(try store.entry(id: gone.id))), "waiting to be removed")
            expectEqual(rowText(try unwrap(try store.entry(id: matched.id))), "folder version")
            expectEqual(try store.count(tabID: tab.id), 2, "the store is unchanged")
            expectEqual(
                try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount,
                0,
                "nothing reached the app trash"
            )
            expectEqual(
                try treeSnapshot(paths.root),
                missingTree,
                "a failed apply creates no file outside the trash root"
            )

            // Unreadable folder: the same guarantees, with the folder present.
            try FileManager.default.createDirectory(at: paths.sync, withIntermediateDirectories: true)
            try writeGroup(stem: matchedStem, text: "folder version", in: paths.sync)
            let unreadablePlan = try CopyQSyncResync.plan(tabID: tab.id, in: store)
            expectEqual(unreadablePlan.removals.map(\.entryID), [gone.id])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: paths.sync.path
            )
            madeUnreadable = true
            let unreadableTree = try treeSnapshot(paths.root)
            do {
                _ = try CopyQSyncResync.plan(tabID: tab.id, in: store)
                TestRunner.fail("planning against an unreadable folder must fail")
            } catch {
                if case .folderUnreadable(let folder, _)? = error as? CopyQSyncResyncError {
                    expectEqual(folder, CopyQSyncBridge.normalizePath(paths.sync.path))
                } else {
                    TestRunner.fail("the plan names the folder it could not read, got \(error)")
                }
            }
            do {
                _ = try CopyQSyncResync.apply(unreadablePlan, in: store, trashRoot: paths.trash)
                TestRunner.fail("applying against an unreadable folder must fail")
            } catch {
                if case .folderUnreadable(let folder, _)? = error as? CopyQSyncResyncError {
                    expectEqual(folder, CopyQSyncBridge.normalizePath(paths.sync.path))
                } else {
                    TestRunner.fail("apply reports the folder it could not read, got \(error)")
                }
            }
            expectNotNil(try store.entry(id: gone.id), "the unreadable folder removes no row")
            expectEqual(rowText(try unwrap(try store.entry(id: gone.id))), "waiting to be removed")
            expectEqual(rowText(try unwrap(try store.entry(id: matched.id))), "folder version")
            expectEqual(try store.count(tabID: tab.id), 2, "the store is unchanged")
            expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)
            expectEqual(try treeSnapshot(paths.root), unreadableTree)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("the resync dialog defaults to the read-only report and needs a second confirmation to write") {
        MainActor.assumeIsolated {
            do {
                let paths = try scratch()
                defer { try? FileManager.default.removeItem(at: paths.root) }

                let importStem = "copyq_20261025120001201"
                try writeGroup(stem: importStem, text: "import me", in: paths.sync)
                waitForSettle()
                let folderBefore = try folderSnapshot(paths.sync)

                let store = try ClipboardStore(inMemory: true)
                let tab = try store.insertTab(ClipboardTab(name: "DialogApplyTab", syncFolder: paths.sync.path))

                let history = ClipboardHistory(store: store)
                history.syncTrashRoot = paths.trash
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.reload()
                model.selectedTabID = tab.id
                model.reload()

                let actions = AppActions(
                    model: model,
                    windowController: ResyncApplyWindowControllerStub(),
                    presentPreferences: {}
                )
                var alerts: [[String]] = []
                var responses: [NSApplication.ModalResponse] = []
                actions.alertPresenter = { alert in
                    alerts.append(alert.buttons.map(\.title))
                    return responses.isEmpty ? .alertFirstButtonReturn : responses.removeFirst()
                }
                model.onResyncTabRequest = { tabID in
                    actions.resyncTab(id: tabID)
                }

                // Return on the report writes nothing.
                responses = [.alertFirstButtonReturn]
                model.requestResyncTab(tab.id)
                expect(waitUntil { alerts.count == 1 }, "the report is presented off the main thread")
                expectEqual(alerts, [["OK", "Apply Changes…"]], "the report is the default surface")
                expectEqual(try store.count(tabID: tab.id), 0)
                expectEqual(try folderSnapshot(paths.sync), folderBefore)

                // Apply Changes… then Cancel writes nothing either.
                alerts.removeAll()
                responses = [.alertSecondButtonReturn, .alertFirstButtonReturn]
                model.requestResyncTab(tab.id)
                expect(waitUntil { alerts.count == 2 }, "the confirmation is presented")
                expectEqual(alerts[1], ["Cancel", "Apply"], "the confirmation defaults to Cancel")
                expectEqual(try store.count(tabID: tab.id), 0)
                expectEqual(try folderSnapshot(paths.sync), folderBefore)
                expectEqual(try CopyQSyncTrash.summary(trashRoot: paths.trash).batchCount, 0)

                // Apply Changes… then Apply performs exactly the plan.
                alerts.removeAll()
                model.notice = nil
                responses = [.alertSecondButtonReturn, .alertSecondButtonReturn]
                model.requestResyncTab(tab.id)
                expect(waitUntil { alerts.count == 2 }, "the confirmed apply runs")
                expectEqual(try store.count(tabID: tab.id), 1)
                expectEqual(try folderSnapshot(paths.sync), folderBefore)
                let notice = model.notice ?? ""
                expect(notice.contains("Imported 1 entry"), "the notice states what was written: \(notice)")
                let imported = try unwrap(
                    store.recentEntries(limit: 10, tabID: tab.id).first,
                    "the confirmed apply stores the imported row"
                )
                expectEqual(
                    model.entries.map(\.id),
                    [imported.id],
                    "the tab's visible list is refreshed with the imported row"
                )
                expectEqual(
                    model.entries.first.flatMap(rowText),
                    "import me",
                    "the refreshed row carries the folder content"
                )

                // A removal that cannot be archived is kept, and the notice says so.
                let blockedRoot = paths.root.appendingPathComponent("blocked-trash")
                try Data("not a directory".utf8).write(to: blockedRoot)
                history.syncTrashRoot = blockedRoot
                let kept = try store.insert(ownedRow(
                    "copyq_20261025120001202",
                    text: "cannot be archived",
                    tabID: tab.id
                ))
                alerts.removeAll()
                model.notice = nil
                responses = [.alertSecondButtonReturn, .alertSecondButtonReturn]
                model.requestResyncTab(tab.id)
                expect(waitUntil { alerts.count == 2 }, "the report still offers the confirmed write")
                expectNotNil(try store.entry(id: kept.id), "a row whose archive failed is kept")
                let failedNotice = model.notice ?? ""
                expect(
                    failedNotice.contains("Could not archive"),
                    "the notice reports the failed archive: \(failedNotice)"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
