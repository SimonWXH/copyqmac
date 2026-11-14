// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncRelocation.swift
//
// Moving entries to another tab has to move their sync identity with them.
//
// When the destination tab has a sync folder, the entry's groups are rewritten
// into the destination folder under a fresh stem, and every source group the
// entry owns is moved to the app trash so Syncthing propagates the removal.
// When the destination has no folder, the source groups still go to the trash.
//
// Every disk change is staged and undone if a later step fails, so a failed
// move leaves both the folders and the rows exactly as they were.

import Foundation

public enum CopyQSyncRelocationError: LocalizedError, Equatable {
    case syncUnavailable
    case destinationFolderUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .syncUnavailable:
            return "Sync is paused. Resume sync before moving items out of a synced tab."
        case .destinationFolderUnavailable(let path):
            return "The destination sync folder is not available: \(path)"
        }
    }
}

public struct CopyQSyncRelocationPlan: Equatable, Sendable {
    /// Entries whose group is rewritten into the destination folder.
    public var rewrittenGroupCount: Int = 0
    /// Entries whose group is moved to the trash because the destination tab
    /// does not write to a sync folder.
    public var deletedGroupCount: Int = 0
    /// Entries that cannot move without touching sync files but cannot do so
    /// safely (paused sync, unavailable destination folder).
    public var blockedGroupCount: Int = 0
    public var blockingReason: String?

    public init(
        rewrittenGroupCount: Int = 0,
        deletedGroupCount: Int = 0,
        blockedGroupCount: Int = 0,
        blockingReason: String? = nil
    ) {
        self.rewrittenGroupCount = rewrittenGroupCount
        self.deletedGroupCount = deletedGroupCount
        self.blockedGroupCount = blockedGroupCount
        self.blockingReason = blockingReason
    }

    public var touchedGroupCount: Int { rewrittenGroupCount + deletedGroupCount }

    /// A move that only changes the tab row needs no confirmation.
    public var requiresConfirmation: Bool { touchedGroupCount > 0 }

    public func summary(language: AppLanguage) -> String {
        guard requiresConfirmation else {
            return Localization.string(.dialogMovePlanNoSyncFiles, language: language)
        }
        var parts: [String] = []
        if rewrittenGroupCount > 0 {
            parts.append(
                Localization.formatCount(
                    rewrittenGroupCount,
                    .dialogMovePlanRewriteSingle,
                    .dialogMovePlanRewritePlural,
                    language: language,
                    rewrittenGroupCount
                )
            )
        }
        if deletedGroupCount > 0 {
            parts.append(
                Localization.formatCount(
                    deletedGroupCount,
                    .dialogMovePlanTrashSingle,
                    .dialogMovePlanTrashPlural,
                    language: language,
                    deletedGroupCount
                )
            )
        }
        return Localization.format(
            .dialogMovePlanAction,
            language: language,
            parts.joined(separator: Localization.string(.dialogMovePlanJoiner, language: language))
        )
    }
}

public struct CopyQSyncRelocationReport: Equatable, Sendable {
    public var movedGroupCount: Int = 0
    public var trashedGroupCount: Int = 0
    public var trashedFileCount: Int = 0
    /// Entries that changed tab, including those without an owned group.
    public var movedEntryCount: Int = 0
    /// Entries whose owned stem changed (or was dropped).
    public var rewrittenEntryCount: Int = 0
    public var failures: [String] = []
    var transactions: [Transaction] = []

    public init() {}

