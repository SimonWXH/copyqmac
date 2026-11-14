// Capture policy on top of the store: consecutive-duplicate collapsing, the
// global entry bound, and tab/preferences access for the UI. AppKit-free so
// the tests can drive it directly.

import Foundation

public enum HistoryTrimReason: Equatable, Sendable {
    case capture
    case preferenceChange
    case move
}

public enum RecordOutcome: Equatable, Sendable {
    /// A brand new entry was stored.
    case inserted(ClipboardEntry)
    /// The payload matched the current top entry of the tab; the existing entry
    /// was bumped and no new row was written.
    case duplicate(ClipboardEntry)
    /// The snapshot carried no flavours at all, so there was nothing to store.
    case empty
}

public final class ClipboardHistory {
    public let store: ClipboardStore
    public var onEntriesWillBeTrimmed: (([Int64], HistoryTrimReason) -> Void)?
    /// Called when a local content edit could not be written to the tab's sync
    /// folder. The edit itself already succeeded locally.
    public var onSyncEditFailure: ((String) -> Void)?
    /// Overrides the app-side trash location for tests and private stores.
    public var syncTrashRoot: URL?

    public init(store: ClipboardStore) {
        self.store = store
        store.onEntriesWillBeDeleted = { [weak self] entries, preferences in
            guard let self else { return }
            _ = try CopyQSyncDeletion.trashOwnedGroups(
                for: entries,
                in: self.store,
                reason: .localDelete,
                trashRoot: self.syncTrashRoot,
                preferences: preferences
            )
        }
    }

    // MARK: - Capture

    /// Records a capture into the default tab for this machine.
    @discardableResult
    public func record(_ flavours: [Flavour], at date: Date = Date()) throws -> RecordOutcome {
        let tab = try store.defaultTab() ?? store.ensureDefaultTab()
        return try record(flavours, into: tab, at: date)
    }

    /// Records a capture into a specific tab.
    ///
    /// Consecutive duplicates are collapsed: if the newest entry of the tab has
    /// the same payload fingerprint, its timestamp is refreshed so it returns to
    /// the top of the list, but no second row is created.
    @discardableResult
    public func record(_ flavours: [Flavour], into tab: ClipboardTab, at date: Date = Date()) throws -> RecordOutcome {
        guard !flavours.isEmpty else { return .empty }

        if let latest = try store.mostRecentEntryIdentity(tabID: tab.id),
           latest.fingerprint == Fingerprint.of(flavours),
           var bumped = try store.entry(id: latest.id) {
            try adoptSyncStem(of: bumped)
            try store.touch(id: latest.id, at: date)
            bumped.createdAt = date
            return .duplicate(bumped)
        }

        let preferences = try store.preferences()
        let limit = preferences.defaultMaxItems
        let entry = ClipboardEntry(createdAt: date, tabID: tab.id, flavours: flavours)
        let inserted = try store.insert(entry)
        _ = trimAfterChange(tabID: tab.id, to: limit, reason: .capture)
        return .inserted(inserted)
    }

    // MARK: - Entry mutations

    /// Sets the pinned state and writes the item's group back so the other
    /// machine sees the same pin state.
    @discardableResult
    public func setPinned(_ id: Int64, _ pinned: Bool) throws -> ClipboardEntry? {
        guard let before = try store.entry(id: id) else { return nil }
        guard before.pinned != pinned else { return before }
        try recoverSyncOwnership(of: before)
        try store.setPinned(id: id, pinned: pinned)
        try store.markLocalEdit(id: id)
        try writeBackLocalEdit(id: id)
        return try store.entry(id: id)
    }

    /// Sets the note and writes the item's group back so the other machine sees
    /// the same note, even when the content itself did not change.
    @discardableResult
    public func setNote(_ id: Int64, _ note: String) throws -> ClipboardEntry? {
        guard let before = try store.entry(id: id) else { return nil }
        guard before.note != note else { return before }
        try recoverSyncOwnership(of: before)
        try store.setNote(id: id, note: note)
        try store.markLocalEdit(id: id)
        try writeBackLocalEdit(id: id)
        return try store.entry(id: id)
    }

    private func writeBackLocalEdit(id: Int64) throws {
        guard let updated = try store.entry(id: id) else { return }
        if let log = CopyQSyncWriter.shared.updateEntry(
            updated,
            in: store,
            reason: "edit",
            trashRoot: syncTrashRoot
        ), let error = log.error
        {
            onSyncEditFailure?("Saved the item, but could not update its sync folder: \(error)")
        }
    }

    /// Moves an entry to the top of its tab by refreshing its timestamp, the
    /// way a repeated capture does. The entry keeps its id, tab, pin state, and
    /// note; only its place in the newest-first order changes.
    public func moveToTop(_ id: Int64, at date: Date = Date()) throws {
        if let entry = try store.entry(id: id) {
            try adoptSyncStem(of: entry)
        }
        try store.touch(id: id, at: date)
    }

