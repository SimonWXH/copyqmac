// Selection is its own observable object on purpose.
//
// `AppModel` publishes the entries, tabs, notices, and caches. If the selected
// entry lived there too, every click and every arrow key would invalidate every
// view that watches the model - including the row hierarchy - and the list
// would re-evaluate a thousand rows to move a highlight. Keeping selection
// separate means a selection change publishes only this object, which only the
// native list and the preview pane observe.

import Combine
import Foundation

@MainActor
final class SelectionState: ObservableObject {
    /// Everything that changes when the selection changes, published as one
    /// value so the list can apply the whole selection in a single update.
    struct Snapshot: Equatable {
        var ids: Set<Int64> = []
        /// The entry commands act on: the last one the user activated.
        var focus: Int64?
    }

    @Published private(set) var snapshot = Snapshot()
    /// Bumped when a data change wants the selected row brought on screen.
    /// Selection changes themselves never ask for a scroll; the list scrolls
    /// only when the newly selected row is not fully inside the viewport.
    @Published private(set) var revealRequest = 0

    var selectedEntryIDs: Set<Int64> { snapshot.ids }
    var focusedEntryID: Int64? { snapshot.focus }
    /// The focused entry. Kept under the old name because the preview and the
    /// item commands have always meant "the entry the user last acted on".
    var selectedEntryID: Int64? { snapshot.focus }

    func set(ids: Set<Int64>, focus: Int64?) {
        var resolvedFocus = focus
        if let focus, !ids.contains(focus) {
            resolvedFocus = ids.first
        }
        let next = Snapshot(ids: ids, focus: ids.isEmpty ? nil : resolvedFocus)
        guard next != snapshot else { return }
        snapshot = next
    }

    func requestReveal() {
        revealRequest &+= 1
    }
}
