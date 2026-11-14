// SPDX-License-Identifier: GPL-3.0-or-later
//
// Writer for CopyQ's `.cpq` export archive.
//
// The layout is the one CopyQ itself writes when no encryption key is
// supplied, which is exactly our case:
//
//   QByteArray  "CopyQ v4"                    mainwindow.cpp:2297-2298
//   QVariantMap export map: "tabs" as a       mainwindow.cpp:537-570 (built)
//               QStringList of tab names        mainwindow.cpp:2300-2301 (written)
//   QVariantMap one map per tab, keyed         mainwindow.cpp:2383-2387
//               "data" (the item list) and
//               "name", in Qt's sorted key
//               order ("data" before "name")
//
//     "data" is `serializeData(model)`'s output: the item count followed by
//     one item data container per item, in model row order
//     (serialize.cpp:590-601), written with the tab's QDataStream, which uses
//     Qt_4_7 (serialize.cpp:29, mainwindow.cpp:103 and 2368).
//
//     An item data container is the `_copyq.dat` body: qint32 -2, the flavour
//     count, then for each flavour the prefix-compressed MIME name, its
//     compression flag and the bytes (serialize.cpp:374-478 and 480-525).
//     Flavours larger than `item_data_threshold` carry flag 1 and their
//     qCompress payload, exactly as CopyQ writes them, so a backup of large
//     histories stays small.
//
// Why v4 and not v5: CopyQ only writes v5 when it has an encryption key
// (mainwindow.cpp:2270-2273) and its v5 reader always asks for a password
// first (mainwindow.cpp:2567-2577), so an unencrypted v5 archive cannot be
// imported by CopyQ at all.  v4 is the format CopyQ writes in the same
// situation we are in, and it is what our reader is verified against.
//
// The archive is streamed to a temporary file next to the destination and
// moved into place only once it is complete, the way CopyQ's `QSaveFile`
// does, so a failed export never leaves a truncated backup behind.

import Foundation

/// Errors raised while writing a `.cpq` archive.
public enum CopyQArchiveWriteError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// `beginTab` was called before the previous tab was finished.
    case tabAlreadyOpen(open: String, started: String)
    /// An item or `finishTab` arrived outside a tab.
    case noOpenTab
    /// `finish` was called while a tab was still open.
    case tabStillOpen(String)
    /// One tab's item list cannot be expressed in the format's `QByteArray`.
    case tabTooLarge(tab: String, items: Int, bytes: Int)

    public var description: String {
        switch self {
        case let .tabAlreadyOpen(open, started):
            return "tab \"\(started)\" is still open while starting tab \"\(open)\""
        case .noOpenTab:
            return "no tab is open"
        case let .tabStillOpen(name):
            return "tab \"\(name)\" is still open"
        case let .tabTooLarge(tab, items, bytes):
            return "tab \"\(tab)\" has \(items) item(s) in \(bytes) byte(s), "
                + "which exceeds the \(Int32.max)-byte item list CopyQ can store"
        }
    }

    public var errorDescription: String? { description }
}

/// Streams a CopyQ v4 `.cpq` export to disk, one item at a time.
///
/// The tab names have to be known up front because CopyQ writes the complete
/// tab list into the archive header, before the tab bodies.  Items are
/// appended as they are read from the source, so peak memory stays at one
/// item rather than one history.
///
/// ```swift
/// let writer = try CopyQArchiveWriter(destinationURL: url, tabs: names)
/// try writer.beginTab("Clipboard")
/// for item in items { try writer.append(item) }
/// try writer.finishTab()
/// try writer.finish()
/// ```
///
/// Call `cancel()` when the export is abandoned; the destination is left
/// untouched and the temporary file is removed.
public final class CopyQArchiveWriter {
    /// The file that is replaced when `finish()` succeeds.
    public let destinationURL: URL
    /// The tab list written into the archive header.
    public let tabNames: [String]

    private let temporaryURL: URL
    private let file: ArchiveFileWriter
    private var openTab: OpenTab?
    private var isFinished = false

    private struct OpenTab {
        var name: String
        /// Offset of the `QByteArray` length prefix of the tab's item list.
        var dataLengthOffset: Int
        /// Offset of the item count, which is also the first byte of the list.
        var dataStart: Int
        var itemCount: Int
    }

