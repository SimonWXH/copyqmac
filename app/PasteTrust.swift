// Reads the Accessibility permission and owns the per-launch trust state.
//
// The rule itself lives in `PasteTrustSession` (core) so it is testable without
// TCC; this type is the thin adapter that performs the two AX checks and hands
// the answers to the policy. One instance is shared by the paste service and
// the model, so a posted paste and the notice that explains a copy-only paste
// always agree.

import AppKit
import Foundation

@MainActor
final class PasteTrust {
    private var session: PasteTrustSession
    /// Reads the process-level trust without ever showing the system dialog.
    private let readProcessTrusted: @MainActor () -> Bool
    /// Reads the trust with the system dialog allowed. Only called through the
    /// policy, which decides whether asking is warranted.
    private let readTrustedWithPrompt: @MainActor () -> Bool

    init(
        session: PasteTrustSession = PasteTrustSession(),
        readProcessTrusted: @escaping @MainActor () -> Bool = { PasteService.isAccessibilityTrusted() },
        readTrustedWithPrompt: @escaping @MainActor () -> Bool = {
            PasteService.isAccessibilityTrusted(prompt: true)
        }
    ) {
        self.session = session
        self.readProcessTrusted = readProcessTrusted
        self.readTrustedWithPrompt = readTrustedWithPrompt
    }

    /// Whether a paste already posted its synthetic Command-V in this launch.
    /// From then on the app treats trust as established and never prompts.
    var isEstablished: Bool { session.pasteSucceeded }

    /// Whether the user was already asked and macOS still reports this build as
    /// untrusted, which is what a stale grant looks like.
    var isStaleGrant: Bool { session.grantLooksStale }

    /// Re-reads the permission for the UI.
    ///
    /// `afterUserAction` is true when the app is reading the permission because
    /// the user came back to it (window activation, an explicit grant). Only
    /// those checks can reveal a stale grant, so only they change the notice
    /// from the first-run instruction to the remove-and-re-add text.
    @discardableResult
    func refresh(afterUserAction: Bool = true) -> Bool {
        let processTrusted = readProcessTrusted()
        session.noteTrustCheck(processTrusted: processTrusted, afterUserAction: afterUserAction)
        return session.isTrusted(processTrusted: processTrusted)
    }

    /// One paste attempt: whether it may post its synthetic Command-V.
    ///
    /// Asks macOS at most once for one paste, and never when the process reads
    /// trusted at that moment (a grant can land between the two checks, and a
    /// dialog for a permission the app already has would be noise).
    func authorizePaste() -> Bool {
        let processTrusted = readProcessTrusted()
        session.noteTrustCheck(processTrusted: processTrusted, afterUserAction: false)
        if session.isTrusted(processTrusted: processTrusted) { return true }
        guard session.shouldPromptForPaste(processTrusted: processTrusted) else { return false }

        let processTrustedNow = readProcessTrusted()
        guard !processTrustedNow else {
            session.noteTrustCheck(processTrusted: true, afterUserAction: false)
            return true
        }

        let promptedTrust = readTrustedWithPrompt()
        session.noteTrustCheck(processTrusted: promptedTrust, afterUserAction: false)
        return session.isTrusted(processTrusted: promptedTrust)
    }

    /// The synthetic paste command reached the target app. Trust is established
    /// for the rest of the session, so the notice is retired and no further
    /// system dialog is shown.
    func notePasteSucceeded() {
        session.notePasteSucceeded()
    }

    /// The status-bar affordance or the notice's button: show the system dialog
    /// once and let the caller open the Accessibility pane.
    func requestFromUser() {
        let processTrusted = readProcessTrusted()
        guard !session.isTrusted(processTrusted: processTrusted) else {
            session.noteTrustCheck(processTrusted: true, afterUserAction: true)
            return
        }
        session.notePromptRequestedByUser()
        let promptedTrust = readTrustedWithPrompt()
        session.noteTrustCheck(processTrusted: promptedTrust, afterUserAction: true)
    }
}
