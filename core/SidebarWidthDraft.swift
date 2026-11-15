// SPDX-License-Identifier: GPL-3.0-or-later
//
// SidebarWidthDraft.swift
//
// Debounced commit decision for the Layout B sidebar column width.
//
// The view reads column width via GeometryReader and debounces updates; this
// file owns the decision of whether a measurement is valid, whether a write
// is needed, and which width wins when dragging ceases.

import Foundation

/// Debounced commit bookkeeping for the sidebar column width in Layout B.
public struct SidebarWidthDraft: Equatable, Sendable {
    private var pendingWidth: Double?

    public init() {}

    /// True when a commit is scheduled but has not been resolved yet.
    public var hasPendingCommit: Bool { pendingWidth != nil }

    /// The currently pending width value, if any.
    public var pendingValue: Double? { pendingWidth }

    /// Records `measuredWidth` as the pending width and reports whether a
    /// debounced write should be scheduled.
    ///
    /// Measurements taken while the sidebar is collapsed or below the minimum
    /// column width are rejected and clear any pending commit. If the clamped
    /// width matches `currentStoredWidth` within 0.5 pt, no write is needed
    /// and any pending commit is cleared.
    @discardableResult
    public mutating func record(
        measuredWidth: Double,
        isCollapsed: Bool,
        currentStoredWidth: Double
    ) -> Bool {
        guard !isCollapsed, measuredWidth >= SidebarLayout.minWidth else {
            pendingWidth = nil
            return false
        }
        let clamped = SidebarLayout.clampWidth(measuredWidth)
        guard abs(clamped - currentStoredWidth) >= 0.5 else {
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

/// Coordinates the debounced commit of sidebar column width changes.
@MainActor
public final class SidebarWidthDebouncer {
    public let delay: Duration
    private var draft = SidebarWidthDraft()
    private var task: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(500)) {
        self.delay = delay
    }

    public var hasPendingCommit: Bool { draft.hasPendingCommit }
    public var pendingValue: Double? { draft.pendingValue }

    /// Handles a new width measurement from the UI.
    public func handleWidthChange(
        measuredWidth: Double,
        isCollapsed: Bool,
        currentStoredWidth: Double,
        onCommit: @escaping @MainActor (Double) -> Void
    ) {
        let shouldSchedule = draft.record(
            measuredWidth: measuredWidth,
            isCollapsed: isCollapsed,
            currentStoredWidth: currentStoredWidth
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
