import AppKit
import Foundation

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

    TestRunner.add("multi-selection drag places standard types only on the drag leader item") {
        MainActor.assumeIsolated {
            let entry1 = ClipboardEntry(
                id: 101,
                createdAt: Date(),
                tabID: 1,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Leader text".utf8))
                ]
            )
            let entry2 = ClipboardEntry(
                id: 102,
                createdAt: Date(),
                tabID: 1,
                flavours: [
                    Flavour(itemIndex: 0, type: PasteboardTypes.utf8Text, data: Data("Follower text".utf8))
                ]
            )
            let rows = [
                makeRow(id: 101, text: "Leader text"),
                makeRow(id: 102, text: "Follower text"),
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

            // Row 0 is the drag leader (first row in selection)
            guard let writer0 = coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem else {
                TestRunner.fail("writer0 must be NSPasteboardItem")
                return
            }
            expectEqual(writer0.string(forType: EntryDrag.pasteboardType), "101")
            expectEqual(
                writer0.string(forType: NSPasteboard.PasteboardType(PasteboardTypes.utf8Text)),
                "Leader text",
                "drag leader gets standard types"
            )

            // Row 1 is a follower
            guard let writer1 = coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSPasteboardItem else {
                TestRunner.fail("writer1 must be NSPasteboardItem")
                return
            }
            expectEqual(writer1.string(forType: EntryDrag.pasteboardType), "102")
            expectNil(
                writer1.data(forType: NSPasteboard.PasteboardType(PasteboardTypes.utf8Text)),
                "follower items must not duplicate standard types on their pasteboard items"
            )
        }
    }

    TestRunner.add("dragging row outside selection acts as single-item drag leader") {
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
            // Table selection is row 0, but user drags row 1
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
                "dragging unselected row makes it its own drag leader"
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
}
