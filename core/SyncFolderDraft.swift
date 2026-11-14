// SPDX-License-Identifier: GPL-3.0-or-later
//
// SyncFolderDraft.swift
//
// The commit decision behind the per-tab Sync folder text field.
//
// The field commits on every change after a short pause, and also on blur,
// Return, and the view disappearing. The view owns the timer; this value owns
// the decision, so the rules are testable without a window: a draft remembers
// the tab it was typed for, a draft whose trimmed text matches the stored
// folder needs no write at all, and a focused field keeps the text it holds
// instead of the stored folder the commit republished.

import Foundation

/// The write a pending Sync folder draft resolves to.
public struct SyncFolderCommit: Equatable, Sendable {
    /// The tab the text was typed for, never the tab that happens to be
    /// selected when the timer fires, so a pending draft cannot land on
    /// another tab.
    public var tabID: Int64
    /// The trimmed folder to store, or nil when the field is empty.
    public var folder: String?

    public init(tabID: Int64, folder: String?) {
        self.tabID = tabID
        self.folder = folder
    }
}

/// Debounced commit bookkeeping for the per-tab Sync folder field.
///
/// A draft records the folder the tab had when the text was typed, so the
/// commit it resolves to compares against the value it replaces and the last
/// typed value wins. Recording a text that needs no write clears any pending
/// draft, which is how a pause after adding or removing surrounding whitespace
/// cancels the scheduled write instead of storing a duplicate.
public struct SyncFolderDraft: Equatable, Sendable {
    private struct Pending: Equatable {
        var tabID: Int64
        var storedFolder: String?
        var text: String
    }

    private var pending: Pending?

    public init() {}

    /// True when a commit is scheduled but has not been resolved yet.
    public var hasPendingCommit: Bool { pending != nil }

    /// The folder a typed text stands for: trimmed, with empty meaning no folder.
    public static func folder(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Records `text` as the pending value for `tabID` and reports whether a
    /// debounced write is worth scheduling.
    ///
    /// Returns false, and clears any pending draft, when the text trims to the
    /// folder the tab already has, so a pause after surrounding whitespace
    /// cannot write to the store.
    @discardableResult
    public mutating func record(tabID: Int64, storedFolder: String?, text: String) -> Bool {
        guard let commit = Self.commit(tabID: tabID, storedFolder: storedFolder, text: text) else {
            pending = nil
            return false
        }
        pending = Pending(tabID: commit.tabID, storedFolder: storedFolder, text: text)
        return true
    }

    /// The text the field shows for a tab: the stored folder unless the typed
    /// text belongs to an unfinished edit, and the typed text itself while it
    /// does.
    ///
    /// An unfinished edit is a scheduled commit, or text that trims to the
    /// stored folder, which is the user's own value already committed. Anything
    /// else means the stored folder came from elsewhere, so a folder assigned
    /// while the field is focused appears in it too.
    public static func fieldText(
        storedFolder: String?,
        typed: String,
        isFocused: Bool,
        hasPendingCommit: Bool
    ) -> String {
        guard isFocused else { return storedFolder ?? "" }
        if hasPendingCommit || folder(for: typed) == storedFolder { return typed }
        return storedFolder ?? ""
    }

    /// Resolves the pending draft into its write and clears it, so a timer
    /// that fires twice writes at most once.
    ///
    /// Returns nil when nothing is pending or when the trimmed text already
    /// matches the folder recorded with the draft.
    public mutating func takeCommit() -> SyncFolderCommit? {
        guard let pending else { return nil }
        self.pending = nil
        return Self.commit(tabID: pending.tabID, storedFolder: pending.storedFolder, text: pending.text)
    }

    private static func commit(tabID: Int64, storedFolder: String?, text: String) -> SyncFolderCommit? {
        let folder = folder(for: text)
        guard folder != storedFolder else { return nil }
        return SyncFolderCommit(tabID: tabID, folder: folder)
    }
}

/// The tab-naming copy the no-mapping import prompt shows.
///
/// The import writes the folder into the selected tab, so the alert and the
/// folder picker name that tab instead of saying "the selected tab", which the
/// Tabs pane cannot show.
public struct SyncFolderImportPrompt: Equatable, Sendable {
    public var alertInformativeText: String
    public var pickerMessage: String

    public static func noMappedSyncFolder(tabName: String, language: AppLanguage = .english) -> SyncFolderImportPrompt {
        SyncFolderImportPrompt(
            alertInformativeText: Localization.format(
                .dialogSyncFolderImportAlert,
                language: language,
                tabName
            ),
            pickerMessage: Localization.format(
                .dialogSyncFolderImportPicker,
                language: language,
                tabName
            )
        )
    }
}
