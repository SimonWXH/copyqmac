// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncBridge.swift
//
// Bridges CopyQ sync folders and .cpq archives with CopyQmac's ClipboardStore.
// Provides import with tab mapping and content deduplication, a backup export of
// the history as a CopyQ .cpq archive, and safe dry-run export into scratch paths.

import Foundation

public enum CopyQSyncBridgeError: LocalizedError, Equatable {
    case protectedPath(String)
    case invalidSource(String)
    case ambiguousSyncFolder(String)

    public var errorDescription: String? {
        switch self {
        case .protectedPath(let path):
            return "Refusing dry-run export into protected CopyQ or Syncthing directory: \(path)"
        case .invalidSource(let message), .ambiguousSyncFolder(let message):
            return message
        }
    }
}

public struct CopyQImportReport: Equatable, Sendable {
    public var importedCount: Int = 0
    public var updatedCount: Int = 0
    public var skippedUpstreamCount: Int = 0
    public var skippedUpstreamStems: [String] = []
    public var duplicateCount: Int = 0
    /// Items that held nothing but our own bookkeeping markers and were
    /// skipped without touching the store.
    public var skippedInternalCount: Int = 0
    public var failedCount: Int = 0
    public var failures: [String] = []
    public var importedTabs: [String] = []
    /// Tabs with a non-empty sync folder that
    /// `CopyQSyncBridge.importConfiguredSyncFolders` had to read. Zero means no
    /// tab has a folder mapped, which the interface reports and offers to
    /// replace with a picked folder instead of showing a silent empty import.
    /// Only the configured-folder import sets it, and `merge` does not add it.
    public var mappedTabCount: Int = 0

    public init(
        importedCount: Int = 0,
        updatedCount: Int = 0,
        skippedUpstreamCount: Int = 0,
        skippedUpstreamStems: [String] = [],
        duplicateCount: Int = 0,
        skippedInternalCount: Int = 0,
        failedCount: Int = 0,
        failures: [String] = [],
        importedTabs: [String] = [],
        mappedTabCount: Int = 0
    ) {
        self.importedCount = importedCount
        self.updatedCount = updatedCount
        self.skippedUpstreamCount = skippedUpstreamCount
        self.skippedUpstreamStems = skippedUpstreamStems
        self.duplicateCount = duplicateCount
        self.skippedInternalCount = skippedInternalCount
        self.failedCount = failedCount
        self.failures = failures
        self.importedTabs = importedTabs
        self.mappedTabCount = mappedTabCount
    }

