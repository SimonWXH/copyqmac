// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncRestoreTests.swift
//
// The write-back path that restores a tab's local items into its sync folder:
// the plan's counts, the files that appear, the entries that are refused, the
// stems that end up owed by the written rows, and the write-only boundary.
//
// Everything runs in temporary directories; no real sync folder and no GUI
// automation are involved.

import AppKit
import Foundation

@MainActor
private final class RestoreWindowControllerStub: NSObject, WindowControllerProtocol {
    var isVisible = false
    func show() {}
    func hide() {}
}

func registerCopyQSyncRestoreTests() {
    TestRunner.currentSuite = "CopyQSyncRestore"

    struct Paths {
        let root: URL
        let sync: URL
    }

    func scratch() throws -> Paths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copyq-write-back-\(UUID().uuidString)", isDirectory: true)
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        return Paths(root: root, sync: sync)
    }

    /// Every regular file directly in `folder`, with its bytes.
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

    func fileNames(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A writer whose log stays in the test's own directory.
    func makeWriter(in root: URL) -> CopyQSyncWriter {
        let writer = CopyQSyncWriter()
        writer.customLogFilePath = root.appendingPathComponent("sync.log").path
        return writer
    }

    func makeStore(folder: URL, name: String = "WriteBackTab") throws -> (ClipboardStore, ClipboardTab) {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.insertTab(ClipboardTab(name: name, syncFolder: folder.path))
        var preferences = try store.preferences()
        preferences.syncPaused = false
        try store.setPreferences(preferences)
        return (store, tab)
    }

    func textEntries(in store: ClipboardStore, tabID: Int64, count: Int) throws -> [ClipboardEntry] {
        var entries: [ClipboardEntry] = []
        for index in 0..<count {
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index)),
                tabID: tabID,
                flavours: [Fixtures.text("restored content \(index)")]
            ))
            entries.append(entry)
        }
        return entries
    }

    TestRunner.add("the plan counts entries and files and writes nothing") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let (store, tab) = try makeStore(folder: paths.sync)
            let entries = try textEntries(in: store, tabID: tab.id, count: 4)
            let unrelated = paths.sync.appendingPathComponent("unrelated-notes.txt")
            try Data("keep me".utf8).write(to: unrelated)
            let before = try folderSnapshot(paths.sync)

            let plan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
            expectEqual(plan.entryCount, 4, "every local entry is planned")
            expectEqual(plan.fileCreateCount, 4, "each text entry creates one file")
            expectEqual(plan.fileUpdateCount, 0, "an empty folder has nothing to update")
            expectEqual(plan.skipped.count, 0, "nothing is skipped")
            expectEqual(try folderSnapshot(paths.sync), before, "planning writes nothing")

            let stems = Set(plan.rows.map(\.stem))
            expectEqual(stems.count, 4, "each row gets its own stem")
            for entry in entries {
                expect(
                    stems.contains(CopyQSyncBridge.formatTimestamp(entry.createdAt)),
                    "the stem follows the capture naming rule for entry \(entry.id)"
                )
            }

            let english = plan.confirmation(language: .english)
            expect(
                english.contains("Write 4 entries back to the folder."),
                "the confirmation states the entry count: \(english)"
            )
            expect(english.contains("Create 4 files."), "the confirmation states the created files: \(english)")
            expect(english.contains("Update 0 files in place."), "the confirmation states the updates: \(english)")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("an emptied folder receives one complete group per entry and keeps unrelated files") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let (store, tab) = try makeStore(folder: paths.sync)
            let entries = try textEntries(in: store, tabID: tab.id, count: 3)
            let unrelated = ["unrelated-notes.md", "unrelated.json", ".hidden-sync-file"]
            for name in unrelated {
                try Data("keep me".utf8).write(to: paths.sync.appendingPathComponent(name))
            }

            let plan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
            let result = try CopyQSyncRestore.apply(
                plan,
                in: store,
                writer: makeWriter(in: paths.root)
            )
            expectEqual(result.entriesWritten, 3, "every planned entry is written")
            expectEqual(result.filesCreated, 3, "every planned file is created")
            expectEqual(result.filesUpdated, 0, "no file is rewritten")
            expectEqual(result.skipped.count, 0, "nothing is skipped")
            expectNil(result.stoppedAt, "the run finishes")

            // Unrelated files are untouched, byte for byte.
            for name in unrelated {
                expectEqual(
                    try Data(contentsOf: paths.sync.appendingPathComponent(name)),
                    Data("keep me".utf8),
                    "the unrelated file \(name) survives"
                )
            }

            // Every group is exactly what the writer's own serialisation
            // produces for the row.
            let contents = try CopyQSyncFolder.read(atPath: paths.sync.path)
            expectEqual(contents.items.count, 3, "the reader sees three groups")
            expectEqual(contents.failures.count, 0, "no written file fails to read")
            for entry in entries {
                let stem = CopyQSyncBridge.formatTimestamp(entry.createdAt)
                let expected = CopyQSyncBridge.entryToItem(entry, baseNameOverride: stem).onDiskFiles()
                for (suffix, bytes) in expected {
                    let path = paths.sync.appendingPathComponent(stem + suffix)
                    expectEqual(
                        try Data(contentsOf: path),
                        bytes,
                        "\(stem + suffix) carries the writer's serialisation"
                    )
                }
            }
            expectEqual(
                Set(contents.items.compactMap(\.text)),
                Set((0..<3).map { "restored content \($0)" }),
                "every entry's text is readable back from the folder"
            )

            // A capture of the same rows through the writer's own path has to
            // produce exactly the same files, byte for byte.
            let control = try scratch()
            defer { try? FileManager.default.removeItem(at: control.root) }
            let (controlStore, controlTab) = try makeStore(folder: control.sync, name: "ControlTab")
            for entry in entries {
                _ = try controlStore.insert(ClipboardEntry(
                    createdAt: entry.createdAt,
                    tabID: controlTab.id,
                    flavours: entry.flavours
                ))
            }
            let controlWriter = makeWriter(in: control.root)
            for entry in try controlStore.recentEntries(limit: Int.max, tabID: controlTab.id) {
                _ = try controlWriter.writeEntry(entry, in: controlStore, reason: "capture")
            }
            let restoredOnly = try folderSnapshot(paths.sync).filter { name, _ in
                !unrelated.contains(name)
            }
            expectEqual(
                restoredOnly,
                try folderSnapshot(control.sync),
                "the write-back groups are byte-identical to the writer's capture output"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a tab without a sync folder is refused and nothing is written") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(name: "UnmappedWriteBack"))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(),
                tabID: tab.id,
                flavours: [Fixtures.text("unmapped")]
            ))

            do {
                _ = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
                TestRunner.fail("an unmapped tab must be refused")
            } catch let error as CopyQSyncResyncError {
                expectEqual(error, .noSyncFolder("UnmappedWriteBack"), "the refusal names the missing folder")
            }

            // A folder that vanished after being mapped is refused too.
            let missing = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("copyq-gone-\(UUID().uuidString)")
            var mapped = try store.tab(id: tab.id)
            mapped?.syncFolder = missing.path
            try store.updateTab(unwrap(mapped, "the mapped tab"))
            do {
                _ = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
                TestRunner.fail("a missing folder must be refused")
            } catch let error as CopyQSyncResyncError {
                expectEqual(error, .folderMissing(missing.path), "the refusal names the missing folder")
            }

            // Two tabs claiming one folder leave no single owner to write for.
            let shared = try scratch()
            defer { try? FileManager.default.removeItem(at: shared.root) }
            let first = try store.insertTab(ClipboardTab(name: "First", syncFolder: shared.sync.path))
            _ = try store.insertTab(ClipboardTab(name: "Second", syncFolder: shared.sync.path))
            do {
                _ = try CopyQSyncRestore.plan(tabID: first.id, in: store)
                TestRunner.fail("an ambiguous folder must be refused")
            } catch let error as CopyQSyncResyncError {
                guard case .ambiguousSyncFolder(let folder, let tabNames) = error else {
                    TestRunner.fail("unexpected refusal: \(error)")
                    return
                }
                expectEqual(folder, shared.sync.path, "the refusal names the folder")
                expectEqual(tabNames.count, 2, "both claiming tabs are named")
            }
            expectEqual(try fileNames(shared.sync), [], "nothing is written for an ambiguous folder")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("internal-only, empty, and undecodable entries are skipped with exact counts") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let (store, tab) = try makeStore(folder: paths.sync)

            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_780_000_100),
                tabID: tab.id,
                flavours: [
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data("copyq_20260101000000000".utf8)
                    ),
                ]
            ))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_780_000_101),
                tabID: tab.id,
                flavours: []
            ))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_780_000_102),
                tabID: tab.id,
                flavours: [
                    Flavour(
                        itemIndex: 0,
                        type: PasteboardTypes.fileURL,
                        data: Data("not a file url".utf8)
                    ),
                ]
            ))
            let writable = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_780_000_103),
                tabID: tab.id,
                flavours: [Fixtures.text("the only writable row")]
            ))

            let plan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
            expectEqual(plan.entryCount, 1, "only the row with content is planned")
            expectEqual(plan.rows.first?.entryID, writable.id, "the planned row is the one with content")
            expectEqual(plan.skipped.count, 3, "three rows are refused")
            expectEqual(
                Set(plan.skipped.map(\.reason)),
                [.undecodable, .emptyContent, .internalOnly],
                "each row is refused for its own reason"
            )

            let english = plan.confirmation(language: .english)
            expect(
                english.contains("Skip 3 entries: 1 only internal markers"),
                "the confirmation names the skip reasons: \(english)"
            )
            let chinese = plan.confirmation(language: .simplifiedChinese)
            expect(
                chinese.contains("跳过 3 条条目："),
                "the Chinese confirmation reports the same skips: \(chinese)"
            )

            let result = try CopyQSyncRestore.apply(
                plan,
                in: store,
                writer: makeWriter(in: paths.root)
            )
            expectEqual(result.entriesWritten, 1, "only the writable row is written")
            expectEqual(result.skipped.count, 3, "the result repeats the refused rows")
            expectEqual(try fileNames(paths.sync), ["\(CopyQSyncBridge.formatTimestamp(writable.createdAt)).txt"],
                "the folder holds exactly one group")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("every written stem is recorded for its row and a repeat writes no duplicate") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let (store, tab) = try makeStore(folder: paths.sync)
            let entries = try textEntries(in: store, tabID: tab.id, count: 3)
            let writer = makeWriter(in: paths.root)

            let first = try CopyQSyncRestore.apply(
                try CopyQSyncRestore.plan(tabID: tab.id, in: store),
                in: store,
                writer: writer
            )
            expectEqual(first.entriesWritten, 3, "the first run writes every row")
            let afterFirst = try folderSnapshot(paths.sync)
            expectEqual(afterFirst.count, 3, "three files after the first run")

            for entry in entries {
                let stems = try store.writtenSyncStems(forEntryID: entry.id, folder: paths.sync.path)
                expectEqual(stems.count, 1, "the row owns exactly one stem")
                if let stem = stems.first {
                    expectEqual(
                        try store.isWrittenSyncStem(stem, folder: paths.sync.path),
                        true,
                        "the stem is recorded durably"
                    )
                    expect(
                        afterFirst.keys.contains("\(stem).txt"),
                        "the recorded stem matches the written group: \(stem)"
                    )
                }
            }

            // A second plan finds every row already in the folder, and a second
            // apply therefore writes nothing.
            let secondPlan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
            expectEqual(secondPlan.entryCount, 0, "no row needs a second write")
            expectEqual(secondPlan.skipped.count, 3, "every row is accounted for")
            expectEqual(
                Set(secondPlan.skipped.map(\.reason)),
                [.alreadyInSync],
                "the rows are reported as already in the folder"
            )
            let second = try CopyQSyncRestore.apply(secondPlan, in: store, writer: writer)
            expectEqual(second.entriesWritten, 0, "the repeat writes nothing")
            expectEqual(try folderSnapshot(paths.sync), afterFirst, "the folder is unchanged by the repeat")
            expectEqual(try fileNames(paths.sync).count, 3, "no duplicate file appears")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("an existing group with different content is rewritten in place, keeping the local version") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let (store, tab) = try makeStore(folder: paths.sync)
            let createdAt = Date(timeIntervalSince1970: 1_780_000_500)
            let stem = CopyQSyncBridge.formatTimestamp(createdAt)
            let entry = try store.insert(ClipboardEntry(
                createdAt: createdAt,
                tabID: tab.id,
                note: "kept note",
                flavours: [Fixtures.text("local version")]
            ))
            try store.recordWrittenSyncStem(stem, folder: paths.sync.path, entryID: entry.id)

            var folderData = CopyQDataMap()
            folderData.set("text/plain", Data("folder version".utf8))
            try CopyQSyncFolder.write(
                CopyQSyncItem(baseName: stem, data: folderData),
                into: paths.sync.path
            )
            let unrelated = paths.sync.appendingPathComponent("copyq_19990101000000000.txt")
            try Data("unrelated history".utf8).write(to: unrelated)

            let plan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
            expectEqual(plan.entryCount, 1, "the row is written")
            expectEqual(plan.fileCreateCount, 1, "the note file does not exist yet")
            expectEqual(plan.fileUpdateCount, 1, "the text file is rewritten")
            expectEqual(plan.rows.first?.stem, stem, "the row keeps its own stem")

            let result = try CopyQSyncRestore.apply(
                plan,
                in: store,
                writer: makeWriter(in: paths.root)
            )
            expectEqual(result.entriesWritten, 1, "the row is written")
            expectEqual(result.filesUpdated, 1, "the existing file is counted as an update")
            expectEqual(result.filesCreated, 1, "the note file is counted as created")

            let contents = try CopyQSyncFolder.read(atPath: paths.sync.path)
            let restored = try unwrap(
                contents.items.first { $0.baseName == stem },
                "the rewritten group"
            )
            expectEqual(restored.text, "local version", "the local version wins")
            expectEqual(restored.notes, "kept note", "the note travels with the group")
            expectEqual(
                try Data(contentsOf: unrelated),
                Data("unrelated history".utf8),
                "an unrelated group in the same folder is untouched"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("paused sync refuses the write and leaves the folder alone") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let (store, tab) = try makeStore(folder: paths.sync)
            _ = try textEntries(in: store, tabID: tab.id, count: 2)
            let plan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)

            var preferences = try store.preferences()
            preferences.syncPaused = true
            try store.setPreferences(preferences)

            do {
                _ = try CopyQSyncRestore.apply(plan, in: store, writer: makeWriter(in: paths.root))
                TestRunner.fail("paused sync must refuse the write")
            } catch let error as CopyQSyncResyncError {
                expectEqual(error, .writeBackPaused("WriteBackTab"), "the refusal says why")
                expect(
                    error.localizedDescription.contains("cannot be written back"),
                    "the message names the write-back: \(error.localizedDescription)"
                )
            }
            expectEqual(try fileNames(paths.sync), [], "nothing is written while paused")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a legacy-only stem is kept when it matches and skipped when it differs") {
        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let (store, tab) = try makeStore(folder: paths.sync)
            let createdAt = Date(timeIntervalSince1970: 1_780_000_900)
            let stem = CopyQSyncBridge.formatTimestamp(createdAt)
            var folderData = CopyQDataMap()
            folderData.set("text/plain", Data("folder history".utf8))
            try CopyQSyncFolder.write(
                CopyQSyncItem(baseName: stem, data: folderData),
                into: paths.sync.path
            )

            // The row carries no base-name flavour and no recorded stem, so its
            // only link to the group is the matching creation time.
            let row = try store.insert(ClipboardEntry(
                createdAt: createdAt,
                tabID: tab.id,
                flavours: [Fixtures.text("local history")]
            ))
            let before = try folderSnapshot(paths.sync)

            let plan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
            expectEqual(plan.entryCount, 0, "the row is not written over a possible stranger")
            expectEqual(plan.skipped.map(\.reason), [.unrelatedHistory], "the skip names the reason")
            expectEqual(try folderSnapshot(paths.sync), before, "the folder is untouched")

            // The same row whose content the group already carries needs no
            // write at all.
            try store.replaceFlavours(
                of: row.id,
                with: [Fixtures.text("folder history")],
                note: "",
                pinned: false
            )
            let matchingPlan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
            expectEqual(matchingPlan.entryCount, 0, "a matching group is not rewritten")
            expectEqual(
                matchingPlan.skipped.map(\.reason),
                [.alreadyInSync],
                "the matching row is reported as already in the folder"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a failed write stops the run and keeps the files already written") {
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

        do {
            let paths = try scratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let (store, tab) = try makeStore(folder: paths.sync)
            _ = try textEntries(in: store, tabID: tab.id, count: 2)
            let plan = try CopyQSyncRestore.plan(tabID: tab.id, in: store)
            expectEqual(plan.entryCount, 2, "both rows are planned")

            // The second group's install is the second move of the run.
            let failingManager = FailingMoveFileManager(failingMove: 2)
            let result = try CopyQSyncRestore.apply(
                plan,
                in: store,
                writer: makeWriter(in: paths.root),
                fileManager: failingManager
            )
            expectEqual(result.entriesWritten, 1, "the first row is written before the failure")
            expectEqual(result.filesCreated, 1, "its file counts as created")
            expectNotNil(result.stoppedAt, "the run reports where it stopped")
            expectEqual(result.failures.count, 1, "one failure is reported")
            expect(
                result.failures[0].hasPrefix("Could not write "),
                "the failure names the write: \(result.failures)"
            )
            expectEqual(try fileNames(paths.sync).count, 1, "the written file is kept and no partial file remains")
            expect(
                result.summary(language: .english).contains("stopped while writing"),
                "the summary reports the stop: \(result.summary(language: .english))"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("the tab command states the plan's counts and cancel writes nothing") {
        MainActor.assumeIsolated {
            do {
                let paths = try scratch()
                defer { try? FileManager.default.removeItem(at: paths.root) }

                let (store, tab) = try makeStore(folder: paths.sync, name: "DialogWriteBack")
                _ = try textEntries(in: store, tabID: tab.id, count: 2)

                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.reload()
                model.selectTab(tab.id)
                model.reload()

                let actions = AppActions(
                    model: model,
                    windowController: RestoreWindowControllerStub(),
                    presentPreferences: {}
                )
                var prompts: [(buttons: [String], text: String)] = []
                var responses: [NSApplication.ModalResponse] = [.alertFirstButtonReturn]
                actions.alertPresenter = { alert in
                    prompts.append((alert.buttons.map(\.title), alert.informativeText))
                    return responses.isEmpty ? .alertFirstButtonReturn : responses.removeFirst()
                }

                model.onWriteBackTabRequest = { tabID in
                    actions.writeBackTab(id: tabID)
                }
                model.requestWriteBackTab(tab.id)
                let deadline = Date().addingTimeInterval(5)
                while prompts.isEmpty, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                expectEqual(prompts.count, 1, "one confirmation is presented")
                expectEqual(
                    prompts.first?.buttons,
                    ["Cancel", "Write to Folder"],
                    "the confirmation defaults to Cancel"
                )
                let text = prompts.first?.text ?? ""
                expect(text.contains("Write 2 entries back to the folder."), "the entry count is stated: \(text)")
                expect(text.contains("Create 2 files."), "the created files are stated: \(text)")
                expect(text.contains("Update 0 files in place."), "the updates are stated: \(text)")
                expect(text.contains(paths.sync.path), "the target folder is named: \(text)")
                expectEqual(try fileNames(paths.sync), [], "cancel writes nothing")

                // Accepting the confirmation performs exactly the planned write.
                prompts.removeAll()
                responses = [.alertSecondButtonReturn]
                model.requestWriteBackTab(tab.id)
                let secondDeadline = Date().addingTimeInterval(5)
                while prompts.isEmpty, Date() < secondDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                expectEqual(prompts.count, 1, "the second confirmation is presented")
                let noticeDeadline = Date().addingTimeInterval(5)
                while (model.notice ?? "").isEmpty, Date() < noticeDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                expect(
                    (model.notice ?? "").contains("Wrote 2 entries to the folder"),
                    "the notice reports the write: \(model.notice ?? "nil")"
                )
                expect(
                    (model.notice ?? "").contains("created 2 files"),
                    "the notice reports the created files: \(model.notice ?? "nil")"
                )
                expectEqual(try fileNames(paths.sync).count, 2, "the confirmed write creates the files")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the confirmation and its diagnostics speak both languages") {
        let plan = CopyQSyncRestorePlan(
            tabID: 1,
            tabName: "Mac mini",
            folder: "/tmp/copyq-localised",
            rows: [
                CopyQSyncRestoreRow(
                    entryID: 1,
                    stem: "copyq_20260101000000000",
                    filesToCreate: ["copyq_20260101000000000.txt"],
                    filesToUpdate: []
                ),
            ],
            skipped: [CopyQSyncRestoreSkip(entryID: 2, stem: nil, reason: .emptyContent)]
        )

        let english = plan.confirmation(language: .english)
        expect(english.contains("Write 1 entry back to the folder."), "singular entry wording: \(english)")
        expect(english.contains("Create 1 file."), "singular created wording: \(english)")
        expect(english.contains("Skip 1 entry: 1 no content."), "the skip reason: \(english)")

        let chinese = plan.confirmation(language: .simplifiedChinese)
        expect(chinese.contains("将 1 条条目写回文件夹。"), "Chinese entry wording: \(chinese)")
        expect(chinese.contains("新建 1 个文件。"), "Chinese created wording: \(chinese)")
        expect(chinese.contains("跳过 1 条条目：1 没有内容。"), "Chinese skip reason: \(chinese)")

        var result = CopyQSyncRestoreResult(
            entriesWritten: 2,
            filesCreated: 3,
            filesUpdated: 1,
            skipped: plan.skipped
        )
        expect(
            result.summary(language: .english).contains("Wrote 2 entries to the folder"),
            "the English summary: \(result.summary(language: .english))"
        )
        expect(
            result.summary(language: .simplifiedChinese).contains("已将 2 条条目写入文件夹"),
            "the Chinese summary: \(result.summary(language: .simplifiedChinese))"
        )

        result.stoppedAt = .writingGroup(stem: "copyq_20260101000000000")
        expect(
            result.summary(language: .simplifiedChinese).contains("已在写入 copyq_20260101000000000时停止"),
            "the stopped stage is translated: \(result.summary(language: .simplifiedChinese))"
        )

        // The per-group diagnostics are translated by the runtime message
        // translator, which is what the notice banner asks for.
        expectEqual(
            Localization.runtimeMessage(
                CopyQSyncRestoreDiagnostic.couldNotWrite("copyq_1", "disk full"),
                language: .simplifiedChinese
            ),
            "无法写入 copyq_1：disk full"
        )
        expectEqual(
            Localization.runtimeMessage(
                CopyQSyncRestoreDiagnostic.skippedNothingToWrite("copyq_1"),
                language: .simplifiedChinese
            ),
            "已跳过 copyq_1：没有可写入的内容。"
        )
        expectEqual(
            Localization.runtimeMessage(
                CopyQSyncRestoreDiagnostic.skippedEntryGone("copyq_1"),
                language: .simplifiedChinese
            ),
            "已跳过 copyq_1：该条目已不存在。"
        )
        expectEqual(
            Localization.runtimeMessage(
                "Could not write the tab's items back to its sync folder: boom",
                language: .simplifiedChinese
            ),
            "无法将标签页的条目写回其同步文件夹：boom"
        )
        expectEqual(
            Localization.runtimeMessage(
                CopyQSyncResyncError.writeBackPaused("Mac mini").localizedDescription,
                language: .simplifiedChinese
            ),
            "同步已暂停，因此无法写回“Mac mini”。请先恢复同步。"
        )

        // The tab menu command carries both languages.
        expectEqual(
            TabContextMenu.titles(for: .layoutB, language: .english).writeBackToSyncFolder,
            "Write Local Items to Sync Folder\u{2026}"
        )
        expectEqual(
            TabContextMenu.titles(for: .layoutB, language: .simplifiedChinese).writeBackToSyncFolder,
            "把本地内容写回同步文件夹\u{2026}"
        )
    }
}
