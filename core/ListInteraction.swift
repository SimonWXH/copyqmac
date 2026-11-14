// Interaction rules for the item list: which keys the window handles while a
// text editor has the keyboard, what has to happen around a selection change,
// and which row the list has to bring on screen.
//
// These rules live in the core, with no AppKit, so they can be tested
// headlessly. The UI is a thin adapter over them: `WindowKeyMonitor` maps a
// key event to a `ListKey` and asks `ListInteractionPolicy`, `AppModel` applies
// `SelectionChangePolicy`, and `EntryListView` asks `SelectionRevealPolicy`
// which row to scroll to.

import Foundation

// MARK: - Keys

/// The list-navigation keys the main window understands.
public enum ListKey: Equatable, Sendable {
    case up
    case down
    case pageUp
    case pageDown
    case home
    case end
    case enter
    case escape
    case delete
}

public enum ListFocus: Equatable, Sendable {
    /// Nothing in the window owns the keyboard.
    case none
    /// The filter field is being edited.
    case filter
    /// The clipboard item list owns the keyboard.
    case itemList
    /// The tab sidebar owns the keyboard.
    case sidebar
}

public enum ListInteractionPolicy {
    /// Keys that must always move the selection, whatever has keyboard focus.
    ///
    /// This is what unblocks the list when the note editor is focused: without
    /// it, the arrows and Page/Home/End never reach the list and the focused
    /// `PlainTextEditor` holds the selection hostage. The sidebar keeps Up and
    /// Down for its list, while Page/Home/End reach this rule so the window can
    /// move its tab selection.
    public static func alwaysMovesSelection(_ key: ListKey) -> Bool {
        switch key {
        case .up, .down, .pageUp, .pageDown, .home, .end: return true
        case .enter, .escape, .delete: return false
        }
    }

    /// Whether a held-down key must be ignored instead of repeating its action.
    ///
    /// Holding Return, Escape, or Delete must not queue several pastes, closes,
    /// or deletions, while holding an arrow key still scrolls the selection.
    public static func ignoresKeyRepeat(_ key: ListKey) -> Bool {
        switch key {
        case .enter, .escape, .delete: return true
        case .up, .down, .pageUp, .pageDown, .home, .end: return false
        }
    }

    /// Whether the window should act on `key`.
    ///
    /// While the note editor is focused, only selection movement is taken from
    /// the editor: Return has to insert a newline and Backspace has to keep
    /// deleting characters, so those stay with the `PlainTextEditor`. Escape ends
    /// note editing rather than hiding the window, which is handled by the
    /// caller through `ListKey.escape`.
    ///
    /// Movement, Return, and Escape work from the filter and the item list, so a
    /// click that ends note editing cannot leave the list unable to move. Delete
    /// is the one destructive key, so it needs the filter or the list to have
    /// focus.
    ///
    /// A focused sidebar keeps Up/Down and Return for the tab list, while
    /// Page/Home/End are handled by the window so they move the tab selection
    /// instead of only scrolling it. Note editing takes precedence, because the
    /// focused `PlainTextEditor` owns the keyboard even if the sidebar still
    /// records that it was focused.
    public static func handles(
        _ key: ListKey,
        noteEditing: Bool,
        searchEmpty: Bool,
        commandHeld: Bool = false,
        focus: ListFocus = .itemList
    ) -> Bool {
        if focus == .sidebar, !noteEditing {
            switch key {
            case .up, .down, .enter:
                return false
            case .pageUp, .pageDown, .home, .end:
                return true
            case .escape, .delete:
                break
            }
        }
        if alwaysMovesSelection(key) { return true }
        if noteEditing {
            // Escape leaves the note editor; Return and Backspace edit text.
            return key == .escape
        }
        switch key {
        case .enter, .escape:
            return true
        case .delete:
            // Backspace keeps editing the filter; it means "delete the selected
            // item" only once the filter is empty or with Command held.
            let itemContextFocused = focus == .filter || focus == .itemList
            return itemContextFocused && (searchEmpty || commandHeld)
        case .up, .down, .pageUp, .pageDown, .home, .end:
            return true
        }
    }
}

// MARK: - Selection changes

