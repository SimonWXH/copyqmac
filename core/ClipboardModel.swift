// Clipboard model: the flavour-preserving representation of one clipboard
// change, plus the pure decoding used to build previews and search text.
//
// This file deliberately depends only on system frameworks. It never
// touches NSPasteboard, so it can be compiled and exercised headlessly by the
// test target.

import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Flavours

/// One raw flavour of one pasteboard item.
///
/// `type` is the pasteboard type identifier exactly as the system reports it
/// (a UTI such as `public.utf8-plain-text`, or a legacy name such as
/// `NSStringPboardType`). `data` is the untouched byte payload, which is what
/// lets an entry be written back to the pasteboard without lossy conversion.
public struct Flavour: Codable, Equatable, Hashable, Sendable {
    /// Index of the pasteboard item this flavour belongs to. A single pasteboard
    /// change can carry several items (for example multiple file URLs), and each
    /// item carries its own set of flavours. Preserving the index preserves that
    /// structure on paste-back.
    public var itemIndex: Int
    public var type: String
    private var rawPayload: Data
    private var isCompressedPayload: Bool

    public var data: Data {
        get {
            if isCompressedPayload {
                return (try? QtCompression.decompress(rawPayload)) ?? rawPayload
            }
            return rawPayload
        }
        set {
            rawPayload = newValue
            isCompressedPayload = false
        }
    }

    public init(itemIndex: Int, type: String, data: Data) {
        self.itemIndex = itemIndex
        self.type = type
        self.rawPayload = data
        self.isCompressedPayload = false
    }

    public init(itemIndex: Int, type: String, rawData: Data, isCompressed: Bool) {
        self.itemIndex = itemIndex
        self.type = type
        self.rawPayload = rawData
        self.isCompressedPayload = isCompressed
    }

    public var isCompressed: Bool {
        isCompressedPayload
    }

    public var rawData: Data {
        rawPayload
    }

    /// Uncompressed byte count without decompressing the payload.
    public var uncompressedByteCount: Int {
        if isCompressedPayload {
            if rawPayload.count >= 4 {
                let size = rawPayload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                return Int(size)
            }
            return rawPayload.count
        }
        return rawPayload.count
    }

    public var sampleFirstByte: UInt8? {
        rawPayload.first
    }

    public var sampleLastByte: UInt8? {
        rawPayload.last
    }

    enum CodingKeys: String, CodingKey {
        case itemIndex, type, data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemIndex = try container.decode(Int.self, forKey: .itemIndex)
        type = try container.decode(String.self, forKey: .type)
        rawPayload = try container.decode(Data.self, forKey: .data)
        isCompressedPayload = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemIndex, forKey: .itemIndex)
        try container.encode(type, forKey: .type)
        try container.encode(data, forKey: .data)
    }

    public static func == (lhs: Flavour, rhs: Flavour) -> Bool {
        guard lhs.itemIndex == rhs.itemIndex, lhs.type == rhs.type else { return false }
        if lhs.isCompressedPayload == rhs.isCompressedPayload && lhs.rawPayload == rhs.rawPayload {
            return true
        }
        return lhs.data == rhs.data
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(itemIndex)
        hasher.combine(type)
        hasher.combine(data)
    }
}

// MARK: - Entry

/// One recorded clipboard change.
public struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64
    public var createdAt: Date
    public var pinned: Bool
    /// The tab this entry lives in. Every entry belongs to exactly one tab.
    public var tabID: Int64
    /// Free-form note attached by the user (F-05). Empty when there is none.
    public var note: String
    public var flavours: [Flavour]

    public init(
        id: Int64 = 0,
        createdAt: Date,
        pinned: Bool = false,
        tabID: Int64 = ClipboardTab.unsavedID,
        note: String = "",
        flavours: [Flavour]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pinned = pinned
        self.tabID = tabID
        self.note = note
        self.flavours = flavours
    }

    /// Stable identity of the payload, independent of time and pin state.
    /// Used to collapse consecutive duplicates.
    public var fingerprint: String { Fingerprint.of(flavours) }

    public var hasSyncBaseName: Bool {
        flavours.contains { $0.type == Fingerprint.syncBaseNameFlavour }
    }

    /// True when the entry holds nothing a user can see, paste, or keep:
    /// every flavour is one of our own bookkeeping markers, or there is no
    /// flavour at all, and there is no note or pin to preserve.
    ///
    /// A sync item that carried no payload reaches the store as exactly this
    /// shape, because import still records the file name it came from. Such an
    /// entry is an artefact of import and must never travel back out to an
    /// archive, a sync folder, or the pasteboard.
    public var hasOnlyInternalFlavours: Bool {
        guard note.isEmpty, !pinned else { return false }
        return flavours.allSatisfy { Fingerprint.isBookkeepingFlavour($0.type) }
    }

    /// The highest pasteboard item index present, or 0 when empty.
    public var itemCount: Int {
        (flavours.map(\.itemIndex).max() ?? -1) + 1
    }
}

// MARK: - Fingerprint

public enum Fingerprint {
    /// Bookkeeping flavour that preserves a sync item's original file stem so
    /// write-back can reuse it. It is part of the item's identity, so distinct
    /// sync files never collapse into one entry.
    public static let syncBaseNameFlavour = "application/x-copyq-itemsync-base-name"