    /// Recovers a durable link to an unowned written group whose payload
    /// matches exactly one row, before the row changes. Rows that already own a
    /// stem are left alone.
    private func recoverSyncOwnership(of entry: ClipboardEntry) throws {
        guard CopyQSyncDeletion.baseName(of: entry) == nil else { return }
        guard let tab = try store.tab(id: entry.tabID) else { return }
        guard let folder = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty
        else { return }
        let normalized = CopyQSyncBridge.normalizePath(folder)
        let written = (try? store.writtenSyncStems(forEntryID: entry.id, folder: normalized)) ?? []
        guard written.isEmpty else { return }
        _ = CopyQSyncBridge.recoverUnlinkedOwnership(
            in: store,
            folder: normalized,
            tabID: entry.tabID
        )
    }

    private func adoptSyncStem(of entry: ClipboardEntry) throws {
        guard let tab = try store.tab(id: entry.tabID),
              let folder = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty
        else { return }
        let normalized = CopyQSyncBridge.normalizePath(folder)
        var candidates = Set<String>()
        for offset in [-0.001, 0, 0.001] {
            let candidate = CopyQSyncBridge.formatTimestamp(entry.createdAt.addingTimeInterval(offset))
            if CopyQSyncWatcher.stemExists(candidate, in: normalized) {
                candidates.insert(candidate)
            }
        }
        _ = CopyQSyncBridge.ownedStem(
            of: entry,
            in: store,
            folder: normalized,
            groupStems: candidates
        )
    }