    public init(destinationURL: URL, tabs: [String]) throws {
        self.destinationURL = destinationURL
        self.tabNames = tabs

        let directory = destinationURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial"
        )
        self.temporaryURL = temporaryURL

        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporaryURL.path])
        }
        do {
            file = try ArchiveFileWriter(temporaryURL: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        var stream = QDataStreamWriter()
        stream.writeQByteArray(Data(CopyQArchive.Format.v4.rawValue.utf8))
        // exportSettings() only emits "tabs" when the list is not empty.
        if tabs.isEmpty {
            stream.writeUInt32(0)
        } else {
            stream.writeUInt32(1)
            stream.writeQString("tabs")
            stream.writeUInt32(QMetaTypeID.stringList)
            stream.writeBool(false)
            stream.writeQStringList(tabs)
        }
        do {
            try file.append(stream.data)
        } catch {
            // A throwing init does not run deinit, so the temporary file has
            // to be removed here.
            file.closeIgnoringErrors()
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    deinit {
        cancel()
    }

    /// Starts a tab map.  The tab's name is written after its item list.
    public func beginTab(_ name: String) throws {
        if let openTab {
            throw CopyQArchiveWriteError.tabAlreadyOpen(open: name, started: openTab.name)
        }

        var stream = QDataStreamWriter()
        // Qt's QMap serialises keys in sorted order, so "data" precedes
        // "name", exactly as in CopyQ's own exportTabData().
        stream.writeUInt32(2)
        stream.writeQString("data")
        stream.writeUInt32(QMetaTypeID.byteArray)
        stream.writeBool(false)
        let dataLengthOffset = file.offset + stream.data.count
        stream.writeUInt32(0) // patched by finishTab()
        let dataStart = dataLengthOffset + 4
        stream.writeInt32(0) // item count, patched by finishTab()
        try file.append(stream.data)

        openTab = OpenTab(
            name: name,
            dataLengthOffset: dataLengthOffset,
            dataStart: dataStart,
            itemCount: 0
        )
    }

    /// Appends one item to the open tab's item list.
    public func append(_ item: CopyQSyncItem) throws {
        guard var tab = openTab else {
            throw CopyQArchiveWriteError.noOpenTab
        }
        var stream = QDataStreamWriter()
        CopyQItemData.encode(
            item.data,
            into: &stream,
            compressionThreshold: CopyQItemData.itemDataThreshold
        )
        try file.append(stream.data)
        tab.itemCount += 1
        openTab = tab
    }

    /// Closes the open tab: patches its item count and list length, then
    /// writes the tab name.
    public func finishTab() throws {
        guard let tab = openTab else {
            throw CopyQArchiveWriteError.noOpenTab
        }

        let listLength = file.offset - tab.dataStart
        guard tab.itemCount <= Int(Int32.max), listLength <= Int(Int32.max) else {
            throw CopyQArchiveWriteError.tabTooLarge(
                tab: tab.name,
                items: tab.itemCount,
                bytes: listLength
            )
        }

        var lengthPatch = QDataStreamWriter()
        lengthPatch.writeUInt32(UInt32(listLength))
        try file.overwrite(lengthPatch.data, at: tab.dataLengthOffset)

        var countPatch = QDataStreamWriter()
        countPatch.writeInt32(Int32(tab.itemCount))
        try file.overwrite(countPatch.data, at: tab.dataStart)

        var nameStream = QDataStreamWriter()
        nameStream.writeQString("name")
        nameStream.writeUInt32(QMetaTypeID.string)
        nameStream.writeBool(false)
        nameStream.writeQString(tab.name)
        try file.append(nameStream.data)

        openTab = nil
    }

    /// Closes the archive and moves it onto `destinationURL`.
    public func finish() throws {
        if let openTab {
            throw CopyQArchiveWriteError.tabStillOpen(openTab.name)
        }
        guard !isFinished else { return }

        do {
            try file.close()
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            isFinished = true
        } catch {
            cancel()
            throw error
        }
    }

    /// Abandons the export, leaving `destinationURL` untouched.
    public func cancel() {
        guard !isFinished else { return }
        isFinished = true
        file.closeIgnoringErrors()
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}

/// Random-access byte sink over the archive's temporary file.
///
/// `QByteArray` fields are length prefixed, but the length of a tab's item
/// list is only known once every item has been written, so the writer patches
/// the two leading fields afterwards instead of encoding a tab twice.
private final class ArchiveFileWriter {
    private let handle: FileHandle
    private(set) var offset = 0

    init(temporaryURL: URL) throws {
        handle = try FileHandle(forWritingTo: temporaryURL)
    }

    func append(_ data: Data) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        offset += data.count
    }

    /// Writes `data` at an already written position, leaving the append
    /// position unchanged.
    func overwrite(_ data: Data, at position: Int) throws {
        try handle.seek(toOffset: UInt64(position))
        try handle.write(contentsOf: data)
    }

    func close() throws {
        try handle.synchronize()
        try handle.close()
    }

    func closeIgnoringErrors() {
        try? handle.close()
    }
}
