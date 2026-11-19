import AppKit
import Foundation

/// The pasteboard types AppKit declares for a file promise. They are documented
/// system types but have no Swift constant, so the names live here.
private enum PromiseTypes {
    static let promiseID = NSPasteboard.PasteboardType("com.apple.pasteboard.NSFilePromiseID")
    static let metaData = NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
    static let suggestedFileName = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")
    static let promisedContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
}

/// A real image the preview decoder accepts, encoded in the requested format.
private func encodedImage(_ type: NSBitmapImageRep.FileType) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    for y in 0..<2 {
        for x in 0..<2 {
            rep.setColor(NSColor.systemBlue, atX: x, y: y)
        }
    }
    return rep.representation(using: type, properties: [:]) ?? Data()
}

private func promiseItems(in pasteboard: NSPasteboard) -> [NSPasteboardItem] {
    (pasteboard.pasteboardItems ?? []).filter { $0.types.contains(PromiseTypes.promiseID) }
}

private func makeEntry(id: Int64, flavours: [Flavour]) -> ClipboardEntry {
    ClipboardEntry(id: id, createdAt: Date(), tabID: 1, flavours: flavours)
}

private func makeRow(id: Int64, kind: ClipboardContentKind) -> EntryRow {
    EntryRow(
        id: id,
        number: Int(id),
        kind: kind,
        primaryText: nil,
        richText: nil,
        fileNames: [],
        fileCount: 0,
        relativeTime: "just now",
        pinned: false,
        hasNote: false,
        icon: nil
    )
}

/// Runs the shipped drag-begin delegate callback against a stand-in session and
/// returns the pasteboard Finder would receive the drag on.
@MainActor
private func dragPasteboard(
    rows: [EntryRow],
    entries: [Int64: ClipboardEntry],
    rowIndexes: IndexSet
) -> NSPasteboard {
    let list = EntryListView(
        rows: rows,
        rowsRevision: 1,
        selection: SelectionState(),
        singleClickActivates: false,
        actions: EntryRowActions(entry: { entries[$0] }),
        contextActions: .none,
        onSelectionChange: { _ in },
        onActivate: { _ in },
        onCopy: { _ in },
        onFocusChange: { _ in },
        onRowBecameVisible: { _ in },
        banner: nil,
        onBannerAction: {},
        onBannerDismiss: {}
    )
    let coordinator = list.makeCoordinator()
    let table = EntryListView.makeTableView(coordinator: coordinator)
    coordinator.attach(to: table)
    let pasteboard = NSPasteboard(name: .init("copyqmac-file-promise-\(UUID().uuidString)"))
    let session = TestDraggingSession(pasteboard: pasteboard)
    coordinator.tableView(
        table,
        draggingSession: session,
        willBeginAt: .zero,
        forRowIndexes: rowIndexes
    )
    return pasteboard
}

