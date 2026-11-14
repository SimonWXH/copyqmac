// Multi-selection, bulk ordering, and bulk tab moves.
//
// The selection maths and the reorder policy live in the core, so these tests
// drive them directly. The model and the sync relocation are exercised through
// the same entry points the UI uses, with temporary folders standing in for
// the real sync folders.

import AppKit
import Foundation

func registerMultiSelectionTests() {
    TestRunner.currentSuite = "MultiSelection"

    // MARK: - Selection maths

    TestRunner.add("selection toggles, extends, selects all, and clears") {
        let order: [Int64] = [1, 2, 3, 4, 5]
        var selection = ItemSelection()

        selection.selectSingle(3)
        expectEqual(selection.ids, [3])
        expectEqual(selection.focus, 3)
        expectEqual(selection.anchor, 3)

        selection.toggle(5, in: order)
        expectEqual(selection.ids, [3, 5], "Command-click adds to the selection")
        expectEqual(selection.focus, 5, "the new entry becomes the focus")
        expectEqual(selection.anchor, 5)

        selection.toggle(3, in: order)
        expectEqual(selection.ids, [5], "Command-click back removes the entry")
        expectEqual(selection.focus, 5, "the remaining entry takes over the focus")

        selection.selectSingle(2)
        selection.extend(to: 4, in: order)
        expectEqual(selection.ids, [2, 3, 4], "Shift-click selects the contiguous range")
        expectEqual(selection.focus, 4)
        expectEqual(selection.anchor, 2, "the anchor stays where the range started")

        selection.extend(to: 5, in: order)
        expectEqual(selection.ids, [2, 3, 4, 5], "the range can be extended again")
        selection.extend(to: 1, in: order)
        expectEqual(selection.ids, [1, 2], "extending back past the anchor keeps the anchor")

        selection.selectAll(in: order)
        expectEqual(selection.ids, Set(order), "Select All covers every listed entry")
        expectEqual(selection.focus, 1, "Select All keeps the existing focus")

        selection.clear()
        expect(selection.isEmpty, "Clear drops every selected identity")
        expectNil(selection.focus)
        expectNil(selection.anchor)
    }

    TestRunner.add("selection focus movement takes the selection with it unless extending") {
        let order: [Int64] = [1, 2, 3, 4, 5]
        var selection = ItemSelection()

        selection.moveFocus(by: 1, extending: false, in: order)
        expectEqual(selection.ids, [1], "down from no selection starts at the first row")
        selection.moveFocus(by: 1, extending: false, in: order)
        expectEqual(selection.ids, [2])
        selection.moveFocus(by: 2, extending: true, in: order)
        expectEqual(selection.ids, [2, 3, 4], "Shift-arrow extends from the anchor")
        expectEqual(selection.focus, 4)
        selection.moveFocus(by: -1, extending: true, in: order)
        expectEqual(selection.ids, [2, 3], "extending back shrinks the range")
        selection.moveFocus(by: -9, extending: true, in: order)
        expectEqual(selection.ids, [1, 2], "the range clamps at the first row")
        expectEqual(selection.focus, 1)

        selection.moveFocus(by: -1, extending: false, in: order)
        expectEqual(selection.ids, [1], "a plain arrow collapses to a single selection")
        selection.moveFocus(by: 9, extending: false, in: order)
        expectEqual(selection.ids, [5], "the focus clamps at the last row")
    }

    TestRunner.add("selection reconciles with a refreshed list") {
        let order: [Int64] = [1, 2, 3, 4, 5]
        var selection = ItemSelection()
        selection.selectSingle(3)
        selection.toggle(5, in: order)

        selection.reconcile(with: order)
        expectEqual(selection.ids, [3, 5], "an unchanged list keeps the whole selection")
        expectEqual(selection.focus, 5)

        selection.reconcile(with: [1, 2, 3])
        expectEqual(selection.ids, [3], "identities that disappeared drop out")
        expectEqual(selection.focus, 3, "the focus falls back to a surviving entry")

        selection.reconcile(with: [1, 2])
        expect(selection.isEmpty, "a refresh with no survivors clears the selection")
        expectNil(selection.focus)
    }

    // MARK: - Reorder

    TestRunner.add("reorder moves a multi-selection and preserves its relative order") {
        let order: [Int64] = [10, 9, 8, 7, 6, 5]
        let selection: Set<Int64> = [9, 7]

        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: [:], selection: selection, command: .up),
            [9, 10, 7, 8, 6, 5],
            "each selected entry moves up one position"
        )
        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: [:], selection: selection, command: .down),
            [10, 8, 9, 6, 7, 5],
            "each selected entry moves down one position"
        )
        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: [:], selection: selection, command: .top),
            [9, 7, 10, 8, 6, 5],
            "Move to Top keeps 9 before 7"
        )
        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: [:], selection: selection, command: .bottom),
            [10, 8, 6, 5, 9, 7],
            "Move to Bottom keeps 9 before 7"
        )
        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: [:], selection: [10], command: .up),
            order,
            "an entry already at the top does not move"
        )
        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: [:], selection: [5], command: .down),
            order,
            "an entry already at the bottom does not move"
        )
    }

    TestRunner.add("reorder keeps pinned entries above unpinned entries") {
        let order: [Int64] = [100, 99, 98, 97]
        let pinned: [Int64: Bool] = [100: true, 99: true, 98: false, 97: false]
        let selection: Set<Int64> = [100, 98]

        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: pinned, selection: selection, command: .top),
            order,
            "both selected entries are already at the top of their pin group"
        )
        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: pinned, selection: selection, command: .down),
            [99, 100, 97, 98],
            "each entry moves down inside its own block"
        )
        expectEqual(
            ItemReorderPolicy.reorder(order: order, pinned: pinned, selection: selection, command: .up),
            order,
            "an unpinned entry cannot jump above the pinned block"
        )
    }

    TestRunner.add("the model persists a reorder without rewriting creation times") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()

                var ids: [Int64] = []
                var dates: [Int64: Date] = [:]
                for index in 0..<5 {
                    let date = Date(timeIntervalSince1970: Double(1000 + index))
                    guard case .inserted(let entry) = try history.record(
                        [Fixtures.text("entry \(index)")],
                        at: date
                    ) else {
                        TestRunner.fail("fixture entry \(index) was not inserted")
                        return
                    }
                    ids.append(entry.id)
                    dates[entry.id] = date
                }
                model.reload()
                // Newest first: 4, 3, 2, 1, 0.
                expectEqual(model.entries.map(\.id), Array(ids.reversed()), "fixture starts newest first")

                model.select(ids[3])
                model.toggleSelection(ids[1])
                expectEqual(model.selectedEntryCount, 2, "two entries are selected")

                model.reorderSelected(.up)
                let expectedUp = [ids[3], ids[4], ids[1], ids[2], ids[0]]
                expectEqual(model.entries.map(\.id), expectedUp, "each selected row moved up one slot")
                expectEqual(model.selectedEntryCount, 2, "the selection survives the reload")

                for (id, date) in dates {
                    let stored = try unwrap(try history.store.entry(id: id), "stored entry \(id)")
                    expectEqual(
                        stored.createdAt,
                        date,
                        "reordering must not rewrite an entry's creation time"
                    )
                }

                model.reorderSelected(.bottom)
                expectEqual(
                    model.entries.map(\.id),
                    [ids[4], ids[2], ids[0], ids[3], ids[1]],
                    "Move to Bottom preserves the selected relative order"
                )

                guard case .inserted(let newest) = try history.record(
                    [Fixtures.text("captured after reorder")],
                    at: Date(timeIntervalSince1970: 5000)
                ) else {
                    TestRunner.fail("the post-reorder capture was not inserted")
                    return
                }
                model.reload()
                expectEqual(
                    model.entries.first?.id,
                    newest.id,
                    "a new capture still lands above a reordered block"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a new capture lands above entries moved into another tab") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let destinationID = model.selectedTabID
                _ = try history.record(
                    [Fixtures.text("destination")],
                    at: Date(timeIntervalSince1970: 1000)
                )

                guard let source = model.addTab(named: "Source") else {
                    TestRunner.fail("source tab was not created")
                    return
                }
                var moved: [Int64] = []
                for index in 0..<3 {
                    guard case .inserted(let entry) = try history.record(
                        [Fixtures.text("moved \(index)")],
                        into: source,
                        at: Date(timeIntervalSince1970: Double(500 + index))
                    ) else {
                        TestRunner.fail("moved entry \(index) was not inserted")
                        return
                    }
                    moved.append(entry.id)
                }

                model.reload()
                model.selectAllEntries()
                expectEqual(model.selectedEntryCount, 3, "every source entry is selected")
                model.moveSelection(toTabID: destinationID)
                model.selectTab(destinationID)
                expectEqual(
                    Array(model.entries.map(\.id).prefix(3)),
                    Array(moved.reversed()),
                    "the moved entries sit at the top of the destination"
                )

                guard case .inserted(let newest) = try history.record(
                    [Fixtures.text("captured after move")],
                    at: Date(timeIntervalSince1970: 1001)
                ) else {
                    TestRunner.fail("the post-move capture was not inserted")
                    return
                }
                model.reload()
                expectEqual(
                    model.entries.first?.id,
                    newest.id,
                    "a new capture still lands above the moved block"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Model selection lifecycle

    TestRunner.add("selection survives a reload and is cleared when the tab changes") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let firstTabID = model.selectedTabID
                for index in 0..<3 {
                    _ = try history.record(
                        [Fixtures.text("survive \(index)")],
                        at: Date(timeIntervalSince1970: Double(index))
                    )
                }
                model.reload()

                model.selectAllEntries()
                expectEqual(model.selectedEntryCount, 3, "Select All covers the visible tab")
                model.reload()
                expectEqual(model.selectedEntryCount, 3, "a refresh with the same identities keeps the selection")

                guard let second = model.addTab(named: "Second") else {
                    TestRunner.fail("second tab was not created")
                    return
                }
                model.selectAllEntries()
                expectEqual(model.selectedEntryCount, 0, "the new tab has nothing to select")

                model.selectTab(firstTabID)
                expectEqual(model.selectedEntryCount, 1, "returning to a tab starts with a single selection")
                expectEqual(model.selectedEntryID, model.entries.first?.id, "the first entry is focused")

                model.selectTab(second.id)
                expectEqual(model.selectedEntryCount, 0, "switching away clears the selection")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a capture takes over a single selection but not a multi-selection") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                var ids: [Int64] = []
                for index in 0..<3 {
                    guard case .inserted(let entry) = try history.record(
                        [Fixtures.text("capture selection \(index)")],
                        at: Date(timeIntervalSince1970: Double(index))
                    ) else {
                        TestRunner.fail("fixture entry \(index) was not inserted")
                        return
                    }
                    ids.append(entry.id)
                }
                model.reload()

                model.select(ids[0])
                guard case .inserted(let firstCapture) = try history.record(
                    [Fixtures.text("fresh single capture")],
                    at: Date(timeIntervalSince1970: 100)
                ) else {
                    TestRunner.fail("first capture was not inserted")
                    return
                }
                model.reload(capturedEntryID: firstCapture.id)
                expectEqual(model.selectedEntryID, firstCapture.id, "a capture replaces a single selection")
                expectEqual(model.selectedEntryCount, 1)

                model.select(ids[0])
                model.toggleSelection(ids[1])
                expectEqual(model.selectedEntryCount, 2)
                guard case .inserted(let secondCapture) = try history.record(
                    [Fixtures.text("fresh multi capture")],
                    at: Date(timeIntervalSince1970: 200)
                ) else {
                    TestRunner.fail("second capture was not inserted")
                    return
                }
                model.reload(capturedEntryID: secondCapture.id)
                expectEqual(model.selectedEntryIDs, [ids[0], ids[1]], "a multi-selection stays put")
                expectEqual(model.selectedEntryID, ids[1], "the focused entry is unchanged")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the model selects a range from the keyboard anchor") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                var ids: [Int64] = []
                for index in 0..<5 {
                    guard case .inserted(let entry) = try history.record(
                        [Fixtures.text("range \(index)")],
                        at: Date(timeIntervalSince1970: Double(index))
                    ) else {
                        TestRunner.fail("fixture entry \(index) was not inserted")
                        return
                    }
                    ids.append(entry.id)
                }
                model.reload()

                model.select(ids[3])
                model.moveSelection(by: 2, extending: true)
                expectEqual(model.selectedEntryIDs, [ids[3], ids[2], ids[1]], "Shift-arrow extends upward")
                model.moveSelection(by: -1, extending: true)
                expectEqual(model.selectedEntryIDs, [ids[3], ids[2]], "extending back shrinks the range")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a mouse selection reports the row under the pointer after AppKit clears clickedRow") {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)

            func row(id: Int64) -> EntryRow {
                EntryRow(
                    id: id,
                    number: Int(id),
                    kind: .text,
                    primaryText: "entry \(id)",
                    richText: nil,
                    fileNames: [],
                    fileCount: 0,
                    relativeTime: "now",
                    pinned: false,
                    hasNote: false,
                    icon: nil
                )
            }

            let rows = (1...5).map { row(id: Int64($0)) }
            var changes: [ListSelectionChange] = []
            let list = EntryListView(
                rows: rows,
                rowsRevision: 1,
                selection: SelectionState(),
                singleClickActivates: false,
                actions: .none,
                contextActions: .none,
                onSelectionChange: { changes.append($0) },
                onActivate: { _ in },
                onCopy: { _ in },
                onFocusChange: { _ in },
                onRowBecameVisible: { _ in },
                banner: nil,
                onBannerAction: {},
                onBannerDismiss: {}
            )
            let coordinator = list.makeCoordinator()
            let table = EntryTableView()
            table.headerView = nil
            table.addTableColumn(NSTableColumn(identifier: EntryListView.Coordinator.columnIdentifier))
            table.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
            table.rowHeight = 20
            table.intercellSpacing = .zero
            table.dataSource = coordinator
            table.reloadData()
            coordinator.attach(to: table)

            table.selectRowIndexes(IndexSet([0, 3]), byExtendingSelection: false)
            table.delegate = coordinator
            table.beginMouseDown(at: NSPoint(x: 10, y: table.rect(ofRow: 3).midY))
            coordinator.tableViewSelectionDidChange(
                Notification(name: NSTableView.selectionDidChangeNotification, object: table)
            )

            guard let change = changes.last else {
                TestRunner.fail("the table selection was not reported")
                return
            }
            expectEqual(change.clickedID, rows[3].id, "the row under the pointer is reported as clicked")
            expectEqual(change.ids, [rows[0].id, rows[3].id], "the table's selection is preserved")
            expectEqual(change.focus, rows[3].id, "the clicked row becomes the focused entry")
        }
    }

    // MARK: - Bulk delete

    TestRunner.add("bulk delete routes every entry through the sync trash") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "Owning",
                syncFolder: paths.syncA.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let stems = ["copyq_20261025120000123", "copyq_20261025120001456"]
            var entryIDs: [Int64] = []
            for (index, stem) in stems.enumerated() {
                try writeSyncGroup("payload \(index)", stem: stem, in: paths.syncA)
                let entry = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: Double(2000 + index)),
                    tabID: tab.id,
                    flavours: [
                        Fixtures.text("payload \(index)"),
                        Flavour(
                            itemIndex: 0,
                            type: Fingerprint.syncBaseNameFlavour,
                            data: Data(stem.utf8)
                        ),
                    ]
                ))
                entryIDs.append(entry.id)
            }
            expectEqual(try store.count(tabID: tab.id), 2)

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            try history.delete(ids: entryIDs)

            expectEqual(try store.count(tabID: tab.id), 0, "every selected row is gone")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path),
                [],
                "both owned groups left the sync folder"
            )
            let records = try trashRecords(in: paths.trash)
            expectEqual(records.count, 2, "each entry produced its own recoverable trash batch")
            expectEqual(Set(records.map(\.stem)), Set(stems), "both stems are recoverable")
            expectEqual(
                Set(records.map(\.reason)),
                Set([CopyQSyncTrashReason.localDelete]),
                "bulk delete uses the normal deletion path"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("bulk delete asks once, names the count, and honours Cancel") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                for index in 0..<3 {
                    _ = try history.record(
                        [Fixtures.text("bulk confirm \(index)")],
                        at: Date(timeIntervalSince1970: Double(index))
                    )
                }
                model.reload()
                model.selectAllEntries()

                var asks: [Int] = []
                model.confirmBulkDeletion = { count, _ in
                    asks.append(count)
                    return false
                }
                model.removeSelected()
                expectEqual(asks, [3], "one confirmation names the full count")
                expectEqual(try history.store.count(), 3, "Cancel leaves every entry in place")

                model.confirmBulkDeletion = { count, _ in
                    asks.append(count)
                    return true
                }
                model.removeSelected()
                expectEqual(asks, [3, 3], "the confirmed delete asks exactly once")
                expectEqual(try history.store.count(), 0, "confirming removes the whole selection")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Move to another tab

    TestRunner.add("moving an entry to a tab with a sync folder rewrites and trashes its group") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let sourceTab = try store.insertTab(ClipboardTab(
                name: "Source",
                syncFolder: paths.syncA.path
            ))
            let destinationTab = try store.insertTab(ClipboardTab(
                name: "Destination",
                syncFolder: paths.syncB.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let sourceStem = "copyq_20261025130000123"
            try writeSyncGroup("move me", stem: sourceStem, in: paths.syncA)
            let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
            for name in try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path) {
                try FileManager.default.setAttributes(
                    [.modificationDate: sourceDate],
                    ofItemAtPath: paths.syncA.appendingPathComponent(name).path
                )
            }
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 3000),
                tabID: sourceTab.id,
                flavours: [
                    Fixtures.text("move me"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(sourceStem.utf8)
                    ),
                ]
            ))

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            let report = try history.move(ids: [entry.id], toTabID: destinationTab.id)

            expectEqual(report.movedGroupCount, 1)
            expectEqual(report.trashedGroupCount, 1)
            let moved = try unwrap(try store.entry(id: entry.id), "the moved entry")
            expectEqual(moved.tabID, destinationTab.id, "the row follows the files")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path),
                [],
                "the source folder no longer holds an orphaned group"
            )

            let destinationGroups = try CopyQSyncFolder.read(atPath: paths.syncB.path)
            expectEqual(destinationGroups.items.count, 1, "the destination folder holds exactly one group")
            let destinationItem = try unwrap(destinationGroups.items.first, "the destination item")
            expectEqual(destinationItem.text, "move me", "the payload moved intact")
            let destinationStem = try unwrap(destinationItem.baseName, "the destination stem")
            expectNotEqual(destinationStem, sourceStem, "the destination gets its own stem")
            expectEqual(
                destinationItem.fileModificationDate?.timeIntervalSince1970 ?? 0,
                sourceDate.timeIntervalSince1970,
                accuracy: 0.001,
                "the moved group keeps the source modification date"
            )
            expectEqual(
                CopyQSyncDeletion.syncBaseName(of: moved, in: store, folder: paths.syncB.path),
                destinationStem,
                "the entry now owns the destination stem"
            )
            expectEqual(
                try store.isWrittenSyncStem(destinationStem, folder: paths.syncB.path),
                true,
                "the rewrite is recorded so the watcher does not import it back"
            )
            let identity = try unwrap(
                try store.mostRecentEntryIdentity(tabID: destinationTab.id),
                "the destination entry identity"
            )
            expectEqual(
                identity.fingerprint,
                moved.fingerprint,
                "the stored fingerprint follows the rewritten stem"
            )

            let records = try trashRecords(in: paths.trash)
            expectEqual(records.map(\.stem), [sourceStem], "the old group is recoverable")
            expectEqual(records.map(\.reason), [.movedToTab])
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a relocated group stays recorded for its destination tab after reopening") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let dbPath = paths.root.appendingPathComponent("history.sqlite").path
            let store = try ClipboardStore(path: dbPath)
            let sourceTab = try store.insertTab(ClipboardTab(
                name: "Source",
                syncFolder: paths.syncA.path
            ))
            let destinationTab = try store.insertTab(ClipboardTab(
                name: "Destination",
                syncFolder: paths.syncB.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let sourceStem = "copyq_20261025130000124"
            try writeSyncGroup("move me", stem: sourceStem, in: paths.syncA)
            let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
            for name in try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path) {
                try FileManager.default.setAttributes(
                    [.modificationDate: sourceDate],
                    ofItemAtPath: paths.syncA.appendingPathComponent(name).path
                )
            }
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 3000),
                tabID: sourceTab.id,
                flavours: [
                    Fixtures.text("move me"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(sourceStem.utf8)
                    ),
                ]
            ))

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            let report = try history.move(ids: [entry.id], toTabID: destinationTab.id)
            expectEqual(report.movedGroupCount, 1)

            let destinationItem = try unwrap(
                try CopyQSyncFolder.read(atPath: paths.syncB.path).items.first,
                "the destination item"
            )
            let destinationStem = try unwrap(destinationItem.baseName, "the destination stem")

            try store.deleteTab(id: sourceTab.id)
            expectEqual(
                try store.count(tabID: destinationTab.id),
                1,
                "removing the source tab keeps the moved entry"
            )

            let reopened = try ClipboardStore(path: dbPath)
            expect(
                try reopened.isWrittenSyncStem(destinationStem, folder: paths.syncB.path),
                "the destination rewrite stays recorded after reopening"
            )
            let scan = try CopyQSyncBridge.importSyncFolder(
                atPath: paths.syncB.path,
                intoTabID: destinationTab.id,
                in: reopened
            )
            expectEqual(scan.importedCount, 0, "the moved group is not imported back")
            let moved = try unwrap(try reopened.entry(id: entry.id), "the moved entry")
            expectEqual(
                moved.createdAt.timeIntervalSince1970,
                3000,
                accuracy: 0.001,
                "the scan does not refresh the moved item"
            )
            expectEqual(try reopened.count(tabID: destinationTab.id), 1, "the destination tab still has one item")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a relocated group without source files keeps the entry date") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let sourceTab = try store.insertTab(ClipboardTab(
                name: "Source",
                syncFolder: paths.syncA.path
            ))
            let destinationTab = try store.insertTab(ClipboardTab(
                name: "Destination",
                syncFolder: paths.syncB.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let sourceStem = "copyq_20261025131000123"
            let entryDate = Date(timeIntervalSince1970: 9500)
            let entry = try store.insert(ClipboardEntry(
                createdAt: entryDate,
                tabID: sourceTab.id,
                flavours: [
                    Fixtures.text("missing source group"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(sourceStem.utf8)
                    ),
                ]
            ))

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            let report = try history.move(ids: [entry.id], toTabID: destinationTab.id)

            expectEqual(report.movedGroupCount, 1, "the destination group was written")
            let destinationGroups = try CopyQSyncFolder.read(atPath: paths.syncB.path)
            let destinationItem = try unwrap(destinationGroups.items.first, "the destination item")
            expectEqual(
                destinationItem.fileModificationDate?.timeIntervalSince1970 ?? 0,
                entryDate.timeIntervalSince1970,
                accuracy: 0.001,
                "the missing source group falls back to the entry date"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("moving out of a synced tab trashes the source group and does not re-import it") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let sourceTab = try store.insertTab(ClipboardTab(
                name: "Mirror",
                syncFolder: paths.syncA.path
            ))
            let destinationTab = try store.insertTab(ClipboardTab(name: "Destination"))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let sourceStem = "copyq_20261025240000123"
            try writeSyncGroup("mirror item", stem: sourceStem, in: paths.syncA)
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 10_000),
                tabID: sourceTab.id,
                flavours: [
                    Fixtures.text("mirror item"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(sourceStem.utf8)
                    ),
                ]
            ))

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            let report = try history.move(ids: [entry.id], toTabID: destinationTab.id)

            expectEqual(report.movedGroupCount, 0, "no destination group is written")
            expectEqual(report.trashedGroupCount, 1, "the source group is trashed")
            let moved = try unwrap(try store.entry(id: entry.id), "the moved entry")
            expectEqual(moved.tabID, destinationTab.id, "the row moved")
            expect(!moved.hasSyncBaseName, "the row no longer carries the source stem")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path),
                [],
                "the source folder no longer holds the group"
            )

            let watcher = CopyQSyncWatcher(store: store)
            watcher.settleDelay = 0
            let scan = try watcher.scanFolder(
                atPath: paths.syncA.path,
                intoTabID: sourceTab.id,
                in: store,
                settleDelayOverride: 0
            )
            expectEqual(scan.importedCount, 0, "the watcher does not re-import the trashed group")
            expectEqual(try store.count(tabID: sourceTab.id), 0, "the source tab stays empty")
            expectEqual(try store.count(tabID: destinationTab.id), 1, "the moved item stays in the destination")

            let reconciliation = try CopyQSyncReconciliation.report(in: store)
            expectEqual(
                reconciliation.fileGroupsWithoutEntriesCount,
                0,
                "the emptied folder is not reported as an orphan group"
            )
            let manual = try CopyQSyncBridge.importSyncFolder(
                atPath: paths.syncA.path,
                intoTabID: sourceTab.id,
                in: store
            )
            expectEqual(manual.importedCount, 0, "manual import finds nothing to import")
            expectEqual(try store.count(tabID: sourceTab.id), 0, "manual import leaves the source tab empty")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("moving an entry to a folderless tab still trashes the source group") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let sourceTab = try store.insertTab(ClipboardTab(
                name: "Source",
                syncFolder: paths.syncA.path
            ))
            let destinationTab = try store.insertTab(ClipboardTab(name: "Local"))

            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let sourceStem = "copyq_20261025140000123"
            try writeSyncGroup("local move", stem: sourceStem, in: paths.syncA)
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 4000),
                tabID: sourceTab.id,
                flavours: [
                    Fixtures.text("local move"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(sourceStem.utf8)
                    ),
                ]
            ))

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            let report = try history.move(ids: [entry.id], toTabID: destinationTab.id)

            expectEqual(report.trashedGroupCount, 1)
            let moved = try unwrap(try store.entry(id: entry.id), "the moved entry")
            expectEqual(moved.tabID, destinationTab.id)
            expectEqual(
                CopyQSyncDeletion.syncBaseName(of: moved, in: store, folder: paths.syncA.path),
                nil,
                "a folderless tab cannot own the old stem"
            )
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path),
                [],
                "the source folder is empty rather than orphaned"
            )
            expectEqual(try trashRecords(in: paths.trash).map(\.reason), [.movedToTab])
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a folderless move does not count a missing group as trashed") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let sourceTab = try store.insertTab(ClipboardTab(
                name: "Source",
                syncFolder: paths.syncA.path
            ))
            let destinationTab = try store.insertTab(ClipboardTab(name: "Local"))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let sourceStem = "copyq_20261025230000123"
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 9000),
                tabID: sourceTab.id,
                flavours: [
                    Fixtures.text("missing group"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(sourceStem.utf8)
                    ),
                ]
            ))

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            let report = try history.move(ids: [entry.id], toTabID: destinationTab.id)

            expectEqual(report.trashedGroupCount, 0, "nothing was moved to the trash")
            expectEqual(report.rewrittenEntryCount, 1, "the entry still drops its stem")
            expectEqual(report.summary, "Moved the item to the tab.", "the summary does not claim a moved group")
            let moved = try unwrap(try store.entry(id: entry.id), "the moved entry")
            expectNil(
                CopyQSyncDeletion.syncBaseName(of: moved, in: store, folder: paths.syncA.path),
                "the missing group cannot keep the old stem"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("the move summary counts items without owned groups") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let sourceTab = try store.insertTab(ClipboardTab(
                name: "Source",
                syncFolder: paths.syncA.path
            ))
            let destinationTab = try store.insertTab(ClipboardTab(name: "Local"))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let stem = "copyq_20261025190000123"
            try writeSyncGroup("owning", stem: stem, in: paths.syncA)
            let owning = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 8000),
                tabID: sourceTab.id,
                flavours: [
                    Fixtures.text("owning"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(stem.utf8)
                    ),
                ]
            ))
            let plain = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 8001),
                tabID: sourceTab.id,
                flavours: [Fixtures.text("plain")]
            ))

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            let report = try history.move(ids: [owning.id, plain.id], toTabID: destinationTab.id)

            expectEqual(report.movedEntryCount, 2, "both entries changed tab")
            expectEqual(report.rewrittenEntryCount, 1, "only one entry owned a sync group")
            expectEqual(
                report.summary,
                "Moved the items to the tab and moved 1 file group to the app trash.",
                "the summary names both items, not just the rewritten one"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a destination with a sync folder receives the group without a separate switch") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let sourceTab = try store.insertTab(ClipboardTab(
                name: "Source",
                syncFolder: paths.syncA.path
            ))
            let destinationTab = try store.insertTab(ClipboardTab(
                name: "Mirror",
                syncFolder: paths.syncB.path
            ))
            var preferences = try store.preferences()
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let sourceStem = "copyq_20261025170000123"
            try writeSyncGroup("read only", stem: sourceStem, in: paths.syncA)
            let entry = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 7000),
                tabID: sourceTab.id,
                flavours: [
                    Fixtures.text("read only"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(sourceStem.utf8)
                    ),
                ]
            ))

            let plan = CopyQSyncRelocation.plan(
                entries: [entry],
                to: destinationTab,
                in: store
            )
            expectEqual(plan.rewrittenGroupCount, 1, "the destination folder receives the group")
            expectEqual(plan.deletedGroupCount, 0, "nothing is dropped for a folderless destination")

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            let report = try history.move(ids: [entry.id], toTabID: destinationTab.id)

            expectEqual(report.movedGroupCount, 1, "the group is written into the destination folder")
            expectEqual(report.trashedGroupCount, 1, "the old group is recoverable")
            let destinationGroups = try CopyQSyncFolder.read(atPath: paths.syncB.path)
            expectEqual(destinationGroups.items.count, 1, "the destination folder holds one group")
            expectEqual(destinationGroups.items.first?.text, "read only", "the payload moved intact")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path),
                [],
                "the source group left its folder"
            )
            let moved = try unwrap(try store.entry(id: entry.id), "the moved entry")
            expectEqual(moved.tabID, destinationTab.id, "the row moved to the destination")
            expectNotNil(
                CopyQSyncDeletion.syncBaseName(of: moved, in: store, folder: paths.syncB.path),
                "the entry claims a stem in the destination folder"
            )
            expectEqual(try trashRecords(in: paths.trash).map(\.stem), [sourceStem])
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("bulk move trims the destination through the sync trash") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let destinationTab = try store.insertTab(ClipboardTab(
                name: "Destination",
                syncFolder: paths.syncA.path
            ))
            let sourceTab = try store.insertTab(ClipboardTab(name: "Source"))
            var preferences = try store.preferences()
            preferences.defaultMaxItems = 3
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let evictedStem = "copyq_20261025180000123"
            try writeSyncGroup("oldest destination", stem: evictedStem, in: paths.syncA)
            var destinationIDs: [Int64] = []
            for index in 0..<3 {
                let entry = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: Double(100 + index)),
                    tabID: destinationTab.id,
                    flavours: index == 0
                        ? [
                            Fixtures.text("oldest destination"),
                            Flavour(
                                itemIndex: 0,
                                type: Fingerprint.syncBaseNameFlavour,
                                data: Data(evictedStem.utf8)
                            ),
                        ]
                        : [Fixtures.text("destination \(index)")]
                ))
                destinationIDs.append(entry.id)
            }
            var movedIDs: [Int64] = []
            for index in 0..<2 {
                let entry = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: Double(1000 + index)),
                    tabID: sourceTab.id,
                    flavours: [Fixtures.text("moved \(index)")]
                ))
                movedIDs.append(entry.id)
            }

            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            var trimmed: [Int64] = []
            var trimReason: HistoryTrimReason?
            history.onEntriesWillBeTrimmed = { ids, reason in
                trimmed = ids
                trimReason = reason
            }
            let report = try history.move(ids: movedIDs, toTabID: destinationTab.id)

            expectEqual(report.movedEntryCount, 2, "the report counts every moved item")
            expectEqual(report.summary, "Moved the items to the tab.", "the summary names both moved items")
            expectEqual(try store.count(tabID: destinationTab.id), 3, "the destination stays within the limit")
            expectEqual(trimmed.count, 2, "the cache callback names both evicted rows")
            expectEqual(
                Set(trimmed),
                Set([destinationIDs[0], destinationIDs[1]]),
                "the oldest two destination rows are evicted"
            )
            expectEqual(trimReason, .move, "the eviction is reported as a tab move")
            expectNil(try store.entry(id: destinationIDs[0]), "the oldest destination row is evicted")
            expectNil(try store.entry(id: destinationIDs[1]), "the next oldest destination row is evicted")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path),
                [],
                "the evicted entry's sync group left the folder"
            )
            let records = try trashRecords(in: paths.trash)
            expectEqual(records.map(\.stem), [evictedStem], "the evicted group is recoverable")
            expectEqual(records.map(\.reason), [.localDelete], "trimming uses the normal deletion path")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("clear tab deletes exactly the rows it trashed") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let history = ClipboardHistory(store: store)
            let tab = try unwrap(try store.defaultTab(), "default tab")
            let first = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 100),
                tabID: tab.id,
                flavours: [Fixtures.text("clear first")]
            ))
            let second = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 101),
                tabID: tab.id,
                flavours: [Fixtures.text("clear second")]
            ))
            var late: Int64?
            store.onEntriesWillBeDeleted = { _, _ in
                late = try? store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 200),
                    tabID: tab.id,
                    flavours: [Fixtures.text("clear late")]
                )).id
            }

            try history.clear(tabID: tab.id)

            let lateID = try unwrap(late, "the late row")
            expectNil(try store.entry(id: first.id), "the first victim is gone")
            expectNil(try store.entry(id: second.id), "the second victim is gone")
            expectNotNil(try store.entry(id: lateID), "a row added after the victim set survives")
            expectEqual(try store.count(tabID: tab.id), 1, "only the late row remains")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("delete all removes exactly the rows it trashed") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try unwrap(try store.defaultTab(), "default tab")
            let first = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 100),
                tabID: tab.id,
                flavours: [Fixtures.text("all first")]
            ))
            let second = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 101),
                tabID: tab.id,
                flavours: [Fixtures.text("all second")]
            ))
            var late: Int64?
            store.onEntriesWillBeDeleted = { _, _ in
                late = try? store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 200),
                    tabID: tab.id,
                    flavours: [Fixtures.text("all late")]
                )).id
            }

            try store.deleteAll()

            let lateID = try unwrap(late, "the late row")
            expectNil(try store.entry(id: first.id), "the first victim is gone")
            expectNil(try store.entry(id: second.id), "the second victim is gone")
            expectNotNil(try store.entry(id: lateID), "a row added after the victim set survives")
            expectEqual(try store.count(), 1, "only the late row remains")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("trim deletes exactly the victims it trashed") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try unwrap(try store.defaultTab(), "default tab")
            var ids: [Int64] = []
            for index in 0..<3 {
                let entry = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: Double(100 + index)),
                    tabID: tab.id,
                    flavours: [Fixtures.text("trim \(index)")]
                ))
                ids.append(entry.id)
            }

            var inserted: Int64?
            let removed = try store.trim(tabID: tab.id, to: 2) { _ in
                inserted = try? store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 200),
                    tabID: tab.id,
                    flavours: [Fixtures.text("late trim")]
                )).id
            }

            let late = try unwrap(inserted, "the late entry")
            expectEqual(removed, 1, "only the precomputed victim is removed")
            expectNil(try store.entry(id: ids[0]), "the oldest entry is the victim")
            expectNotNil(try store.entry(id: ids[1]), "the next entry survives")
            expectNotNil(try store.entry(id: ids[2]), "the newest original entry survives")
            expectNotNil(try store.entry(id: late), "a row added after the victim set is not deleted")
            expectEqual(try store.count(tabID: tab.id), 3, "one victim left and one late row arrived")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("preference change trims through the sync trash") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "Synced",
                syncFolder: paths.syncA.path
            ))
            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = paths.trash
            var preferences = try history.preferences()

            let evictedStem = "copyq_20261025200000123"
            try writeSyncGroup("oldest synced", stem: evictedStem, in: paths.syncA)
            let evicted = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 100),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("oldest synced"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(evictedStem.utf8)
                    ),
                ]
            ))
            for index in 1...2 {
                _ = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: Double(100 + index)),
                    tabID: tab.id,
                    flavours: [Fixtures.text("synced \(index)")]
                ))
            }

            var trimmed: [Int64] = []
            var trimReason: HistoryTrimReason?
            history.onEntriesWillBeTrimmed = { ids, reason in
                trimmed = ids
                trimReason = reason
            }
            preferences.defaultMaxItems = 2
            preferences.syncPaused = false
            try history.setPreferences(preferences)

            expectEqual(try store.count(tabID: tab.id), 2, "the preference change trims the tab")
            expectEqual(trimmed, [evicted.id], "the cache callback names the evicted row")
            expectEqual(trimReason, .preferenceChange, "the eviction is reported as a preference change")
            expectNil(try store.entry(id: evicted.id), "the evicted row is gone")
            expectEqual(
                try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path),
                [],
                "the evicted entry's sync group left the folder"
            )
            expectEqual(
                try trashRecords(in: paths.trash).map(\.stem),
                [evictedStem],
                "the evicted group is recoverable"
            )
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a preference trim deletes exactly the victims it trashed") {
        do {
            let store = try ClipboardStore(inMemory: true)
            let tab = try unwrap(try store.defaultTab(), "default tab")
            let history = ClipboardHistory(store: store)
            var preferences = try history.preferences()
            var ids: [Int64] = []
            for index in 0..<3 {
                let entry = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: Double(100 + index)),
                    tabID: tab.id,
                    flavours: [Fixtures.text("preference trim \(index)")]
                ))
                ids.append(entry.id)
            }

            var inserted: Int64?
            var victims: [Int64] = []
            history.onEntriesWillBeTrimmed = { evicted, _ in
                victims = evicted
                inserted = try? store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 200),
                    tabID: tab.id,
                    flavours: [Fixtures.text("late preference trim")]
                )).id
            }
            preferences.defaultMaxItems = 2
            try history.setPreferences(preferences)

            let late = try unwrap(inserted, "the late entry")
            expectEqual(victims, [ids[0]], "the oldest entry is the victim")
            expectNil(try store.entry(id: ids[0]), "the precomputed victim is gone")
            expectNotNil(try store.entry(id: ids[1]), "the next entry survives")
            expectNotNil(try store.entry(id: ids[2]), "the newest original entry survives")
            expectNotNil(try store.entry(id: late), "a row added after the victim set is not deleted")
            expectEqual(try store.count(tabID: tab.id), 3, "one victim left and one late row arrived")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a capture stays visible when its trim trash work fails") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let tab = try store.insertTab(ClipboardTab(
                name: "Synced",
                syncFolder: paths.syncA.path
            ))
            var preferences = try store.preferences()
            preferences.defaultMaxItems = 1
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let oldStem = "copyq_20261025210000123"
            try writeSyncGroup("old capture", stem: oldStem, in: paths.syncA)
            let old = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 100),
                tabID: tab.id,
                flavours: [
                    Fixtures.text("old capture"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(oldStem.utf8)
                    ),
                ]
            ))
            let blocker = paths.root.appendingPathComponent("trash-blocker")
            try Data("not a directory".utf8).write(to: blocker)
            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = blocker

            guard case .inserted(let inserted) = try history.record(
                [Fixtures.text("new capture")],
                into: tab,
                at: Date(timeIntervalSince1970: 200)
            ) else {
                TestRunner.fail("the capture was not inserted")
                return
            }
            expectEqual(try store.entry(id: inserted.id)?.id, inserted.id, "the new capture is stored")
            expectEqual(try store.entry(id: old.id)?.id, old.id, "the failed trim leaves the old row for a retry")
            expectEqual(try store.count(tabID: tab.id), 2, "the store count matches the surviving rows")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("a move stays successful when the destination trim cannot trash") {
        do {
            let paths = try multiSelectionScratch()
            defer { try? FileManager.default.removeItem(at: paths.root) }

            let store = try ClipboardStore(inMemory: true)
            let destinationTab = try store.insertTab(ClipboardTab(
                name: "Destination",
                syncFolder: paths.syncA.path
            ))
            let sourceTab = try store.insertTab(ClipboardTab(name: "Source"))
            var preferences = try store.preferences()
            preferences.defaultMaxItems = 2
            preferences.syncPaused = false
            try store.setPreferences(preferences)

            let oldStem = "copyq_20261025220000123"
            try writeSyncGroup("old destination", stem: oldStem, in: paths.syncA)
            let old = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 100),
                tabID: destinationTab.id,
                flavours: [
                    Fixtures.text("old destination"),
                    Flavour(
                        itemIndex: 0,
                        type: Fingerprint.syncBaseNameFlavour,
                        data: Data(oldStem.utf8)
                    ),
                ]
            ))
            _ = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 101),
                tabID: destinationTab.id,
                flavours: [Fixtures.text("newer destination")]
            ))
            let moved = try store.insert(ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: 1000),
                tabID: sourceTab.id,
                flavours: [Fixtures.text("moved")]
            ))

            let blocker = paths.root.appendingPathComponent("trash-blocker")
            try Data("not a directory".utf8).write(to: blocker)
            let history = ClipboardHistory(store: store)
            history.syncTrashRoot = blocker
            let report = try history.move(ids: [moved.id], toTabID: destinationTab.id)

            expectEqual(try store.entry(id: moved.id)?.tabID, destinationTab.id, "the move completed")
            expectNotNil(report.failures.first, "the trim failure is reported")
            expectEqual(try store.entry(id: old.id)?.id, old.id, "the victim stays because it could not be trashed")
            expectEqual(try store.count(tabID: destinationTab.id), 3, "the destination remains over the limit for a retry")
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }

    TestRunner.add("paused sync blocks a move that would touch files") {
        MainActor.assumeIsolated {
            do {
                let paths = try multiSelectionScratch()
                defer { try? FileManager.default.removeItem(at: paths.root) }

                let store = try ClipboardStore(inMemory: true)
                let sourceTab = try store.insertTab(ClipboardTab(
                    name: "Source",
                    syncFolder: paths.syncA.path
                ))
                let destinationTab = try store.insertTab(ClipboardTab(
                    name: "Destination",
                    syncFolder: paths.syncB.path
                ))
                var preferences = try store.preferences()
                preferences.syncPaused = true
                try store.setPreferences(preferences)

                let stem = "copyq_20261025160000123"
                try writeSyncGroup("paused", stem: stem, in: paths.syncA)
                let entry = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 6000),
                    tabID: sourceTab.id,
                    flavours: [
                        Fixtures.text("paused"),
                        Flavour(
                            itemIndex: 0,
                            type: Fingerprint.syncBaseNameFlavour,
                            data: Data(stem.utf8)
                        ),
                    ]
                ))

                let plan = CopyQSyncRelocation.plan(
                    entries: [entry],
                    to: destinationTab,
                    in: store
                )
                expectEqual(plan.blockedGroupCount, 1)
                expectNotNil(plan.blockingReason, "the plan explains why the move is blocked")
                expectThrows {
                    _ = try CopyQSyncRelocation.moveOwnedGroups(
                        entries: [entry],
                        to: destinationTab,
                        in: store
                    )
                }
                expectEqual(
                    try FileManager.default.contentsOfDirectory(atPath: paths.syncA.path).isEmpty,
                    false,
                    "the blocked move leaves the source group untouched"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the menus expose bulk reorder, Move to Tab, and Select All") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                _ = try history.record([Fixtures.text("menu item")])
                model.reload()
                model.selectFirst()

                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})
                let menu = MainMenuBuilder.build(actions: actions)

                guard let itemMenu = menu.items.first(where: { $0.title == "Item" })?.submenu else {
                    TestRunner.fail("the Item menu is missing")
                    return
                }
                let actionsInMenu = Set(itemMenu.items.compactMap(\.action))
                for action in [
                    #selector(AppActions.moveSelectedUp(_:)),
                    #selector(AppActions.moveSelectedDown(_:)),
                    #selector(AppActions.moveSelectedToTop(_:)),
                    #selector(AppActions.moveSelectedToBottom(_:)),
                ] {
                    expect(actionsInMenu.contains(action), "the Item menu exposes every reorder command")
                }
                guard let moveToTab = itemMenu.items.first(where: { $0.title == "Move to Tab" }) else {
                    TestRunner.fail("the Move to Tab submenu is missing")
                    return
                }
                expectEqual(moveToTab.submenu?.identifier, MainMenuBuilder.moveToTabMenuIdentifier)
                expect(moveToTab.submenu?.delegate === actions, "the destination list is rebuilt when the menu opens")

                guard let editMenu = menu.items.first(where: { $0.title == "Edit" })?.submenu else {
                    TestRunner.fail("the Edit menu is missing")
                    return
                }
                let selectAll = editMenu.items.first(where: { $0.keyEquivalent == "a" })
                expectEqual(selectAll?.action, #selector(AppActions.selectAllItems(_:)), "Select All selects items")
                expectEqual(selectAll?.target === actions, true)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the move plan asks for confirmation only when sync files change") {
        MainActor.assumeIsolated {
            do {
                let paths = try multiSelectionScratch()
                defer { try? FileManager.default.removeItem(at: paths.root) }

                let store = try ClipboardStore(inMemory: true)
                let sourceTab = try store.insertTab(ClipboardTab(
                    name: "Source",
                    syncFolder: paths.syncA.path
                ))
                let folderlessTab = try store.insertTab(ClipboardTab(name: "Local"))
                var preferences = try store.preferences()
                preferences.syncPaused = false
                try store.setPreferences(preferences)

                let stem = "copyq_20261025150000123"
                try writeSyncGroup("plan", stem: stem, in: paths.syncA)
                let owning = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 5000),
                    tabID: sourceTab.id,
                    flavours: [
                        Fixtures.text("plan"),
                        Flavour(
                            itemIndex: 0,
                            type: Fingerprint.syncBaseNameFlavour,
                            data: Data(stem.utf8)
                        ),
                    ]
                ))
                let plain = try store.insert(ClipboardEntry(
                    createdAt: Date(timeIntervalSince1970: 5001),
                    tabID: sourceTab.id,
                    flavours: [Fixtures.text("no sync identity")]
                ))

                let toFolderless = CopyQSyncRelocation.plan(
                    entries: [owning],
                    to: folderlessTab,
                    in: store
                )
                expectEqual(toFolderless.deletedGroupCount, 1, "a folderless destination trashes the group")
                expect(toFolderless.requiresConfirmation, "the move changes sync files")
                expect(toFolderless.summary(language: .english).contains("trash"), "the summary says the files go to the trash")

                let plainMove = CopyQSyncRelocation.plan(
                    entries: [plain],
                    to: folderlessTab,
                    in: store
                )
                expectEqual(plainMove.touchedGroupCount, 0, "an entry without a group needs no confirmation")
                expect(!plainMove.requiresConfirmation, "a plain tab move stays silent")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the move confirmation names only the sync work the move performs") {
        let rewriteOnly = CopyQSyncRelocationPlan(rewrittenGroupCount: 1, deletedGroupCount: 0)
        expectEqual(
            rewriteOnly.summary(language: .english),
            "The move will rewrite 1 file group into the destination sync folder.",
            "a destination with a sync folder is not described as a trash move"
        )
        expectEqual(
            rewriteOnly.summary(language: .simplifiedChinese),
            "此次移动会将 1 个文件组重写入目标同步文件夹。"
        )

        let trashOnly = CopyQSyncRelocationPlan(rewrittenGroupCount: 0, deletedGroupCount: 2)
        expectEqual(
            trashOnly.summary(language: .english),
            "The move will move 2 file groups to the app trash because the destination tab does not write to a sync folder.",
            "a folderless destination is not described as a rewrite"
        )
        expectEqual(
            trashOnly.summary(language: .simplifiedChinese),
            "此次移动会将 2 个文件组移至应用废纸篓（目标标签页不写入同步文件夹）。"
        )

        let both = CopyQSyncRelocationPlan(rewrittenGroupCount: 1, deletedGroupCount: 2)
        expectEqual(
            both.summary(language: .english),
            "The move will rewrite 1 file group into the destination sync folder and move 2 file groups to the app trash because the destination tab does not write to a sync folder."
        )
        expectEqual(
            both.summary(language: .simplifiedChinese),
            "此次移动会将 1 个文件组重写入目标同步文件夹，并将 2 个文件组移至应用废纸篓（目标标签页不写入同步文件夹）。"
        )
        expectEqual(
            CopyQSyncRelocationPlan().summary(language: .simplifiedChinese),
            "不会移动或删除任何同步文件。"
        )
    }
}

