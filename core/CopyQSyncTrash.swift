// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncTrash.swift
//
// Recoverable home for sync file groups removed by the app.  A group is moved
// out of the sync tree with its original file names and a small metadata file,
// so Syncthing propagates the deletion while the bytes stay recoverable on
// this machine.  Nothing in the trash is ever written back into a sync folder
// automatically.

import Foundation

public enum CopyQSyncTrashReason: String, Codable, Equatable, Sendable {
    case localDelete = "local-delete"
    case remoteDelete = "remote-delete"
    case reconciliation = "reconcile-missing-file"
    /// The entry moved to a tab that has no sync folder. Its files are kept
    /// recoverable in the trash, never left orphaned in the old folder.
    case movedToTab = "move-to-tab"
    /// A duplicate group the entry no longer needs after its stems converged.
    case supersededGroup = "superseded-group"
    /// A resync replaced the entry's payload with the folder's version; the
    /// previous payload is kept recoverable here.
    case resyncUpdate = "resync-update"
}

public struct CopyQSyncTrashRecord: Codable, Equatable, Sendable {
    public let stem: String
    public let folder: String
    public let tabID: Int64
    public let tabName: String
    public let reason: CopyQSyncTrashReason
    public let deletedAt: Date
    /// File names relative to the batch directory, with their original names.
    public let files: [String]

    public init(
        stem: String,
        folder: String,
        tabID: Int64,
        tabName: String,
        reason: CopyQSyncTrashReason,
        deletedAt: Date = Date(),
        files: [String]
    ) {
        self.stem = stem
        self.folder = folder
        self.tabID = tabID
        self.tabName = tabName
        self.reason = reason
        self.deletedAt = deletedAt
        self.files = files
    }
}

public struct CopyQSyncTrashBatch: Equatable, Sendable {
    public let directory: URL
    public let records: [CopyQSyncTrashRecord]

    public init(directory: URL, records: [CopyQSyncTrashRecord]) {
        self.directory = directory
        self.records = records
    }

    public var files: [String] { records.flatMap(\.files) }
}

public struct CopyQSyncTrashSummary: Equatable, Sendable {
    public let batchCount: Int
    public let fileCount: Int
    public let byteCount: Int64

    public init(batchCount: Int = 0, fileCount: Int = 0, byteCount: Int64 = 0) {
        self.batchCount = batchCount
        self.fileCount = fileCount
        self.byteCount = byteCount
    }

    public func summary(language: AppLanguage) -> String {
        guard batchCount > 0 else { return Localization.string(.dialogTrashEmpty, language: language) }
        return Localization.format(
            .dialogTrashSummary,
            language: language,
            batchCount,
            fileCount,
            byteCount
        )
    }
}

public enum CopyQSyncTrashError: LocalizedError, Equatable {
    case trashInsideSyncFolder(String)
    case unsafeTrashRoot(String)

    public var errorDescription: String? {
        switch self {
        case .trashInsideSyncFolder(let path):
            return "Refusing to move sync files into a trash folder inside the sync folder: \(path)"
        case .unsafeTrashRoot(let path):
            return "Refusing to empty an unsafe trash directory: \(path)"
        }
    }
}

public enum CopyQSyncTrash {
    public static let metadataFileName = "metadata.json"

    /// `~/Library/Application Support/CopyQmac/trash`, or the equivalent under
    /// `COPYQMAC_DATA_DIR`.  It lives beside the store, never in a sync folder.
    public static func defaultRootDirectory() throws -> URL {
        try ClipboardStore.defaultDirectoryURL().appendingPathComponent("trash", isDirectory: true)
    }

    public static func rootDirectory(override: URL? = nil) throws -> URL {
        if let override { return override.standardizedFileURL }
        return try defaultRootDirectory()
    }

