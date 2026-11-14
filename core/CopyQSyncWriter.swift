// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncWriter.swift
//
// Background service that writes captures, typed new items, and local edits into mapped CopyQ sync folders.
// Strictly adheres to CopyQ's on-disk format: a capture creates a new group with collision-bumped
// timestamps, an edit rewrites the entry's own group in place, and no other item's files are touched.
// Captures are queued off the main thread; an edit writes synchronously on the editing path so its
// outcome can be reported at once.

import Foundation

public struct SyncWrittenFile: Equatable, Sendable {
    public let path: String
    public let size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

public struct SyncLogEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let stem: String?
    public let folderPath: String
    public let reason: String
    public let files: [SyncWrittenFile]
    public let error: String?
    /// An informational note for a change that was not a file write and not a
    /// failure, such as a payload summary for the side of a content conflict
    /// that was discarded.
    public let detail: String?

    public var isSuccess: Bool { error == nil }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stem: String?,
        folderPath: String,
        reason: String,
        files: [SyncWrittenFile] = [],
        error: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stem = stem
        self.folderPath = folderPath
        self.reason = reason
        self.files = files
        self.error = error
        self.detail = detail
    }

    public var message: String {
        let formatter = ISO8601DateFormatter()
        let timeStr = formatter.string(from: timestamp)
        if let error = error {
            return "[\(timeStr)] ERROR [\(reason)] stem=\(stem ?? "unknown") folder=\(folderPath): \(error)"
        }
        if let detail {
            return "[\(timeStr)] DISCARDED [\(reason)] stem=\(stem ?? "") folder=\(folderPath): \(detail)"
        }
        let fileDetails = files.map { "\($0.path) (\($0.size) B)" }.joined(separator: ", ")
        let totalSize = files.reduce(0) { $0 + $1.size }
        return "[\(timeStr)] WRITTEN [\(reason)] stem=\(stem ?? "") folder=\(folderPath) files=[\(fileDetails)] total=\(totalSize) B"
    }
}

public enum CopyQSyncWriterSafety {
    /// Safety check: never write to upstream CopyQ application support, config, or archive files.
    public static func isForbiddenPath(_ path: String) -> Bool {
        let normalized = CopyQSyncBridge.normalizePath(path).lowercased()
        let home = NSHomeDirectory().lowercased()
        let forbidden = [
            (home as NSString).appendingPathComponent("library/application support/copyq"),
            (home as NSString).appendingPathComponent(".config/copyq"),
        ].map { CopyQSyncBridge.normalizePath($0).lowercased() }

        for p in forbidden {
            if normalized == p || normalized.hasPrefix(p + "/") {
                return true
            }
        }
        if normalized.hasSuffix("copyq_macos.cpq") || normalized.hasSuffix("copyq_fedora.conf") {
            return true
        }
        return false
    }
}

public final class CopyQSyncWriter: @unchecked Sendable {
    public static let shared = CopyQSyncWriter()

    public static let defaultMaxLogFileSize: Int64 = 1024 * 1024
    public static let defaultMaxRotatedFiles: Int = 2

    private let queue = DispatchQueue(label: "local.copyqmac.sync-writer", qos: .utility)
    private let logQueue = DispatchQueue(label: "local.copyqmac.sync-writer.log", qos: .utility)
    /// Serializes capture and in-place group writes, which can arrive from the
    /// edit path on the main thread, the capture queue, and the watcher's
    /// conflict resolution. Recursive so a capture write can delegate to the
    /// in-place rewrite while holding it.
    private let updateLock = NSRecursiveLock()

    public var customLogFilePath: String?
    public var maxLogFileSize: Int64 = CopyQSyncWriter.defaultMaxLogFileSize
    public var maxRotatedFiles: Int = CopyQSyncWriter.defaultMaxRotatedFiles

    public var logFilePath: String {
        if let custom = customLogFilePath {
            return custom
        }
        if let dir = try? ClipboardStore.defaultDirectoryURL() {
            return dir.appendingPathComponent("sync.log").path
        }
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent("Library/Application Support/CopyQmac/sync.log")
    }

    public init() {}

