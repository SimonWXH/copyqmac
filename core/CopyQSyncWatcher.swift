// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncWatcher.swift
//
// Background service that watches configured CopyQ sync folders using FSEvents.
// Imports items from other machines automatically into their mapped tabs once groups settle.
// Prevents echo loops by tracking written stems durably and in memory, while a changed payload for a
// written stem is a remote edit resolved by newest-wins.
// Writes only when a content conflict is resolved: the winning local version is put back into the folder.
// Removes local entries via app trash only after settled upstream deletion.

import CoreServices
import Foundation

/// Represents the status and metrics of a sync folder scan.
public struct CopyQWatcherScanReport: Equatable, Sendable {
    public var importedCount: Int = 0
    public var updatedCount: Int = 0
    public var skippedUpstreamCount: Int = 0
    public var skippedUpstreamStems: [String] = []
    /// Local versions written back after they won a content conflict, or
    /// because they had not reached the folder yet.
    public var reassertedCount: Int = 0
    /// Local versions replaced by a newer upstream edit. Each one is named in
    /// the sync log with the content that was discarded.
    public var discardedLocalCount: Int = 0
    public var duplicateCount: Int = 0
    public var incompleteCount: Int = 0
    public var unsettledCount: Int = 0
    public var skippedWrittenByUsCount: Int = 0
    /// Items that held nothing but our own bookkeeping markers and were
    /// skipped without touching the store.
    public var skippedInternalCount: Int = 0
    /// Entries removed because their tracked group disappeared upstream.
    public var remoteDeletedCount: Int = 0
    public var remoteDeletedStems: [String] = []
    /// Entries whose group disappeared but that were kept because they were
    /// edited locally.
    public var remoteDeletionSkippedCount: Int = 0
    /// Missing groups waiting for a settled rescan before they are acted on.
    public var pendingRemoteDeletionCount: Int = 0
    public var failureCount: Int = 0
    public var failures: [String] = []

    public init(
        importedCount: Int = 0,
        updatedCount: Int = 0,
        skippedUpstreamCount: Int = 0,
        skippedUpstreamStems: [String] = [],
        reassertedCount: Int = 0,
        discardedLocalCount: Int = 0,
        duplicateCount: Int = 0,
        incompleteCount: Int = 0,
        unsettledCount: Int = 0,
        skippedWrittenByUsCount: Int = 0,
        skippedInternalCount: Int = 0,
        remoteDeletedCount: Int = 0,
        remoteDeletedStems: [String] = [],
        remoteDeletionSkippedCount: Int = 0,
        pendingRemoteDeletionCount: Int = 0,
        failureCount: Int = 0,
        failures: [String] = []
    ) {
        self.importedCount = importedCount
        self.updatedCount = updatedCount
        self.skippedUpstreamCount = skippedUpstreamCount
        self.skippedUpstreamStems = skippedUpstreamStems
        self.reassertedCount = reassertedCount
        self.discardedLocalCount = discardedLocalCount
        self.duplicateCount = duplicateCount
        self.incompleteCount = incompleteCount
        self.unsettledCount = unsettledCount
        self.skippedWrittenByUsCount = skippedWrittenByUsCount
        self.skippedInternalCount = skippedInternalCount
        self.remoteDeletedCount = remoteDeletedCount
        self.remoteDeletedStems = remoteDeletedStems
        self.remoteDeletionSkippedCount = remoteDeletionSkippedCount
        self.pendingRemoteDeletionCount = pendingRemoteDeletionCount
        self.failureCount = failureCount
        self.failures = failures
    }

