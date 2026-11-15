// Shared UI state for the main window and the preferences window.
//
// It owns the tab list, the entries shown for the current tab, search, the
// keyboard selection, notes, and preferences. All mutations go through
// ClipboardHistory so the store stays the single source of truth.

import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

/// What Edit Item… offers for one entry: whether it can open, and the title
/// that tells the user to use Edit Note when the payload is not text.
struct EditItemAvailability: Equatable {
    static func defaultTitle(for language: AppLanguage = .english) -> String {
        Localization.string(.menuItemEditItem, language: language)
    }

    static func noteTitle(for language: AppLanguage = .english) -> String {
        Localization.string(.menuItemEditItemUseNote, language: language)
    }

    let isEnabled: Bool
    let title: String
}

/// Why the global Paste as Plain Text shortcut is not live.
enum PlainTextHotKeyProblem: Equatable, Sendable {
    case modifier
    case conflict(shortcutLabel: String)
    case unavailable(shortcutLabel: String)

    func message(language: AppLanguage) -> String {
        switch self {
        case .modifier:
            return Localization.string(.settingsShortcutModifierProblem, language: language)
        case .conflict(let shortcutLabel):
            return Localization.format(
                .settingsShortcutConflictProblem,
                language: language,
                Localization.hotKeyLabel(shortcutLabel, language: language)
            )
        case .unavailable(let shortcutLabel):
            return Localization.format(
                .settingsShortcutUnavailableProblem,
                language: language,
                Localization.hotKeyLabel(shortcutLabel, language: language)
            )
        }
    }
}

/// Which text the global Paste as Plain Text shortcut uses.
///
/// With the window open the user is looking at the selected item, so that is
/// the source. With the window in the menu bar the selected item may be stale,
/// while the live clipboard is what the user just copied in another app.
enum PlainTextPasteSource: Equatable {
    case selectedEntry
    case clipboard

    static func choose(windowIsVisible: Bool, hasSelectedEntry: Bool) -> PlainTextPasteSource {
        windowIsVisible && hasSelectedEntry ? .selectedEntry : .clipboard
    }
}

/// A request to edit an entry's text or to create a new item, driving the
/// editor sheet from the Item menu.
struct PendingTextEdit: Identifiable, Equatable {
    enum Mode: Equatable {
        case edit(entryID: Int64)
        case newItem(tabID: Int64)
    }

    let id = UUID()
    let mode: Mode
    let detail: Detail?
    let text: String
    /// The styled seed when the entry stores HTML or RTF, which opens the
    /// styled editor; nil for plain-text and new-item edits.
    let rich: EntryRichTextEditSeed?

    /// What the sheet says under its title. It stays a fact rather than a
    /// sentence so an open sheet follows a language switch.
    enum Detail: Equatable {
        case formattingFallback
        case previewFallback
        case newItem(tabName: String)
    }

    func title(language: AppLanguage) -> String {
        switch mode {
        case .edit:
            return Localization.string(.textEditTitleEdit, language: language)
        case .newItem:
            return Localization.string(.textEditTitleNew, language: language)
        }
    }

    func confirmTitle(language: AppLanguage) -> String {
        switch mode {
        case .edit:
            return Localization.string(.textEditConfirmSave, language: language)
        case .newItem:
            return Localization.string(.textEditConfirmAdd, language: language)
        }
    }

    func detailText(language: AppLanguage) -> String? {
        guard let detail else { return nil }
        switch detail {
        case .formattingFallback:
            return Localization.string(.textEditFormattingFallbackHint, language: language)
        case .previewFallback:
            return Localization.string(.textEditPreviewFallbackHint, language: language)
        case .newItem(let tabName):
            return Localization.format(.textEditNewDetail, language: language, tabName)
        }
    }
}

