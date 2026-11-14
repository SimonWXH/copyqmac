// Tab storage: user-defined pages with names, order, a default capture tab,
// and the sync-folder mapping the preferences window edits.

import Foundation

extension ClipboardStore {
    /// All tabs ordered by position.
    public func tabs() throws -> [ClipboardTab] {
        let statement = try database.prepare("""
            SELECT id, name, position, is_default, sync_folder
            FROM tabs ORDER BY position, id
            """)
        defer { statement.finalize() }
        var result: [ClipboardTab] = []
        while try statement.step() {
            result.append(readTab(statement))
        }
        return result
    }

    public func tab(id: Int64) throws -> ClipboardTab? {
        let statement = try database.prepare("""
            SELECT id, name, position, is_default, sync_folder
            FROM tabs WHERE id = ?
            """)
        defer { statement.finalize() }
        try statement.bind(1, id)
        guard try statement.step() else { return nil }
        return readTab(statement)
    }

    /// The tab that captures are written into. Falls back to the first tab.
    public func defaultTab() throws -> ClipboardTab? {
        let statement = try database.prepare("""
            SELECT id, name, position, is_default, sync_folder
            FROM tabs ORDER BY is_default DESC, position, id LIMIT 1
            """)
        defer { statement.finalize() }
        guard try statement.step() else { return nil }
        return readTab(statement)
    }

    /// Creates a tab at the end. The first tab becomes the default.
    @discardableResult
    public func insertTab(_ tab: ClipboardTab) throws -> ClipboardTab {
        var created = tab
        try database.transaction {
            let positionStatement = try database.prepare("SELECT COALESCE(MAX(position), 0) + 1 FROM tabs")
            defer { positionStatement.finalize() }
            let nextPosition = Int(try positionStatement.step() ? positionStatement.int64(at: 0) : 1)

            let countStatement = try database.prepare("SELECT COUNT(*) FROM tabs")
            defer { countStatement.finalize() }
            let tabCount = try countStatement.step() ? countStatement.int64(at: 0) : 0

            created.position = nextPosition
            created.isDefault = tab.isDefault || tabCount == 0

            let insert = try database.prepare("""
                INSERT INTO tabs (name, position, is_default, sync_folder)
                VALUES (?, ?, ?, ?)
                """)
            defer { insert.finalize() }
            try insert.bind(1, created.name)
            try insert.bind(2, created.position)
            try insert.bind(3, created.isDefault)
            if let syncFolder = created.syncFolder {
                try insert.bind(4, syncFolder)
            } else {
                try insert.bindNull(4)
            }
            try insert.run()
            created.id = database.lastInsertRowID
        }
        if let rawFolder = created.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawFolder.isEmpty {
            try? reclaimOrphanedWrittenSyncStems(folder: CopyQSyncBridge.normalizePath(rawFolder))
        }
        if created.isDefault {
            try setDefaultTab(id: created.id)
        }
        return created
    }

    /// Updates a tab's name, sync-folder mapping, and position.
    ///
    /// When this leaves the previous folder unmapped by every tab, the written
    /// stems recorded for it are released with the mapping, so a later mapping
    /// of that folder imports those groups instead of suppressing them.
    public func updateTab(_ tab: ClipboardTab) throws {
        func normalizedFolder(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return CopyQSyncBridge.normalizePath(trimmed)
        }

        let previousFolder = normalizedFolder(try self.tab(id: tab.id)?.syncFolder)
        let newFolder = normalizedFolder(tab.syncFolder)
        var removedStems: [(stem: String, folder: String)] = []

        try database.transaction {
            let statement = try database.prepare("""
                UPDATE tabs SET name = ?, sync_folder = ?, position = ? WHERE id = ?
                """)
            defer { statement.finalize() }
            try statement.bind(1, tab.name)
            if let syncFolder = tab.syncFolder, !syncFolder.isEmpty {
                try statement.bind(2, syncFolder)
            } else {
                try statement.bindNull(2)
            }
            try statement.bind(3, tab.position)
            try statement.bind(4, tab.id)
            try statement.run()

            guard let previousFolder, previousFolder != newFolder else { return }
            let stillMapped = try tabs().contains { other in
                other.id != tab.id && normalizedFolder(other.syncFolder) == previousFolder
            }
            guard !stillMapped else { return }

            let select = try database.prepare("SELECT stem FROM written_sync_stems WHERE folder = ?")
            defer { select.finalize() }
            try select.bind(1, previousFolder)
            while try select.step() {
                if let stem = select.string(at: 0) {
                    removedStems.append((stem, previousFolder))
                }
            }
            let delete = try database.prepare("DELETE FROM written_sync_stems WHERE folder = ?")
            defer { delete.finalize() }
            try delete.bind(1, previousFolder)
            try delete.run()
        }

        for (stem, folder) in removedStems {
            onWrittenSyncStemRemoved?(stem, folder)
        }
        if let newFolder, previousFolder != newFolder {
            try? reclaimOrphanedWrittenSyncStems(folder: newFolder)
        }
    }

