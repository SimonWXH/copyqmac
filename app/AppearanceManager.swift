// Theme policy and window-level appearance management.

import AppKit

@MainActor
public final class AppearanceManager {
    public static let shared = AppearanceManager()

    private var theme: AppTheme = .system
    private var contrastObserver: NSObjectProtocol?

    public init() {
        contrastObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyToAllWindows(theme: self.theme)
            }
        }
    }

    /// Applies the theme policy to NSApp and an optional target window.
    public func apply(theme: AppTheme, to window: NSWindow? = nil) {
        self.theme = theme
        let appearance = resolvedAppearance(for: theme)
        NSApp.appearance = appearance
        if let window {
            window.appearance = appearance
        }
    }

    /// Applies the theme policy to NSApp and all currently tracked windows.
    public func applyToAllWindows(theme: AppTheme) {
        self.theme = theme
        let appearance = resolvedAppearance(for: theme)
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }

    /// The appearance a theme resolves to, keeping the system's Increase Contrast setting.
    public func resolvedAppearance(for theme: AppTheme) -> NSAppearance? {
        guard let name = theme.appearanceName(
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        ) else { return nil }
        return NSAppearance(named: name)
    }
}
