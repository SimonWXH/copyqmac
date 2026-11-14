// Paste as Plain Text: deriving text from rich flavours, and writing only that
// text back through the normal paste path.

import AppKit
import Foundation

@MainActor
private final class PlainTextMenuWindowController: NSObject, WindowControllerProtocol {
    var isVisible = false
    func show() {}
    func hide() {}
}

@MainActor
private final class PlainTextPasteFixture {
    let model: AppModel
    let history: ClipboardHistory
    let pasteboard: NSPasteboard
    let entryID: Int64
    let service: PasteService

    init(flavours: [Flavour]) throws {
        history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        pasteboard = NSPasteboard(name: .init("copyqmac-plain-paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let watcher = ClipboardWatcher(history: history, pasteboard: pasteboard)
        service = PasteService(
            tracker: FrontmostAppTracker(),
            watcher: watcher,
            pasteboard: pasteboard,
            requestTrust: { false }
        )
        model = AppModel(history: history, isAccessibilityTrusted: { false })
        model.attach(pasteService: service)
        model.bootstrap()

        guard case .inserted(let entry) = try history.record(flavours) else {
            throw PlainTextPasteFixtureError.duplicateFixture
        }
        entryID = entry.id
        model.reload(capturedEntryID: entry.id)
        model.select(entry.id)
    }

    /// Builds the real application menu and returns the Paste as Plain Text item.
    ///
    /// Creating the shared NSApplication keeps the process headless (no Dock
    /// icon, no window) while still giving AppKit the app object the menu
    /// builder needs.
    func plainTextMenuItem() -> (menu: NSMenu, item: NSMenuItem, actions: AppActions) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let actions = AppActions(
            model: model,
            windowController: PlainTextMenuWindowController(),
            presentPreferences: {}
        )
        let menu = MainMenuBuilder.build(actions: actions)
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        guard let item = items.first(where: { $0.action == #selector(AppActions.pasteSelectedAsPlainText(_:)) })
        else {
            fatalError("the Item menu lost its Paste as Plain Text item")
        }
        return (menu, item, actions)
    }

    /// Sends ⇧⌘V the way a physical key press reaches the menu: the event
    /// carries the layout's unshifted character for Command and the shifted
    /// one for `charactersIgnoringModifiers` (Shift is not ignored there).
    @discardableResult
    func pressShiftCommandV(menu: NSMenu) -> Bool {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true) else {
            TestRunner.fail("could not build a ⇧⌘V key event")
            return false
        }
        cgEvent.flags = [.maskCommand, .maskShift]
        guard let event = NSEvent(cgEvent: cgEvent) else {
            TestRunner.fail("could not build a ⇧⌘V key event")
            return false
        }
        return menu.performKeyEquivalent(with: event)
    }

    @discardableResult
    func waitForPasteboardText(_ text: String, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while pasteboard.string(forType: .string) != text && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return pasteboard.string(forType: .string) == text
    }

    /// Waits for the asynchronous plain-text rewrite to reach the pasteboard.
    /// The rich clipboard can already answer `string(forType:)` through the
    /// pasteboard server, so the text alone is not evidence that our write ran.
    @discardableResult
    func waitForWriteCount(_ count: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while service.writeCount < count && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return service.writeCount >= count
    }

    @discardableResult
    func waitForNotice(_ expected: String, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while model.notice != expected && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return model.notice == expected
    }

    func drain(_ interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

private enum PlainTextPasteFixtureError: Error {
    case duplicateFixture
}

func registerPlainTextPasteTests() {
    TestRunner.add("plain text wins over rich flavours") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("plain & simple".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(#"{\rtf1\ansi rich \b words\b0}"#.utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>rich <b>words</b></p>".utf8)),
        ]
        expectEqual(
            FlavourDecoder.plainTextRepresentation(from: flavours),
            "plain & simple",
            "the plain-text flavour must be preferred over RTF and HTML"
        )
    }

    TestRunner.add("HTML with no plain flavour is stripped to text") {
        let flavours = [
            Flavour(
                itemIndex: 0,
                type: PasteboardTypes.html,
                data: Data("<html><style>p{color:red}</style><body><p>Hello <b>world</b></p></body></html>".utf8)
            )
        ]
        expectEqual(
            FlavourDecoder.plainTextRepresentation(from: flavours),
            "Hello world",
            "HTML-only entries must paste their visible text without tags or CSS"
        )
    }

    TestRunner.add("RTF with no plain flavour is stripped to text") {
        let flavours = [
            Flavour(
                itemIndex: 0,
                type: PasteboardTypes.rtf,
                data: Data(#"{\rtf1\ansi Rich \b text\b0}"#.utf8)
            )
        ]
        expectEqual(
            FlavourDecoder.plainTextRepresentation(from: flavours),
            "Rich text",
            "RTF-only entries must paste their visible text without control words"
        )
    }

    TestRunner.add("compressed rich flavours are decoded before extraction") {
        guard let compressed = QtCompression.compress(Data(#"{\rtf1\ansi Compressed \i text\i0}"#.utf8)) else {
            TestRunner.fail("could not compress the RTF fixture")
            return
        }
        let flavours = [Flavour(itemIndex: 0, type: PasteboardTypes.rtf, rawData: compressed, isCompressed: true)]
        expectEqual(
            FlavourDecoder.plainTextRepresentation(from: flavours),
            "Compressed text",
            "a compressed RTF flavour must be inflated before it is stripped"
        )
    }

    TestRunner.add("multi-item rich entries keep their item order") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(#"{\rtf1\ansi First}"#.utf8)),
            Flavour(itemIndex: 1, type: PasteboardTypes.utf8Text, data: Data("Second".utf8)),
        ]
        expectEqual(
            FlavourDecoder.plainTextRepresentation(from: flavours),
            "First\nSecond",
            "each item must contribute its own text, in pasteboard order"
        )
    }

    TestRunner.add("an entry without text has no plain-text representation") {
        let image = Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)
        expectNil(
            FlavourDecoder.plainTextRepresentation(from: [image]),
            "an image-only entry has no text to paste"
        )
        expectNil(
            FlavourDecoder.plainTextRepresentation(from: [image, Flavour(
                itemIndex: 0,
                type: PasteboardTypes.html,
                data: Data("<img src=\"picture.png\">".utf8)
            )]),
            "HTML markup without visible text has nothing to paste as plain text"
        )
        expectEqual(
            FlavourDecoder.plainTextRepresentation(from: [image, Flavour(
                itemIndex: 0,
                type: PasteboardTypes.html,
                data: Data("<b>x</b>".utf8)
            )]),
            "x",
            "a rich entry with visible HTML text can be pasted as plain text"
        )
    }

    TestRunner.add("menu validation keeps Paste as Plain Text enabled for HTML without visible text") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
                    Flavour(
                        itemIndex: 0,
                        type: PasteboardTypes.html,
                        data: Data("<img src=\"picture.png\">".utf8)
                    ),
                ])
                let (_, item, actions) = fixture.plainTextMenuItem()

                expectEqual(
                    actions.validateMenuItem(item),
                    true,
                    "the item stays enabled so the shortcut cannot turn into a system beep"
                )
                expect(
                    !fixture.model.canPasteSelectedAsPlainText,
                    "an entry with no visible text still has nothing to paste"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the menu item is wired to Shift-Command-V with an explicit target") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(#"{\rtf1\ansi Bold \b text\b0}"#.utf8)),
                ])
                let (_, item, actions) = fixture.plainTextMenuItem()
                expectEqual(item.keyEquivalent, "V", "the key is uppercase for consistency with the other shifted shortcuts")
                expectEqual(
                    item.keyEquivalentModifierMask,
                    [.command, .shift],
                    "the shortcut must be ⇧⌘V, not plain ⌘V"
                )
                expectEqual(
                    item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask),
                    [.command, .shift],
                    "no other modifier may join the shortcut"
                )
                expectEqual(item.action, #selector(AppActions.pasteSelectedAsPlainText(_:)))
                expect(
                    item.target === actions,
                    "the item must target the shared AppActions object, otherwise it is disabled and the key equivalent is swallowed"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("HTML-only and RTF-only entries derive non-empty text end to end") {
        MainActor.assumeIsolated {
            let cases: [(label: String, flavours: [Flavour], expected: String)] = [
                (
                    "HTML",
                    [Flavour(
                        itemIndex: 0,
                        type: PasteboardTypes.html,
                        data: Data("<html><style>p{color:red}</style><body><p>Hello <b>world</b></p></body></html>".utf8)
                    )],
                    "Hello world"
                ),
                (
                    "RTF",
                    [Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(#"{\rtf1\ansi Rich \b text\b0}"#.utf8))],
                    "Rich text"
                ),
            ]

            for testCase in cases {
                do {
                    let fixture = try PlainTextPasteFixture(flavours: testCase.flavours)
                    let (menu, item, actions) = fixture.plainTextMenuItem()
                    expectEqual(
                        actions.validateMenuItem(item),
                        true,
                        "a \(testCase.label)-only entry must enable the shortcut"
                    )
                    let derived = fixture.model.selectedEntryPlainText()
                    expectNotNil(derived, "a \(testCase.label)-only entry must derive text")
                    expect(
                        !(derived ?? "").isEmpty,
                        "a \(testCase.label)-only entry must derive non-empty text so the enabled shortcut cannot fail"
                    )
                    expectEqual(derived, testCase.expected, "\(testCase.label) text is stripped to the visible words")

                    expect(fixture.pressShiftCommandV(menu: menu), "the menu consumes ⇧⌘V")
                    expect(
                        fixture.waitForPasteboardText(testCase.expected),
                        "⇧⌘V pastes the \(testCase.label)-derived text"
                    )
                } catch {
                    TestRunner.fail("threw \(error)")
                }
            }
        }
    }

    TestRunner.add("menu validation stays enabled while the derivation is empty") {
        MainActor.assumeIsolated {
            do {
                let imageOnly = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
                ])
                let (_, imageItem, imageActions) = imageOnly.plainTextMenuItem()
                expectEqual(
                    imageActions.validateMenuItem(imageItem),
                    true,
                    "an image-only entry keeps the item enabled so ⇧⌘V is consumed"
                )
                expectEqual(imageOnly.model.canPasteSelectedAsPlainText, false)
                expectNil(
                    FlavourDecoder.plainTextRepresentation(from: imageOnly.model.selectedEntry?.flavours ?? []),
                    "the derivation the action uses still finds no text"
                )

                let htmlWithText = try PlainTextPasteFixture(flavours: [
                    Flavour(
                        itemIndex: 0,
                        type: PasteboardTypes.html,
                        data: Data("<html><body><p>Hello <b>world</b></p></body></html>".utf8)
                    ),
                ])
                let (_, htmlItem, htmlActions) = htmlWithText.plainTextMenuItem()
                expectEqual(
                    htmlActions.validateMenuItem(htmlItem),
                    true,
                    "an HTML-only entry with visible text enables the item"
                )
                expectEqual(
                    htmlWithText.model.selectedEntryPlainText(),
                    "Hello world",
                    "the enabled state and the action read the same derivation"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("Shift-Command-V on the built menu pastes only the plain text") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(#"{\rtf1\ansi Bold \b text\b0}"#.utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>Bold <b>text</b></p>".utf8)),
                ])
                let (menu, item, actions) = fixture.plainTextMenuItem()
                expectEqual(actions.validateMenuItem(item), true, "the rich entry has text to paste")

                let handled = fixture.pressShiftCommandV(menu: menu)
                expect(handled, "the menu must consume the ⇧⌘V key equivalent")
                expect(
                    fixture.waitForPasteboardText("Bold text"),
                    "⇧⌘V must reach the action and put the stripped text on the pasteboard"
                )
                let types = Set((fixture.pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
                expectEqual(types, [PasteboardTypes.utf8Text], "only one plain-text flavour may be written")
                expectEqual(fixture.service.writeCount, 1, "the key equivalent must paste exactly once")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("Shift-Command-V on an entry without text reports a notice instead of beeping") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
                ])
                let (menu, item, actions) = fixture.plainTextMenuItem()
                expectEqual(actions.validateMenuItem(item), true)
                expect(
                    fixture.pressShiftCommandV(menu: menu),
                    "the enabled item consumes ⇧⌘V instead of letting macOS beep"
                )
                fixture.drain(0.2)
                expectNil(fixture.pasteboard.string(forType: .string), "no text may be written")
                expectEqual(fixture.service.writeCount, 0, "the action must not paste")
                expectEqual(
                    fixture.model.notice,
                    "Paste failed: \(PasteService.noPlainTextMessage)",
                    "the notice explains why the enabled shortcut did nothing"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the plain-text action explains an entry with no text") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
                ])
                expectEqual(fixture.model.canPasteSelectedAsPlainText, false)
                fixture.model.pasteSelectedAsPlainText(dismiss: {})
                fixture.drain(0.2)
                expectNil(fixture.pasteboard.string(forType: .string), "an entry without text must not paste")
                expectEqual(fixture.service.writeCount, 0)
                expectEqual(
                    fixture.model.notice,
                    "Paste failed: \(PasteService.noPlainTextMessage)",
                    "the action explains the same reason the enabled menu item cannot show itself"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the global shortcut source prefers the selection only while the window is open") {
        expectEqual(
            PlainTextPasteSource.choose(windowIsVisible: true, hasSelectedEntry: true),
            .selectedEntry,
            "an open window with a selection uses the selected entry"
        )
        expectEqual(
            PlainTextPasteSource.choose(windowIsVisible: true, hasSelectedEntry: false),
            .clipboard,
            "an open window with no selection falls back to the clipboard"
        )
        expectEqual(
            PlainTextPasteSource.choose(windowIsVisible: false, hasSelectedEntry: true),
            .clipboard,
            "a hidden window uses the clipboard even when a stale selection exists"
        )
        expectEqual(
            PlainTextPasteSource.choose(windowIsVisible: false, hasSelectedEntry: false),
            .clipboard
        )
    }

    TestRunner.add("the global shortcut uses the selected entry while the window is open") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(#"{\rtf1\ansi Entry \b text\b0}"#.utf8)),
                ])
                // A different rich payload is on the live clipboard. The open
                // window means the selected item is what the user means.
                PasteboardBridge.write([
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>Clipboard text</p>".utf8)),
                ], to: fixture.pasteboard)

                fixture.model.pastePlainTextFromGlobalShortcut(
                    windowIsVisible: true,
                    frontmostApp: nil,
                    dismiss: {}
                )

                expect(fixture.waitForWriteCount(1), "the selected entry must be written")
                expectEqual(
                    fixture.pasteboard.string(forType: .string),
                    "Entry text",
                    "the selected entry, not the live clipboard, is pasted"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the global shortcut strips the live clipboard when nothing is selected") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("stale entry".utf8)),
                ])
                fixture.model.select(nil)
                PasteboardBridge.write([
                    Flavour(
                        itemIndex: 0,
                        type: PasteboardTypes.html,
                        data: Data("<html><body><p>Hello <b>clipboard</b></p></body></html>".utf8)
                    ),
                    Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(#"{\rtf1\ansi Hello \b clipboard\b0}"#.utf8)),
                ], to: fixture.pasteboard)

                fixture.model.pastePlainTextFromGlobalShortcut(
                    windowIsVisible: true,
                    frontmostApp: nil,
                    dismiss: {}
                )

                expect(fixture.waitForWriteCount(1), "the clipboard text must be rewritten")
                expectEqual(
                    fixture.pasteboard.string(forType: .string),
                    "Hello clipboard",
                    "the live clipboard is stripped to text when there is no selection"
                )
                let types = Set((fixture.pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
                expectEqual(types, [PasteboardTypes.utf8Text], "the rewrite drops every rich flavour")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the global shortcut uses the clipboard when the window is hidden") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("stale entry".utf8)),
                ])
                PasteboardBridge.write([
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>Clipboard text</p>".utf8)),
                ], to: fixture.pasteboard)

                fixture.model.pastePlainTextFromGlobalShortcut(
                    windowIsVisible: false,
                    frontmostApp: nil,
                    dismiss: {}
                )

                expect(fixture.waitForWriteCount(1), "the clipboard text must be rewritten")
                expectEqual(
                    fixture.pasteboard.string(forType: .string),
                    "Clipboard text",
                    "a hidden window always uses the live clipboard, even with a stale selection"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the global shortcut reports a clipboard with no text") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("stale entry".utf8)),
                ])
                fixture.model.select(nil)
                PasteboardBridge.write([
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
                ], to: fixture.pasteboard)

                var showedNotice = false
                fixture.model.pastePlainTextFromGlobalShortcut(
                    windowIsVisible: false,
                    frontmostApp: nil,
                    dismiss: {},
                    showNotice: { showedNotice = true }
                )
                expect(
                    fixture.waitForNotice("Paste failed: \(PasteService.noClipboardTextMessage)"),
                    "the shortcut explains why the clipboard cannot be pasted as text"
                )

                expectNil(fixture.pasteboard.string(forType: .string), "an image-only clipboard has no text")
                expectEqual(fixture.service.writeCount, 0, "nothing may be written back")
                expect(showedNotice, "the hidden window comes forward so the explanation is visible")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("Paste as Plain Text writes only text and leaves the entry untouched") {
        MainActor.assumeIsolated {
            do {
                let rtf = #"{\rtf1\ansi Bold \b text\b0}"#
                let html = "<p>Bold <b>text</b></p>"
                let flavours = [
                    Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(rtf.utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8)),
                ]
                let fixture = try PlainTextPasteFixture(flavours: flavours)
                expect(fixture.model.canPasteSelectedAsPlainText, "the rich entry has text to paste")

                fixture.model.pasteSelectedAsPlainText(dismiss: {})
                fixture.waitForPasteboardText("Bold text")

                expectEqual(
                    fixture.pasteboard.string(forType: .string),
                    "Bold text",
                    "the pasteboard must carry the stripped text"
                )
                let types = Set((fixture.pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
                expect(!types.contains(PasteboardTypes.rtf), "no RTF flavour may reach the pasteboard")
                expect(!types.contains(PasteboardTypes.html), "no HTML flavour may reach the pasteboard")
                expect(!types.contains(PasteboardTypes.png), "no image flavour may reach the pasteboard")

                let stored = try fixture.history.store.entry(id: fixture.entryID)
                expectEqual(
                    stored?.flavours.map(\.type).sorted(),
                    flavours.map(\.type).sorted(),
                    "the stored entry must keep its original rich flavours"
                )
                expectEqual(fixture.service.writeCount, 1, "the plain paste must write the pasteboard exactly once")
                expectNotNil(
                    fixture.model.notice,
                    "an untrusted paste still reports that it only copied"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("plain-text hotkey problem reports conflict and clears") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PlainTextPasteFixture(flavours: [Fixtures.text("test")])
                expectNil(fixture.model.plainTextHotKeyProblem)
                fixture.model.setPlainTextHotKeyProblem(.conflict(shortcutLabel: "⌥V"))
                expectEqual(
                    fixture.model.plainTextHotKeyProblem,
                    .some(.conflict(shortcutLabel: "⌥V"))
                )
                expectEqual(
                    fixture.model.plainTextHotKeyProblem?.message(language: .english),
                    "⌥V conflicts with the summon shortcut. Choose a different shortcut."
                )
                expectEqual(
                    fixture.model.plainTextHotKeyProblem?.message(language: .simplifiedChinese),
                    "⌥V 与呼出快捷键冲突。请选择其他快捷键。"
                )
                fixture.model.setPlainTextHotKeyProblem(nil)
                expectNil(fixture.model.plainTextHotKeyProblem)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