public enum CaptureSelectionPolicy {
    public static func selectedEntryID(
        current: Int64?,
        captured: Int64?,
        previousVisibleEntryIDs: [Int64],
        visibleEntryIDs: [Int64],
        filterActive: Bool
    ) -> Int64? {
        if !filterActive, let captured, visibleEntryIDs.contains(captured) {
            return captured
        }
        if let current, visibleEntryIDs.contains(current) {
            return current
        }
        guard let current, let oldIndex = previousVisibleEntryIDs.firstIndex(of: current) else {
            return visibleEntryIDs.first
        }
        for distance in 1..<previousVisibleEntryIDs.count {
            let earlier = oldIndex - distance
            if previousVisibleEntryIDs.indices.contains(earlier),
               visibleEntryIDs.contains(previousVisibleEntryIDs[earlier])
            {
                return previousVisibleEntryIDs[earlier]
            }
            let later = oldIndex + distance
            if previousVisibleEntryIDs.indices.contains(later),
               visibleEntryIDs.contains(previousVisibleEntryIDs[later])
            {
                return previousVisibleEntryIDs[later]
            }
        }
        return visibleEntryIDs.first
    }
}

public struct NoteDraftBuffer: Equatable, Sendable {
    private var drafts: [Int64: String] = [:]

    public init() {}

    public var isEmpty: Bool { drafts.isEmpty }

    public func draft(for entryID: Int64) -> String? { drafts[entryID] }

    public mutating func set(_ draft: String, for entryID: Int64) {
        drafts[entryID] = draft
    }

