// SPDX-License-Identifier: GPL-3.0-or-later
//
// The in-memory model of one CopyQ sync item.
//
// A sync item is a group of files sharing a name stem:
//
//   copyq_20260829120939486.txt          text/plain
//   copyq_20260829120939486.html         text/html
//   copyq_20260829120939486_note.txt     application/x-copyq-item-notes
//   copyq_20260829120939486_copyq.dat    every flavour without a file
//   copyq_20260829120939486.png          image/png
//
// The stem is CopyQ's UTC creation stamp, `copyq_yyyyMMddhhmmsszzz`.

import Foundation

public struct CopyQSyncItem: Equatable {
    /// The file name stem, e.g. `copyq_20260829120939486`.  `nil` for items
    /// that came from an archive rather than a sync folder.
    public var baseName: String?

    /// The item's flavours.  A missing key and a null value differ; see
    /// `CopyQDataMap`.
    public var data: CopyQDataMap

    /// Format to file name (relative to the sync folder) for the flavours
    /// stored in their own file.
    public var fileNames: [String: String]

    /// The item's import timestamp: the later of the UTC creation time in
    /// `baseName` and the modification time of its newest backing file.
    ///
    /// The two sources back each other up.  Syncthing preserves modification
    /// times, so a genuinely old item keeps its real date even when its name
    /// stamp is unreadable, while an item whose name carries a stale stamp
    /// (some CopyQ builds reuse a fixed base name and only bump a counter)
    /// gets the date the file actually arrived instead of the stale one.
    public var timestamp: Date?

    /// Modification time of the newest file backing the item, when read from
    /// disk.
    public var fileModificationDate: Date?

    public init(
        baseName: String? = nil,
        data: CopyQDataMap = CopyQDataMap(),
        fileNames: [String: String] = [:],
        timestamp: Date? = nil,
        fileModificationDate: Date? = nil
    ) {
        self.baseName = baseName
        self.data = data
        self.fileNames = fileNames
        self.timestamp = timestamp
        self.fileModificationDate = fileModificationDate
    }

    // MARK: - Well known metadata

    /// UTF-8 text flavour, if present.
    public var text: String? {
        CopyQSyncItem.utf8(data.bytes(CopyQFormat.text) ?? data.bytes(CopyQFormat.textUtf8))
    }

    /// UTF-8 HTML flavour, if present.
    public var html: String? {
        CopyQSyncItem.utf8(data.bytes(CopyQFormat.html))
    }

    /// The item note.  `nil` when the item has no note.
    public var notes: String? {
        CopyQSyncItem.utf8(data.bytes(CopyQFormat.itemNotes))
    }

    /// True when the item carries CopyQ's pinned marker.  The marker's value
    /// is an empty `QByteArray`, so only the key's presence matters.
    public var isPinned: Bool {
        data.contains(CopyQFormat.itemPinned)
    }

    /// Tags from `application/x-copyq-tags`, which CopyQ stores as a comma
    /// separated UTF-8 list.
    public var tags: [String] {
        guard let raw = data.bytes(CopyQFormat.itemTags),
              let text = CopyQSyncItem.utf8(raw) else { return [] }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Every flavour whose MIME type is an image, as raw bytes.
    public var images: [String: Data] {
        var result: [String: Data] = [:]
        for format in data.formats where format.hasPrefix("image/") {
            if let bytes = data.bytes(format) {
                result[format] = bytes
            }
        }
        return result
    }

    // MARK: - Serialisation

    /// The set of files this item occupies in a sync folder, keyed by the
    /// suffix appended to the stem.
    ///
    /// This mirrors CopyQ's write rules: flavours with a known extension get
    /// their own file, every other flavour is packed into `_copyq.dat`, and
    /// the container is written whenever there are no format files or when
    /// there are flavours left over.
    public func onDiskFiles() -> [String: Data] {
        var files: [String: Data] = [:]
        var unknown = CopyQDataMap()

        for format in data.formats {
            // CopyQ skips the plugin bookkeeping formats when saving.
            if CopyQFormat.isBookkeeping(format) {
                continue
            }

            let bytes = data.bytes(format)
            if let ext = CopyQFormat.fileExtension(for: format) {
                // A null value still produces an (empty) file.
                files[ext] = bytes ?? Data()
            } else {
                unknown.set(format, bytes)
            }
        }

        if files.isEmpty || !unknown.isEmpty {
            files[CopyQFormat.dataFileSuffix] = CopyQItemData.encode(unknown)
        }

        return files
    }

    // MARK: - Timestamp parsing

    /// Resolves the timestamp an imported item carries from its two candidate
    /// sources: the stamp in its file name and its newest file modification
    /// time.  The later of the two wins.
    public static func effectiveTimestamp(
        nameTimestamp: Date?,
        fileModificationDate: Date?
    ) -> Date? {
        switch (nameTimestamp, fileModificationDate) {
        case let (name?, modified?):
            return max(name, modified)
        case let (name?, nil):
            return name
        case let (nil, modified?):
            return modified
        case (nil, nil):
            return nil
        }
    }

    /// Parses `copyq_yyyyMMddhhmmsszzz` in UTC.  `hh` is the 24 hour clock in
    /// Qt's date syntax when no AM/PM marker is present.
    public static func parseTimestamp(baseName: String) -> Date? {
        let prefix = "copyq_"
        guard baseName.hasPrefix(prefix) else { return nil }
        let digits = baseName.dropFirst(prefix.count).prefix(17)
        guard digits.count == 17 else { return nil }
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        let values = digits.map { Int(String($0))! }
        let year = values[0] * 1000 + values[1] * 100 + values[2] * 10 + values[3]
        let month = values[4] * 10 + values[5]
        let day = values[6] * 10 + values[7]
        let hour = values[8] * 10 + values[9]
        let minute = values[10] * 10 + values[11]
        let second = values[12] * 10 + values[13]
        let millisecond = values[14] * 100 + values[15] * 10 + values[16]

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = millisecond * 1_000_000

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components) else { return nil }
        // Reject stamps Calendar silently normalised (e.g. month 13).
        let check = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        guard check.year == year, check.month == month, check.day == day,
              check.hour == hour, check.minute == minute, check.second == second
        else { return nil }
        return date
    }

    static func utf8(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
