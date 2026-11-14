// Backup export: menu wiring, validation, the save-panel file name, and the
// status-bar wording. The archive bytes and the round trip are covered by the
// CopyQSync suites; this checks the app surfaces that reach them.

import AppKit
import Foundation

func registerExportBackupTests() {
    TestRunner.currentSuite = "ExportBackup"

    TestRunner.add("File menu offers export backup and export current tab") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})

                let menu = MainMenuBuilder.build(actions: actions)
                let fileMenu = try unwrap(menu.items.first { $0.title == "File" }?.submenu)
                let titles = fileMenu.items.map(\.title)

                let exportBackup = try unwrap(fileMenu.items.first { $0.title == "Export Backup\u{2026}" })
                expectEqual(
                    exportBackup.action,
                    #selector(AppActions.exportBackup(_:)),
                    "Export Backup sends its action"
                )
                expect(exportBackup.target === actions, "Export Backup targets the actions object")
                expectEqual(exportBackup.keyEquivalent, "E", "Export Backup keeps a menu shortcut")
                expectEqual(
                    exportBackup.keyEquivalentModifierMask,
                    [.command, .shift],
                    "Export Backup shortcut is Command-Shift-E"
                )

                let exportTab = try unwrap(fileMenu.items.first { $0.title == "Export Current Tab\u{2026}" })
                expectEqual(
                    exportTab.action,
                    #selector(AppActions.exportCurrentTab(_:)),
                    "Export Current Tab sends its action"
                )
                expect(exportTab.target === actions, "Export Current Tab targets the actions object")

                expect(
                    titles.firstIndex(of: "Export Backup\u{2026}").map {
                        $0 < (titles.firstIndex(of: "Pause Sync") ?? Int.max)
                    } ?? false,
                    "export commands sit above the sync controls"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("export commands are enabled while no export is running") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})

                let exportBackup = NSMenuItem(
                    title: "Export Backup\u{2026}",
                    action: #selector(AppActions.exportBackup(_:)),
                    keyEquivalent: ""
                )
                expect(actions.validateMenuItem(exportBackup), "Export Backup is enabled while idle")

                let exportTab = NSMenuItem(
                    title: "Export Current Tab\u{2026}",
                    action: #selector(AppActions.exportCurrentTab(_:)),
                    keyEquivalent: ""
                )
                expect(actions.validateMenuItem(exportTab), "Export Current Tab is enabled with a selected tab")
                expect(!model.isExporting, "no export is running before one is started")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("save panel file name names the backup and stays a valid file name") {
        let now = Date(timeIntervalSince1970: 1_792_981_216)
        let allTabs = BackupFileName.default(for: nil, now: now)
        expect(allTabs.hasPrefix("CopyQmac Backup "), "all-tab backup is named CopyQmac Backup")
        expect(allTabs.hasSuffix(".cpq"), "backup file name ends in .cpq")

        let tab = ClipboardTab(name: "Work/Notes: 2026")
        let oneTab = BackupFileName.default(for: tab, now: now)
        expect(oneTab.hasPrefix("Work-Notes- 2026 "), "single-tab backup is named after the tab, without path separators")
        expect(oneTab.hasSuffix(".cpq"), "single-tab backup file name ends in .cpq")

        expect(
            BackupFileName.default(for: ClipboardTab(name: "  "), now: now).hasPrefix("Tab "),
            "an empty tab name falls back to Tab"
        )
    }

    TestRunner.add("model export writes the backup off the main thread and reports it") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let tab = try history.defaultTab()
                try history.store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    tabID: tab.id,
                    note: "backup note",
                    flavours: [Fixtures.text("backup me")]
                ))

                let directory = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("backup.cpq")

                model.exportBackup(to: url, tabID: nil)
                expect(model.isExporting, "export starts with a progress line")
                let deadline = Date().addingTimeInterval(10)
                while model.isExporting && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }

                expect(!model.isExporting, "finished export clears the progress line")
                expect(
                    model.notice?.hasPrefix("Backup written") == true,
                    "finished export announces the result"
                )
                expect(FileManager.default.fileExists(atPath: url.path), "export wrote the archive")

                let archive = try CopyQArchive.read(atPath: url.path)
                expectEqual(archive.tabNames, [tab.name], "archive keeps the tab")
                expectEqual(archive.items.count, 1, "archive holds the history")
                let exportedItem = try unwrap(archive.items.first)
                expectEqual(
                    exportedItem.data.bytes(CopyQFormat.text),
                    Data("backup me".utf8),
                    "archive writes the entry text under text/plain byte for byte"
                )
                expect(
                    !exportedItem.data.contains(PasteboardTypes.utf8Text),
                    "archive does not leak the macOS text type"
                )
                expectEqual(exportedItem.notes, "backup note", "archive holds the entry note")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("model export notice reports disambiguated duplicate tab names") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                var first = try history.defaultTab()
                first.name = "Work"
                try history.store.updateTab(first)
                _ = try history.store.insertTab(ClipboardTab(name: "Work"))

                let directory = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("duplicate-tabs.cpq")

                model.exportBackup(to: url, tabID: nil)
                let deadline = Date().addingTimeInterval(10)
                while model.isExporting && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }

                expect(!model.isExporting, "finished export clears the progress line")
                expect(
                    model.notice?.contains("duplicate tab name renamed") == true,
                    "notice reports the disambiguated tab name"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("model export notice writes the backup size in the selected language") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let tab = try history.defaultTab()
                try history.store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    tabID: tab.id,
                    flavours: [Fixtures.text("localized size")]
                ))
                model.updatePreferences { $0.language = .simplifiedChinese }

                let directory = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("localized-size.cpq")

                model.exportBackup(to: url, tabID: nil)
                let deadline = Date().addingTimeInterval(10)
                while model.isExporting && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }

                expect(!model.isExporting, "finished export clears the progress line")
                let archiveSize = try unwrap(
                    FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
                )
                let localizedSize = Localization.byteCount(archiveSize, language: .simplifiedChinese)
                let notice = model.notice ?? ""
                expect(
                    notice.hasPrefix("备份已写入："),
                    "the finished backup notice speaks the selected language: \(notice)"
                )
                expect(
                    notice.contains(localizedSize),
                    "the notice's size clause follows the language (\(localizedSize)): \(notice)"
                )
                expect(
                    !notice.contains(" bytes"),
                    "the notice keeps no English size unit in Chinese: \(notice)"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("export status line names the tab and counts items") {
        let single = CopyQSyncBridge.ExportProgress(
            tabName: "Clipboard",
            tabIndex: 1,
            tabCount: 1,
            exportedItems: 200,
            totalItems: 1200
        )
        let text = BackupExportStatus.text(for: single)
        expect(text.contains("\u{201C}Clipboard\u{201D}"), "status names the tab")
        expect(text.contains("of"), "status shows progress against the total")
        expect(!text.contains("tab 1 of 1"), "single-tab status does not repeat the tab count")

        let multi = CopyQSyncBridge.ExportProgress(
            tabName: "Fedora",
            tabIndex: 2,
            tabCount: 3,
            exportedItems: 0,
            totalItems: 10
        )
        let multiText = BackupExportStatus.text(for: multi)
        expect(multiText.contains("tab 2 of 3"), "multi-tab status shows the tab index")
        expect(multiText.contains("\u{201C}Fedora\u{201D}"), "multi-tab status names the tab")
    }
}
