// Reading a stored rich payload into the styled document the item editor shows,
// and turning what the editor holds back into that document.
//
// The entry keeps HTML or RTF, so the sheet cannot edit the payload directly:
// it needs an attributed string. This file is the only place that crosses
// between the two. `StyledTextDocument` is the value both sides agree on - the
// text, the five edited attributes (bold, italic, underline, colour, size), a
// link per run, and a font family - and it is what `EntryTextEditing` writes
// back in the entry's own format.
//
// The five attributes are the only ones the toolbar changes; a link's URL and
// the text are carried through unchanged. A payload with anything else the
// editor would rewrite - an inline image, a list, paragraph alignment or base
// writing direction other than left or natural, paragraph spacing,
// indentation, a background colour, a strikethrough, a superscript, a font
// family the item's own format cannot record unchanged, or any other structure
// - is not offered the styled editor at all. It keeps the plain editor, whose
// panel says that saving will drop the formatting, instead of silently
// rewriting it.
//
// The system text colour is a catalog `NSColor`, while a parsed payload's
// colours are component based. A catalog colour means "whatever the system
// draws text in", which must not be written into the payload: a white text
// colour recorded in dark mode would be invisible in light mode. It is stored
// as no colour, which is the format's default. An explicit payload colour is
// drawn through `RichTextAppearance.adjusted` so it stays legible on the
// sheet's surface, while the payload's own colour stays in
// `storedRichTextColor` and is what a save writes back.

import AppKit
import Foundation

extension NSAttributedString.Key {
    /// The payload's own colour for a run, kept while `.foregroundColor` holds
    /// the appearance-adjusted colour the editor draws.
    static let storedRichTextColor = NSAttributedString.Key("CopyQmacStoredRichTextColor")
}

