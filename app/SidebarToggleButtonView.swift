import AppKit
import SwiftUI

// MARK: - Sidebar Toggle Button

struct SidebarToggleButton: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let language: AppLanguage

    var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    /// Foreground style for the toggle icon in any sidebar visibility state.
    static let iconForegroundColor = DesignTokens.Colors.label
    /// Background color for the toggle icon in any sidebar visibility state.
    static let iconBackgroundColor = Color.clear

    func toggle() {
        columnVisibility = isSidebarVisible ? .detailOnly : .all
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 14))
                .foregroundStyle(Self.iconForegroundColor)
                .frame(width: 28, height: 28)
                .background(Self.iconBackgroundColor)
        }
        .buttonStyle(.hover)
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(Localization.string(.sidebarToggleHelp, language: language))
        .accessibilityIdentifier("SidebarToggleButton")
    }
}

/// Pins the toolbar item that hosts the sidebar toggle to the spot right of the
/// window title, so clicking the toggle never moves it.
struct ToolbarToggleAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.pin()
    }

    final class AnchorView: NSView {
        static let targetX: CGFloat = 256

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let viewer = toolbarItemViewer else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pin),
                name: NSView.frameDidChangeNotification,
                object: viewer
            )
            pin()
        }

        override func layout() {
            super.layout()
            pin()
        }

        @objc func pin() {
            guard let viewer = toolbarItemViewer, viewer.frame.origin.x != Self.targetX else { return }
            viewer.frame.origin.x = Self.targetX
        }

        private var toolbarItemViewer: NSView? {
            var view = superview
            while let current = view {
                if String(describing: type(of: current)) == "NSToolbarItemViewer" {
                    return current
                }
                view = current.superview
            }
            return nil
        }
    }
}
