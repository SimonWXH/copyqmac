// Cached, layout-ready descriptions of clipboard entries.
//
// A SwiftUI row body runs far more often than an entry changes: on every
// layout pass, hover change, selection change, and window resize. Decoding the
// entry's flavours there - especially checking or hashing a multi-megabyte
// image - pegs the main thread. These caches let a view body do only a
// dictionary lookup, while the actual work happens once, off the main thread.
//
// Both caches are bounded LRUs so a long history cannot grow them without
// limit. They are also AppKit-free: `ThumbnailCache` stores `CGImage`, which
// the app wraps in `NSImage` only when it draws.

import Foundation
import ImageIO

// MARK: - Row presentation

/// Everything a list row and the preview pane draw for one entry.
///
/// Building this value is the expensive part: it decodes the entry's flavour
/// preview and formats the relative timestamp. Store it in
/// `EntryPresentationCache` and read it back on every layout pass instead.
public struct EntryPresentation: Equatable, Sendable {
    public let kind: ClipboardContentKind
    /// Text shown for text, HTML, RTF, image summaries, and unknown payloads.
    /// Nil for file entries, which list their names instead.
    public let primaryText: String?
    public private(set) var fileNames: [String]
    public private(set) var fileURLs: [URL]
    public let fileIconPath: String?
    public let fileCount: Int
    /// Lines in the full text, counted once when the presentation is built.
    /// Nil unless the presentation retains the full text of a text, HTML, or
    /// RTF entry, and nil for entries that have no text body. A view body reads
    /// this instead of walking the payload again.
    public private(set) var lineCount: Int?
    public private(set) var searchText: String?
    public let relativeTime: String
    public let language: AppLanguage

    public init(
        entry: ClipboardEntry,
        now: Date = Date(),
        calendar: Calendar = .current,
        language: AppLanguage = .english
    ) {
        self.init(
            entry: entry,
            preview: FlavourDecoder.preview(for: entry.flavours),
            now: now,
            calendar: calendar,
            language: language
        )
    }

    /// Builds a presentation from an already computed preview, so a caller that
    /// needed the preview for a thumbnail does not decode the flavours twice.
    public init(
        entry: ClipboardEntry,
        preview: EntryPreview,
        retainFullPreviewData: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .current,
        language: AppLanguage = .english
    ) {
        kind = preview.kind
        primaryText = preview.kind == .files ? nil : preview.text
        fileNames = preview.fileNames
        fileURLs = preview.fileURLs
        fileIconPath = preview.fileURLs.first?.path
        fileCount = preview.fileURLs.count
        searchText = preview.kind == .files ? nil : preview.searchText
        lineCount = retainFullPreviewData
            ? EntryPresentation.lineCount(of: preview.searchText, kind: preview.kind)
            : nil
        self.language = language
        relativeTime = RelativeTime.describe(entry.createdAt, now: now, calendar: calendar, language: language)
        createdAt = entry.createdAt
    }

    /// A copy that retains only the details needed to render an unselected row.
    public func discardingFullPreviewData() -> EntryPresentation {
        var copy = self
        switch kind {
        case .text, .html, .rtf, .files:
            copy.searchText = nil
            copy.lineCount = nil
        case .image, .other:
            break
        }
        if kind == .files {
            // The names are what the row shows, so they stay in full; only the
            // URLs are dropped, because the preview pane of the selected entry
            // is the only place that needs them.
            copy.fileURLs = []
        }
        return copy
    }

    func replacingPreviewData(searchText: String?, fileURLs: [URL], lineCount: Int?) -> EntryPresentation {
        var copy = self
        if kind == .files {
            copy.searchText = nil
            copy.fileURLs = fileURLs
            copy.fileNames = fileURLs.map(\.lastPathComponent)
        } else {
            copy.searchText = searchText
            copy.lineCount = lineCount
        }
        return copy
    }

