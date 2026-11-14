// Editing the text of an entry, and creating a new text entry by hand.
//
// A plain-text entry is edited as plain text: the editor speaks for the
// plain-text flavours, images, file URLs, and the itemsync base-name
// bookkeeping flavour are carried over, and every other payload is dropped once
// the text changes. An unchanged save (same text after trimming surrounding
// whitespace) is a no-op and does not mark the entry locally edited.
//
// An entry that stores HTML or RTF is edited as styled text instead: the styled
// editor writes the entry's own rich format back (`RichTextFormat`) and the
// plain-text companions keep the edited text, so paste-back stays consistent.
// A plain-text entry is never upgraded to a rich one.

import Foundation

public enum EntryTextEditingError: Error, Equatable, Sendable {
    case emptyText
    case entryNotFound
    case unsupportedKind
    case multipleItems

    /// Message suitable for the editor sheet or the status bar.
    public var message: String {
        switch self {
        case .emptyText: return "Enter some text before saving."
        case .entryNotFound: return "The item no longer exists."
        case .unsupportedKind: return "This item shows an image or files instead of text. Add a note to describe it."
        case .multipleItems: return "This item holds more than one item and cannot be edited as styled text."
        }
    }
}

/// What the styled editor starts from: the entry's own format and the document
/// the editor opens with.
public struct EntryRichTextEditSeed: Equatable, Sendable {
    public let format: RichTextFormat
    public let document: StyledTextDocument

    public init(format: RichTextFormat, document: StyledTextDocument) {
        self.format = format
        self.document = document
    }
}

/// What the editor starts from.
public struct EntryTextEditSeed: Equatable, Sendable {
    /// The text shown in the editor.
    public let text: String
    /// True when the editor could not use a non-empty stored plain-text
    /// flavour; `text` came from the entry's full preview text, or is empty when
    /// the preview shows no text (an image, a file list, or a non-text payload).
    public let isPreviewFallback: Bool

    public init(text: String, isPreviewFallback: Bool) {
        self.text = text
        self.isPreviewFallback = isPreviewFallback
    }
}

public enum EntryTextEditing {
    /// The text the editor opens with.
    public static func seed(for entry: ClipboardEntry) -> EntryTextEditSeed {
        let preview = FlavourDecoder.preview(for: entry.flavours)
        if let stored = FlavourDecoder.storedPlainText(from: entry.flavours), !stored.isEmpty {
            return EntryTextEditSeed(text: stored, isPreviewFallback: false)
        }
        let fallbackText: String
        switch preview.kind {
        case .text, .html, .rtf:
            fallbackText = preview.searchText ?? preview.text ?? ""
        case .image, .files, .other:
            fallbackText = ""
        }
        return EntryTextEditSeed(text: fallbackText, isPreviewFallback: true)
    }

    /// True when the entry's row and preview show text the editor can change.
    /// Image and file entries draw their payload instead, so editing their
    /// text would be invisible.
    public static func supportsTextEditing(_ entry: ClipboardEntry) -> Bool {
        switch FlavourDecoder.preview(for: entry.flavours).kind {
        case .image, .files: return false
        case .text, .html, .rtf, .other: return true
        }
    }

    /// The rich format the styled editor writes back, or nil when the entry has
    /// to be edited as plain text.
    ///
    /// The styled editor shows one item's payload and a save rewrites that item
    /// and drops every other item, so it is only offered for a single-item
    /// entry, whose flavours all share one item index. A multi-item entry keeps
    /// the plain editor, which shows every item's text joined and collapses it
    /// onto the lowest item index.
    public static func richFormat(for entry: ClipboardEntry) -> RichTextFormat? {
        guard supportsTextEditing(entry) else { return nil }
        guard Set(entry.flavours.map(\.itemIndex)).count == 1 else { return nil }
        let richFlavours = entry.flavours.filter { RichTextFormat.of(type: $0.type) != nil }
        guard let itemIndex = richFlavours.map(\.itemIndex).min() else { return nil }
        let itemFlavours = richFlavours.filter { $0.itemIndex == itemIndex }
        if itemFlavours.contains(where: { RichTextFormat.html.contains($0.type) }) {
            return .html
        }
        return itemFlavours.isEmpty ? nil : .rtf
    }

