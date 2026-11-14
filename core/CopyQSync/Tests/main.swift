// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tiny test runner for the CopyQSync module.
//
// No XCTest: the module and these tests must build and run with only the
// macOS Command Line Tools.  Run it through tools/copyq-sync-tests.sh.
//
// Arguments:
//   --corpus <dir>   additionally round trip every _copyq.dat under <dir>
//   --cpq <file>     additionally parse a real .cpq archive

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("ok   \(name)")
    } else {
        failures += 1
        let extra = detail()
        print("FAIL \(name)" + (extra.isEmpty ? "" : ": \(extra)"))
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    checks += 1
    if actual == expected {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name): expected \(expected), got \(actual)")
    }
}

func hex(_ string: String) -> Data {
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return Data(bytes)
}

func toHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Real capture fixtures

// The two `_copyq.dat` layouts that occur in real CopyQ sync folders,
// copied byte for byte.  They contain no clipboard content, only the Qt MIME
// type marker "dummy" and CopyQ's pinned marker.

let realDummyDAT = hex(
    "fffffffe000000010000002800390078002d00710074002d006d0069006d0065002d007400"
    + "7900700065002d006e0061006d0065000000000564756d6d79"
)
let realPinnedDAT = hex(
    "fffffffe00000001000000180033006900740065006d002d00700069006e006e0065006400"
    + "ffffffff"
)

func testRealFixtureRoundTrip() {
    for (name, original) in [("dummy marker", realDummyDAT), ("pinned marker", realPinnedDAT)] {
        do {
            let map = try CopyQItemData.decode(original)
            let rewritten = CopyQItemData.encode(map)
            check(
                rewritten == original,
                "real \(name) round trips byte-identically",
                "\(toHex(original)) vs \(toHex(rewritten))"
            )
        } catch {
            check(false, "real \(name) round trips byte-identically", "\(error)")
        }
    }
}

func testRealFixtureStructure() {
    do {
        let map = try CopyQItemData.decode(realDummyDAT)
        expectEqual(map.formats, ["application/x-qt-mime-type-name"], "dummy marker format name")
        expectEqual(map.bytes("application/x-qt-mime-type-name"), Data("dummy".utf8), "dummy marker value")
    } catch {
        check(false, "dummy marker decodes", "\(error)")
    }

    do {
        let map = try CopyQItemData.decode(realPinnedDAT)
        expectEqual(map.formats, ["application/x-copyq-item-pinned"], "pinned marker format name")
        check(map.contains(CopyQFormat.itemPinned), "pinned marker is present")
        check(map.value(CopyQFormat.itemPinned) == .some(nil), "pinned marker is a null byte array")
    } catch {
        check(false, "pinned marker decodes", "\(error)")
    }
}

// MARK: - Data map codec

func testDataMapOrdering() {
    var map = CopyQDataMap()
    map.set("text/plain", Data("hi".utf8))
    map.set("application/x-copyq-item-pinned", nil)
    map.set("image/png", Data([0x89, 0x50, 0x4E, 0x47]))

    let encoded = CopyQItemData.encode(map)
    do {
        let decoded = try CopyQItemData.decode(encoded)
        expectEqual(decoded.formats, map.formats, "data map formats survive the round trip")
        expectEqual(decoded.bytes("text/plain"), Data("hi".utf8), "text/plain survives the round trip")
        expectEqual(decoded.bytes("image/png"), Data([0x89, 0x50, 0x4E, 0x47]), "image/png survives the round trip")
        check(decoded.value("application/x-copyq-item-pinned") == .some(nil), "null value is preserved")
    } catch {
        check(false, "data map round trip", "\(error)")
    }

    // CopyQ stores flavours in QMap order, which is UTF-16 ascending: an
    // "application/..." key precedes an "image/..." key precedes "text/...".
    let compressedOrder = ["text/plain", "image/png", "application/x-copyq-item-pinned"]
        .sorted(by: qtStringLessThan)
    expectEqual(
        compressedOrder,
        ["application/x-copyq-item-pinned", "image/png", "text/plain"],
        "formats sort in Qt map order"
    )
}

func testIntValueFloatSafety() {
    expectEqual(QVariantValue.double(.nan).intValue, nil, "NaN double cannot project to Int64")
    expectEqual(QVariantValue.double(.infinity).intValue, nil, "infinite double cannot project to Int64")
    expectEqual(QVariantValue.double(-.infinity).intValue, nil, "negative infinite double cannot project to Int64")
    expectEqual(QVariantValue.double(Double(Int64.max)).intValue, nil, "out-of-range double cannot project to Int64")
    expectEqual(QVariantValue.double(Double(Int64.min)).intValue, Int64.min, "minimum Int64 double remains representable")
    expectEqual(QVariantValue.double(12.9).intValue, 12, "finite double projection still truncates")

    expectEqual(QVariantValue.float(.nan).intValue, nil, "NaN float cannot project to Int64")
    expectEqual(QVariantValue.float(.infinity).intValue, nil, "infinite float cannot project to Int64")
    expectEqual(QVariantValue.float(-.infinity).intValue, nil, "negative infinite float cannot project to Int64")
    expectEqual(QVariantValue.float(Float(9_223_372_036_854_775_808.0)).intValue, nil, "out-of-range float cannot project to Int64")
    expectEqual(QVariantValue.float(Float(-9_223_372_036_854_775_808.0)).intValue, Int64.min, "minimum Int64 float remains representable")
    expectEqual(QVariantValue.float(-12.9).intValue, -12, "finite float projection still truncates")
    expectEqual(QVariantValue.uLongLong(UInt64.max).intValue, nil, "out-of-range unsigned integer cannot wrap into Int64")
    expectEqual(QVariantValue.uLongLong(UInt64(Int64.max)).intValue, Int64.max, "in-range unsigned integer projects exactly")
}

func testMimeCompression() {
    expectEqual(CopyQMimeCompression.compress("text/plain"), "4", "text/plain compresses to id 4")
    expectEqual(CopyQMimeCompression.compress("text/html"), "5", "text/html compresses to id 5")
    expectEqual(CopyQMimeCompression.compress("image/png"), "7png", "image/png compresses to id 7")
    expectEqual(
        CopyQMimeCompression.compress("application/x-qt-mime-type-name"),
        "9x-qt-mime-type-name",
        "application/ prefix compresses to id 9"
    )
    expectEqual(
        CopyQMimeCompression.compress("application/x-copyq-item-pinned"),
        "3item-pinned",
        "CopyQ prefix compresses to id 3"
    )
    expectEqual(
        CopyQMimeCompression.compress("application/x-copyq-item-notes"),
        "2",
        "item notes compresses to its exact prefix id"
    )
    expectEqual(CopyQMimeCompression.compress("x-custom/thing"), "0x-custom/thing", "unknown prefix keeps a 0 marker")

    for format in [
        "text/plain", "text/html", "text/uri-list", "image/png", "application/xml",
        "application/x-copyq-item-pinned", "application/x-copyq-tags",
        "application/x-copyq-item-notes", "application/x-qt-mime-type-name",
    ] {
        do {
            let round = try CopyQMimeCompression.decompress(CopyQMimeCompression.compress(format))
            expectEqual(round, format, "MIME compression round trips \(format)")
        } catch {
            check(false, "MIME compression round trips \(format)", "\(error)")
        }
    }
}

func testCompressedFlavourDecode() {
    let payload = Data(repeating: 0x41, count: 4096)
    guard let compressed = QtCompression.compressForTesting(payload) else {
        check(false, "zlib compress succeeds")
        return
    }
    do {
        expectEqual(try QtCompression.decompress(compressed), payload, "zlib round trips")
    } catch {
        check(false, "zlib round trips", "\(error)")
    }

    // Build a data map with the compression flag set, as CopyQ would read it.
    var stream = QDataStreamWriter()
    stream.writeInt32(-2)
    stream.writeInt32(1)
    stream.writeQString(CopyQMimeCompression.compress("text/plain"))
    stream.writeBool(true)
    stream.writeQByteArray(compressed)

    do {
        let map = try CopyQItemData.decode(stream.data)
        expectEqual(map.bytes("text/plain"), payload, "compressed flavour is expanded on read")
        let rewritten = CopyQItemData.encode(map)
        let again = try CopyQItemData.decode(rewritten)
        expectEqual(again.bytes("text/plain"), payload, "expanded flavour survives re-encoding")
    } catch {
        check(false, "compressed flavour decodes", "\(error)")
    }
}