    public mutating func merge(_ other: CopyQWatcherScanReport) {
        importedCount += other.importedCount
        updatedCount += other.updatedCount
        skippedUpstreamCount += other.skippedUpstreamCount
        skippedUpstreamStems.append(contentsOf: other.skippedUpstreamStems)
        reassertedCount += other.reassertedCount
        discardedLocalCount += other.discardedLocalCount
        duplicateCount += other.duplicateCount
        incompleteCount += other.incompleteCount
        unsettledCount += other.unsettledCount
        skippedWrittenByUsCount += other.skippedWrittenByUsCount
        skippedInternalCount += other.skippedInternalCount
        remoteDeletedCount += other.remoteDeletedCount
        remoteDeletedStems.append(contentsOf: other.remoteDeletedStems)
        remoteDeletionSkippedCount += other.remoteDeletionSkippedCount
        pendingRemoteDeletionCount += other.pendingRemoteDeletionCount
        failureCount += other.failureCount
        failures.append(contentsOf: other.failures)
    }

    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        var parts: [String] = []
        parts.append(Localization.format(.importSummaryImported, language: language, importedCount))
        if updatedCount > 0 {
            parts.append(
                Localization.format(.watcherSummaryUpdatedInPlace, language: language, updatedCount)
            )
        }
        if skippedUpstreamCount > 0 {
            parts.append(
                Localization.formatCount(
                    skippedUpstreamCount,
                    .watcherSummaryUpstreamDiscardedSingle,
                    .watcherSummaryUpstreamDiscardedPlural,
                    language: language,
                    skippedUpstreamCount,
                    skippedUpstreamStems.joined(separator: ", ")
                )
            )
        }
        if reassertedCount > 0 {
            parts.append(
                Localization.formatCount(
                    reassertedCount,
                    .watcherSummaryReassertedSingle,
                    .watcherSummaryReassertedPlural,
                    language: language,
                    reassertedCount
                )
            )
        }
        if discardedLocalCount > 0 {
            parts.append(
                Localization.formatCount(
                    discardedLocalCount,
                    .watcherSummaryReplacedSingle,
                    .watcherSummaryReplacedPlural,
                    language: language,
                    discardedLocalCount
                )
            )
        }
        parts.append(
            Localization.formatCount(
                duplicateCount,
                .importSummaryDuplicateSingle,
                .importSummaryDuplicatePlural,
                language: language,
                duplicateCount
            )
        )
        if skippedWrittenByUsCount > 0 {
            parts.append(
                Localization.format(.watcherSummaryWrittenByUs, language: language, skippedWrittenByUsCount)
            )
        }
        if skippedInternalCount > 0 {
            parts.append(
                Localization.format(.watcherSummaryInternalOnly, language: language, skippedInternalCount)
            )
        }
        if incompleteCount > 0 {
            parts.append(
                Localization.format(.watcherSummaryIncomplete, language: language, incompleteCount)
            )
        }
        if unsettledCount > 0 {
            parts.append(
                Localization.format(.watcherSummaryPendingSettlement, language: language, unsettledCount)
            )
        }
        if remoteDeletedCount > 0 {
            parts.append(
                Localization.format(.watcherSummaryRemoteDeleted, language: language, remoteDeletedCount)
            )
        }
        if remoteDeletionSkippedCount > 0 {
            parts.append(
                Localization.format(.watcherSummaryKeptLocallyEdited, language: language, remoteDeletionSkippedCount)
            )
        }
        if pendingRemoteDeletionCount > 0 {
            parts.append(
                Localization.format(.watcherSummaryPendingDeletionSettlement, language: language, pendingRemoteDeletionCount)
            )
        }
        if failureCount > 0 {
            parts.append(Localization.format(.importSummaryFailed, language: language, failureCount))
        }
        return Localization.joinedSummaryClauses(parts, language: language)
    }
}

/// Represents an item group (set of files sharing the same stem) in a CopyQ sync folder.
public struct CopyQItemGroup: Equatable, Sendable {
    public let stem: String
    public let folderPath: String
    public let hasTextFile: Bool
    public let hasContainerFile: Bool
    public let hasMediaFile: Bool
    public let hasTemporaryFiles: Bool
    public let newestModificationDate: Date
    public let files: [String]

    public init(
        stem: String,
        folderPath: String,
        hasTextFile: Bool,
        hasContainerFile: Bool,
        hasMediaFile: Bool = false,
        hasTemporaryFiles: Bool,
        newestModificationDate: Date,
        files: [String] = []
    ) {
        self.stem = stem
        self.folderPath = folderPath
        self.hasTextFile = hasTextFile
        self.hasContainerFile = hasContainerFile
        self.hasMediaFile = hasMediaFile
        self.hasTemporaryFiles = hasTemporaryFiles
        self.newestModificationDate = newestModificationDate
        self.files = files
    }

    /// An item group is complete only when either a container (_copyq.dat), text (.txt/.html/.uri/.xml),
    /// or media (.png/.jpg/etc.) file is present, and no temporary sync files exist for this stem.
    public var isComplete: Bool {
        (hasTextFile || hasContainerFile || hasMediaFile) && !hasTemporaryFiles
    }

    /// Checks if all files in the group have settled (no modifications within settleDelay).
    public func isSettled(at date: Date = Date(), settleDelay: TimeInterval = 0.5) -> Bool {
        guard isComplete else { return false }
        if settleDelay <= 0 { return true }
        if newestModificationDate > date {
            return true
        }
        return date.timeIntervalSince(newestModificationDate) >= settleDelay
    }
}

public final class CopyQSyncWatcher: @unchecked Sendable {
    public static let shared = CopyQSyncWatcher()

    /// Time required for files in an item group to remain unmodified before importing.
    public var settleDelay: TimeInterval = 0.5
    /// Window to coalesce rapid FSEvents file activity.
    public var debounceInterval: TimeInterval = 0.3

    /// Callback invoked on the main thread whenever new entries are imported.
    public var onImport: (([ClipboardEntry]) -> Void)?
    /// Callback invoked on the main thread with stems whose upstream version was
    /// skipped because the local entry was edited.
    public var onSkippedUpstream: (([String]) -> Void)?
    /// Callback invoked on the main thread after entries were removed because
    /// their file groups disappeared from a watched folder.
    public var onRemoteDeletion: (([String]) -> Void)?
    /// Overrides the app-side trash location for tests and private stores.
    public var trashRoot: URL?

    /// The running state requested by the last `start`, `stop`, or
    /// `updateConfiguration` call, taken from the stored pause preference at
    /// that moment. The queued reconfiguration never changes it.
    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    private var _isRunning: Bool = false
    private let stateLock = NSLock()

    private func setIsRunning(_ value: Bool) {
        stateLock.lock()
        _isRunning = value
        stateLock.unlock()
    }

