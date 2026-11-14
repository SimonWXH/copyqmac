// SPDX-License-Identifier: GPL-3.0-or-later
//
// CopyQSyncIdentity.swift
//
// One model for the question "which sync file group belongs to this row?".
// The read-only comparison and the resync apply both ask it, so a row is
// classified and written through the same answer.
//
// Identity is layered, strongest first:
//
//   1. the row's `application/x-copyq-itemsync-base-name` flavour, which an
//      imported or adopted row carries and which never changes;
//   2. every stem the durable `written_sync_stems` table records for the row
//      in this folder, which survives a creation-time change;
//   3. the legacy rule: a written stem whose stamp is within one second of
//      the row's creation time, matched to the row when a row already owns it
//      or adopted when it has no owner at all, or a folder group whose stamp
//      matches the row exactly and resolves back to it.
//
// Layer 3 is a guess about history, not a durable link. `isLegacyIdentity`
// marks a row that rests on it alone, whether matched back to the row or
// adopted from an unowned released stem, so the plan reports it as unrelated
// history and the write path can refuse to treat a same-stem different-content
// file as a newer version of that row.
//
// A row may own several groups (legacy duplicate groups that converged). The
// owned set is reported whole, and `canonicalStem` names the preferred stem a
// write uses: the base-name flavour when the row owns it, otherwise the oldest
// recorded stem. When that stem has no folder item, a write falls back to a
// differing owned stem that does.

import Foundation

public struct CopyQSyncIdentity: Equatable, Sendable {
    public let entryID: Int64
    /// Every stem this row owns in the folder, in a stable order.
    public let stems: [String]
    /// The preferred stem a write uses, when the row owns one.
    public let canonicalStem: String?
    /// True when the row has no base-name flavour and no recorded stem, so its
    /// ownership comes only from the legacy creation-time rule.
    public let isLegacyIdentity: Bool

    public init(
        entryID: Int64,
        stems: [String],
        canonicalStem: String?,
        isLegacyIdentity: Bool
    ) {
        self.entryID = entryID
        self.stems = stems
        self.canonicalStem = canonicalStem
        self.isLegacyIdentity = isLegacyIdentity
    }
}

public enum CopyQSyncIdentityResolver {
    /// Resolves a row's owned stems in `folder`.
    ///
    /// `persistLink` records a resolved legacy stem for the row, so a later
    /// creation-time change cannot break the link. Read-only callers pass
    /// `false`; the write path records the link itself once it has decided to
    /// act, so a report never adopts anything.
    public static func resolve(
        of entry: ClipboardEntry,
        in store: ClipboardStore,
        folder: String,
        groupStems: Set<String>? = nil,
        persistLink: Bool = false,
        fileManager: FileManager = .default
    ) -> CopyQSyncIdentity {
        var stems: [String] = []
        let flavourStem = CopyQSyncDeletion.baseName(of: entry)
        if let flavourStem {
            stems.append(flavourStem)
        }
        let recorded = (try? store.writtenSyncStems(forEntryID: entry.id, folder: folder)) ?? []
        stems.append(contentsOf: recorded)

        if stems.isEmpty,
           let resolved = CopyQSyncBridge.ownedStem(
               of: entry,
               in: store,
               folder: folder,
               groupStems: groupStems,
               persistLink: persistLink,
               fileManager: fileManager
           )
        {
            stems.append(resolved)
        }

        var seen = Set<String>()
        let owned = stems.filter { seen.insert($0).inserted }

        return CopyQSyncIdentity(
            entryID: entry.id,
            stems: owned,
            canonicalStem: CopyQSyncDeletion.canonicalStem(of: entry, among: owned),
            isLegacyIdentity: !owned.isEmpty && flavourStem == nil && recorded.isEmpty
        )
    }
}