    public static func rotateLogs(at basePath: String, maxRotatedFiles: Int = 2, fileManager: FileManager = .default) {
        guard maxRotatedFiles > 0 else {
            try? fileManager.removeItem(atPath: basePath)
            return
        }

        let oldestPath = "\(basePath).\(maxRotatedFiles)"
        if fileManager.fileExists(atPath: oldestPath) {
            try? fileManager.removeItem(atPath: oldestPath)
        }

        if maxRotatedFiles > 1 {
            for index in (1..<maxRotatedFiles).reversed() {
                let current = "\(basePath).\(index)"
                let next = "\(basePath).\(index + 1)"
                if fileManager.fileExists(atPath: current) {
                    if fileManager.fileExists(atPath: next) {
                        try? fileManager.removeItem(atPath: next)
                    }
                    try? fileManager.moveItem(atPath: current, toPath: next)
                }
            }
        }

        let first = "\(basePath).1"
        if fileManager.fileExists(atPath: basePath) {
            if fileManager.fileExists(atPath: first) {
                try? fileManager.removeItem(atPath: first)
            }
            try? fileManager.moveItem(atPath: basePath, toPath: first)
        }
    }

    /// Resolves a unique stem in the folder. If any file begins with `stem`,
    /// collision bumping advances the stamp by 1ms iteratively.
    public static func resolveUniqueStem(
        initialDate: Date,
        directory: String,
        fileManager: FileManager = .default
    ) throws -> (stem: String, bumpedDate: Date) {
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(atPath: dirURL.path)) ?? []
        var date = initialDate
        var stem = CopyQSyncBridge.formatTimestamp(date)

