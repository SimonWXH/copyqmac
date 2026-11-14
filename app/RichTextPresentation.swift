// Rich text rendering for HTML and RTF clipboard entries.
//
// CopyQ shows a rich item the way it was copied: a heading stays large, bold
// stays bold, and an explicit colour stays that colour. The stored payload is
// HTML or RTF, so the row and the preview pane read it with the system's
// `NSAttributedString` document reader instead of drawing the plain-text
// excerpt that search and paste-back use.
//
// Reading an HTML document is expensive: the first import starts the system
// HTML reader, and a large document takes milliseconds to parse. So parsing
// happens once per entry on the main thread, and both the preview and the
// compact list row are derived from that one parse. `RichTextCache` keeps the
// result in a bounded LRU, and a view body only ever looks the result up by
// entry id.
//
// List rows are compact: the source fonts are scaled into a narrow size band
// so a heading cannot stretch a 44 pt row, and paragraph spacing is dropped.
// The preview pane keeps the source sizes, capped so one enormous heading
// cannot hide the rest of the item. Explicit colours are adjusted for the
// current appearance, because HTML written for a white page would otherwise
// paint black text on CopyQ's dark rows.

import AppKit
import Foundation
import SwiftUI

// MARK: - Appearance

/// The appearance rich text should be legible in.
///
/// The value travels with the parse, so switching appearance cannot produce a
/// row that is half adapted.
enum RichTextAppearance: Equatable, Sendable {
    case light
    case dark

    init(colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }

