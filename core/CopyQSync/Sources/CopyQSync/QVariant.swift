// SPDX-License-Identifier: GPL-3.0-or-later
//
// Qt `QVariant` reader.
//
// The `.cpq` archive - CopyQ's own export format - serialises a QVariantMap
// of settings and commands, so reading the archive means reading QVariants.
// Only the reader is implemented; the archive is never written back.

import Foundation

/// The Qt `QDataStream` version a payload was written with.  It changes how
/// some types are framed.
public enum QDataStreamVersion {
    /// `QDataStream::Qt_4_7`, CopyQ's `.cpq` v4 import version.
    case qt47
    /// `QDataStream::Qt_5_15`, used inside `.cpq` v5.
    case qt515

    var isAtLeastQt5: Bool {
        if case .qt515 = self { return true }
        return false
    }
}

/// A decoded `QVariant`.
public indirect enum QVariantValue: Equatable {
    case null(typeId: UInt32)
    case bool(Bool)
    case int(Int32)
    case uint(UInt32)
    case longLong(Int64)
    case uLongLong(UInt64)
    case double(Double)
    case float(Float)
    case char(UInt16)
    case string(String?)
    case byteArray(Data?)
    case byteArrayList([Data?])
    case stringList([String?])
    case list([QVariantValue])
    case map([String: QVariantValue])
    case hash([String: QVariantValue])
    case date(julianDay: Int64)
    case time(milliseconds: UInt32)
    case dateTime(
        julianDay: Int64,
        milliseconds: UInt32,
        timeSpec: Int8,
        utcOffsetSeconds: Int32?,
        timeZoneID: Data?
    )
    case url(String?)
    case locale(String?)
    case rect(x: Int32, y: Int32, width: Int32, height: Int32)
    case rectF(x: Double, y: Double, width: Double, height: Double)
    case size(width: Int32, height: Int32)
    case sizeF(width: Double, height: Double)
    case line(x1: Int32, y1: Int32, x2: Int32, y2: Int32)
    case lineF(x1: Double, y1: Double, x2: Double, y2: Double)
    case point(x: Int32, y: Int32)
    case pointF(x: Double, y: Double)
    case regularExpression(pattern: String?, options: UInt32)
    case regExp(pattern: String?, caseSensitivity: UInt8, syntax: UInt8, minimal: UInt8)
    case bitArray(bitCount: UInt32, bytes: Data)
    case variant(QVariantValue)

    /// Best-effort string projection used for settings.
    public var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .url(value): return value
        case let .locale(value): return value
        case let .byteArray(value): return value.flatMap { String(data: $0, encoding: .utf8) }
        case let .bool(value): return value ? "true" : "false"
        case let .int(value): return String(value)
        case let .uint(value): return String(value)
        case let .longLong(value): return String(value)
        case let .uLongLong(value): return String(value)
        case let .double(value): return String(value)
        case let .float(value): return String(value)
        case let .stringList(values): return values.compactMap { $0 }.joined(separator: ", ")
        default: return nil
        }
    }

    private static func int64Projection(_ value: Double) -> Int64? {
        guard value.isFinite,
              value >= Double(Int64.min),
              value < -Double(Int64.min)
        else { return nil }
        return Int64(value)
    }

    public var intValue: Int64? {
        switch self {
        case let .int(value): return Int64(value)
        case let .uint(value): return Int64(value)
        case let .longLong(value): return value
        case let .uLongLong(value): return Int64(exactly: value)
        case let .double(value): return Self.int64Projection(value)
        case let .float(value): return Self.int64Projection(Double(value))
        case let .bool(value): return value ? 1 : 0
        case let .string(value): return value.flatMap { Int64($0) }
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .int(value): return value != 0
        case let .uint(value): return value != 0
        case let .longLong(value): return value != 0
        case let .uLongLong(value): return value != 0
        case let .string(value): return value == "true" ? true : (value == "false" ? false : nil)
        default: return nil
        }
    }

    public var mapValue: [String: QVariantValue]? {
        switch self {
        case let .map(value): return value
        case let .hash(value): return value
        default: return nil
        }
    }

    public var listValue: [QVariantValue]? {
        switch self {
        case let .list(value): return value
        case let .stringList(values): return values.map { .string($0) }
        default: return nil
        }
    }

    public func value(forKey key: String) -> QVariantValue? {
        mapValue?[key]
    }
}

