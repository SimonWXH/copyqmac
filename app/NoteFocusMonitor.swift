// Ends note editing before the click that leaves the note editor is delivered.
//
// The note editor is an `NSTextView` (`PlainTextEditor`). While it holds the
// keyboard, the click that moves the selection to another row can be consumed
// as "the editor is ending editing", and the editor's own write-back of its text
// then re-renders the list in the middle of that click - which is what made the
// selection look stuck after a note was edited. Committing the draft and
// dropping focus on mouse-down, before the list handles the click, keeps the
// order the other way round: commit, blur, then select.
//
// Clicks inside the editor are left untouched so the caret still moves.

import AppKit
import Foundation

final class NoteFocusMonitor {
    private var monitor: Any?
    private weak var window: NSWindow?

    func start(
        window: NSWindow,
        noteEditing: @escaping @MainActor () -> Bool,
        commitNote: @escaping @MainActor () -> Void
    ) {
        stop()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Local monitors fire on the main thread; the annotation is what lets
            // this call into main-actor state. The event is never swallowed.
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      noteEditing(), !Self.clickLandedInNoteEditor(event, window: window)
                else { return }
                commitNote()
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }

    /// True when the click is inside the focused note editor.
    ///
    /// `isFieldEditor` separates the standalone `NSTextView` behind
    /// `PlainTextEditor` from the shared field editor a `TextField` (the filter)
    /// uses, so a click into the filter is treated as a click outside the note
    /// editor.
    private static func clickLandedInNoteEditor(_ event: NSEvent, window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView, !textView.isFieldEditor else {
            return false
        }
        let frame = textView.convert(textView.bounds, to: nil)
        return frame.contains(event.locationInWindow)
    }
}
