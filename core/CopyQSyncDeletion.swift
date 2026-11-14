// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncDeletion.swift
//
// The one path that removes a sync identity from the local history.  For a
// user-visible delete it first moves the entry's file group into the app trash,
// then the store removes the row.  For a group that disappeared upstream it
// preserves the local payload in the trash before dropping the row.  Paused
// sync is a hard no-op, and an entry that does not own a stem is never touched
// on disk.

import Foundation

public struct CopyQSyncDeletionReport: Equatable, Sendable {
    public var trashedGroupCount: Int = 0
    public var trashedFileCount: Int = 0
    public var archivedEntryCount: Int = 0
    public var deletedEntryCount: Int = 0
    public var failures: [String] = []

    public init(
        trashedGroupCount: Int = 0,
        trashedFileCount: Int = 0,
        archivedEntryCount: Int = 0,
        deletedEntryCount: Int = 0,
        failures: [String] = []
    ) {
        self.trashedGroupCount = trashedGroupCount
        self.trashedFileCount = trashedFileCount
        self.archivedEntryCount = archivedEntryCount
        self.deletedEntryCount = deletedEntryCount
        self.failures = failures
    }

    public mutating func merge(_ other: CopyQSyncDeletionReport) {
        trashedGroupCount += other.trashedGroupCount
        trashedFileCount += other.trashedFileCount
        archivedEntryCount += other.archivedEntryCount
        deletedEntryCount += other.deletedEntryCount
        failures.append(contentsOf: other.failures)
    }
}

public enum CopyQSyncDeletion {
    /// The stem an entry owns, carried as a bookkeeping flavour by every
    /// imported item, recorded with the entry id for local writes, or resolved
    /// from the folder for rows written or imported by older builds.
    public static func syncBaseName(
        of entry: ClipboardEntry,
        in store: ClipboardStore? = nil,
        folder: String? = nil,
        groupStems: Set<String>? = nil,
        persistLink: Bool = true,
        fileManager: FileManager = .default
    ) -> String? {
        if let baseName = baseName(of: entry) {
            return baseName
        }
        guard let store, let folder, !folder.isEmpty else { return nil }
        return CopyQSyncBridge.ownedStem(
            of: entry,
            in: store,
            folder: folder,
            groupStems: groupStems,
            persistLink: persistLink,
            fileManager: fileManager
        )
    }

    /// Every stem the entry owns in `folder`: its base-name flavour plus every
    /// stem recorded for its id, falling back to the single legacy match. This
    /// is the owned set of `CopyQSyncIdentityResolver`, so deletion, the
    /// comparison, and the resync apply share one answer.
    public static func syncBaseNames(
        of entry: ClipboardEntry,
        in store: ClipboardStore,
        folder: String,
        groupStems: Set<String>? = nil,
        persistLink: Bool = true,
        fileManager: FileManager = .default
    ) -> [String] {
        CopyQSyncIdentityResolver.resolve(
            of: entry,
            in: store,
            folder: folder,
            groupStems: groupStems,
            persistLink: persistLink,
            fileManager: fileManager
        ).stems
    }

    /// The stem a rewrite keeps when an entry owns several groups: its
    /// base-name flavour, or the oldest recorded stem.
    public static func canonicalStem(of entry: ClipboardEntry, among stems: [String]) -> String? {
        if let baseName = baseName(of: entry), stems.contains(baseName) {
            return baseName
        }
        return preferredStem(among: stems)
    }

    /// The oldest stem by name stamp, with a stable tie-break.
    public static func preferredStem(among stems: [String]) -> String? {
        stems.min { lhs, rhs in
            let left = CopyQSyncItem.parseTimestamp(baseName: lhs) ?? .distantFuture
            let right = CopyQSyncItem.parseTimestamp(baseName: rhs) ?? .distantFuture
            if left == right { return lhs < rhs }
            return left < right
        }
    }

    /// The stem carried by the entry's base-name flavour, if it has one.
    public static func baseName(of entry: ClipboardEntry) -> String? {
        for flavour in entry.flavours where flavour.type == Fingerprint.syncBaseNameFlavour {
            guard let stem = String(data: flavour.data, encoding: .utf8),
                  !stem.isEmpty
            else { continue }
            return stem
        }
        return nil
    }

    /// Stems of every group in `folder`, cached per normalized folder so a
    /// batch operation lists each folder once.
    private static func groupStemCache(
        folder: String,
        in cache: inout [String: Set<String>],
        fileManager: FileManager
    ) -> Set<String> {
        let normalized = CopyQSyncBridge.normalizePath(folder)
        if let cached = cache[normalized] { return cached }
        let stems = CopyQSyncWatcher.itemGroupStems(in: normalized, fileManager: fileManager)
        cache[normalized] = stems
        return stems
    }