    public static func isBookkeepingFlavour(_ type: String) -> Bool {
        type == syncBaseNameFlavour
            || type.hasPrefix("application/x-copyq-itemsync-")
            || type.hasPrefix("application/x-copyq-private-")
    }

    /// SHA-256 over a canonical byte serialisation of the flavours.
    ///
    /// Flavours are sorted by (itemIndex, type) so that a reordering of the
    /// system's type list does not read as a new payload, and every field is
    /// length-prefixed so that no two distinct payloads can serialise the same.
    public static func of(_ flavours: [Flavour]) -> String {
        #if COPYQMAC_TESTING
        FingerprintProbe.record()
        #endif
        return hash(flavours)
    }

    /// SHA-256 over the payload flavours only, ignoring sync bookkeeping.
    ///
    /// Import paths use this as the second deduplication level for rows that
    /// predate the base-name flavour.
    public static func payload(of flavours: [Flavour]) -> String {
        #if COPYQMAC_TESTING
        FingerprintProbe.record()
        #endif
        return hash(flavours.filter { !isBookkeepingFlavour($0.type) })
    }

    private static func hash(_ flavours: [Flavour]) -> String {
        var hasher = SHA256Digest()
        appendField(Array("copyqmac.entry.v2".utf8), to: &hasher)
        let ordered = flavours.sorted {
            ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type)
        }
        appendField(bytes(of: UInt64(ordered.count)), to: &hasher)
        for flavour in ordered {
            appendField(bytes(of: Int64(flavour.itemIndex)), to: &hasher)
            appendField(Array(flavour.type.utf8), to: &hasher)
            appendField(Array(flavour.data), to: &hasher)
        }
        return hasher.finalize()
    }

    private static func appendField(_ bytes: [UInt8], to hasher: inout SHA256Digest) {
        hasher.update(UInt64(bytes.count))
        hasher.update(bytes)
    }

    private static func bytes(of value: UInt64) -> [UInt8] {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Array($0) }
    }

    private static func bytes(of value: Int64) -> [UInt8] {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Array($0) }
    }
}

#if COPYQMAC_TESTING
/// Counts fingerprint computations so a test can prove a rendering path stays
/// away from hashing. Only compiled into the test target.
public enum FingerprintProbe {
    private static let lock = NSLock()
    private static var value = 0

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        value = 0
    }

    public static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}
#endif

// MARK: - Content kinds and previews

public enum ClipboardContentKind: String, Codable, Sendable {
    case text
    case html
    case rtf
    case image
    case files
    case other
}

/// A render-ready description of an entry, produced without AppKit so that it
/// can be unit tested headlessly. The UI turns `imageData` into an `NSImage`.
public struct EntryPreview: Equatable, Sendable {
    public var kind: ClipboardContentKind
    /// Text excerpt for text/HTML/RTF entries.
    public var text: String?
    /// Full text used for search indexing (not truncated the way `text` is).
    public var searchText: String?
    /// UTI and raw bytes of the preferred image flavour, when the entry is one.
    public var imageType: String?
    public var imageData: Data?
    /// File names plus paths for file-URL entries.
    public var fileURLs: [URL]

    public init(
        kind: ClipboardContentKind,
        text: String? = nil,
        searchText: String? = nil,
        imageType: String? = nil,
        imageData: Data? = nil,
        fileURLs: [URL] = []
    ) {
        self.kind = kind
        self.text = text
        self.searchText = searchText
        self.imageType = imageType
        self.imageData = imageData
        self.fileURLs = fileURLs
    }

    public var fileNames: [String] { fileURLs.map(\.lastPathComponent) }
}

// MARK: - Pasteboard type identifiers

public enum PasteboardTypes {
    public static let utf8Text = "public.utf8-plain-text"
    public static let utf16Text = "public.utf16-plain-text"
    public static let utf16ExternalText = "public.utf16-external-plain-text"
    public static let plainText = "public.plain-text"
    public static let legacyText = "NSStringPboardType"
    public static let mimeText = "text/plain"
    public static let mimeTextUtf8 = "text/plain;charset=utf-8"

    public static let rtf = "public.rtf"
    public static let legacyRTF = "NSRTFPboardType"
    public static let mimeRtf = "text/rtf"

    public static let html = "public.html"
    public static let legacyHTML = "NSHTMLPboardType"
    public static let mimeHtml = "text/html"

    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let jpeg = "public.jpeg"
    public static let heic = "public.heic"

    public static let fileURL = "public.file-url"
    public static let legacyFilenames = "NSFilenamesPboardType"
    public static let mimeUriList = "text/uri-list"

    public static let url = "public.url"

    public static let textTypes: Set<String> = [
        utf8Text, utf16Text, utf16ExternalText, plainText, legacyText,
        mimeText, mimeTextUtf8,
    ]
    public static let rtfTypes: Set<String> = [rtf, legacyRTF, mimeRtf]
    public static let htmlTypes: Set<String> = [html, legacyHTML, mimeHtml]
    public static let fileTypes: Set<String> = [fileURL, legacyFilenames, mimeUriList]
}

// MARK: - Decoding

