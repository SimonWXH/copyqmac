// Capture policy: consecutive-duplicate collapsing and globally bounded history.

import Foundation

func registerDedupeAndBoundsTests() {
    /// A history whose global cap is `limit` entries (or the default when nil).
    func makeHistory(limit: Int? = nil) throws -> ClipboardHistory {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        if let limit {
            var preferences = try history.preferences()
            preferences.defaultMaxItems = limit
            try history.setPreferences(preferences)
        }
        return history
    }

    TestRunner.add("records a new entry") {
        let history = try makeHistory()
        let outcome = try history.record([Fixtures.text("first")])
        guard case .inserted(let entry) = outcome else {
            TestRunner.fail("expected .inserted, got \(outcome)")
            return
        }
        TestRunner.pass()
        expectEqual(entry.id > 0, true, "expected an assigned id")
        expectEqual(try history.store.count(), 1)
    }

    TestRunner.add("does not record an empty capture") {
        let history = try makeHistory()
        expectEqual(try history.record([]), RecordOutcome.empty)
        expectEqual(try history.store.count(), 0)
    }

    TestRunner.add("collapses consecutive duplicates without adding a row") {
        let history = try makeHistory()
        _ = try history.record([Fixtures.text("same")], at: Date(timeIntervalSince1970: 100))
        let outcome = try history.record([Fixtures.text("same")], at: Date(timeIntervalSince1970: 200))
        guard case .duplicate(let entry) = outcome else {
            TestRunner.fail("expected .duplicate, got \(outcome)")
            return
        }
        TestRunner.pass()
        expectEqual(entry.createdAt, Date(timeIntervalSince1970: 200))
        expectEqual(try history.store.count(), 1)
    }

    TestRunner.add("keeps non-consecutive duplicates as separate entries") {
        let history = try makeHistory()
        _ = try history.record([Fixtures.text("a")])
        _ = try history.record([Fixtures.text("b")])
        _ = try history.record([Fixtures.text("a")])
        expectEqual(try history.store.count(), 3)
    }

    TestRunner.add("collapsing compares the whole flavour set, not just text") {
        let history = try makeHistory()
        _ = try history.record([
            Fixtures.text("hello"),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>hello</b>".utf8)),
        ])
        let outcome = try history.record([
            Fixtures.text("hello"),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<i>hello</i>".utf8)),
        ])
        guard case .inserted = outcome else {
            TestRunner.fail("a different HTML flavour should be a new entry, got \(outcome)")
            return
        }
        TestRunner.pass()
        expectEqual(try history.store.count(), 2)
    }

    TestRunner.add("length-prefixes flavour data for unambiguous deduplication") {
        func encodedMarker(_ type: String) -> Data {
            var index = Int64(0).bigEndian
            return withUnsafeBytes(of: &index) { Data($0) } + Data(type.utf8) + Data([0])
        }
        let x = Data("x".utf8)
        let y = Data("y".utf8)
        let first = [
            Flavour(itemIndex: 0, type: "a", data: x),
            Flavour(itemIndex: 0, type: "b", data: encodedMarker("c") + y),
        ]
        let second = [
            Flavour(itemIndex: 0, type: "a", data: x + encodedMarker("b")),
            Flavour(itemIndex: 0, type: "c", data: y),
        ]
        expectEqual(Fingerprint.of(first) == Fingerprint.of(second), false)

        let history = try makeHistory()
        _ = try history.record(first)
        guard case .inserted = try history.record(second) else {
            TestRunner.fail("distinct flavour payloads must not collapse")
            return
        }
        TestRunner.pass()
        expectEqual(try history.store.count(), 2)
    }

    TestRunner.add("bounds history to the global configured limit") {
        let history = try makeHistory(limit: 5)
        for index in 0..<12 {
            _ = try history.record([Fixtures.text("entry \(index)")], at: Date(timeIntervalSince1970: Double(index)))
        }
        expectEqual(try history.store.count(), 5)
    }

    TestRunner.add("keeps the newest entries when trimming") {
        let history = try makeHistory(limit: 3)
        for index in 0..<6 {
            _ = try history.record([Fixtures.text("entry \(index)")], at: Date(timeIntervalSince1970: Double(index)))
        }
        let recent = try history.recent(limit: 10)
        expectEqual(recent.map { FlavourDecoder.preview(for: $0.flavours).text }, ["entry 5", "entry 4", "entry 3"])
    }

    TestRunner.add("never trims pinned entries under the global limit") {
        let history = try makeHistory(limit: 3)
        let oldest = try history.record([Fixtures.text("pin me")], at: Date(timeIntervalSince1970: 0))
        guard case .inserted(let pinned) = oldest else { return }
        _ = try history.setPinned(pinned.id, true)
        for index in 1..<10 {
            _ = try history.record([Fixtures.text("entry \(index)")], at: Date(timeIntervalSince1970: Double(index)))
        }
        expectEqual(try history.store.pinnedCount(), 1)
        expectNotNil(try history.store.entry(id: pinned.id), "the pinned entry must survive trimming")
        expectEqual(try history.store.count(), 4)  // 3 unpinned + 1 pinned
    }

    TestRunner.add("pinned entries sort above newer unpinned ones") {
        let history = try makeHistory()
        guard case .inserted(let first) = try history.record([Fixtures.text("older")], at: Date(timeIntervalSince1970: 0))
        else { return }
        _ = try history.record([Fixtures.text("newer")], at: Date(timeIntervalSince1970: 100))
        _ = try history.setPinned(first.id, true)
        let recent = try history.recent(limit: 10)
        expectEqual(recent.first?.id, first.id)
    }

    TestRunner.add("bumping a duplicate moves it to the top") {
        let history = try makeHistory()
        _ = try history.record([Fixtures.text("one")], at: Date(timeIntervalSince1970: 0))
        guard case .inserted(let second) = try history.record([Fixtures.text("two")], at: Date(timeIntervalSince1970: 10))
        else { return }
        // Copying "two" again immediately is a consecutive duplicate: it bumps
        // the existing entry instead of adding a third row.
        _ = try history.record([Fixtures.text("two")], at: Date(timeIntervalSince1970: 20))
        var recent = try history.recent(limit: 10)
        expectEqual(recent.count, 2)
        expectEqual(recent.first?.id, second.id)
        expectEqual(recent.first?.createdAt, Date(timeIntervalSince1970: 20))

        // A third distinct payload, then "two" again, is no longer consecutive
        // with the previous "two" and must become a new entry.
        _ = try history.record([Fixtures.text("three")], at: Date(timeIntervalSince1970: 30))
        _ = try history.record([Fixtures.text("two")], at: Date(timeIntervalSince1970: 40))
        recent = try history.recent(limit: 10)
        expectEqual(recent.count, 4)
        expectEqual(FlavourDecoder.preview(for: recent.first?.flavours ?? []).text, "two")
    }

    TestRunner.add("deleting an entry removes its search row") {
        let history = try makeHistory()
        guard case .inserted(let entry) = try history.record([Fixtures.text("deletable marker")]) else { return }
        expectEqual(try history.search("deletable marker").count, 1)
        try history.delete(entry.id)
        expectEqual(try history.search("deletable marker").count, 0)
        expectEqual(try history.store.count(), 0)
    }
}
