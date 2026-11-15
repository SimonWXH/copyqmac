// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncRestore.swift
//
// The one path that writes a tab's local items back into its sync folder.
//
// Every other write path in the app is driven by an event: a capture, a typed
// new item, or an edit.  This one is driven by a tab, and it exists for one
// recovery case: the folder was emptied by another program while the history
// kept every item, and the other machine has to see the items again.
//
// `plan` reads the folder and the store and names, with counts, exactly what a
// write would do: how many entries are written, how many files are created and
// rewritten, and every entry it refuses to write together with why.  `apply`
// executes that plan through `CopyQSyncWriter`, so the files are byte-identical
// to what a capture or an edit writes and the writer's naming, collision
// bumping, echo suppression, and `written_sync_stems` ownership all apply.
//
// Write-only is a hard boundary: the folder is never deleted from, renamed, or
// rearranged.  A row that already owns a stem is rewritten in place, which
// replaces that stem's own group - the writer's rule for a content change - and
// every file under any other stem is left alone.  A failure stops the run where
// it happened and keeps every file already written; there is no rollback that
// removes them.

import Foundation

/// One entry a confirmed write will put back into the folder, with the file
/// names it produces.  A name that already exists is rewritten in place and a
/// name that does not is created, so the confirmation counts both.
public struct CopyQSyncRestoreRow: Equatable, Sendable {
    public let entryID: Int64
    /// The stem the write uses: the row's own stem when it owns one, otherwise
    /// the fresh stem it will be given.
    public let stem: String
    /// Files the write creates because they do not exist yet.
    public let filesToCreate: [String]
    /// Files the write replaces because they already exist under this stem.
    public let filesToUpdate: [String]

    public init(
        entryID: Int64,
        stem: String,
        filesToCreate: [String],
        filesToUpdate: [String]
    ) {
        self.entryID = entryID
        self.stem = stem
        self.filesToCreate = filesToCreate
        self.filesToUpdate = filesToUpdate
    }
}

/// Why a plan leaves one local entry unwritten.
public enum CopyQSyncRestoreSkipReason: String, CaseIterable, Equatable, Sendable {
    /// The row holds nothing but this app's own bookkeeping markers.
    case internalOnly
    /// The row holds nothing at all: no flavour, no note, and no pin.
    case emptyContent
    /// The row holds payload that cannot be folded into a sync item, so the
    /// write would produce a contentless group.
    case undecodable
    /// The folder already carries exactly this row's content.
    case alreadyInSync
    /// The row's stem comes only from the legacy creation-time rule and the
    /// folder's content differs, so the group could be unrelated history.
    case unrelatedHistory

    public var description: String {
        description(language: .english)
    }

    public func description(language: AppLanguage) -> String {
        switch self {
        case .internalOnly:
            return Localization.string(.dialogWriteBackSkipInternalOnly, language: language)
        case .emptyContent:
            return Localization.string(.dialogWriteBackSkipEmptyContent, language: language)
        case .undecodable:
            return Localization.string(.dialogWriteBackSkipUndecodable, language: language)
        case .alreadyInSync:
            return Localization.string(.dialogWriteBackSkipAlreadyInSync, language: language)
        case .unrelatedHistory:
            return Localization.string(.dialogWriteBackSkipUnrelatedHistory, language: language)
        }
    }
}

public struct CopyQSyncRestoreSkip: Equatable, Sendable {
    public let entryID: Int64
    /// The row's stem when it has one, so a report can name the group.
    public let stem: String?
    public let reason: CopyQSyncRestoreSkipReason

    public init(entryID: Int64, stem: String?, reason: CopyQSyncRestoreSkipReason) {
        self.entryID = entryID
        self.stem = stem
        self.reason = reason
    }
}

/// What an explicit write-back will do.  The confirmation text is generated
/// from this value, so the dialog and the write cannot describe different work.
public struct CopyQSyncRestorePlan: Equatable, Sendable {
    public let tabID: Int64
    public let tabName: String
    public let folder: String
    public let rows: [CopyQSyncRestoreRow]
    /// Entries the plan refuses to write, with the reason for each.
    public let skipped: [CopyQSyncRestoreSkip]

