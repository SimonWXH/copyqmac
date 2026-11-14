// SPDX-License-Identifier: GPL-3.0-or-later
//
// The per-tab Sync folder field, driven through the real SwiftUI view.
//
// The reported failure: a path pasted into the field was only stored on focus
// loss, Return, or the view disappearing, so a tab was believed mapped while
// its folder was empty. This suite hosts the real `TabSettingsRow` in a window
// and types into its actual AppKit text field, so the wiring between the field,
// the debounce, and the store is exercised rather than the decision alone.

import AppKit
import SwiftUI

func registerSyncFolderFieldTests() {
    TestRunner.currentSuite = "SyncFolderField"

    TestRunner.add("a pasted sync folder is stored without leaving the field") {
        MainActor.assumeIsolated {
            do {
                let folder = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: folder) }
                let (model, tab, store) = try makeModelWithTab()
                let field = try SyncFolderFieldHarness(model: model, tab: tab)

                field.replaceText(folder.path)

                expectEqual(
                    storedFolder(store, tab.id),
                    nil,
                    "a change on its own writes nothing; the pause comes first"
                )

                expect(
                    waitUntil(3.0) { storedFolder(store, tab.id) == folder.path },
                    "the pasted folder is stored while the field keeps focus"
                )
                expectNil(model.failureNotice, "the commit reports no failure")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a pause inside a path never stores the truncated folder") {
        // The field is focused the whole time, so an echo of the committed,
        // trimmed value would join the next keystroke onto the stem and store
        // "/tmp/…/SyncFolder" instead of "/tmp/…/Sync Folder".
        MainActor.assumeIsolated {
            do {
                let root = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (model, tab, store) = try makeModelWithTab()
                let field = try SyncFolderFieldHarness(model: model, tab: tab)
                let fullPath = root.path + "/Sync Folder"
                let firstHalf = root.path + "/Sync "

                field.replaceText(firstHalf)

                expect(
                    waitUntil(3.0) { storedFolder(store, tab.id) == root.path + "/Sync" },
                    "the pause stores the trimmed text it holds"
                )
                expectEqual(
                    field.text,
                    firstHalf,
                    "the focused field keeps the text being typed, not the trimmed stored folder"
                )

                field.type("Folder")

                expect(
                    waitUntil(3.0) { storedFolder(store, tab.id) == fullPath },
                    "continuing after the pause stores the whole path"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a second edit before the pause replaces the pending folder") {
        MainActor.assumeIsolated {
            do {
                let root = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (model, tab, store) = try makeModelWithTab()
                let field = try SyncFolderFieldHarness(model: model, tab: tab)

                field.replaceText(root.path + "/Fir")
                field.replaceText(root.path + "/Final")

                expect(
                    waitUntil(3.0) { storedFolder(store, tab.id) == root.path + "/Final" },
                    "only the last edited value is stored"
                )
                expect(
                    storedFolder(store, tab.id) != root.path + "/Fir",
                    "the replaced value is never stored"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("leaving the field stores the folder without a pause") {
        MainActor.assumeIsolated {
            do {
                let root = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (model, tab, store) = try makeModelWithTab()
                let field = try SyncFolderFieldHarness(model: model, tab: tab)
                let folder = root.path + "/Blurred"

                field.focus()
                field.replaceText(folder)
                expectEqual(storedFolder(store, tab.id), nil, "nothing is stored before blur")

                field.blur()
                pump(0.2)

                expectEqual(storedFolder(store, tab.id), folder, "blur commits the folder")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("Return stores the folder without a pause") {
        MainActor.assumeIsolated {
            do {
                let root = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (model, tab, store) = try makeModelWithTab()
                let field = try SyncFolderFieldHarness(model: model, tab: tab)
                let folder = root.path + "/Submitted"

                field.focus()
                field.replaceText(folder)
                expectEqual(storedFolder(store, tab.id), nil, "nothing is stored before Return")

                field.submit()
                pump(0.2)

                expectEqual(storedFolder(store, tab.id), folder, "Return commits the folder")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an unchanged folder is not written again on a pause") {
        MainActor.assumeIsolated {
            do {
                let root = try Fixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (model, tab, store) = try makeModelWithTab(folder: root.path)
                let field = try SyncFolderFieldHarness(model: model, tab: tab)

                field.replaceText("  " + root.path + "\n")
                pump(0.6)

                expectEqual(
                    storedFolder(store, tab.id),
                    root.path,
                    "surrounding whitespace keeps the stored folder"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}

// MARK: - Model and view setup

@MainActor
private func makeModelWithTab(folder: String? = nil) throws -> (AppModel, ClipboardTab, ClipboardStore) {
    let store = try ClipboardStore(inMemory: true)
    let tab = try store.insertTab(ClipboardTab(name: "Fedora", syncFolder: folder))
    let model = AppModel(history: ClipboardHistory(store: store), isAccessibilityTrusted: { true })
    model.bootstrap()
    return (model, tab, store)
}

private func storedFolder(_ store: ClipboardStore, _ tabID: Int64) -> String? {
    guard let tab = try? store.tab(id: tabID) else { return nil }
    return tab.syncFolder
}

/// The real per-tab preferences row, laid out in an unshown window so the
/// change, blur and Return paths go through the view the app ships.
@MainActor
private final class SyncFolderFieldHarness {
    let window: NSWindow
    let field: NSTextField

    init(model: AppModel, tab: ClipboardTab) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: TabSettingsRow(model: model, tab: tab, onRename: {})
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 140)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        pump(0.4)
        hosting.layoutSubtreeIfNeeded()
        guard let field = Self.textField(in: hosting) else {
            throw UnwrapFailure()
        }
        self.window = window
        self.field = field
    }

    var text: String { field.stringValue }

    /// Replaces the field's contents the way a paste does: one value change.
    func replaceText(_ text: String) {
        field.stringValue = text
        notifyChange()
    }

    /// Appends to the field's contents the way the next keystroke does.
    func type(_ addition: String) {
        field.stringValue += addition
        notifyChange()
    }

    func focus() {
        window.makeFirstResponder(field)
        pump(0.1)
    }

    func blur() {
        window.makeFirstResponder(nil)
    }

    /// Presses Return: the field editor's newline command, which is what AppKit
    /// runs for a Return key press in the field.
    func submit() {
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertNewline(nil)
        } else if let action = field.action {
            NSApp.sendAction(action, to: field.target, from: field)
        }
    }

    func close() {
        window.contentView = nil
    }

    private func notifyChange() {
        field.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, !(view is NSTextView) { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }
}

@MainActor
private func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return condition()
}