    /// Called before the store removes user-deleted rows.  Only tabs with a
    /// configured sync folder participate, and nothing happens while sync is
    /// paused.  A move failure throws so the rows stay, keeping disk and store
    /// consistent.
    @discardableResult
    public static func trashOwnedGroups(
        for entries: [ClipboardEntry],
        in store: ClipboardStore,
        reason: CopyQSyncTrashReason = .localDelete,
        trashRoot: URL? = nil,
        watcher: CopyQSyncWatcher? = nil,
        fileManager: FileManager = .default,
        preferences: Preferences? = nil
    ) throws -> CopyQSyncDeletionReport {
        var report = CopyQSyncDeletionReport()
        guard !entries.isEmpty else { return report }
        let effectivePreferences = try preferences ?? store.preferences()
        guard !effectivePreferences.syncPaused else { return report }
        try ensureTrashOutsideConfiguredSyncFolders(trashRoot: trashRoot, in: store)

        var staged: [(batch: CopyQSyncTrashBatch, folder: String)] = []
        var ownedStems: [(folder: String, stems: [String])] = []
        var groupStemsByFolder: [String: Set<String>] = [:]
        var recoveredFolders = Set<String>()
        do {
            for entry in entries {
                guard let tab = try store.tab(id: entry.tabID),
                      let folder = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !folder.isEmpty
                else { continue }
                let normalizedFolder = CopyQSyncBridge.normalizePath(folder)
                let groupStems = groupStemCache(
                    folder: normalizedFolder,
                    in: &groupStemsByFolder,
                    fileManager: fileManager
                )
                if recoveredFolders.insert(normalizedFolder).inserted {
                    _ = CopyQSyncBridge.recoverUnlinkedOwnership(
                        in: store,
                        folder: normalizedFolder,
                        tabID: tab.id,
                        fileManager: fileManager
                    )
                }
                let stems = syncBaseNames(
                    of: entry,
                    in: store,
                    folder: normalizedFolder,
                    groupStems: groupStems,
                    fileManager: fileManager
                )
                guard !stems.isEmpty else { continue }
                ownedStems.append((normalizedFolder, stems))
                for stem in stems {
                    guard let batch = try CopyQSyncTrash.moveGroup(
                        stem: stem,
                        fromFolder: normalizedFolder,
                        tab: tab,
                        reason: reason,
                        trashRoot: trashRoot,
                        fileManager: fileManager
                    ) else { continue }
                    staged.append((batch, normalizedFolder))
                    report.trashedGroupCount += 1
                    report.trashedFileCount += batch.files.count
                }
            }
        } catch {
            // Restore anything moved before the failure: the store has not
            // deleted the rows yet, so both sides must stay as they were.
            for item in staged.reversed() {
                CopyQSyncTrash.restore(item.batch, toFolder: item.folder, fileManager: fileManager)
            }
            throw error
        }

        for item in ownedStems {
            for stem in item.stems {
                try? store.removeWrittenSyncStem(stem, folder: item.folder)
                watcher?.removeWrittenStem(stem, folder: item.folder)
                CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: item.folder)
            }
        }
        return report
    }

    /// Removes one local entry whose sync group disappeared upstream.  The
    /// payload is archived to trash first on a best-effort basis; the upstream
    /// deletion already happened, so a failed archive must not strand a stale
    /// entry forever.
    @discardableResult
    public static func deleteEntryRemovedUpstream(
        _ entry: ClipboardEntry,
        stem: String,
        folder: String,
        tab: ClipboardTab,
        in store: ClipboardStore,
        trashRoot: URL? = nil,
        watcher: CopyQSyncWatcher? = nil,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncDeletionReport {
        var report = CopyQSyncDeletionReport()
        try ensureTrashOutsideConfiguredSyncFolders(trashRoot: trashRoot, in: store)
        do {
            if let batch = try CopyQSyncTrash.archiveEntry(
                entry,
                stem: stem,
                folder: folder,
                tab: tab,
                reason: .remoteDelete,
                trashRoot: trashRoot,
                fileManager: fileManager
            ) {
                report.archivedEntryCount = 1
                report.trashedFileCount = batch.files.count
            }
        } catch {
            report.failures.append(
                "Could not archive \(stem) before removing it: \(error.localizedDescription)"
            )
        }

        try store.delete(id: entry.id, propagateSyncDeletion: false)
        report.deletedEntryCount = 1
        try? store.removeWrittenSyncStem(stem, folder: folder)
        watcher?.removeWrittenStem(stem, folder: folder)
        CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: folder)
        return report
    }

    /// Removes entries that no longer have a matching group during an explicit
    /// reconciliation.  Missing files are archived from the stored payload so
    /// the removal stays recoverable.  With `keepUnarchivedRows`, a row whose
    /// own payload cannot be archived is kept and reported while the other rows
    /// still proceed; callers that keep the shipped behaviour remove every row
    /// and report the archive failure.
    @discardableResult
    public static func deleteEntriesMissingFiles(
        _ entries: [ClipboardEntry],
        in store: ClipboardStore,
        trashRoot: URL? = nil,
        keepUnarchivedRows: Bool = false,
        language: AppLanguage = .english,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncDeletionReport {
        var report = CopyQSyncDeletionReport()
        try ensureTrashOutsideConfiguredSyncFolders(trashRoot: trashRoot, in: store)
        var ids: [Int64] = []
        var ownedStems: [(folder: String, stems: [String])] = []
        var groupStemsByFolder: [String: Set<String>] = [:]
        for entry in entries {
            guard let tab = try? store.tab(id: entry.tabID),
                  let configured = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !configured.isEmpty
            else { continue }
            let normalizedFolder = CopyQSyncBridge.normalizePath(configured)
            let groupStems = groupStemCache(
                folder: normalizedFolder,
                in: &groupStemsByFolder,
                fileManager: fileManager
            )
            let stems = syncBaseNames(
                of: entry,
                in: store,
                folder: normalizedFolder,
                groupStems: groupStems,
                fileManager: fileManager
            )
            guard !stems.isEmpty else { continue }
            let archiveStem = canonicalStem(of: entry, among: stems) ?? stems[0]
            var movedBatches: [CopyQSyncTrashBatch] = []
            var entryFailed = false
            for stem in stems {
                do {
                    if let batch = try CopyQSyncTrash.moveGroup(
                        stem: stem,
                        fromFolder: normalizedFolder,
                        tab: tab,
                        reason: .reconciliation,
                        trashRoot: trashRoot,
                        fileManager: fileManager
                    ) {
                        movedBatches.append(batch)
                    }
                } catch {
                    entryFailed = true
                    report.failures.append(
                        Localization.format(
                            .deletionCouldNotMoveBeforeReconciliation,
                            language: language,
                            stem,
                            error.localizedDescription
                        )
                    )
                }
            }
            var archivedFileCount = 0
            if movedBatches.isEmpty {
                do {
                    if let batch = try CopyQSyncTrash.archiveEntry(
                        entry,
                        stem: archiveStem,
                        folder: normalizedFolder,
                        tab: tab,
                        reason: .reconciliation,
                        trashRoot: trashRoot,
                        fileManager: fileManager
                    ) {
                        archivedFileCount = batch.files.count
                    }
                } catch {
                    entryFailed = true
                    report.failures.append(
                        Localization.format(
                            .deletionCouldNotArchiveBeforeReconciliation,
                            language: language,
                            archiveStem,
                            error.localizedDescription
                        )
                    )
                }
            }
            if entryFailed, keepUnarchivedRows {
                for batch in movedBatches {
                    CopyQSyncTrash.restore(batch, toFolder: normalizedFolder, fileManager: fileManager)
                }
                report.failures.append(
                    Localization.format(
                        .diagnosticKeptReason,
                        language: .english,
                        archiveStem,
                        CatalogKey.diagnosticKeptUnarchivedPayload.english
                    )
                )
                continue
            }
            if !movedBatches.isEmpty {
                report.trashedGroupCount += movedBatches.count
                report.trashedFileCount += movedBatches.reduce(0) { $0 + $1.files.count }
            } else if archivedFileCount > 0 {
                report.archivedEntryCount += 1
                report.trashedFileCount += archivedFileCount
            }
            ids.append(entry.id)
            ownedStems.append((normalizedFolder, stems))
        }
        guard !ids.isEmpty else { return report }
        try store.delete(ids: ids, propagateSyncDeletion: false)
        report.deletedEntryCount = ids.count
        for item in ownedStems {
            for stem in item.stems {
                try? store.removeWrittenSyncStem(stem, folder: item.folder)
                CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: item.folder)
            }
        }
        return report
    }

    private static func ensureTrashOutsideConfiguredSyncFolders(
        trashRoot: URL?,
        in store: ClipboardStore
    ) throws {
        let root = try CopyQSyncTrash.rootDirectory(override: trashRoot)
        let folders = try store.tabs().compactMap(\.syncFolder)
        try CopyQSyncTrash.ensureOutsideSyncFolders(trashRoot: root, syncFolders: folders)
    }
}
