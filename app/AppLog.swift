// The app's unified log.
//
// A failure the window reports is transient on screen: its banner fades after a
// few seconds. The log is where the same failure stays, so "why did nothing
// happen?" can be answered later instead of only in the moment.

import os

enum AppLog {
    private static let notices = Logger(subsystem: "local.copyqmac", category: "notices")

    /// Records a failure the window reported to the user.
    static func failure(_ message: String) {
        notices.error("\(message, privacy: .public)")
    }
}
