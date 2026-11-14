// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQ MIME format helpers.
//
// CopyQ identifies every clipboard flavour by a MIME type name.  The sync
// plugin writes the flavours it knows about to one file per flavour and packs
// the rest into `<stem>_copyq.dat`.  This file holds the shared vocabulary:
// the well known format names, the extension table and the MIME type
// compression scheme used inside `_copyq.dat`.

import Foundation

public enum CopyQFormat {
    /// Prefix for CopyQ's own bookkeeping formats.
    public static let prefix = "application/x-copyq-"

    public static let text = "text/plain"
    public static let textUtf8 = "text/plain;charset=utf-8"
    public static let html = "text/html"
    /// Rich text copied on Linux (GTK uses the MIME name, macOS uses
    /// `public.rtf`); CopyQ keeps it in `_copyq.dat` because the sync plugin has
    /// no dedicated file extension for it.
    public static let rtf = "text/rtf"
    public static let uriList = "text/uri-list"
    public static let itemNotes = "application/x-copyq-item-notes"
    public static let itemPinned = "application/x-copyq-item-pinned"
    public static let itemTags = "application/x-copyq-tags"
    public static let windowTitle = "application/x-copyq-owner-window-title"

    public static func isBookkeeping(_ format: String) -> Bool {
        format.hasPrefix("application/x-copyq-itemsync-")
            || format.hasPrefix("application/x-copyq-private-")
    }

    /// Creation time of an item, as CopyQmac writes it into its own `.cpq`
    /// exports.
    ///
    /// CopyQ's item model has no creation time: a tab is just an ordered list
    /// of flavour maps, and the order is the only temporal information an
    /// archive carries.  CopyQmac stores each capture's time and orders its
    /// history by it, so an export has to carry the value or a restored
    /// history would collapse every entry onto the restore time.
    ///
    /// CopyQ keeps unknown formats together with the item (it only decodes
    /// the ones its plugins know), so an archive containing this flavour is
    /// still a valid CopyQ export.  `CopyQArchive` lifts the value back into
    /// `CopyQSyncItem.timestamp` and removes the flavour, and
    /// `CopyQSyncBridge.itemToEntry` drops it from every import path, so no
    /// store entry ever holds it and it can neither reach the pasteboard nor a
    /// sync folder.
    public static let macItemCreatedAt = "application/x-copyqmac-item-created-at"

    /// Encodes a creation time as decimal seconds since the Unix epoch.
    ///
    /// `%.17g` is the shortest form that always parses back to the identical
    /// `Double`, so a restored entry keeps the exact `Date` it was captured
    /// with.  `nil` when the date cannot be represented.
    public static func encodeCreatedAt(_ date: Date) -> Data? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return nil }
        return Data(String(format: "%.17g", seconds).utf8)
    }

    /// Decodes a creation time written by `encodeCreatedAt(_:)`.
    public static func decodeCreatedAt(_ bytes: Data?) -> Date? {
        guard let bytes,
              let text = String(data: bytes, encoding: .utf8),
              let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Extension used for the container that holds every flavour without a
    /// dedicated file.
    public static let dataFileSuffix = "_copyq.dat"
    /// Extension used for the item note.
    public static let noteFileSuffix = "_note.txt"

    /// Symbolic format name the sync plugin uses for the `_copyq.dat`
    /// container (CopyQ calls it `unknown-formats`).
    public static let unknownFormats = "application/x-copyq-itemsync-unknown-formats"

    /// The default extension table, in CopyQ's lookup order.  Order matters:
    /// `_note.txt` is tested before `.txt`; `.xml` is reserved for
    /// `application/xml`, while `text/xml` stays in `_copyq.dat`.
    public static let defaultExtensions: [(ext: String, format: String)] = [
        (noteFileSuffix, itemNotes),
        (".txt", text),
        (".html", html),
        (".uri", uriList),
        (".png", "image/png"),
        ("_inkscape.svg", "image/x-inkscape-svg-compressed"),
        (".svg", "image/svg+xml"),
        (".bmp", "image/bmp"),
        (".gif", "image/gif"),
        (".jpg", "image/jpeg"),
        (".ico", "image/x-icon"),
        (".webp", "image/webp"),
        (".xml", "application/xml"),
    ]

    /// The extension a format should be written to, or `nil` when the format
    /// belongs in `_copyq.dat`.
    public static func fileExtension(for format: String) -> String? {
        if format == unknownFormats { return dataFileSuffix }
        for entry in defaultExtensions where entry.format == format {
            return entry.ext
        }
        return nil
    }

    /// The format a file extension belongs to, or `nil` when the file should
    /// be ignored.
    public static func format(forExtension ext: String) -> String? {
        if ext == dataFileSuffix { return unknownFormats }
        if ext == noteFileSuffix { return itemNotes }
        for entry in defaultExtensions where entry.ext == ext {
            return entry.format
        }
        return nil
    }

    /// The extension with which a file name ends, longest match first, or
    /// `nil` when no known flavour matches.
    public static func matchedExtension(forFileName name: String) -> String? {
        if name.hasSuffix(dataFileSuffix) { return dataFileSuffix }
        if name.hasSuffix(noteFileSuffix) { return noteFileSuffix }
        for entry in defaultExtensions where name.hasSuffix(entry.ext) {
            return entry.ext
        }
        return nil
    }
}

/// The MIME type prefix table CopyQ uses to shrink the format names stored in
/// `_copyq.dat`.  A leading hexadecimal digit selects the prefix; `0` means
/// the name is stored verbatim.
public enum CopyQMimeCompression {
    static let idToPrefix: [Int: String] = [
        1: CopyQFormat.windowTitle,
        2: CopyQFormat.itemNotes,
        3: CopyQFormat.prefix,
        4: CopyQFormat.text,
        5: CopyQFormat.html,
        6: CopyQFormat.uriList,
        7: "image/",
        8: "text/",
        9: "application/",
        10: "audio/",
        11: "video/",
    ]

    /// Expands a compressed MIME name from `_copyq.dat` into a full format
    /// name.
    public static func decompress(_ compressed: String?) throws -> String? {
        guard let compressed, !compressed.isEmpty else { return compressed }
        let first = compressed.first!
        guard let id = Int(String(first), radix: 16) else {
            throw QDataStreamError.corrupt("invalid compressed MIME type \"\(compressed)\"")
        }
        let rest = String(compressed.dropFirst())
        if id == 0 { return rest }
        guard let prefix = idToPrefix[id] else {
            throw QDataStreamError.corrupt("unknown compressed MIME type prefix \(id)")
        }
        return prefix + rest
    }

    /// Compresses a format name the way CopyQ does before writing it to
    /// `_copyq.dat`.
    public static func compress(_ format: String) -> String {
        // Iterating in ascending id order matches CopyQ's unordered_map order
        // closely enough because the prefixes are disjoint, and it makes the
        // result deterministic.
        for id in idToPrefix.keys.sorted() {
            let prefix = idToPrefix[id]!
            if format.hasPrefix(prefix) {
                return String(id, radix: 16) + String(format.dropFirst(prefix.count))
            }
        }
        return "0" + format
    }
}

/// Compares two strings the way Qt's `QString::operator<` does: by UTF-16
/// code unit, which keeps the ordering inside `_copyq.dat` byte compatible.
func qtStringLessThan(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf16)
    let b = Array(rhs.utf16)
    let n = min(a.count, b.count)
    var i = 0
    while i < n {
        if a[i] != b[i] { return a[i] < b[i] }
        i += 1
    }
    return a.count < b.count
}
