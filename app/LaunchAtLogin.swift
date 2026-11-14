// Launch at login, backed by `SMAppService.mainApp`.
//
// The system is the only source of truth: a preference stored in the database
// could disagree with Login Items after the user disables the entry in System
// Settings, so the toggle reads the real registration state instead. A failed
// registration is reported as an error and the toggle falls back to the state
// macOS actually reports, rather than showing the requested one.
//
// The service is a protocol so the state mapping and the toggle behaviour can
// be exercised headlessly without registering anything in the current session.

import Foundation
import ServiceManagement

/// What Login Items currently says about this app.
enum LaunchAtLoginState: Equatable, Sendable {
    /// The app is registered and approved.
    case enabled
    /// The app is not registered at all.
    case disabled
    /// The app is registered but the user has to allow it in System Settings.
    case requiresApproval
    /// macOS cannot manage this app as a login item right now.
    case unavailable(String)

    var isEnabled: Bool { self == .enabled }

    /// True when macOS cannot manage this app as a login item at all.
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// Where this launch came from. A launch macOS starts as a login item stays
/// in the menu bar; a manual launch opens the main window.
enum AppLaunchSource: Equatable, Sendable {
    case manual
    case loginItem

    var opensMainWindow: Bool { self == .manual }

    static func resolve(isLoginItemLaunch: Bool) -> AppLaunchSource {
        isLoginItemLaunch ? .loginItem : .manual
    }

    /// Whether the launch Apple event says macOS started the app as a login
    /// item (`keyAELaunchedAsLogInItem` in `keyAEPropData`).
    static func isLoginItemLaunch(appleEvent: NSAppleEventDescriptor?) -> Bool {
        guard let appleEvent,
              appleEvent.eventClass == AEEventClass(kCoreEventClass),
              appleEvent.eventID == AEEventID(kAEOpenApplication),
              let propData = appleEvent.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        else { return false }
        return propData.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// The in-app notice about login-item approval, and the rule that retires it.
///
/// The notice is shown when macOS registered the app but needs the user to
/// approve it. Once the registration is usable the notice is stale, so it
/// disappears on its own instead of waiting for another toggle.
enum LaunchAtLoginNotice {
    static let requiresApproval = "Launch at login needs approval in System Settings \u{203A} General \u{203A} Login Items."
    private static let unavailablePrefix = "Launch at login is unavailable: "
    private static let approvalPrefix = "Launch at login needs approval"
    private static let enableFailurePrefix = "Could not enable launch at login"
    private static let disableFailurePrefix = "Could not disable launch at login"

    static func unavailable(_ reason: String) -> String { unavailablePrefix + reason }

    static func failure(enabling: Bool, reason: String) -> String {
        "\(enabling ? enableFailurePrefix : disableFailurePrefix): \(reason)"
    }

    /// Whether the notice reports a launch-at-login state or a failed change.
    /// Other notices are unrelated and must survive a state change.
    static func isLaunchAtLoginNotice(_ notice: String?) -> Bool {
        isFailureNotice(notice) || isStateNotice(notice)
    }

    /// Whether the notice reports a failed enable or disable.
    static func isFailureNotice(_ notice: String?) -> Bool {
        guard let notice else { return false }
        return notice.hasPrefix(enableFailurePrefix) || notice.hasPrefix(disableFailurePrefix)
    }

    private static func isStateNotice(_ notice: String?) -> Bool {
        guard let notice else { return false }
        return notice.hasPrefix(approvalPrefix) || notice.hasPrefix(unavailablePrefix)
    }

    /// The notice to keep after the login-item state was re-read. A state
    /// notice follows the state that needs it; a failure notice is left for the
    /// caller to retire once its requested state is reported.
    static func notice(current: String?, state: LaunchAtLoginState) -> String? {
        guard isStateNotice(current) else { return current }
        return notice(for: state)
    }

    /// The notice the state itself calls for, if any.
    static func notice(for state: LaunchAtLoginState) -> String? {
        switch state {
        case .requiresApproval:
            return requiresApproval
        case .unavailable(let reason):
            return unavailable(reason)
        case .enabled, .disabled:
            return nil
        }
    }
}

@MainActor
protocol LaunchAtLoginService: AnyObject {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

/// The change a toggle click has to make to Login Items.
///
/// Registering an already-registered item would fail, and leaving a registered
/// entry alone keeps a pending approval pending. `.notFound` is the normal
/// pre-registration state of a bundle, so enabling registers it and disabling
/// has nothing to remove.
enum LaunchAtLoginAction: Equatable, Sendable {
    case register
    case unregister
    case leaveAlone

    static func forStatus(_ status: SMAppService.Status, enabling: Bool) -> LaunchAtLoginAction {
        if enabling {
            switch status {
            case .notRegistered, .notFound:
                return .register
            case .enabled, .requiresApproval:
                return .leaveAlone
            @unknown default:
                return .leaveAlone
            }
        } else {
            switch status {
            case .notRegistered, .notFound:
                return .leaveAlone
            case .enabled, .requiresApproval:
                return .unregister
            @unknown default:
                return .unregister
            }
        }
    }
}

/// The real service. One instance per app is enough; every property reads
/// through to `SMAppService`, so no cached state can go stale.
@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginService {
    /// Default arguments are evaluated outside the actor, so the (empty)
    /// initializer has to be nonisolated.
    nonisolated init() {}

    /// Maps the system status onto the states the toggle understands.
    ///
    /// `.notFound` is the normal state before this bundle has ever been
    /// registered, so it means "not registered yet" rather than an error:
    /// treating it as unavailable would disable the toggle on a fresh install.
    static func state(for status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered, .notFound:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        @unknown default:
            return .unavailable("macOS reported an unknown login-item state.")
        }
    }

    var state: LaunchAtLoginState {
        Self.state(for: SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) throws {
        switch LaunchAtLoginAction.forStatus(SMAppService.mainApp.status, enabling: enabled) {
        case .register:
            try SMAppService.mainApp.register()
        case .unregister:
            try SMAppService.mainApp.unregister()
        case .leaveAlone:
            break
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