func testQVariantNullFraming() {
    let cases: [(String, UInt32, QDataStreamVersion, Bool, UInt32)] = [
        ("null QString", 10, .qt47, true, 10),
        ("null QByteArray", 12, .qt515, true, 12),
        ("null Qt 4 user type", 127, .qt47, true, QMetaTypeID.user),
        ("null Qt 5 user type", QMetaTypeID.user, .qt515, true, QMetaTypeID.user),
        ("invalid Qt 4 variant", 0, .qt47, false, 0),
        ("invalid Qt 5 variant", 0, .qt515, false, 0),
    ]

    for (name, typeID, version, isNull, expectedTypeID) in cases {
        var stream = QDataStreamWriter()
        stream.writeUInt32(typeID)
        stream.writeBool(isNull)
        stream.writeUInt32(0x1234_5678)
        var reader = QDataStreamReader(stream.data)
        do {
            let value = try QVariantReader.read(from: &reader, version: version)
            expectEqual(value, .null(typeId: expectedTypeID), "\(name) consumes no payload")
            expectEqual(try reader.readUInt32(), 0x1234_5678, "\(name) preserves following field")
        } catch {
            check(false, "\(name) preserves following field", "\(error)")
        }
    }

    for version in [QDataStreamVersion.qt47, .qt515] {
        var stream = QDataStreamWriter()
        stream.writeUInt32(2)
        stream.writeQString("null")
        stream.writeUInt32(QMetaTypeID.string)
        stream.writeBool(true)
        stream.writeQString("next")
        stream.writeUInt32(QMetaTypeID.string)
        stream.writeBool(false)
        stream.writeQString("retained")
        var reader = QDataStreamReader(stream.data)
        do {
            let map = try QVariantReader.readMap(from: &reader, version: version)
            expectEqual(map["null"], .null(typeId: QMetaTypeID.string), "null map entry keeps following key aligned")
            expectEqual(map["next"], .string("retained"), "map value after null decodes")
        } catch {
            check(false, "map containing null then value decodes", "\(error)")
        }
    }
}

func testDateTimeTimezone() {
    let zoneID = Data("America/New_York".utf8)
    let cases: [(QDataStreamVersion, Int8, Int32?, Data?)] = [
        (.qt515, 3, nil, zoneID),
        (.qt515, 2, -18_000, nil),
        (.qt515, 1, nil, nil),
        (.qt47, 1, nil, nil),
    ]

    for (version, spec, offset, zone) in cases {
        var stream = QDataStreamWriter()
        stream.writeUInt32(QMetaTypeID.dateTime)
        stream.writeBool(false)
        if version.isAtLeastQt5 {
            stream.writeInt64(2_460_000)
        } else {
            stream.writeUInt32(2_460_000)
        }
        stream.writeUInt32(12_345)
        stream.writeInt8(spec)
        if version.isAtLeastQt5, let offset {
            stream.writeInt32(offset)
        } else if version.isAtLeastQt5, spec == 3 {
            stream.writeQByteArray(zone)
        }
        stream.writeUInt32(0x1234_5678)

        var reader = QDataStreamReader(stream.data)
        do {
            let value = try QVariantReader.read(from: &reader, version: version)
            let julian: Int64 = 2_460_000
            expectEqual(
                value,
                .dateTime(
                    julianDay: julian,
                    milliseconds: 12_345,
                    timeSpec: spec,
                    utcOffsetSeconds: offset,
                    timeZoneID: zone
                ),
                "QDateTime spec \(spec) retains its payload"
            )
            expectEqual(try reader.readUInt32(), 0x1234_5678, "QDateTime spec \(spec) keeps following field aligned")
        } catch {
            check(false, "QDateTime spec \(spec) decodes", "\(error)")
        }
    }
}

func testQVariantNestingLimit() {
    func nested(_ typeID: UInt32, depth: Int) -> Data {
        var stream = QDataStreamWriter()
        for _ in 0..<depth {
            stream.writeUInt32(typeID)
            stream.writeBool(false)
            if typeID == QMetaTypeID.variantList {
                stream.writeUInt32(1)
            } else if typeID == QMetaTypeID.variantMap || typeID == QMetaTypeID.variantHash {
                stream.writeUInt32(1)
                stream.writeQString("child")
            }
        }
        stream.writeUInt32(QMetaTypeID.int)
        stream.writeBool(false)
        stream.writeInt32(7)
        return stream.data
    }

    for typeID in [QMetaTypeID.variant, QMetaTypeID.variantList, QMetaTypeID.variantMap, QMetaTypeID.variantHash] {
        do {
            var validReader = QDataStreamReader(nested(typeID, depth: 8))
            _ = try QVariantReader.read(from: &validReader, version: .qt515)
            check(true, "nested type \(typeID) decodes below limit")
        } catch {
            check(false, "nested type \(typeID) decodes below limit", "\(error)")
        }

        do {
            var deepReader = QDataStreamReader(nested(typeID, depth: 140))
            _ = try QVariantReader.read(from: &deepReader, version: .qt515)
            check(false, "nested type \(typeID) rejects excessive depth")
        } catch let error as QDataStreamError {
            if case .corrupt = error {
                check(true, "nested type \(typeID) rejects excessive depth")
            } else {
                check(false, "nested type \(typeID) rejects excessive depth", "\(error)")
            }
        } catch {
            check(false, "nested type \(typeID) rejects excessive depth", "\(error)")
        }
    }
}

func testMalformedCollectionCounts() {
    let hugeCount = hex("ffffffff")
    do {
        var reader = QDataStreamReader(hugeCount)
        _ = try reader.readQStringList()
        check(false, "QStringList rejects impossible count")
    } catch {
        check(true, "QStringList rejects impossible count")
    }

    do {
        var reader = QDataStreamReader(hugeCount)
        _ = try QVariantReader.readMap(from: &reader, version: .qt515)
        check(false, "QVariantMap rejects impossible count")
    } catch {
        check(true, "QVariantMap rejects impossible count")
    }

    for (name, typeID) in [("QByteArrayList", QMetaTypeID.byteArrayList), ("QVariantList", QMetaTypeID.variantList)] {
        var stream = QDataStreamWriter()
        stream.writeUInt32(typeID)
        stream.writeBool(false)
        stream.writeUInt32(0xffff_ffff)
        do {
            var reader = QDataStreamReader(stream.data)
            _ = try QVariantReader.read(from: &reader, version: .qt515)
            check(false, "\(name) rejects impossible count")
        } catch {
            check(true, "\(name) rejects impossible count")
        }
    }
}

func testQBitArrayOverflow() {
    var stream = QDataStreamWriter()
    stream.writeUInt32(QMetaTypeID.bitArray)
    stream.writeBool(false)
    stream.writeUInt32(0xffff_ffff)
    var reader = QDataStreamReader(stream.data)
    do {
        _ = try QVariantReader.read(from: &reader, version: .qt515)
        check(false, "QBitArray count does not overflow")
    } catch let error as QDataStreamError {
        if case let .truncated(needed, available, _) = error {
            expectEqual(needed, 536_870_912, "QBitArray uses overflow-safe byte count")
            expectEqual(available, 0, "QBitArray rejects bytes beyond remaining stream")
        } else {
            check(false, "QBitArray reports truncated body", "\(error)")
        }
    } catch {
        check(false, "QBitArray reports truncated body", "\(error)")
    }
}

