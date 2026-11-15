// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncResync.swift
//
// One tab compared with its sync folder, in two halves that share one
// comparison and one identity model (`CopyQSyncIdentityResolver`).
//
// `report` is read-only.  It counts entries whose stem and decoded content
// match a file, content differences, entries whose stem has no file,
// importable folder stems with no entry, entries with no usable folder content
// or unresolved historical identity, entries whose stem has a file that failed
// to decode, distinct files that could not be read, and internal-only or empty
// stems.  Nothing in the store or the folder is written, moved, renamed,
// deleted, or adopted.
//
// `plan` turns that comparison into the three writable categories the report
// already counts, and names every row it refuses to resolve.  `apply` executes
// exactly that plan inside the sync writer's barrier: removals first (archived
// to the app trash, never deleted outright), then imports of folder-only
// stems, then content updates that keep the row's note, pin, and identity.
// The apply never rewrites the sync folder: imports read files that already
// exist, updates take the folder's content, and removals archive the local
// payload, so resync creates, changes, moves, and deletes no folder file.
// Apply is never automatic; the presentation layer asks for an explicit
// confirmation whose text is the plan's own per-category counts.

import Foundation

/// One row whose folder content differs from the row, with the owned stems
/// that differ.  `isLegacyIdentity` marks a row whose ownership rests only on
/// the legacy creation-time rule, so a same-stem difference cannot be told
/// apart from unrelated history.
public struct CopyQSyncContentDifference: Equatable, Sendable {
    public let entryID: Int64
    public let differingStems: [String]
    public let isLegacyIdentity: Bool
    /// True when the row's owned groups do not all carry the same decoded
    /// payload, including when an owned group could not be fully decoded, so no
    /// single row content can be shown to satisfy every group.
    public let hasConflictingGroups: Bool

    public init(
        entryID: Int64,
        differingStems: [String],
        isLegacyIdentity: Bool,
        hasConflictingGroups: Bool = false
    ) {
        self.entryID = entryID
        self.differingStems = differingStems
        self.isLegacyIdentity = isLegacyIdentity
        self.hasConflictingGroups = hasConflictingGroups
    }
}

public struct CopyQSyncResyncReport: Equatable, Sendable {
    public let tabID: Int64
    public let tabName: String
    public let folder: String
    /// Entries whose stem and decoded content both match the folder.
    public let matchedEntryCount: Int
    /// Entries whose stem exists but whose content differs from the file.
    public let contentDifferences: [CopyQSyncContentDifference]
    /// Entries whose stem has no file in the folder.
    public let entriesWithoutFiles: [CopyQSyncMissingEntry]
    /// Importable folder stems that no entry owns.
    public let stemsWithoutEntries: [String]
    /// Entries with no usable folder content, including an internal-only
    /// stem, or no resolved historical identity.
    public let unresolvedEntryCount: Int
    /// Entries whose stem has files that could not be decoded.
    public let unreadableEntryCount: Int
    /// Files that could not be read or were skipped by the folder reader.
    public let unreadableFileCount: Int
    /// Stems whose files carry only internal bookkeeping or no payload.
    public let skippedInternalStems: [String]
    public let failures: [String]

    public init(
        tabID: Int64,
        tabName: String,
        folder: String,
        matchedEntryCount: Int,
        contentDifferences: [CopyQSyncContentDifference],
        entriesWithoutFiles: [CopyQSyncMissingEntry],
        stemsWithoutEntries: [String],
        unresolvedEntryCount: Int,
        unreadableEntryCount: Int,
        unreadableFileCount: Int,
        skippedInternalStems: [String] = [],
        failures: [String] = []
    ) {
        self.tabID = tabID
        self.tabName = tabName
        self.folder = folder
        self.matchedEntryCount = matchedEntryCount
        self.contentDifferences = contentDifferences
        self.entriesWithoutFiles = entriesWithoutFiles
        self.stemsWithoutEntries = stemsWithoutEntries
        self.unresolvedEntryCount = unresolvedEntryCount
        self.unreadableEntryCount = unreadableEntryCount
        self.unreadableFileCount = unreadableFileCount
        self.skippedInternalStems = skippedInternalStems
        self.failures = failures
    }

    public var contentDifferenceCount: Int { contentDifferences.count }
    public var entriesWithoutFilesCount: Int { entriesWithoutFiles.count }
    public var stemsWithoutEntriesCount: Int { stemsWithoutEntries.count }