    /// Rejects text that is empty or only whitespace. Returns the text as typed
    /// so leading and trailing whitespace the user meant to keep is preserved.
    @discardableResult
    public static func validate(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EntryTextEditingError.emptyText
        }
        return text
    }

    /// The flavours for a brand new item created from typed text.
    public static func newItemFlavours(for text: String) throws -> [Flavour] {
        let validated = try validate(text)
        return [textFlavour(type: PasteboardTypes.utf8Text, itemIndex: 0, text: validated)]
    }

    /// The flavour set an entry should have after its text is set to `text`.
    ///
    /// Plain-text flavours are replaced in place, preserving the types the
    /// entry already carried so paste-back keeps its format. A text flavour is
    /// added when the entry had none. When the text changed, only image and
    /// file-URL payloads and the itemsync base-name bookkeeping flavour survive:
    /// HTML, RTF, RTFD, URLs, text-bearing UTI and MIME types, and every other
    /// attachment are dropped because they describe or belong to the old
    /// content. Multi-item text is collapsed onto its lowest item index so the
    /// edited text is not duplicated across items on paste.
    public static func updatedFlavours(for entry: ClipboardEntry, text: String) throws -> [Flavour] {
        let validated = try validate(text)
        let seed = seed(for: entry)
        let textUnchanged = validated == seed.text

        // Saving without a change must not rewrite the entry at all. An entry
        // without a stored text flavour still needs one added, so it falls
        // through even when the preview text was saved unchanged.
        if FlavourDecoder.storedPlainText(from: entry.flavours) != nil, textUnchanged {
            return entry.flavours
        }

        let textFlavours = entry.flavours.filter { PasteboardTypes.textTypes.contains($0.type) }
        let textItemIndex = textFlavours.map(\.itemIndex).min() ?? 0

        var types: [String] = []
        var seenTypes = Set<String>()
        for flavour in textFlavours.sorted(by: { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) })
        where flavour.itemIndex == textItemIndex {
            if seenTypes.insert(flavour.type).inserted {
                types.append(flavour.type)
            }
        }
        if types.isEmpty {
            types = [PasteboardTypes.utf8Text]
        }

        var result = entry.flavours.filter { flavour in
            if PasteboardTypes.textTypes.contains(flavour.type) { return false }
            if !textUnchanged {
                return flavour.type == Fingerprint.syncBaseNameFlavour
                    || FlavourDecoder.isImageType(flavour.type)
                    || flavour.type == PasteboardTypes.fileURL
                    || flavour.type == PasteboardTypes.legacyFilenames
            }
            return true
        }
        for type in types {
            result.append(textFlavour(type: type, itemIndex: textItemIndex, text: validated))
        }
        return result.sorted { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) }
    }

    /// The flavour set an entry should have after a styled edit.
    ///
    /// The entry's own rich format is rewritten in place: HTML for an HTML
    /// item, RTF for an RTF item. The other rich family is dropped, because it
    /// described the old styling and keeping it would paste a stale version of
    /// the same text. The plain-text companions are rewritten with the edited
    /// text so paste-back and search stay consistent, keeping their existing
    /// types. As with a plain edit, only image and file-URL payloads and the
    /// itemsync base-name bookkeeping flavour survive: any other attachment
    /// belonged to the old content. An entry with more than one item is refused
    /// rather than collapsed onto its lowest item, because the styled editor
    /// only ever shows one item.
    public static func updatedFlavours(
        for entry: ClipboardEntry,
        format: RichTextFormat,
        richData: Data,
        plainText: String
    ) throws -> [Flavour] {
        let validated = try validate(plainText)
        guard Set(entry.flavours.map(\.itemIndex)).count == 1 else {
            throw EntryTextEditingError.multipleItems
        }

        let richFlavours = entry.flavours.filter { RichTextFormat.of(type: $0.type) != nil }
        let richItemIndex = richFlavours.map(\.itemIndex).min() ?? 0
        var richTypes: [String] = []
        var seenRichTypes = Set<String>()
        for flavour in richFlavours.sorted(by: { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) })
        where flavour.itemIndex == richItemIndex && format.contains(flavour.type) {
            if seenRichTypes.insert(flavour.type).inserted {
                richTypes.append(flavour.type)
            }
        }
        if richTypes.isEmpty {
            richTypes = [format.canonicalType]
        }

        let textFlavours = entry.flavours.filter { PasteboardTypes.textTypes.contains($0.type) }
        let textItemIndex = textFlavours.map(\.itemIndex).min() ?? 0
        var textTypes: [String] = []
        var seenTextTypes = Set<String>()
        for flavour in textFlavours.sorted(by: { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) })
        where flavour.itemIndex == textItemIndex {
            if seenTextTypes.insert(flavour.type).inserted {
                textTypes.append(flavour.type)
            }
        }
        if textTypes.isEmpty {
            textTypes = [PasteboardTypes.utf8Text]
        }

        var result = entry.flavours.filter { flavour in
            if PasteboardTypes.textTypes.contains(flavour.type) { return false }
            if RichTextFormat.of(type: flavour.type) != nil { return false }
            return flavour.type == Fingerprint.syncBaseNameFlavour
                || FlavourDecoder.isImageType(flavour.type)
                || flavour.type == PasteboardTypes.fileURL
                || flavour.type == PasteboardTypes.legacyFilenames
        }
        for type in richTypes {
            result.append(Flavour(itemIndex: richItemIndex, type: type, data: richData))
        }
        for type in textTypes {
            result.append(textFlavour(type: type, itemIndex: textItemIndex, text: validated))
        }
        let sorted = result.sorted { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) }
        // An unchanged save must leave the entry alone: same bytes, same plain
        // text, nothing to mark locally edited.
        return Set(sorted) == Set(entry.flavours) ? entry.flavours : sorted
    }

    private static func textFlavour(type: String, itemIndex: Int, text: String) -> Flavour {
        Flavour(itemIndex: itemIndex, type: type, data: encoded(text, as: type))
    }

    private static func encoded(_ text: String, as type: String) -> Data {
        switch type {
        case PasteboardTypes.utf16Text:
            return text.data(using: .utf16LittleEndian) ?? Data(text.utf8)
        case PasteboardTypes.utf16ExternalText:
            // External UTF-16 carries a byte-order mark, which is what
            // `FlavourDecoder.decodeText` looks for before falling back.
            return text.data(using: .utf16) ?? Data(text.utf8)
        default:
            return Data(text.utf8)
        }
    }
}