func testFlavourDecompressionFailures() {
    let payload = Data(repeating: 0x41, count: 1024)
    guard let compressed = QtCompression.compressForTesting(payload) else {
        check(false, "oversize fixture compresses")
        return
    }

    do {
        _ = try QtCompression.decompress(compressed, maximumSize: 128)
        check(false, "decompression cap rejects declared oversize")
    } catch {
        check("\(error)".contains("flavour too large"), "decompression cap reports flavour too large")
    }
    do {
        expectEqual(try QtCompression.decompress(compressed, maximumSize: 2048), payload, "caller may raise decompression cap")
    } catch {
        check(false, "caller may raise decompression cap", "\(error)")
    }

    var v2 = QDataStreamWriter()
    v2.writeInt32(-2)
    v2.writeInt32(2)
    v2.writeQString(CopyQMimeCompression.compress("application/x-large"))
    v2.writeBool(true)
    v2.writeQByteArray(compressed)
    v2.writeQString(CopyQMimeCompression.compress("text/plain"))
    v2.writeBool(false)
    v2.writeQByteArray(Data("retained".utf8))

    do {
        let result = try CopyQItemData.decodeReportingFailures(v2.data, maximumDecompressedSize: 128)
        expectEqual(result.map.formats, ["text/plain"], "good v2 flavour survives a decompression failure")
        expectEqual(result.map.bytes("text/plain"), Data("retained".utf8), "good v2 flavour bytes survive")
        expectEqual(result.failures.count, 1, "failed v2 flavour is reported")
        check(result.failures.first?.reason.contains("flavour too large") == true, "v2 failure explains decompression cap")
    } catch {
        check(false, "v2 flavour failure is isolated", "\(error)")
    }

    guard let retainedCompressed = QtCompression.compressForTesting(Data("retained".utf8)) else {
        check(false, "healthy v1 fixture compresses")
        return
    }
    var v1 = QDataStreamWriter()
    v1.writeInt32(2)
    v1.writeQString("application/x-large")
    v1.writeQByteArray(compressed)
    v1.writeQString("text/plain")
    v1.writeQByteArray(retainedCompressed)
    do {
        let result = try CopyQItemData.decodeReportingFailures(v1.data, maximumDecompressedSize: 128)
        expectEqual(result.map.bytes("text/plain"), Data("retained".utf8), "good v1 flavour survives a decompression failure")
        expectEqual(result.failures.count, 1, "failed v1 flavour is reported")
    } catch {
        check(false, "v1 flavour failure is isolated", "\(error)")
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-sync-decompress-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try v2.data.write(to: root.appendingPathComponent("copyq_20260829120939486_copyq.dat"))
        let contents = try CopyQSyncFolder.read(atPath: root.path, maximumDecompressedSize: 128)
        expectEqual(contents.failures.count, 1, "folder report includes failed flavour")
        expectEqual(contents.items.first?.text, "retained", "folder keeps healthy flavour in the same item")
    } catch {
        check(false, "folder isolates decompression failure", "\(error)")
    }
}

// MARK: - Timestamps and on-disk shape

func testTimestamp() {
    guard let date = CopyQSyncItem.parseTimestamp(baseName: "copyq_20260829120939486") else {
        check(false, "timestamp parses")
        return
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    expectEqual(parts.year, 2026, "timestamp year")
    expectEqual(parts.month, 8, "timestamp month")
    expectEqual(parts.day, 29, "timestamp day")
    expectEqual(parts.hour, 12, "timestamp hour")
    expectEqual(parts.minute, 9, "timestamp minute")
    expectEqual(parts.second, 39, "timestamp second")
    expectEqual(
        Int((Double(parts.nanosecond ?? 0) / 1_000_000).rounded()),
        486,
        "timestamp millisecond"
    )

    check(CopyQSyncItem.parseTimestamp(baseName: "copyq_not-a-stamp") == nil, "non stamp base name rejects")
    check(CopyQSyncItem.parseTimestamp(baseName: "copyq_20261329120939486") == nil, "month 13 rejects")
}

func testEffectiveTimestamp() {
    guard let staleStamp = CopyQSyncItem.parseTimestamp(baseName: "copyq_2024120703474115664"),
          let oldStamp = CopyQSyncItem.parseTimestamp(baseName: "copyq_2024120703474115665")
    else {
        check(false, "effective timestamp fixtures parse")
        return
    }

    let recent = Date(timeIntervalSince1970: 1_792_969_788)
    expectEqual(
        CopyQSyncItem.effectiveTimestamp(nameTimestamp: staleStamp, fileModificationDate: recent),
        recent,
        "a recent mtime wins over a stale name stamp"
    )
    expectEqual(
        CopyQSyncItem.effectiveTimestamp(nameTimestamp: oldStamp, fileModificationDate: oldStamp),
        oldStamp,
        "matching old name stamp and mtime keep the old date"
    )
    expectEqual(
        CopyQSyncItem.effectiveTimestamp(nameTimestamp: nil, fileModificationDate: recent),
        recent,
        "a missing name stamp falls back to the mtime"
    )
    expectEqual(
        CopyQSyncItem.effectiveTimestamp(nameTimestamp: staleStamp, fileModificationDate: nil),
        staleStamp,
        "a missing mtime falls back to the name stamp"
    )
    check(
        CopyQSyncItem.effectiveTimestamp(nameTimestamp: nil, fileModificationDate: nil) == nil,
        "no candidate means no timestamp"
    )

    // Reading a folder applies the same resolution to the item it returns.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-sync-timestamps-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("copyq_2024120703474115664.txt")
        try Data("stale stamp, recent file".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: file.path)

        let contents = try CopyQSyncFolder.read(atPath: root.path)
        expectEqual(contents.items.count, 1, "the group reads back")
        if let resolved = contents.items.first?.timestamp {
            expectEqual(
                Int(resolved.timeIntervalSince1970),
                Int(recent.timeIntervalSince1970),
                "a folder read applies the later timestamp"
            )
        } else {
            check(false, "the read item has a timestamp")
        }
        expectEqual(contents.items.first?.fileModificationDate, recent, "the item keeps its file modification time")
    } catch {
        check(false, "folder read resolves the later timestamp", "\(error)")
    }
}

func makeRichItem() -> CopyQSyncItem {
    var data = CopyQDataMap()
    data.set(CopyQFormat.text, Data("hello".utf8))
    data.set(CopyQFormat.itemNotes, Data("a note".utf8))
    data.set(CopyQFormat.itemPinned, nil)
    data.set("application/x-qt-mime-type-name", Data("dummy".utf8))
    return CopyQSyncItem(baseName: "copyq_20260829120939486", data: data)
}

func testOnDiskShape() {
    let item = makeRichItem()
    let files = item.onDiskFiles()
    expectEqual(
        Set(files.keys),
        Set([".txt", "_note.txt", CopyQFormat.dataFileSuffix]),
        "rich item writes text, note and container"
    )
    expectEqual(files[".txt"], Data("hello".utf8), "text file bytes")
    expectEqual(files["_note.txt"], Data("a note".utf8), "note file bytes")

    let container = files[CopyQFormat.dataFileSuffix]!
    do {
        let decoded = try CopyQItemData.decode(container)
        expectEqual(
            decoded.formats,
            ["application/x-copyq-item-pinned", "application/x-qt-mime-type-name"],
            "container holds only the flavours without a file"
        )
    } catch {
        check(false, "container decodes", "\(error)")
    }

    // An item with only known flavours must not create a container.
    var plain = CopyQSyncItem(baseName: "copyq_20260829120939487")
    plain.data.set(CopyQFormat.text, Data("plain".utf8))
    expectEqual(Set(plain.onDiskFiles().keys), Set([".txt"]), "plain item writes only its text file")

    // A null value on a known flavour still writes an empty file, as CopyQ does.
    var nullText = CopyQSyncItem(baseName: "copyq_20260829120939488")
    nullText.data.set(CopyQFormat.text, nil)
    expectEqual(nullText.onDiskFiles()[".txt"], Data(), "null text flavour writes an empty file")

    var xmlItem = CopyQSyncItem(baseName: "copyq_20260829120939490")
    xmlItem.data.set("application/xml", Data("application".utf8))
    xmlItem.data.set("text/xml", Data("text".utf8))
    let xmlFiles = xmlItem.onDiskFiles()
    expectEqual(xmlFiles[".xml"], Data("application".utf8), ".xml stores application/xml")
    if let container = xmlFiles[CopyQFormat.dataFileSuffix],
       let decoded = try? CopyQItemData.decode(container) {
        expectEqual(decoded.bytes("text/xml"), Data("text".utf8), "text/xml stays in the container")
    } else {
        check(false, "text/xml is preserved in the container")
    }

    // Plugin bookkeeping formats are not written.
    var internalOnly = CopyQSyncItem(baseName: "copyq_20260829120939489")
    internalOnly.data.set("application/x-copyq-itemsync-basename", Data("x".utf8))
    expectEqual(Set(internalOnly.onDiskFiles().keys), Set([CopyQFormat.dataFileSuffix]), "internal format is not written as a flavour")
    if let container = internalOnly.onDiskFiles()[CopyQFormat.dataFileSuffix],
       let decoded = try? CopyQItemData.decode(container) {
        expectEqual(decoded.count, 0, "container holds no internal formats")
    } else {
        check(false, "internal format container decodes")
    }
}

// MARK: - Folder read/write

