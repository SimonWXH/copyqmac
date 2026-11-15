// SPDX-License-Identifier: GPL-3.0-or-later
//
// ColumnWidthDraft.swift
//
// Debounced commit decision shared by the Layout B sidebar and inspector
// column widths.
//
// Each column reads its width from an explicit drag handle and debounces the
// measurements; this file owns the decision of whether a measurement is
// valid, whether a write is needed, and which width wins when dragging
// ceases. The columns differ only in their limits and in whether the
// available container narrows the allowed maximum, so a layout supplies that
// geometry and the commit rule is shared.

import Foundation

/// The width limits and clamping rule for one resizable column.
public protocol ColumnWidthLayout {
    static var minWidth: Double { get }
    static var maxWidth: Double { get }
    static func clampWidth(_ width: Double, containerWidth: CGFloat) -> Double
}

/// Debounced commit bookkeeping for a resizable column width.
public struct ColumnWidthDraft<Layout: ColumnWidthLayout> {
    private var pendingWidth: Double?

    public init() {}

    /// True when a commit is scheduled but has not been resolved yet.
    public var hasPendingCommit: Bool { pendingWidth != nil }

    /// The currently pending width value, if any.
    public var pendingValue: Double? { pendingWidth }

    /// Records `measuredWidth` as the pending width and reports whether a
    /// debounced write should be scheduled.
    ///
    /// Measurements taken while the column is hidden or below the minimum
    /// column width are rejected and clear any pending commit. Both the
    /// measurement and the stored width are clamped to the container first, so
    /// a measurement that renders the same width as the stored width needs no
    /// write even when the container clamps both of them.
    @discardableResult
    public mutating func record(
        measuredWidth: Double,
        isVisible: Bool,
        currentStoredWidth: Double,
        containerWidth: CGFloat
    ) -> Bool {
        guard isVisible, measuredWidth >= Layout.minWidth else {
            pendingWidth = nil
            return false
        }
        let clamped = Layout.clampWidth(measuredWidth, containerWidth: containerWidth)
        let stored = Layout.clampWidth(currentStoredWidth, containerWidth: containerWidth)
        guard abs(clamped - stored) >= 0.5 else {
            pendingWidth = nil
            return false
        }
        pendingWidth = clamped
        return true
    }

    /// Resolves the pending draft into its write and clears it.
    public mutating func takeCommit() -> Double? {
        let commit = pendingWidth
        pendingWidth = nil
        return commit
    }

    /// Clears any pending commit without resolving it.
    public mutating func cancel() {
        pendingWidth = nil
    }
}

/// Coordinates the debounced commit of a column width change.
@MainActor
public final class ColumnWidthDebouncer<Layout: ColumnWidthLayout> {
    public let delay: Duration
    private var draft = ColumnWidthDraft<Layout>()
    private var task: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(500)) {
        self.delay = delay
    }

    public var hasPendingCommit: Bool { draft.hasPendingCommit }
    public var pendingValue: Double? { draft.pendingValue }

    /// Handles a new width measurement from the UI.
    public func handleWidthChange(
        measuredWidth: Double,
        isVisible: Bool,
        currentStoredWidth: Double,
        containerWidth: CGFloat,
        onCommit: @escaping @MainActor (Double) -> Void
    ) {
        let shouldSchedule = draft.record(
            measuredWidth: measuredWidth,
            isVisible: isVisible,
            currentStoredWidth: currentStoredWidth,
            containerWidth: containerWidth
        )
        task?.cancel()
        task = nil

        guard shouldSchedule else { return }

        task = Task { @MainActor in
            try? await Task.sleep(for: self.delay)
            guard !Task.isCancelled else { return }
            guard let commit = self.draft.takeCommit() else { return }
            onCommit(commit)
        }
    }

    /// Cancels any scheduled commit.
    public func cancel() {
        task?.cancel()
        task = nil
        draft.cancel()
    }
}