    public mutating func commit(using persist: (Int64, String) -> String?) -> String? {
        let snapshot = drafts.sorted { $0.key < $1.key }
        var failures: [String] = []
        for (entryID, draft) in snapshot {
            if let failure = persist(entryID, draft) {
                failures.append(failure)
            } else {
                drafts.removeValue(forKey: entryID)
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }
}

public struct NoteEditingSession: Equatable, Sendable {
    public enum ResultsReason: Equatable, Sendable {
        case refresh(capturedEntryID: Int64?)
        /// The selection changed. The visible entries are already in memory, so
        /// the store is not read again and the list is not rebuilt.
        case selectionOnly(selected: Int64?)
        case first
        case beginEditing
        case finishEditing
        case draftChanged(Int64)
        case eviction(entryIDs: [Int64], fromCapture: Bool)
    }

    public struct Transition: Equatable, Sendable {
        public let selectedEntryID: Int64?
        public let endedEditing: Bool
        public let notice: String?
        public let preserveCaptureSelection: Bool

        public init(
            selectedEntryID: Int64?,
            endedEditing: Bool,
            notice: String?,
            preserveCaptureSelection: Bool = false
        ) {
            self.selectedEntryID = selectedEntryID
            self.endedEditing = endedEditing
            self.notice = notice
            self.preserveCaptureSelection = preserveCaptureSelection
        }
    }

    public struct AppliedResults<Entry> {
        public let entries: [Entry]
        public let transition: Transition
    }

    public private(set) var entryID: Int64?
    public var isEditing: Bool { entryID != nil }

    public init() {}

    public mutating func applyResults<Entry>(
        reason: ResultsReason,
        currentSelectionID: Int64?,
        previousVisibleEntryIDs: [Int64],
        filterActive: Bool,
        commitDraft: () -> String?,
        load: () throws -> [Entry],
        entryIDFor: (Entry) -> Int64
    ) rethrows -> AppliedResults<Entry> {
        let saveFailure = commitDraft()
        // A selection change reads nothing: the entries are already in
        // memory, and reading them again would make a click as slow as a
        // store reload.
        let isSelectionOnly: Bool
        if case .selectionOnly = reason { isSelectionOnly = true } else { isSelectionOnly = false }
        let loadedEntries: [Entry] = isSelectionOnly ? [] : try load()
        let visibleEntryIDs = isSelectionOnly ? previousVisibleEntryIDs : loadedEntries.map(entryIDFor)
        var endedEditing = false
        var notice: String?
        var preserveCaptureSelection = false
        let selectedEntryID: Int64?

        switch reason {
        case .refresh(let capturedEntryID):
            if let editingID = entryID {
                if visibleEntryIDs.contains(editingID) {
                    selectedEntryID = editingID
                } else {
                    self.entryID = nil
                    endedEditing = true
                    selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                        current: editingID,
                        captured: nil,
                        previousVisibleEntryIDs: previousVisibleEntryIDs,
                        visibleEntryIDs: visibleEntryIDs,
                        filterActive: filterActive
                    )
                    notice = Self.notice(for: "the current results", saveFailure: saveFailure)
                }
            } else {
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: currentSelectionID,
                    captured: capturedEntryID,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
            }
        case .selectionOnly(let requestedID):
            let selectionPlan = SelectionChangePolicy.plan(
                current: currentSelectionID,
                next: requestedID,
                noteEditing: isEditing
            )
            if let editingID = entryID {
                if !visibleEntryIDs.contains(editingID) {
                    self.entryID = nil
                    endedEditing = true
                    notice = Self.notice(for: "the current results", saveFailure: saveFailure)
                    if let requestedID, visibleEntryIDs.contains(requestedID) {
                        selectedEntryID = requestedID
                    } else {
                        selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                            current: editingID,
                            captured: nil,
                            previousVisibleEntryIDs: previousVisibleEntryIDs,
                            visibleEntryIDs: visibleEntryIDs,
                            filterActive: filterActive
                        )
                    }
                } else if requestedID == editingID, selectionPlan?.blurNote != true {
                    selectedEntryID = editingID
                } else {
                    self.entryID = nil
                    endedEditing = true
                    if let requestedID, visibleEntryIDs.contains(requestedID) {
                        selectedEntryID = requestedID
                    } else if requestedID == nil {
                        selectedEntryID = nil
                    } else {
                        selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                            current: currentSelectionID,
                            captured: nil,
                            previousVisibleEntryIDs: previousVisibleEntryIDs,
                            visibleEntryIDs: visibleEntryIDs,
                            filterActive: filterActive
                        )
                    }
                }
            } else if let requestedID, visibleEntryIDs.contains(requestedID) {
                selectedEntryID = requestedID
            } else if requestedID == nil {
                selectedEntryID = nil
            } else {
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: currentSelectionID,
                    captured: nil,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
            }
        case .first:
            if let editingID = entryID {
                if visibleEntryIDs.contains(editingID) {
                    selectedEntryID = editingID
                } else {
                    self.entryID = nil
                    endedEditing = true
                    notice = Self.notice(for: "the current results", saveFailure: saveFailure)
                    selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                        current: editingID,
                        captured: nil,
                        previousVisibleEntryIDs: previousVisibleEntryIDs,
                        visibleEntryIDs: visibleEntryIDs,
                        filterActive: filterActive
                    )
                }
            } else {
                selectedEntryID = visibleEntryIDs.first
            }
        case .beginEditing:
            if let currentSelectionID, visibleEntryIDs.contains(currentSelectionID) {
                self.entryID = currentSelectionID
                selectedEntryID = currentSelectionID
            } else {
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: currentSelectionID,
                    captured: nil,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
            }
        case .finishEditing:
            if let editingID = entryID {
                self.entryID = nil
                endedEditing = true
                if visibleEntryIDs.contains(editingID) {
                    selectedEntryID = editingID
                } else {
                    notice = Self.notice(for: "the current results", saveFailure: saveFailure)
                    selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                        current: editingID,
                        captured: nil,
                        previousVisibleEntryIDs: previousVisibleEntryIDs,
                        visibleEntryIDs: visibleEntryIDs,
                        filterActive: filterActive
                    )
                }
            } else {
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: currentSelectionID,
                    captured: nil,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
            }
        case .draftChanged(let draftEntryID):
            if entryID == draftEntryID, visibleEntryIDs.contains(draftEntryID) {
                selectedEntryID = draftEntryID
            } else if let editingID = entryID, !visibleEntryIDs.contains(editingID) {
                self.entryID = nil
                endedEditing = true
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: editingID,
                    captured: nil,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
                notice = Self.notice(for: "the current results", saveFailure: saveFailure)
            } else {
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: currentSelectionID,
                    captured: nil,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
            }
        case .eviction(let evictedIDs, let fromCapture):
            if let editingID = entryID, evictedIDs.contains(editingID) {
                self.entryID = nil
                endedEditing = true
                preserveCaptureSelection = fromCapture
                notice = Self.notice(for: "the history limit", saveFailure: saveFailure)
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: editingID,
                    captured: nil,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
            } else if let editingID = entryID, !visibleEntryIDs.contains(editingID) {
                self.entryID = nil
                endedEditing = true
                notice = Self.notice(for: "the current results", saveFailure: saveFailure)
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: editingID,
                    captured: nil,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
            } else {
                selectedEntryID = CaptureSelectionPolicy.selectedEntryID(
                    current: currentSelectionID,
                    captured: nil,
                    previousVisibleEntryIDs: previousVisibleEntryIDs,
                    visibleEntryIDs: visibleEntryIDs,
                    filterActive: filterActive
                )
            }
        }

        return AppliedResults(
            entries: loadedEntries,
            transition: Transition(
                selectedEntryID: selectedEntryID,
                endedEditing: endedEditing,
                notice: notice,
                preserveCaptureSelection: preserveCaptureSelection
            )
        )
    }

    private static func notice(for cause: String, saveFailure: String?) -> String {
        if let saveFailure {
            return "The entry being edited was removed by \(cause); its draft could not be saved and remains available for retry: \(saveFailure)"
        }
        return "The entry being edited was removed by \(cause); its note was saved."
    }
}

