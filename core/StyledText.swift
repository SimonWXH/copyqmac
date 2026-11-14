// The styled content of an item, and the HTML and RTF bytes it is stored as.
//
// CopyQ's item editor lets the user style text with five attributes: bold,
// italic, underline, colour, and size. The editor shows those attributes and
// the entry keeps them, so the sheet works in this plain value type instead of
// an `NSAttributedString`: it can cross the app/core boundary, it can be
// compared for equality (which is how an unchanged save is recognised), and
// the writers below can be tested without AppKit.
//
// Both writers are canonical. Newlines are normalised, empty runs are dropped,
// and adjacent runs with the same style are merged, so a document read back
// from a payload this module wrote encodes to the same bytes again. That is
// what makes a second save of an untouched entry a byte-for-byte no-op instead
// of a rewrite that marks the entry locally edited.
//
// The fonts the editor can pick are system families, so the family travels with
// each run and is written into the payload. The two writers keep the five
// styling attributes exactly: HTML in CSS pixels (AppKit's HTML reader maps one
// CSS pixel to one point), RTF in half-points plus an sRGB colour table. A
// link's URL is carried through unchanged, so a save keeps the one structure
// the toolbar does not edit. The HTML writer ends the body with the newline the
// reader passes through, so seeding removes exactly that injected newline and a
// genuine trailing newline survives.

import Foundation

// MARK: - Model

/// An explicit sRGB colour, with opaque alpha. Text the editor cannot colour
/// (a pattern colour, or one that would be invisible) carries no colour at all.
public struct StyledTextColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.component(red)
        self.green = Self.component(green)
        self.blue = Self.component(blue)
    }

    private static func component(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// The bytes written to the payload, 0-255.
    var redByte: Int { Int((red * 255).rounded()) }
    var greenByte: Int { Int((green * 255).rounded()) }
    var blueByte: Int { Int((blue * 255).rounded()) }

    /// The thousandths of a percent an RTF sRGB colour table records.
    var redPercent: Int { Int((red * 100_000).rounded()) }
    var greenPercent: Int { Int((green * 100_000).rounded()) }
    var bluePercent: Int { Int((blue * 100_000).rounded()) }

    var hex: String {
        String(format: "%02x%02x%02x", redByte, greenByte, blueByte)
    }
}

/// One run of text and the styling that applies to it.
public struct StyledTextRun: Equatable, Sendable {
    public var text: String
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    /// Nil means the format's default colour (black).
    public var color: StyledTextColor?
    public var pointSize: Double
    public var fontFamily: String
    /// The URL this run links to, or nil for ordinary text.
    public var link: String?

    public init(
        text: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        color: StyledTextColor? = nil,
        pointSize: Double = StyledTextDocument.defaultPointSize,
        fontFamily: String = StyledTextDocument.defaultFontFamily,
        link: String? = nil
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.color = color
        self.pointSize = StyledTextDocument.sanitized(pointSize)
        self.fontFamily = StyledTextDocument.sanitized(fontFamily)
        self.link = link
    }

    func hasSameStyle(as other: StyledTextRun) -> Bool {
        isBold == other.isBold
            && isItalic == other.isItalic
            && isUnderline == other.isUnderline
            && color == other.color
            && pointSize == other.pointSize
            && fontFamily == other.fontFamily
            && link == other.link
    }
}

/// An entry's editable text with its styling.
public struct StyledTextDocument: Equatable, Sendable {
    /// The size the editor offers before the user picks another one, and the
    /// size a run falls back to when it has none.
    public static let defaultPointSize: Double = 13
    /// The family new styled text is written in: a real installed family, unlike
    /// the system UI font's private name, which HTML resolves to Times. It is
    /// also the only representation of a system font a document can carry.
    public static let defaultFontFamily = "Helvetica Neue"

    public private(set) var runs: [StyledTextRun]

    public init(runs: [StyledTextRun]) {
        self.runs = Self.canonical(runs)
    }

    /// The text of the document, which is what the entry's plain-text
    /// companions carry after a save.
    public var plainText: String {
        runs.map(\.text).joined()
    }