@MainActor
enum RichTextEditing {
    /// The font new text is typed in. It is the family the payloads are written
    /// in, so new text looks the same before and after a save. The system UI
    /// font's private family name does not resolve in HTML, so it is not used.
    static var editorFont: NSFont {
        let size = DesignTokens.Typography.defaultBodyFont.pointSize
        return NSFont(name: StyledTextDocument.defaultFontFamily, size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    /// The base font the styled editor draws and types with for a chosen
    /// preference. The styled editor's text has to be writable into a payload,
    /// and a payload has to name a family, so a system face - the picker's
    /// System, or a stored family this system no longer has - is drawn in the
    /// default writing family at the chosen size instead.
    static func styledBaseFont(_ font: NSFont) -> NSFont {
        guard isSystemFamily(font.familyName ?? font.fontName) else { return font }
        return NSFont(name: StyledTextDocument.defaultFontFamily, size: font.pointSize)
            ?? NSFont.systemFont(ofSize: font.pointSize)
    }

    // MARK: Reading an entry

    /// The entry's rich payload as an editable document, or nil when the entry
    /// has to keep the plain editor: no HTML or RTF payload, a payload that will
    /// not read, one without text, or one whose formatting the styled editor
    /// cannot keep.
    static func seed(for entry: ClipboardEntry) -> EntryRichTextEditSeed? {
        guard let format = EntryTextEditing.richFormat(for: entry),
              let stored = attributedDocument(from: entry, format: format)
        else { return nil }

        // The HTML reader terminates the last block with a line break, so an
        // untrimmed seed would gain an empty last line on every open and save.
        let document = format == .html ? removingTrailingNewline(stored) : stored
        guard isRepresentable(document, format: format) else { return nil }
        let styled = styledDocument(from: document)
        guard !styled.hasNoText else { return nil }
        return EntryRichTextEditSeed(format: format, document: styled)
    }

    /// Reads the payload of the single item `EntryTextEditing.richFormat`
    /// accepted, using the same document reader the row and preview use.
    ///
    /// The declared font is not validated: the item opens in the editor
    /// whatever family it names, and the reader substitutes a missing family
    /// exactly as the list and preview draw it. The exception is a family the
    /// item's own writer cannot record unchanged: an RTF family name with
    /// non-ASCII characters keeps the plain editor instead of being silently
    /// renamed on save.
    private static func attributedDocument(
        from entry: ClipboardEntry,
        format: RichTextFormat
    ) -> NSAttributedString? {
        for flavour in entry.flavours
        .filter({ RichTextFormat.of(type: $0.type) == format })
        .sorted(by: { $0.type < $1.type }) {
            if let document = RichTextBuilder.document(from: flavour) {
                return document
            }
        }
        return nil
    }

    private static func removingTrailingNewline(_ document: NSAttributedString) -> NSAttributedString {
        guard document.length > 0, (document.string as NSString).hasSuffix("\n") else {
            return document
        }
        return document.attributedSubstring(from: NSRange(location: 0, length: document.length - 1))
    }

    // MARK: Converting the editor's content

    /// The styled document for an attributed string: the text, the five
    /// attributes the toolbar edits, and the link it carries through unchanged.
    /// `useStoredColors` reads the payload colour the editor keeps beside the
    /// display-adjusted one; the payload reader has no such attribute, so it
    /// reads the foreground colour instead.
    static func styledDocument(
        from attributed: NSAttributedString,
        useStoredColors: Bool = false
    ) -> StyledTextDocument {
        var runs: [StyledTextRun] = []
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attributes, range, _ in
            // An attachment has no text to style; `seed` refuses such payloads.
            guard attributes[.attachment] == nil else { return }
            let text = (attributed.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let color = useStoredColors
                ? attributes[.storedRichTextColor] as? NSColor
                : attributes[.foregroundColor] as? NSColor
            runs.append(StyledTextRun(
                text: text,
                isBold: traits.contains(.bold),
                isItalic: traits.contains(.italic),
                isUnderline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                color: styledColor(color),
                pointSize: Double(font?.pointSize ?? editorFont.pointSize),
                fontFamily: portableFamily(font),
                link: linkString(attributes[.link])
            ))
        }
        return StyledTextDocument(runs: runs)
    }

    /// The attributed string that draws a styled document, which is what the
    /// editor is seeded with and what a test compares against after a reload.
    /// `appearance` is injectable so a test can check the dark rendition.
    /// `baseFont` is the editor's base font, which a run draws in when the
    /// family it carries is not installed on this system, keeping its own size.
    /// A payload run always carries an installed family, because the reader
    /// resolved it, so only a document built in code reaches that fallback.
    static func attributedText(
        from document: StyledTextDocument,
        appearance: RichTextAppearance? = nil,
        baseFont: NSFont? = nil
    ) -> NSAttributedString {
        let appearance = appearance ?? RichTextAppearance.current()
        let result = NSMutableAttributedString()
        for run in document.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: run, baseFont: baseFont),
            ]
            if run.isUnderline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link, let url = URL(string: link) {
                attributes[.link] = url
            }
            // A rich-text run without a foreground colour draws in black even
            // in a dark window; TextKit only follows the appearance when the
            // attribute is present. The system text colour is a catalog colour,
            // which `styledDocument(from:)` reads back as "no explicit colour",
            // so it never reaches the payload.
            if let color = run.color {
                let stored = NSColor(
                    srgbRed: CGFloat(color.red),
                    green: CGFloat(color.green),
                    blue: CGFloat(color.blue),
                    alpha: 1
                )
                attributes[.storedRichTextColor] = stored
                attributes[.foregroundColor] = appearance.adjusted(stored) ?? stored
            } else {
                attributes[.foregroundColor] = NSColor.textColor
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    /// The font for one run: its family and size, with the bold and italic
    /// faces the run's traits ask for. A family this system does not have, which
    /// only a document built in code can carry, falls back to `baseFont` and
    /// then the system font, keeping the run's own size either way.
    static func font(for run: StyledTextRun, baseFont: NSFont? = nil) -> NSFont {
        let size = CGFloat(run.pointSize)
        let ownFamily = NSFont(name: run.fontFamily, size: size)
        let font = ownFamily
            ?? baseFont.flatMap { NSFont(descriptor: $0.fontDescriptor, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        return emphasized(font, ownFamily: ownFamily, bold: run.isBold, italic: run.isItalic)
    }

    /// The font with the bold and italic faces a run asks for.
    ///
    /// `NSFontManager.convert` returns the font unchanged when the family has no
    /// such face, which would silently drop emphasis the payload declared. The
    /// wanted traits are applied together, so a bold italic run keeps both: the
    /// run's own face, its family's regular face, and the system font are tried
    /// in turn, and the first face that carries every wanted trait wins. A
    /// family that cannot supply the combination is substituted rather than
    /// losing a trait.
    private static func emphasized(
        _ font: NSFont,
        ownFamily: NSFont?,
        bold: Bool,
        italic: Bool
    ) -> NSFont {
        var traits: NSFontTraitMask = []
        var symbolic: NSFontDescriptor.SymbolicTraits = []
        if italic {
            traits.insert(.italicFontMask)
            symbolic.insert(.italic)
        }
        if bold {
            traits.insert(.boldFontMask)
            symbolic.insert(.bold)
        }
        guard !symbolic.isEmpty else { return font }
        let candidates: [NSFont] = [font, ownFamily, NSFont.systemFont(ofSize: font.pointSize)]
            .compactMap { $0 }
        for candidate in candidates {
            if let face = face(traits, symbolic: symbolic, of: candidate) {
                return face
            }
        }
        return font
    }

    /// `font` with `traits` applied, or nil when the result does not carry every
    /// wanted `symbolic` trait.
    private static func face(
        _ traits: NSFontTraitMask,
        symbolic: NSFontDescriptor.SymbolicTraits,
        of font: NSFont
    ) -> NSFont? {
        let converted = NSFontManager.shared.convert(font, toHaveTrait: traits)
        return converted.fontDescriptor.symbolicTraits.isSuperset(of: symbolic) ? converted : nil
    }

    private static func linkString(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    /// Whether the editor can keep every attribute in this attributed string.
    /// The five toolbar attributes, a link, and a plain paragraph are the whole
    /// modelled set, and every font family has to be one the writer for `format`
    /// records unchanged. `requireStoredColors` is for the live editor, where a
    /// non-catalog colour must have its payload colour beside the
    /// display-adjusted one; otherwise it would be an adjusted colour that a
    /// save would store.
    static func isRepresentable(
        _ attributed: NSAttributedString,
        format: RichTextFormat,
        requireStoredColors: Bool = false
    ) -> Bool {
        var representable = true
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attributes, _, stop in
            guard isRepresentable(
                attributes,
                format: format,
                requireStoredColors: requireStoredColors
            ) else {
                representable = false
                stop.pointee = true
                return
            }
        }
        return representable
    }

    private static func isRepresentable(
        _ attributes: [NSAttributedString.Key: Any],
        format: RichTextFormat,
        requireStoredColors: Bool
    ) -> Bool {
        if attributes[.attachment] != nil { return false }
        if let paragraphs = attributes[.paragraphStyle] as? NSParagraphStyle,
           !isPlainParagraph(paragraphs) {
            return false
        }
        if let kern = attributes[.kern] as? NSNumber, kern.doubleValue != 0 { return false }
        if let stroke = attributes[.strokeWidth] as? NSNumber, stroke.doubleValue != 0 {
            return false
        }
        if let underline = attributes[.underlineStyle] as? NSNumber,
           underline.intValue != 0,
           underline.intValue != NSUnderlineStyle.single.rawValue {
            return false
        }
        if let font = attributes[.font] as? NSFont {
            if !isRepresentable(font: font, format: format) { return false }
        }
        if requireStoredColors,
           let color = attributes[.foregroundColor] as? NSColor,
           color.type != .catalog,
           attributes[.storedRichTextColor] == nil {
            return false
        }
        for key in attributes.keys {
            switch key {
            case .font, .foregroundColor, .storedRichTextColor, .underlineStyle, .link,
                 .paragraphStyle, .kern, .strokeColor, .strokeWidth:
                continue
            default:
                return false
            }
        }
        return true
    }

    private static func isPlainParagraph(_ style: NSParagraphStyle) -> Bool {
        guard style.alignment == .natural || style.alignment == .left else { return false }
        guard style.baseWritingDirection == .natural
            || style.baseWritingDirection == .leftToRight
        else { return false }
        guard style.textLists.isEmpty, style.textBlocks.isEmpty else { return false }
        guard style.firstLineHeadIndent == 0,
              style.headIndent == 0,
              style.tailIndent == 0
        else { return false }
        guard style.lineSpacing == 0,
              style.lineHeightMultiple == 0,
              style.paragraphSpacing == 0,
              style.paragraphSpacingBefore == 0
        else { return false }
        guard style.headerLevel == 0, style.hyphenationFactor == 0 else { return false }
        return true
    }

    /// Whether the item's own writer records a family name unchanged.
    ///
    /// Fonts are not validated - a family this system does not have stays
    /// editable and the platform substitutes it when rendering - but a save
    /// must not rename the family the editor shows. RTF's font table is ASCII,
    /// so a family name that is not printable ASCII would be rewritten; that
    /// one case falls back to the plain editor instead of renaming it. HTML
    /// records any name.
    static func isRepresentable(family: String, format: RichTextFormat) -> Bool {
        let family = StyledTextDocument.sanitized(family)
        return RichTextEncoding.writtenFamily(family, format: format) == family
    }

    /// Whether a run drawn in this font keeps the family and the faces the
    /// writers record. The writers record a family plus bold and italic; a
    /// stretched, condensed, or vertical face would come back as something
    /// else, so such a font is not representable either.
    static func isRepresentable(font: NSFont, format: RichTextFormat) -> Bool {
        guard isRepresentable(family: portableFamily(font), format: format) else { return false }
        let unsupported = font.fontDescriptor.symbolicTraits.intersection([
            .condensed, .expanded, .vertical,
        ])
        return unsupported.isEmpty
    }

    /// A colour the payload can carry, or nil for the format's default.
    private static func styledColor(_ color: NSColor?) -> StyledTextColor? {
        guard let color else { return nil }
        // A catalog colour is the system's own text colour, which follows the
        // appearance and must never be frozen into the payload.
        guard color.type != .catalog else { return nil }
        guard let srgb = color.usingColorSpace(.sRGB), srgb.alphaComponent > 0.05 else {
            return nil
        }
        return StyledTextColor(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }

    /// The family name a document can carry. The system font has no writable
    /// family name, so it is recorded as the default family.
    private static func portableFamily(_ font: NSFont?) -> String {
        guard let font else { return StyledTextDocument.defaultFontFamily }
        let family = font.familyName ?? font.fontName
        if isSystemFamily(family) {
            return StyledTextDocument.defaultFontFamily
        }
        return family
    }

    /// The system's own families, whose private names cannot be written; the
    /// default family stands in for them.
    private static func isSystemFamily(_ family: String) -> Bool {
        let lowered = family.lowercased()
        return lowered.hasPrefix(".")
            || lowered.hasPrefix("sf pro")
            || lowered == "-apple-system"
            || lowered == "system-ui"
            || lowered == "blinkmacsystemfont"
    }
}