    struct Transaction: Equatable, Sendable {
        let entryID: Int64
        let sourceFolder: String?
        let sourceStems: [String]
        let sourceWrittenStems: [String]
        let sourceBaseName: String?
        let destinationFolder: String?
        let destinationStem: String?
        let destinationFiles: [String]
        let trashBatches: [CopyQSyncTrashBatch]
    }

    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        var parts: [String] = []
        if movedGroupCount > 0 {
            parts.append(
                Localization.formatCount(
                    movedGroupCount,
                    .relocationSyncGroupsSingle,
                    .relocationSyncGroupsPlural,
                    language: language,
                    movedGroupCount
                )
            )
        }
        if trashedGroupCount > 0 {
            parts.append(
                Localization.formatCount(
                    trashedGroupCount,
                    .relocationTrashGroupsSingle,
                    .relocationTrashGroupsPlural,
                    language: language,
                    trashedGroupCount
                )
            )
        }
        if parts.isEmpty {
            return Localization.formatCount(
                movedEntryCount,
                .relocationMovedSingle,
                .relocationMovedPlural,
                language: language
            )
        }
        return Localization.formatCount(
            movedEntryCount,
            .relocationMovedAndSingle,
            .relocationMovedAndPlural,
            language: language,
            Localization.joinedSummaryClauses(parts, language: language)
        )
    }
}

public enum CopyQSyncRelocation {
    /// What a move would do to disk, without touching anything.
    ///
    /// A source tab with a sync folder owns its file groups, matching the
    /// writer and deletion rules. A destination without a folder still needs
    /// the source group moved to the trash.
    public static func plan(
        entries: [ClipboardEntry],
        to destination: ClipboardTab,
        in store: ClipboardStore,
        fileManager: FileManager = .default
    ) -> CopyQSyncRelocationPlan {
        var plan = CopyQSyncRelocationPlan()
        let preferences = (try? store.preferences()) ?? .defaultValue
        let configuredDestination = configuredSyncFolder(destination)
        let usableDestination = configuredDestination.flatMap {
            usableFolder($0, fileManager: fileManager)
        }
        let writesAllowed = !preferences.syncPaused
        var groupStemsByFolder: [String: Set<String>] = [:]
        var recoveredFolders = Set<String>()

        for entry in entries {
            guard let sourceTab = try? store.tab(id: entry.tabID),
                  let sourceFolder = configuredSyncFolder(sourceTab)
            else { continue }
            let groupStems = groupStemsByFolder[sourceFolder] ?? {
                let stems = CopyQSyncWatcher.itemGroupStems(in: sourceFolder, fileManager: fileManager)
                groupStemsByFolder[sourceFolder] = stems
                return stems
            }()
            if recoveredFolders.insert(sourceFolder).inserted {
                _ = CopyQSyncBridge.recoverUnlinkedOwnership(
                    in: store,
                    folder: sourceFolder,
                    tabID: sourceTab.id,
                    fileManager: fileManager
                )
            }
            guard !CopyQSyncDeletion.syncBaseNames(
                of: entry,
                in: store,
                folder: sourceFolder,
                groupStems: groupStems,
                fileManager: fileManager
            ).isEmpty else { continue }

            if let configuredDestination {
                guard usableDestination != nil else {
                    plan.blockedGroupCount += 1
                    plan.blockingReason = CopyQSyncRelocationError.destinationFolderUnavailable(
                        configuredDestination
                    ).errorDescription
                    continue
                }
                // Same folder on both tabs: the group already lives where it
                // belongs, so only the row moves and nothing needs writing.
                if usableDestination == sourceFolder { continue }
                guard writesAllowed else {
                    plan.blockedGroupCount += 1
                    plan.blockingReason = CopyQSyncRelocationError.syncUnavailable.errorDescription
                    continue
                }
                plan.rewrittenGroupCount += 1
            } else {
                guard writesAllowed else {
                    plan.blockedGroupCount += 1
                    plan.blockingReason = CopyQSyncRelocationError.syncUnavailable.errorDescription
                    continue
                }
                plan.deletedGroupCount += 1
            }
        }
        return plan
    }