func registerEntryFilePromiseTests() {
    TestRunner.currentSuite = "EntryFilePromise"

    // MARK: Text entries

    TestRunner.add("a text entry promises a txt file named after its first line") {
        let text = "Hello world\nthis is the body"
        guard let spec = EntryFilePromises.spec(for: [Fixtures.text(text)]) else {
            TestRunner.fail("a text entry must promise a file")
            return
        }
        expectEqual(spec.fileType, "public.plain-text")
        expectEqual(spec.fileName, "Hello world.txt")
        expectEqual(
            spec.payload,
            Data(text.utf8),
            "the whole text must reach the file, not only the naming line"
        )
    }

    TestRunner.add("a text entry with surrounding whitespace still names the file from its content") {
        guard let spec = EntryFilePromises.spec(for: [Fixtures.text("  report draft \nline two")]) else {
            TestRunner.fail("a text entry must promise a file")
            return
        }
        expectEqual(spec.fileName, "report draft.txt")
        expectEqual(spec.payload, Data("  report draft \nline two".utf8))
    }

    TestRunner.add("path separators in a first line become dashes") {
        expectEqual(EntryFilePromises.fileName(forText: "Q1/Q2: plan"), "Q1-Q2- plan.txt")
        expectEqual(EntryFilePromises.fileName(forText: "http://example.com/a"), "http---example.com-a.txt")
    }

    TestRunner.add("control characters are dropped from a first line") {
        expectEqual(EntryFilePromises.fileName(forText: "a\u{0}b\tc\nd rest"), "abc.txt")
    }

    TestRunner.add("surrounding spaces, dots, and dashes are trimmed from a first line") {
        expectEqual(EntryFilePromises.fileName(forText: "  .hidden.  \nbody"), "hidden.txt")
        expectEqual(EntryFilePromises.fileName(forText: "- bullet item\nbody"), "bullet item.txt")
    }

    TestRunner.add("only a newline break decides the first line") {
        expectEqual(EntryFilePromises.firstLine(of: "one\r\ntwo"), "one")
        expectEqual(EntryFilePromises.firstLine(of: "one\rtwo"), "one")
        expectEqual(EntryFilePromises.firstLine(of: "one\ntwo"), "one")
        expectEqual(EntryFilePromises.firstLine(of: "no break"), "no break")
    }

    TestRunner.add("a first line with nothing usable falls back to Text.txt") {
        expectEqual(EntryFilePromises.fileName(forText: ""), "Text.txt")
        expectEqual(EntryFilePromises.fileName(forText: "\nsecond line"), "Text.txt")
        expectEqual(EntryFilePromises.fileName(forText: "///:::\nbody"), "Text.txt")
        expectEqual(EntryFilePromises.fileName(forText: "   \nbody"), "Text.txt")

        guard let spec = EntryFilePromises.spec(for: [Fixtures.text("\nsecond line")]) else {
            TestRunner.fail("a text entry with an empty first line must still promise a file")
            return
        }
        expectEqual(spec.fileName, "Text.txt")
    }

    TestRunner.add("an overlength first line is truncated to a bounded stem") {
        let longLine = String(repeating: "a", count: 300)
        let name = EntryFilePromises.fileName(forText: longLine + "\nbody")
        expectEqual(name, String(repeating: "a", count: 80) + ".txt")

        // A wide script reaches the cap in fewer characters.
        let cjk = EntryFilePromises.fileName(forText: String(repeating: "好", count: 100))
        expectEqual(cjk.count, 80 + ".txt".count)
        expect(cjk.utf8.count <= 255, "the name must fit the file system's 255-byte limit")

        // Four-byte characters hit the byte cap before the character cap.
        let emoji = String(repeating: "😀", count: 100)
        let emojiStem = EntryFilePromises.sanitizedStem(emoji)
        expectEqual(emojiStem.count, 60)
        expectEqual(emojiStem.utf8.count, 240)
        expect(EntryFilePromises.fileName(forText: emoji).utf8.count <= 255)
    }

    TestRunner.add("rich text entries promise their plain text as a txt file") {
        let html = Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<b>Title</b> body".utf8))
        guard let spec = EntryFilePromises.spec(for: [html]) else {
            TestRunner.fail("an HTML entry must promise a text file")
            return
        }
        expectEqual(spec.fileType, "public.plain-text")
        expectEqual(spec.fileName, "Title body.txt")
        expectEqual(spec.payload, Data("Title body".utf8), "the file holds the stripped text, not the markup")

        let rtf = Flavour(
            itemIndex: 0,
            type: PasteboardTypes.rtf,
            data: Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24 Hello \'e9t\'e9\par Second line}"#.utf8)
        )
        guard let rtfSpec = EntryFilePromises.spec(for: [rtf]) else {
            TestRunner.fail("an RTF entry must promise a text file")
            return
        }
        // RTFText.strip collapses the \par break into a space, so the whole
        // stripped line names the file.
        expectEqual(rtfSpec.fileName, "Hello été Second line.txt")
    }

    // MARK: Image entries

    TestRunner.add("image promises keep their original format and bytes") {
        let formats: [(type: String, fileType: String, fileName: String, data: Data)] = [
            ("image/png", "public.png", "Image.png", Fixtures.pngData),
            ("image/jpeg", "public.jpeg", "Image.jpeg", encodedImage(.jpeg)),
            (PasteboardTypes.tiff, "public.tiff", "Image.tiff", encodedImage(.tiff)),
            ("image/gif", "com.compuserve.gif", "Image.gif", Fixtures.gifData),
            ("com.microsoft.bmp", "com.microsoft.bmp", "Image.bmp", encodedImage(.bmp)),
        ]
        for format in formats {
            guard let spec = EntryFilePromises.spec(for: [
                Flavour(itemIndex: 0, type: format.type, data: format.data),
            ]) else {
                TestRunner.fail("\(format.type) must promise a file")
                continue
            }
            expectEqual(spec.fileType, format.fileType, "\(format.type) promised UTI")
            expectEqual(spec.fileName, format.fileName, "\(format.type) promised name")
            expectEqual(
                spec.payload,
                format.data,
                "\(format.type) must write the stored bytes unchanged, never a re-encoding"
            )
        }
    }

    TestRunner.add("image type spellings map to the canonical UTI and extension") {
        let mappings: [(type: String, fileType: String, fileName: String)] = [
            ("image/png", "public.png", "Image.png"),
            ("public.png", "public.png", "Image.png"),
            ("image/jpeg", "public.jpeg", "Image.jpeg"),
            ("image/jpg", "public.jpeg", "Image.jpeg"),
            ("public.jpeg", "public.jpeg", "Image.jpeg"),
            ("image/tiff", "public.tiff", "Image.tiff"),
            ("public.tiff", "public.tiff", "Image.tiff"),
            ("image/heic", "public.heic", "Image.heic"),
            ("public.heic", "public.heic", "Image.heic"),
            ("image/gif", "com.compuserve.gif", "Image.gif"),
            ("public.gif", "com.compuserve.gif", "Image.gif"),
            ("com.compuserve.gif", "com.compuserve.gif", "Image.gif"),
            ("image/bmp", "com.microsoft.bmp", "Image.bmp"),
            ("com.microsoft.bmp", "com.microsoft.bmp", "Image.bmp"),
            ("IMAGE/PNG", "public.png", "Image.png"),
        ]
        for mapping in mappings {
            guard let spec = EntryFilePromises.imageFileSpec(forImageType: mapping.type) else {
                TestRunner.fail("\(mapping.type) must map to a file spec")
                continue
            }
            expectEqual(spec.fileType, mapping.fileType, "\(mapping.type) UTI")
            expectEqual(spec.fileName, mapping.fileName, "\(mapping.type) name")
        }
        expectNil(
            EntryFilePromises.imageFileSpec(forImageType: "com.example.not-an-image"),
            "a type with no extension must not promise a file"
        )
        expectNil(EntryFilePromises.imageFileSpec(forImageType: "com.adobe.pdf"))
    }

    TestRunner.add("an image entry that also carries text still promises the image") {
        let flavours = [
            Fixtures.text("a screenshot label"),
            Flavour(itemIndex: 0, type: "image/png", data: Fixtures.pngData),
        ]
        guard let spec = EntryFilePromises.spec(for: flavours) else {
            TestRunner.fail("an image entry must promise a file")
            return
        }
        expectEqual(spec.fileType, "public.png")
        expectEqual(spec.fileName, "Image.png")
        expectEqual(spec.payload, Fixtures.pngData)
    }

    TestRunner.add("the decodable image format the preview prefers is the one promised") {
        // `FlavourDecoder` ranks PNG ahead of JPEG, so an entry holding both
        // draws as a PNG and promises a PNG.
        let flavours = [
            Flavour(itemIndex: 0, type: "image/jpeg", data: encodedImage(.jpeg)),
            Flavour(itemIndex: 0, type: "image/png", data: Fixtures.pngData),
        ]
        guard let spec = EntryFilePromises.spec(for: flavours) else {
            TestRunner.fail("an image entry must promise a file")
            return
        }
        expectEqual(spec.fileType, "public.png")
        expectEqual(spec.payload, Fixtures.pngData)
    }

    // MARK: Entries with nothing to promise

    TestRunner.add("file, bookkeeping-only, and payload-less entries promise no file") {
        expectNil(
            EntryFilePromises.spec(for: [Fixtures.fileURL("/tmp/report.txt")]),
            "file entries already drag as public.file-url items"
        )
        expectNil(
            EntryFilePromises.spec(for: [
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("stem".utf8)),
            ]),
            "a bookkeeping-only entry has nothing a file could hold"
        )
        expectNil(EntryFilePromises.spec(for: []))
        expectNil(
            EntryFilePromises.spec(for: [
                Flavour(itemIndex: 0, type: "com.adobe.pdf", data: Data("%PDF-1.7".utf8)),
            ]),
            "a payload the app cannot name as a file must not promise one"
        )
    }

    // MARK: Delivery

    TestRunner.add("the promise delivers its stored bytes under the proposed name") {
        let text = "Promised 文本\nsecond line"
        let entry = makeEntry(id: 7, flavours: [Fixtures.text(text)])
        let providers = EntryFilePromises.providers(for: [entry])
        guard providers.count == 1, let provider = providers.first as? EntryFilePromiseProvider else {
            TestRunner.fail("a text entry must produce exactly one promise")
            return
        }
        expectEqual(provider.fileType, "public.plain-text")
        expect(
            (provider.delegate as AnyObject?) === provider,
            "the provider must be its own delegate so the payload lives as long as the promise"
        )
        expectEqual(
            provider.filePromiseProvider(provider, fileNameForType: provider.fileType),
            "Promised 文本.txt"
        )
        expectNotNil(provider.operationQueue(for: provider), "writes must run on an explicit queue")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("copyqmac-file-promise-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            TestRunner.fail("could not create a temporary directory: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("Promised 文本.txt")
        var completionCalled = false
        var completionError: Error?
        provider.filePromiseProvider(provider, writePromiseTo: url) { error in
            completionCalled = true
            completionError = error
        }
        expect(completionCalled, "the completion handler must be called")
        expectNil(completionError)
        expectEqual(try? Data(contentsOf: url), Data(text.utf8))
    }

    TestRunner.add("an image promise writes the original image bytes") {
        let entry = makeEntry(id: 8, flavours: [
            Flavour(itemIndex: 0, type: "image/jpeg", data: encodedImage(.jpeg)),
        ])
        let providers = EntryFilePromises.providers(for: [entry])
        guard providers.count == 1, let provider = providers.first as? EntryFilePromiseProvider else {
            TestRunner.fail("an image entry must produce exactly one promise")
            return
        }
        guard let spec = EntryFilePromises.spec(for: entry.flavours) else {
            TestRunner.fail("the image entry must have a spec")
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("copyqmac-file-promise-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            TestRunner.fail("could not create a temporary directory: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(spec.fileName)
        var completionError: Error?
        provider.filePromiseProvider(provider, writePromiseTo: url) { completionError = $0 }
        expectNil(completionError)
        expectEqual(try? Data(contentsOf: url), spec.payload)
    }

    // MARK: Drag session wiring

    TestRunner.add("a drag begin attaches a file promise beside the internal id and standard types") {
        MainActor.assumeIsolated {
            let text = "Hello world\nbody"
            let textEntry = makeEntry(id: 42, flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.mimeText, data: Data(text.utf8)),
            ])
            let imageEntry = makeEntry(id: 43, flavours: [
                Flavour(itemIndex: 0, type: "image/png", data: Fixtures.pngData),
            ])
            let pasteboard = dragPasteboard(
                rows: [makeRow(id: 42, kind: .text), makeRow(id: 43, kind: .image)],
                entries: [42: textEntry, 43: imageEntry],
                rowIndexes: IndexSet([0, 1])
            )

            let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
            expect(types.contains(PromiseTypes.promiseID.rawValue), "the promise item type must be declared")
            expect(types.contains(PromiseTypes.metaData.rawValue), "the promise metadata type must be declared")
            expect(
                types.contains(EntryDrag.identifier),
                "the internal drag type must survive so tab drops keep working"
            )
            expect(
                types.contains(PasteboardTypes.utf8Text),
                "the standard text representation must survive beside the promise"
            )

            let items = pasteboard.pasteboardItems ?? []
            expectEqual(items.count, 4, "two entry items plus one promise item each")
            expectEqual(items[0].string(forType: EntryDrag.pasteboardType), "42")
            expectEqual(items[1].string(forType: EntryDrag.pasteboardType), "43")
            expectEqual(pasteboard.string(forType: NSPasteboard.PasteboardType(PasteboardTypes.utf8Text)), text)

            let promises = promiseItems(in: pasteboard)
            expectEqual(promises.count, 2)
            expectEqual(
                promises.first?.string(forType: PromiseTypes.suggestedFileName),
                "Hello world.txt",
                "the text entry's proposal must be the first-line name"
            )
            expectEqual(
                promises.first?.string(forType: PromiseTypes.promisedContentType),
                "public.plain-text"
            )
            expectEqual(promises.count > 1 ? promises[1].string(forType: PromiseTypes.suggestedFileName) : nil, "Image.png")
            expectEqual(
                promises.count > 1 ? promises[1].string(forType: PromiseTypes.promisedContentType) : nil,
                "public.png",
                "the image promise must keep its own format"
            )
        }
    }

    TestRunner.add("a drag of file entries promises no file and keeps the file URL") {
        MainActor.assumeIsolated {
            let fileEntry = makeEntry(id: 44, flavours: [
                Flavour(itemIndex: 0, type: PasteboardTypes.mimeUriList, data: Data("file:///tmp/sample.txt\r\n".utf8)),
            ])
            let pasteboard = dragPasteboard(
                rows: [makeRow(id: 44, kind: .files)],
                entries: [44: fileEntry],
                rowIndexes: IndexSet(integer: 0)
            )
            let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
            expect(
                !types.contains(PromiseTypes.promiseID.rawValue),
                "a file entry must not promise a file; Finder already copies it from the URL"
            )
            expect(pasteboard.data(forType: NSPasteboard.PasteboardType(PasteboardTypes.fileURL)) != nil)
            expectEqual(pasteboard.pasteboardItems?.count, 1)
        }
    }

    TestRunner.add("a drag of an entry with no promiseable payload keeps its internal id") {
        MainActor.assumeIsolated {
            let bookkeepingOnly = makeEntry(id: 45, flavours: [
                Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("stem".utf8)),
            ])
            let pasteboard = dragPasteboard(
                rows: [makeRow(id: 45, kind: .other)],
                entries: [45: bookkeepingOnly],
                rowIndexes: IndexSet(integer: 0)
            )
            let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
            expect(!types.contains(PromiseTypes.promiseID.rawValue))
            expectEqual(pasteboard.pasteboardItems?.count, 1)
            expectEqual(pasteboard.pasteboardItems?.first?.string(forType: EntryDrag.pasteboardType), "45")
        }
    }
}
