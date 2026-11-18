import AppKit
import SwiftUI

// MARK: - Inspector Split Divider

final class InspectorDividerNSView: NSView {
    var availableHeight: CGFloat = 0
    var currentRatio: Double = InspectorSplitLayout.defaultRatio
    var onRatioChange: ((Double) -> Void)?
    var onRatioCommit: ((Double) -> Void)?
    var onReset: (() -> Void)?

    private var dragAnchorY: CGFloat = 0
    private var initialRatio: Double = InspectorSplitLayout.defaultRatio
    private var lastReportedRatio: Double?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        dragAnchorY = event.locationInWindow.y
        initialRatio = currentRatio
        isDragging = true
        NSCursor.resizeUpDown.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, availableHeight > 0 else { return }
        let newRatio = InspectorSplitLayout.ratio(
            startRatio: initialRatio,
            pointerDelta: dragAnchorY - event.locationInWindow.y,
            availableHeight: availableHeight
        )
        lastReportedRatio = newRatio
        onRatioChange?(newRatio)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if let ratio = lastReportedRatio {
            lastReportedRatio = nil
            onRatioCommit?(ratio)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let gripWidth: CGFloat = 22
        let gripHeight: CGFloat = 2
        let gripX = (bounds.width - gripWidth) / 2
        let gripY = (bounds.height - gripHeight) / 2
        let gripRect = NSRect(x: gripX, y: gripY, width: gripWidth, height: gripHeight)
        let gripPath = NSBezierPath(roundedRect: gripRect, xRadius: 1, yRadius: 1)
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        gripPath.fill()
    }
}

struct InspectorDividerRepresentable: NSViewRepresentable {
    let availableHeight: CGFloat
    let currentRatio: Double
    let onRatioChange: (Double) -> Void
    let onRatioCommit: (Double) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> InspectorDividerNSView {
        let view = InspectorDividerNSView()
        view.availableHeight = availableHeight
        view.currentRatio = currentRatio
        view.onRatioChange = onRatioChange
        view.onRatioCommit = onRatioCommit
        view.onReset = onReset
        return view
    }

    func updateNSView(_ nsView: InspectorDividerNSView, context: Context) {
        nsView.availableHeight = availableHeight
        nsView.currentRatio = currentRatio
        nsView.onRatioChange = onRatioChange
        nsView.onRatioCommit = onRatioCommit
        nsView.onReset = onReset
    }
}