    /// Deletes a tab and its stored entries. The last remaining tab cannot be
    /// removed, and deleting the default tab promotes the first survivor. Sync
    /// folder files are left untouched.
    public func deleteTab(id: Int64) throws {
        let allTabs = try tabs()
        guard allTabs.count > 1, let victim = allTabs.first(where: { $0.id == id }) else { return }

        let folderToClean: String?
        if let rawFolder = victim.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !rawFolder.isEmpty {
            let normalized = CopyQSyncBridge.normalizePath(rawFolder)
            let shared = allTabs.contains { other in
                guard other.id != id,
                      let otherFolder = other.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !otherFolder.isEmpty
                else { return false }
                return CopyQSyncBridge.normalizePath(otherFolder) == normalized
            }
            folderToClean = shared ? nil : normalized
        } else {
            folderToClean = nil
        }

        var stemsToNotify: [(stem: String, folder: String)] = []

        try database.transaction {
            try deleteRows(selectedBy: "SELECT id FROM entries WHERE tab_id = ?", bindings: [id])
            let selectTabStems = try database.prepare(
                "SELECT stem, folder FROM written_sync_stems WHERE tab_id = ?"
            )
            defer { selectTabStems.finalize() }
            try selectTabStems.bind(1, id)
            while try selectTabStems.step() {
                if let stem = selectTabStems.string(at: 0), let folder = selectTabStems.string(at: 1) {
                    stemsToNotify.append((stem, folder))
                }
            }
            let deleteTabStems = try database.prepare(
                "DELETE FROM written_sync_stems WHERE tab_id = ?"
            )
            defer { deleteTabStems.finalize() }
            try deleteTabStems.bind(1, id)
            try deleteTabStems.run()
            if let folderToClean {
                let selectStems = try database.prepare("SELECT stem FROM written_sync_stems WHERE folder = ?")
                defer { selectStems.finalize() }
                try selectStems.bind(1, folderToClean)
                while try selectStems.step() {
                    if let stem = selectStems.string(at: 0) {
                        stemsToNotify.append((stem, folderToClean))
                    }
                }
                let deleteStems = try database.prepare("DELETE FROM written_sync_stems WHERE folder = ?")
                defer { deleteStems.finalize() }
                try deleteStems.bind(1, folderToClean)
                try deleteStems.run()
            }
            let deleteTab = try database.prepare("DELETE FROM tabs WHERE id = ?")
            defer { deleteTab.finalize() }
            try deleteTab.bind(1, id)
            try deleteTab.run()
            // Close the gap left in the ordering.
            for (index, tab) in allTabs.filter({ $0.id != id }).enumerated() {
                let update = try database.prepare("UPDATE tabs SET position = ? WHERE id = ?")
                defer { update.finalize() }
                try update.bind(1, index + 1)
                try update.bind(2, tab.id)
                try update.run()
            }
        }

        for (stem, folder) in stemsToNotify {
            onWrittenSyncStemRemoved?(stem, folder)
        }

        if victim.isDefault, let promoted = try tabs().first {
            try setDefaultTab(id: promoted.id)
        }
    }

    /// Moves a tab one slot toward the start of the order (delta -1) or the end
    /// (delta +1); the tab strip draws that as left/right, the sidebar as up/down.
    public func moveTab(id: Int64, delta: Int) throws {
        var allTabs = try tabs()
        guard let index = allTabs.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard target >= 0, target < allTabs.count else { return }
        allTabs.swapAt(index, target)
        try database.transaction {
            for (position, tab) in allTabs.enumerated() {
                let update = try database.prepare("UPDATE tabs SET position = ? WHERE id = ?")
                defer { update.finalize() }
                try update.bind(1, position + 1)
                try update.bind(2, tab.id)
                try update.run()
            }
        }
    }

    /// Marks exactly one tab as the capture target.
    public func setDefaultTab(id: Int64) throws {
        try database.transaction {
            try database.execute("UPDATE tabs SET is_default = 0")
            let update = try database.prepare("UPDATE tabs SET is_default = 1 WHERE id = ?")
            defer { update.finalize() }
            try update.bind(1, id)
            try update.run()
        }
    }

    /// Creates the initial tab when none exists and returns the default tab.
    @discardableResult
    public func ensureDefaultTab(name: String = ClipboardStore.initialTabName) throws -> ClipboardTab {
        if let existing = try defaultTab() { return existing }
        return try insertTab(ClipboardTab(name: name, isDefault: true))
    }

    private func readTab(_ statement: SQLiteStatement) -> ClipboardTab {
        ClipboardTab(
            id: statement.int64(at: 0),
            name: statement.string(at: 1) ?? "",
            position: Int(statement.int64(at: 2)),
            isDefault: statement.bool(at: 3),
            syncFolder: statement.string(at: 4)
        )
    }
}
