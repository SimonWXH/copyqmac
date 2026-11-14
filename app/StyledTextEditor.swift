// The styled editor the Edit Item sheet hosts for HTML and RTF entries.
//
// The sheet must show an entry's own styling (a bold heading stays bold, a
// colour stays that colour) and store the parts it edits, so this hosts a real
// rich-text `NSTextView` rather than SwiftUI's plain `TextEditor`. The editor
// draws the five attributes the item editor can change - bold, italic,
// underline, colour, and size - and the toolbar above it applies them; a
// payload's links travel through the same text unchanged. Content the styled
// save cannot keep is refused at the paste, and the sheet refuses a save whose
// editor content stopped being representable.
//
// It keeps the headroom fix `PlainTextEditor` documents: the first line of a
// CJK paragraph reaches higher than the body font's ascent, and AppKit's clip
// view cut the tops off. The editor reserves `PlainTextEditor.firstLineHeadroom`
// above the first line and uses the same clip-filling scroll view, so the glyph
// box clears the clip and a click below a short document still lands in the
// editor.
//
// Formatting has two paths, as in every AppKit text view: a selection has the
// attribute added to its runs, and an insertion point carries it in the view's
// typing attributes so the next typed characters pick it up. Each command is
// wrapped in `shouldChangeText`/`didChangeText` so Undo works and the sheet's
// text-change notification is posted.

import AppKit
import SwiftUI

// MARK: - Commands

/// The keyboard-driven styling commands. Colour and size are toolbar controls.
enum RichTextFormatCommand {
    case bold
    case italic
    case underline
}

// MARK: - Controller

/// The styling state and commands the toolbar and the editor share.
///
/// The controller is the only object that touches the text view, so the toolbar
/// never needs to know how the selection is stored, and a headless test can
/// drive the same commands the buttons call.
@MainActor
final class RichTextEditingController: ObservableObject {
    /// The traits and attributes at the selection, for the toolbar's state.
    @Published private(set) var isBold = false
    @Published private(set) var isItalic = false
    @Published private(set) var isUnderline = false
    @Published private(set) var color: NSColor = .textColor
    @Published private(set) var pointSize = StyledTextDocument.defaultPointSize
    /// Whether the editor holds any text; the sheet's Save button follows it.
    @Published private(set) var hasText = false

    weak var textView: NSTextView?