    /// True when the document has no text. An empty document is not savable.
    public var hasNoText: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Drops empty runs, normalises line endings, and merges neighbours that
    /// draw the same, so equal content always encodes to equal bytes.
    private static func canonical(_ runs: [StyledTextRun]) -> [StyledTextRun] {
        var result: [StyledTextRun] = []
        for run in runs {
            let text = normalizedNewlines(run.text)
            guard !text.isEmpty else { continue }
            var value = run
            value.text = text
            if let last = result.last, last.hasSameStyle(as: value) {
                result[result.count - 1].text += text
            } else {
                result.append(value)
            }
        }
        return result
    }

    private static func normalizedNewlines(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func sanitized(_ pointSize: Double) -> Double {
        guard pointSize.isFinite, pointSize > 0 else { return defaultPointSize }
        return min(max(pointSize, 1), 1_000)
    }

    static func sanitized(_ fontFamily: String) -> String {
        let trimmed = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFontFamily : trimmed
    }
}

// MARK: - Format

/// The rich format an entry stores its text in.
public enum RichTextFormat: String, Equatable, Sendable, CaseIterable {
    case html
    case rtf

    /// The pasteboard type used when the entry carried no flavour of this
    /// family (an entry that only had a plain-text companion, for instance).
    public var canonicalType: String {
        switch self {
        case .html: return PasteboardTypes.html
        case .rtf: return PasteboardTypes.rtf
        }
    }

    /// The stored types that count as this format.
    public var types: Set<String> {
        switch self {
        case .html: return PasteboardTypes.htmlTypes
        case .rtf: return PasteboardTypes.rtfTypes
        }
    }

    public func contains(_ type: String) -> Bool {
        types.contains(type)
    }

    /// The format a stored type belongs to, if any.
    public static func of(type: String) -> RichTextFormat? {
        for format in allCases where format.contains(type) {
            return format
        }
        return nil
    }
}

// MARK: - Writers

public enum RichTextEncoding {
    /// The payload bytes for a document in its own format.
    public static func data(for document: StyledTextDocument, format: RichTextFormat) -> Data {
        switch format {
        case .html: return Data(html(for: document).utf8)
        case .rtf: return Data(rtf(for: document).utf8)
        }
    }

    /// The family a writer records for a run: the declared name in HTML, and
    /// the default family in RTF when the name is not printable ASCII there.
    public static func writtenFamily(_ family: String, format: RichTextFormat) -> String {
        let family = StyledTextDocument.sanitized(family)
        switch format {
        case .html: return htmlFamily(family)
        case .rtf: return rtfFamily(family)
        }
    }

    // MARK: HTML

