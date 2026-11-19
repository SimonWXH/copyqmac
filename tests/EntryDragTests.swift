import AppKit
import Foundation

/// A real `NSDraggingSession` is only created by AppKit for a live drag, which
/// a headless suite cannot start. This subclass only supplies the pasteboard
/// the shipped delegate method writes through, so the delegate call itself is
/// exercised rather than its implementation being called directly.
private final class EntryDragTestSession: NSDraggingSession {
    /// The base class owns drag-session resources that it only disposes when it
    /// deinitializes. The suite keeps its stand-in sessions alive so teardown
    /// cannot try to dispose a session AppKit never created.
    private static var retained: [EntryDragTestSession] = []

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init()
        Self.retained.append(self)
    }

    override var draggingPasteboard: NSPasteboard { pasteboard }
}

func registerEntryDragTests() {
    TestRunner.currentSuite = "EntryDrag"

    @MainActor
    func makeRow(id: Int64, text: String? = nil, kind: ClipboardContentKind = .text) -> EntryRow {
        EntryRow(
            id: id,
            number: Int(id),
            kind: kind,
            primaryText: text,
            richText: nil,
            fileNames: [],
            fileCount: 0,
            relativeTime: "just now",
            pinned: false,
            hasNote: false,
            icon: nil
        )
    }

    TestRunner.add("dragging row writes standard utf8 text to pasteboard item for external apps") {
        MainActor.assumeIsolated {
            let entryID: Int64 = 42
            let text = "Hello from CopyQmac drag"
            let entry = ClipboardEntry(
                id: entryID,
                createdAt: Date(),
                tabID: 1,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.mimeText, data: Data(text.utf8))
                ]
            )
            let row = makeRow(id: entryID, text: text)
            let list = EntryListView(
                rows: [row],
                rowsRevision: 1,
                selection: SelectionState(),
                singleClickActivates: false,
                actions: EntryRowActions(entry: { id in id == entryID ? entry : nil }),
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

            guard let writer = coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem else {
                TestRunner.fail("pasteboardWriterForRow must return an NSPasteboardItem")
                return
            }

            expectEqual(
                writer.string(forType: EntryDrag.pasteboardType),
                "42",
                "internal id type must be preserved for internal drag"
            )
            expectEqual(
                writer.string(forType: NSPasteboard.PasteboardType(PasteboardTypes.utf8Text)),
                text,
                "standard utf8 plain text must be attached for external drag"
            )
        }
    }

    TestRunner.add("dragging image row attaches public.png to pasteboard item") {
        MainActor.assumeIsolated {
            let entryID: Int64 = 43
            let fakePngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let entry = ClipboardEntry(
                id: entryID,
                createdAt: Date(),
                tabID: 1,
                flavours: [
                    Flavour(itemIndex: 0, type: "image/png", data: fakePngData)
                ]
            )
            let row = makeRow(id: entryID, kind: .image)
            let list = EntryListView(
                rows: [row],
                rowsRevision: 1,
                selection: SelectionState(),
                singleClickActivates: false,
                actions: EntryRowActions(entry: { id in id == entryID ? entry : nil }),
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

            guard let writer = coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem else {
                TestRunner.fail("pasteboardWriterForRow must return an NSPasteboardItem")
                return
            }

            expectEqual(
                writer.string(forType: EntryDrag.pasteboardType),
                "43",
                "internal id type must be preserved"
            )
            expectEqual(
                writer.data(forType: NSPasteboard.PasteboardType(PasteboardTypes.png)),
                fakePngData,
                "standard public.png must be attached for external drag"
            )
        }
    }

    TestRunner.add("dragging file row attaches public.file-url to pasteboard item") {
        MainActor.assumeIsolated {
            let entryID: Int64 = 44
            let fileURI = "file:///tmp/sample.txt\r\n"
            let entry = ClipboardEntry(
                id: entryID,
                createdAt: Date(),
                tabID: 1,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.mimeUriList, data: Data(fileURI.utf8))
                ]
            )
            let row = makeRow(id: entryID, text: "sample.txt", kind: .files)
            let list = EntryListView(
                rows: [row],
                rowsRevision: 1,
                selection: SelectionState(),
                singleClickActivates: false,
                actions: EntryRowActions(entry: { id in id == entryID ? entry : nil }),
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

            guard let writer = coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem else {
                TestRunner.fail("pasteboardWriterForRow must return an NSPasteboardItem")
                return
            }

            expectEqual(
                writer.string(forType: EntryDrag.pasteboardType),
                "44",
                "internal id type must be preserved"
            )
            guard let fileURLData = writer.data(forType: NSPasteboard.PasteboardType(PasteboardTypes.fileURL)),
                  let urlString = String(data: fileURLData, encoding: .utf8)
            else {
                TestRunner.fail("public.file-url must be present and valid UTF-8")
                return
            }
            expectEqual(urlString, "file:///tmp/sample.txt")
        }
    }

    TestRunner.add("multi-selection drag attaches standard types to each dragged item") {
        MainActor.assumeIsolated {
            let entry1 = ClipboardEntry(
                id: 101,
                createdAt: Date(),
                tabID: 1,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("First item text".utf8))
                ]
            )
            let entry2 = ClipboardEntry(
                id: 102,
                createdAt: Date(),
                tabID: 1,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Second item text".utf8))
                ]
            )
            let rows = [
                makeRow(id: 101, text: "First item text"),
                makeRow(id: 102, text: "Second item text"),
            ]
            let entries: [Int64: ClipboardEntry] = [101: entry1, 102: entry2]
            let selection = SelectionState()
            selection.set(ids: [101, 102], focus: 101)
            let list = EntryListView(
                rows: rows,
                rowsRevision: 1,
                selection: selection,
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
            table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

            guard let writer0 = coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem else {
                TestRunner.fail("writer0 must be NSPasteboardItem")
                return
            }
            expectEqual(writer0.string(forType: EntryDrag.pasteboardType), "101")
            expectEqual(
                writer0.string(forType: NSPasteboard.PasteboardType(PasteboardTypes.utf8Text)),
                "First item text",
                "row 0 gets its own standard types"
            )

            guard let writer1 = coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSPasteboardItem else {
                TestRunner.fail("writer1 must be NSPasteboardItem")
                return
            }
            expectEqual(writer1.string(forType: EntryDrag.pasteboardType), "102")
            expectEqual(
                writer1.string(forType: NSPasteboard.PasteboardType(PasteboardTypes.utf8Text)),
                "Second item text",
                "row 1 gets its own standard types"
            )
        }
    }

    TestRunner.add("dragging row outside selection attaches its own standard types") {
        MainActor.assumeIsolated {
            let entry1 = ClipboardEntry(
                id: 101,
                createdAt: Date(),
                tabID: 1,
                flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Item 1".utf8))]
            )
            let entry2 = ClipboardEntry(
                id: 102,
                createdAt: Date(),
                tabID: 1,
                flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Item 2".utf8))]
            )
            let rows = [makeRow(id: 101, text: "Item 1"), makeRow(id: 102, text: "Item 2")]
            let entries: [Int64: ClipboardEntry] = [101: entry1, 102: entry2]
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
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            coordinator.attach(to: table)

            guard let writer1 = coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSPasteboardItem else {
                TestRunner.fail("writer1 must be NSPasteboardItem")
                return
            }
            expectEqual(writer1.string(forType: EntryDrag.pasteboardType), "102")
            expectEqual(
                writer1.string(forType: NSPasteboard.PasteboardType(PasteboardTypes.utf8Text)),
                "Item 2",
                "dragging unselected row attaches its own standard types"
            )
        }
    }

    TestRunner.add("dragging row when entry is unavailable still writes internal drag type") {
        MainActor.assumeIsolated {
            let row = makeRow(id: 999, text: "ghost")
            let list = EntryListView(
                rows: [row],
                rowsRevision: 1,
                selection: SelectionState(),
                singleClickActivates: false,
                actions: .none,
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

            guard let writer = coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem else {
                TestRunner.fail("writer must be NSPasteboardItem")
                return
            }
            expectEqual(writer.string(forType: EntryDrag.pasteboardType), "999")
            expectNil(writer.data(forType: NSPasteboard.PasteboardType(PasteboardTypes.utf8Text)))
        }
    }

    TestRunner.add("pasteboardWriterForRow returns nil for out of bounds row") {
        MainActor.assumeIsolated {
            let list = EntryListView(
                rows: [],
                rowsRevision: 1,
                selection: SelectionState(),
                singleClickActivates: false,
                actions: .none,
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

            expectNil(coordinator.tableView(table, pasteboardWriterForRow: 0))
            expectNil(coordinator.tableView(table, pasteboardWriterForRow: -1))
        }
    }

    TestRunner.add("the drag session delegate publishes standard types and the internal id") {
        MainActor.assumeIsolated {
            let entryID: Int64 = 45
            let text = "Delegate drag payload"
            let entry = ClipboardEntry(
                id: entryID,
                createdAt: Date(),
                tabID: 1,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.mimeText, data: Data(text.utf8))
                ]
            )
            let list = EntryListView(
                rows: [makeRow(id: entryID, text: text)],
                rowsRevision: 1,
                selection: SelectionState(),
                singleClickActivates: false,
                actions: EntryRowActions(entry: { id in id == entryID ? entry : nil }),
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
            expect(
                coordinator.responds(
                    to: NSSelectorFromString("tableView:draggingSession:willBeginAtPoint:forRowIndexes:")
                ),
                "the table delegate must expose the drag-begin callback AppKit invokes"
            )

            let pasteboard = NSPasteboard(name: .init("copyqmac-delegate-drag-\(UUID().uuidString)"))
            guard let writer = coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem else {
                TestRunner.fail("pasteboardWriterForRow must return an NSPasteboardItem")
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([writer])

            let session = EntryDragTestSession(pasteboard: pasteboard)
            coordinator.tableView(
                table,
                draggingSession: session,
                willBeginAt: .zero,
                forRowIndexes: IndexSet(integer: 0)
            )

            expectEqual(pasteboard.string(forType: .init(PasteboardTypes.utf8Text)), text)
            expectEqual(pasteboard.string(forType: EntryDrag.pasteboardType), String(entryID))
            // The entry's own item plus the file promise that lets Finder write
            // a real file; the promise must not duplicate or replace the item.
            expectEqual(pasteboard.pasteboardItems?.count, 2)
            expectEqual(
                pasteboard.pasteboardItems?.filter {
                    $0.types.map(\.rawValue).contains("com.apple.NSFilePromiseItemMetaData")
                }.count,
                1
            )
        }
    }

    TestRunner.add("paste-back restores non-standard stored flavour bytes without derived legacy types") {
        let pdfData = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])
        let webArchiveData = Data(repeating: 0x5A, count: 32)
        let htmlData = Data("<b>label</b>".utf8)
        let rtfData = Data(#"{\rtf1 label}"#.utf8)
        let fileURLData = Data("file:///tmp/label.txt".utf8)
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("label".utf8)),
            Flavour(itemIndex: 0, type: "com.adobe.pdf", data: pdfData),
            Flavour(itemIndex: 0, type: "com.apple.webarchive", data: webArchiveData),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: htmlData),
            Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: rtfData),
            Flavour(itemIndex: 0, type: PasteboardTypes.fileURL, data: fileURLData),
        ]
        let pboard = NSPasteboard(name: .init("copyqmac-pasteback-all-flavours-\(UUID().uuidString)"))
        PasteboardBridge.write(flavours, to: pboard)
        expectEqual(pboard.data(forType: .init("com.adobe.pdf")), pdfData)
        expectEqual(pboard.data(forType: .init("com.apple.webarchive")), webArchiveData)
        expectEqual(pboard.string(forType: .init(PasteboardTypes.utf8Text)), "label")
        expectEqual(pboard.data(forType: .init(PasteboardTypes.html)), htmlData)
        expectEqual(pboard.data(forType: .init(PasteboardTypes.rtf)), rtfData)
        expectEqual(pboard.data(forType: .init(PasteboardTypes.fileURL)), fileURLData)
        let types = Set(pboard.types?.map(\.rawValue) ?? [])
        expect(
            types.isSuperset(of: [
                PasteboardTypes.utf8Text, "com.adobe.pdf", "com.apple.webarchive",
                PasteboardTypes.html, PasteboardTypes.rtf, PasteboardTypes.fileURL,
            ]),
            "paste-back must preserve every stored flavour"
        )
        expectNil(pboard.data(forType: .init(PasteboardTypes.legacyHTML)))
        expectNil(pboard.data(forType: .init(PasteboardTypes.legacyRTF)))
    }

    TestRunner.add("write preserves non-allowlisted flavours during paste-back") {
        let pdfData = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])
        let webArchiveData = Data(repeating: 0x5A, count: 32)
        let rtfdData = Data("rtfd-archive-bytes".utf8)
        let webpData = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("plain".utf8)),
            Flavour(itemIndex: 0, type: "com.adobe.pdf", data: pdfData),
            Flavour(itemIndex: 0, type: "public.webarchive", data: webArchiveData),
            Flavour(itemIndex: 0, type: "public.rtfd", data: rtfdData),
            Flavour(itemIndex: 0, type: "public.webp", data: webpData),
        ]
        let pboard = NSPasteboard(name: .init("copyqmac-pasteback-non-allowlist-\(UUID().uuidString)"))
        PasteboardBridge.write(flavours, to: pboard)
        expectEqual(pboard.data(forType: .init("com.adobe.pdf")), pdfData)
        expectEqual(pboard.data(forType: .init("public.webarchive")), webArchiveData)
        expectEqual(pboard.data(forType: .init("public.rtfd")), rtfdData)
        expectEqual(pboard.data(forType: .init("public.webp")), webpData)
        expectEqual(pboard.string(forType: .init(PasteboardTypes.utf8Text)), "plain")
    }

    TestRunner.add("PasteboardBridge.pasteboardItems converts MIME flavours and strips bookkeeping") {
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.mimeText, data: Data("plain text".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.mimeHtml, data: Data("<b>bold</b>".utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.mimeRtf, data: Data("{\\rtf1 test}".utf8)),
            Flavour(itemIndex: 0, type: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47])),
            Flavour(itemIndex: 0, type: Fingerprint.syncBaseNameFlavour, data: Data("sync_123".utf8)),
        ]
        let items = PasteboardBridge.pasteboardItems(from: flavours)
        expectEqual(items.count, 1)
        let item = items[0]
        let types = Set(item.types.map(\.rawValue))
        expect(types.contains(PasteboardTypes.utf8Text), "utf8Text synthesised")
        expect(types.contains(PasteboardTypes.html), "html synthesised")
        expect(types.contains(PasteboardTypes.rtf), "rtf synthesised")
        expect(types.contains(PasteboardTypes.png), "png synthesised")
        expect(!types.contains(Fingerprint.syncBaseNameFlavour), "bookkeeping flavour excluded")
    }

    TestRunner.add("pasteboardItems preserves every legacy and MIME file URL") {
        let legacyPaths = ["/tmp/a.txt", "/tmp/b.txt"]
        let legacy = try! PropertyListSerialization.data(
            fromPropertyList: legacyPaths,
            format: .xml,
            options: 0
        )
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.legacyFilenames, data: legacy),
            Flavour(itemIndex: 1, type: PasteboardTypes.mimeUriList, data: Data("file:///tmp/c.txt\r\nfile:///tmp/d.txt\r\n".utf8)),
            Flavour(itemIndex: 2, type: PasteboardTypes.fileURL, data: Data("file:///tmp/e.txt".utf8)),
            Flavour(itemIndex: 3, type: PasteboardTypes.fileURL, data: Data("file:///tmp/f.txt".utf8)),
        ]
        let pboard = NSPasteboard(name: .init("copyqmac-file-items-\(UUID().uuidString)"))
        PasteboardBridge.write(flavours, to: pboard)
        let snapshot = PasteboardBridge.snapshot(of: pboard)
        let urls = FlavourDecoder.fileURLs(from: snapshot) ?? []
        expectEqual(urls.map(\.path), legacyPaths + ["/tmp/c.txt", "/tmp/d.txt", "/tmp/e.txt", "/tmp/f.txt"])
    }

    TestRunner.add("derived file URLs do not duplicate native URLs across items") {
        let shared = ["/tmp/shared-a.txt", "/tmp/shared-b.txt"]
        let legacy = try! PropertyListSerialization.data(
            fromPropertyList: shared,
            format: .xml,
            options: 0
        )
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.legacyFilenames, data: legacy),
            Flavour(itemIndex: 0, type: PasteboardTypes.fileURL, data: Data("file:///tmp/shared-a.txt".utf8)),
            Flavour(itemIndex: 1, type: PasteboardTypes.fileURL, data: Data("file:///tmp/shared-b.txt\r\n".utf8)),
        ]

        let pboard = NSPasteboard(name: .init("copyqmac-file-dedupe-\(UUID().uuidString)"))
        PasteboardBridge.write(flavours, to: pboard)
        let snapshot = PasteboardBridge.snapshot(of: pboard)
        expectEqual((FlavourDecoder.fileURLs(from: snapshot) ?? []).map(\.path), shared)
        expectEqual(snapshot.filter { $0.type == PasteboardTypes.fileURL }.count, 2)

        let dragPboard = NSPasteboard(name: .init("copyqmac-file-drag-dedupe-\(UUID().uuidString)"))
        PasteboardBridge.writeDragData(
            for: [ClipboardEntry(id: 77, createdAt: Date(), flavours: flavours)],
            to: dragPboard
        )
        let dragSnapshot = PasteboardBridge.snapshot(of: dragPboard)
        expectEqual((FlavourDecoder.fileURLs(from: dragSnapshot) ?? []).map(\.path), shared)
        expectEqual(dragSnapshot.filter { $0.type == PasteboardTypes.fileURL }.count, 2)

        let nativeData = Data("file:///tmp/native.txt\r\n".utf8)
        let legacyURLs = Data("file:///tmp/native.txt\r\nfile:///tmp/other.txt\r\n".utf8)
        let item = NSPasteboardItem()
        PasteboardBridge.attachDragTypes(from: [
            Flavour(itemIndex: 0, type: PasteboardTypes.mimeUriList, data: legacyURLs),
            Flavour(itemIndex: 1, type: PasteboardTypes.fileURL, data: nativeData),
        ], to: item)
        expectEqual(item.data(forType: .init(PasteboardTypes.fileURL)), nativeData)
        expectNil(item.data(forType: .init(PasteboardTypes.utf8Text)))
    }

    TestRunner.add("a multi-file drag produces separate file items and legacy filenames on the drag pasteboard") {
        MainActor.assumeIsolated {
            let legacyPaths = ["/tmp/a.txt", "/tmp/b.txt"]
            let legacy = try! PropertyListSerialization.data(
                fromPropertyList: legacyPaths,
                format: .xml,
                options: 0
            )
            let entries: [Int64: ClipboardEntry] = [
                1: ClipboardEntry(
                    id: 1,
                    createdAt: Date(),
                    flavours: [Flavour(itemIndex: 0, type: PasteboardTypes.legacyFilenames, data: legacy)]
                ),
                2: ClipboardEntry(
                    id: 2,
                    createdAt: Date(),
                    flavours: [
                        Flavour(itemIndex: 0, type: PasteboardTypes.mimeUriList, data: Data("file:///tmp/c.txt\r\nfile:///tmp/d.txt\r\n".utf8))
                    ]
                ),
            ]
            let list = EntryListView(
                rows: [makeRow(id: 1), makeRow(id: 2)],
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

            let pboard = NSPasteboard(name: .init("copyqmac-drag-test-\(UUID().uuidString)"))
            coordinator.writeDragData(forRowIndexes: IndexSet([0, 1]), to: pboard)

            let snapshot = PasteboardBridge.snapshot(of: pboard)
            let urls = FlavourDecoder.fileURLs(from: snapshot) ?? []
            expectEqual(urls.map(\.path), ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt", "/tmp/d.txt"])

            let filenames = pboard.propertyList(forType: .init(PasteboardTypes.legacyFilenames)) as? [String]
            expectEqual(filenames, ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt", "/tmp/d.txt"])

            guard let items = pboard.pasteboardItems, items.count == 4 else {
                TestRunner.fail("drag pasteboard must have 4 separate items for the 4 files")
                return
            }
            expectEqual(items[0].string(forType: EntryDrag.pasteboardType), "1")
            expectEqual(items[2].string(forType: EntryDrag.pasteboardType), "2")
        }
    }

    TestRunner.add("drag derivation supports legacy HTML and RTF representations") {
        let htmlContent = "<b>legacy html</b>"
        let rtfContent = "{\\rtf1 legacy rtf}"
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.legacyHTML, data: Data(htmlContent.utf8)),
            Flavour(itemIndex: 0, type: PasteboardTypes.legacyRTF, data: Data(rtfContent.utf8)),
        ]
        let item = NSPasteboardItem()
        PasteboardBridge.attachDragTypes(from: flavours, to: item)
        expectEqual(item.string(forType: .html), htmlContent)
        expectEqual(item.string(forType: .rtf), rtfContent)

        let pboard = NSPasteboard(name: .init("copyqmac-legacy-rich-\(UUID().uuidString)"))
        let entry = ClipboardEntry(id: 42, createdAt: Date(), flavours: flavours)
        PasteboardBridge.writeDragData(for: [entry], to: pboard)
        expectEqual(pboard.string(forType: .html), htmlContent)
        expectEqual(pboard.string(forType: .rtf), rtfContent)
        expectEqual(pboard.data(forType: .init(PasteboardTypes.legacyHTML)), Data(htmlContent.utf8))
        expectEqual(pboard.data(forType: .rtf), Data(rtfContent.utf8))
    }

    TestRunner.add("drag legacy rich text comes from the first item only") {
        let laterHTML = "<i>later html</i>"
        let otherRTF = "{\\rtf1 other rtf}"
        let entries = [
            ClipboardEntry(
                id: 1,
                createdAt: Date(),
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("first".utf8)),
                    Flavour(itemIndex: 1, type: PasteboardTypes.html, data: Data(laterHTML.utf8)),
                ]
            ),
            ClipboardEntry(
                id: 2,
                createdAt: Date(),
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("second".utf8)),
                    Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data(otherRTF.utf8)),
                ]
            ),
        ]
        let pboard = NSPasteboard(name: .init("copyqmac-drag-rich-items-\(UUID().uuidString)"))
        PasteboardBridge.writeDragData(for: entries, to: pboard)
        let items = pboard.pasteboardItems ?? []
        expectEqual(items.count, 3)
        expectEqual(items[0].string(forType: .string), "first")
        expectNil(
            pboard.data(forType: .init(PasteboardTypes.legacyHTML)),
            "the first item must not inherit a later item's HTML"
        )
        expectNil(
            pboard.data(forType: .init(PasteboardTypes.legacyRTF)),
            "the first item must not inherit another entry's RTF"
        )
        expectEqual(items[1].data(forType: .init(PasteboardTypes.html)), Data(laterHTML.utf8))
        expectEqual(items[2].data(forType: .init(PasteboardTypes.rtf)), Data(otherRTF.utf8))
    }

    TestRunner.add("drag derivation preserves non-PNG image formats (JPEG, TIFF, GIF, HEIC)") {
        let formats: [(String, String, Data)] = [
            ("image/jpeg", PasteboardTypes.jpeg, Data([0xFF, 0xD8, 0xFF, 0xE0])),
            ("image/tiff", PasteboardTypes.tiff, Data([0x49, 0x49, 0x2A, 0x00])),
            ("image/gif", "com.compuserve.gif", Data([0x47, 0x49, 0x46, 0x38])),
            ("image/heic", PasteboardTypes.heic, Data([0x00, 0x00, 0x00, 0x18])),
        ]
        for (mime, expectedType, sampleBytes) in formats {
            let flavours = [Flavour(itemIndex: 0, type: mime, data: sampleBytes)]
            let item = NSPasteboardItem()
            PasteboardBridge.attachDragTypes(from: flavours, to: item)
            expectEqual(
                item.data(forType: .init(expectedType)),
                sampleBytes,
                "\(mime) must map to native type \(expectedType)"
            )
        }
    }

    TestRunner.add("drag derivation ignores non-standard stored payloads") {
        let data = Data(repeating: 0x41, count: 1_000_000)
        guard let raw = QtCompression.compress(data) else {
            TestRunner.fail("could not compress payload")
            return
        }
        let customType = "com.example.custom-payload"
        let flavours = [
            Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("visible".utf8)),
            Flavour(itemIndex: 0, type: customType, rawData: raw, isCompressed: true),
        ]
        let item = NSPasteboardItem()
        PasteboardBridge.attachDragTypes(from: flavours, to: item)
        expectEqual(item.string(forType: .string), "visible")
        expectNil(
            item.data(forType: NSPasteboard.PasteboardType(customType)),
            "non-standard payloads must not be materialised for a drag"
        )

        let pboard = NSPasteboard(name: .init("copyqmac-drag-containment-\(UUID().uuidString)"))
        let entry = ClipboardEntry(id: 1, createdAt: Date(), flavours: flavours)
        PasteboardBridge.writeDragData(for: [entry], to: pboard)
        expectEqual(pboard.string(forType: .string), "visible")
        expectNil(
            pboard.data(forType: NSPasteboard.PasteboardType(customType)),
            "non-standard payloads must not reach the drag pasteboard"
        )
    }
}
