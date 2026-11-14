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

    /// Writes flavours back to the pasteboard, rebuilding the item structure.
    ///
    /// Returns the pasteboard `changeCount` after the write so the watcher can
    /// recognise and ignore its own write.
    @discardableResult
    public static func write(_ flavours: [Flavour], to pasteboard: NSPasteboard = .general) -> Int {
        let cleanFlavours = flavours.filter { flavour in
            !Fingerprint.isBookkeepingFlavour(flavour.type)
        }

        let grouped = Dictionary(grouping: cleanFlavours, by: \.itemIndex)
        let items: [NSPasteboardItem] = grouped.keys.sorted().map { index in
            var itemFlavours = grouped[index] ?? []
            let itemTypes = Set(itemFlavours.map(\.type))

            if !itemTypes.contains(PasteboardTypes.utf8Text) {
                if let textFlavour = itemFlavours.first(where: {
                    $0.type == PasteboardTypes.mimeText || $0.type == PasteboardTypes.mimeTextUtf8
                }) {
                    itemFlavours.append(Flavour(itemIndex: index, type: PasteboardTypes.utf8Text, data: textFlavour.data))
                }
            }
            if !itemTypes.contains(PasteboardTypes.html) {
                if let html = itemFlavours.first(where: { $0.type == PasteboardTypes.mimeHtml }) {
                    itemFlavours.append(Flavour(itemIndex: index, type: PasteboardTypes.html, data: html.data))
                }
            }
            if !itemTypes.contains(PasteboardTypes.rtf) {
                if let rtf = itemFlavours.first(where: { $0.type == PasteboardTypes.mimeRtf }) {
                    itemFlavours.append(Flavour(itemIndex: index, type: PasteboardTypes.rtf, data: rtf.data))
                }
            }
            if !itemTypes.contains(PasteboardTypes.png) {
                if let png = itemFlavours.first(where: { $0.type == "image/png" }) {
                    itemFlavours.append(Flavour(itemIndex: index, type: PasteboardTypes.png, data: png.data))
                }
            }
            if !itemTypes.contains(PasteboardTypes.fileURL) {
                if let uriFlavour = itemFlavours.first(where: { $0.type == PasteboardTypes.mimeUriList }) {
                    let raw = String(decoding: uriFlavour.data, as: UTF8.self)
                    for line in raw.split(whereSeparator: \.isNewline) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                        if let url = URL(string: trimmed), url.isFileURL {
                            if let urlData = url.absoluteString.data(using: .utf8) {
                                itemFlavours.append(Flavour(itemIndex: index, type: PasteboardTypes.fileURL, data: urlData))
                                break
                            }
                        }
                    }
                }
            }

            let item = NSPasteboardItem()
            for flavour in itemFlavours {
                item.setData(flavour.data, forType: NSPasteboard.PasteboardType(flavour.type))
            }
            return item
        }

        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        return pasteboard.changeCount
    }
}
