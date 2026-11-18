import AppKit
import SwiftUI

// MARK: - Sidebar Resize Handle

/// A drag handle pinned to the sidebar column's trailing edge.
///
/// The Layout B sidebar column width is managed explicitly (min = ideal = max
/// on the column), so the split view's own divider is inert; this handle owns
/// resizing. Dragging updates the rendered width immediately, clamped to the
/// allowed range, and funnels each measurement through the shared debouncer,
/// which commits the width to preferences once the drag settles.
struct SidebarResizeHandle: View {
    @Binding var width: CGFloat?
    @Binding var dragBase: CGFloat?
    let storedWidth: Double
    let isVisible: Bool
    let debouncer: ColumnWidthDebouncer<SidebarLayout>
    let onCommit: @MainActor (Double) -> Void

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragBase ?? width ?? CGFloat(storedWidth)
                        dragBase = base
                        let proposed = SidebarLayout.clampWidth(
                            Double(base + value.translation.width)
                        )
                        width = CGFloat(proposed)
                        debouncer.handleWidthChange(
                            measuredWidth: proposed,
                            isVisible: isVisible,
                            currentStoredWidth: storedWidth,
                            containerWidth: 0,
                            onCommit: onCommit
                        )
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .accessibilityLabel(Text("Resize Sidebar"))
    }
}
