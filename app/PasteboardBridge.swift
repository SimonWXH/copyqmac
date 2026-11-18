// AppKit side of the clipboard: turning a live NSPasteboard into flavours and
// writing flavours back. All Core-layer types stay free of AppKit; only this
// file touches NSPasteboard.

import AppKit
import Foundation

public enum PasteboardBridge {
    /// Whether the source marked this pasteboard change as private.
    ///
    /// The check looks only at type identifiers, never at payload bytes: a
    /// clipboard manager must be able to decide not to capture a secret without
    /// reading the secret at all.
    public static func hasConfidentialMarker(_ pasteboard: NSPasteboard = .general) -> Bool {
        if PasteboardPrivacy.containsConfidentialType(pasteboard.types?.map(\.rawValue) ?? []) {
            return true
        }
        guard let items = pasteboard.pasteboardItems else { return false }
        return items.contains { item in
            PasteboardPrivacy.containsConfidentialType(item.types.map(\.rawValue))
        }
    }

    /// Reads every item and every flavour currently on the pasteboard.
    ///
    /// Types whose data provider declines to produce bytes are skipped rather
    /// than failing the whole capture. The order of items is preserved; flavour
    /// order within an item follows the system's reported order.
    public static func snapshot(of pasteboard: NSPasteboard = .general) -> [Flavour] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }
        var flavours: [Flavour] = []
        for (index, item) in items.enumerated() {
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                flavours.append(Flavour(itemIndex: index, type: type.rawValue, data: data))
            }
        }
        return flavours
    }

    /// Builds NSPasteboardItems for the given flavours, synthesising standard
    /// pasteboard types (UTF-8 plain text, HTML, RTF, PNG, file URL) when only
    /// MIME or legacy flavours are present.
    public static func pasteboardItems(from flavours: [Flavour]) -> [NSPasteboardItem] {
        let cleanFlavours = flavours.filter { flavour in
            !Fingerprint.isBookkeepingFlavour(flavour.type)
        }
        let grouped = Dictionary(grouping: cleanFlavours, by: \.itemIndex)
        return grouped.keys.sorted().flatMap { index in
            let itemFlavours = grouped[index] ?? []
            var items = [NSPasteboardItem()]
            var fileURLData: [Data] = []
            let representations = standardPasteboardFlavours(for: itemFlavours)
            for flavour in representations where flavour.type != PasteboardTypes.fileURL {
                items[0].setData(flavour.data, forType: NSPasteboard.PasteboardType(flavour.type))
            }
            for flavour in representations where flavour.type == PasteboardTypes.fileURL {
                fileURLData.append(flavour.data)
            }
            guard !fileURLData.isEmpty else { return items }
            for data in fileURLData.dropFirst() {
                let item = NSPasteboardItem()
                item.setData(data, forType: .fileURL)
                items.append(item)
            }
            items[0].setData(fileURLData[0], forType: .fileURL)
            return items
        }
    }

    private static func standardPasteboardFlavours(for flavours: [Flavour]) -> [Flavour] {
        var result = flavours
        let existingTypes = Set(flavours.map(\.type))
        let firstOfType: (String) -> Flavour? = { type in
            flavours.first { $0.type == type }
        }

        if !existingTypes.contains(PasteboardTypes.utf8Text) {
            let source = firstOfType(PasteboardTypes.mimeText)
                ?? firstOfType(PasteboardTypes.mimeTextUtf8)
                ?? firstOfType(PasteboardTypes.plainText)
                ?? firstOfType(PasteboardTypes.legacyText)
            if let source {
                result.append(Flavour(itemIndex: source.itemIndex, type: PasteboardTypes.utf8Text, data: source.data))
            }
        }
        if !existingTypes.contains(PasteboardTypes.html),
           let source = firstOfType(PasteboardTypes.mimeHtml) ?? firstOfType(PasteboardTypes.legacyHTML) {
            result.append(Flavour(itemIndex: source.itemIndex, type: PasteboardTypes.html, data: source.data))
        }
        if !existingTypes.contains(PasteboardTypes.rtf),
           let source = firstOfType(PasteboardTypes.mimeRtf) ?? firstOfType(PasteboardTypes.legacyRTF) {
            result.append(Flavour(itemIndex: source.itemIndex, type: PasteboardTypes.rtf, data: source.data))
        }
        if !existingTypes.contains(PasteboardTypes.png),
           let source = firstOfType("image/png") {
            result.append(Flavour(itemIndex: source.itemIndex, type: PasteboardTypes.png, data: source.data))
        }
        if !existingTypes.contains(PasteboardTypes.fileURL) {
            if let uriList = firstOfType(PasteboardTypes.mimeUriList) {
                let raw = String(decoding: uriList.data, as: UTF8.self)
                let urls = fileURLs(from: raw)
                for url in urls {
                    if let data = url.absoluteString.data(using: .utf8) {
                        result.append(Flavour(itemIndex: uriList.itemIndex, type: PasteboardTypes.fileURL, data: data))
                    }
                }
            } else if let filenames = firstOfType(PasteboardTypes.legacyFilenames),
                      let paths = filePaths(from: filenames.data) {
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    if let data = url.absoluteString.data(using: .utf8) {
                        result.append(Flavour(itemIndex: filenames.itemIndex, type: PasteboardTypes.fileURL, data: data))
                    }
                }
            }
        }
        return result
    }

    private static func fileURLs(from uriList: String) -> [URL] {
        uriList.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0) }
            .filter(\.isFileURL)
    }

    private static func filePaths(from filenames: Data) -> [String]? {
        try? PropertyListSerialization.propertyList(from: filenames, options: [], format: nil) as? [String]
    }

    /// Attaches the standard drag representation of an entry to a single
    /// pasteboard item without materialising unrelated stored payloads.
    public static func attachDragTypes(from flavours: [Flavour], to item: NSPasteboardItem) {
        let cleanFlavours = flavours.filter { !Fingerprint.isBookkeepingFlavour($0.type) }
        let standardFlavours = standardPasteboardFlavours(for: cleanFlavours)
        for flavour in standardFlavours where standardDragTypes.contains(flavour.type) {
            if item.data(forType: NSPasteboard.PasteboardType(flavour.type)) == nil {
                item.setData(flavour.data, forType: NSPasteboard.PasteboardType(flavour.type))
            }
        }
    }

    private static let standardDragTypes: Set<String> = [
        PasteboardTypes.utf8Text, PasteboardTypes.utf16Text, PasteboardTypes.utf16ExternalText,
        PasteboardTypes.plainText,
        PasteboardTypes.html, PasteboardTypes.rtf,
        PasteboardTypes.png, PasteboardTypes.tiff, PasteboardTypes.jpeg, PasteboardTypes.heic,
        PasteboardTypes.fileURL, PasteboardTypes.url,
    ]

    /// Writes flavours back to the pasteboard, rebuilding the item structure.
    ///
    /// Returns the pasteboard `changeCount` after the write so the watcher can
    /// recognise and ignore its own write.
    @discardableResult
    public static func write(_ flavours: [Flavour], to pasteboard: NSPasteboard = .general) -> Int {
        let items = pasteboardItems(from: flavours)
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        return pasteboard.changeCount
    }
}