func testXMLFlavourRoundTrip() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-sync-xml-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    var item = CopyQSyncItem(baseName: "copyq_20260829120939490")
    item.data.set("application/xml", Data("application".utf8))
    item.data.set("text/xml", Data("text".utf8))
    do {
        _ = try CopyQSyncFolder.write(item, into: root.path)
        let contents = try CopyQSyncFolder.read(atPath: root.path)
        expectEqual(contents.items.count, 1, "XML formats read as one item")
        expectEqual(contents.items.first?.data.bytes("application/xml"), Data("application".utf8), "application/xml keeps its value")
        expectEqual(contents.items.first?.data.bytes("text/xml"), Data("text".utf8), "text/xml keeps its value")
    } catch {
        check(false, "XML formats survive folder round trip", "\(error)")
    }
}

func testFolderRoundTrip() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-sync-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let item = makeRichItem()
    do {
        let written = try CopyQSyncFolder.write(item, into: root.path)
        expectEqual(written, ["copyq_20260829120939486.txt", "copyq_20260829120939486_copyq.dat", "copyq_20260829120939486_note.txt"], "files written for a rich item")

        // A non-flavour file must be ignored, not reported as a failure.
        try Data().write(to: root.appendingPathComponent("random.md"))

        let contents = try CopyQSyncFolder.read(atPath: root.path)
        expectEqual(contents.items.count, 1, "one item read back")
        expectEqual(contents.failures.count, 0, "no failures for a clean folder")
        expectEqual(contents.ignoredFiles.count, 1, "one non-flavour file ignored")

        let restored = contents.items[0]
        expectEqual(restored.text, "hello", "text read back")
        expectEqual(restored.notes, "a note", "note read back")
        check(restored.isPinned, "pin read back")
        check(restored.timestamp != nil, "timestamp read back")
        expectEqual(restored.onDiskFiles(), item.onDiskFiles(), "re-serialised item matches on disk")
    } catch {
        check(false, "folder round trip", "\(error)")
    }
}

func testFolderSymlinkContainment() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-sync-links-\(UUID().uuidString)")
    let external = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-sync-outside-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: external)
    }

    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("clipboard.txt")
        try Data("secret".utf8).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("copyq_20260829120939486.txt").path,
            withDestinationPath: externalFile.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("outside-directory").path,
            withDestinationPath: external.path
        )

        let contents = try CopyQSyncFolder.read(atPath: root.path)
        expectEqual(contents.skippedCount, 2, "external symlink file and directory are reported as skipped")
        expectEqual(contents.fileCount, 0, "external symlink targets are not counted as readable files")
        expectEqual(contents.items.count, 0, "external symlink content is not imported")
    } catch {
        check(false, "external symlink entries are safely skipped", "\(error)")
    }
}

func testFolderWritePathContainment() {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-sync-write-\(UUID().uuidString)")
    let root = parent.appendingPathComponent("root")
    let external = parent.appendingPathComponent("outside")
    defer { try? FileManager.default.removeItem(at: parent) }

    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        var escaping = CopyQSyncItem(baseName: "../victim")
        escaping.data.set(CopyQFormat.text, Data("unsafe".utf8))
        do {
            _ = try CopyQSyncFolder.write(escaping, into: root.path)
            check(false, "writer rejects parent traversal")
        } catch {
            check(true, "writer rejects parent traversal")
        }
        check(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("victim.txt").path), "parent traversal creates no outside file")

        var nested = CopyQSyncItem(baseName: "safe/nested")
        nested.data.set(CopyQFormat.text, Data("safe".utf8))
        let written = try CopyQSyncFolder.write(nested, into: root.path)
        expectEqual(written, ["safe/nested.txt"], "writer preserves safe nested paths")
        expectEqual(
            try Data(contentsOf: root.appendingPathComponent("safe/nested.txt")),
            Data("safe".utf8),
            "safe nested file is written inside root"
        )

        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("escape").path,
            withDestinationPath: external.path
        )
        var linked = CopyQSyncItem(baseName: "escape/child")
        linked.data.set(CopyQFormat.text, Data("unsafe".utf8))
        do {
            _ = try CopyQSyncFolder.write(linked, into: root.path)
            check(false, "writer rejects external symlink directory")
        } catch {
            check(true, "writer rejects external symlink directory")
        }
        check(!FileManager.default.fileExists(atPath: external.appendingPathComponent("child.txt").path), "external symlink target is not written")
    } catch {
        check(false, "writer confines output paths", "\(error)")
    }
}

func testFolderReportsFailures() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-sync-fail-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x00, 0x00, 0x00, 0x01]).write(
            to: root.appendingPathComponent("copyq_20260829120939486_copyq.dat")
        )
        let contents = try CopyQSyncFolder.read(atPath: root.path)
        expectEqual(contents.failures.count, 1, "corrupt container is reported as a failure")
        check(contents.items.count == 1, "the item group is still listed")
    } catch {
        check(false, "folder failure reporting", "\(error)")
    }
}

// MARK: - Archive

/// Writes a `QVariant` header and body in the Qt 4 stream layout.
func writeVariant(_ stream: inout QDataStreamWriter, typeID: UInt32, isNull: Bool = false, body: (inout QDataStreamWriter) -> Void) {
    stream.writeUInt32(typeID)
    stream.writeBool(isNull)
    body(&stream)
}

func makeV4Archive(tabName: String, items: [CopyQSyncItem]) -> Data {
    makeV4Archive(tabName: tabName, itemList: CopyQArchive.encodeItemListForTesting(items))
}

func makeV4Archive(tabName: String, itemList: Data) -> Data {
    var stream = QDataStreamWriter()
    stream.writeQByteArray(Data(Format_v4.utf8))
    stream.writeUInt32(1)
    stream.writeQString("tabs")
    writeVariant(&stream, typeID: 11) { $0.writeQStringList([tabName]) }
    stream.writeUInt32(2)
    stream.writeQString("name")
    writeVariant(&stream, typeID: 10) { $0.writeQString(tabName) }
    stream.writeQString("data")
    writeVariant(&stream, typeID: 12) { $0.writeQByteArray(itemList) }
    return stream.data
}

func makeV2Container(_ entries: [(format: String, compressed: Bool, bytes: Data?)]) -> Data {
    var stream = QDataStreamWriter()
    stream.writeInt32(-2)
    stream.writeInt32(Int32(entries.count))
    for entry in entries {
        stream.writeQString(CopyQMimeCompression.compress(entry.format))
        stream.writeBool(entry.compressed)
        stream.writeQByteArray(entry.bytes)
    }
    return stream.data
}

let Format_v4 = "CopyQ v4"

func makeV5Archive(tabs: [String]?, itemTexts: [String]) -> Data {
    var settings: [(format: String, compressed: Bool, bytes: Data?)] = []
    if let tabs {
        var value = QDataStreamWriter()
        value.writeUInt32(QMetaTypeID.stringList)
        value.writeBool(false)
        value.writeQStringList(tabs)
        settings.append(("tabs", false, value.data))
    }

    var stream = QDataStreamWriter()
    stream.writeQByteArray(Data(CopyQArchive.Format.v5.rawValue.utf8))
    stream.writeRawData(makeV2Container(settings))
    for text in itemTexts {
        var data = CopyQDataMap()
        data.set("text/plain", Data(text.utf8))
        let itemList = CopyQArchive.encodeItemListForTesting([CopyQSyncItem(data: data)])
        stream.writeRawData(makeV2Container([("data", false, itemList)]))
    }
    return stream.data
}

func testArchiveItemCountWithoutEntries() {
    var stream = QDataStreamWriter()
    stream.writeInt32(1_000_000)
    do {
        _ = try CopyQArchive.parseItemList(stream.data)
        check(false, "archive rejects item count with no entries")
    } catch {
        check(true, "archive rejects item count with no entries")
    }
}

func testArchiveV4() {
    let item = makeRichItem()
    let archiveData = makeV4Archive(tabName: "Test", items: [item])
    do {
        let archive = try CopyQArchive.read(archiveData)
        expectEqual(archive.format, .v4, "archive reports v4")
        expectEqual(archive.tabNames, ["Test"], "archive tab names")
        let items = archive.tabItems["Test"] ?? []
        expectEqual(items.count, 1, "archive item count")
        expectEqual(items[0].text, "hello", "archive item text")
        expectEqual(items[0].notes, "a note", "archive item note")
        check(items[0].isPinned, "archive item pin")
        expectEqual(archive.failures.count, 0, "clean archive has no flavour failures")
    } catch {
        check(false, "archive v4 parses", "\(error)")
    }
}

