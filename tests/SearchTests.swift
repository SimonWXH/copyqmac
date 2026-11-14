// Search: FTS trigram queries, the short-query LIKE fallback, CJK, and edge
// cases such as wildcard characters.

import Foundation

func registerSearchTests() {
    /// Seeds a store with a fixed set of entries.
    func seeded() throws -> ClipboardHistory {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record([Fixtures.text("Hello World")])
        _ = try history.record([Fixtures.text("another entry about swift concurrency")])
        _ = try history.record([Fixtures.text("世界剪贴板管理器")])
        _ = try history.record([Fixtures.fileURL("/Users/example/Documents/quarterly-report.pdf")])
        _ = try history.record([Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)])
        return history
    }

    TestRunner.add("finds a substring with the trigram index") {
        let history = try seeded()
        expectEqual(try history.search("ello").count, 1)
        expectEqual(try history.search("concurr").count, 1)
    }

    TestRunner.add("search is case-insensitive") {
        let history = try seeded()
        expectEqual(try history.search("HELLO").count, 1)
        expectEqual(try history.search("hello").count, 1)
    }

    TestRunner.add("falls back to LIKE for one- and two-character queries") {
        let history = try seeded()
        // "sw" is only two characters, which the trigram tokenizer cannot match,
        // so this exercises the LIKE path.
        expectEqual(try history.search("sw").count, 1)
        // A single character also takes the LIKE path. "s" appears in both
        // "swift" and the indexed file path (e.g. ".../Documents/...").
        expectEqual(try history.search("s").count, 2)
        expectEqual(try history.search("z").count, 0)
    }

    TestRunner.add("finds CJK text") {
        let history = try seeded()
        // Two-character CJK query takes the LIKE path.
        expectEqual(try history.search("世界").count, 1)
        // Three-character query takes the FTS path.
        expectEqual(try history.search("剪贴板").count, 1)
    }

    TestRunner.add("indexes file names") {
        let history = try seeded()
        expectEqual(try history.search("quarterly-report").count, 1)
        expectEqual(try history.search("Documents").count, 1)
    }

    TestRunner.add("treats percent and underscore as literals") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record([Fixtures.text("100% done")])
        _ = try history.record([Fixtures.text("under_score")])
        _ = try history.record([Fixtures.text("unrelated")])
        expectEqual(try history.search("100%").count, 1)
        expectEqual(try history.search("under_score").count, 1)
        expectEqual(try history.search("%").count, 1)
        expectEqual(try history.search("_").count, 1)
    }

    TestRunner.add("handles quotes and FTS syntax without erroring") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record([Fixtures.text("a \"quoted\" value")])
        _ = try history.search("\"quoted\"")
        // These would be FTS operators if not quoted; they must not throw.
        _ = try history.search("foo OR bar")
        _ = try history.search("NEAR(")
        _ = try history.search("*")
        _ = try history.search("a\"b")
        TestRunner.pass()
    }

    TestRunner.add("empty query returns recent entries") {
        let history = try seeded()
        expectEqual(try history.search("").count, 5)
        expectEqual(try history.search("   ").count, 5)
    }

    TestRunner.add("no match returns an empty list") {
        let history = try seeded()
        expectEqual(try history.search("definitely-not-present").count, 0)
    }

    TestRunner.add("respects the result limit") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        for index in 0..<20 {
            _ = try history.record([Fixtures.text("common token \(index)")])
        }
        expectEqual(try history.search("common token", limit: 5).count, 5)
    }

    TestRunner.add("orders limited FTS and LIKE results before applying the limit") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let tab = try history.defaultTab()
        guard case .inserted(let older) = try history.record(
            [Fixtures.text("recencytag older")], into: tab, at: Date(timeIntervalSince1970: 10)
        ) else {
            TestRunner.fail("expected to insert older result")
            return
        }
        guard case .inserted(let newer) = try history.record(
            [Fixtures.text("recencytag newer")], into: tab, at: Date(timeIntervalSince1970: 30)
        ) else {
            TestRunner.fail("expected to insert newer result")
            return
        }
        guard case .inserted(let pinned) = try history.record(
            [Fixtures.text("pinnedtag older")], into: tab, at: Date(timeIntervalSince1970: 20)
        ) else {
            TestRunner.fail("expected to insert pinned result")
            return
        }
        _ = try history.setPinned(pinned.id, true)
        _ = try history.record(
            [Fixtures.text("pinnedtag newer")], into: tab, at: Date(timeIntervalSince1970: 40)
        )

        expectEqual(try history.search("recencytag", limit: 1, tabID: tab.id).first?.id, newer.id)
        expectEqual(try history.search("re", limit: 1, tabID: tab.id).first?.id, newer.id)
        expectEqual(try history.search("pinnedtag", limit: 1, tabID: tab.id).first?.id, pinned.id)
        expectEqual(try history.search("pi", limit: 1, tabID: tab.id).first?.id, pinned.id)
        expectEqual(try history.store.entry(id: older.id)?.pinned, false)
    }

    TestRunner.add("applies tab scope before result limit for FTS and LIKE") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let target = try history.defaultTab()
        let other = try history.addTab(name: "Other")
        _ = try history.record([Fixtures.text("sharedterm in other tab")], into: other)
        guard case .inserted(let targetEntry) = try history.record(
            [Fixtures.text("sharedterm in target tab")], into: target
        ) else {
            TestRunner.fail("expected to insert the target-tab entry")
            return
        }

        let ftsResults = try history.search("sharedterm", limit: 1, tabID: target.id)
        let likeResults = try history.search("sh", limit: 1, tabID: target.id)
        expectEqual(ftsResults.map(\.id), [targetEntry.id])
        expectEqual(likeResults.map(\.id), [targetEntry.id])
    }

    TestRunner.add("notes remain searchable when clipboard text reaches its index limit") {
        let store = try ClipboardStore(inMemory: true)
        let content = String(repeating: "x", count: FlavourDecoder.maxSearchTextLength)
        let entry = try store.insert(
            ClipboardEntry(createdAt: Date(), flavours: [Fixtures.text(content)])
        )
        try store.setNote(id: entry.id, note: "noteonlytoken")
        expectEqual(try store.search("noteonlytoken", limit: 1).map(\.id), [entry.id])
    }

    TestRunner.add("search results still carry full flavours") {
        let history = try seeded()
        let results = try history.search("quarterly-report")
        expectEqual(results.count, 1)
        expectEqual(FlavourDecoder.preview(for: results[0].flavours).fileNames, ["quarterly-report.pdf"])
    }

    TestRunner.add("rebuilding search text on replace keeps results consistent") {
        let store = try ClipboardStore(inMemory: true)
        let entry = try store.insert(ClipboardEntry(createdAt: Date(), flavours: [Fixtures.text("original text")]))
        expectEqual(try store.search("original").count, 1)
        try store.replaceFlavours(of: entry.id, with: [Fixtures.text("replacement text")])
        expectEqual(try store.search("original").count, 0)
        expectEqual(try store.search("replacement").count, 1)
    }
}
