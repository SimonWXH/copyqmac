// Tabs, notes, global bounds, preferences, and schema migrations.

import AppKit
import Foundation
import SwiftUI

func registerTabsAndPreferencesTests() {
    // MARK: - Tabs

    TestRunner.add("fresh store's first tab is named Clipboard") {
        let store = try ClipboardStore(inMemory: true)
        let tabs = try store.tabs()
        expectEqual(tabs.count, 1)
        expectEqual(tabs.first?.name, ClipboardStore.initialTabName)
        expectEqual(tabs.first?.name, "Clipboard")
        expectEqual(tabs.first?.isDefault, true)
        expectEqual(try store.defaultTab()?.id, tabs.first?.id)
    }

    TestRunner.add("adding tabs appends them in order") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let second = try history.addTab(name: "Fedora")
        let third = try history.addTab(name: "Archive")
        let tabs = try history.tabs()
        expectEqual(tabs.map(\.name), [ClipboardStore.initialTabName, "Fedora", "Archive"])
        expectEqual(tabs.map(\.position), [1, 2, 3])
        expectEqual(second.isDefault, false)
        expectEqual(third.isDefault, false)
    }

    TestRunner.add("renaming and sync-folder mapping round-trip") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        var tab = try history.defaultTab()
        tab.name = "Clipboard (renamed)"
        tab.syncFolder = "~/Syncthing/Config/CopyQ"
        try history.updateTab(tab)
        let reloaded = try history.store.tab(id: tab.id)
        expectEqual(reloaded?.name, "Clipboard (renamed)")
        expectEqual(reloaded?.syncFolder, "~/Syncthing/Config/CopyQ")
    }

    TestRunner.add("tabs can be reordered") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let second = try history.addTab(name: "Fedora")
        let third = try history.addTab(name: "Archive")
        try history.moveTab(id: third.id, delta: -1)
        expectEqual(try history.tabs().map(\.name), [ClipboardStore.initialTabName, "Archive", "Fedora"])
        try history.moveTab(id: second.id, delta: -1)
        expectEqual(try history.tabs().map(\.name), [ClipboardStore.initialTabName, "Fedora", "Archive"])
        // Moving past the edge is a no-op.
        try history.moveTab(id: third.id, delta: 5)
        expectEqual(try history.tabs().count, 3)
    }

    TestRunner.add("the default tab can be changed and stays unique") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let second = try history.addTab(name: "Fedora")
        try history.setDefaultTab(id: second.id)
        let tabs = try history.tabs()
        expectEqual(tabs.filter(\.isDefault).count, 1)
        expectEqual(tabs.first(where: \.isDefault)?.id, second.id)
        expectEqual(try history.defaultTab().id, second.id)
    }

    TestRunner.add("deleting a tab removes its entries and promotes a default") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let first = try history.defaultTab()
        let second = try history.addTab(name: "Fedora")
        _ = try history.record([Fixtures.text("in first")], into: first)
        _ = try history.record([Fixtures.text("in second")], into: second)
        expectEqual(try history.store.count(), 2)

        try history.deleteTab(id: first.id)
        expectEqual(try history.tabs().map(\.name), ["Fedora"])
        expectEqual(try history.store.count(), 1)
        expectEqual(try history.defaultTab().id, second.id)
        expectEqual(try history.recent(tabID: second.id).count, 1)
    }

    TestRunner.add("clears every row from a tab beyond the visible history bound") {
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)
        let tab = try history.defaultTab()
        let otherTab = try history.addTab(name: "Other")
        _ = try history.record([Fixtures.text("survive clear")], into: otherTab)
        let insert = try store.database.prepare("""
            WITH RECURSIVE sequence(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 100001
            )
            INSERT INTO entries (created_at, pinned, tab_id, note, fingerprint)
            SELECT value, 1, ?, '', 'entry-' || value FROM sequence
            """)
        defer { insert.finalize() }
        try insert.bind(1, tab.id)
        try insert.run()

        let searchRows = try store.database.prepare("""
            INSERT INTO search_fts (rowid, text)
            SELECT id, 'clear-marker' FROM entries
            WHERE tab_id = ? AND (created_at = 1 OR created_at = 100001)
            """)
        defer { searchRows.finalize() }
        try searchRows.bind(1, tab.id)
        try searchRows.run()
        expectEqual(try store.count(tabID: tab.id), 100_001)
        expectEqual(try store.search("clear-marker", tabID: tab.id).count, 2)

        try history.clear(tabID: tab.id)
        expectEqual(try store.count(tabID: tab.id), 0)
        expectEqual(try store.search("clear-marker", tabID: tab.id).count, 0)
        expectEqual(try store.count(tabID: otherTab.id), 1)
        expectEqual(try store.search("survive clear", tabID: otherTab.id).count, 1)
    }

    TestRunner.add("trim and tab deletion handle more rows than SQLite bind limits") {
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)
        let first = try history.defaultTab()
        let second = try history.addTab(name: "Bulk")
        let insert = try store.database.prepare("""
            WITH RECURSIVE sequence(value) AS (
                SELECT 1
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 100001
            )
            INSERT INTO entries (created_at, pinned, tab_id, note, fingerprint)
            SELECT value, 0, tabs.id, '', 'entry-' || tabs.id || '-' || value
            FROM sequence CROSS JOIN tabs
            WHERE tabs.id IN (?, ?)
            """)
        defer { insert.finalize() }
        try insert.bind(1, first.id)
        try insert.bind(2, second.id)
        try insert.run()
        try store.database.execute("""
            INSERT INTO search_fts (rowid, text)
            SELECT id, 'bulk-marker' FROM entries WHERE created_at IN (1, 100001)
            """)

        expectEqual(try store.count(tabID: first.id), 100_001)
        expectEqual(try store.trim(tabID: first.id, to: 1), 100_000)
        expectEqual(try store.count(tabID: first.id), 1)
        expectEqual(try history.search("bulk-marker", tabID: first.id).count, 1)

        var preferences = try history.preferences()
        preferences.defaultMaxItems = 1
        try history.setPreferences(preferences)
        expectEqual(try store.count(tabID: second.id), 1)
        expectEqual(try history.search("bulk-marker", tabID: second.id).count, 1)

        try history.deleteTab(id: second.id)
        expectEqual(try store.count(tabID: second.id), 0)
        expectEqual(try history.search("bulk-marker", tabID: second.id).count, 0)
    }

    TestRunner.add("the last tab cannot be deleted") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let only = try history.defaultTab()
        try history.deleteTab(id: only.id)
        expectEqual(try history.tabs().count, 1)
    }

    TestRunner.add("search can be scoped to a tab or span every tab") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let first = try history.defaultTab()
        let second = try history.addTab(name: "Fedora")
        _ = try history.record([Fixtures.text("shared token alpha")], into: first)
        _ = try history.record([Fixtures.text("shared token beta")], into: second)
        expectEqual(try history.search("shared token", tabID: first.id).count, 1)
        expectEqual(try history.search("shared token", tabID: second.id).count, 1)
        expectEqual(try history.search("shared token", tabID: nil).count, 2)
    }

    // MARK: - Global bounds

    TestRunner.add("the global cap applies to every tab") {
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)
        var preferences = try history.preferences()
        preferences.defaultMaxItems = 3
        try history.setPreferences(preferences)
        let first = try history.defaultTab()
        let second = try history.addTab(name: "Fedora")
        for index in 0..<8 {
            _ = try history.record([Fixtures.text("first \(index)")], into: first, at: Date(timeIntervalSince1970: Double(index)))
            _ = try history.record([Fixtures.text("second \(index)")], into: second, at: Date(timeIntervalSince1970: Double(index)))
        }
        expectEqual(try store.count(tabID: first.id), 3)
        expectEqual(try store.count(tabID: second.id), 3)
    }

    TestRunner.add("saving a lower limit immediately trims every tab") {
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)
        let first = try history.defaultTab()
        let second = try history.addTab(name: "Fedora")

        func populate(_ tab: ClipboardTab, prefix: String) throws {
            guard case .inserted(let pinned) = try history.record(
                [Fixtures.text("\(prefix) pinned")], into: tab, at: Date(timeIntervalSince1970: 0)
            ) else {
                TestRunner.fail("expected a pinned entry")
                return
            }
            _ = try history.setPinned(pinned.id, true)
            for index in 1...4 {
                _ = try history.record(
                    [Fixtures.text("\(prefix) item \(index)")],
                    into: tab,
                    at: Date(timeIntervalSince1970: Double(index))
                )
            }
        }
        try populate(first, prefix: "first")
        try populate(second, prefix: "second")

        var preferences = try history.preferences()
        preferences.defaultMaxItems = 2
        try history.setPreferences(preferences)

        for tab in [first, second] {
            expectEqual(try store.count(tabID: tab.id), 3)
            expectEqual(try store.pinnedCount(tabID: tab.id), 1)
        }
        expectEqual(try history.search("first item 1", tabID: first.id).count, 0)
        expectEqual(try history.search("first pinned", tabID: first.id).count, 1)
        expectEqual(try history.search("second item 1", tabID: second.id).count, 0)
        expectEqual(try history.search("second pinned", tabID: second.id).count, 1)
    }

    TestRunner.add("pinned entries survive the global limit") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        var preferences = try history.preferences()
        preferences.defaultMaxItems = 2
        try history.setPreferences(preferences)
        let tab = try history.defaultTab()
        guard case .inserted(let pinned) = try history.record([Fixtures.text("keep")], into: tab, at: Date(timeIntervalSince1970: 0))
        else { return }
        _ = try history.setPinned(pinned.id, true)
        for index in 1..<8 {
            _ = try history.record([Fixtures.text("e \(index)")], into: tab, at: Date(timeIntervalSince1970: Double(index)))
        }
        expectNotNil(try history.store.entry(id: pinned.id))
        expectEqual(try history.store.pinnedCount(tabID: tab.id), 1)
        expectEqual(try history.store.count(tabID: tab.id), 3)  // 2 unpinned + 1 pinned
    }

    TestRunner.add("duplicate collapsing is per tab") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let first = try history.defaultTab()
        let second = try history.addTab(name: "Fedora")
        _ = try history.record([Fixtures.text("same")], into: first)
        _ = try history.record([Fixtures.text("same")], into: second)
        expectEqual(try history.store.count(tabID: first.id), 1)
        expectEqual(try history.store.count(tabID: second.id), 1)
    }

    // MARK: - Notes

    TestRunner.add("notes round-trip and are searchable") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        guard case .inserted(let entry) = try history.record([Fixtures.text("payload")]) else { return }
        expectEqual(entry.note, "")
        _ = try history.setNote(entry.id, "remember this for the report")
        let reloaded = try history.store.entry(id: entry.id)
        expectEqual(reloaded?.note, "remember this for the report")
        expectEqual(try history.search("remember this").count, 1)
        // Clearing the note removes it from the index.
        _ = try history.setNote(entry.id, "")
        expectEqual(try history.search("remember this").count, 0)
        expectEqual(try history.search("payload").count, 1)
    }

    TestRunner.add("notes survive a reopen") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        var entryID: Int64 = 0
        do {
            let history = ClipboardHistory(store: try ClipboardStore(path: path))
            guard case .inserted(let entry) = try history.record([Fixtures.text("x")]) else { return }
            entryID = entry.id
            _ = try history.setNote(entry.id, "persisted note")
        }
        let reopened = try ClipboardStore(path: path)
        expectEqual(try reopened.entry(id: entryID)?.note, "persisted note")
    }

    // MARK: - Preferences

    TestRunner.add("default preferences are Option-V, Shift-Command-V, and 1000 items") {
        let store = try ClipboardStore(inMemory: true)
        let preferences = try store.preferences()
        expectEqual(preferences.hotKeyKeyCode, HotKeyKey.v)
        expectEqual(preferences.hotKeyModifiers, HotKeyModifiers.option)
        expectEqual(preferences.hotKeyDisplayLabel, "\u{2325}V")
        expectEqual(preferences.plainTextHotKeyKeyCode, HotKeyKey.v)
        expectEqual(
            preferences.plainTextHotKeyModifiers,
            HotKeyModifiers.command | HotKeyModifiers.shift,
            "the plain-text shortcut defaults to ⇧⌘V"
        )
        expectEqual(preferences.plainTextHotKeyDisplayLabel, "\u{21E7}\u{2318}V")
        expectEqual(preferences.defaultMaxItems, 1000)
        expectEqual(preferences.searchAllTabs, false)
    }

    TestRunner.add("preferences round-trip") {
        let store = try ClipboardStore(inMemory: true)
        var preferences = try store.preferences()
        preferences.hotKeyKeyCode = HotKeyKey.space
        preferences.hotKeyModifiers = HotKeyModifiers.command | HotKeyModifiers.shift
        preferences.plainTextHotKeyKeyCode = HotKeyKey.c
        preferences.plainTextHotKeyModifiers = HotKeyModifiers.control | HotKeyModifiers.option
        preferences.plainTextHotKeyDisplayLabel = "\u{2303}\u{2325}C"
        preferences.defaultMaxItems = 200
        preferences.searchAllTabs = true
        try store.setPreferences(preferences)
        let reloaded = try store.preferences()
        expectEqual(reloaded, preferences)
    }

    TestRunner.add("preferences are clamped to sane ranges") {
        var preferences = Preferences.defaultValue
        preferences.defaultMaxItems = 0
        let sanitized = preferences.sanitized()
        expectEqual(sanitized.defaultMaxItems, 1)
    }

    // MARK: - Fonts

    TestRunner.add("font preferences default to the system font") {
        let preferences = Preferences.defaultValue
        expect(preferences.itemListFont.isDefault, "the item list font starts unset")
        expect(preferences.editorFont.isDefault, "the editor font starts unset")
        expectEqual(preferences.itemListFont, FontPreference.defaultValue)
        expectEqual(preferences.editorFont, FontPreference.defaultValue)
    }

    TestRunner.add("an older preferences blob without font fields gets the system font") {
        let json = #"{"defaultMaxItems":250,"language":"en"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.defaultMaxItems, 250)
        expect(decoded.itemListFont.isDefault, "an absent item list font key is the system font")
        expect(decoded.editorFont.isDefault, "an absent editor font key is the system font")
    }

    TestRunner.add("font preferences survive a store round-trip") {
        let store = try ClipboardStore(inMemory: true)
        var preferences = try store.preferences()
        preferences.itemListFont = FontPreference(family: "Georgia", pointSize: 15)
        preferences.editorFont = FontPreference(family: "Menlo", pointSize: 14)
        try store.setPreferences(preferences)

        let reloaded = try store.preferences()
        expectEqual(reloaded.itemListFont, FontPreference(family: "Georgia", pointSize: 15))
        expectEqual(reloaded.editorFont, FontPreference(family: "Menlo", pointSize: 14))
    }

    TestRunner.add("an untouched font preference resolves to the system body font") {
        let resolved = FontPreference().nsFont
        let body = NSFont.preferredFont(forTextStyle: .body)
        expectEqual(resolved.fontName, body.fontName)
        expectEqual(resolved.pointSize, body.pointSize)
    }

    TestRunner.add("a font preference is applied as stored") {
        let body = NSFont.preferredFont(forTextStyle: .body)

        let chosenFamily = FontPreference(family: "Helvetica", pointSize: 19).nsFont
        expectEqual(chosenFamily.familyName, "Helvetica")
        expectEqual(chosenFamily.pointSize, 19)

        let systemAtSize = FontPreference(pointSize: 17).nsFont
        expectEqual(systemAtSize.familyName, body.familyName)
        expectEqual(systemAtSize.pointSize, 17)

        // No validation: a family this system does not have is resolved by the
        // platform, at the size the user chose, exactly as CopyQ applies its
        // configured font.
        let missingFamily = FontPreference(family: "NoSuchFontFamilyForTests", pointSize: 11).nsFont
        expectEqual(missingFamily.familyName, body.familyName)
        expectEqual(missingFamily.pointSize, 11)
    }

    TestRunner.add("an untouched editor preference keeps each editor's own font") {
        MainActor.assumeIsolated {
            let untouched = FontPreference.defaultValue.chosenFont
            expectNil(untouched, "an untouched setting leaves the editors on their own fonts")

            let styled = RichTextEditor.makeEditor(
                document: StyledTextDocument(runs: []),
                delegate: nil,
                format: .html,
                font: untouched
            )
            expectEqual(styled.textView.font?.fontName, RichTextEditing.editorFont.fontName)
            let typing = styled.textView.typingAttributes[.font] as? NSFont
            expectEqual(typing?.fontName, RichTextEditing.editorFont.fontName)

            let seeded = RichTextEditor.makeEditor(
                document: StyledTextDocument(runs: [
                    StyledTextRun(text: "georgia", pointSize: 24, fontFamily: "Georgia"),
                ]),
                delegate: nil,
                format: .html,
                font: untouched
            )
            seeded.textView.insertText("x", replacementRange: seeded.textView.selectedRange())
            let typed = seeded.textView.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
            expectEqual(
                typed?.familyName,
                "Georgia",
                "an untouched setting keeps the run before the caret"
            )
            expectEqual(typed?.pointSize, 24)

            let plain = PlainTextEditor.makeEditor(text: "", delegate: nil, font: untouched)
            expectEqual(plain.textView.font?.fontName, PlainTextEditor.bodyFont.fontName)
            expectEqual(plain.textView.font?.pointSize, PlainTextEditor.bodyFont.pointSize)
        }
    }

    TestRunner.add("a chosen editor preference replaces the editor's own font") {
        MainActor.assumeIsolated {
            let chosen = FontPreference(family: "Menlo", pointSize: 16)
            let resolved = chosen.chosenFont
            expectEqual(resolved?.fontName, NSFont(name: "Menlo", size: 16)?.fontName)
            expectEqual(resolved?.pointSize, 16)

            let styled = RichTextEditor.makeEditor(
                document: StyledTextDocument(runs: []),
                delegate: nil,
                format: .html,
                font: resolved
            )
            expectEqual(styled.textView.font?.fontName, resolved?.fontName)

            let seeded = RichTextEditor.makeEditor(
                document: StyledTextDocument(runs: [
                    StyledTextRun(text: "georgia", pointSize: 24, fontFamily: "Georgia"),
                ]),
                delegate: nil,
                format: .html,
                font: resolved
            )
            seeded.textView.insertText("x", replacementRange: seeded.textView.selectedRange())
            let typed = seeded.textView.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
            expectEqual(
                typed?.fontName,
                resolved?.fontName,
                "a seeded item types new text in the chosen font"
            )
            expectEqual(typed?.pointSize, 16)
        }
    }

    TestRunner.add("System plus a size keeps the system font outside the styled editor") {
        MainActor.assumeIsolated {
            let resolved = FontPreference(pointSize: 17).chosenFont
            expectEqual(
                resolved?.fontName,
                NSFont.systemFont(ofSize: 17).fontName,
                "the preference itself is the system font"
            )

            let styled = RichTextEditor.makeEditor(
                document: StyledTextDocument(runs: []),
                delegate: nil,
                format: .html,
                font: resolved
            )
            expectEqual(
                styled.textView.font?.familyName,
                StyledTextDocument.defaultFontFamily,
                "the styled editor draws the default writing family"
            )
            expectEqual(styled.textView.font?.pointSize, 17)

            let plain = PlainTextEditor.makeEditor(text: "", delegate: nil, font: resolved)
            expectEqual(
                plain.textView.font?.fontName,
                resolved?.fontName,
                "the plain editor keeps the system font"
            )
            expectEqual(
                FontPreference(pointSize: 17).nsFont.fontName,
                resolved?.fontName,
                "the item list keeps the system font"
            )
        }
    }

    TestRunner.add("every editor font the picker offers can be saved in RTF") {
        MainActor.assumeIsolated {
            let catalog = FontFamilyCatalog()
            catalog.load()
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "missing family", pointSize: 13, fontFamily: "NoSuchFontFamilyForTests"),
            ])
            for family in catalog.editor {
                let baseFont = NSFont(name: family, size: 13)
                expect(baseFont != nil, "the installed family \(family) has to resolve")
                let drawn = RichTextEditing.attributedText(from: document, baseFont: baseFont)
                expect(
                    RichTextEditing.isRepresentable(drawn, format: .rtf, requireStoredColors: true),
                    "\(family) as the editor font would refuse every RTF save"
                )
            }
            for family in NSFontManager.shared.availableFontFamilies {
                guard let font = NSFont(
                    name: family,
                    size: CGFloat(StyledTextDocument.defaultPointSize)
                ) else { continue }
                guard !RichTextEditing.isRepresentable(font: font, format: .rtf) else { continue }
                expect(
                    !catalog.editor.contains(family),
                    "\(family) cannot be written to RTF, so the editor picker must not offer it"
                )
            }
            expect(
                catalog.editor.contains(StyledTextDocument.defaultFontFamily),
                "the styled editor's own base font stays selectable"
            )
        }
    }

    TestRunner.add("the item list offers a non-ASCII font family the editor cannot save") {
        MainActor.assumeIsolated {
            // A family the RTF font table cannot carry would otherwise be read
            // back into the document and refuse every save of that item.
            guard let family = NSFontManager.shared.availableFontFamilies.first(where: { family in
                !family.unicodeScalars.allSatisfy { $0.isASCII }
            }) else { return }

            let catalog = FontFamilyCatalog()
            catalog.load()
            expect(catalog.itemList.contains(family), "the item list may draw \(family)")
            expect(
                !catalog.editor.contains(family),
                "\(family) cannot be written to RTF, so the editor must not offer it"
            )

            let baseFont = NSFont(
                name: family,
                size: CGFloat(StyledTextDocument.defaultPointSize)
            )
            let document = StyledTextDocument(runs: [
                StyledTextRun(text: "text", pointSize: 13, fontFamily: "NoSuchFontFamilyForTests"),
            ])
            let drawn = RichTextEditing.attributedText(from: document, baseFont: baseFont)
            expect(
                !RichTextEditing.isRepresentable(drawn, format: .rtf, requireStoredColors: true),
                "\(family) as a base font would refuse an RTF save, which is why the editor omits it"
            )
        }
    }

    TestRunner.add("the item list may use every installed family") {
        MainActor.assumeIsolated {
            let catalog = FontFamilyCatalog()
            catalog.load()
            expectEqual(catalog.itemList, NSFontManager.shared.availableFontFamilies.sorted())
        }
    }

    TestRunner.add("the font picker offers the families its surface allows") {
        MainActor.assumeIsolated {
            do {
                let harness = try FontPreferenceRowHarness(families: ["Helvetica", "Menlo"])
                defer { harness.close() }

                expectEqual(harness.familyTitles, ["System", "Helvetica", "Menlo"])
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the font picker writes the chosen family and size") {
        MainActor.assumeIsolated {
            do {
                let harness = try FontPreferenceRowHarness()
                defer { harness.close() }

                harness.chooseFamily("Helvetica")
                expectEqual(harness.preference.family, "Helvetica")
                expectNil(harness.preference.pointSize, "choosing a family keeps the default size")

                harness.incrementSize()
                expectEqual(harness.preference.family, "Helvetica")
                expectEqual(
                    harness.preference.pointSize,
                    Double(NSFont.preferredFont(forTextStyle: .body).pointSize + 1),
                    "the size stepper writes the next point size"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("choosing System resets a font setting to the default font") {
        MainActor.assumeIsolated {
            do {
                let harness = try FontPreferenceRowHarness(
                    preference: FontPreference(family: "Georgia", pointSize: 18)
                )
                defer { harness.close() }

                harness.chooseFamily("System")
                expect(harness.preference.isDefault, "System drops the family and the chosen size")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a family that is no longer installed stays selected in the picker") {
        MainActor.assumeIsolated {
            do {
                let harness = try FontPreferenceRowHarness(
                    preference: FontPreference(family: "NoSuchFontFamilyForTests", pointSize: 12)
                )
                defer { harness.close() }

                expectEqual(harness.selectedFamily, "NoSuchFontFamilyForTests")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("unknown preference fields fall back to defaults") {
        // A blob written by a newer build must not brick this one.
        let json = #"{"hotKeyKeyCode":9,"hotKeyModifiers":2048,"appearance":"dark","futureField":true}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.defaultMaxItems, Preferences.defaultMaxItems)
        expectEqual(decoded.plainTextHotKeyKeyCode, HotKeyKey.v)
        expectEqual(
            decoded.plainTextHotKeyModifiers,
            HotKeyModifiers.command | HotKeyModifiers.shift,
            "an older blob without the plain-text fields gets the ⇧⌘V default"
        )
        expectEqual(decoded.plainTextHotKeyDisplayLabel, "\u{21E7}\u{2318}V")
    }

    // MARK: - Migration

    TestRunner.add("a version-1 database migrates to tabs and notes") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        try makeVersion1Database(at: path)

        let store = try ClipboardStore(path: path)
        // Entries were assigned to the freshly seeded default tab.
        let tab = try store.defaultTab()
        expectNotNil(tab)
        guard let tab else { return }
        expectEqual(try store.count(tabID: tab.id), 2)
        let entries = try store.recentEntries(tabID: tab.id)
        let entry = entries.first { FlavourDecoder.preview(for: $0.flavours).text == "legacy entry" }
        expectEqual(entry?.note, "")
        expectEqual(FlavourDecoder.preview(for: entry?.flavours ?? []).text, "legacy entry")
        expectEqual(try store.search("v1-annual-report").count, 1)
        expectEqual(try store.search("Image 1024x1024").count, 0)
        expectEqual(store.database.userVersion, ClipboardStore.currentSchemaVersion)
    }

    TestRunner.add("a version-2 database drops the obsolete per-tab limit") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        try makeVersion2Database(at: path)

        let store = try ClipboardStore(path: path)
        let tab = try store.defaultTab()
        expectEqual(tab?.name, "Archive")
        expectEqual(tab?.syncFolder, "~/CopyQ")
        expectEqual(try store.search("v2-annual-report").count, 1)
        expectEqual(try store.search("Image 1024x1024").count, 0)
        expectEqual(store.database.userVersion, ClipboardStore.currentSchemaVersion)
        let columns = try store.database.prepare("PRAGMA table_info(tabs)")
        defer { columns.finalize() }
        var names: [String] = []
        while try columns.step() { names.append(columns.string(at: 1) ?? "") }
        expectEqual(names.contains("max_items"), false)
    }

    TestRunner.add("a version-4 database migrates flavours to compressed storage") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path

        let largeText = String(repeating: "Large repeatable text block for zlib compression. ", count: 100)
        let largeData = Data(largeText.utf8)
        expect(largeData.count > 1024)
        let smallData = Data("short".utf8)
        expect(smallData.count <= 1024)

        try makeVersion4Database(at: path, smallData: smallData, largeData: largeData)

        let store = try ClipboardStore(path: path)
        expectEqual(store.database.userVersion, ClipboardStore.currentSchemaVersion)
        expectEqual(try store.defaultTab()?.name, "Archive")

        // Verify column added
        let columns = try store.database.prepare("PRAGMA table_info(flavours)")
        defer { columns.finalize() }
        var colNames: [String] = []
        while try columns.step() { colNames.append(columns.string(at: 1) ?? "") }
        expect(colNames.contains("compressed"), "flavours table must have compressed column after migration")

        // Check raw storage
        let select = try store.database.prepare("SELECT type, length(data), compressed FROM flavours ORDER BY entry_id")
        defer { select.finalize() }
        var rows: [(type: String, len: Int, compressed: Int)] = []
        while try select.step() {
            rows.append((
                type: select.string(at: 0) ?? "",
                len: Int(select.int64(at: 1)),
                compressed: Int(select.int64(at: 2))
            ))
        }
        expectEqual(rows.count, 2)
        expectEqual(rows[0].compressed, 0, "small flavour should remain uncompressed")
        expectEqual(rows[0].len, smallData.count)
        expectEqual(rows[1].compressed, 1, "large flavour must be compressed")
        expect(rows[1].len < largeData.count, "compressed blob must be smaller")

        // Reading decompresses byte-identically
        let entries = try store.recentEntries(limit: 10)
        expectEqual(entries.count, 2)
        let loadedSmall = entries.first { $0.flavours.first?.type == "small" }
        expectEqual(loadedSmall?.flavours.first?.data, smallData)
        let loadedLarge = entries.first { $0.flavours.first?.type == "large" }
        expectEqual(loadedLarge?.flavours.first?.data, largeData)
    }

    TestRunner.add("interrupted compression migration resumes safely and is idempotent") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path

        let largeData = Data(String(repeating: "Interrupted migration test data! ", count: 120).utf8)
        try makeVersion4Database(at: path, smallData: Data("small".utf8), largeData: largeData)

        // Simulate interruption: add compressed column, compress only one row, keep userVersion at 4 (or 5)
        let db = try SQLiteDatabase(path: path)
        try db.execute("ALTER TABLE flavours ADD COLUMN compressed INTEGER NOT NULL DEFAULT 0")
        // Compress only the first entry's flavour if it exists
        if let compressed = QtCompression.compress(largeData) {
            let update = try db.prepare("UPDATE flavours SET data = ?, compressed = 1 WHERE type = 'large'")
            defer { update.finalize() }
            try update.bind(1, compressed)
            try update.run()
        }
        // Add another uncompressed large row
        let secondLarge = Data(String(repeating: "Second uncompressed large payload. ", count: 100).utf8)
        let insertEntry = try db.prepare("INSERT INTO entries (created_at, pinned, tab_id, note, fingerprint) VALUES (?, 0, 1, '', ?)")
        try insertEntry.bind(1, 1_700_000_050.0)
        try insertEntry.bind(2, "fingerprint-second")
        try insertEntry.run()
        let secondID = db.lastInsertRowID
        insertEntry.finalize()

        let insertFlavour = try db.prepare("INSERT INTO flavours (entry_id, item_index, type, data, compressed) VALUES (?, 0, 'large2', ?, 0)")
        try insertFlavour.bind(1, secondID)
        try insertFlavour.bind(2, secondLarge)
        try insertFlavour.run()
        insertFlavour.finalize()

        // Set version to 5 (as if migration was interrupted while userVersion was 5)
        db.userVersion = 5

        // Opening the store must detect remaining uncompressed rows > 1024 and compress them
        let store = try ClipboardStore(path: path)
        expectEqual(store.database.userVersion, ClipboardStore.currentSchemaVersion)

        // Verify large2 is now compressed
        let checkStmt = try store.database.prepare("SELECT compressed, length(data) FROM flavours WHERE type = 'large2'")
        defer { checkStmt.finalize() }
        expect(try checkStmt.step())
        expectEqual(checkStmt.int64(at: 0), 1, "large2 should have been compressed during resume")
        expect(Int(checkStmt.int64(at: 1)) < secondLarge.count)

        // Verify reading both decompressed rows produces exact original bytes
        let entry2 = try store.entry(id: secondID)
        expectEqual(entry2?.flavours.first?.data, secondLarge)

        // Idempotent: opening again does nothing and all data stays valid
        let reopened = try ClipboardStore(path: path)
        expectEqual(reopened.database.userVersion, ClipboardStore.currentSchemaVersion)
        let checkAgain = try reopened.entry(id: secondID)
        expectEqual(checkAgain?.flavours.first?.data, secondLarge)
    }

    TestRunner.add("a version-8 database migrates to version 9 and reclaims orphaned written sync stems") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path

        let rawDB = try SQLiteDatabase(path: path)
        rawDB.userVersion = 8
        try rawDB.execute("""
            CREATE TABLE tabs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                position INTEGER NOT NULL,
                is_default INTEGER NOT NULL DEFAULT 0,
                sync_folder TEXT
            );
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                position REAL NOT NULL DEFAULT 0,
                pinned INTEGER NOT NULL DEFAULT 0,
                tab_id INTEGER NOT NULL DEFAULT 0,
                note TEXT NOT NULL DEFAULT '',
                locally_edited INTEGER NOT NULL DEFAULT 0,
                last_imported_fingerprint TEXT NOT NULL DEFAULT '',
                sync_updated_at REAL NOT NULL DEFAULT 0,
                fingerprint TEXT NOT NULL
            );
            CREATE TABLE flavours (
                entry_id INTEGER NOT NULL,
                item_index INTEGER NOT NULL,
                type TEXT NOT NULL,
                data BLOB NOT NULL,
                compressed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (entry_id, item_index, type)
            );
            CREATE TABLE written_sync_stems (
                stem TEXT NOT NULL,
                folder TEXT NOT NULL,
                written_at REAL NOT NULL,
                entry_id INTEGER,
                PRIMARY KEY (stem, folder)
            );
            CREATE VIRTUAL TABLE search_fts USING fts5(text, tokenize='trigram');
        """)

        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let folder = syncFolder.path
        try rawDB.execute("INSERT INTO tabs (id, name, position, is_default, sync_folder) VALUES (1, 'Tab1', 1, 1, '\(folder)')")
        try rawDB.execute("INSERT INTO entries (id, created_at, position, pinned, tab_id, note, locally_edited, last_imported_fingerprint, sync_updated_at, fingerprint) VALUES (10, 1000.0, 1000.0, 0, 1, '', 0, '', 1000.0, 'fp1')")
        try rawDB.execute("INSERT INTO flavours (entry_id, item_index, type, data, compressed) VALUES (10, 0, 'text/plain', X'616263', 0)")

        // Seed 1 live, 2 dead entry_id, 1 null entry_id
        try rawDB.execute("INSERT INTO written_sync_stems (stem, folder, written_at, entry_id) VALUES ('stem-live', '\(folder)', 1000.0, 10)")
        try rawDB.execute("INSERT INTO written_sync_stems (stem, folder, written_at, entry_id) VALUES ('stem-dead1', '\(folder)', 1001.0, 99991)")
        try rawDB.execute("INSERT INTO written_sync_stems (stem, folder, written_at, entry_id) VALUES ('stem-dead2', '\(folder)', 1002.0, 99992)")
        try rawDB.execute("INSERT INTO written_sync_stems (stem, folder, written_at, entry_id) VALUES ('stem-null', '\(folder)', 1003.0, NULL)")

        // Open ClipboardStore: should run migrateFromV8 and reclaim the 3 broken rows
        let store = try ClipboardStore(path: path)
        expectEqual(store.database.userVersion, ClipboardStore.currentSchemaVersion)
        expectEqual(store.database.userVersion, 9)

        expect(try store.isWrittenSyncStem("stem-live", folder: folder), "live stem preserved")
        expect(!(try store.isWrittenSyncStem("stem-dead1", folder: folder)), "dead stem 1 reclaimed")
        expect(!(try store.isWrittenSyncStem("stem-dead2", folder: folder)), "dead stem 2 reclaimed")
        expect(!(try store.isWrittenSyncStem("stem-null", folder: folder)), "null stem reclaimed")
    }

    TestRunner.add("deleteRows and deleteTab cascade to written_sync_stems") {
        let store = try ClipboardStore(inMemory: true)
        let folderA = "/tmp/copyq-cascade-a"
        let folderB = "/tmp/copyq-cascade-b"

        let tab1 = try store.insertTab(ClipboardTab(name: "T1", syncFolder: folderA))
        let tab2 = try store.insertTab(ClipboardTab(name: "T2", syncFolder: folderA)) // shares folderA
        let tab3 = try store.insertTab(ClipboardTab(name: "T3", syncFolder: folderB))

        let entry1 = try store.insert(ClipboardEntry(createdAt: Date(), tabID: tab1.id, flavours: [Fixtures.text("e1")]))
        let entry2 = try store.insert(ClipboardEntry(createdAt: Date(), tabID: tab2.id, flavours: [Fixtures.text("e2")]))
        let entry3 = try store.insert(ClipboardEntry(createdAt: Date(), tabID: tab3.id, flavours: [Fixtures.text("e3")]))

        try store.recordWrittenSyncStem("stem1", folder: folderA, entryID: entry1.id)
        try store.recordWrittenSyncStem("stem2", folder: folderA, entryID: entry2.id)
        try store.recordWrittenSyncStem("stem3", folder: folderB, entryID: entry3.id)

        // delete entry3 directly via delete(id:)
        try store.delete(id: entry3.id, propagateSyncDeletion: false)
        expect(!(try store.isWrittenSyncStem("stem3", folder: folderB)), "entry deletion cascaded into written_sync_stems")

        // delete tab1: folderA is still shared with tab2, so stem2 must be kept, but stem1 was deleted by deleteRows
        try store.deleteTab(id: tab1.id)
        expect(!(try store.isWrittenSyncStem("stem1", folder: folderA)), "deleted tab entries cascaded")
        expect(try store.isWrittenSyncStem("stem2", folder: folderA), "surviving tab entry kept in shared folder")

        // delete tab2: folderA is no longer shared, so any remaining rows for folderA are removed
        try store.deleteTab(id: tab2.id)
        expect(!(try store.isWrittenSyncStem("stem2", folder: folderA)), "folder cleaned up when last tab deleted")
    }

    // MARK: - Data directory isolation

    TestRunner.add("the store honours the data directory override") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv(ClipboardStore.dataDirectoryEnvironmentKey, directory.path, 1)
        defer { unsetenv(ClipboardStore.dataDirectoryEnvironmentKey) }
        let url = try ClipboardStore.defaultURL()
        expectEqual(url.deletingLastPathComponent().path, directory.path)
        expectEqual(url.lastPathComponent, "history.sqlite")
    }
}

/// Builds a version-2 database with a stale file search row and per-tab limit.
private func makeVersion2Database(at path: String) throws {
    let database = try SQLiteDatabase(path: path)
    try database.execute("""
        CREATE TABLE tabs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            position INTEGER NOT NULL,
            is_default INTEGER NOT NULL DEFAULT 0,
            sync_folder TEXT,
            max_items INTEGER
        )
        """)
    try database.execute("""
        INSERT INTO tabs (name, position, is_default, sync_folder, max_items)
        VALUES ('Archive', 1, 1, '~/CopyQ', 25)
        """)
    try database.execute("""
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            tab_id INTEGER NOT NULL DEFAULT 0,
            note TEXT NOT NULL DEFAULT '',
            fingerprint TEXT NOT NULL
        )
        """)
    try database.execute("""
        CREATE TABLE flavours (
            entry_id INTEGER NOT NULL,
            item_index INTEGER NOT NULL,
            type TEXT NOT NULL,
            data BLOB NOT NULL,
            PRIMARY KEY (entry_id, item_index, type)
        )
        """)
    try database.execute("CREATE VIRTUAL TABLE search_fts USING fts5(text, tokenize='trigram')")
    try insertStaleFileEntry(database, version2Schema: true, searchText: "Image 1024x1024 (icns)")
    database.userVersion = 2
}

/// Builds a minimal schema-version-1 database with one entry, as the phase-1
/// slice would have written it.
private func makeVersion1Database(at path: String) throws {
    let database = try SQLiteDatabase(path: path)
    try database.execute("""
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            fingerprint TEXT NOT NULL
        )
        """)
    try database.execute("""
        CREATE TABLE flavours (
            entry_id INTEGER NOT NULL,
            item_index INTEGER NOT NULL,
            type TEXT NOT NULL,
            data BLOB NOT NULL,
            PRIMARY KEY (entry_id, item_index, type)
        )
        """)
    try database.execute("CREATE VIRTUAL TABLE search_fts USING fts5(text, tokenize='trigram')")

    let insertEntry = try database.prepare(
        "INSERT INTO entries (created_at, pinned, fingerprint) VALUES (?, 0, ?)"
    )
    let flavours = [Fixtures.text("legacy entry")]
    try insertEntry.bind(1, 1_700_000_000.0)
    try insertEntry.bind(2, Fingerprint.of(flavours))
    try insertEntry.run()
    let entryID = database.lastInsertRowID
    insertEntry.finalize()

    let insertFlavour = try database.prepare(
        "INSERT INTO flavours (entry_id, item_index, type, data) VALUES (?, ?, ?, ?)"
    )
    for flavour in flavours {
        try insertFlavour.bind(1, entryID)
        try insertFlavour.bind(2, flavour.itemIndex)
        try insertFlavour.bind(3, flavour.type)
        try insertFlavour.bind(4, flavour.data)
        try insertFlavour.run()
    }
    insertFlavour.finalize()

    let insertSearch = try database.prepare("INSERT INTO search_fts (rowid, text) VALUES (?, ?)")
    try insertSearch.bind(1, entryID)
    try insertSearch.bind(2, "legacy entry")
    try insertSearch.run()
    insertSearch.finalize()

    try insertStaleFileEntry(database, version2Schema: false, searchText: "Image 1024x1024 (icns)")
    database.userVersion = 1
}

private func insertStaleFileEntry(_ database: SQLiteDatabase, version2Schema: Bool, searchText: String) throws {
    let flavours = [Fixtures.fileURL("/tmp/v\(version2Schema ? 2 : 1)-annual-report.pdf")]
    let sql = version2Schema
        ? "INSERT INTO entries (created_at, pinned, tab_id, note, fingerprint) VALUES (?, 0, 1, '', ?)"
        : "INSERT INTO entries (created_at, pinned, fingerprint) VALUES (?, 0, ?)"
    let insertEntry = try database.prepare(sql)
    try insertEntry.bind(1, 1_700_000_001.0)
    try insertEntry.bind(2, Fingerprint.of(flavours))
    try insertEntry.run()
    let entryID = database.lastInsertRowID
    insertEntry.finalize()

    let insertFlavour = try database.prepare(
        "INSERT INTO flavours (entry_id, item_index, type, data) VALUES (?, ?, ?, ?)"
    )
    for flavour in flavours {
        try insertFlavour.bind(1, entryID)
        try insertFlavour.bind(2, flavour.itemIndex)
        try insertFlavour.bind(3, flavour.type)
        try insertFlavour.bind(4, flavour.data)
        try insertFlavour.run()
    }
    insertFlavour.finalize()

    let insertSearch = try database.prepare("INSERT INTO search_fts (rowid, text) VALUES (?, ?)")
    try insertSearch.bind(1, entryID)
    try insertSearch.bind(2, searchText)
    try insertSearch.run()
    insertSearch.finalize()
}

/// Builds a schema-version-4 database with uncompressed flavours.
private func makeVersion4Database(at path: String, smallData: Data, largeData: Data) throws {
    let database = try SQLiteDatabase(path: path)
    try database.execute("""
        CREATE TABLE tabs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            position INTEGER NOT NULL,
            is_default INTEGER NOT NULL DEFAULT 0,
            sync_folder TEXT
        )
        """)
    try database.execute("""
        INSERT INTO tabs (name, position, is_default, sync_folder)
        VALUES ('Archive', 1, 1, NULL)
        """)
    try database.execute("""
        CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """)
    try database.execute("""
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            tab_id INTEGER NOT NULL DEFAULT 1,
            note TEXT NOT NULL DEFAULT '',
            fingerprint TEXT NOT NULL
        )
        """)
    try database.execute("""
        CREATE TABLE flavours (
            entry_id INTEGER NOT NULL,
            item_index INTEGER NOT NULL,
            type TEXT NOT NULL,
            data BLOB NOT NULL,
            PRIMARY KEY (entry_id, item_index, type)
        )
        """)
    try database.execute("CREATE VIRTUAL TABLE search_fts USING fts5(text, tokenize='trigram')")

    // Insert small entry
    let insertEntry1 = try database.prepare("INSERT INTO entries (created_at, pinned, tab_id, note, fingerprint) VALUES (?, 0, 1, '', ?)")
    try insertEntry1.bind(1, 1_700_000_000.0)
    try insertEntry1.bind(2, "fingerprint-small")
    try insertEntry1.run()
    let smallID = database.lastInsertRowID
    insertEntry1.finalize()

    let insertFlavour1 = try database.prepare("INSERT INTO flavours (entry_id, item_index, type, data) VALUES (?, 0, 'small', ?)")
    try insertFlavour1.bind(1, smallID)
    try insertFlavour1.bind(2, smallData)
    try insertFlavour1.run()
    insertFlavour1.finalize()

    // Insert large entry
    let insertEntry2 = try database.prepare("INSERT INTO entries (created_at, pinned, tab_id, note, fingerprint) VALUES (?, 0, 1, '', ?)")
    try insertEntry2.bind(1, 1_700_000_010.0)
    try insertEntry2.bind(2, "fingerprint-large")
    try insertEntry2.run()
    let largeID = database.lastInsertRowID
    insertEntry2.finalize()

    let insertFlavour2 = try database.prepare("INSERT INTO flavours (entry_id, item_index, type, data) VALUES (?, 0, 'large', ?)")
    try insertFlavour2.bind(1, largeID)
    try insertFlavour2.bind(2, largeData)
    try insertFlavour2.run()
    insertFlavour2.finalize()

    database.userVersion = 4
}

// MARK: - Font row harness

/// Holds the row's bound value so the harness can read what the real SwiftUI
/// controls wrote, without a second copy of the settings logic in the test.
private final class FontPreferenceBox {
    var value = FontPreference.defaultValue
}

/// The real `FontPreferenceRow` in an unshown window, so the picker and stepper
/// the settings window ships are what the tests drive.
@MainActor
private final class FontPreferenceRowHarness {
    private let box: FontPreferenceBox
    private let window: NSWindow
    private let hosting: NSHostingView<FontPreferenceRow>

    init(
        preference: FontPreference = .defaultValue,
        families: [String]? = nil
    ) throws {
        _ = NSApplication.shared
        let catalog = FontFamilyCatalog()
        catalog.load()
        let families = families ?? catalog.itemList
        let box = FontPreferenceBox()
        box.value = preference
        self.box = box

        let binding = Binding(
            get: { box.value },
            set: { box.value = $0 }
        )
        hosting = NSHostingView(
            rootView: FontPreferenceRow(
                label: "Item list",
                detail: "The font list rows draw in.",
                language: .english,
                families: families,
                preference: binding
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 70)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 70),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        pump(0.4)
        hosting.layoutSubtreeIfNeeded()

        guard picker != nil, stepper != nil else { throw UnwrapFailure() }
    }

    /// What the row's binding was written with.
    var preference: FontPreference { box.value }

    var selectedFamily: String? { picker?.titleOfSelectedItem }

    /// The families the picker's menu offers, in menu order.
    var familyTitles: [String] { picker?.itemTitles ?? [] }

    /// Picks a family the way the menu does: run the selected menu item's
    /// action, which is the target SwiftUI installed for the picker.
    func chooseFamily(_ family: String) {
        guard let picker,
              let item = picker.menu?.item(withTitle: family),
              let action = item.action
        else { return }
        _ = item.target?.perform(action, with: item)
        pump(0.2)
    }

    func incrementSize() {
        guard let stepper else { return }
        // One click's worth, then the control's action, which is what a real
        // press runs.
        stepper.doubleValue += stepper.increment
        if let action = stepper.action {
            NSApp.sendAction(action, to: stepper.target, from: stepper)
        }
        pump(0.2)
    }

    func close() {
        window.contentView = nil
    }

    private var picker: NSPopUpButton? { Self.descendant(NSPopUpButton.self, in: hosting) }
    private var stepper: NSStepper? { Self.descendant(NSStepper.self, in: hosting) }

    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = descendant(type, in: subview) { return match }
        }
        return nil
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