/// Qt meta type ids (Qt 5 numbering, which CopyQ uses).
enum QMetaTypeID {
    static let bool: UInt32 = 1
    static let int: UInt32 = 2
    static let uint: UInt32 = 3
    static let longLong: UInt32 = 4
    static let uLongLong: UInt32 = 5
    static let double: UInt32 = 6
    static let char: UInt32 = 7
    static let variantMap: UInt32 = 8
    static let variantList: UInt32 = 9
    static let string: UInt32 = 10
    static let stringList: UInt32 = 11
    static let byteArray: UInt32 = 12
    static let bitArray: UInt32 = 13
    static let date: UInt32 = 14
    static let time: UInt32 = 15
    static let dateTime: UInt32 = 16
    static let url: UInt32 = 17
    static let locale: UInt32 = 18
    static let rect: UInt32 = 19
    static let rectF: UInt32 = 20
    static let size: UInt32 = 21
    static let sizeF: UInt32 = 22
    static let line: UInt32 = 23
    static let lineF: UInt32 = 24
    static let point: UInt32 = 25
    static let pointF: UInt32 = 26
    static let regExp: UInt32 = 27
    static let variantHash: UInt32 = 28
    static let voidStar: UInt32 = 31
    static let long: UInt32 = 32
    static let short: UInt32 = 33
    static let charType: UInt32 = 34
    static let uLong: UInt32 = 35
    static let uShort: UInt32 = 36
    static let uChar: UInt32 = 37
    static let float: UInt32 = 38
    static let sChar: UInt32 = 40
    static let variant: UInt32 = 41
    static let regularExpression: UInt32 = 44
    static let byteArrayList: UInt32 = 49
    static let user: UInt32 = 1024
}

public enum QVariantReader {
    private static let maximumNestingDepth = 128

    /// Maps a Qt 4 type id (as written by CopyQ's `.cpq` v4) onto the Qt 5
    /// id underlying the value.
    static func remapQt4TypeID(_ typeId: UInt32) -> UInt32 {
        if typeId == 127 { return QMetaTypeID.user }
        if typeId >= 128 { return typeId - 97 }
        if typeId == 75 { return 121 } // QSizePolicy
        if typeId > 75 && typeId <= 86 { return typeId - 1 }
        return typeId
    }

    public static func read(from reader: inout QDataStreamReader, version: QDataStreamVersion) throws -> QVariantValue {
        try read(from: &reader, version: version, depth: 0)
    }

    private static func read(
        from reader: inout QDataStreamReader,
        version: QDataStreamVersion,
        depth: Int
    ) throws -> QVariantValue {
        guard depth <= maximumNestingDepth else {
            throw QDataStreamError.corrupt("QVariant nesting exceeds maximum depth")
        }
        let rawTypeID = try reader.readUInt32()
        let typeID = version.isAtLeastQt5 ? rawTypeID : remapQt4TypeID(rawTypeID)
        let isNull = try reader.readBool()

        if typeID == 0 || isNull {
            return .null(typeId: typeID)
        }

        if typeID == QMetaTypeID.user {
            let name = try reader.readQByteArray()
            throw QDataStreamError.unsupportedUserType(
                name.flatMap { String(data: $0, encoding: .utf8) } ?? "<unnamed>"
            )
        }

        return try readValue(typeID, &reader, version, depth: depth)
    }

