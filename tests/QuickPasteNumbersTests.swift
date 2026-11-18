// Quick paste by number: ⌘1 to ⌘9 directly select and paste the corresponding
// visible item, and plain 1 to 9 also paste when the search filter is empty.

import AppKit
import Carbon.HIToolbox
import Foundation

func registerQuickPasteNumbersTests() {
    TestRunner.add("WindowKeyMonitor maps ANSI 1 through 9 to ListKey.digit") {
        let expectedMapping: [(Int, Int)] = [
            (kVK_ANSI_1, 1),
            (kVK_ANSI_2, 2),
            (kVK_ANSI_3, 3),
            (kVK_ANSI_4, 4),
            (kVK_ANSI_5, 5),
            (kVK_ANSI_6, 6),
            (kVK_ANSI_7, 7),
            (kVK_ANSI_8, 8),
            (kVK_ANSI_9, 9),
        ]
        for (keyCode, digit) in expectedMapping {
            expectEqual(WindowKeyMonitor.map(keyCode: keyCode), .digit(digit), "keyCode \(keyCode) maps to digit \(digit)")
        }
        expectNil(WindowKeyMonitor.map(keyCode: kVK_ANSI_0), "ANSI 0 is not a quick paste key")
        expectEqual(WindowKeyMonitor.map(keyCode: kVK_UpArrow), .up)
    }

    TestRunner.add("WindowKeyMonitor maps NSEvent with ANSI digit keyCodes") {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_1)
        ) else {
            TestRunner.fail("failed to construct key event")
            return
        }
        expectEqual(WindowKeyMonitor.map(event), .digit(1))
    }

    TestRunner.add("ListInteractionPolicy ignores key repeat for digit keys") {
        for n in 1...9 {
            expectEqual(ListInteractionPolicy.ignoresKeyRepeat(.digit(n)), true)
            expectEqual(ListInteractionPolicy.alwaysMovesSelection(.digit(n)), false)
        }
    }

    TestRunner.add("ListInteractionPolicy handles Command+digit regardless of search filter") {
        for n in 1...9 {
            // Command+number triggers quick paste even when search filter has text
            expectEqual(
                ListInteractionPolicy.handles(
                    .digit(n),
                    noteEditing: false,
                    searchEmpty: false,
                    commandHeld: true
                ),
                true,
                "⌘\(n) must be handled when search is active"
            )
            expectEqual(
                ListInteractionPolicy.handles(
                    .digit(n),
                    noteEditing: false,
                    searchEmpty: true,
                    commandHeld: true
                ),
                true,
                "⌘\(n) must be handled when search is empty"
            )
        }
    }

    TestRunner.add("ListInteractionPolicy handles plain digit only when search filter is empty") {
        for n in 1...9 {
            // Plain digit pastes only when search is empty
            expectEqual(
                ListInteractionPolicy.handles(
                    .digit(n),
                    noteEditing: false,
                    searchEmpty: true,
                    commandHeld: false
                ),
                true,
                "plain \(n) must be handled when search is empty"
            )
            // When search has text, plain digit must be passed to the text field
            expectEqual(
                ListInteractionPolicy.handles(
                    .digit(n),
                    noteEditing: false,
                    searchEmpty: false,
                    commandHeld: false
                ),
                false,
                "plain \(n) must not be handled when search has input"
            )
        }
    }

    TestRunner.add("ListInteractionPolicy defers digits while editing a note") {
        for n in 1...9 {
            expectEqual(
                ListInteractionPolicy.handles(
                    .digit(n),
                    noteEditing: true,
                    searchEmpty: true,
                    commandHeld: false
                ),
                false,
                "plain \(n) must type into the note editor"
            )
            expectEqual(
                ListInteractionPolicy.handles(
                    .digit(n),
                    noteEditing: true,
                    searchEmpty: false,
                    commandHeld: true
                ),
                false,
                "⌘\(n) must not trigger paste while editing a note"
            )
        }
    }

    TestRunner.add("ListInteractionPolicy rejects digits with other modifiers or out of range") {
        for n in 1...9 {
            expectEqual(
                ListInteractionPolicy.handles(
                    .digit(n),
                    noteEditing: false,
                    searchEmpty: true,
                    commandHeld: false,
                    hasOtherModifiers: true
                ),
                false,
                "digit with Shift/Option/Control must not trigger paste"
            )
            expectEqual(
                ListInteractionPolicy.handles(
                    .digit(n),
                    noteEditing: false,
                    searchEmpty: true,
                    commandHeld: true,
                    hasOtherModifiers: true
                ),
                false,
                "⌘\(n) with other modifiers must not trigger paste"
            )
        }
        expectEqual(
            ListInteractionPolicy.handles(.digit(0), noteEditing: false, searchEmpty: true, commandHeld: true),
            false,
            "digit 0 is out of range"
        )
        expectEqual(
            ListInteractionPolicy.handles(.digit(10), noteEditing: false, searchEmpty: true, commandHeld: true),
            false,
            "digit 10 is out of range"
        )
    }

    TestRunner.add("AppModel selectEntry by display number selects the expected entry") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()

                var entryIDs: [Int64] = []
                for i in 1...4 {
                    let outcome = try history.record(
                        [Fixtures.text("entry \(i)")],
                        at: Date(timeIntervalSince1970: Double(i))
                    )
                    guard case .inserted(let entry) = outcome else {
                        TestRunner.fail("failed to insert fixture \(i)")
                        return
                    }
                    entryIDs.append(entry.id)
                }
                model.reload()
                // Newer entries appear first: entry 4 is row 1, entry 3 is row 2, etc.
                let expectedFirstID = try unwrap(model.entries.first?.id, "first entry")
                let expectedSecondID = model.entries[1].id
                let expectedThirdID = model.entries[2].id

                expectEqual(model.selectEntry(number: 1), true)
                expectEqual(model.selectedEntryID, expectedFirstID, "number 1 selects first visible row")

                expectEqual(model.selectEntry(number: 2), true)
                expectEqual(model.selectedEntryID, expectedSecondID, "number 2 selects second visible row")

                expectEqual(model.selectEntry(number: 3), true)
                expectEqual(model.selectedEntryID, expectedThirdID, "number 3 selects third visible row")

                // Out of range does not change selection and returns false
                expectEqual(model.selectEntry(number: 5), false)
                expectEqual(model.selectedEntryID, expectedThirdID, "out of bounds index does not change selection")

                expectEqual(model.selectEntry(number: 0), false)
                expectEqual(model.selectEntry(number: -1), false)
                expectEqual(model.selectEntry(number: 10), false)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("MainWindowController handles digit key by selecting entry and pasting") {
        MainActor.assumeIsolated {
            do {
                func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
                    let deadline = Date().addingTimeInterval(timeout)
                    while !condition() && Date() < deadline {
                        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                    }
                    return condition()
                }

                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let pasteboard = NSPasteboard(name: .init("copyqmac-quick-paste-\(UUID().uuidString)"))
                pasteboard.clearContents()
                let watcher = ClipboardWatcher(history: history, pasteboard: pasteboard)
                let service = PasteService(
                    tracker: FrontmostAppTracker(),
                    watcher: watcher,
                    pasteboard: pasteboard,
                    requestTrust: { false }
                )
                let model = AppModel(history: history, isAccessibilityTrusted: { false })
                model.attach(pasteService: service)
                model.bootstrap()

                let outcome1 = try history.record([Fixtures.text("first item")], at: Date(timeIntervalSince1970: 10))
                let outcome2 = try history.record([Fixtures.text("second item")], at: Date(timeIntervalSince1970: 20))
                guard case .inserted(let entry1) = outcome1, case .inserted(let entry2) = outcome2 else {
                    TestRunner.fail("failed to insert fixtures")
                    return
                }
                model.reload()
                // entry2 is newest (row 1), entry1 is row 2
                expectEqual(model.entries.map(\.id), [entry2.id, entry1.id])

                var dismissed = false
                let handled = MainWindowController.handle(
                    key: .digit(2),
                    model: model,
                    dismiss: { dismissed = true }
                )
                expectEqual(handled, true)
                expectEqual(model.selectedEntryID, entry1.id, "digit 2 selected second visible row")
                expect(waitUntil({ pasteboard.string(forType: .string) == "first item" }), "entry was placed on pasteboard")
                expectEqual(service.writeCount, 1, "paste service wrote entry to pasteboard")

                // With closeWindow enabled and delivery off (copy-only), activation closes window
                model.setActivation {
                    $0.paste = false
                    $0.focusPreviousApp = false
                    $0.closeWindow = true
                }
                dismissed = false
                MainWindowController.handle(
                    key: .digit(1),
                    model: model,
                    dismiss: { dismissed = true }
                )
                expectEqual(model.selectedEntryID, entry2.id, "digit 1 selected first visible row")
                expectEqual(dismissed, true, "closeWindow option dismisses window on copy-only activation")

                // Out of range digit
                dismissed = false
                let handledOutOfRange = MainWindowController.handle(
                    key: .digit(9),
                    model: model,
                    dismiss: { dismissed = true }
                )
                expectEqual(handledOutOfRange, true)
                expectEqual(dismissed, false, "out of range digit does not paste or dismiss")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
