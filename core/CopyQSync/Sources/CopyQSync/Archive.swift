// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reader for CopyQ's `.cpq` archive.
//
// A `.cpq` file is CopyQ's own export.  Version 4 - the one CopyQ writes by
// default and the one CopyQ's own backups use - is:
//
//   QByteArray  "CopyQ v4"
//   QVariantMap the export data (settings, commands, tab name list)
//   QVariantMap one map per tab: "name", "data" (the serialised items),
//               and optionally "icon"
//
// Version 5 replaces the QVariant maps with CopyQ's item data container and
// stores each setting as a serialised QVariant.  Both are read here; the
// writer (`CopyQArchiveWriter`) emits v4, see that file for why.
//
// Items CopyQmac exported carry their creation time in
// `CopyQFormat.macItemCreatedAt`, which is lifted into
// `CopyQSyncItem.timestamp` while parsing and removed from the flavour map.

import Foundation

public struct CopyQArchive {
    public enum Format: String {
        case v4 = "CopyQ v4"
        case v5 = "CopyQ v5"
    }

    public struct Failure: Equatable {
        public var location: String
        public var format: String
        public var reason: String

        public init(location: String, format: String, reason: String) {
            self.location = location
            self.format = format
            self.reason = reason
        }
    }

    public struct ItemListResult {
        public var items: [CopyQSyncItem]
        public var failures: [Failure]

        public init(items: [CopyQSyncItem], failures: [Failure] = []) {
            self.items = items
            self.failures = failures
        }
    }

    public var format: Format
    /// The top level export map.  For v4 this is decoded directly; for v5 the
    /// per-key serialised variants are decoded back into values.
    public var settings: [String: QVariantValue]
    public var commands: [QVariantValue]
    public var tabNames: [String]
    /// Items per tab, keyed by tab name.
    public var tabItems: [String: [CopyQSyncItem]]
    /// Compressed flavours that could not be decoded while retaining the rest.
    public var failures: [Failure]

    /// Every item in the archive, across all tabs.
    public var items: [CopyQSyncItem] {
        tabNames.flatMap { tabItems[$0] ?? [] }
    }

