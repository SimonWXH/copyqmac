// Polls NSPasteboard for changes.
//
// AppKit has no pasteboard-change notification, so the accepted approach is to
// poll `changeCount`. A short interval keeps capture feeling instant; the check
// itself is a single integer comparison.

import AppKit
import Foundation

final class ClipboardWatcher {
    /// The pasteboard change counts this app produced itself. Writes made by
    /// paste-back land here so the watcher does not record its own output.
    private var ignoredChangeCounts: Set<Int> = []
    private var lastObservedChangeCount: Int
    private var timer: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?
    private let pasteboard: NSPasteboard
    private let history: ClipboardHistory
    private let pollInterval: TimeInterval
    /// The app that is frontmost when the poll runs, added to the capture window
    /// before the decision. It reports our own app too: our window is a known,
    /// non-excluded source, so it keeps the window alive instead of being
    /// treated as unreadable focus.
    private let frontmostApplication: () -> SourceApplication?
    /// The bundle identifier of this app, so it can be recognized in the window
    /// while staying out of the Preferences hint.
    private let ownBundleIdentifier: String?
    /// The apps that have been frontmost since the last clipboard check.
    private var window = CaptureWindow()
    /// A detected change is judged on the next main-queue turn, so activation
    /// notifications already queued behind the poll get a chance to land in the
    /// window first. Workspace activations arrive on the main operation queue,
    /// so that ordering is best-effort.
    private var isEvaluationScheduled = false
    /// Where a skipped capture is announced. The message never contains the
    /// payload; it names the rule that matched.
    private let logMessage: (String) -> Void

    /// Called on the main thread after a capture is stored.
    var onCapture: ((ClipboardEntry) -> Void)?

    /// Called on the main thread when a capture was dropped because its text
    /// carried an AI-service API key. The payload is never passed on: only the
    /// fact that a capture was skipped reaches the interface.
    var onAPIKeyCaptureBlocked: (() -> Void)?

    /// The last app seen as frontmost, for the Preferences "Add Last App" hint
    /// only. It never takes part in the capture decision.
    private(set) var lastObservedFrontmostApplication: SourceApplication?
    /// Captures skipped because the capture window was empty or stale.
    private(set) var unattributableSkipCount = 0

    init(
        history: ClipboardHistory,
        pasteboard: NSPasteboard = .general,
        pollInterval: TimeInterval = 0.35,
        frontmostApplication: (() -> SourceApplication?)? = nil,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        logMessage: ((String) -> Void)? = nil
    ) {
        self.history = history
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.lastObservedChangeCount = pasteboard.changeCount
        self.ownBundleIdentifier = ownBundleIdentifier
        self.frontmostApplication = frontmostApplication ?? {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return Self.sourceApplication(for: app)
        }
        self.logMessage = logMessage ?? { NSLog("CopyQmac: %@", $0) }
    }

    /// Records an app activation for the capture window and, for another app,
    /// the Preferences hint.
    func noteActivation(_ application: SourceApplication?) {
        guard let application else { return }
        observe(application)
    }

    func start() {
        stop()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let source = Self.sourceApplication(for: app)
            else { return }
            self?.noteActivation(source)
        }
        // A GCD timer on its own queue is less prone to run-loop coalescing than
        // a Timer, and the AppDelegate holds an App Nap opt-out so the queue is
        // not suspended while the panel is closed.
        let queue = DispatchQueue(label: "local.copyqmac.pasteboard-poll", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + pollInterval,
            repeating: pollInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        timer?.cancel()
        timer = nil
    }

    /// Marks a change count as self-produced. Any count at or below the newest
    /// ignored count is treated as our own, which also absorbs the extra
    /// increments that `clearContents` plus `writeObjects` can produce.
    func ignore(changeCount: Int) {
        ignoredChangeCounts.insert(changeCount)
        lastObservedChangeCount = max(lastObservedChangeCount, changeCount)
        // The set only needs the recent past; writes never walk backwards.
        if ignoredChangeCounts.count > 32 {
            ignoredChangeCounts = [changeCount]
        }
    }

    /// Runs one poll immediately. The timer calls this on the main queue; tests
    /// call it directly and then drain the main queue to reach the decision.
    func pollNow() {
        poll()
    }

    private func poll() {
        let current = pasteboard.changeCount
        let live = frontmostApplication()
        if let live {
            observe(live)
        }

        guard current != lastObservedChangeCount else {
            if !isEvaluationScheduled {
                window.reset(to: live)
            }
            return
        }
        lastObservedChangeCount = current
        guard !ignoredChangeCounts.contains(current) else {
            if !isEvaluationScheduled {
                window.reset(to: live)
            }
            return
        }
        guard !isEvaluationScheduled else { return }
        isEvaluationScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.evaluateCapture()
        }
    }

    private func evaluateCapture() {
        isEvaluationScheduled = false
        let live = frontmostApplication()
        if let live {
            observe(live)
        }
        guard !ignoredChangeCounts.contains(pasteboard.changeCount) else {
            window.reset(to: live)
            return
        }

        let preferences = (try? history.preferences()) ?? .defaultValue
        let decision = CaptureExclusionPolicy(preferences: preferences).decide(window: window)
        defer {
            window.reset(to: live)
        }

        if let rule = decision.excludedRule {
            // Stop before snapshot(): the payload is never read.
            skip(reason: "excluded application \(rule.bundleIdentifier)")
            return
        }
        guard !decision.isUnattributable else {
            unattributableSkipCount += 1
            skip(reason: "the frontmost application could not be determined")
            return
        }
        if PasteboardBridge.hasConfidentialMarker(pasteboard) {
            skip(reason: "the source marked it private")
            return
        }

        let flavours = PasteboardBridge.snapshot(of: pasteboard)
        guard !flavours.isEmpty else { return }

        // Content-level guard: an AI-service API key copied once must not sit in
        // the history or a sync folder in plaintext, so it is dropped here -
        // after the snapshot and before record() reads anything into SQLite.
        if preferences.apiKeyGuardEnabled, let rule = APIKeyDetection.match(in: flavours) {
            skip(reason: "an AI service API key (\(rule.label))")
            onAPIKeyCaptureBlocked?()
            return
        }

        do {
            switch try history.record(flavours) {
            case .inserted(let entry), .duplicate(let entry):
                onCapture?(entry)
            case .empty:
                break
            }
        } catch {
            NSLog("CopyQmac: failed to record clipboard change: \(error)")
        }
    }

    private func observe(_ application: SourceApplication) {
        window.note(application)
        if !isOwnApplication(application) {
            lastObservedFrontmostApplication = application
        }
    }

    private func isOwnApplication(_ application: SourceApplication) -> Bool {
        guard let ownBundleIdentifier, !ownBundleIdentifier.isEmpty else { return false }
        return application.bundleIdentifier.caseInsensitiveCompare(ownBundleIdentifier) == .orderedSame
    }

    private func skip(reason: String) {
        logMessage("skipped clipboard capture: \(reason)")
    }

    private static func sourceApplication(for app: NSRunningApplication) -> SourceApplication? {
        guard let bundleIdentifier = app.bundleIdentifier else { return nil }
        return SourceApplication(
            bundleIdentifier: bundleIdentifier,
            name: app.localizedName ?? bundleIdentifier
        )
    }
}