public enum FlavourDecoder {
    /// Preferred order when several text flavours are present.
    private static let textPreference = [
        PasteboardTypes.utf8Text,
        PasteboardTypes.plainText,
        PasteboardTypes.mimeText,
        PasteboardTypes.mimeTextUtf8,
        PasteboardTypes.utf16Text,
        PasteboardTypes.utf16ExternalText,
        PasteboardTypes.legacyText,
    ]

    static func textPreferenceRank(_ type: String) -> Int? {
        textPreference.firstIndex(of: type)
    }

    /// Builds a preview and searchable text from a set of raw flavours, aggregating
    /// text items across multi-item snapshots.
    public static func preview(for flavours: [Flavour]) -> EntryPreview {
        let byType = Dictionary(grouping: flavours, by: \.type)

        // 1. File URLs come first, ahead of images. A file copied in Finder
        //    carries the file's icon as `com.apple.icns` and `public.tiff` in
        //    addition to `public.file-url`, and CopyQ shows such an entry as the
        //    file name, not as an icon thumbnail. The image flavours stay stored
        //    so paste-back still writes the whole payload back.
        if let fileURLs = fileURLs(from: flavours), !fileURLs.isEmpty {
            let names = fileURLs.map(\.lastPathComponent)
            let listing = names.joined(separator: "\n")
            // Index the names and the full paths so searching for a file name, a
            // folder, or a partial path all work.
            let searchText = (names + fileURLs.map(\.path)).joined(separator: "\n")
            return EntryPreview(kind: .files, text: listing, searchText: searchText, fileURLs: fileURLs)
        }

        // 2. Images win visually next, since a thumbnail is the most informative
        //    preview and image payloads usually also carry a text flavour.
        //    CopyQ prefers image/png, then bmp, jpeg, gif, then any image/*.
        let rankedImages = flavours
            .filter { isImageType($0.type) }
            .sorted { lhs, rhs in
                let rankL = imagePreferenceRank(lhs.type)
                let rankR = imagePreferenceRank(rhs.type)
                if rankL != rankR { return rankL < rankR }
                return (lhs.itemIndex, lhs.type) < (rhs.itemIndex, rhs.type)
            }

        for imageFlavour in rankedImages {
            let data = imageFlavour.data
            if isDecodableImage(data) {
                let summary = imageSummary(type: imageFlavour.type, data: data)
                return EntryPreview(
                    kind: .image,
                    text: summary,
                    searchText: summary,
                    imageType: imageFlavour.type,
                    imageData: data
                )
            }
        }

        // 3. Plain text, preferring a decoding we know is lossless. A text
        //    flavour that is only whitespace counts as no text: fall through to
        //    the markup below instead of leaving the row blank.
        if let text = plainText(from: flavours),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return EntryPreview(
                kind: contentKind(for: byType),
                text: excerpt(text),
                searchText: text
            )
        }

        // 4. RTF/HTML with no accompanying plain text.
        let itemsByIndex = Dictionary(grouping: flavours, by: \.itemIndex)
        var htmlTexts: [String] = []
        for itemIndex in itemsByIndex.keys.sorted() {
            guard let itemFlavours = itemsByIndex[itemIndex] else { continue }
            let itemByType = Dictionary(grouping: itemFlavours, by: \.type)
            if let htmlFlavour = firstFlavour(in: itemByType, types: PasteboardTypes.htmlTypes) {
                let raw = String(decoding: htmlFlavour.data, as: UTF8.self)
                let stripped = HTMLText.strip(raw)
                if !stripped.isEmpty {
                    htmlTexts.append(stripped)
                }
            }
        }
        if !htmlTexts.isEmpty {
            let combined = htmlTexts.joined(separator: "\n")
            return EntryPreview(kind: .html, text: excerpt(combined), searchText: combined)
        }

        var rtfTexts: [String] = []
        for itemIndex in itemsByIndex.keys.sorted() {
            guard let itemFlavours = itemsByIndex[itemIndex] else { continue }
            let itemByType = Dictionary(grouping: itemFlavours, by: \.type)
            if let rtfFlavour = firstFlavour(in: itemByType, types: PasteboardTypes.rtfTypes) {
                let stripped = RTFText.strip(rtfFlavour.data)
                if !stripped.isEmpty {
                    rtfTexts.append(stripped)
                }
            }
        }
        if !rtfTexts.isEmpty {
            let combined = rtfTexts.joined(separator: "\n")
            return EntryPreview(kind: .rtf, text: excerpt(combined), searchText: combined)
        }

        // 5. A URL that is not a file.
        var urlTexts: [String] = []
        for itemIndex in itemsByIndex.keys.sorted() {
            guard let itemFlavours = itemsByIndex[itemIndex] else { continue }
            let itemByType = Dictionary(grouping: itemFlavours, by: \.type)
            if let urlFlavour = itemByType[PasteboardTypes.url]?.first {
                let raw = String(decoding: urlFlavour.data, as: UTF8.self)
                if !raw.isEmpty {
                    urlTexts.append(raw)
                }
            }
        }
        if !urlTexts.isEmpty {
            let combined = urlTexts.joined(separator: "\n")
            return EntryPreview(kind: .text, text: excerpt(combined), searchText: combined)
        }