    /// Counts newlines in the full text without allocating a substring per line.
    static func lineCount(of text: String?, kind: ClipboardContentKind) -> Int? {
        switch kind {
        case .text, .html, .rtf:
            guard let text else { return nil }
            return text.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
        case .image, .other, .files:
            return nil
        }
    }

    /// A copy with only the time-dependent part recomputed.
    public func refreshingRelativeTime(
        now: Date = Date(),
        calendar: Calendar = .current,
        language: AppLanguage? = nil
    ) -> EntryPresentation {
        let lang = language ?? self.language
        return EntryPresentation(
            self,
            relativeTime: RelativeTime.describe(createdAt, now: now, calendar: calendar, language: lang),
            language: lang
        )
    }

    /// Kept so a timestamp refresh does not need to re-decode the flavours.
    private let createdAt: Date
    private init(_ source: EntryPresentation, relativeTime: String, language: AppLanguage) {
        kind = source.kind
        primaryText = source.primaryText
        fileNames = source.fileNames
        fileURLs = source.fileURLs
        fileIconPath = source.fileIconPath
        fileCount = source.fileCount
        searchText = source.searchText
        lineCount = source.lineCount
        createdAt = source.createdAt
        self.language = language
        self.relativeTime = relativeTime
    }
}

// MARK: - Presentation cache

/// Bounded LRU cache of row presentations, keyed by entry id.
public final class EntryPresentationCache {
    private struct Item {
        var version: EntryVersion
        var presentation: EntryPresentation
    }

    private let lock = NSLock()
    private var items: LRUCache<Int64, Item>
    private var currentLanguage: AppLanguage

    public init(capacity: Int = 512, language: AppLanguage = .english) {
        items = LRUCache(capacity: capacity)
        currentLanguage = language
    }

    public var language: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return currentLanguage
    }

    @discardableResult
    public func setLanguage(_ newLanguage: AppLanguage, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = currentLanguage != newLanguage
        currentLanguage = newLanguage
        if changed {
            return refreshRelativeTimesLocked(now: now, calendar: calendar)
        }
        return false
    }

    /// Pure lookup. Never decodes, hashes, or touches the database.
    public func presentation(for entryID: Int64) -> EntryPresentation? {
        lock.lock()
        defer { lock.unlock() }
        return items.value(for: entryID)?.presentation
    }

    public func store(_ presentation: EntryPresentation, for entry: ClipboardEntry) {
        lock.lock()
        defer { lock.unlock() }
        items.insert(Item(version: EntryVersion(entry), presentation: presentation), for: entry.id)
    }

    @discardableResult
    public func storeSelectedPreview(
        searchText: String?,
        fileURLs: [URL],
        lineCount: Int?,
        for entryID: Int64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var item = items.value(for: entryID) else { return false }
        item.presentation = item.presentation.replacingPreviewData(
            searchText: searchText,
            fileURLs: fileURLs,
            lineCount: lineCount
        )
        items.insert(item, for: entryID)
        return true
    }

    public func discardFullPreviewData(for entryID: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard var item = items.value(for: entryID) else { return }
        item.presentation = item.presentation.discardingFullPreviewData()
        items.insert(item, for: entryID)
    }

    /// Drops a deleted entry.
    public func invalidate(entryID: Int64) {
        lock.lock()
        defer { lock.unlock() }
        _ = items.removeValue(for: entryID)
    }

    public func invalidate(entryIDs: Set<Int64>) {
        guard !entryIDs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for id in entryIDs { _ = items.removeValue(for: id) }
    }

    /// Drops cached presentations whose entry changed. Returns the ids that
    /// were invalidated so the caller can drop their thumbnails too.
    ///
    /// Only entries present in `entries` are compared; an entry hidden by the
    /// current filter keeps its cache entry until it is visible again.
    @discardableResult
    public func synchronize(with entries: [ClipboardEntry]) -> Set<Int64> {
        guard !entries.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var invalidated: Set<Int64> = []
        for entry in entries {
            guard let item = items.value(for: entry.id) else { continue }
            if item.version != EntryVersion(entry) {
                _ = items.removeValue(for: entry.id)
                invalidated.insert(entry.id)
            }
        }
        return invalidated
    }

    /// Recomputes only timestamps. Returns true when anything changed.
    @discardableResult
    public func refreshRelativeTimes(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return refreshRelativeTimesLocked(now: now, calendar: calendar)
    }

    private func refreshRelativeTimesLocked(now: Date, calendar: Calendar) -> Bool {
        items.updateValues { item in
            let updated = item.presentation.refreshingRelativeTime(
                now: now,
                calendar: calendar,
                language: currentLanguage
            )
            guard updated.relativeTime != item.presentation.relativeTime || updated.language != item.presentation.language else {
                return false
            }
            item.presentation = updated
            return true
        }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
    }
}

