// Editing an entry's text and creating an item by hand.

import AppKit
import Foundation

func registerEntryTextEditingTests() {
    func encoded(_ string: String, as type: String) -> Data {
        switch type {
        case PasteboardTypes.utf16Text:
            return string.data(using: .utf16LittleEndian) ?? Data(string.utf8)
        case PasteboardTypes.utf16ExternalText:
            return string.data(using: .utf16) ?? Data(string.utf8)
        default:
            return Data(string.utf8)
        }
    }

    func text(_ string: String, type: String = PasteboardTypes.utf8Text, itemIndex: Int = 0) -> Flavour {
        Flavour(itemIndex: itemIndex, type: type, data: encoded(string, as: type))
    }

    // MARK: - Flavour rewriting

    TestRunner.add("editing text replaces plain flavours and drops stale rich text") {
        let plainTypes = [
            PasteboardTypes.utf8Text,
            PasteboardTypes.utf16Text,
            PasteboardTypes.utf16ExternalText,
            PasteboardTypes.plainText,
            PasteboardTypes.legacyText,
        ]
        var flavours = plainTypes.map { text("old text", type: $0) }
        flavours.append(Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>old text</p>".utf8)))
        flavours.append(Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data("{\\rtf1\\ansi old text}".utf8)))
        let entry = ClipboardEntry(createdAt: Date(), flavours: flavours)
        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: "new text")
        expectEqual(FlavourDecoder.storedPlainText(from: updated), "new text")
        expectNil(updated.first { $0.type == PasteboardTypes.html }, "stale HTML must be dropped")
        expectNil(updated.first { $0.type == PasteboardTypes.rtf }, "stale RTF must be dropped")
        expectNil(updated.first { $0.type == PasteboardTypes.legacyHTML }, "stale legacy HTML must be dropped")
        expectNil(updated.first { $0.type == PasteboardTypes.legacyRTF }, "stale legacy RTF must be dropped")

        for type in plainTypes {
            let flavour = updated.first { $0.type == type }
            expectNotNil(flavour, "\(type) must be rewritten, not dropped")
            expectEqual(
                flavour.flatMap { FlavourDecoder.decodeText(type: $0.type, data: $0.data) },
                "new text",
                "\(type) must carry the new text"
            )
        }
    }

    TestRunner.add("images and file URLs survive an edit while other payloads are dropped") {
        let png = Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)
        let unknown = Flavour(itemIndex: 1, type: "com.example.custom", data: Data([0x00, 0xFF, 0x10]))
        let file = Fixtures.fileURL("/tmp/report.pdf", itemIndex: 1)
        let legacyFiles = Flavour(itemIndex: 1, type: PasteboardTypes.legacyFilenames, data: Data([0x01]))
        let entry = ClipboardEntry(createdAt: Date(), flavours: [text("before"), png, file, legacyFiles, unknown])

        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: "after")
        expectEqual(updated.first { $0.type == PasteboardTypes.png }?.data, Fixtures.pngData)
        expectEqual(updated.first { $0.type == PasteboardTypes.fileURL }?.data, file.data)
        expectEqual(updated.first { $0.type == PasteboardTypes.legacyFilenames }?.data, legacyFiles.data)
        expectNil(updated.first { $0.type == unknown.type }, "a non-image attachment is dropped")
        expectEqual(FlavourDecoder.storedPlainText(from: updated), "after")
    }

    TestRunner.add("a no-op save keeps rich text and every flavour untouched") {
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            text("same"),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>same</p>".utf8)),
        ])
        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: "same")
        expectEqual(Set(updated), Set(entry.flavours))
    }

    TestRunner.add("a URL-only item seeds from its full preview text and gains plain text") {
        let url = "https://example.com/" + String(repeating: "segment/", count: 40)
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.url, data: Data(url.utf8)),
        ])
        let seed = EntryTextEditing.seed(for: entry)
        expectEqual(seed.isPreviewFallback, true)
        expectEqual(seed.text, url)

        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: seed.text)
        expectEqual(FlavourDecoder.storedPlainText(from: updated), url)
        expectEqual(
            updated.first { $0.type == PasteboardTypes.url }?.data,
            Data(url.utf8),
            "an unchanged save keeps the matching URL"
        )
    }

    TestRunner.add("a non-text item seeds empty instead of its type-name summary") {
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            Flavour(itemIndex: 0, type: "com.example.custom", data: Data([0x00, 0xFF, 0x10])),
        ])
        let preview = FlavourDecoder.preview(for: entry.flavours)
        expectEqual(preview.kind, .other)
        expectEqual(preview.text, "com.example.custom", "the preview shows the type summary")

        let seed = EntryTextEditing.seed(for: entry)
        expectEqual(seed.isPreviewFallback, true)
        expectEqual(seed.text, "", "the type-name summary is not editable text")
        expectEqual(EntryTextEditing.supportsTextEditing(entry), true)

        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: "caption")
        expectEqual(FlavourDecoder.storedPlainText(from: updated), "caption")
        expectNil(updated.first { $0.type == "com.example.custom" }, "the old payload is replaced by the text")
    }

    TestRunner.add("an empty stored text seed falls back to visible rich text") {
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            text(""),
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>visible html</p>".utf8)),
        ])
        let preview = FlavourDecoder.preview(for: entry.flavours)
        expectEqual(preview.kind, .html)
        expectEqual(FlavourDecoder.storedPlainText(from: entry.flavours), "", "the stored text flavour is empty")

        let seed = EntryTextEditing.seed(for: entry)
        expectEqual(seed.isPreviewFallback, true)
        expectEqual(seed.text, "visible html", "the editor shows the text the row shows")

        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: "new text")
        expectNil(updated.first { $0.type == PasteboardTypes.html }, "the old HTML must be dropped")
        expectEqual(FlavourDecoder.storedPlainText(from: updated), "new text")
    }

    TestRunner.add("saving unchanged rich text does not mark the entry locally edited") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let entry = try history.store.insert(ClipboardEntry(createdAt: Date(), flavours: [
            Flavour(itemIndex: 0, type: PasteboardTypes.html, data: Data("<p>visible html</p>".utf8)),
        ]))
        let seed = EntryTextEditing.seed(for: entry)
        expectEqual(seed.text, "visible html")
        expectEqual(seed.isPreviewFallback, true)

        let result = try history.replaceText(of: entry.id, with: seed.text)
        expectEqual(result?.flavours ?? [], entry.flavours)
        expectEqual(try history.store.isEntryLocallyEdited(id: entry.id), false)

        _ = try history.replaceText(of: entry.id, with: "  \(seed.text)  ")
        expectEqual(try history.store.isEntryLocallyEdited(id: entry.id), false)
        expectEqual(try history.store.entry(id: entry.id)?.flavours ?? [], entry.flavours)

        _ = try history.replaceText(of: entry.id, with: "changed")
        expectEqual(try history.store.isEntryLocallyEdited(id: entry.id), true)
    }

    TestRunner.add("a long rich-text-only entry seeds and saves its full text, not the preview excerpt") {
        let fullText = String(repeating: "rich ", count: 60).trimmingCharacters(in: .whitespaces)
        let rtf = Flavour(itemIndex: 0, type: PasteboardTypes.rtf, data: Data("{\\rtf1\\ansi \(fullText)}".utf8))
        let entry = ClipboardEntry(createdAt: Date(), flavours: [rtf])

        let preview = FlavourDecoder.preview(for: entry.flavours)
        expectEqual(preview.text, FlavourDecoder.excerpt(fullText), "the preview is truncated")
        expect(preview.text?.hasSuffix("...") == true, "the preview excerpt is visibly shortened")

        let seed = EntryTextEditing.seed(for: entry)
        expectEqual(seed.isPreviewFallback, true)
        expectEqual(seed.text, fullText, "the editor must open with the full text")

        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: seed.text)
        expectEqual(FlavourDecoder.storedPlainText(from: updated), fullText)
        expectEqual(updated.first { $0.type == PasteboardTypes.rtf }, rtf, "an unchanged save keeps the rich text")
        expectEqual(preview.searchText, fullText)
    }

    TestRunner.add("editing keeps the itemsync base-name bookkeeping flavour") {
        let baseName = Flavour(
            itemIndex: 0,
            type: Fingerprint.syncBaseNameFlavour,
            data: Data("copyq_custom".utf8)
        )
        let entry = ClipboardEntry(createdAt: Date(), flavours: [text("before"), baseName])
        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: "after")
        expectEqual(updated.first { $0.type == Fingerprint.syncBaseNameFlavour }?.data, baseName.data)
        expectEqual(FlavourDecoder.storedPlainText(from: updated), "after")
    }

    TestRunner.add("editing keeps only image and file-URL payloads") {
        let png = Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)
        let svg = Flavour(itemIndex: 0, type: "image/svg+xml", data: Data("<svg/>".utf8))
        let file = Fixtures.fileURL("/tmp/report.pdf")
        let unknown = Flavour(itemIndex: 0, type: "com.example.custom", data: Data([0x00, 0xFF, 0x10]))
        let staleTypes = [
            PasteboardTypes.html,
            PasteboardTypes.legacyHTML,
            PasteboardTypes.rtf,
            PasteboardTypes.legacyRTF,
            "com.apple.flat-rtfd",
            PasteboardTypes.url,
            "public.url-name",
            "public.text",
            "public.vcard",
            "application/rtf",
            "application/x-rtf",
            "application/rtfd",
            "application/x-rtfd",
            "text/rtf",
            "text/uri-list",
            "text/xml",
            "text/csv",
            "application/json",
            "application/xhtml+xml",
        ]
        var flavours = [text("old text"), png, svg, file, unknown]
        flavours += staleTypes.map { Flavour(itemIndex: 0, type: $0, data: Data("old text".utf8)) }
        let entry = ClipboardEntry(createdAt: Date(), flavours: flavours)

        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: "new text")
        for type in staleTypes {
            expectNil(updated.first { $0.type == type }, "\(type) describes the old text and must be dropped")
        }
        expectEqual(FlavourDecoder.storedPlainText(from: updated), "new text")
        expectEqual(updated.first { $0.type == PasteboardTypes.png }?.data, Fixtures.pngData)
        expectEqual(updated.first { $0.type == "image/svg+xml" }?.data, svg.data, "a text-conforming image stays")
        expectEqual(updated.first { $0.type == PasteboardTypes.fileURL }?.data, file.data)
        expectNil(updated.first { $0.type == "com.example.custom" }, "an unknown attachment is dropped")
    }

    TestRunner.add("editing an RTFD entry pastes only the new text") {
        let entry = ClipboardEntry(createdAt: Date(), flavours: [
            text("old text"),
            Flavour(itemIndex: 0, type: "com.apple.flat-rtfd", data: Data([0x00, 0x01, 0x02])),
        ])
        let updated = try EntryTextEditing.updatedFlavours(for: entry, text: "new text")
        expectNil(updated.first { $0.type == "com.apple.flat-rtfd" }, "RTFD must be dropped")

        let pasteboard = NSPasteboard(name: .init("copyqmac-rtfd-edit-\(UUID().uuidString)"))
        pasteboard.declareTypes([], owner: nil)
        PasteboardBridge.write(updated, to: pasteboard)
        let pasted = PasteboardBridge.snapshot(of: pasteboard)
        expectNil(pasted.first { $0.type == "com.apple.flat-rtfd" }, "the old RTFD must not paste")
        expectEqual(pasted.first { $0.type == PasteboardTypes.utf8Text }?.data, Data("new text".utf8))
    }

    TestRunner.add("empty and whitespace-only text is rejected by both entry points") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let tab = try history.defaultTab()
        let entry = try history.store.insert(
            ClipboardEntry(createdAt: Date(), flavours: [Fixtures.text("keep")])
        )
        expectThrows { _ = try EntryTextEditing.updatedFlavours(for: entry, text: "   \n\t") }
        expectThrows { _ = try history.addItem(withText: "   ", in: tab) }
        expectThrows { _ = try history.replaceText(of: entry.id, with: "\n") }
        // A rejected edit must not leave a half-written entry behind.
        let loaded = try history.store.entry(id: entry.id)
        expectEqual(loaded?.fingerprint, entry.fingerprint)
        expectEqual(try history.store.count(tabID: tab.id), 1)
    }

    // MARK: - Store integration

    TestRunner.add("editing an entry keeps its tab, time, note, and reindexes search") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let tab = try history.defaultTab()
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        let outcome = try history.record([Fixtures.text("original token")], at: date)
        guard case .inserted(let entry) = outcome else {
            TestRunner.fail("fixture entry was not inserted")
            return
        }
        try history.store.setNote(id: entry.id, note: "kept note")
        let before = try history.store.entry(id: entry.id)
        expectNotNil(before)

        let after = try history.replaceText(of: entry.id, with: "replacement token")
        expectNotNil(after)
        guard let after, let before else { return }
        expectEqual(after.id, entry.id)
        expectEqual(after.tabID, tab.id)
        expectEqual(after.createdAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        expectEqual(after.note, "kept note")
        expectNotEqual(after.fingerprint, before.fingerprint)
        expectEqual(try history.search("replacement token").count, 1)
        expectEqual(try history.search("original token").count, 0)
    }

    TestRunner.add("editing an entry keeps its image and reindexes the text") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let entry = try history.store.insert(
            ClipboardEntry(
                createdAt: Date(),
                flavours: [
                    Fixtures.text("captioned image"),
                    Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
                ]
            )
        )
        let updated = try history.replaceText(of: entry.id, with: "new caption")
        expectNotNil(updated)
        expectEqual(updated?.flavours.first { $0.type == PasteboardTypes.png }?.data, Fixtures.pngData)
        expectEqual(FlavourDecoder.storedPlainText(from: updated?.flavours ?? []), "new caption")
        expectEqual(try history.search("new caption").count, 1, "the search row is rebuilt from the new flavours")
    }

    TestRunner.add("the indexed text stays bounded when stored text is added to a preview") {
        let long = String(repeating: "x", count: FlavourDecoder.maxSearchTextLength + 100)
        let preview = EntryPreview(kind: .image, text: "Image 1x1 (png)", searchText: "Image 1x1 (png)")
        let blob = ClipboardStore.searchBlob(preview: preview, note: "", storedText: long)
        expectEqual(blob.count, FlavourDecoder.maxSearchTextLength)
        let withNote = ClipboardStore.searchBlob(preview: preview, note: "a note", storedText: long)
        expect(withNote.count <= FlavourDecoder.maxSearchTextLength, "content plus note must stay bounded")
        expect(withNote.hasSuffix("a note"))
    }

    // MARK: - App model and menus

    TestRunner.add("Edit Item is unavailable for image and file entries") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})
                let menu = MainMenuBuilder.build(actions: actions)
                guard let itemMenu = menu.items.first(where: { $0.title == "Item" })?.submenu,
                      let editItem = itemMenu.items.first(where: { $0.action == #selector(AppActions.editItem(_:)) })
                else {
                    TestRunner.fail("Edit Item must be in the Item menu")
                    return
                }

                var ids: [Int64] = []
                for flavours in [
                    [Fixtures.text("captioned"), Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)],
                    [Fixtures.fileURL("/tmp/report.pdf")],
                    [Fixtures.text("editable")],
                ] {
                    guard case .inserted(let entry) = try history.record(flavours) else {
                        TestRunner.fail("fixture entry was not inserted")
                        return
                    }
                    ids.append(entry.id)
                }
                model.reload()

                model.select(ids[0])
                expectEqual(actions.validateMenuItem(editItem), false, "an image entry has no text to edit")
                expectEqual(editItem.title, "Edit Item\u{2026} (Use Edit Note)", "the menu must explain where to describe it")
                model.requestEditSelectedEntry()
                expectNil(model.pendingTextEdit, "no editor may open for an image entry")
                expectEqual(model.notice, EntryTextEditingError.unsupportedKind.message)

                model.select(ids[1])
                expectEqual(actions.validateMenuItem(editItem), false, "a file entry has no text to edit")
                expectEqual(editItem.title, "Edit Item\u{2026} (Use Edit Note)")

                model.select(ids[2])
                expectEqual(actions.validateMenuItem(editItem), true, "a text entry stays editable")
                expectEqual(editItem.title, "Edit Item\u{2026}")
                model.requestEditSelectedEntry()
                expectEqual(model.pendingTextEdit?.text, "editable")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an open editor sheet locks item and tab commands") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let firstTabID = model.selectedTabID
                guard case .inserted(let entry) = try history.record([Fixtures.text("locked target")]) else {
                    TestRunner.fail("fixture entry was not inserted")
                    return
                }
                guard let secondTab = model.addTab(named: "Second") else {
                    TestRunner.fail("second tab was not created")
                    return
                }
                model.selectTab(firstTabID)
                model.reload()
                model.select(entry.id)

                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})
                let menu = MainMenuBuilder.build(actions: actions)
                func find(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
                    for item in menu.items {
                        if item.action == action { return item }
                        if let submenu = item.submenu, let found = find(action, in: submenu) { return found }
                    }
                    return nil
                }
                guard let newItem = find(#selector(AppActions.newItem(_:)), in: menu),
                      let editItem = find(#selector(AppActions.editItem(_:)), in: menu),
                      let remove = find(#selector(AppActions.removeSelected(_:)), in: menu),
                      let clearTab = find(#selector(AppActions.clearTab(_:)), in: menu),
                      let removeTab = find(#selector(AppActions.removeTab(_:)), in: menu),
                      let renameTab = find(#selector(AppActions.renameTab(_:)), in: menu),
                      let newTab = find(#selector(AppActions.newTab(_:)), in: menu)
                else {
                    TestRunner.fail("expected menu commands were not found")
                    return
                }

                model.requestEditSelectedEntry()
                expectEqual(model.pendingTextEdit?.mode, .edit(entryID: entry.id))
                for (item, name) in [
                    (newItem, "New Item"), (editItem, "Edit Item"), (remove, "Remove"),
                    (clearTab, "Clear Tab"), (removeTab, "Remove Tab"), (renameTab, "Rename Tab"),
                    (newTab, "New Tab"),
                ] {
                    expectEqual(actions.validateMenuItem(item), false, "\(name) must be disabled while the sheet is open")
                }

                model.requestNewItem()
                expectEqual(
                    model.pendingTextEdit?.mode,
                    .edit(entryID: entry.id),
                    "a second request must not replace the sheet"
                )

                model.removeSelected()
                expectEqual(try history.store.entry(id: entry.id)?.id, entry.id, "Remove must not delete the target")
                model.remove(entry)
                expectEqual(try history.store.entry(id: entry.id)?.id, entry.id, "row deletion must wait for the sheet")
                model.clearSelectedTab()
                expectEqual(try history.store.entry(id: entry.id)?.id, entry.id, "Clear Tab must not delete the target")
                model.removeTab(secondTab)
                expectEqual(model.tabs.count, 2, "Remove Tab must wait for the sheet")
                expectEqual(model.addTab(named: "Third"), nil, "New Tab must wait for the sheet")
                model.selectTab(secondTab.id)
                expectEqual(model.selectedTabID, firstTabID, "tab switching must wait for the sheet")
                model.requestRenameSelectedTab()
                expectNil(model.pendingRenameTabID, "tab rename must wait for the sheet")

                model.cancelTextEdit()
                expectEqual(actions.validateMenuItem(newItem), true, "New Item returns after the sheet closes")
                expectEqual(actions.validateMenuItem(renameTab), true, "Rename Tab returns after the sheet closes")
                model.requestRenameSelectedTab()
                expectEqual(model.pendingRenameTabID, firstTabID)
                expectEqual(actions.validateMenuItem(newItem), false, "New Item must wait for the rename alert")
                expectEqual(actions.validateMenuItem(editItem), false, "Edit Item must wait for the rename alert")
                model.requestNewItem()
                expectNil(model.pendingTextEdit, "New Item must not open over the rename alert")
                model.requestEditSelectedEntry()
                expectNil(model.pendingTextEdit, "Edit Item must not open over the rename alert")
                model.pendingRenameTabID = nil
                expectEqual(actions.validateMenuItem(newItem), true, "New Item returns after the rename alert")
                expectEqual(actions.validateMenuItem(editItem), true, "Edit Item returns after the rename alert")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("cancelling the editor changes nothing") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let outcome = try history.record([Fixtures.text("leave me alone")])
                guard case .inserted(let entry) = outcome else {
                    TestRunner.fail("fixture entry was not inserted")
                    return
                }
                model.reload()
                model.select(entry.id)

                model.requestEditSelectedEntry()
                expectEqual(model.pendingTextEdit?.text, "leave me alone")
                model.cancelTextEdit()
                expectNil(model.pendingTextEdit)

                let loaded = try history.store.entry(id: entry.id)
                expectEqual(loaded?.fingerprint, entry.fingerprint)
                expectEqual(FlavourDecoder.storedPlainText(from: loaded?.flavours ?? []), "leave me alone")
                expectEqual(try history.search("leave me alone").count, 1)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the editor saves through the model and refreshes the list") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let outcome = try history.record([Fixtures.text("before edit")])
                guard case .inserted(let entry) = outcome else {
                    TestRunner.fail("fixture entry was not inserted")
                    return
                }
                model.reload()
                model.select(entry.id)

                model.requestEditSelectedEntry()
                expectEqual(model.pendingTextEdit?.mode, .edit(entryID: entry.id))
                let failure = model.commitTextEdit(.text("after edit"))
                expectNil(failure)
                expectNil(model.pendingTextEdit)
                expectEqual(FlavourDecoder.storedPlainText(from: model.entries.first?.flavours ?? []), "after edit")
                expectEqual(model.selectedEntryID, entry.id)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a save hidden by the active filter is announced") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                guard case .inserted(let entry) = try history.record([Fixtures.text("visible entry")]) else {
                    TestRunner.fail("fixture entry was not inserted")
                    return
                }
                model.searchText = "visible"
                model.reload()
                model.select(entry.id)

                model.requestEditSelectedEntry()
                let failure = model.commitTextEdit(.text("hidden edit"))
                expectNil(failure)
                expectNil(model.pendingTextEdit)
                expectEqual(model.notice, "Saved; hidden by the current filter.")
                expectEqual(try history.search("hidden edit").count, 1)

                model.requestNewItem()
                let newFailure = model.commitTextEdit(.text("hidden new item"))
                expectNil(newFailure)
                expectEqual(model.notice, "Saved; hidden by the current filter.")
                expectEqual(try history.search("hidden new item").count, 1)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the Item menu exposes New Item and Edit Item") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                let actions = AppActions(model: model, windowController: nil, presentPreferences: {})
                let menu = MainMenuBuilder.build(actions: actions)
                guard let itemMenu = menu.items.first(where: { $0.title == "Item" })?.submenu else {
                    TestRunner.fail("the Item menu is missing")
                    return
                }
                guard let editItem = itemMenu.items.first(where: { $0.action == #selector(AppActions.editItem(_:)) }),
                      let newItem = itemMenu.items.first(where: { $0.action == #selector(AppActions.newItem(_:)) })
                else {
                    TestRunner.fail("New Item and Edit Item must be in the Item menu")
                    return
                }
                expectEqual(editItem.title, "Edit Item\u{2026}")
                expectEqual(newItem.title, "New Item\u{2026}")
                expectEqual(editItem.keyEquivalent, "\u{F705}", "Edit Item uses the literal F2 key")
                expectEqual(editItem.keyEquivalentModifierMask, [])
                expectEqual(actions.validateMenuItem(newItem), true, "New Item is always available")
                expectEqual(actions.validateMenuItem(editItem), false, "Edit Item needs a selected entry")

                _ = try history.record([Fixtures.text("menu entry")])
                model.reload()
                model.selectFirst()
                expectEqual(actions.validateMenuItem(editItem), true, "Edit Item enables with a selection")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a new item lands in the selected tab as the newest entry") {
        MainActor.assumeIsolated {
            do {
                let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
                let model = AppModel(history: history)
                model.bootstrap()
                _ = try history.record([Fixtures.text("older entry")])
                guard let second = model.addTab(named: "Second") else {
                    TestRunner.fail("second tab was not created")
                    return
                }

                model.requestNewItem()
                expectEqual(model.pendingTextEdit?.mode, .newItem(tabID: second.id))
                let failure = model.commitTextEdit(.text("typed into the second tab"))
                expectNil(failure)
                expectNil(model.pendingTextEdit)

                guard let newest = model.entries.first else {
                    TestRunner.fail("the new item is not visible")
                    return
                }
                expectEqual(newest.tabID, second.id)
                expectEqual(FlavourDecoder.storedPlainText(from: newest.flavours), "typed into the second tab")
                expectEqual(model.selectedEntryID, newest.id)
                expectEqual(try history.search("typed into the second tab", tabID: second.id).count, 1)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