    private static func readValue(
        _ typeID: UInt32,
        _ reader: inout QDataStreamReader,
        _ version: QDataStreamVersion,
        depth: Int
    ) throws -> QVariantValue {
        switch typeID {
        case QMetaTypeID.bool:
            return .bool(try reader.readBool())
        case QMetaTypeID.int:
            return .int(try reader.readInt32())
        case QMetaTypeID.uint:
            return .uint(try reader.readUInt32())
        case QMetaTypeID.longLong, QMetaTypeID.long:
            return .longLong(try reader.readInt64())
        case QMetaTypeID.uLongLong, QMetaTypeID.uLong:
            return .uLongLong(try reader.readUInt64())
        case QMetaTypeID.double:
            return .double(try reader.readFloat64())
        case QMetaTypeID.float:
            return .float(try reader.readFloat32())
        case QMetaTypeID.char:
            // `QChar` is a UTF-16 code unit.
            return .char(try reader.readUInt16())
        case QMetaTypeID.charType, QMetaTypeID.sChar:
            return .int(Int32(try reader.readInt8()))
        case QMetaTypeID.short:
            return .int(Int32(try reader.readInt16()))
        case QMetaTypeID.uShort:
            return .uint(UInt32(try reader.readUInt16()))
        case QMetaTypeID.uChar:
            return .uint(UInt32(try reader.readUInt8()))
        case QMetaTypeID.string:
            return .string(try reader.readQString())
        case QMetaTypeID.byteArray:
            return .byteArray(try reader.readQByteArray())
        case QMetaTypeID.stringList:
            return .stringList(try reader.readQStringList())
        case QMetaTypeID.byteArrayList:
            let count = try reader.readCount(minimumElementSize: 4, collection: "QByteArrayList")
            var values: [Data?] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try reader.readQByteArray()) }
            return .byteArrayList(values)
        case QMetaTypeID.variantMap:
            return .map(try readMap(&reader, version: version, depth: depth + 1))
        case QMetaTypeID.variantHash:
            return .hash(try readMap(&reader, version: version, depth: depth + 1))
        case QMetaTypeID.variantList:
            return .list(try readList(&reader, version: version, depth: depth + 1))
        case QMetaTypeID.variant:
            return .variant(try read(from: &reader, version: version, depth: depth + 1))
        case QMetaTypeID.bitArray:
            let bitCount = try reader.readUInt32()
            let byteCount = Int((UInt64(bitCount) + 7) / 8)
            guard byteCount <= reader.remaining else {
                throw QDataStreamError.truncated(
                    needed: byteCount,
                    available: reader.remaining,
                    offset: reader.offset
                )
            }
            return .bitArray(bitCount: bitCount, bytes: try reader.readRawData(byteCount))
        case QMetaTypeID.date:
            return .date(julianDay: try readDate(&reader, version: version))
        case QMetaTypeID.time:
            return .time(milliseconds: try reader.readUInt32())
        case QMetaTypeID.dateTime:
            return try readDateTime(&reader, version: version)
        case QMetaTypeID.url:
            return .url(try reader.readQString())
        case QMetaTypeID.locale:
            return .locale(try reader.readQString())
        case QMetaTypeID.rect:
            return .rect(
                x: try reader.readInt32(), y: try reader.readInt32(),
                width: try reader.readInt32(), height: try reader.readInt32()
            )
        case QMetaTypeID.rectF:
            return .rectF(
                x: try reader.readFloat64(), y: try reader.readFloat64(),
                width: try reader.readFloat64(), height: try reader.readFloat64()
            )
        case QMetaTypeID.size:
            return .size(width: try reader.readInt32(), height: try reader.readInt32())
        case QMetaTypeID.sizeF:
            return .sizeF(width: try reader.readFloat64(), height: try reader.readFloat64())
        case QMetaTypeID.line:
            return .line(
                x1: try reader.readInt32(), y1: try reader.readInt32(),
                x2: try reader.readInt32(), y2: try reader.readInt32()
            )
        case QMetaTypeID.lineF:
            return .lineF(
                x1: try reader.readFloat64(), y1: try reader.readFloat64(),
                x2: try reader.readFloat64(), y2: try reader.readFloat64()
            )
        case QMetaTypeID.point:
            return .point(x: try reader.readInt32(), y: try reader.readInt32())
        case QMetaTypeID.pointF:
            return .pointF(x: try reader.readFloat64(), y: try reader.readFloat64())
        case QMetaTypeID.regularExpression:
            return .regularExpression(
                pattern: try reader.readQString(),
                options: try reader.readUInt32()
            )
        case QMetaTypeID.regExp:
            return .regExp(
                pattern: try reader.readQString(),
                caseSensitivity: try reader.readUInt8(),
                syntax: try reader.readUInt8(),
                minimal: try reader.readUInt8()
            )
        default:
            throw QDataStreamError.unsupportedType(typeID)
        }
    }

    /// Reads a bare `QVariantMap`/`QMap<QString, QVariant>` (a count, then
    /// key/value pairs).  This is what CopyQ writes for the archive's top
    /// level map and per-tab maps, which are not wrapped in a `QVariant`.
    public static func readMap(
        from reader: inout QDataStreamReader,
        version: QDataStreamVersion
    ) throws -> [String: QVariantValue] {
        try readMap(from: &reader, version: version, depth: 0)
    }

    private static func readMap(
        from reader: inout QDataStreamReader,
        version: QDataStreamVersion,
        depth: Int
    ) throws -> [String: QVariantValue] {
        let count = try reader.readCount(minimumElementSize: 9, collection: "QVariantMap")
        var result: [String: QVariantValue] = [:]
        result.reserveCapacity(count)
        for _ in 0..<count {
            let key = try reader.readQString() ?? ""
            result[key] = try read(from: &reader, version: version, depth: depth)
        }
        return result
    }

    private static func readMap(
        _ reader: inout QDataStreamReader,
        version: QDataStreamVersion,
        depth: Int
    ) throws -> [String: QVariantValue] {
        try readMap(from: &reader, version: version, depth: depth)
    }

    private static func readList(
        _ reader: inout QDataStreamReader,
        version: QDataStreamVersion,
        depth: Int
    ) throws -> [QVariantValue] {
        let count = try reader.readCount(minimumElementSize: 5, collection: "QVariantList")
        var result: [QVariantValue] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try read(from: &reader, version: version, depth: depth))
        }
        return result
    }

    private static func readDate(
        _ reader: inout QDataStreamReader,
        version: QDataStreamVersion
    ) throws -> Int64 {
        if version.isAtLeastQt5 {
            return try reader.readInt64()
        }
        return Int64(try reader.readUInt32())
    }

    private static func readDateTime(
        _ reader: inout QDataStreamReader,
        version: QDataStreamVersion
    ) throws -> QVariantValue {
        let julian = try readDate(&reader, version: version)
        let milliseconds = try reader.readUInt32()
        let spec = try reader.readInt8()
        var utcOffsetSeconds: Int32?
        var timeZoneID: Data?
        if version.isAtLeastQt5 {
            if spec == 2 {
                utcOffsetSeconds = try reader.readInt32()
            } else if spec == 3 {
                timeZoneID = try reader.readQByteArray()
            }
        }
        return .dateTime(
            julianDay: julian,
            milliseconds: milliseconds,
            timeSpec: spec,
            utcOffsetSeconds: utcOffsetSeconds,
            timeZoneID: timeZoneID
        )
    }
}