func testV5FallbackTabs() {
    do {
        let archive = try CopyQArchive.read(makeV5Archive(tabs: nil, itemTexts: ["unnamed"]))
        expectEqual(archive.tabNames, ["tab-0"], "v5 archive synthesizes and lists a missing tab name")
        expectEqual(archive.items.first?.text, "unnamed", "items includes unnamed v5 tab data")
    } catch {
        check(false, "v5 archive with no tab names is retained", "\(error)")
    }

    do {
        let archive = try CopyQArchive.read(
            makeV5Archive(tabs: ["tab-1"], itemTexts: ["first", "second"])
        )
        expectEqual(archive.tabNames, ["tab-1", "tab-1-1"], "v5 fallback name avoids collision with stored names")
        expectEqual(archive.items.map(\.text), ["first", "second"], "all named and fallback v5 tabs contribute items")
    } catch {
        check(false, "v5 archive with fewer names than blobs is retained", "\(error)")
    }
}

func testArchiveFailureIsolation() {
    guard let compressed = QtCompression.compressForTesting(Data(repeating: 0x41, count: 1024)) else {
        check(false, "archive failure fixture compresses")
        return
    }

    let brokenItemData = makeV2Container([
        ("application/x-broken", true, compressed),
        ("text/plain", false, Data("v4 retained".utf8)),
    ])
    var v4Items = QDataStreamWriter()
    v4Items.writeInt32(1)
    v4Items.writeRawData(brokenItemData)
    do {
        let archive = try CopyQArchive.read(
            makeV4Archive(tabName: "Broken", itemList: v4Items.data),
            maximumDecompressedSize: 128
        )
        expectEqual(archive.items.first?.text, "v4 retained", "v4 archive retains healthy item flavour")
        expectEqual(archive.failures.count, 1, "v4 archive reports compressed flavour failure")
        expectEqual(archive.failures.first?.location, "tab Broken, item 1", "v4 failure identifies item location")
    } catch {
        check(false, "v4 archive isolates compressed flavour failure", "\(error)")
    }

    var tabsVariant = QDataStreamWriter()
    tabsVariant.writeUInt32(QMetaTypeID.stringList)
    tabsVariant.writeBool(false)
    tabsVariant.writeQStringList(["V5"])

    var zoneVariant = QDataStreamWriter()
    zoneVariant.writeUInt32(QMetaTypeID.dateTime)
    zoneVariant.writeBool(false)
    zoneVariant.writeInt64(2_460_000)
    zoneVariant.writeUInt32(12_345)
    zoneVariant.writeInt8(3)
    zoneVariant.writeQByteArray(Data("Europe/Paris".utf8))

    var offsetVariant = QDataStreamWriter()
    offsetVariant.writeUInt32(QMetaTypeID.dateTime)
    offsetVariant.writeBool(false)
    offsetVariant.writeInt64(2_460_000)
    offsetVariant.writeUInt32(12_345)
    offsetVariant.writeInt8(2)
    offsetVariant.writeInt32(-18_000)

    var healthyItemData = CopyQDataMap()
    healthyItemData.set("text/plain", Data("v5 retained".utf8))
    let v5Items = CopyQArchive.encodeItemListForTesting([CopyQSyncItem(data: healthyItemData)])
    let topBlob = makeV2Container([
        ("application/x-settings-broken", true, compressed),
        ("tabs", false, tabsVariant.data),
        ("timezone", false, zoneVariant.data),
        ("offset", false, offsetVariant.data),
    ])
    let tabBlob = makeV2Container([
        ("application/x-tab-broken", true, compressed),
        ("data", false, v5Items),
    ])
    var v5Archive = QDataStreamWriter()
    v5Archive.writeQByteArray(Data(CopyQArchive.Format.v5.rawValue.utf8))
    v5Archive.writeRawData(topBlob)
    v5Archive.writeRawData(tabBlob)
    do {
        let archive = try CopyQArchive.read(v5Archive.data, maximumDecompressedSize: 128)
        expectEqual(archive.tabNames, ["V5"], "v5 settings survive a compressed flavour failure")
        expectEqual(archive.items.first?.text, "v5 retained", "v5 tab keeps healthy item data")
        expectEqual(
            archive.settings["timezone"],
            .dateTime(
                julianDay: 2_460_000,
                milliseconds: 12_345,
                timeSpec: 3,
                utcOffsetSeconds: nil,
                timeZoneID: Data("Europe/Paris".utf8)
            ),
            "v5 archive retains timezone-aware setting"
        )
        expectEqual(
            archive.settings["offset"],
            .dateTime(
                julianDay: 2_460_000,
                milliseconds: 12_345,
                timeSpec: 2,
                utcOffsetSeconds: -18_000,
                timeZoneID: nil
            ),
            "v5 archive retains UTC offset setting"
        )
        expectEqual(archive.failures.count, 2, "v5 settings and tab failures are both reported")
        expectEqual(Set(archive.failures.map(\.location)), Set(["settings", "tab V5"]), "v5 failures identify their locations")
    } catch {
        check(false, "v5 archive isolates settings and tab failures", "\(error)")
    }
}

func testArchiveRealCorpus(_ path: String) {
    do {
        let archive = try CopyQArchive.read(atPath: path)
        let records = try archiveFlavourRecords(try Data(contentsOf: URL(fileURLWithPath: path)))
        let compressed = records.filter(\.compressed)
        print("info parsed archive \(path): format \(archive.format.rawValue), \(archive.settings.count) top level key(s), \(archive.items.count) item(s), \(records.count) flavour(s), \(compressed.count) compressed")
        check(archive.failures.isEmpty, "real archive flavours all decode")
        check(true, "real archive parses")
    } catch {
        check(false, "real archive parses", "\(error)")
    }
}

// MARK: - Corpus

func testCorpus(_ directory: String) {
    let root = URL(fileURLWithPath: directory)
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    var files: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
        guard url.lastPathComponent.hasSuffix(CopyQFormat.dataFileSuffix) else { continue }
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files.append(url)
        }
    }
    files.sort { $0.path < $1.path }
    print("info corpus: \(files.count) \(CopyQFormat.dataFileSuffix) file(s) under \(directory)")
    for file in files {
        do {
            let original = try Data(contentsOf: file)
            let map = try CopyQItemData.decode(original)
            let rewritten = CopyQItemData.encode(map)
            check(rewritten == original, "corpus round trip \(file.lastPathComponent)")
        } catch {
            check(false, "corpus round trip \(file.lastPathComponent)", "\(error)")
        }
    }
}

// MARK: - Archive writer

func makeArchiveDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("copyq-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct ArchiveFlavourRecord {
    var format: String
    var compressed: Bool
    var storedBytes: Int
}

/// Reads the per-flavour compression flags straight from a v4 archive.
func archiveFlavourRecords(_ data: Data) throws -> [ArchiveFlavourRecord] {
    var reader = QDataStreamReader(data)
    _ = try reader.readQByteArray()
    _ = try QVariantReader.readMap(from: &reader, version: .qt47)
    var records: [ArchiveFlavourRecord] = []
    while !reader.isAtEnd {
        let tab = try QVariantReader.readMap(from: &reader, version: .qt47)
        guard let dataValue = tab["data"],
              case let .byteArray(payload) = dataValue,
              let payload
        else { continue }
        var listReader = QDataStreamReader(payload)
        let count = try listReader.readInt32()
        for _ in 0..<max(0, Int(count)) {
            let marker = try listReader.readInt32()
            guard marker == -2 else {
                throw QDataStreamError.corrupt("unexpected item container marker \(marker)")
            }
            let flavourCount = try listReader.readInt32()
            for _ in 0..<max(0, Int(flavourCount)) {
                let mime = try listReader.readQString()
                let format = try CopyQMimeCompression.decompress(mime) ?? ""
                let compressed = try listReader.readBool()
                let bytes = try listReader.readQByteArray()
                records.append(ArchiveFlavourRecord(
                    format: format,
                    compressed: compressed,
                    storedBytes: bytes?.count ?? -1
                ))
            }
        }
    }
    return records
}