// MARK: - Thumbnail cache

/// Bounded LRU cache of decoded, already-downsampled thumbnails with an explicit
/// byte budget (default 32 MB) and total-byte LRU eviction.
///
/// The key is the entry id plus the requested pixel bound, never a payload
/// fingerprint. Decoding belongs on a background queue; the app calls
/// `decodeThumbnail` there and only ever looks images up on the main thread.
public final class ThumbnailCache {
    public static let defaultByteBudget = 32 * 1024 * 1024 // 32 MB

    public struct Key: Hashable, Sendable {
        public let entryID: Int64
        public let maxPixelSize: Int

        public init(entryID: Int64, maxPixelSize: Int) {
            self.entryID = entryID
            self.maxPixelSize = maxPixelSize
        }
    }

    private struct CachedImage {
        let image: CGImage
        let bytes: Int
    }

    private let lock = NSLock()
    public let byteBudget: Int
    public let maxCount: Int?
    private var currentBytes: Int = 0
    private var images: [Key: CachedImage] = [:]
    private var recency: [Key] = []

    public init(byteBudget: Int = defaultByteBudget, maxCount: Int? = nil) {
        self.byteBudget = max(1, byteBudget)
        self.maxCount = maxCount.map { max(1, $0) }
    }

    public convenience init(capacity: Int) {
        self.init(byteBudget: Self.defaultByteBudget, maxCount: capacity)
    }

    public var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentBytes
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }

    /// Pure lookup. Never decodes image data.
    public func thumbnail(for entryID: Int64, maxPixelSize: Int) -> CGImage? {
        let key = Key(entryID: entryID, maxPixelSize: maxPixelSize)
        lock.lock()
        defer { lock.unlock() }
        guard let cached = images[key] else { return nil }
        if let idx = recency.firstIndex(of: key) {
            recency.remove(at: idx)
        }
        recency.append(key)
        return cached.image
    }

    public func store(_ image: CGImage, for entryID: Int64, maxPixelSize: Int) {
        let key = Key(entryID: entryID, maxPixelSize: maxPixelSize)
        let cost = max(1, image.bytesPerRow * image.height)
        lock.lock()
        defer { lock.unlock() }

        if let existing = images.removeValue(forKey: key) {
            currentBytes -= existing.bytes
            if let idx = recency.firstIndex(of: key) {
                recency.remove(at: idx)
            }
        }

        if cost > byteBudget {
            return
        }

        while !recency.isEmpty && (currentBytes + cost > byteBudget || (maxCount != nil && images.count >= maxCount!)) {
            let oldest = recency.removeFirst()
            if let evicted = images.removeValue(forKey: oldest) {
                currentBytes -= evicted.bytes
            }
        }

        images[key] = CachedImage(image: image, bytes: cost)
        recency.append(key)
        currentBytes += cost
    }

    /// Drops every size for a changed or deleted entry.
    public func invalidate(entryID: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let matching = images.keys.filter { $0.entryID == entryID }
        for key in matching {
            if let evicted = images.removeValue(forKey: key) {
                currentBytes -= evicted.bytes
            }
            if let idx = recency.firstIndex(of: key) {
                recency.remove(at: idx)
            }
        }
    }

    public func invalidate(entryIDs: Set<Int64>) {
        guard !entryIDs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let matching = images.keys.filter { entryIDs.contains($0.entryID) }
        for key in matching {
            if let evicted = images.removeValue(forKey: key) {
                currentBytes -= evicted.bytes
            }
            if let idx = recency.firstIndex(of: key) {
                recency.remove(at: idx)
            }
        }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        images.removeAll()
        recency.removeAll()
        currentBytes = 0
    }

    /// Decodes and downsamples one image subsampled with ImageIO.
    /// Prefers the embedded thumbnail if present and sufficiently large (at least 0.75x maxPixelSize),
    /// otherwise creates a thumbnail from the image bounded by maxPixelSize.
    /// Safe to call off the main thread.
    public static func decodeThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        // 1. Prefer embedded thumbnail only when it reaches at least 0.75x of the requested bound
        let minPixelSize = Int(Double(maxPixelSize) * 0.75)
        let embeddedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, embeddedOptions as CFDictionary) {
            let longestEdge = max(thumbnail.width, thumbnail.height)
            if longestEdge >= minPixelSize && longestEdge <= maxPixelSize {
                return thumbnail
            }
        }

        // 2. Otherwise request thumbnail created from image bounded by maxPixelSize
        let createOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, createOptions as CFDictionary)
    }
}

