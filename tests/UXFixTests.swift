// File-entry display, list selection after note editing, and selection
// visibility - the four things a manual hand test turned up.
//
// The views cannot run without a window server, so the rules they delegate to
// live in `core/ListInteraction.swift` and are exercised here directly.

import Foundation

func registerUXFixTests() {
    /// The pasteboard shape Finder produces when a file is copied: the file URL,
    /// the file name as text, and the file's icon as `com.apple.icns` plus
    /// `public.tiff`.
    func finderFileCopy(_ paths: [String]) -> [Flavour] {
        var flavours: [Flavour] = []
        for (index, path) in paths.enumerated() {
            flavours.append(Fixtures.fileURL(path, itemIndex: index))
            flavours.append(Flavour(
                itemIndex: index,
                type: PasteboardTypes.utf8Text,
                data: Data((path as NSString).lastPathComponent.utf8)
            ))
            flavours.append(Flavour(
                itemIndex: index,
                type: PasteboardTypes.tiff,
                data: Fixtures.pngData
            ))
            flavours.append(Flavour(
                itemIndex: index,
                type: "com.apple.icns",
                data: Fixtures.pngData
            ))
        }
        return flavours
    }

    func beginEditing(
        session: inout NoteEditingSession,
        entryID: Int64,
        previousEntries: [ClipboardEntry],
        filterActive: Bool
    ) {
        _ = session.applyResults(
            reason: .beginEditing,
            currentSelectionID: entryID,
            previousVisibleEntryIDs: previousEntries.map(\.id),
            filterActive: filterActive,
            commitDraft: { nil },
            load: { previousEntries },
            entryIDFor: \.id
        )
    }

    func applyResults(
        session: inout NoteEditingSession,
        drafts: inout NoteDraftBuffer,
        reason: NoteEditingSession.ResultsReason,
        currentSelectionID: Int64?,
        previousEntries: [ClipboardEntry],
        filterActive: Bool,
        history: ClipboardHistory,
        onPersist: ((Int64) -> Void)? = nil,
        preserveDraftOnRefresh: Bool = false,
        load: () throws -> [ClipboardEntry]
    ) throws -> NoteEditingSession.AppliedResults<ClipboardEntry> {
        let isEditing = session.isEditing
        let editingID = session.entryID
        var preservedDraft: (Int64, String)?

        let applied = try session.applyResults(
            reason: reason,
            currentSelectionID: currentSelectionID,
            previousVisibleEntryIDs: previousEntries.map(\.id),
            filterActive: filterActive,
            commitDraft: {
                if case .refresh = reason,
                   preserveDraftOnRefresh,
                   isEditing,
                   let editingID,
                   let draft = drafts.draft(for: editingID)
                {
                    preservedDraft = (editingID, draft)
                    return nil
                }
                return drafts.commit { id, note in
                    onPersist?(id)
                    do {
                        guard try history.setNote(id, note) != nil else {
                            return "entry \(id) no longer exists"
                        }
                        return nil
                    } catch {
                        return String(describing: error)
                    }
                }
            },
            load: load,
            entryIDFor: \.id
        )

        var visibleEntries = applied.entries
        if let (preservedID, _) = preservedDraft {
            if !visibleEntries.contains(where: { $0.id == preservedID }) {
                _ = drafts.commit { id, note in
                    onPersist?(id)
                    do {
                        guard try history.setNote(id, note) != nil else {
                            return "entry \(id) no longer exists"
                        }
                        return nil
                    } catch {
                        return String(describing: error)
                    }
                }
            }
        }
        for index in visibleEntries.indices {
            if let draft = drafts.draft(for: visibleEntries[index].id) {
                visibleEntries[index].note = draft
            }
        }
        return NoteEditingSession.AppliedResults(entries: visibleEntries, transition: applied.transition)
    }

    // MARK: - File entries display like CopyQ

    TestRunner.add("a Finder file copy displays the file name, not the icon image") {
        let path = "/Users/example/Downloads/CopyQ-17.0.0-macos-13-m1.dmg"
        let preview = FlavourDecoder.preview(for: finderFileCopy([path]))
        expectEqual(preview.kind, .files)
        expectEqual(preview.text, "CopyQ-17.0.0-macos-13-m1.dmg")
        expectEqual(preview.fileNames, ["CopyQ-17.0.0-macos-13-m1.dmg"])
        expectNil(preview.imageData, "the icon flavours must not win the preview")
        expectEqual(preview.imageType, nil)
        let searchText = FlavourDecoder.searchText(for: preview)
        expect(searchText.contains("CopyQ-17.0.0-macos-13-m1.dmg"), "search text must carry the file name")
        expect(searchText.contains(path), "search text must still carry the full path")
        expect(!searchText.contains("Image "), "search text must not be the icon summary")
    }

    TestRunner.add("equivalent file URL representations appear once per clipboard item") {
        let path = "/tmp/repeated.txt"
        let legacy = Flavour(
            itemIndex: 0,
            type: PasteboardTypes.legacyFilenames,
            data: try PropertyListSerialization.data(fromPropertyList: [path, path], format: .xml, options: 0)
        )
        let preview = FlavourDecoder.preview(for: finderFileCopy([path, path]) + [legacy])
        expectEqual(preview.fileURLs.count, 2)
        expectEqual(preview.fileNames, ["repeated.txt", "repeated.txt"])
        expectEqual(preview.text, "repeated.txt\nrepeated.txt")
        expectEqual(preview.searchText?.components(separatedBy: path).count, 3)
    }

    TestRunner.add("multiple files list one name per line") {
        let preview = FlavourDecoder.preview(for: finderFileCopy([
            "/tmp/report.pdf", "/tmp/holiday.png", "/tmp/notes.txt",
        ]))
        expectEqual(preview.kind, .files)
        expectEqual(preview.text, "report.pdf\nholiday.png\nnotes.txt")
        expectEqual(preview.fileNames, ["report.pdf", "holiday.png", "notes.txt"])
    }

    TestRunner.add("a file copied from Finder is stored and shown by name") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let path = "/Users/example/Documents/quarterly-report.pdf"
        _ = try history.record(finderFileCopy([path]))
        let stored = try history.recent(limit: 10)
        expectEqual(stored.count, 1)
        guard let entry = stored.first else { return }
        expectEqual(FlavourDecoder.preview(for: entry.flavours).text, "quarterly-report.pdf")
        expectEqual(try history.search("quarterly-report").count, 1)
        expectEqual(try history.search("Documents").count, 1)
    }

    TestRunner.add("file entries keep every flavour so paste-back still pastes the file") {
        let store = try ClipboardStore(inMemory: true)
        let flavours = finderFileCopy(["/tmp/payload.bin"])
        let stored = try store.insert(ClipboardEntry(createdAt: Date(), flavours: flavours))
        guard let loaded = try store.entry(id: stored.id) else {
            TestRunner.fail("entry did not come back")
            return
        }
        expectNotNil(loaded.flavours.first { $0.type == PasteboardTypes.fileURL })
        expectNotNil(loaded.flavours.first { $0.type == PasteboardTypes.legacyFilenames || $0.type == "com.apple.icns" })
        expectEqual(loaded.flavours.count, flavours.count)
    }

    TestRunner.add("an image with no file URL is still an image entry") {
        let preview = FlavourDecoder.preview(for: [
            Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData),
        ])
        expectEqual(preview.kind, .image)
        expectNotNil(preview.imageData)
    }

    // MARK: - File entries as text

    TestRunner.add("a file entry shows the file name as its text") {
        let path = "/Users/example/Downloads/quarterly-report.pdf"
        let entry = ClipboardEntry(createdAt: Date(), flavours: finderFileCopy([path]))
        let presentation = EntryPresentation(entry: entry)
        expectEqual(presentation.kind, .files)
        expectNil(presentation.primaryText)
        expectEqual(presentation.fileNames, ["quarterly-report.pdf"])
        expectEqual(presentation.fileCount, 1)
        expectEqual(presentation.fileIconPath, path)
    }

    TestRunner.add("a cached file row keeps every file name") {
        let paths = [
            "/tmp/first.txt", "/tmp/second.txt", "/tmp/third.txt",
            "/tmp/fourth.txt", "/tmp/fifth.txt",
        ]
        let entry = ClipboardEntry(createdAt: Date(), flavours: finderFileCopy(paths))
        let presentation = EntryPresentation(entry: entry).discardingFullPreviewData()
        expectEqual(presentation.fileNames, [
            "first.txt", "second.txt", "third.txt", "fourth.txt", "fifth.txt",
        ])
        expectNil(presentation.primaryText)
        expectEqual(presentation.fileCount, 5)
    }

    TestRunner.add("a file entry lists one name per file") {
        let paths = ["/tmp/report.pdf", "/tmp/holiday.png", "/tmp/notes.txt"]
        let entry = ClipboardEntry(createdAt: Date(), flavours: finderFileCopy(paths))
        let presentation = EntryPresentation(entry: entry)
        expectNil(presentation.primaryText)
        expectEqual(presentation.fileNames, ["report.pdf", "holiday.png", "notes.txt"])
        expectEqual(presentation.fileCount, 3)
    }

    TestRunner.add("a file entry is still found by its name in the store") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record(finderFileCopy(["/Users/example/Documents/quarterly-report.pdf"]))
        expectEqual(try history.search("quarterly-report").count, 1)
        expectEqual(try history.search("Documents").count, 1)
    }

    TestRunner.add("a file entry remains searchable beyond its displayed names") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let paths = [
            "/tmp/first.txt", "/tmp/second.txt", "/tmp/third.txt",
            "/tmp/fourth.txt", "/tmp/fifthsearchneedle.txt",
        ]
        _ = try history.record(finderFileCopy(paths))
        expectEqual(try history.search("fifthsearchneedle").count, 1)
    }

    TestRunner.add("a file entry stays searchable after the row drops its preview data") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let paths = [
            "/tmp/first.txt", "/tmp/second.txt", "/tmp/third.txt",
            "/tmp/fourth.txt", "/tmp/fifthsearchneedle.txt",
        ]
        let recorded = try history.record(finderFileCopy(paths))
        guard case .inserted(let entry) = recorded else {
            TestRunner.fail("the file entry was not inserted")
            return
        }
        // What an unselected row holds: the payload is dropped, the names stay.
        let cached = EntryPresentation(entry: entry).discardingFullPreviewData()
        expectEqual(cached.fileCount, 5)
        expectEqual(try history.search("fifthsearchneedle").count, 1)
        expectEqual(try history.search("second").count, 1)
    }

    // MARK: - Accessibility notice

    TestRunner.add("the permission notice disappears once the app is trusted") {
        let notice = AccessibilityNoticePolicy.pasteNeedsPermission
        expectEqual(AccessibilityNoticePolicy.isPermissionNotice(notice), true)
        expectNil(AccessibilityNoticePolicy.notice(current: notice, trusted: true))
    }

    TestRunner.add("the permission notice stays while the app is untrusted") {
        let notice = AccessibilityNoticePolicy.pasteNeedsPermission
        expectEqual(
            AccessibilityNoticePolicy.notice(current: notice, trusted: false),
            notice
        )
        expectEqual(
            AccessibilityNoticePolicy.notice(
                current: notice,
                trusted: false,
                grantLooksStale: true
            ),
            AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant
        )
        expectEqual(
            AccessibilityNoticePolicy.notice(current: AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant, trusted: false),
            AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant
        )
    }

    TestRunner.add("the stale-grant notice is retired the same way") {
        expectEqual(
            AccessibilityNoticePolicy.isPermissionNotice(AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant),
            true
        )
        expectNil(
            AccessibilityNoticePolicy.notice(
                current: AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant,
                trusted: true
            )
        )
    }

    TestRunner.add("an unrelated notice survives a permission change") {
        let notice = "Could not read the clipboard store."
        expectEqual(AccessibilityNoticePolicy.isPermissionNotice(notice), false)
        expectEqual(AccessibilityNoticePolicy.notice(current: notice, trusted: true), notice)
        expectNil(AccessibilityNoticePolicy.notice(current: nil, trusted: true))
    }

    TestRunner.add("upgrading from schema 3 reindexes file entries by name") {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path

        let store = try ClipboardStore(path: path)
        let fileEntry = try store.insert(
            ClipboardEntry(createdAt: Date(), flavours: finderFileCopy(["/tmp/annual-budget.xlsx"]))
        )
        let textEntry = try store.insert(
            ClipboardEntry(createdAt: Date(), flavours: [Fixtures.text("plain text entry")])
        )

        // Reproduce what the previous build indexed for a file copy: the icon
        // image summary instead of the file name.
        let stale = try store.database.prepare(
            "INSERT OR REPLACE INTO search_fts (rowid, text) VALUES (?, ?)"
        )
        defer { stale.finalize() }
        try stale.bind(1, fileEntry.id)
        try stale.bind(2, "Image 1024x1024 (icns)")
        try stale.run()
        store.database.userVersion = 3

        // Reopening runs the schema-4 migration.
        let upgraded = try ClipboardStore(path: path)
        expectEqual(upgraded.database.userVersion, ClipboardStore.currentSchemaVersion)
        expectEqual(try upgraded.search("annual-budget").map(\.id), [fileEntry.id])
        expectEqual(try upgraded.search("Image 1024x1024").count, 0)
        expectEqual(try upgraded.search("plain text entry").map(\.id), [textEntry.id])
    }

    // MARK: - Accessibility

    TestRunner.add("the first untrusted paste attempt asks macOS for Accessibility") {
        var permission = AccessibilityPermission()
        expectEqual(permission.shouldPrompt(trusted: false), true)
        expectEqual(permission.promptRequested, true)
    }

    TestRunner.add("later paste attempts do not re-prompt and a trusted process never prompts") {
        var permission = AccessibilityPermission()
        expectEqual(permission.shouldPrompt(trusted: false), true)
        expectEqual(permission.shouldPrompt(trusted: false), false)
        var trusted = AccessibilityPermission()
        expectEqual(trusted.shouldPrompt(trusted: true), false)
    }

    TestRunner.add("the status-bar Accessibility item stops the next paste from prompting again") {
        var permission = AccessibilityPermission()
        permission.markRequested()
        expectEqual(permission.shouldPrompt(trusted: false), false)
        expectEqual(permission.shouldPrompt(trusted: false), false)
    }

    TestRunner.add("becoming trusted forgets the prompt so a later revocation can ask once") {
        var permission = AccessibilityPermission()
        expectEqual(permission.shouldPrompt(trusted: false), true)
        expectEqual(permission.shouldPrompt(trusted: true), false)
        expectEqual(permission.promptRequested, false)
        expectEqual(permission.shouldPrompt(trusted: false), true)
    }

    TestRunner.add("clearing the requested state lets the next untrusted check ask once") {
        var permission = AccessibilityPermission()
        permission.markRequested()
        expectEqual(permission.shouldPrompt(trusted: false), false)
        permission.clearRequested()
        expectEqual(permission.shouldPrompt(trusted: false), true)
    }

    // MARK: - Selection after editing a note

    TestRunner.add("changing the selection while editing a note commits and blurs the editor first") {
        let plan = SelectionChangePolicy.plan(current: 1, next: 2, noteEditing: true)
        expectNotNil(plan)
        expectEqual(plan?.commitNote, true)
        expectEqual(plan?.blurNote, true)
    }

    TestRunner.add("changing the selection with no note editor open does not commit or blur") {
        let plan = SelectionChangePolicy.plan(current: 1, next: 2, noteEditing: false)
        expectNotNil(plan)
        expectEqual(plan?.commitNote, false)
        expectEqual(plan?.blurNote, false)
    }

    TestRunner.add("clicking the row that is already selected changes nothing") {
        expectNil(SelectionChangePolicy.plan(current: 3, next: 3, noteEditing: true))
        expectNil(SelectionChangePolicy.plan(current: nil, next: nil, noteEditing: true))
        expectNotNil(SelectionChangePolicy.plan(current: nil, next: 3, noteEditing: false))
    }

    TestRunner.add("selection movement keys are handled even while the note editor is focused") {
        for key in [ListKey.up, .down, .pageUp, .pageDown, .home, .end] {
            expect(
                ListInteractionPolicy.handles(key, noteEditing: true, searchEmpty: true),
                "\(key) must still move the selection while editing a note"
            )
            expect(
                ListInteractionPolicy.handles(key, noteEditing: true, searchEmpty: true, focus: .sidebar),
                "\(key) must still move the selection while editing a note from the sidebar"
            )
            expect(
                ListInteractionPolicy.handles(key, noteEditing: false, searchEmpty: false),
                "\(key) must move the selection with no editor focused"
            )
        }
    }

    TestRunner.add("Return and Backspace keep editing the note while it has focus") {
        expectEqual(ListInteractionPolicy.handles(.enter, noteEditing: true, searchEmpty: true), false)
        expectEqual(ListInteractionPolicy.handles(.delete, noteEditing: true, searchEmpty: true), false)
        expectEqual(ListInteractionPolicy.handles(.delete, noteEditing: true, searchEmpty: false, commandHeld: true), false)
        expectEqual(
            ListInteractionPolicy.handles(.enter, noteEditing: true, searchEmpty: true, focus: .sidebar),
            false
        )
        expectEqual(
            ListInteractionPolicy.handles(.delete, noteEditing: true, searchEmpty: true, focus: .sidebar),
            false
        )
        expectEqual(ListInteractionPolicy.handles(.enter, noteEditing: false, searchEmpty: false), true)
    }

    TestRunner.add("Escape leaves the note editor before closing the window") {
        expectEqual(ListInteractionPolicy.handles(.escape, noteEditing: true, searchEmpty: false), true)
        expectEqual(ListInteractionPolicy.handles(.escape, noteEditing: false, searchEmpty: false), true)
    }

    TestRunner.add("holding Return, Escape, or Delete does not repeat its action") {
        expectEqual(ListInteractionPolicy.ignoresKeyRepeat(.enter), true)
        expectEqual(ListInteractionPolicy.ignoresKeyRepeat(.escape), true)
        expectEqual(ListInteractionPolicy.ignoresKeyRepeat(.delete), true)
        for key in [ListKey.up, .down, .pageUp, .pageDown, .home, .end] {
            expectEqual(ListInteractionPolicy.ignoresKeyRepeat(key), false, "\(key) should still repeat")
        }
    }

    TestRunner.add("Backspace keeps editing the filter until it is empty") {
        expectEqual(ListInteractionPolicy.handles(.delete, noteEditing: false, searchEmpty: false), false)
        expectEqual(ListInteractionPolicy.handles(.delete, noteEditing: false, searchEmpty: true), true)
        expectEqual(
            ListInteractionPolicy.handles(.delete, noteEditing: false, searchEmpty: false, commandHeld: true),
            true
        )
    }

    TestRunner.add("Backspace does not delete an entry with nothing focused") {
        expectEqual(
            ListInteractionPolicy.handles(
                .delete, noteEditing: false, searchEmpty: true, focus: .none
            ),
            false
        )
        expectEqual(
            ListInteractionPolicy.handles(
                .delete, noteEditing: false, searchEmpty: false, commandHeld: true, focus: .none
            ),
            false
        )
        // Movement keys still work with nothing focused, which is what keeps the
        // list usable right after the note editor gives up focus.
        expectEqual(
            ListInteractionPolicy.handles(
                .down, noteEditing: false, searchEmpty: true, focus: .none
            ),
            true
        )
    }

    // MARK: - Keeping the selection visible

    TestRunner.add("a selected row that is on screen does not ask the list to scroll") {
        // Arrow navigation stays inside the viewport for most key presses; a
        // scroll on every one of them is what made the list hitch.
        expectNil(SelectionRevealPolicy.rowToReveal(selectedRow: 4, visibleRows: 3..<9))
        expectNil(SelectionRevealPolicy.rowToReveal(selectedRow: 3, visibleRows: 3..<9))
        expectNil(SelectionRevealPolicy.rowToReveal(selectedRow: 8, visibleRows: 3..<9))
    }

    TestRunner.add("a selected row off screen is revealed by the list") {
        expectEqual(SelectionRevealPolicy.rowToReveal(selectedRow: 2, visibleRows: 3..<9), 2)
        expectEqual(SelectionRevealPolicy.rowToReveal(selectedRow: 9, visibleRows: 3..<9), 9)
        expectEqual(SelectionRevealPolicy.rowToReveal(selectedRow: 0, visibleRows: 3..<9), 0)
        expectNil(SelectionRevealPolicy.rowToReveal(selectedRow: nil, visibleRows: 3..<9))
        expectNil(SelectionRevealPolicy.rowToReveal(selectedRow: -1, visibleRows: 0..<9))
    }

    TestRunner.add("an unfiltered capture selects and reveals the new row over an older selection") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        _ = try history.record([Fixtures.text("first")])
        _ = try history.record([Fixtures.text("second")])
        let older = try history.record([Fixtures.text("older selection")])
        guard case .inserted(let olderEntry) = older else {
            TestRunner.fail("older entry was not inserted")
            return
        }

        let previousVisibleIDs = try history.recent(limit: 10).map(\.id)
        let capture = try history.record([Fixtures.text("new capture")])
        guard case .inserted(let capturedEntry) = capture else {
            TestRunner.fail("new capture was not inserted")
            return
        }
        let entries = try history.recent(limit: 10)
        let visibleIDs = entries.map(\.id)
        let selected = CaptureSelectionPolicy.selectedEntryID(
            current: olderEntry.id,
            captured: capturedEntry.id,
            previousVisibleEntryIDs: previousVisibleIDs,
            visibleEntryIDs: visibleIDs,
            filterActive: false
        )
        expectEqual(selected, capturedEntry.id)
        expectEqual(entries.firstIndex { $0.id == selected }, 0)
    }

    TestRunner.add("an active filter preserves the selection and reveals that row on capture") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let older = try history.record([Fixtures.text("filtertoken selected older")])
        guard case .inserted(let selectedEntry) = older else {
            TestRunner.fail("selected entry was not inserted")
            return
        }
        _ = try history.record([Fixtures.text("filtertoken other newer")])
        let previousFilteredIDs = try history.search("filtertoken").map(\.id)
        let capture = try history.record([Fixtures.text("unmatched new capture")])
        guard case .inserted(let capturedEntry) = capture else {
            TestRunner.fail("new capture was not inserted")
            return
        }

        let filteredIDs = try history.search("filtertoken").map(\.id)
        expectEqual(filteredIDs.count, 2)
        expectEqual(filteredIDs.last, selectedEntry.id)
        let selected = CaptureSelectionPolicy.selectedEntryID(
            current: selectedEntry.id,
            captured: capturedEntry.id,
            previousVisibleEntryIDs: previousFilteredIDs,
            visibleEntryIDs: filteredIDs,
            filterActive: true
        )
        expectEqual(selected, selectedEntry.id)
        expectEqual(filteredIDs.firstIndex { $0 == selected }, 1)
    }

    TestRunner.add("capture eviction commits an edited note before deleting its entry") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        var preferences = try history.preferences()
        preferences.defaultMaxItems = 2
        try history.setPreferences(preferences)

        let selected = try history.record([Fixtures.text("edited oldest")], at: Date(timeIntervalSince1970: 1))
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        _ = try history.record([Fixtures.text("nearest survivor")], at: Date(timeIntervalSince1970: 2))
        let previousEntries = try history.recent(limit: 10)
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: false)
        var drafts = NoteDraftBuffer()
        let noteDraft = "uncommitted note draft"
        drafts.set(noteDraft, for: editedEntry.id)
        var noteWrites: [Int64] = []
        var savedBeforeDeletion: String?
        var result: NoteEditingSession.AppliedResults<ClipboardEntry>?
        history.onEntriesWillBeTrimmed = { evictedIDs, reason in
            expectEqual(reason, .capture)
            result = try? applyResults(
                session: &session,
                drafts: &drafts,
                reason: .eviction(entryIDs: evictedIDs, fromCapture: true),
                currentSelectionID: editedEntry.id,
                previousEntries: previousEntries,
                filterActive: false,
                history: history,
                onPersist: { noteWrites.append($0) },
                load: { previousEntries.filter { !evictedIDs.contains($0.id) } }
            )
            savedBeforeDeletion = try? history.store.entry(id: editedEntry.id)?.note
        }

        let capture = try history.record([Fixtures.text("new capture")], at: Date(timeIntervalSince1970: 3))
        history.onEntriesWillBeTrimmed = nil
        guard case .inserted(let capturedEntry) = capture else {
            TestRunner.fail("new capture was not inserted")
            return
        }
        expectEqual(savedBeforeDeletion, noteDraft)
        expectEqual(drafts.isEmpty, true)
        expectEqual(session.isEditing, false)
        expectNil(session.entryID)
        expectNotNil(result?.transition.notice)
        expectEqual(result?.transition.endedEditing, true)
        expectEqual(noteWrites, [editedEntry.id])
        expectNil(try history.store.entry(id: editedEntry.id))
        expectEqual(result?.transition.selectedEntryID, previousEntries.first?.id)
        expectNotEqual(result?.transition.selectedEntryID, capturedEntry.id)
        expectEqual(session.entryID, nil)
    }

    TestRunner.add("filtered capture eviction ends note editing and selects a surviving match") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        var preferences = try history.preferences()
        preferences.defaultMaxItems = 2
        try history.setPreferences(preferences)

        let selected = try history.record(
            [Fixtures.text("filtertoken edited oldest")], at: Date(timeIntervalSince1970: 1)
        )
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        let survivor = try history.record(
            [Fixtures.text("filtertoken nearest survivor")], at: Date(timeIntervalSince1970: 2)
        )
        guard case .inserted(let survivorEntry) = survivor else {
            TestRunner.fail("surviving filtered entry was not inserted")
            return
        }
        let previousEntries = try history.search("filtertoken")

        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: true)
        var drafts = NoteDraftBuffer()
        let noteDraft = "filtered uncommitted draft"
        drafts.set(noteDraft, for: editedEntry.id)
        var noteWrites: [Int64] = []
        var result: NoteEditingSession.AppliedResults<ClipboardEntry>?
        var savedBeforeDeletion: String?
        history.onEntriesWillBeTrimmed = { evictedIDs, reason in
            expectEqual(reason, .capture)
            result = try? applyResults(
                session: &session,
                drafts: &drafts,
                reason: .eviction(entryIDs: evictedIDs, fromCapture: true),
                currentSelectionID: editedEntry.id,
                previousEntries: previousEntries,
                filterActive: true,
                history: history,
                onPersist: { noteWrites.append($0) },
                load: { previousEntries.filter { !evictedIDs.contains($0.id) } }
            )
            savedBeforeDeletion = try? history.store.entry(id: editedEntry.id)?.note
        }

        let capture = try history.record([Fixtures.text("unmatched capture")], at: Date(timeIntervalSince1970: 3))
        history.onEntriesWillBeTrimmed = nil
        guard case .inserted(let capturedEntry) = capture else {
            TestRunner.fail("new capture was not inserted")
            return
        }
        expectEqual(savedBeforeDeletion, noteDraft)
        expectEqual(drafts.isEmpty, true)
        expectEqual(session.isEditing, false)
        expectNil(session.entryID)
        expectEqual(result?.transition.endedEditing, true)
        expectEqual(noteWrites, [editedEntry.id])
        expectNil(try history.store.entry(id: editedEntry.id))
        expectEqual(result?.transition.selectedEntryID, survivorEntry.id)
        expectNotEqual(result?.transition.selectedEntryID, capturedEntry.id)
        expectEqual(session.entryID, nil)
    }

    TestRunner.add("search text change commits a draft before the edited entry leaves results") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let selected = try history.record([Fixtures.text("plain body")], at: Date(timeIntervalSince1970: 1))
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        _ = try history.setNote(editedEntry.id, "needle only in note")
        let survivor = try history.record([Fixtures.text("payload needle")], at: Date(timeIntervalSince1970: 2))
        guard case .inserted(let survivorEntry) = survivor else {
            TestRunner.fail("surviving entry was not inserted")
            return
        }
        let previousEntries = try history.search("needle")
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: true)
        var drafts = NoteDraftBuffer()
        drafts.set("draft no longer matches", for: editedEntry.id)
        var noteWrites: [Int64] = []
        let applied = try applyResults(
            session: &session,
            drafts: &drafts,
            reason: .refresh(capturedEntryID: nil),
            currentSelectionID: editedEntry.id,
            previousEntries: previousEntries,
            filterActive: true,
            history: history,
            onPersist: { noteWrites.append($0) },
            load: { try history.search("payload") }
        )
        expectEqual(try history.store.entry(id: editedEntry.id)?.note, "draft no longer matches")
        expectEqual(drafts.isEmpty, true)
        expectEqual(session.isEditing, false)
        expectNil(session.entryID)
        expectEqual(applied.transition.endedEditing, true)
        expectEqual(applied.transition.selectedEntryID, survivorEntry.id)
        expectNotNil(applied.transition.notice)
        expectEqual(noteWrites, [editedEntry.id])
        if let editingID = session.entryID {
            noteWrites.append(editingID)
            _ = try history.setNote(editingID, "late write")
        }
        expectEqual(noteWrites, [editedEntry.id])
    }

    TestRunner.add("note-save refresh ends editing when the saved note leaves search results") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let selected = try history.record([Fixtures.text("plain body")], at: Date(timeIntervalSince1970: 1))
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        _ = try history.setNote(editedEntry.id, "needle only in note")
        let survivor = try history.record([Fixtures.text("payload needle")], at: Date(timeIntervalSince1970: 2))
        guard case .inserted(let survivorEntry) = survivor else {
            TestRunner.fail("surviving entry was not inserted")
            return
        }
        let previousEntries = try history.search("needle")
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: true)
        _ = try history.setNote(editedEntry.id, "already committed no query token")
        var drafts = NoteDraftBuffer()
        let applied = try applyResults(
            session: &session,
            drafts: &drafts,
            reason: .refresh(capturedEntryID: nil),
            currentSelectionID: editedEntry.id,
            previousEntries: previousEntries,
            filterActive: true,
            history: history,
            load: { try history.search("needle") }
        )
        expectEqual(session.isEditing, false)
        expectNil(session.entryID)
        expectEqual(applied.transition.endedEditing, true)
        expectEqual(applied.transition.selectedEntryID, survivorEntry.id)
        expectNotNil(applied.transition.notice)
    }

    TestRunner.add("reload keeps the edited entry bound when its row moves") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let selected = try history.record([Fixtures.text("needle edited row")], at: Date(timeIntervalSince1970: 1))
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        _ = try history.record([Fixtures.text("needle other row")], at: Date(timeIntervalSince1970: 2))
        let previousEntries = try history.search("needle")
        let previousIndex = previousEntries.firstIndex { $0.id == editedEntry.id }
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: true)
        var drafts = NoteDraftBuffer()
        let captured = try history.record([Fixtures.text("needle newest row")], at: Date(timeIntervalSince1970: 3))
        guard case .inserted(let capturedEntry) = captured else {
            TestRunner.fail("new matching entry was not inserted")
            return
        }
        let applied = try applyResults(
            session: &session,
            drafts: &drafts,
            reason: .refresh(capturedEntryID: capturedEntry.id),
            currentSelectionID: editedEntry.id,
            previousEntries: previousEntries,
            filterActive: true,
            history: history,
            load: { try history.search("needle") }
        )
        expectEqual(session.isEditing, true)
        expectEqual(session.entryID, editedEntry.id)
        expectEqual(applied.transition.endedEditing, false)
        expectEqual(applied.transition.selectedEntryID, editedEntry.id)
        expectNotEqual(previousIndex, applied.entries.firstIndex { $0.id == editedEntry.id })
        if let editingID = session.entryID {
            _ = try history.setNote(editingID, "still bound to edited row")
        }
        expectEqual(try history.store.entry(id: editedEntry.id)?.note, "still bound to edited row")
        expectEqual(try history.store.entry(id: capturedEntry.id)?.note, "")
    }

    TestRunner.add("clearing the filter commits a draft and keeps its edited entry selected") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let selected = try history.record([Fixtures.text("filter-clear payload")])
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        _ = try history.setNote(editedEntry.id, "needle note")
        let previousEntries = try history.search("needle")
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: true)
        var drafts = NoteDraftBuffer()
        drafts.set("draft after clearing filter", for: editedEntry.id)
        let applied = try applyResults(
            session: &session,
            drafts: &drafts,
            reason: .refresh(capturedEntryID: nil),
            currentSelectionID: editedEntry.id,
            previousEntries: previousEntries,
            filterActive: false,
            history: history,
            load: { try history.recent(limit: 10) }
        )
        expectEqual(try history.store.entry(id: editedEntry.id)?.note, "draft after clearing filter")
        expectEqual(drafts.isEmpty, true)
        expectEqual(session.isEditing, true)
        expectEqual(session.entryID, editedEntry.id)
        expectEqual(applied.transition.selectedEntryID, editedEntry.id)
    }

    TestRunner.add("tab switch commits the note and selects an entry in the new result set") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let firstTab = try history.defaultTab()
        let secondTab = try history.addTab(name: "Second")
        let selected = try history.record([Fixtures.text("first-tab entry")], into: firstTab)
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        let target = try history.record([Fixtures.text("second-tab entry")], into: secondTab)
        guard case .inserted(let targetEntry) = target else {
            TestRunner.fail("new tab entry was not inserted")
            return
        }
        let previousEntries = try history.recent(limit: 10, tabID: firstTab.id)
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: false)
        var drafts = NoteDraftBuffer()
        drafts.set("tab switch draft", for: editedEntry.id)
        let applied = try applyResults(
            session: &session,
            drafts: &drafts,
            reason: .first,
            currentSelectionID: editedEntry.id,
            previousEntries: previousEntries,
            filterActive: false,
            history: history,
            load: { try history.recent(limit: 10, tabID: secondTab.id) }
        )
        expectEqual(try history.store.entry(id: editedEntry.id)?.note, "tab switch draft")
        expectEqual(session.isEditing, false)
        expectNil(session.entryID)
        expectEqual(applied.transition.endedEditing, true)
        expectEqual(applied.transition.selectedEntryID, targetEntry.id)
        expectNotNil(applied.transition.notice)
        expectEqual(applied.entries.map(\.id), [targetEntry.id])
    }

    TestRunner.add("explicit selection commits and detaches the editor before changing rows") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let first = try history.record([Fixtures.text("first selectable row")])
        guard case .inserted(let editedEntry) = first else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        let second = try history.record([Fixtures.text("second selectable row")])
        guard case .inserted(let nextEntry) = second else {
            TestRunner.fail("next entry was not inserted")
            return
        }
        let previousEntries = try history.recent(limit: 10)
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: false)
        var drafts = NoteDraftBuffer()
        drafts.set("selection commit", for: editedEntry.id)
        let applied = try applyResults(
            session: &session,
            drafts: &drafts,
            reason: .selectionOnly(selected: nextEntry.id),
            currentSelectionID: editedEntry.id,
            previousEntries: previousEntries,
            filterActive: false,
            history: history,
            load: { try history.recent(limit: 10) }
        )
        expectEqual(try history.store.entry(id: editedEntry.id)?.note, "selection commit")
        expectEqual(session.isEditing, false)
        expectNil(session.entryID)
        expectEqual(applied.transition.selectedEntryID, nextEntry.id)
        expectEqual(drafts.isEmpty, true)
    }

    TestRunner.add("a selection change does not read the store again") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let first = try history.record([Fixtures.text("row one")])
        guard case .inserted(let firstEntry) = first else {
            TestRunner.fail("first entry was not inserted")
            return
        }
        let second = try history.record([Fixtures.text("row two")])
        guard case .inserted(let secondEntry) = second else {
            TestRunner.fail("second entry was not inserted")
            return
        }
        let visibleEntries = try history.recent(limit: 10)
        var session = NoteEditingSession()
        var storeReads = 0
        let applied = session.applyResults(
            reason: .selectionOnly(selected: secondEntry.id),
            currentSelectionID: firstEntry.id,
            previousVisibleEntryIDs: visibleEntries.map(\.id),
            filterActive: false,
            commitDraft: { nil },
            load: {
                storeReads += 1
                return visibleEntries
            },
            entryIDFor: \.id
        )
        expectEqual(storeReads, 0, "a selection change must not read the store")
        expectEqual(applied.transition.selectedEntryID, secondEntry.id)
        expectEqual(applied.transition.endedEditing, false)
        expectEqual(applied.entries.count, 0, "the visible entries did not change")
    }

    TestRunner.add("failed result-boundary saves retain drafts for a later retry") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let selected = try history.record([Fixtures.text("plain body")], at: Date(timeIntervalSince1970: 1))
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        _ = try history.setNote(editedEntry.id, "needle only in note")
        let survivor = try history.record([Fixtures.text("payload needle")], at: Date(timeIntervalSince1970: 2))
        guard case .inserted(let survivorEntry) = survivor else {
            TestRunner.fail("surviving entry was not inserted")
            return
        }
        let previousEntries = try history.search("needle")
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: true)
        var drafts = NoteDraftBuffer()
        drafts.set("recoverable draft", for: editedEntry.id)
        let failed = try session.applyResults(
            reason: .refresh(capturedEntryID: nil),
            currentSelectionID: editedEntry.id,
            previousVisibleEntryIDs: previousEntries.map(\.id),
            filterActive: true,
            commitDraft: { drafts.commit { _, _ in "database is temporarily unavailable" } },
            load: { try history.search("payload") },
            entryIDFor: \.id
        )
        expectEqual(drafts.draft(for: editedEntry.id), "recoverable draft")
        expectEqual(session.isEditing, false)
        expectNil(session.entryID)
        expectEqual(failed.transition.selectedEntryID, survivorEntry.id)
        expect(failed.transition.notice?.contains("could not be saved") == true)
        expectEqual(try history.store.entry(id: editedEntry.id)?.note, "needle only in note")

        let retried = try session.applyResults(
            reason: .refresh(capturedEntryID: nil),
            currentSelectionID: survivorEntry.id,
            previousVisibleEntryIDs: failed.entries.map(\.id),
            filterActive: false,
            commitDraft: {
                drafts.commit { id, note in
                    do {
                        guard try history.setNote(id, note) != nil else { return "entry disappeared" }
                        return nil
                    } catch {
                        return String(describing: error)
                    }
                }
            },
            load: { try history.recent(limit: 10) },
            entryIDFor: \.id
        )
        expectNil(drafts.draft(for: editedEntry.id))
        expectEqual(try history.store.entry(id: editedEntry.id)?.note, "recoverable draft")
        expectEqual(retried.transition.selectedEntryID, survivorEntry.id)
    }

    TestRunner.add("note editing preserves the selection on capture") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let older = try history.record([Fixtures.text("note stays focused")])
        guard case .inserted(let selectedEntry) = older else {
            TestRunner.fail("selected entry was not inserted")
            return
        }
        let previousEntries = try history.recent(limit: 10)
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: selectedEntry.id, previousEntries: previousEntries, filterActive: false)
        var drafts = NoteDraftBuffer()
        let capture = try history.record([Fixtures.text("capture while editing")])
        guard case .inserted(let capturedEntry) = capture else {
            TestRunner.fail("new capture was not inserted")
            return
        }

        let applied = try applyResults(
            session: &session,
            drafts: &drafts,
            reason: .refresh(capturedEntryID: capturedEntry.id),
            currentSelectionID: selectedEntry.id,
            previousEntries: previousEntries,
            filterActive: false,
            history: history,
            load: { try history.recent(limit: 10) }
        )
        expectEqual(session.isEditing, true)
        expectEqual(session.entryID, selectedEntry.id)
        expectEqual(applied.transition.selectedEntryID, selectedEntry.id)
        expectEqual(applied.entries.firstIndex { $0.id == applied.transition.selectedEntryID }, 1)
    }

    TestRunner.add("a pending draft survives a reload") {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let selected = try history.record([Fixtures.text("plain body")], at: Date(timeIntervalSince1970: 1))
        guard case .inserted(let editedEntry) = selected else {
            TestRunner.fail("edited entry was not inserted")
            return
        }
        let previousEntries = try history.recent(limit: 10)
        var session = NoteEditingSession()
        beginEditing(session: &session, entryID: editedEntry.id, previousEntries: previousEntries, filterActive: false)
        var drafts = NoteDraftBuffer()
        let draftText = "surviving pending draft"
        drafts.set(draftText, for: editedEntry.id)

        let applied = try applyResults(
            session: &session,
            drafts: &drafts,
            reason: .refresh(capturedEntryID: nil),
            currentSelectionID: editedEntry.id,
            previousEntries: previousEntries,
            filterActive: false,
            history: history,
            preserveDraftOnRefresh: true,
            load: { try history.recent(limit: 10) }
        )

        expectEqual(session.isEditing, true)
        expectEqual(session.entryID, editedEntry.id)
        expectEqual(drafts.draft(for: editedEntry.id), draftText)
        expectEqual(applied.entries.first { $0.id == editedEntry.id }?.note, draftText)
    }
}
