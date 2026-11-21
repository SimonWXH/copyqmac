// Owns the main window and its key monitor.
//
// The window is a standard macOS window: a normal title bar with the traffic
// lights where they belong, an opaque content area that hides the desktop, and
// a frame the user can drag to resize. The glass is an accent inside the
// window, not the window itself.

import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, WindowControllerProtocol {
    private let window: NSWindow
    private let model: AppModel
    private let tracker: FrontmostAppTracker
    private let activationPolicy: ActivationPolicyController
    private let keyMonitor = WindowKeyMonitor()
    private let noteFocusMonitor = NoteFocusMonitor()

    /// The name the window frame is remembered under between launches.
    private static let frameAutosaveName = "CopyQmacMainWindow"
    /// Smallest size that still fits the list, the preview pane, and the note
    /// editor without squeezing them into nothing. This is the window frame,
    /// so it also has to leave room for the title bar above the content.
    private static let minimumSize = NSSize(width: 640, height: 490)

    init(
        model: AppModel,
        tracker: FrontmostAppTracker,
        activationPolicy: ActivationPolicyController
    ) {
        self.model = model
        self.tracker = tracker
        self.activationPolicy = activationPolicy
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "CopyQmac"
        // A standard window: an opaque body that hides the desktop and a
        // normal title bar, so the traffic lights sit where macOS puts them.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.delegate = self
        // With several Spaces the window has to follow the user: ordering it
        // front moves it to the space that is active right now instead of
        // leaving it behind on the space where it was created.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.setFrameAutosaveName(Self.frameAutosaveName)
        let hosting = NSHostingView(
            rootView: MainWindowView(model: model, onDismiss: { [weak self] in self?.hide() })
        )
        // Only the minimum size is taken from SwiftUI: it keeps the window
        // from being dragged smaller than the layout can take, while the
        // window's own size stays the user's. The other sizing options would
        // let SwiftUI's ideal sizes drive the window's maximum size, and a
        // view that briefly needs a lot of height would grow the window far
        // past the screen. The transient banner floats over the list and never
        // contributes height at all.
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        AppearanceManager.shared.apply(theme: model.preferences.theme, to: window)
        restoreFrame()
    }

    /// Puts the window back where the user left it.
    ///
    /// A window that has never been placed is centered; a remembered frame is
    /// restored, unless it ended up on a screen that is no longer there.
    private func restoreFrame() {
        guard window.setFrameUsingName(Self.frameAutosaveName) else {
            window.center()
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        // Remember where the user was before our window takes focus, so
        // paste-back has a target.
        tracker.captureCurrent()
        if model.entries.isEmpty {
            model.reload()
        }
        model.refreshAccessibilityStatus()
        // The menu bar only belongs to a regular app, so become one before the
        // window turns key; an accessory app gets a key, coloured window but no
        // application menu at all.
        activationPolicy.windowWillShow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startKeyMonitor()
        startNoteFocusMonitor()
        model.windowDidShow()
    }

    func hide() {
        keyMonitor.stop()
        noteFocusMonitor.stop()
        window.orderOut(nil)
        // With no window left there is nothing to put a menu bar on, so go back
        // to being a menu-bar-only app and drop the Dock icon.
        activationPolicy.windowDidHide(window)
        model.windowDidHide()
    }

    func toggle() {
        // A window that sits on another Space is not in front of the user, so
        // the hotkey brings it to the active Space instead of hiding it.
        if window.isVisible && window.isOnActiveSpace {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Key handling

    private func startKeyMonitor() {
        keyMonitor.start(
            window: window,
            searchActive: { [weak self] in
                guard let self else { return false }
                return !self.model.searchText.isEmpty
            },
            noteEditing: { [weak self] in
                self?.model.isEditingNote ?? false
            },
            focus: { [weak self] in
                self?.model.keyboardFocus ?? .none
            },
            typeToSearch: { [weak self] text in
                guard let self else { return false }
                self.model.beginTypeToSearch(with: text)
                return true
            },
            handler: { [weak self] key, flags in
                guard let self else { return false }
                return self.handle(key, extending: flags.contains(.shift))
            }
        )
    }

    private func handle(_ key: ListKey, extending: Bool) -> Bool {
        Self.handle(key: key, model: model, extending: extending, dismiss: { [weak self] in self?.hide() })
    }

    @discardableResult
    static func handle(
        key: ListKey,
        model: AppModel,
        extending: Bool = false,
        dismiss: (() -> Void)? = nil
    ) -> Bool {
        if model.handleSidebarNavigation(key) { return true }
        switch key {
        case .up: model.moveSelection(by: -1, extending: extending)
        case .down: model.moveSelection(by: 1, extending: extending)
        case .pageUp: model.moveSelection(by: -8)
        case .pageDown: model.moveSelection(by: 8)
        case .home: model.selectFirst()
        case .end: model.selectLast()
        case .enter: model.pasteSelected(dismiss: dismiss ?? {})
        case .escape:
            // Escape leaves the note editor first, then clears the filter,
            // then drops a multi-selection, then hides the window.
            if model.isEditingNote {
                model.endNoteEditing()
            } else if !model.searchText.isEmpty {
                model.searchText = ""
            } else if model.selectedEntryCount > 1 {
                model.clearSelection()
            } else {
                dismiss?()
            }
        case .delete: model.removeSelected()
        case .digit(let number):
            if model.selectEntry(number: number) {
                model.pasteSelected(dismiss: dismiss ?? {})
            }
        }
        return true
    }

    // MARK: - Mouse handling

    private func startNoteFocusMonitor() {
        noteFocusMonitor.start(
            window: window,
            noteEditing: { [weak self] in self?.model.isEditingNote ?? false },
            commitNote: { [weak self] in self?.model.endNoteEditing() }
        )
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing hides the window; the app keeps running in the menu bar.
        hide()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The permission may have been granted in System Settings while the
        // window was in the background, so the notice and the status-bar
        // button follow the real permission state whenever the window comes
        // back to the front.
        model.refreshAccessibilityStatus()
    }
}
