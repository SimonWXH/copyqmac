// Accessibility trust: when to ask macOS for the permission, how a paste
// attempt uses it, and the in-app notice that explains a copy-only paste.
//
// The system dialog is the only way the app gets into System Settings ▸
// Privacy & Security ▸ Accessibility, so it has to be requested - but at most
// once per untrusted stretch: the first untrusted check prompts, a trusted
// check re-arms the policy, and a declined prompt is not repeated until then.
//
// Two rules matter beyond the prompt itself:
//
// - A posted synthetic Command-V means the session can paste. macOS can keep
//   reporting an ad-hoc-signed build as untrusted after the user has re-granted
//   the permission (the System Settings switch stays on for the old build), and
//   the process-level check can stay stale until relaunch. Once a paste has
//   actually been posted, that evidence outranks the check: the notice is
//   retired, no further prompt is shown, and the state stays retired across
//   window activations for the rest of the session.
// - When the app still reads untrusted after the user has already been asked
//   and has come back to the app, the grant looks stale. An ad-hoc-signed
//   rebuild is a new binary to macOS, and the switch in System Settings still
//   belongs to the old one, so toggling it does not transfer the grant. The
//   notice then says "remove the entry and add the app back" instead of
//   repeating the first-run instruction.
//
// This policy lives in the core, with no AppKit and no TCC calls, so every rule
// can be tested without posting events or showing a system dialog.

import Foundation

public struct AccessibilityPermission: Equatable, Sendable {
    /// Whether a prompt has already been requested in the current untrusted
    /// stretch. A trusted check or `clearRequested()` resets it.
    public private(set) var promptRequested = false

    public init() {}

    /// Whether a trust check should pass `prompt: true`.
    ///
    /// The first untrusted check prompts, so the system dialog (and the app's
    /// entry in the Accessibility list) appears on the first paste attempt.
    /// Every later check only re-reads the state, so a user who declined is not
    /// asked again on every paste. A process that is already trusted never
    /// prompts, and being trusted also clears the "already asked" state so a
    /// grant that is revoked later can ask once more.
    public mutating func shouldPrompt(trusted: Bool) -> Bool {
        if trusted {
            promptRequested = false
            return false
        }
        guard !promptRequested else { return false }
        promptRequested = true
        return true
    }

    /// Records that a prompt was requested explicitly, for example by the
    /// status-bar Accessibility item, so a later paste does not prompt again.
    public mutating func markRequested() { promptRequested = true }

    /// Forgets an earlier prompt now that the process is trusted, so a grant
    /// revoked later can ask once more.
    public mutating func clearRequested() { promptRequested = false }
}

/// Trust for one launch of the app: the prompt policy plus the evidence that a
/// paste really worked.
///
/// The app owns one instance and shares it with the paste service, so a
/// successful paste and the UI that explains a failed one cannot disagree.
public struct PasteTrustSession: Equatable, Sendable {
    private var permission = AccessibilityPermission()
    /// A synthetic Command-V was posted, so this session can paste even if the
    /// process-level check keeps reporting untrusted.
    public private(set) var pasteSucceeded = false
    /// The user has been asked and has come back to the app, but the process
    /// still reads untrusted: the System Settings switch can look on for a
    /// build macOS no longer accepts.
    public private(set) var grantLooksStale = false

    public init() {}

    /// Whether the app has already asked macOS for the permission in the
    /// current untrusted stretch.
    public var hasPrompted: Bool { permission.promptRequested }

    /// Trust as the UI should report it.
    ///
    /// A posted paste outranks the process check, which macOS can keep false
    /// for a build that was re-signed after the permission was granted.
    public func isTrusted(processTrusted: Bool) -> Bool {
        pasteSucceeded || processTrusted
    }

    /// Whether this paste must ask macOS for the permission before it can post
    /// its synthetic Command-V.
    ///
    /// Never asks for a trusted process, never asks again after a paste already
    /// succeeded, and never asks twice in the same untrusted stretch.
    public mutating func shouldPromptForPaste(processTrusted: Bool) -> Bool {
        if isTrusted(processTrusted: processTrusted) {
            permission.clearRequested()
            grantLooksStale = false
            return false
        }
        return permission.shouldPrompt(trusted: false)
    }

