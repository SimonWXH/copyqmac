// SPDX-License-Identifier: GPL-3.0-or-later
//
// SidebarWidthTests.swift
//
// Headless tests for Layout B sidebar column width persistence, clamping,
// and debounced commit behavior.

import Foundation

func registerSidebarWidthTests() {
    TestRunner.currentSuite = "SidebarWidth"

    // MARK: - Clamping and Constraints

    TestRunner.add("SidebarLayout clamping enforces 160...260 range") {
        expectEqual(SidebarLayout.defaultWidth, 200)
        expectEqual(SidebarLayout.minWidth, 160)
        expectEqual(SidebarLayout.maxWidth, 260)

        // Below minimum
        expectEqual(SidebarLayout.clampWidth(159), 160)
        expectEqual(SidebarLayout.clampWidth(100), 160)
        expectEqual(SidebarLayout.clampWidth(0), 160)
        expectEqual(SidebarLayout.clampWidth(-50), 160)

        // Above maximum
        expectEqual(SidebarLayout.clampWidth(261), 260)
        expectEqual(SidebarLayout.clampWidth(500), 260)
        expectEqual(SidebarLayout.clampWidth(1000), 260)

        // In range
        expectEqual(SidebarLayout.clampWidth(160), 160)
        expectEqual(SidebarLayout.clampWidth(200), 200)
        expectEqual(SidebarLayout.clampWidth(255.5), 255.5)
        expectEqual(SidebarLayout.clampWidth(260), 260)
    }

    // MARK: - Preferences Default & Serialization

    TestRunner.add("sidebarWidth defaults to 200 in Preferences.defaultValue") {
        let prefs = Preferences.defaultValue
        expectEqual(prefs.sidebarWidth, 200)
    }

    TestRunner.add("sidebarWidth decode fallback for missing key resolves to default") {
        let json = #"{"defaultMaxItems":250,"language":"en"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.sidebarWidth, 200, "missing sidebarWidth must fall back to 200")
    }

    TestRunner.add("sidebarWidth in json is clamped on decode") {
        let jsonLow = #"{"sidebarWidth":50.0}"#
        let decodedLow = try JSONDecoder().decode(Preferences.self, from: Data(jsonLow.utf8))
        expectEqual(decodedLow.sidebarWidth, 160, "sub-minimum width is clamped to 160")

        let jsonHigh = #"{"sidebarWidth":750.0}"#
        let decodedHigh = try JSONDecoder().decode(Preferences.self, from: Data(jsonHigh.utf8))
        expectEqual(decodedHigh.sidebarWidth, 260, "above-maximum width is clamped to 260")

        let jsonValid = #"{"sidebarWidth":220.0}"#
        let decodedValid = try JSONDecoder().decode(Preferences.self, from: Data(jsonValid.utf8))
        expectEqual(decodedValid.sidebarWidth, 220, "valid width is preserved")
    }

    TestRunner.add("sidebarWidth survives store round-trip") {
        let store = try ClipboardStore(inMemory: true)
        var prefs = try store.preferences()
        expectEqual(prefs.sidebarWidth, 200, "fresh store defaults to 200")

        prefs.sidebarWidth = 240
        try store.setPreferences(prefs)

        let reloaded = try store.preferences()
        expectEqual(reloaded.sidebarWidth, 240, "persisted sidebarWidth is restored")

        prefs.sidebarWidth = 175
        try store.setPreferences(prefs)

        let reloadedB = try store.preferences()
        expectEqual(reloadedB.sidebarWidth, 175, "updated sidebarWidth is restored")
    }

    TestRunner.add("sanitized preferences clamps sidebarWidth") {
        var prefs = Preferences.defaultValue
        prefs.sidebarWidth = 999
        let sanitizedHigh = prefs.sanitized()
        expectEqual(sanitizedHigh.sidebarWidth, 260)

        prefs.sidebarWidth = 20
        let sanitizedLow = prefs.sanitized()
        expectEqual(sanitizedLow.sidebarWidth, 160)
    }
}
