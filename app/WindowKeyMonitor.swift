import AppKit
import Carbon.HIToolbox
import Foundation

/// Installs a local `keyDown` monitor while the main window is on screen.
final class WindowKeyMonitor {
    private var monitor: Any?
    private var handler: (@MainActor (ListKey, NSEvent.ModifierFlags) -> Bool)?
    private var typeToSearch: (@MainActor (String) -> Bool)?
    private weak var window: NSWindow?

    func start(
        window: NSWindow,
        searchActive: @escaping @MainActor () -> Bool,
        noteEditing: @escaping @MainActor () -> Bool,
        focus: @escaping @MainActor () -> ListFocus,
        typeToSearch: @escaping @MainActor (String) -> Bool,
        handler: @escaping @MainActor (ListKey, NSEvent.ModifierFlags) -> Bool
    ) {
        stop()
        self.window = window
        self.handler = handler
        self.typeToSearch = typeToSearch
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local NSEvent monitors fire on the main thread; the annotation is
            // what lets this call into main-actor state. Returning Bool rather
            // than the event keeps the closure's result Sendable.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.isKeyWindow else { return false }
                // A text control already owns its keystrokes, even when the
                // focus token has not caught up (a sheet, a field editor, or
                // the note view). Never type over an active editor.
                if window.firstResponder is NSText { return false }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let plainTyping = flags.subtracting([.shift, .capsLock, .numericPad]).isEmpty
                let currentFocus = focus()
                if let typed = Self.printableText(event),
                   TypeToSearchPolicy.beginsSearch(
                    text: typed,
                    focus: currentFocus,
                    noteEditing: noteEditing(),
                    plainTyping: plainTyping
                   )
                {
                    return self.typeToSearch?(typed) ?? false
                }
                guard let key = Self.map(event) else { return false }
                let otherModifiers = !flags.subtracting([.command, .capsLock, .numericPad, .function]).isEmpty
                guard ListInteractionPolicy.handles(
                    key,
                    noteEditing: noteEditing(),
                    searchEmpty: !searchActive(),
                    commandHeld: flags.contains(.command),
                    hasOtherModifiers: otherModifiers,
                    focus: currentFocus
                ) else { return false }
                if event.isARepeat, ListInteractionPolicy.ignoresKeyRepeat(key) { return true }
                return self.handler?(key, flags) ?? false
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handler = nil
        typeToSearch = nil
    }

    deinit { stop() }

    /// Maps a key event to the list command it means, without deciding whether
    /// the window should act on it; `ListInteractionPolicy` owns that decision.
    static func map(_ event: NSEvent) -> ListKey? {
        map(keyCode: Int(event.keyCode))
    }

    /// Whether the event's characters are printable text rather than a
    /// navigation key, a control character, or a dead key. Search text is
    /// taken from the event, the same text AppKit would deliver to a field.
    static func printableText(_ event: NSEvent) -> String? {
        guard map(event) == nil else { return nil }
        let characters = event.characters ?? ""
        guard !characters.isEmpty else { return nil }
        return TypeToSearchPolicy.beginsSearch(
            text: characters,
            focus: .itemList,
            noteEditing: false,
            plainTyping: true
        ) ? characters : nil
    }

    static func map(keyCode: Int) -> ListKey? {
        switch keyCode {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Escape: return .escape
        case kVK_Delete, kVK_ForwardDelete: return .delete
        case kVK_ANSI_1: return .digit(1)
        case kVK_ANSI_2: return .digit(2)
        case kVK_ANSI_3: return .digit(3)
        case kVK_ANSI_4: return .digit(4)
        case kVK_ANSI_5: return .digit(5)
        case kVK_ANSI_6: return .digit(6)
        case kVK_ANSI_7: return .digit(7)
        case kVK_ANSI_8: return .digit(8)
        case kVK_ANSI_9: return .digit(9)
        default: return nil
        }
    }
}