    public mutating func merge(_ other: CopyQImportReport) {
        importedCount += other.importedCount
        updatedCount += other.updatedCount
        skippedUpstreamCount += other.skippedUpstreamCount
        skippedUpstreamStems.append(contentsOf: other.skippedUpstreamStems)
        duplicateCount += other.duplicateCount
        skippedInternalCount += other.skippedInternalCount
        failedCount += other.failedCount
        failures.append(contentsOf: other.failures)
        for tab in other.importedTabs where !importedTabs.contains(tab) {
            importedTabs.append(tab)
        }
    }

    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        var parts: [String] = []
        parts.append(Localization.format(.importSummaryImported, language: language, importedCount))
        if updatedCount > 0 {
            parts.append(Localization.format(.importSummaryUpdated, language: language, updatedCount))
        }
        if skippedUpstreamCount > 0 {
            parts.append(
                Localization.format(
                    .importSummaryUpstreamSkipped,
                    language: language,
                    skippedUpstreamCount,
                    skippedUpstreamStems.joined(separator: ", ")
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
        if skippedInternalCount > 0 {
            parts.append(
                Localization.formatCount(
                    skippedInternalCount,
                    .importSummaryInternalSingle,
                    .importSummaryInternalPlural,
                    language: language,
                    skippedInternalCount
                )
            )
        }
        if failedCount > 0 {
            parts.append(Localization.format(.importSummaryFailed, language: language, failedCount))
        }
        if !importedTabs.isEmpty {
            parts.append(
                Localization.format(
                    .importSummaryTabs,
                    language: language,
                    importedTabs.joined(separator: ", ")
                )
            )
        }
        return Localization.joinedSummaryClauses(parts, language: language)
    }
}

public enum CopyQSyncImportOutcome: Equatable, Sendable {
    case inserted(ClipboardEntry)
    /// An upstream content change was newer than the local version and was
    /// applied to the existing row in place.
    case updated(ClipboardEntry)
    /// The local version is newer than the upstream one, so the upstream change
    /// was discarded. `discardedSummary` describes the payload that was not
    /// applied without exposing its bytes.
    case skippedUpstream(upstreamFingerprint: String, discardedSummary: String)
    /// The folder still holds the version the entry already reflects and does
    /// not carry a newer version, while the local row has an edit that has not
    /// reached the folder yet. The caller may re-assert the local version.
    case localVersionPending(ClipboardEntry)
    /// The file is unchanged, but it supplied a later date than the stored row,
    /// so the row's creation time moved forward without a content change.
    case refreshed(ClipboardEntry)
    case duplicate
    /// The item held nothing but our own bookkeeping markers, so it was not
    /// turned into an entry at all.
    case skippedInternal
}

/// Remembers which skipped upstream payloads have already been logged and
/// announced, so repeated scans of the same file stay silent.
public enum CopyQSyncSkipNotifier {
    private struct Key: Hashable {
        let folder: String
        let stem: String
        let fingerprint: String
    }

    private static let lock = NSLock()
    private static var notified: Set<Key> = []

    public static func shouldNotify(folder: String, stem: String, fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return notified.insert(Key(folder: folder, stem: stem, fingerprint: fingerprint)).inserted
    }
}

public enum CopyQSyncBridge {
    /// Which tabs a backup archive contains.
    public enum ExportScope: Equatable, Sendable {
        case allTabs
        case tab(Int64)
    }

    /// Progress of a running backup export, reported off the main thread.
    public struct ExportProgress: Equatable, Sendable {
        public var tabName: String
        /// 1-based index of the tab being written.
        public var tabIndex: Int
        public var tabCount: Int
        public var exportedItems: Int
        /// Items in every tab of this export, known before writing starts.
        public var totalItems: Int

        public init(
            tabName: String,
            tabIndex: Int,
            tabCount: Int,
            exportedItems: Int,
            totalItems: Int
        ) {
            self.tabName = tabName
            self.tabIndex = tabIndex
            self.tabCount = tabCount
            self.exportedItems = exportedItems
            self.totalItems = totalItems
        }

        /// Completed fraction in 0...1, or `nil` when the history is empty.
        public var fraction: Double? {
            guard totalItems > 0 else { return nil }
            return min(1, Double(exportedItems) / Double(totalItems))
        }
    }

    /// What a finished backup archive contains.
    public struct ExportReport: Equatable, Sendable {
        public var path: String
        public var tabNames: [String]
        public var itemCount: Int
        public var byteCount: Int
        /// Tabs whose name was disambiguated in the archive because another
        /// tab already used it.
        public var renamedTabCount: Int
        /// The archive was written inside a configured tab sync folder or a
        /// Syncthing folder, so it will travel to the other devices.
        public var syncDestination: Bool

        public init(
            path: String,
            tabNames: [String],
            itemCount: Int,
            byteCount: Int,
            renamedTabCount: Int = 0,
            syncDestination: Bool = false
        ) {
            self.path = path
            self.tabNames = tabNames
            self.itemCount = itemCount
            self.byteCount = byteCount
            self.renamedTabCount = renamedTabCount
            self.syncDestination = syncDestination
        }

        public var summary: String {
            summary(language: .english)
        }

        public func summary(language: AppLanguage) -> String {
            let tabs = Localization.formatCount(
                tabNames.count,
                .exportSummaryTabsSingle,
                .exportSummaryTabsPlural,
                language: language,
                tabNames.count
            )
            let items = Localization.formatCount(
                itemCount,
                .exportSummaryItemsSingle,
                .exportSummaryItemsPlural,
                language: language,
                itemCount
            )
            let size = Localization.byteCount(Int64(byteCount), language: language)
            var text = Localization.format(.exportSummaryHead, language: language, tabs, items, size)
            let sentenceSeparator = Localization.string(.reportSentenceSeparator, language: language)
            if renamedTabCount > 0 {
                text += Localization.string(.reportClauseJoiner, language: language) + Localization.formatCount(
                    renamedTabCount,
                    .exportSummaryRenamedSingle,
                    .exportSummaryRenamedPlural,
                    language: language,
                    renamedTabCount
                )
            }
            text += sentenceSeparator + Localization.string(.exportSummaryPayloadCaveat, language: language)
            if syncDestination {
                text += sentenceSeparator + Localization.string(.exportSummarySyncDestination, language: language)
            }
            return text + Localization.string(.reportTerminator, language: language)
        }
    }

    /// One flavour name that differs between a CopyQ sync item and the native
    /// macOS pasteboard, plus the native aliases that export also treats as
    /// the same content.
    ///
    /// A CopyQ item written on Linux names its flavours with MIME types
    /// (`text/html`, `text/rtf`, ...), while a macOS capture stores pasteboard
    /// types (`public.html`, `public.rtf`, ...). Kind detection, preview, and
    /// paste-back all expect the native names, so import translates the CopyQ
    /// name to `nativeType` and export walks the same row the other way.
    public struct FlavourNameMapping: Equatable, Sendable {
        /// The MIME name CopyQ stores in a sync item.
        public let copyQFormat: String
        /// The pasteboard type import stores for this CopyQ format.
        public let nativeType: String
        /// Less preferred native types that also mean this content on export.
        public let aliases: [String]

        public init(copyQFormat: String, nativeType: String, aliases: [String] = []) {
            self.copyQFormat = copyQFormat
            self.nativeType = nativeType
            self.aliases = aliases
        }

        /// Every native type that maps to this CopyQ format, most preferred first.
        public var pasteboardTypes: [String] { [nativeType] + aliases }
    }

    /// The single table both directions of the mapping read.
    ///
    /// `<->` below means "the same bytes, under the other platform's name".
    /// `text/plain` maps to the UTF-8 flavour and accepts the other text
    /// flavours on export, because whichever text flavour a capture carries is
    /// the same text. Formats absent here (`text/uri-list`, thumbnails, files)
    /// keep their own name in both directions.
    public static let flavourNameMappings: [FlavourNameMapping] = [
        FlavourNameMapping(
            copyQFormat: CopyQFormat.text,
            nativeType: PasteboardTypes.utf8Text,
            aliases: [PasteboardTypes.plainText, PasteboardTypes.legacyText]
        ),
        FlavourNameMapping(
            copyQFormat: CopyQFormat.html,
            nativeType: PasteboardTypes.html,
            aliases: [PasteboardTypes.legacyHTML]
        ),
        FlavourNameMapping(
            copyQFormat: CopyQFormat.rtf,
            nativeType: PasteboardTypes.rtf,
            aliases: [PasteboardTypes.legacyRTF]
        ),
        FlavourNameMapping(copyQFormat: "image/png", nativeType: PasteboardTypes.png),
    ]

    /// The flavour the app stores for `format`. Unknown formats are returned
    /// untouched, which is what keeps payloads that have no native counterpart
    /// byte-identical and usable in both directions.
    public static func nativeType(forCopyQFormat format: String) -> String {
        flavourNameMappings.first { $0.copyQFormat == format }?.nativeType ?? format
    }

    /// The table row a native pasteboard type exports as, or nil when the type
    /// has no CopyQ MIME counterpart.
    public static func flavourNameMapping(forPasteboardType type: String) -> FlavourNameMapping? {
        flavourNameMappings.first { $0.pasteboardTypes.contains(type) }
    }

    /// Normalises a path by expanding tildes and resolving symbolic paths.
    public static func normalizePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardized.path
    }

    /// Hard safety check: prevents writing to real CopyQ or Syncthing directories, or configured tab sync folders (case-insensitive on macOS).
    public static func isProtectedPath(
        _ path: String,
        in store: ClipboardStore? = nil,
        configuredSyncFolders: [String] = []
    ) -> Bool {
        let normalized = normalizePath(path).lowercased()
        let home = NSHomeDirectory()
        let protectedPaths = [
            (home as NSString).appendingPathComponent("Library/Application Support/copyq"),
            (home as NSString).appendingPathComponent(".config/copyq"),
        ].map { normalizePath($0).lowercased() }

        for protected in protectedPaths {
            if normalized == protected || normalized.hasPrefix(protected + "/") {
                return true
            }
        }
        if normalized.contains("syncthing/config/copyq") {
            return true
        }

        var tabSyncFolders = configuredSyncFolders
        if let store = store, let tabs = try? store.tabs() {
            tabSyncFolders.append(contentsOf: tabs.compactMap(\.syncFolder))
        }

        for folder in tabSyncFolders where !folder.isEmpty {
            if isWithin(normalized, folder: folder) {
                return true
            }
        }

        return false
    }

    /// True when a backup written to `path` lands inside a configured tab sync
    /// folder or a Syncthing folder, so it will be synced to the other devices.
    private static func isSyncDestination(
        _ path: String,
        in store: ClipboardStore? = nil,
        configuredSyncFolders: [String] = []
    ) -> Bool {
        let normalized = normalizePath(path).lowercased()
        if normalized.split(separator: "/").contains(where: { $0 == "syncthing" }) {
            return true
        }

        var tabSyncFolders = configuredSyncFolders
        if let store = store, let tabs = try? store.tabs() {
            tabSyncFolders.append(contentsOf: tabs.compactMap(\.syncFolder))
        }

        for folder in tabSyncFolders where !folder.isEmpty {
            if isWithin(normalized, folder: folder) {
                return true
            }
        }

        return false
    }

    private static func isWithin(_ normalizedPath: String, folder: String) -> Bool {
        let normalizedFolder = normalizePath(folder).lowercased()
        guard !normalizedFolder.isEmpty else { return false }
        return normalizedPath == normalizedFolder || normalizedPath.hasPrefix(normalizedFolder + "/")
    }

    /// Formats a UTC creation stamp string matching CopyQ's UTC timestamp convention `copyq_yyyyMMddhhmmsszzz`.
    public static func formatTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ms = max(0, min(999, ((comps.nanosecond ?? 0) + 500_000) / 1_000_000))
        return String(
            format: "copyq_%04d%02d%02d%02d%02d%02d%03d",
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
            comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0, ms
        )
    }

