// Owns the preferences window.
//
// The window and its SwiftUI content are created on first use, not at launch.
// A hidden hosting view would otherwise observe `AppModel` and re-evaluate its
// body - including the stored-item count - on every model publish, which put
// unrelated work on the main thread while the user was only selecting rows.

import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let activationPolicy: ActivationPolicyController
    private let fontFamilies = FontFamilyCatalog()
    private var window: NSWindow?

    init(model: AppModel, activationPolicy: ActivationPolicyController) {
        self.model = model
        self.activationPolicy = activationPolicy
        super.init()
    }

    func show() {
        fontFamilies.load()
        let window = self.window ?? makeWindow()
        self.window = window
        window.title = Localization.string(.settingsWindowTitle, language: model.preferences.language)
        // The preferences window is an app window too: while it is open the
        // app has to be regular so macOS draws the application menu bar for it.
        activationPolicy.windowWillShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateTitle(for language: AppLanguage) {
        window?.title = Localization.string(.settingsWindowTitle, language: language)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Localization.string(.settingsWindowTitle, language: model.preferences.language)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PreferencesView(model: model, fontFamilies: fontFamilies)
        )
        AppearanceManager.shared.apply(theme: model.preferences.theme, to: window)
        window.setFrameAutosaveName("CopyQmacPreferencesWindow")
        window.center()
        return window
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        activationPolicy.windowDidHide(window)
    }
}