    func attach(_ textView: NSTextView) {
        self.textView = textView
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    /// The editor's content as the value the entry stores.
    func document() -> StyledTextDocument {
        guard let textView else { return StyledTextDocument(runs: []) }
        return RichTextEditing.styledDocument(
            from: textView.attributedString(),
            useStoredColors: true
        )
    }

    /// Whether the editor still holds only the content the styled save can keep
    /// in `format`.
    func isRepresentable(for format: RichTextFormat) -> Bool {
        guard let textView else { return true }
        return RichTextEditing.isRepresentable(
            textView.attributedString(),
            format: format,
            requireStoredColors: true
        )
    }

    /// Recomputes the toolbar state from the text view's selection.
    func refresh() {
        guard let textView else { return }
        hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let attributes = selectionAttributes(in: textView)
        let font = attributes[.font] as? NSFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        isBold = traits.contains(.bold)
        isItalic = traits.contains(.italic)
        isUnderline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        pointSize = StyledTextDocument.sanitized(Double(font?.pointSize ?? RichTextEditing.editorFont.pointSize))
        if let stored = attributes[.storedRichTextColor] as? NSColor, stored.type != .catalog {
            color = stored
        } else if let stored = attributes[.foregroundColor] as? NSColor, stored.type != .catalog {
            color = stored
        } else {
            color = .textColor
        }
    }

    private func selectionAttributes(in textView: NSTextView) -> [NSAttributedString.Key: Any] {
        let selection = textView.selectedRange()
        // A selection shows what it would change. A collapsed caret shows the
        // style of the next character typed, which the text view tracks in its
        // typing attributes as the caret moves - including a style the user
        // just asked for, before any text carries it.
        guard selection.length > 0, let storage = textView.textStorage, storage.length > 0 else {
            return textView.typingAttributes
        }
        return storage.attributes(
            at: min(selection.location, storage.length - 1),
            effectiveRange: nil
        )
    }

    // MARK: Commands

    func toggle(_ command: RichTextFormatCommand) {
        switch command {
        case .bold:
            applyFontTrait(.boldFontMask, on: !isBold)
        case .italic:
            applyFontTrait(.italicFontMask, on: !isItalic)
        case .underline:
            applyUnderline(!isUnderline)
        }
        refresh()
        focusEditor()
    }

    func apply(color newColor: NSColor) {
        guard let textView else { return }
        let stored = newColor.usingColorSpace(.sRGB) ?? newColor
        let display = RichTextAppearance.current().adjusted(stored) ?? stored
        EditScope(textView: textView).forEachRange { range in
            if let storage = textView.textStorage {
                storage.addAttribute(.storedRichTextColor, value: stored, range: range)
                storage.addAttribute(.foregroundColor, value: display, range: range)
            }
            textView.typingAttributes[.storedRichTextColor] = stored
            textView.typingAttributes[.foregroundColor] = display
        }
        refresh()
        focusEditor()
    }

    /// Returns the selection to the system's text colour, so it stays legible
    /// in both appearances. The attribute stays on the text - a rich-text run
    /// without a foreground colour draws black in a dark window - but a catalog
    /// colour reads back as "no explicit colour" and is never stored.
    func applyDefaultColor() {
        guard let textView else { return }
        EditScope(textView: textView).forEachRange { range in
            textView.textStorage?.addAttribute(
                .foregroundColor,
                value: NSColor.textColor,
                range: range
            )
            textView.typingAttributes[.foregroundColor] = NSColor.textColor
            textView.textStorage?.removeAttribute(.storedRichTextColor, range: range)
            textView.typingAttributes.removeValue(forKey: .storedRichTextColor)
        }
        refresh()
        focusEditor()
    }

    func apply(pointSize newSize: Double) {
        guard let textView else { return }
        let size = StyledTextDocument.sanitized(newSize)
        EditScope(textView: textView).forEachRange { range in
            guard let storage = textView.textStorage else { return }
            storage.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
                let font = (value as? NSFont) ?? RichTextEditing.editorFont
                storage.addAttribute(.font, value: font.with(pointSize: size), range: runRange)
            }
            if let font = textView.typingAttributes[.font] as? NSFont {
                textView.typingAttributes[.font] = font.with(pointSize: size)
            }
        }
        refresh()
        focusEditor()
    }

    func focusEditor() {
        guard let textView, let window = textView.window,
              window.firstResponder !== textView
        else { return }
        window.makeFirstResponder(textView)
    }

    // MARK: Attribute changes

    private func applyFontTrait(_ trait: NSFontTraitMask, on: Bool) {
        guard let textView else { return }
        EditScope(textView: textView).forEachRange { range in
            guard let storage = textView.textStorage else { return }
            storage.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
                let font = (value as? NSFont) ?? RichTextEditing.editorFont
                storage.addAttribute(
                    .font,
                    value: font.converted(trait: trait, on: on),
                    range: runRange
                )
            }
            if let font = textView.typingAttributes[.font] as? NSFont {
                textView.typingAttributes[.font] = font.converted(trait: trait, on: on)
            }
        }
    }

    private func applyUnderline(_ on: Bool) {
        guard let textView else { return }
        EditScope(textView: textView).forEachRange { range in
            if on {
                textView.textStorage?.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
                textView.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                textView.textStorage?.removeAttribute(.underlineStyle, range: range)
                textView.typingAttributes.removeValue(forKey: .underlineStyle)
            }
        }
    }
}

// MARK: - Edit scope

/// Runs one attribute change over the selection, or over the typing attributes
/// when the caret is collapsed, inside the text view's change notifications.
@MainActor
private struct EditScope {
    let textView: NSTextView

    func forEachRange(_ body: (NSRange) -> Void) {
        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            // Only the typing attributes change; nothing is written to the text.
            body(NSRange(location: selection.location, length: 0))
            return
        }
        guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
        textView.textStorage?.beginEditing()
        body(selection)
        textView.textStorage?.endEditing()
        textView.didChangeText()
        if let storage = textView.textStorage, selection.location < storage.length {
            textView.typingAttributes = storage.attributes(at: selection.location, effectiveRange: nil)
        }
    }
}

// MARK: - Font helpers

private extension NSFont {
    /// The font at a new point size, keeping its family and face.
    func with(pointSize size: Double) -> NSFont {
        NSFont(descriptor: fontDescriptor, size: CGFloat(size))
            ?? NSFont.systemFont(ofSize: CGFloat(size))
    }