    public init(
        tabID: Int64,
        tabName: String,
        folder: String,
        rows: [CopyQSyncRestoreRow],
        skipped: [CopyQSyncRestoreSkip]
    ) {
        self.tabID = tabID
        self.tabName = tabName
        self.folder = folder
        self.rows = rows
        self.skipped = skipped
    }

    public var entryCount: Int { rows.count }
    public var fileCreateCount: Int { rows.reduce(0) { $0 + $1.filesToCreate.count } }
    public var fileUpdateCount: Int { rows.reduce(0) { $0 + $1.filesToUpdate.count } }
    public var isEmpty: Bool { rows.isEmpty }

    /// The per-category counts, one line each, including the empty categories,
    /// plus the skips and their reasons.
    public func confirmation(language: AppLanguage) -> String {
        var lines: [String] = []
        if rows.isEmpty {
            lines.append(Localization.string(.dialogWriteBackNoItems, language: language))
        } else {
            lines.append(
                Localization.formatCount(
                    entryCount,
                    .dialogWriteBackPlanWriteSingle,
                    .dialogWriteBackPlanWritePlural,
                    language: language,
                    entryCount
                )
            )
            lines.append(
                Localization.formatCount(
                    fileCreateCount,
                    .dialogWriteBackPlanCreateSingle,
                    .dialogWriteBackPlanCreatePlural,
                    language: language,
                    fileCreateCount
                )
            )
            lines.append(
                Localization.formatCount(
                    fileUpdateCount,
                    .dialogWriteBackPlanUpdateSingle,
                    .dialogWriteBackPlanUpdatePlural,
                    language: language,
                    fileUpdateCount
                )
            )
        }
        if !skipped.isEmpty {
            lines.append(
                Localization.formatCount(
                    skipped.count,
                    .dialogWriteBackPlanSkipSingle,
                    .dialogWriteBackPlanSkipPlural,
                    language: language,
                    skipped.count,
                    skipSummary(language: language)
                )
            )
        }
        return lines.joined(separator: "\n")
    }

    /// The skip reasons with counts, for the confirmation and the report.
    public func skipSummary(language: AppLanguage) -> String {
        var counts: [CopyQSyncRestoreSkipReason: Int] = [:]
        for skip in skipped {
            counts[skip.reason, default: 0] += 1
        }
        return CopyQSyncRestoreSkipReason.allCases.compactMap { reason -> String? in
            guard let count = counts[reason], count > 0 else { return nil }
            return "\(count) \(reason.description(language: language))"
        }.joined(separator: "; ")
    }
}

/// The stage a write-back stopped at, so a failed run names where it gave up.
public enum CopyQSyncRestoreStage: Equatable, Sendable {
    case readingFolder
    case writingGroup(stem: String)

    public var description: String {
        description(language: .english)
    }

    public func description(language: AppLanguage) -> String {
        switch self {
        case .readingFolder:
            return Localization.string(.writeBackStageReadFolder, language: language)
        case .writingGroup(let stem):
            return Localization.format(.writeBackStageWriteGroup, language: language, stem)
        }
    }
}

public struct CopyQSyncRestoreResult: Equatable, Sendable {
    public var entriesWritten: Int = 0
    public var filesCreated: Int = 0
    public var filesUpdated: Int = 0
    /// Every entry the run left unwritten, including the plan's own skips.
    public var skipped: [CopyQSyncRestoreSkip] = []
    public var failures: [String] = []
    /// Set when the run stopped before finishing; the files already written
    /// stay where they are.
    public var stoppedAt: CopyQSyncRestoreStage?

