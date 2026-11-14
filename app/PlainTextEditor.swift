// The plain-text editor the note pane and the plain item sheet type into.
//
// SwiftUI's `TextEditor` on macOS is an `NSTextView` that keeps AppKit's default
// Helvetica 12 and a zero text-container inset. Helvetica's ascent (9.24 pt) is
// shorter than the height a fallback Chinese glyph reaches above the baseline
// (about 10.2 pt at 12 pt), so the first line's tallest glyphs poke above the
// first line fragment and the clip view cuts their tops off. Latin capitals stay
// inside the ascent, which is why only CJK text looked clipped.
//
// `TextEditor` exposes neither the font nor the text-container inset, and
// `.contentMargins`, `.padding`, and the text editor styles all leave the clip
// where it is, so these editors host a real `NSTextView` instead. The plain
// Edit Item editor draws with the configured editor font, the app's body font
// until one is chosen, and the note editor keeps its previous Helvetica 12.
// Both reserve `firstLineHeadroom` above the first line, so the first line's
// glyph tops stay inside the clip.

import AppKit
import SwiftUI

// MARK: - Editor

/// A plain-text editor with a first-line inset.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// The font the editor draws with; the sheet uses the configured editor
    /// font (the app's body font until one is chosen) and the note pane keeps
    /// its previous Helvetica 12.
    var font: NSFont
    /// The focus the owner wants and the focus the editor actually has.
    ///
    /// The note editor drives this from `focusNoteToken`/`noteBlurToken`. The
    /// sheet leaves it nil and just focuses the editor when its window appears.
    var isFocused: Binding<Bool>?
    /// Whether the editor takes keyboard focus as soon as it is installed.
    var focusOnAttach: Bool
    /// Reports the moment editing begins and ends, from the text view's own
    /// first-responder changes.
    ///
    /// The note pane has to start its note-editing session here instead of a
    /// SwiftUI update later: the session is what makes the model accept the
    /// first keystroke, and a keystroke that arrives before it exists would be
    /// dropped.
    var onEditingChanged: ((Bool) -> Void)?
    @Environment(\.isEnabled) private var isEnabled

    init(
        text: Binding<String>,
        font: NSFont? = nil,
        isFocused: Binding<Bool>? = nil,
        focusOnAttach: Bool = false,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._text = text
        self.font = font ?? Self.bodyFont
        self.isFocused = isFocused
        self.focusOnAttach = focusOnAttach
        self.onEditingChanged = onEditingChanged
    }

    /// Space between the top of the scroll view's clip and the first line, so
    /// the first line's tallest glyphs stay inside the clip instead of touching
    /// its edge.
    static let firstLineHeadroom: CGFloat = 2

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: isFocused, onEditingChanged: onEditingChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = Self.makeEditor(
            text: text,
            delegate: context.coordinator,
            font: font
        )
        let coordinator = context.coordinator
        let focusOnAttach = self.focusOnAttach
        let scrollView = editor.scrollView
        coordinator.lastModelText = text
        scrollView.onWindowAttached = { [weak scrollView, weak coordinator] in
            guard let scrollView else { return }
            if focusOnAttach {
                coordinator?.takeFocus(scrollView)
            } else {
                coordinator?.syncFocus(scrollView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = isFocused
        context.coordinator.onEditingChanged = onEditingChanged
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.font != font {
            textView.font = font
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled

        context.coordinator.applyModelText(text, to: textView)
        context.coordinator.syncFocus(scrollView)
    }

    /// The editor's real views, so the tests can configure and lay out the same
    /// `NSTextView` the app installs.
    static func makeEditor(
        text: String,
        delegate: NSTextViewDelegate?,
        font: NSFont? = nil
    ) -> (scrollView: PlainTextScrollView, textView: NSTextView) {
        let textView = NSTextView()
        textView.font = font ?? bodyFont
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: firstLineHeadroom)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.delegate = delegate

        let scrollView = PlainTextScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return (scrollView, textView)
    }

    /// The app's body font: the sheet editor's font until an editor font is
    /// chosen, so it matches its labels and follows the system text size.
    static var bodyFont: NSFont {
        NSFont.preferredFont(forTextStyle: .body)
    }

    /// The note pane's previous font, kept so its text density does not change.
    static var noteFont: NSFont {
        NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>?
        var onEditingChanged: ((Bool) -> Void)?
        /// The model text the last update settled on, so an update that repeats
        /// a value the editor has already moved past cannot erase typing.
        var lastModelText = ""
        /// Whether the editor is editing right now, from its own text callbacks.
        private(set) var isEditing = false

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>?,
            onEditingChanged: ((Bool) -> Void)? = nil
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onEditingChanged = onEditingChanged
        }

        /// Pushes the model's text into the editor when the model is the one
        /// that changed.
        ///
        /// A text view that is being edited is the authority on its own text: the
        /// note pane reports each keystroke to the model through a binding whose
        /// setter only stores a draft once the note-editing session exists, so an
        /// update that lands in between carries the stale value the model still
        /// holds. Writing that value back would delete what the user just typed -
        /// including the first character of a note, which is exactly the window
        /// between the first keystroke and the session starting. Applying it only
        /// when the model itself changed keeps entry switches and external edits
        /// working while never undoing typing.
        func applyModelText(_ text: String, to textView: NSTextView) {
            let modelChanged = text != lastModelText
            lastModelText = text
            guard textView.string != text, modelChanged || !isEditing else { return }
            let selection = textView.selectedRange()
            textView.string = text
            let limit = (text as NSString).length
            textView.setSelectedRange(NSRange(
                location: min(selection.location, limit),
                length: 0
            ))
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
            isFocused?.wrappedValue = true
            onEditingChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            isFocused?.wrappedValue = false
            onEditingChanged?(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        /// Applies the owner's focus request once the view is in a window.
        func syncFocus(_ scrollView: NSScrollView) {
            guard let isFocused, let textView = scrollView.documentView as? NSTextView,
                  let window = textView.window
            else { return }
            if isFocused.wrappedValue {
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            } else if window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
        }

        /// Takes focus for an editor that opens as the focused control.
        func takeFocus(_ scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }
}

/// A scroll view whose document view fills the clip instead of shrinking to the
/// text.
///
/// AppKit's text-in-scroll-view recipe sets the text view's `minSize.height` to
/// the clip height; without it a one-line document is about one line tall, so a
/// click in the empty area below the text lands in the clip view and never
/// reaches the text view.
final class PlainTextScrollView: NSScrollView {
    var onWindowAttached: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onWindowAttached?()
    }

    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let clipSize = contentView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }

        let minimum = NSSize(width: 0, height: clipSize.height)
        let widthChanged = abs(textView.frame.width - clipSize.width) >= 0.5
        if textView.minSize != minimum || widthChanged {
            textView.minSize = minimum
            var frame = textView.frame
            frame.size.width = clipSize.width
            textView.frame = frame
            textView.sizeToFit()
        }

        var frame = textView.frame
        if abs(frame.width - clipSize.width) >= 0.5 || frame.height < clipSize.height {
            frame.size.width = clipSize.width
            frame.size.height = max(frame.height, clipSize.height)
            textView.frame = frame
        }
    }
}