    @MainActor
    static func current() -> RichTextAppearance {
        guard let appearance = NSApp?.effectiveAppearance else { return .light }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// Blend explicit source colours toward white (dark) or black (light) until
    /// they have enough contrast against the window background. The hue is
    /// preserved, so a red heading stays red instead of becoming grey.
    func adjusted(_ color: NSColor) -> NSColor? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        var red = srgb.redComponent
        var green = srgb.greenComponent
        var blue = srgb.blueComponent
        let alpha = srgb.alphaComponent
        guard alpha > 0.05 else { return nil }

        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        switch self {
        case .dark:
            // Blue and other deep source colours are almost invisible on a
            // dark row, so lift anything below the legibility threshold.
            let target: CGFloat = 0.45
            guard luminance < target else { break }
            let amount = (target - luminance) / max(0.0001, 1 - luminance)
            red += (1 - red) * amount
            green += (1 - green) * amount
            blue += (1 - blue) * amount
        case .light:
            // Yellow and white on a white page are the light-mode equivalent.
            let target: CGFloat = 0.30
            guard luminance > target else { break }
            let amount = (luminance - target) / max(0.0001, luminance)
            red -= red * amount
            green -= green * amount
            blue -= blue * amount
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - Presentation

/// One entry's rich content, already converted to the form SwiftUI draws.
///
/// Both renditions come from the same parse, so a layout pass never asks the
/// document reader to run again.
struct RichTextPresentation: Sendable {
    /// Source sizes, capped for the preview pane.
    let preview: AttributedString
    /// A compact rendition whose fonts fit the fixed-height list row.
    let row: AttributedString
    /// Approximate retained bytes, used by the cache's LRU budget.
    let byteCount: Int
}

/// A completed parse: the original attributed document plus the rendition for
/// one appearance. The cache keeps the document so switching appearance can
/// re-derive both renditions without reading the payload again.
struct RichTextParsed {
    let document: NSAttributedString
    let presentation: RichTextPresentation
}

// MARK: - Builder

@MainActor
enum RichTextBuilder {
    /// Upper bound on the characters rendered from one entry. A pasted novel is
    /// not a useful preview, and the cap keeps a single cache item inside the
    /// byte budget.
    static let maxRenderedCharacters = 50_000

    private static let previewMaximumFontSize: CGFloat = 30
    private static let previewMinimumFontSize: CGFloat = 9
    private static let rowMinimumFontSize: CGFloat = 10.5
    private static let rowMaximumFontSize: CGFloat = 15

    /// Whether any stored flavour is an HTML or RTF payload. Cheap enough to
    /// call on the main thread; it reads type names only.
    nonisolated static func hasRichFlavour(_ flavours: [Flavour]) -> Bool {
        flavours.contains { flavour in
            PasteboardTypes.htmlTypes.contains(flavour.type)
                || PasteboardTypes.rtfTypes.contains(flavour.type)
        }
    }

    /// Reads the entry's rich flavours. Returns nil when the entry has no HTML
    /// or RTF flavour, or when every rich payload is empty or unreadable.
    ///
    /// HTML is preferred over RTF for an item that carries both, which matches
    /// how `FlavourDecoder` labels the entry as HTML. If the preferred payload
    /// fails to produce any text, the other one is tried before giving up.
    static func parse(from flavours: [Flavour], appearance: RichTextAppearance) -> RichTextParsed? {
        guard let document = combinedDocument(from: flavours) else { return nil }
        return parsed(document, appearance: appearance)
    }

    /// Re-derives the two renditions from an already parsed document.
    static func rendition(of document: NSAttributedString, appearance: RichTextAppearance) -> RichTextPresentation {
        let preview = attributedString(
            from: document,
            appearance: appearance,
            variant: .preview
        )
        let row = attributedString(
            from: document,
            appearance: appearance,
            variant: .row
        )
        let byteCount = max(
            1,
            document.length * 8 + preview.characters.count * 16 + row.characters.count * 16
        )
        return RichTextPresentation(preview: preview, row: row, byteCount: byteCount)
    }

    private static func parsed(_ document: NSAttributedString, appearance: RichTextAppearance) -> RichTextParsed? {
        let presentation = rendition(of: document, appearance: appearance)
        guard !presentation.preview.characters.isEmpty else { return nil }
        return RichTextParsed(document: document, presentation: presentation)
    }

    // MARK: Reading the stored payload

    private static func combinedDocument(from flavours: [Flavour]) -> NSAttributedString? {
        let itemsByIndex = Dictionary(grouping: flavours, by: \.itemIndex)
        var pieces: [NSAttributedString] = []
        for itemIndex in itemsByIndex.keys.sorted() {
            guard let itemFlavours = itemsByIndex[itemIndex] else { continue }
            let byType = Dictionary(grouping: itemFlavours, by: \.type)

            let candidates = [
                firstFlavour(in: byType, types: PasteboardTypes.htmlTypes),
                firstFlavour(in: byType, types: PasteboardTypes.rtfTypes),
            ].compactMap { $0 }

            for flavour in candidates {
                guard let parsed = document(from: flavour),
                      let trimmed = trimmed(parsed)
                else { continue }
                pieces.append(trimmed)
                break
            }
        }
        guard !pieces.isEmpty else { return nil }

        let combined = NSMutableAttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                combined.append(NSAttributedString(string: "\n"))
            }
            combined.append(piece)
        }
        if combined.length > maxRenderedCharacters {
            combined.deleteCharacters(
                in: NSRange(location: maxRenderedCharacters, length: combined.length - maxRenderedCharacters)
            )
        }
        return combined
    }

    private static func firstFlavour(in byType: [String: [Flavour]], types: Set<String>) -> Flavour? {
        for type in types.sorted() {
            if let flavour = byType[type]?.first { return flavour }
        }
        return nil
    }

    /// Reads one flavour as an attributed document. Internal rather than
    /// private because the row and preview rendering (`combinedDocument(from:)`)
    /// and the item editor (`RichTextEditing.seed`) both read the payload
    /// through it.
    static func document(from flavour: Flavour) -> NSAttributedString? {
        let data = flavour.data
        guard !data.isEmpty else { return nil }

        var options: [NSAttributedString.DocumentReadingOptionKey: Any]
        if PasteboardTypes.htmlTypes.contains(flavour.type) {
            options = [
                .documentType: NSAttributedString.DocumentType.html,
                // Stored HTML usually has no meta charset. Treat the bytes as
                // UTF-8, which is what the plain-text decoder does too, so the
                // rendered text matches search and paste-back.
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        } else if PasteboardTypes.rtfTypes.contains(flavour.type) {
            options = [.documentType: NSAttributedString.DocumentType.rtf]
        } else {
            return nil
        }

        #if COPYQMAC_TESTING
        RichTextParseProbe.record()
        #endif
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    /// Trims leading and trailing whitespace and drops attachments (inline
    /// images), which the row and preview cannot draw as text.
    private static func trimmed(_ document: NSAttributedString) -> NSAttributedString? {
        let text = document.string as NSString
        guard text.length > 0 else { return nil }

        var start = 0
        var end = text.length
        while start < end, isWhitespace(text.character(at: start)) {
            start += 1
        }
        while end > start, isWhitespace(text.character(at: end - 1)) {
            end -= 1
        }
        guard end > start else { return nil }

        let range = NSRange(location: start, length: end - start)
        return document.attributedSubstring(from: range)
    }

    private static func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: Drawing form

    private enum Variant {
        case preview
        case row
    }

    private static func attributedString(
        from document: NSAttributedString,
        appearance: RichTextAppearance,
        variant: Variant
    ) -> AttributedString {
        var output = AttributedString()
        let fullRange = NSRange(location: 0, length: document.length)
        document.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            // Inline images are attachments: there is no text to draw for them.
            guard attributes[.attachment] == nil else { return }
            let piece = document.attributedSubstring(from: range).string
            guard !piece.isEmpty else { return }

            var segment = AttributedString(piece)
            if let font = attributes[.font] as? NSFont {
                segment.font = Font(scaled(font, variant: variant))
            }
            if let color = attributes[.foregroundColor] as? NSColor,
               let adjusted = appearance.adjusted(color)
            {
                segment.foregroundColor = Color(
                    .sRGB,
                    red: adjusted.redComponent,
                    green: adjusted.greenComponent,
                    blue: adjusted.blueComponent,
                    opacity: adjusted.alphaComponent
                )
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
                segment.underlineStyle = .single
            }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
                segment.strikethroughStyle = .single
            }
            output += segment
        }
        return output
    }

    /// Fits a source font into the size band of the rendition while keeping
    /// its family, weight, and italic/condensed traits.
    private static func scaled(_ font: NSFont, variant: Variant) -> NSFont {
        let size = font.pointSize
        let fitted: CGFloat
        switch variant {
        case .preview:
            fitted = min(max(size, previewMinimumFontSize), previewMaximumFontSize)
        case .row:
            if size >= 20 {
                fitted = rowMaximumFontSize
            } else if size >= 15 {
                fitted = 14
            } else if size >= 12.5 {
                fitted = 13
            } else if size < rowMinimumFontSize {
                fitted = rowMinimumFontSize
            } else {
                fitted = 12.5
            }
        }
        guard fitted != size, let adjusted = NSFont(descriptor: font.fontDescriptor, size: fitted) else {
            return font
        }
        return adjusted
    }
}

// MARK: - Cache

/// Bounded LRU of parsed rich entries, keyed by entry id.
///
/// It mirrors `EntryPresentationCache`: a lookup is a dictionary read, the
/// entry version catches a payload that changed while it was not visible, and
/// the app invalidates by id on edit and delete. The document itself is kept
/// only so an appearance change can re-derive the renditions without reading
/// the payload again.
final class RichTextCache {
    static let defaultByteBudget = 16 * 1024 * 1024

