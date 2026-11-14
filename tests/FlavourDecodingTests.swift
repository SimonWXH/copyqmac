// Flavour decoding: raw pasteboard bytes to previews and search text.

import Foundation

func registerFlavourDecodingTests() {
    TestRunner.add("decodes UTF-8 text") {
        let preview = FlavourDecoder.preview(for: [Fixtures.text("Hello clipboard")])
        expectEqual(preview.kind, .text)
        expectEqual(preview.text, "Hello clipboard")
        expectEqual(preview.searchText, "Hello clipboard")
    }

    TestRunner.add("decodes UTF-16 little-endian text when that is all there is") {
        let data = "Grüße 世界".data(using: .utf16LittleEndian)!
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.utf16Text, data: data)
        let preview = FlavourDecoder.preview(for: [flavour])
        expectEqual(preview.text, "Grüße 世界")
    }

    TestRunner.add("honours the byte-order mark for external UTF-16 text") {
        var data = Data([0xFF, 0xFE])  // little-endian BOM
        data.append("abc".data(using: .utf16LittleEndian)!)
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.utf16ExternalText, data: data)
        expectEqual(FlavourDecoder.preview(for: [flavour]).text, "abc")
    }

    TestRunner.add("prefers UTF-8 over legacy text flavours") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.legacyText, data: Data("old".utf8)),
            Fixtures.text("new"),
        ]
        expectEqual(FlavourDecoder.preview(for: flavours).text, "new")
    }

    TestRunner.add("extracts readable text from HTML") {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;<b>World</b></p><script>var x=1</script></body></html>"
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data(html.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])
        expectEqual(preview.kind, .html)
        expectEqual(preview.text, "Hello World")
    }

    TestRunner.add("extracts readable text from RTF") {
        let rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24 Hello \'e9t\'e9\par Second line}"#
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(rtf.utf8))
        let preview = FlavourDecoder.preview(for: [flavour])
        expectEqual(preview.kind, .rtf)
        expect(preview.text?.contains("Hello été") == true, "expected decoded accents, got \(String(describing: preview.text))")
    }

    TestRunner.add("prefers an accompanying text flavour over stripped HTML") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>rich</b>".utf8)),
            Fixtures.text("plain"),
        ]
        let preview = FlavourDecoder.preview(for: flavours)
        expectEqual(preview.text, "plain")
        // Still reports the richer kind so the UI can label it.
        expectEqual(preview.kind, .html)
    }

    TestRunner.add("decodes file URLs and their names") {
        let flavours = [
            Fixtures.fileURL("/Users/example/Documents/report.pdf", itemIndex: 0),
            Fixtures.fileURL("/Users/example/Pictures/holiday.png", itemIndex: 1),
        ]
        let preview = FlavourDecoder.preview(for: flavours)
        expectEqual(preview.kind, .files)
        expectEqual(preview.fileURLs.count, 2)
        expectEqual(preview.fileNames, ["report.pdf", "holiday.png"])
    }

    TestRunner.add("decodes legacy NSFilenamesPboardType plists") {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["/tmp/a.txt", "/tmp/b.txt"], format: .xml, options: 0
        )
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.legacyFilenames, data: plist)
        expectEqual(FlavourDecoder.preview(for: [flavour]).fileNames, ["a.txt", "b.txt"])
    }

    TestRunner.add("recognises images and reads their pixel size") {
        let flavour = Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)
        let preview = FlavourDecoder.preview(for: [flavour])
        expectEqual(preview.kind, .image)
        expectEqual(preview.imageType, PasteboardTypes.png)
        expectEqual(preview.imageData, Fixtures.pngData)
        expect(preview.text?.contains("1x1") == true, "expected dimensions in summary, got \(String(describing: preview.text))")
    }

    TestRunner.add("recognises decodable image flavours by UTI conformance") {
        let images: [(String, Data)] = [
            (PasteboardTypes.png, Fixtures.pngData),
            (PasteboardTypes.tiff, Fixtures.pngData),
            (PasteboardTypes.jpeg, Fixtures.pngData),
            (PasteboardTypes.heic, Fixtures.pngData),
            ("public.gif", Fixtures.gifData),
            ("com.compuserve.gif", Fixtures.gifData),
        ]
        for (type, data) in images {
            let flavour = Flavour(itemIndex: 0, type: type, data: data)
            let preview = FlavourDecoder.preview(for: [flavour])
            expectEqual(preview.kind, .image, "expected image preview for \(type)")
            expectEqual(preview.imageType, type)
            expectEqual(preview.imageData, data)
        }
    }

    TestRunner.add("ignores undecodable image flavours when choosing a preview") {
        let invalidImage = Flavour(itemIndex: 0, type: PasteboardTypes.jpeg, data: Data("not an image".utf8))
        let preview = FlavourDecoder.preview(for: [invalidImage, Fixtures.text("usable text")])
        expectEqual(preview.kind, .text)
        expectEqual(preview.text, "usable text")
    }

    TestRunner.add("prefers the image flavour over accompanying text") {
        let flavours = [
            Fixtures.text("caption"),
            Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
        ]
        expectEqual(FlavourDecoder.preview(for: flavours).kind, .image)
    }

    TestRunner.add("falls back to listing unknown types") {
        let flavour = Flavour(itemIndex: 0, type: "com.example.custom", data: Data([0x01]))
        let preview = FlavourDecoder.preview(for: [flavour])
        expectEqual(preview.kind, .other)
        expect(preview.text?.contains("com.example.custom") == true)
    }

    TestRunner.add("excerpts long text but keeps full search text") {
        let long = String(repeating: "a", count: 500)
        let preview = FlavourDecoder.preview(for: [Fixtures.text(long)])
        expectEqual(preview.text?.count, 203)  // 200 + "..."
        expectEqual(preview.searchText?.count, 500)
    }

    TestRunner.add("caps indexed search text at the configured limit") {
        let long = String(repeating: "b", count: FlavourDecoder.maxSearchTextLength + 100)
        let preview = FlavourDecoder.preview(for: [Fixtures.text(long)])
        expectEqual(FlavourDecoder.searchText(for: preview).count, FlavourDecoder.maxSearchTextLength)
    }

    TestRunner.add("prefers image/png, then bmp, jpeg, gif, then any image/* for display") {
        // PNG vs TIFF: PNG wins
        let pngAndTiff = [
            Flavour(itemIndex: 0, type: PasteboardTypes.tiff, data: Fixtures.pngData),
            Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
        ]
        expectEqual(FlavourDecoder.preview(for: pngAndTiff).imageType, PasteboardTypes.png)

        // BMP vs JPEG: BMP wins
        let bmpAndJpeg = [
            Flavour(itemIndex: 0, type: PasteboardTypes.jpeg, data: Fixtures.pngData),
            Flavour(itemIndex: 0, type: "com.microsoft.bmp", data: Fixtures.pngData),
        ]
        expectEqual(FlavourDecoder.preview(for: bmpAndJpeg).imageType, "com.microsoft.bmp")

        // JPEG vs GIF: JPEG wins
        let jpegAndGif = [
            Flavour(itemIndex: 0, type: "public.gif", data: Fixtures.gifData),
            Flavour(itemIndex: 0, type: PasteboardTypes.jpeg, data: Fixtures.pngData),
        ]
        expectEqual(FlavourDecoder.preview(for: jpegAndGif).imageType, PasteboardTypes.jpeg)

        // GIF vs TIFF: GIF wins
        let gifAndTiff = [
            Flavour(itemIndex: 0, type: PasteboardTypes.tiff, data: Fixtures.pngData),
            Flavour(itemIndex: 0, type: "public.gif", data: Fixtures.gifData),
        ]
        expectEqual(FlavourDecoder.preview(for: gifAndTiff).imageType, "public.gif")

        // None converted or dropped
        expectEqual(pngAndTiff.count, 2)
    }
}