    /// Rewrites or trashes every owned group for `entries`, then returns the
    /// staged changes. The caller moves the rows afterwards and can undo the
    /// disk work with `rollback` if the store write fails.
    @discardableResult
    public static func moveOwnedGroups(
        entries: [ClipboardEntry],
        to destination: ClipboardTab,
        in store: ClipboardStore,
        trashRoot: URL? = nil,
        watcher: CopyQSyncWatcher? = nil,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncRelocationReport {
        var report = CopyQSyncRelocationReport()
        guard !entries.isEmpty else { return report }
        report.movedEntryCount = entries.count

        let preferences = try store.preferences()
        let writesAllowed = !preferences.syncPaused
        let configuredDestination = configuredSyncFolder(destination)
        let usableDestination = configuredDestination.flatMap {
            usableFolder($0, fileManager: fileManager)
        }
        var sourceModificationDatesByFolder: [String: [String: Date]] = [:]
        var groupStemsByFolder: [String: Set<String>] = [:]
        var recoveredFolders = Set<String>()

        do {
            for entry in entries {
                guard let sourceTab = try store.tab(id: entry.tabID) else { continue }

                guard let sourceFolder = configuredSyncFolder(sourceTab) else { continue }
                let groupStems = groupStemsByFolder[sourceFolder] ?? {
                    let stems = CopyQSyncWatcher.itemGroupStems(in: sourceFolder, fileManager: fileManager)
                    groupStemsByFolder[sourceFolder] = stems
                    return stems
                }()
                if recoveredFolders.insert(sourceFolder).inserted {
                    _ = CopyQSyncBridge.recoverUnlinkedOwnership(
                        in: store,
                        folder: sourceFolder,
                        tabID: sourceTab.id,
                        fileManager: fileManager
                    )
                }
                let sourceStems = CopyQSyncDeletion.syncBaseNames(
                    of: entry,
                    in: store,
                    folder: sourceFolder,
                    groupStems: groupStems,
                    fileManager: fileManager
                )
                guard !sourceStems.isEmpty else { continue }
                let sourceBaseName = CopyQSyncDeletion.baseName(of: entry)
                let sourceWrittenStems = (try? store.writtenSyncStems(
                    forEntryID: entry.id,
                    folder: sourceFolder
                )) ?? []

                if let configuredDestination {
                    guard let destinationFolder = usableDestination else {
                        throw CopyQSyncRelocationError.destinationFolderUnavailable(configuredDestination)
                    }
                    // Same folder on both tabs: nothing on disk needs to move.
                    guard destinationFolder != sourceFolder else { continue }
                    guard writesAllowed else {
                        throw CopyQSyncRelocationError.syncUnavailable
                    }
                    let sourceDates = stemModificationDates(
                        in: sourceFolder,
                        cache: &sourceModificationDatesByFolder
                    )
                    let sourceDate = sourceStems.compactMap { sourceDates[$0] }.max()
                        ?? entry.createdAt
                    let written = try relocateGroup(
                        entry: entry,
                        sourceStems: sourceStems,
                        sourceBaseName: sourceBaseName,
                        sourceWrittenStems: sourceWrittenStems,
                        sourceFolder: sourceFolder,
                        sourceTab: sourceTab,
                        destinationFolder: destinationFolder,
                        sourceModificationDate: sourceDate,
                        store: store,
                        trashRoot: trashRoot,
                        watcher: watcher,
                        fileManager: fileManager
                    )
                    report.transactions.append(written)
                    report.movedGroupCount += 1
                    report.rewrittenEntryCount += 1
                    report.trashedGroupCount += written.trashBatches.count
                    report.trashedFileCount += written.trashBatches.reduce(0) { $0 + $1.files.count }
                } else {
                    guard writesAllowed else {
                        throw CopyQSyncRelocationError.syncUnavailable
                    }
                    let transaction = try trashGroupOnly(
                        entry: entry,
                        sourceStems: sourceStems,
                        sourceBaseName: sourceBaseName,
                        sourceWrittenStems: sourceWrittenStems,
                        sourceFolder: sourceFolder,
                        sourceTab: sourceTab,
                        store: store,
                        trashRoot: trashRoot,
                        watcher: watcher,
                        fileManager: fileManager
                    )
                    report.transactions.append(transaction)
                    report.rewrittenEntryCount += 1
                    report.trashedGroupCount += transaction.trashBatches.count
                    report.trashedFileCount += transaction.trashBatches.reduce(0) { $0 + $1.files.count }
                }
            }
        } catch {
            rollback(report, in: store, watcher: watcher, fileManager: fileManager)
            throw error
        }
        return report
    }

    /// Undoes the staged disk and stem changes after the row move failed.
    public static func rollback(
        _ report: CopyQSyncRelocationReport,
        in store: ClipboardStore,
        watcher: CopyQSyncWatcher? = nil,
        fileManager: FileManager = .default
    ) {
        for transaction in report.transactions.reversed() {
            undo(transaction, in: store, watcher: watcher, fileManager: fileManager)
        }
    }

    private static func undo(
        _ transaction: CopyQSyncRelocationReport.Transaction,
        in store: ClipboardStore,
        watcher: CopyQSyncWatcher?,
        fileManager: FileManager
    ) {
        if let folder = transaction.destinationFolder {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            for name in transaction.destinationFiles {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
            if let stem = transaction.destinationStem {
                try? store.removeWrittenSyncStem(stem, folder: folder)
                watcher?.removeWrittenStem(stem, folder: folder)
                CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: folder)
            }
        }
        if let folder = transaction.sourceFolder {
            for batch in transaction.trashBatches {
                CopyQSyncTrash.restore(batch, toFolder: folder, fileManager: fileManager)
            }
            for stem in transaction.sourceStems {
                try? store.removeWrittenSyncStem(stem, folder: folder)
                watcher?.removeWrittenStem(stem, folder: folder)
                CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: folder)
            }
        }
        try? store.replaceSyncBaseName(id: transaction.entryID, with: transaction.sourceBaseName)
        if let folder = transaction.sourceFolder {
            for stem in transaction.sourceWrittenStems {
                try? store.recordWrittenSyncStem(stem, folder: folder, entryID: transaction.entryID)
                watcher?.recordWrittenStem(stem, folder: folder)
                CopyQSyncWatcher.shared.recordWrittenStem(stem, folder: folder)
            }
        }
    }

