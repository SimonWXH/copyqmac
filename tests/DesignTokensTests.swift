// Tests for the AppTheme preference and AppearanceManager.

import AppKit
import Foundation
import SwiftUI

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

    TestRunner.add("hover colour resolves expected alpha for light and dark appearance") {
        let aqua = try unwrap(NSAppearance(named: .aqua))
        let darkAqua = try unwrap(NSAppearance(named: .darkAqua))

        var lightHoverAlpha: CGFloat = -1
        var lightPressedAlpha: CGFloat = -1
        aqua.performAsCurrentDrawingAppearance {
            lightHoverAlpha = DesignTokens.Colors.hoverNSColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? -1
            lightPressedAlpha = DesignTokens.Colors.hoverPressedNSColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? -1
        }

        var darkHoverAlpha: CGFloat = -1
        var darkPressedAlpha: CGFloat = -1
        darkAqua.performAsCurrentDrawingAppearance {
            darkHoverAlpha = DesignTokens.Colors.hoverNSColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? -1
            darkPressedAlpha = DesignTokens.Colors.hoverPressedNSColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? -1
        }

        // Light appearance: label opacity in the 6-8% range (0.07)
        expect(lightHoverAlpha >= 0.06 && lightHoverAlpha <= 0.08, "light hover alpha should be 6-8%")
        expectEqual(Double(lightHoverAlpha), 0.07, accuracy: 0.005)
        // Light pressed: deeper tone (0.12)
        expect(lightPressedAlpha > lightHoverAlpha, "light pressed alpha should be deeper than hover")
        expectEqual(Double(lightPressedAlpha), 0.12, accuracy: 0.005)

        // Dark appearance: adjusted for dark mode (~10%)
        expect(darkHoverAlpha >= 0.09 && darkHoverAlpha <= 0.11, "dark hover alpha should be ~10%")
        expectEqual(Double(darkHoverAlpha), 0.10, accuracy: 0.005)
        // Dark pressed: deeper tone (0.16)
        expect(darkPressedAlpha > darkHoverAlpha, "dark pressed alpha should be deeper than hover")
        expectEqual(Double(darkPressedAlpha), 0.16, accuracy: 0.005)
    }

    TestRunner.add("hover button style background colour responds to hover, pressed, and disabled states") {
        // Unhovered and unpressed -> transparent (Color.clear)
        expectEqual(
            HoverButtonStyle.backgroundColor(isHovering: false, isPressed: false),
            Color.clear
        )
        // Hovered -> DesignTokens.Colors.hover
        expectEqual(
            HoverButtonStyle.backgroundColor(isHovering: true, isPressed: false),
            DesignTokens.Colors.hover
        )
        // Pressed -> DesignTokens.Colors.hoverPressed (deeper)
        expectEqual(
            HoverButtonStyle.backgroundColor(isHovering: true, isPressed: true),
            DesignTokens.Colors.hoverPressed
        )
        expectEqual(
            HoverButtonStyle.backgroundColor(isHovering: false, isPressed: true),
            DesignTokens.Colors.hoverPressed
        )
        // Disabled -> always transparent
        expectEqual(
            HoverButtonStyle.backgroundColor(isHovering: true, isPressed: false, isEnabled: false),
            Color.clear
        )
        expectEqual(
            HoverButtonStyle.backgroundColor(isHovering: false, isPressed: true, isEnabled: false),
            Color.clear
        )
    }

    TestRunner.add("hover button style updates rendered background on hover transition") {
        try MainActor.assumeIsolated {
            // Unhovered: background is clear, so rendered pixel alpha at corner inset is 0.0
            let unhoveredButton = Button("Action") {}
                .buttonStyle(HoverButtonStyle(hovering: .constant(false)))
            let rendererUnhovered = ImageRenderer(content: unhoveredButton)
            let imageUnhovered = try unwrap(rendererUnhovered.nsImage)
            let repUnhovered = try unwrap(NSBitmapImageRep(data: try unwrap(imageUnhovered.tiffRepresentation)))
            let unhoveredAlpha = repUnhovered.colorAt(x: 2, y: 2)?.alphaComponent ?? -1
            expectEqual(Double(unhoveredAlpha), 0.0, accuracy: 0.001, "unhovered background should be transparent")

            // Hovered: background changes to hover colour
            let hoveredButton = Button("Action") {}
                .buttonStyle(HoverButtonStyle(hovering: .constant(true)))
            let rendererHovered = ImageRenderer(content: hoveredButton)
            let imageHovered = try unwrap(rendererHovered.nsImage)
            let repHovered = try unwrap(NSBitmapImageRep(data: try unwrap(imageHovered.tiffRepresentation)))
            let hoveredAlpha = repHovered.colorAt(x: 2, y: 2)?.alphaComponent ?? -1
            expect(hoveredAlpha > 0.05, "hovered background alpha should reflect hover color")
        }
    }
}