    /// Replaces the text of an existing entry in place and writes the new
    /// version back to the tab's sync folder.
    ///
    /// The entry keeps its id, tab, creation time, pin state, and note; only
    /// its plain-text flavours, stale text-bearing flavours, fingerprint, and
    /// search row change. A changed save marks the entry locally edited, records
    /// the edit time for the newest-wins rule, and rewrites the entry's file
    /// group under the same stem so the other machine updates the item instead
    /// of seeing a new one. A write that succeeds records the version the row
    /// now reflects and clears the local-edit marker; only an edit whose
    /// write-back failed stays marked as pending. A failed sync write never
    /// fails the edit: the local row keeps the new text and the failure is
    /// logged and reported. A save
    /// whose text matches the entry's original text after trimming surrounding
    /// whitespace is a no-op: it writes nothing, adds no plain-text flavour, and
    /// does not mark the entry locally edited.
    @discardableResult
    public func replaceText(of id: Int64, with text: String) throws -> ClipboardEntry? {
        guard let entry = try store.entry(id: id) else {
            throw EntryTextEditingError.entryNotFound
        }
        _ = try EntryTextEditing.validate(text)
        let originalText = EntryTextEditing.seed(for: entry).text
        if text.trimmingCharacters(in: .whitespacesAndNewlines)
            == originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            return entry
        }
        let flavours = try EntryTextEditing.updatedFlavours(for: entry, text: text)
        if Set(flavours) != Set(entry.flavours) {
            try recoverSyncOwnership(of: entry)
            try store.replaceFlavours(of: id, with: flavours, locallyEdited: true)
            try writeBackLocalEdit(id: id)
            return try store.entry(id: id)
        }
        return try store.entry(id: id)
    }

    /// Replaces the text and styling of an existing entry in place and writes
    /// the new version back to the tab's sync folder.
    ///
    /// The styled editor hands over the document it shows, and this is the only
    /// path that stores it: the entry's own rich format (HTML for an HTML item,
    /// RTF for an RTF item) is rewritten from that document, its plain-text
    /// companions carry the same text, and everything that described the old
    /// content is dropped. A document that encodes to the payload the entry
    /// already holds is a no-op, so re-saving an untouched item neither marks it
    /// locally edited nor rewrites its sync file.
    @discardableResult
    public func replaceRichText(
        of id: Int64,
        with document: StyledTextDocument,
        format: RichTextFormat
    ) throws -> ClipboardEntry? {
        guard let entry = try store.entry(id: id) else {
            throw EntryTextEditingError.entryNotFound
        }
        _ = try EntryTextEditing.validate(document.plainText)
        let flavours = try EntryTextEditing.updatedFlavours(
            for: entry,
            format: format,
            richData: RichTextEncoding.data(for: document, format: format),
            plainText: document.plainText
        )
        if Set(flavours) != Set(entry.flavours) {
            try recoverSyncOwnership(of: entry)
            try store.replaceFlavours(of: id, with: flavours, locallyEdited: true)
            try writeBackLocalEdit(id: id)
        }
        return try store.entry(id: id)
    }

    /// Creates a new entry in `tab` from typed text.
    ///
    /// This is a local history write, not a pasteboard capture. The caller
    /// enqueues the new item through the sync write path when its tab has a sync
    /// folder; the writer only checks the global pause, while
    /// consecutive-duplicate collapsing does not apply because the user asked
    /// for an explicit new item.
    @discardableResult
    public func addItem(withText text: String, in tab: ClipboardTab, at date: Date = Date()) throws -> ClipboardEntry {
        let flavours = try EntryTextEditing.newItemFlavours(for: text)
        let limit = try store.preferences().defaultMaxItems
        let entry = ClipboardEntry(createdAt: date, tabID: tab.id, flavours: flavours)
        let inserted = try store.insert(entry)
        _ = trimAfterChange(tabID: tab.id, to: limit, reason: .capture)
        return inserted
    }

    public func delete(_ id: Int64) throws {
        try store.delete(id: id)
    }

    /// Deletes several entries in one pass. Every victim goes through the same
    /// `onEntriesWillBeDeleted` handler as a single delete, so each owned sync
    /// group is moved to the recoverable trash before its row disappears.
    public func delete(ids: [Int64]) throws {
        try store.delete(ids: ids)
    }

    /// Moves entries into another tab, carrying their sync groups along.
    ///
    /// The disk work runs first and is staged; if persisting the new tab
    /// fails, the files, stems, and trash entries are put back exactly where
    /// they were.
    @discardableResult
    public func move(ids: [Int64], toTabID: Int64) throws -> CopyQSyncRelocationReport {
        guard !ids.isEmpty else { return CopyQSyncRelocationReport() }
        guard let destination = try store.tab(id: toTabID) else {
            throw CopyQSyncBridgeError.invalidSource("The destination tab no longer exists.")
        }
        let entries = try store.entries(ids: ids)
        guard !entries.isEmpty else { return CopyQSyncRelocationReport() }
        let limit = try store.preferences().defaultMaxItems

        var report = try CopyQSyncRelocation.moveOwnedGroups(
            entries: entries,
            to: destination,
            in: store,
            trashRoot: syncTrashRoot
        )
        do {
            try store.moveEntries(ids: entries.map(\.id), toTabID: toTabID)
        } catch {
            CopyQSyncRelocation.rollback(report, in: store)
            throw error
        }
        if let failure = trimAfterChange(tabID: toTabID, to: limit, reason: .move) {
            report.failures.append(
                "Could not trim the destination tab: \(failure.localizedDescription)"
            )
        }
        return report
    }

    private func trimAfterChange(
        tabID: Int64,
        to limit: Int,
        reason: HistoryTrimReason
    ) -> Error? {
        do {
            try store.trim(tabID: tabID, to: limit) { [onEntriesWillBeTrimmed] ids in
                onEntriesWillBeTrimmed?(ids, reason)
            }
            return nil
        } catch {
            return error
        }
    }

    /// Persists a new display order for one tab.
    public func reorder(tabID: Int64, order: [Int64]) throws {
        try store.reorderEntries(tabID: tabID, order: order)
    }

    public func clear(tabID: Int64) throws {
        try store.deleteEntries(tabID: tabID)
    }

    // MARK: - Reading

    public func search(_ query: String, limit: Int = 200, tabID: Int64? = nil) throws -> [ClipboardEntry] {
        try store.search(query, limit: limit, tabID: tabID)
    }

    public func recent(limit: Int = 200, tabID: Int64? = nil) throws -> [ClipboardEntry] {
        try store.recentEntries(limit: limit, tabID: tabID)
    }

    // MARK: - Tabs

    public func tabs() throws -> [ClipboardTab] { try store.tabs() }

    public func defaultTab() throws -> ClipboardTab {
        try store.defaultTab() ?? store.ensureDefaultTab()
    }

    @discardableResult
    public func addTab(name: String, syncFolder: String? = nil) throws -> ClipboardTab {
        try store.insertTab(ClipboardTab(name: name, syncFolder: syncFolder))
    }

    public func updateTab(_ tab: ClipboardTab) throws { try store.updateTab(tab) }

    public func deleteTab(id: Int64) throws { try store.deleteTab(id: id) }

    public func moveTab(id: Int64, delta: Int) throws { try store.moveTab(id: id, delta: delta) }

    public func setDefaultTab(id: Int64) throws { try store.setDefaultTab(id: id) }

    // MARK: - Preferences

    public func preferences() throws -> Preferences { try store.preferences() }

    public func setPreferences(_ preferences: Preferences) throws {
        try store.setPreferences(preferences) { [onEntriesWillBeTrimmed] ids in
            onEntriesWillBeTrimmed?(ids, .preferenceChange)
        }
    }
}