/// What the editor sheet hands back for saving.
enum TextEditSubmission {
    case text(String)
    case styled(StyledTextDocument)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tabs: [ClipboardTab] = []
    @Published var selectedTabID: Int64 = ClipboardTab.unsavedID
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleReload() } }
    }
    /// Selected entry. Every write goes through `select(_:)`, which commits and
    /// blurs the note editor first, so the focused editor cannot hold the
    /// selection hostage.
    var selectedEntryID: Int64? { selection.selectedEntryID }
    /// Every selected entry. Commands that act in bulk read this rather than
    /// the focus, which is only the entry the user last activated.
    var selectedEntryIDs: Set<Int64> { selection.selectedEntryIDs }
    var selectedEntryCount: Int { selection.selectedEntryIDs.count }
    /// Fixed end of a Shift range, kept beside the selection instead of inside
    /// it so a range can be extended repeatedly without drifting.
    private var selectionAnchorEntryID: Int64?
    /// Asks before removing more than one entry. The app wires this to a modal
    /// alert; a nil closure allows the delete, which keeps headless tests and
    /// the single-entry path unchanged.
    var confirmBulkDeletion: ((Int, AppLanguage) -> Bool)?
    /// Asks before a tab move that would rewrite or delete sync files.
    var confirmSyncMove: ((CopyQSyncRelocationPlan, ClipboardTab, AppLanguage) -> Bool)?
    /// Bumped when the note editor must resign keyboard focus.
    @Published private(set) var noteBlurToken = 0
    private var noteEditingSession = NoteEditingSession()
    var isEditingNote: Bool { noteEditingSession.isEditing }
    @Published private(set) var preferences: Preferences = .defaultValue
    /// Total entries across every tab, refreshed when the store is reloaded.
    /// The preferences pane shows it, and it must not run a count query from a
    /// view body: that body also re-evaluates when a preview finishes.
    @Published private(set) var totalEntryCount = 0
    /// Entries stored in each tab, refreshed with the visible list. The sidebar
    /// badges read this rather than counting from their own body, and every
    /// badge shows the stored total even when the list itself is capped.
    @Published private(set) var tabEntryCounts: [Int64: Int] = [:]
    /// The window's transient banner. Every assignment restarts the auto-dismiss
    /// timer, so results - move, import, and sync summaries, the Accessibility
    /// explanation - fade out on their own instead of staying on screen. Showing
    /// the same message again restarts the timer for it, and a new message
    /// cancels the old timer rather than stacking a second one.
    @Published var notice: String? {
        didSet {
            if notice != noticeParts.joined(separator: " ") {
                noticeParts = notice.map { [$0] } ?? []
            }
            scheduleNoticeDismissal()
        }
    }
    /// The banner's clauses. A record made from several clauses is translated
    /// clause by clause, the same way the status bar renders it.
    private(set) var noticeParts: [String] = []
    @Published private var failureNoticeParts: [String] = []
    /// The most recent failure the user has not dismissed yet.
    ///
    /// A failure explanation must not disappear with the banner: once the
    /// banner fades the status bar carries this message, and it stays there
    /// until the user dismisses it (`dismissFailureNotice()`).
    var failureNotice: String? {
        guard !failureNoticeParts.isEmpty else { return nil }
        return Localization.runtimeMessage(failureNoticeParts, language: preferences.language)
    }
    /// Whether the status bar carries the failure record. It is hidden while the
    /// same message is still the banner, so one failure is never shown twice.
    var showsFailureStatusItem: Bool {
        NoticeStatusPolicy.showsFailureItem(
            failure: failureNoticeParts.isEmpty ? nil : failureNoticeParts.joined(separator: " "),
            banner: notice
        )
    }
    /// Whether the app may post synthetic events. Read through `trust`, which
    /// also keeps a paste that worked as evidence, so a grant macOS reports
    /// late (or not at all for a rebuilt binary) still retires the notice.
    @Published private(set) var accessibilityGranted: Bool
    /// Whether the status bar carries the Accessibility item. It is hidden
    /// while the permission banner is still on screen, because the banner
    /// already says the same thing, and takes over once the banner fades.
    var showsAccessibilityStatusItem: Bool {
        AccessibilityNoticePolicy.showsStatusItem(
            trusted: accessibilityGranted,
            permissionBannerVisible: AccessibilityNoticePolicy.isPermissionNotice(notice)
        )
    }
    /// The per-launch Accessibility trust state. Shared with the paste service,
    /// so the notice and the paste path cannot disagree about trust.
    let trust: PasteTrust
    /// Real Login Items state for this app. The system is the source of truth;
    /// nothing about launch at login is stored in the preferences blob.
    @Published private(set) var launchAtLogin: LaunchAtLoginState = .disabled
    /// Why the last launch-at-login change failed, if it did. Preferences shows
    /// it next to the toggle so the reason is visible where the user acted.
    @Published private(set) var launchAtLoginProblem: String?
    /// The direction of the last failed launch-at-login change. A refresh
    /// retires the failure only once the system reports that target state.
    private var failedLaunchAtLoginTarget: Bool?
    /// Incremented when a menu command wants the search field focused.
    @Published var focusSearchToken = 0
    /// Incremented when a menu command wants the note editor focused.
    @Published var focusNoteToken = 0
    /// Set when a menu command wants the rename-tab sheet shown.
    @Published var pendingRenameTabID: Int64?
    /// Set while the Item editor sheet is open. Nil closes it.
    @Published var pendingTextEdit: PendingTextEdit?
    var isEditingText: Bool { pendingTextEdit != nil }
    /// Progress line for a backup export running in the background, or `nil`
    /// when no export is running.
    @Published private(set) var exportStatus: String?
    /// Why the global Paste as Plain Text shortcut could not be registered.
    /// Preferences shows it next to the recorder so the user can pick another
    /// combination. Nil when the current shortcut is live.
    @Published private(set) var plainTextHotKeyProblem: PlainTextHotKeyProblem?

    let history: ClipboardHistory
    private let launchAtLoginService: LaunchAtLoginService
    private var pasteService: PasteService?
    private var reloadTask: Task<Void, Never>?
    @Published private(set) var isSearchReloadPending = false
    private var noteSaveTask: Task<Void, Never>?
    private var pendingNotes = NoteDraftBuffer()
    private var preserveSelectionAfterCaptureEviction = false
    /// Which part of the main window owns the keyboard. One signal, so the
    /// window key monitor cannot see two claims on the same key.
    private(set) var keyboardFocus: ListFocus = .none

    /// Row content is driven by caches rather than by work in a view body. A
    /// row only looks these up; the expensive preview, thumbnail, and file-icon
    /// work happens once per entry on a background queue.
    @Published private(set) var presentationRevision = 0
    /// Selected entry.
    ///
    /// Selection is a separate observable object, not a `@Published` property
    /// of this model, so a click or an arrow key publishes only the selection.
    /// Everything that observes `AppModel` - the row hierarchy, the tab strip,
    /// the preview data - is left alone.
    let selection = SelectionState()
    /// Precomputed, layout-ready rows. They are rebuilt when the visible entries
    /// change and never on a selection change, so the list keeps its row models
    /// and only its selection moves.
    @Published private(set) var rows: [EntryRow] = []
    /// Bumped only when `rows` changes, so the native list can skip reconfiguring
    /// its visible cells when some unrelated model state was published.
    @Published private(set) var rowsRevision = 0
    @Published private(set) var selectedPreviewImage: NSImage?
    private let presentationCache = EntryPresentationCache()
    private let thumbnailCache = ThumbnailCache(byteBudget: 32 * 1024 * 1024)
    private let richTextCache = RichTextCache()
    /// The appearance the cached rich renditions were built for. Kept here so
    /// an appearance change re-derives text instead of reading payloads again.
    private var richTextAppearance: RichTextAppearance = .light
    /// Entries whose rich payload has been read but produced no drawable
    /// text, so the preview cannot retry a failed parse on every layout pass.
    private var failedRichTextIDs: Set<Int64> = []
    private var pendingRichTextIDs: [Int64] = []
    private var isProcessingRichText = false
    private let fileIconCache = NSCache<NSString, NSImage>()
    private let presentationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.copyqmac.row-presentation"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    /// Row thumbnails are decoded subsampled with ImageIO (row ≈ 280 px).
    private static let rowThumbnailMaxPixelSize = 280
    /// Preview images are decoded subsampled to the pane's longest edge, capped around 1600 px.
    private static let previewMaxPixelSize = 1600
    private static let deleteKeyCooldown: TimeInterval = 0.3
    private var selectedPreviewOperation: Operation?
    private var latestPresentationToken: [Int64: Int] = [:]
    private var pendingPresentationIDs: Set<Int64> = []
    private var pendingPresentationVersions: [Int64: EntryVersion] = [:]
    private var pendingSelectedPreviewIDs: Set<Int64> = []
    private var pendingThumbnailKeys: Set<ThumbnailCache.Key> = []
    private var failedThumbnailKeys = LRUCache<ThumbnailCache.Key, Bool>(capacity: 256)
    private var nextPresentationToken = 0
    private var pendingFileIcons: Set<String> = []
    private var relativeTimeTimer: Timer?
    /// The pending dismissal of the current banner. It is the only owner of the
    /// banner's lifetime: showing a message cancels the previous timer, so a
    /// retired timer can never clear the message that replaced it.
    private var noticeTimer: NoticeTimer?
    /// Schedules the dismissal. The app uses the run loop; a test drives its own.
    private let noticeTimers: NoticeTimerScheduling
    /// Where a failure notice is logged, in addition to the banner and the
    /// status bar. Injectable so the tests can prove the record reaches it.
    private let noticeLog: @MainActor (String) -> Void
    private var selectedPreviewToken = 0
    private var idleTimer: DispatchWorkItem?
    private var isWindowVisible = false
    private var lastDeleteKeyTime: TimeInterval?

    /// Called when the stored preferences change, so the app can re-register the
    /// hotkey.
    var onPreferencesChanged: ((Preferences) -> Void)?
    var onResyncTabRequest: ((Int64) -> Void)?
    var onWriteBackTabRequest: ((Int64) -> Void)?
    /// The last app seen as frontmost. Preferences uses it to offer "add the app
    /// I just copied from" without depending on AppKit itself.
    var sourceApplicationProvider: (@MainActor () -> SourceApplication?)?

    init(
        history: ClipboardHistory,
        launchAtLogin: LaunchAtLoginService = SystemLaunchAtLoginService(),
        isAccessibilityTrusted: @escaping @MainActor () -> Bool = { PasteService.isAccessibilityTrusted() },
        trust: PasteTrust? = nil,
        noticeTimers: NoticeTimerScheduling? = nil,
        noticeLog: @escaping @MainActor (String) -> Void = AppLog.failure
    ) {
        // The app passes the instance it shares with the paste service; a test
        // that only injects the trust check gets its own session built on it.
        let trust = trust ?? PasteTrust(readProcessTrusted: isAccessibilityTrusted)
        let initiallyTrusted = trust.refresh(afterUserAction: false)
        self.history = history
        self.launchAtLoginService = launchAtLogin
        self.trust = trust
        self.noticeTimers = noticeTimers ?? RunLoopNoticeTimerScheduler()
        self.noticeLog = noticeLog
        self.accessibilityGranted = initiallyTrusted
        fileIconCache.countLimit = 256
        richTextAppearance = RichTextAppearance.current()
        history.onEntriesWillBeTrimmed = { [weak self] evictedEntryIDs, reason in
            self?.handleEntriesWillBeTrimmed(evictedEntryIDs, reason: reason)
        }
        history.onSyncEditFailure = { [weak self] message in
            self?.reportFailure(message)
        }
        startRelativeTimeRefresh()
    }

    deinit {
        relativeTimeTimer?.invalidate()
    }

    func attach(pasteService: PasteService) {
        self.pasteService = pasteService
    }

    // MARK: - Bootstrap and loading

    func bootstrap() {
        do {
            preferences = try history.preferences()
            presentationCache.setLanguage(preferences.language)
            tabs = try history.tabs()
            let defaultID = try history.defaultTab().id
            selectedTabID = tabs.contains { $0.id == defaultID } ? defaultID : (tabs.first?.id ?? 0)
            syncWatcher.onImport = { [weak self] _ in
                self?.reload()
            }
            syncWatcher.onSkippedUpstream = { [weak self] stems in
                guard let self, !stems.isEmpty else { return }
                self.notice = stems.count == 1
                    ? "Kept the local version of \(stems[0]) because it is newer than the upstream edit."
                    : "Kept the local versions of \(stems.joined(separator: ", ")) because they are newer than the upstream edits."
            }
            syncWatcher.onRemoteDeletion = { [weak self] stems in
                guard let self, !stems.isEmpty else { return }
                self.notice = stems.count == 1
                    ? "Removed the entry for \(stems[0]) after it was deleted in the sync folder."
                    : "Removed \(stems.count) entries after their files were deleted in sync folders."
                self.reload()
            }
            syncWatcher.start(store: history.store)
            reload()
        } catch {
            reportFailure("Could not load the clipboard store: \(error)")
        }
    }

    func reload(capturedEntryID: Int64? = nil) {
        reload(reason: .refresh(capturedEntryID: capturedEntryID))
    }

    private func reload(reason: NoteEditingSession.ResultsReason) {
        reloadTask?.cancel()
        reloadTask = nil
        isSearchReloadPending = false
        do {
            tabs = try history.tabs()
            if !tabs.contains(where: { $0.id == selectedTabID }) {
                selectedTabID = try history.defaultTab().id
            }
            applyVisibleResults(reason: reason, load: loadVisibleEntries)
            if let tabCounts = try? history.store.entryCountsByTab() {
                tabEntryCounts = tabCounts
                totalEntryCount = tabCounts.values.reduce(0, +)
            }
        } catch {
            reportFailure("Could not read history: \(error)")
        }
    }

    private func loadVisibleEntries() throws -> [ClipboardEntry] {
        let limit = preferences.defaultMaxItems
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try history.recent(limit: limit, tabID: selectedTabID)
        }
        let searchTabID = preferences.searchAllTabs ? nil : selectedTabID
        return try history.search(searchText, limit: limit, tabID: searchTabID)
    }

    private func applyVisibleResults(
        reason: NoteEditingSession.ResultsReason,
        load: () throws -> [ClipboardEntry]
    ) {
        let previousVisibleEntryIDs = entries.map(\.id)
        let previousSelectedEntryID = selectedEntryID
        var saveFailure: String?
        var transitionSaveFailure: String?
        var effectiveReason = reason
        if case .refresh(let capturedEntryID) = reason,
           capturedEntryID != nil,
           preserveSelectionAfterCaptureEviction
        {
            effectiveReason = .refresh(capturedEntryID: nil)
            preserveSelectionAfterCaptureEviction = false
        }

        let isEditing = isEditingNote
        let editingID = noteEditingSession.entryID
        var preservedDraft: (Int64, String)?

        do {
            let applied = try noteEditingSession.applyResults(
                reason: effectiveReason,
                currentSelectionID: selectedEntryID,
                previousVisibleEntryIDs: previousVisibleEntryIDs,
                filterActive: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                commitDraft: {
                    guard case .draftChanged = effectiveReason else {
                        if case .refresh = effectiveReason,
                           isEditing,
                           let editingID,
                           let draft = self.pendingNotes.draft(for: editingID)
                        {
                            preservedDraft = (editingID, draft)
                            return nil
                        }
                        saveFailure = self.commitPendingNotes()
                        transitionSaveFailure = saveFailure
                        return saveFailure
                    }
                    return nil
                },
                load: load,
                entryIDFor: \.id
            )
            var visibleEntries = applied.entries
            if let (preservedID, _) = preservedDraft {
                if !visibleEntries.contains(where: { $0.id == preservedID }) {
                    saveFailure = self.commitPendingNotes()
                }
            }
            for index in visibleEntries.indices {
                if let draft = pendingNotes.draft(for: visibleEntries[index].id) {
                    visibleEntries[index].note = draft
                }
            }
            entries = visibleEntries
            synchronizeCachedEntries(with: visibleEntries)
            rebuildRows()
            reconcileSelection(
                with: visibleEntries.map(\.id),
                sessionFocus: applied.transition.selectedEntryID
            )
            if applied.transition.endedEditing { noteBlurToken += 1 }
            if transitionSaveFailure != nil, let notice = applied.transition.notice {
                self.reportFailure(notice)
            } else if let saveFailure {
                self.reportFailure("Could not save the note; its draft remains available for retry: \(saveFailure)")
            } else if let notice = applied.transition.notice {
                self.notice = notice
            }
            if applied.transition.preserveCaptureSelection {
                preserveSelectionAfterCaptureEviction = true
            }
        } catch {
            let fallback = noteEditingSession.applyResults(
                reason: .refresh(capturedEntryID: nil),
                currentSelectionID: selectedEntryID,
                previousVisibleEntryIDs: previousVisibleEntryIDs,
                filterActive: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                commitDraft: { saveFailure },
                load: { [ClipboardEntry]() },
                entryIDFor: \.id
            )
            entries = []
            rebuildRows()
            reconcileSelection(with: [], sessionFocus: fallback.transition.selectedEntryID)
            if fallback.transition.endedEditing { noteBlurToken += 1 }
            var messages = [fallback.transition.notice].compactMap { $0 }
            if fallback.transition.notice == nil, let saveFailure {
                messages.append("Could not save the note; its draft remains available for retry: \(saveFailure)")
            }
            messages.append("Could not read history: \(error)")
            reportFailure(messages)
        }
        if previousSelectedEntryID != selectedEntryID {
            if let previousSelectedEntryID {
                presentationCache.discardFullPreviewData(for: previousSelectedEntryID)
            }
            clearSelectedImagePreview()
            requestSelectedPreviewImage()
        }
        revealSelection()
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        isSearchReloadPending = true
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.reloadTask = nil
                self.isSearchReloadPending = false
                self.reload()
            }
        }
    }

    var selectedTab: ClipboardTab? { tabs.first { $0.id == selectedTabID } }

    var selectedEntry: ClipboardEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
    }

    var canActOnSelectedEntry: Bool {
        !isSearchReloadPending && selectedEntry != nil
    }

    /// True when a command that creates content can start: no item editor and
    /// no tab rename is open. New Item, New Tab, and import all share it.
    var canCreateNewItem: Bool {
        !isEditingText && pendingRenameTabID == nil
    }

    /// The enabled state and title for Edit Item…, for the selected entry when
    /// `entryID` is nil. The menu-bar item and the row context menu both read
    /// this, so they cannot disagree about an image or file entry.
    func editItemAvailability(
        for entryID: Int64? = nil,
        language: AppLanguage? = nil
    ) -> EditItemAvailability {
        let lang = language ?? preferences.language
        guard canCreateNewItem,
              let id = entryID ?? selectedEntryID,
              let entry = actionableEntry(id: id)
        else {
            return EditItemAvailability(isEnabled: false, title: EditItemAvailability.defaultTitle(for: lang))
        }
        let editable = EntryTextEditing.supportsTextEditing(entry)
        return EditItemAvailability(
            isEnabled: editable,
            title: editable
                ? EditItemAvailability.defaultTitle(for: lang)
                : EditItemAvailability.noteTitle(for: lang)
        )
    }

    private func actionableEntry(id: Int64) -> ClipboardEntry? {
        guard !isSearchReloadPending else { return nil }
        return entries.first { $0.id == id }
    }

    /// The visible entry with this id, if it is still listed.
    func entry(id: Int64) -> ClipboardEntry? {
        entries.first { $0.id == id }
    }

    /// The tab captures on this machine are written into.
    var captureTab: ClipboardTab? { tabs.first(where: \.isDefault) ?? tabs.first }

    // MARK: - Tab actions

    func selectTab(_ id: Int64) {
        guard !isEditingText else { return }
        guard id != selectedTabID else { return }
        selectedTabID = id
        // A selection belongs to the tab it was made in, so switching tabs
        // starts fresh; the reload below selects the first item.
        selection.set(ids: [], focus: nil)
        selectionAnchorEntryID = nil
        reload(reason: .first)
    }

    /// Applies Page Up, Page Down, Home, and End to the sidebar's tab
    /// selection. Up and Down stay with the List, which already moves its own
    /// selection, and note editing keeps the keyboard.
    @discardableResult
    func handleSidebarNavigation(_ key: ListKey) -> Bool {
        guard keyboardFocus == .sidebar, !isEditingNote else { return false }
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return false }
        let target: Int
        switch key {
        case .pageUp: target = index - 8
        case .pageDown: target = index + 8
        case .home: target = 0
        case .end: target = tabs.count - 1
        default: return false
        }
        let clamped = min(max(target, 0), tabs.count - 1)
        if clamped != index {
            selectTab(tabs[clamped].id)
        }
        return true
    }

    /// Asks the main window to focus the search field.
    func focusSearch() { focusSearchToken += 1 }

    /// Asks the main window to focus the note editor.
    func focusNote() { focusNoteToken += 1 }

    // MARK: - Item text editing

    /// Opens the editor for the selected entry's text.
    func requestEditSelectedEntry() {
        guard pendingTextEdit == nil, pendingRenameTabID == nil else { return }
        finishNoteEditingForEditor()
        guard let selectedEntryID, let entry = actionableEntry(id: selectedEntryID) else { return }
        guard EntryTextEditing.supportsTextEditing(entry) else {
            reportFailure(EntryTextEditingError.unsupportedKind.message)
            return
        }
        let seed = EntryTextEditing.seed(for: entry)
        // An HTML or RTF entry is edited as the styled text it stores. The
        // plain editor stays for every other entry, and for a rich payload the
        // styled editor cannot keep without rewriting it.
        let richSeed = RichTextEditing.seed(for: entry)
        let detail: PendingTextEdit.Detail?
        if richSeed == nil, RichTextBuilder.hasRichFlavour(entry.flavours) {
            detail = .formattingFallback
        } else if richSeed == nil, seed.isPreviewFallback {
            detail = .previewFallback
        } else {
            detail = nil
        }
        pendingTextEdit = PendingTextEdit(
            mode: .edit(entryID: entry.id),
            detail: detail,
            text: seed.text,
            rich: richSeed
        )
    }

    /// Opens an empty editor for a new item in the selected tab.
    func requestNewItem() {
        guard pendingTextEdit == nil, pendingRenameTabID == nil else { return }
        finishNoteEditingForEditor()
        guard let tab = selectedTab else { return }
        pendingTextEdit = PendingTextEdit(
            mode: .newItem(tabID: tab.id),
            detail: .newItem(tabName: tab.name),
            text: "",
            rich: nil
        )
    }

    /// Saves the open editor. Returns a message to show in the sheet when it
    /// could not be saved, or nil after the item was stored and selected.
    ///
    /// A plain editor saves its text; the styled editor saves its document.
    @discardableResult
    func commitTextEdit(_ submission: TextEditSubmission) -> String? {
        switch submission {
        case .text(let text): return commitPlainTextEdit(text)
        case .styled(let document): return commitStyledTextEdit(document)
        }
    }

    /// Saves a styled edit in the entry's own rich format.
    ///
    /// Saving a document identical to the one the editor opened with closes the
    /// sheet without touching the entry: opening a rich item, looking at it,
    /// and pressing Save must not rewrite its payload, mark it locally edited,
    /// or push a normalised version to the sync folder.
    @discardableResult
    func commitStyledTextEdit(_ document: StyledTextDocument) -> String? {
        guard let request = pendingTextEdit, let rich = request.rich else { return nil }
        guard case .edit(let id) = request.mode else { return nil }
        if document == rich.document {
            pendingTextEdit = nil
            return nil
        }
        do {
            notice = nil
            guard try history.replaceRichText(of: id, with: document, format: rich.format) != nil else {
                return EntryTextEditingError.entryNotFound.message
            }
            // The row and rich-text caches compare payload length and edge
            // bytes, so an edit that keeps either would otherwise keep drawing
            // the old styling.
            invalidateCachedEntry(id)
            pendingTextEdit = nil
            reload(capturedEntryID: id)
            announceIfHidden(id)
            return nil
        } catch let error as EntryTextEditingError {
            return error.message
        } catch {
            return "Could not save the item: \(error)"
        }
    }

    @discardableResult
    private func commitPlainTextEdit(_ text: String) -> String? {
        guard let request = pendingTextEdit else { return nil }
        do {
            switch request.mode {
            case .edit(let id):
                // Clear the previous notice before the save so a sync-write
                // failure reported during the save is not wiped by the success
                // path below.
                notice = nil
                guard try history.replaceText(of: id, with: text) != nil else {
                    return EntryTextEditingError.entryNotFound.message
                }
                // The row cache compares only payload length and edge bytes, so
                // invalidate it explicitly; a same-length edit in the middle
                // would otherwise keep drawing the old text.
                invalidateCachedEntry(id)
                pendingTextEdit = nil
                reload(capturedEntryID: id)
                announceIfHidden(id)
            case .newItem(let tabID):
                guard let tab = tabs.first(where: { $0.id == tabID }) else {
                    return "The tab no longer exists."
                }
                let entry = try history.addItem(withText: text, in: tab)
                if !(tab.syncFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    syncWriter.enqueue(entry: entry, store: history.store, reason: "new-item")
                }
                pendingTextEdit = nil
                notice = nil
                reload(capturedEntryID: entry.id)
                announceIfHidden(entry.id)
            }
            return nil
        } catch let error as EntryTextEditingError {
            return error.message
        } catch {
            return "Could not save the item: \(error)"
        }
    }

    private func announceIfHidden(_ id: Int64) {
        guard notice == nil, !entries.contains(where: { $0.id == id }) else { return }
        notice = "Saved; hidden by the current filter."
    }

    /// Closes the editor without touching the store.
    func cancelTextEdit() {
        pendingTextEdit = nil
    }

    /// A sheet takes focus away from the note editor, so commit any pending
    /// note draft first instead of leaving it to the focus change.
    private func finishNoteEditingForEditor() {
        guard isEditingNote else { return }
        reload(reason: .finishEditing)
    }

    /// Asks the main window to show the rename sheet for the current tab.
    func requestRenameSelectedTab() {
        guard !isEditingText else { return }
        pendingRenameTabID = selectedTabID
    }

    @discardableResult
    func addTab(named name: String) -> ClipboardTab? {
        guard !isEditingText else { return nil }
        do {
            let tab = try history.addTab(name: name)
            selectedTabID = tab.id
            reload(reason: .first)
            return tab
        } catch {
            reportFailure("Could not add the tab: \(error)")
            return nil
        }
    }

    func updateTab(_ tab: ClipboardTab) {
        do {
            try history.updateTab(tab)
            syncWatcher.updateConfiguration(store: history.store)
            reload()
        } catch {
            reportFailure("Could not update the tab: \(error)")
        }
    }

    func renameTab(_ tab: ClipboardTab, to name: String) {
        var updated = tab
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return }
        updateTab(updated)
    }

    func removeTab(_ tab: ClipboardTab) {
        guard !isEditingText else { return }
        if let editingID = noteEditingSession.entryID,
           entries.first(where: { $0.id == editingID })?.tabID == tab.id
        {
            reload(reason: .finishEditing)
        }
        do {
            try history.deleteTab(id: tab.id)
            invalidateAllCachedEntries()
            syncWatcher.updateConfiguration(store: history.store)
            reload()
        } catch {
            reportFailure("Could not remove the tab: \(error)")
        }
    }

    func moveTab(_ tab: ClipboardTab, delta: Int) {
        do {
            try history.moveTab(id: tab.id, delta: delta)
            reload()
        } catch {
            reportFailure("Could not reorder the tab: \(error)")
        }
    }

    func setCaptureTab(_ tab: ClipboardTab) {
        do {
            try history.setDefaultTab(id: tab.id)
            reload()
        } catch {
            reportFailure("Could not set the default tab: \(error)")
        }
    }

    // MARK: - CopyQ Sync and Import

    func importFromPath(_ url: URL) {
        notice = Localization.string(.noticeImportingCopyQ, language: preferences.language)
        let store = history.store
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try CopyQSyncBridge.importPath(url.path, in: store)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.reload()
                    let language = self.preferences.language
                    self.notice = Localization.format(
                        .noticeImportCompletePrefix,
                        language: language,
                        report.summary(language: language)
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.reportFailure("Import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Gives the tab the no-mapping prompt named the folder it offered to pick
    /// and lets the watcher's own initial scan import that folder's items.
    ///
    /// The pick is the prompt's own recovery: the folder becomes that tab's
    /// sync folder, so the watcher and the writer take it over, and the items
    /// are imported into that tab rather than a new one named after the folder.
    /// The tab is the one the prompt named, even if the selection moved while
    /// the picker was open. A folder a tab gained while the prompt was open is
    /// never overwritten.
    func adoptPickedSyncFolder(_ url: URL, intoTabID: Int64) {
        guard var target = tab(id: intoTabID) else {
            reportFailure("Could not set the sync folder: the tab it was picked for no longer exists.")
            return
        }
        if let mapped = tabs.first(where: { !($0.syncFolder ?? "").isEmpty }) {
            reportFailure("Could not set the sync folder: '\(mapped.name)' already has one.")
            return
        }

        target.syncFolder = url.path
        do {
            try history.updateTab(target)
        } catch {
            reportFailure("Could not set the sync folder: \(error.localizedDescription)")
            return
        }
        reload()

        let store = history.store
        let watcher = syncWatcher
        let folder = url.path
        let tabID = target.id
        notice = Localization.format(
            .noticeImportingFilePrefix,
            language: preferences.language,
            url.lastPathComponent
        )
        watcher.updateConfiguration(store: store, scan: false)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try watcher.scanFolder(
                    atPath: folder,
                    intoTabID: tabID,
                    in: store,
                    settleDelayOverride: 0
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.reload()
                    let language = self.preferences.language
                    self.notice = Localization.format(
                        .noticeSyncFolderImportedPrefix,
                        language: language,
                        report.summary(language: language)
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.reportFailure("Import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Imports every mapped tab's configured sync folder.
    ///
    /// The completion runs on the main actor with the report once the import
    /// settles; a report whose `mappedTabCount` is zero means no tab had a sync
    /// folder to read, and the caller turns that into the explicit prompt
    /// instead of the ordinary summary.
    func importConfiguredSyncFolders(completion: (@MainActor (CopyQImportReport) -> Void)? = nil) {
        notice = Localization.string(
            .noticeImportingConfiguredSyncFolders,
            language: preferences.language
        )
        let store = history.store
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try CopyQSyncBridge.importConfiguredSyncFolders(in: store)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.reload()
                    let language = self.preferences.language
                    if report.mappedTabCount == 0 {
                        self.notice = Localization.string(.noticeNoSyncFolderSet, language: language)
                    } else {
                        self.notice = Localization.format(
                            .noticeSyncFoldersImportedPrefix,
                            language: language,
                            report.summary(language: language)
                        )
                    }
                    completion?(report)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.reportFailure("Sync folders import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Internal Marker Cleanup

    func internalMarkerCandidateReport() throws -> InternalMarkerCleanupReport {
        _ = persistPendingNotes()
        return try InternalMarkerCleanup.candidateReport(in: history.store)
    }

    @discardableResult
    func removeInternalMarkerEntries() -> InternalMarkerCleanupReport? {
        guard !isEditingText else { return nil }
        _ = persistPendingNotes()
        do {
            let report = try InternalMarkerCleanup.removeMarkerOnlyEntries(in: history.store)
            invalidateAllCachedEntries()
            reload()
            notice = Localization.format(
                .noticeInternalMarkerCleanupPrefix,
                language: preferences.language,
                report.summary(language: preferences.language)
            )
            return report
        } catch {
            reportFailure("Could not remove internal marker entries: \(error)")
            return nil
        }
    }

    // MARK: - Backup export

    /// True while a backup export is writing, which disables the export
    /// commands so two runs cannot fight over the status line.
    var isExporting: Bool { exportStatus != nil }

    /// Writes a CopyQ `.cpq` backup of every tab, or of one tab, to `url`.
    ///
    /// The store is read and the archive encoded on a background task, so a
    /// large history never blocks the window; the status bar follows the
    /// export through `exportStatus` and the outcome lands in `notice`.
    func exportBackup(to url: URL, tabID: Int64?) {
        guard !isExporting else { return }
        let scope: CopyQSyncBridge.ExportScope = tabID.map { .tab($0) } ?? .allTabs
        let store = history.store
        notice = nil
        exportStatus = Localization.string(.statusBarExportingBackup, language: preferences.language)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try CopyQSyncBridge.exportArchive(
                    toPath: url.path,
                    scope: scope,
                    in: store
                ) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isExporting else { return }
                        let text = BackupExportStatus.text(for: progress, language: self.preferences.language)
                        self.exportStatus = text
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.exportStatus = nil
                    let language = self.preferences.language
                    self.notice = Localization.format(
                        .noticeBackupWrittenPrefix,
                        language: language,
                        report.summary(language: language)
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.exportStatus = nil
                    self?.reportFailure("Backup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Entry actions

    func togglePin(_ entry: ClipboardEntry) {
        guard let entry = actionableEntry(id: entry.id) else { return }
        do {
            _ = try history.setPinned(entry.id, !entry.pinned)
            reload()
        } catch {
            reportFailure("Could not update the pin: \(error)")
        }
    }

    func togglePinSelected() {
        guard let selectedEntryID, let entry = actionableEntry(id: selectedEntryID) else { return }
        togglePin(entry)
    }

    /// Removes an entry. Invariant: entry operations do not act while editing a
    /// note or an item's text.
    func remove(_ entry: ClipboardEntry) {
        guard !isEditingNote, !isEditingText else { return }
        guard let entry = actionableEntry(id: entry.id) else { return }
        if noteEditingSession.entryID == entry.id { reload(reason: .finishEditing) }
        do {
            try history.delete(entry.id)
            invalidateCachedEntry(entry.id)
            reload()
        } catch {
            reportFailure("Could not delete the entry: \(error)")
        }
    }

    /// Removes every selected entry. Invariant: entry operations do not act
    /// while editing a note or an item's text.
    ///
    /// Bulk deletion asks once, naming the count; a single entry keeps the old
    /// no-confirmation path. Every row goes through `history.delete(ids:)`, so
    /// each owned sync group is moved to the recoverable trash first.
    func removeSelected() {
        guard !isEditingNote, !isEditingText else { return }
        let ids = selectedEntriesInDisplayOrder.map(\.id)
        guard !ids.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastDeleteKeyTime, now - lastDeleteKeyTime < Self.deleteKeyCooldown { return }
        if ids.count > 1, let confirmBulkDeletion, !confirmBulkDeletion(ids.count, preferences.language) { return }
        remove(ids: ids)
        lastDeleteKeyTime = ProcessInfo.processInfo.systemUptime
    }

    /// Removes several entries in one store call so the sync trash work and the
    /// row deletion cannot interleave.
    private func remove(ids: [Int64]) {
        guard !isEditingNote, !isEditingText else { return }
        let existing = ids.filter { actionableEntry(id: $0) != nil }
        guard !existing.isEmpty else { return }
        if let editingID = noteEditingSession.entryID, existing.contains(editingID) {
            reload(reason: .finishEditing)
        }
        do {
            try history.delete(ids: existing)
            invalidateCachedEntries(Set(existing))
            reload()
        } catch {
            reportFailure(existing.count == 1
                ? "Could not delete the entry: \(error)"
                : "Could not delete the selected entries: \(error)")
        }
    }

    func syncDeletionFileInfo(forTabID tabID: Int64) -> (folder: String, fileCount: Int)? {
        guard let tab = (try? history.store.tab(id: tabID)) ?? tabs.first(where: { $0.id == tabID }),
              let folder = tab.syncFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty
        else { return nil }
        let prefs = (try? history.store.preferences()) ?? preferences
        guard !prefs.syncPaused else { return nil }

        let normalized = CopyQSyncBridge.normalizePath(folder)
        let groups = CopyQSyncWatcher.findItemGroups(in: normalized)
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.stem, $0.files.count) })
        let tabEntries = (try? history.store.recentEntries(limit: Int.max, tabID: tabID)) ?? []
        var seenStems = Set<String>()
        var totalFiles = 0
        for entry in tabEntries {
            let stems = CopyQSyncDeletion.syncBaseNames(
                of: entry,
                in: history.store,
                folder: normalized,
                groupStems: Set(groupMap.keys)
            )
            for stem in stems where seenStems.insert(stem).inserted {
                if let count = groupMap[stem] {
                    totalFiles += count
                }
            }
        }
        return (folder, totalFiles)
    }

    func clearSelectedTab() {
        guard !isEditingText else { return }
        let tabID = selectedTabID != ClipboardTab.unsavedID ? selectedTabID : (try? history.defaultTab().id) ?? 0
        if let editingID = noteEditingSession.entryID,
           entries.first(where: { $0.id == editingID })?.tabID == tabID
        {
            reload(reason: .finishEditing)
        }
        do {
            try history.clear(tabID: tabID)
            invalidateAllCachedEntries()
            reload()
        } catch {
            reportFailure("Could not clear the tab: \(error)")
        }
    }

    /// Called as the user types in the note field. Updates the row immediately
    /// and persists after a short pause.
    func setNoteDraft(_ note: String) {
        guard isEditingNote,
              let id = noteEditingSession.entryID,
              entries.contains(where: { $0.id == id })
        else { return }
        pendingNotes.set(note, for: id)
        applyVisibleResults(reason: .draftChanged(id)) { entries }
        noteSaveTask?.cancel()
        noteSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = self.persistPendingNotes()
                } else {
                    self.reload()
                }
            }
        }
    }

    /// Called when the filter field gains or loses keyboard focus.
    func setFilterFocused(_ focused: Bool) { setKeyboardFocus(.filter, focused: focused) }

    /// Called when the item list gains or loses keyboard focus.
    func setListFocused(_ focused: Bool) { setKeyboardFocus(.itemList, focused: focused) }

    /// Called when the Layout B sidebar gains or loses keyboard focus.
    func setSidebarFocused(_ focused: Bool) { setKeyboardFocus(.sidebar, focused: focused) }

    private func setKeyboardFocus(_ focus: ListFocus, focused: Bool) {
        if focused {
            keyboardFocus = focus
        } else if keyboardFocus == focus {
            keyboardFocus = .none
        }
    }

    /// Called when the note editor gains or loses keyboard focus.
    func setNoteEditing(_ editing: Bool) {
        guard editing != isEditingNote else { return }
        if editing {
            applyVisibleResults(reason: .beginEditing) { entries }
        } else {
            reload(reason: .finishEditing)
        }
    }

    /// Commits the pending note draft and drops keyboard focus from the editor.
    func endNoteEditing() {
        reload(reason: .finishEditing)
    }

    @discardableResult
    func flushPendingNote() -> String? {
        noteSaveTask?.cancel()
        noteSaveTask = nil
        return persistPendingNotes()
    }

    @discardableResult
    private func persistPendingNotes() -> String? {
        let failure = commitPendingNotes()
        if let failure {
            reportFailure("Could not save the note; its draft remains available for retry: \(failure)")
        }
        return failure
    }

    private func commitPendingNotes() -> String? {
        noteSaveTask = nil
        let history = self.history
        return pendingNotes.commit { id, note in
            do {
                guard try history.setNote(id, note) != nil else {
                    return "entry \(id) no longer exists"
                }
                return nil
            } catch {
                return String(describing: error)
            }
        }
    }

    private func handleEntriesWillBeTrimmed(_ evictedEntryIDs: [Int64], reason: HistoryTrimReason) {
        let evicted = Set(evictedEntryIDs)
        invalidateCachedEntries(evicted)
        applyVisibleResults(
            reason: .eviction(entryIDs: evictedEntryIDs, fromCapture: reason == .capture)
        ) {
            entries.filter { !evicted.contains($0.id) }
        }
    }

    // MARK: - Selection

    /// Applies a single selection, honouring `SelectionChangePolicy`.
    ///
    /// A selection change is pure view state: the entries are already in
    /// memory, so the store is not read again, no thumbnail is decoded, no row
    /// model is rebuilt, and the visible row hierarchy is not re-evaluated.
    /// Clicking a row has to feel exactly as immediate as pressing an arrow key.
    func select(_ id: Int64?) {
        guard let id else {
            clearSelection()
            return
        }
        if selectedEntryID == id, selection.selectedEntryIDs == [id] { return }
        applySelection(ids: [id], focus: id, anchor: id)
    }

    /// Command-click: add or remove one entry without disturbing the rest.
    func toggleSelection(_ id: Int64) {
        var next = currentItemSelection()
        next.toggle(id, in: entries.map(\.id))
        applyItemSelection(next)
    }

    /// Shift-click: select the contiguous range between the anchor and `id`.
    func extendSelection(to id: Int64) {
        var next = currentItemSelection()
        next.extend(to: id, in: entries.map(\.id))
        applyItemSelection(next)
    }

    /// Command-A: every entry currently listed.
    func selectAllEntries() {
        guard !entries.isEmpty else { return }
        var next = currentItemSelection()
        next.selectAll(in: entries.map(\.id))
        applyItemSelection(next)
    }

    /// Escape: drop the selection without touching the entries.
    func clearSelection() {
        guard !selection.selectedEntryIDs.isEmpty else { return }
        applySelection(ids: [], focus: nil, anchor: nil)
    }

    /// Applies a selection computed by `ItemSelection`, skipping the work when
    /// the resulting view state is identical. At the end of a list an arrow key
    /// would otherwise re-commit a pending note draft for no visible change.
    private func applyItemSelection(_ next: ItemSelection) {
        if next.ids == selection.selectedEntryIDs, next.focus == selectedEntryID {
            selectionAnchorEntryID = next.anchor
            return
        }
        applySelection(ids: next.ids, focus: next.focus, anchor: next.anchor)
    }

    /// Applies a selection computed by `ItemSelection`, then lets the note
    /// editing session decide whether the note editor has to close first.
    private func applySelection(ids: Set<Int64>, focus: Int64?, anchor: Int64?) {
        let previousSelectedEntryID = selectedEntryID
        let visibleIDs = entries.map(\.id)
        let visible = Set(visibleIDs)
        var nextIDs = ids.intersection(visible)
        let requestedFocus = focus.flatMap { visible.contains($0) ? $0 : nil }
        var saveFailure: String?
        let applied = noteEditingSession.applyResults(
            reason: .selectionOnly(selected: requestedFocus),
            currentSelectionID: selectedEntryID,
            previousVisibleEntryIDs: visibleIDs,
            filterActive: isFilterActive,
            commitDraft: {
                saveFailure = self.commitPendingNotes()
                return saveFailure
            },
            load: { entries },
            entryIDFor: \.id
        )
        // `SelectionState` is the only thing a selection writes. The entries and
        // the row models stay exactly as they are; the list moves its selection
        // and the preview pane follows the new entry.
        var resolvedFocus = applied.transition.selectedEntryID
        if let resolvedFocus, !nextIDs.contains(resolvedFocus), nextIDs.isEmpty {
            // The note session resolved a fallback for a focus that is no
            // longer listed. A command that asked for one entry must not
            // silently widen, so only an otherwise empty selection adopts it.
            nextIDs.insert(resolvedFocus)
        }
        if nextIDs.isEmpty {
            resolvedFocus = nil
        } else if let focus = resolvedFocus, nextIDs.contains(focus) {
            resolvedFocus = focus
        } else {
            resolvedFocus = visibleIDs.first { nextIDs.contains($0) }
        }
        let resolvedAnchor = anchor.flatMap { nextIDs.contains($0) ? $0 : nil } ?? resolvedFocus
        selection.set(ids: nextIDs, focus: resolvedFocus)
        selectionAnchorEntryID = nextIDs.isEmpty ? nil : resolvedAnchor
        if applied.transition.endedEditing { noteBlurToken += 1 }
        if saveFailure != nil, let notice = applied.transition.notice {
            reportFailure(notice)
        } else if let saveFailure {
            reportFailure("Could not save the note; its draft remains available for retry: \(saveFailure)")
        } else if let notice = applied.transition.notice {
            self.notice = notice
        }
        if previousSelectedEntryID != selectedEntryID {
            if let previousSelectedEntryID {
                presentationCache.discardFullPreviewData(for: previousSelectedEntryID)
            }
            clearSelectedImagePreview()
            requestSelectedPreviewImage()
        }
    }

    private func currentItemSelection() -> ItemSelection {
        ItemSelection(
            ids: selection.selectedEntryIDs,
            focus: selectedEntryID,
            anchor: selectionAnchorEntryID
        )
    }

    /// Re-applies the selection after the list changed. Identities that
    /// survived the refresh keep their selection; the focus is whichever entry
    /// the note session picked, and a selection that became empty adopts that
    /// fallback.
    private func reconcileSelection(with order: [Int64], sessionFocus: Int64?) {
        guard !order.isEmpty else {
            selection.set(ids: [], focus: nil)
            selectionAnchorEntryID = nil
            return
        }
        let previousCount = selection.selectedEntryIDs.count
        var next = currentItemSelection()
        next.reconcile(with: order)
        if let sessionFocus {
            if next.ids.contains(sessionFocus) {
                _ = next.focusOn(sessionFocus)
            } else if next.ids.isEmpty || previousCount <= 1 {
                // An unfiltered capture takes over a single selection, as it
                // always has. A multi-selection is deliberate, so it stays
                // where it is and only survives the refresh.
                next.selectSingle(sessionFocus)
            }
        }
        selection.set(ids: next.ids, focus: next.focus)
        selectionAnchorEntryID = next.anchor
    }

    /// Applies a selection the native table already made with the mouse.
    ///
    /// The table has already highlighted the rows, so the model only records
    /// the identities and the focus; re-selecting them would be a no-op at
    /// best and would lose the user's click at worst.
    func applyListSelection(_ change: ListSelectionChange) {
        if let clickedID = change.clickedID, entries.contains(where: { $0.id == clickedID }) {
            if change.extending {
                extendSelection(to: clickedID)
            } else if change.command {
                toggleSelection(clickedID)
            } else {
                select(clickedID)
            }
            return
        }

        // No row under the pointer (a deselection, or a change AppKit made on
        // its own). Trust the table's set and pick a focus that still exists.
        let visible = Set(entries.map(\.id))
        let nextIDs = change.ids.intersection(visible)
        let nextFocus = change.focus.flatMap { visible.contains($0) ? $0 : nil }
        guard nextIDs != selection.selectedEntryIDs || nextFocus != selectedEntryID else { return }
        let anchor = selectionAnchorEntryID.flatMap { nextIDs.contains($0) ? $0 : nil } ?? nextFocus
        applySelection(ids: nextIDs, focus: nextFocus, anchor: anchor)
    }

    /// Focuses `id` without clearing the rest of the selection. A row that was
    /// not selected becomes the single selection, matching a plain click.
    func focusEntry(_ id: Int64) {
        guard entries.contains(where: { $0.id == id }) else { return }
        var next = currentItemSelection()
        if next.ids.contains(id) {
            guard next.focusOn(id) else { return }
            applyItemSelection(next)
        } else {
            select(id)
        }
    }

    /// Asks the list to scroll the focused row into view.
    ///
    /// Only a data change (a capture arriving, a tab switch) asks for this.
    /// Selection changes let the list decide whether the row is already on
    /// screen, so clicking a visible row never scrolls anything.
    func revealSelection() {
        guard selectedEntryID != nil else { return }
        selection.requestReveal()
    }

    /// Moves the focus one step. Plain arrows take the selection with them;
    /// Shift-arrow extends the range from the anchor.
    func moveSelection(by delta: Int, extending: Bool = false) {
        guard !entries.isEmpty else { return }
        var next = currentItemSelection()
        next.moveFocus(by: delta, extending: extending, in: entries.map(\.id))
        applyItemSelection(next)
    }

    func selectFirst() { select(entries.first?.id) }
    func selectLast() { select(entries.last?.id) }

    /// The selected entries in the order the list shows them.
    var selectedEntriesInDisplayOrder: [ClipboardEntry] {
        entries.filter { selection.selectedEntryIDs.contains($0.id) }
    }

    // MARK: - Paste

    /// Copies the selected entry. Invariant: entry operations do not act while editing a note.
    func copySelected() {
        guard !isEditingNote else { return }
        guard let selectedEntryID,
              let entry = actionableEntry(id: selectedEntryID),
              let pasteService
        else { return }
        pasteService.copy(entry)
        notice = nil
    }

    /// Copies one row from the context menu.
    ///
    /// The row becomes the focus so a later Copy repeats it, but the rest of a
    /// multi-selection is left alone.
    func copyEntry(_ id: Int64) {
        guard !isEditingNote else { return }
        guard let entry = actionableEntry(id: id), let pasteService else { return }
        focusEntry(id)
        pasteService.copy(entry)
        notice = nil
    }

    /// Pastes the selected entry (Edit ▸ Paste, ⌘V).
    ///
    /// It runs the same activation pipeline as Return, so the menu, the click,
    /// and the key cannot drift apart.
    func pasteSelected(dismiss: @escaping () -> Void) {
        activateSelected(dismiss: dismiss)
    }

    /// Activates the selected entry (Item ▸ Activate, Return).
    func activateSelected(dismiss: @escaping () -> Void) {
        guard let selectedEntryID else { return }
        activate(selectedEntryID, dismiss: dismiss)
    }

    /// Activates one entry: the single path behind a single click (when the
    /// preference is on), a double click, Return, and Item ▸ Activate.
    ///
    /// The steps and their order come from `ActivationPlan`; this method only
    /// wires the plan to the paste service, the window, and the store.
    func activate(_ id: Int64, dismiss: @escaping () -> Void) {
        guard !isEditingNote else { return }
        guard let entry = actionableEntry(id: id), let pasteService else { return }
        let actions = ActivationPlan.actions(
            for: preferences.activation,
            hasPreviousTarget: pasteService.hasPreviousTarget
        )
        ActivationPipeline.run(actions, handlers: ActivationHandlers(
            copy: { willPaste in
                // The paste step writes the pasteboard itself, so a plain copy
                // here would only write every flavour twice.
                guard !willPaste else { return }
                pasteService.copy(entry)
            },
            paste: { completion in
                pasteService.paste(entry) { [weak self] outcome in
                    completion(self?.handlePasteOutcome(outcome) ?? false)
                }
            },
            focusPreviousApp: { [weak self] in
                let focused = pasteService.focusPreviousApp()
                if !focused { self?.reportFailure(PasteService.focusFailedMessage) }
                return focused
            },
            closeWindow: dismiss,
            moveToTop: { [weak self] in self?.moveToTop(entry.id) }
        ))
    }

    /// The last activation step: move the item to the top of its tab.
    ///
    /// The entry keeps its id and note, and the selection stays on it, so the
    /// list simply redraws with that row first.
    func moveToTop(_ id: Int64) {
        do {
            try history.moveToTop(id)
        } catch {
            reportFailure("Could not move the item to the top: \(error)")
            return
        }
        reload()
    }

    // MARK: - Bulk order and tab moves

    /// Reordering needs the tab's true order, which a filtered list does not
    /// show. With a filter active the commands are disabled rather than
    /// silently reordering rows the user cannot see.
    var canReorderSelectedEntries: Bool {
        !isEditingText && !isEditingNote && !selectedEntryIDs.isEmpty && !isFilterActive
    }

    /// Moves the whole selection by one step, or to an edge, preserving the
    /// relative order of the selected entries.
    func reorderSelected(_ command: ItemMoveCommand) {
        guard canReorderSelectedEntries, let tab = selectedTab else { return }
        let order = entries.map(\.id)
        let pinned = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.pinned) })
        let newOrder = ItemReorderPolicy.reorder(
            order: order,
            pinned: pinned,
            selection: selectedEntryIDs,
            command: command
        )
        guard newOrder != order else { return }
        do {
            try history.reorder(tabID: tab.id, order: newOrder)
            reload()
        } catch {
            reportFailure("Could not reorder the items: \(error)")
        }
    }

    func canMoveSelection(toTabID tabID: Int64) -> Bool {
        guard !isEditingText, !isEditingNote, !selectedEntryIDs.isEmpty else { return false }
        guard tabID != selectedTabID else { return false }
        return tabs.contains { $0.id == tabID }
    }

    /// Moves every selected entry to another tab. Sync groups are rewritten or
    /// trashed by `CopyQSyncRelocation`; the confirmation appears only when
    /// that work would touch files.
    func moveSelection(toTabID tabID: Int64) {
        guard canMoveSelection(toTabID: tabID) else { return }
        guard let destination = tabs.first(where: { $0.id == tabID }) else { return }
        let victims = selectedEntriesInDisplayOrder
        guard !victims.isEmpty else { return }

        let plan = CopyQSyncRelocation.plan(
            entries: victims,
            to: destination,
            in: history.store
        )
        if let reason = plan.blockingReason {
            reportFailure(reason)
            return
        }
        if plan.requiresConfirmation,
           let confirmSyncMove,
           !confirmSyncMove(plan, destination, preferences.language)
        {
            return
        }

        do {
            let report = try history.move(ids: victims.map(\.id), toTabID: tabID)
            let language = preferences.language
            if report.failures.isEmpty {
                notice = report.summary(language: language)
            } else {
                reportFailure([report.summary(language: language)] + report.failures)
            }
            reload()
        } catch {
            reportFailure("Could not move the items to \u{201C}\(destination.name)\u{201D}: \(error.localizedDescription)")
        }
    }

    private var isFilterActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The plain-text representation of one entry, derived once.
    ///
    /// Menu validation runs on every menu open and every key equivalent, so the
    /// derivation (which may decompress and strip a large rich payload) is
    /// memoised for the selected entry. An entry's stored flavours never change,
    /// so the id is enough to key it.
    private var plainTextMemo: (entryID: Int64, text: String?)?

    /// The text Paste as Plain Text would paste, or nil when the entry has none.
    ///
    /// This is the single source of truth for both the menu item's enabled
    /// state and the action, so they cannot disagree.
    func selectedEntryPlainText() -> String? {
        guard canActOnSelectedEntry, let entry = selectedEntry else { return nil }
        if let memo = plainTextMemo, memo.entryID == entry.id { return memo.text }
        let text = FlavourDecoder.plainTextRepresentation(from: entry.flavours)
        plainTextMemo = (entry.id, text)
        return text
    }

    /// Whether the selected entry carries non-empty text that Paste as Plain
    /// Text could paste.
    var canPasteSelectedAsPlainText: Bool {
        guard let text = selectedEntryPlainText() else { return false }
        return !text.isEmpty
    }

    /// The global Paste as Plain Text shortcut.
    ///
    /// It deliberately does not rely on the app-local menu key equivalent:
    /// while the user is in another app that keystroke never reaches CopyQmac.
    /// With the main window open the selected item is pasted; otherwise the
    /// live clipboard is stripped to text and pasted into the app in front.
    func pastePlainTextFromGlobalShortcut(
        windowIsVisible: Bool,
        frontmostApp: NSRunningApplication?,
        dismiss: @escaping () -> Void,
        showNotice: @escaping () -> Void = {}
    ) {
        switch PlainTextPasteSource.choose(
            windowIsVisible: windowIsVisible,
            hasSelectedEntry: selectedEntry != nil
        ) {
        case .selectedEntry:
            pasteSelectedAsPlainText(dismiss: dismiss)
        case .clipboard:
            guard let pasteService else { return }
            // If CopyQmac itself is frontmost (for example after its window was
            // closed), the paste target is the remembered previous app and has
            // to be activated. Otherwise the user's app is already in front and
            // we post Command-V into it without stealing focus.
            let frontmostIsSelf = frontmostApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            let target = frontmostIsSelf ? nil : frontmostApp
            pasteService.pasteCurrentClipboardAsPlainText(
                target: target,
                activateTarget: target == nil,
                completion: { [weak self] outcome in
                    guard let self else { return }
                    if self.handlePasteOutcome(outcome) { dismiss() }
                    // The window is hidden in this path, so a notice nobody can
                    // see would be useless. Bring it up only when the paste did
                    // not happen and there is something to explain.
                    if self.notice != nil { showNotice() }
                }
            )
        }
    }

    /// Updates the Preferences hint for the plain-text global shortcut.
    func setPlainTextHotKeyProblem(_ problem: PlainTextHotKeyProblem?) {
        guard problem != plainTextHotKeyProblem else { return }
        plainTextHotKeyProblem = problem
    }

    /// Pastes only the selected entry's text, through the normal paste path.
    /// Invariant: entry operations do not act while editing a note.
    func pasteSelectedAsPlainText(dismiss: @escaping () -> Void) {
        guard !isEditingNote else { return }
        guard canPasteSelectedAsPlainText else {
            // The item stays enabled for such an entry so the key equivalent is
            // consumed and explains itself instead of turning into a system beep.
            reportFailure("Paste failed: \(PasteService.noPlainTextMessage)")
            return
        }
        guard let selectedEntryID,
              let entry = actionableEntry(id: selectedEntryID),
              let pasteService
        else { return }
        pasteService.pastePlainText(entry) { [weak self] outcome in
            guard let self else { return }
            // A plain-text paste is its own command, not an activation: it
            // closes the window when it arrives and leaves the item where it is.
            if self.handlePasteOutcome(outcome) { dismiss() }
        }
    }

    /// Shared outcome handling so every paste path reports exactly what
    /// happened.
    ///
    /// Returns whether the entry actually arrived in the other app. The
    /// activation pipeline uses that to decide about the steps after the paste:
    /// a delivery that did not happen must not close the window that is showing
    /// the notice, nor take focus away from it.
    ///
    /// Not private so the headless tests can drive the success path without
    /// activating an application or posting a real key event.
    @discardableResult
    func handlePasteOutcome(_ outcome: PasteOutcome) -> Bool {
        // The paste service records a posted Command-V as established trust; do
        // it here as well so a model driven by a different service keeps the
        // same rule.
        if case .pasted = outcome { trust.notePasteSucceeded() }
        // The permission can change while the paste is in flight - the system
        // prompt is asynchronous and the user may have granted it - so re-read
        // it before deciding what the UI says. This is not a user-return check,
        // so it cannot turn the notice into the stale-grant wording by itself.
        refreshAccessibilityStatus(afterUserAction: false)
        switch outcome {
        case .pasted:
            notice = nil
            return true
        case .copiedOnly:
            if !accessibilityGranted {
                notice = AccessibilityNoticePolicy.permissionNotice(grantLooksStale: trust.isStaleGrant)
            }
            return false
        case .copiedOnlyNoTarget:
            notice = "Copied to the clipboard. Open the target app and press \u{2318}V."
            return false
        case .failed(let message):
            reportFailure("Paste failed: \(message)")
            return false
        }
    }

    // MARK: - Accessibility

    /// Re-reads the permission state, for example after the user granted it in
    /// System Settings and came back to the app.
    ///
    /// A notice about the missing permission is stale once the app is trusted,
    /// so it is cleared here as well. Once a paste has posted its synthetic
    /// Command-V, trust stays established for the rest of the session and the
    /// notice stays retired across later activations. This check never prompts.
    func refreshAccessibilityStatus(afterUserAction: Bool = true) {
        let trusted = trust.refresh(afterUserAction: afterUserAction)
        accessibilityGranted = trusted
        notice = AccessibilityNoticePolicy.notice(
            current: notice,
            trusted: trusted,
            grantLooksStale: trust.isStaleGrant
        )
    }

    /// The status-bar affordance: ask macOS to show its dialog and open the pane
    /// where the app is listed. Never asks again once trust is established.
    func grantAccessibility() {
        trust.requestFromUser()
        PasteService.openAccessibilitySettings()
        refreshAccessibilityStatus()
    }

    // MARK: - Preferences

    /// Applies `transform`, stores the result, and notifies the app.
    func updatePreferences(_ transform: (inout Preferences) -> Void) {
        var updated = preferences
        transform(&updated)
        updated = updated.sanitized()
        guard updated != preferences else { return }
        let historyLimitChanged = updated.defaultMaxItems != preferences.defaultMaxItems
        let languageChanged = updated.language != preferences.language
        do {
            try history.setPreferences(updated)
        } catch {
            reportFailure("Could not save preferences: \(error)")
            return
        }
        preferences = updated
        onPreferencesChanged?(updated)
        if languageChanged {
            presentationCache.setLanguage(updated.language)
            rebuildRows()
            presentationRevision &+= 1
        }
        if historyLimitChanged { reload() }
    }

    func setSearchAllTabs(_ value: Bool) {
        updatePreferences { $0.searchAllTabs = value }
        reload()
    }

    /// Changes one History ▸ Activation switch. The switches are stored
    /// together with the other preferences, so the change survives a relaunch.
    func setActivation(_ transform: (inout ActivationOptions) -> Void) {
        updatePreferences { preferences in
            transform(&preferences.activation)
        }
    }

    // MARK: - Capture exclusions

    var observedSourceApplication: SourceApplication? {
        guard let app = sourceApplicationProvider?(),
              !app.bundleIdentifier.isEmpty,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            return nil
        }
        return app
    }

    func isCaptureExcluded(bundleIdentifier: String) -> Bool {
        CaptureExclusionPolicy(preferences: preferences)
            .shouldSkip(bundleIdentifier: bundleIdentifier)
    }

    /// Adds the last app observed as frontmost. That is normally the app the
    /// user copied from, even after switching to another app; the hint is
    /// UI-only and never takes part in the capture decision.
    @discardableResult
    func addObservedAppToCaptureExclusions() -> Bool {
        guard let app = observedSourceApplication else { return false }
        addCaptureExclusion(bundleIdentifier: app.bundleIdentifier, name: app.name)
        return true
    }

    func addCaptureExclusion(bundleIdentifier: String, name: String) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = CaptureExclusionRule(
            bundleIdentifier: identifier,
            name: label.isEmpty ? identifier : label
        )
        updatePreferences { preferences in
            if let index = preferences.captureExclusions.firstIndex(where: { $0.id == rule.id }) {
                preferences.captureExclusions[index].isEnabled = true
                if !label.isEmpty {
                    preferences.captureExclusions[index].name = rule.name
                }
            } else {
                preferences.captureExclusions.append(rule)
            }
        }
    }

    func setCaptureExclusionEnabled(_ rule: CaptureExclusionRule, _ enabled: Bool) {
        updatePreferences { preferences in
            guard let index = preferences.captureExclusions.firstIndex(where: { $0.id == rule.id })
            else { return }
            preferences.captureExclusions[index].isEnabled = enabled
        }
    }

    func removeCaptureExclusion(_ rule: CaptureExclusionRule) {
        updatePreferences { preferences in
            preferences.captureExclusions.removeAll { $0.id == rule.id }
        }
    }

    // MARK: - API-key guard

    /// The AI-service API-key guard on the same ignore-rules tab. The watcher
    /// reads it from the stored preferences before it records a capture, so the
    /// switch takes effect on the next clipboard change without a restart.
    func setAPIKeyGuardEnabled(_ enabled: Bool) {
        updatePreferences { $0.apiKeyGuardEnabled = enabled }
    }

    // MARK: - Launch at login

    /// Re-reads the real Login Items state. Called at launch, whenever the app
    /// becomes active (the user may have changed it in System Settings), and
    /// after every toggle.
    ///
    /// A failure is only retired when the refreshed state is the one the failed
    /// change asked for; a refresh that sees the old state keeps the reason.
    func refreshLaunchAtLoginState() {
        launchAtLogin = launchAtLoginService.state
        if let target = failedLaunchAtLoginTarget,
           launchAtLogin == (target ? LaunchAtLoginState.enabled : .disabled) {
            failedLaunchAtLoginTarget = nil
            launchAtLoginProblem = nil
            if LaunchAtLoginNotice.isFailureNotice(notice) { notice = nil }
        } else {
            notice = LaunchAtLoginNotice.notice(current: notice, state: launchAtLogin)
        }
    }

    /// Asks macOS to add or remove the app as a login item, then reports what
    /// actually happened. A failure leaves the previous registration alone and
    /// shows the system's reason instead of pretending the toggle changed.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
        } catch {
            refreshLaunchAtLoginState()
            let message = LaunchAtLoginNotice.failure(
                enabling: enabled,
                reason: error.localizedDescription
            )
            failedLaunchAtLoginTarget = enabled
            launchAtLoginProblem = message
            reportFailure(message)
            return
        }
        failedLaunchAtLoginTarget = nil
        launchAtLoginProblem = nil
        refreshLaunchAtLoginState()
        if notice == nil || LaunchAtLoginNotice.isLaunchAtLoginNotice(notice) {
            notice = LaunchAtLoginNotice.notice(for: launchAtLogin)
        }
    }

    /// Reports an action that did not happen.
    ///
    /// The message goes to three places with different lifetimes: the banner
    /// (a few seconds), the app log (kept by the system), and the status bar
    /// (until the user dismisses it). A failure the user was not looking at is
    /// therefore still findable afterwards instead of vanishing with the banner.
    func reportFailure(_ message: String) {
        reportFailure([message])
    }

    func reportFailure(_ messages: [String]) {
        let message = messages.joined(separator: " ")
        noticeLog(message)
        failureNoticeParts = messages
        showNotice(messages)
    }

    /// Shows a notice made from its clauses, so each clause is translated on
    /// its own instead of the joined record being looked up as one string.
    func showNotice(_ parts: [String]) {
        noticeParts = parts
        notice = parts.joined(separator: " ")
    }

    /// The status-bar record of a failure was clicked: it is read, so it goes.
    func dismissFailureNotice() {
        failureNoticeParts = []
    }

    /// The banner's close control: retires the banner and the launch-at-login
    /// reason at once instead of waiting for the timer. A failure record moves
    /// from the banner to the status bar and stays there until
    /// `dismissFailureNotice()`.
    func dismissNotice() {
        notice = nil
        launchAtLoginProblem = nil
        failedLaunchAtLoginTarget = nil
    }

    /// Replaces the banner's pending dismissal with one for the message that is
    /// on screen now. The previous timer is cancelled first, so messages replace
    /// each other instead of stacking and a retired timer cannot clear its
    /// replacement.
    private func scheduleNoticeDismissal() {
        noticeTimer?.cancel()
        noticeTimer = nil
        guard notice != nil else { return }
        noticeTimer = noticeTimers.schedule(after: max(0, NoticeTimer.standardDuration)) { [weak self] in
            guard let self else { return }
            self.noticeTimer = nil
            self.notice = nil
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    // MARK: - Sync Write-Back and Watch

    public let syncWriter = CopyQSyncWriter.shared
    public let syncWatcher = CopyQSyncWatcher.shared

    func handleCapturedEntry(_ entry: ClipboardEntry) {
        syncWriter.enqueue(entry: entry, store: history.store, reason: "capture")
    }

    func setSyncPaused(_ value: Bool) {
        updatePreferences { $0.syncPaused = value }
        syncWatcher.updateConfiguration(store: history.store)
    }

    func toggleSyncPause() {
        updatePreferences { $0.syncPaused.toggle() }
        syncWatcher.updateConfiguration(store: history.store)
    }

    // MARK: - Sync reconciliation and trash

    func tab(id: Int64) -> ClipboardTab? {
        tabs.first { $0.id == id } ?? (try? history.store.tab(id: id))
    }

    func requestResyncTab(_ tabID: Int64) {
        onResyncTabRequest?(tabID)
    }

    /// The tab context menu's write-back command, which needs no menu-item
    /// sender to carry the tab id.
    func requestWriteBackTab(_ tabID: Int64) {
        onWriteBackTabRequest?(tabID)
    }

    @discardableResult
    func applyResync(_ plan: CopyQSyncResyncPlan) throws -> CopyQSyncResyncResult {
        let result = try CopyQSyncResync.apply(
            plan,
            in: history.store,
            trashRoot: history.syncTrashRoot,
            watcher: syncWatcher,
            language: preferences.language
        )
        invalidateAllCachedEntries()
        reload()
        return result
    }

    func syncReconciliationReport() throws -> CopyQSyncReconciliationReport {
        try CopyQSyncReconciliation.report(in: history.store)
    }

    @discardableResult
    func reconcileSyncFolders(
        _ report: CopyQSyncReconciliationReport
    ) throws -> CopyQSyncReconciliationResult {
        let result = try CopyQSyncReconciliation.apply(
            report,
            in: history.store,
            trashRoot: history.syncTrashRoot
        )
        invalidateAllCachedEntries()
        reload()
        return result
    }

    func syncTrashSummary() throws -> CopyQSyncTrashSummary {
        try CopyQSyncTrash.summary(trashRoot: history.syncTrashRoot)
    }

    @discardableResult
    func emptySyncTrash() throws -> CopyQSyncTrashSummary {
        let folders = try history.tabs().compactMap(\.syncFolder)
        return try CopyQSyncTrash.empty(
            trashRoot: history.syncTrashRoot,
            syncFolders: folders
        )
    }

    // MARK: - Row rendering

    /// The cached layout data for a row. On a miss the work is scheduled off the
    /// main thread and the view draws a placeholder until the next revision.
    func presentation(for entry: ClipboardEntry) -> EntryPresentation? {
        if let cached = presentationCache.presentation(for: entry.id) {
            let needsSelectedPreview: Bool
            switch cached.kind {
            case .files:
                needsSelectedPreview = cached.fileURLs.isEmpty
            case .text, .html, .rtf:
                needsSelectedPreview = cached.searchText == nil
            case .image, .other:
                needsSelectedPreview = false
            }
            if entry.id == selectedEntryID, needsSelectedPreview {
                requestSelectedPreview(for: entry)
            }
            return cached
        }
        requestPresentation(for: entry)
        return nil
    }

    /// The parsed rich content for an entry, or nil while it is read on the
    /// main thread. Like `presentation(for:)`, this is a cache lookup; a miss
    /// schedules the read and returns nil for the current frame.
    func richText(for entry: ClipboardEntry) -> RichTextPresentation? {
        if let cached = richTextCache.presentation(for: entry.id) {
            return cached
        }
        if failedRichTextIDs.contains(entry.id) {
            return nil
        }
        guard RichTextBuilder.hasRichFlavour(entry.flavours) else {
            return nil
        }
        if entry.id == selectedEntryID {
            return parseRichText(for: entry)
        } else {
            requestRichText(for: entry)
            return nil
        }
    }

    @discardableResult
    private func parseRichText(for entry: ClipboardEntry) -> RichTextPresentation? {
        if let cached = richTextCache.presentation(for: entry.id) {
            return cached
        }
        if failedRichTextIDs.contains(entry.id) {
            return nil
        }
        pendingRichTextIDs.removeAll { $0 == entry.id }
        let parsed = RichTextBuilder.parse(from: entry.flavours, appearance: richTextAppearance)
        richTextCache.store(parsed, for: entry)
        if parsed == nil {
            failedRichTextIDs.insert(entry.id)
        } else {
            failedRichTextIDs.remove(entry.id)
        }
        refreshRow(entry.id)
        presentationRevision &+= 1
        return parsed?.presentation
    }

    private func requestRichText(for entry: ClipboardEntry) {
        guard RichTextBuilder.hasRichFlavour(entry.flavours),
              richTextCache.presentation(for: entry.id) == nil,
              !failedRichTextIDs.contains(entry.id),
              !pendingRichTextIDs.contains(entry.id)
        else { return }
        if entry.id == selectedEntryID {
            parseRichText(for: entry)
            return
        }
        pendingRichTextIDs.append(entry.id)
        scheduleRichTextBatch()
    }

    private func scheduleRichTextBatch() {
        guard !isProcessingRichText, !pendingRichTextIDs.isEmpty else { return }
        isProcessingRichText = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isProcessingRichText = false
            self.processNextRichTextBatch()
        }
    }

    private func processNextRichTextBatch() {
        guard !pendingRichTextIDs.isEmpty else { return }
        let candidateID = pendingRichTextIDs.removeFirst()
        if let entry = entries.first(where: { $0.id == candidateID }) {
            parseRichText(for: entry)
        }
        if !pendingRichTextIDs.isEmpty {
            scheduleRichTextBatch()
        }
    }

    /// Switches the rich renditions to the current appearance. The parsed
    /// documents are reused, so the payload is not read again.
    func applyRichTextAppearance(_ appearance: RichTextAppearance) {
        guard appearance != richTextAppearance else { return }
        richTextAppearance = appearance
        richTextCache.retarget(to: appearance)
        rebuildRows()
        presentationRevision &+= 1
    }

    // MARK: - Row models

    /// Builds the row models for the current entries.
    ///
    /// Only cache lookups happen here: no decoding, no store access, no work
    /// that could stall a scroll or a selection change.
    private func rebuildRows() {
        rows = entries.enumerated().map { index, entry in
            makeRow(for: entry, number: index + 1)
        }
        rowsRevision &+= 1
    }

    private func makeRow(for entry: ClipboardEntry, number: Int) -> EntryRow {
        let presentation = presentationCache.presentation(for: entry.id)
        var icon: NSImage?
        if presentation?.kind == .files, let path = presentation?.fileIconPath {
            icon = fileIconCache.object(forKey: path as NSString)
        }
        return EntryRow(
            id: entry.id,
            number: number,
            kind: presentation?.kind,
            primaryText: presentation?.primaryText,
            richText: richTextCache.presentation(for: entry.id)?.row,
            fileNames: presentation?.fileNames ?? [],
            fileCount: presentation?.fileCount ?? 0,
            relativeTime: presentation?.relativeTime ?? "",
            pinned: entry.pinned,
            hasNote: !entry.note.isEmpty,
            icon: icon
        )
    }

    /// Replaces one row after its background presentation or thumbnail arrived.
    private func refreshRow(_ entryID: Int64) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var updated = rows
        guard updated.indices.contains(index) else { return }
        updated[index] = makeRow(for: entries[index], number: index + 1)
        rows = updated
        rowsRevision &+= 1
    }

    private func refreshRowsWithFileIcon(path: String) {
        guard !rows.isEmpty else { return }
        var updated = rows
        var changed = false
        for index in updated.indices {
            guard presentationCache.presentation(for: entries[index].id)?.fileIconPath == path,
                  updated[index].icon == nil
            else { continue }
            updated[index] = makeRow(for: entries[index], number: index + 1)
            changed = true
        }
        if changed {
            rows = updated
            rowsRevision &+= 1
        }
    }

    /// Called by the list when a cell is realized. Schedules the un-cached work
    /// for the rows the user can actually see, instead of for every entry in
    /// the history.
    func ensureRowContent(for entryID: Int64) {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        if let presentation = presentationCache.presentation(for: entryID) {
            if presentation.kind == .image,
               thumbnailCache.thumbnail(for: entryID, maxPixelSize: Self.rowThumbnailMaxPixelSize) == nil
            {
                requestThumbnail(for: entry, maxPixelSize: Self.rowThumbnailMaxPixelSize)
            }
            if presentation.kind == .files, let path = presentation.fileIconPath {
                _ = fileIcon(forPath: path)
            }
            if presentation.kind == .html || presentation.kind == .rtf,
               richTextCache.presentation(for: entryID) == nil,
               !failedRichTextIDs.contains(entryID)
            {
                requestRichText(for: entry)
            }
        } else {
            requestPresentation(for: entry)
        }
    }

    /// A cached row thumbnail, or nil while it is decoded in the background.
    /// The lookup is by entry id and pixel bound; no fingerprint is involved.
    func thumbnail(for entry: ClipboardEntry, maxSize: CGFloat) -> NSImage? {
        let maxPixelSize = max(1, Int((maxSize * 2).rounded()))
        return cachedThumbnail(for: entry, maxPixelSize: maxPixelSize)
    }

    /// The 34 pt row image slot reads the byte-budgeted cache on every render
    /// instead of retaining decoded pixels in the row model.
    func rowThumbnail(for entryID: Int64) -> NSImage? {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return nil }
        return cachedThumbnail(for: entry, maxPixelSize: Self.rowThumbnailMaxPixelSize)
    }

    private func cachedThumbnail(for entry: ClipboardEntry, maxPixelSize: Int) -> NSImage? {
        guard let presentation = presentationCache.presentation(for: entry.id) else {
            requestPresentation(for: entry)
            return nil
        }
        guard presentation.kind == .image else { return nil }
        guard let image = thumbnailCache.thumbnail(for: entry.id, maxPixelSize: maxPixelSize) else {
            requestThumbnail(for: entry, maxPixelSize: maxPixelSize)
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// File icons are looked up by path, once, so repeated layout passes do not
    /// ask LaunchServices again. The first frame draws the generic fallback.
    func fileIcon(forPath path: String) -> NSImage? {
        if let cached = fileIconCache.object(forKey: path as NSString) { return cached }
        if pendingFileIcons.insert(path).inserted {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingFileIcons.remove(path)
                let icon = NSWorkspace.shared.icon(forFile: path)
                self.fileIconCache.setObject(icon, forKey: path as NSString)
                self.refreshRowsWithFileIcon(path: path)
                self.presentationRevision &+= 1
            }
        }
        return nil
    }

    private func requestPresentation(for entry: ClipboardEntry) {
        guard !pendingPresentationIDs.contains(entry.id) else { return }
        pendingPresentationIDs.insert(entry.id)
        let token = presentationToken(for: entry.id)
        let snapshot = entry
        pendingPresentationVersions[entry.id] = EntryVersion(snapshot)
        let retainFullPreviewData = snapshot.id == selectedEntryID
        let thumbnailPixelSize = Self.rowThumbnailMaxPixelSize
        let presentationLanguage = presentationCache.language
        presentationQueue.addOperation { [weak self] in
            let preview = FlavourDecoder.preview(for: snapshot.flavours)
            let rowThumbnail = preview.imageData.flatMap {
                ThumbnailCache.decodeThumbnail(from: $0, maxPixelSize: thumbnailPixelSize)
            }
            let presentation = EntryPresentation(
                entry: snapshot,
                preview: preview,
                retainFullPreviewData: retainFullPreviewData,
                language: presentationLanguage
            )
            let cachedPresentation = retainFullPreviewData
                ? presentation
                : presentation.discardingFullPreviewData()
            Task { @MainActor [weak self] in
                guard let self, self.latestPresentationToken[snapshot.id] == token else { return }
                self.pendingPresentationIDs.remove(snapshot.id)
                self.pendingPresentationVersions.removeValue(forKey: snapshot.id)
                var presentationToStore = snapshot.id == self.selectedEntryID
                    ? cachedPresentation
                    : cachedPresentation.discardingFullPreviewData()
                if presentationToStore.language != self.presentationCache.language {
                    presentationToStore = presentationToStore.refreshingRelativeTime(language: self.presentationCache.language)
                }
                self.presentationCache.store(presentationToStore, for: snapshot)
                if presentationToStore.kind == .html || presentationToStore.kind == .rtf {
                    if snapshot.id == self.selectedEntryID {
                        self.parseRichText(for: snapshot)
                    } else {
                        self.requestRichText(for: snapshot)
                    }
                }
                if let rowThumbnail {
                    self.thumbnailCache.store(
                        rowThumbnail,
                        for: snapshot.id,
                        maxPixelSize: thumbnailPixelSize
                    )
                }
                self.refreshRow(snapshot.id)
                self.presentationRevision &+= 1
                self.retirePresentationTokenIfIdle(snapshot.id)
                if snapshot.id == self.selectedEntryID,
                   presentationToStore.kind == .image,
                   self.selectedPreviewImage == nil
                {
                    self.requestSelectedPreviewImage()
                }
            }
        }
    }

    private func requestSelectedPreview(for entry: ClipboardEntry) {
        guard entry.id == selectedEntryID,
              !pendingSelectedPreviewIDs.contains(entry.id)
        else { return }
        pendingSelectedPreviewIDs.insert(entry.id)
        let token = presentationToken(for: entry.id)
        let snapshot = entry
        presentationQueue.addOperation { [weak self] in
            let preview = FlavourDecoder.preview(for: snapshot.flavours)
            let searchText = preview.kind == .files ? nil : (preview.searchText ?? preview.text ?? "")
            let lineCount = EntryPresentation.lineCount(of: searchText, kind: preview.kind)
            let fileURLs = preview.fileURLs
            Task { @MainActor [weak self] in
                guard let self, self.latestPresentationToken[snapshot.id] == token else { return }
                self.pendingSelectedPreviewIDs.remove(snapshot.id)
                if self.selectedEntryID == snapshot.id {
                    _ = self.presentationCache.storeSelectedPreview(
                        searchText: searchText,
                        fileURLs: fileURLs,
                        lineCount: lineCount,
                        for: snapshot.id
                    )
                    self.presentationRevision &+= 1
                }
                self.retirePresentationTokenIfIdle(snapshot.id)
            }
        }
    }

    private func requestThumbnail(for entry: ClipboardEntry, maxPixelSize: Int) {
        let key = ThumbnailCache.Key(entryID: entry.id, maxPixelSize: maxPixelSize)
        guard !pendingThumbnailKeys.contains(key), failedThumbnailKeys.value(for: key) == nil else { return }
        let token = presentationToken(for: entry.id)
        pendingThumbnailKeys.insert(key)
        let snapshot = entry
        presentationQueue.addOperation { [weak self] in
            let data = FlavourDecoder.preview(for: snapshot.flavours).imageData
            let image = data.flatMap {
                ThumbnailCache.decodeThumbnail(from: $0, maxPixelSize: maxPixelSize)
            }
            Task { @MainActor [weak self] in
                guard let self, self.latestPresentationToken[entry.id] == token else { return }
                self.pendingThumbnailKeys.remove(key)
                if let image {
                    self.thumbnailCache.store(image, for: entry.id, maxPixelSize: maxPixelSize)
                    if self.isWindowVisible {
                        self.refreshRow(entry.id)
                        self.presentationRevision &+= 1
                    }
                } else {
                    self.failedThumbnailKeys.insert(true, for: key)
                }
                self.retirePresentationTokenIfIdle(entry.id)
            }
        }
    }

    private func invalidateCachedEntry(_ entryID: Int64) {
        invalidateCachedEntries([entryID])
    }

    private func invalidateCachedEntries(_ entryIDs: Set<Int64>) {
        guard !entryIDs.isEmpty else { return }
        for entryID in entryIDs {
            latestPresentationToken.removeValue(forKey: entryID)
            pendingPresentationIDs.remove(entryID)
            pendingPresentationVersions.removeValue(forKey: entryID)
            pendingSelectedPreviewIDs.remove(entryID)
        }
        presentationCache.invalidate(entryIDs: entryIDs)
        thumbnailCache.invalidate(entryIDs: entryIDs)
        richTextCache.invalidate(entryIDs: entryIDs)
        failedRichTextIDs.subtract(entryIDs)
        pendingRichTextIDs.removeAll { entryIDs.contains($0) }
        pendingThumbnailKeys = pendingThumbnailKeys.filter { !entryIDs.contains($0.entryID) }
        failedThumbnailKeys.removeValues { entryIDs.contains($0.entryID) }
        presentationRevision &+= 1
    }

    private func invalidateAllCachedEntries() {
        presentationCache.removeAll()
        thumbnailCache.removeAll()
        richTextCache.removeAll()
        failedRichTextIDs.removeAll()
        pendingRichTextIDs.removeAll()
        clearSelectedImagePreview()
        pendingPresentationIDs.removeAll()
        pendingPresentationVersions.removeAll()
        pendingSelectedPreviewIDs.removeAll()
        pendingThumbnailKeys.removeAll()
        failedThumbnailKeys.removeAll()
        latestPresentationToken.removeAll()
        presentationRevision &+= 1
    }

    /// Drops caches for visible entries whose stored payload changed.
    private func synchronizeCachedEntries(with visibleEntries: [ClipboardEntry]) {
        var invalidated = presentationCache.synchronize(with: visibleEntries)
        invalidated.formUnion(richTextCache.synchronize(with: visibleEntries))
        for entry in visibleEntries {
            if let version = pendingPresentationVersions[entry.id], version != EntryVersion(entry) {
                invalidated.insert(entry.id)
            }
        }
        invalidateCachedEntries(invalidated)
    }

    private func presentationToken(for entryID: Int64) -> Int {
        if let token = latestPresentationToken[entryID] { return token }
        nextPresentationToken &+= 1
        latestPresentationToken[entryID] = nextPresentationToken
        return nextPresentationToken
    }

    private func retirePresentationTokenIfIdle(_ entryID: Int64) {
        guard !pendingPresentationIDs.contains(entryID),
              !pendingSelectedPreviewIDs.contains(entryID),
              !pendingThumbnailKeys.contains(where: { $0.entryID == entryID })
        else { return }
        latestPresentationToken.removeValue(forKey: entryID)
    }

    private func startRelativeTimeRefresh() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.presentationCache.refreshRelativeTimes() {
                    self.rebuildRows()
                    self.presentationRevision &+= 1
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        relativeTimeTimer = timer
    }

    // MARK: - Selected Preview Image & Window Lifecycle

    func clearSelectedImagePreview() {
        selectedPreviewToken &+= 1
        selectedPreviewOperation?.cancel()
        selectedPreviewOperation = nil
        selectedPreviewImage = nil
    }

    func requestSelectedPreviewImage() {
        guard let entry = selectedEntry else {
            clearSelectedImagePreview()
            return
        }
        selectedPreviewToken &+= 1
        let token = selectedPreviewToken
        selectedPreviewOperation?.cancel()
        let snapshot = entry
        let previewPixelSize = Self.previewMaxPixelSize
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let preview = FlavourDecoder.preview(for: snapshot.flavours)
            guard preview.kind == .image, let data = preview.imageData else { return }
            guard !operation.isCancelled else { return }
            guard let cgImage = ThumbnailCache.decodeThumbnail(from: data, maxPixelSize: previewPixelSize) else {
                return
            }
            guard !operation.isCancelled else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            Task { @MainActor [weak self] in
                guard let self,
                      self.selectedPreviewToken == token,
                      self.selectedEntryID == snapshot.id,
                      self.isWindowVisible
                else {
                    return
                }
                self.selectedPreviewImage = image
            }
        }
        selectedPreviewOperation = operation
        presentationQueue.addOperation(operation)
    }

    func windowDidHide() {
        isWindowVisible = false
        clearSelectedImagePreview()
        idleTimer?.cancel()
        malloc_zone_pressure_relief(nil, 0)
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.isWindowVisible else { return }
            self.thumbnailCache.removeAll()
            self.richTextCache.removeAll()
            self.failedRichTextIDs.removeAll()
            self.pendingRichTextIDs.removeAll()
            self.rebuildRows()
            malloc_zone_pressure_relief(nil, 0)
        }
        idleTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timer)
    }

    func windowDidShow() {
        isWindowVisible = true
        idleTimer?.cancel()
        idleTimer = nil
        rebuildRows()
        requestSelectedPreviewImage()
    }

#if COPYQMAC_TESTING
    var failedRichTextIDsForTesting: Set<Int64> { failedRichTextIDs }

    func triggerIdlePurgeForTesting() {
        idleTimer?.cancel()
        idleTimer = nil
        thumbnailCache.removeAll()
        richTextCache.removeAll()
        failedRichTextIDs.removeAll()
        pendingRichTextIDs.removeAll()
        rebuildRows()
    }
#endif
}

// MARK: - Backup export status

/// Status-bar wording for a backup export in flight.
///
/// Kept out of `AppModel` so the background export can format its progress
/// without touching the main actor.
enum BackupExportStatus {
    static func text(
        for progress: CopyQSyncBridge.ExportProgress,
        language: AppLanguage = .english
    ) -> String {
        let current = formatted(progress.exportedItems)
        let total = formatted(progress.totalItems)
        let items = Localization.format(.statusBarExportingItems, language: language, current, total)
        guard progress.tabCount > 1 else {
            return Localization.format(.statusBarExportingTab, language: language, progress.tabName, items)
        }
        return Localization.format(
            .statusBarExportingMultiTab,
            language: language,
            progress.tabIndex,
            progress.tabCount,
            progress.tabName,
            items
        )
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