// MARK: - Fixtures

private func multiSelectionScratch() throws -> (root: URL, syncA: URL, syncB: URL, trash: URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("copyq-multiselection-\(UUID().uuidString)", isDirectory: true)
    let syncA = root.appendingPathComponent("sync-a", isDirectory: true)
    let syncB = root.appendingPathComponent("sync-b", isDirectory: true)
    let trash = root.appendingPathComponent("trash", isDirectory: true)
    for folder in [syncA, syncB] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    return (root, syncA, syncB, trash)
}

private func writeSyncGroup(_ text: String, stem: String, in folder: URL) throws {
    var data = CopyQDataMap()
    data.set(CopyQFormat.text, Data(text.utf8))
    try CopyQSyncFolder.write(CopyQSyncItem(baseName: stem, data: data), into: folder.path)
}

private func trashRecords(in trash: URL) throws -> [CopyQSyncTrashRecord] {
    guard FileManager.default.fileExists(atPath: trash.path) else { return [] }
    let directories = try FileManager.default.contentsOfDirectory(
        at: trash,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ).filter {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var records: [CopyQSyncTrashRecord] = []
    for directory in directories {
        let data = try Data(contentsOf: directory.appendingPathComponent(CopyQSyncTrash.metadataFileName))
        records.append(contentsOf: try decoder.decode([CopyQSyncTrashRecord].self, from: data))
    }
    return records.sorted { $0.stem < $1.stem }
}
