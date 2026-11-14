// The capture model: fingerprints, item structure, and relative time.

import Foundation

func registerCaptureModelTests() {
    TestRunner.add("fingerprint is stable across flavour order") {
        let a = [Fixtures.text("x"), Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>x</b>".utf8))]
        let b = [Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>x</b>".utf8)), Fixtures.text("x")]
        expectEqual(Fingerprint.of(a), Fingerprint.of(b))
    }

    TestRunner.add("fingerprint distinguishes different payloads") {
        expectNotEqual(Fingerprint.of([Fixtures.text("a")]), Fingerprint.of([Fixtures.text("b")]))
    }

    TestRunner.add("fingerprint distinguishes item indexes") {
        let a = [Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("same".utf8))]
        let b = [Flavour(itemIndex: 1, type: PasteboardTypes.utf8Text, data: Data("same".utf8))]
        expectNotEqual(Fingerprint.of(a), Fingerprint.of(b))
    }

    TestRunner.add("fingerprint is not confused by field concatenation") {
        // Without length prefixes, ("ab", "c") and ("a", "bc") would collide.
        let a = [Flavour(itemIndex: 0, type: "ab", data: Data("c".utf8))]
        let b = [Flavour(itemIndex: 0, type: "a", data: Data("bc".utf8))]
        expectNotEqual(Fingerprint.of(a), Fingerprint.of(b))
    }

    TestRunner.add("entry reports its pasteboard item count") {
        let entry = ClipboardEntry(
            createdAt: Date(),
            flavours: [
                Fixtures.fileURL("/tmp/a", itemIndex: 0),
                Fixtures.fileURL("/tmp/b", itemIndex: 1),
                Fixtures.fileURL("/tmp/c", itemIndex: 2),
            ]
        )
        expectEqual(entry.itemCount, 3)
        expectEqual(ClipboardEntry(createdAt: Date(), flavours: []).itemCount, 0)
    }

    TestRunner.add("entry fingerprint matches the flavour fingerprint") {
        let flavours = [Fixtures.text("hello")]
        expectEqual(ClipboardEntry(createdAt: Date(), flavours: flavours).fingerprint, Fingerprint.of(flavours))
    }

    TestRunner.add("relative time describes recent intervals") {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-2), now: now, calendar: calendar), "just now")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-30), now: now, calendar: calendar), "30 s ago")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-180), now: now, calendar: calendar), "3 min ago")
        expectEqual(RelativeTime.describe(now.addingTimeInterval(-7200), now: now, calendar: calendar), "2 h ago")
        let yesterday = now.addingTimeInterval(-90_000)
        expectEqual(RelativeTime.describe(yesterday, now: now, calendar: calendar), "Yesterday")
    }

    TestRunner.add("relative time falls back to a date for older entries") {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let old = now.addingTimeInterval(-60 * 86_400)
        let described = RelativeTime.describe(old, now: now, calendar: calendar)
        expect(!described.isEmpty, "expected a date string")
        expect(described != "Yesterday" && !described.contains("ago"), "expected an absolute date, got \(described)")
    }

    TestRunner.add("sha256 matches the known vector") {
        var hasher = SHA256Digest()
        hasher.update("abc")
        expectEqual(hasher.finalize(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    TestRunner.add("sha256 matches the empty-input vector") {
        var hasher = SHA256Digest()
        expectEqual(hasher.finalize(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    TestRunner.add("hashing a large payload stays linear") {
        // Finder puts a multi-megabyte icon on the pasteboard with every file
        // copy, so the fingerprint has to hash megabytes. Hashing must not
        // get slower the bigger the payload is.
        let payload = Data([UInt8](repeating: 0x37, count: 8 * 1024 * 1024))
        let start = Date()
        let digest = Fingerprint.of([Flavour(itemIndex: 0, type: PasteboardTypes.tiff, data: payload)])
        let elapsed = Date().timeIntervalSince(start)
        expectEqual(digest.count, 64)
        expect(elapsed < 5, "hashing 8 MB took \(elapsed)s, which is far too slow")
    }
}
