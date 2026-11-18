import AppKit
import SwiftUI

// MARK: - Inspector Resize Handle

/// A drag handle pinned to the inspector column's leading edge.
///
/// Dragging updates the rendered width immediately, clamped to the allowed
/// range (240...560 pt) and the available container width, so the item list
/// keeps at least 320 pt whenever the container allows it and the inspector
/// holds its 240 pt minimum below that, and funnels each measurement through
/// the shared debouncer, which commits the width to preferences once the drag
/// settles.
struct InspectorResizeHandle: View {
    @Binding var width: CGFloat?
    @Binding var dragBase: CGFloat?
    let renderedWidth: CGFloat
    let storedWidth: Double
    let isVisible: Bool
    let containerWidth: CGFloat
    let debouncer: ColumnWidthDebouncer<InspectorColumnLayout>
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
                        let base = dragBase ?? renderedWidth
                        dragBase = base
                        let proposed = InspectorColumnLayout.width(
                            baseWidth: Double(base),
                            translationX: value.translation.width,
                            containerWidth: containerWidth
                        )
                        width = CGFloat(proposed)
                        debouncer.handleWidthChange(
                            measuredWidth: proposed,
                            isVisible: isVisible,
                            currentStoredWidth: storedWidth,
                            containerWidth: containerWidth,
                            onCommit: onCommit
                        )
                    }
                    .onEnded { _ in
                        if !debouncer.hasPendingCommit {
                            width = nil
                        }
                        dragBase = nil
                    }
            )
            .accessibilityLabel(Text("Resize Inspector"))
    }
}
