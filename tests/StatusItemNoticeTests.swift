// The menu-bar notice for a blocked AI-service API-key capture.
//
// The regression these tests guard: the notice's lifetime was only reachable
// through `AppDelegate`, so widening the status item, saying the same thing
// again when a second capture is blocked, restoring the resting appearance on
// expiry, and following a language change had no automated proof.

import AppKit
import Foundation

/// The notice timers a test drives itself: nothing here waits on the clock.
@MainActor
private final class ManualNoticeTimers: NoticeTimerScheduling {
    private var entries: [(delay: TimeInterval, fire: @MainActor () -> Void, timer: NoticeTimer)] = []

    var scheduledCount: Int { entries.count }

    /// The delays of the timers that would still fire, oldest first.
    var liveDelays: [TimeInterval] {
        entries.filter { !$0.timer.isCancelled }.map(\.delay)
    }

    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> NoticeTimer {
        let timer = NoticeTimer()
        entries.append((delay, fire, timer))
        return timer
    }

    /// Lets every pending notice timer fire, the way the run loop would.
    func fireAll() {
        for entry in entries where !entry.timer.isCancelled {
            entry.timer.cancel()
            entry.fire()
        }
    }
}

func registerStatusItemNoticeTests() {
    TestRunner.currentSuite = "StatusItemNotice"

    TestRunner.add("a blocked capture widens the status item and names the skip") {
        MainActor.assumeIsolated {
            let timers = ManualNoticeTimers()
            let notice = StatusItemNotice(
                scheduler: timers,
                language: .english,
                hotKeyDisplayLabel: "⌥V"
            )

            let resting = notice.appearance(hasIcon: true)
            expectEqual(resting.isWide, false)
            expectEqual(resting.imagePosition, .iconOnly)
            expectEqual(resting.title, "")

            notice.show(language: .english, hotKeyDisplayLabel: "⌥V")

            expectEqual(notice.isShowing, true)
            let shown = notice.appearance(hasIcon: true)
            expectEqual(shown.isWide, true)
            expectEqual(shown.imagePosition, .iconLeading)
            expectEqual(
                shown.title,
                Localization.string(.statusItemAPIKeyNotSaved, language: .english)
            )
            expectEqual(shown.toolTip, shown.title, "the tooltip says the same thing as the title")
        }
    }

    TestRunner.add("a status item without an icon falls back to the Q title at rest") {
        MainActor.assumeIsolated {
            let notice = StatusItemNotice(
                scheduler: ManualNoticeTimers(),
                language: .english,
                hotKeyDisplayLabel: "⌥V"
            )
            expectEqual(notice.appearance(hasIcon: false).title, "Q")
        }
    }

    TestRunner.add("a second blocked capture replaces the notice and restarts its timer") {
        MainActor.assumeIsolated {
            let timers = ManualNoticeTimers()
            let notice = StatusItemNotice(
                scheduler: timers,
                language: .english,
                hotKeyDisplayLabel: "⌥V"
            )

            notice.show(language: .english, hotKeyDisplayLabel: "⌥V")
            notice.show(language: .english, hotKeyDisplayLabel: "⌥V")

            expectEqual(notice.isShowing, true)
            expectEqual(timers.scheduledCount, 2, "each capture schedules its own lifetime")
            expectEqual(
                timers.liveDelays,
                [NoticeTimer.standardDuration],
                "the replaced notice's timer must not clear the newer notice"
            )
            expectEqual(
                notice.appearance(hasIcon: true).title,
                Localization.string(.statusItemAPIKeyNotSaved, language: .english)
            )
        }
    }

    TestRunner.add("the notice clears when its timer expires") {
        MainActor.assumeIsolated {
            let timers = ManualNoticeTimers()
            let notice = StatusItemNotice(
                scheduler: timers,
                language: .english,
                hotKeyDisplayLabel: "⌥V"
            )
            var dismissals = 0
            notice.onDismiss = { dismissals += 1 }
            notice.show(language: .english, hotKeyDisplayLabel: "⌥V")

            timers.fireAll()

            expectEqual(notice.isShowing, false)
            expectEqual(dismissals, 1, "the status item is told to restore once")
            let resting = notice.appearance(hasIcon: true)
            expectEqual(resting.isWide, false)
            expectEqual(resting.imagePosition, .iconOnly)
            expectEqual(resting.title, "")
            expectEqual(
                resting.toolTip,
                Localization.statusItemTooltip(
                    hotkey: Localization.hotKeyLabel("⌥V", language: .english),
                    language: .english
                )
            )
        }
    }

    TestRunner.add("a language change reapplies the notice text without restarting its timer") {
        MainActor.assumeIsolated {
            let timers = ManualNoticeTimers()
            let notice = StatusItemNotice(
                scheduler: timers,
                language: .english,
                hotKeyDisplayLabel: "⌥V"
            )
            notice.show(language: .english, hotKeyDisplayLabel: "⌥V")
            let englishTitle = notice.appearance(hasIcon: true).title
            let delays = timers.liveDelays

            notice.update(language: .simplifiedChinese, hotKeyDisplayLabel: "⌥V")

            expectEqual(notice.isShowing, true)
            let chineseTitle = notice.appearance(hasIcon: true).title
            expectEqual(
                chineseTitle,
                Localization.string(.statusItemAPIKeyNotSaved, language: .simplifiedChinese)
            )
            expect(chineseTitle != englishTitle, "the notice follows the new language")
            expectEqual(timers.liveDelays, delays, "updating the text does not restart the timer")
        }
    }
}
