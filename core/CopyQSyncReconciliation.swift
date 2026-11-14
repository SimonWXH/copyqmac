// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncReconciliation.swift
//
// One-shot comparison of the local history with the configured sync folders.
// It never runs automatically: the menu action reports both mismatch counts and
// only acts after the user explicitly chooses the reconcile button.  The report
// is read-only, including no legacy-owner adoption.

import Foundation

public struct CopyQSyncMissingEntry: Equatable, Sendable {
    public let entryID: Int64
    public let stem: String

    public init(entryID: Int64, stem: String) {
        self.entryID = entryID
        self.stem = stem
    }
}

public struct CopyQSyncReconciliationTab: Equatable, Sendable {
    public let tabID: Int64
    public let tabName: String
    public let folder: String
    public let missingEntries: [CopyQSyncMissingEntry]
    public let groupsWithoutEntries: [String]

    public init(
        tabID: Int64,
        tabName: String,
        folder: String,
        missingEntries: [CopyQSyncMissingEntry],
        groupsWithoutEntries: [String]
    ) {
        self.tabID = tabID
        self.tabName = tabName
        self.folder = folder
        self.missingEntries = missingEntries
        self.groupsWithoutEntries = groupsWithoutEntries
    }
}

public struct CopyQSyncReconciliationReport: Equatable, Sendable {
    public var tabs: [CopyQSyncReconciliationTab]
    public var skippedFolders: [String]
    public var failures: [String]

    public init(
        tabs: [CopyQSyncReconciliationTab] = [],
        skippedFolders: [String] = [],
        failures: [String] = []
    ) {
        self.tabs = tabs
        self.skippedFolders = skippedFolders
        self.failures = failures
    }

    public var entriesWithoutFilesCount: Int {
        tabs.reduce(0) { $0 + $1.missingEntries.count }
    }

    public var fileGroupsWithoutEntriesCount: Int {
        tabs.reduce(0) { $0 + $1.groupsWithoutEntries.count }
    }

    public var mismatches: Bool {
        entriesWithoutFilesCount > 0 || fileGroupsWithoutEntriesCount > 0
    }

    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        var lines = [
            Localization.format(
                .dialogReconcileReportCounts,
                language: language,
                entriesWithoutFilesCount,
                fileGroupsWithoutEntriesCount
            )
        ]
        if !skippedFolders.isEmpty {
            lines.append(
                Localization.format(
                    .dialogReconcileReportSkipped,
                    language: language,
                    skippedFolders.joined(separator: ", ")
                )
            )
        }
        if !failures.isEmpty {
            lines.append(
                Localization.formatCount(
                    failures.count,
                    .dialogReconcileReportFailuresSingle,
                    .dialogReconcileReportFailuresPlural,
                    language: language,
                    failures.count
                )
            )
        }
        return lines.joined(separator: "\n")
    }
}

public struct CopyQSyncReconciliationResult: Equatable, Sendable {
    public var entriesRemoved: Int = 0
    public var groupsImported: Int = 0
    public var failures: [String] = []

    public init(entriesRemoved: Int = 0, groupsImported: Int = 0, failures: [String] = []) {
        self.entriesRemoved = entriesRemoved
        self.groupsImported = groupsImported
        self.failures = failures
    }

    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        var parts = [
            Localization.formatCount(
                entriesRemoved,
                .reconcileResultRemovedSingle,
                .reconcileResultRemovedPlural,
                language: language,
                entriesRemoved
            ),
            Localization.formatCount(
                groupsImported,
                .reconcileResultImportedSingle,
                .reconcileResultImportedPlural,
                language: language,
                groupsImported
            ),
        ]
        if !failures.isEmpty {
            parts.append(
                Localization.format(.reconcileResultFailed, language: language, failures.count)
            )
        }
        return Localization.joinedSummarySentence(parts, language: language)
    }
}