public enum SelectionChangePolicy {
    /// What the UI has to do around a selection change, in this order:
    /// commit the note draft, drop the note editor's focus, then apply the new
    /// selection.
    public struct Plan: Equatable, Sendable {
        /// A pending note draft has to be persisted before the selection moves.
        public var commitNote: Bool
        /// The note editor has to resign keyboard focus.
        public var blurNote: Bool

        public init(commitNote: Bool, blurNote: Bool) {
            self.commitNote = commitNote
            self.blurNote = blurNote
        }
    }

    /// Returns the plan for moving the selection from `current` to `next`, or
    /// nil when nothing changes (a click on the row that is already selected
    /// must not blur the editor).
    public static func plan(current: Int64?, next: Int64?, noteEditing: Bool) -> Plan? {
        guard current != next else { return nil }
        return Plan(commitNote: noteEditing, blurNote: noteEditing)
    }
}

// MARK: - Keeping a reconfigured row's height honest

/// Decides when a realized row has to be measured again.
///
/// A row's content changes after AppKit measured the row: the placeholder a row
/// shows while its presentation is being built is replaced by the real preview,
/// a thumbnail arrives, or an edited entry becomes longer. Configuring the
/// cell's view does not change the height AppKit remembers for the row, so the
/// taller content is squeezed into the old height. The cell clips what sticks
/// out, and because the row's content centers vertically that is the first
/// line's top - which Chinese text shows first, because a CJK glyph's ink
/// reaches higher inside the same line than Latin capitals do.
public enum RowHeightPolicy {
    /// Difference between the height a row's content needs and the height the
    /// row currently has, below which AppKit's own rounding explains it. AppKit
    /// stores whole-point row heights, so a content height of 39 pt can be a
    /// 40 pt row and re-measuring it would change nothing.
    public static let tolerance: CGFloat = 1.5

    /// Whether the row has to be measured again for its current content.
    ///
    /// Checked after a visible cell was reconfigured. A row whose content grew
    /// is clipped until it is re-measured; a row whose content shrank keeps
    /// blank space until then. Both are only worth the layout pass when the
    /// difference is more than AppKit's rounding.
    public static func needsRemeasure(contentHeight: CGFloat, rowHeight: CGFloat) -> Bool {
        abs(contentHeight - rowHeight) >= tolerance
    }
}

// MARK: - Keeping the selection visible

public enum SelectionRevealPolicy {
    /// The row the list has to scroll to for the selection, or nil when the row
    /// is already fully on screen.
    ///
    /// Clicking a row is by definition a visible selection, and moving the
    /// selection with the arrows usually is too. Scrolling on every selection
    /// change made each key press re-scroll the table and re-lay out the list,
    /// which is what turned fast arrow navigation into a stutter. The list only
    /// scrolls when the selected row is not fully on screen.
    public static func rowToReveal(selectedRow: Int?, visibleRows: Range<Int>) -> Int? {
        guard let selectedRow, selectedRow >= 0 else { return nil }
        return visibleRows.contains(selectedRow) ? nil : selectedRow
    }
}