        // 6. Anything else: surface the type names so the row is not blank.
        let typeList = flavours.map(\.type).sorted()
        let summary = typeList.isEmpty ? "Empty clipboard entry" : typeList.joined(separator: ", ")
        return EntryPreview(kind: .other, text: excerpt(summary), searchText: summary)
    }

    // MARK: Helpers

    /// Upper bound on the text kept for an FTS column. Search over a few
    /// thousand entries stays instant well under this, and it keeps the
    /// database from ballooning when someone copies a novel.
    public static let maxSearchTextLength = 20_000

    /// Text stored in the search index: the decoded payload text, capped so a
    /// pathologically large paste cannot bloat the database.
    public static func searchText(for preview: EntryPreview) -> String {
        let text = preview.searchText ?? preview.text ?? ""
        if text.count <= maxSearchTextLength { return text }
        let end = text.index(text.startIndex, offsetBy: maxSearchTextLength)
        return String(text[..<end])
    }

    public static func excerpt(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<end]) + "..."
    }

    private static func firstFlavour(in byType: [String: [Flavour]], types: Set<String>) -> Flavour? {
        for type in types.sorted() {
            if let flavour = byType[type]?.first { return flavour }
        }
        return nil
    }

    private static func singleItemPlainText(
        from byType: [String: [Flavour]],
        includingEmpty: Bool = false
    ) -> String? {
        // A rich copy from some apps carries a plain-text companion that the
        // source ran through a JavaScript escaper, so the escapes are decoded
        // when this item also has markup to explain them. A capture that is
        // only text keeps its bytes, so a copied code snippet that literally
        // contains `\u4f55` is not rewritten.
        let decodeEscapes = isRichItem(byType)
        for type in textPreference {
            guard let flavour = byType[type]?.first else { continue }
            if let value = decodedText(of: flavour, type: type, decodeEscapes: decodeEscapes),
               includingEmpty || !value.isEmpty {
                return value
            }
        }
        // Fall back to any type that claims to be text.
        for (type, flavours) in byType.sorted(by: { $0.key < $1.key }) {
            guard type.contains("text"), !PasteboardTypes.textTypes.contains(type),
                  !PasteboardTypes.rtfTypes.contains(type), !PasteboardTypes.htmlTypes.contains(type),
                  let flavour = flavours.first,
                  let value = decodedText(of: flavour, type: type, decodeEscapes: decodeEscapes),
                  includingEmpty || !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    /// True when one pasteboard item carries markup alongside its text.
    private static func isRichItem(_ byType: [String: [Flavour]]) -> Bool {
        byType.keys.contains { type in
            PasteboardTypes.htmlTypes.contains(type) || PasteboardTypes.rtfTypes.contains(type)
        }
    }

    private static func decodedText(of flavour: Flavour, type: String, decodeEscapes: Bool) -> String? {
        guard let value = decodeText(type: type, data: flavour.data) else { return nil }
        return decodeEscapes ? UnicodeEscapeDecoder.decode(value) : value
    }

    /// Extracts the stored plain text of an entry, including an empty value, or
    /// nil when it carries no plain-text flavour at all.
    ///
    /// The editor uses this instead of `plainText(from:)` so an entry with an
    /// empty text flavour opens with that empty text rather than with its
    /// preview summary.
    public static func storedPlainText(from flavours: [Flavour]) -> String? {
        let itemsByIndex = Dictionary(grouping: flavours, by: \.itemIndex)
        var texts: [String] = []
        var found = false
        for itemIndex in itemsByIndex.keys.sorted() {
            guard let itemFlavours = itemsByIndex[itemIndex] else { continue }
            let itemByType = Dictionary(grouping: itemFlavours, by: \.type)
            if let text = singleItemPlainText(from: itemByType, includingEmpty: true) {
                found = true
                texts.append(text)
            }
        }
        return found ? texts.joined(separator: "\n") : nil
    }

    /// Extracts and joins plain text across all items in a multi-item snapshot.
    public static func plainText(from flavours: [Flavour]) -> String? {
        let itemsByIndex = Dictionary(grouping: flavours, by: \.itemIndex)
        var texts: [String] = []
        for itemIndex in itemsByIndex.keys.sorted() {
            guard let itemFlavours = itemsByIndex[itemIndex] else { continue }
            let itemByType = Dictionary(grouping: itemFlavours, by: \.type)
            if let text = singleItemPlainText(from: itemByType), !text.isEmpty {
                texts.append(text)
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Extracts plain text from a collection of flavours grouped by type.
    public static func plainText(from byType: [String: [Flavour]]) -> String? {
        plainText(from: Array(byType.values.joined()))
    }

    /// The text-only representation used by Paste as Plain Text.
    ///
    /// Unlike `preview`, this always returns text: a plain-text flavour wins
    /// for an item, and when an item has none its HTML or RTF payload is
    /// stripped to text. Items that carry no readable text are skipped. The
    /// stored entry is never changed; the caller writes the result to the
    /// pasteboard instead.
    public static func plainTextRepresentation(from flavours: [Flavour]) -> String? {
        let itemsByIndex = Dictionary(grouping: flavours, by: \.itemIndex)
        var texts: [String] = []
        for itemIndex in itemsByIndex.keys.sorted() {
            guard let itemFlavours = itemsByIndex[itemIndex] else { continue }
            let itemByType = Dictionary(grouping: itemFlavours, by: \.type)

            if let text = singleItemPlainText(from: itemByType), !text.isEmpty {
                texts.append(text)
                continue
            }
            if let htmlFlavour = firstFlavour(in: itemByType, types: PasteboardTypes.htmlTypes) {
                let stripped = HTMLText.strip(String(decoding: htmlFlavour.data, as: UTF8.self))
                if !stripped.isEmpty {
                    texts.append(stripped)
                    continue
                }
            }
            if let rtfFlavour = firstFlavour(in: itemByType, types: PasteboardTypes.rtfTypes) {
                let stripped = RTFText.strip(rtfFlavour.data)
                if !stripped.isEmpty {
                    texts.append(stripped)
                    continue
                }
            }
            if let urlFlavour = itemByType[PasteboardTypes.url]?.first {
                let url = String(decoding: urlFlavour.data, as: UTF8.self)
                if !url.isEmpty {
                    texts.append(url)
                }
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Decodes the text encodings we can handle without AppKit. RTF/HTML are
    /// handled separately by their strippers.
    public static func decodeText(type: String, data: Data) -> String? {
        switch type {
        case PasteboardTypes.utf8Text, PasteboardTypes.plainText, PasteboardTypes.legacyText,
             PasteboardTypes.mimeText, PasteboardTypes.mimeTextUtf8:
            return String(data: data, encoding: .utf8)
        case PasteboardTypes.utf16Text:
            return String(data: data, encoding: .utf16LittleEndian)
                ?? String(data: data, encoding: .utf16)
        case PasteboardTypes.utf16ExternalText:
            // External files carry a byte-order mark; honour it when present.
            if let bom = String(data: data, encoding: .utf16) { return bom }
            return String(data: data, encoding: .utf16LittleEndian)
        default:
            return nil
        }
    }

    public static func fileURLs(from flavours: [Flavour]) -> [URL]? {
        var urls: [URL] = []
        var representationCounts: [String: [String: Int]] = [:]
        var emittedCounts: [String: Int] = [:]

        func append(_ url: URL, representedBy type: String) {
            let path = url.standardizedFileURL.path
            let occurrence = (representationCounts[type, default: [:]][path] ?? 0) + 1
            representationCounts[type, default: [:]][path] = occurrence
            if occurrence > (emittedCounts[path] ?? 0) {
                urls.append(url)
                emittedCounts[path] = occurrence
            }
        }

        let ordered = flavours.sorted { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) }
        for flavour in ordered {
            switch flavour.type {
            case PasteboardTypes.fileURL:
                let raw = String(decoding: flavour.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: raw), url.isFileURL {
                    append(url, representedBy: flavour.type)
                }
            case PasteboardTypes.legacyFilenames:
                if let list = try? PropertyListSerialization.propertyList(
                    from: flavour.data, options: [], format: nil
                ) as? [String] {
                    for path in list {
                        append(URL(fileURLWithPath: path), representedBy: flavour.type)
                    }
                }
            case PasteboardTypes.mimeUriList:
                let raw = String(decoding: flavour.data, as: UTF8.self)
                for line in raw.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                    if let url = URL(string: trimmed), url.isFileURL {
                        append(url, representedBy: flavour.type)
                    }
                }
            default:
                continue
            }
        }
        return urls.isEmpty ? nil : urls
    }

    /// True for a type that is an image, whether spelled as a UTI or a MIME name.
    public static func isImageType(_ type: String) -> Bool {
        if type.lowercased().starts(with: "image/") { return true }
        let identifier = type == "public.gif" ? "com.compuserve.gif" : type
        return UTType(identifier)?.conforms(to: .image) ?? false
    }

    private static func imagePreferenceRank(_ type: String) -> Int {
        let lower = type.lowercased()
        if lower == "image/png" || lower == "public.png" { return 0 }
        if lower == "image/bmp" || lower == "com.microsoft.bmp" { return 1 }
        if lower == "image/jpeg" || lower == "image/jpg" || lower == "public.jpeg" { return 2 }
        if lower == "image/gif" || lower == "public.gif" || lower == "com.compuserve.gif" { return 3 }
        return 4
    }

    private static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    private static func contentKind(for byType: [String: [Flavour]]) -> ClipboardContentKind {
        if byType.keys.contains(where: { PasteboardTypes.htmlTypes.contains($0) }) { return .html }
        if byType.keys.contains(where: { PasteboardTypes.rtfTypes.contains($0) }) { return .rtf }
        return .text
    }

    private static func imageSummary(type: String, data: Data) -> String {
        if let size = ImageInfo.pixelSize(of: data) {
            return "Image \(size.width)x\(size.height) (\(shortType(type)))"
        }
        return "Image (\(shortType(type)))"
    }

    public static func shortType(_ type: String) -> String {
        type.split(separator: ".").last.map(String.init) ?? type
    }
}

// MARK: - HTML / RTF text extraction

/// Decodes the JavaScript-style `\uXXXX` escapes that some apps write into a
/// clipboard payload instead of the characters themselves.
///
/// Only complete escapes are replaced: a surrogate pair such as
/// `\uD83D\uDE00` becomes the single character it denotes, while a lone
/// surrogate or a sequence that is not four hexadecimal digits is left exactly
/// as it was, so text that merely contains a backslash never loses a character.
enum UnicodeEscapeDecoder {
    static func decode(_ text: String) -> String {
        guard text.contains("\\u") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if let escape = escape(in: text, at: index) {
                output.append(escape.text)
                index = escape.end
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return output
    }

    /// The escape starting at `index`, when there is a complete one there.
    private static func escape(
        in text: String,
        at index: String.Index
    ) -> (text: String, end: String.Index)? {
        guard let first = codeUnit(in: text, at: index) else { return nil }
        if (0xD800...0xDBFF).contains(first.value) {
            // A high surrogate is only meaningful with the low surrogate that
            // follows it; on its own the escape is left alone.
            guard let second = codeUnit(in: text, at: first.end),
                  (0xDC00...0xDFFF).contains(second.value)
            else { return nil }
            let codePoint = 0x10000
                + (UInt32(first.value) - 0xD800) * 0x400
                + (UInt32(second.value) - 0xDC00)
            guard let scalar = Unicode.Scalar(codePoint) else { return nil }
            return (String(scalar), second.end)
        }
        if (0xDC00...0xDFFF).contains(first.value) { return nil }
        guard let scalar = Unicode.Scalar(UInt32(first.value)) else { return nil }
        return (String(scalar), first.end)
    }

    /// One `\uXXXX` sequence at `index`, decoded as a UTF-16 code unit.
    private static func codeUnit(
        in text: String,
        at index: String.Index
    ) -> (value: UInt16, end: String.Index)? {
        guard index < text.endIndex, text[index] == "\\" else { return nil }
        let marker = text.index(after: index)
        guard marker < text.endIndex, text[marker] == "u" else { return nil }
        let digitsStart = text.index(after: marker)
        guard let digitsEnd = text.index(digitsStart, offsetBy: 4, limitedBy: text.endIndex) else { return nil }
        guard let value = UInt16(text[digitsStart..<digitsEnd], radix: 16) else { return nil }
        return (value, digitsEnd)
    }
}

public enum HTMLText {
    /// Small tag stripper. Good enough to index and preview HTML that has no
    /// plain-text companion; the raw bytes are still stored unchanged.
    ///
    /// `<script>` and `<style>` bodies are skipped entirely so CSS and
    /// JavaScript do not end up in the search index. HTML entities and
    /// JavaScript-style `\uXXXX` escapes are decoded into the characters they
    /// stand for, in that order, because a payload can spell the backslash as
    /// `&#92;`. Decoding happens after tag stripping so an escaped `<` stays
    /// text instead of becoming a tag.
    public static func strip(_ html: String) -> String {
        var output = ""
        output.reserveCapacity(html.count)
        var index = html.startIndex
        while index < html.endIndex {
            guard let tagStart = html[index...].firstIndex(of: "<") else {
                output.append(contentsOf: html[index...])
                break
            }
            output.append(contentsOf: html[index..<tagStart])
            guard let tagEnd = html[tagStart...].firstIndex(of: ">") else { break }
            let body = html[html.index(after: tagStart)..<tagEnd].lowercased()
            let name = body.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .first.map(String.init) ?? ""
            if name == "script" || name == "style" {
                let searchStart = html.index(after: tagEnd)
                if let closeStart = html.range(of: "</\(name)", options: [.caseInsensitive], range: searchStart..<html.endIndex),
                   let closeEnd = html[closeStart.lowerBound...].firstIndex(of: ">") {
                    index = html.index(after: closeEnd)
                    continue
                }
                break
            }
            // Every tag becomes whitespace; runs are collapsed below, so inline
            // tags like <b> do not introduce visible gaps.
            output.append(" ")
            index = html.index(after: tagEnd)
        }
        return UnicodeEscapeDecoder.decode(decodeEntities(output))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]

    private static func decodeEntities(_ text: String) -> String {
        var decoded = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let ampersand = text[index...].firstIndex(of: "&") else {
                decoded.append(contentsOf: text[index...])
                break
            }
            decoded.append(contentsOf: text[index..<ampersand])
            guard let semicolon = text[text.index(after: ampersand)...].firstIndex(of: ";") else {
                decoded.append(contentsOf: text[ampersand...])
                break
            }

            let entity = String(text[ampersand...semicolon])
            if let value = entities[entity] {
                decoded.append(contentsOf: value)
            } else if let scalar = numericScalar(in: entity) {
                decoded.unicodeScalars.append(scalar)
            } else {
                decoded.append(contentsOf: entity)
            }
            index = text.index(after: semicolon)
        }
        return decoded
    }

    private static func numericScalar(in entity: String) -> Unicode.Scalar? {
        guard entity.hasPrefix("&#"), entity.last == ";" else { return nil }
        let number = entity.dropFirst(2).dropLast()
        let value: UInt32?
        if number.first == "x" || number.first == "X" {
            value = UInt32(number.dropFirst(), radix: 16)
        } else {
            value = UInt32(number, radix: 10)
        }
        guard let value else { return nil }
        return Unicode.Scalar(value)
    }
}

public enum RTFText {
    private struct GroupState {
        var skipped: Bool
        var hasContent: Bool
        var unicodeFallbackCount: Int
    }

    private static let nonTextDestinations: Set<String> = [
        "annotation", "atnauthor", "colortbl", "colorschememapping", "creatim",
        "datastore", "doccomm", "fonttbl", "footer", "footerf", "footerl",
        "footerr", "ftnsep", "ftnsepc", "generator", "header", "headerf",
        "headerl", "headerr", "info", "keywords", "listoverridetable",
        "listtable", "object", "operator", "pict", "printim", "private",
        "revtbl", "revtim", "rsidtbl", "shpinst", "shppict", "stylesheet",
        "subject", "themedata", "title", "xmlnstbl",
    ]

    /// Extracts readable text, including Unicode escapes, control symbols, and
    /// whitespace entities, while excluding RTF destination groups that do not contain
    /// the document's visible text.
    public static func strip(_ data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii) else { return "" }

        var output: [UInt16] = []
        var groups = [GroupState(skipped: false, hasContent: true, unicodeFallbackCount: 1)]
        var index = raw.startIndex
        var fallbackCharactersToSkip = 0
        var ignorableDestination = false

        while index < raw.endIndex {
            let character = raw[index]

            if fallbackCharactersToSkip > 0 {
                if character == "{" || character == "}" {
                    // Group delimiters are syntax, not fallback characters.
                } else if character == "\\" {
                    index = skipEscape(in: raw, startingAt: index)
                    fallbackCharactersToSkip -= 1
                    continue
                } else {
                    index = raw.index(after: index)
                    fallbackCharactersToSkip -= 1
                    continue
                }
            }

            if character == "{" {
                let parent = groups[groups.count - 1]
                groups.append(GroupState(
                    skipped: parent.skipped,
                    hasContent: false,
                    unicodeFallbackCount: parent.unicodeFallbackCount
                ))
                index = raw.index(after: index)
                continue
            }
            if character == "}" {
                if groups.count > 1 { groups.removeLast() }
                index = raw.index(after: index)
                continue
            }

            if character == "\\" {
                let next = raw.index(after: index)
                guard next < raw.endIndex else { break }
                let control = raw[next]

                if control == "'" {
                    let hexStart = raw.index(after: next)
                    let hexEnd = raw.index(hexStart, offsetBy: 2, limitedBy: raw.endIndex) ?? raw.endIndex
                    if let code = UInt8(raw[hexStart..<hexEnd], radix: 16), !groups[groups.count - 1].skipped,
                       let scalar = String(bytes: [code], encoding: .isoLatin1) {
                        output.append(contentsOf: scalar.utf16)
                    }
                    groups[groups.count - 1].hasContent = true
                    index = hexEnd
                    continue
                }
                if control == "*" {
                    ignorableDestination = true
                    index = raw.index(after: next)
                    continue
                }
                if control == "\\" || control == "{" || control == "}" {
                    if !groups[groups.count - 1].skipped { output.append(contentsOf: String(control).utf16) }
                    groups[groups.count - 1].hasContent = true
                    index = raw.index(after: next)
                    continue
                }
                if control == "~" {
                    if !groups[groups.count - 1].skipped { output.append(contentsOf: "\u{00A0}".utf16) }
                    groups[groups.count - 1].hasContent = true
                    index = raw.index(after: next)
                    continue
                }
                if control == "_" {
                    if !groups[groups.count - 1].skipped { output.append(contentsOf: "\u{2011}".utf16) }
                    groups[groups.count - 1].hasContent = true
                    index = raw.index(after: next)
                    continue
                }
                if control == "-" {
                    if !groups[groups.count - 1].skipped { output.append(contentsOf: "\u{00AD}".utf16) }
                    groups[groups.count - 1].hasContent = true
                    index = raw.index(after: next)
                    continue
                }
                if control.isLetter {
                    var end = next
                    while end < raw.endIndex, raw[end].isLetter { end = raw.index(after: end) }
                    let word = String(raw[next..<end])
                    var digitEnd = end
                    while digitEnd < raw.endIndex, raw[digitEnd].isNumber || raw[digitEnd] == "-" {
                        digitEnd = raw.index(after: digitEnd)
                    }
                    let parameter = digitEnd == end ? nil : Int(raw[end..<digitEnd])
                    let startsGroup = !groups[groups.count - 1].hasContent
                    if startsGroup && (ignorableDestination || nonTextDestinations.contains(word)) {
                        groups[groups.count - 1].skipped = true
                    }
                    ignorableDestination = false
                    groups[groups.count - 1].hasContent = true

                    if !groups[groups.count - 1].skipped {
                        switch word {
                        case "uc":
                            if let parameter, parameter >= 0 {
                                groups[groups.count - 1].unicodeFallbackCount = parameter
                            }
                        case "u":
                            if let parameter, let codeUnit = Int16(exactly: parameter) {
                                output.append(UInt16(bitPattern: codeUnit))
                                fallbackCharactersToSkip = groups[groups.count - 1].unicodeFallbackCount
                            }
                        case "par", "line":
                            output.append(contentsOf: "\n".utf16)
                        case "tab":
                            output.append(contentsOf: "\t".utf16)
                        case "emdash":
                            output.append(contentsOf: "\u{2014}".utf16)
                        case "endash":
                            output.append(contentsOf: "\u{2013}".utf16)
                        case "emspace":
                            output.append(contentsOf: "\u{2003}".utf16)
                        case "enspace":
                            output.append(contentsOf: "\u{2002}".utf16)
                        case "qmspace":
                            output.append(contentsOf: "\u{2005}".utf16)
                        case "bullet":
                            output.append(contentsOf: "\u{2022}".utf16)
                        case "lquote":
                            output.append(contentsOf: "\u{2018}".utf16)
                        case "rquote":
                            output.append(contentsOf: "\u{2019}".utf16)
                        case "ldblquote":
                            output.append(contentsOf: "\u{201C}".utf16)
                        case "rdblquote":
                            output.append(contentsOf: "\u{201D}".utf16)
                        case "zwbo":
                            output.append(contentsOf: "\u{200B}".utf16)
                        case "zwj":
                            output.append(contentsOf: "\u{200D}".utf16)
                        case "zwnj":
                            output.append(contentsOf: "\u{200C}".utf16)
                        default:
                            break
                        }
                    }

                    if digitEnd < raw.endIndex, raw[digitEnd] == " " {
                        index = raw.index(after: digitEnd)
                    } else {
                        index = digitEnd
                    }
                    continue
                }

                ignorableDestination = false
                groups[groups.count - 1].hasContent = true
                index = raw.index(after: next)
                continue
            }

            if !character.isWhitespace { groups[groups.count - 1].hasContent = true }
            if !groups[groups.count - 1].skipped { output.append(contentsOf: String(character).utf16) }
            index = raw.index(after: index)
        }

        return String(decoding: output, as: UTF16.self)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func skipEscape(in raw: String, startingAt index: String.Index) -> String.Index {
        let next = raw.index(after: index)
        guard next < raw.endIndex else { return raw.endIndex }
        if raw[next] == "'" {
            return raw.index(next, offsetBy: 3, limitedBy: raw.endIndex) ?? raw.endIndex
        }
        guard raw[next].isLetter else { return raw.index(after: next) }
        var end = next
        while end < raw.endIndex, raw[end].isLetter { end = raw.index(after: end) }
        while end < raw.endIndex, raw[end].isNumber || raw[end] == "-" { end = raw.index(after: end) }
        if end < raw.endIndex, raw[end] == " " { return raw.index(after: end) }
        return end
    }
}

// MARK: - Image inspection

public enum ImageInfo {
    /// Pixel dimensions straight from the encoded bytes. Uses ImageIO, which
    /// works without a window server.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

// MARK: - SHA-256

/// Minimal SHA-256 so the core has no dependency on CryptoKit's availability
/// quirks in test builds. Streaming interface over the byte sequences we hash.
public struct SHA256Digest {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    /// The pending block, never longer than 64 bytes.
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        length &+= UInt64(bytes.count) &* 8
        var offset = 0
        // Top up a partial block first.
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes[0..<take])
            offset = take
            if buffer.count == 64 {
                compress(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        // Then take the whole blocks straight out of the input, so a large
        // payload is hashed in one linear pass. Consuming the buffer with
        // `removeFirst` instead would shift the remaining bytes for every
        // block and make hashing quadratic in the payload size, which is what
        // used to freeze the app when Finder put a multi-megabyte icon on the
        // pasteboard.
        while bytes.count - offset >= 64 {
            compress(Array(bytes[offset..<(offset + 64)]))
            offset += 64
        }
        if offset < bytes.count {
            buffer.append(contentsOf: bytes[offset...])
        }
    }

    public mutating func update(_ data: Data) { update([UInt8](data)) }

    public mutating func update(_ string: String) {
        update(Array(string.utf8))
    }

    public mutating func update(_ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { update(Array($0)) }
    }

    public mutating func update(_ value: Int64) { update(UInt64(bitPattern: value)) }

    public mutating func finalize() -> String {
        let messageLength = length
        update([0x80])
        while buffer.count % 64 != 56 { buffer.append(0) }
        var bigEndian = messageLength.bigEndian
        withUnsafeBytes(of: &bigEndian) { buffer.append(contentsOf: $0) }
        while buffer.count >= 64 {
            let block = Array(buffer[0..<64])
            buffer.removeFirst(64)
            compress(block)
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(block[i * 4]) << 24 | UInt32(block[i * 4 + 1]) << 16
                | UInt32(block[i * 4 + 2]) << 8 | UInt32(block[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for i in 0..<64 {
            let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

// MARK: - Relative time

public enum RelativeTime {
    /// "just now", "3 min ago", "2 h ago", "Yesterday", or a localized date
    /// such as "Nov 14".
    public static func describe(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        language: AppLanguage = .english
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 5 {
            return Localization.string(.relativeTimeJustNow, language: language)
        }
        if seconds < 60 {
            return Localization.format(.relativeTimeSecondsAgo, language: language, Int(seconds))
        }
        if seconds < 3600 {
            return Localization.format(.relativeTimeMinutesAgo, language: language, Int(seconds / 60))
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return Localization.format(.relativeTimeHoursAgo, language: language, Int(seconds / 3600))
        }
        // Compare against the caller's `now`, not the wall clock: `isDateInYesterday`
        // consults the real current date and gives the wrong answer for a fixed
        // test clock.
        if let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day, days == 1 {
            return Localization.string(.relativeTimeYesterday, language: language)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = language.locale
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        }
        return formatter.string(from: date)
    }
}
