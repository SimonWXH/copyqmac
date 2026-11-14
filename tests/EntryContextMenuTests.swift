// The row context menu: New Item… and Edit Item… next to the row commands, with
// the same enablement the Item menu uses.

import AppKit
import Foundation

func registerEntryContextMenuTests() {
    func row(id: Int64) -> EntryRow {
        EntryRow(
            id: id,
            number: 1,
            kind: .text,
            primaryText: "hello",
            richText: nil,
            fileNames: [],
            fileCount: 0,
            relativeTime: "now",
            pinned: false,
            hasNote: false,
            icon: nil
        )
    }

    TestRunner.add("the row context menu composes New Item and Edit Item with the model's rules") {
        MainActor.assumeIsolated {
            var newItemCalls = 0
            var editedIDs: [Int64] = []
            var activatedIDs: [Int64] = []
            var canCreate = true
            var availability = EditItemAvailability(
                isEnabled: true,
                title: EditItemAvailability.defaultTitle()
            )

            let list = EntryListView(
                rows: [row(id: 42)],
                rowsRevision: 1,
                selection: SelectionState(),
                singleClickActivates: false,
                actions: .none,
                contextActions: EntryContextActions(
                    newItem: { newItemCalls += 1 },
                    editItem: { editedIDs.append($0) },
                    editItemAvailability: { _ in availability },
                    canCreateNewItem: { canCreate },
                    removeSelection: {}
                ),
                onSelectionChange: { _ in },
                onActivate: { activatedIDs.append($0) },
                onCopy: { _ in },
                onFocusChange: { _ in },
                onRowBecameVisible: { _ in },
                banner: nil,
                onBannerAction: {},
                onBannerDismiss: {}
            )
            let coordinator = list.makeCoordinator()

            guard let menu = coordinator.contextMenu(for: 0) else {
                TestRunner.fail("the row has no context menu")
                return
            }
            expectEqual(
                duplicateMenuShortcuts(in: menu),
                [],
                "no two row-menu items may resolve to the same shortcut"
            )
            expectEqual(
                menu.items.map(\.title),
                [
                    "New Item\u{2026}",
                    "Edit Item\u{2026}",
                    "",
                    "Activate",
                    "Copy to Clipboard",
                    "",
                    "Pin",
                    "Remove",
                ],
                "the new commands lead the row menu and the existing commands keep their order"
            )

            guard let newItem = menu.items.first(where: { $0.title == "New Item\u{2026}" }),
                  let editItem = menu.items.first(where: { $0.title == "Edit Item\u{2026}" }),
                  let activate = menu.items.first(where: { $0.title == "Activate" })
            else {
                TestRunner.fail("New Item, Edit Item, and Activate must be in the row context menu")
                return
            }

            expectEqual(activate.keyEquivalent, "\r", "Activate names Return as its key")
            _ = (activate.target as? NSObject)?.perform(activate.action, with: activate)
            expectEqual(activatedIDs, [42], "the context command activates the row it was opened on")

            expectEqual(newItem.keyEquivalent, "n")
            expectEqual(newItem.keyEquivalentModifierMask, [.command])
            expectEqual(editItem.keyEquivalent, "\u{F705}", "Edit Item uses the literal F2 key")
            expectEqual(editItem.keyEquivalentModifierMask, [])

            expectEqual(
                (editItem.representedObject as? NSNumber)?.int64Value,
                42,
                "Edit Item carries the row it was opened on"
            )
            expectEqual(coordinator.validateMenuItem(newItem), true, "New Item follows the model's create rule")
            expectEqual(coordinator.validateMenuItem(editItem), true, "Edit Item follows the model's edit rule")
            expectEqual(editItem.title, "Edit Item\u{2026}", "an editable row keeps the normal title")

            _ = (newItem.target as? NSObject)?.perform(newItem.action, with: newItem)
            _ = (editItem.target as? NSObject)?.perform(editItem.action, with: editItem)
            expectEqual(newItemCalls, 1, "the context command calls the same New Item entry point")
            expectEqual(editedIDs, [42], "the context command edits the row it was opened on")

            // An image or file entry is not editable, and an open editor or tab
            // rename blocks both commands. The context menu must not offer
            // either action in that state.
            availability = EditItemAvailability(
                isEnabled: false,
                title: EditItemAvailability.noteTitle()
            )
            canCreate = false
            expectEqual(coordinator.validateMenuItem(newItem), false, "New Item is disabled while an editor is open")
            expectEqual(coordinator.validateMenuItem(editItem), false, "Edit Item is disabled for a non-text entry")
            expectEqual(
                editItem.title,
                "Edit Item\u{2026} (Use Edit Note)",
                "the disabled item still points the user at Edit Note"
            )

            guard let emptyMenu = coordinator.emptyAreaContextMenu(),
                  let emptyNewItem = emptyMenu.items.first(where: { $0.title == "New Item\u{2026}" })
            else {
                TestRunner.fail("empty area context menu must include New Item")
                return
            }
            expectEqual(emptyNewItem.keyEquivalent, "n")
            expectEqual(emptyNewItem.keyEquivalentModifierMask, [.command])
            expectEqual(coordinator.validateMenuItem(emptyNewItem), false, "empty menu item shares create rule")
        }
    }

    TestRunner.add("edit item availability matches the Item menu for text, image, and file rows") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()

                guard case .inserted(let textEntry) = try history.record([Fixtures.text("caption")]) else {
                    TestRunner.fail("could not record the text entry")
                    return
                }
                model.reload(capturedEntryID: textEntry.id)
                model.select(textEntry.id)
                let textAvailability = model.editItemAvailability(for: textEntry.id)
                expectEqual(textAvailability.isEnabled, true, "a text entry can be edited")
                expectEqual(textAvailability.title, EditItemAvailability.defaultTitle())

                guard case .inserted(let imageEntry) = try history.record([
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
                ]) else {
                    TestRunner.fail("could not record the image entry")
                    return
                }
                model.reload(capturedEntryID: imageEntry.id)
                model.select(imageEntry.id)
                let imageAvailability = model.editItemAvailability(for: imageEntry.id)
                expectEqual(imageAvailability.isEnabled, false, "an image entry has no text to edit")
                expectEqual(imageAvailability.title, EditItemAvailability.noteTitle())

                guard case .inserted(let fileEntry) = try history.record([
                    Fixtures.fileURL("/tmp/report.pdf"),
                ]) else {
                    TestRunner.fail("could not record the file entry")
                    return
                }
                model.reload(capturedEntryID: fileEntry.id)
                model.select(fileEntry.id)
                let fileAvailability = model.editItemAvailability(for: fileEntry.id)
                expectEqual(fileAvailability.isEnabled, false, "a file entry has no text to edit")
                expectEqual(fileAvailability.title, EditItemAvailability.noteTitle())

                // The nil-id form is the menu bar's selected-entry form.
                expectEqual(
                    model.editItemAvailability().isEnabled,
                    false,
                    "the menu bar uses the same rule for the selected file entry"
                )

                // An open item editor or tab rename blocks the context commands
                // exactly as it blocks the menu-bar item.
                model.requestNewItem()
                expectEqual(model.canCreateNewItem, false, "the editor blocks creation")
                expectEqual(
                    model.editItemAvailability(for: textEntry.id).isEnabled,
                    false,
                    "the editor blocks Edit Item too"
                )
                model.cancelTextEdit()

                model.pendingRenameTabID = model.selectedTab?.id
                expectEqual(model.canCreateNewItem, false, "a tab rename blocks creation")
                expectEqual(model.editItemAvailability(for: textEntry.id).isEnabled, false)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("status menu includes New Item and Edit Item with matching shortcuts") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})
                let (statusMenu, _, _) = StatusMenuBuilder.build(actions: actions)
                expectEqual(
                    duplicateMenuShortcuts(in: statusMenu),
                    [],
                    "no two status-menu items may resolve to the same shortcut"
                )

                guard let newItem = statusMenu.items.first(where: { $0.title == "New Item\u{2026}" }),
                      let editItem = statusMenu.items.first(where: { $0.title.hasPrefix("Edit Item") })
                else {
                    TestRunner.fail("status menu must include New Item and Edit Item")
                    return
                }

                expectEqual(newItem.keyEquivalent, "n")
                expectEqual(newItem.keyEquivalentModifierMask, [.command])
                expectEqual(editItem.keyEquivalent, "\u{F705}", "Edit Item uses the literal F2 key")
                expectEqual(editItem.keyEquivalentModifierMask, [])

                expectEqual(actions.validateMenuItem(newItem), true, "New Item is available initially")
                expectEqual(actions.validateMenuItem(editItem), false, "Edit Item is disabled without selection")

                model.requestNewItem()
                expectEqual(actions.validateMenuItem(newItem), false, "New Item disabled while editing")
                model.cancelTextEdit()
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
