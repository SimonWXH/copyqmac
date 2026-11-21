// Type-to-search: printable typing over the main list starts the same filter
// query the search field edits, while every existing key path keeps its owner.

import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

private func keyEventForPolicy(code: Int, characters: String) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: UInt16(code)
    )
}

func registerTypeToSearchTests() {
    TestRunner.add("type-to-search accepts plain typing on the list or an unfocused window") {
        for focus in [ListFocus.none, .itemList] {
            expectEqual(
                TypeToSearchPolicy.beginsSearch(
                    text: "h", focus: focus, noteEditing: false, plainTyping: true
                ),
                true,
                "\(focus) hands plain printable text to the filter"
            )
        }
        expectEqual(
            TypeToSearchPolicy.beginsSearch(
                text: "你好", focus: .itemList, noteEditing: false, plainTyping: true
            ),
            true,
            "non-ASCII printable text can start a search"
        )
        expectEqual(
            TypeToSearchPolicy.beginsSearch(
                text: " ", focus: .itemList, noteEditing: false, plainTyping: true
            ),
            true,
            "space is search text, not a command"
        )
    }

    TestRunner.add("type-to-search leaves editors, the filter, the sidebar, commands, and control characters alone") {
        for focus in [ListFocus.filter, .sidebar] {
            expectEqual(
                TypeToSearchPolicy.beginsSearch(
                    text: "h", focus: focus, noteEditing: false, plainTyping: true
                ),
                false,
                "\(focus) already owns its keystrokes"
            )
        }
        expectEqual(
            TypeToSearchPolicy.beginsSearch(
                text: "h", focus: .itemList, noteEditing: true, plainTyping: true
            ),
            false,
            "the note editor keeps plain typing"
        )
        expectEqual(
            TypeToSearchPolicy.beginsSearch(
                text: "h", focus: .itemList, noteEditing: false, plainTyping: false
            ),
            false,
            "a modified keystroke belongs to its shortcut"
        )
        expectEqual(
            TypeToSearchPolicy.beginsSearch(
                text: "", focus: .itemList, noteEditing: false, plainTyping: true
            ),
            false,
            "no text cannot start a search"
        )
        expectEqual(
            TypeToSearchPolicy.beginsSearch(
                text: "\n", focus: .itemList, noteEditing: false, plainTyping: true
            ),
            false,
            "control characters are not search text"
        )
    }

    TestRunner.add("WindowKeyMonitor treats only unhandled printable key events as type-to-search text") {
        func keyEvent(code: Int, characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: UInt16(code)
            )
        }
        guard let letter = keyEvent(code: kVK_ANSI_H, characters: "h") else {
            TestRunner.fail("could not build a letter event")
            return
        }
        expectEqual(WindowKeyMonitor.printableText(letter), "h")

        let mapped: [(Int, String)] = [
            (kVK_ANSI_1, "1"),
            (kVK_Return, "\r"),
            (kVK_Escape, "\u{1B}"),
            (kVK_Delete, "\u{8}"),
            (kVK_UpArrow, "\u{F700}"),
            (kVK_DownArrow, "\u{F701}"),
        ]
        for (code, characters) in mapped {
            guard let event = keyEvent(code: code, characters: characters) else {
                TestRunner.fail("could not build a mapped event")
                continue
            }
            expectNil(
                WindowKeyMonitor.printableText(event),
                "keyCode \(code) stays a command, not search text"
            )
        }
        guard let tab = keyEvent(code: kVK_Tab, characters: "\u{9}") else {
            TestRunner.fail("could not build a tab event")
            return
        }
        expectNil(WindowKeyMonitor.printableText(tab), "Tab stays a focus command")
        guard let letterAgain = keyEvent(code: kVK_ANSI_H, characters: "h") else { return }
        expectEqual(WindowKeyMonitor.printableText(letterAgain), "h")
    }

    TestRunner.add("AppModel types into the existing filter and asks the window to focus it") {
        MainActor.assumeIsolated {
            do {
                let model = AppModel(history: ClipboardHistory(store: try ClipboardStore(inMemory: true)))
                let tokensBefore = model.focusSearchToken
                model.beginTypeToSearch(with: "re")
                expectEqual(model.searchText, "re", "typing appends to the one search query")
                expectEqual(model.focusSearchToken, tokensBefore + 1, "the search field takes over")

                model.beginTypeToSearch(with: "port")
                expectEqual(model.searchText, "report", "a phrase accumulates in the filter")
                expectEqual(model.focusSearchToken, tokensBefore + 2)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("typing over the main window filters entries and focuses the search field") {
        MainActor.assumeIsolated {
            do {
                let harness = try TypeToSearchWindowHarness()
                defer { harness.close() }

                expectEqual(harness.model.entries.count, 3, "the unfiltered list shows every item")
                harness.model.setListFocused(true)
                expect(harness.sendKey(code: kVK_ANSI_Z, characters: "z"), "the window dispatches Z")
                expectEqual(harness.model.searchText, "z", "the first typed character becomes the filter query")
                expectEqual(harness.model.keyboardFocus, .filter, "the search field takes the keyboard")
                let filtered = try harness.model.history.search("z")
                expectEqual(filtered.count, 1, "the clipboard history applies the typed query")
                expectEqual(filtered.first?.id, harness.matchID, "the matching entry is in the result set")
                harness.model.reload()
                expectEqual(harness.model.entries.count, 1, "the visible list follows the typed query")
                expectEqual(
                    harness.model.entries.first?.id,
                    harness.matchID,
                    "the matching clipboard entry remains visible"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("typing with a modifier, in the note, or in the filter leaves those owners in charge") {
        MainActor.assumeIsolated {
            do {
                let harness = try TypeToSearchWindowHarness()
                defer { harness.close() }

                harness.model.setListFocused(true)
                expect(
                    harness.sendKey(code: kVK_ANSI_A, characters: "a", flags: .command),
                    "the window dispatches Command-A"
                )
                expectEqual(harness.model.searchText, "", "shortcuts do not start a search")

                harness.model.setFilterFocused(true)
                expect(
                    harness.sendKey(code: kVK_ANSI_A, characters: "a"),
                    "the window dispatches A to the filter"
                )
                expectEqual(harness.model.searchText, "", "the monitor does not steal filter typing")

                harness.model.setSidebarFocused(true)
                expect(
                    harness.sendKey(code: kVK_ANSI_A, characters: "a"),
                    "the window dispatches A to the sidebar"
                )
                expectEqual(harness.model.searchText, "", "sidebar typing stays with the sidebar")

                harness.model.setSidebarFocused(false)
                harness.model.setListFocused(true)
                harness.model.setNoteEditing(true)
                expect(
                    harness.sendKey(code: kVK_ANSI_A, characters: "a"),
                    "the window dispatches A while editing a note"
                )
                expectEqual(harness.model.searchText, "", "note editing keeps every plain character")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("mapped list keys keep their old behavior while type-to-search is available") {
        MainActor.assumeIsolated {
            do {
                let harness = try TypeToSearchWindowHarness()
                defer { harness.close() }

                harness.model.setListFocused(true)
                expect(harness.sendKey(code: kVK_ANSI_1, characters: "1"), "plain digit is dispatched")
                expectEqual(harness.model.searchText, "", "a digit is not swallowed as search text")
                expectEqual(
                    harness.model.handleSidebarNavigation(.home),
                    false,
                    "list focus keeps Home away from the sidebar"
                )
                expectEqual(
                    ListInteractionPolicy.handles(
                        .digit(1), noteEditing: false, searchEmpty: true, focus: .itemList
                    ),
                    true,
                    "plain digit quick paste still works with an empty filter"
                )
                expectEqual(
                    ListInteractionPolicy.handles(
                        .enter, noteEditing: false, searchEmpty: false, focus: .itemList
                    ),
                    true,
                    "Return still activates the selection while a search is active"
                )
                expectEqual(
                    ListInteractionPolicy.handles(
                        .up, noteEditing: false, searchEmpty: false, focus: .itemList
                    ),
                    true,
                    "arrow navigation still works while a search is active"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}

// MARK: - Main-window harness

@MainActor
private final class TypeToSearchKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

/// Hosts the shipped main window (Layout B) and the window's key monitor. It
/// sends real key events through AppKit, so the proof covers the event path an
/// end user exercises instead of only the pure policy.
@MainActor
private final class TypeToSearchWindowHarness {
    let model: AppModel
    let matchID: Int64
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>
    private let keyMonitor = WindowKeyMonitor()

    init() throws {
        _ = NSApplication.shared
        let store = try ClipboardStore(inMemory: true)
        var preferences = try store.preferences()
        preferences.windowLayout = .layoutB
        try store.setPreferences(preferences)
        let history = ClipboardHistory(store: store)
        let match = try Self.insert("zebra searchable needle", into: history)
        matchID = match.id
        _ = try Self.insert("beta other content", into: history)
        _ = try Self.insert("gamma different text", into: history)

        model = AppModel(history: history)
        model.bootstrap()
        hosting = NSHostingView(rootView: AnyView(MainWindowView(model: model, onDismiss: {})))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 900, height: 460))
        window = TypeToSearchKeyableWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 900, height: 460)),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1, height: 1)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        if let list = Self.firstView(of: "EntryTableView", in: hosting) {
            window.makeFirstResponder(list)
        }
        keyMonitor.start(
            window: window,
            searchActive: { [weak model] in !(model?.searchText.isEmpty ?? true) },
            noteEditing: { [weak model] in model?.isEditingNote ?? false },
            focus: { [weak model] in model?.keyboardFocus ?? .none },
            typeToSearch: { [weak model] text in
                guard let model else { return false }
                model.beginTypeToSearch(with: text)
                return true
            },
            handler: { [weak model] key, flags in
                guard let model else { return false }
                return MainWindowController.handle(key: key, model: model, extending: flags.contains(.shift))
            }
        )
        Self.settle(0.6)
    }

    @discardableResult
    func sendKey(code: Int, characters: String, flags: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(code)
        ) else { return false }
        NSApp.sendEvent(event)
        Self.settle(0.3)
        return true
    }

    func close() {
        keyMonitor.stop()
        window.contentView = nil
    }

    private static func insert(_ text: String, into history: ClipboardHistory) throws -> ClipboardEntry {
        let outcome = try history.record([Fixtures.text(text)])
        switch outcome {
        case .inserted(let entry): return entry
        case .duplicate(let entry): return entry
        case .empty: throw UnwrapFailure()
        }
    }

    private static func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func firstView(of className: String, in root: NSView) -> NSView? {
        if NSStringFromClass(type(of: root)).hasSuffix(className) { return root }
        for subview in root.subviews {
            if let found = firstView(of: className, in: subview) { return found }
        }
        return nil
    }
}
