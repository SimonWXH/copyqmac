// The menu-bar status item's two appearances: the one a blocked API-key capture
// shows for a few seconds, and the resting one it returns to.
//
// The decision lives here rather than in `AppDelegate` so the notice's lifetime
// - show, replace, expire - and the language it is rendered in can be driven
// without a window server. `AppDelegate` only maps the result onto the status
// item and its button.

import Foundation

/// What the status item must look like right now.
struct StatusItemNoticeAppearance: Equatable {
    enum ImagePosition: Equatable {
        case iconOnly
        case iconLeading
    }

    let isWide: Bool
    let title: String
    let toolTip: String
    let imagePosition: ImagePosition
}

/// The blocked-capture notice and the resting appearance around it.
@MainActor
final class StatusItemNotice {
    private let scheduler: NoticeTimerScheduling
    private var timer: NoticeTimer?
    private var language: AppLanguage
    private var hotKeyDisplayLabel: String

    /// Runs once when the notice's timer expires, so the caller can apply the
    /// resting appearance.
    var onDismiss: (@MainActor () -> Void)?

    init(
        scheduler: NoticeTimerScheduling,
        language: AppLanguage,
        hotKeyDisplayLabel: String
    ) {
        self.scheduler = scheduler
        self.language = language
        self.hotKeyDisplayLabel = hotKeyDisplayLabel
    }

    var isShowing: Bool { timer != nil }

    /// The appearance for the current state. `hasIcon` picks the resting title
    /// fallback, which is only shown when the status item carries no image.
    func appearance(hasIcon: Bool) -> StatusItemNoticeAppearance {
        if isShowing {
            let notice = Localization.string(.statusItemAPIKeyNotSaved, language: language)
            return StatusItemNoticeAppearance(
                isWide: true,
                title: notice,
                toolTip: notice,
                imagePosition: .iconLeading
            )
        }
        return StatusItemNoticeAppearance(
            isWide: false,
            title: hasIcon ? "" : "Q",
            toolTip: Localization.statusItemTooltip(
                hotkey: Localization.hotKeyLabel(hotKeyDisplayLabel, language: language),
                language: language
            ),
            imagePosition: .iconOnly
        )
    }

    /// Shows the notice, replacing any notice already up and restarting its
    /// lifetime so the reader always gets the full duration.
    func show(language: AppLanguage, hotKeyDisplayLabel: String) {
        self.language = language
        self.hotKeyDisplayLabel = hotKeyDisplayLabel
        timer?.cancel()
        timer = scheduler.schedule(after: NoticeTimer.standardDuration) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.onDismiss?()
        }
    }

    /// Follows a preference change: a notice that is up is rendered in the new
    /// language, and the timer keeps running.
    func update(language: AppLanguage, hotKeyDisplayLabel: String) {
        self.language = language
        self.hotKeyDisplayLabel = hotKeyDisplayLabel
    }
}