    public init(
        entriesWritten: Int = 0,
        filesCreated: Int = 0,
        filesUpdated: Int = 0,
        skipped: [CopyQSyncRestoreSkip] = [],
        failures: [String] = [],
        stoppedAt: CopyQSyncRestoreStage? = nil
    ) {
        self.entriesWritten = entriesWritten
        self.filesCreated = filesCreated
        self.filesUpdated = filesUpdated
        self.skipped = skipped
        self.failures = failures
        self.stoppedAt = stoppedAt
    }

    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        var parts = [
            Localization.formatCount(
                entriesWritten,
                .writeBackResultWrittenSingle,
                .writeBackResultWrittenPlural,
                language: language,
                entriesWritten
            ),
            Localization.formatCount(
                filesCreated,
                .writeBackResultCreatedSingle,
                .writeBackResultCreatedPlural,
                language: language,
                filesCreated
            ),
            Localization.formatCount(
                filesUpdated,
                .writeBackResultUpdatedSingle,
                .writeBackResultUpdatedPlural,
                language: language,
                filesUpdated
            ),
            Localization.format(.writeBackResultSkipped, language: language, skipped.count),
        ]
        if let stoppedAt {
            parts.append(
                Localization.format(
                    .writeBackResultStopped,
                    language: language,
                    stoppedAt.description(language: language)
                )
            )
        }
        return Localization.joinedSummarySentence(parts, language: language)
    }
}

/// The per-group diagnostics a write-back reports.  The English text is the
/// record the runtime message translator matches, so one place holds the shape
/// the localization pattern table mirrors.
enum CopyQSyncRestoreDiagnostic {
    static func skippedEntryGone(_ stem: String) -> String {
        "Skipped \(stem): the entry no longer exists."
    }

    static func skippedNothingToWrite(_ stem: String) -> String {
        "Skipped \(stem): the writer found nothing to write."
    }

    static func couldNotWrite(_ stem: String, _ detail: String) -> String {
        "Could not write \(stem): \(detail)"
    }
}

public enum CopyQSyncRestore {
    /// Reads the folder and the tab and returns what a write would do.  It
    /// writes nothing, so it is safe to call before the confirmation.
    public static func plan(
        tabID: Int64,
        in store: ClipboardStore,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncRestorePlan {
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
        guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory),
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

        var itemsByStem: [String: CopyQSyncItem] = [:]
        for item in contents.items {
            guard let baseName = item.baseName, !baseName.isEmpty else { continue }
            if CopyQSyncBridge.isInternalOnly(item) {
                continue
            }
            itemsByStem[baseName] = item
        }
        let fileNames = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        let groupStems = Set(fileNames.compactMap(CopyQSyncWatcher.itemStem(ofFileName:)))

        let entries = try store.recentEntries(limit: Int.max, tabID: tabID)
        var rows: [CopyQSyncRestoreRow] = []
        var skipped: [CopyQSyncRestoreSkip] = []

        func skip(_ entry: ClipboardEntry, stem: String?, _ reason: CopyQSyncRestoreSkipReason) {
            skipped.append(CopyQSyncRestoreSkip(entryID: entry.id, stem: stem, reason: reason))
        }

        for entry in entries {
            if entry.flavours.isEmpty, entry.note.isEmpty, !entry.pinned {
                skip(entry, stem: nil, .emptyContent)
                continue
            }
            if entry.hasOnlyInternalFlavours {
                skip(entry, stem: nil, .internalOnly)
                continue
            }

            let identity = CopyQSyncIdentityResolver.resolve(
                of: entry,
                in: store,
                folder: folder,
                groupStems: groupStems,
                persistLink: false,
                fileManager: fileManager
            )
            let ownedStem = identity.canonicalStem
            if let ownedStem, let item = itemsByStem[ownedStem],
               CopyQSyncBridge.canonicalFingerprint(of: CopyQSyncBridge.itemToEntry(item, tabID: entry.tabID))
                   == CopyQSyncBridge.canonicalFingerprint(of: entry)
            {
                skip(entry, stem: ownedStem, .alreadyInSync)
                continue
            }
            // A stem that only the creation-time rule associates with the row,
            // whose folder content differs, may be another item's history.
            if identity.isLegacyIdentity {
                skip(entry, stem: ownedStem, .unrelatedHistory)
                continue
            }

            let stem = ownedStem ?? predictedStem(
                for: entry,
                in: folder,
                fileManager: fileManager
            )
            let item = CopyQSyncBridge.entryToItem(entry, baseNameOverride: stem)
            guard !item.data.formats.isEmpty else {
                skip(entry, stem: stem, .undecodable)
                continue
            }

            let produced = item.onDiskFiles().keys.map { stem + $0 }.sorted()
            let existing = Set(fileNames.filter {
                CopyQSyncWatcher.itemStem(ofFileName: $0) == stem
            })
            rows.append(CopyQSyncRestoreRow(
                entryID: entry.id,
                stem: stem,
                filesToCreate: produced.filter { !existing.contains($0) },
                filesToUpdate: produced.filter { existing.contains($0) }
            ))
        }

        return CopyQSyncRestorePlan(
            tabID: tab.id,
            tabName: tab.name,
            folder: folder,
            rows: rows,
            skipped: skipped
        )
    }