    private struct Item {
        let version: EntryVersion
        let document: NSAttributedString
        var presentation: RichTextPresentation
    }

    private let lock = NSLock()
    private let capacity: Int
    private let byteBudget: Int
    private var items: [Int64: Item] = [:]
    private var recency: [Int64] = []
    private var totalBytes = 0

    init(capacity: Int = 256, byteBudget: Int = RichTextCache.defaultByteBudget) {
        self.capacity = max(1, capacity)
        self.byteBudget = max(1, byteBudget)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    var currentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    /// Pure lookup. Never parses or touches the database.
    func presentation(for entryID: Int64) -> RichTextPresentation? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = items[entryID] else { return nil }
        touch(entryID)
        return item.presentation
    }

    /// Stores a fresh parse, replacing any older version of the entry.
    func store(_ parsed: RichTextParsed?, for entry: ClipboardEntry) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(entry.id)
        guard let parsed else { return }
        guard parsed.presentation.byteCount <= byteBudget else { return }

        while !recency.isEmpty,
              (totalBytes + parsed.presentation.byteCount > byteBudget || items.count >= capacity)
        {
            removeLocked(recency[0])
        }
        items[entry.id] = Item(
            version: EntryVersion(entry),
            document: parsed.document,
            presentation: parsed.presentation
        )
        recency.append(entry.id)
        totalBytes += parsed.presentation.byteCount
    }

    /// Convenience for a caller that can afford to parse inline (such as tests).
    /// Production code coordinates parsing on the main thread and stores with
    /// `store(_:for:)` instead.
    @MainActor
    func presentation(for entry: ClipboardEntry, appearance: RichTextAppearance) -> RichTextPresentation? {
        if let cached = presentation(for: entry.id) {
            return cached
        }
        let parsed = RichTextBuilder.parse(from: entry.flavours, appearance: appearance)
        store(parsed, for: entry)
        return parsed?.presentation
    }

    func invalidate(entryID: Int64) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(entryID)
    }

    func invalidate(entryIDs: Set<Int64>) {
        guard !entryIDs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for id in entryIDs {
            removeLocked(id)
        }
    }

    /// Drops entries whose payload changed. Returns the invalidated ids so the
    /// caller can report one revision for all caches.
    @discardableResult
    func synchronize(with entries: [ClipboardEntry]) -> Set<Int64> {
        guard !entries.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var invalidated: Set<Int64> = []
        for entry in entries {
            guard let item = items[entry.id] else { continue }
            if item.version != EntryVersion(entry) {
                removeLocked(entry.id)
                invalidated.insert(entry.id)
            }
        }
        return invalidated
    }

    /// Rebuilds the light/dark renditions from the parsed documents. The
    /// payload is not read again.
    @MainActor
    func retarget(to appearance: RichTextAppearance) {
        lock.lock()
        defer { lock.unlock() }
        for id in Array(items.keys) {
            guard var item = items[id] else { continue }
            totalBytes -= item.presentation.byteCount
            item.presentation = RichTextBuilder.rendition(of: item.document, appearance: appearance)
            totalBytes += item.presentation.byteCount
            items[id] = item
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
        recency.removeAll()
        totalBytes = 0
    }

    // MARK: LRU

    private func touch(_ entryID: Int64) {
        if let index = recency.firstIndex(of: entryID) {
            recency.remove(at: index)
        }
        recency.append(entryID)
    }

    private func removeLocked(_ entryID: Int64) {
        if let removed = items.removeValue(forKey: entryID) {
            totalBytes -= removed.presentation.byteCount
        }
        if let index = recency.firstIndex(of: entryID) {
            recency.remove(at: index)
        }
    }
}

// MARK: - Test probe

#if COPYQMAC_TESTING
/// Counts document reads so a test can prove a layout pass reuses the cache.
enum RichTextParseProbe {
    private static let lock = NSLock()
    private static var value = 0

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}
#endif