    /// Records what a trust check saw.
    ///
    /// `afterUserAction` marks the checks that happen when the user comes back
    /// to the app (activation, an explicit grant). That is the moment a stale
    /// grant becomes visible: the user did what the notice asked, and macOS
    /// still reports this build as untrusted.
    public mutating func noteTrustCheck(processTrusted: Bool, afterUserAction: Bool) {
        if processTrusted || pasteSucceeded {
            permission.clearRequested()
            grantLooksStale = false
            return
        }
        if afterUserAction, permission.promptRequested {
            grantLooksStale = true
        }
    }

    /// The synthetic paste command was posted: the session can paste, so stop
    /// asking and stop showing the permission notice for the rest of the
    /// session.
    public mutating func notePasteSucceeded() {
        pasteSucceeded = true
        permission.clearRequested()
        grantLooksStale = false
    }

    /// The user asked for the permission explicitly (the status-bar affordance
    /// or the notice's button), so a paste must not prompt again first.
    public mutating func notePromptRequestedByUser() {
        permission.markRequested()
    }
}

/// The in-app notice about Accessibility, and the rule that retires it.
///
/// The notice is shown when an entry was copied but could not be pasted
/// automatically. Once the permission has been granted the notice is stale -
/// the app can paste - so it has to disappear on its own instead of waiting
/// for the user to dismiss it.
public enum AccessibilityNoticePolicy {
    /// The notice shown when a paste needs the Accessibility permission and
    /// this build has not been asked about yet.
    ///
    /// The remove-and-add guidance matters even for a first grant: the app is
    /// signed locally, so every rebuild is a new binary, and System Settings
    /// keeps the entry of the binary that was there first. Toggling that entry
    /// cannot transfer the grant to the new one.
    public static let pasteNeedsPermission = "Copied to the clipboard. CopyQmac needs Accessibility permission to paste automatically. In System Settings ▸ Privacy & Security ▸ Accessibility, switch CopyQmac on. CopyQmac is signed locally, so every rebuild is a new binary: if CopyQmac is already listed there, select it, remove it with \u{2212}, then add /Applications/CopyQmac.app back with + (or use the Open System Settings\u{2026} button on this message). The entry is ready for a manual \u{2318}V."

    /// The notice shown when the app was already asked about the permission and
    /// the user has come back, but macOS still reports this build as untrusted.
    /// The System Settings switch can look on in that state because it belongs to
    /// an older binary, so repeating the first-run instruction would send the
    /// user in circles.
    public static let pasteNeedsPermissionStaleGrant = "Copied to the clipboard. CopyQmac needs Accessibility permission to paste automatically, but macOS still treats this build as untrusted even though System Settings may show CopyQmac switched on: that switch belongs to an older binary. In System Settings ▸ Privacy & Security ▸ Accessibility, select CopyQmac, remove it with \u{2212}, then add /Applications/CopyQmac.app back with + (or use the Open System Settings\u{2026} button on this message), then return to the app. The entry is ready for a manual \u{2318}V."

    /// The phrase every permission notice contains. Other notices (a failed
    /// read, a note that could not be saved) must survive a permission change.
    private static let permissionMarker = "Accessibility permission"

    /// Whether the notice is one about the Accessibility permission.
    public static func isPermissionNotice(_ notice: String?) -> Bool {
        guard let notice else { return false }
        return notice.contains(permissionMarker)
    }

    /// The permission notice to show for the trust state the app is in.
    public static func permissionNotice(grantLooksStale: Bool) -> String {
        grantLooksStale ? pasteNeedsPermissionStaleGrant : pasteNeedsPermission
    }

    /// Whether the status bar carries the Accessibility item.
    ///
    /// The status bar is the persistent surface for a missing permission: it is
    /// shown while the permission is missing and gone while it is granted. The
    /// banner that announces the same thing is transient, so the two must not be
    /// on screen together; the status-bar item takes over once the banner fades.
    public static func showsStatusItem(trusted: Bool, permissionBannerVisible: Bool) -> Bool {
        !trusted && !permissionBannerVisible
    }

    /// The notice to keep after the permission state was re-read.
    ///
    /// The permission notice disappears as soon as the app is trusted; any
    /// other notice is left alone.
    public static func notice(current: String?, trusted: Bool, grantLooksStale: Bool = false) -> String? {
        guard isPermissionNotice(current) else { return current }
        if trusted { return nil }
        if grantLooksStale { return pasteNeedsPermissionStaleGrant }
        return current
    }
}
