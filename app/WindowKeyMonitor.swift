import AppKit
import Carbon.HIToolbox
import Foundation

/// Installs a local `keyDown` monitor while the main window is on screen.
final class WindowKeyMonitor {
    private var monitor: Any?
    private var handler: (@MainActor (ListKey, NSEvent.ModifierFlags) -> Bool)?
    private weak var window: NSWindow?

    func start(
        window: NSWindow,
        searchActive: @escaping @MainActor () -> Bool,
        noteEditing: @escaping @MainActor () -> Bool,
        focus: @escaping @MainActor () -> ListFocus,
        handler: @escaping @MainActor (ListKey, NSEvent.ModifierFlags) -> Bool
    ) {
        stop()
        self.window = window
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local NSEvent monitors fire on the main thread; the annotation is
            // what lets this call into main-actor state. Returning Bool rather
            // than the event keeps the closure's result Sendable.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.isKeyWindow else { return false }
                guard let key = Self.map(event) else { return false }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard ListInteractionPolicy.handles(
                    key,
                    noteEditing: noteEditing(),
                    searchEmpty: !searchActive(),
                    commandHeld: flags.contains(.command),
                    focus: focus()
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
    }

    deinit { stop() }

    /// Maps a key event to the list command it means, without deciding whether
    /// the window should act on it; `ListInteractionPolicy` owns that decision.
    private static func map(_ event: NSEvent) -> ListKey? {
        switch Int(event.keyCode) {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Escape: return .escape
        case kVK_Delete, kVK_ForwardDelete: return .delete
        default: return nil
        }
    }
}
