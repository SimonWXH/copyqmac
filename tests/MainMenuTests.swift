// The application main menu installed at launch: the six menus the window
// shows. This is also the guard that the menu bar the activation-policy switch
// makes visible actually has something in it.

import AppKit
import Foundation

@MainActor
private final class MainMenuWindowControllerStub: NSObject, WindowControllerProtocol {
    var isVisible = false
    func show() {}
    func hide() {}
}

func registerMainMenuTests() {
    TestRunner.add("the built main menu contains the application, File, Edit, Item, Tabs, and Help menus") {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let history: ClipboardHistory
            do {
                history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
            } catch {
                TestRunner.fail("could not open the in-memory store: \(error)")
                return
            }
            let actions = AppActions(
                model: AppModel(history: history, isAccessibilityTrusted: { true }),
                windowController: MainMenuWindowControllerStub(),
                presentPreferences: {}
            )

            let menu = MainMenuBuilder.build(actions: actions)

            expectEqual(
                duplicateMenuShortcuts(in: menu),
                [],
                "no two main-menu items may resolve to the same shortcut"
            )

            expectEqual(
                menu.items.map(\.title),
                ["CopyQmac", "File", "Edit", "Item", "Tabs", "Help"],
                "the full application menu is installed, in order"
            )
            expect(
                menu.items.allSatisfy { $0.submenu != nil },
                "every top-level menu title opens a submenu"
            )

            // About, Hide, and Quit live in the application menu; Quit is what
            // makes it recognisable as that menu.
            let appMenu = menu.items.first?.submenu
            expectEqual(appMenu?.items.last?.title, "Quit CopyQmac", "Quit closes the application menu")
            expectEqual(appMenu?.items.last?.keyEquivalent, "q", "Quit keeps Command-Q")

            // Deletion recovery is reachable from File without a window-level redesign.
            let fileMenu = menu.items.first { $0.title == "File" }?.submenu
            expect(
                fileMenu?.items.contains { $0.title == "Reconcile Sync Folders\u{2026}" } == true,
                "File offers the one-shot sync reconciliation"
            )
            expect(
                fileMenu?.items.contains { $0.title == "Empty Sync Trash\u{2026}" } == true,
                "File offers emptying the local sync trash"
            )

            expectEqual(
                fileMenu?.items.filter { $0.title == "Pause Sync" }.count,
                1,
                "File keeps the single global pause control"
            )

            // Help is registered with AppKit, which adds its search field.
            expect(
                menu.items.last?.submenu === NSApplication.shared.helpMenu,
                "the Help menu is the one AppKit knows about"
            )
        }
    }

    TestRunner.add("the shortcut guard agrees with AppKit's key-equivalent dispatch") {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let target = ShortcutGuardTarget()

            func menu(_ specs: [(String, NSEvent.ModifierFlags)]) -> NSMenu {
                let menu = NSMenu(title: "shortcut guard")
                for (index, spec) in specs.enumerated() {
                    let item = NSMenuItem(
                        title: "item \(index)",
                        action: #selector(ShortcutGuardTarget.fire(_:)),
                        keyEquivalent: spec.0
                    )
                    item.keyEquivalentModifierMask = spec.1
                    item.target = target
                    item.tag = index
                    menu.addItem(item)
                }
                return menu
            }

            func dispatchedCollisions(_ specs: [(String, NSEvent.ModifierFlags)]) -> Int {
                let menu = menu(specs)
                var collisions = 0
                for (index, spec) in specs.enumerated() {
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: spec.1,
                        timestamp: 0,
                        windowNumber: 0,
                        context: nil,
                        characters: spec.0,
                        charactersIgnoringModifiers: spec.0,
                        isARepeat: false,
                        keyCode: 0
                    ) else {
                        TestRunner.fail("could not build a key event for the \(spec.0) item")
                        return collisions
                    }
                    target.fired = -1
                    let handled = menu.performKeyEquivalent(with: event)
                    if !handled || target.fired != index {
                        collisions += 1
                    }
                }
                return collisions
            }

            let cases: [(String, [(String, NSEvent.ModifierFlags)], Int)] = [
                (
                    "a key whose mask carries Shift next to the same key with Command only",
                    [("e", [.command]), ("e", [.command, .shift])],
                    1
                ),
                (
                    "a shifted lowercase key next to its uppercase form",
                    [("e", [.command, .shift]), ("E", [.command, .shift])],
                    0
                ),
                (
                    "an uppercase key next to the same lowercase key with Shift in the mask",
                    [("V", [.command]), ("v", [.command, .shift])],
                    0
                ),
            ]
            for (label, specs, expected) in cases {
                expectEqual(
                    duplicateMenuShortcuts(in: menu(specs)).count,
                    expected,
                    "\(label) must be reported with \(expected) duplicate(s)"
                )
                expectEqual(
                    dispatchedCollisions(specs),
                    expected,
                    "\(label) must dispatch the way the guard reports it"
                )
            }
        }
    }
}

private final class ShortcutGuardTarget: NSObject {
    var fired = -1

    @objc func fire(_ sender: NSMenuItem) {
        fired = sender.tag
    }
}
