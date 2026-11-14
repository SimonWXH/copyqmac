// What the status bar keeps from the window's transient banner.
//
// The banner itself is short-lived: `NoticeTimer` (app) owns its dismissal, so a
// message is on screen for a few seconds and then goes. Anything the user must
// still be able to act on afterwards is kept here instead.

import Foundation

/// What the status bar shows about the window's notices.
///
/// The status bar is the durable surface: the banner on screen is only ever a
/// few seconds old, so the message a user must still be able to act on lives
/// here once the banner fades.
public enum NoticeStatusPolicy {
    /// Whether the status bar carries the record of a failure notice.
    ///
    /// A failure that is still the banner on screen is not repeated here, the
    /// same rule as the Accessibility item; the record takes over when the
    /// banner goes away - by fading, by being replaced by a newer message, or by
    /// the user closing it.
    public static func showsFailureItem(failure: String?, banner: String?) -> Bool {
        guard let failure else { return false }
        return failure != banner
    }
}