func testArchiveWriterStructure() {
    guard let directory = try? makeArchiveDirectory() else {
        check(false, "writer fixture directory")
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("backup.cpq")

    var firstItem = CopyQDataMap()
    firstItem.set(CopyQFormat.text, Data("first".utf8))
    firstItem.set(CopyQFormat.itemPinned, nil)
    var secondItem = CopyQDataMap()
    secondItem.set(CopyQFormat.html, Data("<b>second</b>".utf8))

    do {
        let writer = try CopyQArchiveWriter(
            destinationURL: url,
            tabs: ["Clipboard", "Empty"]
        )
        try writer.beginTab("Clipboard")
        try writer.append(CopyQSyncItem(data: firstItem))
        try writer.append(CopyQSyncItem(data: secondItem))
        try writer.finishTab()
        try writer.beginTab("Empty")
        try writer.finishTab()
        try writer.finish()
    } catch {
        check(false, "writer writes an archive", "\(error)")
        return
    }

    // The exact byte layout CopyQ's exportDataV4() produces:
    //   QByteArray "CopyQ v4", the export QVariantMap (its one key, "tabs", a
    //   QStringList), then one QVariantMap per tab whose keys Qt sorts as
    //   "data" before "name" (mainwindow.cpp:2293-2311, 2346-2388).
    var expected = QDataStreamWriter()
    expected.writeQByteArray(Data(Format_v4.utf8))
    expected.writeUInt32(1)
    expected.writeQString("tabs")
    writeVariant(&expected, typeID: 11) { $0.writeQStringList(["Clipboard", "Empty"]) }

    var itemList = QDataStreamWriter()
    itemList.writeInt32(2)
    CopyQItemData.encode(
        firstItem,
        into: &itemList,
        compressionThreshold: CopyQItemData.itemDataThreshold
    )
    CopyQItemData.encode(
        secondItem,
        into: &itemList,
        compressionThreshold: CopyQItemData.itemDataThreshold
    )

    expected.writeUInt32(2)
    expected.writeQString("data")
    writeVariant(&expected, typeID: 12) { $0.writeQByteArray(itemList.data) }
    expected.writeQString("name")
    writeVariant(&expected, typeID: 10) { $0.writeQString("Clipboard") }

    var emptyList = QDataStreamWriter()
    emptyList.writeInt32(0)
    expected.writeUInt32(2)
    expected.writeQString("data")
    writeVariant(&expected, typeID: 12) { $0.writeQByteArray(emptyList.data) }
    expected.writeQString("name")
    writeVariant(&expected, typeID: 10) { $0.writeQString("Empty") }

    do {
        let written = try Data(contentsOf: url)
        expectEqual(toHex(written), toHex(expected.data), "writer bytes match CopyQ's v4 field order")

        let archive = try CopyQArchive.read(written)
        expectEqual(archive.format, .v4, "written archive is v4")
        expectEqual(archive.tabNames, ["Clipboard", "Empty"], "written archive tab names")
        expectEqual(archive.tabItems["Clipboard"]?.count, 2, "written archive item count")
        expectEqual(archive.tabItems["Clipboard"]?.first?.data, firstItem, "written archive item data")
        expectEqual(archive.tabItems["Empty"]?.count, 0, "written archive keeps an empty tab")
        expectEqual(archive.failures.count, 0, "written archive has no flavour failures")
    } catch {
        check(false, "written archive reads back", "\(error)")
    }

    // No temporary file may survive a finished write.
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
        .filter { $0.hasSuffix(".partial") } ?? []
    expectEqual(leftovers, [], "finished write leaves no partial file")
}

func testArchiveWriterRoundTrip() {
    guard let directory = try? makeArchiveDirectory() else {
        check(false, "writer round trip fixture")
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("round-trip.cpq")

    let createdAt = Date(timeIntervalSince1970: 1_792_981_216.1234567)
    var data = CopyQDataMap()
    data.set(CopyQFormat.text, Data("round trip".utf8))
    data.set(CopyQFormat.html, Data("<p>round trip</p>".utf8))
    data.set("image/png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    data.set("public.file-url", Data("file:///tmp/report.pdf".utf8))
    data.set("application/x-custom-meta", Data([0x00, 0x01, 0xFE, 0xFF]))
    data.set(CopyQFormat.itemNotes, Data("keep me".utf8))
    data.set(CopyQFormat.itemPinned, nil)
    guard let createdAtBytes = CopyQFormat.encodeCreatedAt(createdAt) else {
        check(false, "created-at encodes")
        return
    }
    data.set(CopyQFormat.macItemCreatedAt, createdAtBytes)

    do {
        let writer = try CopyQArchiveWriter(destinationURL: url, tabs: ["Clipboard"])
        try writer.beginTab("Clipboard")
        try writer.append(CopyQSyncItem(data: data))
        try writer.finishTab()
        try writer.finish()

        let archive = try CopyQArchive.read(atPath: url.path)
        guard let item = archive.tabItems["Clipboard"]?.first else {
            check(false, "round trip item is read back")
            return
        }
        var expected = data
        expected.remove(CopyQFormat.macItemCreatedAt)
        expectEqual(item.data, expected, "every flavour round trips byte for byte")
        expectEqual(item.timestamp, createdAt, "creation time round trips exactly")
        check(item.isPinned, "pinned marker round trips")
        expectEqual(item.notes, "keep me", "note round trips")
        check(item.baseName == nil, "archive item carries no sync stem")
    } catch {
        check(false, "archive writer round trip", "\(error)")
    }
}

func testArchiveWriterCompressesLargeFlavours() {
    guard let directory = try? makeArchiveDirectory() else {
        check(false, "writer compression fixture")
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("compressed.cpq")

    let large = Data(String(repeating: "copyq compression round trip\n", count: 4096).utf8)
    var data = CopyQDataMap()
    data.set(CopyQFormat.text, large)
    data.set("application/x-small", Data(repeating: 0x42, count: 16))
    data.set(
        "application/x-at-threshold",
        Data(repeating: 0x43, count: CopyQItemData.itemDataThreshold)
    )
    data.set(CopyQFormat.itemPinned, nil)

    do {
        let writer = try CopyQArchiveWriter(destinationURL: url, tabs: ["Clipboard"])
        try writer.beginTab("Clipboard")
        try writer.append(CopyQSyncItem(data: data))
        try writer.finishTab()
        try writer.finish()

        let bytes = try Data(contentsOf: url)
        let archive = try CopyQArchive.read(bytes)
        expectEqual(archive.failures, [], "compressed archive has no flavour failures")
        guard let item = archive.items.first else {
            check(false, "compressed archive item is read back")
            return
        }
        expectEqual(item.data, data, "compressed flavours round trip byte for byte")

        let records = try archiveFlavourRecords(bytes)
        let text = records.first { $0.format == CopyQFormat.text }
        check(text?.compressed == true, "flavour above the threshold is stored compressed")
        check(
            (text?.storedBytes ?? large.count) < large.count / 4,
            "compressed flavour keeps only its qCompress payload",
            "\(text?.storedBytes ?? -1) stored bytes for \(large.count)"
        )
        let atThreshold = records.first { $0.format == "application/x-at-threshold" }
        check(atThreshold?.compressed == false, "flavour at the threshold is stored raw")
        check(
            atThreshold?.storedBytes == CopyQItemData.itemDataThreshold,
            "threshold flavour keeps its raw bytes"
        )
        let small = records.first { $0.format == "application/x-small" }
        check(small?.compressed == false, "small flavour is stored raw")
        check(
            bytes.count < large.count / 2,
            "compressible large payload produces a much smaller archive",
            "\(bytes.count) bytes for \(large.count) payload bytes"
        )
    } catch {
        check(false, "archive writer compresses large flavours", "\(error)")
    }
}

func testArchiveWriterReplacesAndAbandons() {
    guard let directory = try? makeArchiveDirectory() else {
        check(false, "writer replacement fixture")
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("existing.cpq")
    do {
        try Data("previous backup".utf8).write(to: url)

        // An abandoned export must not disturb the file it would replace.
        let abandoned = try CopyQArchiveWriter(destinationURL: url, tabs: ["Clipboard"])
        try abandoned.beginTab("Clipboard")
        var partial = CopyQDataMap()
        partial.set(CopyQFormat.text, Data("never written".utf8))
        try abandoned.append(CopyQSyncItem(data: partial))
        abandoned.cancel()
        expectEqual(try String(contentsOf: url, encoding: .utf8), "previous backup", "cancelled write leaves the destination untouched")
        let partials = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".partial") } ?? []
        expectEqual(partials, [], "cancelled write removes its partial file")

        // A finished export replaces an existing archive atomically.
        let writer = try CopyQArchiveWriter(destinationURL: url, tabs: ["Clipboard"])
        try writer.beginTab("Clipboard")
        var replacement = CopyQDataMap()
        replacement.set(CopyQFormat.text, Data("replacement".utf8))
        try writer.append(CopyQSyncItem(data: replacement))
        try writer.finishTab()
        try writer.finish()

        let archive = try CopyQArchive.read(atPath: url.path)
        expectEqual(archive.items.first?.text, "replacement", "finished write replaces the existing archive")
    } catch {
        check(false, "archive writer replaces an existing file", "\(error)")
    }
}

func testArchiveWriterRejectsNestedTabs() {
    guard let directory = try? makeArchiveDirectory() else {
        check(false, "writer nesting fixture")
        return
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("nested.cpq")
    do {
        let writer = try CopyQArchiveWriter(destinationURL: url, tabs: ["One"])
        try writer.beginTab("One")
        do {
            try writer.beginTab("Two")
            check(false, "writer rejects a second open tab")
        } catch {
            check(true, "writer rejects a second open tab")
        }
        writer.cancel()
    } catch {
        check(false, "writer nesting error", "\(error)")
    }
}

func testArchiveWriteErrorLocalizedDescription() {
    let error = CopyQArchiveWriteError.tabTooLarge(
        tab: "Large",
        items: 3,
        bytes: Int(Int32.max) + 1
    )
    check(error.localizedDescription == error.description, "writer errors reach the user with their description")
}

struct RawV4Reader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else {
            throw QDataStreamError.truncated(needed: 1, available: 0, offset: offset)
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let b0 = UInt32(try readUInt8())
        let b1 = UInt32(try readUInt8())
        let b2 = UInt32(try readUInt8())
        let b3 = UInt32(try readUInt8())
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readData(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= bytes.count else {
            throw QDataStreamError.truncated(needed: count, available: bytes.count - offset, offset: offset)
        }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func readQByteArray() throws -> Data? {
        let length = try readUInt32()
        if length == 0xFFFF_FFFF { return nil }
        return try readData(Int(length))
    }

    mutating func readQString() throws -> String? {
        let length = try readUInt32()
        if length == 0xFFFF_FFFF { return nil }
        let raw = try readData(Int(length))
        return String(data: raw, encoding: .utf16BigEndian)
    }

    mutating func skipQVariantPayload(
        _ typeID: UInt32,
        isNull: Bool,
        typeIDs: inout Set<UInt32>
    ) throws -> UInt32? {
        typeIDs.insert(typeID)
        if isNull { return nil }

        let mappedTypeID = QVariantReader.remapQt4TypeID(typeID)
        switch mappedTypeID {
        case QMetaTypeID.bool, QMetaTypeID.charType, QMetaTypeID.sChar, QMetaTypeID.uChar:
            _ = try readData(1)
        case QMetaTypeID.char, QMetaTypeID.short, QMetaTypeID.uShort:
            _ = try readData(2)
        case QMetaTypeID.int, QMetaTypeID.uint, QMetaTypeID.time, QMetaTypeID.float:
            _ = try readData(4)
        case QMetaTypeID.longLong, QMetaTypeID.uLongLong, QMetaTypeID.double,
             QMetaTypeID.long, QMetaTypeID.uLong:
            _ = try readData(8)
        case QMetaTypeID.variantMap, QMetaTypeID.variantHash:
            let count = Int(try readUInt32())
            for _ in 0..<count {
                _ = try readQString()
                let valueType = try readUInt32()
                let valueNull = try readBool()
                if let unsupported = try skipQVariantPayload(valueType, isNull: valueNull, typeIDs: &typeIDs) {
                    return unsupported
                }
            }
        case QMetaTypeID.variantList:
            let count = Int(try readUInt32())
            for _ in 0..<count {
                let valueType = try readUInt32()
                let valueNull = try readBool()
                if let unsupported = try skipQVariantPayload(valueType, isNull: valueNull, typeIDs: &typeIDs) {
                    return unsupported
                }
            }
        case QMetaTypeID.string, QMetaTypeID.url, QMetaTypeID.locale:
            _ = try readQString()
        case QMetaTypeID.stringList:
            let count = Int(try readUInt32())
            for _ in 0..<count { _ = try readQString() }
        case QMetaTypeID.byteArray:
            _ = try readQByteArray()
        case QMetaTypeID.byteArrayList:
            let count = Int(try readUInt32())
            for _ in 0..<count { _ = try readQByteArray() }
        case QMetaTypeID.bitArray:
            let bitCount = Int(try readUInt32())
            _ = try readData((bitCount + 7) / 8)
        case QMetaTypeID.date:
            _ = try readData(4)
        case QMetaTypeID.dateTime:
            _ = try readData(4)
            _ = try readData(4)
            _ = try readUInt8()
        case QMetaTypeID.rect, QMetaTypeID.line:
            _ = try readData(16)
        case QMetaTypeID.rectF, QMetaTypeID.lineF:
            _ = try readData(32)
        case QMetaTypeID.size, QMetaTypeID.point:
            _ = try readData(8)
        case QMetaTypeID.sizeF, QMetaTypeID.pointF:
            _ = try readData(16)
        case QMetaTypeID.regExp:
            _ = try readQString()
            _ = try readData(3)
        case QMetaTypeID.regularExpression:
            _ = try readQString()
            _ = try readData(4)
        case QMetaTypeID.variant:
            let innerType = try readUInt32()
            let innerNull = try readBool()
            if let unsupported = try skipQVariantPayload(innerType, isNull: innerNull, typeIDs: &typeIDs) {
                return unsupported
            }
        default:
            return mappedTypeID
        }
        return nil
    }
}

struct RawArchiveFraming {
    var magic: String
    var topLevelKeys: [(String, UInt32, Bool)]
    var tabKeyOrders: [[(String, UInt32, Bool)]]
    var itemListCounts: [Int32]
    var itemContainers: [(Int32, Int32)]
    var typeIDsSeen: Set<UInt32>
    var unsupportedTypeID: UInt32?
}

func inspectV4Framing(_ data: Data) throws -> RawArchiveFraming {
    var reader = RawV4Reader(data)
    guard let magicData = try reader.readQByteArray(),
          let magic = String(data: magicData, encoding: .utf8)
    else {
        throw QDataStreamError.corrupt("missing archive magic")
    }

    var typeIDsSeen = Set<UInt32>()
    var unsupportedTypeID: UInt32?
    let exportCount = Int(try reader.readUInt32())
    var topLevelKeys: [(String, UInt32, Bool)] = []
    for _ in 0..<exportCount {
        let key = try reader.readQString() ?? ""
        let typeID = try reader.readUInt32()
        let isNull = try reader.readBool()
        topLevelKeys.append((key, typeID, isNull))
        if let unsupported = try reader.skipQVariantPayload(typeID, isNull: isNull, typeIDs: &typeIDsSeen) {
            unsupportedTypeID = unsupported
            break
        }
    }

    var tabKeyOrders: [[(String, UInt32, Bool)]] = []
    var itemListCounts: [Int32] = []
    var itemContainers: [(Int32, Int32)] = []
    while !reader.isAtEnd, unsupportedTypeID == nil {
        let tabCount = Int(try reader.readUInt32())
        var keys: [(String, UInt32, Bool)] = []
        for _ in 0..<tabCount {
            let key = try reader.readQString() ?? ""
            let typeID = try reader.readUInt32()
            let isNull = try reader.readBool()
            keys.append((key, typeID, isNull))
            typeIDsSeen.insert(typeID)
            let mappedTypeID = QVariantReader.remapQt4TypeID(typeID)
            if mappedTypeID == QMetaTypeID.byteArray, !isNull, key == "data" {
                let payload = try reader.readQByteArray()
                guard let payload else { continue }
                var itemReader = RawV4Reader(payload)
                let itemCount = try itemReader.readInt32()
                itemListCounts.append(itemCount)
                for _ in 0..<max(0, Int(itemCount)) {
                    let marker = try itemReader.readInt32()
                    let flavourCount = try itemReader.readInt32()
                    itemContainers.append((marker, flavourCount))
                    for _ in 0..<max(0, Int(flavourCount)) {
                        _ = try itemReader.readQString()
                        _ = try itemReader.readBool()
                        _ = try itemReader.readQByteArray()
                    }
                }
            } else if let unsupported = try reader.skipQVariantPayload(typeID, isNull: isNull, typeIDs: &typeIDsSeen) {
                unsupportedTypeID = unsupported
                break
            }
        }
        tabKeyOrders.append(keys)
    }

    return RawArchiveFraming(
        magic: magic,
        topLevelKeys: topLevelKeys,
        tabKeyOrders: tabKeyOrders,
        itemListCounts: itemListCounts,
        itemContainers: itemContainers,
        typeIDsSeen: typeIDsSeen,
        unsupportedTypeID: unsupportedTypeID
    )
}

func testArchiveFramingRecordsUnsupportedType() {
    var stream = QDataStreamWriter()
    stream.writeQByteArray(Data(Format_v4.utf8))
    stream.writeUInt32(1)
    stream.writeQString("settings")
    writeVariant(&stream, typeID: 75) { _ in }

    do {
        let framing = try inspectV4Framing(stream.data)
        check(framing.unsupportedTypeID == 121, "framing parser records the remapped unsupported type")
        check(framing.topLevelKeys.count == 1, "framing parser keeps keys parsed before the unsupported value")
    } catch {
        check(false, "framing parser records an unsupported type", "\(error)")
    }
}

func testArchiveFramingHandlesDateTimeOffset() {
    var stream = QDataStreamWriter()
    stream.writeQByteArray(Data(Format_v4.utf8))
    stream.writeUInt32(1)
    stream.writeQString("settings")
    writeVariant(&stream, typeID: QMetaTypeID.variantMap) { map in
        map.writeUInt32(2)
        map.writeQString("when")
        writeVariant(&map, typeID: QMetaTypeID.dateTime) { dateTime in
            dateTime.writeUInt32(2_460_000)
            dateTime.writeUInt32(12_345)
            dateTime.writeUInt8(2)
        }
        map.writeQString("after")
        writeVariant(&map, typeID: QMetaTypeID.string) { value in
            value.writeQString("ok")
        }
    }

    do {
        let framing = try inspectV4Framing(stream.data)
        check(framing.unsupportedTypeID == nil, "framing parser handles a v4 QDateTime with OffsetFromUTC")
        check(framing.typeIDsSeen.contains(QMetaTypeID.dateTime), "framing parser saw the date-time type")
    } catch {
        check(false, "framing parser handles a v4 QDateTime with OffsetFromUTC", "\(error)")
    }
}

func testArchiveFramingAgainstRealArchive(_ path: String) {
    do {
        let real = try inspectV4Framing(try Data(contentsOf: URL(fileURLWithPath: path)))
        check(real.magic == "CopyQ v4", "real archive has the v4 QByteArray magic")
        guard let realExport = real.topLevelKeys.first else {
            check(false, "real archive has an export map entry")
            return
        }
        check(!realExport.0.isEmpty, "real export key uses QString framing")
        check(realExport.1 != 0, "real export value uses a QVariant type id")
        check(realExport.2 == false, "real export value uses the non-null QVariant framing")
        let realHasTabBodies: Bool? = real.unsupportedTypeID == nil ? !real.tabKeyOrders.isEmpty : nil

        let directory = try makeArchiveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("framing.cpq")
        var data = CopyQDataMap()
        data.set(CopyQFormat.text, Data("framing".utf8))
        data.set(CopyQFormat.html, Data("<b>framing</b>".utf8))
        data.set(CopyQFormat.uriList, Data("file:///tmp/framing.txt\r\n".utf8))
        let writer = try CopyQArchiveWriter(destinationURL: url, tabs: ["Framing"])
        try writer.beginTab("Framing")
        try writer.append(CopyQSyncItem(data: data))
        try writer.finishTab()
        try writer.finish()

        let ours = try inspectV4Framing(try Data(contentsOf: url))
        check(ours.unsupportedTypeID == nil, "written archive framing parser completes")
        check(ours.magic == real.magic, "written magic uses the same QByteArray framing")
        check(ours.topLevelKeys.count == 1, "written export map has one key")
        check(ours.topLevelKeys.first?.0 == "tabs", "written export key is tabs")
        check((ours.topLevelKeys.first?.1 ?? 0) != 0, "written export value uses a QVariant type id")
        check(ours.topLevelKeys.first?.2 == false, "written export value uses the non-null QVariant framing")
        check(ours.tabKeyOrders.first?.map(\.0) == ["data", "name"], "written tab keys are data before name")
        check(ours.tabKeyOrders.first?.first?.1 == QMetaTypeID.byteArray, "written tab data is a QByteArray")
        check(ours.tabKeyOrders.first?.last?.1 == QMetaTypeID.string, "written tab name is a QString")
        check(ours.itemListCounts == [1], "written tab item-list count framing")
        check(ours.itemContainers.first?.0 == -2, "written item container v2 marker")
        check(Int(ours.itemContainers.first?.1 ?? 0) == data.count, "written item container flavour count")

        if let realHasTabBodies, realHasTabBodies {
            check(
                ours.tabKeyOrders.first?.map(\.0) == real.tabKeyOrders.first?.map(\.0),
                "written tab key order matches the real archive"
            )
        }

        let realTabBodiesText = realHasTabBodies.map { $0 ? "yes" : "no" } ?? "unknown"
        let unsupportedText = real.unsupportedTypeID.map(String.init) ?? "none"
        print("info real archive framing: magic=\(real.magic) exportKey=\(realExport.0) type=\(realExport.1) isNull=\(realExport.2) parseComplete=\(real.unsupportedTypeID == nil) unsupportedType=\(unsupportedText) tabBodies=\(realTabBodiesText) types=\(real.typeIDsSeen.sorted())")
        print("info written archive framing: magic=\(ours.magic) exportKey=\(ours.topLevelKeys.first?.0 ?? "") type=\(ours.topLevelKeys.first?.1 ?? 0) tabKeys=\(ours.tabKeyOrders) itemLists=\(ours.itemListCounts) containers=\(ours.itemContainers) types=\(ours.typeIDsSeen.sorted())")
        if real.unsupportedTypeID != nil {
            print("info comparisons: magic, export map and QVariant framing; tab body comparison skipped because the real fixture parse stopped at type \(unsupportedText)")
        } else if realHasTabBodies == true {
            print("info comparisons: magic, export map and QVariant framing; tab body key order compared with the real archive")
        } else {
            print("info comparisons: magic, export map and QVariant framing; tab body framing checked on the written archive only because the real fixture has no tab bodies")
        }
    } catch {
        check(false, "archive framing control", "\(error)")
    }
}

// MARK: - Entry point

var arguments = Array(CommandLine.arguments.dropFirst())
var corpus: String?
var cpqPath: String?
while let first = arguments.first {
    switch first {
    case "--corpus":
        arguments.removeFirst()
        corpus = arguments.first
        arguments.removeFirst()
    case "--cpq":
        arguments.removeFirst()
        cpqPath = arguments.first
        arguments.removeFirst()
    default:
        arguments.removeFirst()
    }
}

print("CopyQSync tests")
testRealFixtureRoundTrip()
testRealFixtureStructure()
testDataMapOrdering()
testIntValueFloatSafety()
testMimeCompression()
testCompressedFlavourDecode()
testQVariantNullFraming()
testDateTimeTimezone()
testQVariantNestingLimit()
testMalformedCollectionCounts()
testQBitArrayOverflow()
testFlavourDecompressionFailures()
testTimestamp()
testEffectiveTimestamp()
testOnDiskShape()
testXMLFlavourRoundTrip()
testFolderRoundTrip()
testFolderSymlinkContainment()
testFolderWritePathContainment()
testFolderReportsFailures()
testArchiveItemCountWithoutEntries()
testArchiveV4()
testV5FallbackTabs()
testArchiveFailureIsolation()
testArchiveWriterStructure()
testArchiveWriterRoundTrip()
testArchiveWriterCompressesLargeFlavours()
testArchiveWriterReplacesAndAbandons()
testArchiveWriterRejectsNestedTabs()
testArchiveWriteErrorLocalizedDescription()
testArchiveFramingRecordsUnsupportedType()
testArchiveFramingHandlesDateTimeOffset()
if let corpus { testCorpus(corpus) }
if let cpqPath {
    testArchiveRealCorpus(cpqPath)
    testArchiveFramingAgainstRealArchive(cpqPath)
}

print("\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    exit(1)
}
