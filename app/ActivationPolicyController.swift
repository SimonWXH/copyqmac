// Keeps the activation policy in step with the app's visible windows.
//
// macOS 26 does not draw the application menu bar for an accessory
// (`LSUIElement`) app, even while one of its windows is key, its traffic lights
// are coloured, and LaunchServices reports the app as frontmost: the menu bar
// keeps the menus of the last regular app. The menu bar follows the activation
// policy, not the key window. Switching to `.regular` makes the menu bar appear,
// but it also adds a Dock icon, so this controller keeps the app regular only
// while at least one of its own windows is on screen and returns to `.accessory`
// as soon as the last one closes. The measurement behind this is in
// docs/architecture.md#the-menu-bar-and-the-activation-policy.

import AppKit

@MainActor
final class ActivationPolicyController {
    private var visibleWindows: Set<ObjectIdentifier> = []
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Void

    /// `applyPolicy` is injectable so tests can observe the decisions without
    /// creating an `NSApplication` (the headless test binary has no window
    /// server and must not try to change a real activation policy).
    init(applyPolicy: ((NSApplication.ActivationPolicy) -> Void)? = nil) {
        self.applyPolicy = applyPolicy ?? { policy in
            _ = NSApp.setActivationPolicy(policy)
        }
    }

    var hasVisibleWindows: Bool { !visibleWindows.isEmpty }

    /// Registers a window that is about to be ordered front.
    ///
    /// Call this before `makeKeyAndOrderFront` and `activate`: the policy has to
    /// be `.regular` by the time the window becomes key, otherwise the window
    /// turns key under the accessory policy and the menu bar is never drawn for
    /// it (switching afterwards does not help).
    func windowWillShow(_ window: AnyObject) {
        guard visibleWindows.insert(ObjectIdentifier(window)).inserted else { return }
        if visibleWindows.count == 1 {
            applyPolicy(.regular)
        }
    }

    /// Registers a window that has been ordered out.
    func windowDidHide(_ window: AnyObject) {
        guard visibleWindows.remove(ObjectIdentifier(window)) != nil else { return }
        if visibleWindows.isEmpty {
            applyPolicy(.accessory)
        }
    }
}
