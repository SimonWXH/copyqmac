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
    /// pasteboard types (UTF-8 plain text, HTML, RTF, PNG, JPEG, TIFF, GIF,
    /// HEIC, file URL) when only MIME or legacy flavours are present.
    public static func pasteboardItems(from flavours: [Flavour]) -> [NSPasteboardItem] {
        makePasteboardItems(from: flavours, allowedTypes: nil)
    }

    private static func nativeFileURLPaths(in flavours: [Flavour]) -> Set<String> {
        let native = flavours.filter { $0.type == PasteboardTypes.fileURL }
        return Set((FlavourDecoder.fileURLs(from: native) ?? []).map(\.standardizedFileURL.path))
    }

    private static func makePasteboardItems(
        from flavours: [Flavour],
        allowedTypes: Set<String>?
    ) -> [NSPasteboardItem] {
        let cleanFlavours = flavours.filter { flavour in
            !Fingerprint.isBookkeepingFlavour(flavour.type)
        }
        let nativeURLPaths = nativeFileURLPaths(in: cleanFlavours)
        let grouped = Dictionary(grouping: cleanFlavours, by: \.itemIndex)
        return grouped.keys.sorted().flatMap { index in
            let itemFlavours = grouped[index] ?? []
            var items = [NSPasteboardItem()]
            var fileURLData: [Data] = []
            let representations = standardPasteboardFlavours(
                for: itemFlavours,
                existingNativeURLs: nativeURLPaths
            ).filter { flavour in
                allowedTypes?.contains(flavour.type) ?? true
            }
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

    private static func standardPasteboardFlavours(
        for flavours: [Flavour],
        existingNativeURLs: Set<String>
    ) -> [Flavour] {
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
        if !existingTypes.contains(PasteboardTypes.jpeg),
           let source = firstOfType("image/jpeg") ?? firstOfType("image/jpg") {
            result.append(Flavour(itemIndex: source.itemIndex, type: PasteboardTypes.jpeg, data: source.data))
        }
        if !existingTypes.contains(PasteboardTypes.tiff),
           let source = firstOfType("image/tiff") {
            result.append(Flavour(itemIndex: source.itemIndex, type: PasteboardTypes.tiff, data: source.data))
        }
        if !existingTypes.contains(PasteboardTypes.heic),
           let source = firstOfType("image/heic") {
            result.append(Flavour(itemIndex: source.itemIndex, type: PasteboardTypes.heic, data: source.data))
        }
        if !existingTypes.contains("com.compuserve.gif"),
           let source = firstOfType("image/gif") {
            result.append(Flavour(itemIndex: source.itemIndex, type: "com.compuserve.gif", data: source.data))
        }
        if !existingTypes.contains("com.microsoft.bmp"),
           let source = firstOfType("image/bmp") {
            result.append(Flavour(itemIndex: source.itemIndex, type: "com.microsoft.bmp", data: source.data))
        }

        let urls = FlavourDecoder.fileURLs(from: flavours) ?? []
        if !urls.isEmpty {
            let baseIndex = flavours.first?.itemIndex ?? 0
            for url in urls where !existingNativeURLs.contains(url.standardizedFileURL.path) {
                let str = url.absoluteString
                if let data = str.data(using: .utf8) {
                    result.append(Flavour(itemIndex: baseIndex, type: PasteboardTypes.fileURL, data: data))
                }
            }
        }
        return result
    }

    /// Attaches the standard drag representation of an entry to a single
    /// pasteboard item without materialising unrelated stored payloads.
    public static func attachDragTypes(from flavours: [Flavour], to item: NSPasteboardItem) {
        let cleanFlavours = flavours.filter { !Fingerprint.isBookkeepingFlavour($0.type) }
        let standardFlavours = standardPasteboardFlavours(
            for: cleanFlavours,
            existingNativeURLs: nativeFileURLPaths(in: cleanFlavours)
        )
        for flavour in standardFlavours where standardDragTypes.contains(flavour.type) {
            if item.data(forType: NSPasteboard.PasteboardType(flavour.type)) == nil {
                item.setData(flavour.data, forType: NSPasteboard.PasteboardType(flavour.type))
            }
        }
    }

    public static let standardDragTypes: Set<String> = [
        PasteboardTypes.utf8Text, PasteboardTypes.utf16Text, PasteboardTypes.utf16ExternalText,
        PasteboardTypes.plainText,
        PasteboardTypes.html, PasteboardTypes.rtf,
        PasteboardTypes.png, PasteboardTypes.tiff, PasteboardTypes.jpeg, PasteboardTypes.heic,
        "com.compuserve.gif", "com.microsoft.bmp",
        PasteboardTypes.fileURL, PasteboardTypes.url,
    ]

    public static let legacyDragTypes: Set<String> = [
        PasteboardTypes.legacyFilenames,
        PasteboardTypes.legacyHTML,
        PasteboardTypes.legacyRTF,
        PasteboardTypes.legacyText,
    ]

    /// Writes legacy representations for a drag. Rich text and plain text come
    /// only from the first item's flavours, while filenames cover every dragged
    /// file.
    private static func attachLegacyTypes(from entries: [ClipboardEntry], to pasteboard: NSPasteboard) {
        let firstFlavours: [Flavour]
        if let firstEntry = entries.first,
           let firstIndex = firstEntry.flavours.map(\.itemIndex).min() {
            firstFlavours = firstEntry.flavours.filter { $0.itemIndex == firstIndex }
        } else {
            firstFlavours = []
        }

        let urls = FlavourDecoder.fileURLs(from: entries.flatMap(\.flavours)) ?? []
        if !urls.isEmpty {
            pasteboard.addTypes([NSPasteboard.PasteboardType(PasteboardTypes.legacyFilenames)], owner: nil)
            pasteboard.setPropertyList(urls.map(\.path), forType: NSPasteboard.PasteboardType(PasteboardTypes.legacyFilenames))
        }

        if let flavour = firstFlavours.first(where: {
            $0.type == PasteboardTypes.html || $0.type == PasteboardTypes.mimeHtml || $0.type == PasteboardTypes.legacyHTML
        }) {
            pasteboard.addTypes([NSPasteboard.PasteboardType(PasteboardTypes.legacyHTML)], owner: nil)
            pasteboard.setData(flavour.data, forType: NSPasteboard.PasteboardType(PasteboardTypes.legacyHTML))
        }

        if let flavour = firstFlavours.first(where: {
            $0.type == PasteboardTypes.rtf || $0.type == PasteboardTypes.mimeRtf || $0.type == PasteboardTypes.legacyRTF
        }) {
            pasteboard.addTypes([NSPasteboard.PasteboardType(PasteboardTypes.legacyRTF)], owner: nil)
            pasteboard.setData(flavour.data, forType: NSPasteboard.PasteboardType(PasteboardTypes.legacyRTF))
        }

        if let flavour = firstFlavours.first(where: {
            $0.type == PasteboardTypes.utf8Text || $0.type == PasteboardTypes.plainText ||
            $0.type == PasteboardTypes.mimeText || $0.type == PasteboardTypes.legacyText
        }), let str = String(data: flavour.data, encoding: .utf8) {
            pasteboard.addTypes([NSPasteboard.PasteboardType(PasteboardTypes.legacyText)], owner: nil)
            pasteboard.setString(str, forType: NSPasteboard.PasteboardType(PasteboardTypes.legacyText))
        }
    }

    /// Populates a pasteboard with all items and legacy types for a drag
    /// operation across one or more entries, ensuring multi-file entries emit
    /// one item per URL and internal drag identity is preserved.
    public static func writeDragData(for entries: [ClipboardEntry], to pasteboard: NSPasteboard) {
        var items: [NSPasteboardItem] = []

        for entry in entries {
            let entryItems = makePasteboardItems(
                from: entry.flavours,
                allowedTypes: standardDragTypes.union(legacyDragTypes)
            )
            if let first = entryItems.first {
                first.setString(String(entry.id), forType: EntryDrag.pasteboardType)
                items.append(contentsOf: entryItems)
            } else {
                let item = NSPasteboardItem()
                item.setString(String(entry.id), forType: EntryDrag.pasteboardType)
                items.append(item)
            }
        }

        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        attachLegacyTypes(from: entries, to: pasteboard)
    }

    /// Writes flavours back to the pasteboard, rebuilding the item structure.
    ///
    /// Unlike the drag path, this restores all stored representations. Returns
    /// the pasteboard `changeCount` after the write so the watcher can recognise
    /// and ignore its own write.
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
