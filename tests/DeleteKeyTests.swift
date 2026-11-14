// Delete-key safety: one Delete press removes one entry, while Backspace keeps
// repeating inside text editors.

import AppKit
import Foundation

func registerDeleteKeyTests() {
    TestRunner.add("holding Delete removes at most one entry") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()

                var entryIDs: [Int64] = []
                for index in 0..<3 {
                    let outcome = try history.record(
                        [Fixtures.text("entry \(index)")],
                        at: Date(timeIntervalSince1970: Double(index))
                    )
                    guard case .inserted(let entry) = outcome else {
                        TestRunner.fail("fixture entry \(index) was not inserted")
                        return
                    }
                    entryIDs.append(entry.id)
                }
                model.reload()
                model.select(entryIDs.last)

                model.removeSelected()
                model.removeSelected()
                expectEqual(try history.store.count(), 2, "repeated Delete inside the cooldown removes only one entry")

                Thread.sleep(forTimeInterval: 0.35)
                model.removeSelected()
                expectEqual(try history.store.count(), 1, "Delete works again after the cooldown")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("Backspace repeats in the search filter and note editor") {
        expectEqual(ListInteractionPolicy.handles(.delete, noteEditing: false, searchEmpty: false), false)
        expectEqual(ListInteractionPolicy.handles(.delete, noteEditing: true, searchEmpty: false), false)
    }

    TestRunner.add("shortcuts deferred while a text control is focused") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let outcome = try history.record([Fixtures.text("initial entry")])
                guard case .inserted(let entry) = outcome else {
                    TestRunner.fail("entry not inserted")
                    return
                }
                model.reload()
                model.select(entry.id)

                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})
                let textView = TestTextView()
                actions.firstResponderOverride = { textView }

                // 1. Copy defers to text control
                actions.copySelected(nil)
                expectEqual(textView.copyCallCount, 1, "copy was deferred to focused text view")

                // 2. Paste defers to text control
                actions.pasteSelected(nil)
                expectEqual(textView.pasteCallCount, 1, "paste was deferred to focused text view")

                // 3. Remove defers to deleteToBeginningOfLine: and does not delete entry
                actions.removeSelected(nil)
                expectEqual(textView.deleteToBeginningOfLineCallCount, 1, "remove was deferred to text view")
                expectEqual(try history.store.count(), 1, "entry was not deleted")

                // 4. Validate menu items while text control is focused
                let copyItem = NSMenuItem(title: "Copy", action: #selector(AppActions.copySelected(_:)), keyEquivalent: "c")
                let pasteItem = NSMenuItem(title: "Paste", action: #selector(AppActions.pasteSelected(_:)), keyEquivalent: "v")
                let removeItem = NSMenuItem(title: "Remove", action: #selector(AppActions.removeSelected(_:)), keyEquivalent: "\u{8}")
                expectEqual(actions.validateMenuItem(copyItem), true, "copy enabled for text control")
                expectEqual(actions.validateMenuItem(pasteItem), true, "paste enabled for text control")
                expectEqual(actions.validateMenuItem(removeItem), false, "remove disabled for text control")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the list never deletes while a note is being edited") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let outcome = try history.record([Fixtures.text("item with note")])
                guard case .inserted(let entry) = outcome else {
                    TestRunner.fail("entry not inserted")
                    return
                }
                model.reload()
                model.select(entry.id)

                model.setNoteEditing(true)
                expectEqual(model.isEditingNote, true)

                // Try model.removeSelected()
                model.removeSelected()
                expectEqual(try history.store.count(), 1, "removeSelected ignored while editing note")

                // Try model.remove(entry)
                model.remove(entry)
                expectEqual(try history.store.count(), 1, "remove ignored while editing note")

                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})
                actions.removeSelected(nil)
                expectEqual(try history.store.count(), 1, "actions.removeSelected ignored while editing note")

                let removeItem = NSMenuItem(title: "Remove", action: #selector(AppActions.removeSelected(_:)), keyEquivalent: "\u{8}")
                let editNoteItem = NSMenuItem(title: "Edit Note", action: #selector(AppActions.editNote(_:)), keyEquivalent: "e")
                expectEqual(actions.validateMenuItem(removeItem), false, "remove is disabled while editing note")
                expectEqual(actions.validateMenuItem(editNoteItem), false, "edit note is disabled while editing note")

                model.setNoteEditing(false)
                expectEqual(model.isEditingNote, false)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("actions and model never fall through to item operations while editing note or text focused") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let outcome = try history.record([Fixtures.text("initial entry")])
                guard case .inserted(let entry) = outcome else {
                    TestRunner.fail("entry not inserted")
                    return
                }
                model.reload()
                model.select(entry.id)

                let windowController = TestWindowController()
                let actions = AppActions(model: model, windowController: windowController, presentPreferences: {})
                actions.firstResponderOverride = { nil }

                model.setNoteEditing(true)

                actions.copySelected(nil)
                actions.pasteSelected(nil)
                actions.removeSelected(nil)
                expectEqual(windowController.hideCallCount, 0, "actions.pasteSelected did not dismiss window")
                expectEqual(try history.store.count(), 1, "actions.removeSelected did not remove entry")

                var dismissed = false
                model.copySelected()
                model.pasteSelected(dismiss: { dismissed = true })
                expectEqual(dismissed, false, "model.pasteSelected did not dismiss window")
                model.removeSelected()
                expectEqual(try history.store.count(), 1, "model.removeSelected did not remove entry")

                model.setNoteEditing(false)
                let textControl = NSText()
                actions.firstResponderOverride = { textControl }
                actions.copySelected(nil)
                actions.pasteSelected(nil)
                actions.removeSelected(nil)
                expectEqual(windowController.hideCallCount, 0, "actions.pasteSelected did not dismiss window when text control focused")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}

private final class TestWindowController: WindowControllerProtocol {
    var isVisible = false
    var hideCallCount = 0
    func show() {}
    func hide() { hideCallCount += 1 }
}

private final class TestTextView: NSTextView {
    var copyCallCount = 0
    var pasteCallCount = 0
    var deleteToBeginningOfLineCallCount = 0
    var deleteCallCount = 0

    override func copy(_ sender: Any?) {
        copyCallCount += 1
    }

    override func paste(_ sender: Any?) {
        pasteCallCount += 1
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        deleteToBeginningOfLineCallCount += 1
    }

    override func delete(_ sender: Any?) {
        deleteCallCount += 1
    }
}