public enum CopyQSyncReconciliation {
    /// Counts both mismatch directions without changing the store or any file.
    public static func report(in store: ClipboardStore) throws -> CopyQSyncReconciliationReport {
        var report = CopyQSyncReconciliationReport()

        let tabs = try store.tabs()
        var tabCountsByFolder: [String: Int] = [:]
        for tab in tabs {
            guard let folder = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !folder.isEmpty
            else { continue }
            let normalized = CopyQSyncBridge.normalizePath(folder)
            tabCountsByFolder[normalized, default: 0] += 1
        }

        for tab in tabs {
            guard let folder = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !folder.isEmpty
            else { continue }
            let normalized = CopyQSyncBridge.normalizePath(folder)
            guard tabCountsByFolder[normalized] == 1 else {
                if !report.skippedFolders.contains(normalized) {
                    report.skippedFolders.append(normalized)
                }
                continue
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                report.failures.append("Sync folder does not exist: \(normalized)")
                continue
            }

            let groups = CopyQSyncWatcher.findItemGroups(in: normalized)
            let folderStems = Set(groups.map(\.stem))
            let entries = try store.recentEntries(limit: Int.max, tabID: tab.id)

            var missing: [CopyQSyncMissingEntry] = []
            for entry in entries {
                let stems = CopyQSyncDeletion.syncBaseNames(
                    of: entry,
                    in: store,
                    folder: normalized,
                    groupStems: folderStems,
                    persistLink: false
                )
                guard !stems.isEmpty else { continue }
                if stems.contains(where: { folderStems.contains($0) }) { continue }
                let missingStem = CopyQSyncDeletion.canonicalStem(of: entry, among: stems) ?? stems[0]
                missing.append(CopyQSyncMissingEntry(entryID: entry.id, stem: missingStem))
            }

            var unowned: [String] = []
            for stem in folderStems.sorted() {
                if try CopyQSyncBridge.existingOwner(
                    stem: stem,
                    tabID: tab.id,
                    folder: normalized,
                    in: store
                ) == nil {
                    // A stem this app wrote but no longer owns (for example a
                    // group released by a tab move) is suppressed, not an
                    // orphan to import again.
                    if try store.isWrittenSyncStem(stem, folder: normalized) {
                        continue
                    }
                    unowned.append(stem)
                }
            }

            if !missing.isEmpty || !unowned.isEmpty {
                report.tabs.append(CopyQSyncReconciliationTab(
                    tabID: tab.id,
                    tabName: tab.name,
                    folder: normalized,
                    missingEntries: missing,
                    groupsWithoutEntries: unowned
                ))
            }
        }
        return report
    }

    /// Applies the report the user has just seen: missing-file entries are
    /// archived to the app trash and removed, and file groups with no entry are
    /// imported into their mapped tab.  This is only called from the explicit
    /// reconcile choice in the confirmation dialog.
    @discardableResult
    public static func apply(
        _ report: CopyQSyncReconciliationReport,
        in store: ClipboardStore,
        trashRoot: URL? = nil
    ) throws -> CopyQSyncReconciliationResult {
        var result = CopyQSyncReconciliationResult()
        let entryIDs = report.tabs.flatMap { $0.missingEntries.map(\.entryID) }
        if !entryIDs.isEmpty {
            let entries = try store.entries(ids: entryIDs)
            let deletion = try CopyQSyncDeletion.deleteEntriesMissingFiles(
                entries,
                in: store,
                trashRoot: trashRoot
            )
            result.entriesRemoved = deletion.deletedEntryCount
            result.failures.append(contentsOf: deletion.failures)
        }

        for tab in report.tabs where !tab.groupsWithoutEntries.isEmpty {
            do {
                let imported = try CopyQSyncBridge.importSyncFolder(
                    atPath: tab.folder,
                    intoTabID: tab.tabID,
                    in: store
                )
                result.groupsImported += imported.importedCount
                result.failures.append(contentsOf: imported.failures)
            } catch {
                result.failures.append(
                    "Could not import \(tab.folder): \(error.localizedDescription)"
                )
            }
        }
        return result
    }
}