    /// The date an item supplies, or nil when it carries neither a name stamp
    /// nor a backing-file modification time.
    public static func resolvedDate(for item: CopyQSyncItem) -> Date? {
        CopyQSyncItem.effectiveTimestamp(
            nameTimestamp: item.timestamp,
            fileModificationDate: item.fileModificationDate
        )
    }

    /// True when a sync item or archive item holds nothing a user can see,
    /// paste, or keep: every flavour is one of our own bookkeeping markers or
    /// our own metadata, with no note and no pin.
    ///
    /// CopyQ on the other side of a sync folder materialises such an item for
    /// an entry that had no payload at all, and our import would otherwise
    /// store it as an entry whose only flavour is the base-name marker. Those
    /// entries have no content and must never enter the history.
    public static func isInternalOnly(_ item: CopyQSyncItem) -> Bool {
        guard !item.isPinned, item.notes?.isEmpty != false else { return false }
        return item.data.formats.allSatisfy { format in
            Fingerprint.isBookkeepingFlavour(format)
                || format == CopyQFormat.itemNotes
                || format == CopyQFormat.itemPinned
                || format == CopyQFormat.macItemCreatedAt
        }
    }

    /// Converts an in-memory CopyQSyncItem into a ClipboardEntry.
    public static func itemToEntry(_ item: CopyQSyncItem, tabID: Int64) -> ClipboardEntry {
        let createdAt = resolvedDate(for: item) ?? Date()
        var flavours: [Flavour] = []

        for format in item.data.formats {
            // Item notes, pin state and the private creation-time flavour are
            // modelled directly on ClipboardEntry, so they never become a
            // stored flavour.
            if format == CopyQFormat.itemNotes
                || format == CopyQFormat.itemPinned
                || format == CopyQFormat.macItemCreatedAt
                || Fingerprint.isBookkeepingFlavour(format)
            {
                continue
            }
            let bytes = item.data.bytes(format) ?? Data()
            flavours.append(Flavour(
                itemIndex: 0,
                type: nativeType(forCopyQFormat: format),
                data: bytes
            ))
        }

        // Keep the sync file name as a bookkeeping flavour: it proves which
        // entry owns a stem and write-back reuses it. It is excluded from the
        // content fingerprint, so it never blocks dedupe.
        if let baseName = item.baseName, !baseName.isEmpty {
            flavours.append(Flavour(
                itemIndex: 0,
                type: Fingerprint.syncBaseNameFlavour,
                data: Data(baseName.utf8)
            ))
        }

        return ClipboardEntry(
            createdAt: createdAt,
            pinned: item.isPinned,
            tabID: tabID,
            note: item.notes ?? "",
            flavours: flavours
        )
    }

    /// Converts a ClipboardEntry into the CopyQSyncItem its file group carries.
    ///
    /// The payload is the same canonical map the sync folder is compared
    /// against, so a later read of the written files matches the row.
    public static func entryToItem(_ entry: ClipboardEntry, baseNameOverride: String? = nil) -> CopyQSyncItem {
        var customBaseName: String?

        for flavour in entry.flavours where flavour.type == Fingerprint.syncBaseNameFlavour {
            customBaseName = String(data: flavour.data, encoding: .utf8)
        }

        let baseName = baseNameOverride ?? customBaseName ?? formatTimestamp(entry.createdAt)
        return CopyQSyncItem(
            baseName: baseName,
            data: canonicalDataMap(from: entry),
            timestamp: entry.createdAt,
            fileModificationDate: entry.createdAt
        )
    }

    /// Payload identity of the files a sync item publishes, which is what a
    /// later scan of the folder compares the writing row against.
    static func writtenPayloadFingerprint(of item: CopyQSyncItem) -> String {
        canonicalFingerprint(of: itemToEntry(item, tabID: ClipboardTab.unsavedID))
    }

    private static func isFilePasteboardType(_ type: String) -> Bool {
        type == PasteboardTypes.fileURL || type == PasteboardTypes.legacyFilenames
    }

    private static func archivePreferenceRank(for type: String) -> Int {
        if let rank = FlavourDecoder.textPreferenceRank(type) {
            return rank
        }
        switch type {
        case PasteboardTypes.html:
            return 0
        case PasteboardTypes.mimeHtml:
            return 1
        case PasteboardTypes.legacyHTML:
            return 2
        case PasteboardTypes.rtf:
            return 0
        case PasteboardTypes.mimeRtf:
            return 1
        case PasteboardTypes.legacyRTF:
            return 2
        case PasteboardTypes.png:
            return 0
        case "image/png":
            return 1
        default:
            return 0
        }
    }

    private static func archiveDataMap(from flavours: [Flavour]) -> CopyQDataMap {
        let ordered = flavours.sorted { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) }
        let fileURLs = FlavourDecoder.fileURLs(from: flavours)
        let hasFileURLs = !(fileURLs?.isEmpty ?? true)
        var selected: [String: Flavour] = [:]

        for flavour in ordered {
            if flavour.type == CopyQFormat.itemNotes
                || flavour.type == CopyQFormat.itemPinned
                || flavour.type == CopyQFormat.macItemCreatedAt
                || isFilePasteboardType(flavour.type)
                || Fingerprint.isBookkeepingFlavour(flavour.type)
            {
                continue
            }
            if hasFileURLs, flavour.type == CopyQFormat.uriList {
                continue
            }
            let format = flavourNameMapping(forPasteboardType: flavour.type)?.copyQFormat ?? flavour.type
            if let existing = selected[format] {
                if archivePreferenceRank(for: flavour.type) < archivePreferenceRank(for: existing.type) {
                    selected[format] = flavour
                }
            } else {
                selected[format] = flavour
            }
        }