    /// The font with a trait on or off, or unchanged when its family has no
    /// such face.
    func converted(trait: NSFontTraitMask, on: Bool) -> NSFont {
        let manager = NSFontManager.shared
        return on
            ? manager.convert(self, toHaveTrait: trait)
            : manager.convert(self, toNotHaveTrait: trait)
    }
}

// MARK: - Text view

/// An `NSTextView` that owns the standard bold/italic/underline shortcuts.
///
/// The sheet has no Format menu, so the key equivalents would otherwise have no
/// target. Handling them in the text view keeps them working while it has
/// keyboard focus, which is exactly when they should apply.
final class StyledTextView: NSTextView {
    var formatHandler: ((RichTextFormatCommand) -> Void)?
    /// The format this item is saved in, which decides whether a pasted
    /// family survives the save.
    var richFormat: RichTextFormat = .html
    /// The font new text is typed in once the user has chosen an editor font:
    /// the first keystroke at the opening caret and text typed into an emptied
    /// item. It is nil while the preference is untouched, which keeps the text
    /// view's own inheritance from the run before the caret.
    var baseFont: NSFont?

    /// Copies the payload's own colours rather than the appearance-adjusted
    /// ones the editor draws, so a paste inside the item cannot turn a display
    /// adjustment into a stored colour.
    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0, let storage = textStorage else {
            super.copy(sender)
            return
        }
        let copied = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: selection)
        )
        var hasStoredColor = false
        copied.enumerateAttribute(
            .storedRichTextColor,
            in: NSRange(location: 0, length: copied.length),
            options: []
        ) { value, range, _ in
            guard let color = value as? NSColor else { return }
            hasStoredColor = true
            copied.addAttribute(.foregroundColor, value: color, range: range)
        }
        guard hasStoredColor else {
            super.copy(sender)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([copied])
    }

    /// Keeps the editor's content representable: a paste that carries no text
    /// representation, or a text representation the styled save cannot keep, is
    /// refused instead of appearing and then disappearing on save. A pasteboard
    /// that also holds a picture still contributes the text it carries.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard canPaste(from: pasteboard) else {
            NSSound.beep()
            return
        }
        let selection = selectedRange()
        let before = (string as NSString).length
        super.paste(sender)
        let after = (string as NSString).length
        let inserted = after - before + selection.length
        guard inserted > 0 else { return }
        normalizeStoredColors(in: NSRange(location: selection.location, length: inserted))
    }

    private func canPaste(from pasteboard: NSPasteboard) -> Bool {
        guard let document = Self.pastedDocument(from: pasteboard) else {
            // A file reference pastes as its path, which is plain text.
            return pasteboard.availableType(from: [.fileURL]) != nil
        }
        // A missing font family is not a reason to refuse a paste: the editor
        // renders the platform's substitution and saves what it shows, the way
        // CopyQ does.
        return RichTextEditing.isRepresentable(document, format: richFormat)
    }

    private static func pastedDocument(from pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .rtf),
           let document = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return document
        }
        if let data = pasteboard.data(forType: .html),
           let document = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ) {
            return document
        }
        if let string = pasteboard.string(forType: .string) {
            return NSAttributedString(string: string)
        }
        return nil
    }

    /// Types the next keystroke in the editor's base font with the system text
    /// colour, which is stored as no explicit colour. Does nothing while the
    /// editor font preference is untouched.
    func useBaseFontForNewText() {
        guard let baseFont else { return }
        typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.textColor,
        ]
    }

    override func didChangeText() {
        if string.isEmpty {
            useBaseFontForNewText()
        }
        super.didChangeText()
    }

    /// Treats a pasted colour as the payload colour and draws its adjusted
    /// version, so the stored colour is the one the paste carried.
    private func normalizeStoredColors(in range: NSRange) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.foregroundColor, in: range, options: []) { value, runRange, _ in
            guard let color = value as? NSColor, color.type != .catalog else { return }
            if storage.attribute(.storedRichTextColor, at: runRange.location, effectiveRange: nil) != nil {
                return
            }
            storage.addAttribute(.storedRichTextColor, value: color, range: runRange)
            if let adjusted = RichTextAppearance.current().adjusted(color) {
                storage.addAttribute(.foregroundColor, value: adjusted, range: runRange)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let command = Self.formatCommand(for: event) {
            formatHandler?(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func formatCommand(for event: NSEvent) -> RichTextFormatCommand? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command,
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else { return nil }
        switch characters {
        case "b": return .bold
        case "i": return .italic
        case "u": return .underline
        default: return nil
        }
    }
}

// MARK: - Editor

/// The styled editing surface: a rich-text `NSTextView` in the same clip-filling
/// scroll view the plain editor uses.
struct RichTextEditor: NSViewRepresentable {
    /// What the editor opens with.
    let seed: StyledTextDocument
    /// The format the item is written back in.
    let format: RichTextFormat
    /// The font the editor draws in, from the History ▸ Fonts preference, or
    /// nil while that preference is untouched. While it is untouched the editor
    /// keeps exactly the behaviour it had before the setting existed: the text
    /// view inherits the formatting of the run before the caret, so the first
    /// keystroke writes that run's style. When a font is chosen, new text is
    /// typed in it: the first keystroke at the opening caret and text typed into
    /// an emptied item, without bold or italic, while text typed inside an
    /// existing run keeps that run's formatting. A document built in code whose
    /// run carries a family this system does not have also draws in it at the
    /// run's own size, and a payload's own families always keep their rendering.
    /// The picker's System
    /// is drawn in the default writing family at the chosen size, because a
    /// styled item cannot carry the system UI font. It is fixed when the editor
    /// loads `seed`, so a live change applies to the next item instead of
    /// restyling text the user is editing.
    var font: NSFont? = nil
    /// The toolbar's connection to this editor.
    let controller: RichTextEditingController
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = controller
        let editor = Self.makeEditor(
            document: seed,
            delegate: context.coordinator,
            format: format,
            font: font
        )
        editor.textView.formatHandler = { [weak controller] command in
            controller?.toggle(command)
        }
        controller.attach(editor.textView)
        editor.scrollView.onWindowAttached = { [weak textView = editor.textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
        return editor.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.controller = controller
        guard let textView = scrollView.documentView as? StyledTextView else { return }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
    }

    /// The editor's real views, so the tests lay out the same `NSTextView` the
    /// sheet installs and drive the same commands.
    static func makeEditor(
        document: StyledTextDocument,
        delegate: NSTextViewDelegate?,
        format: RichTextFormat,
        font: NSFont? = nil
    ) -> (scrollView: PlainTextScrollView, textView: StyledTextView) {
        let textView = StyledTextView()
        textView.richFormat = format
        let baseFont = font.map { RichTextEditing.styledBaseFont($0) }
            ?? RichTextEditing.editorFont
        textView.font = baseFont
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: PlainTextEditor.firstLineHeadroom)
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
        // A chosen font is the base font new text is typed in, so the first
        // keystroke at the opening caret writes it. An untouched preference
        // keeps the text view's own inheritance: the attributes of the run
        // before the caret, as moving the caret there leaves them, or the base
        // font for an empty document. The runs the seed draws keep their own
        // formatting either way.
        textView.baseFont = font == nil ? nil : baseFont
        let attributed = RichTextEditing.attributedText(from: document, baseFont: baseFont)
        textView.textStorage?.setAttributedString(attributed)
        if textView.baseFont != nil {
            textView.useBaseFontForNewText()
        } else if attributed.length > 0 {
            textView.typingAttributes = typingAttributes(in: textView)
        } else {
            textView.typingAttributes = [
                .font: baseFont,
                .foregroundColor: NSColor.textColor,
            ]
        }
        textView.delegate = delegate

        let scrollView = PlainTextScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return (scrollView, textView)
    }

    /// The attributes a keystroke at the current insertion point inherits: the
    /// run before it, or the first run when the caret is at the start, without
    /// the link the text view never types into.
    private static func typingAttributes(in textView: NSTextView) -> [NSAttributedString.Key: Any] {
        guard let storage = textView.textStorage, storage.length > 0 else { return [:] }
        let location = textView.selectedRange().location
        let index = min(max(location - 1, 0), storage.length - 1)
        var attributes = storage.attributes(at: index, effectiveRange: nil)
        attributes.removeValue(forKey: .link)
        return attributes
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var controller: RichTextEditingController

        init(controller: RichTextEditingController) {
            self.controller = controller
        }

        func textDidChange(_ notification: Notification) {
            controller.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.refresh()
        }
    }
}
