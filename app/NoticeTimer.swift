// The banner's one-shot auto-dismiss timer.
//
// The model owns exactly one of these at a time: showing a message cancels the
// pending timer of the message it replaces, so a replacement never stacks a
// second timer and a retired timer can never clear the message that replaced it.
// The scheduler is injectable so the lifetime rules can be checked without
// waiting on the wall clock.

import AppKit

/// A scheduled banner dismissal. The model holds it so it can cancel it; once
/// cancelled the timer never runs.
@MainActor
final class NoticeTimer {
    /// How long a message stays up. Long enough to read a one-line result, short
    /// enough that the banner is gone before it becomes furniture.
    nonisolated static let standardDuration: TimeInterval = 4.5

    private let cancelHandler: @MainActor () -> Void
    private(set) var isCancelled = false

    init(cancelHandler: @escaping @MainActor () -> Void = {}) {
        self.cancelHandler = cancelHandler
    }

    /// Retires the timer. Cancelling twice is harmless.
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelHandler()
    }
}

/// Schedules the banner's dismissal. The app waits on the run loop; a test can
/// hand in a scheduler it fires itself.
@MainActor
protocol NoticeTimerScheduling: AnyObject {
    /// Runs `fire` once after `delay` unless the returned timer is cancelled
    /// first.
    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> NoticeTimer
}

/// The scheduler the app uses: a one-shot timer on the main run loop, in the
/// common modes so it also fires while a menu or a tracking loop is open.
@MainActor
final class RunLoopNoticeTimerScheduler: NoticeTimerScheduling {
    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> NoticeTimer {
        var scheduled: Timer?
        let handle = NoticeTimer { scheduled?.invalidate() }
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        scheduled = timer
        RunLoop.main.add(timer, forMode: .common)
        return handle
    }
}
