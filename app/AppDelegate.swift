// Application wiring: store, watcher, hotkey, menu-bar item, main window, and
// the preferences window.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var history: ClipboardHistory!
    private var watcher: ClipboardWatcher!
    private var pasteService: PasteService!
    private var tracker: FrontmostAppTracker!
    private var hotKeyManager: HotKeyManager!
    private var model: AppModel!
    private var windowController: MainWindowController!
    private var preferencesController: PreferencesWindowController!
    private var activationPolicy: ActivationPolicyController!
    private var actions: AppActions!
    private var statusItem: NSStatusItem!
    /// The right-click menu. It is not assigned to the status item permanently:
    /// doing that would also take over left clicks, which keep toggling the
    /// window. It is attached only for the duration of a right click.
    private var statusMenu: NSMenu!
    private var statusShowItem: NSMenuItem!
    private var statusPauseSyncItem: NSMenuItem!
    private var lastAttemptedShortcut: HotKeyShortcut?
    private var lastAttemptedPlainTextShortcut: HotKeyShortcut?
    private var lastAppliedLanguage: AppLanguage?
    private var lastAppliedWindowLayout: WindowLayout?
    /// The menu-bar notice for a blocked API-key capture and the resting
    /// appearance it returns to.
    private var statusItemNotice: StatusItemNotice!

    /// Held for the lifetime of the app to opt out of App Nap. Without it the
    /// change-count poll timer is throttled while the window is closed, and
    /// clipboard changes are captured late or missed entirely.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Monitoring the pasteboard for clipboard history"
        )

        do {
            let store = try ClipboardStore.openDefault()
            history = ClipboardHistory(store: store)
        } catch {
            presentFatalError("Could not open the clipboard history store: \(error)")
            return
        }

        tracker = FrontmostAppTracker()
        tracker.captureCurrent()
        let tracker = self.tracker!
        watcher = ClipboardWatcher(history: history)
        let watcher = self.watcher!
        // One trust session shared by the paste path and the UI, so a paste that
        // actually posted its Command-V retires the Accessibility notice for the
        // rest of the launch.
        let trust = PasteTrust()
        pasteService = PasteService(tracker: tracker, watcher: watcher, trust: trust)

        model = AppModel(history: history, trust: trust)
        model.attach(pasteService: pasteService)
        model.sourceApplicationProvider = { [weak watcher] in
            watcher?.lastObservedFrontmostApplication
        }
        model.confirmBulkDeletion = { count, language in
            let alert = NSAlert()
            let title = Localization.format(.dialogRemoveItemsTitlePlural, language: language, count)
            alert.messageText = title
            alert.informativeText = Localization.string(.dialogRemoveItemsInformative, language: language)
            alert.alertStyle = .warning
            alert.addButton(withTitle: title)
            alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))
            return alert.runModal() == .alertFirstButtonReturn
        }
        model.confirmSyncMove = { plan, destination, language in
            let alert = NSAlert()
            alert.messageText = Localization.format(.dialogMoveToTabTitle, language: language, destination.name)
            alert.informativeText = plan.summary(language: language)
            alert.alertStyle = .warning
            alert.addButton(withTitle: Localization.string(.buttonMove, language: language))
            alert.addButton(withTitle: Localization.string(.buttonCancel, language: language))
            return alert.runModal() == .alertFirstButtonReturn
        }
        model.onPreferencesChanged = { [weak self] preferences in
            self?.apply(preferences: preferences)
        }
        statusItemNotice = StatusItemNotice(
            scheduler: RunLoopNoticeTimerScheduler(),
            language: model.preferences.language,
            hotKeyDisplayLabel: model.preferences.hotKeyDisplayLabel
        )
        statusItemNotice.onDismiss = { [weak self] in
            self?.applyStatusItemAppearance()
        }

        watcher.onCapture = { [weak self] entry in
            Task { @MainActor in
                self?.model.reload(capturedEntryID: entry.id)
                self?.model.handleCapturedEntry(entry)
            }
        }
        watcher.onAPIKeyCaptureBlocked = { [weak self] in
            MainActor.assumeIsolated { self?.showAPIKeyBlockedNotice() }
        }
        watcher.start()

        // Remember the frontmost app whenever it changes to one that is not us,
        // so paste-back targets the app the user was actually using.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            tracker.remember(app)
        }

        activationPolicy = ActivationPolicyController()
        windowController = MainWindowController(
            model: model,
            tracker: tracker,
            activationPolicy: activationPolicy
        )
        preferencesController = PreferencesWindowController(
            model: model,
            activationPolicy: activationPolicy
        )
        AppearanceManager.shared.applyToAllWindows(theme: model.preferences.theme)
        actions = AppActions(
            model: model,
            windowController: windowController,
            presentPreferences: { [weak self] in self?.preferencesController.show() }
        )
        model.onResyncTabRequest = { [weak self] tabID in
            self?.actions.resyncTab(id: tabID)
        }

        // Granting Accessibility happens in System Settings, so re-read the
        // permission state whenever the user comes back to the app: the banner
        // and the status-bar item can then follow the real permission state on
        // their own.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model?.refreshAccessibilityStatus()
                self?.model?.refreshLaunchAtLoginState()
            }
        }

        setupMainMenu()
        setupStatusItem()

        model.bootstrap()
        model.refreshLaunchAtLoginState()
        apply(preferences: model.preferences)

        // CopyQ opens its main window on launch, so this app does too - except
        // when macOS starts it as a login item, where it stays in the menu bar.
        let launchSource = AppLaunchSource.resolve(
            isLoginItemLaunch: AppLaunchSource.isLoginItemLaunch(
                appleEvent: NSAppleEventManager.shared().currentAppleEvent
            )
        )
        if launchSource.opensMainWindow {
            windowController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flushPendingNote()
        watcher?.stop()
        CopyQSyncWatcher.shared.stop()
        hotKeyManager?.unregisterAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: - Menus

    private func setupMainMenu() {
        NSApp.mainMenu = MainMenuBuilder.build(actions: actions, language: model.preferences.language)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        if let image = NSImage(
            systemSymbolName: "clipboard",
            accessibilityDescription: Localization.string(.statusItemAccessibilityDescription, language: model.preferences.language)
        ) {
            image.isTemplate = true
            button.image = image
        }
        applyStatusItemAppearance()
        // The supported way to tell left from right on a status item button:
        // ask the button to send its action on both mouse-up events and look at
        // the event that triggered it. The old gesture recognizer never saw the
        // right click, which is why the menu never appeared.
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        installStatusMenu(language: model.preferences.language)
    }

    private func installStatusMenu(language: AppLanguage) {
        if statusItem?.menu != nil {
            statusItem.menu = nil
        }
        (statusMenu, statusShowItem, statusPauseSyncItem) = StatusMenuBuilder.build(
            actions: actions,
            language: language
        )
        statusMenu.delegate = self
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            DispatchQueue.main.async { [weak self] in
                self?.windowController.toggle()
            }
            return
        }
        // Attach the menu just long enough to show it, then click the button
        // again. With a menu attached the button shows the menu instead of
        // sending the action, so nothing runs twice; `menuDidClose` detaches it
        // again. This is the supported replacement for the deprecated
        // `popUpStatusItemMenu` and avoids the modal tracking loop that the old
        // synchronous `popUp(positioning:at:in:)` call deadlocked in.
        statusItem.menu = statusMenu
        sender.performClick(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        let visible = windowController.isVisible
        let lang = model.preferences.language
        statusShowItem.title = visible
            ? Localization.string(.statusItemHideCopyQmac, language: lang)
            : Localization.string(.statusItemShowCopyQmac, language: lang)
        statusShowItem.action = visible
            ? #selector(AppActions.hideWindow(_:))
            : #selector(AppActions.showMainWindow(_:))
        statusPauseSyncItem.title = model.preferences.syncPaused
            ? Localization.string(.menuFileResumeSync, language: lang)
            : Localization.string(.menuFilePauseSync, language: lang)
        statusPauseSyncItem.state = model.preferences.syncPaused ? .on : .off
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusItem.menu = nil
    }

    // MARK: - API-key guard notice

    /// Announces a blocked API-key capture in the menu bar itself: the status
    /// item widens for a few seconds and shows a one-line notice beside its
    /// icon, then returns to its usual square. Nothing opens, nothing takes
    /// focus, and the notice never names any part of the payload.
    private func showAPIKeyBlockedNotice() {
        guard statusItem?.button != nil else { return }
        statusItemNotice.show(
            language: model.preferences.language,
            hotKeyDisplayLabel: model.preferences.hotKeyDisplayLabel
        )
        applyStatusItemAppearance()
    }

    private func applyStatusItemAppearance() {
        guard let statusItem, let button = statusItem.button else { return }
        let appearance = statusItemNotice.appearance(hasIcon: button.image != nil)
        statusItem.length = appearance.isWide
            ? NSStatusItem.variableLength
            : NSStatusItem.squareLength
        button.imagePosition = appearance.imagePosition == .iconOnly
            ? .imageOnly
            : .imageLeading
        button.title = appearance.title
        button.toolTip = appearance.toolTip
    }

    // MARK: - Preferences

    private func apply(preferences: Preferences) {
        AppearanceManager.shared.applyToAllWindows(theme: preferences.theme)
        statusItemNotice.update(
            language: preferences.language,
            hotKeyDisplayLabel: preferences.hotKeyDisplayLabel
        )
        applyStatusItemAppearance()

        let languageChanged = preferences.language != lastAppliedLanguage
        let layoutChanged = preferences.windowLayout != lastAppliedWindowLayout
        if languageChanged || layoutChanged {
            lastAppliedLanguage = preferences.language
            lastAppliedWindowLayout = preferences.windowLayout
            setupMainMenu()
        }
        if languageChanged {
            installStatusMenu(language: preferences.language)
            statusItem?.button?.image?.accessibilityDescription = Localization.string(
                .statusItemAccessibilityDescription,
                language: preferences.language
            )
            preferencesController?.updateTitle(for: preferences.language)
        }

        let summon = HotKeyShortcut(preferences: preferences)
        let plainText = HotKeyShortcut.plainText(from: preferences)
        if summon != lastAttemptedShortcut || plainText != lastAttemptedPlainTextShortcut {
            registerHotKeys()
        }
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        let summon = HotKeyShortcut(preferences: model.preferences)
        let plainText = HotKeyShortcut.plainText(from: model.preferences)
        lastAttemptedShortcut = summon
        lastAttemptedPlainTextShortcut = plainText
        hotKeyManager = hotKeyManager ?? HotKeyManager()

        if plainText.isSameKeystroke(as: summon)
            || hotKeyManager.shortcut(for: .pastePlainText)?.isSameKeystroke(as: summon) == true
        {
            hotKeyManager.unregister(.pastePlainText)
        }

        let summonRegistered = hotKeyManager.register(summon, as: .summon) { [weak self] in
            self?.windowController.toggle()
        }
        if !summonRegistered {
            let language = model.preferences.language
            let alert = NSAlert()
            alert.messageText = Localization.string(.dialogShortcutUnavailableTitle, language: language)
            alert.informativeText = Localization.format(
                .dialogShortcutUnavailableInformative,
                language: language,
                Localization.hotKeyLabel(summon.label, language: language)
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: Localization.string(.buttonOpenPreferences, language: language))
            alert.addButton(withTitle: Localization.string(.buttonLater, language: language))
            if alert.runModal() == .alertFirstButtonReturn {
                preferencesController.show()
            }
        }

        guard plainText.isUsable else {
            hotKeyManager.unregister(.pastePlainText)
            model.setPlainTextHotKeyProblem(.modifier)
            return
        }
        guard !plainText.isSameKeystroke(as: summon) else {
            hotKeyManager.unregister(.pastePlainText)
            model.setPlainTextHotKeyProblem(.conflict(shortcutLabel: plainText.label))
            return
        }

        let plainTextRegistered = hotKeyManager.register(plainText, as: .pastePlainText) { [weak self] in
            self?.handlePlainTextShortcut()
        }
        model.setPlainTextHotKeyProblem(
            plainTextRegistered ? nil : .unavailable(shortcutLabel: plainText.label)
        )
    }

    /// The global Paste as Plain Text shortcut.
    ///
    /// A focused text control in our own window keeps the local menu-item
    /// behaviour (paste into the field). Everywhere else the model picks the
    /// selected item when the window is open, or the live clipboard when the
    /// user is working in another app.
    private func handlePlainTextShortcut() {
        // Defer to a focused text control only while CopyQmac is the active app.
        // When another app is in front, its own field must receive the paste.
        if NSApp.isActive, actions.isTextControlFocused {
            actions.pasteSelectedAsPlainText(nil)
            return
        }
        model.pastePlainTextFromGlobalShortcut(
            windowIsVisible: windowController.isVisible,
            frontmostApp: NSWorkspace.shared.frontmostApplication,
            dismiss: { [weak self] in self?.windowController.hide() },
            showNotice: { [weak self] in self?.windowController.show() }
        )
    }

    // MARK: - Errors

    private func presentFatalError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Localization.string(.dialogFatalTitle, language: .english)
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}