    // MARK: - One entry

    private static func relocateGroup(
        entry: ClipboardEntry,
        sourceStems: [String],
        sourceBaseName: String?,
        sourceWrittenStems: [String],
        sourceFolder: String,
        sourceTab: ClipboardTab,
        destinationFolder: String,
        sourceModificationDate: Date,
        store: ClipboardStore,
        trashRoot: URL?,
        watcher: CopyQSyncWatcher?,
        fileManager: FileManager
    ) throws -> CopyQSyncRelocationReport.Transaction {
        let (destinationStem, _) = try CopyQSyncWriter.resolveUniqueStem(
            initialDate: entry.createdAt,
            directory: destinationFolder,
            fileManager: fileManager
        )

        let item = CopyQSyncBridge.entryToItem(entry, baseNameOverride: destinationStem)
        let destinationDirectory = URL(fileURLWithPath: destinationFolder, isDirectory: true)
        var written: [String] = []
        do {
            for (suffix, data) in item.onDiskFiles() {
                let name = destinationStem + suffix
                let destination = destinationDirectory.appendingPathComponent(name)
                try data.write(to: destination, options: .withoutOverwriting)
                written.append(name)
                try fileManager.setAttributes(
                    [.modificationDate: sourceModificationDate],
                    ofItemAtPath: destination.path
                )
            }
        } catch {
            for name in written {
                try? fileManager.removeItem(at: destinationDirectory.appendingPathComponent(name))
            }
            throw error
        }

        var batches: [CopyQSyncTrashBatch] = []
        do {
            for stem in sourceStems {
                if let batch = try CopyQSyncTrash.moveGroup(
                    stem: stem,
                    fromFolder: sourceFolder,
                    tab: sourceTab,
                    reason: .movedToTab,
                    trashRoot: trashRoot,
                    fileManager: fileManager
                ) {
                    batches.append(batch)
                }
            }
        } catch {
            for name in written {
                try? fileManager.removeItem(at: destinationDirectory.appendingPathComponent(name))
            }
            for batch in batches {
                CopyQSyncTrash.restore(batch, toFolder: sourceFolder, fileManager: fileManager)
            }
            throw error
        }

        let transaction = CopyQSyncRelocationReport.Transaction(
            entryID: entry.id,
            sourceFolder: sourceFolder,
            sourceStems: sourceStems,
            sourceWrittenStems: sourceWrittenStems,
            sourceBaseName: sourceBaseName,
            destinationFolder: destinationFolder,
            destinationStem: destinationStem,
            destinationFiles: written,
            trashBatches: batches
        )
        do {
            try store.replaceSyncBaseName(id: entry.id, with: destinationStem)
            for stem in sourceStems {
                try? store.removeWrittenSyncStem(stem, folder: sourceFolder)
                watcher?.removeWrittenStem(stem, folder: sourceFolder)
                CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: sourceFolder)
            }
            try? store.recordWrittenSyncStem(
                destinationStem,
                folder: destinationFolder,
                entryID: entry.id
            )
            watcher?.recordWrittenStem(destinationStem, folder: destinationFolder)
            CopyQSyncWatcher.shared.recordWrittenStem(destinationStem, folder: destinationFolder)
            try? store.recordSyncedVersion(
                id: entry.id,
                date: Date(),
                fingerprint: CopyQSyncBridge.writtenPayloadFingerprint(of: item)
            )
        } catch {
            undo(transaction, in: store, watcher: watcher, fileManager: fileManager)
            throw error
        }
        return transaction
    }

    private static func trashGroupOnly(
        entry: ClipboardEntry,
        sourceStems: [String],
        sourceBaseName: String?,
        sourceWrittenStems: [String],
        sourceFolder: String,
        sourceTab: ClipboardTab,
        store: ClipboardStore,
        trashRoot: URL?,
        watcher: CopyQSyncWatcher?,
        fileManager: FileManager
    ) throws -> CopyQSyncRelocationReport.Transaction {
        var batches: [CopyQSyncTrashBatch] = []
        do {
            for stem in sourceStems {
                if let batch = try CopyQSyncTrash.moveGroup(
                    stem: stem,
                    fromFolder: sourceFolder,
                    tab: sourceTab,
                    reason: .movedToTab,
                    trashRoot: trashRoot,
                    fileManager: fileManager
                ) {
                    batches.append(batch)
                }
            }
        } catch {
            for batch in batches {
                CopyQSyncTrash.restore(batch, toFolder: sourceFolder, fileManager: fileManager)
            }
            throw error
        }
        let transaction = CopyQSyncRelocationReport.Transaction(
            entryID: entry.id,
            sourceFolder: sourceFolder,
            sourceStems: sourceStems,
            sourceWrittenStems: sourceWrittenStems,
            sourceBaseName: sourceBaseName,
            destinationFolder: nil,
            destinationStem: nil,
            destinationFiles: [],
            trashBatches: batches
        )
        do {
            try store.replaceSyncBaseName(id: entry.id, with: nil)
            for stem in sourceStems {
                try? store.removeWrittenSyncStem(stem, folder: sourceFolder)
                watcher?.removeWrittenStem(stem, folder: sourceFolder)
                CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: sourceFolder)
            }
        } catch {
            undo(transaction, in: store, watcher: watcher, fileManager: fileManager)
            throw error
        }
        return transaction
    }

    // MARK: - Folders

    private static func stemModificationDates(
        in folder: String,
        cache: inout [String: [String: Date]]
    ) -> [String: Date] {
        if let cached = cache[folder] { return cached }
        var dates: [String: Date] = [:]
        for group in CopyQSyncWatcher.findItemGroups(in: folder) {
            dates[group.stem] = group.newestModificationDate
        }
        cache[folder] = dates
        return dates
    }

    /// A tab with a sync folder owns files there; a tab without one owns none.
    private static func configuredSyncFolder(_ tab: ClipboardTab) -> String? {
        guard let folder = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty
        else { return nil }
        return CopyQSyncBridge.normalizePath(folder)
    }

    private static func usableFolder(
        _ folder: String,
        fileManager: FileManager
    ) -> String? {
        let normalized = CopyQSyncBridge.normalizePath(folder)
        guard !CopyQSyncWriterSafety.isForbiddenPath(normalized) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return normalized
    }
}