    private let queue = DispatchQueue(label: "local.copyqmac.sync-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private var streamRef: FSEventStreamRef?
    private var store: ClipboardStore?

    /// In-memory cache of stems written by this app, scoped by sync folder,
    /// preventing echo loops without suppressing the same stem in another folder.
    private var knownWrittenStems: Set<String> = []
    private let stemLock = NSLock()

    /// Active watched folders: normalized directory path -> tab ID.
    private var watchedFolders: [String: Int64] = [:]
    private var debounceTimer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?

    private struct PendingRemoteDeletion {
        let firstMissingAt: Date
    }

    /// Stems seen in the previous scan for each folder.  A deletion is only
    /// considered for a stem that was actually tracked, never for a group that
    /// was already absent on the first scan after launch.
    private var trackedStems: [String: Set<String>] = [:]
    /// Tracked stems currently absent, keyed by folder then stem.  The first
    /// absent scan only records; deletion waits for a later settled scan.
    private var pendingRemoteDeletions: [String: [String: PendingRemoteDeletion]] = [:]
    private let trackingLock = NSLock()

    public init(store: ClipboardStore? = nil) {
        self.store = store
        queue.setSpecific(key: queueKey, value: ())
        if let store {
            loadDurablyWrittenStems(from: store)
            store.onWrittenSyncStemRemoved = { [weak self] stem, folder in
                self?.removeWrittenStem(stem, folder: folder)
            }
        }
    }

    deinit {
        stop()
    }

    // MARK: - Stem Tracking (Echo Prevention)

    /// Loads durably recorded stems from store to prevent echo loops across restarts.
    public func loadDurablyWrittenStems(from store: ClipboardStore) {
        guard let durablyWritten = try? store.allWrittenSyncStemsByFolder() else { return }
        stemLock.lock()
        for (folder, stems) in durablyWritten {
            for stem in stems {
                knownWrittenStems.insert(Self.writtenStemKey(folder: folder, stem: stem))
            }
        }
        stemLock.unlock()
    }

    /// Remembers a stem written by this app into `folder` so the watcher never
    /// re-imports it from there.
    public func recordWrittenStem(_ stem: String, folder: String) {
        let key = Self.writtenStemKey(folder: folder, stem: stem)
        stemLock.lock()
        knownWrittenStems.insert(key)
        stemLock.unlock()
    }

    /// Forgets a stem written by this app, so a restored or re-synced group
    /// can be imported again.
    public func removeWrittenStem(_ stem: String, folder: String) {
        let key = Self.writtenStemKey(folder: folder, stem: stem)
        stemLock.lock()
        knownWrittenStems.remove(key)
        stemLock.unlock()
    }

    /// Checks whether this app wrote `stem` into `folder`.
    public func isWrittenByUs(_ stem: String, folder: String) -> Bool {
        let key = Self.writtenStemKey(folder: folder, stem: stem)
        stemLock.lock()
        defer { stemLock.unlock() }
        return knownWrittenStems.contains(key)
    }

    public var hasActiveRetryTimer: Bool {
        retryTimer != nil
    }

    private static func writtenStemKey(folder: String, stem: String) -> String {
        CopyQSyncBridge.normalizePath(folder) + "\u{0}" + stem
    }

    // MARK: - Lifecycle

    /// Starts watching every tab that has a sync folder.
    public func start(store: ClipboardStore) {
        let prefs = (try? store.preferences()) ?? Preferences.defaultValue
        setIsRunning(!prefs.syncPaused)
        store.onWrittenSyncStemRemoved = { [weak self] stem, folder in
            self?.removeWrittenStem(stem, folder: folder)
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.store = store
            self.loadDurablyWrittenStems(from: store)
            self.reconfigureAndScan(in: store, scan: true)
        }
    }

    /// Stops watching and invalidates any active FSEvents stream synchronously.
    public func stop() {
        setIsRunning(false)
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            performStop()
        } else {
            queue.sync {
                performStop()
            }
        }
    }

    private func performStop() {
        stopStream()
        debounceTimer?.cancel()
        debounceTimer = nil
        retryTimer?.cancel()
        retryTimer = nil
        setIsRunning(false)
    }

    /// Updates watcher configuration when preferences or tab settings change.
    public func updateConfiguration(store: ClipboardStore) {
        updateConfiguration(store: store, scan: true)
    }

    /// Updates the watcher configuration, optionally skipping the scan that
    /// otherwise runs on reconfiguration.
    ///
    /// An adoption skips it and scans the adopted folder on this queue instead,
    /// so the one scan that imports the folder also returns its outcome and the
    /// two can never import the same item twice.
    public func updateConfiguration(store: ClipboardStore, scan: Bool) {
        let prefs = (try? store.preferences()) ?? Preferences.defaultValue
        setIsRunning(!prefs.syncPaused)

        queue.async { [weak self] in
            guard let self else { return }
            self.store = store
            self.reconfigureAndScan(in: store, scan: scan)
        }
    }

