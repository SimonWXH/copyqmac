// SPDX-License-Identifier: GPL-3.0-or-later
//
// One-time sweep for the sync-marker leak.
//
// Older builds imported sync items that carried no payload at all.  CopyQ on
// the other device materialises such an item for an entry that held nothing,
// and our importer still attached the item's file stem as the
// `application/x-copyq-itemsync-base-name` bookkeeping flavour, so the store
// filled up with entries whose only flavour is that internal marker: an empty
// row whose preview shows the flavour name instead of content.
//
// The import and export paths now refuse those items, so no new ones appear.
// This sweep removes the ones already stored.  It runs only when the caller
// asks for it explicitly (`CopyQmac --cleanup-internal-marker-entries` or via
// Item ▸ "Remove Internal-Marker Entries…"); no launch, capture, or import path calls it.
//
// The sweep deletes an entry only when that entry carries no payload flavours
// (zero flavours, or only internal bookkeeping markers) and has no note and
// is not pinned. Every other entry, and every note and pin, is left untouched.

import Foundation

/// What a marker sweep found or deleted.
public struct InternalMarkerCleanupReport: Equatable, Sendable {
    /// Entries per tab, in the store's tab order.
    public struct TabCount: Equatable, Sendable {
        public let tabID: Int64
        public let tabName: String
        public let singleMarkerCount: Int
        public let otherPayloadlessCount: Int

        public init(
            tabID: Int64,
            tabName: String,
            singleMarkerCount: Int = 0,
            otherPayloadlessCount: Int = 0
        ) {
            self.tabID = tabID
            self.tabName = tabName
            self.singleMarkerCount = singleMarkerCount
            self.otherPayloadlessCount = otherPayloadlessCount
        }

        public var deletedCount: Int {
            singleMarkerCount + otherPayloadlessCount
        }
    }

    public var tabs: [TabCount]

    public init(tabs: [TabCount] = []) {
        self.tabs = tabs
    }

    public var deletedCount: Int {
        tabs.reduce(0) { $0 + $1.deletedCount }
    }

    public var singleMarkerCount: Int {
        tabs.reduce(0) { $0 + $1.singleMarkerCount }
    }

    public var otherPayloadlessCount: Int {
        tabs.reduce(0) { $0 + $1.otherPayloadlessCount }
    }

    /// Tabs that have at least one candidate entry.
    public var affectedTabs: [TabCount] {
        tabs.filter { $0.deletedCount > 0 }
    }

    /// One line per tab, plus the total. Empty when nothing was found or deleted.
    public var summary: String {
        summary(language: .english)
    }

    public func summary(language: AppLanguage) -> String {
        let affected = affectedTabs
        guard !affected.isEmpty else {
            return Localization.string(.markerCleanupNoEntries, language: language)
        }
        var lines = affected.map {
            Localization.format(
                .markerCleanupTabLine,
                language: language,
                $0.tabName,
                $0.deletedCount,
                $0.singleMarkerCount,
                $0.otherPayloadlessCount
            )
        }
        let totalKey: CatalogKey = deletedCount == 1
            ? .markerCleanupTotalSingle
            : .markerCleanupTotalPlural
        lines.append(
            Localization.format(
                totalKey,
                language: language,
                deletedCount,
                singleMarkerCount,
                otherPayloadlessCount
            )
        )
        return lines.joined(separator: "\n")
    }
}

public enum InternalMarkerCleanup {
    public static func candidateReport(
        in store: ClipboardStore
    ) throws -> InternalMarkerCleanupReport {
        var tabs: [InternalMarkerCleanupReport.TabCount] = []
        for tab in try store.tabs() {
            let candidates = try store.shellCandidateEntries(tabID: tab.id)
            let singleMarkerCount = candidates.filter { $0.kind == .singleMarker }.count
            let otherPayloadlessCount = candidates.filter { $0.kind == .otherPayloadless }.count
            tabs.append(InternalMarkerCleanupReport.TabCount(
                tabID: tab.id,
                tabName: tab.name,
                singleMarkerCount: singleMarkerCount,
                otherPayloadlessCount: otherPayloadlessCount
            ))
        }
        return InternalMarkerCleanupReport(tabs: tabs)
    }

    @discardableResult
    public static func removeMarkerOnlyEntries(
        in store: ClipboardStore
    ) throws -> InternalMarkerCleanupReport {
        var tabs: [InternalMarkerCleanupReport.TabCount] = []

        for tab in try store.tabs() {
            let candidates = try store.shellCandidateEntries(tabID: tab.id)
            let singleMarkerCount = candidates.filter { $0.kind == .singleMarker }.count
            let otherPayloadlessCount = candidates.filter { $0.kind == .otherPayloadless }.count
            let victims = candidates.map(\.id)

            if !victims.isEmpty {
                try store.delete(ids: victims)
            }
            tabs.append(InternalMarkerCleanupReport.TabCount(
                tabID: tab.id,
                tabName: tab.name,
                singleMarkerCount: singleMarkerCount,
                otherPayloadlessCount: otherPayloadlessCount
            ))
        }

        return InternalMarkerCleanupReport(tabs: tabs)
    }
}