    /// Executes a confirmed plan.
    ///
    /// The whole write runs inside `CopyQSyncWriter.withSettledWrites`, so a
    /// queued capture write has finished and no new write can start while the
    /// rows are generated, and every row goes through the writer's own group
    /// install.  The folder is captured first so created and rewritten files
    /// are counted from what was actually there.  The first failure stops the
    /// remaining writes and keeps every file already written.
    @discardableResult
    public static func apply(
        _ plan: CopyQSyncRestorePlan,
        in store: ClipboardStore,
        writer: CopyQSyncWriter = .shared,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncRestoreResult {
        let preferences = try store.preferences()
        guard !preferences.syncPaused else {
            throw CopyQSyncResyncError.writeBackPaused(plan.tabName)
        }
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

        var result = CopyQSyncRestoreResult(skipped: plan.skipped)
        guard !plan.rows.isEmpty else { return result }

        return writer.withSettledWrites {
            let existing = Set((try? fileManager.contentsOfDirectory(atPath: plan.folder)) ?? [])
            for row in plan.rows {
                guard let entry = try? store.entry(id: row.entryID) else {
                    result.failures.append(
                        CopyQSyncRestoreDiagnostic.skippedEntryGone(row.stem)
                    )
                    continue
                }
                let identity = CopyQSyncIdentityResolver.resolve(
                    of: entry,
                    in: store,
                    folder: plan.folder,
                    persistLink: false,
                    fileManager: fileManager
                )
                let log = writer.updateEntry(
                    entry,
                    in: store,
                    reason: "write-back",
                    stem: identity.canonicalStem,
                    convergeSupersededGroups: false,
                    fileManager: fileManager
                )
                guard let log else {
                    // The writer found no row, no tab folder, or nothing to
                    // write; no file was touched, so the run continues.
                    result.failures.append(
                        CopyQSyncRestoreDiagnostic.skippedNothingToWrite(row.stem)
                    )
                    continue
                }
                if let error = log.error {
                    let stem = log.stem ?? row.stem
                    result.failures.append(
                        CopyQSyncRestoreDiagnostic.couldNotWrite(stem, error)
                    )
                    result.stoppedAt = .writingGroup(stem: stem)
                    break
                }
                for file in log.files {
                    if existing.contains(file.path) {
                        result.filesUpdated += 1
                    } else {
                        result.filesCreated += 1
                    }
                }
                result.entriesWritten += 1
            }
            return result
        }
    }

    /// The stem `CopyQSyncWriter.updateEntry` allocates for an entry that owns
    /// no group yet: the creation-time stamp, bumped by 1 ms until no file in
    /// the folder starts with it.  Asking the writer keeps the prediction and
    /// the write on one rule.
    private static func predictedStem(
        for entry: ClipboardEntry,
        in folder: String,
        fileManager: FileManager
    ) -> String {
        (try? CopyQSyncWriter.resolveUniqueStem(
            initialDate: entry.createdAt,
            directory: folder,
            fileManager: fileManager
        ).stem) ?? CopyQSyncBridge.formatTimestamp(entry.createdAt)
    }
}
