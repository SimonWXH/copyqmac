// The apps that were frontmost since the last clipboard check.
//
// A pasteboard change is judged against the whole window, not just the app
// frontmost when the poll runs: a secret copied in an ignored app is still
// skipped after the user switches away to paste it. The window is reset after
// each check and starts from the app that was frontmost at that moment when one
// could be read, so a change is judged only against apps observed since the
// previous check.

import Foundation

public struct CaptureWindow: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var application: SourceApplication
        public var observedAt: Date

        public init(application: SourceApplication, observedAt: Date) {
            self.application = application
            self.observedAt = observedAt
        }
    }

    private var entries: [Entry] = []
    private let limit: Int

    public init(limit: Int = 32) {
        self.limit = max(limit, 1)
    }

    public var mostRecentEntry: Entry? { entries.last }
    public var applications: [SourceApplication] { entries.map(\.application) }

    /// Adds an app to the window, collapsing a consecutive repeat.
    public mutating func note(_ application: SourceApplication, at date: Date = Date()) {
        if let last = entries.last,
           last.application.bundleIdentifier.caseInsensitiveCompare(application.bundleIdentifier)
               == .orderedSame
        {
            entries[entries.count - 1].observedAt = date
        } else {
            entries.append(Entry(application: application, observedAt: date))
        }
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// Starts the next window from the app frontmost at the end of a check.
    public mutating func reset(to application: SourceApplication?, at date: Date = Date()) {
        entries.removeAll()
        if let application {
            entries.append(Entry(application: application, observedAt: date))
        }
    }
}

/// The single capture decision for a clipboard change.
public struct CaptureWindowDecision: Equatable, Sendable {
    public var application: SourceApplication?
    public var excludedRule: CaptureExclusionRule?
    public var isUnattributable: Bool

    public init(
        application: SourceApplication?,
        excludedRule: CaptureExclusionRule?,
        isUnattributable: Bool
    ) {
        self.application = application
        self.excludedRule = excludedRule
        self.isUnattributable = isUnattributable
    }
}

public extension CaptureExclusionPolicy {
    /// How old the newest observation may be before the window fails safe.
    static let captureWindowMaxAge: TimeInterval = 2

    /// Any excluded app in the window skips the change. Otherwise a window whose
    /// newest observation is still fresh captures and attributes to that app,
    /// while an empty or stale window is unattributable.
    func decide(
        window: CaptureWindow,
        now: Date = Date(),
        maxAge: TimeInterval = captureWindowMaxAge
    ) -> CaptureWindowDecision {
        guard let newest = window.mostRecentEntry,
              now.timeIntervalSince(newest.observedAt) <= maxAge
        else {
            return CaptureWindowDecision(
                application: nil,
                excludedRule: nil,
                isUnattributable: true
            )
        }
        for application in window.applications {
            if let rule = excludedRule(bundleIdentifier: application.bundleIdentifier) {
                return CaptureWindowDecision(
                    application: nil,
                    excludedRule: rule,
                    isUnattributable: false
                )
            }
        }
        return CaptureWindowDecision(
            application: newest.application,
            excludedRule: nil,
            isUnattributable: false
        )
    }
}
