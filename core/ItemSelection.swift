// Multi-selection maths for the item list.
//
// The UI is a thin adapter over these rules: AppKit reports a click, a
// modified click, or a key, and this value type decides which entries are
// selected and which one holds the focus. Keeping it in the core, without
// AppKit, lets the click and keyboard rules be tested headlessly.
//
// The focus is the entry the user last acted on: the preview pane shows it and
// commands such as Copy and Activate use it. The anchor is where a Shift-click
// or Shift-arrow range starts; it deliberately survives the range growing and
// shrinking.

import Foundation

public struct ItemSelection: Equatable, Sendable {
    /// The selected entry identities. A set because the list only needs
    /// membership and the display order comes from the caller's `order`.
    public private(set) var ids: Set<Int64>
    /// The entry commands act on. Nil when nothing is selected.
    public private(set) var focus: Int64?
    /// The fixed end of a Shift range. Nil when there is no range.
    public private(set) var anchor: Int64?

    public init(ids: Set<Int64> = [], focus: Int64? = nil, anchor: Int64? = nil) {
        self.ids = ids
        self.focus = focus
        self.anchor = anchor
    }

    public var isEmpty: Bool { ids.isEmpty }

    /// A plain click: exactly one entry, which also becomes the focus and the
    /// range anchor.
    public mutating func selectSingle(_ id: Int64?) {
        guard let id else {
            clear()
            return
        }
        ids = [id]
        focus = id
        anchor = id
    }

    /// Command-click: add or remove one entry without disturbing the others.
    ///
    /// Removing the focused entry hands the focus to the first remaining
    /// selected entry in display order, so the preview keeps showing something
    /// the user selected.
    public mutating func toggle(_ id: Int64, in order: [Int64]) {
        if ids.contains(id) {
            ids.remove(id)
            if focus == id {
                focus = order.first { ids.contains($0) }
            }
            if ids.isEmpty {
                anchor = nil
                focus = nil
            } else if let anchor, !ids.contains(anchor) {
                self.anchor = focus
            }
        } else {
            ids.insert(id)
            focus = id
            anchor = id
        }
    }

    /// Shift-click or Shift-arrow: select the contiguous range between the
    /// anchor and `id`, keeping the anchor where it is.
    public mutating func extend(to id: Int64, in order: [Int64]) {
        guard let target = order.firstIndex(of: id) else { return }
        let base = anchor ?? focus
        if let base, let baseIndex = order.firstIndex(of: base) {
            let lower = min(baseIndex, target)
            let upper = max(baseIndex, target)
            ids = Set(order[lower...upper])
            anchor = base
        } else {
            ids = [id]
            anchor = id
        }
        focus = id
    }

    /// Command-A: every entry the list currently shows.
    public mutating func selectAll(in order: [Int64]) {
        ids = Set(order)
        if let focus, ids.contains(focus) {
            anchor = focus
        } else {
            focus = order.first
            anchor = focus
        }
    }

    /// Escape: no selection at all.
    public mutating func clear() {
        ids = []
        focus = nil
        anchor = nil
    }

    /// Moves the focus one step and, unless the caller is extending, takes the
    /// selection with it. Up from no selection picks the first row, matching
    /// the old single-selection behaviour.
    public mutating func moveFocus(by delta: Int, extending: Bool, in order: [Int64]) {
        guard !order.isEmpty else {
            clear()
            return
        }
        let current = focus.flatMap { order.firstIndex(of: $0) }
        let base: Int
        if let current {
            base = current
        } else {
            base = delta > 0 ? -1 : 0
        }
        let next = min(max(base + delta, 0), order.count - 1)
        let nextID = order[next]

        if extending {
            let rangeAnchor = anchor ?? focus
            if let rangeAnchor, let anchorIndex = order.firstIndex(of: rangeAnchor) {
                let lower = min(anchorIndex, next)
                let upper = max(anchorIndex, next)
                ids = Set(order[lower...upper])
                self.anchor = rangeAnchor
            } else {
                ids = [nextID]
                self.anchor = nextID
            }
        } else {
            ids = [nextID]
            anchor = nextID
        }
        focus = nextID
    }

    /// Re-applies the selection to a refreshed list.
    ///
    /// A refresh that does not change identities keeps the whole selection and
    /// its focus. Entries that disappeared drop out; when the focus was one of
    /// them the first still-selected entry takes over.
    public mutating func reconcile(with order: [Int64]) {
        let visible = Set(order)
        ids.formIntersection(visible)
        if let focus, !ids.contains(focus) {
            self.focus = order.first { ids.contains($0) }
        }
        if focus == nil {
            focus = order.first { ids.contains($0) }
        }
        if ids.isEmpty {
            focus = nil
            anchor = nil
        } else if let anchor, !ids.contains(anchor) {
            self.anchor = focus
        }
    }

    /// Makes `id` the focus without changing which entries are selected.
    /// Returns false when `id` is not selected, because the focus must always
    /// be one of the selected entries.
    @discardableResult
    public mutating func focusOn(_ id: Int64) -> Bool {
        guard ids.contains(id) else { return false }
        focus = id
        return true
    }
}