        var attempts = 0
        while contents.contains(where: { $0.hasPrefix(stem) }) {
            attempts += 1
            if attempts > 100_000 {
                throw CocoaError(.fileWriteUnknown)
            }
            date = date.addingTimeInterval(0.001)
            stem = CopyQSyncBridge.formatTimestamp(date)
        }
        return (stem, date)
    }

    /// Installs one item group as a unit.
    ///
    /// Every file is staged under a temporary name, the previous group is moved
    /// aside, and only then are the staged files renamed into place. The
    /// temporary names make the group incomplete while it is being swapped, and
    /// a failure restores the previous group and removes every temporary file,
    /// so the folder never holds a mix of an old and a new group.
    private func installGroup(
        _ files: [String: Data],
        stem: String,
        in directory: URL,
        replacing previousNames: [String],
        fileManager: FileManager
    ) throws -> [SyncWrittenFile] {
        func url(_ name: String) -> URL {
            directory.appendingPathComponent(name)
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            where isInterruptedInstallFile(name, stem: stem) {
            try? fileManager.removeItem(at: url(name))
        }
        let staged = files.keys.sorted().map { (suffix: $0, name: stem + $0 + ".tmp") }

        do {
            for (suffix, data) in files {
                try data.write(to: url(stem + suffix + ".tmp"))
            }
        } catch {
            for entry in staged {
                try? fileManager.removeItem(at: url(entry.name))
            }
            throw error
        }

        var backups: [(backup: String, original: String)] = []
        var installed: [String] = []
        do {
            for name in previousNames.sorted() {
                let backup = name + ".bak"
                try? fileManager.removeItem(at: url(backup))
                try fileManager.moveItem(at: url(name), to: url(backup))
                backups.append((backup, name))
            }
            for entry in staged {
                let name = stem + entry.suffix
                try fileManager.moveItem(at: url(entry.name), to: url(name))
                installed.append(name)
            }
        } catch {
            for name in installed {
                try? fileManager.removeItem(at: url(name))
            }
            for entry in backups {
                try? fileManager.moveItem(at: url(entry.backup), to: url(entry.original))
            }
            for entry in staged {
                try? fileManager.removeItem(at: url(entry.name))
            }
            throw error
        }

        for entry in backups {
            try? fileManager.removeItem(at: url(entry.backup))
        }
        return staged.map {
            SyncWrittenFile(path: stem + $0.suffix, size: Int64(files[$0.suffix]?.count ?? 0))
        }
    }

    /// True when `name` is a staging or backup file this writer left behind for
    /// `stem`, for example after an install was interrupted.
    private func isInterruptedInstallFile(_ name: String, stem: String) -> Bool {
        guard !name.hasPrefix("."), !name.contains(".syncthing.") else { return false }
        let base: String
        if name.hasSuffix(".tmp") {
            base = String(name.dropLast(".tmp".count))
        } else if name.hasSuffix(".bak") {
            base = String(name.dropLast(".bak".count))
        } else {
            return false
        }
        return CopyQSyncWatcher.itemStem(ofFileName: base) == stem
    }

    /// Synchronously writes a newly captured entry into its mapped sync folder.
    /// Returns `nil` when sync is paused or the tab has no sync folder.
    @discardableResult
    public func writeEntry(
        _ entry: ClipboardEntry,
        in store: ClipboardStore,
        reason: String = "capture",
        fileManager: FileManager = .default
    ) throws -> SyncLogEntry? {
        updateLock.lock()
        defer { updateLock.unlock() }

        let preferences = try store.preferences()
        guard !preferences.syncPaused else {
            return nil
        }

        guard let tab = try store.tab(id: entry.tabID),
              let syncFolder = tab.syncFolder,
              !syncFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let normalizedFolder = CopyQSyncBridge.normalizePath(syncFolder)

        // An entry that holds nothing but our own bookkeeping markers has no
        // item to write. Writing it would create an empty item in the folder,
        // which CopyQ on the other device shows as a contentless entry and
        // syncs straight back.
        if entry.hasOnlyInternalFlavours {
            return nil
        }

        guard !CopyQSyncWriterSafety.isForbiddenPath(normalizedFolder) else {
            let log = SyncLogEntry(
                stem: nil,
                folderPath: normalizedFolder,
                reason: reason,
                error: "Refusing write: target directory is protected."
            )
            recordLog(log)
            throw CopyQSyncBridgeError.protectedPath("Refusing write: target directory is protected: \(normalizedFolder)")
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedFolder, isDirectory: &isDir), isDir.boolValue else {
            let log = SyncLogEntry(
                stem: nil,
                folderPath: normalizedFolder,
                reason: reason,
                error: "Target directory does not exist or is not a directory."
            )
            recordLog(log)
            throw CocoaError(.fileNoSuchFile)
        }

        // A queued capture write can run after an edit, so the group is built
        // from the stored row. A row deleted meanwhile is not resurrected.
        let current: ClipboardEntry
        if entry.id == ClipboardTab.unsavedID {
            current = entry
        } else if let stored = try? store.entry(id: entry.id) {
            current = stored
        } else {
            return nil
        }

        // A row that already owns a group here (for example an edit that
        // reached the writer before the queued capture write) is rewritten in
        // place instead of getting a second stem.
        if current.id != ClipboardTab.unsavedID,
           CopyQSyncDeletion.syncBaseName(
               of: current,
               in: store,
               folder: normalizedFolder,
               groupStems: CopyQSyncWatcher.itemGroupStems(in: normalizedFolder, fileManager: fileManager),
               fileManager: fileManager
           ) != nil
        {
            return updateEntry(current, in: store, reason: reason, fileManager: fileManager)
        }

        let (uniqueStem, _) = try Self.resolveUniqueStem(
            initialDate: current.createdAt,
            directory: normalizedFolder,
            fileManager: fileManager
        )

        let item = CopyQSyncBridge.entryToItem(current, baseNameOverride: uniqueStem)
        let onDiskFiles = item.onDiskFiles()
        let dirURL = URL(fileURLWithPath: normalizedFolder, isDirectory: true)

        // Safety check: ensure none of the candidate files exist
        for (suffix, _) in onDiskFiles {
            let candidateURL = dirURL.appendingPathComponent(uniqueStem + suffix)
            if fileManager.fileExists(atPath: candidateURL.path) {
                let log = SyncLogEntry(
                    stem: uniqueStem,
                    folderPath: normalizedFolder,
                    reason: reason,
                    error: "Collision: target file \(uniqueStem + suffix) already exists."
                )
                recordLog(log)
                throw CocoaError(.fileWriteFileExists)
            }
        }

        var written: [SyncWrittenFile] = []
        do {
            written = try installGroup(
                onDiskFiles,
                stem: uniqueStem,
                in: dirURL,
                replacing: [],
                fileManager: fileManager
            )
        } catch {
            let log = SyncLogEntry(
                stem: uniqueStem,
                folderPath: normalizedFolder,
                reason: reason,
                error: "Could not write the item's files: \(error.localizedDescription)"
            )
            recordLog(log)
            throw error
        }

        // Remember our own write durably and in memory to prevent echo loops,
        // and record the version the entry now reflects. The entry id makes the
        // stem resolvable later even when the entry's creation time moves.
        try? store.recordWrittenSyncStem(
            uniqueStem,
            folder: normalizedFolder,
            entryID: current.id == ClipboardTab.unsavedID ? nil : current.id
        )
        CopyQSyncWatcher.shared.recordWrittenStem(uniqueStem, folder: normalizedFolder)
        try? store.recordSyncedVersion(
            id: current.id,
            date: Date(),
            fingerprint: CopyQSyncBridge.writtenPayloadFingerprint(of: item)
        )

        let log = SyncLogEntry(
            stem: uniqueStem,
            folderPath: normalizedFolder,
            reason: reason,
            files: written
        )
        recordLog(log)
        return log
    }

    /// Rewrites the entry's own file group in its tab's sync folder after a
    /// local content edit.
    ///
    /// The group keeps the stem the entry already owns, so the other machine
    /// matches it to the same item and updates it in place instead of seeing a
    /// deletion plus a new item. When the entry does not own a stem yet, a fresh
    /// one is allocated from the entry's creation time. Every file of the group
    /// is regenerated and any file from the previous content that is no longer
    /// produced is removed, so a removed flavour never lingers as an orphan.
    ///
    /// A missing or unreadable folder never fails the edit: the failure is
    /// written to the sync log and returned, and the local row keeps the new
    /// content. When the entry owns several groups, the rewrite keeps one stem
    /// and moves the extra groups to the app trash.
    @discardableResult
    public func updateEntry(
        _ entry: ClipboardEntry,
        in store: ClipboardStore,
        reason: String = "edit",
        stem preferredStem: String? = nil,
        trashRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> SyncLogEntry? {
        updateLock.lock()
        defer { updateLock.unlock() }

        let preferences = (try? store.preferences()) ?? Preferences.defaultValue
        guard !preferences.syncPaused else { return nil }

        // A queued capture write can run after the user edited the row, so the
        // group is built from the stored version rather than a stale snapshot.
        // A row that was deleted meanwhile is not resurrected in the folder.
        let current: ClipboardEntry
        if entry.id == ClipboardTab.unsavedID {
            current = entry
        } else if let stored = try? store.entry(id: entry.id) {
            current = stored
        } else {
            return nil
        }

        guard let tab = try? store.tab(id: current.tabID),
              let syncFolder = tab.syncFolder,
              !syncFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let normalizedFolder = CopyQSyncBridge.normalizePath(syncFolder)

        // An entry that holds nothing but our own bookkeeping markers has no
        // item to write.
        guard !current.hasOnlyInternalFlavours else { return nil }

        func failure(_ message: String) -> SyncLogEntry {
            let log = SyncLogEntry(
                stem: nil,
                folderPath: normalizedFolder,
                reason: reason,
                error: message
            )
            recordLog(log)
            return log
        }

        guard !CopyQSyncWriterSafety.isForbiddenPath(normalizedFolder) else {
            return failure("Refusing write: target directory is protected.")
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: normalizedFolder, isDirectory: &isDir), isDir.boolValue else {
            return failure("Target directory does not exist or is not a directory.")
        }

        let folderNames = (try? fileManager.contentsOfDirectory(atPath: normalizedFolder)) ?? []
        let groupStems = Set(folderNames.compactMap(CopyQSyncWatcher.itemStem(ofFileName:)))
        var ownedStems = CopyQSyncDeletion.syncBaseNames(
            of: current,
            in: store,
            folder: normalizedFolder,
            groupStems: groupStems,
            fileManager: fileManager
        )
        if ownedStems.isEmpty,
           CopyQSyncBridge.recoverUnlinkedOwnership(
               in: store,
               folder: normalizedFolder,
               tabID: current.tabID,
               fileManager: fileManager
           )
        {
            ownedStems = CopyQSyncDeletion.syncBaseNames(
                of: current,
                in: store,
                folder: normalizedFolder,
                groupStems: groupStems,
                fileManager: fileManager
            )
        }
        let stem: String
        if let preferredStem, !preferredStem.isEmpty {
            stem = preferredStem
        } else if let canonical = CopyQSyncDeletion.canonicalStem(of: current, among: ownedStems) {
            stem = canonical
        } else {
            stem = (try? Self.resolveUniqueStem(
                initialDate: current.createdAt,
                directory: normalizedFolder,
                fileManager: fileManager
            ).stem) ?? CopyQSyncBridge.formatTimestamp(entry.createdAt)
        }

        let item = CopyQSyncBridge.entryToItem(current, baseNameOverride: stem)
        let newFiles = item.onDiskFiles()
        let dirURL = URL(fileURLWithPath: normalizedFolder, isDirectory: true)

        // Files from the previous content that this version may no longer
        // write. The whole group is replaced as a unit below.
        let previousNames = folderNames.filter {
            CopyQSyncWatcher.itemStem(ofFileName: $0) == stem
        }

        let written: [SyncWrittenFile]
        do {
            written = try installGroup(
                newFiles,
                stem: stem,
                in: dirURL,
                replacing: previousNames,
                fileManager: fileManager
            )
        } catch {
            let log = failure("Could not rewrite the item's files: \(error.localizedDescription)")
            return log
        }

        try? store.recordWrittenSyncStem(stem, folder: normalizedFolder, entryID: current.id)
        CopyQSyncWatcher.shared.recordWrittenStem(stem, folder: normalizedFolder)
        try? store.recordSyncedVersion(
            id: current.id,
            date: Date(),
            fingerprint: CopyQSyncBridge.writtenPayloadFingerprint(of: item)
        )
        if let baseName = CopyQSyncDeletion.baseName(of: current), baseName != stem {
            try? store.replaceSyncBaseName(id: current.id, with: stem)
        }
        convergeSupersededStems(
            ownedStems.filter { $0 != stem },
            folder: normalizedFolder,
            tab: tab,
            store: store,
            trashRoot: trashRoot,
            fileManager: fileManager
        )

        let log = SyncLogEntry(
            stem: stem,
            folderPath: normalizedFolder,
            reason: reason,
            files: written.sorted { $0.path < $1.path }
        )
        recordLog(log)
        return log
    }

    private func convergeSupersededStems(
        _ stems: [String],
        folder: String,
        tab: ClipboardTab,
        store: ClipboardStore,
        trashRoot: URL?,
        fileManager: FileManager
    ) {
        for stem in stems {
            do {
                _ = try CopyQSyncTrash.moveGroup(
                    stem: stem,
                    fromFolder: folder,
                    tab: tab,
                    reason: .supersededGroup,
                    trashRoot: trashRoot,
                    fileManager: fileManager
                )
                try? store.removeWrittenSyncStem(stem, folder: folder)
                CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: folder)
            } catch {
                recordLog(SyncLogEntry(
                    stem: stem,
                    folderPath: folder,
                    reason: "superseded-stem",
                    error: "Could not move the extra sync group to the trash: \(error.localizedDescription)"
                ))
            }
        }
    }

    /// Runs `body` once every queued capture write has finished and while no
    /// write can start, so a resync apply compares and changes one settled
    /// state. A write enqueued after the drain waits on `updateLock` until the
    /// body returns; a write that already started finishes first.
    ///
    /// A write whose row the body removed finds no stored row when it finally
    /// runs and returns without writing, so a queued capture can never
    /// recreate a group for a deleted row.
    @discardableResult
    public func withSettledWrites<T>(_ body: () throws -> T) rethrows -> T {
        queue.sync {}
        updateLock.lock()
        defer { updateLock.unlock() }
        return try body()
    }

    /// Asynchronously enqueues write-back on a background utility queue so the capture hot path and UI remain instant.
    public func enqueue(
        entry: ClipboardEntry,
        store: ClipboardStore,
        reason: String = "capture"
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.writeEntry(entry, in: store, reason: reason)
            } catch {
                let log = SyncLogEntry(
                    stem: nil,
                    folderPath: "unknown",
                    reason: reason,
                    error: "Write-back failed: \(error)"
                )
                self.recordLog(log)
            }
        }
    }

    func recordLog(_ log: SyncLogEntry) {
        logQueue.sync {
            let logLine = log.message + "\n"
            NSLog("%@", log.message)

            let path = logFilePath
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            guard let data = logLine.data(using: .utf8) else { return }

            let fileManager = FileManager.default
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = (attrs[.size] as? NSNumber)?.int64Value,
               size >= maxLogFileSize {
                Self.rotateLogs(at: path, maxRotatedFiles: maxRotatedFiles, fileManager: fileManager)
            }

            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }
}
