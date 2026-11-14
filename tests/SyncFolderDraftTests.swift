// SPDX-License-Identifier: GPL-3.0-or-later
//
// The per-tab Sync folder field commits on every change after a short pause,
// and Import Configured Sync Folders says so when no tab has a folder. The
// view owns the timer and the folder picker; this suite drives the decisions
// behind them and the prompt the menu action shows, so it needs no window
// server. Folders are created in temporary directories only.

import AppKit
import Foundation

@MainActor
private final class SyncFolderImportWindowControllerStub: NSObject, WindowControllerProtocol {
    var isVisible = false
    func show() {}
    func hide() {}
}

func registerSyncFolderDraftTests() {
    TestRunner.currentSuite = "SyncFolderDraft"

    TestRunner.add("a debounced commit stores the trimmed folder for the tab it was typed for") {
        var draft = SyncFolderDraft()
        expectEqual(draft.hasPendingCommit, false, "a fresh draft has nothing pending")

        expect(
            draft.record(tabID: 42, storedFolder: nil, text: "  /tmp/folder\n"),
            "typing a folder schedules a commit"
        )
        expectEqual(draft.hasPendingCommit, true, "the foldered draft is pending")

        expectEqual(
            draft.takeCommit(),
            SyncFolderCommit(tabID: 42, folder: "/tmp/folder"),
            "the commit carries the trimmed folder and the tab"
        )
        expectEqual(draft.hasPendingCommit, false, "taking the commit clears the draft")
        expectNil(draft.takeCommit(), "a second timer fire writes nothing")
    }

    TestRunner.add("a draft that trims to the stored folder schedules no write") {
        var draft = SyncFolderDraft()

        expectEqual(
            draft.record(tabID: 7, storedFolder: "/tmp/folder", text: " /tmp/folder\n"),
            false,
            "surrounding whitespace alone needs no write"
        )
        expectNil(draft.takeCommit(), "nothing is pending for an equal value")

        expectEqual(
            draft.record(tabID: 7, storedFolder: "/tmp/folder", text: "/tmp/folder"),
            false,
            "the exact stored value needs no write"
        )
        expectEqual(
            draft.record(tabID: 7, storedFolder: nil, text: "  \n"),
            false,
            "an empty field on a tab without a folder needs no write"
        )
        expectNil(draft.takeCommit())
    }

    TestRunner.add("clearing the field removes the folder") {
        var draft = SyncFolderDraft()
        expect(
            draft.record(tabID: 9, storedFolder: "/tmp/folder", text: "   "),
            "emptying the field schedules a write"
        )
        expectEqual(
            draft.takeCommit(),
            SyncFolderCommit(tabID: 9, folder: nil),
            "an empty field stores no folder"
        )
    }

    TestRunner.add("the last typed value wins a debounced commit") {
        var draft = SyncFolderDraft()
        expect(draft.record(tabID: 3, storedFolder: nil, text: "/tmp/fi"), "first keystroke")
        expect(
            draft.record(tabID: 3, storedFolder: nil, text: "/tmp/final"),
            "a later keystroke replaces the pending value"
        )
        expectEqual(
            draft.takeCommit(),
            SyncFolderCommit(tabID: 3, folder: "/tmp/final"),
            "only the last typed value is committed"
        )
        expectNil(draft.takeCommit(), "the replaced value is never written")
    }

    TestRunner.add("a commit while the field is focused keeps the text the next keystroke continues") {
        // The reported sequence: type a path containing a space, pause past the
        // debounce inside "Sync ", and keep typing. Echoing the committed,
        // trimmed folder into the focused field would join the next keystroke
        // onto the trimmed stem and silently store the wrong folder.
        var draft = SyncFolderDraft()
        let tabID: Int64 = 21
        var storedFolder: String?
        var typed = ""

        func commitIfPending() {
            guard let commit = draft.takeCommit() else { return }
            storedFolder = commit.folder
        }

        func typeIntoField(_ addition: String) {
            typed += addition
            _ = draft.record(tabID: tabID, storedFolder: storedFolder, text: typed)
        }

        typeIntoField("/tmp/Sync ")
        expectEqual(
            SyncFolderDraft.fieldText(
                storedFolder: storedFolder,
                typed: typed,
                isFocused: true,
                hasPendingCommit: draft.hasPendingCommit
            ),
            "/tmp/Sync ",
            "a scheduled commit keeps the text being typed"
        )
        commitIfPending()
        expectEqual(storedFolder, "/tmp/Sync", "the pause stores the trimmed path so far")

        typed = SyncFolderDraft.fieldText(
            storedFolder: storedFolder,
            typed: typed,
            isFocused: true,
            hasPendingCommit: draft.hasPendingCommit
        )
        expectEqual(typed, "/tmp/Sync ", "the focused field keeps the text being typed")

        typeIntoField("Data")
        commitIfPending()
        expectEqual(
            storedFolder,
            "/tmp/Sync Data",
            "the finished path is stored whole instead of the trimmed stem plus the rest"
        )

        expectEqual(
            SyncFolderDraft.fieldText(
                storedFolder: storedFolder,
                typed: typed,
                isFocused: false,
                hasPendingCommit: draft.hasPendingCommit
            ),
            "/tmp/Sync Data",
            "leaving the field shows the stored folder"
        )
    }

    TestRunner.add("a pending draft commits to the tab it was typed for after the tab switch") {
        var draft = SyncFolderDraft()
        expect(draft.record(tabID: 11, storedFolder: nil, text: "/tmp/one"), "typed into tab one")

        // The selection moves: the view flushes the draft before showing the
        // other tab's folder, so the text lands on the tab that was typed into.
        expectEqual(
            draft.takeCommit(),
            SyncFolderCommit(tabID: 11, folder: "/tmp/one"),
            "the flush stays bound to the first tab"
        )
        expectEqual(
            draft.record(tabID: 12, storedFolder: "/tmp/two", text: "/tmp/two"),
            false,
            "the second tab's stored folder records nothing"
        )
        expectNil(draft.takeCommit(), "the first tab's draft does not fire against the new tab")

        expect(
            draft.record(tabID: 12, storedFolder: "/tmp/two", text: "/tmp/two-b"),
            "typing in the new tab schedules a commit"
        )
        expectEqual(
            draft.takeCommit(),
            SyncFolderCommit(tabID: 12, folder: "/tmp/two-b"),
            "the new tab's draft commits to the new tab"
        )
    }

    TestRunner.currentSuite = "SyncFolderImport"

    TestRunner.add("importConfiguredSyncFolders reports no mapped tabs when none has a sync folder") {
        let store = try ClipboardStore(inMemory: true)
        _ = try store.insertTab(ClipboardTab(name: "Local", syncFolder: nil))
        _ = try store.insertTab(ClipboardTab(name: "Empty", syncFolder: ""))

        let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: store)
        expectEqual(report.mappedTabCount, 0, "the report says no tab had a folder to read")
        expectEqual(report.importedCount, 0, "nothing is imported")
        expectEqual(report.failures, [], "no tab is reported as broken")
    }

    TestRunner.add("importConfiguredSyncFolders counts only tabs with a mapped folder") {
        let store = try ClipboardStore(inMemory: true)
        let tempDir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mappedTab = try store.insertTab(ClipboardTab(name: "Mapped", syncFolder: tempDir.path))
        _ = try store.insertTab(ClipboardTab(name: "Local", syncFolder: nil))

        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("Mapped folder content".utf8))
        let item = CopyQSyncItem(baseName: "copyq_20261105120000001", data: data)
        try CopyQSyncFolder.write(item, into: tempDir.path)

        let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: store)
        expectEqual(report.mappedTabCount, 1, "only the mapped tab had a folder to read")
        expectEqual(report.importedCount, 1)
        expectEqual(try store.count(tabID: mappedTab.id), 1)
    }

    TestRunner.add("a configured import with no mapped folder says so in the banner") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                _ = try history.store.insertTab(ClipboardTab(name: "Local", syncFolder: nil))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })

                var reported: CopyQImportReport?
                model.importConfiguredSyncFolders { reported = $0 }
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline, reported == nil {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                expectEqual(reported?.mappedTabCount, 0, "the import reports that no tab had a folder")
                expectEqual(
                    model.notice,
                    "No tab has a sync folder set.",
                    "the interface says no tab has a folder instead of reporting an empty summary"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the no-mapping prompt is shown only for an import with no mapped folder") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let localTab = try store.insertTab(ClipboardTab(name: "Local", syncFolder: nil))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                let actions = AppActions(
                    model: model,
                    windowController: SyncFolderImportWindowControllerStub(),
                    presentPreferences: {}
                )
                var alerts: [NSAlert] = []
                actions.alertPresenter = { alert in
                    alerts.append(alert)
                    return .alertSecondButtonReturn
                }

                actions.importConfiguredSyncFolders(nil)
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline, alerts.isEmpty {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                expectEqual(alerts.count, 1, "the empty import explains itself with one prompt")
                expectEqual(
                    alerts.first?.messageText,
                    "No tab has a sync folder set",
                    "the prompt names the missing mapping"
                )
                let targetTab = try unwrap(model.selectedTab)
                let deliveredText = alerts.first?.informativeText ?? ""
                expect(
                    deliveredText.contains("\"\(targetTab.name)\""),
                    "the delivered alert names the tab that receives the picked folder"
                )
                expect(
                    deliveredText.contains("imported into that tab"),
                    "the delivered alert says the folder's items are imported into that tab"
                )
                expect(
                    !deliveredText.contains("the selected tab"),
                    "the delivered alert names the tab instead of the vague selected tab"
                )
                expectEqual(
                    model.notice,
                    "No tab has a sync folder set.",
                    "the banner carries the same explanation"
                )

                let tempDir = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: tempDir) }
                var mapped = localTab
                mapped.syncFolder = tempDir.path
                model.updateTab(mapped)

                actions.importConfiguredSyncFolders(nil)
                let mappedDeadline = Date().addingTimeInterval(2)
                while Date() < mappedDeadline,
                      model.notice?.hasPrefix("Sync folders imported:") != true
                {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                expect(
                    model.notice?.hasPrefix("Sync folders imported:") == true,
                    "the mapped import keeps the ordinary summary"
                )
                expectEqual(alerts.count, 1, "a mapped import never shows the no-mapping prompt")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("choosing the empty-import prompt opens a picker that names the target tab") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                let targetTab = try unwrap(model.selectedTab)
                let actions = AppActions(
                    model: model,
                    windowController: SyncFolderImportWindowControllerStub(),
                    presentPreferences: {}
                )
                actions.alertPresenter = { _ in .alertFirstButtonReturn }
                var presentedPanel: NSOpenPanel?
                actions.panelPresenter = { panel, _ in presentedPanel = panel as? NSOpenPanel }

                actions.importConfiguredSyncFolders(nil)
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline, presentedPanel == nil {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                let panel = try unwrap(presentedPanel, "choosing the prompt opens the folder picker")
                expectEqual(
                    panel.message,
                    SyncFolderImportPrompt.noMappedSyncFolder(tabName: targetTab.name).pickerMessage,
                    "the picker shows the prompt's picker message"
                )
                expect(
                    panel.message.contains("\"\(targetTab.name)\""),
                    "the delivered picker names the tab that receives the picked folder"
                )
                expect(
                    panel.message.contains("imported into that tab"),
                    "the delivered picker says the items go into the tab, not into the folder"
                )
                expect(
                    !panel.message.contains("the selected tab"),
                    "the delivered picker names the tab instead of the vague selected tab"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a folder picked from the no-mapping prompt becomes the selected tab's sync folder") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                let selected = try unwrap(model.selectedTab)

                let tempDir = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: tempDir) }

                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("Picked folder content".utf8))
                let item = CopyQSyncItem(baseName: "copyq_20261105120000002", data: data)
                try CopyQSyncFolder.write(item, into: tempDir.path)

                var secondData = CopyQDataMap()
                secondData.set(CopyQFormat.text, Data("Second picked folder content".utf8))
                let secondItem = CopyQSyncItem(baseName: "copyq_20261105120000003", data: secondData)
                try CopyQSyncFolder.write(secondItem, into: tempDir.path)

                var fieldText = SyncFolderDraft.fieldText(
                    storedFolder: selected.syncFolder,
                    typed: "",
                    isFocused: true,
                    hasPendingCommit: false
                )
                expectEqual(fieldText, "", "a focused field with no keystrokes shows the tab's empty folder")

                model.adoptPickedSyncFolder(tempDir, intoTabID: selected.id)

                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline,
                      model.notice?.hasPrefix("Sync folder imported:") != true
                {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                expect(
                    model.notice?.hasPrefix("Sync folder imported:") == true,
                    "the picked folder's items are imported and reported"
                )
                expectEqual(
                    try store.tab(id: selected.id)?.syncFolder,
                    tempDir.path,
                    "the pick becomes the tab's sync folder"
                )
                expectEqual(
                    try CopyQSyncBridge.tabs(forSyncFolder: tempDir.path, in: store).map(\.id),
                    [selected.id],
                    "the picked folder reads as the tab's sync folder"
                )
                expectEqual(try store.tabs().count, 1, "the pick creates no second tab")
                expectEqual(
                    try store.count(tabID: selected.id),
                    2,
                    "each item in the picked folder lands once in that tab"
                )

                let adoptedFolder = try store.tab(id: selected.id)?.syncFolder
                fieldText = SyncFolderDraft.fieldText(
                    storedFolder: adoptedFolder,
                    typed: fieldText,
                    isFocused: true,
                    hasPendingCommit: false
                )
                expectEqual(fieldText, tempDir.path, "the adopted folder appears in the focused field")
                expectEqual(
                    SyncFolderDraft.folder(for: fieldText),
                    adoptedFolder,
                    "the field and the caption below it read the same folder"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a picked folder's import notice follows a language switch made while it runs") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                let selected = try unwrap(model.selectedTab)

                let tempDir = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: tempDir) }

                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("Picked folder content".utf8))
                try CopyQSyncFolder.write(
                    CopyQSyncItem(baseName: "copyq_20261105120000010", data: data),
                    into: tempDir.path
                )

                model.adoptPickedSyncFolder(tempDir, intoTabID: selected.id)
                model.updatePreferences { $0.language = .simplifiedChinese }

                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline,
                      model.notice?.hasPrefix("同步文件夹已导入：") != true
                {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                expect(
                    model.notice?.hasPrefix("同步文件夹已导入：") == true,
                    "the finished notice reads in the language current at completion: \(model.notice ?? "nil")"
                )
                expect(
                    model.notice?.contains("已导入 1 个") == true,
                    "the scan summary reads in the same language: \(model.notice ?? "nil")"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a picked folder never overwrites a mapping made while the prompt was open") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let existingFolder = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: existingFolder) }
                let mapped = try store.insertTab(ClipboardTab(name: "Mapped", syncFolder: existingFolder.path))
                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()

                let pickedFolder = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: pickedFolder) }
                let selected = try unwrap(model.selectedTab)
                model.adoptPickedSyncFolder(pickedFolder, intoTabID: selected.id)

                expectEqual(
                    try store.tab(id: mapped.id)?.syncFolder,
                    existingFolder.path,
                    "the existing mapping is kept"
                )
                expectEqual(
                    try store.tabs().first(where: { $0.id == model.selectedTab?.id })?.syncFolder,
                    nil,
                    "the selected tab gains no second mapping"
                )
                expectNotNil(model.failureNotice, "the refusal is reported instead of overwriting silently")
                expectEqual(try store.tabs().count, 2, "the refusal creates no tab")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a folder picked after the selection moved still goes to the tab the prompt named") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let otherTab = try store.insertTab(ClipboardTab(name: "Archive", syncFolder: nil))
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                let target = try unwrap(model.selectedTab)

                let tempDir = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: tempDir) }

                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("Moved selection content".utf8))
                let item = CopyQSyncItem(baseName: "copyq_20261105120000004", data: data)
                try CopyQSyncFolder.write(item, into: tempDir.path)

                let actions = AppActions(
                    model: model,
                    windowController: SyncFolderImportWindowControllerStub(),
                    presentPreferences: {}
                )
                var capturedAlert: NSAlert?
                actions.alertPresenter = { alert in
                    capturedAlert = alert
                    return .alertFirstButtonReturn
                }
                var completePick: ((URL?) -> Void)?
                actions.panelPresenter = { _, completion in completePick = completion }

                actions.importConfiguredSyncFolders(nil)
                let alertDeadline = Date().addingTimeInterval(2)
                while Date() < alertDeadline, completePick == nil {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                expect(
                    capturedAlert?.informativeText.contains("\"\(target.name)\"") == true,
                    "the prompt names the tab it will map"
                )

                model.selectTab(otherTab.id)
                expectEqual(model.selectedTab?.id, otherTab.id, "the selection moved while the picker was open")

                completePick?(tempDir)
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline,
                      model.notice?.hasPrefix("Sync folder imported:") != true
                {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                expectEqual(
                    try store.tab(id: target.id)?.syncFolder,
                    tempDir.path,
                    "the named tab receives the picked folder"
                )
                expectEqual(
                    try store.tab(id: otherTab.id)?.syncFolder,
                    nil,
                    "the tab selected while the picker was open stays untouched"
                )
                expectEqual(try store.count(tabID: target.id), 1, "the items land in the named tab")
                expectEqual(try store.count(tabID: otherTab.id), 0, "the moved-to tab receives nothing")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("adopting a folder while sync is paused still imports its items once") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                model.setSyncPaused(true)
                let selected = try unwrap(model.selectedTab)

                let tempDir = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: tempDir) }

                var data = CopyQDataMap()
                data.set(CopyQFormat.text, Data("Paused adopt content".utf8))
                let item = CopyQSyncItem(baseName: "copyq_20261105120000005", data: data)
                try CopyQSyncFolder.write(item, into: tempDir.path)

                model.adoptPickedSyncFolder(tempDir, intoTabID: selected.id)

                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline,
                      model.notice?.hasPrefix("Sync folder imported:") != true
                {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                expectEqual(
                    try store.tab(id: selected.id)?.syncFolder,
                    tempDir.path,
                    "the pick maps the tab while sync is paused"
                )
                expectEqual(
                    try store.count(tabID: selected.id),
                    1,
                    "the paused pick still imports each folder item once"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("adopting a folder that already holds several items stores one row per item") {
        // The adoption used to import the picked folder explicitly while the
        // watcher's own reconfigure scan imported the same folder, and the two
        // could both insert the same stem. The watcher's scan is now the only
        // importer, so a folder full of items must land exactly once each, and
        // the banner has to report what that scan actually did.
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()
                let selected = try unwrap(model.selectedTab)

                let tempDir = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: tempDir) }

                let itemCount = 6
                for index in 0..<itemCount {
                    var data = CopyQDataMap()
                    data.set(CopyQFormat.text, Data("Adopted folder item \(index)".utf8))
                    let item = CopyQSyncItem(
                        baseName: String(format: "copyq_2026110512010%04d", index),
                        data: data
                    )
                    try CopyQSyncFolder.write(item, into: tempDir.path)
                }

                model.adoptPickedSyncFolder(tempDir, intoTabID: selected.id)

                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline,
                      model.notice?.hasPrefix("Sync folder imported:") != true
                {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                let notice = model.notice ?? ""
                expect(
                    notice.hasPrefix("Sync folder imported:"),
                    "the banner reports the import the watcher performed, got '\(notice)'"
                )
                expect(
                    notice.contains("\(itemCount) imported"),
                    "the banner reports every item that arrived, got '\(notice)'"
                )
                expectEqual(
                    try store.count(tabID: selected.id),
                    itemCount,
                    "each folder item lands in the tab exactly once"
                )

                // A late watcher scan must not add a second row for a stem the
                // adoption already imported.
                pumpRunLoop(1.5)
                expectEqual(
                    try store.count(tabID: selected.id),
                    itemCount,
                    "no later scan duplicates an item the adoption already imported"
                )
                expectEqual(try store.tabs().count, 1, "the adoption creates no second tab")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("adopting for a tab that no longer exists explains itself and changes nothing") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history, isAccessibilityTrusted: { true })
                model.bootstrap()

                let tempDir = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: tempDir) }

                model.adoptPickedSyncFolder(tempDir, intoTabID: 9_999)

                let failure = model.failureNotice ?? ""
                expect(
                    failure.contains("no longer exists"),
                    "the missing tab is explained, got '\(failure)'"
                )
                pumpRunLoop(0.5)
                expectEqual(
                    try store.tabs().map(\.syncFolder),
                    [nil],
                    "no tab gains the picked folder"
                )
                expectEqual(try store.count(), 0, "nothing is imported")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}

@MainActor
private func pumpRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
