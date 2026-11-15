// SPDX-License-Identifier: GPL-3.0-or-later
//
// InspectorWidthTests.swift
//
// Headless tests for Layout B inspector column width persistence, clamping,
// geometric drag calculation, and debounced commit behavior.

import Foundation

func registerInspectorWidthTests() {
    TestRunner.currentSuite = "InspectorWidth"

    // MARK: - Clamping and Constraints

    TestRunner.add("InspectorColumnLayout clamping enforces 240...560 range") {
        expectEqual(InspectorColumnLayout.defaultWidth, 280)
        expectEqual(InspectorColumnLayout.minWidth, 240)
        expectEqual(InspectorColumnLayout.maxWidth, 560)
        expectEqual(InspectorColumnLayout.minItemListWidth, 320)

        // Below minimum
        expectEqual(InspectorColumnLayout.clampWidth(239), 240)
        expectEqual(InspectorColumnLayout.clampWidth(100), 240)
        expectEqual(InspectorColumnLayout.clampWidth(0), 240)
        expectEqual(InspectorColumnLayout.clampWidth(-50), 240)

        // Above maximum
        expectEqual(InspectorColumnLayout.clampWidth(561), 560)
        expectEqual(InspectorColumnLayout.clampWidth(750), 560)
        expectEqual(InspectorColumnLayout.clampWidth(1000), 560)

        // In range
        expectEqual(InspectorColumnLayout.clampWidth(240), 240)
        expectEqual(InspectorColumnLayout.clampWidth(280), 280)
        expectEqual(InspectorColumnLayout.clampWidth(350.5), 350.5)
        expectEqual(InspectorColumnLayout.clampWidth(560), 560)
    }

    TestRunner.add("InspectorColumnLayout clamping leaves 320 pt for the item list when the container allows it") {
        // Wide container (1000 pt): item list needs 320, remaining is 680, but capped at maxWidth 560
        expectEqual(InspectorColumnLayout.clampWidth(600, containerWidth: 1000), 560)
        expectEqual(InspectorColumnLayout.clampWidth(400, containerWidth: 1000), 400)

        // Medium container (700 pt): 700 - 320 = 380 max allowed inspector width
        expectEqual(InspectorColumnLayout.clampWidth(500, containerWidth: 700), 380)
        expectEqual(InspectorColumnLayout.clampWidth(380, containerWidth: 700), 380)
        expectEqual(InspectorColumnLayout.clampWidth(300, containerWidth: 700), 300)
        expectEqual(InspectorColumnLayout.clampWidth(200, containerWidth: 700), 240, "never below minWidth")

        // Container 560 pt is exactly minWidth + minItemListWidth
        expectEqual(InspectorColumnLayout.clampWidth(560, containerWidth: 560), 240)
        expectEqual(InspectorColumnLayout.clampWidth(560, containerWidth: 561), 241)

        // Narrower container (559 pt and below) cannot fit both minimums: the
        // inspector stays at 240 and the item list takes the remaining 319 pt.
        expectEqual(InspectorColumnLayout.clampWidth(560, containerWidth: 559), 240)
        expectEqual(InspectorColumnLayout.clampWidth(350, containerWidth: 500), 240)
        expectEqual(InspectorColumnLayout.clampWidth(240, containerWidth: 500), 240)

        // Zero / unmeasured container falls back to standard clamping
        expectEqual(InspectorColumnLayout.clampWidth(300, containerWidth: 0), 300)
        expectEqual(InspectorColumnLayout.clampWidth(100, containerWidth: 0), 240)
        expectEqual(InspectorColumnLayout.clampWidth(800, containerWidth: 0), 560)
    }

    TestRunner.add("InspectorColumnLayout drag translation widens on left drag and narrows on right drag") {
        let base: Double = 280

        // Dragging left (negative translation) increases inspector width
        let draggedLeft = InspectorColumnLayout.width(baseWidth: base, translationX: -50, containerWidth: 800)
        expectEqual(draggedLeft, 330, "dragging left by 50 pt widens the column by 50 pt")

        // Dragging right (positive translation) decreases inspector width
        let draggedRight = InspectorColumnLayout.width(baseWidth: base, translationX: 30, containerWidth: 800)
        expectEqual(draggedRight, 250, "dragging right by 30 pt narrows the column by 30 pt")

        // Dragging past minWidth stops at 240
        let draggedPastMin = InspectorColumnLayout.width(baseWidth: base, translationX: 100, containerWidth: 800)
        expectEqual(draggedPastMin, 240, "cannot shrink past minWidth 240")

        // Dragging past container allowance (e.g. 600 pt container, 600 - 320 = 280 max)
        let draggedPastContainer = InspectorColumnLayout.width(baseWidth: base, translationX: -100, containerWidth: 600)
        expectEqual(draggedPastContainer, 280, "cannot expand past container item list minimum constraint")
    }

    TestRunner.add("InspectorColumnLayout drag from a container-clamped width moves on the first pixel") {
        let stored: Double = 560
        let container: CGFloat = 824
        let rendered = InspectorColumnLayout.clampWidth(stored, containerWidth: container)
        expectEqual(rendered, 504, "a 824 pt container renders a stored 560 pt column at 504 pt")

        let draggedRight = InspectorColumnLayout.width(
            baseWidth: rendered,
            translationX: 40,
            containerWidth: container
        )
        expectEqual(draggedRight, 464, "dragging right from the rendered edge narrows the column by 40 pt")

        let draggedLeft = InspectorColumnLayout.width(
            baseWidth: rendered,
            translationX: -40,
            containerWidth: container
        )
        expectEqual(draggedLeft, 504, "a widening drag from the rendered edge stays at the container maximum")
    }

    // MARK: - Preferences Default & Serialization

    TestRunner.add("inspectorColumnWidth defaults to 280 in Preferences.defaultValue") {
        let prefs = Preferences.defaultValue
        expectEqual(prefs.inspectorColumnWidth, 280)
    }

    TestRunner.add("inspectorColumnWidth decode fallback for missing key resolves to default") {
        let json = #"{"defaultMaxItems":250,"language":"en"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.inspectorColumnWidth, 280, "missing inspectorColumnWidth must fall back to 280")
    }

    TestRunner.add("inspectorColumnWidth in json is clamped on decode") {
        let jsonLow = #"{"inspectorColumnWidth":120.0}"#
        let decodedLow = try JSONDecoder().decode(Preferences.self, from: Data(jsonLow.utf8))
        expectEqual(decodedLow.inspectorColumnWidth, 240, "sub-minimum width is clamped to 240")

        let jsonHigh = #"{"inspectorColumnWidth":850.0}"#
        let decodedHigh = try JSONDecoder().decode(Preferences.self, from: Data(jsonHigh.utf8))
        expectEqual(decodedHigh.inspectorColumnWidth, 560, "above-maximum width is clamped to 560")

        let jsonValid = #"{"inspectorColumnWidth":360.0}"#
        let decodedValid = try JSONDecoder().decode(Preferences.self, from: Data(jsonValid.utf8))
        expectEqual(decodedValid.inspectorColumnWidth, 360, "valid width is preserved")
    }

    TestRunner.add("inspectorColumnWidth survives store round-trip") {
        let store = try ClipboardStore(inMemory: true)
        var prefs = try store.preferences()
        expectEqual(prefs.inspectorColumnWidth, 280, "fresh store defaults to 280")

        prefs.inspectorColumnWidth = 350
        try store.setPreferences(prefs)

        let reloaded = try store.preferences()
        expectEqual(reloaded.inspectorColumnWidth, 350, "persisted inspectorColumnWidth is restored")

        prefs.inspectorColumnWidth = 245
        try store.setPreferences(prefs)

        let reloadedB = try store.preferences()
        expectEqual(reloadedB.inspectorColumnWidth, 245, "updated inspectorColumnWidth is restored")
    }

    TestRunner.add("sanitized preferences clamps inspectorColumnWidth") {
        var prefs = Preferences.defaultValue
        prefs.inspectorColumnWidth = 999
        let sanitizedHigh = prefs.sanitized()
        expectEqual(sanitizedHigh.inspectorColumnWidth, 560)

        prefs.inspectorColumnWidth = 50
        let sanitizedLow = prefs.sanitized()
        expectEqual(sanitizedLow.inspectorColumnWidth, 240)
    }
}
