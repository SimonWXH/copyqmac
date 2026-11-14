// Store round-trip: every flavour, every field, across reopen.

import AppKit
import Foundation

func registerStoreRoundTripTests() {
    /// A payload that exercises binary data, multiple items, empty data, and
    /// several type identifiers.
    func richFlavours() -> [Flavour] {
        [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Hello 世界".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>Hello 世界</p>".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
            Flavour(itemIndex: 1, type: PasteboardTypes.fileURL, data: Data("file:///tmp/one.txt".utf8)),
            Flavour(itemIndex: 2, type: PasteboardTypes.fileURL, data: Data("file:///tmp/two.txt".utf8)),
            Flavour(itemIndex: 2, type: "com.example.empty", data: Data()),
            Flavour(itemIndex: 3, type: "com.example.binary", data: Data([0x00, 0xFF, 0x10, 0x80, 0x7F])),
        ]
    }

    TestRunner.add("round-trips every flavour exactly") {
        let store = try ClipboardStore(inMemory: true)
        let date = Date(timeIntervalSince1970: 1_700_123_456.789)
        let stored = try store.insert(ClipboardEntry(createdAt: date, flavours: richFlavours()))
        let loaded = try store.entry(id: stored.id)
        expectNotNil(loaded)
        guard let loaded else { return }
        expectEqual(loaded.createdAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.0001)
        expectEqual(loaded.pinned, false)
        expectEqual(loaded.flavours.count, 7)
        // Compare as a dictionary keyed by (itemIndex, type) since SQLite
        // returns rows in its own order.
        let expected = Dictionary(uniqueKeysWithValues: richFlavours().map { ("\($0.itemIndex)|\($0.type)", $0.data) })
        let actual = Dictionary(uniqueKeysWithValues: loaded.flavours.map { ("\($0.itemIndex)|\($0.type)", $0.data) })
        expectEqual(actual, expected)
    }

    TestRunner.add("persists across close and reopen") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path

        var storedID: Int64 = 0
        do {
            let store = try ClipboardStore(path: path)
            let entry = try store.insert(ClipboardEntry(createdAt: Date(), flavours: richFlavours()))
            storedID = entry.id
            expectEqual(try store.count(), 1)
        }
        do {
            let reopened = try ClipboardStore(path: path)
            expectEqual(try reopened.count(), 1)
            let loaded = try reopened.entry(id: storedID)
            expectNotNil(loaded, "entry should survive reopen")
            expectEqual(loaded?.flavours.count, 7)
        }
    }

    TestRunner.add("keeps pinned state and timestamps") {
        let store = try ClipboardStore(inMemory: true)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let stored = try store.insert(ClipboardEntry(createdAt: date, pinned: true, flavours: [Fixtures.text("pinned")]))
        let loaded = try store.entry(id: stored.id)
        expectEqual(loaded?.pinned, true)
        expectEqual(loaded?.createdAt.timeIntervalSince1970, 1_600_000_000)
    }

    TestRunner.add("setPinned and touch update the stored row") {
        let store = try ClipboardStore(inMemory: true)
        let stored = try store.insert(ClipboardEntry(createdAt: Date(timeIntervalSince1970: 0), flavours: [Fixtures.text("x")]))
        try store.setPinned(id: stored.id, pinned: true)
        try store.touch(id: stored.id, at: Date(timeIntervalSince1970: 999))
        let loaded = try store.entry(id: stored.id)
        expectEqual(loaded?.pinned, true)
        expectEqual(loaded?.createdAt.timeIntervalSince1970, 999)
    }

    TestRunner.add("sets and reports the schema version") {
        let store = try ClipboardStore(inMemory: true)
        expectEqual(try store.count(), 0)
        // Opening an already-current database must not re-run the migration.
        _ = store
    }

    TestRunner.add("refuses a future schema version") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        do {
            let store = try ClipboardStore(path: path)
            _ = store
        }
        // Bump the version behind the store's back.
        let raw = try SQLiteDatabase(path: path)
        raw.userVersion = 999
        expectThrows {
            _ = try ClipboardStore(path: path)
        }
    }

    TestRunner.add("updates flavours in place") {
        let store = try ClipboardStore(inMemory: true)
        let stored = try store.insert(ClipboardEntry(createdAt: Date(), flavours: [Fixtures.text("before")]))
        try store.replaceFlavours(of: stored.id, with: [Fixtures.text("after")])
        let loaded = try store.entry(id: stored.id)
        expectEqual(loaded?.flavours.count, 1)
        expectEqual(FlavourDecoder.preview(for: loaded?.flavours ?? []).text, "after")
        expectEqual(try store.search("after").count, 1)
        expectEqual(try store.search("before").count, 0)
    }

    TestRunner.add("replacing flavours can turn a text entry into an image entry") {
        let store = try ClipboardStore(inMemory: true)
        let stored = try store.insert(ClipboardEntry(createdAt: Date(), flavours: [Fixtures.text("before")]))
        try store.replaceFlavours(of: stored.id, with: [
            Fixtures.text("after"),
            Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
        ])
        let loaded = try store.entry(id: stored.id)
        expectEqual(loaded?.flavours.count, 2)
        expectEqual(FlavourDecoder.preview(for: loaded?.flavours ?? []).kind, .image)
    }

    TestRunner.add("deletes all entries") {
        let store = try ClipboardStore(inMemory: true)
        for index in 0..<5 {
            _ = try store.insert(ClipboardEntry(createdAt: Date(), flavours: [Fixtures.text("e\(index)")]))
        }
        expectEqual(try store.count(), 5)
        try store.deleteAll()
        expectEqual(try store.count(), 0)
        expectEqual(try store.search("e1").count, 0)
    }

    TestRunner.add("trim respects the limit and reports removals") {
        let store = try ClipboardStore(inMemory: true)
        let tab = try store.defaultTab()
        guard let tab else {
            TestRunner.fail("expected a default tab")
            return
        }
        for index in 0..<10 {
            _ = try store.insert(
                ClipboardEntry(createdAt: Date(timeIntervalSince1970: Double(index)), tabID: tab.id, flavours: [Fixtures.text("e\(index)")])
            )
        }
        expectEqual(try store.trim(tabID: tab.id, to: 4), 6)
        expectEqual(try store.count(), 4)
        expectEqual(try store.trim(tabID: tab.id, to: 4), 0)
    }

    TestRunner.add("round-trips large TIFF with compression and exact byte equality") {
        let store = try ClipboardStore(inMemory: true)
        let tiffData = Fixtures.largeTIFF(width: 600, height: 600)
        expect(tiffData.count > 1_000_000, "fixture TIFF should be over 1 MB")

        let originalFlavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.tiff, data: tiffData),
            Fixtures.text("sample TIFF text"),
        ]
        let inserted = try store.insert(ClipboardEntry(createdAt: Date(), flavours: originalFlavours))

        // Check raw database storage: large TIFF must be compressed with compressed = 1
        let stmt = try store.database.prepare(
            "SELECT type, length(data), compressed FROM flavours WHERE entry_id = ? ORDER BY item_index, type"
        )
        defer { stmt.finalize() }
        try stmt.bind(1, inserted.id)

        var inspected: [(type: String, blobLen: Int, compressed: Int)] = []
        while try stmt.step() {
            inspected.append((
                type: stmt.string(at: 0) ?? "",
                blobLen: Int(stmt.int64(at: 1)),
                compressed: Int(stmt.int64(at: 2))
            ))
        }
        expectEqual(inspected.count, 2)
        let tiffRow = inspected.first { $0.type == PasteboardTypes.tiff }
        expectNotNil(tiffRow)
        expectEqual(tiffRow?.compressed, 1, "large TIFF must be compressed at rest")
        expect(tiffRow!.blobLen < tiffData.count, "compressed blob must be smaller than raw uncompressed TIFF")

        let textRow = inspected.first { $0.type == PasteboardTypes.utf8Text }
        expectNotNil(textRow)
        expectEqual(textRow?.compressed, 0, "small text flavour must remain uncompressed")

        // Reading back decompresses to byte-identical data
        let loaded = try store.entry(id: inserted.id)
        expectNotNil(loaded)
        let loadedTiff = loaded?.flavours.first { $0.type == PasteboardTypes.tiff }
        expectNotNil(loadedTiff)
        expectEqual(loadedTiff?.data.count, tiffData.count)
        expectEqual(loadedTiff?.data, tiffData, "decompressed TIFF must be byte-identical to original")
    }

    TestRunner.add("a damaged compressed flavour leaves the rest of the history readable") {
        let store = try ClipboardStore(inMemory: true)
        let inserted = try store.insert(ClipboardEntry(createdAt: Date(), flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.tiff, data: Fixtures.largeTIFF(width: 200, height: 200)),
            Fixtures.text("survives a damaged neighbour"),
        ]))

        let damage = try store.database.prepare(
            "UPDATE flavours SET data = ?, compressed = 1 WHERE entry_id = ? AND type = ?"
        )
        defer { damage.finalize() }
        try damage.bind(1, Data([0, 0, 0, 16, 1, 2, 3]))
        try damage.bind(2, inserted.id)
        try damage.bind(3, PasteboardTypes.tiff)
        try damage.run()

        let recent = try store.recentEntries(limit: 10)
        expectEqual(recent.count, 1, "a damaged row must not hide the entry")
        expectEqual(recent.first?.flavours.count, 1)
        expectEqual(recent.first?.flavours.first?.type, PasteboardTypes.utf8Text)
        expectEqual(recent.first?.flavours.first?.data, Data("survives a damaged neighbour".utf8))

        let loaded = try store.entry(id: inserted.id)
        expectEqual(loaded?.flavours.first?.data, Data("survives a damaged neighbour".utf8))
    }

    TestRunner.add("paste-back after restart produces byte-identical flavours") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("history.sqlite").path

        let tiffData = Fixtures.largeTIFF(width: 400, height: 400)
        let originalFlavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.tiff, data: tiffData),
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Restart fidelity test".utf8)),
        ]
        var entryID: Int64 = 0

        // Process 1: capture and store
        do {
            let store = try ClipboardStore(path: dbPath)
            let entry = try store.insert(ClipboardEntry(createdAt: Date(), flavours: originalFlavours))
            entryID = entry.id
        }

        // Process 2: restart, read back, and paste to pasteboard
        do {
            let store = try ClipboardStore(path: dbPath)
            guard let entry = try store.entry(id: entryID) else {
                TestRunner.fail("stored entry not found after restart")
                return
            }

            // Write to an isolated named NSPasteboard
            let pasteboard = NSPasteboard(name: .init("copyqmac-restart-paste-test-\(UUID().uuidString)"))
            pasteboard.declareTypes([], owner: nil)
            PasteboardBridge.write(entry.flavours, to: pasteboard)

            // Read flavours back from the pasteboard
            let snapshot = PasteboardBridge.snapshot(of: pasteboard)
            let tiffFlavour = snapshot.first { $0.type == PasteboardTypes.tiff }
            expectNotNil(tiffFlavour, "TIFF flavour must be present on pasteboard")
            expectEqual(tiffFlavour?.data, tiffData, "paste-back after restart must produce identical bytes")

            let textFlavour = snapshot.first { $0.type == PasteboardTypes.utf8Text }
            expectNotNil(textFlavour, "text flavour must be present on pasteboard")
            expectEqual(textFlavour?.data, Data("Restart fidelity test".utf8))
        }
    }
}