    /// Rejects a trash location that is itself inside any configured sync
    /// folder.  Moving a group there would keep it inside the tree Syncthing
    /// watches, so the deletion would never propagate.
    public static func ensureOutsideSyncFolders(
        trashRoot: URL,
        syncFolders: [String]
    ) throws {
        let rootPath = CopyQSyncBridge.normalizePath(trashRoot.path)
        for folder in syncFolders {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = CopyQSyncBridge.normalizePath(trimmed)
            if rootPath == normalized || rootPath.hasPrefix(normalized + "/") {
                throw CopyQSyncTrashError.trashInsideSyncFolder(rootPath)
            }
        }
    }

    /// Moves one stem's complete file group out of `folder` into a new trash
    /// batch.  Returns nil when the folder no longer holds that group, so a
    /// caller deleting the matching entry still succeeds.
    @discardableResult
    public static func moveGroup(
        stem: String,
        fromFolder folder: String,
        tab: ClipboardTab,
        reason: CopyQSyncTrashReason,
        trashRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncTrashBatch? {
        let folderPath = CopyQSyncBridge.normalizePath(folder)
        let root = try rootDirectory(override: trashRoot)
        try ensureTrashIsOutsideSyncFolder(root, folder: folderPath)
        guard let group = CopyQSyncWatcher.findItemGroups(in: folderPath)
            .first(where: { $0.stem == stem }),
              !group.files.isEmpty
        else { return nil }

        let batchDirectory = try makeBatchDirectory(
            root: root,
            stem: stem,
            fileManager: fileManager
        )
        let sourceDirectory = URL(fileURLWithPath: folderPath, isDirectory: true)
        var moved: [String] = []

        do {
            for filename in group.files.sorted() {
                guard isSafeFileName(filename) else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                let source = sourceDirectory.appendingPathComponent(filename)
                let destination = batchDirectory.appendingPathComponent(filename)
                try fileManager.moveItem(at: source, to: destination)
                moved.append(filename)
            }
            let record = CopyQSyncTrashRecord(
                stem: stem,
                folder: folderPath,
                tabID: tab.id,
                tabName: tab.name,
                reason: reason,
                files: moved
            )
            try writeMetadata([record], to: batchDirectory, fileManager: fileManager)
            return CopyQSyncTrashBatch(directory: batchDirectory, records: [record])
        } catch {
            if restoreFiles(moved, from: batchDirectory, to: sourceDirectory, fileManager: fileManager) {
                try? fileManager.removeItem(at: batchDirectory)
            }
            throw error
        }
    }

    /// Preserves a local entry whose sync files are already gone.  The payload
    /// is written with the group's original stem and CopyQ file names, so it
    /// can be re-imported from the trash later.
    @discardableResult
    public static func archiveEntry(
        _ entry: ClipboardEntry,
        stem: String,
        folder: String,
        tab: ClipboardTab,
        reason: CopyQSyncTrashReason,
        trashRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncTrashBatch? {
        guard !entry.hasOnlyInternalFlavours else { return nil }
        let folderPath = CopyQSyncBridge.normalizePath(folder)
        let root = try rootDirectory(override: trashRoot)
        try ensureTrashIsOutsideSyncFolder(root, folder: folderPath)

        let batchDirectory = try makeBatchDirectory(
            root: root,
            stem: stem,
            fileManager: fileManager
        )
        do {
            let item = CopyQSyncBridge.entryToItem(entry, baseNameOverride: stem)
            let written = try CopyQSyncFolder.write(item, into: batchDirectory.path)
            guard !written.isEmpty else {
                try? fileManager.removeItem(at: batchDirectory)
                return nil
            }
            let record = CopyQSyncTrashRecord(
                stem: stem,
                folder: folderPath,
                tabID: tab.id,
                tabName: tab.name,
                reason: reason,
                files: written
            )
            try writeMetadata([record], to: batchDirectory, fileManager: fileManager)
            return CopyQSyncTrashBatch(directory: batchDirectory, records: [record])
        } catch {
            try? fileManager.removeItem(at: batchDirectory)
            throw error
        }
    }

    /// Undoes a move so a failed database deletion cannot leave files stranded
    /// in the trash with their entries still present.
    public static func restore(
        _ batch: CopyQSyncTrashBatch,
        toFolder folder: String,
        fileManager: FileManager = .default
    ) {
        let folderURL = URL(
            fileURLWithPath: CopyQSyncBridge.normalizePath(folder),
            isDirectory: true
        )
        if restoreFiles(batch.files, from: batch.directory, to: folderURL, fileManager: fileManager) {
            try? fileManager.removeItem(at: batch.directory)
        }
    }

    public static func summary(
        trashRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> CopyQSyncTrashSummary {
        let root = try rootDirectory(override: trashRoot)
        guard fileManager.fileExists(atPath: root.path) else {
            return CopyQSyncTrashSummary()
        }
        let batches = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        var fileCount = 0
        var byteCount: Int64 = 0
        for batch in batches {
            guard let enumerator = fileManager.enumerator(
                at: batch,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                guard file.lastPathComponent != metadataFileName,
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
                fileCount += 1
                byteCount += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return CopyQSyncTrashSummary(
            batchCount: batches.count,
            fileCount: fileCount,
            byteCount: byteCount
        )
    }

    /// Removes every trash batch.  This is the only hard deletion, and it only
    /// happens when the user explicitly asks to empty the trash.
    @discardableResult
    public static func empty(
        trashRoot: URL? = nil,
        syncFolders: [String] = [],
        fileManager: FileManager = .default
    ) throws -> CopyQSyncTrashSummary {
        let root = try rootDirectory(override: trashRoot)
        let report = try summary(trashRoot: root, fileManager: fileManager)
        try ensureOutsideSyncFolders(trashRoot: root, syncFolders: syncFolders)
        let normalized = CopyQSyncBridge.normalizePath(root.path)
        guard normalized != "/",
              normalized != CopyQSyncBridge.normalizePath(NSHomeDirectory())
        else {
            throw CopyQSyncTrashError.unsafeTrashRoot(normalized)
        }
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        return report
    }

    // MARK: - Internals

    private static func ensureTrashIsOutsideSyncFolder(_ trashRoot: URL, folder: String) throws {
        let rootPath = CopyQSyncBridge.normalizePath(trashRoot.path)
        if rootPath == folder || rootPath.hasPrefix(folder + "/") {
            throw CopyQSyncTrashError.trashInsideSyncFolder(rootPath)
        }
    }

    private static func isSafeFileName(_ filename: String) -> Bool {
        !filename.isEmpty
            && !filename.hasPrefix("/")
            && !filename.contains("/")
            && !filename.contains("\0")
            && filename != "."
            && filename != ".."
    }

    private static func makeBatchDirectory(
        root: URL,
        stem: String,
        fileManager: FileManager
    ) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())

        let safeStem = sanitizedDirectoryName(stem)
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : "-\(attempt)"
            let candidate = root.appendingPathComponent("\(stamp)-\(safeStem)\(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            }
            attempt += 1
            if attempt > 10_000 {
                throw CocoaError(.fileWriteFileExists)
            }
        }
    }

    private static func sanitizedDirectoryName(_ stem: String) -> String {
        let cleaned = stem
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(60))
        return limited.isEmpty ? "item" : limited
    }

    private static func writeMetadata(
        _ records: [CopyQSyncTrashRecord],
        to directory: URL,
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: directory.appendingPathComponent(metadataFileName), options: .atomic)
    }

    /// Moves files back and reports whether every file reached the folder.
    /// When a destination already exists the batch is intentionally left in
    /// place instead of being removed, so a failed restore can never destroy
    /// the only remaining copy.
    @discardableResult
    private static func restoreFiles(
        _ filenames: [String],
        from batchDirectory: URL,
        to folder: URL,
        fileManager: FileManager
    ) -> Bool {
        var restoredAll = true
        for filename in filenames.reversed() {
            guard isSafeFileName(filename) else {
                restoredAll = false
                continue
            }
            let source = batchDirectory.appendingPathComponent(filename)
            let destination = folder.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: source.path) else {
                restoredAll = false
                continue
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                restoredAll = false
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                restoredAll = false
            }
        }
        return restoredAll
    }
}
