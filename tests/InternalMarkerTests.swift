// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tests for treating our own sync bookkeeping flavours as internal.
//
// The leak these cover: a sync item that carries no payload reached the store
// as an entry whose only flavour is `application/x-copyq-itemsync-base-name`,
// and that contentless entry then travelled back out through a `.cpq` archive
// or a sync folder, where CopyQ on the other device materialised it as an
// empty item and synced it back. The fix is that such items are skipped on
// import, never written on export, and removable by an explicit one-time
// cleanup.

import AppKit
import Foundation

func registerInternalMarkerTests() {
    TestRunner.currentSuite = "InternalMarker"

    func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The shape a payload-less sync item leaves behind: one bookkeeping
    /// flavour holding the item's file stem and nothing else.
    func markerOnlyEntry(
        tabID: Int64,
        baseName: String = "copyq_20261025120000001",
        createdAt: TimeInterval = 1_700_000_000
    ) -> ClipboardEntry {
        ClipboardEntry(
            createdAt: Date(timeIntervalSince1970: createdAt),
            tabID: tabID,
            flavours: [Flavour(
                itemIndex: 0,
                type: Fingerprint.syncBaseNameFlavour,
                data: Data(baseName.utf8)
            )]
        )
    }

    func syncItem(_ stem: String, formats: [(String, String?)] = []) -> CopyQSyncItem {
        var map = CopyQDataMap()
        for (format, value) in formats {
            map.set(format, value.map { Data($0.utf8) })
        }
        return CopyQSyncItem(baseName: stem, data: map)
    }

    // MARK: - Export

    TestRunner.add("archive export leaves out marker-only entries and their flavour") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var tab = try store.ensureDefaultTab()
            tab.name = "Fedora"
            try store.updateTab(tab)

            let synced = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                tabID: tab.id,
                flavours: [
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("copyq_20261025120000001".utf8)),
                    Fixtures.text("synced content"),
                ]
            ))
            let markerOnly = try store.insert(markerOnlyEntry(tabID: tab.id, baseName: "copyq_20261025120000002"))

            let directory = try temporaryDirectory("internal-marker-export")
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("backup.cpq")

            let report = try CopyQSyncBridge.exportArchive(
                toPath: archiveURL.path,
                scope: .tab(tab.id),
                in: store
            )
            expectEqual(report.itemCount, 1, "only the entry with a payload is exported")

            let archive = try CopyQArchive.read(atPath: archiveURL.path)
            let items = try unwrap(archive.tabItems["Fedora"])
            expectEqual(items.count, 1, "the marker-only entry is not written as an empty item")
            let exported = try unwrap(items.first)
            expectEqual(
                exported.data.formats.sorted(),
                ["text/plain"],
                "the exported flavour list is the payload only: \(exported.data.formats)"
            )
            expect(
                !exported.data.formats.contains { Fingerprint.isBookkeepingFlavour($0) },
                "no internal bookkeeping flavour reaches the archive"
            )

            // The stored entry still keeps the marker: it is the sync identity.
            let stored = try unwrap(store.entry(id: synced.id))
            expect(
                stored.flavours.contains { $0.type == Fingerprint.syncBaseNameFlavour },
                "the local store keeps the bookkeeping flavour"
            )
            expectNotNil(try store.entry(id: markerOnly.id), "export never deletes a stored entry")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("dry-run sync export writes nothing for a marker-only entry") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.ensureDefaultTab()
            let directory = try temporaryDirectory("internal-marker-dry-run")
            defer { try? FileManager.default.removeItem(at: directory) }

            let entries = [
                ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    tabID: tab.id,
                    flavours: [Fixtures.text("kept content")]
                ),
                markerOnlyEntry(tabID: tab.id, createdAt: 1_700_000_001),
            ]
            let files = try CopyQSyncBridge.dryRunExport(
                entries: entries,
                into: directory.path,
                in: store
            )
            expectEqual(files.count, 1, "only the entry with a payload produces files: \(files)")
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            expectEqual(remaining.count, 1, "no empty _copyq.dat is left behind")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("write-back writes nothing for a marker-only entry") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let directory = try temporaryDirectory("internal-marker-write-back")
            defer { try? FileManager.default.removeItem(at: directory) }

            let tab = try store.insertTab(ClipboardTab(
                name: "WriteBack",
                syncFolder: directory.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let log = try CopyQSyncWriter().writeEntry(
                markerOnlyEntry(tabID: tab.id),
                in: store,
                reason: "capture"
            )
            expectNil(log, "a contentless entry is not a write-back candidate")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            expectEqual(files, [], "the sync folder stays empty")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    // MARK: - Import

    TestRunner.add("sync folder import skips marker-only items and keeps the rest") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let directory = try temporaryDirectory("internal-marker-folder")
            defer { try? FileManager.default.removeItem(at: directory) }

            let tab = try store.insertTab(ClipboardTab(
                name: "Fedora",
                syncFolder: directory.path
            ))

            // A real item with content, written the way CopyQ writes it.
            try CopyQSyncFolder.write(
                syncItem("copyq_20261025120000001", formats: [(CopyQFormat.text, "real content")]),
                into: directory.path
            )
            // An item with no flavours at all: what the other side's plugin
            // materialises for an entry that held nothing.
            try CopyQSyncFolder.write(
                CopyQSyncItem(baseName: "copyq_20261025120000002"),
                into: directory.path
            )
            // An item whose only flavour is our own bookkeeping marker.
            var markerMap = CopyQDataMap()
            markerMap.set(Fingerprint.syncBaseNameFlavour, Data("copyq_20261025120000003".utf8))
            try CopyQItemData.encode(markerMap).write(
                to: directory.appendingPathComponent("copyq_20261025120000003\(CopyQFormat.dataFileSuffix)")
            )

            let report = try CopyQSyncBridge.importSyncFolder(
                atPath: directory.path,
                intoTabID: tab.id,
                in: store
            )
            expectEqual(report.importedCount, 1, "only the item with content is imported")
            expectEqual(report.skippedInternalCount, 2, "both marker-only items are reported as skipped")
            expectEqual(report.failedCount, 0, "a marker-only item is not a failure")
            expectEqual(try store.count(tabID: tab.id), 1, "no contentless entry is stored")

            let imported = try unwrap(try store.recentEntries(tabID: tab.id).first)
            expectEqual(
                FlavourDecoder.plainText(from: imported.flavours),
                "real content",
                "the real item keeps its text"
            )
            expect(
                imported.flavours.contains { $0.type == Fingerprint.syncBaseNameFlavour },
                "the real item keeps its sync identity"
            )

            // A second scan stays quiet about the same items.
            let second = try CopyQSyncBridge.importSyncFolder(
                atPath: directory.path,
                intoTabID: tab.id,
                in: store
            )
            expectEqual(second.skippedInternalCount, 2, "repeated scans keep skipping them")
            expectEqual(second.importedCount, 0, "and import nothing new")
            expectEqual(try store.count(tabID: tab.id), 1, "the store still holds one entry")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("archive import skips marker-only items and keeps the rest") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let directory = try temporaryDirectory("internal-marker-archive")
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("incoming.cpq")

            let writer = try CopyQArchiveWriter(destinationURL: archiveURL, tabs: ["Fedora"])
            try writer.beginTab("Fedora")
            try writer.append(syncItem("copyq_20261025120000001", formats: [(CopyQFormat.text, "kept text")]))
            try writer.append(syncItem("copyq_20261025120000002"))
            try writer.append(syncItem(
                "copyq_20261025120000003",
                formats: [(Fingerprint.syncBaseNameFlavour, "copyq_20261025120000003")]
            ))
            try writer.finishTab()
            try writer.finish()

            let report = try CopyQSyncBridge.importArchive(atPath: archiveURL.path, in: store)
            expectEqual(report.importedCount, 1, "only the item with content is imported")
            expectEqual(report.skippedInternalCount, 2, "both marker-only items are skipped")
            expectEqual(try store.count(), 1, "no contentless entry is stored")

            let imported = try unwrap(try store.recentEntries().first)
            expectEqual(FlavourDecoder.plainText(from: imported.flavours), "kept text", "text survives")
            expectEqual(imported.note, "", "no note is invented")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("watcher scan skips marker-only groups and reports them once") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let directory = try temporaryDirectory("internal-marker-watcher")
            defer { try? FileManager.default.removeItem(at: directory) }

            let tab = try store.insertTab(ClipboardTab(
                name: "Fedora",
                syncFolder: directory.path
            ))
            try CopyQSyncFolder.write(
                CopyQSyncItem(baseName: "copyq_20261025120000001"),
                into: directory.path
            )
            try CopyQSyncFolder.write(
                syncItem("copyq_20261025120000002", formats: [(CopyQFormat.text, "watched text")]),
                into: directory.path
            )

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0
            let report = try watcher.scanFolder(
                atPath: directory.path,
                intoTabID: tab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(report.importedCount, 1, "the item with content is imported")
            expectEqual(report.skippedInternalCount, 1, "the empty group is skipped")
            expectEqual(report.failureCount, 0, "skipping is not a failure")
            expectEqual(try store.count(tabID: tab.id), 1, "no contentless entry is stored")
            expect(
                report.summary.contains("internal bookkeeping only"),
                "the scan summary mentions the skipped group: \(report.summary)"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    // MARK: - One-time cleanup

    TestRunner.add("marker cleanup deletes only shell entries and reports counts separately") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let fedora = try store.insertTab(ClipboardTab(name: "Fedora"))
            let stars = try store.insertTab(ClipboardTab(name: "Stars"))

            let fedoraSingleMarkers = [
                try store.insert(markerOnlyEntry(tabID: fedora.id, baseName: "copyq_20261025120000001")),
                try store.insert(markerOnlyEntry(tabID: fedora.id, baseName: "copyq_20261025120000002")),
            ]
            let starsSingleMarker = try store.insert(
                markerOnlyEntry(tabID: stars.id, baseName: "copyq_20261025120000003")
            )
            let starsPrivateSingleMarker = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_050),
                tabID: stars.id,
                flavours: [Flavour(
                    itemIndex: 0,
                    type: "application/x-copyq-private-tag",
                    data: Data("private".utf8)
                )]
            ))

            let fedoraZeroFlavour = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_060),
                tabID: fedora.id,
                flavours: []
            ))
            let starsZeroFlavour = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_070),
                tabID: stars.id,
                flavours: []
            ))

            let fedoraMultiMarker = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_080),
                tabID: fedora.id,
                flavours: [
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("copyq_20261025120000010".utf8)),
                    Flavour(itemIndex: 0, type: "application/x-copyq-private-tag", data: Data("tag".utf8)),
                ]
            ))
            let starsMultiMarker = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_090),
                tabID: stars.id,
                flavours: [
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("copyq_20261025120000011".utf8)),
                    Flavour(itemIndex: 0, type: "application/x-copyq-itemsync-item-group", data: Data("grp".utf8)),
                ]
            ))

            let markerWithText = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                tabID: fedora.id,
                flavours: [
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("copyq_20261025120000004".utf8)),
                    Fixtures.text("content that stays"),
                ]
            ))
            let notedSingleMarker = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_200),
                tabID: fedora.id,
                note: "keep me",
                flavours: markerOnlyEntry(tabID: fedora.id).flavours
            ))
            let pinnedSingleMarker = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_300),
                pinned: true,
                tabID: fedora.id,
                flavours: markerOnlyEntry(tabID: fedora.id).flavours
            ))
            let notedZeroFlavour = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_310),
                tabID: fedora.id,
                note: "zero flavour note",
                flavours: []
            ))
            let pinnedZeroFlavour = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_320),
                pinned: true,
                tabID: fedora.id,
                flavours: []
            ))
            let notedMultiMarker = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_330),
                tabID: fedora.id,
                note: "multi marker note",
                flavours: [
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("stem1".utf8)),
                    Flavour(itemIndex: 0, type: "application/x-copyq-private-tag", data: Data("t".utf8)),
                ]
            ))
            let pinnedMultiMarker = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_340),
                pinned: true,
                tabID: fedora.id,
                flavours: [
                    Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("stem2".utf8)),
                    Flavour(itemIndex: 0, type: "application/x-copyq-private-tag", data: Data("t".utf8)),
                ]
            ))
            let plain = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_400),
                tabID: fedora.id,
                flavours: [Fixtures.text("plain content")]
            ))

            let report = try InternalMarkerCleanup.removeMarkerOnlyEntries(in: store)
            expectEqual(report.deletedCount, 8, "total deleted shell entries")
            expectEqual(report.singleMarkerCount, 4, "total single marker entries")
            expectEqual(report.otherPayloadlessCount, 4, "total other payload-less entries")

            let fedoraTabReport = try unwrap(report.tabs.first { $0.tabName == "Fedora" })
            expectEqual(fedoraTabReport.deletedCount, 4, "Fedora deleted count")
            expectEqual(fedoraTabReport.singleMarkerCount, 2, "Fedora single marker count")
            expectEqual(fedoraTabReport.otherPayloadlessCount, 2, "Fedora other payload-less count")

            let starsTabReport = try unwrap(report.tabs.first { $0.tabName == "Stars" })
            expectEqual(starsTabReport.deletedCount, 4, "Stars deleted count")
            expectEqual(starsTabReport.singleMarkerCount, 2, "Stars single marker count")
            expectEqual(starsTabReport.otherPayloadlessCount, 2, "Stars other payload-less count")

            expect(
                report.summary.contains("Fedora: 4 (2 single-marker, 2 other payload-less)"),
                "summary reports Fedora breakdown: \(report.summary)"
            )
            expect(
                report.summary.contains("Stars: 4 (2 single-marker, 2 other payload-less)"),
                "summary reports Stars breakdown: \(report.summary)"
            )
            expect(
                report.summary.contains("Total: 8 entries deleted (4 single-marker, 4 other payload-less)."),
                "summary reports total breakdown: \(report.summary)"
            )

            let allDeleted = fedoraSingleMarkers + [starsSingleMarker, starsPrivateSingleMarker, fedoraZeroFlavour, starsZeroFlavour, fedoraMultiMarker, starsMultiMarker]
            for deleted in allDeleted {
                expectNil(try store.entry(id: deleted.id), "candidate entry \(deleted.id) was deleted")
            }

            expectNotNil(try store.entry(id: markerWithText.id), "marker next to text was preserved")
            expectNotNil(try store.entry(id: notedSingleMarker.id), "noted single marker was preserved")
            expectNotNil(try store.entry(id: pinnedSingleMarker.id), "pinned single marker was preserved")
            expectNotNil(try store.entry(id: notedZeroFlavour.id), "noted zero flavour was preserved")
            expectNotNil(try store.entry(id: pinnedZeroFlavour.id), "pinned zero flavour was preserved")
            expectNotNil(try store.entry(id: notedMultiMarker.id), "noted multi marker was preserved")
            expectNotNil(try store.entry(id: pinnedMultiMarker.id), "pinned multi marker was preserved")
            expectNotNil(try store.entry(id: plain.id), "plain entry was preserved")

            let second = try InternalMarkerCleanup.removeMarkerOnlyEntries(in: store)
            expectEqual(second.deletedCount, 0, "the sweep is idempotent")
            expectEqual(second.singleMarkerCount, 0)
            expectEqual(second.otherPayloadlessCount, 0)
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("candidateReport inspects without mutating the store") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try store.ensureDefaultTab()
            _ = try store.insert(markerOnlyEntry(tabID: tab.id, baseName: "copyq_stem1"))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1_700_000_010),
                tabID: tab.id,
                flavours: []
            ))

            let initialCount = try store.count()
            let report = try InternalMarkerCleanup.candidateReport(in: store)
            expectEqual(report.deletedCount, 2)
            expectEqual(report.singleMarkerCount, 1)
            expectEqual(report.otherPayloadlessCount, 1)
            expectEqual(try store.count(), initialCount, "store is unchanged by candidateReport")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("GUI menu action confirms before deleting and updates notice") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let tab = try store.ensureDefaultTab()
                let single = try store.insert(markerOnlyEntry(tabID: tab.id, baseName: "copyq_gui_1"))
                let zero = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_020),
                    tabID: tab.id,
                    flavours: []
                ))

                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history)
                model.bootstrap()

                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})
                let menu = MainMenuBuilder.build(actions: actions)
                let itemSubmenu = try unwrap(menu.items.first { $0.title == "Item" }?.submenu)
                let menuItem = try unwrap(itemSubmenu.items.first { $0.action == #selector(AppActions.removeInternalMarkerEntries(_:)) })
                expectEqual(menuItem.title, "Remove Internal-Marker Entries\u{2026}")

                // 1. Cancellation leaves entries in store
                actions.alertPresenter = { _ in .alertSecondButtonReturn }
                actions.removeInternalMarkerEntries(nil)

                expectNotNil(try store.entry(id: single.id), "single marker entry untouched on cancel")
                expectNotNil(try store.entry(id: zero.id), "zero flavour entry untouched on cancel")

                // 2. Confirmation checks dialog wording and performs cleanup
                var dialogMessage = ""
                var dialogInfo = ""
                actions.alertPresenter = { alert in
                    dialogMessage = alert.messageText
                    dialogInfo = alert.informativeText
                    return .alertFirstButtonReturn
                }
                actions.removeInternalMarkerEntries(nil)

                expectEqual(dialogMessage, "Remove Internal-Marker Entries")
                expect(
                    dialogInfo.contains("deletes shell entries that contain no real content"),
                    "dialog states purpose: \(dialogInfo)"
                )
                expect(
                    dialogInfo.contains("Total: 2."),
                    "dialog includes total count: \(dialogInfo)"
                )
                expect(
                    dialogInfo.contains("Single-marker shells: 1."),
                    "dialog includes single-marker count: \(dialogInfo)"
                )
                expect(
                    dialogInfo.contains("Other payload-less entries: 1."),
                    "dialog includes other payload-less count: \(dialogInfo)"
                )

                expectNil(try store.entry(id: single.id), "single marker entry deleted after confirmation")
                expectNil(try store.entry(id: zero.id), "zero flavour entry deleted after confirmation")
                let notice = try unwrap(model.notice)
                expect(
                    notice.contains("Total: 2 entries deleted (1 single-marker, 1 other payload-less)."),
                    "notice reports cleanup summary: \(notice)"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("shell cleanup never runs automatically during normal lifecycle operations") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let tab = try store.ensureDefaultTab()
                let shell1 = try store.insert(markerOnlyEntry(tabID: tab.id, baseName: "copyq_auto_1"))
                let shell2 = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 1_700_000_030),
                    tabID: tab.id,
                    flavours: []
                ))

                let history = ClipboardHistory(store: store)
                let model = AppModel(history: history)
                model.bootstrap()
                model.reload()

                expectNotNil(try store.entry(id: shell1.id), "entry survived app model bootstrap")
                expectNotNil(try store.entry(id: shell2.id), "entry survived app model bootstrap")

                _ = try history.record([Fixtures.text("new capture")])
                model.reload()

                expectNotNil(try store.entry(id: shell1.id), "entry survived capture")
                expectNotNil(try store.entry(id: shell2.id), "entry survived capture")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