        var map = CopyQDataMap()
        for (format, flavour) in selected {
            map.set(format, flavour.data)
        }
        if let fileURLs, !fileURLs.isEmpty {
            let lines = fileURLs.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
            map.set(CopyQFormat.uriList, Data(lines.utf8))
        }
        return map
    }

    /// Converts a stored entry into the item a `.cpq` backup carries.
    ///
    /// Native pasteboard types are written under the CopyQ MIME name for the
    /// same payload (`text/plain`, `text/html`, `text/rtf`, `image/png`, `text/uri-list`),
    /// while types CopyQ has no name for keep their original identifier.  Private
    /// sync bookkeeping flavours are omitted so internal sync stems do not leak into
    /// backups.  Payload bytes are copied untouched so a restore keeps the captured
    /// content.
    public static func entryToArchiveItem(_ entry: ClipboardEntry) -> CopyQSyncItem {
        var map = canonicalDataMap(from: entry)

        if let createdAt = CopyQFormat.encodeCreatedAt(entry.createdAt) {
            map.set(CopyQFormat.macItemCreatedAt, createdAt)
        }

        return CopyQSyncItem(data: map, timestamp: entry.createdAt)
    }

    /// The canonical payload map: flavours folded onto the CopyQ names an
    /// archive and a sync item carry, plus the item note and pinned marker.
    private static func canonicalDataMap(from entry: ClipboardEntry) -> CopyQDataMap {
        var map = archiveDataMap(from: entry.flavours)
        if !entry.note.isEmpty {
            map.set(CopyQFormat.itemNotes, Data(entry.note.utf8))
        }
        if entry.pinned {
            map.set(CopyQFormat.itemPinned, nil)
        }
        return map
    }

    /// Payload identity with native pasteboard names folded onto the CopyQ
    /// names an archive carries, so a locally captured entry and the same
    /// entry read back from an archive or sync folder compare equal. The note
    /// and pinned marker are part of the identity because they travel with the
    /// item.
    static func canonicalFingerprint(of entry: ClipboardEntry) -> String {
        Fingerprint.of(canonicalFlavours(of: entry))
    }

    private static func canonicalFlavours(of entry: ClipboardEntry) -> [Flavour] {
        let map = canonicalDataMap(from: entry)
        return map.formats.map { format in
            Flavour(itemIndex: 0, type: format, data: map.bytes(format) ?? Data())
        }
    }

    static func canonicalFingerprints(
        in store: ClipboardStore,
        tabID: Int64,
        nativeOnly: Bool = false
    ) throws -> [String: Int64] {
        try canonicalIndex(in: store, tabID: tabID, nativeOnly: nativeOnly)
            .compactMapValues(\.first)
    }

    private static func canonicalIndex(
        in store: ClipboardStore,
        tabID: Int64,
        nativeOnly: Bool = false
    ) throws -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        let pageSize = 200
        var offset = 0
        while true {
            let ids = try store.recentEntryIDs(limit: pageSize, offset: offset, tabID: tabID)
            if ids.isEmpty { break }
            for entry in try store.entries(ids: ids) {
                if nativeOnly && entry.hasSyncBaseName {
                    continue
                }
                result[canonicalFingerprint(of: entry), default: []].append(entry.id)
            }
            offset += ids.count
            if ids.count < pageSize { break }
        }
        return result
    }

    /// Records links for written stems in `folder` that have no owner yet, when
    /// the stem's complete group payload matches exactly one row in `tabID`.
    /// Anything ambiguous, incomplete, or unreadable is left suppressed.
    @discardableResult
    static func recoverUnlinkedOwnership(
        in store: ClipboardStore,
        folder: String,
        tabID: Int64,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let unlinked = try? store.writtenSyncStemsWithoutOwner(folder: folder),
              !unlinked.isEmpty
        else { return false }
        let groups = CopyQSyncWatcher.findItemGroups(in: folder)
        var index: [String: [Int64]]?
        var recorded = false
        for stem in unlinked {
            guard let group = groups.first(where: { $0.stem == stem }), group.isComplete else {
                continue
            }
            guard let result = try? CopyQSyncFolder.readItem(
                baseName: stem,
                atPath: folder,
                candidateFiles: group.files
            ) else { continue }
            let item = result.item
            if index == nil {
                index = (try? canonicalIndex(in: store, tabID: tabID)) ?? [:]
            }
            let fingerprint = canonicalFingerprint(of: itemToEntry(item, tabID: tabID))
            guard let matches = index?[fingerprint], matches.count == 1 else { continue }
            try? store.recordWrittenSyncStem(stem, folder: folder, entryID: matches[0])
            recorded = true
        }
        return recorded
    }

    /// Every tab whose configured sync folder is exactly `folderPath`.
    ///
    /// A folder may map to at most one tab. The watcher treats more than one
    /// match as ambiguous, logs the conflicting tabs, and skips the folder
    /// rather than resolving it by position.
    public static func tabs(forSyncFolder folderPath: String, in store: ClipboardStore) throws -> [ClipboardTab] {
        let normalized = normalizePath(folderPath)
        return try store.tabs().filter { tab in
            guard let syncFolder = tab.syncFolder,
                  !syncFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return normalizePath(syncFolder) == normalized
        }
    }

    private static func ambiguousFolderMessage(_ folder: String, tabs: [ClipboardTab]) -> String {
        let conflicts = tabs.map { "'\($0.name)' (id \($0.id))" }.joined(separator: ", ")
        return "Skipped \(folder): multiple tabs claim this sync folder: \(conflicts)"
    }

    /// Finds an existing tab matching the exact configured sync folder path, or creates a new tab with an empty sync folder if unmatched.
    ///
    /// More than one match is ambiguous: the folder is skipped and logged
    /// rather than resolved by position or imported into a new tab.
    public static func findOrCreateTab(forFolder folderPath: String, in store: ClipboardStore) throws -> ClipboardTab {
        let normalized = normalizePath(folderPath)
        let matches = try tabs(forSyncFolder: normalized, in: store)
        if matches.count > 1 {
            let message = ambiguousFolderMessage(normalized, tabs: matches)
            NSLog("CopyQSyncBridge: %@", message)
            throw CopyQSyncBridgeError.ambiguousSyncFolder(message)
        }
        if let match = matches.first {
            return match
        }

        let folderName = URL(fileURLWithPath: normalized).lastPathComponent
        let tabName = folderName.isEmpty ? "Imported" : folderName
        return try store.insertTab(ClipboardTab(name: tabName, syncFolder: nil))
    }

    /// A log-safe summary of an entry's payload: its canonical formats, byte
    /// length, and a short content hash. It never contains clipboard bytes,
    /// notes, or file names.
    public static func payloadSummary(of entry: ClipboardEntry) -> String {
        let flavours = canonicalFlavours(of: entry)
        let formats = Set(flavours.map(\.type)).sorted()
        let bytes = flavours.reduce(0) { $0 + $1.data.count }
        let hashPrefix = String(canonicalFingerprint(of: entry).prefix(8))
        let formatList = formats.isEmpty ? "none" : formats.joined(separator: ",")
        return "formats=[\(formatList)] bytes=\(bytes) sha256=\(hashPrefix)"
    }

    private enum OwnerSource {
        case baseName
        case writtenStem
        case legacy
    }

    private static func resolvedOwner(
        stem: String,
        tabID: Int64,
        folder: String?,
        in store: ClipboardStore
    ) throws -> (entry: ClipboardEntry, source: OwnerSource)? {
        if let folder,
           let entryID = try store.entryID(forWrittenSyncStem: stem, folder: folder),
           let entry = try store.entry(id: entryID),
           entry.tabID == tabID
        {
            return (entry, .writtenStem)
        }
        if let entry = try store.entryMatchingSyncStem(stem, tabID: tabID) {
            return (entry, entry.hasSyncBaseName ? .baseName : .legacy)
        }
        return nil
    }

    /// The row that already owns `stem` in `tabID`, including a stem this app
    /// wrote for a local entry. The folder is required for the written-stem
    /// lookup because the same stem can exist in two folders. Reporting paths
    /// use this read-only form so they never adopt a legacy match.
    static func existingOwner(
        stem: String,
        tabID: Int64,
        folder: String?,
        in store: ClipboardStore
    ) throws -> ClipboardEntry? {
        try resolvedOwner(stem: stem, tabID: tabID, folder: folder, in: store)?.entry
    }

    /// Resolves the owner of `stem` and records the row's link when the match
    /// comes only from the legacy creation-time proximity, so a later
    /// creation-time refresh cannot break it.
    @discardableResult
    static func adoptOwner(
        stem: String,
        tabID: Int64,
        folder: String?,
        in store: ClipboardStore
    ) throws -> ClipboardEntry? {
        guard let resolved = try resolvedOwner(stem: stem, tabID: tabID, folder: folder, in: store) else {
            return nil
        }
        if resolved.source == .legacy, let folder {
            try store.recordWrittenSyncStem(stem, folder: folder, entryID: resolved.entry.id)
        }
        return resolved.entry
    }

    /// The stem a folder already associates with `entry`: the stem recorded for
    /// its id, a written stem whose stamp matches its creation time, or a legacy
    /// group whose stamp matches it. Every candidate must resolve back to
    /// `entry` through `existingOwner`, so the writer never adopts a stem that
    /// import would attribute to another row. A resolved candidate is recorded
    /// for the row before its creation time can move.
    static func ownedStem(
        of entry: ClipboardEntry,
        in store: ClipboardStore,
        folder: String,
        groupStems: Set<String>? = nil,
        persistLink: Bool = true,
        fileManager: FileManager = .default
    ) -> String? {
        func adopt(_ stem: String) -> String {
            if persistLink {
                try? store.recordWrittenSyncStem(stem, folder: folder, entryID: entry.id)
            }
            return stem
        }
        if let stem = (try? store.writtenSyncStem(forEntryID: entry.id, folder: folder)) ?? nil,
           !stem.isEmpty
        {
            return stem
        }
        if let candidate = (try? store.writtenSyncStem(matching: entry.createdAt, folder: folder)) ?? nil {
            let owner = (try? existingOwner(
                stem: candidate,
                tabID: entry.tabID,
                folder: folder,
                in: store
            )) ?? nil
            if owner == nil || owner?.id == entry.id {
                return adopt(candidate)
            }
        }
        let stems = groupStems ?? CopyQSyncWatcher.itemGroupStems(in: folder, fileManager: fileManager)
        for candidate in stems.sorted() {
            guard let stemDate = CopyQSyncItem.parseTimestamp(baseName: candidate),
                  CopyQSyncBridge.formatTimestamp(stemDate) == candidate,
                  abs(stemDate.timeIntervalSince(entry.createdAt)) <= 0.0005
            else { continue }
            let owner = (try? existingOwner(
                stem: candidate,
                tabID: entry.tabID,
                folder: folder,
                in: store
            )) ?? nil
            if owner?.id == entry.id {
                return adopt(candidate)
            }
        }
        return nil
    }

    /// Applies one sync item to a tab.
    ///
    /// An unchanged file is a duplicate that still moves its entry's date
    /// forward when the file supplies a later one. When the file's content
    /// differs from the row that owns the stem, the newest timestamp wins: an
    /// upstream version newer than the version the row reflects replaces the
    /// row's flavours in place, and an older one is discarded and reported so
    /// the caller can log what was not applied. The row keeps its id, tab, note,
    /// pin, and (unless upstream is newer) its creation time. A changed file
    /// whose stem has no owner becomes a new entry unless an entry with the same
    /// content already exists.
    public static func importSyncItem(
        _ item: CopyQSyncItem,
        stem: String,
        tabID: Int64,
        folder: String? = nil,
        in store: ClipboardStore,
        nativeCanonical: [String: Int64] = [:]
    ) throws -> CopyQSyncImportOutcome {
        // An item that carries no payload is an artefact of the other side's
        // sync plugin, not clipboard content: skip it before it can claim a
        // stem or create a contentless entry.
        guard !isInternalOnly(item) else { return .skippedInternal }

        let entry = itemToEntry(item, tabID: tabID)
        let resolvedDate = resolvedDate(for: item)
        // Canonical fingerprints fold native pasteboard aliases onto the CopyQ
        // MIME name the folder carries, so an alias-rich local capture and the
        // item read back from its own group compare equal.
        let payloadFingerprint = canonicalFingerprint(of: entry)
        let legacyPayloadFingerprint = Fingerprint.payload(of: entry.flavours)
        let ownWrittenGroup = folder.flatMap {
            try? store.isWrittenSyncStem(stem, folder: $0)
        } ?? false

        if let owner = try adoptOwner(stem: stem, tabID: tabID, folder: folder, in: store) {
            let localPayload = canonicalFingerprint(of: owner)
            let lastImported = try store.lastImportedPayloadFingerprint(id: owner.id)

            if payloadFingerprint == localPayload {
                let currentVersion = (try store.syncUpdatedAt(id: owner.id)) ?? owner.createdAt
                if !ownWrittenGroup, let resolvedDate, resolvedDate > owner.createdAt {
                    try store.touch(id: owner.id, at: resolvedDate)
                    try store.recordSyncedVersion(
                        id: owner.id,
                        date: max(currentVersion, resolvedDate),
                        fingerprint: payloadFingerprint
                    )
                    var refreshed = owner
                    refreshed.createdAt = resolvedDate
                    return .refreshed(refreshed)
                }
                try store.recordSyncedVersion(
                    id: owner.id,
                    date: currentVersion,
                    fingerprint: payloadFingerprint
                )
                return .duplicate
            }

            let localDate = (try store.syncUpdatedAt(id: owner.id)) ?? owner.createdAt
            let upstreamDate = resolvedDate ?? Date.distantPast

            // The folder holds the version this row already reflects and no
            // newer upstream version exists; the local row is an edit that has
            // not reached the folder yet.
            if !lastImported.isEmpty,
               payloadFingerprint == lastImported,
               upstreamDate <= localDate
            {
                return .localVersionPending(owner)
            }

            if upstreamDate > localDate {
                CopyQSyncWriter.shared.recordLog(SyncLogEntry(
                    stem: stem,
                    folderPath: folder ?? "unknown",
                    reason: "local-edit-replaced",
                    detail: "a newer upstream edit replaced the local payload: "
                        + payloadSummary(of: owner)
                ))
                let newCreatedAt = max(owner.createdAt, upstreamDate)
                try store.replaceFlavours(
                    of: owner.id,
                    with: entry.flavours,
                    createdAt: newCreatedAt,
                    note: entry.note,
                    pinned: entry.pinned
                )
                try store.recordSyncedVersion(
                    id: owner.id,
                    date: upstreamDate,
                    fingerprint: payloadFingerprint
                )
                var updated = owner
                updated.createdAt = newCreatedAt
                updated.flavours = entry.flavours
                updated.note = entry.note
                updated.pinned = entry.pinned
                return .updated(updated)
            }

            return .skippedUpstream(
                upstreamFingerprint: payloadFingerprint,
                discardedSummary: payloadSummary(of: entry)
            )
        }

        // No stem owner: an entry with the same payload is the same content
        // under a different file name, so it only refreshes its date.
        if let existing = try store.entry(withFingerprint: legacyPayloadFingerprint, tabID: tabID) {
            if let folder {
                _ = ownedStem(of: existing, in: store, folder: folder)
                try store.recordWrittenSyncStem(stem, folder: folder, entryID: existing.id)
            }
            if let resolvedDate, resolvedDate > existing.createdAt {
                try store.touch(id: existing.id, at: resolvedDate)
                try store.setLastImportedPayloadFingerprint(
                    id: existing.id,
                    fingerprint: payloadFingerprint
                )
                var refreshed = existing
                refreshed.createdAt = resolvedDate
                return .refreshed(refreshed)
            }
            try store.setLastImportedPayloadFingerprint(
                id: existing.id,
                fingerprint: payloadFingerprint
            )
            return .duplicate
        }

        if let matchedID = nativeCanonical[canonicalFingerprint(of: entry)],
           let matched = try store.entry(id: matchedID)
        {
            if let folder {
                try store.recordWrittenSyncStem(stem, folder: folder, entryID: matched.id)
            }
            return .duplicate
        }
        let inserted = try store.insert(entry)
        try store.recordSyncedVersion(
            id: inserted.id,
            date: resolvedDate ?? Date(),
            fingerprint: payloadFingerprint
        )
        return .inserted(inserted)
    }

    /// Imports an individual CopyQ sync folder into the store.
    public static func importSyncFolder(
        atPath folderPath: String,
        intoTabID: Int64? = nil,
        in store: ClipboardStore
    ) throws -> CopyQImportReport {
        var report = CopyQImportReport()
        let normalized = normalizePath(folderPath)
        let matchingTabs = try tabs(forSyncFolder: normalized, in: store)
        if matchingTabs.count > 1 {
            let message = ambiguousFolderMessage(normalized, tabs: matchingTabs)
            NSLog("CopyQSyncBridge: %@", message)
            report.failedCount += 1
            report.failures.append(message)
            return report
        }
        let contents = try CopyQSyncFolder.read(atPath: folderPath)

        for failure in contents.failures {
            report.failedCount += 1
            report.failures.append(Localization.folderFailure(failure, language: .english))
        }
        for skipped in contents.skippedFiles {
            report.failedCount += 1
            report.failures.append(
                Localization.format(
                    .diagnosticSkippedFile,
                    language: .english,
                    skipped.fileName,
                    Localization.folderFailureReason(skipped.reason, language: .english)
                )
            )
        }

        let targetTab: ClipboardTab
        if let tabID = intoTabID, let existing = try store.tab(id: tabID) {
            targetTab = existing
        } else if let match = matchingTabs.first {
            targetTab = match
        } else {
            targetTab = try findOrCreateTab(forFolder: normalized, in: store)
        }
        report.importedTabs.append(targetTab.name)

        var canonical: [String: Int64] = [:]
        var canonicalLoaded = false
        var skippedInternal = 0
        for item in contents.items {
            guard let baseName = item.baseName, !baseName.isEmpty else {
                report.failedCount += 1
                report.failures.append("Item has no base name")
                continue
            }
            if isInternalOnly(item) {
                skippedInternal += 1
                continue
            }
            // A stem this app wrote but whose row does not own this tab (a
            // released group, or a row whose tab now points elsewhere) is
            // suppressed instead of imported back. A stem with an owner here
            // is compared below, so a remote edit to it is still applied.
            if try store.isWrittenSyncStem(baseName, folder: normalized),
               try adoptOwner(
                   stem: baseName,
                   tabID: targetTab.id,
                   folder: normalized,
                   in: store
               ) == nil
            {
                report.duplicateCount += 1
                continue
            }
            if !canonicalLoaded {
                canonical = try canonicalFingerprints(in: store, tabID: targetTab.id, nativeOnly: true)
                canonicalLoaded = true
            }
            do {
                switch try importSyncItem(
                    item,
                    stem: baseName,
                    tabID: targetTab.id,
                    folder: normalized,
                    in: store,
                    nativeCanonical: canonical
                ) {
                case .inserted:
                    report.importedCount += 1
                case .updated:
                    report.updatedCount += 1
                case .localVersionPending:
                    report.duplicateCount += 1
                case .skippedUpstream(let upstreamFingerprint, let discardedSummary):
                    if CopyQSyncSkipNotifier.shouldNotify(
                        folder: normalized,
                        stem: baseName,
                        fingerprint: upstreamFingerprint
                    ) {
                        report.skippedUpstreamCount += 1
                        report.skippedUpstreamStems.append(baseName)
                        CopyQSyncWriter.shared.recordLog(SyncLogEntry(
                            stem: baseName,
                            folderPath: normalized,
                            reason: "upstream-edit-discarded",
                            detail: "the local version is newer; discarded upstream payload: \(discardedSummary)"
                        ))
                    }
                case .refreshed:
                    report.duplicateCount += 1
                case .duplicate:
                    report.duplicateCount += 1
                case .skippedInternal:
                    skippedInternal += 1
                }
            } catch {
                report.failedCount += 1
                report.failures.append("Failed importing entry \(baseName): \(error)")
            }
        }
        report.skippedInternalCount += skippedInternal
        if skippedInternal > 0 {
            NSLog(
                "CopyQSyncBridge: skipped %d item(s) in %@ that carried only internal bookkeeping flavours",
                skippedInternal,
                normalized
            )
        }
        return report
    }

    /// Imports a .cpq export archive into the store.
    public static func importArchive(
        atPath archivePath: String,
        intoTabID: Int64? = nil,
        in store: ClipboardStore
    ) throws -> CopyQImportReport {
        var report = CopyQImportReport()
        let archive = try CopyQArchive.read(atPath: archivePath)

        for failure in archive.failures {
            report.failedCount += 1
            report.failures.append("\(failure.location) [\(failure.format)]: \(failure.reason)")
        }

        let allTabs = try store.tabs()
        let tabNames = archive.tabNames.isEmpty ? Array(archive.tabItems.keys).sorted() : archive.tabNames
        var canonicalByTab: [Int64: [String: Int64]] = [:]
        var skippedInternal = 0

        for tabName in tabNames {
            let items = archive.tabItems[tabName] ?? []
            guard !items.isEmpty else { continue }

            let targetTab: ClipboardTab
            if let tabID = intoTabID, let existing = try store.tab(id: tabID) {
                targetTab = existing
            } else if let existing = allTabs.first(where: { $0.name.caseInsensitiveCompare(tabName) == .orderedSame }) {
                targetTab = existing
            } else {
                targetTab = try store.insertTab(ClipboardTab(name: tabName))
            }
            if !report.importedTabs.contains(targetTab.name) {
                report.importedTabs.append(targetTab.name)
            }

            var canonical: [String: Int64] = [:]
            var canonicalLoaded = false
            if let cached = canonicalByTab.removeValue(forKey: targetTab.id) {
                canonical = cached
                canonicalLoaded = true
            }

            for item in items {
                // An item with no payload at all is a sync artefact: it must
                // not become a contentless entry here either.
                if isInternalOnly(item) {
                    skippedInternal += 1
                    continue
                }
                let entry = itemToEntry(item, tabID: targetTab.id)
                if let existing = try store.entry(withFingerprint: entry.fingerprint, tabID: targetTab.id) {
                    if let folder = targetTab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !folder.isEmpty
                    {
                        _ = ownedStem(of: existing, in: store, folder: folder)
                    }
                    _ = try store.refreshEntryDate(id: existing.id, to: resolvedDate(for: item))
                    report.duplicateCount += 1
                    continue
                }
                if !canonicalLoaded {
                    canonical = try canonicalFingerprints(in: store, tabID: targetTab.id)
                    canonicalLoaded = true
                }
                let canonicalKey = canonicalFingerprint(of: entry)
                if canonical[canonicalKey] != nil {
                    report.duplicateCount += 1
                    continue
                }
                do {
                    let inserted = try store.insert(entry)
                    canonical[canonicalKey] = inserted.id
                    report.importedCount += 1
                } catch {
                    report.failedCount += 1
                    report.failures.append("Failed inserting archive entry: \(error)")
                }
            }
            if canonicalLoaded {
                canonicalByTab[targetTab.id] = canonical
            }
        }
        report.skippedInternalCount += skippedInternal
        if skippedInternal > 0 {
            NSLog(
                "CopyQSyncBridge: skipped %d item(s) in archive %@ that carried only internal bookkeeping flavours",
                skippedInternal,
                archivePath
            )
        }
        return report
    }

    /// Imports either a sync folder, an archive file, or a parent folder containing sync folders / archives.
    public static func importPath(
        _ path: String,
        intoTabID: Int64? = nil,
        in store: ClipboardStore
    ) throws -> CopyQImportReport {
        let normalized = normalizePath(path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: normalized, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if !isDir.boolValue {
            if normalized.hasSuffix(".cpq") {
                return try importArchive(atPath: normalized, intoTabID: intoTabID, in: store)
            } else {
                throw CopyQSyncBridgeError.invalidSource("Not a .cpq archive or sync directory: \(normalized)")
            }
        }

        let items = try fm.contentsOfDirectory(atPath: normalized)
        let hasDirectItems = items.contains { name in
            !name.hasPrefix(".") && name.hasPrefix("copyq_")
        }

        if hasDirectItems {
            return try importSyncFolder(atPath: normalized, intoTabID: intoTabID, in: store)
        }

        var aggregatedReport = CopyQImportReport()
        for name in items.sorted() {
            guard !name.hasPrefix(".") else { continue }
            let childPath = (normalized as NSString).appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            if fm.fileExists(atPath: childPath, isDirectory: &childIsDir) {
                if childIsDir.boolValue {
                    let subItems = (try? fm.contentsOfDirectory(atPath: childPath)) ?? []
                    if subItems.contains(where: { !$0.hasPrefix(".") && $0.hasPrefix("copyq_") }) {
                        let subReport = try importSyncFolder(atPath: childPath, in: store)
                        aggregatedReport.merge(subReport)
                    }
                } else if name.hasSuffix(".cpq") {
                    let subReport = try importArchive(atPath: childPath, in: store)
                    aggregatedReport.merge(subReport)
                }
            }
        }
        return aggregatedReport
    }

    /// Imports every tab that has a configured syncFolder in preferences.
    ///
    /// `report.mappedTabCount` is the number of tabs that had a folder to read,
    /// so a caller can tell "no tab is mapped" from "nothing needed importing".
    public static func importConfiguredSyncFolders(in store: ClipboardStore) throws -> CopyQImportReport {
        var report = CopyQImportReport()
        let allTabs = try store.tabs()
        var mappedTabCount = 0
        var reportedAmbiguousFolders = Set<String>()
        for tab in allTabs {
            guard let syncFolder = tab.syncFolder, !syncFolder.isEmpty else { continue }
            mappedTabCount += 1
            let normalized = normalizePath(syncFolder)
            let matches = try tabs(forSyncFolder: normalized, in: store)
            if matches.count > 1 {
                if reportedAmbiguousFolders.insert(normalized).inserted {
                    let message = ambiguousFolderMessage(normalized, tabs: matches)
                    NSLog("CopyQSyncBridge: %@", message)
                    report.failedCount += 1
                    report.failures.append(message)
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: normalized) else {
                report.failedCount += 1
                report.failures.append("Sync folder for tab '\(tab.name)' does not exist: \(normalized)")
                continue
            }
            do {
                let subReport = try importSyncFolder(atPath: normalized, intoTabID: tab.id, in: store)
                report.merge(subReport)
            } catch {
                report.failedCount += 1
                report.failures.append("Failed importing sync folder for tab '\(tab.name)': \(error)")
            }
        }
        report.mappedTabCount = mappedTabCount
        return report
    }

    /// Dry-run writer: produces on-disk CopyQ itemsync files only into a safe scratch directory.
    public static func dryRunExport(
        entries: [ClipboardEntry],
        into scratchDirectoryPath: String,
        in store: ClipboardStore? = nil
    ) throws -> [String] {
        let normalized = normalizePath(scratchDirectoryPath)
        guard !isProtectedPath(normalized, in: store) else {
            throw CopyQSyncBridgeError.protectedPath(
                "Refusing dry-run export into protected CopyQ or Syncthing directory: \(normalized)"
            )
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: normalized, withIntermediateDirectories: true)

        var writtenFiles: [String] = []
        var usedBaseNames: Set<String> = []

        let sortedEntries = entries.sorted { $0.createdAt < $1.createdAt }

        for entry in sortedEntries {
            // An entry that holds nothing but our own bookkeeping markers has
            // no item to write: writing it would put an empty item into the
            // folder, which the other device shows as a contentless entry.
            if entry.hasOnlyInternalFlavours { continue }

            var item = entryToItem(entry)
            var baseName = item.baseName ?? formatTimestamp(entry.createdAt)

            if usedBaseNames.contains(baseName) {
                var offset = 1
                var candidate = baseName
                while usedBaseNames.contains(candidate) {
                    let date = entry.createdAt.addingTimeInterval(Double(offset) * 0.001)
                    candidate = formatTimestamp(date)
                    offset += 1
                }
                baseName = candidate
            }
            usedBaseNames.insert(baseName)
            item.baseName = baseName

            let files = try CopyQSyncFolder.write(item, into: normalized)
            writtenFiles.append(contentsOf: files)
        }

        return writtenFiles.sorted()
    }

    /// Dry-run export for all entries belonging to a tab.
    public static func dryRunExport(
        tabID: Int64,
        in store: ClipboardStore,
        into scratchDirectoryPath: String
    ) throws -> [String] {
        let entries = try store.recentEntries(limit: 100_000, tabID: tabID)
        return try dryRunExport(entries: entries, into: scratchDirectoryPath, in: store)
    }

    /// Writes a CopyQ-compatible `.cpq` backup of the entries in `scope`.
    ///
    /// The archive is written to exactly the path the caller passes.  A
    /// destination inside a configured tab sync folder or a Syncthing folder
    /// is allowed and reported, because putting a backup there is how it
    /// reaches the other devices; the export still only creates the chosen
    /// archive file and never touches the itemsync files around it.
    ///
    /// Tabs are written in their configured order.  A tab name that is already
    /// taken in the archive gets a ` (2)`, ` (3)`, ... suffix, so every tab
    /// keeps its own item list instead of the later one overwriting the earlier
    /// one on restore.
    ///
    /// Entries are read and encoded a chunk at a time, and `progress` is
    /// called on the calling thread, so callers run the export off the main
    /// thread and only forward the progress they want to show.
    @discardableResult
    public static func exportArchive(
        toPath path: String,
        scope: ExportScope = .allTabs,
        in store: ClipboardStore,
        progress: ((ExportProgress) -> Void)? = nil
    ) throws -> ExportReport {
        let normalized = normalizePath(path)

        let allTabs = try store.tabs()
        let tabs: [ClipboardTab]
        switch scope {
        case .allTabs:
            tabs = allTabs
        case .tab(let tabID):
            guard let tab = allTabs.first(where: { $0.id == tabID }) else {
                throw CopyQSyncBridgeError.invalidSource("There is no tab \(tabID) to export")
            }
            tabs = [tab]
        }
        guard !tabs.isEmpty else {
            throw CopyQSyncBridgeError.invalidSource("There are no tabs to export")
        }

        let archiveNames = uniqueArchiveTabNames(tabs)
        let renamedTabCount = zip(tabs, archiveNames).filter { $0.name != $1 }.count

        // Snapshot the order up front.  A capture that lands while the export
        // runs is then simply not part of this backup, instead of shifting
        // every later page and silently skipping an older entry.
        var plans: [(archiveName: String, ids: [Int64])] = []
        var totalItems = 0
        for (index, tab) in tabs.enumerated() {
            let ids = try store.recentEntryIDs(limit: Int.max, tabID: tab.id)
            plans.append((archiveNames[index], ids))
            totalItems += ids.count
        }

        let destination = URL(fileURLWithPath: normalized)
        let writer = try CopyQArchiveWriter(
            destinationURL: destination,
            tabs: archiveNames
        )
        var exportedItems = 0

        func reportProgress(tabIndex: Int) {
            guard let progress else { return }
            let plan = plans[tabIndex]
            progress(ExportProgress(
                tabName: plan.archiveName,
                tabIndex: tabIndex + 1,
                tabCount: plans.count,
                exportedItems: exportedItems,
                totalItems: totalItems
            ))
        }

        do {
            for (index, plan) in plans.enumerated() {
                try writer.beginTab(plan.archiveName)
                var start = 0
                while start < plan.ids.count {
                    let chunk = Array(plan.ids[start..<min(start + 200, plan.ids.count)])
                    for stored in try store.entries(ids: chunk) {
                        // Entries whose only flavours are our own bookkeeping
                        // markers carry no content. Exporting one would write
                        // an empty item that CopyQ materialises as a new empty
                        // entry on the other device and syncs straight back.
                        if stored.hasOnlyInternalFlavours {
                            totalItems = max(0, totalItems - 1)
                            continue
                        }
                        try writer.append(entryToArchiveItem(stored))
                        exportedItems += 1
                    }
                    start += chunk.count
                    reportProgress(tabIndex: index)
                }
                try writer.finishTab()
                reportProgress(tabIndex: index)
            }
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: normalized)
        let byteCount = Int((attributes?[.size] as? NSNumber)?.int64Value ?? 0)

        return ExportReport(
            path: normalized,
            tabNames: archiveNames,
            itemCount: exportedItems,
            byteCount: byteCount,
            renamedTabCount: renamedTabCount,
            syncDestination: isSyncDestination(normalized, in: store)
        )
    }

    private static func uniqueArchiveTabNames(_ tabs: [ClipboardTab]) -> [String] {
        var used = Set<String>()
        return tabs.map { tab in
            var name = tab.name
            if used.contains(name) {
                var suffix = 2
                repeat {
                    name = "\(tab.name) (\(suffix))"
                    suffix += 1
                } while used.contains(name)
            }
            used.insert(name)
            return name
        }
    }
}