// MARK: - Entry version

/// A cheap snapshot of what a cached presentation was built from. It records
/// only metadata and a couple of sample bytes per flavour, never the payload
/// itself, so the cache does not keep old image bytes alive and comparing it on
/// a reload does not scan megabytes of data.
///
/// Every mutation path in the app also invalidates by entry id explicitly, so
/// this is the safety net for a payload that changed while it was not visible.
struct EntryVersion: Equatable {
    private struct FlavourVersion: Equatable {
        var itemIndex: Int
        var type: String
        var byteCount: Int
        var firstByte: UInt8?
        var lastByte: UInt8?
    }

    private var createdAt: Date
    private var flavours: [FlavourVersion]

    init(_ entry: ClipboardEntry) {
        createdAt = entry.createdAt
        flavours = entry.flavours
            .sorted { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) }
            .map { flavour in
                FlavourVersion(
                    itemIndex: flavour.itemIndex,
                    type: flavour.type,
                    byteCount: flavour.uncompressedByteCount,
                    firstByte: flavour.sampleFirstByte,
                    lastByte: flavour.sampleLastByte
                )
            }
    }
}

// MARK: - LRU

/// Small, allocation-light LRU. Guarded by the caches above; not thread-safe
/// on its own.
struct LRUCache<Key: Hashable, Value> {
    private var values: [Key: Value] = [:]
    private var recency: [Key] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        if values[key] == nil {
            if values.count >= capacity, let oldest = recency.first {
                recency.removeFirst()
                values.removeValue(forKey: oldest)
            }
        } else if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        values[key] = value
        recency.append(key)
    }

    mutating func removeValue(for key: Key) -> Value? {
        guard let value = values.removeValue(forKey: key) else { return nil }
        if let index = recency.firstIndex(of: key) { recency.remove(at: index) }
        return value
    }

    mutating func removeValues(where predicate: (Key) -> Bool) {
        let removed = values.keys.filter(predicate)
        guard !removed.isEmpty else { return }
        let removedSet = Set(removed)
        for key in removed { values.removeValue(forKey: key) }
        recency.removeAll { removedSet.contains($0) }
    }

    mutating func removeAll() {
        values.removeAll()
        recency.removeAll()
    }

    mutating func updateValues(_ transform: (inout Value) -> Bool) -> Bool {
        var changed = false
        for key in recency {
            guard var value = values[key] else { continue }
            if transform(&value) {
                values[key] = value
                changed = true
            }
        }
        return changed
    }
}