    private func stopStream() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        watchedFolders = [:]
    }

    /// Applies the stored configuration to the stream and, optionally, scans.
    ///
    /// `isRunning` is owned by the caller, which sets it synchronously from the
    /// same preferences snapshot before queueing this work. This method must not
    /// write it: a reconfiguration queued before a preference change could else
    /// resume the flag from its stale snapshot after the newer request already
    /// paused the watcher.
    private func reconfigureAndScan(in store: ClipboardStore, scan: Bool) {
        let prefs = (try? store.preferences()) ?? Preferences.defaultValue
        if prefs.syncPaused {
            stopStream()
            return
        }

        let tabs = (try? store.tabs()) ?? []
        var newWatched: [String: Int64] = [:]

        for tab in tabs {
            guard let folder = tab.syncFolder,
                  !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let normalized = CopyQSyncBridge.normalizePath(folder)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue {
                newWatched[normalized] = tab.id
            } else {
                NSLog(
                    "CopyQSyncWatcher: not watching %@ for tab '%@': folder does not exist",
                    normalized,
                    tab.name
                )
            }
        }

        trackingLock.lock()
        trackedStems = trackedStems.filter { newWatched[$0.key] != nil }
        pendingRemoteDeletions = pendingRemoteDeletions.filter { newWatched[$0.key] != nil }
        trackingLock.unlock()

        let oldPaths = Set(watchedFolders.keys)
        let newPaths = Set(newWatched.keys)

        if oldPaths != newPaths || streamRef == nil {
            stopStream()
            watchedFolders = newWatched
            if !newWatched.isEmpty {
                setupStream(for: Array(newWatched.keys))
            }
        } else {
            watchedFolders = newWatched
        }

        guard scan else { return }

        // Perform scan on startup or reconfiguration
        let imported = scanAllWatchedFolders(store: store)
        if !imported.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onImport?(imported)
            }
        }
    }

    private func setupStream(for directories: [String]) {
        guard !directories.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { (stream, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientCallBackInfo else { return }
            let watcher = Unmanaged<CopyQSyncWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            watcher.handleFSEvents(paths: paths)
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            directories as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.streamRef = stream
    }

    private func handleFSEvents(paths: [String]) {
        // Coalesce / debounce rapid bursts
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounceTimer = nil
            guard let store = self.store else { return }
            let imported = self.scanAllWatchedFolders(store: store)
            if !imported.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onImport?(imported)
                }
            }
        }
        timer.resume()
        self.debounceTimer = timer
    }

    // MARK: - Scanning & Importing

    func reconfigureFoldersSynchronously(in store: ClipboardStore) {
        let tabs = (try? store.tabs()) ?? []
        var newWatched: [String: Int64] = [:]
        for tab in tabs {
            guard let folder = tab.syncFolder,
                  !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let normalized = CopyQSyncBridge.normalizePath(folder)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue {
                newWatched[normalized] = tab.id
            }
        }
        self.watchedFolders = newWatched
    }

    /// Scans all watched folders and imports any newly settled items.
    ///
    /// Scans are serialized on the watcher queue, so a manual scan cannot race
    /// a background FSEvents scan into inserting the same item twice.
    @discardableResult
    public func scanAllWatchedFolders(store: ClipboardStore) -> [ClipboardEntry] {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return scanAllWatchedFoldersOnQueue(store: store)
        }
        return queue.sync { scanAllWatchedFoldersOnQueue(store: store) }
    }

    @discardableResult
    private func scanAllWatchedFoldersOnQueue(store: ClipboardStore) -> [ClipboardEntry] {
        if watchedFolders.isEmpty {
            reconfigureFoldersSynchronously(in: store)
        }
        var allImported = store.takeSyncRepairs()
        var skippedUpstream: [String] = []
        var remoteDeletedStems: [String] = []
        var hasPendingUnsettled = false
        var hasPendingRemoteDeletion = false

        for folderPath in watchedFolders.keys.sorted() {
            do {
                let (entries, report) = try scanAndImport(
                    atPath: folderPath,
                    intoTabID: watchedFolders[folderPath],
                    in: store
                )
                allImported.append(contentsOf: entries)
                skippedUpstream.append(contentsOf: report.skippedUpstreamStems)
                if report.unsettledCount > 0 {
                    hasPendingUnsettled = true
                }
                if report.pendingRemoteDeletionCount > 0 {
                    hasPendingRemoteDeletion = true
                }
                remoteDeletedStems.append(contentsOf: report.remoteDeletedStems)
            } catch {
                NSLog("CopyQSyncWatcher: failed scanning %@: %@", folderPath, error.localizedDescription)
            }
        }

        if !skippedUpstream.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onSkippedUpstream?(skippedUpstream)
            }
        }

        if !remoteDeletedStems.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onRemoteDeletion?(remoteDeletedStems)
            }
        }

        // If groups were unsettled, or a tracked group vanished, re-check after
        // the settle window.  A missing group is never acted on in the scan
        // that first noticed it.
        if hasPendingUnsettled || hasPendingRemoteDeletion {
            scheduleRetryScan(after: max(settleDelay, debounceInterval))
        }

        return allImported
    }

    private func scheduleRetryScan(after delay: TimeInterval) {
        retryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, let store = self.store else { return }
            self.retryTimer = nil
            let imported = self.scanAllWatchedFolders(store: store)
            if !imported.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onImport?(imported)
                }
            }
        }
        timer.resume()
        self.retryTimer = timer
    }

    /// True when `name` matches a Syncthing sync-conflict file pattern.
    static func isSyncConflictFileName(_ name: String) -> Bool {
        CopyQSyncFolder.isSyncConflictFileName(name)
    }

    /// True when `name` is an in-flight sync or temporary file rather than an
    /// item file.
    static func isTemporaryFileName(_ name: String) -> Bool {
        name.hasPrefix(".syncthing.")
            || name.hasSuffix(".tmp")
            || name.hasSuffix(".temp")
            || name.hasSuffix(".part")
            || name.hasSuffix(".crdownload")
            || name.contains(".syncthing.")
    }

    /// The item stem a file name belongs to, or `nil` for hidden, temporary,
    /// sync-conflict, and unknown files.
    static func itemStem(ofFileName name: String) -> String? {
        guard !name.hasPrefix("."), !isTemporaryFileName(name), !isSyncConflictFileName(name) else { return nil }
        guard let ext = CopyQFormat.matchedExtension(forFileName: name),
              name.count > ext.count
        else { return nil }
        return String(name.dropLast(ext.count))
    }

    /// Stems of every item group in a folder, from file names alone.
    static func itemGroupStems(
        in folderPath: String,
        fileManager: FileManager = .default
    ) -> Set<String> {
        let normalized = CopyQSyncBridge.normalizePath(folderPath)
        guard let filenames = try? fileManager.contentsOfDirectory(atPath: normalized) else {
            return []
        }
        return Set(filenames.compactMap(itemStem(ofFileName:)))
    }

    /// True when `folder` holds a regular item file for exactly `stem`, without
    /// listing the folder.
    static func stemExists(
        _ stem: String,
        in folderPath: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !isSyncConflictFileName(stem) else { return false }
        let normalized = CopyQSyncBridge.normalizePath(folderPath)
        var suffixes = Set(CopyQFormat.defaultExtensions.map(\.ext))
        suffixes.insert(CopyQFormat.dataFileSuffix)
        for suffix in suffixes {
            var isDirectory: ObjCBool = false
            let path = (normalized as NSString).appendingPathComponent(stem + suffix)
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return true
            }
        }
        return false
    }

    /// Discovers all item groups in a sync folder.
    public static func findItemGroups(in folderPath: String) -> [CopyQItemGroup] {
        let fm = FileManager.default
        let normalized = CopyQSyncBridge.normalizePath(folderPath)
        guard let filenames = try? fm.contentsOfDirectory(atPath: normalized) else { return [] }

        var stemsWithTemporaryFiles = Set<String>()
        var regularFilesByStem: [String: [(file: String, ext: String)]] = [:]
        var newestMtimeByStem: [String: Date] = [:]

        for filename in filenames {
            let fullPath = (normalized as NSString).appendingPathComponent(filename)
            let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? Date.distantPast

            guard !isSyncConflictFileName(filename) else { continue }

            // Check for temporary / in-flight file patterns:
            // .syncthing.<filename>.tmp, <stem>.<ext>.tmp, <stem>.tmp, <stem>.part, <stem>.crdownload, etc.
            let isTemp = isTemporaryFileName(filename)

            if isTemp {
                // Determine candidate stem
                var cleaned = filename
                if cleaned.hasPrefix(".syncthing.") {
                    cleaned = String(cleaned.dropFirst(".syncthing.".count))
                }
                if let tmpRange = cleaned.range(of: ".tmp", options: .backwards) {
                    cleaned = String(cleaned[..<tmpRange.lowerBound])
                }
                if let ext = CopyQFormat.matchedExtension(forFileName: cleaned) {
                    let stem = String(cleaned.dropLast(ext.count))
                    stemsWithTemporaryFiles.insert(stem)
                }
                continue
            }

            guard !filename.hasPrefix(".") else { continue }

            guard let ext = CopyQFormat.matchedExtension(forFileName: filename) else {
                continue
            }

            let stem = String(filename.dropLast(ext.count))
            regularFilesByStem[stem, default: []].append((file: filename, ext: ext))
            let currentNewest = newestMtimeByStem[stem] ?? Date.distantPast
            if mtime > currentNewest {
                newestMtimeByStem[stem] = mtime
            }
        }

        var groups: [CopyQItemGroup] = []
        for (stem, files) in regularFilesByStem {
            let hasText = files.contains {
                $0.ext == ".txt" || $0.ext == ".html" || $0.ext == ".uri" || $0.ext == ".xml"
            }
            let hasContainer = files.contains { $0.ext == CopyQFormat.dataFileSuffix }
            let hasMedia = files.contains {
                $0.ext == ".png" || $0.ext == ".jpg" || $0.ext == ".jpeg" ||
                $0.ext == ".gif" || $0.ext == ".bmp" || $0.ext == ".svg" ||
                $0.ext == "_inkscape.svg" || $0.ext == ".webp" || $0.ext == ".ico"
            }
            let hasTemp = stemsWithTemporaryFiles.contains(stem)
            let newestMtime = newestMtimeByStem[stem] ?? Date()

            groups.append(CopyQItemGroup(
                stem: stem,
                folderPath: normalized,
                hasTextFile: hasText,
                hasContainerFile: hasContainer,
                hasMediaFile: hasMedia,
                hasTemporaryFiles: hasTemp,
                newestModificationDate: newestMtime,
                files: files.map { $0.file }
            ))
        }

        return groups.sorted { $0.stem < $1.stem }
    }

    /// True when a stem has an in-flight Syncthing or temporary file in the
    /// folder.  A missing group with such a file is being rewritten, not
    /// deleted, so it must never trigger a local removal yet.
    public static func hasTemporaryFiles(forStem stem: String, in folderPath: String) -> Bool {
        let normalized = CopyQSyncBridge.normalizePath(folderPath)
        guard let filenames = try? FileManager.default.contentsOfDirectory(atPath: normalized) else {
            return true
        }
        for filename in filenames {
            guard !isSyncConflictFileName(filename) else { continue }
            let isTemp = isTemporaryFileName(filename)
            guard isTemp else { continue }

            var cleaned = filename
            if cleaned.hasPrefix(".syncthing.") {
                cleaned = String(cleaned.dropFirst(".syncthing.".count))
            }
            if let tmpRange = cleaned.range(of: ".tmp", options: .backwards) {
                cleaned = String(cleaned[..<tmpRange.lowerBound])
            }
            guard let ext = CopyQFormat.matchedExtension(forFileName: cleaned) else { continue }
            let candidateStem = String(cleaned.dropLast(ext.count))
            if candidateStem == stem { return true }
        }
        return false
    }

    /// Applies the disk-to-app half of deletion sync.  `groups` is the settled
    /// group snapshot from this scan; a stem that was tracked before and is now
    /// absent becomes pending, and only a later scan (after the settle delay,
    /// with no in-flight file) may remove its owner.
    private func processVanishedGroups(
        groups: [CopyQItemGroup],
        folder: String,
        tab: ClipboardTab,
        in store: ClipboardStore,
        report: inout CopyQWatcherScanReport
    ) {
        let now = Date()
        let current = Set(groups.map(\.stem))

        trackingLock.lock()
        var pending = pendingRemoteDeletions[folder] ?? [:]
        defer {
            pendingRemoteDeletions[folder] = pending
            trackingLock.unlock()
        }

        let previouslyTracked = trackedStems[folder] ?? []
        for stem in current {
            pending.removeValue(forKey: stem)
        }
        var newlyMissing = Set<String>()
        for stem in previouslyTracked.subtracting(current) where pending[stem] == nil {
            pending[stem] = PendingRemoteDeletion(firstMissingAt: now)
            newlyMissing.insert(stem)
        }
        trackedStems[folder] = current

        guard !pending.isEmpty else { return }
        let preferences = (try? store.preferences()) ?? Preferences.defaultValue
        guard !preferences.syncPaused else {
            report.pendingRemoteDeletionCount += pending.count
            return
        }

        for stem in pending.keys.sorted() where !newlyMissing.contains(stem) {
            guard !current.contains(stem) else { continue }
            // A group being rewritten is not a settled deletion.
            guard !Self.hasTemporaryFiles(forStem: stem, in: folder) else { continue }
            let firstMissing = pending[stem]?.firstMissingAt ?? now
            guard now.timeIntervalSince(firstMissing) >= settleDelay else { continue }

            do {
                guard let owner = try CopyQSyncBridge.adoptOwner(
                    stem: stem,
                    tabID: tab.id,
                    folder: folder,
                    in: store
                ) else {
                    pending.removeValue(forKey: stem)
                    continue
                }
                let ownedStems = CopyQSyncDeletion.syncBaseNames(
                    of: owner,
                    in: store,
                    folder: folder,
                    persistLink: false
                )
                let remaining = ownedStems.filter { $0 != stem }
                if !remaining.isEmpty {
                    if CopyQSyncDeletion.baseName(of: owner) == stem,
                       let next = CopyQSyncDeletion.preferredStem(among: remaining)
                    {
                        try? store.replaceSyncBaseName(id: owner.id, with: next)
                    }
                    try? store.removeWrittenSyncStem(stem, folder: folder)
                    self.removeWrittenStem(stem, folder: folder)
                    CopyQSyncWatcher.shared.removeWrittenStem(stem, folder: folder)
                    pending.removeValue(forKey: stem)
                    continue
                }
                if try store.isEntryLocallyEdited(id: owner.id) {
                    report.remoteDeletionSkippedCount += 1
                    pending.removeValue(forKey: stem)
                    continue
                }
                let deletion = try CopyQSyncDeletion.deleteEntryRemovedUpstream(
                    owner,
                    stem: stem,
                    folder: folder,
                    tab: tab,
                    in: store,
                    trashRoot: trashRoot,
                    watcher: self
                )
                report.remoteDeletedCount += 1
                report.remoteDeletedStems.append(stem)
                report.failures.append(contentsOf: deletion.failures)
                pending.removeValue(forKey: stem)
            } catch {
                report.failureCount += 1
                report.failures.append(
                    "Failed removing \(stem) after its group disappeared: \(error.localizedDescription)"
                )
                pending.removeValue(forKey: stem)
            }
        }

        report.pendingRemoteDeletionCount += pending.count
    }

    /// Scans a folder and imports complete, settled groups into the tab whose
    /// configured sync folder matches that folder.
    ///
    /// `tabID` is only a hint: the resolved tab comes from the store's
    /// sync-folder mapping, so a watched folder's items can never be injected
    /// into the capture tab.  When no tab claims the folder the scan is skipped,
    /// logged, and reported instead of guessing.
    /// Deduplicates by fingerprint, ignores our own writes, and removes local entries via app trash only after settled upstream deletion.
    public func scanFolder(
        atPath folderPath: String,
        intoTabID tabID: Int64,
        in store: ClipboardStore,
        settleDelayOverride: TimeInterval? = nil
    ) throws -> CopyQWatcherScanReport {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try scanFolderOnQueue(
                atPath: folderPath,
                intoTabID: tabID,
                in: store,
                settleDelayOverride: settleDelayOverride
            )
        }
        return try queue.sync {
            try scanFolderOnQueue(
                atPath: folderPath,
                intoTabID: tabID,
                in: store,
                settleDelayOverride: settleDelayOverride
            )
        }
    }

    private func scanFolderOnQueue(
        atPath folderPath: String,
        intoTabID tabID: Int64,
        in store: ClipboardStore,
        settleDelayOverride: TimeInterval? = nil
    ) throws -> CopyQWatcherScanReport {
        let (entries, report) = try scanAndImport(
            atPath: folderPath,
            intoTabID: tabID,
            in: store,
            settleDelayOverride: settleDelayOverride
        )
        notifyImport(store.takeSyncRepairs() + entries)
        if !report.skippedUpstreamStems.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onSkippedUpstream?(report.skippedUpstreamStems)
            }
        }
        if !report.remoteDeletedStems.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onRemoteDeletion?(report.remoteDeletedStems)
            }
        }
        return report
    }

    private func notifyImport(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onImport?(entries)
        }
    }

    private func scanAndImport(
        atPath folderPath: String,
        intoTabID tabID: Int64?,
        in store: ClipboardStore,
        settleDelayOverride: TimeInterval? = nil
    ) throws -> (entries: [ClipboardEntry], report: CopyQWatcherScanReport) {
        var report = CopyQWatcherScanReport()
        var importedEntries: [ClipboardEntry] = []
        let normalized = CopyQSyncBridge.normalizePath(folderPath)
        let effectiveSettleDelay = settleDelayOverride ?? settleDelay

        // The tab mapping is authoritative: resolve the tab that claims this
        // exact sync folder.  There is deliberately no capture-tab fallback.
        let matchingTabs = try CopyQSyncBridge.tabs(forSyncFolder: normalized, in: store)
        if matchingTabs.count > 1 {
            let conflicts = matchingTabs
                .map { "'\($0.name)' (id \($0.id))" }
                .joined(separator: ", ")
            let message = "Skipped \(normalized): multiple tabs claim this sync folder: \(conflicts)"
            NSLog("CopyQSyncWatcher: %@", message)
            report.failureCount += 1
            report.failures.append(message)
            return ([], report)
        }
        guard let resolvedTab = matchingTabs.first,
              resolvedTab.id != ClipboardTab.unsavedID
        else {
            let hint = tabID.map { " (tab id \($0) was offered)" } ?? ""
            let message = "Skipped \(normalized): no tab has this path as its sync folder\(hint)"
            NSLog("CopyQSyncWatcher: %@", message)
            report.failureCount += 1
            report.failures.append(message)
            return ([], report)
        }

        if let tabID, tabID != resolvedTab.id {
            // A stale or wrong hint must not move items: folder mapping wins.
            NSLog(
                "CopyQSyncWatcher: folder %@ belongs to tab '%@' (%lld); ignoring tab id %lld",
                normalized,
                resolvedTab.name,
                resolvedTab.id,
                tabID
            )
        }

        guard let targetTab = try store.tab(id: resolvedTab.id) else {
            let message = "Skipped \(normalized): mapped tab \(resolvedTab.id) no longer exists"
            NSLog("CopyQSyncWatcher: %@", message)
            report.failureCount += 1
            report.failures.append(message)
            return ([], report)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            let message = "Skipped \(normalized): folder no longer exists"
            report.failureCount += 1
            report.failures.append(message)
            return ([], report)
        }

        let groups = Self.findItemGroups(in: normalized)
        processVanishedGroups(
            groups: groups,
            folder: normalized,
            tab: targetTab,
            in: store,
            report: &report
        )
        var canonical: [String: Int64] = [:]
        var canonicalLoaded = false
        var skippedInternal = 0

        for group in groups {
            // 1. Check completeness
            guard group.isComplete else {
                report.incompleteCount += 1
                continue
            }

            // 2. Check stability (settled modification dates)
            guard group.isSettled(settleDelay: effectiveSettleDelay) else {
                report.unsettledCount += 1
                continue
            }

            // 3. Read the item
            let itemResult: (item: CopyQSyncItem, failures: [CopyQSyncFolder.Failure])?
            do {
                itemResult = try CopyQSyncFolder.readItem(
                    baseName: group.stem,
                    atPath: normalized,
                    candidateFiles: group.files
                )
            } catch {
                // If the container is still being written and throws decode error, treat as pending
                report.incompleteCount += 1
                continue
            }

            guard let item = itemResult?.item else {
                report.incompleteCount += 1
                continue
            }

            // 4. An item with no payload is not content: the other side's
            //    sync plugin materialises one for an entry that held nothing,
            //    and importing it would only create a contentless entry.
            if CopyQSyncBridge.isInternalOnly(item) {
                skippedInternal += 1
                continue
            }

            // 5. A stem this app wrote is only an echo while its payload still
            //    matches the local row. A changed payload is an upstream edit
            //    and must go through the newest-wins rule below. A written stem
            //    with no owner was released by a tab move and stays suppressed.
            let writtenByUs = isWrittenByUs(group.stem, folder: normalized)
                || (try? store.isWrittenSyncStem(group.stem, folder: normalized)) == true
            let owner = try CopyQSyncBridge.existingOwner(
                stem: group.stem,
                tabID: targetTab.id,
                folder: normalized,
                in: store
            )
            let upstreamEntry = CopyQSyncBridge.itemToEntry(item, tabID: targetTab.id)
            let upstreamPayload = CopyQSyncBridge.canonicalFingerprint(of: upstreamEntry)
            let ownerPayload = owner.map { CopyQSyncBridge.canonicalFingerprint(of: $0) }
            let wasLocallyEdited = (try? owner.map {
                try store.isEntryLocallyEdited(id: $0.id)
            }) ?? false
            if writtenByUs {
                if owner == nil || ownerPayload == upstreamPayload {
                    if owner != nil {
                        _ = try CopyQSyncBridge.adoptOwner(
                            stem: group.stem,
                            tabID: targetTab.id,
                            folder: normalized,
                            in: store
                        )
                    }
                    report.skippedWrittenByUsCount += 1
                    continue
                }
            }

            // 6. Apply the item through the shared import rule: unchanged files
            //    are duplicates, and a changed file with the same stem is
            //    resolved by the newest timestamp.
            if !canonicalLoaded {
                canonical = try CopyQSyncBridge.canonicalFingerprints(
                    in: store,
                    tabID: targetTab.id,
                    nativeOnly: true
                )
                canonicalLoaded = true
            }
            do {
                switch try CopyQSyncBridge.importSyncItem(
                    item,
                    stem: group.stem,
                    tabID: targetTab.id,
                    folder: normalized,
                    in: store,
                    nativeCanonical: canonical
                ) {
                case .inserted(let inserted):
                    report.importedCount += 1
                    importedEntries.append(inserted)
                case .updated(let updated):
                    report.updatedCount += 1
                    if wasLocallyEdited {
                        report.discardedLocalCount += 1
                    }
                    importedEntries.append(updated)
                case .localVersionPending(let pendingOwner):
                    if let log = CopyQSyncWriter.shared.updateEntry(
                        pendingOwner,
                        in: store,
                        reason: "local-pending",
                        stem: group.stem,
                        trashRoot: trashRoot
                    ), log.error == nil {
                        report.reassertedCount += 1
                    } else {
                        report.failureCount += 1
                        report.failures.append(
                            "Could not write the local version of \(group.stem) back to \(normalized)"
                        )
                    }
                case .skippedUpstream(let upstreamFingerprint, let discardedSummary):
                    if CopyQSyncSkipNotifier.shouldNotify(
                        folder: normalized,
                        stem: group.stem,
                        fingerprint: upstreamFingerprint
                    ) {
                        report.skippedUpstreamCount += 1
                        report.skippedUpstreamStems.append(group.stem)
                        CopyQSyncWriter.shared.recordLog(SyncLogEntry(
                            stem: group.stem,
                            folderPath: normalized,
                            reason: "upstream-edit-discarded",
                            detail: "the local version is newer; discarded upstream payload: \(discardedSummary)"
                        ))
                    }
                    // Put the winning local version back so the folder and the
                    // other machine converge on it instead of re-reading the
                    // discarded upstream content on every scan.
                    if let owner, let log = CopyQSyncWriter.shared.updateEntry(
                        owner,
                        in: store,
                        reason: "local-wins",
                        stem: group.stem,
                        trashRoot: trashRoot
                    ), log.error == nil {
                        report.reassertedCount += 1
                    } else {
                        report.failureCount += 1
                        report.failures.append(
                            "Could not write the local version of \(group.stem) back to \(normalized)"
                        )
                    }
                case .refreshed(let refreshed):
                    report.duplicateCount += 1
                    importedEntries.append(refreshed)
                case .duplicate:
                    report.duplicateCount += 1
                case .skippedInternal:
                    skippedInternal += 1
                }
            } catch {
                report.failureCount += 1
                report.failures.append("Failed importing entry for \(group.stem): \(error.localizedDescription)")
            }
        }

        report.skippedInternalCount += skippedInternal
        if skippedInternal > 0 {
            NSLog(
                "CopyQSyncWatcher: skipped %d item(s) in %@ that carried only internal bookkeeping flavours",
                skippedInternal,
                normalized
            )
        }

        return (importedEntries, report)
    }
}