    /// A single preformatted block: `white-space: pre-wrap` keeps the user's
    /// line breaks, repeated spaces, and tabs, which HTML would otherwise
    /// collapse. Each run is a span with its own family, size, and colour;
    /// bold/italic/underline are the plain tags AppKit's reader still maps onto
    /// font traits and the underline attribute, and a linked run is an anchor
    /// around them. The newline after the spans is the terminator the reader
    /// passes through, so seeding removes exactly one injected newline and a
    /// genuine trailing newline survives.
    public static func html(for document: StyledTextDocument) -> String {
        var body = ""
        for run in document.runs {
            body += htmlSpan(run, text: run.text)
        }
        body += "\n"
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"></head>\
            <body><div style="white-space: pre-wrap">\(body)</div></body></html>
            """
    }

    private static func htmlSpan(_ run: StyledTextRun, text: String) -> String {
        var style = "font-family:'\(writtenFamily(run.fontFamily, format: .html))';font-size:\(cssSize(run.pointSize))px"
        if let color = run.color {
            style += ";color:#\(color.hex)"
        }
        var piece = htmlEscaped(text)
        if run.isUnderline { piece = "<u>\(piece)</u>" }
        if run.isItalic { piece = "<i>\(piece)</i>" }
        if run.isBold { piece = "<b>\(piece)</b>" }
        if let link = run.link {
            piece = "<a href=\"\(htmlAttributeEscaped(link))\">\(piece)</a>"
        }
        return "<span style=\"\(style)\">\(piece)</span>"
    }

    /// A CSS pixel maps one-to-one to an AppKit point in the system HTML
    /// reader, which is why sizes are written in `px` and not `pt`: the latter
    /// is converted through a 4/3 display scale and comes back larger.
    private static func cssSize(_ pointSize: Double) -> String {
        let rounded = (pointSize * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(rounded)
    }

    private static func htmlFamily(_ family: String) -> String {
        // The style attribute is double-quoted, so a single-quoted CSS family
        // name only needs the quote and the CSS punctuation removed.
        family
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ";", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
    }

    private static func htmlAttributeEscaped(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "\"": output += "&quot;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            default: output.append(character)
            }
        }
        return output
    }

    private static func htmlEscaped(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            default: output.append(character)
            }
        }
        return output
    }

    // MARK: RTF

    /// A flat RTF document. Each run is its own group, so a run's traits end
    /// with it and no state has to be reset between runs, and a run's own
    /// newlines stay inside its group, which keeps their attributes. Colours are
    /// written twice: the device-RGB `\colortbl` every reader understands, and
    /// the sRGB `\*\expandedcolortbl` AppKit prefers, which is what keeps a
    /// chosen colour exactly the colour that comes back. A linked run is an RTF
    /// hyperlink field. Non-ASCII text is written as `\uN?` escapes and a font
    /// family that is not printable ASCII falls back to the default family, so
    /// the payload is pure ASCII and cannot be read back in the wrong byte
    /// encoding.
    public static func rtf(for document: StyledTextDocument) -> String {
        var families: [String] = []
        var colors: [StyledTextColor] = []
        func familyIndex(_ family: String) -> Int {
            if let index = families.firstIndex(of: family) { return index }
            families.append(family)
            return families.count - 1
        }
        func colorIndex(_ color: StyledTextColor) -> Int {
            if let index = colors.firstIndex(of: color) { return index }
            colors.append(color)
            return colors.count - 1
        }

        var body = ""
        for run in document.runs {
            var piece = "{\\f\(familyIndex(run.fontFamily))\\fs\(halfPoints(run.pointSize))"
            if let color = run.color {
                // Index 1 is the first table entry; `\cf0` means the default.
                piece += "\\cf\(colorIndex(color) + 1)"
            }
            if run.isBold { piece += "\\b" }
            if run.isItalic { piece += "\\i" }
            if run.isUnderline { piece += "\\ul" }
            // The space terminates the last control word; a leading space in
            // the run's own text is a second space and survives.
            let text = rtfEscaped(run.text)
            if let link = run.link {
                piece += " " + rtfLinkField(text: text, url: link) + "}"
            } else {
                piece += " " + text + "}"
            }
            body += piece
        }

        var fonts = "{\\fonttbl"
        for (index, family) in families.enumerated() {
            fonts += "{\\f\(index)\\fnil\\fcharset0 \(writtenFamily(family, format: .rtf));}"
        }
        fonts += "}"

        var table = "{\\colortbl ;"
        for color in colors {
            table += "\\red\(color.redByte)\\green\(color.greenByte)\\blue\(color.blueByte);"
        }
        table += "}"

        var expanded = "{\\*\\expandedcolortbl;"
        for color in colors {
            expanded += "\\cssrgb\\c\(color.redPercent)\\c\(color.greenPercent)\\c\(color.bluePercent);"
        }
        expanded += "}"

        return """
            {\\rtf1\\ansi\\ansicpg1252\\deff0
            \(fonts)
            \(table)
            \(expanded)
            \\pard
            \(body)
            }
            """
    }

    private static func rtfLinkField(text: String, url: String) -> String {
        let target = rtfEscaped(
            url
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
        )
        return "{\\field{\\*\\fldinst{HYPERLINK \"\(target)\"}}{\\fldrslt{\(text)}}}"
    }

    private static func halfPoints(_ pointSize: Double) -> Int {
        Int((pointSize * 2).rounded())
    }

    private static func rtfFamily(_ family: String) -> String {
        let stripped = family
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: ";", with: "")
        let isPrintableASCII = stripped.unicodeScalars.allSatisfy {
            $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F
        }
        guard !stripped.isEmpty, isPrintableASCII else {
            return StyledTextDocument.defaultFontFamily
        }
        return stripped
    }

    private static func rtfEscaped(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": output += "\\\\"
            case "{": output += "\\{"
            case "}": output += "\\}"
            case "\n": output += "\\par "
            case "\t": output += "\\tab "
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    output += "\\u\(Int(scalar.value))?"
                } else if scalar.value < 0x80 {
                    output.unicodeScalars.append(scalar)
                } else {
                    // RTF carries UTF-16, so a scalar outside the BMP is two
                    // escapes; a signed 16-bit value is what `\uN` records.
                    for unit in String(scalar).utf16 {
                        output += "\\u\(Int(Int16(bitPattern: unit)))?"
                    }
                }
            }
        }
        return output
    }
}