    public var mismatches: Bool {
        contentDifferenceCount > 0
            || entriesWithoutFilesCount > 0
            || stemsWithoutEntriesCount > 0
            || unresolvedEntryCount > 0
            || unreadableEntryCount > 0
            || unreadableFileCount > 0
            || !skippedInternalStems.isEmpty
    }

    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        var lines = [
            Localization.format(
                .dialogResyncReportCounts,
                language: language,
                matchedEntryCount,
                contentDifferenceCount,
                entriesWithoutFilesCount,
                stemsWithoutEntriesCount
            )
        ]
        if unresolvedEntryCount > 0 {
            lines.append(
                Localization.formatCount(
                    unresolvedEntryCount,
                    .dialogResyncReportUnresolvedSingle,
                    .dialogResyncReportUnresolvedPlural,
                    language: language,
                    unresolvedEntryCount
                )
            )
        }
        if unreadableEntryCount > 0 {
            lines.append(
                Localization.formatCount(
                    unreadableEntryCount,
                    .dialogResyncReportUnreadableEntriesSingle,
                    .dialogResyncReportUnreadableEntriesPlural,
                    language: language,
                    unreadableEntryCount
                )
            )
        }
        if unreadableFileCount > 0 {
            lines.append(
                Localization.formatCount(
                    unreadableFileCount,
                    .dialogResyncReportUnreadableFilesSingle,
                    .dialogResyncReportUnreadableFilesPlural,
                    language: language,
                    unreadableFileCount
                )
            )
        }
        if !skippedInternalStems.isEmpty {
            lines.append(
                Localization.formatCount(
                    skippedInternalStems.count,
                    .dialogResyncReportSkippedStemsSingle,
                    .dialogResyncReportSkippedStemsPlural,
                    language: language,
                    skippedInternalStems.count
                )
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// The conditions one tab's sync folder can be in when an operation that
/// compares with it, resyncs it, or writes back into it has to stop.
public enum CopyQSyncResyncError: LocalizedError, Equatable {
    case tabNotFound(Int64)
    case noSyncFolder(String)
    case ambiguousSyncFolder(String, [String])
    case folderMissing(String)
    case folderUnreadable(String, String)
    case folderChanged(String, String)
    case syncPaused(String)
    /// Paused sync blocks the folder write-back, which is a different
    /// operation from resync and says so.
    case writeBackPaused(String)

    public var errorDescription: String? {
        switch self {
        case .tabNotFound(let id):
            return "The tab with id \(id) no longer exists."
        case .noSyncFolder(let tabName):
            return "The tab “\(tabName)” has no sync folder configured."
        case .ambiguousSyncFolder(let folder, let tabNames):
            return "Several tabs claim the sync folder \(folder): \(tabNames.joined(separator: ", ")). Fix the tab folders before comparing."
        case .folderMissing(let folder):
            return "The sync folder does not exist: \(folder)"
        case .folderUnreadable(let folder, let reason):
            return "Could not read \(folder): \(reason)"
        case .folderChanged(let planned, let current):
            return "The tab's sync folder changed from \(planned) to \(current) after the report. Compare the tab again before applying."
        case .syncPaused(let tabName):
            return "Sync is paused, so “\(tabName)” cannot be resynced. Resume sync first."
        case .writeBackPaused(let tabName):
            return "Sync is paused, so “\(tabName)” cannot be written back. Resume sync first."
        }
    }
}

/// Why the apply half refuses to touch one content-different row.
public enum CopyQSyncResyncConflictReason: String, CaseIterable, Equatable, Sendable {
    /// The row holds an edit that has not reached the folder.
    case locallyEdited
    /// The folder item's note or pin differs from the row's.
    case noteOrPin
    /// The row owns several groups whose content differs; one row cannot take
    /// both, and resync does not choose between them.
    case multipleGroups
    /// The row's ownership rests only on the legacy creation-time rule, so the
    /// same stem could be unrelated history.
    case unrelatedHistory

    public var description: String {
        description(language: .english)
    }

    public func description(language: AppLanguage) -> String {
        switch self {
        case .locallyEdited:
            return Localization.string(.dialogResyncConflictLocallyEdited, language: language)
        case .noteOrPin:
            return Localization.string(.dialogResyncConflictNoteOrPin, language: language)
        case .multipleGroups:
            return Localization.string(.dialogResyncConflictMultipleGroups, language: language)
        case .unrelatedHistory:
            return Localization.string(.dialogResyncConflictUnrelatedHistory, language: language)
        }
    }
}

public struct CopyQSyncResyncConflict: Equatable, Sendable {
    public let entryID: Int64
    public let stems: [String]
    public let reason: CopyQSyncResyncConflictReason

    public init(entryID: Int64, stems: [String], reason: CopyQSyncResyncConflictReason) {
        self.entryID = entryID
        self.stems = stems
        self.reason = reason
    }
}

/// What an explicit resync apply will do, per category, with counts.  The
/// confirmation text is generated from this value so the dialog and the write
/// cannot describe different work.
public struct CopyQSyncResyncPlan: Equatable, Sendable {
    public let tabID: Int64
    public let tabName: String
    public let folder: String
    /// Folder-only stems that will become entries.
    public let imports: [String]
    /// Rows whose files are gone; each is archived to the app trash, then removed.
    public let removals: [CopyQSyncMissingEntry]
    /// Rows whose content the folder's version replaces; notes and pins stay.
    public let updates: [CopyQSyncContentDifference]
    /// Rows resync refuses to resolve on its own.
    public let conflicts: [CopyQSyncResyncConflict]

    public init(
        tabID: Int64,
        tabName: String,
        folder: String,
        imports: [String],
        removals: [CopyQSyncMissingEntry],
        updates: [CopyQSyncContentDifference],
        conflicts: [CopyQSyncResyncConflict]
    ) {
        self.tabID = tabID
        self.tabName = tabName
        self.folder = folder
        self.imports = imports
        self.removals = removals
        self.updates = updates
        self.conflicts = conflicts
    }

    public var isEmpty: Bool {
        imports.isEmpty && removals.isEmpty && updates.isEmpty
    }

    /// The per-category counts, one line each, including the empty categories.
    public func confirmation(language: AppLanguage) -> String {
        var lines = [
            Localization.formatCount(
                imports.count,
                .dialogResyncPlanImportSingle,
                .dialogResyncPlanImportPlural,
                language: language,
                imports.count
            ),
            Localization.formatCount(
                removals.count,
                .dialogResyncPlanRemoveSingle,
                .dialogResyncPlanRemovePlural,
                language: language,
                removals.count
            ),
            Localization.formatCount(
                updates.count,
                .dialogResyncPlanUpdateSingle,
                .dialogResyncPlanUpdatePlural,
                language: language,
                updates.count
            ),
        ]
        if !conflicts.isEmpty {
            lines.append(
                Localization.formatCount(
                    conflicts.count,
                    .dialogResyncPlanConflictSingle,
                    .dialogResyncPlanConflictPlural,
                    language: language,
                    conflicts.count,
                    conflictSummary(language: language)
                )
            )
        }
        return lines.joined(separator: "\n")
    }

    /// The conflict reasons with counts, for the confirmation and the report.
    public func conflictSummary(language: AppLanguage) -> String {
        var counts: [CopyQSyncResyncConflictReason: Int] = [:]
        for conflict in conflicts {
            counts[conflict.reason, default: 0] += 1
        }
        return CopyQSyncResyncConflictReason.allCases.compactMap { reason -> String? in
            guard let count = counts[reason], count > 0 else { return nil }
            return "\(count) \(reason.description(language: language))"
        }.joined(separator: "; ")
    }
}

public struct CopyQSyncResyncResult: Equatable, Sendable {
    public var entriesImported: Int = 0
    /// Folder stems whose payload already existed as a row, so they were
    /// linked to it instead of adding a duplicate.
    public var entriesLinked: Int = 0
    public var entriesRemoved: Int = 0
    public var entriesUpdated: Int = 0
    public var conflictsLeft: Int = 0
    public var failures: [String] = []

    public init(
        entriesImported: Int = 0,
        entriesLinked: Int = 0,
        entriesRemoved: Int = 0,
        entriesUpdated: Int = 0,
        conflictsLeft: Int = 0,
        failures: [String] = []
    ) {
        self.entriesImported = entriesImported
        self.entriesLinked = entriesLinked
        self.entriesRemoved = entriesRemoved
        self.entriesUpdated = entriesUpdated
        self.conflictsLeft = conflictsLeft
        self.failures = failures
    }

    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        var parts = [
            Localization.formatCount(
                entriesImported,
                .resyncResultImportedSingle,
                .resyncResultImportedPlural,
                language: language,
                entriesImported
            ),
            Localization.format(.resyncResultLinked, language: language, entriesLinked),
            Localization.format(.resyncResultRemoved, language: language, entriesRemoved),
            Localization.format(.resyncResultUpdated, language: language, entriesUpdated),
        ]
        if conflictsLeft > 0 {
            parts.append(
                Localization.formatCount(
                    conflictsLeft,
                    .resyncResultConflictsSingle,
                    .resyncResultConflictsPlural,
                    language: language,
                    conflictsLeft
                )
            )
        }
        if !failures.isEmpty {
            parts.append(
                Localization.format(.resyncResultSkipped, language: language, failures.count)
            )
        }
        return Localization.joinedSummarySentence(parts, language: language)
    }
}

public enum CopyQSyncResync {
    /// Reads the folder and the tab without changing either side.
    public static func report(
        tabID: Int64,
        in store: ClipboardStore,
        language: AppLanguage = .english
    ) throws -> CopyQSyncResyncReport {
        try compare(tabID: tabID, in: store, language: language).report
    }

    /// The write plan derived from the same comparison the report shows.  It
    /// reads only; `apply` performs the writes after an explicit confirmation.
    public static func plan(
        tabID: Int64,
        in store: ClipboardStore,
        language: AppLanguage = .english
    ) throws -> CopyQSyncResyncPlan {
        try plan(from: try compare(tabID: tabID, in: store, language: language), in: store)
    }

    /// The report and the plan from one scan of the folder and the store, so a
    /// dialog cannot describe a different state than the plan it offers.  The
    /// plan is nil while sync is paused; the report still reads.  Writes only
    /// happen through `apply` after an explicit confirmation.
    public static func reportAndPlan(
        tabID: Int64,
        in store: ClipboardStore,
        language: AppLanguage = .english
    ) throws -> (report: CopyQSyncResyncReport, plan: CopyQSyncResyncPlan?) {
        let comparison = try compare(tabID: tabID, in: store, language: language)
        guard try !store.preferences().syncPaused else {
            return (comparison.report, nil)
        }
        return (comparison.report, try plan(from: comparison, in: store))
    }

    private static func plan(
        from comparison: Comparison,
        in store: ClipboardStore
    ) throws -> CopyQSyncResyncPlan {
        let report = comparison.report
        let preferences = try store.preferences()
        guard !preferences.syncPaused else {
            throw CopyQSyncResyncError.syncPaused(report.tabName)
        }

        var updates: [CopyQSyncContentDifference] = []
        var removals: [CopyQSyncMissingEntry] = []
        var conflicts: [CopyQSyncResyncConflict] = []
        for removal in report.entriesWithoutFiles {
            if comparison.identities[removal.entryID]?.isLegacyIdentity == true {
                conflicts.append(CopyQSyncResyncConflict(
                    entryID: removal.entryID,
                    stems: [removal.stem],
                    reason: .unrelatedHistory
                ))
                continue
            }
            if try store.isEntryLocallyEdited(id: removal.entryID) {
                conflicts.append(CopyQSyncResyncConflict(
                    entryID: removal.entryID,
                    stems: [removal.stem],
                    reason: .locallyEdited
                ))
                continue
            }
            removals.append(removal)
        }
        for difference in report.contentDifferences {
            guard let entry = comparison.entries[difference.entryID],
                  let identity = comparison.identities[difference.entryID],
                  let target = updateTarget(
                      for: identity,
                      candidates: difference.differingStems,
                      itemsByStem: comparison.itemsByStem
                  )
            else { continue }
            if let reason = try refusal(
                of: entry,
                item: target.item,
                isLegacyIdentity: difference.isLegacyIdentity,
                hasConflictingGroups: hasConflictingGroups(
                    of: identity,
                    itemsByStem: comparison.itemsByStem,
                    unreadableStems: comparison.unreadableStems,
                    tabID: entry.tabID
                ),
                in: store
            ) {
                conflicts.append(CopyQSyncResyncConflict(
                    entryID: entry.id,
                    stems: difference.differingStems,
                    reason: reason
                ))
                continue
            }
            updates.append(CopyQSyncContentDifference(
                entryID: entry.id,
                differingStems: [target.stem],
                isLegacyIdentity: false
            ))
        }

        return CopyQSyncResyncPlan(
            tabID: report.tabID,
            tabName: report.tabName,
            folder: report.folder,
            imports: report.stemsWithoutEntries.sorted(),
            removals: removals,
            updates: updates,
            conflicts: conflicts
        )
    }

    /// The item stem a folder file name belongs to, or nil when the name
    /// carries no CopyQ format extension.
    private static func stemForFileName(_ name: String) -> String? {
        guard let ext = CopyQFormat.matchedExtension(forFileName: name),
              name.count > ext.count
        else { return nil }
        return String(name.dropLast(ext.count))
    }

    /// True when the row's owned groups do not all carry the same content the
    /// folder can decode, or when any owned group could not be fully decoded,
    /// so no single row content can satisfy every group.
    private static func hasConflictingGroups(
        of identity: CopyQSyncIdentity,
        itemsByStem: [String: CopyQSyncItem],
        unreadableStems: Set<String>,
        tabID: Int64
    ) -> Bool {
        if identity.stems.contains(where: unreadableStems.contains) {
            return true
        }
        var fingerprints = Set<String>()
        for owned in identity.stems {
            guard let item = itemsByStem[owned] else { continue }
            fingerprints.insert(CopyQSyncBridge.canonicalFingerprint(
                of: CopyQSyncBridge.itemToEntry(item, tabID: tabID)
            ))
        }
        return fingerprints.count > 1
    }

    /// The stem an update writes, with the folder item it uses.  The identity's
    /// canonical stem wins when the folder has its item; otherwise the first
    /// planned differing stem the folder can supply.  The plan and the apply
    /// both ask this one question, so a planned update always has its item.
    private static func updateTarget(
        for identity: CopyQSyncIdentity,
        candidates: [String],
        itemsByStem: [String: CopyQSyncItem]
    ) -> (stem: String, item: CopyQSyncItem)? {
        let stem = identity.canonicalStem.flatMap { itemsByStem[$0] == nil ? nil : $0 }
            ?? candidates.first { itemsByStem[$0] != nil }
        guard let stem, let item = itemsByStem[stem] else { return nil }
        return (stem, item)
    }

    /// Why the write path refuses one row, from the plan and again from the
    /// settled state in apply, so both ask the same question in one place.
    private static func refusal(
        of entry: ClipboardEntry,
        item: CopyQSyncItem,
        isLegacyIdentity: Bool,
        hasConflictingGroups: Bool,
        in store: ClipboardStore
    ) throws -> CopyQSyncResyncConflictReason? {
        if isLegacyIdentity {
            return .unrelatedHistory
        }
        if hasConflictingGroups {
            return .multipleGroups
        }
        let folderEntry = CopyQSyncBridge.itemToEntry(item, tabID: entry.tabID)
        if folderEntry.note != entry.note || folderEntry.pinned != entry.pinned {
            return .noteOrPin
        }
        if try store.isEntryLocallyEdited(id: entry.id) {
            return .locallyEdited
        }
        return nil
    }

    /// Executes a confirmed plan.
    ///
    /// The whole apply runs inside `CopyQSyncWriter.withSettledWrites`, so
    /// every queued capture write has finished and no new write can start
    /// while the folder and the store are compared and changed.  Removals run
    /// first so an import can never deduplicate onto a row that is about to be
    /// removed.  Every action is re-validated against the settled state and
    /// skipped with a reported reason when it no longer applies, so a stale
    /// confirmation never performs an unconfirmed write.
    @discardableResult
    public static func apply(
        _ plan: CopyQSyncResyncPlan,
        in store: ClipboardStore,
        trashRoot: URL? = nil,
        watcher: CopyQSyncWatcher? = nil,
        writer: CopyQSyncWriter = .shared,
        language: AppLanguage = .english,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncResyncResult {
        let preferences = try store.preferences()
        guard !preferences.syncPaused else {
            throw CopyQSyncResyncError.syncPaused(plan.tabName)
        }
        var result = CopyQSyncResyncResult(conflictsLeft: plan.conflicts.count)
        guard !plan.isEmpty else { return result }

        guard let tab = try store.tab(id: plan.tabID) else {
            throw CopyQSyncResyncError.tabNotFound(plan.tabID)
        }
        guard let configured = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configured.isEmpty
        else {
            throw CopyQSyncResyncError.noSyncFolder(tab.name)
        }
        let currentFolder = CopyQSyncBridge.normalizePath(configured)
        guard currentFolder == plan.folder else {
            throw CopyQSyncResyncError.folderChanged(plan.folder, currentFolder)
        }

        return try writer.withSettledWrites {
            // The folder is read inside the barrier, so a queued write that
            // settled just before it is already visible here.
            let contents: CopyQSyncFolder.Contents
            do {
                contents = try CopyQSyncFolder.read(atPath: plan.folder)
            } catch {
                throw CopyQSyncResyncError.folderUnreadable(
                    plan.folder,
                    error.localizedDescription
                )
            }

            let settleDelay = watcher?.settleDelay ?? CopyQSyncWatcher.shared.settleDelay
            let unreadableStems = Set((contents.failures + contents.skippedFiles).compactMap {
                stemForFileName($0.fileName)
            })
            let groups = CopyQSyncWatcher.findItemGroups(in: plan.folder)
            var readyStems = Set<String>()
            var settlingStems = Set<String>()
            for group in groups {
                if group.isSettled(settleDelay: settleDelay) {
                    readyStems.insert(group.stem)
                } else {
                    settlingStems.insert(group.stem)
                }
            }

            var itemsByStem: [String: CopyQSyncItem] = [:]
            var internalStems = Set<String>()
            for item in contents.items {
                guard let baseName = item.baseName, !baseName.isEmpty else { continue }
                guard readyStems.contains(baseName) else {
                    settlingStems.insert(baseName)
                    continue
                }
                if CopyQSyncBridge.isInternalOnly(item) {
                    internalStems.insert(baseName)
                } else {
                    itemsByStem[baseName] = item
                }
            }
            let groupStems = Set(groups.map(\.stem))

            applyRemovals(
                plan,
                groupStems: groupStems,
                in: store,
                trashRoot: trashRoot,
                watcher: watcher,
                language: language,
                fileManager: fileManager,
                result: &result
            )
            applyImports(
                plan,
                itemsByStem: itemsByStem,
                internalStems: internalStems,
                settlingStems: settlingStems,
                in: store,
                watcher: watcher,
                result: &result
            )
            applyUpdates(
                plan,
                itemsByStem: itemsByStem,
                groupStems: groupStems,
                settlingStems: settlingStems,
                unreadableStems: unreadableStems,
                tab: tab,
                in: store,
                trashRoot: trashRoot,
                watcher: watcher,
                fileManager: fileManager,
                result: &result
            )
            return result
        }
    }

    // MARK: - Comparison

    /// The single read both surfaces use: one folder scan and one store scan.
    private struct Comparison {
        let report: CopyQSyncResyncReport
        let itemsByStem: [String: CopyQSyncItem]
        let entries: [Int64: ClipboardEntry]
        let identities: [Int64: CopyQSyncIdentity]
        let unreadableStems: Set<String>
    }

    private static func compare(
        tabID: Int64,
        in store: ClipboardStore,
        language: AppLanguage
    ) throws -> Comparison {
        guard let tab = try store.tab(id: tabID) else {
            throw CopyQSyncResyncError.tabNotFound(tabID)
        }
        guard let configured = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configured.isEmpty
        else {
            throw CopyQSyncResyncError.noSyncFolder(tab.name)
        }

        let folder = CopyQSyncBridge.normalizePath(configured)
        let owners = try CopyQSyncBridge.tabs(forSyncFolder: folder, in: store)
        if owners.count > 1 {
            throw CopyQSyncResyncError.ambiguousSyncFolder(
                folder,
                owners.map { "'\($0.name)' (id \($0.id))" }
            )
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CopyQSyncResyncError.folderMissing(folder)
        }

        let contents: CopyQSyncFolder.Contents
        do {
            contents = try CopyQSyncFolder.read(atPath: folder)
        } catch {
            throw CopyQSyncResyncError.folderUnreadable(folder, error.localizedDescription)
        }

        let readFailures = contents.failures + contents.skippedFiles
        var allStems: Set<String> = []
        var failedStems: Set<String> = []
        var importableStems: [String] = []
        var skippedInternalStems: [String] = []
        var itemsByStem: [String: CopyQSyncItem] = [:]

        for failure in readFailures {
            guard let stem = stemForFileName(failure.fileName) else { continue }
            allStems.insert(stem)
            failedStems.insert(stem)
        }

        for item in contents.items {
            guard let baseName = item.baseName, !baseName.isEmpty else { continue }
            allStems.insert(baseName)
            if CopyQSyncBridge.isInternalOnly(item) {
                if !failedStems.contains(baseName) {
                    skippedInternalStems.append(baseName)
                }
            } else {
                importableStems.append(baseName)
                itemsByStem[baseName] = item
            }
        }

        let entries = try store.recentEntries(limit: Int.max, tabID: tabID)
        let folderStems = Set(allStems)

        enum StemState: Hashable {
            case matched
            case different
            case unreadable
            case internalOnly
            case absent
        }

        func comparison(
            of stem: String,
            for entry: ClipboardEntry
        ) -> StemState {
            guard allStems.contains(stem) else { return .absent }
            if failedStems.contains(stem) { return .unreadable }
            guard let item = itemsByStem[stem] else {
                return skippedInternalStems.contains(stem) ? .internalOnly : .unreadable
            }
            let folderEntry = CopyQSyncBridge.itemToEntry(item, tabID: entry.tabID)
            return CopyQSyncBridge.canonicalFingerprint(of: folderEntry)
                == CopyQSyncBridge.canonicalFingerprint(of: entry)
                ? .matched
                : .different
        }

        var matched = 0
        var contentDifferences: [CopyQSyncContentDifference] = []
        var missing: [CopyQSyncMissingEntry] = []
        var identities: [Int64: CopyQSyncIdentity] = [:]
        var unresolved = 0
        var unreadableEntries = 0

        for entry in entries {
            let identity = CopyQSyncIdentityResolver.resolve(
                of: entry,
                in: store,
                folder: folder,
                groupStems: folderStems,
                persistLink: false
            )
            identities[entry.id] = identity
            guard !identity.stems.isEmpty else {
                unresolved += 1
                continue
            }
            let comparisons = identity.stems.map { ($0, comparison(of: $0, for: entry)) }
            let states = Set(comparisons.map(\.1))
            let differing = comparisons.filter { $0.1 == .different }.map(\.0)
            if !differing.isEmpty {
                contentDifferences.append(CopyQSyncContentDifference(
                    entryID: entry.id,
                    differingStems: differing,
                    isLegacyIdentity: identity.isLegacyIdentity,
                    hasConflictingGroups: hasConflictingGroups(
                        of: identity,
                        itemsByStem: itemsByStem,
                        unreadableStems: failedStems,
                        tabID: entry.tabID
                    )
                ))
            } else if states.contains(.unreadable) {
                unreadableEntries += 1
            } else if states.contains(.matched) {
                matched += 1
            } else if states.contains(.internalOnly) {
                unresolved += 1
            } else {
                let missingStem = CopyQSyncDeletion.canonicalStem(of: entry, among: identity.stems)
                    ?? identity.stems[0]
                missing.append(CopyQSyncMissingEntry(entryID: entry.id, stem: missingStem))
            }
        }

        var unowned: [String] = []
        for stem in importableStems {
            if try CopyQSyncBridge.existingOwner(
                stem: stem,
                tabID: tabID,
                folder: folder,
                in: store
            ) != nil {
                continue
            }
            if try store.isWrittenSyncStem(stem, folder: folder) {
                continue
            }
            unowned.append(stem)
        }

        let failures = readFailures.map {
            Localization.folderFailure($0, language: language)
        }
        let unreadableFileCount = Set(readFailures.map(\.fileName)).count

        let report = CopyQSyncResyncReport(
            tabID: tab.id,
            tabName: tab.name,
            folder: folder,
            matchedEntryCount: matched,
            contentDifferences: contentDifferences,
            entriesWithoutFiles: missing,
            stemsWithoutEntries: unowned,
            unresolvedEntryCount: unresolved,
            unreadableEntryCount: unreadableEntries,
            unreadableFileCount: unreadableFileCount,
            skippedInternalStems: skippedInternalStems,
            failures: failures
        )
        var entriesByID: [Int64: ClipboardEntry] = [:]
        for entry in entries {
            entriesByID[entry.id] = entry
        }
        return Comparison(
            report: report,
            itemsByStem: itemsByStem,
            entries: entriesByID,
            identities: identities,
            unreadableStems: failedStems
        )
    }

    // MARK: - Apply steps

    private static func applyRemovals(
        _ plan: CopyQSyncResyncPlan,
        groupStems: Set<String>,
        in store: ClipboardStore,
        trashRoot: URL?,
        watcher: CopyQSyncWatcher?,
        language: AppLanguage,
        fileManager: FileManager,
        result: inout CopyQSyncResyncResult
    ) {
        guard !plan.removals.isEmpty else { return }
        var victims: [ClipboardEntry] = []
        var ownedStems: [Int64: [String]] = [:]
        for removal in plan.removals {
            guard let entry = try? store.entry(id: removal.entryID) else {
                result.failures.append("Skipped \(removal.stem): the entry no longer exists.")
                continue
            }
            let identity = CopyQSyncIdentityResolver.resolve(
                of: entry,
                in: store,
                folder: plan.folder,
                groupStems: groupStems,
                persistLink: false,
                fileManager: fileManager
            )
            guard !identity.stems.isEmpty else {
                result.failures.append("Skipped \(removal.stem): the entry has no resolved sync identity.")
                continue
            }
            if identity.isLegacyIdentity {
                result.conflictsLeft += 1
                result.failures.append(
                    "Kept \(removal.stem): \(CopyQSyncResyncConflictReason.unrelatedHistory.description)."
                )
                continue
            }
            let locallyEdited: Bool
            do {
                locallyEdited = try store.isEntryLocallyEdited(id: entry.id)
            } catch {
                result.failures.append(
                    "Could not check \(removal.stem) for a pending local edit: \(error.localizedDescription)"
                )
                continue
            }
            if locallyEdited {
                result.conflictsLeft += 1
                result.failures.append(
                    "Kept \(removal.stem): \(CopyQSyncResyncConflictReason.locallyEdited.description)."
                )
                continue
            }
            if identity.stems.contains(where: { groupStems.contains($0) }) {
                result.failures.append("Skipped \(removal.stem): its group reappeared in the folder.")
                continue
            }
            if identity.stems.contains(where: {
                CopyQSyncWatcher.hasTemporaryFiles(forStem: $0, in: plan.folder)
            }) {
                result.failures.append("Skipped \(removal.stem): its group is still being written.")
                continue
            }
            victims.append(entry)
            ownedStems[entry.id] = identity.stems
        }
        guard !victims.isEmpty else { return }

        do {
            let deletion = try CopyQSyncDeletion.deleteEntriesMissingFiles(
                victims,
                in: store,
                trashRoot: trashRoot,
                keepUnarchivedRows: true,
                language: language,
                fileManager: fileManager
            )
            result.entriesRemoved += deletion.deletedEntryCount
            result.failures.append(contentsOf: deletion.failures)
            for entry in victims {
                for stem in ownedStems[entry.id] ?? [] {
                    syncStemCaches(stem: stem, folder: plan.folder, in: store, watcher: watcher)
                }
            }
        } catch {
            result.failures.append(
                "Could not remove the entries whose files are gone: \(error.localizedDescription)"
            )
        }
    }

    private static func applyImports(
        _ plan: CopyQSyncResyncPlan,
        itemsByStem: [String: CopyQSyncItem],
        internalStems: Set<String>,
        settlingStems: Set<String>,
        in store: ClipboardStore,
        watcher: CopyQSyncWatcher?,
        result: inout CopyQSyncResyncResult
    ) {
        for stem in plan.imports {
            guard !internalStems.contains(stem), let item = itemsByStem[stem] else {
                if settlingStems.contains(stem) {
                    result.failures.append("Skipped \(stem): its group is still being written.")
                } else {
                    result.failures.append("Skipped \(stem): it is no longer importable folder content.")
                }
                continue
            }
            do {
                if try CopyQSyncBridge.existingOwner(
                    stem: stem,
                    tabID: plan.tabID,
                    folder: plan.folder,
                    in: store
                ) != nil {
                    result.failures.append("Skipped \(stem): an entry already owns it.")
                    continue
                }
                if try store.isWrittenSyncStem(stem, folder: plan.folder) {
                    result.failures.append("Skipped \(stem): this app wrote it and no entry owns it.")
                    continue
                }
                switch try CopyQSyncBridge.importSyncItem(
                    item,
                    stem: stem,
                    tabID: plan.tabID,
                    folder: plan.folder,
                    in: store
                ) {
                case .inserted:
                    result.entriesImported += 1
                case .duplicate, .refreshed:
                    result.entriesLinked += 1
                case .updated:
                    result.entriesUpdated += 1
                case .localVersionPending:
                    result.conflictsLeft += 1
                    result.failures.append("Skipped \(stem): the entry has a local edit that has not reached the folder.")
                case .skippedUpstream:
                    result.conflictsLeft += 1
                    result.failures.append("Skipped \(stem): the folder's version is older than the entry's.")
                case .skippedInternal:
                    result.failures.append("Skipped \(stem): it carries no content.")
                }
                syncStemCaches(stem: stem, folder: plan.folder, in: store, watcher: watcher)
            } catch {
                result.failures.append("Could not import \(stem): \(error.localizedDescription)")
            }
        }
    }

    private static func applyUpdates(
        _ plan: CopyQSyncResyncPlan,
        itemsByStem: [String: CopyQSyncItem],
        groupStems: Set<String>,
        settlingStems: Set<String>,
        unreadableStems: Set<String>,
        tab: ClipboardTab,
        in store: ClipboardStore,
        trashRoot: URL?,
        watcher: CopyQSyncWatcher?,
        fileManager: FileManager,
        result: inout CopyQSyncResyncResult
    ) {
        for update in plan.updates {
            let planned = update.differingStems.first ?? "the planned update"
            guard let entry = try? store.entry(id: update.entryID) else {
                result.failures.append("Skipped \(planned): the entry no longer exists.")
                continue
            }
            let identity = CopyQSyncIdentityResolver.resolve(
                of: entry,
                in: store,
                folder: plan.folder,
                groupStems: groupStems,
                persistLink: false,
                fileManager: fileManager
            )
            if identity.stems.contains(where: { settlingStems.contains($0) }) {
                result.failures.append("Skipped \(planned): its group is still being written.")
                continue
            }
            guard let target = updateTarget(
                for: identity,
                candidates: update.differingStems,
                itemsByStem: itemsByStem
            ) else {
                result.failures.append("Skipped \(planned): the folder item is gone.")
                continue
            }
            let stem = target.stem
            let item = target.item
            let folderEntry = CopyQSyncBridge.itemToEntry(item, tabID: entry.tabID)
            let folderFingerprint = CopyQSyncBridge.canonicalFingerprint(of: folderEntry)
            let reason: CopyQSyncResyncConflictReason?
            do {
                reason = try refusal(
                    of: entry,
                    item: item,
                    isLegacyIdentity: identity.isLegacyIdentity,
                    hasConflictingGroups: hasConflictingGroups(
                        of: identity,
                        itemsByStem: itemsByStem,
                        unreadableStems: unreadableStems,
                        tabID: entry.tabID
                    ),
                    in: store
                )
            } catch {
                result.failures.append(
                    "Could not check \(stem) for a pending local edit: \(error.localizedDescription)"
                )
                continue
            }
            if let reason {
                result.conflictsLeft += 1
                result.failures.append("Kept \(stem): \(reason.description).")
                continue
            }
            if folderFingerprint == CopyQSyncBridge.canonicalFingerprint(of: entry) {
                result.failures.append("Skipped \(stem): the entry already has the folder's content.")
                continue
            }

            do {
                // The previous payload stays recoverable before it is replaced.
                try CopyQSyncTrash.archiveEntry(
                    entry,
                    stem: stem,
                    folder: plan.folder,
                    tab: tab,
                    reason: .resyncUpdate,
                    trashRoot: trashRoot,
                    fileManager: fileManager
                )
                try store.replaceFlavours(
                    of: entry.id,
                    with: folderEntry.flavours,
                    note: entry.note,
                    pinned: entry.pinned
                )
                let version = max(
                    (try store.syncUpdatedAt(id: entry.id)) ?? entry.createdAt,
                    CopyQSyncBridge.resolvedDate(for: item) ?? entry.createdAt
                )
                try store.recordSyncedVersion(
                    id: entry.id,
                    date: version,
                    fingerprint: folderFingerprint
                )
                try store.recordWrittenSyncStem(
                    stem,
                    folder: plan.folder,
                    entryID: entry.id
                )
                syncStemCaches(stem: stem, folder: plan.folder, in: store, watcher: watcher)
                result.entriesUpdated += 1
            } catch {
                result.failures.append("Could not update \(stem): \(error.localizedDescription)")
            }
        }
    }

    /// Re-derives the in-memory echo cache from the durable record after a
    /// write, so a stale in-memory stem is never reused.
    private static func syncStemCaches(
        stem: String,
        folder: String,
        in store: ClipboardStore,
        watcher: CopyQSyncWatcher?
    ) {
        let written = (try? store.isWrittenSyncStem(stem, folder: folder)) == true
        if written {
            CopyQSyncWatcher.shared.recordWrittenStem(stem, folder: folder)
            watcher?.recordWrittenStem(stem, folder: folder)
        } else {
            CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: folder)
            watcher?.removeWrittenStem(stem, folder: folder)
        }
    }
}
