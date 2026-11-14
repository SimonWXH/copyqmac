// Tests for the AppTheme preference and AppearanceManager.

import AppKit
import Foundation

func registerDesignTokensTests() {
    TestRunner.currentSuite = "DesignTokens"

    TestRunner.add("theme defaults to system in preferences") {
        let preferences = Preferences.defaultValue
        expectEqual(preferences.theme, .system)
    }

    TestRunner.add("older preferences json without theme decodes to system") {
        let json = #"{"defaultMaxItems":250,"language":"en"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.theme, .system)
    }

    TestRunner.add("unknown theme value in preferences json falls back to system") {
        let json = #"{"defaultMaxItems":250,"language":"en","theme":"cyberpunk_neon"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.theme, .system)
    }

    TestRunner.add("known theme values survive json encode and decode") {
        for theme in AppTheme.allCases {
            var prefs = Preferences.defaultValue
            prefs.theme = theme
            let encoded = try JSONEncoder().encode(prefs)
            let decoded = try JSONDecoder().decode(Preferences.self, from: encoded)
            expectEqual(decoded.theme, theme)
        }
    }

    TestRunner.add("theme survives store round-trip") {
        let store = try ClipboardStore(inMemory: true)
        var preferences = try store.preferences()
        preferences.theme = .dark
        try store.setPreferences(preferences)

        let reloaded = try store.preferences()
        expectEqual(reloaded.theme, .dark)

        preferences.theme = .light
        try store.setPreferences(preferences)
        let reloadedLight = try store.preferences()
        expectEqual(reloadedLight.theme, .light)
    }

    TestRunner.add("theme maps to the standard or high contrast appearance") {
        expectNil(AppTheme.system.appearanceName(increaseContrast: false))
        expectNil(AppTheme.system.appearanceName(increaseContrast: true))

        expectEqual(AppTheme.light.appearanceName(increaseContrast: false), .aqua)
        expectEqual(
            AppTheme.light.appearanceName(increaseContrast: true),
            .accessibilityHighContrastAqua
        )
        expectEqual(AppTheme.dark.appearanceName(increaseContrast: false), .darkAqua)
        expectEqual(
            AppTheme.dark.appearanceName(increaseContrast: true),
            .accessibilityHighContrastDarkAqua
        )
    }

    TestRunner.add("AppearanceManager applies theme to NSApp and target window") {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let previous = app.appearance
            defer { app.appearance = previous }

            let manager = AppearanceManager.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )

            manager.apply(theme: .dark, to: window)
            expectEqual(window.appearance?.name, manager.resolvedAppearance(for: .dark)?.name)
            expectEqual(NSApp.appearance?.name, manager.resolvedAppearance(for: .dark)?.name)

            manager.apply(theme: .light, to: window)
            expectEqual(window.appearance?.name, manager.resolvedAppearance(for: .light)?.name)
            expectEqual(NSApp.appearance?.name, manager.resolvedAppearance(for: .light)?.name)

            manager.apply(theme: .system, to: window)
            expectNil(window.appearance)
            expectNil(NSApp.appearance)
        }
    }
}
