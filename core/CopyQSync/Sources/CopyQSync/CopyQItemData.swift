// SPDX-License-Identifier: GPL-3.0-or-later
//
// Codec for the CopyQ item data map, the payload of `<stem>_copyq.dat`.
//
// On disk the container is a Qt `QDataStream` holding:
//
//   qint32   version (-2 for the current format, -3 for encrypted data,
//            and a non-negative legacy item count for the deprecated v1)
//   qint32   flavour count                     (v2)
//   for each flavour:
//     QString  MIME type, optionally prefix compressed
//     qint8    compression flag (0 = stored, 1 = qCompress)
//     QByteArray  the flavour bytes (0xFFFFFFFF marks a null value)
//
// CopyQ writes 1 for flavours larger than `item_data_threshold` and stores
// their qCompress payload, and 0 for everything else.  The sync writer keeps
// the raw layout so `_copyq.dat` files stay byte-stable; the archive writer
// asks for the compressed form.

import Foundation

/// A flavour map decoded from `_copyq.dat` or from a `.cpq` archive.
///
/// A missing key and a key with a `nil` value are different things: the
/// latter is a null `QByteArray` such as the empty marker CopyQ stores for
/// `application/x-copyq-item-pinned`.
public struct CopyQDataMap: Equatable {
    private var storage: [String: Data?]

    public init() {
        storage = [:]
    }

    public init(_ storage: [String: Data?]) {
        self.storage = storage
    }

    /// Every format in Qt's `QMap` order (UTF-16 code units ascending).
    public var formats: [String] {
        storage.keys.sorted(by: qtStringLessThan)
    }

    public var isEmpty: Bool { storage.isEmpty }

    public var count: Int { storage.count }

    public func contains(_ format: String) -> Bool {
        storage.index(forKey: format) != nil
    }

    /// `nil` when the format is absent, `.some(nil)` for a null value and
    /// `.some(bytes)` otherwise.
    public func value(_ format: String) -> Data?? {
        storage[format]
    }

    /// The bytes for a format, treating both "absent" and "null" as `nil`.
    public func bytes(_ format: String) -> Data? {
        (storage[format] ?? nil)
    }

    /// Stores a format.  `nil` bytes records a null `QByteArray`.
    public mutating func set(_ format: String, _ bytes: Data?) {
        storage.updateValue(bytes, forKey: format)
    }

    public mutating func set(_ format: String, _ bytes: [UInt8]) {
        set(format, Data(bytes))
    }

    public mutating func remove(_ format: String) {
        storage.removeValue(forKey: format)
    }

    /// The map as a plain Swift dictionary.
    public var asDictionary: [String: Data?] { storage }
}

public enum CopyQItemData {
    /// CopyQ's `item_data_threshold` default: a flavour whose payload is
    /// larger than this many bytes is stored qCompress-ed.
    public static let itemDataThreshold = 1024

    public struct Failure: Equatable {
        public var format: String
        public var reason: String

        public init(format: String, reason: String) {
            self.format = format
            self.reason = reason
        }
    }

    public struct DecodeResult {
        public var map: CopyQDataMap
        public var failures: [Failure]

        public init(map: CopyQDataMap, failures: [Failure] = []) {
            self.map = map
            self.failures = failures
        }
    }