    public static func read(
        atPath path: String,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> CopyQArchive {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try read(data, maximumDecompressedSize: maximumDecompressedSize)
    }

    public static func read(
        _ data: Data,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> CopyQArchive {
        var reader = QDataStreamReader(data)
        guard let magicData = try reader.readQByteArray(),
              let magic = String(data: magicData, encoding: .utf8),
              let format = Format(rawValue: magic)
        else {
            throw QDataStreamError.corrupt("not a CopyQ archive: missing magic header")
        }

        switch format {
        case .v4:
            return try readV4(
                &reader,
                format: format,
                maximumDecompressedSize: maximumDecompressedSize
            )
        case .v5:
            return try readV5(
                &reader,
                format: format,
                maximumDecompressedSize: maximumDecompressedSize
            )
        }
    }

    private static func readV4(
        _ reader: inout QDataStreamReader,
        format: Format,
        maximumDecompressedSize: Int
    ) throws -> CopyQArchive {
        let top = try QVariantReader.readMap(from: &reader, version: .qt47)

        var tabNames: [String] = []
        if case let .stringList(names)? = top["tabs"] {
            tabNames = names.compactMap { $0 }
        }

        var tabItems: [String: [CopyQSyncItem]] = [:]
        var failures: [Failure] = []
        var index = 0
        while !reader.isAtEnd {
            let tabMap = try QVariantReader.readMap(from: &reader, version: .qt47)
            let name: String
            if let explicit = tabMap["name"]?.stringValue {
                name = explicit
                if !tabNames.contains(name) {
                    tabNames.append(name)
                }
            } else {
                name = appendFallbackTabName(index: index, to: &tabNames)
            }
            if let dataValue = tabMap["data"],
               case let .byteArray(bytes) = dataValue,
               let dataBytes = bytes {
                let result = try parseItemList(
                    dataBytes,
                    maximumDecompressedSize: maximumDecompressedSize
                )
                tabItems[name] = result.items
                failures.append(contentsOf: result.failures.map {
                    Failure(
                        location: "tab \(name), \($0.location)",
                        format: $0.format,
                        reason: $0.reason
                    )
                })
            } else {
                tabItems[name] = []
            }
            index += 1
        }

        var commands: [QVariantValue] = []
        if case let .list(values)? = top["commands"] {
            commands = values
        }

        return CopyQArchive(
            format: format,
            settings: top,
            commands: commands,
            tabNames: tabNames,
            tabItems: tabItems,
            failures: failures
        )
    }

    private static func readV5(
        _ reader: inout QDataStreamReader,
        format: Format,
        maximumDecompressedSize: Int
    ) throws -> CopyQArchive {
        let topResult = try CopyQItemData.decodeReportingFailures(
            &reader,
            maximumDecompressedSize: maximumDecompressedSize
        )
        let topBlob = topResult.map
        var failures = topResult.failures.map {
            Failure(location: "settings", format: $0.format, reason: $0.reason)
        }
        var settings: [String: QVariantValue] = [:]
        for key in topBlob.formats {
            guard let bytes = topBlob.bytes(key) else {
                settings[key] = .null(typeId: 0)
                continue
            }
            var variantReader = QDataStreamReader(bytes)
            settings[key] = try QVariantReader.read(from: &variantReader, version: .qt515)
        }

        var tabNames: [String] = []
        if let tabsValue = settings["tabs"], case let .stringList(names) = tabsValue {
            tabNames = names.compactMap { $0 }
        }

        var commands: [QVariantValue] = []
        if let value = settings["commands"], case let .list(values) = value {
            commands = values
        }

        var tabItems: [String: [CopyQSyncItem]] = [:]
        var index = 0
        while !reader.isAtEnd {
            let tabResult = try CopyQItemData.decodeReportingFailures(
                &reader,
                maximumDecompressedSize: maximumDecompressedSize
            )
            let tabBlob = tabResult.map
            let name: String
            if tabNames.indices.contains(index) {
                name = tabNames[index]
            } else {
                name = appendFallbackTabName(index: index, to: &tabNames)
            }
            failures.append(contentsOf: tabResult.failures.map {
                Failure(location: "tab \(name)", format: $0.format, reason: $0.reason)
            })
            if let dataBytes = tabBlob.bytes("data") {
                let result = try parseItemList(
                    dataBytes,
                    maximumDecompressedSize: maximumDecompressedSize
                )
                tabItems[name] = result.items
                failures.append(contentsOf: result.failures.map {
                    Failure(
                        location: "tab \(name), \($0.location)",
                        format: $0.format,
                        reason: $0.reason
                    )
                })
            } else {
                tabItems[name] = []
            }
            index += 1
        }

        return CopyQArchive(
            format: format,
            settings: settings,
            commands: commands,
            tabNames: tabNames,
            tabItems: tabItems,
            failures: failures
        )
    }

    private static func appendFallbackTabName(index: Int, to tabNames: inout [String]) -> String {
        let baseName = "tab-\(index)"
        var name = baseName
        var suffix = 1
        while tabNames.contains(name) {
            name = "\(baseName)-\(suffix)"
            suffix += 1
        }
        tabNames.append(name)
        return name
    }

    /// Decodes the item list CopyQ stores inside a tab, which is a v4
    /// serialised `QAbstractItemModel`: an item count followed by one data
    /// container per item.
    public static func parseItemList(
        _ data: Data,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> ItemListResult {
        var reader = QDataStreamReader(data)
        let count = try reader.readInt32()
        guard count >= 0, count <= 1_000_000 else {
            throw QDataStreamError.corrupt("invalid archive item count \(count)")
        }
        var items: [CopyQSyncItem] = []
        var failures: [Failure] = []
        for index in 0..<count {
            let decoded = try CopyQItemData.decodeReportingFailures(
                &reader,
                maximumDecompressedSize: maximumDecompressedSize
            )
            var map = decoded.map
            let createdAt = CopyQFormat.decodeCreatedAt(map.bytes(CopyQFormat.macItemCreatedAt))
            if createdAt != nil {
                map.remove(CopyQFormat.macItemCreatedAt)
            }
            items.append(CopyQSyncItem(data: map, timestamp: createdAt))
            failures.append(contentsOf: decoded.failures.map {
                Failure(location: "item \(index + 1)", format: $0.format, reason: $0.reason)
            })
        }
        return ItemListResult(items: items, failures: failures)
    }

    /// Serialises an item list in the layout `parseItemList` reads.
    static func encodeItemListForTesting(_ items: [CopyQSyncItem]) -> Data {
        var stream = QDataStreamWriter()
        stream.writeInt32(Int32(items.count))
        for item in items {
            CopyQItemData.encode(item.data, into: &stream)
        }
        return stream.data
    }
}
