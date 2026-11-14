// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal Qt `QDataStream` reader/writer.
//
// CopyQ stores its data with Qt's `QDataStream` in big-endian byte order.
// This file implements only the primitives the CopyQ sync and archive
// formats need: fixed width integers, `bool`, `QString`, `QByteArray`
// and raw byte runs.  None of it depends on Qt, Xcode or XCTest.

import Foundation

/// Errors raised while reading or writing a Qt data stream.
public enum QDataStreamError: Error, CustomStringConvertible, Equatable {
    /// The stream ended before the requested number of bytes was available.
    case truncated(needed: Int, available: Int, offset: Int)
    /// A primitive was handed a value it cannot represent.
    case outOfRange(String)
    /// The stream carries a type this library does not know how to read.
    case unsupportedType(UInt32)
    /// The stream is structurally invalid.
    case corrupt(String)
    /// A custom (user registered) Qt type was found; it cannot be decoded.
    case unsupportedUserType(String)

    public var description: String {
        switch self {
        case let .truncated(needed, available, offset):
            return "truncated stream: needed \(needed) more byte(s) at offset \(offset), \(available) available"
        case let .outOfRange(message):
            return "value out of range: \(message)"
        case let .unsupportedType(type):
            return "unsupported Qt metatype id \(type)"
        case let .corrupt(message):
            return "corrupt stream: \(message)"
        case let .unsupportedUserType(name):
            return "unsupported Qt user type \"\(name)\""
        }
    }
}

/// Reads big-endian Qt `QDataStream` primitives from an in-memory buffer.
public struct QDataStreamReader {
    private let bytes: [UInt8]

    /// Number of bytes consumed so far.
    public private(set) var offset: Int = 0

    /// Bytes left to read.
    public var remaining: Int { bytes.count - offset }

    /// Total number of bytes in the underlying buffer.
    public var count: Int { bytes.count }

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// True once every byte has been consumed.
    public var isAtEnd: Bool { offset == bytes.count }

    private func require(_ n: Int) throws {
        guard n >= 0, offset + n <= bytes.count else {
            throw QDataStreamError.truncated(needed: n, available: remaining, offset: offset)
        }
    }

    mutating func readCount(minimumElementSize: Int, collection: String) throws -> Int {
        let count = try readUInt32()
        guard minimumElementSize > 0,
              UInt64(count) <= UInt64(remaining / minimumElementSize)
        else {
            throw QDataStreamError.corrupt(
                "\(collection) count \(count) exceeds the remaining stream"
            )
        }
        return Int(count)
    }

    public mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    public mutating func readUInt16() throws -> UInt16 {
        let hi = UInt16(try readUInt8())
        let lo = UInt16(try readUInt8())
        return (hi << 8) | lo
    }

    public mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    public mutating func readUInt32() throws -> UInt32 {
        let b0 = UInt32(try readUInt8())
        let b1 = UInt32(try readUInt8())
        let b2 = UInt32(try readUInt8())
        let b3 = UInt32(try readUInt8())
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readUInt64() throws -> UInt64 {
        let hi = UInt64(try readUInt32())
        let lo = UInt64(try readUInt32())
        return (hi << 32) | lo
    }

    public mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    public mutating func readFloat32() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    public mutating func readFloat64() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    /// Qt serialises `bool` as a single byte.
    public mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    /// Reads `n` raw bytes as a `Data` value.
    public mutating func readRawData(_ n: Int) throws -> Data {
        try require(n)
        defer { offset += n }
        return Data(bytes[offset..<(offset + n)])
    }

    /// Reads Qt's length-prefixed `QByteArray`.  `nil` (0xFFFFFFFF) means a
    /// null byte array, which is distinct from an empty one.
    public mutating func readQByteArray() throws -> Data? {
        let length = try readUInt32()
        if length == 0xFFFF_FFFF { return nil }
        guard length <= UInt32(Int32.max) else {
            throw QDataStreamError.corrupt("QByteArray length \(length) is too large")
        }
        return try readRawData(Int(length))
    }

    /// Reads Qt's length-prefixed UTF-16 `QString`.  `nil` (0xFFFFFFFF) means
    /// a null string.
    public mutating func readQString() throws -> String? {
        let byteLength = try readUInt32()
        if byteLength == 0xFFFF_FFFF { return nil }
        guard byteLength % 2 == 0 else {
            throw QDataStreamError.corrupt("QString byte length \(byteLength) is odd")
        }
        let raw = try readRawData(Int(byteLength))
        return QStringCodec.decode(raw)
    }

    /// Reads a `QStringList` (count, then each string).
    public mutating func readQStringList() throws -> [String?] {
        let count = try readCount(minimumElementSize: 4, collection: "QStringList")
        var result: [String?] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try readQString())
        }
        return result
    }
}

/// Writes big-endian Qt `QDataStream` primitives into an in-memory buffer.
public struct QDataStreamWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// The accumulated bytes.
    public var data: Data { Data(bytes) }

    public mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func writeInt8(_ value: Int8) {
        bytes.append(UInt8(bitPattern: value))
    }

    public mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    public mutating func writeInt16(_ value: Int16) {
        writeUInt16(UInt16(bitPattern: value))
    }

    public mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    public mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    public mutating func writeUInt64(_ value: UInt64) {
        writeUInt32(UInt32(truncatingIfNeeded: value >> 32))
        writeUInt32(UInt32(truncatingIfNeeded: value))
    }

    public mutating func writeInt64(_ value: Int64) {
        writeUInt64(UInt64(bitPattern: value))
    }

    public mutating func writeFloat32(_ value: Float) {
        writeUInt32(value.bitPattern)
    }

    public mutating func writeFloat64(_ value: Double) {
        writeUInt64(value.bitPattern)
    }

    public mutating func writeBool(_ value: Bool) {
        writeUInt8(value ? 1 : 0)
    }

    public mutating func writeRawData(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    public mutating func writeRawData(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
    }

    /// Writes a length-prefixed `QByteArray`; `nil` writes 0xFFFFFFFF.
    public mutating func writeQByteArray(_ data: Data?) {
        guard let data else {
            writeUInt32(0xFFFF_FFFF)
            return
        }
        writeUInt32(UInt32(data.count))
        writeRawData(data)
    }

    /// Writes a length-prefixed UTF-16 `QString`; `nil` writes 0xFFFFFFFF.
    public mutating func writeQString(_ value: String?) {
        guard let value else {
            writeUInt32(0xFFFF_FFFF)
            return
        }
        let raw = QStringCodec.encode(value)
        writeUInt32(UInt32(raw.count))
        writeRawData(raw)
    }

    public mutating func writeQStringList(_ values: [String?]) {
        writeUInt32(UInt32(values.count))
        for value in values {
            writeQString(value)
        }
    }
}

/// Qt serialises `QString` as big-endian UTF-16 code units with a byte length
/// prefix.  Kept separate so the `_copyq.dat` round trip stays byte exact.
enum QStringCodec {
    static func encode(_ value: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(value.utf16.count * 2)
        for unit in value.utf16 {
            out.append(UInt8((unit >> 8) & 0xFF))
            out.append(UInt8(unit & 0xFF))
        }
        return out
    }

    static func decode(_ raw: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(raw.count / 2)
        let bytes = [UInt8](raw)
        var i = 0
        while i + 1 < bytes.count {
            units.append((UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
