// Activation: what happens when an item is activated.
//
// CopyQ's History preferences split one fixed behaviour into switches: a single
// click may activate, and an activation copies the item and then optionally
// pastes it, focuses the previous app, closes the window, and moves the item to
// the top of its tab. Every trigger - a single click, a double click, Return,
// and Item ▸ Activate - runs the same ordered plan, so the paths cannot drift
// apart.
//
// AppKit-free, so the tests drive the plan and the runner directly.

import Foundation

/// One step of an activation, in the order `ActivationPlan` applies them.
public enum ActivationAction: String, Equatable, Sendable, CaseIterable {
    /// The item goes on the clipboard. Always the first step.
    case copy
    /// Paste into the previous app, which also brings it to the front.
    case paste
    /// Bring the previous app to the front without pasting.
    case focusPreviousApp
    /// Hide the main window.
    case closeWindow
    /// Move the item to the top of its tab.
    case moveToTop
}

/// The History ▸ Activation switches.
///
/// The defaults are the behaviour from before the switches existed: a click
/// only selects, and activating pastes into the previous app and closes the
/// window.
public struct ActivationOptions: Codable, Equatable, Sendable {
    /// A single click activates the clicked item. When off, a click only
    /// selects it and Return or a double click activates.
    public var singleClickActivates: Bool
    /// Activation pastes the item into the previous app.
    public var paste: Bool
    /// Activation brings the previous app to the front. Pasting does that as
    /// part of its own step, so this only changes anything with `paste` off.
    public var focusPreviousApp: Bool
    /// Activation hides the main window.
    public var closeWindow: Bool
    /// Activation moves the item to the top of its tab.
    public var moveToTop: Bool

    public static let defaultValue = ActivationOptions(
        singleClickActivates: false,
        paste: true,
        focusPreviousApp: true,
        closeWindow: true,
        moveToTop: false
    )

    public init(
        singleClickActivates: Bool,
        paste: Bool,
        focusPreviousApp: Bool,
        closeWindow: Bool,
        moveToTop: Bool
    ) {
        self.singleClickActivates = singleClickActivates
        self.paste = paste
        self.focusPreviousApp = focusPreviousApp
        self.closeWindow = closeWindow
        self.moveToTop = moveToTop
    }

    /// Tolerant decoding, like `Preferences`: a blob written before a switch
    /// existed keeps today's default for it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ActivationOptions.defaultValue
        singleClickActivates = try container.decodeIfPresent(Bool.self, forKey: .singleClickActivates)
            ?? fallback.singleClickActivates
        paste = try container.decodeIfPresent(Bool.self, forKey: .paste) ?? fallback.paste
        focusPreviousApp = try container.decodeIfPresent(Bool.self, forKey: .focusPreviousApp)
            ?? fallback.focusPreviousApp
        closeWindow = try container.decodeIfPresent(Bool.self, forKey: .closeWindow) ?? fallback.closeWindow
        moveToTop = try container.decodeIfPresent(Bool.self, forKey: .moveToTop) ?? fallback.moveToTop
    }
}

public enum ActivationPlan {
    /// The order every activation follows. `actions(for:hasPreviousTarget:)` is
    /// the only thing that decides which of these run.
    public static let order: [ActivationAction] = [
        .copy, .paste, .focusPreviousApp, .closeWindow, .moveToTop,
    ]

    /// The steps one activation runs, in order.
    ///
    /// `hasPreviousTarget` is false when there is no other app to paste into or
    /// focus, for example when the window was opened from the menu bar with
    /// nothing in front of it. Closing the window then would hide the notice
    /// that explains why the item was not delivered, so the window stays open.
    /// A copy-only activation has nothing to deliver, so it may close.
    public static func actions(
        for options: ActivationOptions,
        hasPreviousTarget: Bool
    ) -> [ActivationAction] {
        let delivers = options.paste || options.focusPreviousApp
        let closesWindow = options.closeWindow && (hasPreviousTarget || !delivers)
        return order.filter { action in
            switch action {
            case .copy: return true
            case .paste: return options.paste
            case .focusPreviousApp: return options.focusPreviousApp
            case .closeWindow: return closesWindow
            case .moveToTop: return options.moveToTop
            }
        }
    }
}

/// The work behind each activation step.
///
/// The app supplies the real implementation and the tests supply a recorder
/// that appends every step to an array. It is a value of closures, like the row
/// actions, so the pipeline knows nothing about the window or the paste service.
public struct ActivationHandlers {
    /// Puts the item on the clipboard. `willPaste` is true when a paste step
    /// follows: pasting writes the clipboard itself, so the copy step can leave
    /// the work to it instead of writing every flavour twice.
    public var copy: (_ willPaste: Bool) -> Void
    /// Pastes the item and reports whether it arrived in the previous app.
    public var paste: (@escaping (Bool) -> Void) -> Void
    /// Brings the previous app to the front and reports whether it could.
    public var focusPreviousApp: () -> Bool
    public var closeWindow: () -> Void
    public var moveToTop: () -> Void

    public init(
        copy: @escaping (_ willPaste: Bool) -> Void,
        paste: @escaping (@escaping (Bool) -> Void) -> Void,
        focusPreviousApp: @escaping () -> Bool,
        closeWindow: @escaping () -> Void,
        moveToTop: @escaping () -> Void
    ) {
        self.copy = copy
        self.paste = paste
        self.focusPreviousApp = focusPreviousApp
        self.closeWindow = closeWindow
        self.moveToTop = moveToTop
    }
}

public enum ActivationPipeline {
    /// Runs the plan one step at a time, waiting for a step that finishes
    /// asynchronously (the paste) before starting the next one.
    ///
    /// A delivery that did not arrive - no Accessibility trust, no target, or
    /// an app that refused to activate - skips the close step as well, so the
    /// window stays open with the notice that explains it. A failed delivery
    /// does not steal focus either, for the same reason.
    public static func run(_ actions: [ActivationAction], handlers: ActivationHandlers) {
        var index = 0
        var deliveryFailed = false

        func step() {
            guard index < actions.count else { return }
            let action = actions[index]
            index += 1
            switch action {
            case .copy:
                handlers.copy(actions.contains(.paste))
                step()
            case .paste:
                handlers.paste { arrived in
                    if !arrived { deliveryFailed = true }
                    step()
                }
            case .focusPreviousApp:
                if !deliveryFailed, !handlers.focusPreviousApp() { deliveryFailed = true }
                step()
            case .closeWindow:
                if !deliveryFailed { handlers.closeWindow() }
                step()
            case .moveToTop:
                handlers.moveToTop()
                step()
            }
        }
        step()
    }
}
