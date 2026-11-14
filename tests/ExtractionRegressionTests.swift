import Foundation

// Real payload pairs from a Fedora copy of a web page. The source app wrote the
// characters into the HTML, but its plain-text companion was produced by a
// JavaScript escaper, so the `.txt` flavour reads `\u4f55` where the markup reads
// 何. CopyQ syncs all three files (`.html`, `.txt`, `_copyq.dat`) and the macOS
// app imports every flavour.
private let fedoraHTML = "<meta http-equiv=\"content-type\" content=\"text/html; charset=utf-8\"><header class=\"marquee-header\"><p class=\"marquee-headline\">何止厉害一点点</p></header>"
private let fedoraEscapedText = #"\u4f55\u6b62\u5389\u5bb3\u4e00\u70b9\u70b9"#

func registerExtractionRegressionTests() {
    TestRunner.add("extracts RTF Unicode and skips destination groups") {
        let rtf = #"{\rtf1\ansi{\fonttbl{\f0 Arial;}}\f0 RTF A\u8217?B\par Next line}"#
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(rtf.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record([flavour])

        expectEqual(preview.kind, .rtf)
        expectEqual(preview.text, "RTF A’B Next line")
        expectEqual(FlavourDecoder.searchText(for: preview), "RTF A’B Next line")
        expectEqual(try history.search("’").count, 1)
    }

    TestRunner.add("decodes decimal and hexadecimal HTML character references") {
        let html = "<p>Quote: &#8217; &#x1F642;</p>"
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record([flavour])

        expectEqual(preview.kind, .html)
        expectEqual(preview.text, "Quote: ’ 🙂")
        expectEqual(FlavourDecoder.searchText(for: preview), "Quote: ’ 🙂")
        expectEqual(try history.search("’").count, 1)
        expectEqual(try history.search("🙂").count, 1)
    }

    TestRunner.add("extracts RTF control words including tab and emdash and ignores header footer groups") {
        let rtf = #"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\header Header\tab Note}\f0 Text\tab before\emdash after\par End}"#
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(rtf.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record([flavour])

        expectEqual(preview.kind, .rtf)
        let expected = "Text before\u{2014}after End"
        expectEqual(preview.text, expected)
        expectEqual(FlavourDecoder.searchText(for: preview), expected)
        expectEqual(try history.search("before\u{2014}after").count, 1)
        expectEqual(try history.search("Header Note").count, 0)
    }

    TestRunner.add("extracts RTF inline styled runs and punctuation without inserting spurious spaces") {
        let rtf = #"{\rtf1\ansi{\f0 super}{\f0 script} {\b Note}: {\*\doccomm ignored}done}"#
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(rtf.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])

        expectEqual(preview.kind, .rtf)
        expectEqual(preview.text, "superscript Note: done")
    }

    TestRunner.add("extracts text from multi-item snapshots and makes later items searchable") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.plainText, data: Data("first plain item".utf8)),
            Flavour(itemIndex: 1, type: PasteboardTypes.plainText, data: Data("second plain item".utf8)),
        ]
        let preview = FlavourDecoder.preview(for: flavours)
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record(flavours)

        expectEqual(preview.kind, .text)
        expectEqual(preview.text, "first plain item\nsecond plain item")
        expectEqual(FlavourDecoder.searchText(for: preview), "first plain item\nsecond plain item")
        expectEqual(try history.search("first plain").count, 1)
        expectEqual(try history.search("second plain").count, 1)
    }

    // MARK: - JavaScript-style escapes in a copied payload

    TestRunner.add("decodes JavaScript escapes in an HTML payload") {
        let html = #"<p class="headline">\u4f55\u5bb3 <b>\u4e2d\u6587</b></p><p>&#92;u4f55</p>"#
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])

        expectEqual(preview.kind, .html)
        expectEqual(preview.text, "何害 中文 何")
        expectEqual(preview.searchText, "何害 中文 何")
    }

    TestRunner.add("decodes surrogate pair escapes alongside HTML entities") {
        let html = #"<p>&#8217;\u2019 \uD83D\uDE00 &amp; \u0026</p>"#
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])

        expectEqual(preview.text, "’’ 😀 & &")
    }

    TestRunner.add("leaves an escape that is not a whole code point exactly as typed") {
        let html = #"<p>broken \uD83D end, short \u12 end, \uZZZZ end</p>"#
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])

        expectEqual(preview.text, #"broken \uD83D end, short \u12 end, \uZZZZ end"#)
    }

    TestRunner.add("decodes an escaped plain-text flavour when the item also carries HTML") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(fedoraHTML.utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data(fedoraEscapedText.utf8)),
        ]
        let preview = FlavourDecoder.preview(for: flavours)
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record(flavours)

        expectEqual(preview.kind, .html)
        expectEqual(preview.text, "何止厉害一点点")
        expectEqual(preview.searchText, "何止厉害一点点")
        expectEqual(try history.search("何止").count, 1, "the list and the search index read the real characters")
        expectEqual(try history.search("厉害").count, 1)
        expectEqual(try history.search("u4f55").count, 0, "the escapes are not indexed as text")

        let entry = ClipboardEntry(createdAt: Date(timeIntervalSince1970: 1_700_000_000), flavours: flavours)
        let presentation = EntryPresentation(entry: entry)
        expectEqual(presentation.primaryText, "何止厉害一点点")
        expectEqual(presentation.searchText, "何止厉害一点点")
        expectEqual(
            FlavourDecoder.storedPlainText(from: flavours),
            "何止厉害一点点",
            "the editor opens with readable text"
        )
    }

    TestRunner.add("paste as plain text decodes escapes from a rich item") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(fedoraHTML.utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data(fedoraEscapedText.utf8)),
        ]

        expectEqual(FlavourDecoder.plainTextRepresentation(from: flavours), "何止厉害一点点")
    }

    TestRunner.add("leaves a literal escape sequence in a plain text capture alone") {
        let code = #"{"emoji":"\uD83D\uDE00"}"#
        let flavour = Fixtures.text(code)
        let preview = FlavourDecoder.preview(for: [flavour])

        expectEqual(preview.kind, .text)
        expectEqual(preview.text, code, "a code snippet keeps its bytes unless a rich flavour shows it was escaped")
    }

    TestRunner.add("falls through a blank text flavour to the markup's text") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>Visible</p>".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data(" \n\t ".utf8)),
        ]

        expectEqual(FlavourDecoder.preview(for: flavours).text, "Visible")
    }

    TestRunner.add("labels markup that has no visible text instead of leaving the row empty") {
        let html = "<style>body{color:red}</style><script>var x = 1</script>"
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])
        let entry = ClipboardEntry(createdAt: Date(timeIntervalSince1970: 1_700_000_000), flavours: [flavour])

        expectEqual(preview.kind, .other)
        expectEqual(preview.text, "public.html")
        expectEqual(preview.searchText, "public.html")
        expectEqual(EntryPresentation(entry: entry).primaryText, "public.html")
    }

    TestRunner.add("reindexes escaped rows and decodes them on upgrade") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path

        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(fedoraHTML.utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data(fedoraEscapedText.utf8)),
        ]
        // Above 1 KiB the store compresses a flavour at rest, so the migration
        // has to decompress the payload to notice its escapes.
        let escapedRun = String(repeating: #"\u4f55\u5bb3"#, count: 200)
        let largeHTML = "<p>\(escapedRun)</p>"
        let largeFlavour = Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(largeHTML.utf8))

        let small: ClipboardEntry
        let large: ClipboardEntry
        do {
            let store = try ClipboardStore(path: path)
            small = try store.insert(ClipboardEntry(createdAt: Date(), flavours: flavours))
            large = try store.insert(ClipboardEntry(createdAt: Date(), flavours: [largeFlavour]))
            // A build before the fix indexed the escaped form and left the row
            // searchable only by its gibberish.
            for (id, indexed) in [(small.id, fedoraEscapedText), (large.id, escapedRun)] {
                let statement = try store.database.prepare("UPDATE search_fts SET text = ? WHERE rowid = ?")
                defer { statement.finalize() }
                try statement.bind(1, indexed)
                try statement.bind(2, id)
                try statement.run()
            }
            store.database.userVersion = 6
        }

        let reopened = try ClipboardStore(path: path)
        expectEqual(reopened.database.userVersion, ClipboardStore.currentSchemaVersion)
        expect(
            try reopened.entry(id: large.id)?.flavours.first?.isCompressed == true,
            "the large payload is stored compressed"
        )
        expectEqual(try reopened.search("何止", tabID: nil).map(\.id), [small.id], "the upgrade reindexes the decoded text")
        expectEqual(try reopened.search("何害", tabID: nil).map(\.id), [large.id], "the upgrade decodes the compressed payload")
        expectEqual(try reopened.search("u4f55", tabID: nil).count, 0)
        expectEqual(
            try reopened.entry(id: small.id)?.flavours.first { $0.type == PasteboardTypes.html }?.data,
            Data(fedoraHTML.utf8),
            "reindexing never touches the stored payload"
        )
    }
}