    /// Decodes the payload of a `_copyq.dat` file. Throws if any flavour
    /// cannot be decompressed.
    public static func decode(
        _ data: Data,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> CopyQDataMap {
        var reader = QDataStreamReader(data)
        return try decode(&reader, maximumDecompressedSize: maximumDecompressedSize)
    }

    /// Decodes a data map from an existing stream, consuming exactly its
    /// bytes. Throws if any flavour cannot be decompressed.
    public static func decode(
        _ reader: inout QDataStreamReader,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> CopyQDataMap {
        let result = try decodeReportingFailures(
            &reader,
            maximumDecompressedSize: maximumDecompressedSize
        )
        if let failure = result.failures.first {
            throw QDataStreamError.corrupt(
                "failed to decompress flavour \"\(failure.format)\": \(failure.reason)"
            )
        }
        return result.map
    }

    /// Decodes all readable flavours and retains decompression failures so a
    /// caller can use the rest of the item and report the failed formats.
    public static func decodeReportingFailures(
        _ data: Data,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> DecodeResult {
        var reader = QDataStreamReader(data)
        return try decodeReportingFailures(
            &reader,
            maximumDecompressedSize: maximumDecompressedSize
        )
    }

    /// Decodes a map from an existing stream, retaining per-flavour
    /// decompression failures while consuming the complete map.
    public static func decodeReportingFailures(
        _ reader: inout QDataStreamReader,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> DecodeResult {
        guard maximumDecompressedSize >= 0 else {
            throw QDataStreamError.outOfRange("negative decompression limit")
        }
        let version = try reader.readInt32()

        if version == -2 {
            return try decodeV2(&reader, maximumDecompressedSize: maximumDecompressedSize)
        }
        if version == -3 {
            throw QDataStreamError.corrupt("encrypted item data (v3) is not supported")
        }
        if version < 0 {
            throw QDataStreamError.corrupt("unknown item data version \(version)")
        }
        return try decodeV1(
            &reader,
            count: Int(version),
            maximumDecompressedSize: maximumDecompressedSize
        )
    }

    private static func decodeV2(
        _ reader: inout QDataStreamReader,
        maximumDecompressedSize: Int
    ) throws -> DecodeResult {
        let count = try reader.readInt32()
        guard count >= 0, count <= 1_000_000 else {
            throw QDataStreamError.corrupt("invalid flavour count \(count)")
        }

        var map = CopyQDataMap()
        var failures: [Failure] = []
        for _ in 0..<count {
            let compressedMime = try reader.readQString()
            let format = try CopyQMimeCompression.decompress(compressedMime)
                ?? ""
            let isCompressed = try reader.readBool()
            var bytes = try reader.readQByteArray()
            if isCompressed, let compressed = bytes {
                do {
                    bytes = try QtCompression.decompress(
                        compressed,
                        maximumSize: maximumDecompressedSize
                    )
                } catch {
                    failures.append(Failure(format: format, reason: "\(error)"))
                    continue
                }
            }
            map.set(format, bytes)
        }
        return DecodeResult(map: map, failures: failures)
    }

    private static func decodeV1(
        _ reader: inout QDataStreamReader,
        count: Int,
        maximumDecompressedSize: Int
    ) throws -> DecodeResult {
        guard count >= 0, count <= 1_000_000 else {
            throw QDataStreamError.corrupt("invalid flavour count \(count)")
        }
        var map = CopyQDataMap()
        var failures: [Failure] = []
        for _ in 0..<count {
            let format = try reader.readQString() ?? ""
            let raw = try reader.readQByteArray()
            if let raw, !raw.isEmpty {
                do {
                    map.set(
                        format,
                        try QtCompression.decompress(raw, maximumSize: maximumDecompressedSize)
                    )
                } catch {
                    failures.append(Failure(format: format, reason: "\(error)"))
                }
            } else {
                map.set(format, raw)
            }
        }
        return DecodeResult(map: map, failures: failures)
    }

    /// Serialises a flavour map exactly the way CopyQ writes `_copyq.dat`.
    public static func encode(_ map: CopyQDataMap) -> Data {
        var stream = QDataStreamWriter()
        encode(map, into: &stream)
        return stream.data
    }

    /// Appends the serialised map to an existing stream, storing every
    /// flavour raw.
    public static func encode(_ map: CopyQDataMap, into stream: inout QDataStreamWriter) {
        encode(map, into: &stream, compressionThreshold: nil)
    }

    /// Appends the serialised map to an existing stream.
    ///
    /// When `compressionThreshold` is set, a non-null flavour larger than it
    /// is written with the compression flag set and its qCompress payload,
    /// mirroring CopyQ's `item_data_threshold`.  `nil` keeps every flavour
    /// raw, which is what the sync folder writer wants.
    public static func encode(
        _ map: CopyQDataMap,
        into stream: inout QDataStreamWriter,
        compressionThreshold: Int?
    ) {
        stream.writeInt32(-2)
        let formats = map.formats
        stream.writeInt32(Int32(formats.count))
        for format in formats {
            stream.writeQString(CopyQMimeCompression.compress(format))
            let value = map.value(format)
            if let threshold = compressionThreshold,
               let bytes = value ?? nil,
               bytes.count > threshold,
               let compressed = QtCompression.compress(bytes) {
                stream.writeBool(true)
                stream.writeQByteArray(compressed)
            } else {
                stream.writeBool(false)
                switch value {
                case .some(let bytes):
                    stream.writeQByteArray(bytes)
                case .none:
                    // Should not happen; `formats` is derived from the storage.
                    stream.writeQByteArray(nil)
                }
            }
        }
    }
}
