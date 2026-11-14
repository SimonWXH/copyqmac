// Reordering rules for the item list.
//
// The list is ordered pinned entries first, then newest first, and the store
// keeps that order in a dedicated `position` column so reordering never has to
// rewrite an entry's creation time. These rules work on the display order and
// return the order the store should persist.
//
// Moving more than one entry preserves their relative order, and each entry
// moves within its own pin group: an unpinned entry cannot be moved above a
// pinned one, because the pinned block always floats to the top.

import Foundation

public enum ItemMoveCommand: Equatable, Sendable {
    case up
    case down
    case top
    case bottom
}

public enum ItemReorderPolicy {
    /// Returns `order` with the selected entries moved by `command`.
    ///
    /// `order` is the full display order of the tab and `pinned` says which
    /// entries belong to the pinned block. Nothing changes when the selection
    /// is empty or already at the requested edge.
    public static func reorder(
        order: [Int64],
        pinned: [Int64: Bool],
        selection: Set<Int64>,
        command: ItemMoveCommand
    ) -> [Int64] {
        let selected = selection.intersection(order)
        guard !selected.isEmpty else { return order }

        let pinnedOrder = order.filter { pinned[$0] == true }
        let unpinnedOrder = order.filter { pinned[$0] != true }

        let movedPinned = move(pinnedOrder, selection: selected, command: command)
        let movedUnpinned = move(unpinnedOrder, selection: selected, command: command)

        // Pinned entries always sort above unpinned ones, so the stored order
        // has to keep the two blocks apart even when the selection mixes them.
        if pinnedOrder.isEmpty { return unpinnedOrder.isEmpty ? order : movedUnpinned }
        if unpinnedOrder.isEmpty { return movedPinned }
        return movedPinned + movedUnpinned
    }

    private static func move(
        _ order: [Int64],
        selection: Set<Int64>,
        command: ItemMoveCommand
    ) -> [Int64] {
        guard !order.isEmpty else { return order }
        switch command {
        case .up:
            var moved = order
            for index in 1..<moved.count
            where selection.contains(moved[index]) && !selection.contains(moved[index - 1])
            {
                moved.swapAt(index, index - 1)
            }
            return moved
        case .down:
            var moved = order
            for index in stride(from: moved.count - 2, through: 0, by: -1)
            where selection.contains(moved[index]) && !selection.contains(moved[index + 1])
            {
                moved.swapAt(index, index + 1)
            }
            return moved
        case .top:
            let selected = order.filter { selection.contains($0) }
            let rest = order.filter { !selection.contains($0) }
            return selected + rest
        case .bottom:
            let selected = order.filter { selection.contains($0) }
            let rest = order.filter { !selection.contains($0) }
            return rest + selected
        }
    }
}
